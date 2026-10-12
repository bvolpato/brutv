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
    }
}
