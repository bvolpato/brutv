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

public struct TopShelfPayload: Codable, Equatable, Sendable {
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
    private static let profilesStorageKey = "brutv.topshelf.profilePayloads"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var activeProfileID: UUID?

    public init(suiteName: String? = appGroupID) {
        #if os(tvOS)
        if let suiteName, let groupDefaults = UserDefaults(suiteName: suiteName) {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
        #else
        self.defaults = .standard
        #endif
    }

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    /// Scopes Top Shelf content to the selected profile. Passing `nil` (on logout) clears the active Top Shelf payload.
    public func selectProfile(_ profileID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        activeProfileID = profileID
        guard let profileID else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        let map = loadProfilePayloadsLocked()
        let payload = map[profileID.uuidString] ?? TopShelfPayload()
        writeActivePayloadLocked(payload)
    }

    public func clearProfile(_ profileID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadProfilePayloadsLocked()
        map.removeValue(forKey: profileID.uuidString)
        saveProfilePayloadsLocked(map)
        if activeProfileID == profileID {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    public func loadPayload() -> TopShelfPayload {
        lock.lock()
        defer { lock.unlock() }
        return loadActivePayloadLocked()
    }

    public func save(payload: TopShelfPayload) {
        lock.lock()
        defer { lock.unlock() }
        writeActivePayloadLocked(payload)
        if let activeProfileID {
            var map = loadProfilePayloadsLocked()
            map[activeProfileID.uuidString] = payload
            saveProfilePayloadsLocked(map)
        }
    }

    public func updateFavorites(items: [TopShelfItem]) {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadActivePayloadLocked()
        payload.favorites = Array(items.prefix(20))
        writeActivePayloadLocked(payload)
        if let activeProfileID {
            var map = loadProfilePayloadsLocked()
            map[activeProfileID.uuidString] = payload
            saveProfilePayloadsLocked(map)
        }
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
        lock.lock()
        defer { lock.unlock() }
        var payload = loadActivePayloadLocked()
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
        writeActivePayloadLocked(payload)
        if let activeProfileID {
            var map = loadProfilePayloadsLocked()
            map[activeProfileID.uuidString] = payload
            saveProfilePayloadsLocked(map)
        }
    }

    private func loadActivePayloadLocked() -> TopShelfPayload {
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(TopShelfPayload.self, from: data) else {
            return TopShelfPayload()
        }
        return payload
    }

    private func writeActivePayloadLocked(_ payload: TopShelfPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func loadProfilePayloadsLocked() -> [String: TopShelfPayload] {
        guard let data = defaults.data(forKey: Self.profilesStorageKey),
              let map = try? JSONDecoder().decode([String: TopShelfPayload].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveProfilePayloadsLocked(_ map: [String: TopShelfPayload]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.profilesStorageKey)
    }
}
