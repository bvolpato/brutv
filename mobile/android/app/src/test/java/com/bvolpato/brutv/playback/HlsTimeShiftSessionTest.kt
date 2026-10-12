package com.bvolpato.brutv.playback

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
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
