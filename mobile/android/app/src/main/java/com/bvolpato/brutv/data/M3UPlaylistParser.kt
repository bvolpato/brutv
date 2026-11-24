package com.bvolpato.brutv.data

import com.google.gson.JsonParser
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okio.Buffer
import okio.BufferedSource
import java.io.IOException
import java.util.Locale

/** A single playable EXTINF item and the HTTP headers declared for its URL. */
data class PlaylistItem(
    val id: String,
    val name: String,
    val url: String,
    val logo: String = "",
    val group: String = M3UPlaylistParser.ungroupedTitle,
    val tvgId: String = "",
    val kind: MediaKind = MediaKind.LIVE,
    val headers: Map<String, String> = emptyMap(),
) {
    override fun toString(): String = "PlaylistItem(id=$id, name=$name, url=<redacted>, headers=<redacted>)"
}

/** Parsed playlist items alongside optional header metadata such as `url-tvg`. */
data class ParsedPlaylist(
    val items: List<PlaylistItem>,
    val epgUrl: String? = null,
)

/**
 * Bounded parser for provider M3U files. Parsing is incremental from an Okio source, so
 * callers do not have to buffer a large playlist in memory before the first entry is built.
 */
object M3UPlaylistParser {
    const val ungroupedTitle = "Uncategorized"
    const val maxPlaylistBytes: Long = 64L * 1024 * 1024
    const val maxEntries: Int = 250_000
    private const val maxLineBytes = 128L * 1024

    private val ATTR_REGEX = Regex("([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s,]+))")
    private val HEADER_NAME_REGEX = Regex("[!#\$%&'*+.^_`|~0-9A-Za-z-]{1,64}")
    private val VOD_EXTENSIONS = setOf("mp4", "mkv", "avi", "mov", "webm", "m4v")

    fun parse(text: String): List<PlaylistItem> = parseWithMetadata(Buffer().writeUtf8(text)).items

    @Throws(IOException::class)
    fun parse(source: BufferedSource, checkCancellation: () -> Unit = {}): List<PlaylistItem> =
        parseWithMetadata(source, checkCancellation).items

    fun parseWithMetadata(text: String): ParsedPlaylist = parseWithMetadata(Buffer().writeUtf8(text))

    @Throws(IOException::class)
    fun parseWithMetadata(source: BufferedSource, checkCancellation: () -> Unit = {}): ParsedPlaylist {
        val entries = ArrayList<PlaylistItem>()
        val seen = HashSet<String>()
        var consumed = 0L
        var pendingInfo: String? = null
        var fallbackGroup: String? = null
        var headers = linkedMapOf<String, String>()
        var isHlsPlaylist = false
        var epgUrl: String? = null

        while (true) {
            checkCancellation()
            val lineEnd = source.indexOf('\n'.code.toByte(), 0, maxLineBytes + 1)
            val line: String
            val lineByteCount: Long
            if (lineEnd >= 0) {
                if (lineEnd > maxLineBytes) throw IOException("Playlist contains an overlong line.")
                line = source.readUtf8(lineEnd)
                source.skip(1)
                lineByteCount = lineEnd + 1L
            } else {
                // indexOf can stop at its search limit while the upstream still has more bytes.
                // Requesting the bound plus one distinguishes a final short line from a long one.
                if (source.request(maxLineBytes + 1) || source.buffer.size > maxLineBytes) {
                    throw IOException("Playlist contains an overlong line.")
                }
                val remaining = source.buffer.size
                if (remaining == 0L) break
                line = source.readUtf8()
                lineByteCount = remaining
            }
            consumed += lineByteCount
            if (consumed > maxPlaylistBytes) throw IOException("Playlist exceeds the size limit.")
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (trimmed.startsWith("#EXT-X-", ignoreCase = true)) isHlsPlaylist = true

            when {
                trimmed.startsWith("#EXTM3U", ignoreCase = true) -> {
                    if (epgUrl == null && trimmed.length > 7) {
                        epgUrl = extractHeaderEpgUrl(trimmed.substring(7))
                    }
                }
                trimmed.startsWith("#EXTINF", ignoreCase = true) -> {
                    pendingInfo = trimmed
                    fallbackGroup = null
                    if (headers.isNotEmpty()) headers = linkedMapOf()
                }
                trimmed.startsWith("#EXTGRP:", ignoreCase = true) -> {
                    fallbackGroup = trimmed.substringAfter(':').trim().takeIf(String::isNotEmpty)
                }
                trimmed.startsWith("#EXTVLCOPT:", ignoreCase = true) -> {
                    parseVlcOption(trimmed.substringAfter(':'))?.let { (name, value) -> headers[name] = value }
                }
                trimmed.startsWith("#EXTHTTP:", ignoreCase = true) -> {
                    headers.putAll(parseJsonHeaders(trimmed.substringAfter(':')))
                }
                trimmed.startsWith('#') -> Unit
                else -> {
                    val kind = validateAndClassifyHttpUrl(trimmed)
                    if (kind == null) {
                        pendingInfo = null
                        fallbackGroup = null
                        if (headers.isNotEmpty()) headers = linkedMapOf()
                        continue
                    }
                    val info = parseInfo(pendingInfo.orEmpty())
                    val url = trimmed
                    val group = primaryGroup(info.group) ?: primaryGroup(fallbackGroup) ?: ungroupedTitle
                    val title = info.title?.takeIf(String::isNotBlank)
                        ?: info.tvgName?.takeIf(String::isNotBlank)
                        ?: url.substringAfterLast('/').substringBefore('?').ifBlank { url }
                    val id = stableId(url)
                    if (seen.add(id)) {
                        if (entries.size >= maxEntries) throw IOException("Playlist has too many entries.")
                        entries += PlaylistItem(
                            id = id,
                            name = title,
                            url = url,
                            logo = info.logo.orEmpty(),
                            group = group,
                            tvgId = info.tvgId.orEmpty(),
                            kind = kind,
                            headers = if (headers.isEmpty()) emptyMap() else headers.toMap(),
                        )
                    }
                    pendingInfo = null
                    fallbackGroup = null
                    if (headers.isNotEmpty()) headers = linkedMapOf()
                }
            }
        }
        if (isHlsPlaylist) throw IOException("Playlist is an HLS stream playlist, not an IPTV channel list.")
        return ParsedPlaylist(items = entries, epgUrl = epgUrl)
    }

    /** FNV-1a 64-bit ID, stable across application launches and JVM processes. */
    fun stableId(value: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        var isAscii = true
        for (i in 0 until value.length) {
            val code = value[i].code
            if (code >= 0x80) {
                isAscii = false
                break
            }
            hash = (hash xor code.toLong()) * 0x100000001b3L
        }
        if (!isAscii) {
            hash = -0x340d631b7bdddcdbL
            val bytes = value.toByteArray(Charsets.UTF_8)
            for (byte in bytes) {
                hash = (hash xor (byte.toLong() and 0xff)) * 0x100000001b3L
            }
        }
        return "m3u:${java.lang.Long.toUnsignedString(hash, 16)}"
    }

    private fun extractHeaderEpgUrl(attributesText: String): String? {
        val attrs = parseAttributes(attributesText)
        val raw = attrs["url-tvg"] ?: attrs["x-tvg-url"] ?: return null
        return raw.split(',')
            .asSequence()
            .map(String::trim)
            .firstOrNull { candidate -> candidate.isNotEmpty() && validateAndClassifyHttpUrl(candidate) != null }
    }

    private data class Info(
        val title: String? = null,
        val tvgName: String? = null,
        val tvgId: String? = null,
        val logo: String? = null,
        val group: String? = null,
    )

    private fun parseInfo(line: String): Info {
        val comma = findUnquotedComma(line)
        if (comma < 0) return Info()
        val prefixLength = "#EXTINF".length
        val attributes = line.substring(prefixLength, comma)
        val values = parseAttributes(attributes)
        val title = line.substring(comma + 1).trim().takeIf(String::isNotEmpty)
        return Info(
            title = title,
            tvgName = values["tvg-name"],
            tvgId = values["tvg-id"],
            logo = values["tvg-logo"],
            group = values["group-title"],
        )
    }

    private fun findUnquotedComma(line: String): Int {
        var quoted = false
        var escaped = false
        for (index in 0 until line.length) {
            val char = line[index]
            if (char == '"' && !escaped) quoted = !quoted
            if (char == ',' && !quoted) return index
            escaped = char == '\\' && !escaped
        }
        return -1
    }

    private fun parseAttributes(input: String): Map<String, String> {
        val map = HashMap<String, String>(8)
        for (match in ATTR_REGEX.findAll(input)) {
            val value = match.groups[2]?.value ?: match.groups[3]?.value ?: match.groups[4]?.value.orEmpty()
            map[match.groupValues[1].lowercase(Locale.ROOT)] = value
        }
        return map
    }

    private fun parseVlcOption(option: String): Pair<String, String>? {
        val equals = option.indexOf('=')
        if (equals <= 0) return null
        val key = option.substring(0, equals).trim().lowercase(Locale.ROOT)
        val value = option.substring(equals + 1).trim().trim('"', '\'')
        val header = when (key) {
            "http-user-agent" -> "User-Agent"
            "http-referrer", "http-referer" -> "Referer"
            "http-cookie" -> "Cookie"
            else -> key.removePrefix("http-header-").takeIf { key.startsWith("http-header-") }
                ?.toHeaderName()
        } ?: return null
        return safeHeader(header, value)
    }

    private fun parseJsonHeaders(json: String): Map<String, String> = runCatching {
        val element = JsonParser.parseString(json)
        if (!element.isJsonObject) return@runCatching emptyMap()
        buildMap {
            element.asJsonObject.entrySet().forEach { (name, value) ->
                if (value.isJsonPrimitive && value.asJsonPrimitive.isString) {
                    safeHeader(name, value.asString)?.let { (header, headerValue) -> put(header, headerValue) }
                }
            }
        }
    }.getOrDefault(emptyMap())

    private fun safeHeader(name: String, value: String): Pair<String, String>? {
        val trimmedName = name.trim()
        val trimmedValue = value.trim()
        if (!HEADER_NAME_REGEX.matches(trimmedName) || trimmedValue.isEmpty()) return null
        if (trimmedName.equals("host", true) || trimmedName.equals("content-length", true) ||
            trimmedName.equals("connection", true) || trimmedValue.any { it == '\r' || it == '\n' }) return null
        return trimmedName.toHeaderName() to trimmedValue
    }

    private fun String.toHeaderName(): String = split('-').joinToString("-") { part ->
        part.lowercase(Locale.ROOT).replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
    }

    private fun primaryGroup(value: String?): String? {
        if (value.isNullOrEmpty()) return null
        val semi = value.indexOf(';')
        if (semi < 0) return value.trim().takeIf(String::isNotEmpty)
        var start = 0
        while (start <= value.length) {
            val end = value.indexOf(';', start).let { if (it < 0) value.length else it }
            val part = value.substring(start, end).trim()
            if (part.isNotEmpty()) return part
            start = end + 1
        }
        return null
    }

    /**
     * Single-pass HTTP/HTTPS URL validation and live/VOD classification.
     * Avoids allocating both an OkHttp HttpUrl and a java.net.URI for every line in a 100k playlist.
     */
    internal fun validateAndClassifyHttpUrl(url: String): MediaKind? {
        val authorityStart = when {
            url.startsWith("https://", ignoreCase = true) -> 8
            url.startsWith("http://", ignoreCase = true) -> 7
            else -> return null
        }
        val length = url.length
        if (authorityStart >= length) return null

        var pathStart = length
        var needsFallbackValidation = false
        for (i in authorityStart until length) {
            val c = url[i]
            if (c <= ' ' || c == '\u007f') return null
            if (c == '/' || c == '?' || c == '#') {
                pathStart = i
                break
            }
            if (c == '@' || c == '[' || c == ']' || c.code >= 0x80) {
                needsFallbackValidation = true
            }
        }
        if (pathStart == authorityStart) return null

        if (needsFallbackValidation) {
            if (runCatching { url.toHttpUrlOrNull() }.getOrNull() == null) return null
        } else {
            // Validate host[:port] in-place without substring allocations.
            val colon = url.indexOf(':', authorityStart).takeIf { it in authorityStart until pathStart }
            val hostEnd = colon ?: pathStart
            if (hostEnd <= authorityStart) return null
            for (i in authorityStart until hostEnd) {
                val c = url[i]
                val ok = (c in 'a'..'z') || (c in 'A'..'Z') || (c in '0'..'9') || c == '.' || c == '-' || c == '_'
                if (!ok) {
                    if (runCatching { url.toHttpUrlOrNull() }.getOrNull() == null) return null
                    break
                }
            }
            if (colon != null) {
                val portStart = colon + 1
                if (portStart >= pathStart || pathStart - portStart > 5) return null
                var port = 0
                for (i in portStart until pathStart) {
                    val d = url[i] - '0'
                    if (d !in 0..9) return null
                    port = port * 10 + d
                }
                if (port !in 1..65535) return null
            }
        }

        if (pathStart >= length || url[pathStart] != '/') {
            for (i in pathStart until length) {
                val c = url[i]
                if (c <= ' ' || c == '\u007f') return null
            }
            return MediaKind.LIVE
        }

        var pathEnd = length
        for (i in pathStart until length) {
            val c = url[i]
            if (c <= ' ' || c == '\u007f') return null
            if (pathEnd == length && (c == '?' || c == '#')) {
                pathEnd = i
            }
        }
        return classifyPathSlice(url, pathStart, pathEnd)
    }

    private fun classifyPathSlice(url: String, start: Int, end: Int): MediaKind {
        // An M3U entry has no reliable series/season metadata. Keep provider series URLs
        // visible as flat VOD items instead of dropping them from the catalog.
        if (containsSegmentIgnoreCase(url, start, end, "/movie/") ||
            containsSegmentIgnoreCase(url, start, end, "/series/")
        ) {
            return MediaKind.MOVIE
        }
        var lastDot = -1
        for (i in end - 1 downTo start) {
            val c = url[i]
            if (c == '.') {
                lastDot = i
                break
            }
            if (c == '/') break
        }
        if (lastDot in start until (end - 1)) {
            val extLen = end - (lastDot + 1)
            if (extLen in 3..4) {
                val ext = url.substring(lastDot + 1, end).lowercase(Locale.ROOT)
                if (ext in VOD_EXTENSIONS) return MediaKind.MOVIE
            }
        }
        return MediaKind.LIVE
    }

    private fun containsSegmentIgnoreCase(source: String, start: Int, end: Int, needle: String): Boolean {
        val needleLen = needle.length
        if (end - start < needleLen) return false
        val limit = end - needleLen
        for (i in start..limit) {
            if (source.regionMatches(i, needle, 0, needleLen, ignoreCase = true)) {
                return true
            }
        }
        return false
    }
}
