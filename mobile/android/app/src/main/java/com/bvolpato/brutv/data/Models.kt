package com.bvolpato.brutv.data

import androidx.compose.runtime.Immutable
import java.net.URI
import java.util.Locale
import java.util.UUID

private val SCHEME_PREFIX_REGEX = Regex("^[A-Za-z][A-Za-z0-9+.-]*://")
private val APP_PLAYLIST_FILE_REGEX = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\.m3u")

/** A provider connection. IDs remain stable when the profile is edited. */
@Immutable
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
                    if (SCHEME_PREFIX_REGEX.containsMatchIn(input) &&
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
            APP_PLAYLIST_FILE_REGEX.matches(parts.last()) &&
            parts.none { it == "." || it == ".." }
    }
}

enum class SourceType { XTREAM, M3U }

enum class MediaKind { LIVE, MOVIE, SERIES, EPISODE }

@Immutable
data class Category(val id: String, val name: String)

@Immutable
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
    val quality: String = computeQuality(name)

    val searchableName: String = name.trim().lowercase(Locale.ROOT)

    override fun toString(): String =
        "MediaEntry(id=$id, providerId=$providerId, name=$name, kind=$kind, categoryId=$categoryId, streamUrl=<redacted>, requestHeaders=<redacted>)"
}

private fun computeQuality(name: String): String {
    val upper = name.uppercase(Locale.ROOT)
    return when {
        "4K" in upper || "UHD" in upper -> "4K"
        "FHD" in upper || "1080P" in upper -> "FHD"
        "HD" in upper || "720P" in upper -> "HD"
        else -> "SD"
    }
}

@Immutable
data class MovieDetails(
    val plot: String = "",
    val cast: String = "",
    val director: String = "",
    val duration: String = "",
    val genre: String = "",
    val releaseDate: String = "",
    val rating: String = "",
    val artwork: String = "",
)

@Immutable
data class CatalogSection(
    val categories: List<Category> = emptyList(),
    val entries: List<MediaEntry> = emptyList(),
    val categoryCounts: Map<String, Int> = emptyMap(),
    val categoryIcons: Map<String, String> = emptyMap(),
    val firstArtworkUrl: String? = null,
    val entriesByCategory: Map<String, List<MediaEntry>> = emptyMap(),
    val entriesById: Map<String, MediaEntry> = emptyMap(),
) {
    companion object {
        fun build(categories: List<Category>, entries: List<MediaEntry>): CatalogSection {
            val categoryCap = categories.size.coerceAtLeast(16)
            val counts = HashMap<String, Int>(categoryCap)
            val icons = HashMap<String, String>(categoryCap)
            val byCategory = HashMap<String, ArrayList<MediaEntry>>(categoryCap)
            val byId = HashMap<String, MediaEntry>((entries.size * 4 / 3) + 16)
            var firstArtwork: String? = null
            for (entry in entries) {
                byId[entry.id] = entry
                if (firstArtwork == null && entry.artwork.isNotBlank()) {
                    firstArtwork = entry.artwork
                }
                val catId = entry.categoryId
                if (catId.isNotBlank()) {
                    counts[catId] = (counts[catId] ?: 0) + 1
                    val bucket = byCategory[catId] ?: ArrayList<MediaEntry>().also { byCategory[catId] = it }
                    bucket.add(entry)
                    if (!icons.containsKey(catId) && entry.artwork.isNotBlank()) {
                        icons[catId] = entry.artwork
                    }
                }
            }
            return CatalogSection(
                categories = categories,
                entries = entries,
                categoryCounts = counts,
                categoryIcons = icons,
                firstArtworkUrl = firstArtwork,
                entriesByCategory = byCategory,
                entriesById = byId,
            )
        }
    }
}

@Immutable
data class Programme(
    val title: String,
    val description: String = "",
    val startEpochSeconds: Long = 0,
    val endEpochSeconds: Long = 0,
) {
    fun isLiveAt(nowEpochSeconds: Long): Boolean =
        startEpochSeconds > 0 && endEpochSeconds > startEpochSeconds &&
            nowEpochSeconds in startEpochSeconds until endEpochSeconds
}

@Immutable
data class LibraryState(
    val favoriteIds: Set<String> = emptySet(),
    val recentIds: List<String> = emptyList(),
    val resumePositions: Map<String, Long> = emptyMap(),
)

@Immutable
data class SavedState(
    val profiles: List<SourceConfig> = emptyList(),
    val activeSourceId: String? = null,
    val libraries: Map<String, LibraryState> = emptyMap(),
    val bufferProfile: String = "balanced",
    val showStats: Boolean = false,
    val language: String = "system",
    val liveRewind: Boolean = false,
    val preferredAudioLanguage: String? = null,
    val preferredSubtitleLanguage: String? = null,
    val subtitlesEnabled: Boolean = false,
    val defaultAspectMode: String = "fit",
    val autoFrameRate: Boolean = false,
)

internal const val MAX_RESUME_POSITIONS = 500
internal const val RESUME_COMPLETION_PERCENT = 95L

/**
 * Updates the bounded LRU resume map for VOD items.
 * Clears the entry once playback completes or passes 95% of duration, and caps total entries at [maxEntries].
 */
internal fun updateResumePositions(
    existing: Map<String, Long>,
    entryId: String,
    positionMs: Long,
    durationMs: Long = 0L,
    completed: Boolean = false,
    maxEntries: Int = MAX_RESUME_POSITIONS,
): Map<String, Long> {
    val clamped = positionMs.coerceAtLeast(0L)
    val reachedEnd = completed || (durationMs > 0L && clamped * 100L >= durationMs * RESUME_COMPLETION_PERCENT)
    if (reachedEnd) {
        if (entryId !in existing) return existing
        val next = LinkedHashMap<String, Long>(existing.size)
        for ((key, value) in existing) {
            if (key != entryId) next[key] = value
        }
        return next
    }
    val next = LinkedHashMap<String, Long>(minOf(existing.size + 1, maxEntries + 1))
    for ((key, value) in existing) {
        if (key != entryId) next[key] = value
    }
    next[entryId] = clamped
    while (next.size > maxEntries) {
        val eldest = next.entries.iterator().next().key
        next.remove(eldest)
    }
    return next
}
