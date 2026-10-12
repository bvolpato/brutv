package com.bvolpato.brutv.playback

import android.content.Context
import android.net.Uri
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
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.session.MediaSession
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import java.net.SocketTimeoutException
import java.net.SocketException
import java.net.UnknownHostException
import java.io.File
import java.util.UUID
import javax.net.ssl.SSLException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.random.Random

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
internal class PlaybackController(context: Context, private val profile: BufferProfile) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val recovery = RecoveryPolicy()
    private var generation = 0L
    private var retryJob: Job? = null
    private var watchdog: Job? = null
    private var healthySince = 0L
    private var hasPlayed = false
    private var lastPlaybackState = Player.STATE_IDLE
    private var resumeAfterBackground = false
    private var disposed = false
    private var timeShift: HlsTimeShiftSession? = null
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
        .setTrackSelector(DefaultTrackSelector(appContext).apply {
            setParameters(buildUponParameters().setExceedRendererCapabilitiesIfNecessary(false))
        })
        .setLoadControl(
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(tuning.minBufferMs, tuning.maxBufferMs, tuning.startBufferMs, tuning.rebufferMs)
                .setTargetBufferBytes(tuning.targetBytes)
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
                    (prepareJob?.isActive == true || pendingLiveAnchorMs != null)) {
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
            if (playbackState == Player.STATE_BUFFERING && retryJob?.isActive == true) {
                // System or native controls prepared the player before the delayed reconnect.
                cancelRecovery()
                generation = recovery.startEntry()
                mutableState.value = mutableState.value.copy(error = null)
            }
            if (playbackState == Player.STATE_ENDED && mutableState.value.entry?.kind == MediaKind.LIVE && player.playWhenReady) {
                if (timeShift?.snapshot()?.recording == false) {
                    player.pause()
                    refresh()
                    return
                }
                recover(FailureKind.NETWORK)
                return
            }
            val buffering = playbackState == Player.STATE_BUFFERING && player.playWhenReady
            if (buffering && previousState == Player.STATE_READY && hasPlayed) {
                mutableState.value = mutableState.value.copy(stalls = mutableState.value.stalls + 1)
            }
            if (buffering) {
                healthySince = 0
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
                if (healthySince == 0L) healthySince = SystemClock.elapsedRealtime()
            } else {
                healthySince = 0
            }
            refresh()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (disposed) return
            if (playWhenReady && player.mediaItemCount == 0 && prepareJob?.isActive != true && mutableState.value.entry != null) {
                retry(play = true)
                return
            }
            if (playWhenReady && mutableState.value.error != null) {
                mutableState.value = mutableState.value.copy(error = null)
                generation = recovery.startEntry()
            }
            if (playWhenReady && !recovery.isCurrent(generation)) generation = recovery.startEntry()
            if (playWhenReady && player.playbackState == Player.STATE_BUFFERING) startWatchdog()
            if (!playWhenReady) cancelRecovery()
            refresh()
        }

        override fun onPlayerError(error: PlaybackException) {
            if (disposed) return
            val kind = classify(error)
            if (timeShift != null && kind == FailureKind.UNSUPPORTED) {
                val entry = mutableState.value.entry ?: return
                val play = if (pendingLiveAnchorMs != null) pendingLivePlay else player.playWhenReady
                cancelRecovery()
                closeTimeShift()
                // One native fallback can choose a different master rendition for this device.
                timeShiftAttempted = true
                timeShiftNotice = "The recording rendition is unsupported on this device. Using direct live playback."
                generation = recovery.startEntry()
                mutableState.value = mutableState.value.copy(error = null, recovering = false)
                player.stop()
                prepare(entry, 0, play)
                return
            }
            val response = generateSequence<Throwable>(error) { it.cause }.take(12)
                .filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
            if (timeShift != null && expiredRecoveryAttempts < 2 &&
                (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW || response == 410)) {
                // A bounded ring can expire an old paused position or cached native manifest.
                timeShiftNotice = "Older buffered footage expired. Playback moved to the oldest saved footage."
                expiredRecoveryAttempts++
                val play = player.playWhenReady
                player.seekTo(0)
                player.prepare()
                player.playWhenReady = play
                refresh()
            } else recover(kind)
        }

        override fun onTracksChanged(tracks: Tracks) {
            mutableState.value = mutableState.value.copy(tracks = tracks)
            refresh()
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                manuallyBehindLive = (liveDistanceFromDefaultMs() ?: 0) > 1_000
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

    init {
        player.addListener(listener)
        player.addAnalyticsListener(analytics)
        scope.launch {
            while (isActive) {
                refresh()
                if (healthySince != 0L && SystemClock.elapsedRealtime() - healthySince >= 30_000) {
                    recovery.healthy()
                    expiredRecoveryAttempts = 0
                }
                delay(500)
            }
        }
    }

    fun select(entry: MediaEntry, resumePositionMs: Long = 0) {
        checkMainThread()
        if (disposed || (mutableState.value.entry == entry && player.mediaItemCount > 0)) return
        cancelRecovery()
        closeTimeShift()
        timeShiftNotice = null
        backgroundSourceReleased = false
        expiredRecoveryAttempts = 0
        generation = recovery.startEntry()
        healthySince = 0
        hasPlayed = false
        lastPlaybackState = Player.STATE_IDLE
        resumeAfterBackground = false
        player.stop()
        player.clearMediaItems()
        mutableState.value = PlaybackSnapshot(entry = entry)
        prepare(entry, resumePositionMs, true)
    }

    fun retry(play: Boolean = player.playWhenReady || timeShift == null) {
        checkMainThread()
        val entry = mutableState.value.entry ?: return
        val position = if (entry.kind == MediaKind.LIVE && timeShift == null) 0 else player.currentPosition
        val anchor = liveContentAnchorMs()
        cancelRecovery()
        generation = recovery.startEntry()
        expiredRecoveryAttempts = 0
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
        if (prepareJob?.isActive == true || pendingLiveAnchorMs != null) refresh()
        else if (mutableState.value.error != null || player.playbackState == Player.STATE_IDLE) retry(play = true)
        else player.play()
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
        resumeAfterBackground = requestedPlay() || mutableState.value.recovering
        cancelRecovery()
        player.pause()
        if (timeShift != null || prepareJob?.isActive == true) {
            closeTimeShift()
            player.stop()
            player.clearMediaItems()
            backgroundSourceReleased = true
            timeShiftNotice = "The temporary live buffer was cleared when BruTV left the foreground."
            refresh()
        }
    }

    fun resumeForeground() {
        checkMainThread()
        if (!resumeAfterBackground) return
        resumeAfterBackground = false
        if (backgroundSourceReleased) {
            backgroundSourceReleased = false
            retry(play = true)
            return
        }
        if (player.playbackState == Player.STATE_IDLE && mutableState.value.error == null) retry()
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
        player.seekToDefaultPosition()
        player.play()
    }

    fun seekBy(offsetMs: Long) {
        checkMainThread()
        if (!player.isCurrentMediaItemSeekable) return
        expiredRecoveryAttempts = 0
        val duration = player.duration.takeUnless { it == C.TIME_UNSET } ?: return
        player.seekTo((player.currentPosition + offsetMs).coerceIn(0, duration.coerceAtLeast(0)))
    }

    fun stop() {
        checkMainThread()
        cancelRecovery()
        recovery.stop()
        closeTimeShift()
        player.pause()
        player.stop()
        player.clearMediaItems()
        mutableState.value = mutableState.value.copy(error = null)
        refresh()
    }

    fun position(): Long = if (disposed) mutableState.value.positionMs else player.currentPosition.coerceAtLeast(0)

    fun release() {
        checkMainThread()
        if (disposed) return
        disposed = true
        cancelRecovery()
        recovery.stop()
        closeTimeShift()
        scope.cancel()
        player.removeListener(listener)
        player.removeAnalyticsListener(analytics)
        mediaSession.release()
        player.release()
    }

    private fun closeTimeShift() {
        prepareJob?.cancel()
        prepareJob = null
        timeShift?.close()
        timeShift = null
        timeShiftAttempted = false
        manuallyBehindLive = false
        localSource = null
        pendingLiveAnchorMs = null
    }

    private fun prepare(entry: MediaEntry, positionMs: Long, play: Boolean, liveAnchorMs: Long? = null) {
        prepareJob?.cancel()
        intendedPlay = play
        mutableState.value = mutableState.value.copy(buffering = play)
        prepareJob = scope.launch {
            if (entry.kind == MediaKind.LIVE && !timeShiftAttempted) {
                timeShiftAttempted = true
                val url = Uri.parse(entry.streamUrl)
                if (url.path?.endsWith(".ts", true) == true || url.path?.endsWith(".mpd", true) == true) {
                    timeShiftNotice = "Local live recording is available for supported HLS sources. This stream plays directly."
                } else {
                    try {
                        timeShift = HlsTimeShiftSession.open(File(appContext.cacheDir, "brutv_timeshift"), entry.streamUrl, entry.requestHeaders)
                        timeShiftNotice = null
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: UnsupportedTimeShift) {
                        timeShiftNotice = error.message
                    } catch (_: Exception) {
                        timeShiftNotice = "The temporary live recorder could not start. This stream plays directly."
                    }
                }
            }
            if (!disposed && mutableState.value.entry == entry) {
                prepareResolved(entry, positionMs, intendedPlay, liveAnchorMs)
            }
            prepareJob = null
        }
    }

    private fun prepareResolved(entry: MediaEntry, positionMs: Long, play: Boolean, liveAnchorMs: Long?) {
        localSource = timeShift?.createPlaybackSource()
        pendingLiveAnchorMs = liveAnchorMs
        pendingLivePlay = play
        val uri = Uri.parse(localSource?.url ?: entry.streamUrl)
        if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
            recovery.stop()
            player.pause()
            mutableState.value = mutableState.value.copy(error = "This entry does not contain a supported HTTP or HTTPS stream.", recovering = false)
            return
        }
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("BruTV Android/1.0")
            .setConnectTimeoutMs(12_000)
            .setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(if (timeShift == null) entry.requestHeaders else emptyMap())
        val sources = DefaultMediaSourceFactory(DefaultDataSource.Factory(appContext, http))
            .setLoadErrorHandlingPolicy(object : DefaultLoadErrorHandlingPolicy(0) {
                override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long = C.TIME_UNSET
                override fun getFallbackSelectionFor(
                    fallbackOptions: LoadErrorHandlingPolicy.FallbackOptions,
                    loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo,
                ): LoadErrorHandlingPolicy.FallbackSelection? = null
            })
        val item = MediaItem.Builder()
            .setMediaId(entry.id)
            .setUri(uri)
            .setMediaMetadata(MediaMetadata.Builder().setTitle(entry.name).build())
        val extension = when {
            timeShift != null || uri.path?.endsWith(".m3u8", true) == true -> "m3u8"
            uri.path?.endsWith(".mpd", true) == true -> "mpd"
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
        player.setMediaSource(sources.createMediaSource(item.build()), if (entry.kind == MediaKind.LIVE) C.TIME_UNSET else positionMs.coerceAtLeast(0))
        player.playWhenReady = play && liveAnchorMs == null
        player.prepare()
        if (play) startWatchdog()
    }

    private fun recover(kind: FailureKind) {
        watchdog?.cancel()
        watchdog = null
        if (retryJob?.isActive == true || disposed) return
        val entry = mutableState.value.entry ?: return
        if (!player.playWhenReady) {
            player.stop()
            mutableState.value = mutableState.value.copy(error = message(kind), recovering = false, buffering = false)
            return
        }
        val ticket = recovery.retry(kind, Random.nextDouble())
        if (ticket == null) {
            recovery.stop()
            player.pause()
            player.stop()
            mutableState.value = mutableState.value.copy(error = message(kind), recovering = false, buffering = false)
            return
        }
        val position = if (entry.kind == MediaKind.LIVE && timeShift == null) 0 else position()
        val anchor = liveContentAnchorMs()
        player.stop()
        mutableState.value = mutableState.value.copy(recovering = true, error = null)
        retryJob = scope.launch {
            delay(ticket.delayMs)
            if (!recovery.isCurrent(ticket.generation) || disposed) return@launch
            retryJob = null
            mutableState.value = mutableState.value.copy(recovering = false, retries = mutableState.value.retries + 1)
            prepare(entry, position, true, liveAnchorMs = anchor)
        }
    }

    private fun startWatchdog() {
        if (watchdog?.isActive == true || retryJob?.isActive == true || disposed) return
        val token = generation
        watchdog = scope.launch {
            delay(25_000)
            if (recovery.isCurrent(token) && player.playWhenReady && player.playbackState == Player.STATE_BUFFERING) {
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
        mutableState.value = mutableState.value.copy(
            isPlaying = player.isPlaying,
            playWhenReady = if (prepareJob?.isActive == true) intendedPlay else player.playWhenReady,
            buffering = if (prepareJob?.isActive == true) intendedPlay else player.playbackState == Player.STATE_BUFFERING && player.playWhenReady,
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
}

@OptIn(UnstableApi::class)
private fun classify(error: PlaybackException): FailureKind {
    val causes = generateSequence<Throwable>(error) { it.cause }.take(12).toList()
    val response = causes.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
    if (response != null) return httpFailure(response)
    if (causes.any { it is SSLException }) return FailureKind.OTHER
    if (causes.any { it is SocketTimeoutException }) return FailureKind.TIMEOUT
    if (causes.any { it is SocketException || it is UnknownHostException }) return FailureKind.NETWORK
    return when (error.errorCode) {
        PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> FailureKind.LIVE_WINDOW
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> FailureKind.NETWORK
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> FailureKind.TIMEOUT
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> FailureKind.NOT_FOUND
        PlaybackException.ERROR_CODE_IO_NO_PERMISSION -> FailureKind.UNAUTHORIZED
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> FailureKind.UNSUPPORTED
        else -> FailureKind.OTHER
    }
}

private fun message(kind: FailureKind): String = when (kind) {
    FailureKind.UNAUTHORIZED -> "The provider refused access. Check the account or stream permissions."
    FailureKind.NOT_FOUND -> "This stream is no longer available from the provider."
    FailureKind.UNSUPPORTED -> "This device cannot decode the stream, or the stream format is unsupported."
    FailureKind.NETWORK -> "The stream could not connect. Check the connection or try another stream."
    FailureKind.TIMEOUT -> "The provider stopped sending data. Try another stream or retry when the connection improves."
    FailureKind.SERVER -> "The provider is having a server problem. Try again later."
    FailureKind.LIVE_WINDOW -> "The live window moved beyond the available stream. Retry to return to live."
    FailureKind.OTHER -> "The stream could not be played. Check the source settings or try another stream."
}
