import Foundation
import Combine

@MainActor
public final class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public private(set) var favoriteChannelIDs: Set<Int> = []
    @Published public private(set) var recentChannelIDs: [Int] = []

    private let favoritesKey = "brutv.favorites.channelIDs"
    private let recentsKey = "brutv.favorites.recentIDs"

    public init() {
        load()
    }

    private func load() {
        if let stored = UserDefaults.standard.array(forKey: favoritesKey) as? [Int] {
            self.favoriteChannelIDs = Set(stored)
        }
        if let stored = UserDefaults.standard.array(forKey: recentsKey) as? [Int] {
            self.recentChannelIDs = stored
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteChannelIDs), forKey: favoritesKey)
    }

    private func saveRecents() {
        UserDefaults.standard.set(recentChannelIDs, forKey: recentsKey)
    }

    public func isFavorite(channelID: Int) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    public func toggleFavorite(channelID: Int) {
        if favoriteChannelIDs.contains(channelID) {
            favoriteChannelIDs.remove(channelID)
        } else {
            favoriteChannelIDs.insert(channelID)
        }
        saveFavorites()
    }

    public func addRecent(channelID: Int) {
        var recents = recentChannelIDs.filter { $0 != channelID }
        recents.insert(channelID, at: 0)
        // Keep max 30 recent channels
        if recents.count > 30 {
            recents = Array(recents.prefix(30))
        }
        self.recentChannelIDs = recents
        saveRecents()
    }

    public func clearRecents() {
        self.recentChannelIDs.removeAll()
        saveRecents()
    }
}
