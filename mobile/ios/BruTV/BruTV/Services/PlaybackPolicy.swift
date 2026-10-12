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
    private let maxAttempts: Int
    private let healthyInterval: TimeInterval

    init(maxAttempts: Int = 2, healthyInterval: TimeInterval = 30) {
        self.maxAttempts = maxAttempts
        self.healthyInterval = healthyInterval
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
        guard failure.canRetry, attempts < maxAttempts else { return nil }
        attempts += 1
        return 1.5 * Double(attempts)
    }
}
