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
    /// Reads the provider's continuous `.ts` stream through BruTV's local relay, and uses
    /// HLS when the relay cannot start. Only Xtream live channels have a `.ts` stream.
    case ts = "ts"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hls: return "Apple HLS (.m3u8)"
        case .ts: return "MPEG-TS (.ts, most compatible)"
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
    /// Records live channels on the device so people can pause and rewind adaptively.
    public var liveRewind: Bool

    public init(
        bufferProfile: BufferProfile = .balanced,
        preferredFormat: StreamFormatPreference = .ts,
        defaultAspectRatio: VideoAspectRatio = .fit,
        showStatsHUD: Bool = false,
        autoPlayNextChannel: Bool = true,
        hardwareAcceleration: Bool = true,
        liveRewind: Bool = true
    ) {
        self.bufferProfile = bufferProfile
        self.preferredFormat = preferredFormat
        self.defaultAspectRatio = defaultAspectRatio
        self.showStatsHUD = showStatsHUD
        self.autoPlayNextChannel = autoPlayNextChannel
        self.hardwareAcceleration = hardwareAcceleration
        self.liveRewind = liveRewind
    }

    /// Missing keys use the defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let defaults = PlayerSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferProfile = (try? container.decodeIfPresent(BufferProfile.self, forKey: .bufferProfile)) ?? defaults.bufferProfile
        preferredFormat = (try? container.decodeIfPresent(StreamFormatPreference.self, forKey: .preferredFormat)) ?? defaults.preferredFormat
        defaultAspectRatio = (try? container.decodeIfPresent(VideoAspectRatio.self, forKey: .defaultAspectRatio)) ?? defaults.defaultAspectRatio
        showStatsHUD = (try? container.decodeIfPresent(Bool.self, forKey: .showStatsHUD)) ?? defaults.showStatsHUD
        autoPlayNextChannel = (try? container.decodeIfPresent(Bool.self, forKey: .autoPlayNextChannel)) ?? defaults.autoPlayNextChannel
        hardwareAcceleration = (try? container.decodeIfPresent(Bool.self, forKey: .hardwareAcceleration)) ?? defaults.hardwareAcceleration
        liveRewind = (try? container.decodeIfPresent(Bool.self, forKey: .liveRewind)) ?? defaults.liveRewind
    }

    private static let storageKey = "brutv.playerSettings"

    public static func load(from defaults: UserDefaults = .standard) -> PlayerSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(PlayerSettings.self, from: data) else {
            return PlayerSettings()
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
