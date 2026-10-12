import XCTest
@testable import BruTV

@MainActor
final class FavoritesStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "BruTV.FavoritesStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testFavoriteToggle() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoritesStore(userDefaults: defaults, sourceID: UUID())
        let channelID = 99999

        if store.isFavorite(channelID: channelID) {
            store.toggleFavorite(channelID: channelID)
        }

        XCTAssertFalse(store.isFavorite(channelID: channelID))

        store.toggleFavorite(channelID: channelID)
        XCTAssertTrue(store.isFavorite(channelID: channelID))

        store.toggleFavorite(channelID: channelID)
        XCTAssertFalse(store.isFavorite(channelID: channelID))
    }

    func testRecentsTracking() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoritesStore(userDefaults: defaults, sourceID: UUID())
        store.clearRecents()

        store.addRecent(channelID: 101)
        store.addRecent(channelID: 102)

        XCTAssertEqual(store.recentChannelIDs.first, 102)
        XCTAssertTrue(store.recentChannelIDs.contains(101))
    }

    func testSwitchingAndRestartingRetainsSeparateSourceLibraries() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let second = UUID()
        let store = FavoritesStore(userDefaults: defaults, sourceID: first)
        store.toggleFavorite(channelID: 7)
        store.addRecent(channelID: 7)

        store.selectSource(second)
        XCTAssertFalse(store.isFavorite(channelID: 7))
        XCTAssertTrue(store.recentChannelIDs.isEmpty)
        store.toggleFavorite(channelID: 9)
        store.addRecent(channelID: 7)

        store.selectSource(nil)
        store.toggleFavorite(channelID: 100)
        store.addRecent(channelID: 100)
        XCTAssertTrue(store.favoriteChannelIDs.isEmpty)
        XCTAssertTrue(store.recentChannelIDs.isEmpty)

        let restarted = FavoritesStore(userDefaults: defaults, sourceID: first)
        XCTAssertEqual(restarted.favoriteChannelIDs, [7])
        XCTAssertEqual(restarted.recentChannelIDs, [7])
        restarted.selectSource(second)
        XCTAssertEqual(restarted.favoriteChannelIDs, [9])
        XCTAssertEqual(restarted.recentChannelIDs, [7])
    }

    func testLegacyLibraryMigratesOnlyToPersistedProfile() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(serverURL: "https://provider.example", username: "test", password: "test")
        defaults.set(try JSONEncoder().encode(profile), forKey: "brutv.account.currentProfile")
        defaults.set([7], forKey: "brutv.favorites.channelIDs")
        defaults.set([9, 7], forKey: "brutv.favorites.recentIDs")

        let store = FavoritesStore(userDefaults: defaults)
        XCTAssertEqual(store.favoriteChannelIDs, [7])
        XCTAssertEqual(store.recentChannelIDs, [9, 7])
        XCTAssertNil(defaults.object(forKey: "brutv.favorites.channelIDs"))
        XCTAssertNil(defaults.object(forKey: "brutv.favorites.recentIDs"))
        store.selectSource(UUID())
        XCTAssertTrue(store.favoriteChannelIDs.isEmpty)
        XCTAssertTrue(store.recentChannelIDs.isEmpty)
        store.selectSource(profile.id)
        XCTAssertEqual(store.favoriteChannelIDs, [7])
    }
}

final class ChannelFilteringTests: XCTestCase {
    func testChannelFilteringByName() {
        let channels = [
            LiveStream(id: 1, name: "Globo SP FHD", categoryId: "1377"),
            LiveStream(id: 2, name: "SBT HD", categoryId: "1288"),
            LiveStream(id: 3, name: "Record SP HD", categoryId: "40"),
            LiveStream(id: 4, name: "Band SP HD", categoryId: "1289")
        ]

        let globoMatches = channels.filter { $0.name.localizedCaseInsensitiveContains("globo") }
        XCTAssertEqual(globoMatches.count, 1)
        XCTAssertEqual(globoMatches.first?.name, "Globo SP FHD")

        let sbtMatches = channels.filter { $0.name.localizedCaseInsensitiveContains("sbt") }
        XCTAssertEqual(sbtMatches.count, 1)

        let recordMatches = channels.filter { $0.name.localizedCaseInsensitiveContains("record") }
        XCTAssertEqual(recordMatches.count, 1)
    }

    func testQualityFiltering() {
        let channels = [
            LiveStream(id: 1, name: "Globo SP FHD"),
            LiveStream(id: 2, name: "Globo SP HD"),
            LiveStream(id: 3, name: "Globo SP")
        ]

        let fhdOnly = channels.filter { $0.quality == .fhd }
        XCTAssertEqual(fhdOnly.count, 1)
        XCTAssertEqual(fhdOnly.first?.id, 1)

        let hdOnly = channels.filter { $0.quality == .hd }
        XCTAssertEqual(hdOnly.count, 1)
        XCTAssertEqual(hdOnly.first?.id, 2)
    }
}
