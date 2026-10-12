package com.bvolpato.brutv.playback

internal object LivePlaybackPolicy {
    const val MIN_GO_LIVE_DRIFT_MS = 15_000L

    fun behindDefaultPositionMs(
        currentPositionMs: Long,
        defaultPositionMs: Long?,
        isLive: Boolean,
        isDynamic: Boolean,
        isSeekable: Boolean,
        isPlaceholder: Boolean,
        canSeekToDefaultPosition: Boolean,
    ): Long? {
        if (!isLive || !isDynamic || !isSeekable || isPlaceholder || !canSeekToDefaultPosition) {
            return null
        }
        val defaultPosition = defaultPositionMs ?: return null
        return (defaultPosition - currentPositionMs)
            .takeIf { it > MIN_GO_LIVE_DRIFT_MS }
    }
}
