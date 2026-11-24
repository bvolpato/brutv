package com.bvolpato.brutv.playback

import android.os.Looper
import com.bvolpato.brutv.data.CatalogRepository
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

internal class TimeShiftHttpException(val statusCode: Int) : IOException("The live source returned HTTP $statusCode.")

internal data class TimeShiftRecordingSnapshot(
    val durationMs: Long,
    val bytes: Long,
    val recording: Boolean,
    val notice: String?,
    val windowStartOffsetMs: Long,
)

internal class LocalTimeShiftSource(val url: String) {
    @Volatile var windowStartOffsetMs: Long? = null
        internal set
}

/** A foreground live recorder whose network ingestion is independent of player pause. */
internal class HlsTimeShiftSession private constructor(
    private val directory: File,
    private val headers: Map<String, String>,
    private val limits: TimeShiftLimits,
    client: OkHttpClient,
    private val originalUrl: String,
) : Closeable {
    private data class Resource(val name: String, val file: File, val bytes: Long)
    private data class Segment(
        val spec: RecordedSegmentSpec,
        val resource: Resource?,
        val map: Resource?,
        val startOffsetMs: Long,
        val localSequence: Long,
        val localDiscontinuity: Long,
    )
    private data class Retired(val segment: Segment, val expiresAt: Long)

    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private val closeCompleted = CompletableDeferred<Unit>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val calls = Collections.newSetFromMap(ConcurrentHashMap<Call, Boolean>())
    private val sockets = Collections.newSetFromMap(ConcurrentHashMap<Socket, Boolean>())
    private val connectionSlots = Semaphore(MAX_CONCURRENT_LOOPBACK_CONNECTIONS)
    private val segments = ArrayDeque<Segment>()
    private val retired = ArrayDeque<Retired>()
    private val maps = mutableMapOf<String, Resource>()
    private val pinnedMaps = mutableSetOf<Resource>()
    private val resourceIndex = HashMap<String, Resource>(64)
    private val readLeases = mutableMapOf<String, Int>()
    private var cachedPlaylistBytes: ByteArray? = null
    private val server = ServerSocket()
    private val token = UUID.randomUUID().toString()
    private var resourceNumber = 0L
    private var sourceNumber = 0L
    private var totalDurationMs = 0L
    private var windowDurationMs = 0L
    private var nextLocalSequence = 0L
    private var localDiscontinuity = 0L
    private var lastUpstreamSequence: Long? = null
    private var lastUpstreamDiscontinuity: Long? = null
    private val playerSources = linkedMapOf<String, LocalTimeShiftSource>()
    private var diskBytes = 0L
    private var targetDuration = 0
    private var providerTargetDuration = 0
    private var version = 3
    private var independentSegments = false
    private var recording = true
    private var ended = false
    private var notice: String? = null
    private var upstream = originalUrl
    private var lastAdvanceElapsedMs = nowElapsedMs()
    private val snapshotRef = AtomicReference(
        TimeShiftRecordingSnapshot(0L, 0L, true, null, 0L),
    )
    private val sourceOrigin = originalUrl.toHttpUrl()
    private val sessionPool = ConnectionPool(4, 30, TimeUnit.SECONDS)
    private val guardedClient = client.newBuilder()
        .connectionPool(sessionPool)
        .followRedirects(true)
        .followSslRedirects(true)
        .addNetworkInterceptor(CrossOriginHeaderStripInterceptor(sourceOrigin, headers.keys))
        .build()

    val playbackUrl: String get() = "http://127.0.0.1:${server.localPort}/$token/live.m3u8"

    /** Lock-free snapshot safe to poll frequently from the UI/Main thread. */
    fun snapshot(): TimeShiftRecordingSnapshot = snapshotRef.get()

    private fun publishSnapshotLocked() {
        val isClosed = closed.get()
        snapshotRef.set(
            TimeShiftRecordingSnapshot(
                durationMs = if (isClosed) 0L else windowDurationMs,
                bytes = if (isClosed) 0L else diskBytes,
                recording = recording && !isClosed,
                notice = notice,
                windowStartOffsetMs = segments.firstOrNull()?.startOffsetMs ?: totalDurationMs,
            ),
        )
    }

    fun createPlaybackSource(): LocalTimeShiftSource = synchronized(lock) {
        val id = (++sourceNumber).toString()
        LocalTimeShiftSource("$playbackUrl?player=$id").also {
            playerSources[id] = it
            while (playerSources.size > 4) playerSources.remove(playerSources.keys.first())
        }
    }

    private fun start(url: String) {
        val (initial, resolvedUrl, masterIndependent) = fetchMediaPlaylist(url)
        upstream = resolvedUrl
        if (initial.ended) throw UnsupportedTimeShift("This source is not an ongoing live broadcast.")
        targetDuration = maxOf(initial.targetDuration, initial.segments.maxOf { ((it.durationMs + 999) / 1000).toInt() })
        providerTargetDuration = initial.targetDuration
        version = initial.version
        independentSegments = initial.independentSegments || masterIndependent
        if (limits.durationMs < targetDuration * 3_000L) {
            throw UnsupportedTimeShift("The live segments are too long for the recording limit.")
        }
        val selected = selectStartupSegments(initial.segments, targetDuration)
        if (selected.size > limits.segments) throw UnsupportedTimeShift("This source has too many tiny segments for bounded live recording.")
        synchronized(lock) {
            nextLocalSequence = selected.first().sequence
            localDiscontinuity = selected.first().discontinuitySequence
            cachedPlaylistBytes = null
        }
        selected.forEach { append(it, forceDiscontinuity = false) }
        lastAdvanceElapsedMs = nowElapsedMs()
        server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), LOOPBACK_BACKLOG)
        scope.launch { serve() }
        scope.launch { ingest() }
    }

    private fun selectStartupSegments(all: List<RecordedSegmentSpec>, target: Int): List<RecordedSegmentSpec> {
        // Fast single-segment startup for typical 4-10s IPTV segments, up to 3s for 1s test segments.
        val startupTargetMs = minOf(STARTUP_TARGET_DURATION_MS, target * 3_000L)
        var duration = 0L
        val start = all.indices.reversed().firstOrNull { index ->
            duration += all[index].durationMs
            duration >= startupTargetMs
        } ?: 0
        return all.drop(start)
    }

    private data class ResolvedMediaPlaylist(
        val playlist: TimeShiftPlaylist,
        val resolvedUrl: String,
        val masterIndependent: Boolean,
    )

    private fun fetchMediaPlaylist(url: String): ResolvedMediaPlaylist {
        var manifest = fetchManifest(url)
        var playlistUrl = manifest.second
        var masterIndependent = false
        for (depth in 0 until 3) {
            masterIndependent = masterIndependent || manifest.first.lineSequence().any { it.trim() == "#EXT-X-INDEPENDENT-SEGMENTS" }
            val variant = TimeShiftPlaylistParser.variant(manifest.first, playlistUrl) ?: break
            manifest = fetchManifest(variant)
            playlistUrl = manifest.second
        }
        val parsed = TimeShiftPlaylistParser.parse(manifest.first, playlistUrl)
        return ResolvedMediaPlaylist(parsed, playlistUrl, masterIndependent)
    }

    private suspend fun ingest() {
        var failures = 0
        var stuckResolutions = 0
        var immediatePoll = false
        while (scope.isActive && !closed.get()) {
            if (immediatePoll) {
                immediatePoll = false
            } else {
                delay((providerTargetDuration * 500L).coerceIn(500, 8_000))
            }
            try {
                val resolved = fetchMediaPlaylist(upstream)
                val playlist = resolved.playlist
                upstream = resolved.resolvedUrl
                val updatedTarget = maxOf(
                    targetDuration,
                    playlist.targetDuration,
                    playlist.segments.maxOf { ((it.durationMs + 999) / 1000).toInt() },
                )
                if (limits.durationMs < updatedTarget * 3_000L) {
                    throw UnsupportedTimeShift("The live segments are too long for the recording limit.")
                }
                synchronized(lock) {
                    if (targetDuration != updatedTarget) {
                        targetDuration = updatedTarget
                        cachedPlaylistBytes = null
                    }
                    providerTargetDuration = playlist.targetDuration
                }
                val previous = synchronized(lock) { lastUpstreamSequence }
                val latestSeq = playlist.segments.last().sequence
                if (previous != null && latestSeq < previous) {
                    val backwardDelta = previous - latestSeq
                    if (backwardDelta <= MAX_EDGE_SKEW_SEGMENTS) {
                        if (playlist.ended) {
                            stopRecording("The broadcast ended. Its saved history is still available.")
                            return
                        }
                        val stuckThresholdMs = limits.staleManifestTimeoutMs ?: maxOf(MIN_STUCK_MANIFEST_MS, updatedTarget * 3_000L)
                        if (nowElapsedMs() - lastAdvanceElapsedMs >= stuckThresholdMs) {
                            stuckResolutions++
                            upstream = originalUrl
                            lastAdvanceElapsedMs = nowElapsedMs()
                            if (stuckResolutions >= MAX_STUCK_RESOLUTIONS) {
                                stopRecording("Recording stopped because the live playlist stopped updating. Go live to reconnect.")
                                return
                            }
                            immediatePoll = true
                        }
                        failures = 0
                        continue
                    }
                    val restarted = selectStartupSegments(playlist.segments, updatedTarget)
                    restarted.forEachIndexed { index, spec ->
                        append(spec, forceDiscontinuity = index == 0)
                    }
                    lastAdvanceElapsedMs = nowElapsedMs()
                    stuckResolutions = 0
                } else {
                    val additions = playlist.segments.filter { previous == null || it.sequence > previous }
                    if (additions.isNotEmpty()) {
                        val missing = if (previous == null) 0L else additions.first().sequence - previous - 1L
                        if (missing > MAX_BRIDGEABLE_GAP_SEGMENTS) {
                            throw UnsupportedTimeShift("Recording stopped because the source expired footage before it could be saved.")
                        }
                        additions.forEachIndexed { index, spec ->
                            append(spec, forceDiscontinuity = index == 0 && missing > 0L)
                        }
                        lastAdvanceElapsedMs = nowElapsedMs()
                        stuckResolutions = 0
                    } else if (!playlist.ended) {
                        val stuckThresholdMs = limits.staleManifestTimeoutMs ?: maxOf(MIN_STUCK_MANIFEST_MS, updatedTarget * 3_000L)
                        if (nowElapsedMs() - lastAdvanceElapsedMs >= stuckThresholdMs) {
                            stuckResolutions++
                            upstream = originalUrl
                            lastAdvanceElapsedMs = nowElapsedMs()
                            if (stuckResolutions >= MAX_STUCK_RESOLUTIONS) {
                                stopRecording("Recording stopped because the live playlist stopped updating. Go live to reconnect.")
                                return
                            }
                            immediatePoll = true
                        }
                    }
                }
                synchronized(lock) {
                    expireRetired()
                    if (playlist.ended) {
                        recording = false
                        ended = true
                        notice = "The broadcast ended. Its saved history is still available."
                        cachedPlaylistBytes = null
                    }
                    publishSnapshotLocked()
                }
                failures = 0
                if (playlist.ended) return
            } catch (error: Exception) {
                if (closed.get()) return
                if (error is CancellationException) throw error
                if (error is UnsupportedTimeShift) {
                    stopRecording(error.message)
                    return
                }
                runCatching { sessionPool.evictAll() }
                if (error is TimeShiftHttpException && error.statusCode in FAST_FAIL_HTTP_STATUSES) {
                    stopRecording("Recording stopped because the live source returned HTTP ${error.statusCode}. Go live to reconnect.")
                    return
                }
                upstream = originalUrl
                val maxFailures = if (error is TimeShiftHttpException && error.statusCode == 403) 2 else 3
                if (++failures >= maxFailures) {
                    stopRecording("Recording stopped after a network interruption. Go live to reconnect.")
                    return
                }
                delay(failures * 1_000L)
                immediatePoll = true
            }
        }
    }

    private fun stopRecording(message: String?) {
        synchronized(lock) {
            recording = false
            ended = true
            notice = message
            cachedPlaylistBytes = null
            publishSnapshotLocked()
        }
    }

    private fun append(spec: RecordedSegmentSpec, forceDiscontinuity: Boolean) {
        if (closed.get()) throw IOException("Recording closed.")
        val initialization = spec.initializationUrl?.let { uri ->
            synchronized(lock) { maps[uri]?.also(pinnedMaps::add) } ?: download(uri, ".mp4").also {
                synchronized(lock) {
                    maps[uri] = it
                    resourceIndex[it.name] = it
                    pinnedMaps.add(it)
                }
            }
        }
        var appended = false
        try {
            val resource = if (spec.gap) null else download(spec.url, if (initialization == null) ".ts" else ".m4s")
            synchronized(lock) {
                if (closed.get()) throw IOException("Recording closed.")
                val prevUpstreamDisc = lastUpstreamDiscontinuity
                val discDelta = when {
                    forceDiscontinuity -> 1L
                    prevUpstreamDisc == null -> 0L
                    spec.discontinuitySequence == prevUpstreamDisc -> 0L
                    spec.discontinuitySequence > prevUpstreamDisc ->
                        (spec.discontinuitySequence - prevUpstreamDisc).coerceAtMost(4L)
                    else -> 1L
                }
                localDiscontinuity += discDelta
                val assignedSeq = nextLocalSequence++
                lastUpstreamSequence = spec.sequence
                lastUpstreamDiscontinuity = spec.discontinuitySequence
                if (resource != null) {
                    resourceIndex[resource.name] = resource
                }
                segments.addLast(
                    Segment(
                        spec = spec,
                        resource = resource,
                        map = initialization,
                        startOffsetMs = totalDurationMs,
                        localSequence = assignedSeq,
                        localDiscontinuity = localDiscontinuity,
                    ),
                )
                appended = true
                totalDurationMs += spec.durationMs
                windowDurationMs += spec.durationMs
                while (segments.size > 3 && (windowDurationMs > limits.durationMs || segments.size > limits.segments)) retireFirst()
                expireRetired()
                cachedPlaylistBytes = null
                publishSnapshotLocked()
            }
        } finally {
            synchronized(lock) {
                initialization?.let {
                    pinnedMaps.remove(it)
                    if (!appended) cleanMaps()
                }
            }
        }
    }

    private fun fetchManifest(url: String): Pair<String, String> = request(url) { response, call ->
        val contentType = response.header("Content-Type")?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
        if (contentType != null && isNonPlaylistMediaType(contentType)) {
            call.cancel()
            throw UnsupportedTimeShift("This live source is not HLS. Live recording is unavailable.")
        }
        val body = response.body
        if (body.contentLength() > limits.manifestBytes) throw UnsupportedTimeShift("The HLS playlist exceeds the recording size limit.")
        val output = ByteArrayOutputStream()
        var verifiedHeader = false
        body.byteStream().use { input ->
            val buffer = ByteArray(4 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size().toLong() + read > limits.manifestBytes) {
                    call.cancel()
                    throw UnsupportedTimeShift("The HLS playlist exceeds the recording size limit.")
                }
                output.write(buffer, 0, read)
                if (!verifiedHeader) {
                    when (sniffHlsHeader(output.toByteArray())) {
                        HeaderSniff.VALID -> verifiedHeader = true
                        HeaderSniff.INVALID -> {
                            call.cancel()
                            throw UnsupportedTimeShift("This live source is not HLS. Live recording is unavailable.")
                        }
                        HeaderSniff.NEED_MORE -> if (output.size() >= MAX_HEADER_SNIFF_BYTES) {
                            call.cancel()
                            throw UnsupportedTimeShift("This live source is not HLS. Live recording is unavailable.")
                        }
                    }
                }
            }
        }
        if (!verifiedHeader) {
            throw UnsupportedTimeShift("This live source is not HLS. Live recording is unavailable.")
        }
        output.toByteArray().toString(Charsets.UTF_8) to response.request.url.toString()
    }

    private fun download(url: String, suffix: String): Resource = request(url) { response, _ ->
        val body = response.body
        if (body.contentLength() > limits.segmentBytes) throw UnsupportedTimeShift("A live segment exceeds the recording size limit.")
        val name = synchronized(lock) {
            if (closed.get()) throw IOException("Recording closed.")
            "resource-${++resourceNumber}$suffix"
        }
        val part = File(directory, "$name.part")
        var written = 0L
        try {
            synchronized(lock) {
                if (closed.get()) throw IOException("Recording closed.")
                part.createNewFile()
            }
            part.outputStream().use { output ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var bytesSinceUsableSpaceCheck = USABLE_SPACE_CHECK_INTERVAL_BYTES
                    var lastSnapshotElapsedMs = nowElapsedMs()
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (written + read > limits.segmentBytes) throw UnsupportedTimeShift("A live segment exceeds the recording size limit.")
                        val checkUsableSpace = bytesSinceUsableSpaceCheck >= USABLE_SPACE_CHECK_INTERVAL_BYTES
                        if (checkUsableSpace) bytesSinceUsableSpaceCheck = 0L
                        bytesSinceUsableSpaceCheck += read
                        val now = nowElapsedMs()
                        val shouldPublish = now - lastSnapshotElapsedMs >= SNAPSHOT_PUBLISH_INTERVAL_MS
                        synchronized(lock) {
                            if (closed.get()) throw IOException("Recording closed.")
                            reserve(read.toLong(), checkUsableSpace = checkUsableSpace)
                            diskBytes += read
                            if (shouldPublish) {
                                lastSnapshotElapsedMs = now
                                publishSnapshotLocked()
                            }
                        }
                        written += read
                        output.write(buffer, 0, read)
                    }
                }
            }
            if (written == 0L) throw IOException("The live source returned an empty segment.")
            val file = File(directory, name)
            synchronized(lock) {
                if (closed.get() || !part.renameTo(file)) throw IOException("The live buffer could not be saved.")
                publishSnapshotLocked()
            }
            Resource(name, file, written)
        } catch (error: Exception) {
            synchronized(lock) {
                part.delete()
                diskBytes = (diskBytes - written).coerceAtLeast(0)
                publishSnapshotLocked()
            }
            throw error
        }
    }

    private fun reserve(bytes: Long, checkUsableSpace: Boolean) {
        expireRetired()
        while (diskBytes + bytes > limits.bytes && deleteRetired(force = true)) { }
        while (diskBytes + bytes > limits.bytes && segments.size > 3) {
            retireFirst()
            while (diskBytes + bytes > limits.bytes && deleteRetired(force = true)) { }
        }
        if (diskBytes + bytes > limits.bytes || (checkUsableSpace && directory.usableSpace < bytes + 16L * 1024 * 1024)) {
            throw UnsupportedTimeShift("The temporary live buffer reached its storage limit. Go live to restart recording.")
        }
    }

    private fun retireFirst() {
        val removed = segments.removeFirst()
        windowDurationMs = (windowDurationMs - removed.spec.durationMs).coerceAtLeast(0L)
        retired.addLast(Retired(removed, System.currentTimeMillis() + maxOf(5_000, targetDuration * 2_000L)))
        cachedPlaylistBytes = null
    }

    private fun expireRetired() {
        while (deleteRetired(force = false)) { }
    }

    private fun deleteRetired(force: Boolean): Boolean {
        if (retired.isEmpty()) return false
        val index = retired.indexOfFirst {
            (force || it.expiresAt <= System.currentTimeMillis()) && (readLeases[it.segment.resource?.name] ?: 0) == 0
        }
        if (index < 0) return false
        retired.removeAt(index).segment.resource?.let(::deleteResource)
        cleanMaps()
        return true
    }

    private fun cleanMaps() {
        val referenced = (segments.mapNotNull { it.map } + retired.mapNotNull { it.segment.map } + pinnedMaps).toSet()
        maps.entries.removeAll { (_, resource) ->
            if (resource in referenced || (readLeases[resource.name] ?: 0) > 0) false else {
                deleteResource(resource)
                true
            }
        }
    }

    private fun deleteResource(resource: Resource) {
        resourceIndex.remove(resource.name)
        if (resource.file.delete() || !resource.file.exists()) diskBytes = (diskBytes - resource.bytes).coerceAtLeast(0)
    }

    private fun playlistLocked(): ByteArray {
        cachedPlaylistBytes?.let { return it }
        val built = buildString {
            append("#EXTM3U\n#EXT-X-VERSION:$version\n#EXT-X-TARGETDURATION:$targetDuration\n")
            if (independentSegments) append("#EXT-X-INDEPENDENT-SEGMENTS\n")
            val first = segments.firstOrNull() ?: return ByteArray(0)
            append("#EXT-X-MEDIA-SEQUENCE:${first.localSequence}\n#EXT-X-DISCONTINUITY-SEQUENCE:${first.localDiscontinuity}\n")
            var discontinuity = first.localDiscontinuity
            var initialization: Resource? = null
            segments.forEach { segment ->
                val discCount = (segment.localDiscontinuity - discontinuity).toInt().coerceAtLeast(0)
                if (discCount > 0) {
                    repeat(discCount) { append("#EXT-X-DISCONTINUITY\n") }
                    initialization = null
                }
                discontinuity = segment.localDiscontinuity
                if (segment.map != initialization && segment.map != null) {
                    append("#EXT-X-MAP:URI=\"${segment.map.name}\"\n")
                    initialization = segment.map
                }
                segment.spec.programDateTime?.let { append("#EXT-X-PROGRAM-DATE-TIME:$it\n") }
                if (segment.spec.gap) append("#EXT-X-GAP\n")
                append("#EXTINF:${segment.spec.durationMs / 1000.0},\n")
                append(segment.resource?.name ?: "gap-${segment.localSequence}.ts")
                append('\n')
            }
            if (ended) append("#EXT-X-ENDLIST\n")
        }.toByteArray(Charsets.UTF_8)
        cachedPlaylistBytes = built
        return built
    }

    private fun serve() {
        while (!closed.get()) {
            val socket = try {
                server.accept()
            } catch (_: SocketException) {
                if (closed.get() || server.isClosed) return
                continue
            } catch (_: IOException) {
                if (closed.get() || server.isClosed) return
                continue
            }
            if (closed.get()) {
                runCatching { socket.close() }
                return
            }
            sockets.add(socket)
            scope.launch(Dispatchers.IO) {
                try {
                    connectionSlots.withPermit {
                        socket.use { respond(it) }
                    }
                } catch (_: IOException) {
                    // A native player may cancel a seek or manifest request.
                } finally {
                    sockets.remove(socket)
                    runCatching { socket.close() }
                }
            }
        }
    }

    private fun respond(socket: Socket) {
        socket.tcpNoDelay = true
        socket.soTimeout = LOOPBACK_KEEPALIVE_TIMEOUT_MS
        val input = BufferedInputStream(socket.getInputStream(), 8 * 1024)
        val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
        val headerBuffer = ByteArrayOutputStream(512)
        val copyBuffer = ByteArray(64 * 1024)
        var requestsServed = 0

        while (!closed.get() && requestsServed < MAX_KEEPALIVE_REQUESTS_PER_SOCKET) {
            headerBuffer.reset()
            var tail = 0
            var eof = false
            try {
                while (headerBuffer.size() < 8_192) {
                    val next = input.read()
                    if (next < 0) {
                        eof = true
                        break
                    }
                    headerBuffer.write(next)
                    tail = (tail shl 8) or next
                    if (tail == 0x0d0a0d0a) break
                }
            } catch (_: SocketTimeoutException) {
                return
            }
            if (eof || tail != 0x0d0a0d0a) return
            requestsServed++

            val lines = headerBuffer.toString("US-ASCII").split("\r\n")
            val request = lines.first().split(' ')
            val method = request.getOrNull(0)
            val fullPath = request.getOrNull(1)
            val protocol = request.getOrNull(2).orEmpty()
            val connectionHeader = lines.firstOrNull { it.startsWith("Connection:", ignoreCase = true) }
                ?.substringAfter(':')?.trim()?.lowercase(Locale.ROOT)
            val keepAlive = when {
                connectionHeader == "close" -> false
                connectionHeader == "keep-alive" -> true
                protocol.equals("HTTP/1.1", ignoreCase = true) -> true
                else -> false
            } && !closed.get() && requestsServed < MAX_KEEPALIVE_REQUESTS_PER_SOCKET

            val path = fullPath?.substringBefore('?')
            if (method !in ALLOWED_METHODS || path?.startsWith("/$token/") != true) {
                reply(output, 404, "Not Found", 0, keepAlive = false)
                output.flush()
                return
            }
            val resource = path.removePrefix("/$token/")
            if (resource == "live.m3u8") {
                val body = synchronized(lock) {
                    val id = fullPath.orEmpty().substringAfter('?', "").split('&')
                        .firstOrNull { it.startsWith("player=") }?.substringAfter('=')
                    playerSources[id]?.let { source ->
                        if (source.windowStartOffsetMs == null) source.windowStartOffsetMs = segments.firstOrNull()?.startOffsetMs
                    }
                    playlistLocked()
                }
                reply(output, 200, "OK", body.size.toLong(), "application/vnd.apple.mpegurl", keepAlive = keepAlive)
                if (method == "GET") output.write(body)
                output.flush()
                if (!keepAlive) return
                continue
            }

            val stored = synchronized(lock) {
                resourceIndex[resource]?.takeIf { it.file.isFile }?.also {
                    readLeases[it.name] = (readLeases[it.name] ?: 0) + 1
                }
            }
            if (stored == null) {
                // Old native playlist requests can outlive the bounded grace period.
                reply(output, 410, "Gone", 0, keepAlive = false)
                output.flush()
                return
            }
            try {
                val file = stored.file
                val length = file.length()
                val range = lines.firstOrNull { it.startsWith("Range:", true) }?.substringAfter(':')?.trim()
                val requested = range?.let { RANGE_REGEX.matchEntire(it) }
                val start = requested?.groupValues?.get(1)?.toLongOrNull() ?: 0
                val end = requested?.groupValues?.get(2)?.toLongOrNull() ?: (length - 1)
                if (range != null && (requested == null || start !in 0 until length || end < start || end >= length)) {
                    reply(output, 416, "Range Not Satisfiable", 0, keepAlive = false)
                    output.flush()
                    return
                }
                val count = end - start + 1
                reply(
                    output,
                    if (range == null) 200 else 206,
                    if (range == null) "OK" else "Partial Content",
                    count,
                    extra = if (range == null) "Accept-Ranges: bytes\r\n" else "Accept-Ranges: bytes\r\nContent-Range: bytes $start-$end/$length\r\n",
                    keepAlive = keepAlive,
                )
                if (method == "GET") file.inputStream().use { source ->
                    var skipped = 0L
                    while (skipped < start) {
                        val progress = source.skip(start - skipped)
                        if (progress <= 0) throw IOException("The live buffer range could not be read.")
                        skipped += progress
                    }
                    var remaining = count
                    while (remaining > 0) {
                        val read = source.read(copyBuffer, 0, minOf(copyBuffer.size.toLong(), remaining).toInt())
                        if (read <= 0) break
                        output.write(copyBuffer, 0, read)
                        remaining -= read
                    }
                }
                output.flush()
            } finally {
                synchronized(lock) {
                    val remaining = (readLeases[stored.name] ?: 1) - 1
                    if (remaining <= 0) readLeases.remove(stored.name) else readLeases[stored.name] = remaining
                    expireRetired()
                    if (remaining <= 0 && maps.values.any { it.name == stored.name }) {
                        cleanMaps()
                    }
                    publishSnapshotLocked()
                }
            }
            if (!keepAlive) return
        }
    }

    private fun reply(
        output: BufferedOutputStream,
        code: Int,
        reason: String,
        length: Long,
        type: String = "application/octet-stream",
        extra: String = "",
        keepAlive: Boolean,
    ) {
        val conn = if (keepAlive) "Connection: keep-alive\r\nKeep-Alive: timeout=15\r\n" else "Connection: close\r\n"
        output.write(
            ("HTTP/1.1 $code $reason\r\nContent-Length: $length\r\n" +
                "Content-Type: $type\r\nCache-Control: no-store\r\n$conn$extra\r\n").toByteArray(Charsets.US_ASCII),
        )
    }

    private fun <T> request(url: String, block: (okhttp3.Response, Call) -> T): T {
        if (closed.get()) throw IOException("Recording closed.")
        val builder = Request.Builder()
            .url(url)
            .header("User-Agent", CatalogRepository.USER_AGENT)
            .header("Cache-Control", "no-cache")
        val target = url.toHttpUrl()
        val sameOrigin = target.scheme == sourceOrigin.scheme && target.host == sourceOrigin.host && target.port == sourceOrigin.port
        headers.filter { (name, _) -> sameOrigin || name.equals("User-Agent", true) }
            .forEach { (name, value) -> builder.header(name, value) }
        val call = guardedClient.newCall(builder.build())
        calls.add(call)
        try {
            if (closed.get()) {
                call.cancel()
                throw IOException("Recording closed.")
            }
            return call.execute().use { response ->
                if (!response.isSuccessful) throw TimeShiftHttpException(response.code)
                block(response, call)
            }
        } finally {
            calls.remove(call)
        }
    }

    /** Non-blocking close safe for the Android Main thread; tears down network and disk asynchronously. */
    fun closeAsync(): Job {
        if (closed.compareAndSet(false, true)) {
            snapshotRef.set(TimeShiftRecordingSnapshot(0L, 0L, false, snapshotRef.get().notice, snapshotRef.get().windowStartOffsetMs))
            scope.cancel()
            cleanupScope.launch { finishClose() }
        }
        return closeCompleted
    }

    override fun close() {
        if (isAndroidMainThread()) {
            closeAsync()
            return
        }
        if (!closed.compareAndSet(false, true)) return
        snapshotRef.set(TimeShiftRecordingSnapshot(0L, 0L, false, snapshotRef.get().notice, snapshotRef.get().windowStartOffsetMs))
        scope.cancel()
        finishClose()
    }

    private fun finishClose() {
        try {
            calls.forEach { runCatching { it.cancel() } }
            sockets.forEach { runCatching { it.close() } }
            runCatching { server.close() }
            runCatching { sessionPool.evictAll() }
            synchronized(lock) {
                segments.clear()
                retired.clear()
                maps.clear()
                pinnedMaps.clear()
                resourceIndex.clear()
                readLeases.clear()
                playerSources.clear()
                cachedPlaylistBytes = null
                directory.deleteRecursively()
                diskBytes = 0
                windowDurationMs = 0L
                recording = false
                publishSnapshotLocked()
                activeDirectories.remove(directory.absolutePath)
            }
        } finally {
            closeCompleted.complete(Unit)
        }
    }

    private enum class HeaderSniff { VALID, INVALID, NEED_MORE }

    companion object {
        private const val STARTUP_TARGET_DURATION_MS = 4_000L
        private const val MIN_STUCK_MANIFEST_MS = 20_000L
        private const val MAX_STUCK_RESOLUTIONS = 2
        private const val MAX_BRIDGEABLE_GAP_SEGMENTS = 2L
        private const val MAX_EDGE_SKEW_SEGMENTS = 3L
        private const val MAX_CONCURRENT_LOOPBACK_CONNECTIONS = 16
        private const val LOOPBACK_BACKLOG = 16
        private const val LOOPBACK_KEEPALIVE_TIMEOUT_MS = 15_000
        private const val MAX_KEEPALIVE_REQUESTS_PER_SOCKET = 256
        private const val MAX_HEADER_SNIFF_BYTES = 1024
        private const val USABLE_SPACE_CHECK_INTERVAL_BYTES = 1024L * 1024L
        private const val SNAPSHOT_PUBLISH_INTERVAL_MS = 250L
        private val ALLOWED_METHODS = setOf("GET", "HEAD")
        private val RANGE_REGEX = Regex("bytes=(\\d+)-(\\d*)")
        private val SESSION_DIR_REGEX = Regex("session-[a-f0-9-]{36}")
        private val FAST_FAIL_HTTP_STATUSES = setOf(401, 404, 410)
        private val HLS_MAGIC = "#EXTM3U".toByteArray(Charsets.US_ASCII)

        private val activeDirectories = Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())
        private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val defaultClient = OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS)
            .build()

        private fun nowElapsedMs(): Long = System.nanoTime() / 1_000_000L

        private fun isAndroidMainThread(): Boolean = runCatching {
            val mainLooper = Looper.getMainLooper()
            mainLooper != null && Looper.myLooper() === mainLooper
        }.getOrDefault(false)

        private fun isNonPlaylistMediaType(contentType: String): Boolean =
            contentType.startsWith("video/") ||
                contentType.startsWith("image/") ||
                (contentType.startsWith("audio/") &&
                    contentType != "audio/mpegurl" &&
                    contentType != "audio/x-mpegurl")

        private fun sniffHlsHeader(bytes: ByteArray): HeaderSniff {
            var offset = 0
            if (bytes.size >= 3 &&
                bytes[0] == 0xEF.toByte() &&
                bytes[1] == 0xBB.toByte() &&
                bytes[2] == 0xBF.toByte()
            ) {
                offset = 3
            } else if (bytes.size < 3 && bytes.isNotEmpty() && bytes[0] == 0xEF.toByte()) {
                return HeaderSniff.NEED_MORE
            }
            while (offset < bytes.size) {
                val b = bytes[offset].toInt() and 0xFF
                if (b == ' '.code || b == '\t'.code || b == '\r'.code || b == '\n'.code) {
                    offset++
                } else {
                    break
                }
            }
            if (offset >= bytes.size) return HeaderSniff.NEED_MORE
            val remaining = bytes.size - offset
            val checkLength = minOf(remaining, HLS_MAGIC.size)
            for (i in 0 until checkLength) {
                if (bytes[offset + i] != HLS_MAGIC[i]) return HeaderSniff.INVALID
            }
            return if (remaining >= HLS_MAGIC.size) HeaderSniff.VALID else HeaderSniff.NEED_MORE
        }

        suspend fun open(
            root: File,
            url: String,
            headers: Map<String, String>,
            limits: TimeShiftLimits = TimeShiftLimits(),
            client: OkHttpClient = defaultClient,
        ): HlsTimeShiftSession = suspendCancellableCoroutine { continuation ->
            val owned = AtomicReference<HlsTimeShiftSession?>()
            val startup = CoroutineScope(Dispatchers.IO).launch {
                try {
                    require(limits.bytes > 0 && limits.durationMs > 0 && limits.segmentBytes > 0 && limits.manifestBytes > 0 && limits.segments >= 3)
                    url.toHttpUrl()
                    synchronized(activeDirectories) {
                        root.mkdirs()
                        root.listFiles()?.filter { it.isDirectory && SESSION_DIR_REGEX.matches(it.name) && it.absolutePath !in activeDirectories }
                            ?.forEach(File::deleteRecursively)
                        val directory = File(root, "session-${UUID.randomUUID()}")
                        if (!directory.mkdirs()) throw IOException("The temporary live buffer could not be created.")
                        activeDirectories.add(directory.absolutePath)
                        owned.set(HlsTimeShiftSession(directory, headers, limits, client, url))
                    }
                    val session = owned.get() ?: return@launch
                    if (!continuation.isActive) {
                        session.close()
                        return@launch
                    }
                    session.start(url)
                    continuation.resume(session) { _, resource, _ -> resource.close() }
                    owned.set(null)
                } catch (error: Exception) {
                    owned.getAndSet(null)?.close()
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
            continuation.invokeOnCancellation {
                owned.getAndSet(null)?.closeAsync()
                startup.cancel()
            }
        }
    }
}
