import Foundation
import AVFoundation
import AVKit
import Combine
import MediaPlayer

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

@MainActor
public final class PlaybackManager: ObservableObject {
    public static let shared = PlaybackManager()
    private static var hasCleanedLiveBuffers = false

    @Published public private(set) var player: AVPlayer
    @Published public private(set) var currentStream: LiveStream?
    @Published public private(set) var currentVOD: VODStream?
    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var isPlaybackRequested = false
    @Published public private(set) var telemetry: StreamTelemetry = StreamTelemetry()
    @Published public var aspectRatio: VideoAspectRatio = .fit
    @Published public var settings: PlayerSettings = PlayerSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }
    @Published public var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    @Published public private(set) var vodCurrentTime: Double = 0
    @Published public private(set) var vodDuration: Double = 0
    @Published public private(set) var availableAudioTracks: [MediaTrackOption] = []
    @Published public private(set) var selectedAudioTrackID: String?
    @Published public private(set) var availableSubtitles: [MediaTrackOption] = []
    @Published public private(set) var selectedSubtitleID: String?
    @Published public var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    @Published private(set) var liveBuffer = LiveTimeshiftSnapshot()
    @Published private(set) var liveBufferUnavailable: String?
    @Published private(set) var liveBehindSeconds: Double = 0
    @Published private(set) var liveSeekStart: Double = 0
    @Published private(set) var liveSeekEnd: Double = 0
    @Published private(set) var livePlayhead: Double = 0
    private var liveRecorder: LiveTimeshiftRecorder?
    private var liveServer: LiveTimeshiftServer?
    private var liveCaptureTask: Task<Void, Never>?
    private var pausedLivePosition: Double?
    private var pendingLiveRecordedPosition: Double?
    private var pendingLiveDate: Date?
    private var explicitlyRewound = false
    private var liveJumpInProgress = false
    private var originalLiveURL: URL?
    private var codecFallback = LiveTimeshiftCodecFallback()

    var canSeekLive: Bool { liveRecorder != nil && liveBuffer.canRewind && liveSeekEnd > liveSeekStart }
    var shouldShowGoLive: Bool { canSeekLive && (liveBehindSeconds > 15 || ((!isPlaybackRequested || explicitlyRewound) && liveBehindSeconds > 1)) }

    // Active playlist for fast zapping
    @Published public private(set) var activePlaylist: [LiveStream] = []
    @Published public private(set) var activeIndex: Int = 0

    private var itemObservers: Set<AnyCancellable> = []
    private var accountObserver: AnyCancellable?
    private var nowPlayingObserver: AnyCancellable?
    private var telemetryTimer: Timer?
    private var stallCount: Int = 0
    private var recovery = PlaybackRecoveryPolicy(maxAttempts: nil, maxDelay: 15.0)
    private var quality = QualityStepDownPolicy()
    /// The provider URL of what is playing. With live rewind on, AVPlayer reads a local
    /// copy instead, so this is the URL to hand to another player app.
    @Published public private(set) var providerURL: URL?
    private var sessionGeneration: UInt64 = 0
    private var itemGeneration: UInt64 = 0
    private var currentPlaybackURL: URL?
    private var pendingResumePosition: Double?
    private var resumeSeekInProgress = false
    private var lastVODPosition: Double = 0
    private var currentFormat: StreamFormatPreference = .hls
    private var watchdogWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var watchdogGeneration: UInt64 = 0
    private var retryGeneration: UInt64 = 0

    public init() {
        self.player = AVPlayer()
        self.player.automaticallyWaitsToMinimizeStalling = true
        if !Self.hasCleanedLiveBuffers {
            LiveTimeshiftRecorder.removeStaleSessions()
            Self.hasCleanedLiveBuffers = true
        }
        setupAudioSession()
        setupNowPlaying()
        accountObserver = AccountStore.shared.$currentProfile
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.stop() }
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure the playback audio session.")
        }
    }

    /// Shows the channel or title on the Lock Screen and in Control Center, and
    /// handles the play, pause, and next or previous channel commands there.
    private func setupNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
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
                let info = MPNowPlayingInfoCenter.default()
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
                self.synchronizeTransport(for: item, session: session, generation: generation)
            }
            .store(in: &itemObservers)
    }

    private func synchronizeTransport(for item: AVPlayerItem, session: UInt64, generation: UInt64) {
        let status = player.timeControlStatus
        let requestsPlayback = player.rate != 0 || status != .paused
        if !requestsPlayback {
            guard retryWorkItem == nil else { return }
            if item.status == .failed, isPlaybackRequested {
                handlePlaybackFailure(classifyPlaybackFailure(item.error, item: item),
                                      item: item, session: session, generation: generation)
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
            recovery.recordPlaying(at: ProcessInfo.processInfo.systemUptime)
        case .paused, .waitingToPlayAtSpecifiedRate:
            recovery.recordInterruption()
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
        beginPlaybackSession()

        if let playlist {
            setPlaylist(playlist, startingWith: stream)
        } else if activePlaylist.isEmpty {
            self.activePlaylist = [stream]
            self.activeIndex = 0
        }

        self.currentStream = stream
        self.currentVOD = nil
        self.playbackState = .loading
        self.stallCount = 0
        self.currentFormat = .hls
        // For live TV, a lower quality that keeps up beats a better picture that stalls.
        self.quality = QualityStepDownPolicy(stallsToStepDown: 1)

        // Record in history
        FavoritesStore.shared.addRecent(channelID: stream.id)

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
    private func startLive(url: URL) {
        providerURL = url
        guard !url.isFileURL else {
            prepareAndPlay(url: url)
            return
        }
        if settings.preferredFormat == .ts, let relayURL = TransportStreamRelayPolicy.relayURL(for: url) {
            startRelayedLivePlayback(relayURL: relayURL, fallbackURL: url)
        } else if settings.liveRewind {
            startBufferedLivePlayback(url: url)
        } else {
            prepareAndPlay(url: url)
        }
    }

    private func startRelayedLivePlayback(relayURL: URL, fallbackURL: URL) {
        // Used by the codec fallback when AVPlayer cannot decode the relayed segments.
        originalLiveURL = fallbackURL
        let session = sessionGeneration
        liveCaptureTask = Task { [weak self] in
            guard let self else { return }
            var capture: Task<Void, Never>?
            defer { capture?.cancel() }
            do {
                let recorder = try LiveTimeshiftRecorder()
                self.liveRecorder = recorder
                let server = LiveTimeshiftServer(recorder: recorder)
                self.liveServer = server
                capture = Task { await recorder.captureTransportStream(relayURL) }
                var ready = false
                let deadline = Date().addingTimeInterval(5)
                while !Task.isCancelled, self.sessionGeneration == session {
                    if let failure = await recorder.transportStreamFailure() { throw failure }
                    let snapshot = await recorder.snapshot()
                    guard !Task.isCancelled, self.liveRecorder === recorder else { return }
                    self.liveBuffer = snapshot
                    // Start as soon as we have at least 1 segment so playback begins fast.
                    if !ready, snapshot.duration > 0 {
                        let localURL = try await server.start()
                        guard !Task.isCancelled, self.liveRecorder === recorder else { server.stop(); return }
                        ready = true
                        relayLog.info("relay ready with \(snapshot.duration, privacy: .public)s buffered")
                        self.prepareAndPlay(url: localURL)
                    }
                    if !ready, Date() > deadline { throw LiveTimeshiftError.startupTimeout }
                    try await Task.sleep(nanoseconds: ready ? 1_000_000_000 : 250_000_000)
                }
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == session else { return }
                capture?.cancel()
                capture = nil
                relayLog.error("relay failed, playing HLS: \(String(describing: error), privacy: .public)")
                let isTimeout = (error as? LiveTimeshiftError) == .startupTimeout
                let reason = isTimeout ? nil : ((error as? LiveTimeshiftError)?.errorDescription ?? "The MPEG-TS relay could not read this channel.")
                // Let the relay close its provider connection first: many accounts allow only one.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, self.sessionGeneration == session else { return }
                // This cancels the current task, so play the fallback right after it.
                self.stopLiveBuffer()
                self.liveBufferUnavailable = reason
                self.prepareAndPlay(url: fallbackURL)
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
        beginPlaybackSession()

        self.currentVOD = vod
        self.quality = QualityStepDownPolicy(stallsToStepDown: 2)
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0

        guard let url = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension) else {
            failPlayback(with: "Invalid movie URL.")
            return
        }

        providerURL = url
        prepareAndPlay(url: url)
    }

    public func playEpisode(episode: SeriesEpisode, seriesName: String) {
        beginPlaybackSession()

        let titleFormatted: String
        if episode.title.hasPrefix("Episode") || episode.title.hasPrefix("E") {
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
        self.quality = QualityStepDownPolicy(stallsToStepDown: 2)
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0

        guard let url = AccountStore.shared.client.seriesStreamURL(streamID: episode.id, containerExtension: episode.containerExtension) else {
            failPlayback(with: "Invalid episode URL.")
            return
        }

        providerURL = url
        prepareAndPlay(url: url)
    }

    private func beginPlaybackSession() {
        stopLiveBuffer()
        originalLiveURL = nil
        codecFallback = LiveTimeshiftCodecFallback()
        sessionGeneration &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
        stopTelemetryMonitoring()
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        quality.reset()
        providerURL = nil
        isPlaybackRequested = true
        currentPlaybackURL = nil
        pendingResumePosition = nil
        resumeSeekInProgress = false
        lastVODPosition = 0
        vodCurrentTime = 0
        vodDuration = 0
        availableAudioTracks = []
        selectedAudioTrackID = nil
        availableSubtitles = []
        selectedSubtitleID = nil
        telemetry = StreamTelemetry()
    }

    private func startBufferedLivePlayback(url: URL) {
        originalLiveURL = url
        let session = sessionGeneration
        liveCaptureTask = Task { [weak self] in
            guard let self else { return }
            var ready = false
            do {
                let recorder = try LiveTimeshiftRecorder()
                self.liveRecorder = recorder
                let server = LiveTimeshiftServer(recorder: recorder)
                self.liveServer = server
                var pollDelay: Double = 1
                var failures = 0
                // Past this, play the provider directly instead of making people wait.
                let deadline = Date().addingTimeInterval(5)
                while !Task.isCancelled, self.sessionGeneration == session {
                    do {
                        if ready {
                            pollDelay = try await recorder.capture(url)
                        } else {
                            pollDelay = try await recorder.capture(url, timeout: deadline.timeIntervalSinceNow)
                        }
                        failures = 0
                        let snapshot = await recorder.snapshot()
                        guard !Task.isCancelled, self.liveRecorder === recorder else { return }
                        self.liveBuffer = snapshot
                        if !ready, snapshot.duration > 0 {
                            let localURL = try await server.start()
                            guard !Task.isCancelled, self.liveRecorder === recorder else { server.stop(); return }
                            ready = true
                            self.prepareAndPlay(url: localURL)
                        }
                    } catch {
                        if Task.isCancelled { throw error }
                        if let failure = error as? LiveTimeshiftError {
                            guard case .network(let status) = failure, status == 408 || status == 429 || status >= 500 else { throw error }
                        }
                        failures += 1
                        if failures >= 3 { throw error }
                        self.liveBuffer.notice = "The provider connection was interrupted. Capture is retrying."
                        pollDelay = 2
                    }
                    if !ready, Date() > deadline { throw LiveTimeshiftError.startupTimeout }
                    let delay = ready ? pollDelay : min(pollDelay, 1)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == session else { return }
                let isTimeout = (error as? LiveTimeshiftError) == .startupTimeout
                let reason = isTimeout ? nil : ((error as? LiveTimeshiftError)?.errorDescription ?? "The live buffer could not connect to this provider.")
                self.stopLiveBuffer()
                self.liveBufferUnavailable = reason
                // Failed recorder requests are cancelled before AVPlayer connects directly.
                self.prepareAndPlay(url: url)
            }
        }
    }

    private func stopLiveBuffer() {
        liveCaptureTask?.cancel()
        liveCaptureTask = nil
        liveServer?.stop()
        liveServer = nil
        let recorder = liveRecorder
        liveRecorder = nil
        if let recorder { Task { await recorder.stop() } }
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
    }

    func prepareAndPlay(url: URL, resumePosition: Double? = nil) {
        cancelWatchdog()
        cancelRetry()
        player.currentItem?.cancelPendingSeeks()
        itemObservers.removeAll()
        itemGeneration &+= 1
        let session = sessionGeneration
        let generation = itemGeneration
        currentPlaybackURL = url
        pendingResumePosition = resumePosition
        resumeSeekInProgress = false
        playbackState = .loading
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "IPTVSmartersPro/1.1.1"
                ]
            ]
        )
        let playerItem = AVPlayerItem(asset: asset)

        HLSBufferEngine.shared.configurePlayerItem(
            playerItem,
            with: settings.bufferProfile,
            hardwareAccelerated: settings.hardwareAcceleration
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
        // Before any media arrives, wait longer: some providers take about 40 seconds to
        // deliver the first segment of a channel nobody is watching, and a retry starts that
        // wait again. After media has played, a 20 second stall is a real failure.
        let hasMedia = playerItem.status == .readyToPlay && !playerItem.loadedTimeRanges.isEmpty
        DispatchQueue.main.asyncAfter(deadline: .now() + (hasMedia ? 20.0 : 45.0), execute: workItem)
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
                self.stepDownQualityAfterStall(playerItem)
                self.playbackState = .buffering
                self.startWatchdog(for: playerItem, session: session, generation: generation)
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] _ in
                guard let self, let playerItem,
                      self.isCurrent(playerItem, session: session, generation: generation) else { return }
                self.isPlaybackRequested = false
                self.cancelWatchdog()
                self.cancelRetry()
                self.recovery.recordInterruption()
                self.playbackState = .paused
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
        if liveRecorder != nil, let range = liveSeekableRange(for: item) {
            let restored: Double
            if let date = pendingLiveDate, let currentDate = item.currentDate() {
                restored = CMTimeGetSeconds(item.currentTime()) + date.timeIntervalSince(currentDate)
            } else if let anchor = pendingLiveRecordedPosition {
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
                self.synchronizeTransport(for: item, session: session, generation: generation)
            }
        }
    }

    private func classifyPlaybackFailure(_ error: Error?, item: AVPlayerItem) -> PlaybackFailure {
        if let networkFailure = PlaybackPolicy.networkFailure(
            for: error,
            httpStatus: item.errorLog()?.events.last?.errorStatusCode
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
        if let url = originalLiveURL,
           codecFallback.consume(for: failure, recording: liveRecorder != nil) {
            fallbackToOriginalLivePlayback(url: url)
            return
        }
        cancelWatchdog()
        let resumePosition = currentPlaybackResumePosition()
        guard let delay = recovery.nextRetryDelay(for: failure), let url = currentPlaybackURL else {
            failPlayback(with: failure.message)
            return
        }
        playbackState = .buffering
        let ticket = retryGeneration
        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item,
                  self.isCurrent(item, session: session, generation: generation),
                  self.isPlaybackRequested, self.retryGeneration == ticket else { return }
            self.retryWorkItem = nil
            self.prepareAndPlay(url: url, resumePosition: resumePosition)
        }
        retryWorkItem = workItem
        player.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func fallbackToOriginalLivePlayback(url: URL) {
        let recorder = liveRecorder
        let session = sessionGeneration
        cancelWatchdog()
        cancelRetry()
        itemGeneration &+= 1
        let generation = itemGeneration
        itemObservers.removeAll()
        player.pause()
        stopLiveBuffer()
        currentPlaybackURL = url
        recovery.reset()
        liveBufferUnavailable = "This device could not decode the recorded variant. Playing the original stream directly without rewind."
        playbackState = isPlaybackRequested ? .loading : .paused
        Task { [weak self] in
            if let recorder { await recorder.stop() }
            guard let self, self.sessionGeneration == session, self.itemGeneration == generation else { return }
            self.prepareAndPlay(url: url)
            if !self.isPlaybackRequested { self.playbackState = .paused }
        }
    }

    private func failPlayback(with message: String) {
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.recordInterruption()
        player.pause()
        playbackState = .failed(message)
    }

    private func currentPlaybackResumePosition() -> Double? {
        if liveRecorder != nil, let item = player.currentItem {
            let position = pausedLivePosition ?? CMTimeGetSeconds(item.currentTime())
            let itemPosition = CMTimeGetSeconds(item.currentTime())
            pendingLiveDate = position.isFinite && itemPosition.isFinite
                ? item.currentDate()?.addingTimeInterval(position - itemPosition) : nil
            if let range = liveSeekableRange(for: item), position.isFinite {
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
        if liveRecorder != nil, currentPlaybackURL == nil {
            isPlaybackRequested = true
            playbackState = .loading
            return
        }
        let resumePosition = currentPlaybackResumePosition()
        let url = currentPlaybackURL
        if liveRecorder == nil { sessionGeneration &+= 1 }
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
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
        if isPlaybackRequested {
            if liveRecorder != nil { pausedLivePosition = CMTimeGetSeconds(player.currentTime()) }
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
                if liveRecorder != nil, let position = pausedLivePosition,
                   let range = liveSeekableRange(for: item) {
                    pendingResumePosition = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end)
                    let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                                          targetDuration: liveBuffer.targetDuration) ?? range.end
                    explicitlyRewound = position < livePosition - 1
                    pausedLivePosition = nil
                }
                resumePlayback(for: item, session: sessionGeneration, generation: itemGeneration)
            }
        }
    }

    private func pausePlaybackIntent() {
        if liveRecorder != nil, pausedLivePosition == nil { pausedLivePosition = CMTimeGetSeconds(player.currentTime()) }
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.recordInterruption()
        if case .failed = playbackState { return }
        playbackState = .paused
    }

    /// After repeated stalls, caps the peak bitrate so AVPlayer switches to a lower variant.
    /// Streams with one variant (most Xtream channels) have nothing lower to switch to.
    private func stepDownQualityAfterStall(_ item: AVPlayerItem) {
        let indicated = item.accessLog()?.events.last?.indicatedBitrate ?? 0
        guard let cap = quality.recordStall(at: ProcessInfo.processInfo.systemUptime, currentBitrate: indicated) else { return }
        item.preferredPeakBitRate = cap
    }

    public func stop() {
        stopLiveBuffer()
        originalLiveURL = nil
        codecFallback = LiveTimeshiftCodecFallback()
        sessionGeneration &+= 1
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        quality.reset()
        providerURL = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.removeAll()
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
                if self.isPlaybackRequested, self.player.timeControlStatus == .playing {
                    self.recovery.recordPlaying(at: ProcessInfo.processInfo.systemUptime)
                    if self.currentVOD != nil,
                       let position = PlaybackPolicy.vodResumePosition(CMTimeGetSeconds(currentItem.currentTime())) {
                        self.lastVODPosition = position
                    }
                } else {
                    self.recovery.recordInterruption()
                }
                if self.currentVOD != nil {
                    let currentSeconds = CMTimeGetSeconds(currentItem.currentTime())
                    if currentSeconds.isFinite && !currentSeconds.isNaN {
                        self.vodCurrentTime = max(0, currentSeconds)
                    }
                    let durationSeconds = CMTimeGetSeconds(currentItem.duration)
                    if durationSeconds.isFinite && !durationSeconds.isNaN && durationSeconds > 0 {
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
                self.telemetry = t
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
        guard currentStream != nil, isPlaybackRequested, retryWorkItem == nil, pendingResumePosition == nil,
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
            relayLog.info("jumping \(range.end - current, privacy: .public)s ahead to live")
            liveJumpInProgress = true
            item.seek(to: CMTime(seconds: range.end, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor [weak self] in self?.liveJumpInProgress = false }
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

    private func updateLiveTimeline(for item: AVPlayerItem) {
        guard liveRecorder != nil, let range = liveSeekableRange(for: item) else { return }
        liveSeekStart = range.start
        liveSeekEnd = range.end
        let position = pausedLivePosition ?? CMTimeGetSeconds(item.currentTime())
        livePlayhead = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end) ?? range.start
        let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                              targetDuration: liveBuffer.targetDuration) ?? range.end
        liveBehindSeconds = max(0, livePosition - livePlayhead)
        if liveBehindSeconds <= 1 { explicitlyRewound = false }
        if !isPlaybackRequested, let position = pausedLivePosition, position < range.start {
            pausedLivePosition = range.start
            item.seek(to: CMTime(seconds: range.start, preferredTimescale: 600))
            liveBuffer.notice = "The paused position expired. Resume from the oldest retained content."
        }
    }

    func seekLive(to position: Double) {
        guard canSeekLive, let item = player.currentItem, let range = liveSeekableRange(for: item),
              let position = LiveTimeshiftSeekPolicy.clamp(position, start: range.start, end: range.end) else { return }
        let livePosition = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                              targetDuration: liveBuffer.targetDuration) ?? range.end
        explicitlyRewound = position < livePosition - 1
        let playing = isPlaybackRequested
        if !playing { pausedLivePosition = position }
        item.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
                  toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
        livePlayhead = position
    }

    func seekLive(by seconds: Double) { seekLive(to: livePlayhead + seconds) }

    func goLive() {
        guard canSeekLive, let item = player.currentItem, let range = liveSeekableRange(for: item),
              let position = LiveTimeshiftSeekPolicy.livePosition(start: range.start, end: range.end,
                                                               targetDuration: liveBuffer.targetDuration) else { return }
        isPlaybackRequested = true
        pausedLivePosition = nil
        seekLive(to: position)
        player.play()
        liveBehindSeconds = 0
        explicitlyRewound = false
    }

    public func seek(to seconds: Double) {
        guard let item = player.currentItem else { return }
        let target = max(0, min(seconds, vodDuration > 0 ? vodDuration : seconds))
        vodCurrentTime = target
        lastVODPosition = target
        item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastVODPosition = target
            }
        }
    }

    public func seekRelative(_ deltaSeconds: Double) {
        let target = max(0, vodCurrentTime + deltaSeconds)
        seek(to: target)
    }

    public func updateMediaTracks(for item: AVPlayerItem) {
        let asset = item.asset

        // Audio tracks
        if let audioGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: audioGroup)
            var audioTracks: [MediaTrackOption] = []
            for option in audioGroup.options {
                let id = option.displayName + "_" + (option.extendedLanguageTag ?? option.locale?.identifier ?? "")
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
        if let subGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: subGroup)
            var subTracks: [MediaTrackOption] = []
            for option in subGroup.options {
                let id = option.displayName + "_" + (option.extendedLanguageTag ?? option.locale?.identifier ?? "")
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
              let audioGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
        for option in audioGroup.options {
            let optionID = option.displayName + "_" + (option.extendedLanguageTag ?? option.locale?.identifier ?? "")
            if optionID == id {
                item.select(option, in: audioGroup)
                selectedAudioTrackID = id
                updateMediaTracks(for: item)
                break
            }
        }
    }

    public func selectSubtitle(id: String?) {
        guard let item = player.currentItem,
              let subGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if let id {
            for option in subGroup.options {
                let optionID = option.displayName + "_" + (option.extendedLanguageTag ?? option.locale?.identifier ?? "")
                if optionID == id {
                    item.select(option, in: subGroup)
                    selectedSubtitleID = id
                    updateMediaTracks(for: item)
                    break
                }
            }
        } else {
            item.select(nil, in: subGroup)
            selectedSubtitleID = nil
            updateMediaTracks(for: item)
        }
    }

    private func stopTelemetryMonitoring() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }
}
