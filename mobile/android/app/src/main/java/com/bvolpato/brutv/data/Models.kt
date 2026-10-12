package com.bvolpato.brutv.data

import java.net.URI
import java.util.UUID

/** A provider connection. IDs remain stable when the profile is edited. */
data class SourceConfig(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val type: SourceType = SourceType.XTREAM,
    val server: String = "",
    val username: String = "",
    val password: String = "",
    val playlistUrl: String = "",
) {
    /** Returns a trimmed, validated copy without ever including credentials in errors. */
    fun normalized(): SourceConfig {
        val normalizedName = name.trim().ifEmpty { "My IPTV" }
        return when (type) {
            SourceType.XTREAM -> {
                val cleanServer = server.trim().let { input ->
                    if (Regex("^[A-Za-z][A-Za-z0-9+.-]*://").containsMatchIn(input) &&
                        !input.startsWith("http://", true) && !input.startsWith("https://", true)) {
                        throw IllegalArgumentException("Enter a valid HTTP or HTTPS server address.")
                    }
                    val withScheme = if (input.startsWith("http://", true) || input.startsWith("https://", true)) {
                        input
                    } else {
                        "http://$input"
                    }
                    val uri = runCatching { URI(withScheme) }.getOrNull()
                        ?: throw IllegalArgumentException("Enter a valid HTTP or HTTPS server address.")
                    val scheme = uri.scheme?.lowercase()
                    if ((scheme != "http" && scheme != "https") || uri.host.isNullOrBlank() ||
                        uri.port !in -1..65535 || uri.rawUserInfo != null || uri.rawFragment != null) {
                        throw IllegalArgumentException("Enter a valid HTTP or HTTPS server address.")
                    }
                    val path = uri.path.orEmpty().trimEnd('/')
                    URI(scheme, null, uri.host, uri.port, path.ifEmpty { null }, null, null).toASCIIString().trimEnd('/')
                }
                val user = username.trim()
                val pass = password.trim()
                if (user.isEmpty() || pass.isEmpty()) {
                    throw IllegalArgumentException("Enter the provider username and password.")
                }
                copy(name = normalizedName, server = cleanServer, username = user, password = pass, playlistUrl = "")
            }
            SourceType.M3U -> {
                val cleanUrl = playlistUrl.trim()
                val uri = runCatching { URI(cleanUrl) }.getOrNull()
                val scheme = uri?.scheme?.lowercase()
                val remote = uri != null && (scheme == "http" || scheme == "https") &&
                    !uri.host.isNullOrBlank() && uri.port in -1..65535
                val local = uri != null && scheme == "file" && uri.host == null &&
                    uri.rawQuery == null && uri.rawFragment == null && isAppPlaylistPath(uri.path.orEmpty())
                if (uri == null || (!remote && !local)) {
                    throw IllegalArgumentException("Enter a valid HTTP or HTTPS playlist URL.")
                }
                copy(name = normalizedName, playlistUrl = cleanUrl, server = "", username = "", password = "")
            }
        }
    }

    override fun toString(): String =
        "SourceConfig(id=$id, name=<redacted>, type=$type, server=<redacted>, username=<redacted>, password=<redacted>, playlistUrl=<redacted>)"

    private fun isAppPlaylistPath(path: String): Boolean {
        val parts = path.split('/').filter(String::isNotEmpty)
        return parts.size >= 3 && parts[parts.size - 3] == "no_backup" && parts[parts.size - 2] == "playlists" &&
            parts.last().matches(Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\.m3u")) &&
            parts.none { it == "." || it == ".." }
    }
}

enum class SourceType { XTREAM, M3U }

enum class MediaKind { LIVE, MOVIE, SERIES, EPISODE }

data class Category(val id: String, val name: String)

data class MediaEntry(
    val id: String,
    val providerId: String = id,
    val name: String,
    val kind: MediaKind,
    val categoryId: String = "",
    val artwork: String = "",
    val rating: String = "",
    val plot: String = "",
    val streamUrl: String = "",
    val containerExtension: String = "mp4",
    val epgId: String = "",
    val requestHeaders: Map<String, String> = emptyMap(),
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
) {
    val quality: String
        get() = when {
            "4K" in name.uppercase() || "UHD" in name.uppercase() -> "4K"
            "FHD" in name.uppercase() || "1080P" in name.uppercase() -> "FHD"
            "HD" in name.uppercase() || "720P" in name.uppercase() -> "HD"
            else -> "SD"
        }

    val searchableName: String get() = name.trim().lowercase()

    override fun toString(): String =
        "MediaEntry(id=$id, providerId=$providerId, name=$name, kind=$kind, categoryId=$categoryId, streamUrl=<redacted>, requestHeaders=<redacted>)"
}

data class CatalogSection(
    val categories: List<Category> = emptyList(),
    val entries: List<MediaEntry> = emptyList(),
)

data class Programme(
    val title: String,
    val description: String = "",
    val startEpochSeconds: Long = 0,
    val endEpochSeconds: Long = 0,
)

data class LibraryState(
    val favoriteIds: Set<String> = emptySet(),
    val recentIds: List<String> = emptyList(),
    val resumePositions: Map<String, Long> = emptyMap(),
)

data class SavedState(
    val profiles: List<SourceConfig> = emptyList(),
    val activeSourceId: String? = null,
    val libraries: Map<String, LibraryState> = emptyMap(),
    val bufferProfile: String = "balanced",
    val showStats: Boolean = false,
)
