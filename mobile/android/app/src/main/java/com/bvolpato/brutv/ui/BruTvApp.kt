package com.bvolpato.brutv.ui

import android.text.format.DateFormat
import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.PlaylistAdd
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FileOpen
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.InsertLink
import androidx.compose.material.icons.outlined.LiveTv
import androidx.compose.material.icons.outlined.ManageAccounts
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SwitchAccount
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.Player
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.request.ImageRequest
import coil.size.Precision
import coil.size.Size
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import com.bvolpato.brutv.data.Programme
import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import com.bvolpato.brutv.playback.BufferProfile
import com.bvolpato.brutv.playback.PlaybackScreen
import com.bvolpato.brutv.signin.LoginQrScreen
import com.bvolpato.brutv.signin.PairingSendScreen
import com.bvolpato.brutv.signin.PrivateScreen
import com.bvolpato.brutv.signin.QrScannerScreen
import com.bvolpato.brutv.signin.TvPairingScreen
import java.io.File
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.delay

private val BruTvColors = darkColorScheme(
    primary = Color(0xFF41E0D0),
    onPrimary = Color(0xFF06201F),
    secondary = Color(0xFF75D9F3),
    background = Color(0xFF091116),
    surface = Color(0xFF111B22),
    surfaceVariant = Color(0xFF1A2932),
    onBackground = Color(0xFFEAF5F6),
    onSurface = Color(0xFFEAF5F6),
    onSurfaceVariant = Color(0xFF9AAEB4),
    error = Color(0xFFFF8F82),
)

private val Canvas = Color(0xFF091116)
private val CardSurface = Color(0xFF121F27)
private val Aqua = Color(0xFF41E0D0)
private val Muted = Color(0xFF9AAEB4)

private enum class SignInField {
    PROFILE_NAME,
    SERVER,
    USERNAME,
    PASSWORD,
    PLAYLIST_URL,
}

/** Main app entry point. Player content replaces navigation so video owns the whole display. */
@Composable
fun BruTvApp(
    viewModel: BruTvViewModel,
    isTv: Boolean,
    onPlayerChanged: (Player?) -> Unit,
    isInPictureInPictureMode: Boolean = false,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var pasteLinkOpen by remember { mutableStateOf(false) }
    var splashDismissed by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        delay(1400)
        splashDismissed = true
    }

    val playlistPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) viewModel.importLocalPlaylist(uri)
    }
    val imageLoader = remember(context) {
        ImageLoader.Builder(context)
            .memoryCache { coil.memory.MemoryCache.Builder(context).maxSizeBytes(56 * 1024 * 1024).build() }
            .diskCache { coil.disk.DiskCache.Builder().directory(File(context.cacheDir, "brutv_artwork")).maxSizeBytes(192L * 1024 * 1024).build() }
            .crossfade(180)
            .build()
    }

    MaterialTheme(colorScheme = BruTvColors) {
        Surface(Modifier.fillMaxSize(), color = Canvas) {
            val currentEntry = state.playingEntry
            if (currentEntry != null) {
                PlaybackScreen(
                    entry = currentEntry,
                    queue = state.playQueue,
                    profile = BufferProfile.fromKey(state.bufferProfile),
                    showStats = state.showStats,
                    resumePositionMs = state.library.resumePositions[currentEntry.id] ?: 0L,
                    isTv = isTv,
                    onClose = viewModel::closePlayer,
                    onItemChanged = viewModel::onPlayerItemChanged,
                    onPosition = viewModel::savePosition,
                    onToggleFavorite = viewModel::toggleFavorite,
                    isFavorite = viewModel::isFavorite,
                    onPlayerChanged = onPlayerChanged,
                    isInPictureInPictureMode = isInPictureInPictureMode,
                )
                return@Surface
            }

            Box(Modifier.fillMaxSize()) {
                if (state.page == BruTvPage.SIGN_IN || state.page == BruTvPage.LOGIN_QR || pasteLinkOpen) PrivateScreen()

            when {
                state.page == BruTvPage.SCAN_QR -> Box(Modifier.fillMaxSize()) {
                    QrScannerScreen(
                        onResult = viewModel::acceptLink,
                        onCancel = viewModel::closePage,
                    )
                    if (!isTv) ActionButton(
                        "Enter details manually",
                        { viewModel.openSignIn() },
                        Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp),
                        icon = Icons.Outlined.Edit,
                        primary = true,
                        isTv = false,
                    )
                }
                state.page == BruTvPage.TV_PAIRING -> TvPairingScreen(
                    onSource = viewModel::pairingReceivedSource,
                    onCancel = viewModel::closePage,
                )
                state.page == BruTvPage.LOGIN_QR -> state.loginQrSource?.let { source ->
                    if (source.isShareable()) LoginQrScreen(source, viewModel::closePage)
                    else LocalPlaylistShareMessage(viewModel::closePage)
                }
                state.pendingPairInvite != null && state.profiles.isNotEmpty() && state.page != BruTvPage.SIGN_IN -> {
                    val shareableProfiles = state.profiles.filter { it.isShareable() }
                    if (shareableProfiles.isEmpty()) {
                        CenteredMessage(
                            title = "This profile cannot be shared",
                            body = "Imported playlist files are stored only on this device. Add a provider login or playlist URL to pair with the TV.",
                            action = "Continue",
                            actionIcon = Icons.Outlined.Check,
                            onAction = viewModel::clearPairingInvite,
                        )
                    } else {
                        PairingSendScreen(
                            invite = checkNotNull(state.pendingPairInvite),
                            profiles = shareableProfiles,
                            onDone = viewModel::clearPairingInvite,
                            onCancel = viewModel::clearPairingInvite,
                        )
                    }
                }
                state.page == BruTvPage.SIGN_IN -> SignInPage(
                    state = state,
                    viewModel = viewModel,
                    isTv = isTv,
                    onChoosePlaylist = { playlistPicker.launch(arrayOf("*/*")) },
                    onScan = viewModel::openScanner,
                    onClose = viewModel::closePage,
                    onPair = viewModel::openTvPairing,
                    onPasteLink = { pasteLinkOpen = true },
                )
                state.initialized && state.activeSource == null -> WelcomePage(
                    state = state,
                    isTv = isTv,
                    onAddXtream = { viewModel.openSignIn(SourceType.XTREAM) },
                    onAddPlaylist = { viewModel.openSignIn(SourceType.M3U) },
                    onChoosePlaylist = { playlistPicker.launch(arrayOf("*/*")) },
                    onScan = viewModel::openScanner,
                    onPasteLink = { pasteLinkOpen = true },
                    onPair = viewModel::openTvPairing,
                )
                state.page == BruTvPage.DETAIL && state.selectedEntry != null -> DetailPage(
                    state = state,
                    entry = checkNotNull(state.selectedEntry),
                    isTv = isTv,
                    imageLoader = imageLoader,
                    onBack = viewModel::closePage,
                    onPlay = viewModel::play,
                    onFavorite = viewModel::toggleFavorite,
                    isFavorite = viewModel::isFavorite,
                )
                else -> BruTvHome(
                    state = state,
                    viewModel = viewModel,
                    isTv = isTv,
                    imageLoader = imageLoader,
                    onAddXtream = { viewModel.openSignIn(SourceType.XTREAM) },
                    onAddPlaylist = { viewModel.openSignIn(SourceType.M3U) },
                    onChoosePlaylist = { playlistPicker.launch(arrayOf("*/*")) },
                    onScan = viewModel::openScanner,
                    onPair = viewModel::openTvPairing,
                )
            }

            if (pasteLinkOpen) PasteLinkDialog(
                initialText = clipboard.getText()?.text.orEmpty(),
                onCancel = { pasteLinkOpen = false },
                onImport = { raw ->
                    val accepted = viewModel.supportsLink(raw)
                    if (accepted) {
                        viewModel.acceptLink(raw)
                        pasteLinkOpen = false
                    }
                    accepted
                },
            )

            val showSplash = (!splashDismissed || !state.initialized)
            AnimatedVisibility(
                visible = showSplash,
                enter = fadeIn(),
                exit = fadeOut(animationSpec = tween(350)),
            ) {
                BruTvSplashScreen(isTv = isTv)
            }
        }
    }
}
}

@Composable
private fun BruTvHome(
    state: BruTvUiState,
    viewModel: BruTvViewModel,
    isTv: Boolean,
    imageLoader: ImageLoader,
    onAddXtream: () -> Unit,
    onAddPlaylist: () -> Unit,
    onChoosePlaylist: () -> Unit,
    onScan: () -> Unit,
    onPair: () -> Unit,
) {
    val width = LocalConfiguration.current.screenWidthDp
    val tablet = width >= 760
    BackHandler(enabled = state.destination != BruTvDestination.LIVE) {
        viewModel.onDestinationSelected(BruTvDestination.LIVE)
    }
    if (isTv || tablet) {
        val layoutInsets = if (isTv) WindowInsets(0, 0, 0, 0) else WindowInsets.safeDrawing
        Row(Modifier.fillMaxSize().windowInsetsPadding(layoutInsets)) {
            NavigationRail(
                selected = state.destination,
                isTv = isTv,
                onSelect = viewModel::onDestinationSelected,
                onInitialFocus = isTv,
            )
            Column(Modifier.fillMaxSize().weight(1f)) {
                AppHeader(
                    source = state.activeSource,
                    isTv = isTv,
                    onProfiles = { viewModel.onDestinationSelected(BruTvDestination.PROFILES) },
                    onAdd = onAddXtream,
                    onShare = { viewModel.showLoginQr() },
                    onPair = if (isTv) onPair else onScan,
                    onSettings = { viewModel.onDestinationSelected(BruTvDestination.SETTINGS) },
                )
                PersistenceNotice(state, viewModel, isTv)
                if (state.pageError != null) InlineError(state.pageError)
                when (state.destination) {
                    BruTvDestination.SETTINGS -> SettingsPage(state, viewModel, isTv)
                    BruTvDestination.PROFILES -> ProfilesPage(state, viewModel, isTv, onAddXtream, onAddPlaylist, onChoosePlaylist, onScan)
                    else -> CatalogPage(state, viewModel, isTv, tablet, imageLoader, onAddXtream, onScan)
                }
            }
        }
    } else {
        Scaffold(
            containerColor = Canvas,
            bottomBar = {
                PhoneNavigationBar(state.destination, viewModel::onDestinationSelected)
            },
        ) { insets ->
            Column(Modifier.fillMaxSize().padding(insets)) {
                AppHeader(
                    source = state.activeSource,
                    isTv = false,
                    onProfiles = { viewModel.onDestinationSelected(BruTvDestination.PROFILES) },
                    onAdd = onAddXtream,
                    onShare = { viewModel.showLoginQr() },
                    onPair = if (isTv) onPair else onScan,
                    onSettings = { viewModel.onDestinationSelected(BruTvDestination.SETTINGS) },
                )
                PersistenceNotice(state, viewModel, false)
                if (state.pageError != null) InlineError(state.pageError)
                when (state.destination) {
                    BruTvDestination.SETTINGS -> SettingsPage(state, viewModel, false)
                    BruTvDestination.PROFILES -> ProfilesPage(state, viewModel, false, onAddXtream, onAddPlaylist, onChoosePlaylist, onScan)
                    else -> CatalogPage(state, viewModel, false, false, imageLoader, onAddXtream, onScan)
                }
            }
        }
    }
}

@Composable
private fun WelcomePage(
    state: BruTvUiState,
    isTv: Boolean,
    onAddXtream: () -> Unit,
    onAddPlaylist: () -> Unit,
    onChoosePlaylist: () -> Unit,
    onScan: () -> Unit,
    onPasteLink: () -> Unit,
    onPair: () -> Unit,
) {
    val pairFocus = remember { FocusRequester() }
    LaunchedEffect(isTv) { if (isTv) pairFocus.requestFocus() }
    BoxWithConstraints(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF122C35), Canvas)))) {
        val centered = maxWidth >= 760.dp
        Column(
            Modifier
                .then(if (centered) Modifier.width(620.dp).align(Alignment.Center) else Modifier.fillMaxWidth().align(Alignment.Center))
                .padding(if (isTv) 48.dp else 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            horizontalAlignment = if (centered) Alignment.CenterHorizontally else Alignment.Start,
        ) {
            BrandMark()
            Text("Connect your TV provider", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text("Bring your own provider or playlist. BruTV does not include channels, demos, or provider accounts.", color = Muted, style = MaterialTheme.typography.bodyLarge)
            if (state.pageError != null) InlineError(state.pageError)
            if (!state.initialized) {
                CircularProgressIndicator(color = Aqua)
            } else {
                if (isTv) ActionButton("Pair with phone", onPair, Modifier.focusRequester(pairFocus), icon = Icons.Outlined.Devices, primary = true, isTv = true)
                ActionButton("Connect with Xtream", onAddXtream, icon = Icons.Outlined.InsertLink, primary = !isTv, isTv = isTv)
                ActionButton("Add an M3U playlist URL", onAddPlaylist, icon = Icons.AutoMirrored.Outlined.PlaylistAdd, isTv = isTv)
                ActionButton("Import an M3U file", onChoosePlaylist, icon = Icons.Outlined.FileOpen, isTv = isTv)
                if (!isTv) ActionButton("Scan a BruTV QR code", onScan, icon = Icons.Outlined.QrCodeScanner, isTv = false)
                ActionButton("Paste a sign-in link", onPasteLink, icon = Icons.Outlined.ContentPaste, isTv = isTv)
            }
            Text("Your provider login stays on this device. Use links and QR codes only with people you trust.", color = Muted, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun SignInPage(
    state: BruTvUiState,
    viewModel: BruTvViewModel,
    isTv: Boolean,
    onChoosePlaylist: () -> Unit,
    onScan: () -> Unit,
    onClose: () -> Unit,
    onPair: () -> Unit,
    onPasteLink: () -> Unit,
) {
    val profileNameFocus = remember { FocusRequester() }
    val xtreamTypeFocus = remember { FocusRequester() }
    val m3uTypeFocus = remember { FocusRequester() }
    val serverFocus = remember { FocusRequester() }
    val usernameFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    val playlistUrlFocus = remember { FocusRequester() }
    val chooseFileFocus = remember { FocusRequester() }
    val connectFocus = remember { FocusRequester() }
    var editingField by remember { mutableStateOf<SignInField?>(null) }
    var imeWasShownForEditing by remember { mutableStateOf(false) }
    val keyboardController = LocalSoftwareKeyboardController.current
    val imeVisible = WindowInsets.isImeVisible
    LaunchedEffect(Unit) { if (isTv) profileNameFocus.requestFocus() }
    LaunchedEffect(editingField, isTv) {
        val requester = when (editingField) {
            SignInField.PROFILE_NAME -> profileNameFocus
            SignInField.SERVER -> serverFocus
            SignInField.USERNAME -> usernameFocus
            SignInField.PASSWORD -> passwordFocus
            SignInField.PLAYLIST_URL -> playlistUrlFocus
            null -> null
        }
        if (isTv && requester != null) {
            requester.requestFocus()
            keyboardController?.show()
        }
    }
    LaunchedEffect(editingField, imeVisible, isTv) {
        if (!isTv) return@LaunchedEffect
        when {
            editingField == null -> imeWasShownForEditing = false
            imeVisible -> imeWasShownForEditing = true
            imeWasShownForEditing -> {
                imeWasShownForEditing = false
                editingField = null
            }
        }
    }
    BackHandler(enabled = isTv && editingField != null) {
        keyboardController?.hide()
        editingField = null
    }
    BackHandler(enabled = !isTv || editingField == null, onBack = onClose)
    BoxWithConstraints(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF122C35), Canvas)))) {
        val formWidth = if (maxWidth >= 900.dp) 600.dp else maxWidth
        Column(
            Modifier.width(formWidth).fillMaxHeight().align(if (maxWidth >= 900.dp) Alignment.Center else Alignment.TopCenter)
                .verticalScroll(rememberScrollState()).padding(horizontal = if (isTv) 32.dp else 22.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Add a provider", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                if (isTv) HeaderTextButton("Pair with phone", Icons.Outlined.Devices, onPair, true)
                TextButton(onClick = onClose) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("Cancel")
                    }
                }
            }
            Text("Your sign-in details are encrypted and stored on this device.", color = Muted)
            if (isTv) Text("Select a field to edit it. Press Back to return to navigation.", color = Muted, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FilterChip(
                    selected = state.draft.type == SourceType.XTREAM,
                    onClick = { viewModel.updateDraft { it.copy(type = SourceType.XTREAM) } },
                    label = { Text("Xtream") },
                    modifier = if (isTv) Modifier.focusRequester(xtreamTypeFocus) else Modifier,
                )
                FilterChip(
                    selected = state.draft.type == SourceType.M3U,
                    onClick = { viewModel.updateDraft { it.copy(type = SourceType.M3U) } },
                    label = { Text("M3U") },
                    modifier = if (isTv) Modifier.focusRequester(m3uTypeFocus) else Modifier,
                )
            }
            OutlinedTextField(
                value = state.draft.name,
                onValueChange = { value -> viewModel.updateDraft { it.copy(name = value) } },
                label = { Text("Profile name") },
                singleLine = true,
                readOnly = isTv && editingField != SignInField.PROFILE_NAME,
                modifier = Modifier.fillMaxWidth().then(
                    tvTextFieldFocusModifier(
                        isTv,
                        SignInField.PROFILE_NAME,
                        editingField,
                        onBeginEditing = { editingField = SignInField.PROFILE_NAME },
                        focusRequester = profileNameFocus,
                        upFocusRequester = if (state.draft.type == SourceType.XTREAM) xtreamTypeFocus else m3uTypeFocus,
                        downFocusRequester = if (state.draft.type == SourceType.XTREAM) serverFocus else playlistUrlFocus,
                    ),
                ),
            )
            if (state.draft.type == SourceType.XTREAM) {
                OutlinedTextField(value = state.draft.server, onValueChange = { value -> viewModel.updateDraft { it.copy(server = value) } }, label = { Text("Server address") }, singleLine = true, readOnly = isTv && editingField != SignInField.SERVER, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth().then(tvTextFieldFocusModifier(isTv, SignInField.SERVER, editingField, { editingField = SignInField.SERVER }, serverFocus, profileNameFocus, usernameFocus)))
                OutlinedTextField(value = state.draft.username, onValueChange = { value -> viewModel.updateDraft { it.copy(username = value) } }, label = { Text("Username") }, singleLine = true, readOnly = isTv && editingField != SignInField.USERNAME, modifier = Modifier.fillMaxWidth().then(tvTextFieldFocusModifier(isTv, SignInField.USERNAME, editingField, { editingField = SignInField.USERNAME }, usernameFocus, serverFocus, passwordFocus)))
                OutlinedTextField(value = state.draft.password, onValueChange = { value -> viewModel.updateDraft { it.copy(password = value) } }, label = { Text("Password") }, singleLine = true, readOnly = isTv && editingField != SignInField.PASSWORD, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().then(tvTextFieldFocusModifier(isTv, SignInField.PASSWORD, editingField, { editingField = SignInField.PASSWORD }, passwordFocus, usernameFocus, connectFocus)))
            } else {
                OutlinedTextField(value = state.draft.playlistUrl, onValueChange = { value -> viewModel.updateDraft { it.copy(playlistUrl = value) } }, label = { Text("M3U playlist URL") }, singleLine = true, readOnly = isTv && editingField != SignInField.PLAYLIST_URL, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth().then(tvTextFieldFocusModifier(isTv, SignInField.PLAYLIST_URL, editingField, { editingField = SignInField.PLAYLIST_URL }, playlistUrlFocus, profileNameFocus, chooseFileFocus)))
                Text("You can import an .m3u file from this device. The file is copied into private app storage.", color = Muted, style = MaterialTheme.typography.bodySmall)
                ActionButton("Choose .m3u file", onChoosePlaylist, Modifier.then(if (isTv) Modifier.focusRequester(chooseFileFocus) else Modifier), icon = Icons.Outlined.FileOpen, isTv = isTv)
            }
            if (state.pageError != null) InlineError(state.pageError)
            if (state.pendingPairInvite != null) InfoNotice("TV code saved. Connect a profile, then choose which one to send.")
            ActionButton(if (state.busy) "Connecting…" else "Connect", viewModel::connectDraft, Modifier.then(if (isTv) Modifier.focusRequester(connectFocus) else Modifier), icon = Icons.Outlined.InsertLink, primary = true, enabled = !state.busy, isTv = isTv)
            if (state.busy) CircularProgressIndicator(color = Aqua, modifier = Modifier.align(Alignment.CenterHorizontally))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!isTv) ActionButton("Scan QR", onScan, Modifier.weight(1f), icon = Icons.Outlined.QrCodeScanner, isTv = false)
                ActionButton("Paste sign-in link", onPasteLink, Modifier.weight(1f), icon = Icons.Outlined.ContentPaste, isTv = isTv)
            }
        }
    }
}

private fun tvTextFieldFocusModifier(
    isTv: Boolean,
    field: SignInField,
    editingField: SignInField?,
    onBeginEditing: () -> Unit,
    focusRequester: FocusRequester,
    upFocusRequester: FocusRequester,
    downFocusRequester: FocusRequester,
): Modifier {
    if (!isTv) return Modifier
    return Modifier
        .focusRequester(focusRequester)
        .focusProperties {
            up = upFocusRequester
            down = downFocusRequester
        }
        .onPreviewKeyEvent { event ->
            val key = event.nativeKeyEvent
            when (key.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> if (editingField != field) {
                    if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) {
                        if (key.keyCode == KeyEvent.KEYCODE_DPAD_UP) upFocusRequester.requestFocus() else downFocusRequester.requestFocus()
                    }
                    true
                } else false
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> if (editingField != field) {
                    if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) onBeginEditing()
                    true
                } else false
                else -> false
            }
        }
}

@Composable
private fun NavigationRail(
    selected: BruTvDestination,
    isTv: Boolean,
    onSelect: (BruTvDestination) -> Unit,
    onInitialFocus: Boolean,
) {
    val first = remember { FocusRequester() }
    LaunchedEffect(onInitialFocus) { if (onInitialFocus) first.requestFocus() }
    Column(
        Modifier.width(if (isTv) 205.dp else 84.dp).fillMaxHeight().background(Color(0xFF0E1A20)).padding(horizontal = if (isTv) 14.dp else 8.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        BrandMark(compact = !isTv)
        Spacer(Modifier.height(10.dp))
        navItems.forEachIndexed { index, item ->
            NavRailButton(
                item = item,
                selected = selected == item.destination,
                isTv = isTv,
                modifier = if (index == 0 && onInitialFocus) Modifier.focusRequester(first) else Modifier,
                onClick = { onSelect(item.destination) },
            )
        }
    }
}

@Composable
private fun PhoneNavigationBar(selected: BruTvDestination, onSelect: (BruTvDestination) -> Unit) {
    val current = if (selected == BruTvDestination.RECENTS) BruTvDestination.FAVORITES else selected
    Surface(
        color = Color(0xFF101A20),
        border = BorderStroke(1.dp, Color(0xFF16252C)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = 6.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            listOf(
                BruTvDestination.LIVE,
                BruTvDestination.MOVIES,
                BruTvDestination.SERIES,
                BruTvDestination.FAVORITES,
                BruTvDestination.SETTINGS,
            ).forEach { destination ->
                val item = navItems.first { it.destination == destination }
                val isSelected = current == destination
                Surface(
                    onClick = { onSelect(destination) },
                    shape = RoundedCornerShape(12.dp),
                    color = if (isSelected) Color(0xFF163C43) else Color.Transparent,
                    modifier = Modifier.clip(RoundedCornerShape(12.dp)),
                ) {
                    Column(
                        Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Icon(
                            item.icon,
                            contentDescription = item.label,
                            tint = if (isSelected) Aqua else Muted,
                            modifier = Modifier.size(19.dp),
                        )
                        Text(
                            item.shortLabel,
                            color = if (isSelected) Aqua else Muted,
                            fontSize = 10.sp,
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

private data class NavItem(val destination: BruTvDestination, val label: String, val shortLabel: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)
private val navItems = listOf(
    NavItem(BruTvDestination.LIVE, "Live TV", "Live", Icons.Outlined.LiveTv),
    NavItem(BruTvDestination.MOVIES, "Movies", "Movies", Icons.Outlined.Movie),
    NavItem(BruTvDestination.SERIES, "Series", "Series", Icons.Outlined.Tv),
    NavItem(BruTvDestination.FAVORITES, "Favorites", "Saved", Icons.Outlined.Favorite),
    NavItem(BruTvDestination.RECENTS, "Recently watched", "Recent", Icons.Outlined.Bookmark),
    NavItem(BruTvDestination.PROFILES, "Profiles", "Profiles", Icons.Outlined.Tv),
    NavItem(BruTvDestination.SETTINGS, "Settings", "Settings", Icons.Outlined.Settings),
)

@Composable
private fun NavRailButton(item: NavItem, selected: Boolean, isTv: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth()
            .then(modifier)
            .onFocusChanged { focused = it.isFocused }
            .clip(RoundedCornerShape(15.dp))
            .background(if (selected) Color(0xFF163C43) else Color.Transparent)
            .border(if (focused) 2.dp else 1.dp, if (focused) Aqua else if (selected) Color(0xFF2B7979) else Color.Transparent, RoundedCornerShape(15.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = if (isTv) 15.dp else 10.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Icon(item.icon, contentDescription = item.label, tint = if (selected) Aqua else Muted, modifier = Modifier.size(23.dp))
        if (isTv) Text(item.label, color = if (selected) Color.White else Muted, fontSize = 16.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1)
    }
}

@Composable
private fun AppHeader(
    source: SourceConfig?,
    isTv: Boolean,
    onProfiles: () -> Unit,
    onAdd: () -> Unit,
    onShare: () -> Unit,
    onPair: () -> Unit,
    onSettings: () -> Unit,
) {
    val showQr = source != null && source.isShareable()
    Row(
        Modifier
            .fillMaxWidth()
            .background(Color(0xFF0E1A20))
            .padding(horizontal = if (isTv) 28.dp else 12.dp, vertical = if (isTv) 10.dp else 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (isTv) 10.dp else 6.dp),
    ) {
        HeaderIdentity(source, Modifier.weight(1f))
        HeaderActionButton("Add", Icons.Outlined.Add, onAdd, isTv = isTv, primary = true)
        if (showQr) {
            HeaderActionButton(if (isTv) "Login QR" else "QR", Icons.Outlined.QrCode2, onShare, isTv = isTv)
        }
        HeaderActionButton(if (isTv) "Pair phone" else "Pair TV", Icons.Outlined.Devices, onPair, isTv = isTv)
        HeaderActionButton("Profiles", Icons.Outlined.ManageAccounts, onProfiles, isTv = isTv)
        if (isTv) {
            HeaderActionButton("Settings", Icons.Outlined.Settings, onSettings, isTv = true)
        }
    }
}

@Composable
private fun HeaderIdentity(source: SourceConfig?, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text("BruTV", style = MaterialTheme.typography.titleMedium, color = Color.White, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(source?.name ?: "No provider selected", style = MaterialTheme.typography.bodySmall, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun CatalogPage(
    state: BruTvUiState,
    viewModel: BruTvViewModel,
    isTv: Boolean,
    tablet: Boolean,
    imageLoader: ImageLoader,
    onAdd: () -> Unit,
    onScan: () -> Unit,
) {
    var editingSearch by remember { mutableStateOf(false) }
    var imeWasShownForSearch by remember { mutableStateOf(false) }
    val keyboardController = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val imeVisible = WindowInsets.isImeVisible
    LaunchedEffect(editingSearch, isTv) {
        if (isTv && editingSearch) keyboardController?.show()
    }
    LaunchedEffect(editingSearch, imeVisible, isTv) {
        if (!isTv) return@LaunchedEffect
        when {
            !editingSearch -> imeWasShownForSearch = false
            imeVisible -> imeWasShownForSearch = true
            imeWasShownForSearch -> {
                imeWasShownForSearch = false
                editingSearch = false
            }
        }
    }
    BackHandler(enabled = isTv && editingSearch) {
        keyboardController?.hide()
        editingSearch = false
    }
    val title = when (state.destination) {
        BruTvDestination.LIVE -> "Live TV"
        BruTvDestination.MOVIES -> "Movies"
        BruTvDestination.SERIES -> "Series"
        BruTvDestination.FAVORITES -> "Your library"
        BruTvDestination.RECENTS -> "Recently watched"
        else -> "Browse"
    }
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = if (isTv) 30.dp else 18.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, style = if (isTv) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                val itemCount = state.visibleEntries.size
                Text("$itemCount ${if (itemCount == 1) "item" else "items"}", style = MaterialTheme.typography.bodySmall, color = Muted)
            }
            OutlinedTextField(
                value = state.searchText,
                onValueChange = viewModel::setSearchText,
                singleLine = true,
                readOnly = isTv && !editingSearch,
                leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                placeholder = { Text("Search") },
                modifier = Modifier.width(if (isTv) 330.dp else 150.dp).then(
                    if (isTv) Modifier.onPreviewKeyEvent { event ->
                        val key = event.nativeKeyEvent
                        when (key.keyCode) {
                            KeyEvent.KEYCODE_DPAD_UP,
                            KeyEvent.KEYCODE_DPAD_DOWN,
                            KeyEvent.KEYCODE_DPAD_LEFT,
                            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                                if (!editingSearch && key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) {
                                    val direction = when (key.keyCode) {
                                        KeyEvent.KEYCODE_DPAD_UP -> FocusDirection.Up
                                        KeyEvent.KEYCODE_DPAD_DOWN -> FocusDirection.Down
                                        KeyEvent.KEYCODE_DPAD_LEFT -> FocusDirection.Left
                                        else -> FocusDirection.Right
                                    }
                                    focusManager.moveFocus(direction)
                                }
                                !editingSearch
                            }
                            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                                if (!editingSearch && key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) editingSearch = true
                                true
                            }
                            else -> false
                        }
                    } else Modifier,
                ),
            )
            if (state.destination == BruTvDestination.LIVE) FilterChip(
                selected = state.onlyFavorites,
                onClick = { viewModel.setOnlyFavorites(!state.onlyFavorites) },
                label = { Text("Saved") },
            )
        }
        if (state.destination == BruTvDestination.FAVORITES || state.destination == BruTvDestination.RECENTS) {
            Row(Modifier.fillMaxWidth().padding(horizontal = if (isTv) 30.dp else 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = state.destination == BruTvDestination.FAVORITES, onClick = { viewModel.onDestinationSelected(BruTvDestination.FAVORITES) }, label = { Text("Favorites") })
                FilterChip(selected = state.destination == BruTvDestination.RECENTS, onClick = { viewModel.onDestinationSelected(BruTvDestination.RECENTS) }, label = { Text("Recent") })
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = if (isTv) 30.dp else 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(MediaKind.LIVE to "Live", MediaKind.MOVIE to "Movies", MediaKind.SERIES to "Series").forEach { (kind, label) ->
                    FilterChip(selected = state.libraryKind == kind, onClick = { viewModel.selectLibraryKind(kind) }, label = { Text(label) })
                }
            }
        }
        if (state.activeSection.categories.isNotEmpty() && state.destination !in setOf(BruTvDestination.FAVORITES, BruTvDestination.RECENTS)) {
            LazyRow(
                Modifier.fillMaxWidth().padding(horizontal = if (isTv) 24.dp else 12.dp, vertical = 8.dp),
                contentPadding = PaddingValues(horizontal = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item(key = "all") { FilterChip(selected = state.selectedCategoryId == null, onClick = { viewModel.selectCategory(null) }, label = { Text("All") }) }
                items(state.activeSection.categories, key = { it.id }) { category ->
                    FilterChip(selected = state.selectedCategoryId == category.id, onClick = { viewModel.selectCategory(category.id) }, label = { Text(category.name, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                }
            }
        }
        if (state.destination in setOf(BruTvDestination.LIVE, BruTvDestination.MOVIES, BruTvDestination.SERIES, BruTvDestination.FAVORITES, BruTvDestination.RECENTS)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = if (isTv) 30.dp else 18.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                listOf(null, "4K", "FHD", "HD", "SD").forEach { quality ->
                    FilterChip(selected = state.qualityFilter == quality, onClick = { viewModel.setQualityFilter(quality) }, label = { Text(quality ?: "Any quality") })
                }
            }
        }
        if (state.catalogError != null) ErrorBlock(state.catalogError, viewModel::retryCatalog)
        when {
            state.catalogLoading && state.activeSection.entries.isEmpty() -> LoadingBlock("Loading your ${title.lowercase(Locale.ROOT)}…")
            state.visibleEntries.isEmpty() -> EmptyCatalog(
                title = if (state.searchText.isNotBlank()) "No matches" else if (state.destination == BruTvDestination.FAVORITES) "Nothing saved yet" else if (state.destination == BruTvDestination.RECENTS) "Nothing watched yet" else "No ${title.lowercase(Locale.ROOT)} found",
                body = when {
                    state.searchText.isNotBlank() -> "Try another search or clear a filter."
                    state.destination in setOf(BruTvDestination.FAVORITES, BruTvDestination.RECENTS) -> "Save a channel or start watching to build your library."
                    else -> "Your provider has not returned items for this section. Try another section or refresh."
                },
                onAdd = onAdd,
                isTv = isTv,
                onScan = onScan,
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = when {
                    isTv -> 238.dp
                    tablet -> 190.dp
                    else -> 144.dp
                }),
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = if (isTv) 28.dp else 14.dp, vertical = 18.dp),
                horizontalArrangement = Arrangement.spacedBy(if (isTv) 20.dp else 12.dp),
                verticalArrangement = Arrangement.spacedBy(if (isTv) 22.dp else 16.dp),
            ) {
                items(state.visibleEntries, key = { it.id }, contentType = { it.kind.name }) { entry ->
                    MediaCard(
                        entry = entry,
                        imageLoader = imageLoader,
                        isTv = isTv,
                        favorite = viewModel.isFavorite(entry.id),
                        onClick = {
                            if (entry.kind == MediaKind.LIVE) viewModel.play(entry)
                            else viewModel.openEntry(entry)
                        },
                        onFavorite = { viewModel.toggleFavorite(entry) },
                    )
                }
            }
        }
    }
}

@Composable
private fun MediaCard(
    entry: MediaEntry,
    imageLoader: ImageLoader,
    isTv: Boolean,
    favorite: Boolean,
    onClick: () -> Unit,
    onFavorite: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .clip(RoundedCornerShape(17.dp))
            .background(CardSurface)
            .border(if (focused) 3.dp else 1.dp, if (focused) Aqua else Color(0xFF243740), RoundedCornerShape(17.dp))
            .clickable(onClick = onClick)
            .padding(8.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(if (entry.kind == MediaKind.LIVE) 136.dp else 192.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF1C303A))) {
            Artwork(entry.artwork, entry.kind, imageLoader, Modifier.fillMaxSize())
            Surface(color = Color(0xCC071116), shape = RoundedCornerShape(50), modifier = Modifier.align(Alignment.TopStart).padding(8.dp)) {
                Text(entry.quality, color = Aqua, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
            }
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(42.dp).background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xB9071116)))))
            Text(if (entry.kind == MediaKind.LIVE) "LIVE" else entry.kind.displayName(), color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold, modifier = Modifier.align(Alignment.BottomStart).padding(9.dp))
            Surface(
                onClick = { onFavorite() },
                color = Color(0xBB081318),
                shape = CircleShape,
                modifier = Modifier.align(Alignment.TopEnd).size(38.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        if (favorite) Icons.Outlined.Favorite else Icons.Outlined.FavoriteBorder,
                        contentDescription = if (favorite) "Remove favorite" else "Add favorite",
                        tint = if (favorite) Aqua else Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
        Text(entry.name, color = Color.White, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 4.dp, vertical = 9.dp))
        if (entry.rating.isNotBlank()) Text("★ ${entry.rating}", color = Muted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 4.dp))
    }
}

@Composable
private fun Artwork(url: String, kind: MediaKind, imageLoader: ImageLoader, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    if (url.isBlank()) {
        Box(modifier.background(Brush.linearGradient(listOf(Color(0xFF1E515B), Color(0xFF14262E)))), contentAlignment = Alignment.Center) {
            Icon(if (kind == MediaKind.LIVE) Icons.Outlined.LiveTv else Icons.Outlined.Movie, contentDescription = null, tint = Color(0xFF69C8CC), modifier = Modifier.size(42.dp))
        }
    } else {
        val request = remember(url) {
            ImageRequest.Builder(context)
                .data(url)
                .size(Size(640, 640))
                .precision(Precision.INEXACT)
                .crossfade(180)
                .build()
        }
        AsyncImage(model = request, imageLoader = imageLoader, contentDescription = entryDescription(kind), contentScale = ContentScale.Crop, modifier = modifier)
    }
}

@Composable
private fun DetailPage(
    state: BruTvUiState,
    entry: MediaEntry,
    isTv: Boolean,
    imageLoader: ImageLoader,
    onBack: () -> Unit,
    onPlay: (MediaEntry) -> Unit,
    onFavorite: (MediaEntry) -> Unit,
    isFavorite: (String) -> Boolean,
) {
    BackHandler(onBack = onBack)
    val width = LocalConfiguration.current.screenWidthDp
    if (!isTv && width < 780) {
        PhoneDetailPage(state, entry, imageLoader, onBack, onPlay, onFavorite, isFavorite)
    } else {
        Row(Modifier.fillMaxSize().background(Canvas).padding(if (isTv) 38.dp else 18.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Box(Modifier.width(if (width > 780) 300.dp else 130.dp).fillMaxHeight().clip(RoundedCornerShape(20.dp)).background(CardSurface)) {
                Artwork(entry.artwork, entry.kind, imageLoader, Modifier.fillMaxSize())
            }
            Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                DetailOverview(entry, isTv, onBack, onPlay, onFavorite, isFavorite)
                DetailSupplementary(state, entry, Modifier.weight(1f), onPlay)
            }
        }
    }
}

@Composable
private fun PhoneDetailPage(
    state: BruTvUiState,
    entry: MediaEntry,
    imageLoader: ImageLoader,
    onBack: () -> Unit,
    onPlay: (MediaEntry) -> Unit,
    onFavorite: (MediaEntry) -> Unit,
    isFavorite: (String) -> Boolean,
) {
    LazyColumn(
        Modifier.fillMaxSize().background(Canvas),
        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(key = "detail-artwork") {
            Box(Modifier.fillMaxWidth().height(190.dp).clip(RoundedCornerShape(17.dp)).background(CardSurface)) {
                Artwork(entry.artwork, entry.kind, imageLoader, Modifier.fillMaxSize())
            }
        }
        item(key = "detail-overview") {
            DetailOverview(entry, false, onBack, onPlay, onFavorite, isFavorite, compact = true)
        }
        when (entry.kind) {
            MediaKind.LIVE -> {
                item(key = "programme-heading") { DetailSectionHeading("Now and next") }
                if (state.programmes.isEmpty()) {
                    item(key = "programme-empty") { Text("No guide details were returned by this provider.", color = Muted) }
                } else {
                    items(state.programmes, key = { "${it.startEpochSeconds}:${it.title}" }) { ProgrammeCard(it) }
                }
            }
            MediaKind.SERIES -> {
                item(key = "episode-heading") { DetailSectionHeading("Episodes") }
                if (state.busy) {
                    item(key = "episode-loading") { CircularProgressIndicator(color = Aqua) }
                } else if (state.episodes.isEmpty()) {
                    item(key = "episode-empty") { Text("No episodes were returned for this series.", color = Muted) }
                } else {
                    episodeRows(state.episodes, onPlay)
                }
            }
            else -> Unit
        }
    }
}

@Composable
private fun DetailOverview(
    entry: MediaEntry,
    isTv: Boolean,
    onBack: () -> Unit,
    onPlay: (MediaEntry) -> Unit,
    onFavorite: (MediaEntry) -> Unit,
    isFavorite: (String) -> Boolean,
    compact: Boolean = false,
) {
    Column(verticalArrangement = Arrangement.spacedBy(if (compact) 10.dp else 12.dp)) {
        Text(entry.kind.displayName(), color = Aqua, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge)
        Text(
            entry.name,
            color = Color.White,
            style = when {
                isTv -> MaterialTheme.typography.headlineLarge
                compact -> MaterialTheme.typography.headlineSmall
                else -> MaterialTheme.typography.headlineMedium
            },
            fontWeight = FontWeight.Bold,
            maxLines = if (compact) 3 else 4,
            overflow = TextOverflow.Ellipsis,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (entry.rating.isNotBlank()) Text("★ ${entry.rating}", color = Muted)
            Text(entry.quality, color = Muted)
        }
        if (entry.plot.isNotBlank()) {
            Text(entry.plot, color = Muted, style = MaterialTheme.typography.bodyLarge, maxLines = 7, overflow = TextOverflow.Ellipsis)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (entry.kind != MediaKind.SERIES) {
                ActionButton("Play", { onPlay(entry) }, Modifier.weight(1f), icon = Icons.Outlined.PlayArrow, primary = true, isTv = isTv)
            }
            ActionButton(if (isFavorite(entry.id)) "Saved" else "Save", { onFavorite(entry) }, Modifier.weight(1f), icon = if (isFavorite(entry.id)) Icons.Outlined.Bookmark else Icons.Outlined.BookmarkBorder, isTv = isTv)
            ActionButton("Back", onBack, Modifier.weight(1f), icon = Icons.AutoMirrored.Outlined.ArrowBack, isTv = isTv)
        }
    }
}

@Composable
private fun DetailSupplementary(state: BruTvUiState, entry: MediaEntry, modifier: Modifier, onPlay: (MediaEntry) -> Unit) {
    when (entry.kind) {
        MediaKind.LIVE -> Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            DetailSectionHeading("Now and next")
            if (state.programmes.isEmpty()) {
                Text("No guide details were returned by this provider.", color = Muted)
            } else {
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(state.programmes, key = { "${it.startEpochSeconds}:${it.title}" }) { ProgrammeCard(it) }
                }
            }
        }
        MediaKind.SERIES -> Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            DetailSectionHeading("Episodes")
            when {
                state.busy -> CircularProgressIndicator(color = Aqua)
                state.episodes.isEmpty() -> Text("No episodes were returned for this series.", color = Muted)
                else -> LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    episodeRows(state.episodes, onPlay)
                }
            }
        }
        else -> Unit
    }
}

@Composable
private fun DetailSectionHeading(title: String) {
    Text(title, style = MaterialTheme.typography.titleMedium, color = Color.White, fontWeight = FontWeight.Bold)
}

@Composable
private fun ProgrammeCard(programme: Programme) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(CardSurface).padding(13.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(programme.title, color = Color.White, fontWeight = FontWeight.SemiBold)
        if (programme.startEpochSeconds > 0 && programme.endEpochSeconds > 0) {
            val start = DateFormat.format("h:mm a", Date(programme.startEpochSeconds * 1000)).toString()
            val end = DateFormat.format("h:mm a", Date(programme.endEpochSeconds * 1000)).toString()
            Text("$start – $end", color = Aqua, style = MaterialTheme.typography.labelSmall)
        }
        if (programme.description.isNotBlank()) Text(programme.description, color = Muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

private fun LazyListScope.episodeRows(episodes: List<MediaEntry>, onPlay: (MediaEntry) -> Unit) {
    episodes
        .sortedWith(compareBy({ it.seasonNumber ?: Int.MAX_VALUE }, { it.episodeNumber ?: Int.MAX_VALUE }, { it.name }))
        .groupBy { it.seasonNumber?.takeIf { season -> season > 0 } }
        .forEach { (season, seasonEpisodes) ->
            item(key = "season-${season ?: "unknown"}") {
                Text(season?.let { "Season $it" } ?: "Episodes", color = Aqua, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 9.dp, bottom = 2.dp))
            }
            items(seasonEpisodes, key = { it.id }) { episode -> EpisodeCard(episode, onPlay) }
        }
}

@Composable
private fun EpisodeCard(episode: MediaEntry, onPlay: (MediaEntry) -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .clip(RoundedCornerShape(12.dp))
            .background(CardSurface)
            .border(if (focused) 2.dp else 1.dp, if (focused) Aqua else Color.Transparent, RoundedCornerShape(12.dp))
            .clickable { onPlay(episode) }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(episode.name, color = Color.White, fontWeight = FontWeight.Medium)
            if (episode.plot.isNotBlank()) Text(episode.plot, color = Muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.Outlined.PlayArrow, contentDescription = "Play ${episode.name}", tint = Aqua)
    }
}

@Composable
private fun ProfilesPage(
    state: BruTvUiState,
    viewModel: BruTvViewModel,
    isTv: Boolean,
    onAddXtream: () -> Unit,
    onAddPlaylist: () -> Unit,
    onChoosePlaylist: () -> Unit,
    onScan: () -> Unit,
) {
    var removeProfileId by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (isTv) 30.dp else 18.dp, vertical = 22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Profiles", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text("Switch between saved providers on this device.", color = Muted)
        state.profiles.forEach { profile ->
            val active = profile.id == state.activeSourceId
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CardSurface).padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(Modifier.weight(1f)) {
                    Text(profile.name, color = Color.White, fontWeight = FontWeight.SemiBold)
                    Text(if (active) "Currently active" else if (profile.type == SourceType.M3U) "M3U playlist" else "Xtream provider", color = Muted, style = MaterialTheme.typography.bodySmall)
                }
                if (!active) ActionButton("Switch", { viewModel.switchProfile(profile.id) }, icon = Icons.Outlined.SwitchAccount, isTv = isTv)
                if (profile.isShareable()) ActionButton("QR", { viewModel.showLoginQr(profile) }, icon = Icons.Outlined.QrCode2, isTv = isTv)
                ActionButton("Remove", { removeProfileId = profile.id }, icon = Icons.Outlined.DeleteOutline, isTv = isTv)
            }
        }
        if (state.profiles.isEmpty()) Text("No saved profiles yet.", color = Muted)
        if (state.profiles.any { !it.isShareable() }) InfoNotice("Imported playlist files stay on this device. Use a playlist URL to share a profile with another device.")
        HorizontalDivider(color = Color(0xFF293A42))
        Text("Add a provider", style = MaterialTheme.typography.titleLarge, color = Color.White, fontWeight = FontWeight.Bold)
        if (isTv) {
            Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    ActionButton("Xtream login", onAddXtream, icon = Icons.Outlined.InsertLink, primary = true, isTv = true)
                    ActionButton("M3U URL", onAddPlaylist, icon = Icons.AutoMirrored.Outlined.PlaylistAdd, isTv = true)
                }
                ActionButton("Import M3U file", onChoosePlaylist, icon = Icons.Outlined.FileOpen, isTv = true)
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ActionButton("Xtream login", onAddXtream, Modifier.weight(1f), icon = Icons.Outlined.InsertLink, primary = true, isTv = false)
                    ActionButton("M3U URL", onAddPlaylist, Modifier.weight(1f), icon = Icons.AutoMirrored.Outlined.PlaylistAdd, isTv = false)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ActionButton("Import M3U file", onChoosePlaylist, Modifier.weight(1f), icon = Icons.Outlined.FileOpen, isTv = false)
                    ActionButton("Scan QR", onScan, Modifier.weight(1f), icon = Icons.Outlined.QrCodeScanner, isTv = false)
                }
            }
        }
        if (state.pendingPairInvite != null) InfoNotice("A TV code is waiting. Choose a profile from the pairing screen.")
    }
    removeProfileId?.let { id ->
        val profile = state.profiles.firstOrNull { it.id == id }
        AlertDialog(
            onDismissRequest = { removeProfileId = null },
            title = { Text("Remove profile?") },
            text = { Text("${profile?.name ?: "This profile"} and its favorites and resume history will be removed from this device.") },
            confirmButton = {
                TextButton(onClick = { viewModel.removeProfile(id); removeProfileId = null }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Outlined.DeleteOutline, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("Remove")
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { removeProfileId = null }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("Cancel")
                    }
                }
            },
        )
    }
}

@Composable
private fun SettingsPage(state: BruTvUiState, viewModel: BruTvViewModel, isTv: Boolean) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (isTv) 30.dp else 18.dp, vertical = 22.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text("Tune playback for your network and device.", color = Muted)
        Text("Buffer profile", style = MaterialTheme.typography.titleLarge, color = Color.White, fontWeight = FontWeight.SemiBold)
        BufferProfile.entries.forEach { profile ->
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(CardSurface).clickable { viewModel.setBufferProfile(profile.key) }.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = state.bufferProfile == profile.key, onClick = { viewModel.setBufferProfile(profile.key) })
                Column(Modifier.padding(start = 8.dp)) {
                    Text(profile.title, color = Color.White, fontWeight = FontWeight.Medium)
                    Text(profile.description, color = Muted, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(CardSurface).clickable { viewModel.setShowStats(!state.showStats) }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Playback diagnostics", color = Color.White, fontWeight = FontWeight.SemiBold)
                Text("Show resolution, bitrate, buffer and recovery details while playing.", color = Muted, style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = state.showStats, onCheckedChange = viewModel::setShowStats)
        }
        Text("Privacy", style = MaterialTheme.typography.titleLarge, color = Color.White, fontWeight = FontWeight.SemiBold)
        Text("BruTV has no account backend or bundled channels. Your provider credentials are stored encrypted on this device and sent only to the provider you add. Prefer HTTPS when available; HTTP connections do not encrypt credentials or streams in transit.", color = Muted)
        Text("BruTV • Version 1.0.0 (3)", color = Muted, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun EmptyCatalog(title: String, body: String, onAdd: () -> Unit, isTv: Boolean, onScan: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Outlined.Tv, contentDescription = null, tint = Aqua, modifier = Modifier.size(42.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color.White)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = Muted)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ActionButton("Add a provider", onAdd, icon = Icons.Outlined.Add, primary = true, isTv = isTv)
            if (!isTv) ActionButton("Scan QR", onScan, icon = Icons.Outlined.QrCodeScanner, isTv = false)
        }
    }
}

@Composable
private fun LoadingBlock(message: String) {
    Column(Modifier.fillMaxWidth().padding(36.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(color = Aqua)
        Text(message, color = Muted)
    }
}

@Composable
private fun ErrorBlock(message: String, onRetry: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp).clip(RoundedCornerShape(15.dp)).background(Color(0xFF351C1E)).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, color = Color(0xFFFFB7AB), modifier = Modifier.weight(1f))
        ActionButton("Retry", onRetry, icon = Icons.Outlined.Refresh, isTv = false)
    }
}

@Composable
private fun InlineError(message: String) {
    Text(message, color = Color(0xFFFFB7AB), modifier = Modifier.fillMaxWidth().background(Color(0xFF351C1E)).padding(horizontal = 18.dp, vertical = 10.dp))
}

@Composable
private fun PersistenceNotice(state: BruTvUiState, viewModel: BruTvViewModel, isTv: Boolean = false) {
    val message = state.persistenceError ?: if (state.saving) "Saving profile changes…" else return
    Row(
        Modifier.fillMaxWidth()
            .background(if (state.persistenceError != null) Color(0xFF351C1E) else Color(0xFF12353A))
            .padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            message,
            color = if (state.persistenceError != null) Color(0xFFFFB7AB) else Aqua,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
        )
        if (state.persistenceRetryable) {
            ActionButton("Retry save", viewModel::retryPersistence, icon = Icons.Outlined.Refresh, isTv = isTv)
        }
    }
}

@Composable
private fun InfoNotice(message: String) {
    Text(message, color = Aqua, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0xFF12353A)).padding(13.dp))
}

@Composable
private fun LocalPlaylistShareMessage(onClose: () -> Unit) {
    CenteredMessage(
        title = "This playlist is on this device",
        body = "A local playlist file cannot be shared by QR or sent to a TV. Add the playlist URL on the other device, or use a provider login profile.",
        action = "Close",
        actionIcon = Icons.Outlined.Close,
        onAction = onClose,
    )
}

@Composable
private fun PasteLinkDialog(
    initialText: String,
    onCancel: () -> Unit,
    onImport: (String) -> Boolean,
) {
    val clipboard = LocalClipboardManager.current
    var value by remember(initialText) { mutableStateOf(initialText) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Paste a BruTV sign-in link") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Links can contain provider sign-in details. BruTV keeps them on this device.", color = Muted)
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it; error = null },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Login link") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                )
                TextButton(onClick = { value = clipboard.getText()?.text.orEmpty(); error = null }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Outlined.ContentPaste, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("Paste from clipboard")
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = { if (value.isBlank() || !onImport(value.trim())) error = "Enter a valid BruTV login or TV pairing link." }) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Outlined.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("Continue")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("Cancel")
                }
            }
        },
    )
}

@Composable
private fun CenteredMessage(title: String, body: String, action: String, actionIcon: ImageVector, onAction: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(title, style = MaterialTheme.typography.headlineSmall, color = Color.White, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        Text(body, color = Muted)
        Spacer(Modifier.height(18.dp))
        ActionButton(action, onAction, icon = actionIcon, primary = true, isTv = true)
    }
}

@Composable
private fun ActionButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    primary: Boolean = false,
    enabled: Boolean = true,
    isTv: Boolean,
) {
    var focused by remember { mutableStateOf(false) }
    val colors = if (primary) ButtonDefaults.buttonColors(containerColor = Aqua, contentColor = Color(0xFF06201F))
    else ButtonDefaults.outlinedButtonColors(contentColor = Color.White, disabledContentColor = Muted)
    if (primary) {
        Button(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.onFocusChanged { focused = it.isFocused },
            shape = RoundedCornerShape(13.dp),
            colors = colors,
            border = if (focused) BorderStroke(3.dp, Color.White) else null,
            contentPadding = PaddingValues(horizontal = if (isTv) 23.dp else 17.dp, vertical = if (isTv) 14.dp else 11.dp),
        ) { ActionButtonContent(label, icon, isTv, primary = true) }
    } else {
        OutlinedButton(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.onFocusChanged { focused = it.isFocused },
            shape = RoundedCornerShape(13.dp),
            colors = colors,
            border = BorderStroke(if (focused) 3.dp else 1.dp, if (focused) Aqua else Color(0xFF42616B)),
            contentPadding = PaddingValues(horizontal = if (isTv) 20.dp else 14.dp, vertical = if (isTv) 13.dp else 10.dp),
        ) { ActionButtonContent(label, icon, isTv, primary = false) }
    }
}

@Composable
private fun ActionButtonContent(label: String, icon: ImageVector?, isTv: Boolean, primary: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (isTv) 7.dp else 5.dp)) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(if (isTv) 20.dp else 18.dp))
        }
        Text(
            label,
            fontWeight = if (primary) FontWeight.SemiBold else null,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun HeaderActionButton(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    isTv: Boolean = false,
    primary: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        onClick = onClick,
        modifier = modifier
            .onFocusChanged { focused = it.isFocused }
            .clip(RoundedCornerShape(10.dp)),
        shape = RoundedCornerShape(10.dp),
        color = when {
            primary -> Aqua
            focused -> Color(0xFF163C43)
            else -> Color(0xFF142229)
        },
        contentColor = if (primary) Color(0xFF06201F) else Color.White,
        border = BorderStroke(
            if (focused) 2.dp else 1.dp,
            when {
                focused -> Color.White
                primary -> Aqua
                else -> Color(0xFF243B45)
            },
        ),
    ) {
        Row(
            Modifier.padding(
                horizontal = if (isTv) 12.dp else 8.dp,
                vertical = if (isTv) 8.dp else 5.dp,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(if (isTv) 18.dp else 15.dp))
            Text(
                label,
                fontSize = if (isTv) 14.sp else 11.sp,
                fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Medium,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun HeaderTextButton(label: String, icon: ImageVector, onClick: () -> Unit, isTv: Boolean, primary: Boolean = false) {
    HeaderActionButton(label, icon, onClick, isTv = isTv, primary = primary)
}

@Composable
private fun BrandMark(compact: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(Modifier.size(35.dp).clip(RoundedCornerShape(11.dp)).background(Aqua), contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.PlayArrow, contentDescription = null, tint = Color(0xFF06201F), modifier = Modifier.size(26.dp))
        }
        if (!compact) {
            Text("BruTV", color = Color.White, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
private fun BruTvSplashScreen(isTv: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Canvas),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(if (isTv) 20.dp else 16.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(if (isTv) 80.dp else 68.dp)
                    .clip(RoundedCornerShape(if (isTv) 24.dp else 20.dp))
                    .background(
                        Brush.linearGradient(
                            listOf(Color(0xFF55E2D1), Color(0xFF167E74))
                        )
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.PlayArrow,
                    contentDescription = null,
                    tint = Color(0xFF06201F),
                    modifier = Modifier.size(if (isTv) 52.dp else 44.dp),
                )
            }
            Text(
                "BruTV",
                style = MaterialTheme.typography.headlineLarge.copy(
                    fontSize = if (isTv) 40.sp else 32.sp,
                    letterSpacing = (-0.5).sp,
                ),
                fontWeight = FontWeight.ExtraBold,
                color = Color.White,
            )
            Text(
                "IPTV that just works.",
                style = MaterialTheme.typography.titleMedium.copy(
                    fontSize = if (isTv) 18.sp else 15.sp,
                ),
                fontWeight = FontWeight.Medium,
                color = Aqua,
            )
            Spacer(Modifier.height(8.dp))
            CircularProgressIndicator(
                modifier = Modifier.size(22.dp),
                color = Aqua.copy(alpha = 0.85f),
                strokeWidth = 2.5.dp,
            )
        }
    }
}

private fun MediaKind.displayName(): String = when (this) {
    MediaKind.LIVE -> "Live channel"
    MediaKind.MOVIE -> "Movie"
    MediaKind.SERIES -> "Series"
    MediaKind.EPISODE -> "Episode"
}

private fun entryDescription(kind: MediaKind): String = when (kind) {
    MediaKind.LIVE -> "Channel artwork"
    MediaKind.MOVIE, MediaKind.EPISODE -> "Program poster"
    MediaKind.SERIES -> "Series poster"
}

private fun SourceConfig.isShareable(): Boolean = !(type == SourceType.M3U && playlistUrl.startsWith("file:"))
