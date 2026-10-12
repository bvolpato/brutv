package com.bvolpato.brutv.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.UUID
import java.util.Base64

class CatalogRepositoryTest {
    @Test
    fun authenticatesLoadsXtreamCatalogAndEncodesCredentialsInPlaybackPath() = runBlocking {
        val seenActions = mutableListOf<String>()
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

        assertEquals(listOf("get_live_categories", "get_live_streams"), seenActions.drop(1))
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
        val actions = mutableListOf<String>()
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

        assertEquals("get_series_categories", actions[0])
        assertEquals("get_series", actions[1])
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
}
