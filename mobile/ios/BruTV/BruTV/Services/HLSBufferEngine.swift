import Foundation
import AVFoundation

public struct StreamTelemetry: Equatable, Sendable {
    public var bufferDuration: Double = 0.0
    public var observedBitrate: Double = 0.0 // in bps
    public var indicatedBitrate: Double = 0.0 // in bps
    public var resolution: CGSize = .zero
    public var droppedFrames: Int = 0
    public var stallCount: Int = 0
    public var isLive: Bool = true
    public var playbackRate: Float = 0.0

    public var bufferDurationFormatted: String {
        String(format: "%.1fs", bufferDuration)
    }

    public var observedBitrateFormatted: String {
        if observedBitrate <= 0 { return "Analyzing..." }
        let mbps = observedBitrate / 1_000_000.0
        if mbps >= 1.0 {
            return String(format: "%.2f Mbps", mbps)
        } else {
            let kbps = observedBitrate / 1_000.0
            return String(format: "%.0f kbps", kbps)
        }
    }

    public var resolutionFormatted: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "Auto / Detecting"
    }
}

public final class HLSBufferEngine: @unchecked Sendable {
    public static let shared = HLSBufferEngine()

    private init() {}

    public func configurePlayerItem(
        _ playerItem: AVPlayerItem,
        with profile: BufferProfile,
        hardwareAccelerated: Bool = true
    ) {
        playerItem.preferredForwardBufferDuration = profile.forwardBufferDuration
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        // Let AVPlayer adapt within the provider's available variants.
        playerItem.preferredPeakBitRate = 0
    }

    public func calculateBufferDuration(for playerItem: AVPlayerItem) -> Double {
        let currentTime = playerItem.currentTime()
        guard currentTime.isValid, !currentTime.isIndefinite else { return 0.0 }

        let ranges = playerItem.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return PlaybackBufferRange(
                start: CMTimeGetSeconds(range.start),
                duration: CMTimeGetSeconds(range.duration)
            )
        }
        return PlaybackPolicy.bufferedDuration(at: CMTimeGetSeconds(currentTime), ranges: ranges)
    }

    public func extractTelemetry(from playerItem: AVPlayerItem, currentStallCount: Int) -> StreamTelemetry {
        var telemetry = StreamTelemetry()
        telemetry.bufferDuration = calculateBufferDuration(for: playerItem)
        telemetry.stallCount = currentStallCount

        if playerItem.presentationSize != .zero {
            telemetry.resolution = playerItem.presentationSize
        }

        if let accessLog = playerItem.accessLog(), let lastEvent = accessLog.events.last {
            telemetry.observedBitrate = lastEvent.observedBitrate
            telemetry.indicatedBitrate = lastEvent.indicatedBitrate
            telemetry.droppedFrames = lastEvent.numberOfDroppedVideoFrames
            if lastEvent.numberOfStalls > 0 {
                telemetry.stallCount = max(telemetry.stallCount, lastEvent.numberOfStalls)
            }
        }

        return telemetry
    }
}
