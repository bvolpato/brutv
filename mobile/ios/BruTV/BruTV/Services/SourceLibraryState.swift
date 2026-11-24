import Foundation

enum SourceEndpointIdentity {
    static func canonicalURL(_ raw: String, isPanel: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPanel, !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return text }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if isPanel {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            components.percentEncodedPath = path
            components.query = nil
            components.fragment = nil
        }
        return components.string ?? text
    }
}

struct ChannelLibrary: Codable, Equatable, Sendable {
    var favoriteIDs: Set<Int> = []
    var recentIDs: [Int] = []

    mutating func addRecent(_ channelID: Int) {
        recentIDs.removeAll { $0 == channelID }
        recentIDs.insert(channelID, at: 0)
        recentIDs = Array(recentIDs.prefix(30))
    }
}

struct SourceLibraryState: Codable, Equatable, Sendable {
    private var libraries: [String: ChannelLibrary] = [:]

    func library(for sourceID: UUID?) -> ChannelLibrary {
        guard let sourceID else { return ChannelLibrary() }
        return libraries[sourceID.uuidString] ?? ChannelLibrary()
    }

    mutating func setLibrary(_ library: ChannelLibrary, for sourceID: UUID) {
        libraries[sourceID.uuidString] = library
    }

    /// Old IDs have no source marker. Only the profile persisted before migration may claim them.
    @discardableResult
    mutating func migrateLegacy(favorites: [Int]?, recents: [Int]?, ownerID: UUID?) -> Bool {
        guard let ownerID, favorites != nil || recents != nil else { return false }
        if libraries[ownerID.uuidString] == nil {
            var seen = Set<Int>()
            let recentIDs = (recents ?? []).filter { seen.insert($0).inserted }
            libraries[ownerID.uuidString] = ChannelLibrary(
                favoriteIDs: Set(favorites ?? []),
                recentIDs: Array(recentIDs.prefix(30))
            )
        }
        return true
    }
}

public struct WatchProgressItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let streamID: Int
    public let kind: String // "vod" or "series"
    public let title: String
    public let subtitle: String?
    public let imageURLString: String?
    public let containerExtension: String
    public let season: Int?
    public let episodeNum: Int?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(
        streamID: Int,
        kind: String,
        title: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        containerExtension: String = "mp4",
        season: Int? = nil,
        episodeNum: Int? = nil,
        position: Double,
        duration: Double,
        updatedAt: Date = Date()
    ) {
        self.id = "\(kind):\(streamID)"
        self.streamID = streamID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.imageURLString = imageURLString
        self.containerExtension = containerExtension
        self.season = season
        self.episodeNum = episodeNum
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var progressFraction: Double {
        guard duration.isFinite, duration > 0, position.isFinite, position > 0 else { return 0 }
        return min(1.0, max(0.0, position / duration))
    }

    public var remainingSeconds: Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return max(0, duration - position)
    }

    public var imageURL: URL? {
        MediaURL.parse(imageURLString)
    }
}

/// Per-profile watch progress tracking with completion reset (>92%) and bounded history.
public struct WatchProgressState: Codable, Equatable, Sendable {
    public static let minimumResumeSeconds: Double = 10.0
    public static let completionFraction: Double = 0.92
    public static let maxItemsPerProfile: Int = 50

    private var profiles: [String: [WatchProgressItem]] = [:]

    public init() {}

    public func items(for sourceID: UUID?) -> [WatchProgressItem] {
        guard let sourceID else { return [] }
        return profiles[sourceID.uuidString] ?? []
    }

    public func resumePosition(for sourceID: UUID?, kind: String, streamID: Int) -> Double? {
        guard let sourceID,
              let item = profiles[sourceID.uuidString]?.first(where: { $0.kind == kind && $0.streamID == streamID }) else {
            return nil
        }
        guard item.position >= Self.minimumResumeSeconds else { return nil }
        if item.duration > 0 && (item.position / item.duration) >= Self.completionFraction {
            return nil
        }
        return item.position
    }

    /// Updates or clears an item's watch progress. Positions >= 92% of duration reset completion and remove the entry.
    @discardableResult
    public mutating func record(sourceID: UUID?, item: WatchProgressItem) -> Bool {
        guard let sourceID, item.streamID > 0, item.position.isFinite else { return false }
        let key = sourceID.uuidString
        var list = profiles[key] ?? []
        list.removeAll { $0.kind == item.kind && $0.streamID == item.streamID }

        let completed = item.duration.isFinite && item.duration > 0 && (item.position / item.duration) >= Self.completionFraction
        if completed || item.position < Self.minimumResumeSeconds {
            profiles[key] = list
            return true
        }

        list.insert(item, at: 0)
        if list.count > Self.maxItemsPerProfile {
            list = Array(list.prefix(Self.maxItemsPerProfile))
        }
        profiles[key] = list
        return true
    }

    public mutating func markCompleted(sourceID: UUID?, kind: String, streamID: Int) {
        guard let sourceID else { return }
        let key = sourceID.uuidString
        profiles[key]?.removeAll { $0.kind == kind && $0.streamID == streamID }
    }

    public mutating func remove(sourceID: UUID?, kind: String, streamID: Int) {
        markCompleted(sourceID: sourceID, kind: kind, streamID: streamID)
    }

    public mutating func clear(sourceID: UUID?) {
        guard let sourceID else { return }
        profiles.removeValue(forKey: sourceID.uuidString)
    }
}
