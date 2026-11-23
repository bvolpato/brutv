package com.bvolpato.brutv.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LivePlaybackPolicyTest {
    @Test fun defaultManifestHoldbackDoesNotCountAsBehindLive() {
        assertNull(drift(currentPositionMs = 70_000))
        assertNull(drift(currentPositionMs = 90_000))
    }

    @Test fun showsGoLiveOnlyAfterSignificantDriftFromDefaultPosition() {
        assertNull(drift(currentPositionMs = 55_000))
        assertEquals(15_001L, drift(currentPositionMs = 54_999))
        assertEquals(30_000L, drift(currentPositionMs = 40_000))
    }

    @Test fun hidesGoLiveForUnknownVodNonseekableOrFinishedTimelines() {
        assertNull(drift(defaultPositionMs = null))
        assertNull(drift(isLive = false))
        assertNull(drift(isDynamic = false))
        assertNull(drift(isSeekable = false))
        assertNull(drift(isPlaceholder = true))
        assertNull(drift(canSeekToDefaultPosition = false))
    }

    @Test fun derivesBidirectionalAlternateXtreamLiveUrlsAndPreservesQueryAndEncoding() {
        assertEquals(
            "https://provider.example/live/user/pass/1234.ts",
            LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live/user/pass/1234.m3u8"),
        )
        assertEquals(
            "https://provider.example/live/user/pass/1234.m3u8",
            LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live/user/pass/1234.ts"),
        )
        assertEquals(
            "https://provider.example:8443/panel/live/user%2Fname/pass%20%2B%20word/77.ts?token=a%2Bb&k=1",
            LivePlaybackPolicy.alternateLiveFormatUrl(
                "https://provider.example:8443/panel/live/user%2Fname/pass%20%2B%20word/77.m3u8?token=a%2Bb&k=1",
            ),
        )
        assertEquals(
            "http://provider.example:8080/alice/secret/99.ts?output=ts",
            LivePlaybackPolicy.alternateLiveFormatUrl("http://provider.example:8080/alice/secret/99.m3u8?output=ts"),
        )
        assertEquals(
            "http://provider.example:8080/alice/secret/99.m3u8?token=xyz",
            LivePlaybackPolicy.alternateLiveFormatUrl("http://provider.example:8080/alice/secret/99.ts?token=xyz"),
        )
        assertEquals(
            "https://provider.example/live/u/p/55.ts",
            LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live/u/p/55.M3U8"),
        )
        assertEquals(
            "https://provider.example/live/u/p/55.m3u8",
            LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live/u/p/55.TS"),
        )

        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://cdn.example/channel/live.m3u8"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/movie/u/p/12.mp4"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/movie/u/p/12.m3u8"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/series/u/p/12.ts"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live/u/p/.m3u8"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("https://provider.example/live//p/12.m3u8"))
        assertNull(LivePlaybackPolicy.alternateLiveFormatUrl("file:///tmp/live/u/p/12.m3u8"))
    }

    @Test fun progressMonitorDetectsFrozenPlayheadForLiveAndVodAndIgnoresPause() {
        val monitor = PlaybackProgressMonitor()
        assertFalse(monitor.sample(nowElapsedMs = 0L, positionMs = 5_000L, isPlayingReady = true, isLive = true).frozen)
        assertFalse(monitor.sample(nowElapsedMs = 9_500L, positionMs = 5_000L, isPlayingReady = true, isLive = true).frozen)
        assertTrue(monitor.sample(nowElapsedMs = 10_000L, positionMs = 5_000L, isPlayingReady = true, isLive = true).frozen)

        // Advancing playhead resets the frozen timer.
        assertFalse(monitor.sample(nowElapsedMs = 11_000L, positionMs = 6_000L, isPlayingReady = true, isLive = true).frozen)
        assertFalse(monitor.sample(nowElapsedMs = 19_000L, positionMs = 6_000L, isPlayingReady = true, isLive = true).frozen)

        // VOD waits 15s before triggering frozen detection.
        monitor.resetAll()
        assertFalse(monitor.sample(nowElapsedMs = 0L, positionMs = 1_000L, isPlayingReady = true, isLive = false).frozen)
        assertFalse(monitor.sample(nowElapsedMs = 10_000L, positionMs = 1_000L, isPlayingReady = true, isLive = false).frozen)
        assertFalse(monitor.sample(nowElapsedMs = 14_500L, positionMs = 1_000L, isPlayingReady = true, isLive = false).frozen)
        assertTrue(monitor.sample(nowElapsedMs = 15_000L, positionMs = 1_000L, isPlayingReady = true, isLive = false).frozen)

        // Paused state never triggers frozen detection.
        assertFalse(monitor.sample(nowElapsedMs = 100_000L, positionMs = 1_000L, isPlayingReady = false, isLive = true).frozen)
    }

    @Test fun progressMonitorAccumulatesHealthyPlaybackAcrossMicroRebuffersAndIgnoresBigSeeks() {
        val monitor = PlaybackProgressMonitor()
        var now = 0L
        var pos = 0L
        monitor.sample(now, pos, isPlayingReady = true, isLive = true)
        repeat(18) {
            now += 1_000L
            pos += 1_000L
            assertFalse(monitor.sample(now, pos, isPlayingReady = true, isLive = true).reachedHealthyThreshold)
        }
        // Brief micro-rebuffer drops isPlayingReady without wiping the 18s of healthy playback.
        now += 1_000L
        assertFalse(monitor.sample(now, pos, isPlayingReady = false, isLive = true).reachedHealthyThreshold)
        // Resume playback after micro-rebuffer: first sample re-anchors position, then 12s more reaches 30s total.
        now += 500L
        assertFalse(monitor.sample(now, pos, isPlayingReady = true, isLive = true).reachedHealthyThreshold)
        var reached = false
        repeat(12) {
            now += 1_000L
            pos += 1_000L
            if (monitor.sample(now, pos, isPlayingReady = true, isLive = true).reachedHealthyThreshold) {
                reached = true
            }
        }
        assertTrue(reached)

        // Large forward seek must not count as 60s of healthy playback.
        monitor.resetAll()
        monitor.sample(0L, 1_000L, isPlayingReady = true, isLive = false)
        assertFalse(monitor.sample(500L, 61_000L, isPlayingReady = true, isLive = false).reachedHealthyThreshold)
    }

    @Test fun liveFormatMemoryRemembersEvictsLruExpiresByTtlAndClears() {
        val memory = LiveFormatMemory(maxEntries = 2, ttlMs = 1_000L)
        memory.remember("https://provider.example/live/u/p/1.m3u8", "https://provider.example/live/u/p/1.ts", nowMs = 100L)
        memory.remember("https://provider.example/live/u/p/2.m3u8", "https://provider.example/live/u/p/2.ts", nowMs = 200L)

        // Access entry 1 so entry 2 becomes least recently used.
        assertEquals("https://provider.example/live/u/p/1.ts", memory.get("https://provider.example/live/u/p/1.m3u8", nowMs = 300L))

        // Adding entry 3 evicts entry 2, keeping entries 1 and 3.
        memory.remember("https://provider.example/live/u/p/3.m3u8", "https://provider.example/live/u/p/3.ts", nowMs = 400L)
        assertNull(memory.get("https://provider.example/live/u/p/2.m3u8", nowMs = 450L))
        assertEquals("https://provider.example/live/u/p/1.ts", memory.get("https://provider.example/live/u/p/1.m3u8", nowMs = 450L))
        assertEquals("https://provider.example/live/u/p/3.ts", memory.get("https://provider.example/live/u/p/3.m3u8", nowMs = 450L))

        // Entry 1 expires at recordedAtMs (100) + ttlMs (1000) = 1100; entry 3 is still valid until 1400.
        assertNull(memory.get("https://provider.example/live/u/p/1.m3u8", nowMs = 1_100L))
        assertEquals("https://provider.example/live/u/p/3.ts", memory.get("https://provider.example/live/u/p/3.m3u8", nowMs = 1_100L))

        memory.clear()
        assertNull(memory.get("https://provider.example/live/u/p/3.m3u8", nowMs = 1_150L))
    }

    private fun drift(
        currentPositionMs: Long = 40_000,
        defaultPositionMs: Long? = 70_000,
        isLive: Boolean = true,
        isDynamic: Boolean = true,
        isSeekable: Boolean = true,
        isPlaceholder: Boolean = false,
        canSeekToDefaultPosition: Boolean = true,
    ) = LivePlaybackPolicy.behindDefaultPositionMs(
        currentPositionMs, defaultPositionMs, isLive, isDynamic,
        isSeekable, isPlaceholder, canSeekToDefaultPosition,
    )
}
