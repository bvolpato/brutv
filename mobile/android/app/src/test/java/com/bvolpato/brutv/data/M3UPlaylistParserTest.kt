package com.bvolpato.brutv.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class M3UPlaylistParserTest {
    @Test
    fun parsesQuotedMetadataHeadersAndSeparatesMoviesFromLive() {
        val playlist = """
            #EXTM3U
            #EXTINF:-1 tvg-id="news.us" tvg-name="News" tvg-logo="https://img.example/logo.png" group-title="News;US",News HD, East
            #EXTVLCOPT:http-user-agent=BruTV Test Agent
            #EXTVLCOPT:http-referrer=https://provider.example/watch
            https://provider.example/live/news.m3u8?token=a%2Bb
            #EXTINF:-1 group-title="Films",A Film
            https://provider.example/movie/a-film.mkv
            #EXTINF:-1 group-title="Series",Episode without season metadata
            https://provider.example/series/55.mkv
            #EXTINF:-1,Unsupported local file
            file:///tmp/film.mp4
        """.trimIndent()

        val entries = M3UPlaylistParser.parse(playlist)

        assertEquals(3, entries.size)
        val live = entries[0]
        assertEquals("News HD, East", live.name)
        assertEquals("News", live.group)
        assertEquals("news.us", live.tvgId)
        assertEquals("https://img.example/logo.png", live.logo)
        assertEquals("BruTV Test Agent", live.headers["User-Agent"])
        assertEquals("https://provider.example/watch", live.headers["Referer"])
        assertEquals(MediaKind.LIVE, live.kind)
        assertEquals(MediaKind.MOVIE, entries[1].kind)
        assertEquals(MediaKind.MOVIE, entries[2].kind)
        assertFalse(live.id == entries[1].id)
        assertTrue(live.toString().contains("url=<redacted>"))
    }

    @Test
    fun boundsOverlongPlaylistLinesAndUsesStableIds() {
        val first = M3UPlaylistParser.parse("#EXTINF:-1,One\nhttps://example.com/live.ts")
        val second = M3UPlaylistParser.parse("#EXTINF:-1,Renamed\nhttps://example.com/live.ts")

        assertEquals(first.single().id, second.single().id)
        assertTrue(first.single().id.startsWith("m3u:"))
        try {
            M3UPlaylistParser.parse("#" + "x".repeat(128 * 1024) + "\n")
            throw AssertionError("Expected an overlong line to be rejected")
        } catch (error: java.io.IOException) {
            assertEquals("Playlist contains an overlong line.", error.message)
        }
    }

    @Test
    fun rejectsHlsMediaSegmentsAsAChannelList() {
        val hls = """
            #EXTM3U
            #EXT-X-TARGETDURATION:8
            #EXTINF:8.0,
            https://cdn.example/segment-1.ts
            #EXT-X-ENDLIST
        """.trimIndent()

        try {
            M3UPlaylistParser.parse(hls)
            throw AssertionError("Expected an HLS media playlist to be rejected")
        } catch (error: java.io.IOException) {
            assertEquals("Playlist is an HLS stream playlist, not an IPTV channel list.", error.message)
        }
    }
}
