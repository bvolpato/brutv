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
