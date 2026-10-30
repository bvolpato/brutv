import XCTest
import AVFoundation
@testable import BruTV

final class BufferEngineTests: XCTestCase {
    func testBufferProfiles() {
        XCTAssertEqual(BufferProfile.ultraLowLatency.forwardBufferDuration, 1.5)
        XCTAssertEqual(BufferProfile.balanced.forwardBufferDuration, 4.0)
        XCTAssertEqual(BufferProfile.highStability.forwardBufferDuration, 10.0)
    }

    func testPlayerItemConfiguration() {
        let dummyURL = URL(string: "http://example.com/live.m3u8")!
        let item = AVPlayerItem(url: dummyURL)

        HLSBufferEngine.shared.configurePlayerItem(item, with: .ultraLowLatency)
        XCTAssertEqual(item.preferredForwardBufferDuration, 1.5)
        XCTAssertTrue(item.canUseNetworkResourcesForLiveStreamingWhilePaused)

        HLSBufferEngine.shared.configurePlayerItem(item, with: .balanced)
        XCTAssertEqual(item.preferredForwardBufferDuration, 4.0)

        HLSBufferEngine.shared.configurePlayerItem(item, with: .highStability)
        XCTAssertEqual(item.preferredForwardBufferDuration, 10.0)
    }

    func testTelemetryFormatters() {
        var t = StreamTelemetry()
        t.bufferDuration = 4.2
        t.observedBitrate = 4_500_000
        t.resolution = CGSize(width: 1920, height: 1080)

        XCTAssertEqual(t.bufferDurationFormatted, "4.2s")
        XCTAssertEqual(t.observedBitrateFormatted, "4.50 Mbps")
        XCTAssertEqual(t.resolutionFormatted, "1920x1080")

        // Prefers indicated stream bitrate over loopback throughput
        t.indicatedBitrate = 3_200_000
        t.observedBitrate = 3_600_000_000
        XCTAssertEqual(t.observedBitrateFormatted, "3.20 Mbps")

        // Suppresses extreme localhost socket burst speed when no indicated bitrate
        t.indicatedBitrate = 0
        XCTAssertEqual(t.observedBitrateFormatted, "Local Stream")
    }

    @MainActor
    func testPlaybackManagerStopResetsState() {
        let manager = PlaybackManager()
        let dummyStream = LiveStream(
            id: 99999,
            num: 1,
            name: "Test Channel",
            streamType: "live",
            iconURLString: nil,
            epgChannelId: nil,
            categoryId: "1"
        )

        manager.play(stream: dummyStream)
        XCTAssertEqual(manager.currentStream?.id, 99999)
        XCTAssertNotEqual(manager.playbackState, .idle)

        // Stopping playback must immediately clear active stream and return to idle
        manager.stop()
        XCTAssertNil(manager.currentStream)
        XCTAssertNil(manager.currentVOD)
        XCTAssertEqual(manager.playbackState, .idle)
        XCTAssertFalse(manager.isPlaybackRequested)
    }

    @MainActor
    func testPausingAConnectingItemCancelsPlaybackIntent() async throws {
        let manager = PlaybackManager()
        defer { manager.stop() }
        let stream = LiveStream(id: 99998, num: 1, name: "Unavailable test stream",
                                directURLString: "http://127.0.0.1:9/test.m3u8")
        manager.play(stream: stream)
        XCTAssertTrue(manager.isPlaybackRequested)
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaybackRequested)
        XCTAssertEqual(manager.playbackState, .paused)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(manager.isPlaybackRequested)
        XCTAssertEqual(manager.playbackState, .paused)
        XCTAssertEqual(manager.player.rate, 0)
    }

    @MainActor
    func testNativePauseWhileConnectingCancelsPlaybackIntent() async throws {
        let url = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = PlaybackManager()
        defer { manager.stop() }
        manager.play(stream: LiveStream(id: 99997, name: "Local audio", directURLString: url.absoluteString))
        manager.player.pause()
        let paused = try await waitUntil { !manager.isPlaybackRequested }
        XCTAssertTrue(paused)
        XCTAssertEqual(manager.playbackState, .paused)
        XCTAssertEqual(manager.player.rate, 0)
    }

    @MainActor
    func testNativePauseAndPlaySynchronizePlaybackIntent() async throws {
        let url = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = PlaybackManager()
        defer { manager.stop() }
        manager.play(stream: LiveStream(id: 99996, name: "Local audio", directURLString: url.absoluteString))
        let started = try await waitUntil { manager.playbackState == .playing }
        XCTAssertTrue(started)

        manager.player.pause()
        let paused = try await waitUntil { !manager.isPlaybackRequested && manager.playbackState == .paused }
        XCTAssertTrue(paused)
        manager.player.play()
        let resumed = try await waitUntil { manager.isPlaybackRequested && manager.playbackState == .playing }
        XCTAssertTrue(resumed)
    }

    @MainActor
    func testCustomResumeAppliesPendingSeekAfterItemBecameReadyWhilePaused() async throws {
        try await assertPendingSeekResumes(usingNativeControls: false)
    }

    @MainActor
    func testNativeResumeAppliesPendingSeekAfterItemBecameReadyWhilePaused() async throws {
        try await assertPendingSeekResumes(usingNativeControls: true)
    }

    @MainActor
    func testNativePauseImmediatelyAfterResumeIsNotOverriddenBySeekCompletion() async throws {
        let url = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = PlaybackManager()
        defer { manager.stop() }
        manager.play(stream: LiveStream(id: 99994, name: "Local audio", directURLString: url.absoluteString))
        manager.prepareAndPlay(url: url, resumePosition: 3)
        manager.togglePlayPause()
        let ready = try await waitUntil(timeout: 15) { manager.player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "Item did not become ready: status=\(String(describing: manager.player.currentItem?.status)), error=\(String(describing: manager.player.currentItem?.error))")
        manager.togglePlayPause()
        manager.player.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(manager.isPlaybackRequested)
        XCTAssertEqual(manager.playbackState, .paused)
        XCTAssertEqual(manager.player.rate, 0)
    }

    @MainActor
    private func assertPendingSeekResumes(usingNativeControls: Bool) async throws {
        let url = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = PlaybackManager()
        defer { manager.stop() }
        manager.play(stream: LiveStream(id: 99995, name: "Local audio", directURLString: url.absoluteString))
        manager.prepareAndPlay(url: url, resumePosition: 3)
        manager.togglePlayPause()
        let ready = try await waitUntil(timeout: 15) { manager.player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "Item did not become ready: status=\(String(describing: manager.player.currentItem?.status)), error=\(String(describing: manager.player.currentItem?.error))")
        XCTAssertFalse(manager.isPlaybackRequested)
        XCTAssertEqual(manager.playbackState, .paused)

        if usingNativeControls {
            manager.player.play()
        } else {
            manager.togglePlayPause()
        }
        let resumed = try await waitUntil { manager.playbackState == .playing }
        XCTAssertTrue(resumed)
        let position = CMTimeGetSeconds(manager.player.currentTime())
        XCTAssertGreaterThanOrEqual(position, 2.9)
        XCTAssertLessThan(position, 4.5)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeAudioFixture() throws -> URL {
        let samples = Data(repeating: 0, count: 16_000 * 2 * 8)
        var data = Data()
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendInteger(UInt32(36 + samples.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendInteger(UInt32(16))
        appendInteger(UInt16(1))
        appendInteger(UInt16(1))
        appendInteger(UInt32(16_000))
        appendInteger(UInt32(32_000))
        appendInteger(UInt16(2))
        appendInteger(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendInteger(UInt32(samples.count))
        data.append(samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brutv-playback-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}
