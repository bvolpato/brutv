package com.bvolpato.brutv.playback

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HlsTimeShiftSessionTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun independentRecorderKeepsExpiredUpstreamFootageAndCleansOnClose() = runBlocking {
        Source().use { source ->
            val root = temporary.newFolder()
            val session = HlsTimeShiftSession.open(root, source.url, emptyMap())
            val firstManifest = URL(session.playbackUrl).readText()
            val saved = firstManifest.lines().first { it.startsWith("resource-") }
            val oldUrl = URL(URL(session.playbackUrl), saved)
            for (end in 4L..8L) {
                source.end.set(end)
                await { session.snapshot().durationMs >= end * 1_000 }
            }
            assertEquals(410, source.status("/segment-1.ts"))
            assertEquals(4, oldUrl.readBytes().size)
            assertTrue(session.snapshot().recording)
            assertTrue(session.snapshot().bytes > 3 * 4)
            assertTrue(URL(session.playbackUrl).readText().contains(saved))
            session.close()
            assertTrue(root.listFiles().orEmpty().isEmpty())
            assertEquals(0L, session.snapshot().bytes)
        }
    }

    @Test fun rollingWindowHonorsTimeAndTotalFileBudgetIncludingInitialization() = runBlocking {
        Source(initialization = true, segmentSize = 4_096).use { source ->
            val root = temporary.newFolder()
            val limits = TimeShiftLimits(durationMs = 4_000, bytes = 24_576, segmentBytes = 8_192)
            val session = HlsTimeShiftSession.open(root, source.url, emptyMap(), limits)
            for (end in 4L..9L) {
                source.end.set(end)
                await { TimeShiftPlaylistParser.parse(URL(session.playbackUrl).readText(), session.playbackUrl).segments.last().sequence >= end }
                assertTrue(session.snapshot().bytes <= limits.bytes)
                assertTrue(root.walkTopDown().filter(File::isFile).sumOf(File::length) <= limits.bytes)
            }
            await { session.snapshot().durationMs <= limits.durationMs }
            val manifest = URL(session.playbackUrl).readText()
            assertTrue(manifest.contains("#EXT-X-MAP:URI=\"resource-"))
            assertFalse(manifest.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
            assertTrue(session.snapshot().durationMs in 3_000..4_000)
            session.close()
        }
    }

    @Test fun boundedDownloadsRejectOversizedBodiesWithoutLeavingTemporaryFiles() = runBlocking {
        Source(segmentSize = 8_192, chunked = true).use { source ->
            val root = temporary.newFolder()
            try {
                HlsTimeShiftSession.open(root, source.url, emptyMap(), TimeShiftLimits(segmentBytes = 4_096))
                throw AssertionError("Oversized segment was accepted")
            } catch (_: UnsupportedTimeShift) {
                assertTrue(root.listFiles().orEmpty().isEmpty())
            }
        }
    }

    @Test fun retrySourceCapturesFirstManifestOffsetAndDoesNotRebaseOldSources() = runBlocking {
        Source().use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap(), TimeShiftLimits(durationMs = 4_000))
            val first = session.createPlaybackSource()
            URL(first.url).readText()
            assertEquals(0L, first.windowStartOffsetMs)
            for (end in 4L..8L) {
                source.end.set(end)
                await { TimeShiftPlaylistParser.parse(URL(session.playbackUrl).readText(), session.playbackUrl).segments.last().sequence >= end }
            }
            assertEquals(4_000L, session.snapshot().windowStartOffsetMs)
            val retry = session.createPlaybackSource()
            URL(retry.url).readText()
            assertEquals(4_000L, retry.windowStartOffsetMs)
            URL(first.url).readText()
            assertEquals(0L, first.windowStartOffsetMs)
            session.close()
        }
    }

    @Test fun sourceGapsStopRecordingWithoutStitchingMissingFootage() = runBlocking {
        Source().use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            source.end.set(10)
            await { !session.snapshot().recording }
            assertEquals(3_000L, session.snapshot().durationMs)
            assertTrue(session.snapshot().notice!!.contains("expired footage"))
            assertTrue(URL(session.playbackUrl).readText().contains("#EXT-X-ENDLIST"))
            session.close()
        }
    }

    @Test fun changingProviderTargetKeepsRecordingAndRoundsUpActualNewSegments() = runBlocking {
        Source().use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            source.target.set(2)
            source.segmentDurationMs.set(1_500)
            source.end.set(4)
            await {
                !session.snapshot().recording ||
                    TimeShiftPlaylistParser.parse(URL(session.playbackUrl).readText(), session.playbackUrl).segments.last().sequence >= 4
            }
            assertTrue(session.snapshot().recording)
            assertTrue(URL(session.playbackUrl).readText().contains("#EXT-X-TARGETDURATION:2"))
            source.target.set(1)
            source.segmentDurationMs.set(2_500)
            source.end.set(5)
            await {
                !session.snapshot().recording ||
                    TimeShiftPlaylistParser.parse(URL(session.playbackUrl).readText(), session.playbackUrl).segments.last().sequence >= 5
            }
            assertTrue(session.snapshot().recording)
            assertTrue(URL(session.playbackUrl).readText().contains("#EXT-X-TARGETDURATION:3"))
            assertEquals(7_000L, session.snapshot().durationMs)
            session.close()
        }
    }

    @Test fun fasterProviderDoesNotInheritRetainedLargeTargetPollingInterval() = runBlocking {
        Source().use { source ->
            source.target.set(6)
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            source.target.set(1)
            source.end.set(4)
            await { session.snapshot().durationMs >= 4_000 }
            assertTrue(URL(session.playbackUrl).readText().contains("#EXT-X-TARGETDURATION:6"))
            source.end.set(5)
            await(timeoutMs = 2_000) { session.snapshot().durationMs >= 5_000 }
            assertTrue(session.snapshot().recording)
            session.close()
        }
    }

    @Test fun stripsPrivateHeadersOnCrossOriginSegmentsAndRedirects() = runBlocking {
        val captured = AtomicReference<Map<String, List<String>>>()
        val other = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/") { exchange ->
                captured.set(exchange.requestHeaders.toMap())
                respond(exchange, 200, ByteArray(4))
            }
            start()
        }
        Source(externalSegment = "http://127.0.0.1:${other.address.port}/outside.ts").use { source ->
            val headers = mapOf("Authorization" to "Bearer private", "Cookie" to "private=1", "X-Provider-Secret" to "private", "User-Agent" to "BruTV test")
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, headers)
            val names = captured.get().keys.map(String::lowercase)
            assertFalse("authorization" in names)
            assertFalse("cookie" in names)
            assertFalse("x-provider-secret" in names)
            assertEquals(listOf("BruTV test"), captured.get().entries.first { it.key.equals("User-Agent", true) }.value)
            session.close()
        }
        Source(redirect = "http://127.0.0.1:${other.address.port}/redirected.m3u8").use { source ->
            try {
                HlsTimeShiftSession.open(temporary.newFolder(), source.url, mapOf("Authorization" to "Bearer private", "Cookie" to "private=1", "X-Provider-Secret" to "private"))
                throw AssertionError("A non-HLS redirect response was accepted")
            } catch (_: UnsupportedTimeShift) {
                val names = captured.get().keys.map(String::lowercase)
                assertFalse("authorization" in names)
                assertFalse("cookie" in names)
                assertFalse("x-provider-secret" in names)
            }
        }
        other.stop(0)
    }

    @Test fun cleansOnlyStaleOwnedDirectoriesWithoutRemovingUnrelatedCache() = runBlocking {
        Source().use { source ->
            val root = temporary.newFolder()
            val stale = File(root, "session-00000000-0000-0000-0000-000000000000").apply { mkdir() }
            File(stale, "resource-1.ts").writeBytes(ByteArray(4))
            val unrelated = File(root, "keep-me").apply { writeText("keep") }
            val session = HlsTimeShiftSession.open(root, source.url, emptyMap())
            assertFalse(stale.exists())
            assertTrue(unrelated.exists())
            session.close()
            assertEquals(listOf(unrelated), root.listFiles().orEmpty().toList())
        }
    }

    @Test fun servesConcurrentLoopbackRequestsWithoutBlocking() = runBlocking {
        Source(segmentSize = 8_192).use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            try {
                val manifest = URL(session.playbackUrl).readText()
                val segment = manifest.lines().first { it.startsWith("resource-") }
                val segmentUrl = URL(URL(session.playbackUrl), segment)
                val results = (1..8).map { index ->
                    async(Dispatchers.IO) {
                        if (index % 2 == 0) URL(session.playbackUrl).readText().contains("#EXTM3U")
                        else segmentUrl.readBytes().size == 8_192
                    }
                }.awaitAll()
                assertTrue(results.all { it })
            } finally {
                session.close()
            }
        }
    }

    @Test fun closeAsyncFlipsSnapshotImmediatelyAndCleansDirectoryInBackground() = runBlocking {
        Source().use { source ->
            val root = temporary.newFolder()
            val session = HlsTimeShiftSession.open(root, source.url, emptyMap())
            assertTrue(session.snapshot().recording)
            assertTrue(session.snapshot().bytes > 0L)
            session.closeAsync()
            assertFalse(session.snapshot().recording)
            assertEquals(0L, session.snapshot().bytes)
            await { root.listFiles().orEmpty().isEmpty() }
        }
    }

    @Test fun fastStartupDownloadsOneSegmentForLongTenSecondIptvSegments() = runBlocking {
        Source().use { source ->
            source.target.set(10)
            source.segmentDurationMs.set(10_000)
            source.end.set(5)
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            try {
                assertEquals(10_000L, session.snapshot().durationMs)
                assertTrue(session.snapshot().recording)
            } finally {
                session.close()
            }
        }
    }

    @Test fun bridgesBriefGapAndSourceRestartWithDiscontinuity() = runBlocking {
        Source().use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            try {
                // Brief gap: skip 1 segment (sequence 4 missed, playlist jumps from 3 -> [5, 6, 7]).
                source.end.set(7)
                await { session.snapshot().durationMs >= 6_000L }
                assertTrue(session.snapshot().recording)
                val afterGap = URL(session.playbackUrl).readText()
                assertTrue(afterGap.contains("#EXT-X-DISCONTINUITY"))

                // Source restart: upstream resets back to [1, 2, 3] after reaching 12.
                source.end.set(8)
                await { session.snapshot().durationMs >= 7_000L }
                source.end.set(9)
                await { session.snapshot().durationMs >= 8_000L }
                source.end.set(10)
                await { session.snapshot().durationMs >= 9_000L }
                source.end.set(3)
                await { session.snapshot().durationMs >= 12_000L }
                assertTrue(session.snapshot().recording)
                val afterRestart = URL(session.playbackUrl).readText()
                assertTrue(afterRestart.split("#EXT-X-DISCONTINUITY").size >= 3)
            } finally {
                session.close()
            }
        }
    }

    @Test fun reResolvesOriginalUrlWhenStaleEdgeStallsOrReturnsError() = runBlocking {
        val edgeTwoEnd = AtomicLong(4)
        val redirectCount = AtomicInteger(0)
        val edge1 = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/") { exchange ->
                val path = exchange.requestURI.path
                when {
                    path == "/edge1.m3u8" -> {
                        val body = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n" +
                            "#EXTINF:1.0,\nseg-1.ts\n#EXTINF:1.0,\nseg-2.ts\n#EXTINF:1.0,\nseg-3.ts\n"
                        respond(exchange, 200, body.toByteArray())
                    }
                    path.startsWith("/seg-") -> respond(exchange, 200, ByteArray(8))
                    else -> respond(exchange, 404, ByteArray(0))
                }
            }
            start()
        }
        val edge2 = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/") { exchange ->
                val path = exchange.requestURI.path
                when {
                    path == "/edge2.m3u8" -> {
                        val last = edgeTwoEnd.get()
                        val body = buildString {
                            append("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:${last - 2}\n")
                            for (seq in last - 2..last) append("#EXTINF:1.0,\nseg-$seq.ts\n")
                        }
                        respond(exchange, 200, body.toByteArray())
                    }
                    path.startsWith("/seg-") -> respond(exchange, 200, ByteArray(8))
                    else -> respond(exchange, 404, ByteArray(0))
                }
            }
            start()
        }
        val router = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/live.m3u8") { exchange ->
                val target = if (redirectCount.incrementAndGet() == 1) {
                    "http://127.0.0.1:${edge1.address.port}/edge1.m3u8"
                } else {
                    "http://127.0.0.1:${edge2.address.port}/edge2.m3u8"
                }
                exchange.responseHeaders.add("Location", target)
                respond(exchange, 302, ByteArray(0))
            }
            start()
        }
        try {
            val session = HlsTimeShiftSession.open(
                temporary.newFolder(),
                "http://127.0.0.1:${router.address.port}/live.m3u8",
                emptyMap(),
                TimeShiftLimits(staleManifestTimeoutMs = 900L),
            )
            try {
                await(timeoutMs = 5_000) { session.snapshot().durationMs >= 4_000L }
                assertTrue(redirectCount.get() >= 2)
                assertTrue(session.snapshot().recording)
            } finally {
                session.close()
            }
        } finally {
            router.stop(0)
            edge1.stop(0)
            edge2.stop(0)
        }
    }

    @Test fun rejectsExtensionlessMpegTsAndVideoContentTypeImmediatelyWithoutDraining() = runBlocking {
        val bytesWrittenVideo = AtomicLong(0)
        val bytesWrittenOctet = AtomicLong(0)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/ts-header") { exchange ->
                exchange.responseHeaders.add("Content-Type", "video/mp2t")
                exchange.sendResponseHeaders(200, 0)
                val chunk = ByteArray(16 * 1024) { 0x47 }
                exchange.responseBody.use { out ->
                    runCatching {
                        repeat(128) {
                            out.write(chunk)
                            out.flush()
                            bytesWrittenVideo.addAndGet(chunk.size.toLong())
                        }
                    }
                }
                exchange.close()
            }
            createContext("/ts-extensionless") { exchange ->
                exchange.responseHeaders.add("Content-Type", "application/octet-stream")
                exchange.sendResponseHeaders(200, 0)
                val chunk = ByteArray(16 * 1024) { 0x47 }
                exchange.responseBody.use { out ->
                    runCatching {
                        repeat(128) {
                            out.write(chunk)
                            out.flush()
                            bytesWrittenOctet.addAndGet(chunk.size.toLong())
                        }
                    }
                }
                exchange.close()
            }
            start()
        }
        try {
            for (path in listOf("/ts-header", "/ts-extensionless")) {
                val root = temporary.newFolder()
                try {
                    HlsTimeShiftSession.open(root, "http://127.0.0.1:${server.address.port}$path", emptyMap())
                    throw AssertionError("Raw MPEG-TS stream at $path was accepted as HLS")
                } catch (_: UnsupportedTimeShift) {
                    assertTrue(root.listFiles().orEmpty().isEmpty())
                }
            }
            assertTrue("Expected video/mp2t stream to abort early", bytesWrittenVideo.get() < 512 * 1024)
            assertTrue("Expected extensionless TS stream to abort early", bytesWrittenOctet.get() < 512 * 1024)
        } finally {
            server.stop(0)
        }
    }

    @Test fun reEmitsInitializationMapAfterDiscontinuity() = runBlocking {
        Source(initialization = true).use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            try {
                // Brief gap triggers #EXT-X-DISCONTINUITY while keeping the same initialization map.
                source.end.set(7)
                await { session.snapshot().durationMs >= 6_000L }
                val manifest = URL(session.playbackUrl).readText()
                val afterDiscontinuity = manifest.substringAfter("#EXT-X-DISCONTINUITY\n")
                assertTrue("Expected #EXT-X-DISCONTINUITY in local manifest", manifest.contains("#EXT-X-DISCONTINUITY\n"))
                assertTrue(
                    "Expected #EXT-X-MAP to be re-emitted immediately after #EXT-X-DISCONTINUITY",
                    afterDiscontinuity.startsWith("#EXT-X-MAP:URI=\"resource-"),
                )
            } finally {
                session.close()
            }
        }
    }

    @Test fun http404ThrowsTimeShiftHttpExceptionOnOpenAndFailsFastDuringIngest() = runBlocking {
        val openRequests = AtomicInteger(0)
        val ingestRequests = AtomicInteger(0)
        val failIngest = AtomicInteger(0)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/missing.m3u8") { exchange ->
                openRequests.incrementAndGet()
                respond(exchange, 404, ByteArray(0))
            }
            createContext("/live.m3u8") { exchange ->
                if (failIngest.get() > 0) {
                    ingestRequests.incrementAndGet()
                    respond(exchange, 404, ByteArray(0))
                } else {
                    val body = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n" +
                        "#EXTINF:1.0,\nseg-1.ts\n#EXTINF:1.0,\nseg-2.ts\n#EXTINF:1.0,\nseg-3.ts\n"
                    respond(exchange, 200, body.toByteArray())
                }
            }
            createContext("/seg-") { exchange ->
                respond(exchange, 200, ByteArray(8))
            }
            start()
        }
        try {
            val root = temporary.newFolder()
            try {
                HlsTimeShiftSession.open(root, "http://127.0.0.1:${server.address.port}/missing.m3u8", emptyMap())
                throw AssertionError("Expected HTTP 404 to throw TimeShiftHttpException")
            } catch (error: TimeShiftHttpException) {
                assertEquals(404, error.statusCode)
                assertEquals(1, openRequests.get())
                assertTrue(root.listFiles().orEmpty().isEmpty())
            }

            val session = HlsTimeShiftSession.open(
                temporary.newFolder(),
                "http://127.0.0.1:${server.address.port}/live.m3u8",
                emptyMap(),
            )
            try {
                failIngest.set(1)
                await(timeoutMs = 2_000) { !session.snapshot().recording }
                assertEquals(1, ingestRequests.get())
                assertTrue(session.snapshot().notice.orEmpty().contains("404"))
            } finally {
                session.closeAsync().join()
            }
        } finally {
            server.stop(0)
        }
    }

    @Test fun loopbackServerSupportsHttp11KeepAliveAndDynamicLimitsCapLowRamDevices() = runBlocking {
        val lowRamLimits = computeTimeShiftLimits(isLowRamDevice = true, usableSpaceBytes = 2L * 1024 * 1024 * 1024)
        assertEquals(64L * 1024 * 1024, lowRamLimits.bytes)
        assertEquals(300_000L, lowRamLimits.durationMs)

        val lowStorageLimits = computeTimeShiftLimits(isLowRamDevice = false, usableSpaceBytes = 128L * 1024 * 1024)
        assertTrue(lowStorageLimits.bytes <= 64L * 1024 * 1024)

        Source(segmentSize = 16).use { source ->
            val session = HlsTimeShiftSession.open(temporary.newFolder(), source.url, emptyMap())
            try {
                val url = URL(session.playbackUrl)
                java.net.Socket("127.0.0.1", url.port).use { socket ->
                    socket.soTimeout = 3_000
                    val out = socket.getOutputStream()
                    val input = socket.getInputStream().buffered()

                    fun readHttpResponse(): Pair<String, ByteArray> {
                        val headerBytes = java.io.ByteArrayOutputStream()
                        var tail = 0
                        while (true) {
                            val b = input.read()
                            if (b < 0) throw AssertionError("Unexpected EOF on keep-alive socket")
                            headerBytes.write(b)
                            tail = (tail shl 8) or b
                            if (tail == 0x0d0a0d0a) break
                        }
                        val headerText = headerBytes.toString("US-ASCII")
                        val contentLength = headerText.lines()
                            .first { it.startsWith("Content-Length:", true) }
                            .substringAfter(':').trim().toInt()
                        val body = ByteArray(contentLength)
                        var read = 0
                        while (read < contentLength) {
                            val n = input.read(body, read, contentLength - read)
                            if (n <= 0) throw AssertionError("Short body read")
                            read += n
                        }
                        return headerText to body
                    }

                    // Request 1: manifest over persistent HTTP/1.1 socket.
                    out.write("GET ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    out.flush()
                    val (manifestHeaders, manifestBody) = readHttpResponse()
                    assertTrue(manifestHeaders.contains("200 OK"))
                    assertTrue(manifestHeaders.contains("Connection: keep-alive", ignoreCase = true))
                    val manifestText = manifestBody.toString(Charsets.UTF_8)
                    val segmentName = manifestText.lines().first { it.startsWith("resource-") }

                    // Request 2: segment over the exact same TCP connection (tests keep-alive + HashMap resource index).
                    val segmentPath = url.path.substringBeforeLast('/') + "/" + segmentName
                    out.write("GET $segmentPath HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    out.flush()
                    val (segHeaders, segBody) = readHttpResponse()
                    assertTrue(segHeaders.contains("200 OK"))
                    assertEquals(16, segBody.size)
                }
            } finally {
                session.close()
            }
        }
    }

    private fun await(timeoutMs: Long = 4_000, condition: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (!condition()) {
            if (System.nanoTime() >= deadline) throw AssertionError("Recorder did not reach the expected state")
            Thread.sleep(25)
        }
    }

    private class Source(
        val initialization: Boolean = false,
        val segmentSize: Int = 4,
        val chunked: Boolean = false,
        val externalSegment: String? = null,
        val redirect: String? = null,
    ) : AutoCloseable {
        val end = AtomicLong(3)
        val lastRequested = AtomicLong()
        val target = AtomicInteger(1)
        val segmentDurationMs = AtomicLong(1_000)
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            createContext("/") { exchange ->
                val path = exchange.requestURI.path
                when {
                    path == "/live.m3u8" && redirect != null -> {
                        exchange.responseHeaders.add("Location", redirect)
                        respond(exchange, 302, ByteArray(0))
                    }
                    path == "/live.m3u8" -> {
                        val last = end.get()
                        val text = buildString {
                            append("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:${target.get()}\n#EXT-X-MEDIA-SEQUENCE:${last - 2}\n")
                            if (initialization) append("#EXT-X-MAP:URI=\"init.mp4\"\n")
                            for (sequence in last - 2..last) {
                                append("#EXTINF:${segmentDurationMs.get() / 1000.0},\n${externalSegment ?: "segment-$sequence.ts"}\n")
                            }
                        }
                        respond(exchange, 200, text.toByteArray())
                    }
                    path == "/init.mp4" -> respond(exchange, 200, ByteArray(4_096))
                    path.startsWith("/segment-") -> {
                        val sequence = path.substringAfter("segment-").substringBefore('.').toLong()
                        lastRequested.set(sequence)
                        val status = if (sequence < end.get() - 2) 410 else 200
                        respond(exchange, status, if (status == 200) ByteArray(segmentSize) else ByteArray(0), chunked)
                    }
                    else -> respond(exchange, 404, ByteArray(0))
                }
            }
            start()
        }
        val url = "http://127.0.0.1:${server.address.port}/live.m3u8"
        fun status(path: String): Int = (URL(URL(url), path).openConnection() as java.net.HttpURLConnection).run {
            try { responseCode } finally { disconnect() }
        }
        override fun close() { server.stop(0) }
    }

    companion object {
        private fun respond(exchange: HttpExchange, code: Int, body: ByteArray, chunked: Boolean = false) {
            exchange.sendResponseHeaders(code, if (body.isEmpty()) -1 else if (chunked) 0 else body.size.toLong())
            exchange.responseBody.use { output -> runCatching { output.write(body) } }
            exchange.close()
        }
    }
}
