import Foundation

public struct TopShelfItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let imageURLString: String?
    public let playURLString: String
    public let displayURLString: String
    public let kind: String
    public let recordedDate: Date

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        playURLString: String,
        displayURLString: String,
        kind: String = "live",
        recordedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageURLString = imageURLString
        self.playURLString = playURLString
        self.displayURLString = displayURLString
        self.kind = kind
        self.recordedDate = recordedDate
    }

    public var playURL: URL? {
        URL(string: playURLString)
    }

    public var displayURL: URL? {
        URL(string: displayURLString)
    }

    public var imageURL: URL? {
        guard let imageURLString, !imageURLString.isEmpty else { return nil }
        return URL(string: imageURLString)
    }
}

public struct TopShelfPayload: Codable, Sendable {
    public var favorites: [TopShelfItem]
    public var continueWatching: [TopShelfItem]

    public init(favorites: [TopShelfItem] = [], continueWatching: [TopShelfItem] = []) {
        self.favorites = favorites
        self.continueWatching = continueWatching
    }
}

public final class TopShelfStore: @unchecked Sendable {
    public static let shared = TopShelfStore()
    public static let appGroupID = "group.com.bvolpato.brutv"
    private static let storageKey = "brutv.topshelf.payload"

    private let defaults: UserDefaults

    public init(suiteName: String? = appGroupID) {
        if let suiteName, let groupDefaults = UserDefaults(suiteName: suiteName) {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
    }

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    public func loadPayload() -> TopShelfPayload {
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(TopShelfPayload.self, from: data) else {
            return TopShelfPayload()
        }
        return payload
    }

    public func save(payload: TopShelfPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public func updateFavorites(items: [TopShelfItem]) {
        var payload = loadPayload()
        payload.favorites = Array(items.prefix(20))
        save(payload: payload)
    }

#if !TOPSHELF_EXTENSION
    public func updateFavorites(channels: [LiveStream]) {
        let items = channels.prefix(20).map { stream in
            TopShelfItem(
                id: "\(stream.id)",
                title: stream.cleanName,
                subtitle: stream.quality.rawValue,
                imageURLString: stream.iconURLString,
                playURLString: "brutv://play?id=\(stream.id)&type=live",
                displayURLString: "brutv://channel?id=\(stream.id)&type=live",
                kind: "live"
            )
        }
        updateFavorites(items: items)
    }
#endif

    public func recordContinueWatching(
        id: String,
        title: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        kind: String
    ) {
        var payload = loadPayload()
        payload.continueWatching.removeAll { $0.id == id && $0.kind == kind }
        let item = TopShelfItem(
            id: id,
            title: title,
            subtitle: subtitle,
            imageURLString: imageURLString,
            playURLString: "brutv://play?id=\(id)&type=\(kind)",
            displayURLString: "brutv://play?id=\(id)&type=\(kind)",
            kind: kind,
            recordedDate: Date()
        )
        payload.continueWatching.insert(item, at: 0)
        payload.continueWatching = Array(payload.continueWatching.prefix(20))
        save(payload: payload)
    }
}
