package com.bvolpato.brutv.ui

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bvolpato.brutv.data.CatalogRepository
import com.bvolpato.brutv.data.CatalogSection
import com.bvolpato.brutv.data.LibraryState
import com.bvolpato.brutv.data.M3UPlaylistParser
import com.bvolpato.brutv.data.LoginLinks
import com.bvolpato.brutv.data.MediaEntry
import com.bvolpato.brutv.data.MediaKind
import com.bvolpato.brutv.data.Programme
import com.bvolpato.brutv.data.ProfileStore
import com.bvolpato.brutv.data.SavedState
import com.bvolpato.brutv.data.SourceConfig
import com.bvolpato.brutv.data.SourceType
import com.bvolpato.brutv.signin.Pairing
import com.bvolpato.brutv.signin.PairingInvite
import java.util.concurrent.atomic.AtomicLong
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay

enum class BruTvDestination { LIVE, MOVIES, SERIES, FAVORITES, RECENTS, SETTINGS, PROFILES }
enum class BruTvPage { HOME, SIGN_IN, DETAIL, SCAN_QR, TV_PAIRING, LOGIN_QR }

data class LoginDraft(
    val name: String = "",
    val type: SourceType = SourceType.XTREAM,
    val server: String = "",
    val username: String = "",
    val password: String = "",
    val playlistUrl: String = "",
)

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
    val episodes: List<MediaEntry> = emptyList(),
    val programmes: List<Programme> = emptyList(),
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
    val library: LibraryState = LibraryState(),
) {
    val activeSource: SourceConfig? get() = profiles.firstOrNull { it.id == activeSourceId }
    val activeSection: CatalogSection get() = sections[destination.browseKind(libraryKind)] ?: CatalogSection()
}

private data class PersistenceRequest(
    val revision: Long,
    val state: SavedState,
    val localPlaylistDeleteUrls: Set<String>,
)

/** Owns profile persistence, source switching and demand-loaded catalog state for the UI. */
class BruTvViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val _state = MutableStateFlow(BruTvUiState())
    val state = _state.asStateFlow()

    private var savedState = SavedState()
    private var storeReady = false
    private var persistenceRevision = 0L
    private var latestPersistenceRequest: PersistenceRequest? = null
    private val pendingLocalPlaylistDeletes = mutableSetOf<String>()
    private var connectJob: Job? = null
    private var connectingLocalSource: SourceConfig? = null
    private var playlistImportJob: Job? = null
    private var playlistImportGeneration = 0L
    private var repository: CatalogRepository? = null
    private var linkBeforeRestore: String? = null
    private var catalogJob: Job? = null
    private var detailJob: Job? = null
    private var searchJob: Job? = null
    private var pageBeforeOverlay = BruTvPage.HOME
    private var sourceGeneration = 0L
    private val persistenceQueue = Channel<PersistenceRequest>(Channel.CONFLATED)
    private val filterGeneration = AtomicLong()

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
                val writeFailure = runCatching { store.write(request.state) }.exceptionOrNull()
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
                                    writeFailure != null -> "Profile changes could not be saved. Your current session is still available."
                                    failedDeletes.isNotEmpty() -> "Profile changes were saved, but an imported playlist copy could not be deleted. Retry cleanup."
                                    else -> null
                                },
                                persistenceRetryable = writeFailure != null || failedDeletes.isNotEmpty(),
                            )
                        }
                    }
                }
            }
        }
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
            BruTvPage.DETAIL -> _state.update { it.copy(page = BruTvPage.HOME, selectedEntry = null, episodes = emptyList(), programmes = emptyList()) }
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
        kind?.let(::loadCatalog)
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
        searchJob?.cancel()
        val request = filterGeneration.incrementAndGet()
        searchJob = viewModelScope.launch {
            delay(120)
            recomputeVisible(request)
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
        _state.update { it.copy(busy = true, pageError = null, catalogError = null) }
        connectJob = viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    CatalogRepository(
                        normalized,
                        localPlaylistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists"),
                    ).also { it.authenticate() }
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
                        library = savedState.libraries[normalized.id].orEmptyLibrary(),
                    )
                }
                persist()
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
        persist()
        if (activeId == null) {
            sourceGeneration++
            catalogJob?.cancel()
            repository = null
            _state.update { it.copy(sections = emptyMap(), visibleEntries = emptyList(), library = LibraryState(), destination = BruTvDestination.LIVE) }
        } else if (activeId != current.activeSourceId) {
            profiles.firstOrNull { it.id == activeId }?.let { activate(it, persist = false) }
        }
    }

    fun openEntry(entry: MediaEntry) {
        detailJob?.cancel()
        _state.update { it.copy(page = BruTvPage.DETAIL, selectedEntry = entry, episodes = emptyList(), programmes = emptyList(), pageError = null) }
        when (entry.kind) {
            MediaKind.SERIES -> detailJob = viewModelScope.launch {
                val selectedRepository = repository ?: return@launch
                val generation = sourceGeneration
                _state.update { it.copy(busy = true) }
                val result = runCatching { withContext(Dispatchers.IO) { selectedRepository.episodes(entry) } }
                if (generation != sourceGeneration || _state.value.selectedEntry?.id != entry.id) return@launch
                _state.update { it.copy(busy = false, episodes = result.getOrDefault(emptyList()), pageError = result.exceptionOrNull()?.let(::safeMessage)) }
            }
            MediaKind.LIVE -> detailJob = viewModelScope.launch {
                val selectedRepository = repository ?: return@launch
                val generation = sourceGeneration
                val result = runCatching { withContext(Dispatchers.IO) { selectedRepository.guide(entry) } }
                if (generation == sourceGeneration && _state.value.selectedEntry?.id == entry.id) {
                    _state.update { it.copy(programmes = result.getOrDefault(emptyList())) }
                }
            }
            else -> Unit
        }
    }

    fun play(entry: MediaEntry) {
        if (entry.streamUrl.isBlank()) {
            _state.update { it.copy(pageError = "This item does not have a playable stream.") }
            return
        }
        recordRecent(entry)
        val queue = if (entry.kind == MediaKind.EPISODE) _state.value.episodes.filter { it.streamUrl.isNotBlank() }
        else _state.value.visibleEntries.filter { it.streamUrl.isNotBlank() }
        _state.update { it.copy(playingEntry = entry, playQueue = if (entry in queue) queue else listOf(entry), pageError = null) }
    }

    fun closePlayer(positionMs: Long) {
        _state.value.playingEntry?.let { updateResumePosition(it, positionMs) }
        _state.update { it.copy(playingEntry = null) }
    }

    fun onPlayerItemChanged(entry: MediaEntry) {
        recordRecent(entry)
        _state.update { it.copy(playingEntry = entry) }
    }

    fun savePosition(entry: MediaEntry, positionMs: Long) = updateResumePosition(entry, positionMs)

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
        persist()
    }

    fun setShowStats(enabled: Boolean) {
        savedState = savedState.copy(showStats = enabled)
        _state.update { it.copy(showStats = enabled) }
        persist()
    }

    fun retryPersistence() {
        if (!storeReady) return
        val latest = latestPersistenceRequest ?: return
        val next = latest.copy(revision = ++persistenceRevision)
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

    private fun activate(source: SourceConfig, persist: Boolean) {
        cancelPlaylistImport()
        connectJob?.cancel()
        connectJob = null
        sourceGeneration++
        val generation = sourceGeneration
        catalogJob?.cancel()
        detailJob?.cancel()
        repository = CatalogRepository(
            source,
            localPlaylistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists"),
        )
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
                episodes = emptyList(),
                programmes = emptyList(),
                library = library,
                catalogLoading = true,
                catalogError = null,
            )
        }
        if (persist) persist()
        catalogJob = viewModelScope.launch {
            val currentRepository = repository ?: return@launch
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    currentRepository.authenticate()
                    currentRepository.load(MediaKind.LIVE)
                }
            }
            if (generation != sourceGeneration) return@launch
            result.onSuccess { section ->
                _state.update { it.copy(catalogLoading = false, sections = it.sections + (MediaKind.LIVE to section), catalogError = null) }
                recomputeVisible()
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _state.update { it.copy(catalogLoading = false, catalogError = safeMessage(error)) }
            }
        }
    }

    private fun loadCatalog(kind: MediaKind, force: Boolean = false) {
        val source = _state.value.activeSource ?: return
        val selectedRepository = repository ?: CatalogRepository(
            source,
            localPlaylistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists"),
        ).also { repository = it }
        if (!force && kind in _state.value.sections) {
            recomputeVisible()
            return
        }
        val generation = sourceGeneration
        catalogJob?.cancel()
        _state.update { it.copy(catalogLoading = true, catalogError = null) }
        catalogJob = viewModelScope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { selectedRepository.load(kind) } }
            if (generation != sourceGeneration || _state.value.destination.browseKindOrNull(_state.value.libraryKind) != kind) return@launch
            result.onSuccess { section ->
                _state.update { it.copy(catalogLoading = false, sections = it.sections + (kind to section), catalogError = null) }
                recomputeVisible()
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                _state.update { it.copy(catalogLoading = false, catalogError = safeMessage(error)) }
            }
        }
    }

    private fun recomputeVisible(request: Long = filterGeneration.incrementAndGet()) {
        val snapshot = _state.value
        val entries = when (snapshot.destination) {
            BruTvDestination.FAVORITES -> snapshot.activeSection.entries.filter { it.id in snapshot.library.favoriteIds }
            BruTvDestination.RECENTS -> snapshot.activeSection.entries.associateBy { it.id }
                .let { index -> snapshot.library.recentIds.mapNotNull(index::get) }
            else -> snapshot.activeSection.entries
        }
        val categories = if (snapshot.destination == BruTvDestination.FAVORITES || snapshot.destination == BruTvDestination.RECENTS) {
            emptyList()
        } else snapshot.activeSection.categories
        val query = snapshot.searchText.trim().lowercase()
        val categoryId = snapshot.selectedCategoryId
        val quality = snapshot.qualityFilter
        val favorites = snapshot.library.favoriteIds
        val onlyFavorites = snapshot.onlyFavorites
        val filtered = viewModelScope.launch(Dispatchers.Default) {
            val result = entries.asSequence()
                .filter { categoryId == null || it.categoryId == categoryId }
                .filter { query.isBlank() || it.searchableName.contains(query) }
                .filter { quality == null || it.quality == quality }
                .filter { !onlyFavorites || it.id in favorites }
                .toList()
            withContext(Dispatchers.Main.immediate) {
                if (request == filterGeneration.get()) _state.update { it.copy(visibleEntries = result) }
            }
        }
        searchJob = filtered
    }

    private fun recordRecent(entry: MediaEntry) {
        val old = _state.value.library
        val recent = (listOf(entry.id) + old.recentIds.filterNot { it == entry.id }).take(100)
        updateLibrary(old.copy(recentIds = recent))
    }

    private fun updateResumePosition(entry: MediaEntry, positionMs: Long) {
        if (entry.kind == MediaKind.LIVE) return
        val updated = _state.value.library.copy(resumePositions = _state.value.library.resumePositions + (entry.id to positionMs.coerceAtLeast(0)))
        updateLibrary(updated)
    }

    private fun updateLibrary(library: LibraryState) {
        val sourceId = _state.value.activeSourceId ?: return
        savedState = savedState.copy(libraries = savedState.libraries + (sourceId to library))
        _state.update { it.copy(library = library) }
        persist()
    }

    private fun persist() {
        savedState = savedState.copy(
            profiles = _state.value.profiles,
            activeSourceId = _state.value.activeSourceId,
            bufferProfile = _state.value.bufferProfile,
            showStats = _state.value.showStats,
        )
        if (!storeReady) {
            _state.update {
                it.copy(
                    saving = false,
                    persistenceError = "Saved profiles could not be read. BruTV has kept the encrypted file unchanged; profile changes in this session cannot be saved.",
                    persistenceRetryable = false,
                )
            }
            return
        }
        val request = PersistenceRequest(++persistenceRevision, savedState, pendingLocalPlaylistDeletes.toSet())
        latestPersistenceRequest = request
        _state.update { it.copy(saving = true, persistenceError = null, persistenceRetryable = false) }
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
            deletePrivatePlaylistCopy(source.playlistUrl)
        }
    }

    private fun deletePrivatePlaylistCopy(uriString: String): Boolean = runCatching {
        val uri = java.net.URI(uriString)
        if (uri.scheme != "file" || uri.rawAuthority != null || uri.rawQuery != null || uri.rawFragment != null) return@runCatching false
        val playlistDirectory = File(getApplication<Application>().noBackupFilesDir, "playlists").canonicalFile
        val candidate = File(uri).canonicalFile
        val uuidName = candidate.name.removeSuffix(".m3u")
        val uuidPattern = Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
        if (candidate.parentFile != playlistDirectory || !candidate.name.endsWith(".m3u") ||
            !uuidPattern.matches(uuidName) || runCatching { UUID.fromString(uuidName) }.isFailure
        ) {
            return@runCatching false
        }
        !candidate.exists() || candidate.delete()
    }.getOrDefault(false)

    private fun safeMessage(error: Throwable): String = when (error) {
        is IllegalArgumentException -> error.message ?: "Check the sign-in details and try again."
        else -> error.message?.takeIf { it.isNotBlank() && !it.contains("http", ignoreCase = true) }
            ?.take(160) ?: "BruTV could not reach this provider. Check the connection and try again."
    }

    override fun onCleared() {
        playlistImportGeneration++
        playlistImportJob?.cancel()
        cancelConnect()
        persistenceQueue.close()
        super.onCleared()
    }
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
private fun SavedState.librariesFor(sourceId: String?): LibraryState = sourceId?.let { libraries[it] }.orEmptyLibrary()
private fun BruTvDestination.toMediaKindOrNull(): MediaKind? = when (this) {
    BruTvDestination.LIVE -> MediaKind.LIVE
    BruTvDestination.MOVIES -> MediaKind.MOVIE
    BruTvDestination.SERIES -> MediaKind.SERIES
    else -> null
}
private fun BruTvDestination.toMediaKind(): MediaKind = toMediaKindOrNull() ?: MediaKind.LIVE
private fun BruTvDestination.isLibrary(): Boolean = this == BruTvDestination.FAVORITES || this == BruTvDestination.RECENTS
private fun BruTvDestination.browseKind(libraryKind: MediaKind): MediaKind = toMediaKindOrNull() ?: if (isLibrary()) libraryKind else MediaKind.LIVE
private fun BruTvDestination.browseKindOrNull(libraryKind: MediaKind): MediaKind? = toMediaKindOrNull() ?: if (isLibrary()) libraryKind else null
