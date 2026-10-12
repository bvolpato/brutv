import Foundation

public enum BufferProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case ultraLowLatency = "ultra_low"
    case balanced = "balanced"
    case highStability = "high_stability"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraLowLatency: return "Ultra Low Latency (1.5s)"
        case .balanced: return "Balanced / Default (4.0s)"
        case .highStability: return "High Stability / Cellular (10.0s)"
        }
    }

    public var description: String {
        switch self {
        case .ultraLowLatency:
            return "Requests a small buffer for faster starts on a stable connection. Actual live delay depends on the stream."
        case .balanced:
            return "Balances startup speed and stall protection. The player adapts buffering to the stream."
        case .highStability:
            return "Requests more data ahead of playback to reduce stalls on fluctuating connections. Provider and network quality still matter."
        }
    }

    public var forwardBufferDuration: Double {
        switch self {
        case .ultraLowLatency: return 1.5
        case .balanced: return 4.0
        case .highStability: return 10.0
        }
    }
}

public enum StreamFormatPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case hls = "m3u8"
    case ts = "ts"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hls: return "Apple HLS (.m3u8)"
        case .ts: return "MPEG-TS (.ts)"
        }
    }
}

public enum VideoAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case fit = "fit"
    case fill = "fill"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fit: return "Fit Screen"
        case .fill: return "Fill Screen"
        case .sixteenByNine: return "16 : 9 Widescreen"
        case .fourByThree: return "4 : 3 Classic"
        }
    }
}

public struct PlayerSettings: Codable, Equatable, Sendable {
    public var bufferProfile: BufferProfile
    public var preferredFormat: StreamFormatPreference
    public var defaultAspectRatio: VideoAspectRatio
    public var showStatsHUD: Bool
    public var autoPlayNextChannel: Bool
    public var hardwareAcceleration: Bool

    public init(
        bufferProfile: BufferProfile = .balanced,
        preferredFormat: StreamFormatPreference = .hls,
        defaultAspectRatio: VideoAspectRatio = .fit,
        showStatsHUD: Bool = false,
        autoPlayNextChannel: Bool = true,
        hardwareAcceleration: Bool = true
    ) {
        self.bufferProfile = bufferProfile
        self.preferredFormat = preferredFormat
        self.defaultAspectRatio = defaultAspectRatio
        self.showStatsHUD = showStatsHUD
        self.autoPlayNextChannel = autoPlayNextChannel
        self.hardwareAcceleration = hardwareAcceleration
    }
}
