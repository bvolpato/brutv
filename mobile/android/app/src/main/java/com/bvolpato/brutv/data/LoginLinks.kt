package com.bvolpato.brutv.data

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/** Parses and creates the same `brutv://login` links as the iOS app. */
object LoginLinks {
    fun parse(input: String): SourceConfig? {
        val text = input.trim()
        if (text.isEmpty()) return null
        val uri = runCatching { URI(text) }.getOrNull() ?: return null
        return when (uri.scheme?.lowercase(Locale.ROOT)) {
            "brutv" -> parseDeepLink(uri)
            "http", "https" -> parsePlaylistOrXtream(uri, text)
            else -> null
        }
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

    private fun parseDeepLink(uri: URI): SourceConfig? {
        if (!uri.host.equals("login", ignoreCase = true)) return null
        val values = parseQuery(uri.rawQuery)
        val playlist = values.firstValue("m3u")
        if (!playlist.isNullOrBlank()) {
            val playlistUri = runCatching { URI(playlist) }.getOrNull() ?: return null
            if (!playlistUri.scheme.equals("http", true) && !playlistUri.scheme.equals("https", true)) return null
            return m3uSource(playlist)
        }
        val server = values.firstValue("server") ?: return null
        val username = values.firstValue("username") ?: return null
        val password = values.firstValue("password") ?: return null
        return runCatching {
            SourceConfig(name = username, type = SourceType.XTREAM, server = server, username = username, password = password).normalized()
        }.getOrNull()
    }

    private fun parsePlaylistOrXtream(uri: URI, original: String): SourceConfig? {
        if (uri.host.isNullOrBlank()) return null
        val isGetPhp = uri.path?.endsWith("get.php", ignoreCase = true) == true
        if (isGetPhp) {
            val values = parseQuery(uri.rawQuery)
            val username = values.firstValue("username")
            val password = values.firstValue("password")
            if (!username.isNullOrBlank() && !password.isNullOrBlank()) {
                val parent = uri.path.substringBeforeLast('/').trimEnd('/')
                val server = buildString {
                    append(uri.scheme.lowercase(Locale.ROOT)).append("://").append(uri.rawAuthority)
                    if (parent.isNotEmpty()) append(parent)
                }
                return runCatching {
                    SourceConfig(name = username, server = server, username = username, password = password).normalized()
                }.getOrNull()
            }
        }
        return m3uSource(original)
    }

    private fun m3uSource(url: String): SourceConfig? = runCatching {
        val parsed = URI(url)
        val name = parsed.host?.takeIf(String::isNotBlank) ?: "M3U Playlist"
        SourceConfig(name = name, type = SourceType.M3U, playlistUrl = url).normalized()
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
