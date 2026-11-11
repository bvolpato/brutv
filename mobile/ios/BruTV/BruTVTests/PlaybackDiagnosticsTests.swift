import Foundation
import XCTest
@testable import BruTV

final class PlaybackDiagnosticsTests: XCTestCase {
    private let environment = PlaybackDiagnosticsEnvironment(platform: "iOS", appVersion: "1.0.1", appBuild: "17", osMajorVersion: 27)

    func testPersistenceDoesNotRelabelRecordsFromAnotherBuild() throws {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 0)
        recorder.transition(to: .playing, at: 1)
        recorder.finish(outcome: .ended, at: 5)
        let previous = PlaybackDiagnosticsEnvironment(platform: "iOS", appVersion: "1.0.1", appBuild: "16", osMajorVersion: 27)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: recorder.completed, checkpoint: nil,
                                                                     environment: previous))

        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: data, environment: environment).isEmpty)
        XCTAssertEqual(PlaybackDiagnosticsPersistence.restore(from: data, environment: previous), recorder.completed)
    }

    func testPersistenceRestoresOnlyLastRecordedCheckpointAsInterrupted() throws {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 3)
        recorder.transition(to: .waiting, at: 5)
        let checkpoint = try XCTUnwrap(recorder.snapshot(at: 9).last)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: [], checkpoint: checkpoint,
                                                                     environment: environment))

        let restored = PlaybackDiagnosticsPersistence.restore(from: data, environment: environment)
        let interrupted = try XCTUnwrap(restored.first)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(interrupted.outcome, .interrupted)
        XCTAssertEqual(interrupted.requestedSeconds, 9)
        XCTAssertEqual(interrupted.startupSeconds, 3)
        XCTAssertEqual(interrupted.stallCount, 1)
        XCTAssertEqual(interrupted.stallSeconds, 4)
        XCTAssertEqual(interrupted.maxStallSeconds, 4)

        let afterRestart = PlaybackDiagnosticsRecorder(completed: restored)
        XCTAssertEqual(afterRestart.snapshot(at: 50_000), restored)
        let normalized = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: restored, checkpoint: nil,
                                                                           environment: environment))
        XCTAssertEqual(PlaybackDiagnosticsPersistence.restore(from: normalized, environment: environment), restored)
    }

    func testPersistenceRotatesVersionPlatformAndOSHistory() throws {
        let summary = PlaybackHealthSummary(kind: .video, outcome: .ended, requestedSeconds: 8,
                                            startupSeconds: 1, stallCount: 0, stallSeconds: 0,
                                            maxStallSeconds: 0, retryCount: 0)
        let checkpoint = PlaybackHealthSummary(kind: .live, outcome: .inProgress, requestedSeconds: 10,
                                               startupSeconds: 1, stallCount: 1, stallSeconds: 3,
                                               maxStallSeconds: 3, retryCount: 1)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: [summary], checkpoint: checkpoint,
                                                                     environment: environment))
        let differentEnvironments = [
            PlaybackDiagnosticsEnvironment(platform: "iOS", appVersion: "1.0.2", appBuild: "17", osMajorVersion: 27),
            PlaybackDiagnosticsEnvironment(platform: "tvOS", appVersion: "1.0.1", appBuild: "17", osMajorVersion: 27),
            PlaybackDiagnosticsEnvironment(platform: "iOS", appVersion: "1.0.1", appBuild: "17", osMajorVersion: 28),
        ]
        for different in differentEnvironments {
            XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: data, environment: different).isEmpty)
        }
    }

    func testPersistenceDiscardsLegacyOrUnsupportedArchiveFormats() throws {
        let summary = PlaybackHealthSummary(kind: .video, outcome: .ended, requestedSeconds: 8,
                                            startupSeconds: 1, stallCount: 0, stallSeconds: 0,
                                            maxStallSeconds: 0, retryCount: 0)
        let legacy = try JSONEncoder().encode([summary])
        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: legacy, environment: environment).isEmpty)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: [summary], checkpoint: nil,
                                                                     environment: environment))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 3
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: unsupported, environment: environment).isEmpty)
        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: Data("incomplete".utf8), environment: environment).isEmpty)
        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: Data(repeating: 0, count: 32 * 1024 + 1),
                                                             environment: environment).isEmpty)
    }

    func testPersistenceCapsHistoryIncludingRecoveredCheckpoint() throws {
        let completed = (0..<12).map { index in
            PlaybackHealthSummary(kind: .video, outcome: .ended, requestedSeconds: 8,
                                  startupSeconds: 1, stallCount: 0, stallSeconds: 0,
                                  maxStallSeconds: 0, retryCount: index)
        }
        let checkpoint = PlaybackHealthSummary(kind: .live, outcome: .inProgress, requestedSeconds: 10,
                                               startupSeconds: 1, stallCount: 1, stallSeconds: 3,
                                               maxStallSeconds: 3, retryCount: 100)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: completed, checkpoint: checkpoint,
                                                                     environment: environment))
        let restored = PlaybackDiagnosticsPersistence.restore(from: data, environment: environment)
        XCTAssertEqual(restored.count, 10)
        XCTAssertEqual(restored.first?.retryCount, 3)
        XCTAssertEqual(restored.last?.retryCount, 100)
        XCTAssertEqual(restored.last?.outcome, .interrupted)
        XCTAssertLessThanOrEqual(data.count, 32 * 1024)
    }

    func testClearRemovesSavedAndCheckpointDataFromNextArchive() throws {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 0)
        recorder.transition(to: .playing, at: 1)
        recorder.finish(outcome: .ended, at: 8)
        recorder.begin(kind: .live, at: 10)
        recorder.clear()

        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: recorder.completed,
                                                                     checkpoint: recorder.snapshot(at: 12).last,
                                                                     environment: environment))
        XCTAssertTrue(PlaybackDiagnosticsPersistence.restore(from: data, environment: environment).isEmpty)
        XCTAssertFalse(recorder.isRecording)
    }

    func testArchiveUsesOnlyVersionContextAndAllowlistedHealthData() throws {
        let checkpoint = PlaybackHealthSummary(kind: .live, outcome: .inProgress, requestedSeconds: 10,
                                               startupSeconds: 1, stallCount: 1, stallSeconds: 3,
                                               maxStallSeconds: 3, retryCount: 1)
        let data = try XCTUnwrap(PlaybackDiagnosticsPersistence.encode(completed: [], checkpoint: checkpoint,
                                                                     environment: environment))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "environment", "completed", "checkpoint"]))
        let context = try XCTUnwrap(object["environment"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), Set(["platform", "appVersion", "appBuild", "osMajorVersion"]))
        let active = try XCTUnwrap(object["checkpoint"] as? [String: Any])
        XCTAssertEqual(Set(active.keys), Set(["kind", "outcome", "requestedSeconds", "startupSeconds",
                                             "stallCount", "stallSeconds", "maxStallSeconds", "retryCount"]))
    }

    func testPlaybackAfterEOFStartsAnotherSummary() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 0)
        recorder.transition(to: .playing, at: 1)
        recorder.finish(outcome: .ended, at: 5)
        recorder.transition(to: .playing, at: 6, restartingKind: .video)
        let summaries = recorder.snapshot(at: 8)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.last?.outcome, .inProgress)
        XCTAssertEqual(summaries.last?.requestedSeconds, 2)
    }

    func testClearDoesNotRestoreOldDataAndPausedTransportDoesNotRestart() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 1)
        recorder.clear()
        recorder.transition(to: .paused, at: 3, restartingKind: .live)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.snapshot(at: 3).isEmpty)
        recorder.transition(to: .waiting, at: 4, restartingKind: .live)
        recorder.transition(to: .playing, at: 6)
        recorder.finish(outcome: .stopped, at: 8)
        XCTAssertEqual(recorder.completed.count, 1)
        XCTAssertEqual(recorder.completed.last?.startupSeconds, 2)
        XCTAssertEqual(recorder.completed.last?.requestedSeconds, 4)
    }

    func testStartupRemainsUnknownUntilPlaybackActuallyStarts() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        XCTAssertNil(recorder.snapshot(at: 2).last?.startupSeconds)
        recorder.finish(outcome: .failed, at: 5)
        XCTAssertNil(recorder.completed.last?.startupSeconds)
        XCTAssertEqual(recorder.completed.last?.requestedSeconds, 5)
    }

    func testEncodedSummaryContainsOnlyPlaybackHealthFields() throws {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 0)
        recorder.transition(to: .playing, at: 1)
        recorder.finish(outcome: .ended, at: 5)
        let data = try JSONEncoder().encode(recorder.completed[0])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["kind", "outcome", "requestedSeconds", "startupSeconds",
                                               "stallCount", "stallSeconds", "maxStallSeconds", "retryCount"]))
    }

    func testStartupTimeCountsWaitingBeforeFirstPlayback() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 10)
        recorder.transition(to: .playing, at: 15)
        recorder.finish(outcome: .ended, at: 20)

        let summary = recorder.completed[0]
        XCTAssertEqual(summary.outcome, .ended)
        XCTAssertEqual(summary.startupSeconds, 5)
        XCTAssertEqual(summary.requestedSeconds, 10)
        XCTAssertEqual(summary.stallCount, 0)
    }

    func testRepeatedWaitingEventsProduceOneRebufferInterval() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 0)
        recorder.transition(to: .playing, at: 2)
        recorder.transition(to: .waiting, at: 5)
        recorder.transition(to: .waiting, at: 8)
        recorder.transition(to: .playing, at: 12)
        recorder.finish(outcome: .stopped, at: 20)

        let summary = recorder.completed[0]
        XCTAssertEqual(summary.requestedSeconds, 20)
        XCTAssertEqual(summary.startupSeconds, 2)
        XCTAssertEqual(summary.stallCount, 1)
        XCTAssertEqual(summary.stallSeconds, 7)
        XCTAssertEqual(summary.maxStallSeconds, 7)
    }

    func testPausedTimeIsExcludedFromRequestedStartupAndPlaybackTime() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 3)
        recorder.transition(to: .paused, at: 8)
        recorder.transition(to: .playing, at: 18)
        recorder.finish(outcome: .ended, at: 23)

        let summary = recorder.completed[0]
        XCTAssertEqual(summary.requestedSeconds, 13)
        XCTAssertEqual(summary.startupSeconds, 3)
        XCTAssertEqual(summary.stallCount, 0)
        XCTAssertEqual(summary.stallSeconds, 0)
    }

    func testRetriesOnlyCountWhileRecording() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.recordRetry()
        recorder.begin(kind: .video, at: 0)
        recorder.recordRetry()
        recorder.recordRetry()
        recorder.finish(outcome: .failed, at: 1)
        recorder.recordRetry()

        XCTAssertEqual(recorder.completed[0].retryCount, 2)
    }

    func testSnapshotIncludesCurrentTimeWithoutMutatingRecorder() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 2)
        recorder.transition(to: .waiting, at: 5)

        let first = recorder.snapshot(at: 9)
        let second = recorder.snapshot(at: 9)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].outcome, .inProgress)
        XCTAssertEqual(first[0].stallCount, 1)
        XCTAssertEqual(first[0].stallSeconds, 4)
        XCTAssertEqual(first[0].requestedSeconds, 9)
        XCTAssertTrue(recorder.completed.isEmpty)
        XCTAssertTrue(recorder.isRecording)

        recorder.transition(to: .playing, at: 10)
        recorder.finish(outcome: .ended, at: 12)
        XCTAssertEqual(recorder.completed[0].stallCount, 1)
        XCTAssertEqual(recorder.completed[0].stallSeconds, 5)
        XCTAssertEqual(recorder.completed[0].requestedSeconds, 12)
    }

    func testClockRegressionsAndInvalidTimesDoNotReduceOrAddTime() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .video, at: 10)
        recorder.transition(to: .waiting, at: 12)
        recorder.transition(to: .playing, at: 15)
        recorder.transition(to: .paused, at: 20)
        recorder.transition(to: .playing, at: 19)
        recorder.transition(to: .paused, at: .infinity)
        recorder.finish(outcome: .ended, at: 24)

        XCTAssertEqual(recorder.completed[0].requestedSeconds, 10)
        XCTAssertEqual(recorder.completed[0].startupSeconds, 5)
    }

    func testStaleBeginAndFinishDoNotReplaceOrFinishTheCurrentSession() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 5)
        recorder.begin(kind: .video, at: 4)
        recorder.finish(outcome: .stopped, at: 4)

        let current = recorder.snapshot(at: 5)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].kind, .live)
        XCTAssertEqual(current[0].outcome, .inProgress)
        XCTAssertTrue(recorder.isRecording)

        recorder.finish(outcome: .stopped, at: 6)
        XCTAssertEqual(recorder.completed[0].kind, .live)
        XCTAssertEqual(recorder.completed[0].outcome, .stopped)
        XCTAssertEqual(recorder.completed[0].requestedSeconds, 6)
    }

    func testBeginningAnotherSessionFinishesPreviousAsSwitched() {
        var recorder = PlaybackDiagnosticsRecorder()
        recorder.begin(kind: .live, at: 0)
        recorder.transition(to: .playing, at: 2)
        recorder.begin(kind: .video, at: 8)

        let values = recorder.snapshot(at: 10)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].kind, .live)
        XCTAssertEqual(values[0].outcome, .switched)
        XCTAssertEqual(values[0].requestedSeconds, 8)
        XCTAssertEqual(values[1].kind, .video)
        XCTAssertEqual(values[1].outcome, .inProgress)
        XCTAssertTrue(recorder.isRecording)
    }

    func testRetentionKeepsOnlyLatestTenValidSummaries() {
        let invalid = PlaybackHealthSummary(kind: .live, outcome: .ended, requestedSeconds: .nan,
                                            startupSeconds: nil, stallCount: 0, stallSeconds: 0,
                                            maxStallSeconds: 0, retryCount: 0)
        XCTAssertFalse(invalid.isValid)

        var recorder = PlaybackDiagnosticsRecorder(completed: [invalid])
        for index in 0..<12 {
            recorder.begin(kind: .video, at: Double(index * 2))
            for _ in 0..<index { recorder.recordRetry() }
            recorder.finish(outcome: .ended, at: Double(index * 2 + 1))
        }

        XCTAssertEqual(recorder.completed.count, 10)
        XCTAssertEqual(recorder.completed.first?.retryCount, 2)
        XCTAssertEqual(recorder.completed.last?.retryCount, 11)

        recorder.clear()
        XCTAssertTrue(recorder.completed.isEmpty)
        XCTAssertFalse(recorder.isRecording)
    }
}
