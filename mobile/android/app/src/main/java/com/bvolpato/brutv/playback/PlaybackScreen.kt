package com.bvolpato.brutv.playback

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
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
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import kotlinx.coroutines.delay
import java.util.Locale

@Composable
@OptIn(UnstableApi::class)
fun PlaybackScreen(
    entry: MediaEntry,
    queue: List<MediaEntry>,
    profile: BufferProfile,
    showStats: Boolean,
    resumePositionMs: Long,
    isTv: Boolean,
    onClose: (Long) -> Unit,
    onItemChanged: (MediaEntry) -> Unit,
    onPosition: (MediaEntry, Long) -> Unit,
    onToggleFavorite: (MediaEntry) -> Unit,
    isFavorite: (String) -> Boolean,
    onPlayerChanged: (Player?) -> Unit,
    isInPictureInPictureMode: Boolean = false,
) {
    val context = LocalContext.current
    val activity = remember(context) { context.activity() }
    val lifecycleOwner = LocalLifecycleOwner.current
    val controller = remember(context.applicationContext, profile) { PlaybackController(context, profile) }
    val snapshot by controller.state.collectAsState()
    val current = snapshot.entry ?: entry
    val positionCallback by rememberUpdatedState(onPosition)
    val itemCallback by rememberUpdatedState(onItemChanged)
    val playerCallback by rememberUpdatedState(onPlayerChanged)
    var guideOpen by remember { mutableStateOf(false) }
    var trackDialog by remember { mutableIntStateOf(C.TRACK_TYPE_UNKNOWN) }
    var aspect by remember { mutableIntStateOf(AspectRatioFrameLayout.RESIZE_MODE_FIT) }
    var statsVisible by remember(showStats) { mutableStateOf(showStats) }
    val isInPip = isInPictureInPictureMode
    val pipActive by rememberUpdatedState(isInPictureInPictureMode)
    var favoriteRefresh by remember { mutableIntStateOf(0) }
    val retryFocus = remember { FocusRequester() }

    fun savePosition() {
        snapshot.entry?.let { positionCallback(it, controller.position()) }
    }

    fun select(next: MediaEntry) {
        if (next.id == current.id) return
        savePosition()
        controller.select(next)
        itemCallback(next)
        guideOpen = false
    }

    fun changeChannel(offset: Int) {
        if (queue.size < 2) return
        val index = queue.indexOfFirst { it.id == current.id }.coerceAtLeast(0)
        select(queue[(index + offset + queue.size) % queue.size])
    }

    fun close() {
        val position = controller.position()
        snapshot.entry?.let { positionCallback(it, position) }
        controller.release()
        playerCallback(null)
        onClose(position)
    }

    DisposableEffect(controller) {
        playerCallback(controller.controlPlayer)
        onDispose {
            controller.state.value.entry?.let { positionCallback(it, controller.position()) }
            playerCallback(null)
            controller.release()
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
    LaunchedEffect(controller, entry) { controller.select(entry, resumePositionMs) }
    LaunchedEffect(snapshot.error, isInPip) {
        if (isTv && snapshot.error != null && !isInPip) retryFocus.requestFocus()
    }
    LaunchedEffect(controller) {
        while (true) {
            delay(5_000)
            controller.state.value.entry?.let { positionCallback(it, controller.position()) }
        }
    }
    DisposableEffect(lifecycleOwner, controller, activity) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> if (!pipActive &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || activity?.isInPictureInPictureMode != true)) {
                    controller.state.value.entry?.let { positionCallback(it, controller.position()) }
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
    fun pokeControls() {
        controlsVisible = true
        lastInteractionNanos = System.nanoTime()
    }

    LaunchedEffect(current.id) {
        pokeControls()
    }

    LaunchedEffect(controlsVisible, lastInteractionNanos, snapshot.isPlaying) {
        if (controlsVisible && snapshot.isPlaying) {
            delay(2800L)
            controlsVisible = false
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
            Modifier.fillMaxSize().then(if (isInPip) Modifier else Modifier.safeDrawingPadding()).onPreviewKeyEvent { event ->
                if (event.nativeKeyEvent.action != KeyEvent.ACTION_DOWN) return@onPreviewKeyEvent false
                pokeControls()
                when (event.nativeKeyEvent.keyCode) {
                    KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_MEDIA_NEXT -> { changeChannel(1); true }
                    KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { changeChannel(-1); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { controller.togglePlayPause(); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY -> {
                        if (!snapshot.playWhenReady) controller.togglePlayPause()
                        true
                    }
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> { controller.pause(); true }
                    KeyEvent.KEYCODE_MEDIA_STOP -> { controller.stop(); true }
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
                        isFocusable = true
                        if (isTv) requestFocus()
                    }
                },
                modifier = Modifier
                    .fillMaxSize()
                    .clickable {
                        if (controlsVisible) controlsVisible = false else pokeControls()
                    },
                update = { view ->
                    view.player = controller.player
                    view.resizeMode = aspect
                    view.useController = false
                    view.keepScreenOn = snapshot.isPlaying || snapshot.buffering || snapshot.recovering
                },
                onRelease = { view ->
                    view.keepScreenOn = false
                    view.player = null
                },
            )

            AnimatedVisibility(
                visible = (controlsVisible || !snapshot.isPlaying) && !isInPip,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.fillMaxSize(),
            ) {
                Box(Modifier.fillMaxSize()) {
                    Row(
                        Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color(0xE6101A20), Color.Transparent)))
                            .padding(horizontal = if (isTv) 32.dp else 12.dp, vertical = if (isTv) 16.dp else 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PlayerButton("Back", Icons.AutoMirrored.Outlined.ArrowBack) { close() }
                        Text(
                            current.name,
                            modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                            color = Color.White,
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (current.kind == MediaKind.LIVE && snapshot.canGoLive) {
                            PlayerButton("Go live", Icons.Outlined.LiveTv) {
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
                            val message = snapshot.timeShiftNotice ?: if (snapshot.timeShiftAvailable) {
                                "Live buffer ${snapshot.timeShiftDurationMs / 60_000}:${(snapshot.timeShiftDurationMs / 1000 % 60).toString().padStart(2, '0')} · " +
                                    "${snapshot.timeShiftBytes / (1024 * 1024)} MiB · " +
                                    if (snapshot.timeShiftRecording) "Recording${if (!snapshot.playWhenReady) " while paused" else ""}" else "Recording stopped"
                            } else "Preparing the temporary live buffer…"
                            Text(
                                message,
                                color = Color(0xFFCBD0D8),
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.padding(horizontal = if (isTv) 32.dp else 14.dp, vertical = 3.dp),
                            )
                        } else if (snapshot.durationMs > 0) {
                            val currentPos = snapshot.positionMs
                            val duration = snapshot.durationMs
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = if (isTv) 32.dp else 14.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(formatTime(currentPos), color = Color.White, style = MaterialTheme.typography.labelSmall)
                                Box(
                                    Modifier
                                        .weight(1f)
                                        .height(4.dp)
                                        .clip(RoundedCornerShape(2.dp))
                                        .background(Color(0x55FFFFFF)),
                                ) {
                                    val fraction = (currentPos.toFloat() / duration.coerceAtLeast(1L)).coerceIn(0f, 1f)
                                    Box(
                                        Modifier
                                            .fillMaxWidth(fraction)
                                            .fillMaxHeight()
                                            .background(Color(0xFF38D9CA)),
                                    )
                                }
                                Text(formatTime(duration), color = Color(0xFFCBD0D8), style = MaterialTheme.typography.labelSmall)
                            }
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
                                if (snapshot.playWhenReady) "Pause" else "Play",
                                if (snapshot.playWhenReady) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                                primary = true,
                            ) {
                                pokeControls()
                                controller.togglePlayPause()
                            }
                            if (snapshot.liveSeekable || current.kind != MediaKind.LIVE) {
                                PlayerButton("Back 10s", Icons.Outlined.Replay10) {
                                    pokeControls()
                                    controller.seekBy(-10_000)
                                }
                                PlayerButton("Forward 10s", Icons.Outlined.Forward10) {
                                    pokeControls()
                                    controller.seekBy(10_000)
                                }
                            }
                            if (queue.size > 1) {
                                PlayerButton("Previous", Icons.Outlined.SkipPrevious) {
                                    pokeControls()
                                    changeChannel(-1)
                                }
                                PlayerButton("Next", Icons.Outlined.SkipNext) {
                                    pokeControls()
                                    changeChannel(1)
                                }
                            }
                            if (queue.isNotEmpty()) {
                                PlayerButton("Guide", Icons.AutoMirrored.Outlined.ViewList) {
                                    pokeControls()
                                    guideOpen = true
                                }
                            }
                            val favorite = remember(current.id, favoriteRefresh, isFavorite) { isFavorite(current.id) }
                            PlayerButton(if (favorite) "Unfavorite" else "Favorite", if (favorite) Icons.Outlined.Favorite else Icons.Outlined.FavoriteBorder) {
                                pokeControls()
                                onToggleFavorite(current)
                                favoriteRefresh += 1
                            }
                            PlayerButton("Aspect: ${aspectLabel(aspect)}", Icons.Outlined.AspectRatio) {
                                pokeControls()
                                aspect = when (aspect) {
                                    AspectRatioFrameLayout.RESIZE_MODE_FIT -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                                    AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                                    else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                                }
                            }
                            PlayerButton("Audio", Icons.AutoMirrored.Outlined.VolumeUp, enabled = snapshot.tracks.groups.any { it.type == C.TRACK_TYPE_AUDIO && it.isSupported }) {
                                pokeControls()
                                trackDialog = C.TRACK_TYPE_AUDIO
                            }
                            PlayerButton("Subtitles", Icons.Outlined.Subtitles, enabled = snapshot.tracks.groups.any { it.type == C.TRACK_TYPE_TEXT && it.isSupported }) {
                                pokeControls()
                                trackDialog = C.TRACK_TYPE_TEXT
                            }
                            PlayerButton(if (statsVisible) "Hide stats" else "Stats", Icons.Outlined.Equalizer) {
                                pokeControls()
                                statsVisible = !statsVisible
                            }
                        }
                    }
                }
            }

            if (!isInPip && (snapshot.buffering || snapshot.recovering)) {
                Column(
                    Modifier.align(Alignment.Center).background(Color(0xD91A1D24), MaterialTheme.shapes.medium).padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    CircularProgressIndicator(color = Color(0xFF9BD7FF))
                    Text(if (snapshot.recovering) "Reconnecting…" else "Buffering…", color = Color.White)
                }
            }
            if (!isInPip && snapshot.error != null) {
                Surface(
                    color = Color(0xF21A1D24),
                    shape = MaterialTheme.shapes.large,
                    modifier = Modifier.align(Alignment.Center).padding(if (isTv) 64.dp else 24.dp),
                ) {
                    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("Playback unavailable", style = MaterialTheme.typography.titleLarge, color = Color.White)
                        Text(snapshot.error.orEmpty(), color = Color.White)
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { controller.retry() }, modifier = Modifier.focusRequester(retryFocus)) {
                                Icon(Icons.Outlined.Replay, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Retry")
                            }
                            PlayerButton("Back", Icons.AutoMirrored.Outlined.ArrowBack) { close() }
                            if (queue.size > 1) PlayerButton("Next", Icons.Outlined.SkipNext) { changeChannel(1) }
                        }
                    }
                }
            }
            if (statsVisible && !isInPip) {
                Statistics(snapshot, profile, Modifier.align(Alignment.TopEnd).padding(top = 68.dp, end = if (isTv) 36.dp else 12.dp))
            }
        }
    }

    if (guideOpen) {
        AlertDialog(
            onDismissRequest = { guideOpen = false },
            title = { Text(if (current.kind == MediaKind.LIVE) "Channel guide" else "Play queue") },
            text = {
                LazyColumn(Modifier.height(if (isTv) 360.dp else 400.dp)) {
                    items(queue, key = { it.id }) { item ->
                        TextButton(onClick = { select(item); guideOpen = false }, modifier = Modifier.fillMaxWidth()) {
                            Icon(if (item.id == current.id) Icons.Outlined.Check else Icons.Outlined.PlayArrow, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                if (item.id == current.id) "Playing · ${item.name}" else item.name,
                                modifier = Modifier.fillMaxWidth(),
                                fontWeight = if (item.id == current.id) FontWeight.Bold else FontWeight.Normal,
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { guideOpen = false }) {
                    Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Close")
                }
            },
        )
    }
    if (trackDialog != C.TRACK_TYPE_UNKNOWN) {
        TrackDialog(controller.player, snapshot.tracks, trackDialog) { trackDialog = C.TRACK_TYPE_UNKNOWN }
    }
}

@Composable
private fun PlayerButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean = true,
    primary: Boolean = false,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val accent = Color(0xFF38D9CA)
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.onFocusChanged { focused = it.isFocused },
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
private fun TrackDialog(player: Player, tracks: Tracks, type: Int, onDismiss: () -> Unit) {
    val choices = remember(tracks, type) {
        tracks.groups.filter { it.type == type }.flatMap { group ->
            (0 until group.length).filter { group.isTrackSupported(it) }.map { TrackChoice(group, it) }
        }
    }
    fun choose(choice: TrackChoice?) {
        val parameters = player.trackSelectionParameters.buildUpon().clearOverridesOfType(type)
            .setTrackTypeDisabled(type, type == C.TRACK_TYPE_TEXT && choice == null)
        if (choice != null) parameters.setOverrideForType(TrackSelectionOverride(choice.group.mediaTrackGroup, listOf(choice.index)))
        player.trackSelectionParameters = parameters.build()
        onDismiss()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (type == C.TRACK_TYPE_AUDIO) "Audio track" else "Subtitles") },
        text = {
            LazyColumn(Modifier.height(280.dp)) {
                item {
                    TextButton(onClick = { choose(null) }, modifier = Modifier.fillMaxWidth()) {
                        Icon(if (type == C.TRACK_TYPE_AUDIO) Icons.AutoMirrored.Outlined.VolumeUp else Icons.Outlined.Subtitles, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (type == C.TRACK_TYPE_AUDIO) "Automatic" else "Off", modifier = Modifier.fillMaxWidth())
                    }
                }
                items(choices) { choice ->
                    val format = choice.group.getTrackFormat(choice.index)
                    val language = format.language?.takeUnless { it == "und" }?.let { Locale.forLanguageTag(it).displayLanguage }
                    val label = format.label ?: language ?: "Track ${choice.index + 1}"
                    TextButton(onClick = { choose(choice) }, modifier = Modifier.fillMaxWidth()) {
                        Icon(if (choice.group.isTrackSelected(choice.index)) Icons.Outlined.Check else if (type == C.TRACK_TYPE_AUDIO) Icons.AutoMirrored.Outlined.VolumeUp else Icons.Outlined.Subtitles, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (choice.group.isTrackSelected(choice.index)) "Selected · $label" else label, modifier = Modifier.fillMaxWidth())
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Close")
            }
        },
    )
}

private data class TrackChoice(val group: Tracks.Group, val index: Int)

@Composable
private fun Statistics(state: PlaybackSnapshot, profile: BufferProfile, modifier: Modifier) {
    Column(
        modifier.background(Color(0xD91A1D24), MaterialTheme.shapes.small).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Stat("Buffer", "${decimal(state.bufferMs / 1_000.0)} s")
        Stat("Video", if (state.width > 0) "${state.width} × ${state.height}" else "Waiting")
        Stat("Video bitrate", if (state.bitrate > 0) "${decimal(state.bitrate / 1_000_000.0)} Mbps" else "Unknown")
        Stat("Bandwidth", if (state.bandwidthEstimate > 0) "${decimal(state.bandwidthEstimate / 1_000_000.0)} Mbps" else "Measuring")
        Stat("Format FPS", if (state.frameRate > 0) decimal(state.frameRate.toDouble()) else "Unknown")
        Stat("Dropped", state.droppedFrames.toString())
        Stat("Stalls / retries", "${state.stalls} / ${state.retries}")
        if (state.entry?.kind == MediaKind.LIVE && state.liveOffsetMs > 0) Stat("Live offset", "${decimal(state.liveOffsetMs / 1_000.0)} s")
        if (state.timeShiftAvailable) {
            Stat("Saved history", "${decimal(state.timeShiftDurationMs / 1_000.0)} s")
            Stat("Temp storage", "${decimal(state.timeShiftBytes / 1_048_576.0)} MiB")
            Stat("Recording", if (state.timeShiftRecording) "Active" else "Stopped")
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
private fun aspectLabel(aspect: Int): String = when (aspect) {
    AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> "Zoom"
    AspectRatioFrameLayout.RESIZE_MODE_FILL -> "Stretch"
    else -> "Fit"
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}
