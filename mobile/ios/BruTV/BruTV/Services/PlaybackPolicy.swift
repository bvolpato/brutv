import Foundation

enum PlaybackFailure: Equatable, Sendable {
    case transient
    case timedOut
    case unauthorized
    case notFound
    case unsupported
    case unknown

    var canRetry: Bool { self == .transient || self == .timedOut }

    var message: String {
        switch self {
        case .transient:
            return "The connection was interrupted. Try again when it improves."
        case .timedOut:
            return "The provider stopped sending data. Try another stream or retry later."
        case .unauthorized:
            return "The provider did not authorize playback. Check your account."
        case .notFound:
            return "This stream is no longer available from the provider."
        case .unsupported:
            return "This stream uses a format or protection this device cannot play."
        case .unknown:
            return "The stream could not be played. Try another stream or retry later."
        }
    }
}

struct PlaybackBufferRange: Sendable {
    let start: Double
    let duration: Double
}

enum PlaybackPolicy {
    static func bufferedDuration(at position: Double, ranges: [PlaybackBufferRange]) -> Double {
        guard position.isFinite, position >= 0 else { return 0 }
        let validRanges = ranges.filter {
            $0.start.isFinite && $0.duration.isFinite && $0.duration > 0 && ($0.start + $0.duration).isFinite
        }.sorted { $0.start < $1.start }

        var bufferedEnd: Double?
        for range in validRanges {
            let end = range.start + range.duration
            if let currentEnd = bufferedEnd {
                guard range.start <= currentEnd + 0.001 else { break }
                bufferedEnd = max(currentEnd, end)
            } else if range.start <= position, end > position {
                bufferedEnd = end
            }
        }
        return max(0, (bufferedEnd ?? position) - position)
    }

    static func vodResumePosition(_ position: Double, duration: Double? = nil) -> Double? {
        guard position.isFinite, position > 0 else { return nil }
        if let duration, duration.isFinite, duration > 0 {
            return min(position, max(0, duration - 0.1))
        }
        return position
    }

    static func vodSeekPosition(_ position: Double, duration: Double) -> Double? {
        guard position.isFinite else { return nil }
        return max(0, min(position, duration.isFinite && duration > 0 ? duration : position))
    }

    static func retriesAtEnd(isLive: Bool, url: URL?) -> Bool {
        isLive && url.map { !$0.isFileURL } == true
    }

    static func declaresBackgroundAudio(in infoDictionary: [String: Any]?) -> Bool {
        (infoDictionary?["UIBackgroundModes"] as? [String])?.contains("audio") == true
    }

    /// Maps an `AVPlayerItemErrorLogEvent` status code to an HTTP status if recent.
    /// Ignores stale error log entries older than `maxAge` seconds and translates
    /// CoreMedia HTTP status codes (`-12660` 403, `-12661` 503, `-12938` 404).
    static func recentHTTPStatus(
        errorStatusCode: Int?,
        eventDate: Date?,
        now: Date = Date(),
        maxAge: TimeInterval = 10
    ) -> Int? {
        guard let code = errorStatusCode else { return nil }
        if let eventDate, abs(now.timeIntervalSince(eventDate)) > maxAge {
            return nil
        }
        switch code {
        case 100...599: return code
        case -12660: return 403
        case -12661: return 503
        case -12938: return 404
        default: return nil
        }
    }

    static func networkFailure(for error: Error?, httpStatus: Int? = nil, localLiveRecording: Bool = false) -> PlaybackFailure? {
        if let status = httpStatus {
            switch status {
            case 401, 403: return .unauthorized
            case 410 where localLiveRecording: return .transient
            case 404, 410: return .notFound
            case 408, 429, 458, 500...599: return .transient
            case 400...499: return .unknown
            default: break
            }
        }

        var currentError = error as NSError?
        var transientFailure: PlaybackFailure?
        for _ in 0..<8 {
            guard let current = currentError else { break }
            if current.domain == NSURLErrorDomain {
                switch current.code {
                case URLError.Code.timedOut.rawValue:
                    transientFailure = .timedOut
                case URLError.Code.networkConnectionLost.rawValue,
                     URLError.Code.notConnectedToInternet.rawValue,
                     URLError.Code.cannotConnectToHost.rawValue,
                     URLError.Code.cannotFindHost.rawValue,
                     URLError.Code.dnsLookupFailed.rawValue:
                    transientFailure = .transient
                case URLError.Code.userAuthenticationRequired.rawValue,
                     URLError.Code.userCancelledAuthentication.rawValue:
                    return .unauthorized
                case URLError.Code.fileDoesNotExist.rawValue:
                    return .notFound
                case URLError.Code.badURL.rawValue, URLError.Code.unsupportedURL.rawValue:
                    return .unsupported
                default:
                    return .unknown
                }
            } else if current.domain == "CoreMediaErrorDomain" || current.domain == NSOSStatusErrorDomain {
                switch current.code {
                case -12660: return .unauthorized
                case -12661: transientFailure = .transient
                case -12938: return .notFound
                case -12889: transientFailure = .timedOut
                default: break
                }
            }
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return transientFailure
    }
}

struct PlaybackRecoveryPolicy {
    private(set) var attempts = 0
    private var healthySince: TimeInterval?
    private let maxAttempts: Int?
    private let healthyInterval: TimeInterval
    private let maxDelay: TimeInterval
    private let jitterFactor: Double
    private let randomUnit: @Sendable () -> Double

    init(
        maxAttempts: Int? = 2,
        healthyInterval: TimeInterval = 30,
        maxDelay: TimeInterval = 15.0,
        jitterFactor: Double = 0,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }
    ) {
        self.maxAttempts = maxAttempts
        self.healthyInterval = healthyInterval
        self.maxDelay = maxDelay
        self.jitterFactor = max(0, min(0.5, jitterFactor))
        self.randomUnit = randomUnit
    }

    mutating func reset() {
        attempts = 0
        healthySince = nil
    }

    mutating func recordPlaying(at time: TimeInterval) {
        guard time.isFinite else { return }
        guard let healthySince else {
            self.healthySince = time
            return
        }
        if time - healthySince >= healthyInterval {
            attempts = 0
            self.healthySince = time
        }
    }

    mutating func recordInterruption() {
        healthySince = nil
    }

    mutating func nextRetryDelay(for failure: PlaybackFailure) -> TimeInterval? {
        recordInterruption()
        guard failure.canRetry else { return nil }
        if let maxAttempts, attempts >= maxAttempts { return nil }
        attempts += 1
        // Exponential backoff: 1.5s, 3.0s, 6.0s, 12.0s, capped at maxDelay.
        let exponent = min(attempts - 1, 6)
        let base = min(maxDelay, 1.5 * pow(2.0, Double(exponent)))
        guard jitterFactor > 0 else { return base }
        let jittered = base * (1.0 + jitterFactor * max(-1, min(1, randomUnit())))
        return max(0.5, min(maxDelay, jittered))
    }
}

enum LiveTransportMode: Equatable, Hashable, Sendable {
    case tsRelay
    case bufferedHLS
    case directHLS

    var displayLabel: String {
        switch self {
        case .tsRelay: return "MPEG-TS Relay (.ts)"
        case .bufferedHLS: return "Buffered HLS (.m3u8)"
        case .directHLS: return "Direct HLS (.m3u8)"
        }
    }
}

/// Bounded in-memory LRU cache remembering the last confirmed working live transport
/// per canonical channel key, with optional TTL expiration.
struct LiveTransportMemory: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let mode: LiveTransportMode
        let recordedAt: TimeInterval
    }

    let maxEntries: Int
    let ttl: TimeInterval?

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(maxEntries: Int = 128, ttl: TimeInterval? = 3600) {
        self.maxEntries = max(1, maxEntries)
        self.ttl = ttl
    }

    var count: Int { entries.count }

    mutating func mode(
        for key: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> LiveTransportMode? {
        let canonicalKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalKey.isEmpty, let entry = entries[canonicalKey] else { return nil }
        if let ttl, now.isFinite, now - entry.recordedAt >= ttl {
            entries.removeValue(forKey: canonicalKey)
            order.removeAll { $0 == canonicalKey }
            return nil
        }
        order.removeAll { $0 == canonicalKey }
        order.append(canonicalKey)
        return entry.mode
    }

    mutating func remember(
        _ mode: LiveTransportMode,
        for key: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let canonicalKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalKey.isEmpty, now.isFinite else { return }
        pruneExpired(now: now)
        entries[canonicalKey] = Entry(mode: mode, recordedAt: now)
        order.removeAll { $0 == canonicalKey }
        order.append(canonicalKey)
        while entries.count > maxEntries, !order.isEmpty {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func pruneExpired(now: TimeInterval) {
        guard let ttl else { return }
        var remaining: [String] = []
        remaining.reserveCapacity(order.count)
        for key in order {
            if let entry = entries[key], now - entry.recordedAt < ttl {
                remaining.append(key)
            } else {
                entries.removeValue(forKey: key)
            }
        }
        order = remaining
    }
}

/// Coordinates bidirectional `.ts <-> .m3u8` transport fallback for live channels.
///
/// Prevents infinite retry loops on a broken transport (for example, a stalled `.ts` relay
/// or an Xtream `.m3u8` endpoint returning 404/timeouts) while resetting the tried set
/// after sustained healthy playback so later outages can fall back again.
struct LiveTransportFallbackPolicy: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case retryCurrent
        case switchTo(LiveTransportMode)
        case fail
    }

    static func resolvePreferences(
        preferredFormat: StreamFormatPreference,
        hasTSRelay: Bool,
        allowedOutputFormats: [String]?
    ) -> (preferredFormat: StreamFormatPreference, hasTSRelay: Bool) {
        let normalized = Set(
            (allowedOutputFormats ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normalized.isEmpty else {
            return (preferredFormat, hasTSRelay)
        }
        let allowsTS = normalized.contains("ts") || normalized.contains("mpegts")
        let allowsHLS = normalized.contains("m3u8") || normalized.contains("hls")
        if allowsHLS && !allowsTS {
            return (.hls, false)
        }
        if allowsTS && !allowsHLS && hasTSRelay {
            return (.ts, true)
        }
        return (preferredFormat, hasTSRelay)
    }

    let preferredFormat: StreamFormatPreference
    let hasTSRelay: Bool
    let liveRewind: Bool
    let maxFailuresBeforeSwitch: Int
    let stallsToFallback: Int
    let stallWindow: TimeInterval
    let healthyResetInterval: TimeInterval

    private(set) var currentMode: LiveTransportMode
    private(set) var triedModes: Set<LiveTransportMode>
    private(set) var consecutiveFailures: Int = 0
    private(set) var recentStallTimes: [TimeInterval] = []
    private var healthySince: TimeInterval?

    init(
        preferredFormat: StreamFormatPreference,
        hasTSRelay: Bool,
        liveRewind: Bool,
        rememberedMode: LiveTransportMode? = nil,
        maxFailuresBeforeSwitch: Int = 2,
        stallsToFallback: Int = 3,
        stallWindow: TimeInterval = 45,
        healthyResetInterval: TimeInterval = 60
    ) {
        self.preferredFormat = preferredFormat
        self.hasTSRelay = hasTSRelay
        self.liveRewind = liveRewind
        self.maxFailuresBeforeSwitch = max(1, maxFailuresBeforeSwitch)
        self.stallsToFallback = max(1, stallsToFallback)
        self.stallWindow = stallWindow
        self.healthyResetInterval = healthyResetInterval
        let defaultInitial: LiveTransportMode
        if preferredFormat == .ts, hasTSRelay {
            defaultInitial = .tsRelay
        } else if liveRewind {
            defaultInitial = .bufferedHLS
        } else {
            defaultInitial = .directHLS
        }
        let initial: LiveTransportMode
        if let rememberedMode {
            switch rememberedMode {
            case .tsRelay:
                initial = hasTSRelay ? .tsRelay : defaultInitial
            case .bufferedHLS:
                initial = liveRewind ? .bufferedHLS : .directHLS
            case .directHLS:
                initial = .directHLS
            }
        } else {
            initial = defaultInitial
        }
        self.currentMode = initial
        self.triedModes = [initial]
    }

    mutating func recordPlaying(at time: TimeInterval) {
        guard time.isFinite else { return }
        guard let healthySince else {
            self.healthySince = time
            return
        }
        if time - healthySince >= healthyResetInterval {
            consecutiveFailures = 0
            recentStallTimes.removeAll()
            triedModes = [currentMode]
            self.healthySince = time
        }
    }

    mutating func recordInterruption() {
        healthySince = nil
    }

    /// Records a playback stall. Returns a fallback transport when stalls exceed threshold.
    mutating func recordStall(at time: TimeInterval) -> LiveTransportMode? {
        guard time.isFinite else { return nil }
        healthySince = nil
        recentStallTimes = recentStallTimes.filter { time - $0 < stallWindow } + [time]
        guard recentStallTimes.count >= stallsToFallback else { return nil }
        return switchToNextMode(preferDirectHLS: false)
    }

    /// Called when local capture (`.tsRelay` or `.bufferedHLS`) fails at startup or exhausts
    /// its bounded capture retries.
    mutating func recordCaptureFailure(unsupported: Bool = false) -> LiveTransportMode? {
        healthySince = nil
        return switchToNextMode(preferDirectHLS: unsupported)
    }

    /// Called when AVPlayer fails or times out on the active transport.
    mutating func recordPlaybackFailure(_ failure: PlaybackFailure) -> Action {
        healthySince = nil
        switch failure {
        case .unsupported:
            // Codec/format failures should try native HLS from local capture or `.ts` from direct HLS.
            if let next = switchToNextMode(preferDirectHLS: currentMode != .directHLS) {
                return .switchTo(next)
            }
            return .fail
        case .notFound, .unauthorized:
            // Cross-format fallback handles providers where one format (.ts or .m3u8) rejects a channel
            // while the alternate format works.
            if let next = switchToCrossFormatMode() {
                return .switchTo(next)
            }
            return .fail
        case .transient, .timedOut:
            consecutiveFailures += 1
            if consecutiveFailures >= maxFailuresBeforeSwitch,
               let next = switchToNextMode(preferDirectHLS: currentMode == .tsRelay) {
                return .switchTo(next)
            }
            return .retryCurrent
        case .unknown:
            if let next = switchToNextMode(preferDirectHLS: currentMode != .directHLS) {
                return .switchTo(next)
            }
            return .fail
        }
    }

    private mutating func switchToCrossFormatMode() -> LiveTransportMode? {
        let candidate: LiveTransportMode?
        switch currentMode {
        case .tsRelay:
            candidate = triedModes.contains(.directHLS) ? nil : .directHLS
        case .bufferedHLS, .directHLS:
            candidate = (hasTSRelay && !triedModes.contains(.tsRelay)) ? .tsRelay : nil
        }
        guard let next = candidate else { return nil }
        commitSwitch(to: next)
        return next
    }

    private mutating func switchToNextMode(preferDirectHLS: Bool) -> LiveTransportMode? {
        let candidates: [LiveTransportMode]
        switch currentMode {
        case .tsRelay:
            candidates = [.directHLS]
        case .bufferedHLS:
            if preferDirectHLS || !hasTSRelay {
                candidates = hasTSRelay ? [.directHLS, .tsRelay] : [.directHLS]
            } else {
                candidates = [.tsRelay, .directHLS]
            }
        case .directHLS:
            candidates = hasTSRelay ? [.tsRelay] : []
        }
        guard let next = candidates.first(where: { !triedModes.contains($0) }) else { return nil }
        commitSwitch(to: next)
        return next
    }

    private mutating func commitSwitch(to mode: LiveTransportMode) {
        currentMode = mode
        triedModes.insert(mode)
        consecutiveFailures = 0
        recentStallTimes.removeAll()
        healthySince = nil
    }
}

/// Detects silent decoder freezes where AVPlayer reports `.playing` with rate > 0 while
/// `item.currentTime()` stops advancing (black screen / frozen picture).
struct PlaybackProgressWatchdog: Equatable, Sendable {
    let stallThreshold: TimeInterval
    let minimumAdvance: Double

    private var lastMediaTime: Double?
    private var lastProgressUptime: TimeInterval?
    private(set) var isProgressing = false

    init(isLive: Bool, minimumAdvance: Double = 0.05) {
        self.stallThreshold = isLive ? 10.0 : 15.0
        self.minimumAdvance = minimumAdvance
    }

    init(stallThreshold: TimeInterval, minimumAdvance: Double = 0.05) {
        self.stallThreshold = stallThreshold
        self.minimumAdvance = minimumAdvance
    }

    mutating func reset() {
        lastMediaTime = nil
        lastProgressUptime = nil
        isProgressing = false
    }

    func frozenDuration(at uptime: TimeInterval) -> TimeInterval {
        guard !isProgressing, uptime.isFinite, let lastProgressUptime else { return 0 }
        return max(0, uptime - lastProgressUptime)
    }

    /// Evaluates playhead advancement at `uptime`.
    /// Returns `true` when playback has remained frozen for at least `stallThreshold` seconds.
    mutating func evaluate(
        mediaTime: Double,
        at uptime: TimeInterval,
        isPlaying: Bool
    ) -> Bool {
        guard isPlaying, uptime.isFinite else {
            reset()
            return false
        }
        guard mediaTime.isFinite else {
            isProgressing = false
            if lastProgressUptime == nil {
                lastProgressUptime = uptime
                return false
            }
            return uptime - (lastProgressUptime ?? uptime) >= stallThreshold
        }
        guard let previous = lastMediaTime, let lastAdvance = lastProgressUptime else {
            lastMediaTime = mediaTime
            lastProgressUptime = uptime
            isProgressing = false
            return false
        }
        if abs(mediaTime - previous) >= minimumAdvance {
            lastMediaTime = mediaTime
            lastProgressUptime = uptime
            isProgressing = true
            return false
        }
        isProgressing = false
        return uptime - lastAdvance >= stallThreshold
    }
}

/// Lowers the quality cap when a stream keeps stalling.
///
/// AVPlayer already adapts between HLS variants, but it reacts slowly to a provider that
/// cannot keep up. After `stallsToStepDown` stalls inside `window` seconds, cap the peak
/// bitrate below the variant that is playing, so AVPlayer moves to a lower variant.
struct QualityStepDownPolicy {
    private(set) var peakBitRate: Double = 0
    private var stalls: [TimeInterval] = []
    let stallsToStepDown: Int
    let window: TimeInterval
    let floor: Double

    init(stallsToStepDown: Int = 2, window: TimeInterval = 60, floor: Double = 350_000) {
        self.stallsToStepDown = stallsToStepDown
        self.window = window
        self.floor = floor
    }

    mutating func reset() {
        peakBitRate = 0
        stalls.removeAll()
    }

    /// Records a stall. Returns a new peak bitrate cap when quality must step down.
    /// `currentBitrate` is the bitrate of the variant that is playing, in bits per second.
    mutating func recordStall(at time: TimeInterval, currentBitrate: Double) -> Double? {
        guard time.isFinite else { return nil }
        stalls = stalls.filter { time - $0 < window } + [time]
        guard stalls.count >= stallsToStepDown, currentBitrate.isFinite, currentBitrate > 0 else { return nil }
        let reference = peakBitRate > 0 ? min(peakBitRate, currentBitrate) : currentBitrate
        let next = max(floor, reference * 0.7)
        guard next < reference, peakBitRate == 0 || next < peakBitRate else { return nil }
        peakBitRate = next
        stalls.removeAll()
        return next
    }
}

/// Keeps live TV close to live when the provider is slow.
///
/// AVPlayer waits "to minimize stalls" until it predicts that playback can continue. When
/// the provider sends media slower than real time, that never happens, and the picture
/// freezes even with seconds of media buffered. For live TV, a short pause and some lost
/// content are better than a frozen picture, so play what is buffered and jump ahead when
/// playback falls far behind.
enum LiveEdgePolicy {
    enum Action: Equatable {
        case none
        /// Play the buffered media now.
        case resume
        /// Seek to the live position.
        case jumpToLive
    }

    /// Media buffered ahead, in seconds, that is enough to play after a stall.
    static let resumeBuffer: Double = 3
    /// Distance behind live, in seconds, that makes playback jump back to live.
    static let maximumBehind: Double = 30

    static func action(waitingToMinimizeStalls: Bool, bufferedAhead: Double,
                       behindLive: Double?, rewindEnabled: Bool) -> Action {
        if !rewindEnabled, let behindLive, behindLive.isFinite, behindLive > maximumBehind {
            return .jumpToLive
        }
        if waitingToMinimizeStalls, bufferedAhead.isFinite, bufferedAhead >= resumeBuffer {
            return .resume
        }
        return .none
    }
}

/// Captures connectivity reachability and active interface types so playback recovery
/// can detect offline -> online transitions and interface handoffs (e.g. Wi-Fi <-> cellular).
struct NetworkPathSignature: Equatable, Sendable {
    let isSatisfied: Bool
    let interfaceMask: Int

    init(isSatisfied: Bool, interfaceMask: Int) {
        self.isSatisfied = isSatisfied
        self.interfaceMask = interfaceMask
    }
}

/// Decides when a network path change should trigger immediate playback reconnection.
/// Ignores the initial baseline snapshot and debounces rapid interface flaps.
struct NetworkPathRecoveryPolicy: Equatable, Sendable {
    let cooldown: TimeInterval
    private var lastSignature: NetworkPathSignature?
    private var lastRecoveryTime: TimeInterval?

    init(cooldown: TimeInterval = 2.0) {
        self.cooldown = max(0, cooldown)
    }

    mutating func reset() {
        lastSignature = nil
        lastRecoveryTime = nil
    }

    mutating func recordPath(_ signature: NetworkPathSignature, at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        guard let previous = lastSignature else {
            lastSignature = signature
            return false
        }
        lastSignature = signature
        guard signature.isSatisfied else {
            return false
        }
        let becameSatisfied = !previous.isSatisfied
        let switchedInterface = previous.isSatisfied && signature.interfaceMask != previous.interfaceMask
        guard becameSatisfied || switchedInterface else {
            return false
        }
        if let lastRecoveryTime, time - lastRecoveryTime < cooldown {
            return false
        }
        lastRecoveryTime = time
        return true
    }
}
