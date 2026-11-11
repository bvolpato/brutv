import Foundation

public struct PlaybackHealthSummary: Codable, Equatable {
    public enum Kind: String, Codable {
        case live
        case video
    }

    public enum Outcome: String, Codable {
        case stopped
        case ended
        case failed
        case switched
        case interrupted
        case inProgress
    }

    public let kind: Kind
    public let outcome: Outcome
    public let requestedSeconds: Double
    public let startupSeconds: Double?
    public let stallCount: Int
    public let stallSeconds: Double
    public let maxStallSeconds: Double
    public let retryCount: Int

    public init(kind: Kind, outcome: Outcome, requestedSeconds: Double, startupSeconds: Double?,
                stallCount: Int, stallSeconds: Double, maxStallSeconds: Double, retryCount: Int) {
        self.kind = kind
        self.outcome = outcome
        self.requestedSeconds = requestedSeconds
        self.startupSeconds = startupSeconds
        self.stallCount = stallCount
        self.stallSeconds = stallSeconds
        self.maxStallSeconds = maxStallSeconds
        self.retryCount = retryCount
    }

    public var isValid: Bool {
        requestedSeconds.isFinite && requestedSeconds >= 0 &&
        (startupSeconds.map { $0.isFinite && $0 >= 0 } ?? true) &&
        stallCount >= 0 && stallSeconds.isFinite && stallSeconds >= 0 &&
        maxStallSeconds.isFinite && maxStallSeconds >= 0 &&
        stallSeconds <= requestedSeconds && maxStallSeconds <= stallSeconds &&
        (startupSeconds.map { $0 <= requestedSeconds } ?? true) && retryCount >= 0
    }
}

struct PlaybackDiagnosticsEnvironment: Codable, Equatable {
    let platform: String
    let appVersion: String
    let appBuild: String
    let osMajorVersion: Int
}

enum PlaybackDiagnosticsPersistence {
    static let maximumBytes = 32 * 1024

    private struct Archive: Codable {
        let schemaVersion: Int
        let environment: PlaybackDiagnosticsEnvironment
        let completed: [PlaybackHealthSummary]
        let checkpoint: PlaybackHealthSummary?
    }

    static func restore(from data: Data?, environment: PlaybackDiagnosticsEnvironment) -> [PlaybackHealthSummary] {
        guard let data, data.count <= maximumBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.schemaVersion == 2, archive.environment == environment else { return [] }
        var summaries = archive.completed.filter { $0.isValid && $0.outcome != .inProgress }
        if let checkpoint = archive.checkpoint, checkpoint.isValid, checkpoint.outcome == .inProgress {
            summaries.append(PlaybackHealthSummary(
                kind: checkpoint.kind, outcome: .interrupted,
                requestedSeconds: checkpoint.requestedSeconds, startupSeconds: checkpoint.startupSeconds,
                stallCount: checkpoint.stallCount, stallSeconds: checkpoint.stallSeconds,
                maxStallSeconds: checkpoint.maxStallSeconds, retryCount: checkpoint.retryCount
            ))
        }
        return Array(summaries.suffix(10))
    }

    static func encode(completed: [PlaybackHealthSummary], checkpoint: PlaybackHealthSummary?,
                       environment: PlaybackDiagnosticsEnvironment) -> Data? {
        let summaries = Array(completed.filter { $0.isValid && $0.outcome != .inProgress }.suffix(10))
        let active = checkpoint.flatMap { $0.isValid && $0.outcome == .inProgress ? $0 : nil }
        let archive = Archive(schemaVersion: 2, environment: environment, completed: summaries, checkpoint: active)
        guard let data = try? JSONEncoder().encode(archive), data.count <= maximumBytes else { return nil }
        return data
    }
}

public struct PlaybackDiagnosticsRecorder {
    public enum Phase: Equatable {
        case waiting
        case playing
        case paused
    }

    private struct ActiveSession {
        let kind: PlaybackHealthSummary.Kind
        var phase: Phase = .waiting
        var phaseStartedAt: TimeInterval
        var lastObservedAt: TimeInterval
        var hasPlayed = false
        var requestedSeconds = 0.0
        var startupWaitSeconds = 0.0
        var stallCount = 0
        var stallSeconds = 0.0
        var maxStallSeconds = 0.0
        var retryCount = 0

        init(kind: PlaybackHealthSummary.Kind, at time: TimeInterval) {
            self.kind = kind
            phaseStartedAt = time
            lastObservedAt = time
        }
    }

    public private(set) var completed: [PlaybackHealthSummary]
    public var isRecording: Bool { active != nil }

    private let retentionLimit: Int
    private var active: ActiveSession?

    public init(completed: [PlaybackHealthSummary] = [], limit: Int = 10) {
        retentionLimit = max(0, min(limit, 10))
        self.completed = Array(completed.filter(\.isValid).suffix(retentionLimit))
    }

    public mutating func begin(kind: PlaybackHealthSummary.Kind, at time: TimeInterval) {
        guard let time = validTime(time) else { return }
        if active != nil {
            guard let session = active, time >= session.lastObservedAt else { return }
            finishActive(outcome: .switched, at: time)
        }
        active = ActiveSession(kind: kind, at: time)
    }

    public mutating func transition(to phase: Phase, at time: TimeInterval,
                                    restartingKind: PlaybackHealthSummary.Kind? = nil) {
        guard let time = validTime(time) else { return }
        if active == nil {
            guard phase != .paused, let kind = restartingKind else { return }
            begin(kind: kind, at: time)
        }
        guard var session = active else { return }
        guard time >= session.lastObservedAt else { return }
        let eventTime = time
        session.lastObservedAt = eventTime
        guard session.phase != phase else {
            active = session
            return
        }

        Self.accountCurrentPhase(&session, through: eventTime)
        if phase == .playing, !session.hasPlayed {
            session.hasPlayed = true
        }
        session.phase = phase
        session.phaseStartedAt = eventTime
        active = session
    }

    public mutating func recordRetry() {
        guard var session = active else { return }
        if session.retryCount < Int.max { session.retryCount += 1 }
        active = session
    }

    public mutating func finish(outcome: PlaybackHealthSummary.Outcome, at time: TimeInterval) {
        guard outcome != .inProgress, let session = active, let time = validTime(time),
              time >= session.lastObservedAt else { return }
        finishActive(outcome: outcome, at: time)
    }

    public func snapshot(at time: TimeInterval) -> [PlaybackHealthSummary] {
        guard var session = active else { return completed }
        let snapshotTime = validTime(time).map { max($0, session.lastObservedAt) } ?? session.lastObservedAt
        Self.accountCurrentPhase(&session, through: snapshotTime)
        let current = Self.summary(from: session, outcome: .inProgress,
                                   startupSeconds: session.hasPlayed ? session.startupWaitSeconds : nil)
        return completed + [current]
    }

    public mutating func clear() {
        completed.removeAll()
        active = nil
    }

    private mutating func finishActive(outcome: PlaybackHealthSummary.Outcome, at time: TimeInterval) {
        guard var session = active else { return }
        Self.accountCurrentPhase(&session, through: time)
        append(Self.summary(from: session, outcome: outcome,
                            startupSeconds: session.hasPlayed ? session.startupWaitSeconds : nil))
        active = nil
    }

    private mutating func append(_ summary: PlaybackHealthSummary) {
        guard retentionLimit > 0 else { return }
        completed.append(summary)
        if completed.count > retentionLimit {
            completed.removeFirst(completed.count - retentionLimit)
        }
    }

    private static func accountCurrentPhase(_ session: inout ActiveSession, through time: TimeInterval) {
        let elapsed = max(0, time - session.phaseStartedAt)
        switch session.phase {
        case .waiting:
            session.requestedSeconds = add(session.requestedSeconds, elapsed)
            if session.hasPlayed {
                session.stallSeconds = add(session.stallSeconds, elapsed)
                session.maxStallSeconds = max(session.maxStallSeconds, elapsed)
                if session.stallCount < Int.max { session.stallCount += 1 }
            } else {
                session.startupWaitSeconds = add(session.startupWaitSeconds, elapsed)
            }
        case .playing:
            session.requestedSeconds = add(session.requestedSeconds, elapsed)
        case .paused:
            break
        }
        session.phaseStartedAt = time
    }

    private static func summary(from session: ActiveSession, outcome: PlaybackHealthSummary.Outcome,
                                startupSeconds: Double?) -> PlaybackHealthSummary {
        PlaybackHealthSummary(
            kind: session.kind,
            outcome: outcome,
            requestedSeconds: session.requestedSeconds,
            startupSeconds: startupSeconds,
            stallCount: session.stallCount,
            stallSeconds: session.stallSeconds,
            maxStallSeconds: session.maxStallSeconds,
            retryCount: session.retryCount
        )
    }

    private func validTime(_ time: TimeInterval) -> TimeInterval? {
        time.isFinite && time >= 0 ? time : nil
    }

    private static func add(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs < Double.greatestFiniteMagnitude - rhs else { return .greatestFiniteMagnitude }
        return lhs + rhs
    }
}
