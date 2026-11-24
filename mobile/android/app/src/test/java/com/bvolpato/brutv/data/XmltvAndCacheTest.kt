package com.bvolpato.brutv.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.kxml2.io.KXmlParser
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.util.zip.GZIPOutputStream

class XmltvAndCacheTest {
    @Test
    fun catalogSectionPrecomputesCategoryAndIdIndexesInSinglePass() {
        val catNews = Category("1", "News")
        val catSports = Category("2", "Sports")
        val e1 = MediaEntry(id = "c1", name = "News 1 HD", kind = MediaKind.LIVE, categoryId = "1", artwork = "https://img.example/1.png")
        val e2 = MediaEntry(id = "c2", name = "News 2 4K", kind = MediaKind.LIVE, categoryId = "1")
        val e3 = MediaEntry(id = "c3", name = "Sports 1", kind = MediaKind.LIVE, categoryId = "2", artwork = "https://img.example/3.png")

        val section = CatalogSection.build(listOf(catNews, catSports), listOf(e1, e2, e3))

        assertEquals(listOf(e1, e2), section.entriesByCategory["1"])
        assertEquals(listOf(e3), section.entriesByCategory["2"])
        assertEquals(e1, section.entriesById["c1"])
        assertEquals(e2, section.entriesById["c2"])
        assertEquals(e3, section.entriesById["c3"])
        assertNull(section.entriesById["missing"])
        assertEquals(2, section.categoryCounts["1"])
        assertEquals("https://img.example/1.png", section.categoryIcons["1"])
        assertEquals("https://img.example/3.png", section.categoryIcons["2"])
    }

    @Test
    fun xmltvParserStreamsBoundedWindowHandlesGzipAndResolvesNowAndNext() {
        // Fixed reference time: 2026-11-24 12:30:00 UTC -> 1795523400
        val now = XmltvParser.parseXmltvTimestamp("20261124123000 +0000")!!
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <tv>
              <channel id="News.US">
                <display-name>World News HD</display-name>
              </channel>
              <programme start="20261120100000 +0000" stop="20261120110000 +0000" channel="News.US">
                <title>Ancient Programme Outside Window</title>
              </programme>
              <programme start="20261124120000 +0000" stop="20261124130000 +0000" channel="News.US">
                <title>Midday Headlines</title>
                <desc>Live coverage</desc>
              </programme>
              <programme start="20261124100000 -0300" stop="20261124110000 -0300" channel="News.US">
                <title>Afternoon Briefing</title>
                <desc>Timezone offset test (13:00-14:00 UTC)</desc>
              </programme>
              <programme start="20261201120000 +0000" stop="20261201130000 +0000" channel="News.US">
                <title>Far Future Outside Window</title>
              </programme>
            </tv>
        """.trimIndent()

        // Compress as GZIP to verify transparent gzip detection.
        val gzOut = ByteArrayOutputStream()
        GZIPOutputStream(gzOut).use { it.write(xml.toByteArray(Charsets.UTF_8)) }

        val guide = XmltvParser.parse(
            input = ByteArrayInputStream(gzOut.toByteArray()),
            nowEpochSeconds = now,
            parserFactory = { KXmlParser() },
        )

        val byEpgId = MediaEntry(id = "ch1", name = "Other Name", kind = MediaKind.LIVE, epgId = "news.us")
        val byDisplayName = MediaEntry(id = "ch2", name = "World News HD", kind = MediaKind.LIVE)
        val programmes = guide.programmesFor(byEpgId)
        assertEquals(2, programmes.size)
        assertEquals("Midday Headlines", programmes[0].title)
        assertEquals("Afternoon Briefing", programmes[1].title)
        assertEquals(programmes, guide.programmesFor(byDisplayName))

        val (current, next) = guide.nowAndNext(byEpgId, nowEpochSeconds = now)
        assertNotNull(current)
        assertNotNull(next)
        assertEquals("Midday Headlines", current!!.title)
        assertEquals("Afternoon Briefing", next!!.title)
    }

    @Test
    fun catalogDiskCacheRespectsTtlAndClearsSourceFiles() {
        val dir = Files.createTempDirectory("brutv-disk-cache").toFile()
        try {
            val cache = CatalogDiskCache(dir, ttlMs = 1_000L)
            val entry = MediaEntry(
                id = "src:live:10",
                providerId = "10",
                name = "Channel 10 HD",
                kind = MediaKind.LIVE,
                categoryId = "cat1",
                artwork = "https://img.example/10.png",
                streamUrl = "https://streams.example/live.m3u8",
                epgId = "ch10",
                requestHeaders = mapOf("User-Agent" to "CustomUA"),
            )
            val section = CatalogSection.build(listOf(Category("cat1", "General")), listOf(entry))
            cache.write("src-1", MediaKind.LIVE, section, isXtream = false, nowMs = 10_000L)

            val fresh = cache.read("src-1", MediaKind.LIVE, isXtream = false, nowMs = 10_500L)
            assertNotNull(fresh)
            assertFalse(fresh!!.isStale)
            assertEquals("Channel 10 HD", fresh.section.entriesById["src:live:10"]?.name)
            assertEquals("CustomUA", fresh.section.entries.single().requestHeaders["User-Agent"])

            val stale = cache.read("src-1", MediaKind.LIVE, isXtream = false, nowMs = 12_000L)
            assertNotNull(stale)
            assertTrue(stale!!.isStale)

            cache.clearSource("src-1")
            assertNull(cache.read("src-1", MediaKind.LIVE, isXtream = false, nowMs = 10_500L))
        } finally {
            dir.deleteRecursively()
        }
    }
}
