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

/**
 * Bounded parser for provider M3U files. Parsing is incremental from an Okio source, so
 * callers do not have to buffer a large playlist in memory before the first entry is built.
 */
object M3UPlaylistParser {
    const val ungroupedTitle = "Uncategorized"
    const val maxPlaylistBytes: Long = 64L * 1024 * 1024
    const val maxEntries: Int = 250_000
    private const val maxLineBytes = 128L * 1024

    fun parse(text: String): List<PlaylistItem> = parse(Buffer().writeUtf8(text))

    @Throws(IOException::class)
    fun parse(source: BufferedSource, checkCancellation: () -> Unit = {}): List<PlaylistItem> {
        val entries = ArrayList<PlaylistItem>()
        val seen = HashSet<String>()
        var consumed = 0L
        var pendingInfo: String? = null
        var fallbackGroup: String? = null
        var headers = linkedMapOf<String, String>()
        var isHlsPlaylist = false

        while (true) {
            checkCancellation()
            val lineEnd = source.indexOf('\n'.code.toByte(), 0, maxLineBytes + 1)
            val line: String
            val hasNewline: Boolean
            if (lineEnd >= 0) {
                if (lineEnd > maxLineBytes) throw IOException("Playlist contains an overlong line.")
                line = source.readUtf8(lineEnd)
                source.skip(1)
                hasNewline = true
            } else {
                // indexOf can stop at its search limit while the upstream still has more bytes.
                // Requesting the bound plus one distinguishes a final short line from a long one.
                if (source.request(maxLineBytes + 1) || source.buffer.size > maxLineBytes) {
                    throw IOException("Playlist contains an overlong line.")
                }
                if (source.buffer.size == 0L) break
                line = source.readUtf8()
                hasNewline = false
            }
            consumed += line.toByteArray(Charsets.UTF_8).size + if (hasNewline) 1 else 0
            if (consumed > maxPlaylistBytes) throw IOException("Playlist exceeds the size limit.")
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (trimmed.startsWith("#EXT-X-", ignoreCase = true)) isHlsPlaylist = true

            when {
                trimmed.startsWith("#EXTINF", ignoreCase = true) -> {
                    pendingInfo = trimmed
                    fallbackGroup = null
                    headers = linkedMapOf()
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
                    if (!isHttpUrl(trimmed)) {
                        pendingInfo = null
                        fallbackGroup = null
                        headers = linkedMapOf()
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
                            kind = classify(url),
                            headers = headers.toMap(),
                        )
                    }
                    pendingInfo = null
                    fallbackGroup = null
                    headers = linkedMapOf()
                }
            }
        }
        if (isHlsPlaylist) throw IOException("Playlist is an HLS stream playlist, not an IPTV channel list.")
        return entries
    }

    /** FNV-1a 64-bit ID, stable across application launches and JVM processes. */
    fun stableId(value: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            hash = (hash xor (byte.toLong() and 0xff)) * 0x100000001b3L
        }
        return "m3u:${java.lang.Long.toUnsignedString(hash, 16)}"
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
        line.forEachIndexed { index, char ->
            if (char == '"' && !escaped) quoted = !quoted
            if (char == ',' && !quoted) return index
            escaped = char == '\\' && !escaped
        }
        return -1
    }

    private fun parseAttributes(input: String): Map<String, String> {
        val pattern = Regex("([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s,]+))")
        return pattern.findAll(input).associate { match ->
            val value = match.groups[2]?.value ?: match.groups[3]?.value ?: match.groups[4]?.value.orEmpty()
            match.groupValues[1].lowercase(Locale.ROOT) to value
        }
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
        if (!trimmedName.matches(Regex("[!#\$%&'*+.^_`|~0-9A-Za-z-]{1,64}")) || trimmedValue.isEmpty()) return null
        if (trimmedName.equals("host", true) || trimmedName.equals("content-length", true) ||
            trimmedName.equals("connection", true) || trimmedValue.any { it == '\r' || it == '\n' }) return null
        return trimmedName.toHeaderName() to trimmedValue
    }

    private fun String.toHeaderName(): String = split('-').joinToString("-") { part ->
        part.lowercase(Locale.ROOT).replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
    }

    private fun primaryGroup(value: String?): String? = value?.split(';')
        ?.asSequence()?.map(String::trim)?.firstOrNull(String::isNotEmpty)

    private fun classify(url: String): MediaKind {
        val path = runCatching { java.net.URI(url).path.orEmpty().lowercase(Locale.ROOT) }.getOrDefault(url.lowercase(Locale.ROOT))
        return when {
            // An M3U entry has no reliable series/season metadata. Keep provider series URLs
            // visible as flat VOD items instead of dropping them from the catalog.
            "/movie/" in path || "/series/" in path -> MediaKind.MOVIE
            path.substringAfterLast('.', "") in setOf("mp4", "mkv", "avi", "mov", "webm", "m4v") -> MediaKind.MOVIE
            else -> MediaKind.LIVE
        }
    }

    private fun isHttpUrl(url: String): Boolean = runCatching {
        url.toHttpUrlOrNull() != null
    }.getOrDefault(false)
}
