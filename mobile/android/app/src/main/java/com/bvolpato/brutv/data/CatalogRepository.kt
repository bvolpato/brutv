package com.bvolpato.brutv.data

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.Strictness
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import com.google.gson.stream.MalformedJsonException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.ByteString.Companion.decodeBase64
import okio.buffer
import okio.source
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedReader
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.PushbackInputStream
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLKeyException
import javax.net.ssl.SSLPeerUnverifiedException
import kotlin.random.Random

class CatalogDataException(message: String) : IOException(message)

/** Xtream Codes and M3U data adapter. Create one repository per saved source profile. */
class CatalogRepository internal constructor(
    source: SourceConfig,
    private val client: OkHttpClient,
    private val localPlaylistDirectory: File?,
    private val retryDelay: suspend (Long) -> Unit,
    private val jitter: () -> Double,
    private val maxJsonBytes: Long,
    cacheDirectory: File? = null,
    diskCacheTtlMs: Long = CatalogDiskCache.DEFAULT_TTL_MS,
    private val xmlPullParserFactory: () -> XmlPullParser = { android.util.Xml.newPullParser() },
) {
    constructor(
        source: SourceConfig,
        client: OkHttpClient = defaultClient,
        localPlaylistDirectory: File? = null,
        cacheDirectory: File? = null,
    ) : this(
        source = source,
        client = client,
        localPlaylistDirectory = localPlaylistDirectory,
        retryDelay = { delay(it) },
        jitter = { Random.nextDouble() },
        maxJsonBytes = DEFAULT_MAX_JSON_BYTES,
        cacheDirectory = cacheDirectory,
    )

    private data class CachedGuide(val programmes: List<Programme>, val fetchedAtMs: Long)

    private val source = source.normalized()
    private val baseUrl: HttpUrl? = if (this.source.type == SourceType.XTREAM) this.source.server.toHttpUrlOrNull() else null
    private val xtreamBasePrefix: String? = baseUrl?.toString()?.trimEnd('/')
    private val encodedUser: String = if (this.source.type == SourceType.XTREAM) encodePathSegment(this.source.username) else ""
    private val encodedPass: String = if (this.source.type == SourceType.XTREAM) encodePathSegment(this.source.password) else ""
    private val diskCache: CatalogDiskCache? = cacheDirectory?.let { CatalogDiskCache(it, diskCacheTtlMs) }
    private val cache = ConcurrentHashMap<MediaKind, CatalogSection>()
    private val sectionMutexes: Map<MediaKind, Mutex> = MediaKind.entries.associateWith { Mutex() }
    private val playlistMutex = Mutex()
    private val xmltvMutex = Mutex()
    private val shortGuideCache = ConcurrentHashMap<String, CachedGuide>()
    @Volatile private var m3uEpgUrl: String? = null
    @Volatile private var xmltvGuide: XmltvGuide? = null
    @Volatile private var preferredLiveExtension: String = "m3u8"
    @Volatile var maxConnections: Int = 1
        private set

    suspend fun authenticate() {
        if (source.type == SourceType.M3U) {
            loadPlaylistIntoCache(force = false)
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
        val allowedFormats = user.arrayOrNull("allowed_output_formats")
            ?.elements()
            ?.mapNotNull { element ->
                element.takeIf { it.isJsonPrimitive && !it.asJsonPrimitive.isJsonNull }
                    ?.asJsonPrimitive?.asString
            }
        preferredLiveExtension = selectLiveExtension(allowedFormats)
        maxConnections = parseMaxConnections(user.string("max_connections"))
    }

    /** Reads a previously cached section from disk for stale-while-revalidate startup. */
    suspend fun readDiskCache(kind: MediaKind, nowMs: Long = System.currentTimeMillis()): CachedCatalogSection? {
        val store = diskCache ?: return null
        return withContext(Dispatchers.IO) {
            store.read(
                sourceId = source.id,
                kind = kind,
                isXtream = source.type == SourceType.XTREAM,
                nowMs = nowMs,
                resolveXtreamUrl = { entryKind, providerId, extension ->
                    when (entryKind) {
                        MediaKind.LIVE -> streamUrl("live", providerId, preferredLiveExtension)
                        MediaKind.MOVIE -> streamUrl("movie", providerId, extension)
                        MediaKind.SERIES, MediaKind.EPISODE -> ""
                    }
                },
            )
        }
    }

    suspend fun load(kind: MediaKind, force: Boolean = false): CatalogSection {
        if (!force) {
            cache[kind]?.let { return it }
        }
        if (source.type == SourceType.M3U) {
            return playlistMutex.withLock {
                if (!force) cache[kind]?.let { return@withLock it }
                loadPlaylistIntoCache(force = force)
                cache[kind] ?: CatalogSection()
            }
        }
        val mutex = sectionMutexes.getValue(kind)
        return mutex.withLock {
            if (!force) {
                cache[kind]?.let { return@withLock it }
            }
            val section = loadXtreamSection(kind)
            cache[kind] = section
            diskCache?.write(source.id, kind, section, isXtream = true)
            section
        }
    }

    suspend fun episodes(series: MediaEntry): List<MediaEntry> {
        if (source.type != SourceType.XTREAM || series.kind != MediaKind.SERIES || series.providerId.isBlank()) return emptyList()
        val root = requestJson("get_series_info", "series_id" to series.providerId)
        val seasons = root.objectOrNull("episodes") ?: return emptyList()
        val seriesPrefix = xtreamStreamPrefix("series")
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
                    streamUrl = buildStreamUrlWithPrefix(seriesPrefix, providerId, ext),
                    containerExtension = ext,
                    seasonNumber = season,
                    episodeNumber = number,
                )
            }
        }
        return output
    }

    suspend fun vodInfo(movie: MediaEntry): MovieDetails? {
        if (source.type != SourceType.XTREAM || movie.kind != MediaKind.MOVIE || movie.providerId.isBlank()) return null
        val root = requestJson("get_vod_info", "vod_id" to movie.providerId)
        val info = root.objectOrNull("info") ?: return null
        val durationText = info.string("duration").ifBlank {
            info.string("duration_secs").toLongOrNull()?.takeIf { it > 0L }?.let { secs ->
                val hours = secs / 3600L
                val minutes = (secs % 3600L) / 60L
                if (hours > 0) "${hours}h ${minutes}m" else "${minutes}m"
            }.orEmpty()
        }
        return MovieDetails(
            plot = info.string("plot").ifBlank { info.string("description") },
            cast = info.string("cast").ifBlank { info.string("actors") },
            director = info.string("director"),
            duration = durationText,
            genre = info.string("genre"),
            releaseDate = info.string("releasedate").ifBlank { info.string("release_date") },
            rating = info.string("rating").ifBlank { info.string("rating_5based") },
            artwork = info.string("movie_image").ifBlank { info.string("cover_big") },
        )
    }

    /** Synchronous lookup for already-cached short EPG or XMLTV programmes for a live channel. */
    fun cachedGuide(channel: MediaEntry): List<Programme> {
        if (channel.kind != MediaKind.LIVE) return emptyList()
        val now = System.currentTimeMillis()
        shortGuideCache[channel.id]?.takeIf { now - it.fetchedAtMs < SHORT_GUIDE_TTL_MS }?.let {
            if (it.programmes.isNotEmpty()) return it.programmes
        }
        xmltvGuide?.programmesFor(channel)?.takeIf { it.isNotEmpty() }?.let { return it }
        return emptyList()
    }

    suspend fun guide(channel: MediaEntry): List<Programme> {
        if (channel.kind != MediaKind.LIVE) return emptyList()
        val now = System.currentTimeMillis()
        shortGuideCache[channel.id]?.takeIf { now - it.fetchedAtMs < SHORT_GUIDE_TTL_MS }?.let {
            return it.programmes
        }
        if (source.type == SourceType.XTREAM && channel.providerId.isNotBlank()) {
            val root = requestJson("get_short_epg", "stream_id" to channel.providerId, "limit" to "24")
            val listings = root.arrayOrNull("epg_listings")
            val parsed = listings?.mapNotNull { element ->
                val item = element.objectOrNull() ?: return@mapNotNull null
                val title = decodeEpgText(item.string("title")).ifBlank { decodeEpgText(item.string("name")) }
                if (title.isBlank()) return@mapNotNull null
                Programme(
                    title = title,
                    description = decodeEpgText(item.string("description")),
                    startEpochSeconds = item.epochSeconds("start_timestamp", "start"),
                    endEpochSeconds = item.epochSeconds("stop_timestamp", "end"),
                )
            }.orEmpty()
            if (parsed.isNotEmpty()) {
                cacheShortGuide(channel.id, parsed, now)
                return parsed
            }
        }
        xmltvGuide?.programmesFor(channel)?.takeIf { it.isNotEmpty() }?.let { return it }
        return emptyList()
    }

    /** Loads XMLTV guide (`xmltv.php` for Xtream or `url-tvg` for M3U) with a bounded 24-48h window. */
    suspend fun loadXmltv(
        force: Boolean = false,
        nowEpochSeconds: Long = System.currentTimeMillis() / 1_000L,
    ): XmltvGuide? {
        val nowMs = System.currentTimeMillis()
        if (!force) {
            xmltvGuide?.takeIf { nowMs - it.fetchedAtMs < XMLTV_TTL_MS }?.let { return it }
        }
        val request = buildXmltvRequest() ?: return null
        return xmltvMutex.withLock {
            if (!force) {
                xmltvGuide?.takeIf { System.currentTimeMillis() - it.fetchedAtMs < XMLTV_TTL_MS }?.let { return@withLock it }
            }
            val parsed = execute(request) { response, call ->
                XmltvParser.parse(
                    input = response.body.byteStream(),
                    nowEpochSeconds = nowEpochSeconds,
                    checkCancellation = {
                        if (call.isCanceled()) throw CancellationException("The provider request was cancelled.")
                    },
                    parserFactory = xmlPullParserFactory,
                )
            }
            xmltvGuide = parsed
            parsed
        }
    }

    private fun buildXmltvRequest(): Request? = when (source.type) {
        SourceType.XTREAM -> {
            val base = baseUrl ?: return null
            val url = base.newBuilder()
                .addPathSegment("xmltv.php")
                .addQueryParameter("username", source.username)
                .addQueryParameter("password", source.password)
                .build()
            Request.Builder().url(url).get().build()
        }
        SourceType.M3U -> {
            val url = m3uEpgUrl?.toHttpUrlOrNull() ?: return null
            Request.Builder().url(url).get().build()
        }
    }

    private fun cacheShortGuide(channelId: String, programmes: List<Programme>, nowMs: Long) {
        if (shortGuideCache.size >= MAX_SHORT_GUIDE_ENTRIES) {
            val iterator = shortGuideCache.entries.iterator()
            var removed = 0
            while (iterator.hasNext() && removed < 64) {
                iterator.next()
                iterator.remove()
                removed++
            }
        }
        shortGuideCache[channelId] = CachedGuide(programmes, nowMs)
    }

    fun clearCache(clearDisk: Boolean = false) {
        cache.clear()
        shortGuideCache.clear()
        xmltvGuide = null
        m3uEpgUrl = null
        preferredLiveExtension = "m3u8"
        maxConnections = 1
        if (clearDisk) {
            diskCache?.clearSource(source.id)
        }
    }

    private suspend fun loadXtreamSection(kind: MediaKind): CatalogSection = coroutineScope {
        val (categoryAction, itemAction) = when (kind) {
            MediaKind.LIVE -> "get_live_categories" to "get_live_streams"
            MediaKind.MOVIE -> "get_vod_categories" to "get_vod_streams"
            MediaKind.SERIES -> "get_series_categories" to "get_series"
            MediaKind.EPISODE -> return@coroutineScope CatalogSection()
        }
        val categoriesDeferred = async(Dispatchers.IO) {
            requestJsonStream(categoryAction) { reader, call ->
                if (reader.peek() != JsonToken.BEGIN_ARRAY) {
                    throw CatalogDataException("The provider returned an invalid category response.")
                }
                val result = ArrayList<Category>()
                val seenIds = HashSet<String>()
                reader.beginArray()
                while (reader.hasNext()) {
                    if (call.isCanceled()) throw CancellationException("The provider request was cancelled.")
                    if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                        reader.skipValue()
                        continue
                    }
                    var categoryId = ""
                    var fallbackId = ""
                    var categoryName = ""
                    reader.beginObject()
                    while (reader.hasNext()) {
                        when (reader.nextName()) {
                            "category_id" -> categoryId = reader.readScalarString()
                            "id" -> fallbackId = reader.readScalarString()
                            "category_name" -> categoryName = reader.readScalarString()
                            else -> reader.skipValue()
                        }
                    }
                    reader.endObject()
                    val id = categoryId.ifBlank { fallbackId }
                    if (id.isNotBlank() && seenIds.add(id)) {
                        result += Category(id, categoryName.ifBlank { "Uncategorized" })
                    }
                }
                reader.endArray()
                result
            }
        }
        val entriesDeferred = async(Dispatchers.IO) {
            val kindLower = kind.name.lowercase(Locale.ROOT)
            val idPrefix = "${source.id}:$kindLower:"
            val urlPrefix = when (kind) {
                MediaKind.LIVE -> xtreamStreamPrefix("live")
                MediaKind.MOVIE -> xtreamStreamPrefix("movie")
                MediaKind.SERIES, MediaKind.EPISODE -> ""
            }
            val liveExt = safeExtension(preferredLiveExtension)
            requestJsonStream(itemAction) { reader, call ->
                if (reader.peek() != JsonToken.BEGIN_ARRAY) {
                    throw CatalogDataException("The provider returned an invalid catalog response.")
                }
                val result = ArrayList<MediaEntry>()
                val seenIds = HashSet<String>()
                reader.beginArray()
                while (reader.hasNext()) {
                    if (call.isCanceled()) throw CancellationException("The provider request was cancelled.")
                    if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                        reader.skipValue()
                        continue
                    }
                    var streamId = ""
                    var seriesId = ""
                    var genericId = ""
                    var categoryId = ""
                    var name = ""
                    var title = ""
                    var containerExtension = ""
                    var streamIcon = ""
                    var cover = ""
                    var coverBig = ""
                    var rating = ""
                    var rating5Based = ""
                    var plot = ""
                    var epgChannelId = ""
                    reader.beginObject()
                    while (reader.hasNext()) {
                        when (reader.nextName()) {
                            "stream_id" -> streamId = reader.readScalarString()
                            "series_id" -> seriesId = reader.readScalarString()
                            "id" -> genericId = reader.readScalarString()
                            "category_id" -> categoryId = reader.readScalarString()
                            "name" -> name = reader.readScalarString()
                            "title" -> title = reader.readScalarString()
                            "container_extension" -> containerExtension = reader.readScalarString()
                            "stream_icon" -> streamIcon = reader.readScalarString()
                            "cover" -> cover = reader.readScalarString()
                            "cover_big" -> coverBig = reader.readScalarString()
                            "rating" -> rating = reader.readScalarString()
                            "rating_5based" -> rating5Based = reader.readScalarString()
                            "plot" -> plot = reader.readScalarString()
                            "epg_channel_id" -> epgChannelId = reader.readScalarString()
                            else -> reader.skipValue()
                        }
                    }
                    reader.endObject()
                    val providerId = when (kind) {
                        MediaKind.LIVE, MediaKind.MOVIE -> streamId
                        MediaKind.SERIES -> seriesId.ifBlank { genericId }
                        MediaKind.EPISODE -> ""
                    }.ifBlank { genericId }
                    if (providerId.isBlank()) continue
                    val id = idPrefix + providerId
                    if (!seenIds.add(id)) continue
                    val resolvedName = name.ifBlank { title }.ifBlank { "Untitled" }
                    val extension = containerExtension.ifBlank { "mp4" }
                    val playbackUrl = when (kind) {
                        MediaKind.LIVE -> buildStreamUrlWithPrefix(urlPrefix, providerId, liveExt, alreadySafeExt = true)
                        MediaKind.MOVIE -> buildStreamUrlWithPrefix(urlPrefix, providerId, extension)
                        MediaKind.SERIES, MediaKind.EPISODE -> ""
                    }
                    result += MediaEntry(
                        id = id,
                        providerId = providerId,
                        name = resolvedName,
                        kind = kind,
                        categoryId = categoryId,
                        artwork = streamIcon.ifBlank { cover }.ifBlank { coverBig },
                        rating = rating.ifBlank { rating5Based },
                        plot = plot,
                        streamUrl = playbackUrl,
                        containerExtension = extension,
                        epgId = epgChannelId,
                    )
                }
                reader.endArray()
                result
            }
        }
        val categories = categoriesDeferred.await()
        val entries = entriesDeferred.await()
        CatalogSection.build(categories, entries)
    }

    /**
     * Parses the M3U playlist once, partitions directly into LIVE/MOVIE/SERIES sections in [cache],
     * writes disk cache, and drops the raw [PlaylistItem] list immediately to avoid 2x heap retention.
     */
    private suspend fun loadPlaylistIntoCache(force: Boolean) {
        if (!force && cache.containsKey(MediaKind.LIVE)) return
        val uri = runCatching { java.net.URI(source.playlistUrl) }.getOrNull()
            ?: throw CatalogDataException("The playlist address is invalid.")
        val parsed = if (uri.scheme.equals("file", true)) {
            loadLocalPlaylist(uri)
        } else {
            val url = source.playlistUrl.toHttpUrlOrNull()
                ?: throw CatalogDataException("The playlist address is invalid.")
            execute(Request.Builder().url(url).get().build()) { response, call ->
                val body = response.body
                try {
                    M3UPlaylistParser.parseWithMetadata(body.source()) {
                        if (call.isCanceled()) throw CancellationException("The provider request was cancelled.")
                    }
                } catch (error: IOException) {
                    if (error is CatalogDataException) throw error
                    throw CatalogDataException(error.message?.takeIf { it.startsWith("Playlist ") } ?: "The playlist could not be read.")
                }
            }
        }
        if (parsed.items.isEmpty()) throw CatalogDataException("The playlist contains no supported HTTP streams.")
        m3uEpgUrl = parsed.epgUrl

        val liveEntries = ArrayList<MediaEntry>()
        val movieEntries = ArrayList<MediaEntry>()
        val liveCategories = LinkedHashSet<String>()
        val movieCategories = LinkedHashSet<String>()
        val idPrefix = "${source.id}:"

        for (item in parsed.items) {
            val entry = MediaEntry(
                id = idPrefix + item.id,
                providerId = item.id,
                name = item.name,
                kind = item.kind,
                categoryId = item.group,
                artwork = item.logo,
                streamUrl = item.url,
                epgId = item.tvgId,
                requestHeaders = item.headers,
            )
            when (item.kind) {
                MediaKind.LIVE -> {
                    liveEntries.add(entry)
                    liveCategories.add(item.group)
                }
                MediaKind.MOVIE -> {
                    movieEntries.add(entry)
                    movieCategories.add(item.group)
                }
                else -> Unit
            }
        }
        val liveSection = CatalogSection.build(
            categories = liveCategories.map { Category(it, it) },
            entries = liveEntries,
        )
        val movieSection = CatalogSection.build(
            categories = movieCategories.map { Category(it, it) },
            entries = movieEntries,
        )
        val emptySeries = CatalogSection()

        cache[MediaKind.LIVE] = liveSection
        cache[MediaKind.MOVIE] = movieSection
        cache[MediaKind.SERIES] = emptySeries
        diskCache?.let { store ->
            store.write(source.id, MediaKind.LIVE, liveSection, isXtream = false)
            store.write(source.id, MediaKind.MOVIE, movieSection, isXtream = false)
            store.write(source.id, MediaKind.SERIES, emptySeries, isXtream = false)
        }
    }

    private suspend fun loadLocalPlaylist(uri: java.net.URI): ParsedPlaylist = withContext(Dispatchers.IO) {
        try {
            val directory = localPlaylistDirectory?.canonicalFile
                ?: throw CatalogDataException("The imported playlist is not available on this device.")
            val file = File(uri.path).canonicalFile
            if (file.parentFile != directory || !file.name.matches(LOCAL_PLAYLIST_NAME) || !file.isFile) {
                throw CatalogDataException("The imported playlist is not available on this device.")
            }
            val coroutineContext = currentCoroutineContext()
            file.source().buffer().use { M3UPlaylistParser.parseWithMetadata(it) { coroutineContext.ensureActive() } }
        } catch (error: CatalogDataException) {
            throw error
        } catch (error: IOException) {
            val message = error.message?.takeIf { it.startsWith("Playlist ") }
            throw CatalogDataException(message ?: "The imported playlist could not be read.")
        }
    }

    private fun buildXtreamRequest(action: String?, vararg params: Pair<String, String>): Request {
        val base = baseUrl ?: throw CatalogDataException("The provider address is invalid.")
        val builder = base.newBuilder().addPathSegment("player_api.php")
            .addQueryParameter("username", source.username)
            .addQueryParameter("password", source.password)
        if (action != null) builder.addQueryParameter("action", action)
        params.forEach { (name, value) -> builder.addQueryParameter(name, value) }
        return Request.Builder().url(builder.build()).get().build()
    }

    private suspend fun <T> requestJsonStream(
        action: String?,
        vararg params: Pair<String, String>,
        parseStream: (JsonReader, Call) -> T,
    ): T {
        val request = buildXtreamRequest(action, *params)
        return execute(request) { response, call ->
            val body = response.body
            val bounded = PushbackInputStream(BoundedInputStream(body.byteStream(), maxJsonBytes), 3)
            val bom = ByteArray(3)
            var bomRead = 0
            while (bomRead < 3) {
                val n = bounded.read(bom, bomRead, 3 - bomRead)
                if (n <= 0) break
                bomRead += n
            }
            if (bomRead > 0 && !(bomRead == 3 && bom[0] == 0xEF.toByte() && bom[1] == 0xBB.toByte() && bom[2] == 0xBF.toByte())) {
                bounded.unread(bom, 0, bomRead)
            }
            try {
                JsonReader(BufferedReader(InputStreamReader(bounded, Charsets.UTF_8), 16 * 1024)).use { reader ->
                    reader.strictness = Strictness.LENIENT
                    parseStream(reader, call)
                }
            } catch (error: CatalogDataException) {
                throw error
            } catch (error: CancellationException) {
                throw error
            } catch (_: MalformedJsonException) {
                throw CatalogDataException("The provider returned invalid JSON.")
            } catch (_: IllegalStateException) {
                throw CatalogDataException("The provider returned invalid JSON.")
            } catch (_: NumberFormatException) {
                throw CatalogDataException("The provider returned invalid JSON.")
            }
        }
    }

    private suspend fun requestJson(action: String?, vararg params: Pair<String, String>): JsonElement {
        val request = buildXtreamRequest(action, *params)
        return execute(request) { response, _ ->
            val body = response.body
            val bytes = readBounded(body, maxJsonBytes)
            try {
                JsonParser.parseString(bytes.readUtf8().removePrefix("\uFEFF"))
            } catch (_: Exception) {
                throw CatalogDataException("The provider returned invalid JSON.")
            }
        }
    }

    private fun xtreamStreamPrefix(kind: String): String {
        val prefix = xtreamBasePrefix ?: throw CatalogDataException("The provider address is invalid.")
        return "$prefix/$kind/$encodedUser/$encodedPass/"
    }

    private fun streamUrl(kind: String, providerId: String, extension: String): String =
        buildStreamUrlWithPrefix(xtreamStreamPrefix(kind), providerId, extension)

    private fun buildStreamUrlWithPrefix(
        prefix: String,
        providerId: String,
        extension: String,
        alreadySafeExt: Boolean = false,
    ): String {
        val ext = if (alreadySafeExt) extension else safeExtension(extension)
        if (isSafePathSegment(providerId)) {
            return "$prefix$providerId.$ext"
        }
        return "$prefix${encodePathSegment("$providerId.$ext")}"
    }

    private fun safeExtension(extension: String): String {
        if (extension == "mp4" || extension == "m3u8" || extension == "ts" || extension == "mkv") {
            return extension
        }
        val sb = StringBuilder(extension.length)
        for (c in extension) {
            if (c.isLetterOrDigit()) sb.append(c.lowercaseChar())
        }
        return if (sb.isEmpty()) "mp4" else sb.toString()
    }

    private fun isSafePathSegment(value: String): Boolean {
        if (value.isEmpty()) return false
        for (i in 0 until value.length) {
            val c = value[i]
            val safe = (c in '0'..'9') || (c in 'a'..'z') || (c in 'A'..'Z') || c == '-' || c == '_'
            if (!safe) return false
        }
        return true
    }

    private fun encodePathSegment(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

    private sealed interface AttemptOutcome<out T> {
        data class Success<T>(val value: T) : AttemptOutcome<T>
        data class Retry(val delayMs: Long, val fallbackError: CatalogDataException) : AttemptOutcome<Nothing>
        data class Failure(val error: Throwable) : AttemptOutcome<Nothing>
    }

    private suspend fun <T> execute(request: Request, parse: (Response, Call) -> T): T {
        var attempt = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            when (val outcome = executeOnce(request, attempt, parse)) {
                is AttemptOutcome.Success -> return outcome.value
                is AttemptOutcome.Failure -> throw outcome.error
                is AttemptOutcome.Retry -> {
                    if (attempt >= MAX_TRANSIENT_RETRIES) throw outcome.fallbackError
                    attempt++
                    currentCoroutineContext().ensureActive()
                    retryDelay(outcome.delayMs)
                }
            }
        }
    }

    private suspend fun <T> executeOnce(
        request: Request,
        attempt: Int,
        parse: (Response, Call) -> T,
    ): AttemptOutcome<T> = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request.newBuilder().header("User-Agent", USER_AGENT).build())
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (call.isCanceled()) {
                    continuation.resumeWith(Result.success(AttemptOutcome.Failure(CancellationException("The provider request was cancelled."))))
                    return
                }
                val error = CatalogDataException("Could not connect to the provider.")
                val outcome = if (attempt < MAX_TRANSIENT_RETRIES && isRetryableCatalogIo(e)) {
                    AttemptOutcome.Retry(computeBackoffMs(attempt, retryAfterMs = null), error)
                } else {
                    AttemptOutcome.Failure(error)
                }
                continuation.resumeWith(Result.success(outcome))
            }

            override fun onResponse(call: Call, response: Response) {
                val outcome: AttemptOutcome<T> = try {
                    response.use {
                        if (!it.isSuccessful) {
                            val error = CatalogDataException("Provider request failed with HTTP ${it.code}.")
                            if (attempt < MAX_TRANSIENT_RETRIES && isRetryableHttpStatus(it.code)) {
                                val retryAfterMs = parseRetryAfterMs(it.header("Retry-After"))
                                return@use AttemptOutcome.Retry(computeBackoffMs(attempt, retryAfterMs), error)
                            }
                            return@use AttemptOutcome.Failure(error)
                        }
                        AttemptOutcome.Success(parse(it, call))
                    }
                } catch (error: CatalogDataException) {
                    AttemptOutcome.Failure(error)
                } catch (error: CancellationException) {
                    AttemptOutcome.Failure(error)
                } catch (error: IOException) {
                    if (call.isCanceled()) {
                        AttemptOutcome.Failure(CancellationException("The provider request was cancelled."))
                    } else {
                        val wrapped = CatalogDataException("Could not connect to the provider.")
                        if (attempt < MAX_TRANSIENT_RETRIES && isRetryableCatalogIo(error)) {
                            AttemptOutcome.Retry(computeBackoffMs(attempt, retryAfterMs = null), wrapped)
                        } else {
                            AttemptOutcome.Failure(wrapped)
                        }
                    }
                } catch (_: Exception) {
                    AttemptOutcome.Failure(CatalogDataException("The provider response could not be read."))
                }
                continuation.resumeWith(Result.success(outcome))
            }
        })
    }

    private fun computeBackoffMs(attempt: Int, retryAfterMs: Long?): Long {
        if (retryAfterMs != null) return retryAfterMs.coerceIn(0L, MAX_RETRY_AFTER_MS)
        val base = if (attempt == 0) 500L else 1_500L
        val factor = 0.8 + jitter().coerceIn(0.0, 1.0) * 0.4
        return (base * factor).toLong().coerceAtMost(MAX_RETRY_AFTER_MS)
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
        internal const val USER_AGENT = "BruTV/1.0"
        private const val MAX_TRANSIENT_RETRIES = 2
        internal const val MAX_RETRY_AFTER_MS = 10_000L
        private const val SHORT_GUIDE_TTL_MS = 15L * 60L * 1_000L
        private const val XMLTV_TTL_MS = 6L * 60L * 60L * 1_000L
        private const val MAX_SHORT_GUIDE_ENTRIES = 256
        private val LOCAL_PLAYLIST_NAME = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\.m3u")
        private const val DEFAULT_MAX_JSON_BYTES = 64L * 1024 * 1024
        private val defaultClient = OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .callTimeout(60, TimeUnit.SECONDS)
            .build()

        internal fun isRetryableHttpStatus(code: Int): Boolean =
            code == 408 || code == 429 || code in 500..599

        internal fun isRetryableCatalogIo(error: IOException): Boolean {
            val causes = generateSequence<Throwable>(error) { it.cause }.take(12).toList()
            if (causes.any {
                    it is SSLPeerUnverifiedException ||
                        it is SSLKeyException ||
                        it is CertificateException ||
                        it is CertPathValidatorException
                }
            ) {
                return false
            }
            if (causes.any { it is SSLHandshakeException }) {
                return causes.any { it is SocketTimeoutException || it is SocketException || it is EOFException }
            }
            return true
        }

        internal fun selectLiveExtension(allowedFormats: List<String>?): String {
            val normalized = allowedFormats
                ?.mapNotNull { it.trim().removePrefix(".").lowercase(Locale.ROOT).takeIf(String::isNotEmpty) }
                ?.toSet()
                .orEmpty()
            if (normalized.isEmpty()) return "m3u8"
            val hasHls = "m3u8" in normalized || "hls" in normalized
            val hasTs = "ts" in normalized || "mpegts" in normalized
            return if (!hasHls && hasTs) "ts" else "m3u8"
        }

        internal fun parseMaxConnections(raw: String?): Int =
            raw?.trim()?.toIntOrNull()?.takeIf { it > 0 } ?: 1

        internal fun parseRetryAfterMs(header: String?, nowMs: Long = System.currentTimeMillis()): Long? {
            val value = header?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            value.toLongOrNull()?.let { seconds ->
                return (seconds.coerceAtLeast(0L) * 1_000L).coerceAtMost(MAX_RETRY_AFTER_MS)
            }
            val parsed = runCatching {
                SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
                    isLenient = false
                    timeZone = TimeZone.getTimeZone("GMT")
                }.parse(value)?.time
            }.getOrNull() ?: return null
            return (parsed - nowMs).coerceIn(0L, MAX_RETRY_AFTER_MS)
        }
    }
}

private class BoundedInputStream(
    private val delegate: InputStream,
    private val limitBytes: Long,
) : InputStream() {
    private var bytesRead = 0L

    override fun read(): Int {
        val next = delegate.read()
        if (next >= 0 && ++bytesRead > limitBytes) {
            throw CatalogDataException("The provider response exceeds the size limit.")
        }
        return next
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val count = delegate.read(b, off, len)
        if (count > 0) {
            bytesRead += count
            if (bytesRead > limitBytes) {
                throw CatalogDataException("The provider response exceeds the size limit.")
            }
        }
        return count
    }

    override fun close() {
        delegate.close()
    }
}

private fun JsonReader.readScalarString(): String = when (peek()) {
    JsonToken.STRING, JsonToken.NUMBER -> nextString()
    JsonToken.BOOLEAN -> nextBoolean().toString()
    JsonToken.NULL -> {
        nextNull()
        ""
    }
    else -> {
        skipValue()
        ""
    }
}

private val EPG_BASE64_REGEX = Regex("[A-Za-z0-9+/]+={0,2}")
private val EPG_WHITESPACE_REGEX = Regex("\\s+")

private fun decodeEpgText(value: String): String {
    val text = value.normalizeEpgWhitespace()
    if (text.length < 8 || text.any(Char::isWhitespace) ||
        !EPG_BASE64_REGEX.matches(text) || text.length % 4 == 1) {
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

private fun String.normalizeEpgWhitespace(): String = trim().replace(EPG_WHITESPACE_REGEX, " ")
