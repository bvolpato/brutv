import Combine
import Foundation

@MainActor
public final class PlaybackDiagnosticsStore: ObservableObject {
    public static let shared = PlaybackDiagnosticsStore()
    @Published public private(set) var revision = 0

    private static let storageKey = "brutv.playbackHealth.v2"
    private static let legacyStorageKey = "brutv.playbackHealth.v1"
    private var recorder: PlaybackDiagnosticsRecorder
    private let enabled: Bool
    private let environment: PlaybackDiagnosticsEnvironment
    private let defaults = UserDefaults.standard

    private init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        enabled = !arguments.contains("--ui-fixtures") && !arguments.contains("--store-screenshots")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        enabled = true
        #endif
        environment = Self.currentEnvironment()
        let saved = enabled ? defaults.data(forKey: Self.storageKey) : nil
        recorder = PlaybackDiagnosticsRecorder(completed: PlaybackDiagnosticsPersistence.restore(from: saved, environment: environment))
        if enabled {
            defaults.removeObject(forKey: Self.legacyStorageKey)
            persist(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    public func begin(kind: PlaybackHealthSummary.Kind) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recorder.begin(kind: kind, at: now)
        persist(at: now)
    }

    public func transition(to phase: PlaybackDiagnosticsRecorder.Phase, kind: PlaybackHealthSummary.Kind? = nil) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recorder.transition(to: phase, at: now, restartingKind: kind)
        persist(at: now)
    }

    public func recordRetry(kind: PlaybackHealthSummary.Kind) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !recorder.isRecording { recorder.begin(kind: kind, at: now) }
        recorder.recordRetry()
        persist(at: now)
    }

    public func finish(outcome: PlaybackHealthSummary.Outcome) {
        guard enabled, recorder.isRecording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recorder.finish(outcome: outcome, at: now)
        persist(at: now)
    }

    public var summaries: [PlaybackHealthSummary] {
        recorder.snapshot(at: ProcessInfo.processInfo.systemUptime)
    }

    public func clear() {
        guard enabled else { return }
        recorder.clear()
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.legacyStorageKey)
        revision &+= 1
    }

    public var report: String {
        struct Report: Encodable {
            let schemaVersion = 2
            let platform: String
            let appVersion: String
            let appBuild: String
            let osMajorVersion: Int
            let sessions: [PlaybackHealthSummary]
        }
        let report = Report(platform: environment.platform,
                            appVersion: environment.appVersion,
                            appBuild: environment.appBuild,
                            osMajorVersion: environment.osMajorVersion,
                            sessions: summaries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func persist(at time: TimeInterval) {
        let checkpoint = recorder.snapshot(at: time).last.flatMap { $0.outcome == .inProgress ? $0 : nil }
        if let data = PlaybackDiagnosticsPersistence.encode(completed: recorder.completed, checkpoint: checkpoint,
                                                           environment: environment) {
            defaults.set(data, forKey: Self.storageKey)
        }
        revision &+= 1
    }

    private static func currentEnvironment() -> PlaybackDiagnosticsEnvironment {
        #if targetEnvironment(macCatalyst)
        let platform = "Mac Catalyst"
        #elseif os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "iOS"
        #endif
        return PlaybackDiagnosticsEnvironment(
            platform: platform,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}
