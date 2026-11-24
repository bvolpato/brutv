package com.bvolpato.brutv.data

import com.bvolpato.brutv.ui.sanitizeUserErrorMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.UUID
import java.util.Base64
import javax.net.ssl.SSLPeerUnverifiedException

class CatalogRepositoryTest {
    @Test
    fun authenticatesLoadsXtreamCatalogAndEncodesCredentialsInPlaybackPath() = runBlocking {
        val seenActions = java.util.Collections.synchronizedList(mutableListOf<String>())
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            seenActions += request.url.queryParameter("action").orEmpty()
            val body = when (request.url.queryParameter("action")) {
                null -> """{"user_info":{"auth":"1","status":"Active"},"server_info":{}}"""
                "get_live_categories" -> """[{"category_id":3,"category_name":"News"}]"""
                "get_live_streams" -> """[{"stream_id":77,"name":"World News HD","category_id":"3","epg_channel_id":"world.news","stream_icon":"https://img.example/world.png"}]"""
                else -> "[]"
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(
                name = "Family",
                server = "https://provider.example/panel",
                username = "user/name",
                password = "pass + word",
            ),
            client,
        )

        repository.authenticate()
        val catalog = repository.load(MediaKind.LIVE)

        assertEquals(setOf("get_live_categories", "get_live_streams"), seenActions.drop(1).toSet())
        assertEquals("News", catalog.categories.single().name)
        val channel = catalog.entries.single()
        assertEquals("world.news", channel.epgId)
        assertTrue(channel.streamUrl.contains("/live/user%2Fname/pass%20%2B%20word/77.m3u8"))
        assertTrue(channel.toString().contains("streamUrl=<redacted>"))
    }

    @Test
    fun duplicateXtreamCategoriesAndStreamsKeepTheFirstProviderEntry() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val body = when (request.url.queryParameter("action")) {
                "get_live_categories" -> """[
                    {"category_id":"3","category_name":"First category"},
                    {"category_id":"3","category_name":"Duplicate category"}
                ]"""
                "get_live_streams" -> """[
                    {"stream_id":"77","name":"First channel","category_id":"3"},
                    {"stream_id":"77","name":"Duplicate channel","category_id":"3"}
                ]"""
                else -> "[]"
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p"),
            client,
        )

        val catalog = repository.load(MediaKind.LIVE)

        assertEquals(listOf(Category("3", "First category")), catalog.categories)
        assertEquals(1, catalog.entries.size)
        assertEquals("First channel", catalog.entries.single().name)
    }

    @Test
    fun malformedSuccessfulCatalogResponseThrowsAndCanBeRetried() = runBlocking {
        var streamRequests = 0
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val body = when (request.url.queryParameter("action")) {
                "get_live_categories" -> "[]"
                "get_live_streams" -> {
                    streamRequests++
                    if (streamRequests == 1) """{"error":"temporarily unavailable"}"""
                    else """[{"stream_id":"77","name":"Recovered channel"}]"""
                }
                else -> "[]"
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p"),
            client,
        )

        try {
            repository.load(MediaKind.LIVE)
            throw AssertionError("Expected a malformed catalog response to be rejected")
        } catch (error: CatalogDataException) {
            assertEquals("The provider returned an invalid catalog response.", error.message)
        }

        assertEquals("Recovered channel", repository.load(MediaKind.LIVE).entries.single().name)
        assertEquals(2, streamRequests)
    }

    @Test
    fun cancellingProviderRequestCancelsTheUnderlyingOkHttpCall() = runBlocking {
        val requestEntered = CountDownLatch(1)
        val releaseRequest = CountDownLatch(1)
        val observedCall = AtomicReference<okhttp3.Call>()
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            observedCall.set(chain.call())
            requestEntered.countDown()
            if (!releaseRequest.await(5, TimeUnit.SECONDS)) throw IOException("Test request timed out")
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body("""{"user_info":{"auth":"1","status":"Active"}}""".toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p"),
            client,
        )

        val job = launch(Dispatchers.IO) { repository.authenticate() }
        try {
            assertTrue(requestEntered.await(5, TimeUnit.SECONDS))
            val call = requireNotNull(observedCall.get())
            job.cancel()
            releaseRequest.countDown()
            job.join()
            assertTrue("The cancelled coroutine must cancel its HTTP call", call.isCanceled())
        } finally {
            releaseRequest.countDown()
        }
    }

    @Test
    fun seriesEpisodesAndShortGuideUseTheMatchingXtreamActions() = runBlocking {
        val actions = java.util.Collections.synchronizedList(mutableListOf<String>())
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val action = request.url.queryParameter("action").orEmpty()
            actions += action
            val body = when (action) {
                "get_series_categories" -> """[{"category_id":"9","category_name":"Drama"}]"""
                "get_series" -> """[{"series_id":12,"name":"Example series","category_id":"9"}]"""
                "get_series_info" -> """{"episodes":{"1":[{"id":55,"title":"Pilot","episode_num":1,"container_extension":"mkv","info":{"plot":"First episode","movie_image":"https://img.example/pilot.jpg"}}]}}"""
                "get_short_epg" -> """{"epg_listings":[{"title":"Evening news","description":"Headlines","start_timestamp":"100","stop_timestamp":"200"}]}"""
                else -> "[]"
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p"), client)

        val series = repository.load(MediaKind.SERIES).entries.single()
        val episodes = repository.episodes(series)
        val guideChannel = MediaEntry(id = "channel", providerId = "7", name = "News", kind = MediaKind.LIVE)
        val guide = repository.guide(guideChannel)

        assertEquals(setOf("get_series_categories", "get_series"), actions.take(2).toSet())
        assertEquals("get_series_info", actions[2])
        assertEquals("get_short_epg", actions[3])
        assertEquals("First episode", episodes.single().plot)
        assertTrue(episodes.single().streamUrl.endsWith("/series/u/p/55.mkv"))
        assertEquals(1, episodes.single().seasonNumber)
        assertEquals(1, episodes.single().episodeNumber)
        assertEquals("Evening news", guide.single().title)
        assertEquals("Headlines", guide.single().description)
        assertEquals(100L, guide.single().startEpochSeconds)
        assertEquals(200L, guide.single().endEpochSeconds)
    }

    @Test
    fun decodesStandardBase64EpgTextAndNormalizesDecodedWhitespace() = runBlocking {
        val title = Base64.getEncoder().encodeToString("  Family programme\n".toByteArray(Charsets.UTF_8))
        val description = Base64.getEncoder().encodeToString("A programme with family stories.".toByteArray(Charsets.UTF_8))
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val body = if (request.url.queryParameter("action") == "get_short_epg") {
                """{"epg_listings":[{"title":"$title","description":"$description","start_timestamp":"100","stop_timestamp":"200"}]}"""
            } else "[]"
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p"),
            client,
        )
        val channel = MediaEntry(id = "channel", providerId = "7", name = "News", kind = MediaKind.LIVE)

        val programme = repository.guide(channel).single()

        assertEquals("Family programme", programme.title)
        assertEquals("A programme with family stories.", programme.description)
    }

    @Test
    fun m3uRepositorySeparatesLiveAndVODAndReturnsNoInventedGuideData() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val playlist = """
                #EXTM3U
                #EXTINF:-1 group-title="News",Channel
                https://streams.example/channel.m3u8
                #EXTINF:-1 group-title="Films",Film
                https://streams.example/movie/film.mp4
            """.trimIndent()
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(playlist.toResponseBody("audio/x-mpegurl".toMediaType()))
                .build()
        }).build()
        val repository = CatalogRepository(
            SourceConfig(name = "Family playlist", type = SourceType.M3U, playlistUrl = "https://provider.example/list.m3u"),
            client,
        )

        repository.authenticate()
        val live = repository.load(MediaKind.LIVE)
        val movies = repository.load(MediaKind.MOVIE)

        assertEquals("Channel", live.entries.single().name)
        assertEquals("Film", movies.entries.single().name)
        assertEquals("News", live.categories.single().name)
        assertTrue(repository.load(MediaKind.SERIES).entries.isEmpty())
        assertTrue(repository.guide(live.entries.single()).isEmpty())
    }

    @Test
    fun localM3uImportsAreReadOnlyAndConfinedToTheAppPlaylistDirectory() = runBlocking {
        val root = Files.createTempDirectory("brutv-store").toFile()
        val playlistDirectory = File(root, "no_backup/playlists").apply { mkdirs() }
        val playlistFile = File(playlistDirectory, "${UUID.randomUUID()}.m3u").apply {
            writeText("#EXTM3U\n#EXTINF:-1,Local channel\nhttps://streams.example/local.m3u8\n")
        }
        val source = SourceConfig(
            name = "Imported playlist",
            type = SourceType.M3U,
            playlistUrl = playlistFile.toURI().toString(),
        )
        val repository = CatalogRepository(source, localPlaylistDirectory = playlistDirectory)

        val channels = repository.load(MediaKind.LIVE).entries

        assertEquals("Local channel", channels.single().name)
        assertTrue(playlistFile.exists())
        val outside = File(root, "outside.m3u").apply { writeText("#EXTM3U") }
        val link = File(playlistDirectory, "${UUID.randomUUID()}.m3u")
        Files.createSymbolicLink(link.toPath(), outside.toPath())
        try {
            CatalogRepository(source.copy(playlistUrl = link.toURI().toString()), localPlaylistDirectory = playlistDirectory)
                .load(MediaKind.LIVE)
            throw AssertionError("Expected a file outside the import directory to be rejected")
        } catch (error: CatalogDataException) {
            assertEquals("The imported playlist is not available on this device.", error.message)
        }
    }

    @Test
    fun retriesTransientHttpAndNetworkErrorsRespectingRetryAfterAndStopsOnAuthOrCertErrors() = runBlocking {
        val attempts = AtomicInteger(0)
        val recordedDelays = mutableListOf<Long>()
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            when (attempts.incrementAndGet()) {
                1 -> Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(429)
                    .message("Too Many Requests")
                    .header("Retry-After", "2")
                    .body("".toResponseBody("text/plain".toMediaType()))
                    .build()
                2 -> Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(522)
                    .message("Origin Connection Timed Out")
                    .body("".toResponseBody("text/plain".toMediaType()))
                    .build()
                else -> Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body("""{"user_info":{"auth":"1","status":"Active"}}""".toResponseBody("application/json".toMediaType()))
                    .build()
            }
        }).build()

        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
        val repository = CatalogRepository(
            source = source,
            client = client,
            localPlaylistDirectory = null,
            retryDelay = { recordedDelays += it },
            jitter = { 0.5 },
            maxJsonBytes = 64L * 1024 * 1024,
        )
        repository.authenticate()
        assertEquals(3, attempts.get())
        assertEquals(listOf(2_000L, 1_500L), recordedDelays)

        // Retry-After is capped at MAX_RETRY_AFTER_MS.
        assertEquals(CatalogRepository.MAX_RETRY_AFTER_MS, CatalogRepository.parseRetryAfterMs("999"))
        assertEquals(0L, CatalogRepository.parseRetryAfterMs("0"))

        // Transient SocketTimeoutException retries up to 2 times and succeeds on 3rd attempt.
        val ioAttempts = AtomicInteger(0)
        val ioClient = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            if (ioAttempts.incrementAndGet() <= 2) throw SocketTimeoutException("read timed out")
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body("""{"user_info":{"auth":"1","status":"Active"}}""".toResponseBody("application/json".toMediaType()))
                .build()
        }).build()
        CatalogRepository(source, ioClient, null, { }, { 0.5 }, 64L * 1024 * 1024).authenticate()
        assertEquals(3, ioAttempts.get())

        // Non-retryable HTTP 403 and SSLPeerUnverifiedException fail immediately without retries.
        val authAttempts = AtomicInteger(0)
        val authClient = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            authAttempts.incrementAndGet()
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(403)
                .message("Forbidden")
                .body("".toResponseBody("text/plain".toMediaType()))
                .build()
        }).build()
        try {
            CatalogRepository(source, authClient, null, { }, { 0.5 }, 64L * 1024 * 1024).authenticate()
            throw AssertionError("Expected HTTP 403 to fail")
        } catch (error: CatalogDataException) {
            assertEquals("Provider request failed with HTTP 403.", error.message)
            assertEquals(1, authAttempts.get())
        }

        val sslAttempts = AtomicInteger(0)
        val sslClient = OkHttpClient.Builder().addInterceptor(Interceptor { _ ->
            sslAttempts.incrementAndGet()
            throw SSLPeerUnverifiedException("cert mismatch")
        }).build()
        try {
            CatalogRepository(source, sslClient, null, { }, { 0.5 }, 64L * 1024 * 1024).authenticate()
            throw AssertionError("Expected SSLPeerUnverifiedException to fail")
        } catch (_: CatalogDataException) {
            assertEquals(1, sslAttempts.get())
        }
    }

    @Test
    fun streamsLargeXtreamCatalogPrecomputingQualityAndCategoryStatsAndRejectsOversized() = runBlocking {
        val count = 1_500
        val largeStreamsJson = buildString {
            append('[')
            for (i in 1..count) {
                if (i > 1) append(',')
                val tag = when (i % 4) {
                    0 -> "4K"
                    1 -> "FHD"
                    2 -> "HD"
                    else -> "Channel"
                }
                val cat = (i % 5) + 1
                append(
                    """{"stream_id":$i,"name":"Item $i $tag","category_id":"$cat","stream_icon":"https://img.example/$i.png","nested":{"a":[1,2,3],"flag":true},"extra_null":null}""",
                )
            }
            append(']')
        }
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val body = when (chain.request().url.queryParameter("action")) {
                "get_live_categories" -> """[{"category_id":"1","category_name":"Cat 1"},{"category_id":"2","category_name":"Cat 2"}]"""
                "get_live_streams" -> largeStreamsJson
                else -> "[]"
            }
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()

        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
        val section = CatalogRepository(source, client).load(MediaKind.LIVE)
        assertEquals(count, section.entries.size)
        assertEquals(300, section.categoryCounts["1"])
        assertEquals("https://img.example/5.png", section.categoryIcons["1"])
        assertEquals("https://img.example/1.png", section.firstArtworkUrl)
        assertEquals("FHD", section.entries[0].quality)
        assertEquals("HD", section.entries[1].quality)
        assertEquals("SD", section.entries[2].quality)
        assertEquals("4K", section.entries[3].quality)
        assertEquals("item 1 fhd", section.entries[0].searchableName)

        // Oversized streaming catalog is rejected cleanly by BoundedInputStream.
        val tinyLimitRepo = CatalogRepository(source, client, null, { }, { 0.5 }, maxJsonBytes = 512L)
        try {
            tinyLimitRepo.load(MediaKind.LIVE)
            throw AssertionError("Expected oversized streamed catalog to be rejected")
        } catch (error: CatalogDataException) {
            assertEquals("The provider response exceeds the size limit.", error.message)
        }
    }

    @Test
    fun sanitizeUserErrorMessagePreservesHttpStatusWithoutLeakingUrlsOrCredentials() {
        assertEquals(
            "Provider request failed with HTTP 522.",
            sanitizeUserErrorMessage(CatalogDataException("Provider request failed with HTTP 522.")),
        )
        assertEquals(
            "Provider request failed with HTTP 403.",
            sanitizeUserErrorMessage(CatalogDataException("Provider request failed with HTTP 403.")),
        )
        assertEquals(
            "The playlist contains no supported HTTP streams.",
            sanitizeUserErrorMessage(CatalogDataException("The playlist contains no supported HTTP streams.")),
        )

        val leakedUrl = sanitizeUserErrorMessage(IOException("Failed reading https://provider.example/live/alice/secret/1.m3u8"))
        assertFalse(leakedUrl.contains("provider.example"))
        assertFalse(leakedUrl.contains("secret"))

        val leakedCreds = sanitizeUserErrorMessage(IOException("Invalid query username=alice&password=secret"))
        assertFalse(leakedCreds.contains("alice"))
        assertFalse(leakedCreds.contains("secret"))

        val leakedHost = sanitizeUserErrorMessage(IOException("Unable to resolve host \"private.example\": No address"))
        assertFalse(leakedHost.contains("private.example"))
    }

    @Test
    fun streamingJsonReaderHandlesUtf8BomAndLenientJson() = runBlocking {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val raw = when (chain.request().url.queryParameter("action")) {
                "get_live_categories" -> """/* header */ [{category_id:1,category_name:'News'}]"""
                "get_live_streams" -> """[{stream_id:42,name:'Channel One',category_id:1}]"""
                else -> "[]"
            }
            val bytes = bom + raw.toByteArray(Charsets.UTF_8)
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(bytes.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()

        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
        val section = CatalogRepository(source, client).load(MediaKind.LIVE)
        assertEquals(1, section.categories.size)
        assertEquals("News", section.categories.single().name)
        assertEquals(1, section.entries.size)
        assertEquals("Channel One", section.entries.single().name)
    }

    @Test
    fun midStreamEofDuringCatalogStreamRetriesAndSucceeds() = runBlocking {
        val streamAttempts = AtomicInteger(0)
        val recordedDelays = mutableListOf<Long>()
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val action = request.url.queryParameter("action")
            val body: ResponseBody = when (action) {
                "get_live_categories" -> """[{"category_id":"1","category_name":"News"}]"""
                    .toResponseBody("application/json".toMediaType())
                "get_live_streams" -> {
                    if (streamAttempts.incrementAndGet() == 1) {
                        object : ResponseBody() {
                            override fun contentType() = "application/json".toMediaType()
                            override fun contentLength() = -1L
                            override fun source(): BufferedSource = object : Source {
                                private var sentPrefix = false
                                override fun read(sink: Buffer, byteCount: Long): Long {
                                    if (!sentPrefix) {
                                        sentPrefix = true
                                        val prefix = """[{"stream_id":"77","name":"Part"""
                                        sink.writeUtf8(prefix)
                                        return prefix.length.toLong()
                                    }
                                    throw EOFException("mid-stream disconnect")
                                }
                                override fun timeout(): Timeout = Timeout.NONE
                                override fun close() {}
                            }.buffer()
                        }
                    } else {
                        """[{"stream_id":"77","name":"Recovered Live","category_id":"1"}]"""
                            .toResponseBody("application/json".toMediaType())
                    }
                }
                else -> "[]".toResponseBody("application/json".toMediaType())
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body)
                .build()
        }).build()

        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
        val repository = CatalogRepository(
            source = source,
            client = client,
            localPlaylistDirectory = null,
            retryDelay = { recordedDelays += it },
            jitter = { 0.5 },
            maxJsonBytes = 64L * 1024 * 1024,
        )
        val section = repository.load(MediaKind.LIVE)

        assertEquals(2, streamAttempts.get())
        assertEquals(1, recordedDelays.size)
        assertEquals("Recovered Live", section.entries.single().name)
    }

    @Test
    fun authenticateHandlesUtf8BomAndHonorsAllowedOutputFormatsAndMaxConnections() = runBlocking {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val authJson = AtomicReference(
            """{"user_info":{"auth":"1","status":"Active","allowed_output_formats":["ts"],"max_connections":"3"}}""",
        )
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val raw = when (request.url.queryParameter("action")) {
                null -> authJson.get()
                "get_live_categories" -> """[{"category_id":"1","category_name":"News"}]"""
                "get_live_streams" -> """[{"stream_id":"42","name":"Channel One","category_id":"1"}]"""
                else -> "[]"
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body((bom + raw.toByteArray(Charsets.UTF_8)).toResponseBody("application/json".toMediaType()))
                .build()
        }).build()

        val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
        val repository = CatalogRepository(source, client)

        repository.authenticate()
        assertEquals(3, repository.maxConnections)
        val tsChannel = repository.load(MediaKind.LIVE).entries.single()
        assertTrue(tsChannel.streamUrl.endsWith("/live/u/p/42.ts"))

        repository.clearCache()
        assertEquals(1, repository.maxConnections)

        authJson.set(
            """{"user_info":{"auth":"1","status":"Active","allowed_output_formats":["m3u8","ts"],"max_connections":"0"}}""",
        )
        repository.authenticate()
        assertEquals(1, repository.maxConnections)
        val hlsChannel = repository.load(MediaKind.LIVE).entries.single()
        assertTrue(hlsChannel.streamUrl.endsWith("/live/u/p/42.m3u8"))

        assertEquals("ts", CatalogRepository.selectLiveExtension(listOf("ts")))
        assertEquals("ts", CatalogRepository.selectLiveExtension(listOf("MPEGTS")))
        assertEquals("m3u8", CatalogRepository.selectLiveExtension(listOf("m3u8", "ts")))
        assertEquals("m3u8", CatalogRepository.selectLiveExtension(listOf("hls", "ts")))
        assertEquals("m3u8", CatalogRepository.selectLiveExtension(null))
        assertEquals(1, CatalogRepository.parseMaxConnections(null))
        assertEquals(1, CatalogRepository.parseMaxConnections("-2"))
        assertEquals(4, CatalogRepository.parseMaxConnections(" 4 "))
    }

    @Test
    fun forceReloadInvalidatesCacheDeduplicatesConcurrentLoadsAndFetchesVodInfo() = runBlocking {
        val streamCalls = AtomicInteger(0)
        val channelName = AtomicReference("Initial Channel")
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val action = chain.request().url.queryParameter("action")
            val body = when (action) {
                "get_live_categories" -> """[{"category_id":"1","category_name":"News"}]"""
                "get_live_streams" -> {
                    streamCalls.incrementAndGet()
                    Thread.sleep(60)
                    """[{"stream_id":"42","name":"${channelName.get()}","category_id":"1"}]"""
                }
                "get_vod_info" -> """{"info":{"plot":"A classic film.","cast":"Actor A, Actor B","director":"Director X","duration":"01:45:00","genre":"Drama","releasedate":"2024-05-01","rating":"8.4"}}"""
                else -> "[]"
            }
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()
        }).build()

        val cacheDir = Files.createTempDirectory("brutv-cache").toFile()
        try {
            val source = SourceConfig(name = "Family", server = "https://provider.example", username = "u", password = "p")
            val repository = CatalogRepository(source, client, cacheDirectory = cacheDir)

            // Concurrent loads for the same MediaKind deduplicate to 1 network request.
            val results = listOf(
                async(Dispatchers.IO) { repository.load(MediaKind.LIVE) },
                async(Dispatchers.IO) { repository.load(MediaKind.LIVE) },
            ).map { it.await() }
            assertEquals(1, streamCalls.get())
            assertEquals("Initial Channel", results[0].entries.single().name)
            assertEquals("Initial Channel", results[1].entries.single().name)

            // force = true invalidates cache and replaces cached section with fresh data.
            channelName.set("Updated Channel")
            val refreshed = repository.load(MediaKind.LIVE, force = true)
            assertEquals(2, streamCalls.get())
            assertEquals("Updated Channel", refreshed.entries.single().name)
            assertEquals("Updated Channel", repository.load(MediaKind.LIVE).entries.single().name)
            assertEquals(2, streamCalls.get())

            // Disk cache round-trip works and reconstructs Xtream URLs without storing credentials on disk.
            val diskCached = repository.readDiskCache(MediaKind.LIVE)
            assertTrue(diskCached != null && !diskCached.isStale)
            assertEquals("Updated Channel", diskCached!!.section.entries.single().name)
            assertTrue(diskCached.section.entries.single().streamUrl.endsWith("/live/u/p/42.m3u8"))
            val rawCacheBytes = cacheDir.listFiles()!!.single().readBytes().toString(Charsets.UTF_8)
            assertFalse(rawCacheBytes.contains("/live/u/p/"))

            // get_vod_info parses movie metadata.
            val movie = MediaEntry(id = "m1", providerId = "99", name = "Film", kind = MediaKind.MOVIE)
            val details = repository.vodInfo(movie)
            assertTrue(details != null)
            assertEquals("A classic film.", details!!.plot)
            assertEquals("Actor A, Actor B", details.cast)
            assertEquals("Director X", details.director)
            assertEquals("01:45:00", details.duration)
            assertEquals("Drama", details.genre)
        } finally {
            cacheDir.deleteRecursively()
        }
    }
}
