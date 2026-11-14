import Foundation
import XCTest
@testable import BruTV

final class PlaybackPolicyTests: XCTestCase {
    func testBufferedDurationUsesTheRangeContainingPlaybackAndMergesAdjacentRanges() {
        let ranges = [
            PlaybackBufferRange(start: 30, duration: 8),
            PlaybackBufferRange(start: 0, duration: 5),
            PlaybackBufferRange(start: 20, duration: 10),
            PlaybackBufferRange(start: 27, duration: 5)
        ]
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: 22, ranges: ranges), 16, accuracy: 0.001)
    }

    func testBufferedDurationDoesNotCountDataAcrossAnUnloadedGap() {
        let ranges = [
            PlaybackBufferRange(start: 0, duration: 5),
            PlaybackBufferRange(start: 20, duration: 10)
        ]
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: 2, ranges: ranges), 3)
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: 12, ranges: ranges), 0)
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: 30, ranges: ranges), 0)
    }

    func testBufferedDurationIgnoresInvalidTimes() {
        let ranges = [
            PlaybackBufferRange(start: .nan, duration: 4),
            PlaybackBufferRange(start: 0, duration: .infinity),
            PlaybackBufferRange(start: 0, duration: -4),
            PlaybackBufferRange(start: 4, duration: 6)
        ]
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: 5, ranges: ranges), 5)
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: .nan, ranges: ranges), 0)
        XCTAssertEqual(PlaybackPolicy.bufferedDuration(at: .infinity, ranges: ranges), 0)
    }

    func testRepeatedBriefPlaybackDoesNotReplenishRetryBudget() {
        var policy = PlaybackRecoveryPolicy()
        XCTAssertEqual(policy.nextRetryDelay(for: .transient), 1.5)
        policy.recordPlaying(at: 10)
        policy.recordPlaying(at: 11)
        XCTAssertEqual(policy.nextRetryDelay(for: .timedOut), 3)
        policy.recordPlaying(at: 20)
        policy.recordPlaying(at: 21)
        XCTAssertNil(policy.nextRetryDelay(for: .transient))
        XCTAssertEqual(policy.attempts, 2)
    }

    func testOnlyContinuousHealthyPlaybackReplenishesRetryBudget() {
        var policy = PlaybackRecoveryPolicy()
        _ = policy.nextRetryDelay(for: .transient)
        _ = policy.nextRetryDelay(for: .transient)
        policy.recordPlaying(at: 10)
        policy.recordPlaying(at: 39)
        XCTAssertEqual(policy.attempts, 2)
        policy.recordInterruption()
        policy.recordPlaying(at: 50)
        policy.recordPlaying(at: 79)
        XCTAssertEqual(policy.attempts, 2)
        policy.recordPlaying(at: 80)
        XCTAssertEqual(policy.nextRetryDelay(for: .transient), 1.5)
    }

    func testTerminalFailuresAreNotRetriedAndManualResetStartsANewBudget() {
        var policy = PlaybackRecoveryPolicy()
        for failure in [PlaybackFailure.unauthorized, .notFound, .unsupported, .unknown] {
            XCTAssertNil(policy.nextRetryDelay(for: failure))
        }
        XCTAssertEqual(policy.attempts, 0)
        _ = policy.nextRetryDelay(for: .transient)
        _ = policy.nextRetryDelay(for: .transient)
        XCTAssertNil(policy.nextRetryDelay(for: .transient))
        policy.reset()
        XCTAssertEqual(policy.nextRetryDelay(for: .transient), 1.5)
    }

    func testNetworkFailuresAreClassifiedWithoutExposingProviderURLs() {
        let sensitiveURL = "https://provider.example/live/private-user/private-password/42.m3u8"
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue,
                                 userInfo: [NSURLErrorFailingURLStringErrorKey: sensitiveURL])
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        let failure = PlaybackPolicy.networkFailure(for: wrapped)
        XCTAssertEqual(failure, .timedOut)
        XCTAssertFalse(failure?.message.contains("private-user") ?? true)
        XCTAssertFalse(failure?.message.contains("private-password") ?? true)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: wrapped, httpStatus: 403), .unauthorized)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: wrapped, httpStatus: 404), .notFound)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: nil, httpStatus: 503), .transient)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: nil, httpStatus: 400), .unknown)
    }

    func testInvalidAndSecurityFailuresDoNotBecomeTransientRetries() {
        for code in [URLError.Code.badURL, .unsupportedURL, .serverCertificateUntrusted, .cancelled] {
            let failure = PlaybackPolicy.networkFailure(for: NSError(domain: NSURLErrorDomain, code: code.rawValue))
            XCTAssertNotNil(failure)
            XCTAssertFalse(failure?.canRetry ?? true)
        }
    }

    func testVODResumePositionRejectsInvalidTimesAndClampsToDuration() {
        XCTAssertNil(PlaybackPolicy.vodResumePosition(.nan))
        XCTAssertNil(PlaybackPolicy.vodResumePosition(.infinity))
        XCTAssertNil(PlaybackPolicy.vodResumePosition(-1))
        XCTAssertNil(PlaybackPolicy.vodResumePosition(0))
        XCTAssertEqual(PlaybackPolicy.vodResumePosition(42), 42)
        XCTAssertEqual(PlaybackPolicy.vodResumePosition(42, duration: .nan), 42)
        XCTAssertEqual(PlaybackPolicy.vodResumePosition(42, duration: 20) ?? 0, 19.9, accuracy: 0.001)
    }

    func testVODSeeksRejectNonfiniteInputAndAllowSeekingToTheBeginning() {
        XCTAssertNil(PlaybackPolicy.vodSeekPosition(.nan, duration: 120))
        XCTAssertNil(PlaybackPolicy.vodSeekPosition(.infinity, duration: 0))
        XCTAssertNil(PlaybackPolicy.vodSeekPosition(-.infinity, duration: 120))
        XCTAssertEqual(PlaybackPolicy.vodSeekPosition(-10, duration: 120), 0)
        XCTAssertEqual(PlaybackPolicy.vodSeekPosition(0, duration: 120), 0)
        XCTAssertEqual(PlaybackPolicy.vodSeekPosition(150, duration: 120), 120)
        XCTAssertEqual(PlaybackPolicy.vodSeekPosition(42, duration: .nan), 42)
        XCTAssertEqual(PlaybackPolicy.vodSeekPosition(42, duration: .infinity), 42)
    }

    func testRemoteLiveEndRecoversButFiniteFilesAndVODRemainEnded() {
        let remote = URL(string: "https://fixture.example.test/live.m3u8")!
        let file = URL(fileURLWithPath: "/tmp/finite-fixture.wav")
        XCTAssertTrue(PlaybackPolicy.retriesAtEnd(isLive: true, url: remote))
        XCTAssertFalse(PlaybackPolicy.retriesAtEnd(isLive: true, url: file))
        XCTAssertFalse(PlaybackPolicy.retriesAtEnd(isLive: false, url: remote))
        XCTAssertFalse(PlaybackPolicy.retriesAtEnd(isLive: true, url: nil))
    }

    func testBackgroundAudioDeclarationRequiresAudioBackgroundMode() {
        XCTAssertTrue(PlaybackPolicy.declaresBackgroundAudio(in: ["UIBackgroundModes": ["audio"]]))
        XCTAssertTrue(PlaybackPolicy.declaresBackgroundAudio(in: ["UIBackgroundModes": ["fetch", "audio"]]))
        XCTAssertFalse(PlaybackPolicy.declaresBackgroundAudio(in: ["UIBackgroundModes": ["fetch"]]))
        XCTAssertFalse(PlaybackPolicy.declaresBackgroundAudio(in: ["UIBackgroundModes": []]))
        XCTAssertFalse(PlaybackPolicy.declaresBackgroundAudio(in: [:]))
        XCTAssertFalse(PlaybackPolicy.declaresBackgroundAudio(in: nil))
    }

    // MARK: - Quality step-down

    func testOneStallKeepsQualityAndTwoStallsCapBelowThePlayingVariant() {
        var policy = QualityStepDownPolicy()
        XCTAssertNil(policy.recordStall(at: 100, currentBitrate: 4_000_000))
        XCTAssertEqual(policy.recordStall(at: 120, currentBitrate: 4_000_000) ?? 0, 2_800_000, accuracy: 1)
        XCTAssertEqual(policy.peakBitRate, 2_800_000, accuracy: 1)
    }

    func testStallsOutsideTheWindowDoNotStepDown() {
        var policy = QualityStepDownPolicy(stallsToStepDown: 2, window: 60)
        XCTAssertNil(policy.recordStall(at: 0, currentBitrate: 4_000_000))
        XCTAssertNil(policy.recordStall(at: 61, currentBitrate: 4_000_000))
    }

    func testRepeatedStepDownsKeepLoweringUntilTheFloor() {
        var policy = QualityStepDownPolicy(stallsToStepDown: 1, window: 60, floor: 1_000_000)
        XCTAssertEqual(policy.recordStall(at: 0, currentBitrate: 2_000_000) ?? 0, 1_400_000, accuracy: 1)
        XCTAssertEqual(policy.recordStall(at: 1, currentBitrate: 1_400_000) ?? 0, 1_000_000, accuracy: 1)
        XCTAssertNil(policy.recordStall(at: 2, currentBitrate: 1_000_000), "Must not go below the floor")
    }

    func testUnknownVariantBitrateDoesNotCapQuality() {
        // Single-variant Xtream playlists report no bitrate (-1).
        var policy = QualityStepDownPolicy(stallsToStepDown: 1)
        XCTAssertNil(policy.recordStall(at: 0, currentBitrate: -1))
        XCTAssertEqual(policy.peakBitRate, 0)
    }

    // MARK: - Live edge

    func testStallWithBufferedMediaResumesInsteadOfWaiting() {
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: true, bufferedAhead: 3.2,
                                             behindLive: 10, rewindEnabled: false), .resume)
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: true, bufferedAhead: 1,
                                             behindLive: 10, rewindEnabled: false), .none)
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: false, bufferedAhead: 8,
                                             behindLive: 10, rewindEnabled: false), .none)
    }

    func testFarBehindLiveJumpsToLiveUnlessRewindIsOn() {
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: false, bufferedAhead: 0,
                                             behindLive: 31, rewindEnabled: false), .jumpToLive)
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: false, bufferedAhead: 0,
                                             behindLive: 31, rewindEnabled: true), .none)
        XCTAssertEqual(LiveEdgePolicy.action(waitingToMinimizeStalls: false, bufferedAhead: 0,
                                             behindLive: nil, rewindEnabled: false), .none)
    }

    // MARK: - Player settings

    func testSettingsSavedBeforeLiveRewindExistedStillLoadWithItOn() throws {
        let old = Data(#"{"bufferProfile":"high_stability","preferredFormat":"m3u8","defaultAspectRatio":"fill","showStatsHUD":true,"autoPlayNextChannel":false,"hardwareAcceleration":true}"#.utf8)
        let settings = try JSONDecoder().decode(PlayerSettings.self, from: old)
        XCTAssertEqual(settings.bufferProfile, .highStability)
        XCTAssertEqual(settings.defaultAspectRatio, .fill)
        XCTAssertTrue(settings.showStatsHUD)
        XCTAssertTrue(settings.liveRewind)
    }

    func testSettingsRoundTripThroughUserDefaults() throws {
        let suite = "brutv.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PlayerSettings.load(from: defaults), PlayerSettings())

        var settings = PlayerSettings()
        settings.liveRewind = false
        settings.bufferProfile = .ultraLowLatency
        settings.save(to: defaults)
        XCTAssertEqual(PlayerSettings.load(from: defaults), settings)
    }
}
