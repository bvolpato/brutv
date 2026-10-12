package com.bvolpato.brutv.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimeShiftPlaylistTest {
    @Test fun preservesSequenceDiscontinuityGapInitializationAndDate() {
        val playlist = TimeShiftPlaylistParser.parse("""
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:40
            #EXT-X-DISCONTINUITY-SEQUENCE:3
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-PROGRAM-DATE-TIME:2026-10-12T12:00:00Z
            #EXTINF:2.0,
            one.m4s
            #EXT-X-DISCONTINUITY
            #EXT-X-GAP
            #EXTINF:1.5,
            two.m4s
        """.trimIndent(), "https://example.com/channel/live.m3u8")
        assertEquals(40L, playlist.segments[0].sequence)
        assertEquals(41L, playlist.segments[1].sequence)
        assertEquals(3L, playlist.segments[0].discontinuitySequence)
        assertEquals(4L, playlist.segments[1].discontinuitySequence)
        assertEquals("https://example.com/channel/init.mp4", playlist.segments[0].initializationUrl)
        assertEquals("2026-10-12T12:00:00Z", playlist.segments[0].programDateTime)
        assertFalse(playlist.segments[0].gap)
        assertTrue(playlist.segments[1].gap)
        assertEquals(1500L, playlist.segments[1].durationMs)
    }

    @Test fun choosesOneBoundedMuxedVariantWithoutSilentlyDiscardingRenditions() {
        assertEquals("https://example.com/hd.m3u8", TimeShiftPlaylistParser.variant("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
            sd.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
            hd.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=16000000,RESOLUTION=3840x2160
            uhd.m3u8
        """.trimIndent(), "https://example.com/master.m3u8"))
        rejects("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            video.m3u8
        """.trimIndent(), master = true)
    }

    @Test fun rejectsEncryptedRangesDeltaAndPartialOnlyInsteadOfPretendingToRecord() {
        listOf(
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"",
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"",
            "#EXT-X-BYTERANGE:200@0",
            "#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"100@0\"",
            "#EXT-X-SKIP:SKIPPED-SEGMENTS=3",
        ).forEach { tag -> rejects("#EXTM3U\n#EXT-X-TARGETDURATION:2\n$tag\n#EXTINF:2,\nsegment.ts\n") }
        rejects("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-PART:DURATION=0.5,URI=\"part.ts\"\n")
        rejects("not a playlist")
    }

    private fun rejects(text: String, master: Boolean = false) {
        try {
            if (master) TimeShiftPlaylistParser.variant(text, "https://example.com/live.m3u8")
            else TimeShiftPlaylistParser.parse(text, "https://example.com/live.m3u8")
            throw AssertionError("Unsupported recording was accepted")
        } catch (_: UnsupportedTimeShift) {
            // The caller can safely retain direct native playback.
        }
    }
}
