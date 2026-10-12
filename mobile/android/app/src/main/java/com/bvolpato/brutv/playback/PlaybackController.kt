package com.bvolpato.brutv.playback

import android.content.Context
import android.net.Uri
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
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
import java.util.UUID
import javax.net.ssl.SSLException
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
    private val mediaSession = MediaSession.Builder(appContext, player)
        .setId("BruTV-${UUID.randomUUID()}")
        .setCallback(object : MediaSession.Callback {
            override fun onPlayerInteractionFinished(
                session: MediaSession,
                controllerInfo: MediaSession.ControllerInfo,
                playerCommands: Player.Commands,
            ) {
                if (disposed) return
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
            if (!disposed) recover(classify(error))
        }

        override fun onTracksChanged(tracks: Tracks) {
            mutableState.value = mutableState.value.copy(tracks = tracks)
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
                }
                delay(500)
            }
        }
    }

    fun select(entry: MediaEntry, resumePositionMs: Long = 0) {
        checkMainThread()
        if (disposed || (mutableState.value.entry == entry && player.mediaItemCount > 0)) return
        cancelRecovery()
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

    fun retry() {
        checkMainThread()
        val entry = mutableState.value.entry ?: return
        val position = if (entry.kind == MediaKind.LIVE) 0 else player.currentPosition
        cancelRecovery()
        generation = recovery.startEntry()
        mutableState.value = mutableState.value.copy(error = null, recovering = false)
        prepare(entry, position, true)
    }

    fun togglePlayPause() {
        checkMainThread()
        if (player.playWhenReady) {
            cancelRecovery()
            player.pause()
        } else if (mutableState.value.error != null || player.playbackState == Player.STATE_IDLE) {
            retry()
        } else {
            player.play()
        }
    }

    fun pauseForBackground() {
        checkMainThread()
        resumeAfterBackground = player.playWhenReady || mutableState.value.recovering
        cancelRecovery()
        player.pause()
    }

    fun resumeForeground() {
        checkMainThread()
        if (!resumeAfterBackground) return
        resumeAfterBackground = false
        if (player.playbackState == Player.STATE_IDLE && mutableState.value.error == null) retry()
        else player.play()
    }

    fun goLive() {
        checkMainThread()
        if (player.isCurrentMediaItemLive) player.seekToDefaultPosition()
        else if (mutableState.value.entry?.kind == MediaKind.LIVE) retry()
    }

    fun stop() {
        checkMainThread()
        cancelRecovery()
        recovery.stop()
        player.pause()
        player.stop()
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
        scope.cancel()
        player.removeListener(listener)
        player.removeAnalyticsListener(analytics)
        mediaSession.release()
        player.release()
    }

    private fun prepare(entry: MediaEntry, positionMs: Long, play: Boolean) {
        val uri = Uri.parse(entry.streamUrl)
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
            .setDefaultRequestProperties(entry.requestHeaders)
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
        when (entry.containerExtension.lowercase().removePrefix(".")) {
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
        player.playWhenReady = play
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
        val position = if (entry.kind == MediaKind.LIVE) 0 else position()
        player.stop()
        mutableState.value = mutableState.value.copy(recovering = true, error = null)
        retryJob = scope.launch {
            delay(ticket.delayMs)
            if (!recovery.isCurrent(ticket.generation) || disposed) return@launch
            retryJob = null
            mutableState.value = mutableState.value.copy(recovering = false, retries = mutableState.value.retries + 1)
            prepare(entry, position, true)
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
        mutableState.value = mutableState.value.copy(
            isPlaying = player.isPlaying,
            playWhenReady = player.playWhenReady,
            buffering = player.playbackState == Player.STATE_BUFFERING && player.playWhenReady,
            positionMs = player.currentPosition.coerceAtLeast(0),
            durationMs = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0,
            bufferMs = player.totalBufferedDuration.coerceAtLeast(0),
            liveOffsetMs = player.currentLiveOffset.takeIf { it != C.TIME_UNSET }?.coerceAtLeast(0) ?: 0,
            bitrate = format?.bitrate?.coerceAtLeast(0) ?: 0,
            width = player.videoSize.width,
            height = player.videoSize.height,
            frameRate = format?.frameRate?.coerceAtLeast(0f) ?: 0f,
        )
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
