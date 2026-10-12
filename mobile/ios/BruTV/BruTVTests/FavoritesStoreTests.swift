import XCTest
@testable import BruTV

@MainActor
final class FavoritesStoreTests: XCTestCase {
    func testFavoriteToggle() {
        let store = FavoritesStore()
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
        let store = FavoritesStore()
        store.clearRecents()

        store.addRecent(channelID: 101)
        store.addRecent(channelID: 102)

        XCTAssertEqual(store.recentChannelIDs.first, 102)
        XCTAssertTrue(store.recentChannelIDs.contains(101))
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
