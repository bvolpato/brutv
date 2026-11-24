import Foundation
import Combine

@MainActor
public final class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public private(set) var favoriteChannelIDs: Set<Int> = []
    @Published public private(set) var recentChannelIDs: [Int] = []

    private let defaults: UserDefaults
    private let libraryKey = "brutv.favorites.sourceLibraries"
    private let favoritesKey = "brutv.favorites.channelIDs"
    private let recentsKey = "brutv.favorites.recentIDs"
    private var sourceID: UUID?
    private var state = SourceLibraryState()

    public init(userDefaults: UserDefaults = .standard, sourceID: UUID? = nil) {
        self.defaults = userDefaults
        if let data = userDefaults.data(forKey: libraryKey),
           let stored = try? JSONDecoder().decode(SourceLibraryState.self, from: data) {
            state = stored
        }
        let persistedProfile = userDefaults.data(forKey: "brutv.account.currentProfile")
            .flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) }
        self.sourceID = sourceID ?? persistedProfile?.id
        if state.migrateLegacy(
            favorites: userDefaults.array(forKey: favoritesKey) as? [Int],
            recents: userDefaults.array(forKey: recentsKey) as? [Int],
            ownerID: persistedProfile?.id
        ), persistState() {
            userDefaults.removeObject(forKey: favoritesKey)
            userDefaults.removeObject(forKey: recentsKey)
        }
        publishLibrary()
    }

    public func selectSource(_ sourceID: UUID?) {
        self.sourceID = sourceID
        publishLibrary()
    }

    private func publishLibrary() {
        let library = state.library(for: sourceID)
        favoriteChannelIDs = library.favoriteIDs
        recentChannelIDs = library.recentIDs
    }

    @discardableResult
    private func persistState() -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: libraryKey)
        return true
    }

    private func updateLibrary(_ update: (inout ChannelLibrary) -> Void) {
        guard let sourceID else { return }
        var library = state.library(for: sourceID)
        update(&library)
        state.setLibrary(library, for: sourceID)
        persistState()
        publishLibrary()
    }

    public func isFavorite(channelID: Int) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    public func toggleFavorite(channelID: Int) {
        updateLibrary { library in
            if library.favoriteIDs.contains(channelID) {
                library.favoriteIDs.remove(channelID)
            } else {
                library.favoriteIDs.insert(channelID)
            }
        }
    }

    public func addRecent(channelID: Int) {
        updateLibrary { $0.addRecent(channelID) }
    }

    public func clearRecents() {
        updateLibrary { $0.recentIDs.removeAll() }
    }
}

/// Persists per-profile VOD & Series watch positions so users can resume across launches.
@MainActor
public final class WatchProgressStore: ObservableObject {
    public static let shared = WatchProgressStore()

    @Published public private(set) var items: [WatchProgressItem] = []

    private let defaults: UserDefaults
    private let storageKey = "brutv.watchProgress.state"
    private var sourceID: UUID?
    private var state = WatchProgressState()

    public init(userDefaults: UserDefaults = .standard, sourceID: UUID? = nil) {
        self.defaults = userDefaults
        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(WatchProgressState.self, from: data) {
            state = stored
        }
        let persistedProfile = userDefaults.data(forKey: "brutv.account.currentProfile")
            .flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) }
        self.sourceID = sourceID ?? persistedProfile?.id
        publishItems()
    }

    public func selectSource(_ sourceID: UUID?) {
        self.sourceID = sourceID
        publishItems()
    }

    public func resumePosition(kind: String, streamID: Int) -> Double? {
        state.resumePosition(for: sourceID, kind: kind, streamID: streamID)
    }

    public func record(
        streamID: Int,
        kind: String,
        title: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        containerExtension: String = "mp4",
        season: Int? = nil,
        episodeNum: Int? = nil,
        position: Double,
        duration: Double
    ) {
        guard let sourceID else { return }
        let item = WatchProgressItem(
            streamID: streamID,
            kind: kind,
            title: title,
            subtitle: subtitle,
            imageURLString: imageURLString,
            containerExtension: containerExtension,
            season: season,
            episodeNum: episodeNum,
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        if state.record(sourceID: sourceID, item: item) {
            persistState()
            publishItems()
        }
    }

    public func markCompleted(kind: String, streamID: Int) {
        guard let sourceID else { return }
        state.markCompleted(sourceID: sourceID, kind: kind, streamID: streamID)
        persistState()
        publishItems()
    }

    public func remove(kind: String, streamID: Int) {
        guard let sourceID else { return }
        state.remove(sourceID: sourceID, kind: kind, streamID: streamID)
        persistState()
        publishItems()
    }

    public func clearCurrentProfile() {
        guard let sourceID else { return }
        state.clear(sourceID: sourceID)
        persistState()
        publishItems()
    }

    public func clear(sourceID: UUID) {
        state.clear(sourceID: sourceID)
        persistState()
        publishItems()
    }

    private func publishItems() {
        items = state.items(for: sourceID)
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
