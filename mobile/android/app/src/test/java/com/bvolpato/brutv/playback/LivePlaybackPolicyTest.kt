package com.bvolpato.brutv.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
