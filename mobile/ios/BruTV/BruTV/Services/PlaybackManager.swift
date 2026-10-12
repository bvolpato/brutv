import Foundation
import AVFoundation
import AVKit
import Combine

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case failed(String)
}

@MainActor
public final class PlaybackManager: ObservableObject {
    public static let shared = PlaybackManager()

    @Published public private(set) var player: AVPlayer
    @Published public private(set) var currentStream: LiveStream?
    @Published public private(set) var currentVOD: VODStream?
    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var isPlaybackRequested = false
    @Published public private(set) var telemetry: StreamTelemetry = StreamTelemetry()
    @Published public var aspectRatio: VideoAspectRatio = .fit
    @Published public var settings: PlayerSettings = PlayerSettings()
    @Published public var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    @Published public var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    // Active playlist for fast zapping
    @Published public private(set) var activePlaylist: [LiveStream] = []
    @Published public private(set) var activeIndex: Int = 0

    private var itemObservers: Set<AnyCancellable> = []
    private var telemetryTimer: Timer?
    private var stallCount: Int = 0
    private var recovery = PlaybackRecoveryPolicy()
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
        setupAudioSession()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure the playback audio session.")
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
            prepareAndPlay(url: url)
            return
        }

        guard let url = AccountStore.shared.client.liveStreamURL(streamID: stream.id, format: format) else {
            failPlayback(with: "Invalid stream URL.")
            return
        }

        prepareAndPlay(url: url)
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
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0

        guard let url = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension) else {
            failPlayback(with: "Invalid movie URL.")
            return
        }

        prepareAndPlay(url: url)
    }

    private func beginPlaybackSession() {
        sessionGeneration &+= 1
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        isPlaybackRequested = true
        currentPlaybackURL = nil
        pendingResumePosition = nil
        resumeSeekInProgress = false
        lastVODPosition = 0
        telemetry = StreamTelemetry()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: workItem)
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
        let seconds = PlaybackPolicy.vodResumePosition(position, duration: CMTimeGetSeconds(item.duration)) ?? 0
        resumeSeekInProgress = true
        player.play()
        startWatchdog(for: item, session: session, generation: generation)
        item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                      self.isCurrent(item, session: session, generation: generation) else { return }
                self.resumeSeekInProgress = false
                self.pendingResumePosition = nil
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
                if [AVError.Code.decoderNotFound.rawValue, AVError.Code.fileFormatNotRecognized.rawValue,
                    AVError.Code.operationNotSupportedForAsset.rawValue].contains(current.code) {
                    return .unsupported
                }
                if current.code == AVError.Code.mediaServicesWereReset.rawValue {
                    return .transient
                }
            }
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown
    }

    private func handlePlaybackFailure(_ failure: PlaybackFailure, item: AVPlayerItem, session: UInt64, generation: UInt64) {
        guard isCurrent(item, session: session, generation: generation), isPlaybackRequested, retryWorkItem == nil else { return }
        cancelWatchdog()
        let resumePosition = currentVODResumePosition()
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

    private func failPlayback(with message: String) {
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.recordInterruption()
        player.pause()
        playbackState = .failed(message)
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
        let resumePosition = currentVODResumePosition()
        let url = currentPlaybackURL
        sessionGeneration &+= 1
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
        isPlaybackRequested = true
        if let url {
            prepareAndPlay(url: url, resumePosition: resumePosition)
        } else if let stream = currentStream {
            startPlayback(for: stream, format: currentFormat)
        } else if let vod = currentVOD,
                  let url = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension) {
            prepareAndPlay(url: url, resumePosition: resumePosition)
        } else {
            failPlayback(with: "Invalid movie URL.")
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
                resumePlayback(for: item, session: sessionGeneration, generation: itemGeneration)
            }
        }
    }

    private func pausePlaybackIntent() {
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.recordInterruption()
        if case .failed = playbackState { return }
        playbackState = .paused
    }

    public func stop() {
        sessionGeneration &+= 1
        isPlaybackRequested = false
        cancelWatchdog()
        cancelRetry()
        recovery.reset()
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
                var t = HLSBufferEngine.shared.extractTelemetry(from: currentItem, currentStallCount: self.stallCount)
                t.playbackRate = self.player.rate
                t.isLive = self.currentVOD == nil
                self.telemetry = t
            }
        }
    }

    private func stopTelemetryMonitoring() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }
}
