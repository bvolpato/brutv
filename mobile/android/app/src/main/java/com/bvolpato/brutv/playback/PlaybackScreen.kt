package com.bvolpato.brutv.playback

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.text.format.DateFormat
import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.outlined.AspectRatio
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Equalizer
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Forward10
import androidx.compose.material.icons.outlined.LiveTv
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Replay
import androidx.compose.material.icons.outlined.Replay10
import androidx.compose.material.icons.outlined.SkipNext
import androidx.compose.material.icons.outlined.SkipPrevious
import androidx.compose.material.icons.outlined.Subtitles
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import com.bvolpato.brutv.data.Programme
import com.bvolpato.brutv.data.XmltvGuide
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.delay

@Composable
@OptIn(UnstableApi::class)
internal fun PlaybackScreen(
    controller: PlaybackController,
    entry: MediaEntry,
    queue: List<MediaEntry>,
    profile: BufferProfile,
    showStats: Boolean,
    liveRewind: Boolean,
    defaultAspectMode: String,
    isTv: Boolean,
    isPt: Boolean,
    resumePositionFor: (String) -> Long,
    epgLookup: (MediaEntry) -> List<Programme>,
    onRequestGuide: (MediaEntry) -> Unit,
    onOpenGuide: () -> Unit,
    onClose: (MediaEntry?, Long, Long) -> Unit,
    onItemChanged: (MediaEntry) -> Unit,
    onPosition: (MediaEntry, Long, Long) -> Unit,
    onCommitPosition: (MediaEntry, Long, Long) -> Unit,
    onEnded: (MediaEntry) -> Unit,
    onAspectChanged: (String) -> Unit,
    onTrackPreferencesChanged: (audioLang: String?, subtitleLang: String?, subtitlesEnabled: Boolean) -> Unit,
    onToggleFavorite: (MediaEntry) -> Unit,
    isFavorite: (String) -> Boolean,
    onPlayerChanged: (Player?) -> Unit,
    isInPictureInPictureMode: Boolean = false,
) {
    val context = LocalContext.current
    val activity = remember(context) { context.activity() }
    val lifecycleOwner = LocalLifecycleOwner.current
    // Structural snapshot only: 500 ms telemetry is isolated to visible progress/HUD leaf composables.
    val snapshot by controller.state.collectAsState()
    val current = snapshot.entry ?: entry
    val positionCallback by rememberUpdatedState(onPosition)
    val commitPositionCallback by rememberUpdatedState(onCommitPosition)
    val endedCallback by rememberUpdatedState(onEnded)
    val itemCallback by rememberUpdatedState(onItemChanged)
    val playerCallback by rememberUpdatedState(onPlayerChanged)
    val resumeLookup by rememberUpdatedState(resumePositionFor)
    var guideOpen by remember { mutableStateOf(false) }
    var trackDialog by remember { mutableIntStateOf(C.TRACK_TYPE_UNKNOWN) }
    var aspect by remember(defaultAspectMode) { mutableIntStateOf(aspectKeyToResizeMode(defaultAspectMode)) }
    var statsVisible by remember(showStats) { mutableStateOf(showStats) }
    val isInPip = isInPictureInPictureMode
    val pipActive by rememberUpdatedState(isInPictureInPictureMode)
    var wasInPip by remember { mutableStateOf(false) }
    var favoriteRefresh by remember { mutableIntStateOf(0) }
    val retryFocus = remember { FocusRequester() }
    val playPauseFocus = remember { FocusRequester() }
    val rootFocus = remember { FocusRequester() }

    // Accelerated D-pad seek state on TV.
    var seekBurstCount by remember { mutableIntStateOf(0) }
    var seekBurstDirection by remember { mutableIntStateOf(0) }
    var lastSeekKeyNanos by remember { mutableLongStateOf(0L) }
    var seekIndicatorText by remember { mutableStateOf<String?>(null) }

    fun savePosition(force: Boolean = false) {
        snapshot.entry?.let {
            val pos = controller.position()
            val dur = controller.durationMs()
            if (force) commitPositionCallback(it, pos, dur) else positionCallback(it, pos, dur)
        }
    }

    fun select(next: MediaEntry) {
        if (next.id == current.id) return
        savePosition(force = true)
        controller.select(next, resumeLookup(next.id))
        itemCallback(next)
        guideOpen = false
    }

    fun changeChannel(offset: Int) {
        if (queue.size < 2) return
        val index = queue.indexOfFirst { it.id == current.id }.coerceAtLeast(0)
        for (step in 1..queue.size) {
            val candidate = queue[(index + offset * step + queue.size * 2) % queue.size]
            if (candidate.streamUrl.isNotBlank()) {
                select(candidate)
                return
            }
        }
    }

    fun close() {
        val activeEntry = snapshot.entry ?: current
        val position = controller.position()
        val duration = controller.durationMs()
        if (controller.canCommitPosition()) {
            commitPositionCallback(activeEntry, position, duration)
        }
        controller.standby()
        playerCallback(null)
        onClose(activeEntry, position, duration)
    }

    fun performAcceleratedSeek(direction: Int) {
        if (!snapshot.liveSeekable && current.kind == MediaKind.LIVE) return
        val now = System.nanoTime()
        if (direction == seekBurstDirection && now - lastSeekKeyNanos <= 1_500_000_000L) {
            seekBurstCount = (seekBurstCount + 1).coerceAtMost(8)
        } else {
            seekBurstDirection = direction
            seekBurstCount = 1
        }
        lastSeekKeyNanos = now
        val stepMs = when {
            seekBurstCount >= 6 -> 120_000L
            seekBurstCount >= 4 -> 60_000L
            seekBurstCount >= 2 -> 30_000L
            else -> 10_000L
        }
        controller.seekBy(direction * stepMs)
        val sign = if (direction > 0) "+" else "-"
        seekIndicatorText = "$sign${stepMs / 1_000L}s"
    }

    LaunchedEffect(seekIndicatorText, lastSeekKeyNanos) {
        if (seekIndicatorText != null) {
            delay(1_200L)
            seekIndicatorText = null
        }
    }

    DisposableEffect(controller) {
        playerCallback(controller.controlPlayer)
        onDispose {
            if (controller.canCommitPosition()) {
                controller.state.value.entry?.let {
                    commitPositionCallback(it, controller.position(), controller.durationMs())
                }
            }
            playerCallback(null)
            controller.standby()
        }
    }
    DisposableEffect(activity, isTv) {
        val insets = activity?.let { WindowCompat.getInsetsController(it.window, it.window.decorView) }
        if (!isTv) {
            insets?.hide(WindowInsetsCompat.Type.systemBars())
            insets?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        onDispose { if (!isTv) insets?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    LaunchedEffect(controller, entry.id) {
        controller.select(entry, resumeLookup(entry.id))
    }
    LaunchedEffect(current.id) {
        if (current.kind == MediaKind.LIVE) {
            onRequestGuide(current)
        }
    }
    // Auto-clear resume and auto-play next episode on STATE_ENDED.
    var lastHandledEndedEvent by remember(controller) { mutableLongStateOf(snapshot.endedEvent) }
    LaunchedEffect(snapshot.endedEvent) {
        if (snapshot.endedEvent > lastHandledEndedEvent) {
            lastHandledEndedEvent = snapshot.endedEvent
            val endedEntry = snapshot.entry ?: return@LaunchedEffect
            if (endedEntry.kind != MediaKind.LIVE) {
                endedCallback(endedEntry)
                if (endedEntry.kind == MediaKind.EPISODE) {
                    val idx = queue.indexOfFirst { it.id == endedEntry.id }
                    if (idx >= 0 && idx + 1 < queue.size) {
                        val nextEp = queue[idx + 1]
                        if (nextEp.streamUrl.isNotBlank()) {
                            controller.select(nextEp, resumeLookup(nextEp.id))
                            itemCallback(nextEp)
                        }
                    }
                }
            }
        }
    }
    LaunchedEffect(snapshot.error, isInPip) {
        if (isTv && snapshot.error != null && !isInPip) runCatching { retryFocus.requestFocus() }
    }
    var wasPlayWhenReady by remember(controller, entry.id) { mutableStateOf(false) }
    LaunchedEffect(snapshot.playWhenReady) {
        if (wasPlayWhenReady && !snapshot.playWhenReady && controller.canCommitPosition()) {
            controller.state.value.entry?.let {
                commitPositionCallback(it, controller.position(), controller.durationMs())
            }
        }
        wasPlayWhenReady = snapshot.playWhenReady
    }
    LaunchedEffect(isInPip, lifecycleOwner, controller) {
        if (wasInPip && !isInPip && !lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            if (controller.canCommitPosition()) {
                controller.state.value.entry?.let {
                    commitPositionCallback(it, controller.position(), controller.durationMs())
                }
            }
            controller.pauseForBackground()
        }
        wasInPip = isInPip
    }
    // Periodic VOD progress save every 30s (pause/stop/close/switch flush immediately).
    LaunchedEffect(controller) {
        while (true) {
            delay(30_000L)
            if (controller.canCommitPosition()) {
                controller.state.value.entry?.let {
                    positionCallback(it, controller.position(), controller.durationMs())
                }
            }
        }
    }
    DisposableEffect(lifecycleOwner, controller, activity) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> if (!pipActive &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || activity?.isInPictureInPictureMode != true)
                ) {
                    if (controller.canCommitPosition()) {
                        controller.state.value.entry?.let {
                            commitPositionCallback(it, controller.position(), controller.durationMs())
                        }
                    }
                    controller.pauseForBackground()
                }
                Lifecycle.Event.ON_START -> controller.resumeForeground()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var controlsVisible by remember { mutableStateOf(true) }
    var lastInteractionNanos by remember { mutableLongStateOf(System.nanoTime()) }
    var suppressNextSelectUp by remember { mutableStateOf(false) }
    fun pokeControls() {
        controlsVisible = true
        lastInteractionNanos = System.nanoTime()
    }

    LaunchedEffect(current.id) {
        pokeControls()
    }

    LaunchedEffect(controlsVisible, lastInteractionNanos, snapshot.isPlaying, guideOpen, trackDialog) {
        if (controlsVisible && snapshot.isPlaying && !guideOpen && trackDialog == C.TRACK_TYPE_UNKNOWN) {
            delay(3_200L)
            controlsVisible = false
        }
    }

    // Ensure TV D-pad focus lands reliably on Play/Pause whenever controls open, and on root when hidden.
    val showOverlay = (controlsVisible || !snapshot.isPlaying) && !isInPip
    LaunchedEffect(showOverlay, isTv, guideOpen, trackDialog, snapshot.error) {
        if (!isTv || isInPip) return@LaunchedEffect
        if (showOverlay && !guideOpen && trackDialog == C.TRACK_TYPE_UNKNOWN && snapshot.error == null) {
            runCatching { playPauseFocus.requestFocus() }
        } else if (!showOverlay && !guideOpen && trackDialog == C.TRACK_TYPE_UNKNOWN && snapshot.error == null) {
            runCatching { rootFocus.requestFocus() }
        }
    }

    BackHandler {
        when {
            guideOpen -> guideOpen = false
            trackDialog != C.TRACK_TYPE_UNKNOWN -> trackDialog = C.TRACK_TYPE_UNKNOWN
            !controlsVisible -> pokeControls()
            else -> close()
        }
    }

    Surface(color = Color.Black, modifier = Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .then(if (isInPip) Modifier else Modifier.safeDrawingPadding())
                .then(if (isTv) Modifier.focusRequester(rootFocus).focusable() else Modifier)
                .onPreviewKeyEvent { event ->
                    val native = event.nativeKeyEvent
                    val isSelectKey = native.keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
                        native.keyCode == KeyEvent.KEYCODE_ENTER ||
                        native.keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER
                    if (isSelectKey && native.action == KeyEvent.ACTION_UP && suppressNextSelectUp) {
                        suppressNextSelectUp = false
                        return@onPreviewKeyEvent true
                    }
                    if (native.action != KeyEvent.ACTION_DOWN) return@onPreviewKeyEvent false
                    val wasHidden = !controlsVisible
                    // Accelerated D-pad seek when controls are hidden on TV for seekable content.
                    if (isTv && wasHidden && !guideOpen && trackDialog == C.TRACK_TYPE_UNKNOWN &&
                        (current.kind != MediaKind.LIVE || snapshot.liveSeekable) &&
                        (native.keyCode == KeyEvent.KEYCODE_DPAD_LEFT || native.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT)
                    ) {
                        performAcceleratedSeek(if (native.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 1 else -1)
                        return@onPreviewKeyEvent true
                    }
                    pokeControls()
                    val isRevealNavKey = isSelectKey ||
                        native.keyCode == KeyEvent.KEYCODE_DPAD_UP ||
                        native.keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                        native.keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                        native.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                    if (wasHidden && !guideOpen && trackDialog == C.TRACK_TYPE_UNKNOWN && isRevealNavKey) {
                        if (isSelectKey) suppressNextSelectUp = true
                        return@onPreviewKeyEvent true
                    }
                    when (native.keyCode) {
                        KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_MEDIA_NEXT -> { changeChannel(1); true }
                        KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { changeChannel(-1); true }
                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { controller.togglePlayPause(); true }
                        KeyEvent.KEYCODE_MEDIA_PLAY -> {
                            if (!snapshot.playWhenReady) controller.togglePlayPause()
                            true
                        }
                        KeyEvent.KEYCODE_MEDIA_PAUSE -> { controller.pause(); true }
                        KeyEvent.KEYCODE_MEDIA_STOP -> { controller.stop(); true }
                        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { performAcceleratedSeek(1); true }
                        KeyEvent.KEYCODE_MEDIA_REWIND -> { performAcceleratedSeek(-1); true }
                        KeyEvent.KEYCODE_GUIDE, KeyEvent.KEYCODE_INFO -> {
                            if (queue.isNotEmpty()) {
                                guideOpen = true
                                onOpenGuide()
                            }
                            true
                        }
                        else -> false
                    }
                },
        ) {
            AndroidView(
                factory = { viewContext ->
                    PlayerView(viewContext).apply {
                        player = controller.player
                        useController = false
                        resizeMode = aspect
                        isFocusable = !isTv
                    }
                },
                modifier = Modifier
                    .fillMaxSize()
                    .then(
                        if (!isTv) {
                            Modifier.clickable {
                                if (controlsVisible) controlsVisible = false else pokeControls()
                            }
                        } else {
                            Modifier
                        },
                    ),
                update = { view ->
                    view.player = controller.player
                    view.resizeMode = aspect
                    view.useController = false
                    view.isFocusable = !isTv
                    view.keepScreenOn = snapshot.isPlaying || snapshot.buffering || snapshot.recovering
                },
                onRelease = { view ->
                    view.keepScreenOn = false
                    view.player = null
                },
            )

            AnimatedVisibility(
                visible = showOverlay,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.fillMaxSize(),
            ) {
                val activeProgrammes = if (current.kind == MediaKind.LIVE) epgLookup(current) else emptyList()
                val (nowProgramme, nextProgramme) = remember(activeProgrammes, current.id) {
                    XmltvGuide.findNowAndNext(activeProgrammes)
                }
                Box(Modifier.fillMaxSize()) {
                    Row(
                        Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color(0xE6101A20), Color.Transparent)))
                            .padding(horizontal = if (isTv) 32.dp else 12.dp, vertical = if (isTv) 16.dp else 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PlayerButton(if (isPt) "Voltar" else "Back", Icons.AutoMirrored.Outlined.ArrowBack) { close() }
                        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                            Text(
                                current.name,
                                color = Color.White,
                                style = MaterialTheme.typography.titleMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (current.kind == MediaKind.LIVE && (nowProgramme != null || nextProgramme != null)) {
                                val epgLine = buildString {
                                    nowProgramme?.let {
                                        append(if (isPt) "Agora: " else "Now: ")
                                        append(it.title)
                                    }
                                    nextProgramme?.let {
                                        if (isNotEmpty()) append(" · ")
                                        append(if (isPt) "A seguir: " else "Next: ")
                                        append(it.title)
                                    }
                                }
                                Text(
                                    epgLine,
                                    color = Color(0xFF9BD7FF),
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        if (current.kind == MediaKind.LIVE && snapshot.canGoLive) {
                            PlayerButton(if (isPt) "Ao vivo" else "Go live", Icons.Outlined.LiveTv) {
                                pokeControls()
                                controller.goLive()
                            }
                        }
                    }

                    Column(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xE6101A20))))
                            .padding(bottom = if (isTv) 20.dp else 10.dp),
                    ) {
                        if (current.kind == MediaKind.LIVE) {
                            if (liveRewind || snapshot.timeShiftAvailable || snapshot.timeShiftNotice != null) {
                                LiveBufferBanner(
                                    controller = controller,
                                    snapshot = snapshot,
                                    isTv = isTv,
                                    isPt = isPt,
                                )
                            }
                        } else if (snapshot.durationMs > 0) {
                            VodProgressBar(
                                controller = controller,
                                isTv = isTv,
                                onInteraction = ::pokeControls,
                            )
                        }
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState())
                                .padding(horizontal = if (isTv) 32.dp else 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            PlayerButton(
                                label = if (snapshot.playWhenReady) (if (isPt) "Pausar" else "Pause") else (if (isPt) "Reproduzir" else "Play"),
                                icon = if (snapshot.playWhenReady) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                                primary = true,
                                modifier = Modifier.focusRequester(playPauseFocus),
                            ) {
                                pokeControls()
                                controller.togglePlayPause()
                            }
                            if (snapshot.liveSeekable || current.kind != MediaKind.LIVE) {
                                PlayerButton(if (isPt) "-10s" else "Back 10s", Icons.Outlined.Replay10) {
                                    pokeControls()
                                    controller.seekBy(-10_000)
                                }
                                PlayerButton(if (isPt) "+10s" else "Forward 10s", Icons.Outlined.Forward10) {
                                    pokeControls()
                                    controller.seekBy(10_000)
                                }
                            }
                            if (queue.size > 1) {
                                PlayerButton(if (isPt) "Anterior" else "Previous", Icons.Outlined.SkipPrevious) {
                                    pokeControls()
                                    changeChannel(-1)
                                }
                                PlayerButton(if (isPt) "Próximo" else "Next", Icons.Outlined.SkipNext) {
                                    pokeControls()
                                    changeChannel(1)
                                }
                            }
                            if (queue.isNotEmpty()) {
                                PlayerButton(if (isPt) "Guia" else "Guide", Icons.AutoMirrored.Outlined.ViewList) {
                                    pokeControls()
                                    guideOpen = true
                                    onOpenGuide()
                                }
                            }
                            val favorite = remember(current.id, favoriteRefresh, isFavorite) { isFavorite(current.id) }
                            PlayerButton(
                                label = if (favorite) (if (isPt) "Remover" else "Unfavorite") else (if (isPt) "Favoritar" else "Favorite"),
                                icon = if (favorite) Icons.Outlined.Favorite else Icons.Outlined.FavoriteBorder,
                            ) {
                                pokeControls()
                                onToggleFavorite(current)
                                favoriteRefresh += 1
                            }
                            PlayerButton(
                                label = "${if (isPt) "Tela" else "Aspect"}: ${aspectLabel(aspect, isPt)}",
                                icon = Icons.Outlined.AspectRatio,
                            ) {
                                pokeControls()
                                aspect = when (aspect) {
                                    AspectRatioFrameLayout.RESIZE_MODE_FIT -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                                    AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                                    else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                                }
                                onAspectChanged(resizeModeToAspectKey(aspect))
                            }
                            PlayerButton(
                                label = if (isPt) "Áudio" else "Audio",
                                icon = Icons.AutoMirrored.Outlined.VolumeUp,
                                enabled = snapshot.tracks.groups.any { it.type == C.TRACK_TYPE_AUDIO && it.isSupported },
                            ) {
                                pokeControls()
                                trackDialog = C.TRACK_TYPE_AUDIO
                            }
                            PlayerButton(
                                label = if (isPt) "Legendas" else "Subtitles",
                                icon = Icons.Outlined.Subtitles,
                                enabled = snapshot.tracks.groups.any { it.type == C.TRACK_TYPE_TEXT && it.isSupported },
                            ) {
                                pokeControls()
                                trackDialog = C.TRACK_TYPE_TEXT
                            }
                            PlayerButton(
                                label = if (statsVisible) (if (isPt) "Ocultar stats" else "Hide stats") else "Stats",
                                icon = Icons.Outlined.Equalizer,
                            ) {
                                pokeControls()
                                statsVisible = !statsVisible
                            }
                        }
                    }
                }
            }

            if (!isInPip && seekIndicatorText != null) {
                Surface(
                    color = Color(0xCC0D1B22),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.align(Alignment.Center),
                ) {
                    Text(
                        seekIndicatorText.orEmpty(),
                        color = Color(0xFF38D9CA),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
                    )
                }
            }

            if (!isInPip && (snapshot.buffering || snapshot.recovering)) {
                Column(
                    Modifier.align(Alignment.Center).background(Color(0xD91A1D24), MaterialTheme.shapes.medium).padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    CircularProgressIndicator(color = Color(0xFF9BD7FF))
                    Text(
                        if (snapshot.recovering) (if (isPt) "Reconectando…" else "Reconnecting…") else (if (isPt) "Carregando…" else "Buffering…"),
                        color = Color.White,
                    )
                }
            }
            if (!isInPip && snapshot.error != null) {
                Surface(
                    color = Color(0xF21A1D24),
                    shape = MaterialTheme.shapes.large,
                    modifier = Modifier.align(Alignment.Center).padding(if (isTv) 64.dp else 24.dp),
                ) {
                    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(if (isPt) "Reprodução indisponível" else "Playback unavailable", style = MaterialTheme.typography.titleLarge, color = Color.White)
                        Text(snapshot.error.orEmpty(), color = Color.White)
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { controller.retry() }, modifier = Modifier.focusRequester(retryFocus)) {
                                Icon(Icons.Outlined.Replay, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(if (isPt) "Tentar novamente" else "Retry")
                            }
                            PlayerButton(if (isPt) "Voltar" else "Back", Icons.AutoMirrored.Outlined.ArrowBack) { close() }
                            if (queue.size > 1) PlayerButton(if (isPt) "Próximo" else "Next", Icons.Outlined.SkipNext) { changeChannel(1) }
                        }
                    }
                }
            }
            if (statsVisible && !isInPip) {
                StatisticsOverlay(
                    controller = controller,
                    snapshot = snapshot,
                    profile = profile,
                    isPt = isPt,
                    modifier = Modifier.align(Alignment.TopEnd).padding(top = 68.dp, end = if (isTv) 36.dp else 12.dp),
                )
            }
        }
    }

    if (guideOpen) {
        val activeIndex = remember(queue, current.id) {
            queue.indexOfFirst { it.id == current.id }.coerceAtLeast(0)
        }
        val guideListState = rememberLazyListState(initialFirstVisibleItemIndex = activeIndex)
        LaunchedEffect(guideOpen, activeIndex) {
            if (guideOpen) {
                guideListState.scrollToItem(activeIndex)
            }
        }
        val activeProgrammes = if (current.kind == MediaKind.LIVE) epgLookup(current) else emptyList()
        val (nowProg, nextProg) = remember(activeProgrammes, current.id) {
            XmltvGuide.findNowAndNext(activeProgrammes)
        }
        AlertDialog(
            onDismissRequest = { guideOpen = false },
            title = {
                Text(
                    if (current.kind == MediaKind.LIVE) {
                        if (isPt) "Guia de canais" else "Channel guide"
                    } else {
                        if (isPt) "Fila de reprodução" else "Play queue"
                    },
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (current.kind == MediaKind.LIVE && (nowProg != null || nextProg != null)) {
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color(0xFF132630))
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            nowProg?.let {
                                Text(
                                    "${if (isPt) "Agora" else "Now"} · ${it.title}${formatProgrammeRange(it)}",
                                    color = Color(0xFF38D9CA),
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            nextProg?.let {
                                Text(
                                    "${if (isPt) "A seguir" else "Next"} · ${it.title}${formatProgrammeRange(it)}",
                                    color = Color(0xFFCBD0D8),
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                    LazyColumn(
                        state = guideListState,
                        modifier = Modifier.height(if (isTv) 340.dp else 380.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        items(queue, key = { it.id }) { item ->
                            val active = item.id == current.id
                            val itemNow = if (item.kind == MediaKind.LIVE) {
                                XmltvGuide.findNowAndNext(epgLookup(item)).first
                            } else {
                                null
                            }
                            DialogRowButton(
                                label = if (active) "${if (isPt) "Reproduzindo" else "Playing"} · ${item.name}" else item.name,
                                subtitle = itemNow?.let { "${it.title}${formatProgrammeRange(it)}" },
                                icon = if (active) Icons.Outlined.Check else Icons.Outlined.PlayArrow,
                                selected = active,
                                onClick = { select(item); guideOpen = false },
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { guideOpen = false }) {
                    Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (isPt) "Fechar" else "Close")
                }
            },
        )
    }
    if (trackDialog != C.TRACK_TYPE_UNKNOWN) {
        TrackDialog(
            player = controller.player,
            tracks = snapshot.tracks,
            type = trackDialog,
            isPt = isPt,
            onTrackPreferencesChanged = onTrackPreferencesChanged,
            onDismiss = { trackDialog = C.TRACK_TYPE_UNKNOWN },
        )
    }
}

@Composable
private fun LiveBufferBanner(
    controller: PlaybackController,
    snapshot: PlaybackSnapshot,
    isTv: Boolean,
    isPt: Boolean,
) {
    val telemetry by controller.telemetry.collectAsState()
    val message = snapshot.timeShiftNotice ?: if (snapshot.timeShiftAvailable) {
        val mins = telemetry.timeShiftDurationMs / 60_000
        val secs = (telemetry.timeShiftDurationMs / 1000 % 60).toString().padStart(2, '0')
        val mib = telemetry.timeShiftBytes / (1024 * 1024)
        val status = if (snapshot.timeShiftRecording) {
            if (!snapshot.playWhenReady) {
                if (isPt) "Gravando em pausa" else "Recording while paused"
            } else {
                if (isPt) "Gravando" else "Recording"
            }
        } else {
            if (isPt) "Gravação pausada" else "Recording stopped"
        }
        "${if (isPt) "Buffer ao vivo" else "Live buffer"} $mins:$secs · $mib MiB · $status"
    } else {
        if (isPt) "Preparando buffer ao vivo…" else "Preparing the temporary live buffer…"
    }
    Text(
        message,
        color = Color(0xFFCBD0D8),
        style = MaterialTheme.typography.labelSmall,
        modifier = Modifier.padding(horizontal = if (isTv) 32.dp else 14.dp, vertical = 3.dp),
    )
}

@Composable
private fun VodProgressBar(
    controller: PlaybackController,
    isTv: Boolean,
    onInteraction: () -> Unit,
) {
    val telemetry by controller.telemetry.collectAsState()
    val duration = telemetry.durationMs.coerceAtLeast(1L)
    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableFloatStateOf(0f) }
    val displayPos = if (dragging) (dragFraction * duration).toLong() else telemetry.positionMs

    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = if (isTv) 32.dp else 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(formatTime(displayPos), color = Color.White, style = MaterialTheme.typography.labelSmall)
        if (!isTv) {
            Slider(
                value = if (dragging) dragFraction else (telemetry.positionMs.toFloat() / duration).coerceIn(0f, 1f),
                onValueChange = { fraction ->
                    dragging = true
                    dragFraction = fraction
                    onInteraction()
                },
                onValueChangeFinished = {
                    val targetMs = (dragFraction * duration).toLong()
                    dragging = false
                    controller.seekTo(targetMs)
                    onInteraction()
                },
                modifier = Modifier.weight(1f).height(28.dp),
                colors = SliderDefaults.colors(
                    thumbColor = Color(0xFF38D9CA),
                    activeTrackColor = Color(0xFF38D9CA),
                    inactiveTrackColor = Color(0x55FFFFFF),
                ),
            )
        } else {
            Box(
                Modifier
                    .weight(1f)
                    .height(5.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(Color(0x55FFFFFF)),
            ) {
                val fraction = (telemetry.positionMs.toFloat() / duration).coerceIn(0f, 1f)
                Box(
                    Modifier
                        .fillMaxWidth(fraction)
                        .fillMaxHeight()
                        .background(Color(0xFF38D9CA)),
                )
            }
        }
        Text(formatTime(duration), color = Color(0xFFCBD0D8), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun PlayerButton(
    label: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    primary: Boolean = false,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val accent = Color(0xFF38D9CA)
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.onFocusChanged { focused = it.isFocused },
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = if (primary) accent else Color(0xFF1B2932),
            contentColor = if (primary) Color(0xFF06201F) else Color.White,
            disabledContentColor = Color(0xFF858B94),
        ),
        border = BorderStroke(
            if (focused) 3.dp else 1.dp,
            when {
                !focused -> Color(0xFF42616B)
                primary -> Color.White
                else -> accent
            },
        ),
        shape = RoundedCornerShape(12.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, maxLines = 1)
    }
}

@Composable
@OptIn(UnstableApi::class)
private fun TrackDialog(
    player: Player,
    tracks: Tracks,
    type: Int,
    isPt: Boolean,
    onTrackPreferencesChanged: (audioLang: String?, subtitleLang: String?, subtitlesEnabled: Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val choices = remember(tracks, type) {
        tracks.groups.filter { it.type == type }.flatMap { group ->
            (0 until group.length).filter { group.isTrackSupported(it) }.map { TrackChoice(group, it) }
        }
    }
    fun choose(choice: TrackChoice?) {
        val parameters = player.trackSelectionParameters.buildUpon().clearOverridesOfType(type)
            .setTrackTypeDisabled(type, type == C.TRACK_TYPE_TEXT && choice == null)
        if (choice != null) {
            parameters.setOverrideForType(TrackSelectionOverride(choice.group.mediaTrackGroup, listOf(choice.index)))
        }
        val selectedLang = choice?.let {
            it.group.getTrackFormat(it.index).language?.takeUnless { lang -> lang.isBlank() || lang == "und" }
        }
        if (type == C.TRACK_TYPE_AUDIO) {
            if (selectedLang != null) parameters.setPreferredAudioLanguage(selectedLang)
            else parameters.setPreferredAudioLanguages()
            val curSubLang = player.trackSelectionParameters.preferredTextLanguages.firstOrNull()
            val curSubEnabled = !player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
            onTrackPreferencesChanged(selectedLang, curSubLang, curSubEnabled)
        } else if (type == C.TRACK_TYPE_TEXT) {
            val enabled = choice != null
            if (enabled && selectedLang != null) parameters.setPreferredTextLanguage(selectedLang)
            else if (!enabled) parameters.setPreferredTextLanguages()
            val curAudioLang = player.trackSelectionParameters.preferredAudioLanguages.firstOrNull()
            onTrackPreferencesChanged(curAudioLang, if (enabled) selectedLang else null, enabled)
        }
        player.trackSelectionParameters = parameters.build()
        onDismiss()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                if (type == C.TRACK_TYPE_AUDIO) {
                    if (isPt) "Faixa de áudio" else "Audio track"
                } else {
                    if (isPt) "Legendas" else "Subtitles"
                },
            )
        },
        text = {
            LazyColumn(Modifier.height(280.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                item {
                    DialogRowButton(
                        label = if (type == C.TRACK_TYPE_AUDIO) {
                            if (isPt) "Automático" else "Automatic"
                        } else {
                            if (isPt) "Desativado" else "Off"
                        },
                        icon = if (type == C.TRACK_TYPE_AUDIO) Icons.AutoMirrored.Outlined.VolumeUp else Icons.Outlined.Subtitles,
                        selected = false,
                        onClick = { choose(null) },
                    )
                }
                items(choices) { choice ->
                    val format = choice.group.getTrackFormat(choice.index)
                    val label = formatTrackLabel(format, type, choice.index, isPt)
                    val detail = formatTrackMeta(format, type)
                    val selected = choice.group.isTrackSelected(choice.index)
                    DialogRowButton(
                        label = if (selected) "${if (isPt) "Selecionado" else "Selected"} · $label" else label,
                        subtitle = detail,
                        icon = if (selected) Icons.Outlined.Check else if (type == C.TRACK_TYPE_AUDIO) Icons.AutoMirrored.Outlined.VolumeUp else Icons.Outlined.Subtitles,
                        selected = selected,
                        onClick = { choose(choice) },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (isPt) "Fechar" else "Close")
            }
        },
    )
}

@Composable
private fun DialogRowButton(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    subtitle: String? = null,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(10.dp)
    val accent = Color(0xFF38D9CA)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .clip(shape)
            .background(
                when {
                    focused -> Color(0xFF1E3344)
                    selected -> Color(0xFF163C43)
                    else -> Color.Transparent
                },
            )
            .border(
                width = if (focused) 2.dp else 1.dp,
                color = when {
                    focused -> accent
                    selected -> Color(0xFF2B7979)
                    else -> Color.Transparent
                },
                shape = shape,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (focused || selected) accent else Color.White,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                label,
                color = Color.White,
                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    subtitle,
                    color = Color(0xFF9AAEB4),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private data class TrackChoice(val group: Tracks.Group, val index: Int)

@Composable
private fun StatisticsOverlay(
    controller: PlaybackController,
    snapshot: PlaybackSnapshot,
    profile: BufferProfile,
    isPt: Boolean,
    modifier: Modifier,
) {
    val telemetry by controller.telemetry.collectAsState()
    Column(
        modifier.background(Color(0xD91A1D24), MaterialTheme.shapes.small).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Stat("Buffer", "${decimal(telemetry.bufferMs / 1_000.0)} s")
        Stat(if (isPt) "Vídeo" else "Video", if (telemetry.width > 0) "${telemetry.width} × ${telemetry.height}" else (if (isPt) "Aguardando" else "Waiting"))
        Stat("Bitrate", if (telemetry.bitrate > 0) "${decimal(telemetry.bitrate / 1_000_000.0)} Mbps" else (if (isPt) "Desconhecido" else "Unknown"))
        Stat(if (isPt) "Banda" else "Bandwidth", if (telemetry.bandwidthEstimate > 0) "${decimal(telemetry.bandwidthEstimate / 1_000_000.0)} Mbps" else (if (isPt) "Medindo" else "Measuring"))
        Stat("FPS", if (telemetry.frameRate > 0) decimal(telemetry.frameRate.toDouble()) else (if (isPt) "Desconhecido" else "Unknown"))
        Stat(if (isPt) "Quedas" else "Dropped", telemetry.droppedFrames.toString())
        Stat(if (isPt) "Travamentos" else "Stalls / retries", "${telemetry.stalls} / ${telemetry.retries}")
        if (snapshot.entry?.kind == MediaKind.LIVE && telemetry.liveOffsetMs > 0) {
            Stat(if (isPt) "Atraso" else "Live offset", "${decimal(telemetry.liveOffsetMs / 1_000.0)} s")
        }
        if (snapshot.timeShiftAvailable) {
            Stat(if (isPt) "Histórico" else "Saved history", "${decimal(telemetry.timeShiftDurationMs / 1_000.0)} s")
            Stat(if (isPt) "Armaz. temp." else "Temp storage", "${decimal(telemetry.timeShiftBytes / 1_048_576.0)} MiB")
            Stat(if (isPt) "Gravação" else "Recording", if (snapshot.timeShiftRecording) (if (isPt) "Ativa" else "Active") else (if (isPt) "Parada" else "Stopped"))
        }
        Spacer(Modifier.height(4.dp))
        Text(profile.title, color = Color(0xFF9BD7FF), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Row {
        Text(label, color = Color(0xFFCBD0D8), style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(96.dp))
        Text(value, color = Color.White, style = MaterialTheme.typography.labelSmall)
    }
}

private fun formatProgrammeRange(programme: Programme): String {
    if (programme.startEpochSeconds <= 0 || programme.endEpochSeconds <= programme.startEpochSeconds) return ""
    val start = DateFormat.format("HH:mm", Date(programme.startEpochSeconds * 1_000L)).toString()
    val end = DateFormat.format("HH:mm", Date(programme.endEpochSeconds * 1_000L)).toString()
    return " ($start-$end)"
}

@OptIn(UnstableApi::class)
internal fun formatTrackLabel(format: Format, type: Int, index: Int, isPt: Boolean): String {
    val language = format.language?.takeUnless { it == "und" || it.isBlank() }
        ?.let { Locale.forLanguageTag(it).displayLanguage }
        ?.takeIf { it.isNotBlank() }
    val base = format.label?.takeIf { it.isNotBlank() } ?: language
    return base ?: if (type == C.TRACK_TYPE_AUDIO) {
        if (isPt) "Faixa ${index + 1}" else "Track ${index + 1}"
    } else {
        if (isPt) "Legenda ${index + 1}" else "Subtitle ${index + 1}"
    }
}

@OptIn(UnstableApi::class)
internal fun formatTrackMeta(format: Format, type: Int): String? {
    val parts = ArrayList<String>(3)
    val codec = when (format.sampleMimeType) {
        MimeTypes.AUDIO_AAC -> "AAC"
        MimeTypes.AUDIO_AC3 -> "AC-3"
        MimeTypes.AUDIO_E_AC3 -> "E-AC-3"
        MimeTypes.AUDIO_E_AC3_JOC -> "E-AC-3 Atmos"
        MimeTypes.AUDIO_AC4 -> "AC-4"
        MimeTypes.AUDIO_DTS -> "DTS"
        MimeTypes.AUDIO_DTS_HD -> "DTS-HD"
        MimeTypes.AUDIO_OPUS -> "Opus"
        MimeTypes.AUDIO_FLAC -> "FLAC"
        MimeTypes.AUDIO_MPEG -> "MP3"
        MimeTypes.AUDIO_MPEG_L2 -> "MP2"
        MimeTypes.TEXT_VTT -> "WebVTT"
        MimeTypes.APPLICATION_SUBRIP -> "SubRip"
        MimeTypes.TEXT_SSA -> "ASS/SSA"
        MimeTypes.APPLICATION_CEA608 -> "CEA-608"
        MimeTypes.APPLICATION_CEA708 -> "CEA-708"
        MimeTypes.APPLICATION_DVBSUBS -> "DVB"
        MimeTypes.APPLICATION_PGS -> "PGS"
        MimeTypes.APPLICATION_TTML -> "TTML"
        else -> format.codecs?.substringBefore('.')?.uppercase(Locale.ROOT)?.takeIf { it.isNotBlank() }
    }
    if (!codec.isNullOrBlank()) parts.add(codec)
    if (type == C.TRACK_TYPE_AUDIO && format.channelCount > 0) {
        val channels = when (format.channelCount) {
            1 -> "Mono"
            2 -> "Stereo"
            6 -> "5.1"
            8 -> "7.1"
            else -> "${format.channelCount}ch"
        }
        parts.add(channels)
    }
    if (type == C.TRACK_TYPE_AUDIO && format.bitrate > 0) {
        parts.add("${format.bitrate / 1000} kbps")
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun formatTime(ms: Long): String {
    val totalSeconds = (ms / 1000).coerceAtLeast(0)
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds % 3600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.ROOT, "%02d:%02d", minutes, seconds)
    }
}

private fun decimal(value: Double): String = String.format(Locale.US, "%.1f", value)

@OptIn(UnstableApi::class)
internal fun aspectKeyToResizeMode(key: String): Int = when (key) {
    "zoom" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
    "fill" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
    else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
}

@OptIn(UnstableApi::class)
internal fun resizeModeToAspectKey(mode: Int): String = when (mode) {
    AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> "zoom"
    AspectRatioFrameLayout.RESIZE_MODE_FILL -> "fill"
    else -> "fit"
}

@OptIn(UnstableApi::class)
private fun aspectLabel(aspect: Int, isPt: Boolean): String = when (aspect) {
    AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> "Zoom"
    AspectRatioFrameLayout.RESIZE_MODE_FILL -> if (isPt) "Esticar" else "Stretch"
    else -> if (isPt) "Ajustar" else "Fit"
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}
