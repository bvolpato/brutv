package com.bvolpato.brutv.data

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okio.Buffer
import okio.ByteString.Companion.decodeBase64
import okio.buffer
import okio.source
import java.io.File
import java.io.IOException
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class CatalogDataException(message: String) : IOException(message)

/** Xtream Codes and M3U data adapter. Create one repository per saved source profile. */
class CatalogRepository(
    source: SourceConfig,
    private val client: OkHttpClient = defaultClient,
    private val localPlaylistDirectory: File? = null,
) {
    private val source = source.normalized()
    private val baseUrl: HttpUrl? = if (this.source.type == SourceType.XTREAM) this.source.server.toHttpUrlOrNull() else null
    private val cache = ConcurrentHashMap<MediaKind, CatalogSection>()
    @Volatile private var playlistEntries: List<PlaylistItem>? = null

    suspend fun authenticate() {
        if (source.type == SourceType.M3U) {
            loadPlaylist()
            return
        }
        val response = requestJson(action = null)
        val user = response.objectOrNull("user_info")
            ?: throw CatalogDataException("The provider returned an invalid sign-in response.")
        val auth = user.string("auth").toIntOrNull() ?: if (user.string("auth").equals("true", true)) 1 else 0
        val status = user.string("status").lowercase(Locale.ROOT)
        if (auth == 0 || status == "disabled" || status == "expired") {
            throw CatalogDataException("The provider rejected this sign-in.")
        }
    }

    suspend fun load(kind: MediaKind): CatalogSection {
        cache[kind]?.let { return it }
        val section = if (source.type == SourceType.M3U) {
            loadPlaylistSection(kind)
        } else {
            loadXtreamSection(kind)
        }
        cache.putIfAbsent(kind, section)
        return cache[kind] ?: section
    }

    suspend fun episodes(series: MediaEntry): List<MediaEntry> {
        if (source.type != SourceType.XTREAM || series.kind != MediaKind.SERIES || series.providerId.isBlank()) return emptyList()
        val root = requestJson("get_series_info", "series_id" to series.providerId)
        val seasons = root.objectOrNull("episodes") ?: return emptyList()
        val output = ArrayList<MediaEntry>()
        for ((seasonKey, episodeArray) in seasons.entrySet()) {
            val season = seasonKey.toIntOrNull()
            for (item in episodeArray.arrayOrNull().elements()) {
                val episode = item.objectOrNull() ?: continue
                val providerId = episode.string("id").ifBlank { episode.string("episode_id") }
                if (providerId.isBlank()) continue
                val info = episode.objectOrNull("info")
                val ext = episode.string("container_extension").ifBlank { "mp4" }
                val number = episode.string("episode_num").toIntOrNull()
                val title = episode.string("title").ifBlank {
                    "${series.name} - S${(season ?: 0).toString().padStart(2, '0')}E${(number ?: 0).toString().padStart(2, '0')}"
                }
                output += MediaEntry(
                    id = "${series.id}:episode:$providerId",
                    providerId = providerId,
                    name = title,
                    kind = MediaKind.EPISODE,
                    categoryId = series.categoryId,
                    artwork = info?.string("movie_image").orEmpty().ifBlank { series.artwork },
                    rating = info?.string("rating").orEmpty(),
                    plot = info?.string("plot").orEmpty(),
                    streamUrl = streamUrl("series", providerId, ext),
                    containerExtension = ext,
                    seasonNumber = season,
                    episodeNumber = number,
                )
            }
        }
        return output
    }

    suspend fun guide(channel: MediaEntry): List<Programme> {
        if (source.type != SourceType.XTREAM || channel.kind != MediaKind.LIVE || channel.providerId.isBlank()) return emptyList()
        val root = requestJson("get_short_epg", "stream_id" to channel.providerId, "limit" to "24")
        val listings = root.arrayOrNull("epg_listings") ?: return emptyList()
        return listings.mapNotNull { element ->
            val item = element.objectOrNull() ?: return@mapNotNull null
            val title = decodeEpgText(item.string("title")).ifBlank { decodeEpgText(item.string("name")) }
            if (title.isBlank()) return@mapNotNull null
            Programme(
                title = title,
                description = decodeEpgText(item.string("description")),
                startEpochSeconds = item.epochSeconds("start_timestamp", "start"),
                endEpochSeconds = item.epochSeconds("stop_timestamp", "end"),
            )
        }
    }

    fun clearCache() {
        cache.clear()
        playlistEntries = null
    }

    private suspend fun loadXtreamSection(kind: MediaKind): CatalogSection {
        val (categoryAction, itemAction) = when (kind) {
            MediaKind.LIVE -> "get_live_categories" to "get_live_streams"
            MediaKind.MOVIE -> "get_vod_categories" to "get_vod_streams"
            MediaKind.SERIES -> "get_series_categories" to "get_series"
            MediaKind.EPISODE -> return CatalogSection()
        }
        val categoryJson = requestJson(categoryAction)
        val itemJson = requestJson(itemAction)
        val categoryArray = categoryJson.arrayOrNull()
            ?: throw CatalogDataException("The provider returned an invalid category response.")
        val itemArray = itemJson.arrayOrNull()
            ?: throw CatalogDataException("The provider returned an invalid catalog response.")
        val categories = categoryArray.elements().mapNotNull { element ->
            val item = element.objectOrNull() ?: return@mapNotNull null
            val id = item.string("category_id").ifBlank { item.string("id") }
            if (id.isBlank()) null else Category(id, item.string("category_name").ifBlank { "Uncategorized" })
        }.distinctBy { it.id }
        val entries = itemArray.elements().mapNotNull { element ->
            val item = element.objectOrNull() ?: return@mapNotNull null
            val providerId = when (kind) {
                MediaKind.LIVE -> item.string("stream_id")
                MediaKind.MOVIE -> item.string("stream_id")
                MediaKind.SERIES -> item.string("series_id").ifBlank { item.string("id") }
                MediaKind.EPISODE -> ""
            }.ifBlank { item.string("id") }
            if (providerId.isBlank()) return@mapNotNull null
            val id = "${source.id}:${kind.name.lowercase(Locale.ROOT)}:$providerId"
            val categoryId = item.string("category_id")
            val name = item.string("name").ifBlank { item.string("title") }.ifBlank { "Untitled" }
            val extension = item.string("container_extension").ifBlank { "mp4" }
            val playbackUrl = when (kind) {
                MediaKind.LIVE -> streamUrl("live", providerId, "m3u8")
                MediaKind.MOVIE -> streamUrl("movie", providerId, extension)
                MediaKind.SERIES, MediaKind.EPISODE -> ""
            }
            MediaEntry(
                id = id,
                providerId = providerId,
                name = name,
                kind = kind,
                categoryId = categoryId,
                artwork = item.string("stream_icon").ifBlank { item.string("cover") }.ifBlank { item.string("cover_big") },
                rating = item.string("rating").ifBlank { item.string("rating_5based") },
                plot = item.string("plot"),
                streamUrl = playbackUrl,
                containerExtension = extension,
                epgId = item.string("epg_channel_id"),
            )
        }.distinctBy { it.id }
        return CatalogSection(categories, entries)
    }

    private suspend fun loadPlaylistSection(kind: MediaKind): CatalogSection {
        val entries = loadPlaylist().filter { it.kind == kind }.map { item ->
            MediaEntry(
                id = "${source.id}:${item.id}",
                providerId = item.id,
                name = item.name,
                kind = item.kind,
                categoryId = item.group,
                artwork = item.logo,
                streamUrl = item.url,
                epgId = item.tvgId,
                requestHeaders = item.headers,
            )
        }
        val categories = entries.asSequence().map { it.categoryId }.distinct().map { Category(it, it) }.toList()
        return CatalogSection(categories = categories, entries = entries)
    }

    private suspend fun loadPlaylist(): List<PlaylistItem> {
        playlistEntries?.let { return it }
        val uri = runCatching { java.net.URI(source.playlistUrl) }.getOrNull()
            ?: throw CatalogDataException("The playlist address is invalid.")
        val parsed = if (uri.scheme.equals("file", true)) {
            loadLocalPlaylist(uri)
        } else {
            val url = source.playlistUrl.toHttpUrlOrNull()
                ?: throw CatalogDataException("The playlist address is invalid.")
            execute(Request.Builder().url(url).get().build()) { response, call ->
                val body = response.body ?: throw CatalogDataException("The playlist response was empty.")
                try {
                    M3UPlaylistParser.parse(body.source()) {
                        if (call.isCanceled()) throw CancellationException("The provider request was cancelled.")
                    }
                } catch (error: IOException) {
                    if (error is CatalogDataException) throw error
                    throw CatalogDataException(error.message?.takeIf { it.startsWith("Playlist ") } ?: "The playlist could not be read.")
                }
            }
        }
        if (parsed.isEmpty()) throw CatalogDataException("The playlist contains no supported HTTP streams.")
        playlistEntries = parsed
        return parsed
    }

    private suspend fun loadLocalPlaylist(uri: java.net.URI): List<PlaylistItem> = withContext(Dispatchers.IO) {
        try {
            val directory = localPlaylistDirectory?.canonicalFile
                ?: throw CatalogDataException("The imported playlist is not available on this device.")
            val file = File(uri.path).canonicalFile
            if (file.parentFile != directory || !file.name.matches(LOCAL_PLAYLIST_NAME) || !file.isFile) {
                throw CatalogDataException("The imported playlist is not available on this device.")
            }
            val coroutineContext = currentCoroutineContext()
            file.source().buffer().use { M3UPlaylistParser.parse(it) { coroutineContext.ensureActive() } }
        } catch (error: CatalogDataException) {
            throw error
        } catch (error: IOException) {
            val message = error.message?.takeIf { it.startsWith("Playlist ") }
            throw CatalogDataException(message ?: "The imported playlist could not be read.")
        }
    }

    private suspend fun requestJson(action: String?, vararg params: Pair<String, String>): JsonElement {
        val base = baseUrl ?: throw CatalogDataException("The provider address is invalid.")
        val builder = base.newBuilder().addPathSegment("player_api.php")
            .addQueryParameter("username", source.username)
            .addQueryParameter("password", source.password)
        if (action != null) builder.addQueryParameter("action", action)
        params.forEach { (name, value) -> builder.addQueryParameter(name, value) }
        val request = Request.Builder().url(builder.build()).get().build()
        return execute(request) { response, _ ->
            val body = response.body ?: throw CatalogDataException("The provider returned an empty response.")
            val bytes = readBounded(body, maxJsonBytes)
            try {
                JsonParser.parseString(bytes.readUtf8())
            } catch (_: Exception) {
                throw CatalogDataException("The provider returned invalid JSON.")
            }
        }
    }

    private fun streamUrl(kind: String, providerId: String, extension: String): String {
        val base = baseUrl ?: throw CatalogDataException("The provider address is invalid.")
        val safeExtension = extension.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }.ifBlank { "mp4" }
        return base.newBuilder()
            .addPathSegment(kind)
            .addEncodedPathSegment(encodePathSegment(source.username))
            .addEncodedPathSegment(encodePathSegment(source.password))
            .addEncodedPathSegment(encodePathSegment("$providerId.$safeExtension"))
            .build().toString()
    }

    private fun encodePathSegment(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

    private suspend fun <T> execute(request: Request, parse: (Response, Call) -> T): T =
        suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request.newBuilder().header("User-Agent", USER_AGENT).build())
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWith(Result.failure(CatalogDataException("Could not connect to the provider.")))
                }

                override fun onResponse(call: Call, response: Response) {
                    val outcome: Result<T> = try {
                        response.use {
                            if (!it.isSuccessful) {
                                throw CatalogDataException("Provider request failed with HTTP ${it.code}.")
                            }
                            Result.success(parse(it, call))
                        }
                    } catch (error: CatalogDataException) {
                        Result.failure(error)
                    } catch (error: CancellationException) {
                        Result.failure(error)
                    } catch (_: IOException) {
                        Result.failure(CatalogDataException("Could not connect to the provider."))
                    } catch (_: Exception) {
                        Result.failure(CatalogDataException("The provider response could not be read."))
                    }
                    continuation.resumeWith(outcome)
                }
            })
        }

    private fun readBounded(body: ResponseBody, limit: Long): Buffer {
        val buffer = Buffer()
        val upstream = body.source()
        var total = 0L
        while (true) {
            val read = upstream.read(buffer, 8_192)
            if (read < 0) break
            total += read
            if (total > limit) throw CatalogDataException("The provider response exceeds the size limit.")
        }
        return buffer
    }

    private fun JsonElement?.objectOrNull(name: String? = null): JsonObject? {
        val value = if (name == null) this else this?.takeIf { it.isJsonObject }?.asJsonObject?.get(name)
        return value?.takeIf { it.isJsonObject }?.asJsonObject
    }

    private fun JsonElement?.arrayOrNull(name: String? = null): JsonArray? {
        val value = if (name == null) this else this?.takeIf { it.isJsonObject }?.asJsonObject?.get(name)
        return value?.takeIf { it.isJsonArray }?.asJsonArray
    }

    private fun JsonArray?.elements(): List<JsonElement> = this?.let { array ->
        List(array.size()) { index -> array[index] }
    }.orEmpty()

    private fun JsonObject.string(name: String): String = get(name)
        ?.takeIf { it.isJsonPrimitive && !it.asJsonPrimitive.isJsonNull }
        ?.asJsonPrimitive?.asString.orEmpty()

    private fun JsonObject.epochSeconds(vararg names: String): Long {
        names.forEach { key ->
            val value = string(key)
            value.toLongOrNull()?.let { return it }
            if (value.isNotBlank()) {
                runCatching {
                    SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).apply {
                        isLenient = false
                        timeZone = TimeZone.getTimeZone("UTC")
                    }.parse(value)?.time?.div(1000)
                }.getOrNull()?.let { return it }
            }
        }
        return 0L
    }

    companion object {
        private const val USER_AGENT = "BruTV/1.0"
        private val LOCAL_PLAYLIST_NAME = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\.m3u")
        private const val maxJsonBytes = 64L * 1024 * 1024
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .callTimeout(60, TimeUnit.SECONDS)
            .build()
    }
}

private fun decodeEpgText(value: String): String {
    val text = value.normalizeEpgWhitespace()
    if (text.length < 8 || text.any(Char::isWhitespace) ||
        !text.matches(Regex("[A-Za-z0-9+/]+={0,2}")) || text.length % 4 == 1) {
        return text
    }

    val encoded = text.decodeBase64() ?: return text
    val decoded = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(encoded.toByteArray()))
            .toString()
    }.getOrNull() ?: return text
    if (decoded.isBlank() || decoded.any { it.isISOControl() && !it.isWhitespace() }) return text

    val hasEncodingHint = text.any { it == '=' || it.isDigit() || it == '+' || it == '/' }
    if (!hasEncodingHint && decoded.none { it.isWhitespace() || !it.isLetterOrDigit() }) return text
    return decoded.normalizeEpgWhitespace()
}

private fun String.normalizeEpgWhitespace(): String = trim().replace(Regex("\\s+"), " ")
