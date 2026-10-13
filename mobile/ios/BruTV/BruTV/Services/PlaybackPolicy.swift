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

    static func networkFailure(for error: Error?, httpStatus: Int? = nil) -> PlaybackFailure? {
        if let status = httpStatus {
            switch status {
            case 401, 403: return .unauthorized
            case 404, 410: return .notFound
            case 408, 429, 500...599: return .transient
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

    init(maxAttempts: Int? = 2, healthyInterval: TimeInterval = 30, maxDelay: TimeInterval = 15.0) {
        self.maxAttempts = maxAttempts
        self.healthyInterval = healthyInterval
        self.maxDelay = maxDelay
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
        return min(maxDelay, 1.5 * Double(attempts))
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
