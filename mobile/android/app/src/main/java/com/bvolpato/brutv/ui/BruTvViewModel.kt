package com.bvolpato.brutv.ui

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.Immutable
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bvolpato.brutv.data.CatalogDiskCache
import com.bvolpato.brutv.data.CatalogRepository
import com.bvolpato.brutv.data.CatalogSection
import com.bvolpato.brutv.data.LibraryState
import com.bvolpato.brutv.data.LoginLinks
import com.bvolpato.brutv.data.M3UPlaylistParser
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import com.bvolpato.brutv.data.MovieDetails
import com.bvolpato.brutv.data.ProfileStore
import com.bvolpato.brutv.data.Programme
import com.bvolpato.brutv.data.SavedState
import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import com.bvolpato.brutv.data.updateResumePositions
import com.bvolpato.brutv.playback.BufferProfile
import com.bvolpato.brutv.playback.LiveFormatCache
import com.bvolpato.brutv.playback.PlaybackController
import com.bvolpato.brutv.signin.Pairing
import com.bvolpato.brutv.signin.PairingInvite
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class BruTvDestination { LIVE, MOVIES, SERIES, FAVORITES, RECENTS, SETTINGS, PROFILES }
enum class BruTvPage { HOME, SIGN_IN, DETAIL, SCAN_QR, TV_PAIRING, LOGIN_QR }

@Immutable
data class LoginDraft(
    val name: String = "",
    val type: SourceType = SourceType.XTREAM,
    val server: String = "",
    val username: String = "",
    val password: String = "",
    val playlistUrl: String = "",
)

@Immutable
data class BruTvUiState(
    val initialized: Boolean = false,
    val profiles: List<SourceConfig> = emptyList(),
    val activeSourceId: String? = null,
    val page: BruTvPage = BruTvPage.HOME,
    val destination: BruTvDestination = BruTvDestination.LIVE,
    val libraryKind: MediaKind = MediaKind.LIVE,
    val sections: Map<MediaKind, CatalogSection> = emptyMap(),
    val visibleEntries: List<MediaEntry> = emptyList(),
    val selectedCategoryId: String? = null,
    val selectedEntry: MediaEntry? = null,
    val selectedMovieDetails: MovieDetails? = null,
    val episodes: List<MediaEntry> = emptyList(),
    val programmes: List<Programme> = emptyList(),
    val epgRevision: Int = 0,
    val playingEntry: MediaEntry? = null,
    val playQueue: List<MediaEntry> = emptyList(),
    val searchText: String = "",
    val qualityFilter: String? = null,
    val onlyFavorites: Boolean = false,
    val draft: LoginDraft = LoginDraft(),
    val busy: Boolean = false,
    val catalogLoading: Boolean = false,
    val pageError: String? = null,
    val catalogError: String? = null,
    val persistenceError: String? = null,
    val persistenceRetryable: Boolean = false,
    val saving: Boolean = false,
    val pendingPairInvite: PairingInvite? = null,
    val loginQrSource: SourceConfig? = null,
    val bufferProfile: String = "balanced",
    val showStats: Boolean = false,
    val language: String = "system",
    val liveRewind: Boolean = false,
    val preferredAudioLanguage: String? = null,
    val preferredSubtitleLanguage: String? = null,
    val subtitlesEnabled: Boolean = false,
    val defaultAspectMode: String = "fit",
    val autoFrameRate: Boolean = false,
    val maxConnections: Int = 1,
    val library: LibraryState = LibraryState(),
) {
    val activeSource: SourceConfig? get() = profiles.firstOrNull { it.id == activeSourceId }
    val activeSection: CatalogSection get() = sections[destination.browseKind(libraryKind)] ?: CatalogSection()
}

private data class PersistenceRequest(
    val revision: Long,
    val state: SavedState,
    val localPlaylistDeleteUrls: Set<String>,
    val showSavingIndicator: Boolean,
)

/** Owns profile persistence, hoisted playback lifecycle, source switching and demand-loaded catalog state. */
class BruTvViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val catalogCacheDir = File(application.cacheDir, "catalog_cache")
    private val _state = MutableStateFlow(BruTvUiState())
    val state = _state.asStateFlow()

    private var savedState = SavedState()
    private var storeReady = false
    private var persistenceRevision = 0L
    private var latestPersistenceRequest: PersistenceRequest? = null
    private val credentialsDirty = AtomicBoolean(false)
    private val pendingLocalPlaylistDeletes = mutableSetOf<String>()
    private var connectJob: Job? = null
    private var connectingLocalSource: SourceConfig? = null
    private var playlistImportJob: Job? = null
    private var playlistImportGeneration = 0L
    private var repository: CatalogRepository? = null
    private var linkBeforeRestore: String? = null
    private var catalogJob: Job? = null
    private var detailJob: Job? = null
    private var xmltvJob: Job? = null
    private var searchDebounceJob: Job? = null
    private var searchJob: Job? = null
    private var pageBeforeOverlay = BruTvPage.HOME
    private var sourceGeneration = 0L
    private val persistenceQueue = Channel<PersistenceRequest>(Channel.CONFLATED)
    private val filterGeneration = AtomicLong()
    private var hoistedPlaybackController: PlaybackController? = null

    init {
        viewModelScope.launch(Dispatchers.IO) {
            val readResult = runCatching { store.read() }
            val restored = readResult.getOrDefault(SavedState())
            withContext(Dispatchers.Main.immediate) {
                savedState = restored
                storeReady = readResult.isSuccess
                val activeId = restored.activeSourceId?.takeIf { id -> restored.profiles.any { it.id == id } }
                _state.update {
                    it.copy(
                        initialized = true,
                        profiles = restored.profiles,
                        activeSourceId = activeId,
                        bufferProfile = restored.bufferProfile,
                        showStats = restored.showStats,
                        language = restored.language,
                        liveRewind = restored.liveRewind,
                        preferredAudioLanguage = restored.preferredAudioLanguage,
                        preferredSubtitleLanguage = restored.preferredSubtitleLanguage,
                        subtitlesEnabled = restored.subtitlesEnabled,
                        defaultAspectMode = restored.defaultAspectMode,
                        autoFrameRate = restored.autoFrameRate,
                        library = activeId?.let { restored.libraries[it] }.orEmptyLibrary(),
                        pageError = readResult.exceptionOrNull()?.let { "Saved profiles could not be loaded. Existing encrypted data was left untouched." },
                        persistenceError = readResult.exceptionOrNull()?.let { "Saved profiles could not be read. BruTV has kept the encrypted file unchanged; profile changes in this session cannot be saved." },
                    )
                }
                activeId?.let { id -> activate(restored.profiles.first { it.id == id }, persist = false) }
                linkBeforeRestore?.let { raw ->
                    linkBeforeRestore = null
                    acceptLink(raw)
                }
            }
        }
        viewModelScope.launch(Dispatchers.IO) {
            for (request in persistenceQueue) {
                val writeCreds = credentialsDirty.getAndSet(false)
                val writeFailure = runCatching {
                    if (writeCreds) {
                        store.writeCredentials(request.state)
                    }
                    store.writePreferences(request.state)
                }.exceptionOrNull()
                if (writeFailure != null && writeCreds) {
                    credentialsDirty.set(true)
                }
                val referencedUrls = request.state.profiles
                    .filter { it.type == SourceType.M3U && it.playlistUrl.startsWith("file:") }
                    .mapTo(mutableSetOf()) { it.playlistUrl }
                val deletionCandidates = request.localPlaylistDeleteUrls - referencedUrls
                val canDelete = writeFailure == null && deletionCandidates.isNotEmpty() &&
                    withContext(Dispatchers.Main.immediate) { request.revision == persistenceRevision }
                val failedDeletes = if (canDelete) {
                    deletionCandidates.filterNot(::deletePrivatePlaylistCopy).toSet()
                } else {
                    emptySet()
                }
                withContext(Dispatchers.Main.immediate) {
                    if (request.revision == persistenceRevision) {
                        if (writeFailure == null) {
                            pendingLocalPlaylistDeletes.removeAll(request.localPlaylistDeleteUrls - deletionCandidates)
                            pendingLocalPlaylistDeletes.removeAll(deletionCandidates - failedDeletes)
                        }
                        _state.update {
                            it.copy(
                                saving = false,
                                persistenceError = when {
                                    writeFailure != null && writeCreds -> "Profile changes could not be saved. Your current session is still available."
                                    writeFailure != null -> it.persistenceError
                                    failedDeletes.isNotEmpty() -> "Profile changes were saved, but an imported playlist copy could not be deleted. Retry cleanup."
                                    else -> null
                                },
                                persistenceRetryable = (writeFailure != null && writeCreds) || failedDeletes.isNotEmpty(),
                            )
                        }
                    }
                }
            }
        }
    }

    /** Returns the ViewModel-scoped PlaybackController, keeping ExoPlayer and OkHttp warm across navigation. */
    internal fun acquirePlaybackController(): PlaybackController {
        val current = _state.value
        val desiredProfile = BufferProfile.fromKey(current.bufferProfile)
        val existing = hoistedPlaybackController
        val controller = if (existing != null && existing.profile == desiredProfile) {
            existing
        } else {
            existing?.release()
            PlaybackController(
                context = getApplication(),
                profile = desiredProfile,
                maxConnections = current.maxConnections,
                liveRewind = current.liveRewind,
            ).also { hoistedPlaybackController = it }
        }
        controller.maxConnections = current.maxConnections
        controller.liveRewind = current.liveRewind
        controller.applyPreferences(
            preferredAudioLanguage = current.preferredAudioLanguage,
            preferredSubtitleLanguage = current.preferredSubtitleLanguage,
            subtitlesEnabled = current.subtitlesEnabled,
            autoFrameRate = current.autoFrameRate,
        )
        return controller
    }

    fun acceptLink(raw: String) {
        if (!_state.value.initialized) {
            linkBeforeRestore = raw
            return
        }
        Pairing.parseInvite(raw)?.let { invite ->
            _state.update {
                it.copy(
                    page = if (it.profiles.isEmpty()) BruTvPage.SIGN_IN else BruTvPage.HOME,
                    pendingPairInvite = invite,
                    pageError = null,
                )
            }
            return
        }
        val source = LoginLinks.parse(raw)
        if (source == null) {
            _state.update {
                it.copy(
                    page = if (it.page == BruTvPage.SCAN_QR) pageBeforeOverlay else it.page,
                    pageError = "This BruTV link could not be read.",
                )
            }
            return
        }
        _state.update {
            it.copy(
                page = BruTvPage.SIGN_IN,
                draft = source.toDraft(),
                pageError = null,
            )
        }
    }

    fun supportsLink(raw: String): Boolean = LoginLinks.parse(raw) != null || Pairing.parseInvite(raw) != null

    fun openSignIn(type: SourceType = SourceType.XTREAM) {
        cancelPlaylistImport()
        cancelConnect()
        if (_state.value.page != BruTvPage.SCAN_QR && _state.value.page != BruTvPage.TV_PAIRING) {
            pageBeforeOverlay = BruTvPage.HOME
        }
        _state.update { it.copy(page = BruTvPage.SIGN_IN, draft = LoginDraft(type = type), pageError = null) }
    }

    fun closePage() {
        cancelPlaylistImport()
        val current = _state.value
        if (current.busy && current.page in setOf(BruTvPage.SIGN_IN, BruTvPage.TV_PAIRING)) cancelConnect()
        when (current.page) {
            BruTvPage.DETAIL -> _state.update {
                it.copy(
                    page = BruTvPage.HOME,
                    selectedEntry = null,
                    selectedMovieDetails = null,
                    episodes = emptyList(),
                    programmes = emptyList(),
                )
            }
            BruTvPage.LOGIN_QR, BruTvPage.SCAN_QR, BruTvPage.TV_PAIRING, BruTvPage.SIGN_IN -> _state.update {
                it.copy(
                    page = pageBeforeOverlay,
                    loginQrSource = null,
                    pageError = null,
                    busy = if (current.page == BruTvPage.SIGN_IN || current.page == BruTvPage.TV_PAIRING) false else it.busy,
                )
            }
            BruTvPage.HOME -> Unit
        }
    }

    fun openScanner() {
        pageBeforeOverlay = _state.value.page
        _state.update { it.copy(page = BruTvPage.SCAN_QR, pageError = null) }
    }

    fun openTvPairing() {
        pageBeforeOverlay = _state.value.page
        _state.update { it.copy(page = BruTvPage.TV_PAIRING, pageError = null) }
    }

    fun onDestinationSelected(destination: BruTvDestination) {
        val selectedKind = destination.toMediaKindOrNull()
        _state.update {
            it.copy(
                destination = destination,
                libraryKind = selectedKind ?: it.libraryKind,
                selectedCategoryId = null,
                qualityFilter = null,
                onlyFavorites = false,
                searchText = "",
                catalogError = null,
            )
        }
        val kind = selectedKind ?: if (destination.isLibrary()) _state.value.libraryKind else null
        kind?.let { loadCatalog(it) }
        recomputeVisible()
    }

    fun selectLibraryKind(kind: MediaKind) {
        if (kind !in setOf(MediaKind.LIVE, MediaKind.MOVIE, MediaKind.SERIES)) return
        _state.update { it.copy(libraryKind = kind, selectedCategoryId = null, searchText = "", catalogError = null) }
        loadCatalog(kind)
        recomputeVisible()
    }

    fun selectCategory(id: String?) {
        _state.update { it.copy(selectedCategoryId = id) }
        recomputeVisible()
    }

    fun setSearchText(value: String) {
        _state.update { it.copy(searchText = value) }
        searchDebounceJob?.cancel()
        val request = filterGeneration.incrementAndGet()
        searchDebounceJob = viewModelScope.launch {
            delay(120)
            recomputeVisible(request, cancelDebounce = false)
        }
    }

    fun setQualityFilter(quality: String?) {
        _state.update { it.copy(qualityFilter = quality) }
        recomputeVisible()
    }

    fun setOnlyFavorites(enabled: Boolean) {
        _state.update { it.copy(onlyFavorites = enabled) }
        recomputeVisible()
    }

    fun retryCatalog() {
        val current = _state.value
        current.destination.toMediaKindOrNull()?.let { loadCatalog(it, force = true) }
            ?: if (current.destination.isLibrary()) loadCatalog(current.libraryKind, force = true) else Unit
    }

    fun updateDraft(transform: (LoginDraft) -> LoginDraft) = _state.update { it.copy(draft = transform(it.draft), pageError = null) }

    fun connectDraft() {
        val draft = _state.value.draft
        val raw = when (draft.type) {
            SourceType.XTREAM -> SourceConfig(
                name = draft.name.ifBlank { draft.username },
                type = SourceType.XTREAM,
                server = draft.server,
                username = draft.username,
                password = draft.password,
            )
            SourceType.M3U -> SourceConfig(
                name = draft.name.ifBlank { "My playlist" },
                type = SourceType.M3U,
                playlistUrl = draft.playlistUrl,
            )
        }
        connect(raw)
    }

    /** Copies a user-selected playlist into private app storage before parsing or saving its path. */
    fun importLocalPlaylist(uri: Uri) {
        cancelPlaylistImport()
        val generation = ++playlistImportGeneration
        _state.update { it.copy(busy = true, pageError = null) }
        playlistImportJob = viewModelScope.launch {
            val copied = runCatching {
                withContext(Dispatchers.IO) {
                    val importContext = currentCoroutineContext()
                    importContext.ensureActive()
                    val resolver = getApplication<Application>().contentResolver
                    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0).orEmpty() else ""
                    }.orEmpty().ifBlank { "Playlist.m3u" }
                    if (!name.substringBefore('?').lowercase().endsWith(".m3u") && !name.substringBefore('?').lowercase().endsWith(".m3u8")) {
                        throw IllegalArgumentException("Choose an .m3u or .m3u8 playlist file.")
                    }
                    val directory = File(getApplication<Application>().noBackupFilesDir, "playlists").apply { mkdirs() }
                    if (!directory.isDirectory) throw IllegalStateException("BruTV could not prepare private playlist storage.")
                    val destination = File(directory, "${UUID.randomUUID()}.m3u")
                    val temporary = File(directory, "${destination.name}.tmp")
                    try {
                        val input = resolver.openInputStream(uri) ?: throw IllegalArgumentException("The selected playlist could not be opened.")
                        input.use { source ->
                            FileOutputStream(temporary).use { output ->
                                val buffer = ByteArray(16 * 1024)
                                var total = 0L
                                while (true) {
                                    importContext.ensureActive()
                                    val count = source.read(buffer)
                                    if (count < 0) break
                                    total += count
                                    if (total > M3UPlaylistParser.maxPlaylistBytes) {
                                        throw IllegalArgumentException("This playlist is larger than BruTV supports.")
                                    }
                                    output.write(buffer, 0, count)
                                }
                                output.fd.sync()
                            }
                        }
                        if (!temporary.renameTo(destination)) throw IllegalStateException("BruTV could not save the playlist privately.")
                        importContext.ensureActive()
                        SourceConfig(
                            name = name.substringBeforeLast('.').take(60).ifBlank { "Local playlist" },
                            type = SourceType.M3U,
                            playlistUrl = destination.toURI().toString(),
                        ).normalized()
                    } catch (error: Throwable) {
                        temporary.delete()
                        destination.delete()
                        throw error
                    }
                }
            }
            if (generation != playlistImportGeneration || !currentCoroutineContext().isActive) {
                copied.getOrNull()?.let(::deleteImportedPlaylist)
                return@launch
            }
            _state.update { it.copy(busy = false) }
            copied.onSuccess { source -> connect(source, removeLocalFileOnFailure = true) }.onFailure { error ->
                _state.update { it.copy(pageError = safeMessage(error)) }
            }
            playlistImportJob = null
        }
    }

    fun connect(source: SourceConfig) = connect(source, removeLocalFileOnFailure = false)

    private fun connect(source: SourceConfig, removeLocalFileOnFailure: Boolean) {
        if (!removeLocalFileOnFailure) cancelPlaylistImport()
        cancelConnect()
        val normalized = runCatching { source.normalized() }.getOrElse { error ->
            if (removeLocalFileOnFailure) deleteImportedPlaylist(source)
            _state.update { it.copy(busy = false, pageError = error.message ?: "Check the sign-in details and try again.") }
            return
        }
        connectingLocalSource = normalized.takeIf { removeLocalFileOnFailure && it.type == SourceType.M3U && it.playlistUrl.startsWith("file:") }
        val generation = ++sourceGeneration
        catalogJob?.cancel()
        xmltvJob?.cancel()
        _state.update { it.copy(busy = true, pageError = null, catalogError = null) }
        connectJob = viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    newRepository(normalized).also { it.authenticate() }
                }
            }
            if (generation != sourceGeneration) return@launch
            result.onSuccess { nextRepository ->
                if (connectingLocalSource?.id == normalized.id) connectingLocalSource = null
                val profiles = _state.value.profiles.filterNot { it.id == normalized.id } + normalized
                savedState = savedState.copy(
                    profiles = profiles,
                    activeSourceId = normalized.id,
                    libraries = savedState.libraries + (normalized.id to savedState.libraries[normalized.id].orEmptyLibrary()),
                )
                repository = nextRepository
                LiveFormatCache.shared.clear()
                _state.update {
                    it.copy(
                        busy = false,
                        profiles = profiles,
                        activeSourceId = normalized.id,
                        page = BruTvPage.HOME,
                        pageError = null,
                        catalogError = null,
                        sections = emptyMap(),
                        destination = BruTvDestination.LIVE,
                        selectedCategoryId = null,
                        maxConnections = nextRepository.maxConnections,
                        library = savedState.libraries[normalized.id].orEmptyLibrary(),
                    )
                }
                persist(writeCredentials = true)
                loadCatalog(MediaKind.LIVE)
                if (_state.value.pendingPairInvite != null) _state.update { it.copy(pageError = "Choose the profile to send to the TV.") }
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                if (connectingLocalSource?.id == normalized.id) connectingLocalSource = null
                if (removeLocalFileOnFailure) deleteImportedPlaylist(normalized)
                _state.update { it.copy(busy = false, pageError = safeMessage(error)) }
            }
        }
    }

    fun switchProfile(id: String) {
        val source = _state.value.profiles.firstOrNull { it.id == id } ?: return
        if (id == _state.value.activeSourceId) return
        activate(source, persist = true)
    }

    fun removeProfile(id: String) {
        val current = _state.value
        current.profiles.firstOrNull { it.id == id }
            ?.takeIf { it.type == SourceType.M3U && it.playlistUrl.startsWith("file:") }
            ?.let { pendingLocalPlaylistDeletes += it.playlistUrl }
        val profiles = current.profiles.filterNot { it.id == id }
        val activeId = if (current.activeSourceId == id) profiles.firstOrNull()?.id else current.activeSourceId
        savedState = savedState.copy(
            profiles = profiles,
            activeSourceId = activeId,
            libraries = savedState.libraries - id,
        )
        _state.update { it.copy(profiles = profiles, activeSourceId = activeId, pageError = null) }
        persist(writeCredentials = true)
        viewModelScope.launch(Dispatchers.IO) {
            CatalogDiskCache(catalogCacheDir).clearSource(id)
        }
        if (activeId == null) {
            sourceGeneration++
            catalogJob?.cancel()
            xmltvJob?.cancel()
            repository = null
            LiveFormatCache.shared.clear()
            _state.update { it.copy(sections = emptyMap(), visibleEntries = emptyList(), library = LibraryState(), destination = BruTvDestination.LIVE, maxConnections = 1) }
        } else if (activeId != current.activeSourceId) {
            profiles.firstOrNull { it.id == activeId }?.let { activate(it, persist = false) }
        }
    }

    fun openEntry(entry: MediaEntry) {
        detailJob?.cancel()
        val initialProgrammes = if (entry.kind == MediaKind.LIVE) cachedProgrammes(entry) else emptyList()
        _state.update {
            it.copy(
                page = BruTvPage.DETAIL,
                selectedEntry = entry,
                selectedMovieDetails = null,
                episodes = emptyList(),
                programmes = initialProgrammes,
                pageError = null,
            )
        }
        when (entry.kind) {
            MediaKind.SERIES -> detailJob = viewModelScope.launch {
                val selectedRepository = repository ?: return@launch
                val generation = sourceGeneration
                _state.update { it.copy(busy = true) }
                val result = runCatching {
                    withContext(Dispatchers.IO) {
                        selectedRepository.episodes(entry).sortedWith(
                            compareBy({ it.seasonNumber ?: Int.MAX_VALUE }, { it.episodeNumber ?: Int.MAX_VALUE }, { it.name }),
                        )
                    }
                }
                if (generation != sourceGeneration || _state.value.selectedEntry?.id != entry.id) return@launch
                _state.update { it.copy(busy = false, episodes = result.getOrDefault(emptyList()), pageError = result.exceptionOrNull()?.let(::safeMessage)) }
            }
            MediaKind.MOVIE -> detailJob = viewModelScope.launch {
                val selectedRepository = repository ?: return@launch
                val generation = sourceGeneration
                val result = runCatching { withContext(Dispatchers.IO) { selectedRepository.vodInfo(entry) } }
                if (generation == sourceGeneration && _state.value.selectedEntry?.id == entry.id) {
                    val details = result.getOrNull()
                    if (details != null) {
                        _state.update { it.copy(selectedMovieDetails = details) }
                    }
                }
            }
            MediaKind.LIVE -> detailJob = viewModelScope.launch {
                val selectedRepository = repository ?: return@launch
                val generation = sourceGeneration
                val result = runCatching { withContext(Dispatchers.IO) { selectedRepository.guide(entry) } }
                if (generation == sourceGeneration && _state.value.selectedEntry?.id == entry.id) {
                    val fetched = result.getOrDefault(emptyList())
                    if (fetched.isNotEmpty()) {
                        _state.update { it.copy(programmes = fetched, epgRevision = it.epgRevision + 1) }
                    } else if (initialProgrammes.isEmpty()) {
                        // Fall back to XMLTV if short EPG returned nothing.
                        runCatching { withContext(Dispatchers.IO) { selectedRepository.loadXmltv() } }
                        if (generation == sourceGeneration && _state.value.selectedEntry?.id == entry.id) {
                            _state.update {
                                it.copy(
                                    programmes = selectedRepository.cachedGuide(entry),
                                    epgRevision = it.epgRevision + 1,
                                )
                            }
                        }
                    }
                }
            }
            else -> Unit
        }
    }

    fun cachedProgrammes(channel: MediaEntry): List<Programme> =
        repository?.cachedGuide(channel).orEmpty()

    fun requestChannelGuide(channel: MediaEntry) {
        if (channel.kind != MediaKind.LIVE) return
        val selectedRepository = repository ?: return
        val generation = sourceGeneration
        viewModelScope.launch(Dispatchers.IO) {
            val loaded = runCatching { selectedRepository.guide(channel) }.getOrDefault(emptyList())
            if (loaded.isNotEmpty()) {
                withContext(Dispatchers.Main.immediate) {
                    if (generation == sourceGeneration) {
                        _state.update { it.copy(epgRevision = it.epgRevision + 1) }
                    }
                }
            }
        }
    }

    fun loadXmltvInBackground() {
        val selectedRepository = repository ?: return
        if (xmltvJob?.isActive == true) return
        val generation = sourceGeneration
        xmltvJob = viewModelScope.launch(Dispatchers.IO) {
            val guide = runCatching { selectedRepository.loadXmltv() }.getOrNull()
            if (guide != null && !guide.isEmpty) {
                withContext(Dispatchers.Main.immediate) {
                    if (generation == sourceGeneration) {
                        _state.update { it.copy(epgRevision = it.epgRevision + 1) }
                    }
                }
            }
        }
    }

    fun play(entry: MediaEntry) {
        if (entry.streamUrl.isBlank()) {
            _state.update { it.copy(pageError = "This item does not have a playable stream.") }
            return
        }
        recordRecent(entry)
        val snapshot = _state.value
        val queue = if (entry.kind == MediaKind.EPISODE) {
            val playableEpisodes = snapshot.episodes.filter { it.streamUrl.isNotBlank() }
            if (playableEpisodes.any { it.id == entry.id }) playableEpisodes else listOf(entry)
        } else {
            val visible = snapshot.visibleEntries
            val inVisible = visible.isNotEmpty() &&
                visible.first().kind == entry.kind &&
                (snapshot.activeSection.entriesById.containsKey(entry.id) || visible.size <= 32 && visible.any { it.id == entry.id })
            if (inVisible) visible else listOf(entry)
        }
        _state.update { it.copy(playingEntry = entry, playQueue = queue, pageError = null) }
    }

    fun closePlayer(entry: MediaEntry?, positionMs: Long, durationMs: Long = 0L) {
        val target = entry ?: _state.value.playingEntry
        target?.let { updateResumePosition(it, positionMs, durationMs, completed = false, force = true) }
        _state.update { it.copy(playingEntry = null) }
    }

    fun onPlayerItemChanged(entry: MediaEntry) {
        recordRecent(entry)
        _state.update { it.copy(playingEntry = entry) }
    }

    fun savePosition(
        entry: MediaEntry,
        positionMs: Long,
        durationMs: Long = 0L,
        force: Boolean = false,
    ) = updateResumePosition(entry, positionMs, durationMs, completed = false, force = force)

    fun onPlaybackEnded(entry: MediaEntry) {
        updateResumePosition(entry, positionMs = 0L, durationMs = 0L, completed = true, force = true)
    }

    fun resumePositionFor(entryId: String): Long = _state.value.library.resumePositions[entryId] ?: 0L

    fun isFavorite(id: String): Boolean = id in _state.value.library.favoriteIds

    fun toggleFavorite(entry: MediaEntry) {
        val current = _state.value.library
        val favorites = if (entry.id in current.favoriteIds) current.favoriteIds - entry.id else current.favoriteIds + entry.id
        updateLibrary(current.copy(favoriteIds = favorites))
        recomputeVisible()
    }

    fun setBufferProfile(key: String) {
        if (key !in setOf("ultra_low", "balanced", "high_stability")) return
        savedState = savedState.copy(bufferProfile = key)
        _state.update { it.copy(bufferProfile = key) }
        persist(writeCredentials = false)
    }

    fun setShowStats(enabled: Boolean) {
        savedState = savedState.copy(showStats = enabled)
        _state.update { it.copy(showStats = enabled) }
        persist(writeCredentials = false)
    }

    fun setLanguage(lang: String) {
        if (lang !in setOf("system", "pt", "en")) return
        savedState = savedState.copy(language = lang)
        _state.update { it.copy(language = lang) }
        persist(writeCredentials = false)
    }

    fun setLiveRewind(enabled: Boolean) {
        savedState = savedState.copy(liveRewind = enabled)
        _state.update { it.copy(liveRewind = enabled) }
        hoistedPlaybackController?.liveRewind = enabled
        persist(writeCredentials = false)
    }

    fun setDefaultAspectMode(mode: String) {
        if (mode !in setOf("fit", "zoom", "fill")) return
        savedState = savedState.copy(defaultAspectMode = mode)
        _state.update { it.copy(defaultAspectMode = mode) }
        persist(writeCredentials = false)
    }

    fun setAutoFrameRate(enabled: Boolean) {
        savedState = savedState.copy(autoFrameRate = enabled)
        _state.update { it.copy(autoFrameRate = enabled) }
        hoistedPlaybackController?.applyPreferences(
            preferredAudioLanguage = savedState.preferredAudioLanguage,
            preferredSubtitleLanguage = savedState.preferredSubtitleLanguage,
            subtitlesEnabled = savedState.subtitlesEnabled,
            autoFrameRate = enabled,
        )
        persist(writeCredentials = false)
    }

    fun setTrackPreferences(
        audioLanguage: String?,
        subtitleLanguage: String?,
        subtitlesEnabled: Boolean,
    ) {
        val cleanAudio = audioLanguage?.trim()?.takeIf { it.isNotEmpty() }
        val cleanSub = subtitleLanguage?.trim()?.takeIf { it.isNotEmpty() }
        savedState = savedState.copy(
            preferredAudioLanguage = cleanAudio,
            preferredSubtitleLanguage = cleanSub,
            subtitlesEnabled = subtitlesEnabled,
        )
        _state.update {
            it.copy(
                preferredAudioLanguage = cleanAudio,
                preferredSubtitleLanguage = cleanSub,
                subtitlesEnabled = subtitlesEnabled,
            )
        }
        persist(writeCredentials = false)
    }

    fun retryPersistence() {
        if (!storeReady) return
        val latest = latestPersistenceRequest ?: return
        credentialsDirty.set(true)
        val next = latest.copy(revision = ++persistenceRevision, showSavingIndicator = true)
        latestPersistenceRequest = next
        _state.update { it.copy(saving = true, persistenceError = null, persistenceRetryable = false) }
        persistenceQueue.trySend(next)
    }

    fun showLoginQr(source: SourceConfig? = _state.value.activeSource) {
        if (source == null) return
        pageBeforeOverlay = _state.value.page
        _state.update { it.copy(page = BruTvPage.LOGIN_QR, loginQrSource = source) }
    }

    fun pairingReceivedSource(source: SourceConfig) {
        pageBeforeOverlay = BruTvPage.HOME
        _state.update { it.copy(page = BruTvPage.SIGN_IN, draft = source.toDraft(), pageError = null) }
        connect(source)
    }

    fun clearPairingInvite() = _state.update { it.copy(pendingPairInvite = null, pageError = null) }

    private fun newRepository(source: SourceConfig): CatalogRepository = CatalogRepository(
        source = source,
        localPlaylistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists"),
        cacheDirectory = catalogCacheDir,
    )

    private fun activate(source: SourceConfig, persist: Boolean) {
        cancelPlaylistImport()
        connectJob?.cancel()
        connectJob = null
        sourceGeneration++
        val generation = sourceGeneration
        catalogJob?.cancel()
        detailJob?.cancel()
        xmltvJob?.cancel()
        LiveFormatCache.shared.clear()
        val currentRepository = newRepository(source)
        repository = currentRepository
        val library = savedState.libraries[source.id].orEmptyLibrary()
        if (persist) savedState = savedState.copy(activeSourceId = source.id)
        _state.update {
            it.copy(
                activeSourceId = source.id,
                destination = BruTvDestination.LIVE,
                page = BruTvPage.HOME,
                sections = emptyMap(),
                visibleEntries = emptyList(),
                selectedCategoryId = null,
                selectedEntry = null,
                selectedMovieDetails = null,
                episodes = emptyList(),
                programmes = emptyList(),
                maxConnections = 1,
                library = library,
                catalogLoading = true,
                catalogError = null,
            )
        }
        if (persist) persist(writeCredentials = true)
        catalogJob = viewModelScope.launch {
            // Stale-while-revalidate: paint cached channels immediately, then refresh in background.
            val cached = runCatching { currentRepository.readDiskCache(MediaKind.LIVE) }.getOrNull()
            if (generation != sourceGeneration) return@launch
            val showedCache = cached != null && cached.section.entries.isNotEmpty()
            if (cached != null && cached.section.entries.isNotEmpty()) {
                _state.update {
                    it.copy(
                        catalogLoading = false,
                        sections = it.sections + (MediaKind.LIVE to cached.section),
                        catalogError = null,
                    )
                }
                recomputeVisible()
            }
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    currentRepository.authenticate()
                    currentRepository.load(MediaKind.LIVE, force = showedCache)
                }
            }
            if (generation != sourceGeneration) return@launch
            result.onSuccess { section ->
                _state.update {
                    it.copy(
                        catalogLoading = false,
                        sections = it.sections + (MediaKind.LIVE to section),
                        catalogError = null,
                        maxConnections = currentRepository.maxConnections,
                    )
                }
                recomputeVisible()
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _state.update {
                    it.copy(
                        catalogLoading = false,
                        catalogError = if (showedCache) null else safeMessage(error),
                    )
                }
            }
        }
    }

    private fun loadCatalog(kind: MediaKind, force: Boolean = false) {
        val source = _state.value.activeSource ?: return
        val selectedRepository = repository ?: newRepository(source).also { repository = it }
        if (!force && kind in _state.value.sections) {
            recomputeVisible()
            return
        }
        val generation = sourceGeneration
        catalogJob?.cancel()
        _state.update { it.copy(catalogLoading = true, catalogError = null) }
        catalogJob = viewModelScope.launch {
            var showedCache = false
            if (!force) {
                val cached = runCatching { selectedRepository.readDiskCache(kind) }.getOrNull()
                if (generation != sourceGeneration || _state.value.destination.browseKindOrNull(_state.value.libraryKind) != kind) return@launch
                if (cached != null && cached.section.entries.isNotEmpty()) {
                    showedCache = true
                    _state.update {
                        it.copy(
                            catalogLoading = false,
                            sections = it.sections + (kind to cached.section),
                            catalogError = null,
                        )
                    }
                    recomputeVisible()
                    if (!cached.isStale) return@launch
                }
            }
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    selectedRepository.load(kind, force = force || showedCache)
                }
            }
            if (generation != sourceGeneration || _state.value.destination.browseKindOrNull(_state.value.libraryKind) != kind) return@launch
            result.onSuccess { section ->
                _state.update { it.copy(catalogLoading = false, sections = it.sections + (kind to section), catalogError = null) }
                recomputeVisible()
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _state.update {
                    it.copy(
                        catalogLoading = false,
                        catalogError = if (showedCache) null else safeMessage(error),
                    )
                }
            }
        }
    }

    private fun recomputeVisible(
        request: Long = filterGeneration.incrementAndGet(),
        cancelDebounce: Boolean = true,
    ) {
        if (cancelDebounce) searchDebounceJob?.cancel()
        searchJob?.cancel()
        val snapshot = _state.value
        val destination = snapshot.destination
        val section = snapshot.activeSection
        val favoriteIds = snapshot.library.favoriteIds
        val recentIds = snapshot.library.recentIds
        val query = snapshot.searchText.trim().lowercase(Locale.ROOT)
        val categoryId = snapshot.selectedCategoryId
        val quality = snapshot.qualityFilter
        val onlyFavorites = snapshot.onlyFavorites

        // Fast-path O(1) slice when no search/quality/favorites filters are active.
        if (destination !in setOf(BruTvDestination.FAVORITES, BruTvDestination.RECENTS) &&
            query.isBlank() &&
            quality == null &&
            !onlyFavorites
        ) {
            val direct = if (categoryId == null) section.entries else section.entriesByCategory[categoryId].orEmpty()
            _state.update { it.copy(visibleEntries = direct) }
            return
        }

        searchJob = viewModelScope.launch(Dispatchers.Default) {
            val baseEntries: List<MediaEntry> = when (destination) {
                BruTvDestination.FAVORITES -> {
                    val sourceList = if (categoryId != null) section.entriesByCategory[categoryId].orEmpty() else section.entries
                    sourceList.filter { it.id in favoriteIds }
                }
                BruTvDestination.RECENTS -> {
                    // O(R) lookup via precomputed entriesById instead of O(N) HashMap rebuild.
                    recentIds.mapNotNull(section.entriesById::get)
                }
                else -> if (categoryId != null) section.entriesByCategory[categoryId].orEmpty() else section.entries
            }
            val result = if (query.isBlank() && quality == null && !onlyFavorites && (destination != BruTvDestination.RECENTS || categoryId == null)) {
                baseEntries
            } else {
                val filtered = ArrayList<MediaEntry>(minOf(baseEntries.size, 256))
                for (entry in baseEntries) {
                    if (categoryId != null && entry.categoryId != categoryId) continue
                    if (query.isNotEmpty() && !entry.searchableName.contains(query)) continue
                    if (quality != null && entry.quality != quality) continue
                    if (onlyFavorites && entry.id !in favoriteIds) continue
                    filtered.add(entry)
                }
                filtered
            }
            withContext(Dispatchers.Main.immediate) {
                if (request == filterGeneration.get()) _state.update { it.copy(visibleEntries = result) }
            }
        }
    }

    private fun recordRecent(entry: MediaEntry) {
        val old = _state.value.library
        val recent = (listOf(entry.id) + old.recentIds.filterNot { it == entry.id }).take(100)
        updateLibrary(old.copy(recentIds = recent))
    }

    private fun updateResumePosition(
        entry: MediaEntry,
        positionMs: Long,
        durationMs: Long,
        completed: Boolean,
        force: Boolean,
    ) {
        if (entry.kind == MediaKind.LIVE) return
        val currentMap = _state.value.library.resumePositions
        val clamped = positionMs.coerceAtLeast(0L)
        val previous = currentMap[entry.id]
        val isCompletion = completed || (durationMs > 0L && clamped * 100L >= durationMs * 95L)
        if (!isCompletion) {
            if (previous == clamped) return
            if (!force && previous != null && abs(clamped - previous) < RESUME_PERSIST_MIN_DELTA_MS) return
        } else if (previous == null) {
            return
        }
        val nextPositions = updateResumePositions(
            existing = currentMap,
            entryId = entry.id,
            positionMs = clamped,
            durationMs = durationMs,
            completed = completed,
        )
        if (nextPositions === currentMap) return
        updateLibrary(_state.value.library.copy(resumePositions = nextPositions))
    }

    private fun updateLibrary(library: LibraryState) {
        val sourceId = _state.value.activeSourceId ?: return
        savedState = savedState.copy(libraries = savedState.libraries + (sourceId to library))
        _state.update { it.copy(library = library) }
        persist(writeCredentials = false)
    }

    private fun persist(writeCredentials: Boolean) {
        savedState = savedState.copy(
            profiles = _state.value.profiles,
            activeSourceId = _state.value.activeSourceId,
            bufferProfile = _state.value.bufferProfile,
            showStats = _state.value.showStats,
            language = _state.value.language,
            liveRewind = _state.value.liveRewind,
            preferredAudioLanguage = _state.value.preferredAudioLanguage,
            preferredSubtitleLanguage = _state.value.preferredSubtitleLanguage,
            subtitlesEnabled = _state.value.subtitlesEnabled,
            defaultAspectMode = _state.value.defaultAspectMode,
            autoFrameRate = _state.value.autoFrameRate,
        )
        if (!storeReady) {
            if (writeCredentials) {
                _state.update {
                    it.copy(
                        saving = false,
                        persistenceError = "Saved profiles could not be read. BruTV has kept the encrypted file unchanged; profile changes in this session cannot be saved.",
                        persistenceRetryable = false,
                    )
                }
            }
            return
        }
        if (writeCredentials) {
            credentialsDirty.set(true)
        }
        val request = PersistenceRequest(
            revision = ++persistenceRevision,
            state = savedState,
            localPlaylistDeleteUrls = pendingLocalPlaylistDeletes.toSet(),
            showSavingIndicator = writeCredentials,
        )
        latestPersistenceRequest = request
        if (writeCredentials) {
            _state.update { it.copy(saving = true, persistenceError = null, persistenceRetryable = false) }
        }
        persistenceQueue.trySend(request)
    }

    private fun cancelConnect() {
        if (connectJob?.isActive == true) {
            sourceGeneration++
            connectJob?.cancel()
            connectingLocalSource?.let(::deleteImportedPlaylist)
        }
        connectingLocalSource = null
        connectJob = null
    }

    private fun cancelPlaylistImport() {
        if (playlistImportJob?.isActive == true) {
            playlistImportGeneration++
            playlistImportJob?.cancel()
            _state.update { it.copy(busy = false) }
        }
        playlistImportJob = null
    }

    private fun deleteImportedPlaylist(source: SourceConfig) {
        if (source.type == SourceType.M3U && source.playlistUrl.startsWith("file:")) {
            val url = source.playlistUrl
            viewModelScope.launch(Dispatchers.IO) {
                deletePrivatePlaylistCopy(url)
            }
        }
    }

    private fun deletePrivatePlaylistCopy(uriString: String): Boolean = runCatching {
        val uri = java.net.URI(uriString)
        if (uri.scheme != "file" || uri.rawAuthority != null || uri.rawQuery != null || uri.rawFragment != null) return@runCatching false
        val playlistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists").canonicalFile
        val candidate = File(uri).canonicalFile
        val uuidName = candidate.name.removeSuffix(".m3u")
        if (candidate.parentFile != playlistDirectory || !candidate.name.endsWith(".m3u") ||
            !UUID_PATTERN.matches(uuidName) || runCatching { UUID.fromString(uuidName) }.isFailure
        ) {
            return@runCatching false
        }
        !candidate.exists() || candidate.delete()
    }.getOrDefault(false)

    private fun safeMessage(error: Throwable): String = sanitizeUserErrorMessage(error)

    override fun onCleared() {
        playlistImportGeneration++
        playlistImportJob?.cancel()
        searchDebounceJob?.cancel()
        searchJob?.cancel()
        xmltvJob?.cancel()
        cancelConnect()
        hoistedPlaybackController?.release()
        hoistedPlaybackController = null
        persistenceQueue.close()
        super.onCleared()
    }

    companion object {
        internal const val RESUME_PERSIST_MIN_DELTA_MS = 10_000L
        private val UUID_PATTERN = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
    }
}

private val SENSITIVE_CREDENTIAL_PATTERN =
    Regex("""(?:\b(?:username|password|pass|token|secret|auth)\s*=|://)""", RegexOption.IGNORE_CASE)

private val HOST_LEAK_PATTERN =
    Regex("""(?:resolve host|failed to connect to|unable to resolve)""", RegexOption.IGNORE_CASE)

internal fun sanitizeUserErrorMessage(error: Throwable): String {
    val fallback = when (error) {
        is IllegalArgumentException -> "Check the sign-in details and try again."
        else -> "BruTV could not reach this provider. Check the connection and try again."
    }
    val raw = error.message?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
    if (SENSITIVE_CREDENTIAL_PATTERN.containsMatchIn(raw) || HOST_LEAK_PATTERN.containsMatchIn(raw)) {
        return fallback
    }
    return raw.take(160)
}

private fun SourceConfig.toDraft() = LoginDraft(
    name = name,
    type = type,
    server = server,
    username = username,
    password = password,
    playlistUrl = playlistUrl,
)

private fun LibraryState?.orEmptyLibrary() = this ?: LibraryState()
private fun BruTvDestination.toMediaKindOrNull(): MediaKind? = when (this) {
    BruTvDestination.LIVE -> MediaKind.LIVE
    BruTvDestination.MOVIES -> MediaKind.MOVIE
    BruTvDestination.SERIES -> MediaKind.SERIES
    else -> null
}
private fun BruTvDestination.isLibrary(): Boolean = this == BruTvDestination.FAVORITES || this == BruTvDestination.RECENTS
private fun BruTvDestination.browseKind(libraryKind: MediaKind): MediaKind = toMediaKindOrNull() ?: if (isLibrary()) libraryKind else MediaKind.LIVE
private fun BruTvDestination.browseKindOrNull(libraryKind: MediaKind): MediaKind? = toMediaKindOrNull() ?: if (isLibrary()) libraryKind else null
