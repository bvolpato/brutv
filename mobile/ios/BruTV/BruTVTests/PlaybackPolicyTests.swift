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

    // MARK: - HTTP 458, CoreMedia error codes & recent error log

    func testHTTP458AndCoreMediaErrorCodesAreClassifiedCorrectly() {
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: nil, httpStatus: 458), .transient)

        let cm403 = NSError(domain: "CoreMediaErrorDomain", code: -12660)
        let cm503 = NSError(domain: "CoreMediaErrorDomain", code: -12661)
        let cm404 = NSError(domain: "CoreMediaErrorDomain", code: -12938)
        let cmTimeout = NSError(domain: "CoreMediaErrorDomain", code: -12889)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: cm403), .unauthorized)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: cm503), .transient)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: cm404), .notFound)
        XCTAssertEqual(PlaybackPolicy.networkFailure(for: cmTimeout), .timedOut)
    }

    func testRecentHTTPStatusIgnoresStaleErrorLogEventsAndMapsCoreMediaCodes() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let recent = now.addingTimeInterval(-3)
        let stale = now.addingTimeInterval(-15)

        XCTAssertEqual(PlaybackPolicy.recentHTTPStatus(errorStatusCode: 503, eventDate: recent, now: now), 503)
        XCTAssertEqual(PlaybackPolicy.recentHTTPStatus(errorStatusCode: -12660, eventDate: recent, now: now), 403)
        XCTAssertEqual(PlaybackPolicy.recentHTTPStatus(errorStatusCode: -12661, eventDate: recent, now: now), 503)
        XCTAssertEqual(PlaybackPolicy.recentHTTPStatus(errorStatusCode: -12938, eventDate: recent, now: now), 404)
        XCTAssertNil(PlaybackPolicy.recentHTTPStatus(errorStatusCode: 403, eventDate: stale, now: now))
        XCTAssertNil(PlaybackPolicy.recentHTTPStatus(errorStatusCode: -12660, eventDate: stale, now: now))
        XCTAssertNil(PlaybackPolicy.recentHTTPStatus(errorStatusCode: -99999, eventDate: recent, now: now))
    }

    func testRecoveryPolicyExponentialBackoffJitterAndVODCap() throws {
        var exp = PlaybackRecoveryPolicy(maxAttempts: nil, healthyInterval: 30, maxDelay: 15.0)
        XCTAssertEqual(exp.nextRetryDelay(for: .transient), 1.5)
        XCTAssertEqual(exp.nextRetryDelay(for: .transient), 3.0)
        XCTAssertEqual(exp.nextRetryDelay(for: .transient), 6.0)
        XCTAssertEqual(exp.nextRetryDelay(for: .transient), 12.0)
        XCTAssertEqual(exp.nextRetryDelay(for: .transient), 15.0)

        var jitteredHigh = PlaybackRecoveryPolicy(maxAttempts: 3, healthyInterval: 30, maxDelay: 15.0, jitterFactor: 0.2, randomUnit: { 1.0 })
        XCTAssertEqual(try XCTUnwrap(jitteredHigh.nextRetryDelay(for: .transient)), 1.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(jitteredHigh.nextRetryDelay(for: .timedOut)), 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(jitteredHigh.nextRetryDelay(for: .transient)), 7.2, accuracy: 0.001)
        // VOD 3-attempt cap exhausted
        XCTAssertNil(jitteredHigh.nextRetryDelay(for: .transient))
        // Sustained 30s playback replenishes retry budget
        jitteredHigh.recordPlaying(at: 100)
        jitteredHigh.recordPlaying(at: 130)
        XCTAssertNotNil(jitteredHigh.nextRetryDelay(for: .transient))
    }

    // MARK: - Bidirectional live transport fallback

    func testLiveTransportFallbackSwitchesFromTSRelayToDirectHLS() {
        var policy = LiveTransportFallbackPolicy(preferredFormat: .ts, hasTSRelay: true, liveRewind: true)
        XCTAssertEqual(policy.currentMode, .tsRelay)

        // Startup or mid-stream relay exhaustion switches to Direct HLS instead of looping .ts forever.
        XCTAssertEqual(policy.recordCaptureFailure(), .directHLS)
        XCTAssertEqual(policy.currentMode, .directHLS)
        // Already tried both transports: no further switch until sustained healthy playback.
        XCTAssertEqual(policy.recordPlaybackFailure(.transient), .retryCurrent)
        XCTAssertEqual(policy.recordPlaybackFailure(.transient), .retryCurrent)

        // Sustained 60s healthy playback resets tried modes so a later outage can switch back to .tsRelay.
        policy.recordPlaying(at: 10)
        policy.recordPlaying(at: 70)
        XCTAssertEqual(policy.recordPlaybackFailure(.notFound), .switchTo(.tsRelay))
        XCTAssertEqual(policy.currentMode, .tsRelay)
    }

    func testLiveTransportFallbackSwitchesFromDirectHLSToTSRelayOnFailureOrStalls() {
        var failurePolicy = LiveTransportFallbackPolicy(preferredFormat: .hls, hasTSRelay: true, liveRewind: false)
        XCTAssertEqual(failurePolicy.currentMode, .directHLS)
        // First transient retries current, second switches to .tsRelay!
        XCTAssertEqual(failurePolicy.recordPlaybackFailure(.timedOut), .retryCurrent)
        XCTAssertEqual(failurePolicy.recordPlaybackFailure(.timedOut), .switchTo(.tsRelay))
        XCTAssertEqual(failurePolicy.currentMode, .tsRelay)

        // Repeated stalls on Direct HLS also trigger fallback to .tsRelay.
        var stallPolicy = LiveTransportFallbackPolicy(preferredFormat: .hls, hasTSRelay: true, liveRewind: false, stallsToFallback: 3, stallWindow: 45)
        XCTAssertNil(stallPolicy.recordStall(at: 10))
        XCTAssertNil(stallPolicy.recordStall(at: 20))
        XCTAssertEqual(stallPolicy.recordStall(at: 30), .tsRelay)
        XCTAssertEqual(stallPolicy.currentMode, .tsRelay)

        // 404/403 on Xtream .m3u8 immediately tries cross-format .tsRelay once, then fails if .tsRelay also 403s.
        var authPolicy = LiveTransportFallbackPolicy(preferredFormat: .hls, hasTSRelay: true, liveRewind: false)
        XCTAssertEqual(authPolicy.recordPlaybackFailure(.unauthorized), .switchTo(.tsRelay))
        XCTAssertEqual(authPolicy.recordPlaybackFailure(.unauthorized), .fail)
    }

    func testLiveTransportFallbackBufferedHLSHandlesUnsupportedAndTimeouts() {
        // Encrypted/unsupported HLS falls back directly to native Direct HLS.
        var unsupported = LiveTransportFallbackPolicy(preferredFormat: .hls, hasTSRelay: true, liveRewind: true)
        XCTAssertEqual(unsupported.currentMode, .bufferedHLS)
        XCTAssertEqual(unsupported.recordCaptureFailure(unsupported: true), .directHLS)

        // Broken/slow Xtream .m3u8 switches to .tsRelay first, and still has .directHLS if .tsRelay fails too.
        var brokenM3U8 = LiveTransportFallbackPolicy(preferredFormat: .hls, hasTSRelay: true, liveRewind: true)
        XCTAssertEqual(brokenM3U8.recordCaptureFailure(unsupported: false), .tsRelay)
        XCTAssertEqual(brokenM3U8.recordCaptureFailure(unsupported: false), .directHLS)
        XCTAssertNil(brokenM3U8.recordCaptureFailure(unsupported: false))

        // Non-Xtream M3U channel without .ts equivalent never tries .tsRelay.
        var nonXtream = LiveTransportFallbackPolicy(preferredFormat: .ts, hasTSRelay: false, liveRewind: true)
        XCTAssertEqual(nonXtream.currentMode, .bufferedHLS)
        XCTAssertEqual(nonXtream.recordCaptureFailure(), .directHLS)
        XCTAssertNil(nonXtream.recordStall(at: 10))
        XCTAssertNil(nonXtream.recordStall(at: 20))
        XCTAssertNil(nonXtream.recordStall(at: 30))
    }

    // MARK: - Frozen playhead watchdog

    func testPlaybackProgressWatchdogDetectsFrozenLiveAndVODPlayhead() {
        var liveWatchdog = PlaybackProgressWatchdog(isLive: true)
        // Normal advancing playhead keeps isProgressing = true and never triggers.
        XCTAssertFalse(liveWatchdog.evaluate(mediaTime: 10.0, at: 100, isPlaying: true))
        XCTAssertFalse(liveWatchdog.evaluate(mediaTime: 11.0, at: 101, isPlaying: true))
        XCTAssertTrue(liveWatchdog.isProgressing)

        // Playhead freezes at 11.0 (<0.05s advance): isProgressing immediately becomes false.
        XCTAssertFalse(liveWatchdog.evaluate(mediaTime: 11.01, at: 105, isPlaying: true))
        XCTAssertFalse(liveWatchdog.isProgressing)
        XCTAssertEqual(liveWatchdog.frozenDuration(at: 105), 4.0, accuracy: 0.001)
        XCTAssertFalse(liveWatchdog.evaluate(mediaTime: 11.02, at: 110, isPlaying: true))
        // At 10s since last advance (101 -> 111), live watchdog fires!
        XCTAssertTrue(liveWatchdog.evaluate(mediaTime: 11.02, at: 111, isPlaying: true))

        // Pausing resets the watchdog cleanly.
        XCTAssertFalse(liveWatchdog.evaluate(mediaTime: 11.02, at: 112, isPlaying: false))
        XCTAssertEqual(liveWatchdog.frozenDuration(at: 112), 0)

        // VOD uses a 15s stall threshold.
        var vodWatchdog = PlaybackProgressWatchdog(isLive: false)
        XCTAssertFalse(vodWatchdog.evaluate(mediaTime: 50.0, at: 200, isPlaying: true))
        XCTAssertFalse(vodWatchdog.evaluate(mediaTime: 50.0, at: 210, isPlaying: true))
        XCTAssertFalse(vodWatchdog.evaluate(mediaTime: 50.0, at: 214, isPlaying: true))
        XCTAssertTrue(vodWatchdog.evaluate(mediaTime: 50.0, at: 215, isPlaying: true))
    }

    // MARK: - Live transport memory, output format preferences & remembered modes

    func testLiveTransportMemoryLRUEvictionTTLExpiryAndClear() {
        var memory = LiveTransportMemory(maxEntries: 2, ttl: 60)
        memory.remember(.tsRelay, for: "chan-a", now: 100)
        memory.remember(.directHLS, for: "chan-b", now: 105)
        // Touch chan-a so chan-b becomes least-recently-used.
        XCTAssertEqual(memory.mode(for: "chan-a", now: 110), .tsRelay)

        // Adding chan-c evicts chan-b, preserving chan-a and chan-c.
        memory.remember(.bufferedHLS, for: "chan-c", now: 115)
        XCTAssertEqual(memory.count, 2)
        XCTAssertNil(memory.mode(for: "chan-b", now: 120))
        XCTAssertEqual(memory.mode(for: "chan-a", now: 120), .tsRelay)
        XCTAssertEqual(memory.mode(for: "chan-c", now: 120), .bufferedHLS)

        // TTL expiry (chan-a recorded at 100 expires at 160; chan-c recorded at 115 still valid at 165).
        XCTAssertNil(memory.mode(for: "chan-a", now: 160))
        XCTAssertEqual(memory.mode(for: "chan-c", now: 165), .bufferedHLS)
        XCTAssertNil(memory.mode(for: "chan-c", now: 175))

        // Clear removes all entries.
        memory.remember(.directHLS, for: "chan-d", now: 200)
        XCTAssertEqual(memory.count, 1)
        memory.removeAll()
        XCTAssertEqual(memory.count, 0)
        XCTAssertNil(memory.mode(for: "chan-d", now: 201))
    }

    func testResolvePreferencesRespectsAllowedOutputFormats() {
        // HLS-only disables TS relay even when user prefers .ts.
        let hlsOnly = LiveTransportFallbackPolicy.resolvePreferences(
            preferredFormat: .ts,
            hasTSRelay: true,
            allowedOutputFormats: [" M3U8 ", "rtmp"]
        )
        XCTAssertEqual(hlsOnly.preferredFormat, .hls)
        XCTAssertFalse(hlsOnly.hasTSRelay)

        // TS-only forces .ts when relay URL exists, and preserves false when no relay exists.
        let tsOnlyWithRelay = LiveTransportFallbackPolicy.resolvePreferences(
            preferredFormat: .hls,
            hasTSRelay: true,
            allowedOutputFormats: ["MPEGTS"]
        )
        XCTAssertEqual(tsOnlyWithRelay.preferredFormat, .ts)
        XCTAssertTrue(tsOnlyWithRelay.hasTSRelay)

        let tsOnlyNoRelay = LiveTransportFallbackPolicy.resolvePreferences(
            preferredFormat: .hls,
            hasTSRelay: false,
            allowedOutputFormats: ["ts"]
        )
        XCTAssertEqual(tsOnlyNoRelay.preferredFormat, .hls)
        XCTAssertFalse(tsOnlyNoRelay.hasTSRelay)

        // Both formats, empty, or nil preserve user preferences.
        for formats in [["m3u8", "ts"], [], nil, ["rtmp"]] {
            let preserved = LiveTransportFallbackPolicy.resolvePreferences(
                preferredFormat: .hls,
                hasTSRelay: true,
                allowedOutputFormats: formats
            )
            XCTAssertEqual(preserved.preferredFormat, .hls)
            XCTAssertTrue(preserved.hasTSRelay)
        }
    }

    func testRememberedModeInitializesAndFallsBackWhenBroken() {
        // Channel remembered on Direct HLS stays on Direct HLS even when user prefers TS + rewind,
        // and still falls back to .tsRelay if Direct HLS breaks later.
        var directRemembered = LiveTransportFallbackPolicy(
            preferredFormat: .ts,
            hasTSRelay: true,
            liveRewind: true,
            rememberedMode: .directHLS
        )
        XCTAssertEqual(directRemembered.currentMode, .directHLS)
        XCTAssertEqual(directRemembered.triedModes, [.directHLS])
        XCTAssertEqual(directRemembered.recordPlaybackFailure(.notFound), .switchTo(.tsRelay))
        XCTAssertEqual(directRemembered.currentMode, .tsRelay)

        // Remembered .bufferedHLS maps to .directHLS when live rewind is turned off.
        let bufferedNoRewind = LiveTransportFallbackPolicy(
            preferredFormat: .hls,
            hasTSRelay: true,
            liveRewind: false,
            rememberedMode: .bufferedHLS
        )
        XCTAssertEqual(bufferedNoRewind.currentMode, .directHLS)
        XCTAssertEqual(bufferedNoRewind.triedModes, [.directHLS])

        // Remembered .tsRelay is ignored if relay is unavailable (e.g., HLS-only provider).
        let tsUnavailable = LiveTransportFallbackPolicy(
            preferredFormat: .hls,
            hasTSRelay: false,
            liveRewind: true,
            rememberedMode: .tsRelay
        )
        XCTAssertEqual(tsUnavailable.currentMode, .bufferedHLS)
        XCTAssertEqual(tsUnavailable.triedModes, [.bufferedHLS])
    }

    // MARK: - Network path recovery

    func testNetworkPathRecoveryPolicyHandlesReconnectInterfaceSwitchAndDebounce() {
        var policy = NetworkPathRecoveryPolicy(cooldown: 2.0)

        // Ignores initial path snapshot.
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 1), at: 10.0))
        // Duplicate satisfied path does not trigger.
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 1), at: 11.0))

        // Unsatisfied path does not trigger, then unsatisfied -> satisfied triggers recovery.
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: false, interfaceMask: 0), at: 12.0))
        XCTAssertTrue(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 1), at: 13.0))

        // Rapid flap within cooldown (2.0s) is debounced.
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: false, interfaceMask: 0), at: 13.5))
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 1), at: 14.2))

        // Interface switch (Wi-Fi -> cellular) after cooldown triggers recovery.
        XCTAssertTrue(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 2), at: 15.0))
        // Immediate switch back inside cooldown is debounced.
        XCTAssertFalse(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 1), at: 16.0))
        // Subsequent switch after cooldown recovers again.
        XCTAssertTrue(policy.recordPath(NetworkPathSignature(isSatisfied: true, interfaceMask: 2), at: 17.5))
    }
}
