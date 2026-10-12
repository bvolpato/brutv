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
}
