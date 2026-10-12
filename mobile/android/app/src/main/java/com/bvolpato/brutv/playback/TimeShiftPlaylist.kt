package com.bvolpato.brutv.playback

import java.net.URI

internal data class TimeShiftLimits(
    val durationMs: Long = 600_000,
    val bytes: Long = 256L * 1024 * 1024,
    val manifestBytes: Long = 1024 * 1024,
    val segmentBytes: Long = 32L * 1024 * 1024,
    val segments: Int = 2_000,
)

internal class UnsupportedTimeShift(message: String) : Exception(message)

internal data class RecordedSegmentSpec(
    val sequence: Long,
    val url: String,
    val durationMs: Long,
    val discontinuitySequence: Long,
    val initializationUrl: String?,
    val gap: Boolean,
    val programDateTime: String?,
)

internal data class TimeShiftPlaylist(
    val targetDuration: Int,
    val segments: List<RecordedSegmentSpec>,
    val ended: Boolean,
    val version: Int,
    val independentSegments: Boolean,
)

internal object TimeShiftPlaylistParser {
    fun variant(text: String, baseUrl: String): String? {
        val lines = lines(text)
        if (lines.any { it.startsWith("#EXTINF:") }) return null
        if (lines.any { it.startsWith("#EXT-X-MEDIA:") || it.startsWith("#EXT-X-SESSION-KEY:") }) {
            throw UnsupportedTimeShift("This HLS master uses separate renditions or encryption. Live recording is unavailable.")
        }
        val variants = lines.mapIndexedNotNull { index, line ->
            if (!line.startsWith("#EXT-X-STREAM-INF:")) return@mapIndexedNotNull null
            val attributes = attributes(line.substringAfter(':'))
            if (attributes.containsKey("AUDIO") || attributes.containsKey("SUBTITLES")) {
                throw UnsupportedTimeShift("This HLS master uses separate audio or subtitles. Live recording is unavailable.")
            }
            val uri = lines.getOrNull(index + 1)?.takeUnless { it.startsWith('#') }
                ?: throw UnsupportedTimeShift("The HLS variant playlist is incomplete.")
            val bandwidth = attributes["AVERAGE-BANDWIDTH"]?.toLongOrNull()
                ?: attributes["BANDWIDTH"]?.toLongOrNull() ?: Long.MAX_VALUE
            val height = attributes["RESOLUTION"]?.substringAfter('x')?.toIntOrNull() ?: 0
            Triple(resolve(baseUrl, uri), bandwidth, height)
        }
        if (variants.isEmpty()) throw UnsupportedTimeShift("This live source does not provide a supported HLS playlist.")
        // One muxed rendition keeps the entire recorded history playable at the same quality.
        return (variants.filter { it.third <= 1080 && it.second <= 8_000_000 }
            .maxByOrNull { it.second } ?: variants.minBy { it.second }).first
    }

    fun parse(text: String, baseUrl: String): TimeShiftPlaylist {
        val lines = lines(text)
        var sequence = 0L
        var discontinuity = 0L
        var target = 0
        var version = 3
        var duration: Long? = null
        var map: String? = null
        var gap = false
        var date: String? = null
        var ended = false
        val segments = mutableListOf<RecordedSegmentSpec>()
        for (line in lines) {
            when {
                line.startsWith("#EXT-X-KEY:") && attributes(line.substringAfter(':'))["METHOD"] != "NONE" ->
                    throw UnsupportedTimeShift("Encrypted live streams cannot be recorded locally.")
                line.startsWith("#EXT-X-BYTERANGE:") -> throw UnsupportedTimeShift("Byte-range HLS recording is unavailable.")
                line.startsWith("#EXT-X-SKIP:") || line.startsWith("#EXT-X-DEFINE:") ->
                    throw UnsupportedTimeShift("This HLS playlist uses unsupported delta updates or variables.")
                line.startsWith("#EXT-X-I-FRAMES-ONLY") || line.startsWith("#EXT-X-STREAM-INF:") ->
                    throw UnsupportedTimeShift("This is not a complete HLS media playlist.")
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> sequence = positiveLong(line)
                line.startsWith("#EXT-X-DISCONTINUITY-SEQUENCE:") -> discontinuity = positiveLong(line)
                line == "#EXT-X-DISCONTINUITY" -> discontinuity++
                line.startsWith("#EXT-X-TARGETDURATION:") -> target = line.substringAfter(':').toIntOrNull() ?: 0
                line.startsWith("#EXT-X-VERSION:") -> version = line.substringAfter(':').toIntOrNull() ?: 3
                line.startsWith("#EXTINF:") -> {
                    val seconds = line.substringAfter(':').substringBefore(',').toDoubleOrNull()
                    if (seconds == null || !seconds.isFinite() || seconds <= 0 || seconds > 120) {
                        throw UnsupportedTimeShift("The HLS segment duration is invalid.")
                    }
                    duration = (seconds * 1000).toLong().coerceAtLeast(1)
                }
                line.startsWith("#EXT-X-MAP:") -> {
                    val attrs = attributes(line.substringAfter(':'))
                    if ("BYTERANGE" in attrs) throw UnsupportedTimeShift("Byte-range HLS initialization is unavailable.")
                    map = resolve(baseUrl, attrs["URI"] ?: throw UnsupportedTimeShift("The HLS initialization URI is missing."))
                    version = maxOf(version, 6)
                }
                line.startsWith("#EXT-X-PROGRAM-DATE-TIME:") -> {
                    date = line.substringAfter(':')
                    if (date.length > 80) throw UnsupportedTimeShift("The HLS program timestamp is invalid.")
                }
                line == "#EXT-X-GAP" -> gap = true
                line == "#EXT-X-ENDLIST" -> ended = true
                !line.startsWith('#') -> {
                    val millis = duration ?: throw UnsupportedTimeShift("The HLS playlist contains an incomplete segment.")
                    segments += RecordedSegmentSpec(sequence++, resolve(baseUrl, line), millis, discontinuity, map, gap, date)
                    duration = null
                    date = null
                    gap = false
                }
            }
        }
        if (target !in 1..120 || segments.isEmpty()) {
            throw UnsupportedTimeShift("This live source does not provide complete HLS segments for recording.")
        }
        if (duration != null) throw UnsupportedTimeShift("The HLS playlist contains an incomplete segment.")
        if (segments.zipWithNext().any { (first, next) -> next.discontinuitySequence - first.discontinuitySequence !in 0..4 }) {
            throw UnsupportedTimeShift("The HLS discontinuity sequence is unsupported.")
        }
        return TimeShiftPlaylist(target, segments, ended, version.coerceIn(3, 10), "#EXT-X-INDEPENDENT-SEGMENTS" in lines)
    }

    private fun lines(text: String): List<String> {
        val lines = text.removePrefix("\uFEFF").lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        if (lines.firstOrNull() != "#EXTM3U") throw UnsupportedTimeShift("This live source is not HLS. Live recording is unavailable.")
        return lines
    }

    private fun positiveLong(line: String): Long = line.substringAfter(':').toLongOrNull()
        ?.takeIf { it >= 0 && it < Long.MAX_VALUE / 2 }
        ?: throw UnsupportedTimeShift("The HLS sequence number is invalid.")

    private fun resolve(base: String, path: String): String {
        val uri = runCatching { URI(base).resolve(path) }.getOrNull()
            ?: throw UnsupportedTimeShift("The HLS resource URI is invalid.")
        if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
            throw UnsupportedTimeShift("The HLS resource URI is unsupported.")
        }
        return uri.toString()
    }

    private fun attributes(value: String): Map<String, String> =
        Regex("(?:^|,)([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)").findAll(value)
            .associate { it.groupValues[1] to it.groupValues[2].removeSurrounding("\"") }
}
