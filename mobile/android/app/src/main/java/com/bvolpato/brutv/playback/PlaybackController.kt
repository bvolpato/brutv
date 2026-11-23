package com.bvolpato.brutv.playback

import android.app.ActivityManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.DefaultHlsExtractorFactory
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.session.MediaSession
import com.bvolpato.brutv.data.CatalogRepository
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.CacheControl
import okhttp3.ConnectionPool
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal data class PlaybackSnapshot(
    val entry: MediaEntry? = null,
    val isPlaying: Boolean = false,
    val playWhenReady: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val bufferMs: Long = 0,
    val liveOffsetMs: Long = 0,
    val behindLiveDefaultPositionMs: Long = 0,
    val bitrate: Int = 0,
    val bandwidthEstimate: Long = 0,
    val width: Int = 0,
    val height: Int = 0,
    val frameRate: Float = 0f,
    val droppedFrames: Int = 0,
    val stalls: Int = 0,
    val retries: Int = 0,
    val recovering: Boolean = false,
    val tracks: Tracks = Tracks.EMPTY,
    val error: String? = null,
    val liveSeekable: Boolean = false,
    val timeShiftAvailable: Boolean = false,
    val timeShiftRecording: Boolean = false,
    val timeShiftDurationMs: Long = 0,
    val timeShiftBytes: Long = 0,
    val timeShiftNotice: String? = null,
    val canGoLive: Boolean = false,
)

@OptIn(UnstableApi::class)
internal class PlaybackController(
    context: Context,
    private val profile: BufferProfile,
    maxConnections: Int = 1,
) {
    private val appContext = context.applicationContext
    var maxConnections: Int = maxConnections.coerceAtLeast(1)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val ioCleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val playbackConnectionPool = ConnectionPool(5, 30, TimeUnit.SECONDS)
    private val playbackClient = createPlaybackHttpClient(playbackConnectionPool)
    private val loadErrorPolicy = StreamLoadErrorHandlingPolicy()
    private val recovery = RecoveryPolicy()
    private val progressMonitor = PlaybackProgressMonitor()
    private val networkRecoveryPolicy = NetworkRecoveryPolicy()
    private val connectivityManager = runCatching {
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    }.getOrNull()
    private var networkCallbackRegistered = false
    private val isLowRamDevice = (appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
        ?.isLowRamDevice == true
    private var generation = 0L
    private var retryJob: Job? = null
    private var watchdog: Job? = null
    private var hasPlayed = false
    private var lastPlaybackState = Player.STATE_IDLE
    private var resumeAfterBackground = false
    private var inBackground = false
    private var disposed = false
    private var timeShift: HlsTimeShiftSession? = null
    private var pendingTimeShiftCloseJob: Job? = null
    private var pendingEvictJob: Job? = null
    private var hadPreviousLiveConnection = false
    private var timeShiftAttempted = false
    private var timeShiftNotice: String? = null
    private var prepareJob: Job? = null
    private var backgroundSourceReleased = false
    private var intendedPlay = false
    private var expiredRecoveryAttempts = 0
    private var manuallyBehindLive = false
    private var localSource: LocalTimeShiftSource? = null
    private var pendingLiveAnchorMs: Long? = null
    private var pendingLivePlay = false
    private var activeStreamUrl = ""
    private var formatFallbackUsed = false
    private var retriesOnCurrentFormat = 0
    private var liveAuthNotFoundRetries = 0
    private var lastAutoLiveSeekElapsedMs = 0L
    private var lastTerminalFailureKind: FailureKind? = null
    private val mutableState = MutableStateFlow(PlaybackSnapshot())
    val state = mutableState.asStateFlow()

    private val decoderSelector = MediaCodecSelector { mimeType, secure, tunneling ->
        MediaCodecSelector.DEFAULT.getDecoderInfos(mimeType, secure, tunneling)
            .sortedBy { if (it.hardwareAccelerated) 0 else 1 }
    }
    private val tuning = profile.tuning
    val player: ExoPlayer = ExoPlayer.Builder(
        appContext,
        DefaultRenderersFactory(appContext)
            .setEnableDecoderFallback(true)
            .setMediaCodecSelector(decoderSelector),
    )
        .setLooper(Looper.getMainLooper())
        .setTrackSelector(DefaultTrackSelector(appContext))
        .setLoadControl(
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(tuning.minBufferMs, tuning.maxBufferMs, tuning.startBufferMs, tuning.rebufferMs)
                .setTargetBufferBytes(tuning.effectiveTargetBytes(isLowRamDevice))
                .setPrioritizeTimeOverSizeThresholds(false)
                .setBackBuffer(0, false)
                .build(),
        )
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .setSeekBackIncrementMs(10_000)
        .setSeekForwardIncrementMs(10_000)
        .build()
    val controlPlayer: Player = object : ForwardingPlayer(player) {
        override fun getPlayWhenReady(): Boolean = requestedPlay()
        override fun setPlayWhenReady(playWhenReady: Boolean) {
            if (playWhenReady) this@PlaybackController.play() else this@PlaybackController.pause()
        }
        override fun play() = this@PlaybackController.play()
        override fun pause() = this@PlaybackController.pause()
        override fun prepare() {
            if (prepareJob?.isActive != true && pendingLiveAnchorMs == null && player.playbackState == Player.STATE_IDLE) {
                retry(play = requestedPlay())
            }
        }
        override fun stop() = this@PlaybackController.stop()
        override fun seekBack() = seekBy(-10_000)
        override fun seekForward() = seekBy(10_000)
    }
    private val mediaSession = MediaSession.Builder(appContext, controlPlayer)
        .setId("BruTV-${UUID.randomUUID()}")
        .setCallback(object : MediaSession.Callback {
            override fun onPlayerInteractionFinished(
                session: MediaSession,
                controllerInfo: MediaSession.ControllerInfo,
                playerCommands: Player.Commands,
            ) {
                if (disposed) return
                if (playerCommands.contains(Player.COMMAND_PLAY_PAUSE) &&
                    (prepareJob?.isActive == true || pendingLiveAnchorMs != null)
                ) {
                    intendedPlay = controlPlayer.playWhenReady
                    pendingLivePlay = intendedPlay
                    if (!intendedPlay) cancelRecovery()
                    refresh()
                }
                if (playerCommands.contains(Player.COMMAND_STOP) && player.playbackState == Player.STATE_IDLE) stop()
            }
        })
        .build()

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (disposed) return
            val previousState = lastPlaybackState
            lastPlaybackState = playbackState
            val currentEntry = mutableState.value.entry
            if (playbackState == Player.STATE_BUFFERING && retryJob?.isActive == true) {
                // System or native controls prepared the player before the delayed reconnect.
                cancelRecovery()
                generation = recovery.startEntry(isLive = currentEntry?.kind == MediaKind.LIVE)
                lastTerminalFailureKind = null
                mutableState.value = mutableState.value.copy(error = null)
            }
            if (playbackState == Player.STATE_ENDED && currentEntry?.kind == MediaKind.LIVE && requestedPlay()) {
                if (timeShift?.snapshot()?.recording == false) {
                    closeTimeShift()
                    timeShiftNotice = null
                }
                recover(FailureKind.NETWORK)
                return
            }
            val buffering = playbackState == Player.STATE_BUFFERING && requestedPlay()
            if (buffering && previousState == Player.STATE_READY && hasPlayed) {
                mutableState.value = mutableState.value.copy(stalls = mutableState.value.stalls + 1)
            }
            if (buffering) {
                startWatchdog()
            } else {
                watchdog?.cancel()
                watchdog = null
            }
            refresh()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
                hasPlayed = true
            }
            refresh()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (disposed) return
            val currentEntry = mutableState.value.entry
            if (playWhenReady && player.mediaItemCount == 0 && prepareJob?.isActive != true && currentEntry != null) {
                retry(play = true)
                return
            }
            if (playWhenReady && mutableState.value.error != null) {
                lastTerminalFailureKind = null
                mutableState.value = mutableState.value.copy(error = null)
                generation = recovery.startEntry(isLive = currentEntry?.kind == MediaKind.LIVE)
            }
            if (playWhenReady && !recovery.isCurrent(generation)) {
                generation = recovery.startEntry(isLive = currentEntry?.kind == MediaKind.LIVE)
            }
            if (playWhenReady && player.playbackState == Player.STATE_BUFFERING) startWatchdog()
            if (!playWhenReady && pendingLiveAnchorMs == null) cancelRecovery()
            refresh()
        }

        override fun onPlayerError(error: PlaybackException) {
            if (disposed) return
            val kind = classify(error)
            val httpStatus = extractHttpStatusCode(error)
            if (timeShift != null && kind == FailureKind.UNSUPPORTED) {
                val entry = mutableState.value.entry ?: return
                val play = requestedPlay()
                cancelRecovery()
                closeTimeShift()
                // One native fallback can choose a different master rendition for this device.
                timeShiftAttempted = true
                timeShiftNotice = "The recording rendition is unsupported on this device. Using direct live playback."
                generation = recovery.startEntry(isLive = entry.kind == MediaKind.LIVE)
                lastTerminalFailureKind = null
                mutableState.value = mutableState.value.copy(error = null, recovering = false)
                stopAndEvict(cancelActive = true)
                prepare(entry, 0, play)
                return
            }
            if (timeShift != null && expiredRecoveryAttempts < 2 &&
                (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW || httpStatus == 410)
            ) {
                expiredRecoveryAttempts++
                val play = requestedPlay()
                if (manuallyBehindLive) {
                    // A bounded ring can expire an old paused or rewound position.
                    timeShiftNotice = "Older buffered footage expired. Playback moved to the oldest saved footage."
                    player.seekTo(0)
                } else {
                    player.seekToDefaultPosition()
                }
                player.prepare()
                player.playWhenReady = play
                refresh()
            } else {
                recover(kind, httpStatus)
            }
        }

        override fun onTracksChanged(tracks: Tracks) {
            mutableState.value = mutableState.value.copy(tracks = tracks)
            refresh()
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                manuallyBehindLive = (liveDistanceFromDefaultMs() ?: 0) > 1_000
                progressMonitor.onSeek()
            }
            refresh()
        }

        override fun onTimelineChanged(timeline: Timeline, reason: Int) {
            applyPendingLiveAnchor()
            refresh()
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) = refresh()
    }

    private val analytics = object : AnalyticsListener {
        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            mutableState.value = mutableState.value.copy(droppedFrames = mutableState.value.droppedFrames + droppedFrames)
        }

        override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) {
            mutableState.value = mutableState.value.copy(bandwidthEstimate = bitrateEstimate)
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val networkId = network.networkHandle
            scope.launch {
                if (disposed) return@launch
                if (!networkRecoveryPolicy.onAvailable(networkId, SystemClock.elapsedRealtime())) return@launch
                evictPlaybackConnections(cancelActive = false)
                if (inBackground) return@launch
                val entry = mutableState.value.entry ?: return@launch
                when {
                    retryJob?.isActive == true -> retry(play = true)
                    mutableState.value.error != null && lastTerminalFailureKind?.retryable == true -> retry(play = true)
                    requestedPlay() && entry.kind == MediaKind.LIVE && player.playbackState == Player.STATE_BUFFERING -> retry(play = true)
                }
            }
        }

        override fun onLost(network: Network) {
            val networkId = network.networkHandle
            scope.launch {
                if (disposed) return@launch
                networkRecoveryPolicy.onLost(networkId)
            }
        }
    }

    init {
        player.addListener(listener)
        player.addAnalyticsListener(analytics)
        connectivityManager?.let { cm ->
            runCatching {
                if (cm.activeNetwork == null) {
                    networkRecoveryPolicy.onLost(-1L)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    cm.registerDefaultNetworkCallback(networkCallback)
                } else {
                    val request = NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .build()
                    cm.registerNetworkCallback(request, networkCallback)
                }
                networkCallbackRegistered = true
            }
        }
        scope.launch {
            while (isActive) {
                refresh()
                val now = SystemClock.elapsedRealtime()
                val entry = mutableState.value.entry
                val isLive = entry?.kind == MediaKind.LIVE
                val isPlayingReady = player.playbackState == Player.STATE_READY &&
                    player.isPlaying &&
                    requestedPlay()
                val progress = progressMonitor.sample(
                    nowElapsedMs = now,
                    positionMs = player.currentPosition,
                    isPlayingReady = isPlayingReady,
                    isLive = isLive,
                )
                if (progress.reachedHealthyThreshold) {
                    recovery.healthy()
                    expiredRecoveryAttempts = 0
                    retriesOnCurrentFormat = 0
                    liveAuthNotFoundRetries = 0
                    if (isLive) {
                        LiveFormatCache.shared.remember(entry.streamUrl, activeStreamUrl.ifBlank { entry.streamUrl })
                    }
                }
                if (progress.frozen && entry != null && retryJob?.isActive != true && prepareJob?.isActive != true) {
                    recover(FailureKind.TIMEOUT)
                }
                if (isLive &&
                    timeShift == null &&
                    !manuallyBehindLive &&
                    requestedPlay() &&
                    player.playbackState == Player.STATE_READY &&
                    now - lastAutoLiveSeekElapsedMs >= AUTO_LIVE_SEEK_COOLDOWN_MS
                ) {
                    val behind = behindLiveDefaultPositionMs()
                    if (behind != null && behind > 30_000L) {
                        lastAutoLiveSeekElapsedMs = now
                        player.seekToDefaultPosition()
                    }
                }
                delay(500)
            }
        }
    }

    fun select(entry: MediaEntry, resumePositionMs: Long = 0) {
        checkMainThread()
        if (disposed || (mutableState.value.entry == entry && (player.mediaItemCount > 0 || prepareJob?.isActive == true))) return
        val previousEntry = mutableState.value.entry
        if (timeShift != null ||
            (previousEntry?.kind == MediaKind.LIVE && (player.mediaItemCount > 0 || prepareJob?.isActive == true))
        ) {
            hadPreviousLiveConnection = true
        }
        inBackground = false
        cancelRecovery()
        closeTimeShift()
        stopAndEvict(cancelActive = true)
        activeStreamUrl = if (entry.kind == MediaKind.LIVE) {
            LiveFormatCache.shared.get(entry.streamUrl) ?: entry.streamUrl
        } else {
            entry.streamUrl
        }
        formatFallbackUsed = false
        retriesOnCurrentFormat = 0
        liveAuthNotFoundRetries = 0
        lastTerminalFailureKind = null
        timeShiftNotice = null
        backgroundSourceReleased = false
        expiredRecoveryAttempts = 0
        lastAutoLiveSeekElapsedMs = 0L
        progressMonitor.resetAll()
        generation = recovery.startEntry(isLive = entry.kind == MediaKind.LIVE)
        hasPlayed = false
        lastPlaybackState = Player.STATE_IDLE
        resumeAfterBackground = false
        mutableState.value = PlaybackSnapshot(entry = entry)
        prepare(entry, resumePositionMs, true)
    }

    fun retry(play: Boolean = requestedPlay() || timeShift == null) {
        checkMainThread()
        val entry = mutableState.value.entry ?: return
        val hadError = mutableState.value.error != null
        val deadTimeShift = timeShift?.snapshot()?.recording == false
        if (timeShift != null ||
            (entry.kind == MediaKind.LIVE && (player.mediaItemCount > 0 || prepareJob?.isActive == true))
        ) {
            hadPreviousLiveConnection = true
        }
        cancelRecovery()
        if (hadError) {
            closeTimeShift()
            if (formatFallbackUsed) {
                LiveFormatCache.shared.remove(entry.streamUrl)
                activeStreamUrl = entry.streamUrl
                formatFallbackUsed = false
            }
            retriesOnCurrentFormat = 0
            liveAuthNotFoundRetries = 0
        } else if (deadTimeShift) {
            closeTimeShift()
        }
        val position = if (entry.kind == MediaKind.LIVE && timeShift == null) 0 else player.currentPosition
        val anchor = liveContentAnchorMs()
        backgroundSourceReleased = false
        expiredRecoveryAttempts = 0
        lastTerminalFailureKind = null
        progressMonitor.resetAll()
        generation = recovery.startEntry(isLive = entry.kind == MediaKind.LIVE)
        stopAndEvict(cancelActive = true)
        mutableState.value = mutableState.value.copy(error = null, recovering = false)
        prepare(entry, position, play, liveAnchorMs = anchor)
    }

    fun togglePlayPause() {
        checkMainThread()
        if (requestedPlay()) pause() else play()
    }

    private fun requestedPlay(): Boolean = when {
        prepareJob?.isActive == true -> intendedPlay
        pendingLiveAnchorMs != null -> pendingLivePlay
        else -> player.playWhenReady
    }

    fun play() {
        checkMainThread()
        intendedPlay = true
        pendingLivePlay = true
        if (prepareJob?.isActive == true || pendingLiveAnchorMs != null) {
            lastTerminalFailureKind = null
            refresh()
        } else if (mutableState.value.error != null || player.playbackState == Player.STATE_IDLE) {
            retry(play = true)
        } else {
            lastTerminalFailureKind = null
            player.play()
        }
    }

    fun pause() {
        checkMainThread()
        intendedPlay = false
        pendingLivePlay = false
        cancelRecovery()
        player.pause()
        refresh()
    }

    fun pauseForBackground() {
        checkMainThread()
        inBackground = true
        resumeAfterBackground = requestedPlay() || mutableState.value.recovering
        cancelRecovery()
        player.pause()
        val isLive = mutableState.value.entry?.kind == MediaKind.LIVE
        val hadTimeShift = timeShift != null || (isLive && prepareJob?.isActive == true)
        if (isLive || hadTimeShift) {
            closeTimeShift()
            stopAndEvict(cancelActive = true)
            backgroundSourceReleased = true
            if (hadTimeShift) {
                timeShiftNotice = "The temporary live buffer was cleared when BruTV left the foreground."
            }
            refresh()
        } else {
            evictPlaybackConnections(cancelActive = false)
        }
    }

    fun resumeForeground() {
        checkMainThread()
        inBackground = false
        if (!resumeAfterBackground) return
        resumeAfterBackground = false
        if (backgroundSourceReleased) {
            backgroundSourceReleased = false
            retry(play = true)
            return
        }
        if (player.playbackState == Player.STATE_IDLE && mutableState.value.error == null) retry(play = true)
        else player.play()
    }

    fun goLive() {
        checkMainThread()
        if (timeShift?.snapshot()?.recording == false) {
            closeTimeShift()
            timeShiftNotice = null
            retry(play = true)
            return
        }
        if (behindLiveDefaultPositionMs() == null && !(manuallyBehindLive && (liveDistanceFromDefaultMs() ?: 0) > 1_000)) return
        expiredRecoveryAttempts = 0
        manuallyBehindLive = false
        timeShiftNotice = null
        lastAutoLiveSeekElapsedMs = SystemClock.elapsedRealtime()
        player.seekToDefaultPosition()
        player.play()
    }

    fun seekBy(offsetMs: Long) {
        checkMainThread()
        if (!player.isCurrentMediaItemSeekable) return
        expiredRecoveryAttempts = 0
        val duration = player.duration.takeUnless { it == C.TIME_UNSET } ?: return
        progressMonitor.onSeek()
        player.seekTo((player.currentPosition + offsetMs).coerceIn(0, duration.coerceAtLeast(0)))
    }

    fun stop() {
        checkMainThread()
        cancelRecovery()
        recovery.stop()
        closeTimeShift()
        progressMonitor.resetAll()
        lastTerminalFailureKind = null
        player.pause()
        stopAndEvict(cancelActive = true)
        mutableState.value = mutableState.value.copy(error = null)
        refresh()
    }

    fun position(): Long = if (disposed) mutableState.value.positionMs else player.currentPosition.coerceAtLeast(0)

    fun canCommitPosition(): Boolean = !disposed && prepareJob?.isActive != true && player.mediaItemCount > 0

    fun release() {
        checkMainThread()
        if (disposed) return
        disposed = true
        if (networkCallbackRegistered) {
            networkCallbackRegistered = false
            runCatching { connectivityManager?.unregisterNetworkCallback(networkCallback) }
        }
        cancelRecovery()
        recovery.stop()
        closeTimeShift()
        progressMonitor.resetAll()
        scope.cancel()
        player.removeListener(listener)
        player.removeAnalyticsListener(analytics)
        mediaSession.release()
        player.release()
        ioCleanupScope.launch {
            runCatching { playbackClient.dispatcher.cancelAll() }
            runCatching { playbackConnectionPool.evictAll() }
            runCatching { playbackClient.dispatcher.executorService.shutdown() }
            ioCleanupScope.cancel()
        }
    }

    private fun stopAndEvict(cancelActive: Boolean) {
        player.stop()
        player.clearMediaItems()
        evictPlaybackConnections(cancelActive = cancelActive)
    }

    private fun evictPlaybackConnections(cancelActive: Boolean) {
        val previous = pendingEvictJob
        pendingEvictJob = ioCleanupScope.launch {
            previous?.join()
            if (cancelActive) runCatching { playbackClient.dispatcher.cancelAll() }
            runCatching { playbackConnectionPool.evictAll() }
        }
    }

    private fun closeTimeShift() {
        prepareJob?.cancel()
        prepareJob = null
        timeShift?.let { session ->
            pendingTimeShiftCloseJob = session.closeAsync()
            hadPreviousLiveConnection = true
        }
        timeShift = null
        timeShiftAttempted = false
        manuallyBehindLive = false
        localSource = null
        pendingLiveAnchorMs = null
    }

    private fun prepare(
        entry: MediaEntry,
        positionMs: Long,
        play: Boolean,
        liveAnchorMs: Long? = null,
        skipSlotReleaseDelay: Boolean = false,
    ) {
        prepareJob?.cancel()
        intendedPlay = play
        val targetUrl = activeStreamUrl.ifBlank { entry.streamUrl }
        val waitForSlotRelease = !skipSlotReleaseDelay &&
            hadPreviousLiveConnection &&
            entry.kind == MediaKind.LIVE &&
            maxConnections <= 1
        hadPreviousLiveConnection = false
        mutableState.value = mutableState.value.copy(buffering = play)
        prepareJob = scope.launch {
            // Ensure previous channel and timeshift sockets are closed before opening a new stream.
            val closeJob = pendingTimeShiftCloseJob
            if (closeJob != null) {
                withTimeoutOrNull(TIMESHIFT_CLOSE_TIMEOUT_MS) { closeJob.join() }
                if (pendingTimeShiftCloseJob === closeJob) pendingTimeShiftCloseJob = null
            }
            val evictJob = pendingEvictJob
            if (evictJob != null) {
                withTimeoutOrNull(TIMESHIFT_CLOSE_TIMEOUT_MS) { evictJob.join() }
                if (pendingEvictJob === evictJob) pendingEvictJob = null
            }
            withContext(Dispatchers.IO) {
                runCatching { playbackConnectionPool.evictAll() }
            }
            if (waitForSlotRelease) {
                delay(CHANNEL_SWITCH_RELEASE_DELAY_MS)
            }
            if (entry.kind == MediaKind.LIVE && !timeShiftAttempted) {
                timeShiftAttempted = true
                val url = Uri.parse(targetUrl)
                if (url.path?.endsWith(".ts", true) == true || url.path?.endsWith(".mpd", true) == true) {
                    timeShiftNotice = "Local live recording is available for supported HLS sources. This stream plays directly."
                } else {
                    val alternateUrl = if (!formatFallbackUsed) {
                        LivePlaybackPolicy.alternateLiveFormatUrl(targetUrl)
                    } else {
                        null
                    }
                    val openTimeoutMs = if (alternateUrl != null) {
                        PREPARE_TIMESHIFT_WITH_ALTERNATE_TIMEOUT_MS
                    } else {
                        PREPARE_TIMESHIFT_TIMEOUT_MS
                    }
                    try {
                        val opened = withTimeoutOrNull(openTimeoutMs) {
                            HlsTimeShiftSession.open(
                                File(appContext.cacheDir, "brutv_timeshift"),
                                targetUrl,
                                entry.requestHeaders,
                            )
                        }
                        if (opened != null) {
                            timeShift = opened
                            timeShiftNotice = null
                        } else {
                            if (alternateUrl != null) {
                                retriesOnCurrentFormat++
                            }
                            timeShiftNotice = "The temporary live recorder timed out. This stream plays directly."
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: TimeShiftHttpException) {
                        if (alternateUrl != null && error.statusCode in setOf(403, 404, 410)) {
                            if (!disposed && mutableState.value.entry == entry) {
                                prepareJob = null
                                switchToAlternateLiveFormat(entry, alternateUrl, play = intendedPlay)
                            }
                            return@launch
                        }
                        timeShiftNotice = "The temporary live recorder could not start. This stream plays directly."
                    } catch (error: UnsupportedTimeShift) {
                        timeShiftNotice = error.message
                    } catch (_: Exception) {
                        timeShiftNotice = "The temporary live recorder could not start. This stream plays directly."
                    }
                }
            }
            if (!disposed && mutableState.value.entry == entry) {
                prepareResolved(entry, targetUrl, positionMs, intendedPlay, liveAnchorMs)
            }
            prepareJob = null
        }
    }

    private fun prepareResolved(
        entry: MediaEntry,
        targetUrl: String,
        positionMs: Long,
        play: Boolean,
        liveAnchorMs: Long?,
    ) {
        localSource = timeShift?.createPlaybackSource()
        pendingLiveAnchorMs = liveAnchorMs
        pendingLivePlay = play
        val resolvedUrl = localSource?.url ?: targetUrl
        val uri = Uri.parse(resolvedUrl)
        if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
            recovery.stop()
            player.pause()
            lastTerminalFailureKind = FailureKind.UNSUPPORTED
            mutableState.value = mutableState.value.copy(error = "This entry does not contain a supported HTTP or HTTPS stream.", recovering = false)
            return
        }
        val effectiveUserAgent = entry.requestHeaders.entries
            .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
            ?.value
            ?.takeIf { it.isNotBlank() }
            ?: CatalogRepository.USER_AGENT
        val customHeaders = if (timeShift == null) {
            entry.requestHeaders.filterKeys { !it.equals("User-Agent", ignoreCase = true) }
        } else {
            emptyMap()
        }
        val sourceOrigin = if (timeShift == null) resolvedUrl.toHttpUrlOrNull() else null
        val requestClient = if (sourceOrigin != null) {
            playbackClient.newBuilder()
                .addNetworkInterceptor(CrossOriginHeaderStripInterceptor(sourceOrigin, customHeaders.keys))
                .build()
        } else {
            playbackClient
        }
        val http = OkHttpDataSource.Factory(requestClient)
            .setUserAgent(effectiveUserAgent)
            .setDefaultRequestProperties(customHeaders)
            .apply {
                if (entry.kind == MediaKind.LIVE && timeShift == null) {
                    setCacheControl(CacheControl.FORCE_NETWORK)
                }
            }
        val dataSourceFactory = DefaultDataSource.Factory(appContext, http)
        val tsFlags = DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or
            DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS
        val extractorsFactory = DefaultExtractorsFactory()
            .setTsExtractorFlags(tsFlags)
        val item = MediaItem.Builder()
            .setMediaId(entry.id)
            .setUri(uri)
            .setMediaMetadata(MediaMetadata.Builder().setTitle(entry.name).build())
        val extension = when {
            timeShift != null || uri.path?.endsWith(".m3u8", true) == true -> "m3u8"
            uri.path?.endsWith(".mpd", true) == true -> "mpd"
            uri.path?.endsWith(".ts", true) == true -> "ts"
            else -> entry.containerExtension.lowercase().removePrefix(".")
        }
        when (extension) {
            "m3u8" -> item.setMimeType(MimeTypes.APPLICATION_M3U8)
            "mpd" -> item.setMimeType(MimeTypes.APPLICATION_MPD)
            "ts" -> item.setMimeType(MimeTypes.VIDEO_MP2T)
        }
        val liveOffsetOverride = tuning.liveOffsetMs
        // Conventional live streams keep their manifest/default holdback and playback speed.
        if (entry.kind == MediaKind.LIVE && liveOffsetOverride != null) {
            item.setLiveConfiguration(
                MediaItem.LiveConfiguration.Builder()
                    .setTargetOffsetMs(liveOffsetOverride)
                    .setMinPlaybackSpeed(0.97f)
                    .setMaxPlaybackSpeed(1.03f)
                    .build(),
            )
        }
        val builtItem = item.build()
        val mediaSource = if (extension == "m3u8") {
            HlsMediaSource.Factory(dataSourceFactory)
                .setExtractorFactory(DefaultHlsExtractorFactory(tsFlags, true))
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(builtItem)
        } else {
            DefaultMediaSourceFactory(dataSourceFactory, extractorsFactory)
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(builtItem)
        }
        player.setMediaSource(mediaSource, if (entry.kind == MediaKind.LIVE) C.TIME_UNSET else positionMs.coerceAtLeast(0))
        player.playWhenReady = play && liveAnchorMs == null
        player.prepare()
        if (play) startWatchdog()
    }

    private fun recover(kind: FailureKind, httpStatus: Int? = null) {
        watchdog?.cancel()
        watchdog = null
        if (retryJob?.isActive == true || disposed) return
        val entry = mutableState.value.entry ?: return
        progressMonitor.resetAll()
        if (!requestedPlay()) {
            stopAndEvict(cancelActive = true)
            lastTerminalFailureKind = kind
            mutableState.value = mutableState.value.copy(error = message(kind), recovering = false, buffering = false)
            return
        }
        val isLive = entry.kind == MediaKind.LIVE
        val currentUrl = activeStreamUrl.ifBlank { entry.streamUrl }
        val alternateUrl = if (isLive && !formatFallbackUsed && httpStatus != 401) {
            LivePlaybackPolicy.alternateLiveFormatUrl(currentUrl)
        } else {
            null
        }
        val immediateFormatFallback = alternateUrl != null && (
            httpStatus == 403 ||
                httpStatus == 404 ||
                httpStatus == 410 ||
                kind == FailureKind.UNSUPPORTED ||
                (kind.retryable && retriesOnCurrentFormat >= PRIMARY_FORMAT_RETRIES_BEFORE_FALLBACK)
            )
        if (immediateFormatFallback) {
            switchToAlternateLiveFormat(entry, checkNotNull(alternateUrl))
            return
        }
        val allowLiveStatusRetry = isLive &&
            (httpStatus == 403 || httpStatus == 404) &&
            liveAuthNotFoundRetries < MAX_LIVE_AUTH_NOT_FOUND_RETRIES
        val ticket = recovery.retry(kind, Random.nextDouble(), allowTemporaryOverride = allowLiveStatusRetry)
        if (ticket == null) {
            if (alternateUrl != null) {
                switchToAlternateLiveFormat(entry, alternateUrl)
                return
            }
            recovery.stop()
            player.pause()
            stopAndEvict(cancelActive = true)
            lastTerminalFailureKind = kind
            mutableState.value = mutableState.value.copy(error = message(kind), recovering = false, buffering = false)
            return
        }
        if (allowLiveStatusRetry) liveAuthNotFoundRetries++
        retriesOnCurrentFormat++
        if (timeShift != null && (timeShift?.snapshot()?.recording == false || kind == FailureKind.TIMEOUT || httpStatus == 403 || httpStatus == 404)) {
            closeTimeShift()
            timeShiftNotice = null
        }
        val position = if (isLive && timeShift == null) 0 else position()
        val anchor = liveContentAnchorMs()
        stopAndEvict(cancelActive = true)
        lastTerminalFailureKind = null
        mutableState.value = mutableState.value.copy(recovering = true, error = null)
        retryJob = scope.launch {
            delay(ticket.delayMs)
            if (!recovery.isCurrent(ticket.generation) || disposed) return@launch
            retryJob = null
            mutableState.value = mutableState.value.copy(recovering = false, retries = mutableState.value.retries + 1)
            prepare(
                entry,
                position,
                true,
                liveAnchorMs = anchor,
                skipSlotReleaseDelay = ticket.delayMs >= CHANNEL_SWITCH_RELEASE_DELAY_MS,
            )
        }
    }

    private fun switchToAlternateLiveFormat(entry: MediaEntry, alternateUrl: String, play: Boolean = true) {
        formatFallbackUsed = true
        activeStreamUrl = alternateUrl
        retriesOnCurrentFormat = 0
        liveAuthNotFoundRetries = 0
        lastTerminalFailureKind = null
        closeTimeShift()
        timeShiftNotice = null
        stopAndEvict(cancelActive = true)
        generation = recovery.startEntry(isLive = true)
        val token = generation
        mutableState.value = mutableState.value.copy(recovering = true, error = null)
        retryJob = scope.launch {
            // Brief pause lets single-connection Xtream panels release the old slot cleanly.
            delay(FORMAT_FALLBACK_RELEASE_DELAY_MS)
            if (!recovery.isCurrent(token) || disposed) return@launch
            retryJob = null
            mutableState.value = mutableState.value.copy(recovering = false, retries = mutableState.value.retries + 1)
            prepare(entry, 0, play, liveAnchorMs = null, skipSlotReleaseDelay = true)
        }
    }

    private fun startWatchdog() {
        if (watchdog?.isActive == true || retryJob?.isActive == true || disposed) return
        val token = generation
        watchdog = scope.launch {
            delay(BUFFERING_WATCHDOG_TIMEOUT_MS)
            if (recovery.isCurrent(token) && requestedPlay() && player.playbackState == Player.STATE_BUFFERING) {
                watchdog = null
                recover(FailureKind.TIMEOUT)
            }
        }
    }

    private fun cancelRecovery() {
        retryJob?.cancel()
        retryJob = null
        watchdog?.cancel()
        watchdog = null
        mutableState.value = mutableState.value.copy(recovering = false)
    }

    private fun refresh() {
        if (disposed) return
        val format = player.videoFormat
        val recording = timeShift?.snapshot()
        val wantPlay = requestedPlay()
        mutableState.value = mutableState.value.copy(
            isPlaying = player.isPlaying,
            playWhenReady = wantPlay,
            buffering = if (prepareJob?.isActive == true) intendedPlay else player.playbackState == Player.STATE_BUFFERING && wantPlay,
            positionMs = player.currentPosition.coerceAtLeast(0),
            durationMs = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0,
            bufferMs = player.totalBufferedDuration.coerceAtLeast(0),
            liveOffsetMs = player.currentLiveOffset.takeIf { it != C.TIME_UNSET }?.coerceAtLeast(0) ?: 0,
            behindLiveDefaultPositionMs = behindLiveDefaultPositionMs() ?: 0,
            bitrate = format?.bitrate?.coerceAtLeast(0) ?: 0,
            width = player.videoSize.width,
            height = player.videoSize.height,
            frameRate = format?.frameRate?.coerceAtLeast(0f) ?: 0f,
            liveSeekable = player.isCurrentMediaItemSeekable,
            timeShiftAvailable = recording != null,
            timeShiftRecording = recording?.recording == true,
            timeShiftDurationMs = recording?.durationMs ?: 0,
            timeShiftBytes = recording?.bytes ?: 0,
            timeShiftNotice = recording?.notice ?: timeShiftNotice,
            canGoLive = behindLiveDefaultPositionMs() != null ||
                (manuallyBehindLive && (liveDistanceFromDefaultMs() ?: 0) > 1_000) ||
                (recording != null && !recording.recording),
        )
    }

    private fun behindLiveDefaultPositionMs(): Long? {
        if (!player.isCommandAvailable(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)) return null
        val timeline = player.currentTimeline
        if (timeline.isEmpty) return null
        val windowIndex = player.currentMediaItemIndex
        if (windowIndex !in 0 until timeline.windowCount) return null
        val window = timeline.getWindow(windowIndex, Timeline.Window())
        return LivePlaybackPolicy.behindDefaultPositionMs(
            currentPositionMs = player.currentPosition,
            defaultPositionMs = window.defaultPositionMs.takeUnless { it == C.TIME_UNSET },
            isLive = window.isLive,
            isDynamic = window.isDynamic,
            isSeekable = window.isSeekable,
            isPlaceholder = window.isPlaceholder,
            canSeekToDefaultPosition = player.isCommandAvailable(
                Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
            ),
        )
    }

    private fun liveDistanceFromDefaultMs(): Long? {
        if (!player.isCommandAvailable(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)) return null
        val timeline = player.currentTimeline
        val index = player.currentMediaItemIndex
        if (timeline.isEmpty || index !in 0 until timeline.windowCount) return null
        val window = timeline.getWindow(index, Timeline.Window())
        if (!window.isLive || !window.isDynamic || !window.isSeekable || window.isPlaceholder || window.defaultPositionMs == C.TIME_UNSET) return null
        return (window.defaultPositionMs - player.currentPosition).coerceAtLeast(0)
    }

    private fun liveContentAnchorMs(): Long? {
        pendingLiveAnchorMs?.let { return it }
        val origin = localSource?.windowStartOffsetMs ?: return null
        val timeline = player.currentTimeline
        val index = player.currentMediaItemIndex
        if (timeline.isEmpty || index !in 0 until timeline.windowCount) return null
        val window = timeline.getWindow(index, Timeline.Window())
        if (window.isPlaceholder) return null
        return origin + window.positionInFirstPeriodMs + player.currentPosition
    }

    private fun applyPendingLiveAnchor() {
        val anchor = pendingLiveAnchorMs ?: return
        val origin = localSource?.windowStartOffsetMs ?: return
        val timeline = player.currentTimeline
        val index = player.currentMediaItemIndex
        if (timeline.isEmpty || index !in 0 until timeline.windowCount) return
        val window = timeline.getWindow(index, Timeline.Window())
        if (window.isPlaceholder || window.durationMs == C.TIME_UNSET) return
        val earliest = origin + window.positionInFirstPeriodMs
        if (anchor < earliest) timeShiftNotice = "Older buffered footage expired. Playback moved to the oldest saved footage."
        pendingLiveAnchorMs = null
        player.seekTo((anchor - earliest).coerceIn(0, window.durationMs.coerceAtLeast(0)))
        player.playWhenReady = pendingLivePlay
    }

    private fun checkMainThread() = check(Looper.myLooper() == Looper.getMainLooper())

    companion object {
        private const val PREPARE_TIMESHIFT_TIMEOUT_MS = 20_000L
        private const val PREPARE_TIMESHIFT_WITH_ALTERNATE_TIMEOUT_MS = 10_000L
        private const val TIMESHIFT_CLOSE_TIMEOUT_MS = 500L
        private const val CHANNEL_SWITCH_RELEASE_DELAY_MS = 300L
        private const val BUFFERING_WATCHDOG_TIMEOUT_MS = 25_000L
        private const val AUTO_LIVE_SEEK_COOLDOWN_MS = 15_000L
        private const val FORMAT_FALLBACK_RELEASE_DELAY_MS = 300L
        private const val PRIMARY_FORMAT_RETRIES_BEFORE_FALLBACK = 2
        private const val MAX_LIVE_AUTH_NOT_FOUND_RETRIES = 2
    }
}

@OptIn(UnstableApi::class)
private fun classify(error: PlaybackException): FailureKind {
    val causes = generateSequence<Throwable>(error) { it.cause }.take(12).toList()
    return classifyFailure(causes, error.errorCode)
}

private fun message(kind: FailureKind): String = when (kind) {
    FailureKind.UNAUTHORIZED -> "The provider refused access. Check the account or stream permissions."
    FailureKind.NOT_FOUND -> "This stream is no longer available from the provider."
    FailureKind.UNSUPPORTED -> "This device cannot decode the stream, or the stream format is unsupported."
    FailureKind.NETWORK -> "The stream could not connect. Check the connection or try another stream."
    FailureKind.TIMEOUT -> "The provider stopped sending data. Try another stream or retry when the connection improves."
    FailureKind.SERVER -> "The provider is having a server problem. Try again later."
    FailureKind.RATE_LIMITED -> "The provider is limiting connections right now. Wait a moment and try again."
    FailureKind.LIVE_WINDOW -> "The live window moved beyond the available stream. Retry to return to live."
    FailureKind.OTHER -> "The stream could not be played. Check the source settings or try another stream."
}
