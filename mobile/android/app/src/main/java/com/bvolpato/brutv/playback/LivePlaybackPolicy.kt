package com.bvolpato.brutv.playback

import java.net.URI
import java.util.Locale

internal object LivePlaybackPolicy {
    const val MIN_GO_LIVE_DRIFT_MS = 15_000L
    private val NON_LIVE_ROOT_SEGMENTS = setOf("movie", "series", "timeshift", "vod", "hls", "streams", "static", "assets")

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

    /**
     * Derives the alternate Xtream live format URL (`.m3u8` <-> `.ts`) while preserving
     * percent-encoded path segments, port, query parameters, and fragments.
     * Supports `/live/u/p/id.{m3u8|ts}`, `/prefix/live/u/p/id.{m3u8|ts}`, and `/u/p/id.{m3u8|ts}`.
     */
    fun alternateLiveFormatUrl(url: String): String? {
        val trimmed = url.trim()
        val parsed = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = parsed.scheme?.lowercase(Locale.ROOT)
        if ((scheme != "http" && scheme != "https") || parsed.host.isNullOrBlank()) return null

        val schemeEnd = trimmed.indexOf("://")
        if (schemeEnd < 0) return null
        val authorityStart = schemeEnd + 3
        val pathStart = trimmed.indexOf('/', authorityStart)
        if (pathStart < 0) return null
        val suffixStart = trimmed.indexOfAny(charArrayOf('?', '#'), pathStart).let { if (it < 0) trimmed.length else it }
        val rawPath = trimmed.substring(pathStart, suffixStart)
        val segments = rawPath.removePrefix("/").split('/')
        if (segments.any { it.isEmpty() }) return null

        val lastSegment = segments.last()
        val dotIndex = lastSegment.lastIndexOf('.')
        if (dotIndex <= 0 || dotIndex == lastSegment.lastIndex) return null
        val extension = lastSegment.substring(dotIndex + 1).lowercase(Locale.ROOT)
        val alternateExtension = when (extension) {
            "m3u8" -> "ts"
            "ts" -> "m3u8"
            else -> return null
        }

        val hasLivePrefix = segments.size >= 4 && segments[segments.size - 4].equals("live", ignoreCase = true)
        val isShortXtreamLive = segments.size == 3 && segments[0].lowercase(Locale.ROOT) !in NON_LIVE_ROOT_SEGMENTS
        if (!hasLivePrefix && !isShortXtreamLive) return null

        val replacementPath = rawPath.substring(0, rawPath.length - extension.length) + alternateExtension
        return trimmed.substring(0, pathStart) + replacementPath + trimmed.substring(suffixStart)
    }
}

internal data class PlaybackProgressSample(
    val frozen: Boolean,
    val reachedHealthyThreshold: Boolean,
)

/**
 * Tracks live/VOD playhead advancement to detect frozen playback (without false positives on pause)
 * and accumulate healthy playback time across brief micro-rebuffers.
 */
internal class PlaybackProgressMonitor(
    private val liveFrozenTimeoutMs: Long = LIVE_FROZEN_TIMEOUT_MS,
    private val vodFrozenTimeoutMs: Long = VOD_FROZEN_TIMEOUT_MS,
    private val healthyResetThresholdMs: Long = HEALTHY_RESET_THRESHOLD_MS,
) {
    private var lastPositionMs: Long = Long.MIN_VALUE
    private var frozenSinceMs: Long = Long.MIN_VALUE
    private var cumulativeHealthyMs: Long = 0L

    fun sample(
        nowElapsedMs: Long,
        positionMs: Long,
        isPlayingReady: Boolean,
        isLive: Boolean,
    ): PlaybackProgressSample {
        if (!isPlayingReady) {
            // Micro-rebuffers or pauses reset the frozen detector without erasing healthy playback credit.
            lastPositionMs = Long.MIN_VALUE
            frozenSinceMs = Long.MIN_VALUE
            return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
        }
        if (lastPositionMs == Long.MIN_VALUE) {
            lastPositionMs = positionMs
            frozenSinceMs = nowElapsedMs
            return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
        }
        val delta = positionMs - lastPositionMs
        if (delta > 0L) {
            lastPositionMs = positionMs
            frozenSinceMs = nowElapsedMs
            if (delta <= MAX_NATURAL_TICK_ADVANCE_MS) {
                cumulativeHealthyMs += delta
            }
            if (cumulativeHealthyMs >= healthyResetThresholdMs) {
                cumulativeHealthyMs = 0L
                return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = true)
            }
            return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
        }
        if (delta < 0L) {
            lastPositionMs = positionMs
            frozenSinceMs = nowElapsedMs
            return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
        }
        if (frozenSinceMs == Long.MIN_VALUE) {
            frozenSinceMs = nowElapsedMs
            return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
        }
        val threshold = if (isLive) liveFrozenTimeoutMs else vodFrozenTimeoutMs
        if (nowElapsedMs - frozenSinceMs >= threshold) {
            frozenSinceMs = nowElapsedMs
            return PlaybackProgressSample(frozen = true, reachedHealthyThreshold = false)
        }
        return PlaybackProgressSample(frozen = false, reachedHealthyThreshold = false)
    }

    fun onSeek() {
        lastPositionMs = Long.MIN_VALUE
        frozenSinceMs = Long.MIN_VALUE
    }

    fun resetAll() {
        lastPositionMs = Long.MIN_VALUE
        frozenSinceMs = Long.MIN_VALUE
        cumulativeHealthyMs = 0L
    }

    companion object {
        const val LIVE_FROZEN_TIMEOUT_MS = 10_000L
        const val VOD_FROZEN_TIMEOUT_MS = 15_000L
        const val HEALTHY_RESET_THRESHOLD_MS = 30_000L
        private const val MAX_NATURAL_TICK_ADVANCE_MS = 5_000L
    }
}

/**
 * Bounded thread-safe LRU cache remembering the last working live stream format URL
 * (for example `.m3u8` vs `.ts`) per canonical channel URL.
 */
internal class LiveFormatMemory(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val ttlMs: Long = DEFAULT_TTL_MS,
) {
    private data class Entry(val workingUrl: String, val recordedAtMs: Long)

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>(16, 0.75f, true)

    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
        require(ttlMs > 0L) { "ttlMs must be positive" }
    }

    fun get(url: String, nowMs: Long = defaultClockMs()): String? = synchronized(lock) {
        val key = url.trim()
        if (key.isEmpty()) return null
        val entry = entries[key] ?: return null
        val ageMs = nowMs - entry.recordedAtMs
        if (ageMs < 0L || ageMs >= ttlMs) {
            entries.remove(key)
            return null
        }
        entry.workingUrl
    }

    fun remember(canonicalUrl: String, workingUrl: String, nowMs: Long = defaultClockMs()) {
        synchronized(lock) {
            val key = canonicalUrl.trim()
            val value = workingUrl.trim()
            if (key.isEmpty() || value.isEmpty()) return
            entries[key] = Entry(workingUrl = value, recordedAtMs = nowMs)
            while (entries.size > maxEntries) {
                val eldestKey = entries.entries.iterator().next().key
                entries.remove(eldestKey)
            }
        }
    }

    fun remove(canonicalUrl: String) {
        synchronized(lock) {
            val key = canonicalUrl.trim()
            if (key.isNotEmpty()) entries.remove(key)
        }
    }

    fun clear() {
        synchronized(lock) {
            entries.clear()
        }
    }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 128
        const val DEFAULT_TTL_MS = 3_600_000L
        private fun defaultClockMs(): Long = System.nanoTime() / 1_000_000L
    }
}

internal object LiveFormatCache {
    val shared = LiveFormatMemory()
}
