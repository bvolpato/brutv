import Foundation
import AVFoundation
import AVKit
import Combine
import MediaPlayer
#if canImport(Network)
import Network
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(Network)
private final class WeakLiveServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _server: LiveTimeshiftServer?

    var server: LiveTimeshiftServer? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _server
        }
        set {
            lock.lock()
            _server = newValue
            lock.unlock()
        }
    }
}
#endif

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case failed(String)

    /// A short name that UI tests read from the video view.
    public var testDescription: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering: return "buffering"
        case .failed: return "failed"
        }
    }
}

public struct MediaTrackOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let language: String?
    public let isSelected: Bool

    public init(id: String, displayName: String, language: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.isSelected = isSelected
    }
}

/// High-frequency playhead and timeshift timeline state, isolated from `PlaybackManager`
/// so root views (`PlayerView`, `SettingsView`, `MainContentView`) do not re-render at 1 Hz.
@MainActor
public final class PlaybackClockModel: ObservableObject {
    @Published public var vodCurrentTime: Double = 0
    @Published public var vodDuration: Double = 0
    @Published var liveBuffer = LiveTimeshiftSnapshot()
    @Published public var liveBehindSeconds: Double = 0
    @Published public var liveSeekStart: Double = 0
    @Published public var liveSeekEnd: Double = 0
    @Published public var livePlayhead: Double = 0
    @Published public var canSeekLive: Bool = false
    @Published public var shouldShowGoLive: Bool = false
}

/// High-frequency stream telemetry isolated so only visible HUD/buffer bars re-render at 1 Hz.
@MainActor
public final class PlaybackTelemetryModel: ObservableObject {
    @Published public var telemetry: StreamTelemetry = StreamTelemetry()
}

@MainActor
public final class PlaybackManager: ObservableObject {
    public static let shared = PlaybackManager()
    private static var hasCleanedLiveBuffers = false
    private nonisolated static let audioSessionQueue = DispatchQueue(label: "com.bvolpato.brutv.audio-session")

    public let clock = PlaybackClockModel()
    public let telemetryModel = PlaybackTelemetryModel()

    @Published public private(set) var player: AVPlayer
    @Published public private(set) var currentStream: LiveStream?
    @Published public private(set) var currentVOD: VODStream?
    @Published public private(set) var playbackState: PlaybackState = .idle {
        didSet {
            guard playbackState != oldValue else { return }
            let diagnostics = PlaybackDiagnosticsStore.shared
            switch playbackState {
            case .loading, .buffering:
                diagnostics.transition(to: isPlaybackRequested ? .waiting : .paused,
                                       kind: isPlaybackRequested ? diagnosticKind : nil)
            case .playing: diagnostics.transition(to: .playing, kind: diagnosticKind)
            case .paused: diagnostics.transition(to: .paused)
            case .idle: diagnostics.finish(outcome: .stopped)
            case .failed: diagnostics.finish(outcome: .failed)
            }
        }
    }
    @Published public private(set) var isPlaybackRequested = false {
        didSet { syncLiveSeekFlags() }
    }
    public var telemetry: StreamTelemetry {
        get { telemetryModel.telemetry }
        set {
            if telemetryModel.telemetry != newValue {
                telemetryModel.telemetry = newValue
            }
        }
    }

    private var diagnosticKind: PlaybackHealthSummary.Kind? {
        if currentStream != nil { return .live }
        if currentVOD != nil { return .video }
        return nil
    }
    @Published public var aspectRatio: VideoAspectRatio = .fit {
        didSet {
            guard aspectRatio != oldValue else { return }
            if settings.defaultAspectRatio != aspectRatio {
                settings.defaultAspectRatio = aspectRatio
            }
        }
    }
    @Published public var settings: PlayerSettings = PlayerSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            handleSettingsChanged(from: oldValue, to: settings)
        }
    }
    @Published public var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    public var vodCurrentTime: Double {
        get { clock.vodCurrentTime }
        set { clock.vodCurrentTime = newValue }
    }
    public var vodDuration: Double {
        get { clock.vodDuration }
        set { clock.vodDuration = newValue }
    }
    @Published public private(set) var availableAudioTracks: [MediaTrackOption] = []
    @Published public private(set) var selectedAudioTrackID: String?
    @Published public private(set) var availableSubtitles: [MediaTrackOption] = []
    @Published public private(set) var selectedSubtitleID: String?
    @Published public var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    var liveBuffer: LiveTimeshiftSnapshot {
        get { clock.liveBuffer }
        set {
            if clock.liveBuffer != newValue {
                clock.liveBuffer = newValue
            }
            syncLiveSeekFlags()
        }
    }
    @Published private(set) var liveBufferUnavailable: String?
    @Published public private(set) var isRecoveringLiveBuffer = false
    @Published public private(set) var activeFormatLabel: String = "HLS (.m3u8)"
    var liveBehindSeconds: Double {
        get { clock.liveBehindSeconds }
        set {
            clock.liveBehindSeconds = newValue
            syncLiveSeekFlags()
        }
    }
    var liveSeekStart: Double {
        get { clock.liveSeekStart }
        set {
            clock.liveSeekStart = newValue
            syncLiveSeekFlags()
        }
    }
    var liveSeekEnd: Double {
        get { clock.liveSeekEnd }
        set {
            clock.liveSeekEnd = newValue
            syncLiveSeekFlags()
        }
    }
    var livePlayhead: Double {
        get { clock.livePlayhead }
        set { clock.livePlayhead = newValue }
    }
    private var liveRecorder: LiveTimeshiftRecorder? {
        didSet { syncLiveSeekFlags() }
    }
    private var liveServer: LiveTimeshiftServer?
    private var liveCaptureTask: Task<Void, Never>?
    private var liveRecoveryTask: Task<Void, Never>?
    private var liveRecoveryBlockedForSession = false
    private var liveFallback: LiveTransportFallbackPolicy?
    private var liveTransportMemory = LiveTransportMemory()
    private var networkRecoveryPolicy = NetworkPathRecoveryPolicy()
    private var lastTerminalFailureWasNetwork = false
    private var confirmedHealthyForSession = false
    private var healthyProgressStartedAt: TimeInterval?
    #if canImport(Network)
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.bvolpato.brutv.network-path")
    #endif
    private var pendingTeardownTask: Task<Void, Never>?
    private var needsConnectionReleasePause = false
    private var pausedLivePosition: Double?
    private var pendingLiveRecordedPosition: Double?
    private var pendingLiveDate: Date?
    private var explicitlyRewound = false {
        didSet { syncLiveSeekFlags() }
    }
    private var liveJumpInProgress = false
    private var originalLiveURL: URL?
    private var codecFallback = LiveTimeshiftCodecFallback()
    private var progressWatchdog = PlaybackProgressWatchdog(isLive: true)
    private var resumeAfterAudioInterruption = false
    private var backgroundedWithLocalServer = false
    private var lastSavedProgressUptime: TimeInterval = 0

    var canSeekLive: Bool {
        guard currentStream != nil, settings.liveRewind else { return false }
        if liveRecorder != nil {
            return liveBuffer.canRewind && liveSeekEnd > liveSeekStart
        }
        return (liveSeekEnd - liveSeekStart) >= 1.5
    }
    var shouldShowGoLive: Bool { canSeekLive && (liveBehindSeconds > 15 || ((!isPlaybackRequested || explicitlyRewound) && liveBehindSeconds > 1)) }

    private func syncLiveSeekFlags() {
        let canSeek = canSeekLive
        if clock.canSeekLive != canSeek {
            clock.canSeekLive = canSeek
        }
        let showGoLive = shouldShowGoLive
        if clock.shouldShowGoLive != showGoLive {
            clock.shouldShowGoLive = showGoLive
        }
    }

    // Active playlist for fast zapping
    @Published public private(set) var activePlaylist: [LiveStream] = []
    @Published public private(set) var activeIndex: Int = 0
    @Published public private(set) var activeEpisodeList: [SeriesEpisode] = []
    @Published public private(set) var activeEpisodeIndex: Int = 0
    @Published public private(set) var activeSeriesName: String = ""

    private var itemObservers: Set<AnyCancellable> = []
    private var lifecycleObservers: Set<AnyCancellable> = []
    private var mediaTracksTask: Task<Void, Never>?
    private var audioSelectionGroup: AVMediaSelectionGroup?
    private var subtitleSelectionGroup: AVMediaSelectionGroup?
    private var audioOptionMap: [String: AVMediaSelectionOption] = [:]
    private var subtitleOptionMap: [String: AVMediaSelectionOption] = [:]
    private var appliedPreferredTracksForItem = false
    private var accountObserver: AnyCancellable?
    private var nowPlayingObserver: AnyCancellable?
    #if os(tvOS)
    private lazy var nowPlayingSession = MPNowPlayingSession(players: [player])
    private var nowPlayingActivationObserver: AnyCancellable?
    #endif
    private var telemetryTimer: Timer?
    private var stallCount: Int = 0
    private var recovery = PlaybackRecoveryPolicy(maxAttempts: nil, healthyInterval: 30, maxDelay: 15.0, jitterFactor: 0.2)
    private var quality = QualityStepDownPolicy()
    /// The provider URL of what is playing. With live rewind on, AVPlayer reads a local
    /// copy instead, so this is the URL to hand to another player app.
    @Published public private(set) var providerURL: URL?
    private var sessionGeneration: UInt64 = 0
    private var itemGeneration: UInt64 = 0
    private var currentPlaybackURL: URL?
    private var managedLocalPlaylistURL: URL?
    private var pendingResumePosition: Double?
    private var resumeSeekInProgress = false
    private var vodSeekGeneration: UInt64 = 0
    private var lastVODPosition: Double = 0
    private var currentFormat: StreamFormatPreference = .hls
    private var watchdogWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var watchdogGeneration: UInt64 = 0
    private var retryGeneration: UInt64 = 0

    public init() {
        self.player = AVPlayer()
        self.player.automaticallyWaitsToMinimizeStalling = true
        self.aspectRatio = settings.defaultAspectRatio
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-fixtures") && arguments.contains("--ui-disable-live-rewind") {
            var fixtureSettings = settings
            fixtureSettings.liveRewind = false
            // Keep the fixture override out of persisted player preferences.
            _settings = Published(wrappedValue: fixtureSettings)
        }
        #endif
        if !Self.hasCleanedLiveBuffers {
            Self.hasCleanedLiveBuffers = true
            Task.detached(priority: .utility) {
                LiveTimeshiftRecorder.removeStaleSessions()
            }
        }
        setupAudioSession()
        setupNowPlaying()
        setupLifecycleObservers()
        #if canImport(Network)
        setupNetworkPathMonitor()
        #endif
        accountObserver = AccountStore.shared.$currentProfile
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.liveTransportMemory.removeAll()
                self?.stop()
            }
    }

    deinit {
        #if canImport(Network)
        pathMonitor.cancel()
        #endif
    }

    #if canImport(Network)
    private func setupNetworkPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            var mask = 0
            if path.usesInterfaceType(.wifi) { mask |= 1 << 0 }
            if path.usesInterfaceType(.cellular) { mask |= 1 << 1 }
            if path.usesInterfaceType(.wiredEthernet) { mask |= 1 << 2 }
            if path.usesInterfaceType(.other) { mask |= 1 << 3 }
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(isSatisfied: isSatisfied, interfaceMask: mask)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }
    #endif

    private func handleNetworkPathUpdate(isSatisfied: Bool, interfaceMask: Int) {
        let signature = NetworkPathSignature(isSatisfied: isSatisfied, interfaceMask: interfaceMask)
        guard networkRecoveryPolicy.recordPath(signature, at: ProcessInfo.processInfo.systemUptime) else {
            return
        }
        guard currentStream != nil || currentVOD != nil else { return }
        if retryWorkItem != nil {
            relayLog.info("network path recovered during retry backoff; retrying immediately")
            retryCurrentPlayback()
        } else if case .failed = playbackState, lastTerminalFailureWasNetwork {
            relayLog.info("network path recovered after network failure; retrying playback")
            retryCurrentPlayback()
        } else if isPlaybackRequested, currentStream != nil,
                  player.timeControlStatus != .playing
                      || (liveFallback?.currentMode == .tsRelay && !progressWatchdog.isProgressing) {
            relayLog.info("network path changed while live playback was not progressing; reconnecting")
            retryCurrentPlayback()
        }
    }

    private func setupAudioSession() {
        Self.audioSessionQueue.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true)
            } catch {
                print("Failed to configure the playback audio session.")
            }
        }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &lifecycleObservers)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionRouteChange(notification)
            }
            .store(in: &lifecycleObservers)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMediaServicesReset()
            }
            .store(in: &lifecycleObservers)

        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
            .store(in: &lifecycleObservers)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
            .store(in: &lifecycleObservers)
        #endif
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            let wasPlaying = isPlaybackRequested && (currentStream != nil || currentVOD != nil)
            resumeAfterAudioInterruption = wasPlaying
            if wasPlaying {
                pausePlaybackIntent()
                player.pause()
            }
        case .ended:
            setupAudioSession()
            let shouldAutoResume = resumeAfterAudioInterruption
            resumeAfterAudioInterruption = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldAutoResume, options.contains(.shouldResume),
               !isPlaybackRequested, currentStream != nil || currentVOD != nil {
                togglePlayPause()
            }
        @unknown default:
            break
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        if reason == .oldDeviceUnavailable {
            resumeAfterAudioInterruption = false
            if isPlaybackRequested {
                pausePlaybackIntent()
                player.pause()
            }
        }
    }

    private func handleMediaServicesReset() {
        setupAudioSession()
        if isPlaybackRequested, currentStream != nil || currentVOD != nil {
            retryCurrentPlayback()
        }
    }

    private var isPlayingManagedLocalPlaylist: Bool {
        currentPlaybackURL != nil && currentPlaybackURL == managedLocalPlaylistURL
    }

    private func handleAppDidEnterBackground() {
        if liveServer != nil || isPlayingManagedLocalPlaylist {
            backgroundedWithLocalServer = true
        }
    }

    private func handleAppWillEnterForeground() {
        let wasLocal = backgroundedWithLocalServer
        backgroundedWithLocalServer = false
        if isPlaybackRequested {
            setupAudioSession()
        }
        guard wasLocal, currentStream != nil else { return }
        let serverAlive = liveServer?.isRunning ?? false
        let needsRestart = !serverAlive || liveRecorder == nil
            || (isPlaybackRequested && (player.currentItem?.status == .failed || player.timeControlStatus != .playing))
        if isPlaybackRequested && needsRestart {
            retryCurrentPlayback()
        } else if !serverAlive || liveRecorder == nil {
            stopLiveBuffer()
            player.replaceCurrentItem(with: nil)
            currentPlaybackURL = nil
        }
    }

    /// Shows the channel or title on the Lock Screen and in Control Center, and
    /// handles the play, pause, and next or previous channel commands there.
    private func setupNowPlaying() {
        #if os(tvOS)
        let center = nowPlayingSession.remoteCommandCenter
        let info = nowPlayingSession.nowPlayingInfoCenter
        nowPlayingActivationObserver = Publishers.CombineLatest(
            $isPlaybackRequested.removeDuplicates(),
            nowPlayingSession.publisher(for: \.canBecomeActive, options: [.initial, .new]).removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing, canBecomeActive in
                guard let self, playing, canBecomeActive, self.isPlaybackRequested else { return }
                self.nowPlayingSession.becomeActiveIfPossible(completion: nil)
            }
        #else
        let center = MPRemoteCommandCenter.shared()
        let info = MPNowPlayingInfoCenter.default()
        #endif
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentStream != nil || self.currentVOD != nil else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.currentStream != nil || self.currentVOD != nil else { return .noActionableNowPlayingItem }
            if !self.isPlaybackRequested { self.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentStream != nil || self.currentVOD != nil else { return .noActionableNowPlayingItem }
            if self.isPlaybackRequested { self.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentStream != nil, !self.activePlaylist.isEmpty else { return .noActionableNowPlayingItem }
            self.nextChannel()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentStream != nil, !self.activePlaylist.isEmpty else { return .noActionableNowPlayingItem }
            self.previousChannel()
            return .success
        }

        nowPlayingObserver = Publishers.CombineLatest3($currentStream, $currentVOD, $isPlaybackRequested)
            .receive(on: DispatchQueue.main)
            .sink { stream, vod, playing in
                guard let title = stream?.name ?? vod?.name else {
                    info.nowPlayingInfo = nil
                    info.playbackState = .stopped
                    return
                }
                info.nowPlayingInfo = [
                    MPMediaItemPropertyTitle: title,
                    MPMediaItemPropertyArtist: "BruTV",
                    MPNowPlayingInfoPropertyIsLiveStream: stream != nil,
                    MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
                ]
                info.playbackState = playing ? .playing : .paused
            }
    }

    private func setupPlayerObservers(for item: AVPlayerItem, session: UInt64, generation: UInt64) {
        Publishers.Merge(
            player.publisher(for: \.timeControlStatus, options: [.new]).map { _ in () },
            player.publisher(for: \.rate, options: [.new]).map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.isCurrent(item, session: session, generation: generation) else { return }
                self.synchronizeTransport(for: item, session: session, generation: generation,
                                          recognizesPauseRequest: self.resumeSeekInProgress)
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: AVPlayer.rateDidChangeNotification, object: player)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] notification in
                guard let self, let item, self.isCurrent(item, session: session, generation: generation) else { return }
                let reason = notification.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String
                let requestedPause = reason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue
                    || reason == AVPlayer.RateDidChangeReason.audioSessionInterrupted.rawValue
                    || reason == AVPlayer.RateDidChangeReason.appBackgrounded.rawValue
                self.synchronizeTransport(for: item, session: session, generation: generation,
                                          recognizesPauseRequest: requestedPause)
            }
            .store(in: &itemObservers)
    }

    private func synchronizeTransport(for item: AVPlayerItem, session: UInt64, generation: UInt64,
                                      recognizesPauseRequest: Bool = false) {
        let status = player.timeControlStatus
        let requestsPlayback = player.rate != 0 || status != .paused
        if !requestsPlayback {
            guard retryWorkItem == nil else { return }
            if item.status == .failed, isPlaybackRequested {
                handlePlaybackFailure(classifyPlaybackFailure(item.error, item: item),
                                      item: item, session: session, generation: generation)
                return
            }
            // End/failure can change the rate before its notification. Outside a restore seek,
            // preserve recovery intent until a rate-change reason identifies a pause.
            guard recognizesPauseRequest else {
                if isPlaybackRequested {
                    recovery.recordInterruption()
                    healthyProgressStartedAt = nil
                    playbackState = item.status == .readyToPlay ? .buffering : .loading
                    startWatchdog(for: item, session: session, generation: generation)
                }
                return
            }
            pausePlaybackIntent()
            return
        }

        if item.status == .failed, isPlaybackRequested, retryWorkItem == nil {
            handlePlaybackFailure(classifyPlaybackFailure(item.error, item: item),
                                  item: item, session: session, generation: generation)
            return
        }
        if retryWorkItem != nil || item.status == .failed {
            retryCurrentPlayback()
            return
        }
        isPlaybackRequested = true
        if pendingResumePosition != nil || resumeSeekInProgress {
            playbackState = item.status == .readyToPlay ? .buffering : .loading
            recovery.recordInterruption()
            resumePlayback(for: item, session: session, generation: generation)
            return
        }
        switch status {
        case .playing:
            cancelWatchdog()
            playbackState = .playing
            // Defer `recovery.recordPlaying` until `progressWatchdog` confirms playhead advances.
            if progressWatchdog.isProgressing {
                let now = ProcessInfo.processInfo.systemUptime
                recovery.recordPlaying(at: now)
                liveFallback?.recordPlaying(at: now)
            }
        case .paused, .waitingToPlayAtSpecifiedRate:
            recovery.recordInterruption()
            liveFallback?.recordInterruption()
            healthyProgressStartedAt = nil
            progressWatchdog.reset()
            playbackState = item.status == .readyToPlay ? .buffering : .loading
            startWatchdog(for: item, session: session, generation: generation)
        @unknown default:
            break
        }
    }

    public func setPlaylist(_ streams: [LiveStream], startingWith stream: LiveStream) {
        self.activePlaylist = streams
        if let idx = streams.firstIndex(where: { $0.id == stream.id }) {
            self.activeIndex = idx
        } else {
            self.activeIndex = 0
        }
    }

    public func play(stream: LiveStream, from playlist: [LiveStream]? = nil) {
        beginPlaybackSession(diagnosticKind: .live)

        if let playlist {
            setPlaylist(playlist, startingWith: stream)
        } else if activePlaylist.isEmpty {
            self.activePlaylist = [stream]
            self.activeIndex = 0
        }

        self.currentStream = stream
        self.currentVOD = nil
        self.activeEpisodeList = []
        self.activeEpisodeIndex = 0
        self.activeSeriesName = ""
        self.playbackState = .loading
        self.stallCount = 0
        self.currentFormat = .hls
        // For live TV, a lower quality that keeps up beats a better picture that stalls.
        self.quality = QualityStepDownPolicy(stallsToStepDown: 1)

        // Record in history
        FavoritesStore.shared.addRecent(channelID: stream.id)
        TopShelfStore.shared.recordContinueWatching(
            id: "\(stream.id)",
            title: stream.cleanName,
            subtitle: stream.quality.rawValue,
            imageURLString: stream.iconURLString,
            kind: "live"
        )

        startPlayback(for: stream, format: currentFormat)
    }

    private func startPlayback(for stream: LiveStream, format: StreamFormatPreference) {
        if let direct = stream.directURLString {
            guard let url = Self.playableURL(fromPlaylistEntry: direct) else {
                failPlayback(with: "Invalid stream URL.")
                return
            }
            startLive(url: url)
            return
        }

        guard let url = AccountStore.shared.client.liveStreamURL(streamID: stream.id, format: format) else {
            failPlayback(with: "Invalid stream URL.")
            return
        }

        startLive(url: url)
    }

    /// Plays a live URL.
    ///
    /// With the MPEG-TS protocol (the default), Xtream channels play through the local relay,
    /// which reads the provider's continuous `.ts` stream like IPTV Smarters does. If the relay
    /// cannot start, playback falls back to the provider's HLS. With live rewind on and HLS
    /// chosen, a local recorder captures the HLS stream first. Otherwise AVPlayer reads the
    /// provider's HLS directly.
    private func handleSettingsChanged(from oldValue: PlayerSettings, to newValue: PlayerSettings) {
        if oldValue.defaultAspectRatio != newValue.defaultAspectRatio, aspectRatio != newValue.defaultAspectRatio {
            aspectRatio = newValue.defaultAspectRatio
        }
        if oldValue.preferredFormat != newValue.preferredFormat || oldValue.liveRewind != newValue.liveRewind {
            liveTransportMemory.removeAll()
        }
        guard currentStream != nil else { return }
        if !oldValue.liveRewind && newValue.liveRewind {
            // Serialize teardown before re-opening with live rewind enabled so we never open
            // a 2nd concurrent connection to a single-connection provider.
            liveRecoveryBlockedForSession = false
            if liveRecorder == nil, let url = originalLiveURL ?? providerURL, !url.isFileURL {
                let wasPlaying = isPlaybackRequested
                let resolved = LiveTransportFallbackPolicy.resolvePreferences(
                    preferredFormat: settings.preferredFormat,
                    hasTSRelay: TransportStreamRelayPolicy.relayURL(for: url) != nil,
                    allowedOutputFormats: AccountStore.shared.authResponse?.userInfo.allowedOutputFormats
                )
                let policy = LiveTransportFallbackPolicy(
                    preferredFormat: resolved.preferredFormat,
                    hasTSRelay: resolved.hasTSRelay,
                    liveRewind: true
                )
                liveFallback = policy
                switchLiveTransport(to: policy.currentMode, hlsURL: url)
                if !wasPlaying {
                    pausePlaybackIntent()
                    player.pause()
                }
            }
        } else if oldValue.liveRewind && !newValue.liveRewind {
            cancelLiveBufferRecovery()
            if liveRecorder != nil, liveFallback?.currentMode == .bufferedHLS,
               let directURL = originalLiveURL ?? providerURL {
                let wasPlaying = isPlaybackRequested
                let resolved = LiveTransportFallbackPolicy.resolvePreferences(
                    preferredFormat: settings.preferredFormat,
                    hasTSRelay: TransportStreamRelayPolicy.relayURL(for: directURL) != nil,
                    allowedOutputFormats: AccountStore.shared.authResponse?.userInfo.allowedOutputFormats
                )
                liveFallback = LiveTransportFallbackPolicy(
                    preferredFormat: resolved.preferredFormat,
                    hasTSRelay: resolved.hasTSRelay,
                    liveRewind: false,
                    rememberedMode: .directHLS
                )
                switchLiveTransport(to: .directHLS, hlsURL: directURL)
                if !wasPlaying {
                    pausePlaybackIntent()
                    player.pause()
                }
            }
        }
    }

    private func startLive(url: URL) {
        providerURL = url
        originalLiveURL = url
        guard !url.isFileURL else {
            activeFormatLabel = "Local File"
            prepareAndPlay(url: url)
            return
        }
        let resolved = LiveTransportFallbackPolicy.resolvePreferences(
            preferredFormat: settings.preferredFormat,
            hasTSRelay: TransportStreamRelayPolicy.relayURL(for: url) != nil,
            allowedOutputFormats: AccountStore.shared.authResponse?.userInfo.allowedOutputFormats
        )
        let rememberedMode = liveTransportMemory.mode(
            for: url.absoluteString,
            now: ProcessInfo.processInfo.systemUptime
        )
        let policy = LiveTransportFallbackPolicy(
            preferredFormat: resolved.preferredFormat,
            hasTSRelay: resolved.hasTSRelay,
            liveRewind: settings.liveRewind,
            rememberedMode: rememberedMode
        )
        liveFallback = policy
        let pauseForRelease = needsConnectionReleasePause
        needsConnectionReleasePause = false
        startLiveTransport(policy.currentMode, hlsURL: url, pauseForRelease: pauseForRelease)
    }

    private func startLiveTransport(_ mode: LiveTransportMode, hlsURL: URL, pauseForRelease: Bool) {
        activeFormatLabel = mode.displayLabel
        switch mode {
        case .tsRelay:
            if let relayURL = TransportStreamRelayPolicy.relayURL(for: hlsURL) {
                startRelayedLivePlayback(relayURL: relayURL, fallbackURL: hlsURL, pauseForRelease: pauseForRelease)
            } else {
                startLiveTransport(.directHLS, hlsURL: hlsURL, pauseForRelease: pauseForRelease)
            }
        case .bufferedHLS:
            startBufferedLivePlayback(url: hlsURL, pauseForRelease: pauseForRelease)
        case .directHLS:
            if !pauseForRelease && pendingTeardownTask == nil {
                prepareAndPlay(url: hlsURL)
            } else {
                let session = sessionGeneration
                playbackState = .loading
                liveCaptureTask = Task { [weak self] in
                    guard let self else { return }
                    guard await self.awaitConnectionRelease(pauseForXtream: pauseForRelease, session: session) else { return }
                    self.liveCaptureTask = nil
                    self.prepareAndPlay(url: hlsURL)
                }
            }
        }
    }

    private func switchLiveTransport(to mode: LiveTransportMode, hlsURL: URL, unavailableNotice: String? = nil) {
        PlaybackDiagnosticsStore.shared.recordRetry(kind: .live)
        cancelLiveBufferRecovery()
        cancelWatchdog()
        cancelRetry()
        itemGeneration &+= 1
        itemObservers.removeAll()
        resetMediaTracks()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopLiveBuffer()
        if let unavailableNotice {
            liveBufferUnavailable = unavailableNotice
        }
        recovery.reset()
        progressWatchdog.reset()
        confirmedHealthyForSession = false
        healthyProgressStartedAt = nil
        lastTerminalFailureWasNetwork = false
        liveJumpInProgress = false
        currentPlaybackURL = nil
        managedLocalPlaylistURL = nil
        if isPlaybackRequested {
            playbackState = .loading
        }
        startLiveTransport(mode, hlsURL: hlsURL, pauseForRelease: true)
    }

    private func awaitConnectionRelease(pauseForXtream: Bool, session: UInt64) async -> Bool {
        if let teardown = pendingTeardownTask {
            await teardown.value
        }
        guard !Task.isCancelled, sessionGeneration == session else { return false }
        let maxConnections = AccountStore.shared.authResponse?.userInfo.maxConnectionsCount ?? 1
        if pauseForXtream, maxConnections <= 1 {
            // Brief release pause so single-connection Xtream panels free the prior slot.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, sessionGeneration == session else { return false }
        }
        return true
    }

    public func waitForPendingTeardown(timeout: TimeInterval = 0.5) async {
        guard let teardown = pendingTeardownTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await teardown.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func handleLocalServerFailure(session: UInt64, server: LiveTimeshiftServer?) {
        guard sessionGeneration == session, currentStream != nil,
              let server, self.liveServer === server else { return }
        relayLog.error("local timeshift server failed after startup; recovering live transport")
        stopLiveBuffer()
        guard isPlaybackRequested else {
            player.replaceCurrentItem(with: nil)
            currentPlaybackURL = nil
            return
        }
        guard let hlsURL = originalLiveURL ?? providerURL else {
            failPlayback(with: PlaybackFailure.transient.message, isNetworkFailure: true)
            return
        }
        let nextMode = liveFallback?.recordCaptureFailure(unsupported: false) ?? .directHLS
        switchLiveTransport(to: nextMode, hlsURL: hlsURL)
    }

    private func startRelayedLivePlayback(relayURL: URL, fallbackURL: URL, pauseForRelease: Bool) {
        // Used by fallback when AVPlayer cannot decode or the relay cannot read the `.ts` stream.
        originalLiveURL = fallbackURL
        cancelLiveBufferRecovery()
        let session = sessionGeneration
        let limits = settings.liveRewind
            ? LiveTimeshiftLimits()
            : LiveTimeshiftLimits(seconds: 30, bytes: 32 * 1024 * 1024, segmentBytes: 16 * 1024 * 1024, segmentCount: 120)
        liveCaptureTask = Task { [weak self] in
            guard let self else { return }
            guard await self.awaitConnectionRelease(pauseForXtream: pauseForRelease, session: session) else { return }
            var activeRecorder: LiveTimeshiftRecorder?
            do {
                let recorder = try LiveTimeshiftRecorder(limits: limits)
                activeRecorder = recorder
                self.liveRecorder = recorder
                let serverRef = WeakLiveServerBox()
                let server = LiveTimeshiftServer(recorder: recorder) { [weak self, serverRef] in
                    Task { @MainActor [weak self, serverRef] in
                        self?.handleLocalServerFailure(session: session, server: serverRef.server)
                    }
                }
                serverRef.server = server
                self.liveServer = server
                // Start the local HTTP server upfront in parallel with stream capture so no listener
                // startup delay is paid after the first keyframe segment lands.
                let localURL = try await server.start()
                guard !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder else {
                    server.stop()
                    return
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await recorder.captureTransportStream(relayURL)
                    }
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return }
                        // Cold-start Xtream channels behind reverse proxies can need >6s for 1st keyframe+segment.
                        let initialSnapshot = try await recorder.waitForFirstSegment(timeout: 12)
                        guard !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder else {
                            return
                        }
                        self.liveBuffer = initialSnapshot
                        relayLog.info("relay ready on first segment (\(initialSnapshot.duration, privacy: .public)s buffered)")
                        self.managedLocalPlaylistURL = localURL
                        self.prepareAndPlay(url: localURL)

                        var lastRecordedEnd = initialSnapshot.recordedEnd
                        while !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder {
                            let updated = try await recorder.waitForSnapshotUpdate(afterRecordedEnd: lastRecordedEnd, timeout: 2.0)
                            guard !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder else { return }
                            self.liveBuffer = updated
                            lastRecordedEnd = updated.recordedEnd
                        }
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                    group.cancelAll()
                    while (try? await group.next()) != nil {}
                }
                // If captureTransportStream returned after exhausting retries, escalate to fallback.
                if let failure = await recorder.transportStreamFailure() {
                    throw failure
                }
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == session else { return }
                relayLog.error("relay failed, escalating live transport: \(String(describing: error), privacy: .public)")
                let isTimeout = (error as? LiveTimeshiftError) == .startupTimeout
                let isUnsupported: Bool
                if case .unsupported = error as? LiveTimeshiftError {
                    isUnsupported = true
                } else {
                    isUnsupported = false
                }
                let reason = isTimeout ? nil : ((error as? LiveTimeshiftError)?.errorDescription ?? "The MPEG-TS relay could not read this channel.")
                if self.liveRecorder === activeRecorder {
                    self.liveCaptureTask = nil
                }
                self.stopLiveBuffer()
                if let nextMode = self.liveFallback?.recordCaptureFailure(unsupported: isUnsupported) {
                    self.switchLiveTransport(to: nextMode, hlsURL: fallbackURL, unavailableNotice: reason)
                } else {
                    self.switchLiveTransport(to: .directHLS, hlsURL: fallbackURL, unavailableNotice: reason)
                }
            }
        }
    }

    /// True for playlists served by BruTV's own local server (relay or recorder).
    nonisolated static func isLocalPlaylist(_ url: URL) -> Bool {
        url.host == "127.0.0.1"
    }

    /// AVPlayer cannot play raw MPEG-TS over HTTP. Xtream-style playlist entries
    /// (`/live/user/pass/123.ts`) also serve HLS at the same path with `.m3u8`.
    nonisolated static func playableURL(fromPlaylistEntry entry: String) -> URL? {
        guard var components = URLComponents(string: entry) else { return nil }
        let path = components.path
        if path.lowercased().hasSuffix(".ts"), path.contains("/live/") {
            components.path = String(path.dropLast(3)) + ".m3u8"
        }
        return components.url
    }

    public func playVOD(vod: VODStream) {
        beginPlaybackSession(diagnosticKind: .video)

        self.currentVOD = vod
        self.activeEpisodeList = []
        self.activeEpisodeIndex = 0
        self.activeSeriesName = ""
        self.quality = QualityStepDownPolicy(stallsToStepDown: 2)
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0
        self.activeFormatLabel = vod.containerExtension.isEmpty ? "VOD" : vod.containerExtension.uppercased()

        guard let url = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension) else {
            failPlayback(with: "Invalid movie URL.")
            return
        }

        providerURL = url
        TopShelfStore.shared.recordContinueWatching(
            id: "\(vod.id)",
            title: vod.name,
            subtitle: vod.rating,
            imageURLString: vod.iconURLString,
            kind: "vod"
        )
        let savedPosition = WatchProgressStore.shared.resumePosition(kind: "vod", streamID: vod.id)
        prepareAndPlay(url: url, resumePosition: savedPosition)
    }

    public func playEpisode(episode: SeriesEpisode, seriesName: String, seasonEpisodes: [SeriesEpisode] = []) {
        beginPlaybackSession(diagnosticKind: .video)

        let titleFormatted: String
        if seriesName.isEmpty || episode.title.hasPrefix(seriesName) {
            titleFormatted = episode.title
        } else if episode.title.hasPrefix("Episode") || episode.title.hasPrefix("E") {
            titleFormatted = "\(seriesName) - \(episode.title)"
        } else {
            titleFormatted = "\(seriesName) - S\(episode.season)E\(episode.episodeNum): \(episode.title)"
        }

        let vod = VODStream(
            id: episode.id,
            name: titleFormatted,
            iconURLString: episode.info?.movieImage,
            rating: episode.info?.rating,
            categoryId: "\(episode.season)",
            containerExtension: episode.containerExtension,
            streamType: "series"
        )
        self.currentVOD = vod
        if !seasonEpisodes.isEmpty {
            self.activeEpisodeList = seasonEpisodes
            self.activeEpisodeIndex = seasonEpisodes.firstIndex(where: { $0.id == episode.id }) ?? 0
            self.activeSeriesName = seriesName
        } else if let idx = self.activeEpisodeList.firstIndex(where: { $0.id == episode.id }) {
            self.activeEpisodeIndex = idx
        } else {
            self.activeEpisodeList = []
            self.activeEpisodeIndex = 0
            self.activeSeriesName = ""
        }
        self.quality = QualityStepDownPolicy(stallsToStepDown: 2)
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0
        self.activeFormatLabel = episode.containerExtension.isEmpty ? "VOD" : episode.containerExtension.uppercased()

        guard let url = AccountStore.shared.client.seriesStreamURL(streamID: episode.id, containerExtension: episode.containerExtension) else {
            failPlayback(with: "Invalid episode URL.")
            return
        }

        providerURL = url
        TopShelfStore.shared.recordContinueWatching(
            id: "\(episode.id)",
            title: titleFormatted,
            subtitle: seriesName,
            imageURLString: episode.info?.movieImage,
            kind: "series"
        )
        let savedPosition = WatchProgressStore.shared.resumePosition(kind: "series", streamID: episode.id)
        prepareAndPlay(url: url, resumePosition: savedPosition)
    }

    public var hasPreviousEpisode: Bool {
        !activeEpisodeList.isEmpty && activeEpisodeIndex > 0
    }

    public var hasNextEpisode: Bool {
        !activeEpisodeList.isEmpty && activeEpisodeIndex + 1 < activeEpisodeList.count
    }

    public func previousEpisode() {
        guard hasPreviousEpisode else { return }
        let prev = activeEpisodeList[activeEpisodeIndex - 1]
        playEpisode(episode: prev, seriesName: activeSeriesName, seasonEpisodes: activeEpisodeList)
    }

    public func nextEpisode() {
        guard hasNextEpisode else { return }
        let next = activeEpisodeList[activeEpisodeIndex + 1]
        playEpisode(episode: next, seriesName: activeSeriesName, seasonEpisodes: activeEpisodeList)
    }

    private func beginPlaybackSession(diagnosticKind: PlaybackHealthSummary.Kind) {
        persistVODWatchProgress(force: true)
        let hadRemoteLive = currentStream != nil && (
            liveRecorder != nil || liveCaptureTask != nil ||
            (currentPlaybackURL != nil && currentPlaybackURL?.isFileURL == false)
        )
        PlaybackDiagnosticsStore.shared.begin(kind: diagnosticKind)
        cancelLiveBufferRecovery()
        stopLiveBuffer()
        liveRecoveryBlockedForSession = false
        liveFallback = nil
        originalLiveURL = nil
        codecFallback = LiveTimeshiftCodecFallback()
        confirmedHealthyForSession = false
        healthyProgressStartedAt = nil
        lastTerminalFailureWasNetwork = false
        liveJumpInProgress = false
        resumeAfterAudioInterruption = false
        backgroundedWithLocalServer = false
        sessionGeneration &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        stopTelemetryMonitoring()
        cancelWatchdog()
        cancelRetry()
        recovery = diagnosticKind == .live
            ? PlaybackRecoveryPolicy(maxAttempts: nil, healthyInterval: 30, maxDelay: 15.0, jitterFactor: 0.2)
            : PlaybackRecoveryPolicy(maxAttempts: 3, healthyInterval: 30, maxDelay: 15.0, jitterFactor: 0.2)
        progressWatchdog = PlaybackProgressWatchdog(isLive: diagnosticKind == .live)
        quality.reset()
        providerURL = nil
        isPlaybackRequested = true
        currentPlaybackURL = nil
        pendingResumePosition = nil
        resumeSeekInProgress = false
        lastVODPosition = 0
        vodCurrentTime = 0
        vodDuration = 0
        resetMediaTracks()
        telemetry = StreamTelemetry()
        needsConnectionReleasePause = hadRemoteLive && diagnosticKind == .live
    }

    private func startBufferedLivePlayback(url: URL, pauseForRelease: Bool) {
        originalLiveURL = url
        cancelLiveBufferRecovery()
        let session = sessionGeneration
        liveCaptureTask = Task { [weak self] in
            guard let self else { return }
            guard await self.awaitConnectionRelease(pauseForXtream: pauseForRelease, session: session) else { return }
            var ready = false
            var activeRecorder: LiveTimeshiftRecorder?
            do {
                let recorder = try LiveTimeshiftRecorder()
                activeRecorder = recorder
                self.liveRecorder = recorder
                let serverRef = WeakLiveServerBox()
                let server = LiveTimeshiftServer(recorder: recorder) { [weak self, serverRef] in
                    Task { @MainActor [weak self, serverRef] in
                        self?.handleLocalServerFailure(session: session, server: serverRef.server)
                    }
                }
                serverRef.server = server
                self.liveServer = server
                let localURL = try await server.start()
                guard !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder else {
                    server.stop()
                    return
                }
                var pollDelay: Double = 1
                var failures = 0
                // Past this, escalate to alternate transport instead of waiting indefinitely.
                let deadline = Date().addingTimeInterval(12)
                while !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder {
                    do {
                        if ready {
                            pollDelay = try await recorder.capture(url)
                        } else {
                            pollDelay = try await recorder.capture(url, timeout: deadline.timeIntervalSinceNow)
                        }
                        failures = 0
                        let snapshot = await recorder.snapshot()
                        guard !Task.isCancelled, self.sessionGeneration == session, self.liveRecorder === recorder else { return }
                        self.liveBuffer = snapshot
                        self.liveBufferUnavailable = nil
                        if !ready, snapshot.duration > 0 {
                            ready = true
                            self.managedLocalPlaylistURL = localURL
                            self.prepareAndPlay(url: localURL)
                        }
                    } catch {
                        if Task.isCancelled { throw error }
                        if let failure = error as? LiveTimeshiftError {
                            switch failure {
                            case .unsupported, .stopped, .bufferLimit:
                                throw error
                            case .stalePlaylist:
                                if !ready { throw error }
                            default:
                                if !ready {
                                    guard case .network(let status) = failure, status == 408 || status == 429 || status == 458 || status >= 500 else { throw error }
                                }
                            }
                        }
                        failures += 1
                        if failures >= 3 { throw error }
                        self.liveBuffer.notice = "The provider connection was interrupted. Capture is retrying."
                        pollDelay = min(15, Double(2 * min(failures, 5)))
                    }
                    if !ready, Date() > deadline { throw LiveTimeshiftError.startupTimeout }
                    let delay = ready ? pollDelay : min(pollDelay, 1)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == session else { return }
                let isTimeout = (error as? LiveTimeshiftError) == .startupTimeout
                let isUnsupported: Bool
                if case .unsupported = error as? LiveTimeshiftError {
                    isUnsupported = true
                    self.liveRecoveryBlockedForSession = true
                } else {
                    isUnsupported = false
                }
                let reason = isTimeout ? nil : ((error as? LiveTimeshiftError)?.errorDescription ?? "The live buffer could not connect to this provider.")
                if self.liveRecorder === activeRecorder {
                    self.liveCaptureTask = nil
                }
                self.stopLiveBuffer()
                if let nextMode = self.liveFallback?.recordCaptureFailure(unsupported: isUnsupported) {
                    self.switchLiveTransport(to: nextMode, hlsURL: url, unavailableNotice: reason)
                } else {
                    self.switchLiveTransport(to: .directHLS, hlsURL: url, unavailableNotice: reason)
                }
            }
        }
    }

    private func cancelLiveBufferRecovery() {
        liveRecoveryTask?.cancel()
        liveRecoveryTask = nil
        isRecoveringLiveBuffer = false
    }

    private func stopLiveBuffer() {
        let previousCaptureTask = liveCaptureTask
        liveCaptureTask = nil
        previousCaptureTask?.cancel()
        liveServer?.stop()
        liveServer = nil
        managedLocalPlaylistURL = nil
        let previousRecorder = liveRecorder
        liveRecorder = nil
        if previousCaptureTask != nil || previousRecorder != nil {
            let priorTeardown = pendingTeardownTask
            pendingTeardownTask = Task {
                await priorTeardown?.value
                await previousCaptureTask?.value
                if let previousRecorder {
                    await previousRecorder.stop()
                }
            }
        }
        liveBuffer = LiveTimeshiftSnapshot()
        liveBufferUnavailable = nil
        liveBehindSeconds = 0
        liveSeekStart = 0
        liveSeekEnd = 0
        livePlayhead = 0
        pausedLivePosition = nil
        pendingLiveRecordedPosition = nil
        pendingLiveDate = nil
        explicitlyRewound = false
        liveJumpInProgress = false
    }

    func prepareAndPlay(url: URL, resumePosition: Double? = nil) {
        cancelWatchdog()
        cancelRetry()
        resetMediaTracks()
        player.currentItem?.cancelPendingSeeks()
        itemObservers.removeAll()
        itemGeneration &+= 1
        let session = sessionGeneration
        let generation = itemGeneration
        currentPlaybackURL = url
        pendingResumePosition = resumePosition
        resumeSeekInProgress = false
        liveJumpInProgress = false
        lastTerminalFailureWasNetwork = false
        progressWatchdog.reset()
        playbackState = .loading
        var httpHeaders: [String: String] = [
            "User-Agent": "IPTVSmartersPro/1.1.1"
        ]
        if currentStream != nil, !url.isFileURL {
            httpHeaders["Cache-Control"] = "no-cache"
        }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": httpHeaders
            ]
        )
        let playerItem = AVPlayerItem(asset: asset)

        HLSBufferEngine.shared.configurePlayerItem(
            playerItem,
            with: settings.bufferProfile,
            liveRewindEnabled: settings.liveRewind
        )
        if quality.peakBitRate > 0 {
            playerItem.preferredPeakBitRate = quality.peakBitRate
        }
        // The local relay and recorder serve a short live playlist from memory. With a fixed
        // forward buffer, AVPlayer never becomes ready on it, even with seconds of media
        // available. The automatic buffer (0) starts at once.
        if Self.isLocalPlaylist(url) {
            playerItem.preferredForwardBufferDuration = 0
        }
        // Staying live matters more than quality: after a stall, jump ahead to keep the same
        // distance from the live edge instead of playing further and further behind.
        // With live rewind on, people choose where to watch, so keep their position.
        if currentStream != nil, !settings.liveRewind {
            playerItem.automaticallyPreservesTimeOffsetFromLive = true
        }

        player.pause()
        player.actionAtItemEnd = PlaybackPolicy.retriesAtEnd(isLive: currentStream != nil, url: url) ? .none : .pause
        player.replaceCurrentItem(with: playerItem)
        observePlayerItem(playerItem, session: session, generation: generation)
        if isPlaybackRequested, resumePosition == nil {
            player.play()
        }

        startTelemetryMonitoring()
        startWatchdog(for: playerItem, session: session, generation: generation)
    }

    private func isCurrent(_ item: AVPlayerItem, session: UInt64, generation: UInt64) -> Bool {
        sessionGeneration == session && itemGeneration == generation && player.currentItem === item
    }

    private func startWatchdog(for playerItem: AVPlayerItem, session: UInt64, generation: UInt64) {
        guard isPlaybackRequested, watchdogWorkItem == nil, retryWorkItem == nil,
              player.timeControlStatus != .playing || pendingResumePosition != nil || resumeSeekInProgress else { return }
        let ticket = watchdogGeneration
        let workItem = DispatchWorkItem { [weak self, weak playerItem] in
            guard let self, let playerItem,
                  self.isCurrent(playerItem, session: session, generation: generation),
                  self.isPlaybackRequested, self.watchdogGeneration == ticket else { return }
            self.watchdogWorkItem = nil
            guard self.player.timeControlStatus != .playing || self.pendingResumePosition != nil || self.resumeSeekInProgress else { return }
            self.handlePlaybackFailure(.timedOut, item: playerItem, session: session, generation: generation)
        }
        watchdogWorkItem = workItem
        // Before any media arrives, wait longer on single-transport remote streams: some providers
        // take ~40s for a cold channel. Fail faster on local loopback playlists (12s) or remote
        // live streams that still have an untried alternate transport (18s). After media has
        // played, a 20 second stall is a real failure.
        let hasMedia = playerItem.status == .readyToPlay && !playerItem.loadedTimeRanges.isEmpty
        let timeout: TimeInterval
        if hasMedia {
            timeout = 20.0
        } else if isPlayingManagedLocalPlaylist || currentPlaybackURL.map(Self.isLocalPlaylist) == true {
            timeout = 12.0
        } else if currentStream != nil,
                  let fallback = liveFallback,
                  fallback.hasTSRelay,
                  fallback.triedModes.count == 1 {
            timeout = 18.0
        } else {
            timeout = 45.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelWatchdog() {
        watchdogGeneration &+= 1
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
    }

    private func cancelRetry() {
        retryGeneration &+= 1
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem, session: UInt64, generation: UInt64) {
        setupPlayerObservers(for: playerItem, session: session, generation: generation)

        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] _ in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation),
                      self.isPlaybackRequested, self.retryWorkItem == nil else { return }
                switch playerItem.status {
                case .readyToPlay:
                    self.updateMediaTracks(for: playerItem)
                    self.updateLiveTimeline(for: playerItem)
                    if self.currentVOD != nil {
                        let dur = CMTimeGetSeconds(playerItem.duration)
                        if dur.isFinite && !dur.isNaN && dur > 0 {
                            self.vodDuration = dur
                        }
                    }
                    if self.pendingResumePosition != nil {
                        DispatchQueue.main.async { [weak self, weak playerItem] in
                            guard let self, let playerItem else { return }
                            self.resumePlayback(for: playerItem, session: session, generation: generation)
                        }
                    }
                case .failed:
                    let failure = self.classifyPlaybackFailure(playerItem.error, item: playerItem)
                    self.handlePlaybackFailure(failure, item: playerItem, session: session, generation: generation)
                default:
                    break
                }
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] _ in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation),
                      self.isPlaybackRequested, self.retryWorkItem == nil else { return }
                self.stallCount += 1
                self.recovery.recordInterruption()
                self.liveFallback?.recordInterruption()
                self.healthyProgressStartedAt = nil
                self.progressWatchdog.reset()
                self.stepDownQualityAfterStall(playerItem)
                if let hlsURL = self.originalLiveURL ?? self.providerURL,
                   !hlsURL.isFileURL,
                   let fallbackMode = self.liveFallback?.recordStall(at: ProcessInfo.processInfo.systemUptime) {
                    relayLog.info("repeated stalls on live stream; switching to \(fallbackMode.displayLabel, privacy: .public)")
                    self.switchLiveTransport(to: fallbackMode, hlsURL: hlsURL)
                    return
                }
                self.playbackState = .buffering
                self.startWatchdog(for: playerItem, session: session, generation: generation)
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] _ in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation) else { return }
                if self.isPlaybackRequested,
                   PlaybackPolicy.retriesAtEnd(isLive: self.currentStream != nil, url: self.currentPlaybackURL) {
                    self.handlePlaybackFailure(.transient, item: playerItem, session: session, generation: generation)
                    return
                }
                if let vod = self.currentVOD {
                    let kind = vod.streamType == "series" ? "series" : "vod"
                    WatchProgressStore.shared.markCompleted(kind: kind, streamID: vod.id)
                    if vod.streamType == "series", self.settings.autoPlayNextEpisode, self.hasNextEpisode {
                        self.nextEpisode()
                        return
                    }
                }
                PlaybackDiagnosticsStore.shared.finish(outcome: .ended)
                self.isPlaybackRequested = false
                self.cancelWatchdog()
                self.cancelRetry()
                self.recovery.recordInterruption()
                self.playbackState = .paused
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] notification in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation),
                      self.isPlaybackRequested, self.retryWorkItem == nil else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let failure = self.classifyPlaybackFailure(error ?? playerItem.error, item: playerItem)
                self.handlePlaybackFailure(failure, item: playerItem, session: session, generation: generation)
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: AVPlayerItem.mediaSelectionDidChangeNotification, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] _ in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation) else { return }
                self.applyMediaTracks(for: playerItem)
            }
            .store(in: &itemObservers)
    }

    private func resumePlayback(for item: AVPlayerItem, session: UInt64, generation: UInt64) {
        guard isCurrent(item, session: session, generation: generation), isPlaybackRequested,
              retryWorkItem == nil, !resumeSeekInProgress else { return }
        guard let position = pendingResumePosition else {
            player.play()
            startWatchdog(for: item, session: session, generation: generation)
            return
        }
        guard item.status == .readyToPlay else {
            startWatchdog(for: item, session: session, generation: generation)
            return
        }
        if liveRecorder != nil, liveSeekableRange(for: item) == nil {
            player.play()
            startWatchdog(for: item, session: session, generation: generation)
            return
        }
        let seconds: Double
        if (liveRecorder != nil || (currentStream != nil && settings.liveRewind && !(currentPlaybackURL?.isFileURL ?? false))),
           let range = liveSeekableRange(for: item) {
            let restored: Double
            if let date = pendingLiveDate, let currentDate = item.currentDate() {
                restored = CMTimeGetSeconds(item.currentTime()) + date.timeIntervalSince(currentDate)
            } else if liveRecorder != nil, let anchor = pendingLiveRecordedPosition {
                restored = LiveTimeshiftSeekPolicy.restoredPosition(recordedPosition: anchor, recordedEnd: liveBuffer.recordedEnd,
                                                                   seekableStart: range.start, seekableEnd: range.end) ?? range.start
            } else { restored = position }
            seconds = LiveTimeshiftSeekPolicy.clamp(restored, start: range.start, end: range.end) ?? range.start
        } else {
            seconds = PlaybackPolicy.vodResumePosition(position, duration: CMTimeGetSeconds(item.duration)) ?? 0
        }
        resumeSeekInProgress = true
        player.play()
        startWatchdog(for: item, session: session, generation: generation)
        item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                      self.isCurrent(item, session: session, generation: generation) else { return }
                self.resumeSeekInProgress = false
                self.pendingResumePosition = nil
                self.pendingLiveDate = nil
                self.pendingLiveRecordedPosition = nil
                guard self.isPlaybackRequested, self.retryWorkItem == nil else { return }
                // A native pause can race its rate-change notification during the seek.
                // Honor the completed transport state instead of the earlier resume intent.
                self.synchronizeTransport(for: item, session: session, generation: generation,
                                          recognizesPauseRequest: true)
            }
        }
    }

    private func classifyPlaybackFailure(_ error: Error?, item: AVPlayerItem) -> PlaybackFailure {
        let lastEvent = item.errorLog()?.events.last
        let recentHTTPStatus = PlaybackPolicy.recentHTTPStatus(
            errorStatusCode: lastEvent?.errorStatusCode,
            eventDate: lastEvent?.date
        )
        if let networkFailure = PlaybackPolicy.networkFailure(
            for: error,
            httpStatus: recentHTTPStatus,
            localLiveRecording: liveRecorder != nil && currentStream != nil
                && currentPlaybackURL.map(Self.isLocalPlaylist) == true
        ) {
            return networkFailure
        }
        var currentError = error as NSError?
        for _ in 0..<8 {
            guard let current = currentError else { break }
            if current.domain == AVFoundationErrorDomain {
                if [AVError.Code.contentIsNotAuthorized.rawValue, AVError.Code.contentIsProtected.rawValue].contains(current.code) {
                    return .unauthorized
                }
                if [AVError.Code.decoderNotFound.rawValue, AVError.Code.decodeFailed.rawValue,
                    AVError.Code.undecodableMediaData.rawValue, AVError.Code.fileFormatNotRecognized.rawValue,
                    AVError.Code.operationNotSupportedForAsset.rawValue].contains(current.code) {
                    return .unsupported
                }
                if current.code == AVError.Code.mediaServicesWereReset.rawValue {
                    return .transient
                }
            }
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // Live streams should automatically retry on unclassified playback interruptions.
        if currentStream != nil {
            return .transient
        }
        return .unknown
    }

    private func handlePlaybackFailure(_ failure: PlaybackFailure, item: AVPlayerItem, session: UInt64, generation: UInt64) {
        guard isCurrent(item, session: session, generation: generation), isPlaybackRequested, retryWorkItem == nil else { return }
        let itemError = item.error as NSError?
        relayLog.error("playback failure \(String(describing: failure), privacy: .public): \(itemError?.domain ?? "none", privacy: .public) \(itemError?.code ?? 0, privacy: .public)")
        progressWatchdog.reset()
        healthyProgressStartedAt = nil
        liveFallback?.recordInterruption()

        let isLocal = isPlayingManagedLocalPlaylist
        if currentStream != nil, let hlsURL = originalLiveURL ?? providerURL, !hlsURL.isFileURL {
            // Never retry a dead loopback server URL; tear down and switch or restart upstream capture.
            if isLocal && (liveServer == nil || liveRecorder == nil || !(liveServer?.isRunning ?? false)) {
                let nextMode = liveFallback?.recordCaptureFailure(unsupported: failure == .unsupported) ?? .directHLS
                switchLiveTransport(to: nextMode, hlsURL: hlsURL)
                return
            }

            if let decision = liveFallback?.recordPlaybackFailure(failure) {
                switch decision {
                case .switchTo(let nextMode):
                    relayLog.info("live failure triggered transport switch to \(nextMode.displayLabel, privacy: .public)")
                    var notice: String?
                    if nextMode == .directHLS, codecFallback.consume(for: failure, recording: liveRecorder != nil) {
                        liveRecoveryBlockedForSession = true
                        notice = "This device could not decode the recorded variant. Playing the original stream directly without rewind."
                    }
                    switchLiveTransport(to: nextMode, hlsURL: hlsURL, unavailableNotice: notice)
                    return
                case .fail:
                    failPlayback(with: failure.message, isNetworkFailure: failure.canRetry)
                    return
                case .retryCurrent:
                    if isLocal && recovery.attempts >= 1 {
                        // Do not keep hammering a stalled local 127.0.0.1 playlist; restart upstream capture cleanly.
                        let mode = liveFallback?.currentMode ?? .directHLS
                        switchLiveTransport(to: mode, hlsURL: hlsURL)
                        return
                    }
                }
            }
        }

        cancelWatchdog()
        let resumePosition = currentPlaybackResumePosition()
        guard let delay = recovery.nextRetryDelay(for: failure), let url = currentPlaybackURL else {
            failPlayback(with: failure.message, isNetworkFailure: failure.canRetry)
            return
        }
        // Detach the failed item immediately so AVFoundation closes its upstream TCP socket
        // during backoff (critical for single-connection Xtream panels).
        itemObservers.removeAll()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackState = .buffering
        let ticket = retryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionGeneration == session,
                  self.itemGeneration == generation,
                  self.isPlaybackRequested,
                  self.retryGeneration == ticket else { return }
            self.retryWorkItem = nil
            PlaybackDiagnosticsStore.shared.recordRetry(kind: self.currentStream != nil ? .live : .video)
            self.prepareAndPlay(url: url, resumePosition: resumePosition)
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func failPlayback(with message: String, isNetworkFailure: Bool = false) {
        _ = currentVODResumePosition()
        lastTerminalFailureWasNetwork = isNetworkFailure
        isPlaybackRequested = false
        PlaybackDiagnosticsStore.shared.finish(outcome: .failed)
        cancelLiveBufferRecovery()
        stopLiveBuffer()
        cancelWatchdog()
        cancelRetry()
        stopTelemetryMonitoring()
        recovery.recordInterruption()
        progressWatchdog.reset()
        healthyProgressStartedAt = nil
        itemObservers.removeAll()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if currentPlaybackURL.map(Self.isLocalPlaylist) == true {
            currentPlaybackURL = nil
        }
        playbackState = .failed(message)
    }

    private func currentPlaybackResumePosition() -> Double? {
        if (liveRecorder != nil || canSeekLive), let item = player.currentItem {
            let position = pausedLivePosition ?? CMTimeGetSeconds(item.currentTime())
            let itemPosition = CMTimeGetSeconds(item.currentTime())
            pendingLiveDate = position.isFinite && itemPosition.isFinite
                ? item.currentDate()?.addingTimeInterval(position - itemPosition) : nil
            if liveRecorder != nil, let range = liveSeekableRange(for: item), position.isFinite {
                pendingLiveRecordedPosition = liveBuffer.recordedEnd - (range.end - position)
            }
            return position.isFinite ? position : nil
        }
        return currentVODResumePosition()
    }

    private func currentVODResumePosition() -> Double? {
        guard currentVOD != nil else { return nil }
        if let item = player.currentItem,
           let position = PlaybackPolicy.vodResumePosition(CMTimeGetSeconds(item.currentTime())) {
            lastVODPosition = position
        }
        return PlaybackPolicy.vodResumePosition(lastVODPosition)
    }

    public func retryCurrentPlayback() {
        guard currentStream != nil || currentVOD != nil else { return }
        PlaybackDiagnosticsStore.shared.recordRetry(kind: currentStream != nil ? .live : .video)
        resumeAfterAudioInterruption = false
        lastTerminalFailureWasNetwork = false
        confirmedHealthyForSession = false
        healthyProgressStartedAt = nil

        // Never retry a potentially dead local 127.0.0.1 URL on live streams; tear down and
        // restart upstream capture cleanly so a fresh listener and provider connection are created.
        if let stream = currentStream,
           isPlayingManagedLocalPlaylist || liveRecorder != nil || liveServer != nil
            || currentPlaybackURL.map(Self.isLocalPlaylist) == true {
            let hadLocal = liveRecorder != nil || liveServer != nil || currentPlaybackURL != nil
            cancelLiveBufferRecovery()
            stopLiveBuffer()
            cancelWatchdog()
            cancelRetry()
            sessionGeneration &+= 1
            player.currentItem?.cancelPendingSeeks()
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemObservers.removeAll()
            recovery.reset()
            progressWatchdog.reset()
            codecFallback = LiveTimeshiftCodecFallback()
            liveFallback = nil
            currentPlaybackURL = nil
            managedLocalPlaylistURL = nil
            isPlaybackRequested = true
            playbackState = .loading
            needsConnectionReleasePause = hadLocal
            startPlayback(for: stream, format: currentFormat)
            return
        }

        let resumePosition = currentPlaybackResumePosition()
        let url = currentPlaybackURL
        if liveRecorder == nil { sessionGeneration &+= 1 }
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        progressWatchdog.reset()
        if currentStream != nil, let hlsURL = originalLiveURL ?? providerURL, !hlsURL.isFileURL {
            let resolved = LiveTransportFallbackPolicy.resolvePreferences(
                preferredFormat: .hls,
                hasTSRelay: TransportStreamRelayPolicy.relayURL(for: hlsURL) != nil,
                allowedOutputFormats: AccountStore.shared.authResponse?.userInfo.allowedOutputFormats
            )
            liveFallback = LiveTransportFallbackPolicy(
                preferredFormat: resolved.preferredFormat,
                hasTSRelay: resolved.hasTSRelay,
                liveRewind: false,
                rememberedMode: .directHLS
            )
        }
        isPlaybackRequested = true
        if let url {
            prepareAndPlay(url: url, resumePosition: resumePosition)
        } else if let stream = currentStream {
            startPlayback(for: stream, format: currentFormat)
        } else if let vod = currentVOD {
            let streamURL: URL?
            if vod.streamType == "series" {
                streamURL = AccountStore.shared.client.seriesStreamURL(streamID: vod.id, containerExtension: vod.containerExtension)
            } else {
                streamURL = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension)
            }
            if let streamURL {
                prepareAndPlay(url: streamURL, resumePosition: resumePosition)
            } else {
                failPlayback(with: vod.streamType == "series" ? "Invalid episode URL." : "Invalid movie URL.")
            }
        }
    }

    public func nextChannel() {
        guard !activePlaylist.isEmpty else { return }
        let nextIdx = (activeIndex + 1) % activePlaylist.count
        self.activeIndex = nextIdx
        let nextStream = activePlaylist[nextIdx]
        play(stream: nextStream)
    }

    public func previousChannel() {
        guard !activePlaylist.isEmpty else { return }
        let prevIdx = (activeIndex - 1 + activePlaylist.count) % activePlaylist.count
        self.activeIndex = prevIdx
        let prevStream = activePlaylist[prevIdx]
        play(stream: prevStream)
    }

    public func togglePlayPause() {
        guard currentStream != nil || currentVOD != nil else { return }
        resumeAfterAudioInterruption = false
        if isPlaybackRequested {
            if (liveRecorder != nil || canSeekLive), pendingResumePosition == nil,
               player.currentItem?.status == .readyToPlay {
                pausedLivePosition = CMTimeGetSeconds(player.currentTime())
            }
            pausePlaybackIntent()
            player.pause()
        } else if case .failed = playbackState {
            retryCurrentPlayback()
        } else if player.currentItem == nil || player.currentItem?.status == .failed {
            retryCurrentPlayback()
        } else {
            isPlaybackRequested = true
            playbackState = player.currentItem?.status == .readyToPlay ? .buffering : .loading
            if let item = player.currentItem {
                if (liveRecorder != nil || canSeekLive), let position = pausedLivePosition,
                   let range = liveSeekableRange(for: item) {
                    pendingResumePosition = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end)
                    let targetDur = effectiveLiveTargetDuration(for: range)
                    let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                                          targetDuration: targetDur) ?? range.end
                    explicitlyRewound = position < livePosition - 1
                    pausedLivePosition = nil
                }
                resumePlayback(for: item, session: sessionGeneration, generation: itemGeneration)
            }
        }
    }

    private func pausePlaybackIntent() {
        persistVODWatchProgress(force: true)
        if (liveRecorder != nil || canSeekLive), pausedLivePosition == nil,
           pendingResumePosition == nil, player.currentItem?.status == .readyToPlay {
            pausedLivePosition = CMTimeGetSeconds(player.currentTime())
        }
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.recordInterruption()
        liveFallback?.recordInterruption()
        healthyProgressStartedAt = nil
        progressWatchdog.reset()
        if case .failed = playbackState { return }
        playbackState = .paused
    }

    private func persistVODWatchProgress(force: Bool) {
        guard let vod = currentVOD else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force, uptime - lastSavedProgressUptime < 5.0 { return }
        let position: Double
        if let item = player.currentItem, item.status == .readyToPlay {
            let t = CMTimeGetSeconds(item.currentTime())
            position = (t.isFinite && !t.isNaN && t > 0) ? t : lastVODPosition
        } else {
            position = lastVODPosition
        }
        guard position.isFinite && position > 0 else { return }
        let duration: Double
        if let item = player.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            duration = (d.isFinite && !d.isNaN && d > 0) ? d : vodDuration
        } else {
            duration = vodDuration
        }
        lastSavedProgressUptime = uptime
        let isSeries = vod.streamType == "series"
        let currentEpisode = isSeries && activeEpisodeIndex < activeEpisodeList.count ? activeEpisodeList[activeEpisodeIndex] : nil
        WatchProgressStore.shared.record(
            streamID: vod.id,
            kind: isSeries ? "series" : "vod",
            title: vod.name,
            subtitle: isSeries ? (activeSeriesName.isEmpty ? nil : activeSeriesName) : vod.rating,
            imageURLString: vod.iconURLString,
            containerExtension: vod.containerExtension,
            season: currentEpisode?.season ?? Int(vod.categoryId),
            episodeNum: currentEpisode?.episodeNum,
            position: position,
            duration: duration
        )
    }

    /// After repeated stalls, caps the peak bitrate so AVPlayer switches to a lower variant.
    /// Streams with one variant (most Xtream channels) have nothing lower to switch to.
    private func stepDownQualityAfterStall(_ item: AVPlayerItem) {
        let indicated = item.accessLog()?.events.last?.indicatedBitrate ?? 0
        guard let cap = quality.recordStall(at: ProcessInfo.processInfo.systemUptime, currentBitrate: indicated) else { return }
        item.preferredPeakBitRate = cap
    }

    public func stop() {
        persistVODWatchProgress(force: true)
        cancelLiveBufferRecovery()
        stopLiveBuffer()
        liveRecoveryBlockedForSession = false
        liveFallback = nil
        originalLiveURL = nil
        codecFallback = LiveTimeshiftCodecFallback()
        confirmedHealthyForSession = false
        healthyProgressStartedAt = nil
        lastTerminalFailureWasNetwork = false
        liveJumpInProgress = false
        resumeAfterAudioInterruption = false
        backgroundedWithLocalServer = false
        needsConnectionReleasePause = false
        sessionGeneration &+= 1
        isPlaybackRequested = false
        PlaybackDiagnosticsStore.shared.finish(outcome: .stopped)
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        progressWatchdog.reset()
        quality.reset()
        providerURL = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        resetMediaTracks()
        currentStream = nil
        currentVOD = nil
        currentPlaybackURL = nil
        pendingResumePosition = nil
        resumeSeekInProgress = false
        lastVODPosition = 0
        playbackState = .idle
        telemetry = StreamTelemetry()
        stopTelemetryMonitoring()
    }

    private func startTelemetryMonitoring() {
        stopTelemetryMonitoring()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let currentItem = self.player.currentItem else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                let mediaTime = CMTimeGetSeconds(currentItem.currentTime())
                let isActivelyPlaying = self.isPlaybackRequested
                    && self.player.timeControlStatus == .playing
                    && self.player.rate > 0
                    && !self.resumeSeekInProgress
                    && !self.liveJumpInProgress
                    && self.pendingResumePosition == nil

                if self.progressWatchdog.evaluate(mediaTime: mediaTime, at: uptime, isPlaying: isActivelyPlaying) {
                    relayLog.error("playhead frozen while player reports playing; triggering recovery")
                    self.progressWatchdog.reset()
                    self.recovery.recordInterruption()
                    self.liveFallback?.recordInterruption()
                    self.handlePlaybackFailure(.timedOut, item: currentItem, session: self.sessionGeneration, generation: self.itemGeneration)
                    return
                }

                if isActivelyPlaying {
                    if self.progressWatchdog.isProgressing {
                        self.recovery.recordPlaying(at: uptime)
                        self.liveFallback?.recordPlaying(at: uptime)
                        if self.currentStream != nil, !self.confirmedHealthyForSession {
                            if let startedAt = self.healthyProgressStartedAt {
                                if uptime - startedAt >= 10.0,
                                   let mode = self.liveFallback?.currentMode,
                                   let originalURL = self.originalLiveURL,
                                   !originalURL.isFileURL {
                                    self.confirmedHealthyForSession = true
                                    self.liveTransportMemory.remember(mode, for: originalURL.absoluteString, now: uptime)
                                }
                            } else {
                                self.healthyProgressStartedAt = uptime
                            }
                        }
                    } else if self.progressWatchdog.frozenDuration(at: uptime) >= 2.0 {
                        self.recovery.recordInterruption()
                        self.liveFallback?.recordInterruption()
                        self.healthyProgressStartedAt = nil
                    }
                    if self.currentVOD != nil,
                       let position = PlaybackPolicy.vodResumePosition(mediaTime) {
                        self.lastVODPosition = position
                        self.persistVODWatchProgress(force: false)
                    }
                } else {
                    self.recovery.recordInterruption()
                    self.liveFallback?.recordInterruption()
                    self.healthyProgressStartedAt = nil
                }

                if self.currentVOD != nil {
                    if mediaTime.isFinite && !mediaTime.isNaN {
                        let clamped = max(0, mediaTime)
                        if abs(self.vodCurrentTime - clamped) >= 0.25 {
                            self.vodCurrentTime = clamped
                        }
                    }
                    let durationSeconds = CMTimeGetSeconds(currentItem.duration)
                    if durationSeconds.isFinite && !durationSeconds.isNaN && durationSeconds > 0,
                       abs(self.vodDuration - durationSeconds) >= 0.5 {
                        self.vodDuration = durationSeconds
                    }
                }
                if self.pendingResumePosition != nil, !self.resumeSeekInProgress, self.isPlaybackRequested {
                    self.resumePlayback(for: currentItem, session: self.sessionGeneration, generation: self.itemGeneration)
                }
                self.updateLiveTimeline(for: currentItem)
                self.keepLive(currentItem)
                var t = HLSBufferEngine.shared.extractTelemetry(from: currentItem, currentStallCount: self.stallCount)
                t.playbackRate = self.player.rate
                t.isLive = self.currentVOD == nil
                if self.telemetry != t {
                    self.telemetry = t
                }
            }
        }
    }

    /// Live TV prefers staying live over a smooth picture. See `LiveEdgePolicy`.
    private func keepLive(_ item: AVPlayerItem) {
        if currentStream != nil {
            relayLog.debug("""
                live state item=\(item.status.rawValue, privacy: .public) control=\(self.player.timeControlStatus.rawValue, privacy: .public) \
                reason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public) \
                time=\(CMTimeGetSeconds(item.currentTime()), privacy: .public) \
                ahead=\(HLSBufferEngine.shared.calculateBufferDuration(for: item), privacy: .public) \
                size=\(item.presentationSize.width, privacy: .public)x\(item.presentationSize.height, privacy: .public)
                """)
        }
        guard currentStream != nil, liveRecorder != nil || !(currentPlaybackURL?.isFileURL ?? false),
              isPlaybackRequested, retryWorkItem == nil, pendingResumePosition == nil,
              !resumeSeekInProgress, !liveJumpInProgress, !explicitlyRewound, item.status == .readyToPlay else { return }
        let range = liveSeekableRange(for: item)
        let current = CMTimeGetSeconds(item.currentTime())
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && player.reasonForWaitingToPlay == .toMinimizeStalls
        let action = LiveEdgePolicy.action(waitingToMinimizeStalls: waiting,
                                           bufferedAhead: HLSBufferEngine.shared.calculateBufferDuration(for: item),
                                           behindLive: range.map { $0.end - current },
                                           rewindEnabled: settings.liveRewind)
        switch action {
        case .none:
            break
        case .resume:
            relayLog.info("playing buffered media after a stall")
            player.playImmediately(atRate: 1)
        case .jumpToLive:
            guard let range else { return }
            let targetDur = effectiveLiveTargetDuration(for: range)
            let destination = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                                   targetDuration: targetDur) ?? range.end
            guard destination > current + 1 else { return }
            relayLog.info("jumping \(destination - current, privacy: .public)s ahead to live")
            let session = sessionGeneration
            let generation = itemGeneration
            liveJumpInProgress = true
            progressWatchdog.reset()
            item.seek(to: CMTime(seconds: destination, preferredTimescale: 600)) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item,
                          self.isCurrent(item, session: session, generation: generation) else { return }
                    self.liveJumpInProgress = false
                }
            }
        }
    }

    private func liveSeekableRange(for item: AVPlayerItem) -> (start: Double, end: Double)? {
        guard let value = item.seekableTimeRanges.last else { return nil }
        let range = value.timeRangeValue
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return (start, end)
    }

    private func effectiveLiveTargetDuration(for range: (start: Double, end: Double)) -> Double {
        if liveRecorder != nil, liveBuffer.targetDuration > 0 {
            return liveBuffer.targetDuration
        }
        return max(2, min(6, (range.end - range.start) * 0.25))
    }

    private func updateLiveTimeline(for item: AVPlayerItem) {
        guard currentStream != nil, settings.liveRewind,
              liveRecorder != nil || !(currentPlaybackURL?.isFileURL ?? false),
              let range = liveSeekableRange(for: item) else { return }
        if abs(liveSeekStart - range.start) >= 0.25 { liveSeekStart = range.start }
        if abs(liveSeekEnd - range.end) >= 0.25 { liveSeekEnd = range.end }
        let position = pausedLivePosition ?? CMTimeGetSeconds(item.currentTime())
        let clampedPlayhead = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end) ?? range.start
        if abs(livePlayhead - clampedPlayhead) >= 0.25 { livePlayhead = clampedPlayhead }
        let targetDur = effectiveLiveTargetDuration(for: range)
        let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                              targetDuration: targetDur) ?? range.end
        let behind = max(0, livePosition - clampedPlayhead)
        if abs(liveBehindSeconds - behind) >= 0.25 { liveBehindSeconds = behind }
        if behind <= 1 { explicitlyRewound = false }
        if !isPlaybackRequested, let position = pausedLivePosition, position < range.start {
            pausedLivePosition = range.start
            item.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), completionHandler: nil)
            if liveRecorder != nil {
                liveBuffer.notice = "The paused position expired. Resume from the oldest retained content."
            }
        }
    }

    func seekLive(to position: Double) {
        guard canSeekLive, let item = player.currentItem, let range = liveSeekableRange(for: item),
              let position = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end) else { return }
        let targetDur = effectiveLiveTargetDuration(for: range)
        let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                              targetDuration: targetDur) ?? range.end
        explicitlyRewound = position < livePosition - 1
        let playing = isPlaybackRequested
        if !playing { pausedLivePosition = position }
        progressWatchdog.reset()
        item.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
                  toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600), completionHandler: nil)
        livePlayhead = position
    }

    func seekLive(by seconds: Double) { seekLive(to: livePlayhead + seconds) }

    func goLive() {
        guard canSeekLive, let item = player.currentItem, let range = liveSeekableRange(for: item) else { return }
        let targetDur = effectiveLiveTargetDuration(for: range)
        guard let position = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                                 targetDuration: targetDur) else { return }
        isPlaybackRequested = true
        pausedLivePosition = nil
        seekLive(to: position)
        player.play()
        liveBehindSeconds = 0
        explicitlyRewound = false
    }

    public func seek(to seconds: Double) {
        guard let item = player.currentItem,
              let target = PlaybackPolicy.vodSeekPosition(seconds, duration: vodDuration) else { return }
        let session = sessionGeneration
        let generation = itemGeneration
        vodSeekGeneration &+= 1
        let seekGeneration = vodSeekGeneration
        vodCurrentTime = target
        lastVODPosition = target
        progressWatchdog.reset()
        item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard finished, let self, let item,
                      self.isCurrent(item, session: session, generation: generation),
                      self.vodSeekGeneration == seekGeneration else { return }
                self.lastVODPosition = target
                self.persistVODWatchProgress(force: true)
            }
        }
    }

    public func seekRelative(_ deltaSeconds: Double) {
        seek(to: vodCurrentTime + deltaSeconds)
    }

    public func updateMediaTracks(for item: AVPlayerItem) {
        mediaTracksTask?.cancel()
        let session = sessionGeneration
        let generation = itemGeneration
        let asset = item.asset
        mediaTracksTask = Task { [weak self, weak item] in
            async let audio = try? asset.loadMediaSelectionGroup(for: .audible)
            async let subtitles = try? asset.loadMediaSelectionGroup(for: .legible)
            let groups = await (audio, subtitles)
            guard !Task.isCancelled, let self, let item,
                  self.isCurrent(item, session: session, generation: generation) else { return }
            self.audioSelectionGroup = groups.0
            self.subtitleSelectionGroup = groups.1
            if !self.appliedPreferredTracksForItem {
                self.appliedPreferredTracksForItem = true
                self.applyPreferredTrackLanguages(for: item)
            }
            self.applyMediaTracks(for: item)
        }
    }

    private func resetMediaTracks() {
        mediaTracksTask?.cancel()
        mediaTracksTask = nil
        audioSelectionGroup = nil
        subtitleSelectionGroup = nil
        audioOptionMap.removeAll()
        subtitleOptionMap.removeAll()
        appliedPreferredTracksForItem = false
        availableAudioTracks = []
        selectedAudioTrackID = nil
        availableSubtitles = []
        selectedSubtitleID = nil
    }

    private static func trackCharacteristics(for option: AVMediaSelectionOption) -> [String] {
        var tags: [String] = []
        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { tags.append("forced") }
        if option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) { tags.append("sdh") }
        if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) { tags.append("cc") }
        if option.hasMediaCharacteristic(.describesVideoForAccessibility) { tags.append("ad") }
        return tags
    }

    private func applyPreferredTrackLanguages(for item: AVPlayerItem) {
        if let audioGroup = audioSelectionGroup, let prefAudio = settings.preferredAudioLanguage {
            let descriptors = audioGroup.options.enumerated().map { idx, option in
                MediaTrackMatcher.TrackDescriptor(
                    index: idx,
                    displayName: option.displayName,
                    languageTag: option.extendedLanguageTag ?? option.locale?.identifier,
                    characteristics: Self.trackCharacteristics(for: option),
                    isForced: false
                )
            }
            if let matchIdx = MediaTrackMatcher.preferredTrackIndex(in: descriptors, preferredLanguage: prefAudio),
               matchIdx < audioGroup.options.count {
                item.select(audioGroup.options[matchIdx], in: audioGroup)
            }
        }

        if let subGroup = subtitleSelectionGroup, let prefSub = settings.preferredSubtitleLanguage {
            if MediaTrackMatcher.normalizedLanguageTag(prefSub) == "off" {
                item.select(nil, in: subGroup)
            } else {
                let descriptors = subGroup.options.enumerated().map { idx, option in
                    MediaTrackMatcher.TrackDescriptor(
                        index: idx,
                        displayName: option.displayName,
                        languageTag: option.extendedLanguageTag ?? option.locale?.identifier,
                        characteristics: Self.trackCharacteristics(for: option),
                        isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                    )
                }
                if let matchIdx = MediaTrackMatcher.preferredTrackIndex(in: descriptors, preferredLanguage: prefSub),
                   matchIdx < subGroup.options.count {
                    item.select(subGroup.options[matchIdx], in: subGroup)
                }
            }
        }
    }

    private func applyMediaTracks(for item: AVPlayerItem) {
        selectedAudioTrackID = nil
        selectedSubtitleID = nil
        audioOptionMap.removeAll()
        subtitleOptionMap.removeAll()

        // Audio tracks (collision-free IDs incorporating track index & characteristics)
        if let audioGroup = audioSelectionGroup {
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: audioGroup)
            var audioTracks: [MediaTrackOption] = []
            audioTracks.reserveCapacity(audioGroup.options.count)
            for (idx, option) in audioGroup.options.enumerated() {
                let langTag = option.extendedLanguageTag ?? option.locale?.identifier
                let chars = Self.trackCharacteristics(for: option)
                let id = MediaTrackMatcher.makeTrackID(
                    index: idx,
                    displayName: option.displayName,
                    languageTag: langTag,
                    characteristics: chars
                )
                audioOptionMap[id] = option
                let isSel = (currentSelected == option)
                audioTracks.append(MediaTrackOption(
                    id: id,
                    displayName: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.localizedString(forIdentifier: option.locale?.identifier ?? ""),
                    isSelected: isSel
                ))
                if isSel {
                    self.selectedAudioTrackID = id
                }
            }
            self.availableAudioTracks = audioTracks
        } else {
            self.availableAudioTracks = []
            self.selectedAudioTrackID = nil
        }

        // Subtitles
        if let subGroup = subtitleSelectionGroup {
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: subGroup)
            var subTracks: [MediaTrackOption] = []
            subTracks.reserveCapacity(subGroup.options.count)
            for (idx, option) in subGroup.options.enumerated() {
                let langTag = option.extendedLanguageTag ?? option.locale?.identifier
                let chars = Self.trackCharacteristics(for: option)
                let id = MediaTrackMatcher.makeTrackID(
                    index: idx,
                    displayName: option.displayName,
                    languageTag: langTag,
                    characteristics: chars
                )
                subtitleOptionMap[id] = option
                let isSel = (currentSelected == option)
                subTracks.append(MediaTrackOption(
                    id: id,
                    displayName: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.localizedString(forIdentifier: option.locale?.identifier ?? ""),
                    isSelected: isSel
                ))
                if isSel {
                    self.selectedSubtitleID = id
                }
            }
            self.availableSubtitles = subTracks
        } else {
            self.availableSubtitles = []
            self.selectedSubtitleID = nil
        }
    }

    public func selectAudioTrack(id: String) {
        guard let item = player.currentItem,
              let audioGroup = audioSelectionGroup,
              let option = audioOptionMap[id] else { return }
        item.select(option, in: audioGroup)
        selectedAudioTrackID = id
        if let langTag = MediaTrackMatcher.normalizedLanguageTag(option.extendedLanguageTag ?? option.locale?.identifier) {
            settings.preferredAudioLanguage = langTag
        }
        applyMediaTracks(for: item)
    }

    public func selectSubtitle(id: String?) {
        guard let item = player.currentItem,
              let subGroup = subtitleSelectionGroup else { return }
        if let id, let option = subtitleOptionMap[id] {
            item.select(option, in: subGroup)
            selectedSubtitleID = id
            if let langTag = MediaTrackMatcher.normalizedLanguageTag(option.extendedLanguageTag ?? option.locale?.identifier) {
                settings.preferredSubtitleLanguage = langTag
            }
            applyMediaTracks(for: item)
        } else {
            item.select(nil, in: subGroup)
            selectedSubtitleID = nil
            settings.preferredSubtitleLanguage = "off"
            applyMediaTracks(for: item)
        }
    }

    private func stopTelemetryMonitoring() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }
}
