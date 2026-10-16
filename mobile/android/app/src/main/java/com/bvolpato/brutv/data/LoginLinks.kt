package com.bvolpato.brutv.data

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/** Parses and creates the same `brutv://login` links as the iOS app. */
object LoginLinks {
    fun parse(input: String): SourceConfig? {
        val text = input.trim().trim('"', '\'')
        if (text.isEmpty()) return null

        if (text.regionMatches(0, "brutv:", 0, 6, ignoreCase = true)) {
            return parseDeepLink(text)
        }
        if (text.regionMatches(0, "http://", 0, 7, ignoreCase = true) ||
            text.regionMatches(0, "https://", 0, 8, ignoreCase = true)) {
            return parsePlaylistOrXtream(text)
        }
        return null
    }

    fun encode(source: SourceConfig): String {
        val normalized = source.normalized()
        val values = when (normalized.type) {
            SourceType.XTREAM -> listOf(
                "server" to normalized.server,
                "username" to normalized.username,
                "password" to normalized.password,
            )
            SourceType.M3U -> {
                require(normalized.playlistUrl.startsWith("http://", true) || normalized.playlistUrl.startsWith("https://", true)) {
                    "Device-local playlists cannot be shared in a sign-in link."
                }
                listOf("m3u" to normalized.playlistUrl)
            }
        }
        return "brutv://login?" + values.joinToString("&") { (key, value) ->
            "$key=${encodeQueryValue(value)}"
        }
    }

    private fun parseDeepLink(raw: String): SourceConfig? {
        val afterScheme = raw.substring(6).trimStart('/')
        val pathAndHost = afterScheme.substringBefore('?').substringBefore('#').trimEnd('/')
        if (!pathAndHost.equals("login", ignoreCase = true)) return null

        val query = if ('?' in afterScheme) {
            afterScheme.substringAfter('?').substringBefore('#')
        } else ""
        val values = parseQuery(query)
        val playlist = values.firstValue("m3u")
        if (!playlist.isNullOrBlank()) {
            if (!playlist.startsWith("http://", ignoreCase = true) &&
                !playlist.startsWith("https://", ignoreCase = true)) return null
            return m3uSource(playlist)
        }
        val server = values.firstValue("server") ?: return null
        val username = values.firstValue("username") ?: return null
        val password = values.firstValue("password") ?: return null
        return runCatching {
            SourceConfig(name = username, type = SourceType.XTREAM, server = server, username = username, password = password).normalized()
        }.getOrNull()
    }

    private fun parsePlaylistOrXtream(original: String): SourceConfig? {
        val uri = runCatching { URI(original) }.getOrNull()
        if (uri != null && isIosUniversalJoin(uri)) {
            return parseUniversalJoin(uri.rawQuery)
        }

        val isGetPhp = original.contains("get.php", ignoreCase = true)
        if (isGetPhp) {
            val query = original.substringAfter('?', "").substringBefore('#')
            val values = parseQuery(query)
            val username = values.firstValue("username")
            val password = values.firstValue("password")
            if (!username.isNullOrBlank() && !password.isNullOrBlank()) {
                val beforeQuery = original.substringBefore('?')
                val parent = beforeQuery.substringBeforeLast("get.php", beforeQuery).trimEnd('/')
                if (parent.startsWith("http://", ignoreCase = true) || parent.startsWith("https://", ignoreCase = true)) {
                    return runCatching {
                        SourceConfig(name = username, server = parent, username = username, password = password).normalized()
                    }.getOrNull()
                }
            }
        }
        return m3uSource(original)
    }

    private fun isIosUniversalJoin(uri: URI): Boolean =
        uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals("bvolpato.github.io", ignoreCase = true) &&
            uri.port == -1 &&
            uri.rawUserInfo == null &&
            uri.rawFragment == null &&
            uri.rawPath == "/brutv/join.html"

    private fun parseUniversalJoin(query: String?): SourceConfig? {
        val values = parseQuery(query)
        val playlist = values.firstValue("m3u")
        if (playlist != null) {
            if (!playlist.startsWith("http://", ignoreCase = true) &&
                !playlist.startsWith("https://", ignoreCase = true)) return null
            return m3uSource(playlist)
        }
        val server = values.firstValue("server") ?: return null
        val username = values.firstValue("username") ?: return null
        val password = values.firstValue("password") ?: return null
        return runCatching {
            SourceConfig(name = username, type = SourceType.XTREAM, server = server, username = username, password = password).normalized()
        }.getOrNull()
    }

    private fun m3uSource(url: String): SourceConfig? = runCatching {
        val clean = url.trim()
        val uri = runCatching { URI(clean) }.getOrNull()
        val name = uri?.host?.takeIf(String::isNotBlank) ?: "M3U Playlist"
        SourceConfig(name = name, type = SourceType.M3U, playlistUrl = clean).normalized()
    }.getOrNull()

    private fun parseQuery(query: String?): List<Pair<String, String>> = query.orEmpty()
        .split('&')
        .mapNotNull { part ->
            if (part.isEmpty()) return@mapNotNull null
            val separator = part.indexOf('=')
            val rawKey = if (separator < 0) part else part.substring(0, separator)
            val rawValue = if (separator < 0) "" else part.substring(separator + 1)
            val key = runCatching { URLDecoder.decode(rawKey, StandardCharsets.UTF_8.name()) }.getOrNull() ?: return@mapNotNull null
            val value = runCatching { URLDecoder.decode(rawValue, StandardCharsets.UTF_8.name()) }.getOrNull() ?: return@mapNotNull null
            key to value
        }

    private fun List<Pair<String, String>>.firstValue(name: String): String? =
        firstOrNull { it.first.equals(name, ignoreCase = true) }?.second?.trim()?.takeIf(String::isNotEmpty)

    private fun encodeQueryValue(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8.name())
        .replace("+", "%20")
        .replace("%7E", "~")
}
