package com.bvolpato.brutv.playback

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.UUID
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl

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
    sourceUrl: String,
) : Closeable {
    private data class Resource(val name: String, val file: File, val bytes: Long)
    private data class Segment(val spec: RecordedSegmentSpec, val resource: Resource?, val map: Resource?, val startOffsetMs: Long)
    private data class Retired(val segment: Segment, val expiresAt: Long)

    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val calls = Collections.newSetFromMap(ConcurrentHashMap<Call, Boolean>())
    private val sockets = Collections.newSetFromMap(ConcurrentHashMap<Socket, Boolean>())
    private val segments = ArrayDeque<Segment>()
    private val retired = ArrayDeque<Retired>()
    private val maps = mutableMapOf<String, Resource>()
    private val pinnedMaps = mutableSetOf<Resource>()
    private val readLeases = mutableMapOf<String, Int>()
    private val server = ServerSocket()
    private val token = UUID.randomUUID().toString()
    private var resourceNumber = 0L
    private var sourceNumber = 0L
    private var totalDurationMs = 0L
    private val playerSources = linkedMapOf<String, LocalTimeShiftSource>()
    private var diskBytes = 0L
    private var targetDuration = 0
    private var providerTargetDuration = 0
    private var version = 3
    private var independentSegments = false
    private var recording = true
    private var ended = false
    private var notice: String? = null
    private var upstream = ""
    private val sourceOrigin = sourceUrl.toHttpUrl()
    private val guardedClient = client.newBuilder().addNetworkInterceptor { chain ->
        val request = chain.request()
        val actual = request.url
        val sameOrigin = actual.scheme == sourceOrigin.scheme && actual.host == sourceOrigin.host && actual.port == sourceOrigin.port
        val safe = if (sameOrigin) request else request.newBuilder().apply {
            headers.keys.filterNot { it.equals("User-Agent", true) }.forEach(::removeHeader)
        }.build()
        chain.proceed(safe)
    }.build()

    val playbackUrl: String get() = "http://127.0.0.1:${server.localPort}/$token/live.m3u8"

    fun snapshot(): TimeShiftRecordingSnapshot = synchronized(lock) {
        TimeShiftRecordingSnapshot(segments.sumOf { it.spec.durationMs }, diskBytes, recording && !closed.get(), notice,
            segments.firstOrNull()?.startOffsetMs ?: totalDurationMs)
    }

    fun createPlaybackSource(): LocalTimeShiftSource = synchronized(lock) {
        val id = (++sourceNumber).toString()
        LocalTimeShiftSource("$playbackUrl?player=$id").also {
            playerSources[id] = it
            while (playerSources.size > 4) playerSources.remove(playerSources.keys.first())
        }
    }

    private fun start(url: String) {
        var manifest = fetchManifest(url)
        var playlistUrl = manifest.second
        var masterIndependent = false
        for (depth in 0 until 3) {
            masterIndependent = masterIndependent || manifest.first.lineSequence().any { it.trim() == "#EXT-X-INDEPENDENT-SEGMENTS" }
            val variant = TimeShiftPlaylistParser.variant(manifest.first, playlistUrl) ?: break
            manifest = fetchManifest(variant)
            playlistUrl = manifest.second
        }
        upstream = playlistUrl
        val initial = TimeShiftPlaylistParser.parse(manifest.first, playlistUrl)
        if (initial.ended) throw UnsupportedTimeShift("This source is not an ongoing live broadcast.")
        targetDuration = maxOf(initial.targetDuration, initial.segments.maxOf { ((it.durationMs + 999) / 1000).toInt() })
        providerTargetDuration = initial.targetDuration
        version = initial.version
        independentSegments = initial.independentSegments || masterIndependent
        if (limits.durationMs < targetDuration * 3_000L) {
            throw UnsupportedTimeShift("The live segments are too long for the recording limit.")
        }
        // Begin with the source's normal three-segment holdback, then grow the local history.
        var duration = 0L
        val start = initial.segments.indices.reversed().firstOrNull { index ->
            duration += initial.segments[index].durationMs
            duration >= targetDuration * 3_000L
        } ?: 0
        val selected = initial.segments.drop(start)
        if (selected.size > limits.segments) throw UnsupportedTimeShift("This source has too many tiny segments for bounded live recording.")
        selected.forEach(::append)
        server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 4)
        scope.launch { serve() }
        scope.launch { ingest() }
    }

    private suspend fun ingest() {
        var failures = 0
        while (scope.isActive && !closed.get()) {
            delay((providerTargetDuration * 500L).coerceIn(500, 8_000))
            try {
                val manifest = fetchManifest(upstream)
                val playlist = TimeShiftPlaylistParser.parse(manifest.first, manifest.second)
                val updatedTarget = maxOf(targetDuration, playlist.targetDuration,
                    playlist.segments.maxOf { ((it.durationMs + 999) / 1000).toInt() })
                if (limits.durationMs < updatedTarget * 3_000L) {
                    throw UnsupportedTimeShift("The live segments are too long for the recording limit.")
                }
                synchronized(lock) {
                    targetDuration = updatedTarget
                    providerTargetDuration = playlist.targetDuration
                }
                val previous = synchronized(lock) { segments.lastOrNull()?.spec?.sequence }
                if (previous != null && playlist.segments.last().sequence < previous) {
                    throw UnsupportedTimeShift("Recording stopped because the live source restarted.")
                }
                val additions = playlist.segments.filter { previous == null || it.sequence > previous }
                if (previous != null && additions.firstOrNull()?.sequence?.let { it != previous + 1 } == true) {
                    throw UnsupportedTimeShift("Recording stopped because the source expired footage before it could be saved.")
                }
                val previousDiscontinuity = synchronized(lock) { segments.lastOrNull()?.spec?.discontinuitySequence }
                if (previousDiscontinuity != null && additions.firstOrNull()?.discontinuitySequence?.let { it - previousDiscontinuity !in 0..4 } == true) {
                    throw UnsupportedTimeShift("Recording stopped because the live source reset its timeline.")
                }
                additions.forEach(::append)
                synchronized(lock) {
                    expireRetired()
                    if (playlist.ended) {
                        recording = false
                        ended = true
                        notice = "The broadcast ended. Its saved history is still available."
                    }
                }
                failures = 0
                if (playlist.ended) return
            } catch (error: Exception) {
                if (closed.get()) return
                if (error is UnsupportedTimeShift || ++failures >= 3) {
                    synchronized(lock) {
                        recording = false
                        ended = true
                        notice = if (error is UnsupportedTimeShift) error.message else "Recording stopped after a network interruption. Go live to reconnect."
                    }
                    return
                }
                delay(failures * 1_000L)
            }
        }
    }

    private fun append(spec: RecordedSegmentSpec) {
        if (closed.get()) throw IOException("Recording closed.")
        val initialization = spec.initializationUrl?.let { uri ->
            synchronized(lock) { maps[uri]?.also(pinnedMaps::add) } ?: download(uri, ".mp4").also {
                synchronized(lock) {
                    maps[uri] = it
                    pinnedMaps.add(it)
                }
            }
        }
        try {
            val resource = if (spec.gap) null else download(spec.url, if (initialization == null) ".ts" else ".m4s")
            synchronized(lock) {
                if (closed.get()) throw IOException("Recording closed.")
                segments.addLast(Segment(spec, resource, initialization, totalDurationMs))
                totalDurationMs += spec.durationMs
                while (segments.size > 3 && (segments.sumOf { it.spec.durationMs } > limits.durationMs || segments.size > limits.segments)) retireFirst()
                expireRetired()
            }
        } finally {
            synchronized(lock) { initialization?.let(pinnedMaps::remove) }
        }
    }

    private fun fetchManifest(url: String): Pair<String, String> = request(url) { response ->
        val body = response.body ?: throw IOException("The live source returned an empty response.")
        if (body.contentLength() > limits.manifestBytes) throw UnsupportedTimeShift("The HLS playlist exceeds the recording size limit.")
        val output = java.io.ByteArrayOutputStream()
        body.byteStream().use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size().toLong() + read > limits.manifestBytes) {
                    throw UnsupportedTimeShift("The HLS playlist exceeds the recording size limit.")
                }
                output.write(buffer, 0, read)
            }
        }
        output.toByteArray().toString(Charsets.UTF_8) to response.request.url.toString()
    }

    private fun download(url: String, suffix: String): Resource = request(url) { response ->
        val body = response.body ?: throw IOException("The live source returned an empty segment.")
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
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (written + read > limits.segmentBytes) throw UnsupportedTimeShift("A live segment exceeds the recording size limit.")
                        synchronized(lock) {
                            if (closed.get()) throw IOException("Recording closed.")
                            reserve(read.toLong())
                            diskBytes += read
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
            }
            Resource(name, file, written)
        } catch (error: Exception) {
            synchronized(lock) {
                part.delete()
                diskBytes = (diskBytes - written).coerceAtLeast(0)
            }
            throw error
        }
    }

    private fun reserve(bytes: Long) {
        expireRetired()
        while (diskBytes + bytes > limits.bytes && deleteRetired(force = true)) { }
        while (diskBytes + bytes > limits.bytes && segments.size > 3) {
            retireFirst()
            while (diskBytes + bytes > limits.bytes && deleteRetired(force = true)) { }
        }
        if (diskBytes + bytes > limits.bytes || directory.usableSpace < bytes + 16L * 1024 * 1024) {
            throw UnsupportedTimeShift("The temporary live buffer reached its storage limit. Go live to restart recording.")
        }
    }

    private fun retireFirst() {
        retired.addLast(Retired(segments.removeFirst(), System.currentTimeMillis() + maxOf(5_000, targetDuration * 2_000L)))
    }

    private fun expireRetired() {
        while (deleteRetired(force = false)) { }
        cleanMaps()
    }

    private fun deleteRetired(force: Boolean): Boolean {
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
        if (resource.file.delete() || !resource.file.exists()) diskBytes = (diskBytes - resource.bytes).coerceAtLeast(0)
    }

    private fun playlist(): ByteArray = synchronized(lock) {
        buildString {
            append("#EXTM3U\n#EXT-X-VERSION:$version\n#EXT-X-TARGETDURATION:$targetDuration\n")
            if (independentSegments) append("#EXT-X-INDEPENDENT-SEGMENTS\n")
            val first = segments.firstOrNull() ?: return@synchronized ByteArray(0)
            append("#EXT-X-MEDIA-SEQUENCE:${first.spec.sequence}\n#EXT-X-DISCONTINUITY-SEQUENCE:${first.spec.discontinuitySequence}\n")
            var discontinuity = first.spec.discontinuitySequence
            var initialization: Resource? = null
            segments.forEach { segment ->
                repeat((segment.spec.discontinuitySequence - discontinuity).toInt()) { append("#EXT-X-DISCONTINUITY\n") }
                discontinuity = segment.spec.discontinuitySequence
                if (segment.map != initialization && segment.map != null) {
                    append("#EXT-X-MAP:URI=\"${segment.map.name}\"\n")
                    initialization = segment.map
                }
                segment.spec.programDateTime?.let { append("#EXT-X-PROGRAM-DATE-TIME:$it\n") }
                if (segment.spec.gap) append("#EXT-X-GAP\n")
                append("#EXTINF:${segment.spec.durationMs / 1000.0},\n")
                append(segment.resource?.name ?: "gap-${segment.spec.sequence}.ts")
                append('\n')
            }
            if (ended) append("#EXT-X-ENDLIST\n")
        }.toByteArray(Charsets.UTF_8)
    }

    private fun serve() {
        while (!closed.get()) {
            val socket = try { server.accept() } catch (_: SocketException) { return }
            sockets.add(socket)
            try {
                socket.use { respond(it) }
            } catch (_: IOException) {
                // A native player may cancel a seek or manifest request.
            } finally {
                sockets.remove(socket)
            }
        }
    }

    private fun respond(socket: Socket) {
        socket.soTimeout = 3_000
        val input = socket.getInputStream().buffered()
        val bytes = java.io.ByteArrayOutputStream()
        var tail = 0
        while (bytes.size() < 8_192) {
            val next = input.read()
            if (next < 0) return
            bytes.write(next)
            tail = (tail shl 8) or next
            if (tail == 0x0d0a0d0a) break
        }
        if (tail != 0x0d0a0d0a) return
        val lines = bytes.toString("US-ASCII").split("\r\n")
        val request = lines.first().split(' ')
        val method = request.getOrNull(0)
        val fullPath = request.getOrNull(1)
        val path = fullPath?.substringBefore('?')
        if (method !in setOf("GET", "HEAD") || path?.startsWith("/$token/") != true) {
            reply(socket, 404, "Not Found", 0)
            return
        }
        val resource = path.removePrefix("/$token/")
        if (resource == "live.m3u8") {
            val body = synchronized(lock) {
                val id = fullPath.orEmpty().substringAfter('?', "").split('&').firstOrNull { it.startsWith("player=") }?.substringAfter('=')
                playerSources[id]?.let { source ->
                    if (source.windowStartOffsetMs == null) source.windowStartOffsetMs = segments.firstOrNull()?.startOffsetMs
                }
                playlist()
            }
            reply(socket, 200, "OK", body.size.toLong(), "application/vnd.apple.mpegurl")
            if (method == "GET") socket.getOutputStream().write(body)
            return
        }
        val stored = synchronized(lock) {
            (segments.mapNotNull { it.resource } + maps.values + retired.mapNotNull { it.segment.resource })
                .firstOrNull { it.name == resource }?.takeIf { it.file.isFile }?.also {
                    readLeases[it.name] = (readLeases[it.name] ?: 0) + 1
                }
        }
        if (stored == null) {
            // Old native playlist requests can outlive the bounded grace period.
            reply(socket, 410, "Gone", 0)
            return
        }
        try {
            val file = stored.file
            val length = file.length()
            val range = lines.firstOrNull { it.startsWith("Range:", true) }?.substringAfter(':')?.trim()
            val requested = range?.let { Regex("bytes=(\\d+)-(\\d*)").matchEntire(it) }
            val start = requested?.groupValues?.get(1)?.toLongOrNull() ?: 0
            val end = requested?.groupValues?.get(2)?.toLongOrNull() ?: (length - 1)
            if (range != null && (requested == null || start !in 0 until length || end < start || end >= length)) {
                reply(socket, 416, "Range Not Satisfiable", 0)
                return
            }
            val count = end - start + 1
            reply(socket, if (range == null) 200 else 206, if (range == null) "OK" else "Partial Content", count,
                extra = if (range == null) "Accept-Ranges: bytes\r\n" else "Accept-Ranges: bytes\r\nContent-Range: bytes $start-$end/$length\r\n")
            if (method == "GET") file.inputStream().use { source ->
                var skipped = 0L
                while (skipped < start) {
                    val progress = source.skip(start - skipped)
                    if (progress <= 0) throw IOException("The live buffer range could not be read.")
                    skipped += progress
                }
                var remaining = count
                val buffer = ByteArray(64 * 1024)
                while (remaining > 0) {
                    val read = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (read <= 0) break
                    socket.getOutputStream().write(buffer, 0, read)
                    remaining -= read
                }
            }
        } finally {
            synchronized(lock) {
                val remaining = (readLeases[stored.name] ?: 1) - 1
                if (remaining <= 0) readLeases.remove(stored.name) else readLeases[stored.name] = remaining
                expireRetired()
            }
        }
    }

    private fun reply(socket: Socket, code: Int, reason: String, length: Long,
        type: String = "application/octet-stream", extra: String = "") {
        socket.getOutputStream().write(("HTTP/1.1 $code $reason\r\nContent-Length: $length\r\n" +
            "Content-Type: $type\r\nCache-Control: no-store\r\nConnection: close\r\n$extra\r\n").toByteArray(Charsets.US_ASCII))
    }

    private fun <T> request(url: String, block: (okhttp3.Response) -> T): T {
        if (closed.get()) throw IOException("Recording closed.")
        val builder = Request.Builder().url(url).header("User-Agent", "BruTV Android/1.0").header("Cache-Control", "no-cache")
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
                if (!response.isSuccessful) throw IOException("The live source returned HTTP ${response.code}.")
                block(response)
            }
        } finally {
            calls.remove(call)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        calls.forEach(Call::cancel)
        sockets.forEach { runCatching { it.close() } }
        runCatching { server.close() }
        scope.cancel()
        synchronized(lock) {
            segments.clear()
            retired.clear()
            maps.clear()
            pinnedMaps.clear()
            readLeases.clear()
            playerSources.clear()
            directory.deleteRecursively()
            diskBytes = 0
            recording = false
            activeDirectories.remove(directory.absolutePath)
        }
    }

    companion object {
        private val activeDirectories = Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(12, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS)
            .callTimeout(25, TimeUnit.SECONDS).build()

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
                        root.listFiles()?.filter { it.isDirectory && it.name.matches(Regex("session-[a-f0-9-]{36}")) && it.absolutePath !in activeDirectories }
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
                owned.getAndSet(null)?.close()
                startup.cancel()
            }
        }
    }
}
