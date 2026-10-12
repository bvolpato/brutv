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

    private var timeObserverToken: Any?
    private var itemObservers: Set<AnyCancellable> = []
    private var telemetryTimer: Timer?
    private var stallCount: Int = 0
    private var retryAttempts: Int = 0
    private let maxRetryAttempts = 3
    private var currentFormat: StreamFormatPreference = .hls

    public init() {
        self.player = AVPlayer()
        self.player.automaticallyWaitsToMinimizeStalling = true
        setupAudioSession()
        setupPlayerObservers()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
        }
    }

    private func setupPlayerObservers() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .playing:
                    self.playbackState = .playing
                    self.retryAttempts = 0
                case .paused:
                    if case .failed = self.playbackState {
                        // Keep failed state
                    } else {
                        self.playbackState = .paused
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.playbackState = .buffering
                @unknown default:
                    break
                }
            }
            .store(in: &itemObservers)
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
        self.currentFormat = settings.preferredFormat

        // Record in history
        FavoritesStore.shared.addRecent(channelID: stream.id)

        startPlayback(for: stream, format: currentFormat)
    }

    private func startPlayback(for stream: LiveStream, format: StreamFormatPreference) {
        guard let url = AccountStore.shared.client.liveStreamURL(streamID: stream.id, format: format) else {
            self.playbackState = .failed("Invalid stream URL.")
            return
        }

        prepareAndPlay(url: url)
    }

    public func playVOD(vod: VODStream) {
        self.currentVOD = vod
        self.currentStream = nil
        self.playbackState = .loading
        self.stallCount = 0

        guard let url = AccountStore.shared.client.vodStreamURL(streamID: vod.id, containerExtension: vod.containerExtension) else {
            self.playbackState = .failed("Invalid movie URL.")
            return
        }

        prepareAndPlay(url: url)
    }

    private func prepareAndPlay(url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        // Apply state-of-the-art buffer tuning
        HLSBufferEngine.shared.configurePlayerItem(
            playerItem,
            with: settings.bufferProfile,
            hardwareAccelerated: settings.hardwareAcceleration
        )

        observePlayerItem(playerItem)
        player.replaceCurrentItem(with: playerItem)
        player.play()

        startTelemetryMonitoring()
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        itemObservers.removeAll()
        setupPlayerObservers()

        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.playbackState = .playing
                    self.player.play()
                case .failed:
                    self.handlePlaybackFailure(playerItem.error)
                default:
                    break
                }
            }
            .store(in: &itemObservers)

        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.stallCount += 1
                self.playbackState = .buffering
            }
            .store(in: &itemObservers)
    }

    private func handlePlaybackFailure(_ error: Error?) {
        print("Playback failed: \(String(describing: error))")

        // Format fallback: if HLS failed, try MPEG-TS
        if currentFormat == .hls, let stream = currentStream {
            print("Attempting fallback to MPEG-TS...")
            currentFormat = .ts
            startPlayback(for: stream, format: .ts)
            return
        }

        // Retry mechanism
        if retryAttempts < maxRetryAttempts, let stream = currentStream {
            retryAttempts += 1
            print("Retrying stream (attempt \(retryAttempts))...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.startPlayback(for: stream, format: self.currentFormat)
            }
            return
        }

        self.playbackState = .failed(error?.localizedDescription ?? "Stream failed to load.")
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
        if player.timeControlStatus == .playing {
            player.pause()
            playbackState = .paused
        } else {
            player.play()
            playbackState = .playing
        }
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStream = nil
        currentVOD = nil
        playbackState = .idle
        stopTelemetryMonitoring()
    }

    private func startTelemetryMonitoring() {
        stopTelemetryMonitoring()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let currentItem = self.player.currentItem else { return }
                var t = HLSBufferEngine.shared.extractTelemetry(from: currentItem, currentStallCount: self.stallCount)
                t.playbackRate = self.player.rate
                self.telemetry = t
            }
        }
    }

    private func stopTelemetryMonitoring() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }
}
