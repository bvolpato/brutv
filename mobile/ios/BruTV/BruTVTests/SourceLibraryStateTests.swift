import Foundation
import XCTest
@testable import BruTV

final class SourceLibraryStateTests: XCTestCase {
    func testSourceIdentityNormalizesEndpointsWithoutMergingDistinctSources() {
        func account(_ server: String, username: String = "test", password: String = "test") -> ServerProfile {
            ServerProfile(serverURL: server, username: username, password: password)
        }
        let panel = account("HTTP://TV.Example:80/Panel/")
        XCTAssertTrue(panel.sameSource(as: account("http://tv.example/Panel")))
        XCTAssertTrue(panel.sameSource(as: account("tv.example/Panel")))
        XCTAssertTrue(panel.sameSource(as: account("http://tv.example/Panel?tracking=one#section")))
        XCTAssertTrue(account("HTTPS://TV.Example:443/Panel").sameSource(as: account("https://tv.example/Panel")))
        XCTAssertFalse(panel.sameSource(as: account("https://tv.example/Panel")))
        XCTAssertFalse(panel.sameSource(as: account("http://tv.example:8080/Panel")))
        XCTAssertFalse(panel.sameSource(as: account("http://tv.example/panel")))
        XCTAssertFalse(panel.sameSource(as: account("http://tv.example/Panel", username: "another")))
        XCTAssertFalse(panel.sameSource(as: account("http://tv.example/Panel", password: "another")))

        let playlist = ServerProfile.playlist(url: "HTTPS://TV.Example:443/Family.m3u?token=first")
        XCTAssertTrue(playlist.sameSource(as: .playlist(url: "https://tv.example/Family.m3u?token=first")))
        XCTAssertFalse(playlist.sameSource(as: .playlist(url: "https://tv.example/Family.m3u?token=second")))
        XCTAssertFalse(playlist.sameSource(as: .playlist(url: "https://tv.example/family.m3u?token=first")))
        XCTAssertFalse(playlist.sameSource(as: .playlist(url: "https://tv.example/Family.m3u/?token=first")))
    }

    func testLibraryRoundTripKeepsIdenticalChannelIDsSeparate() throws {
        let firstSource = UUID()
        let secondSource = UUID()
        var state = SourceLibraryState()
        state.setLibrary(ChannelLibrary(favoriteIDs: [7], recentIDs: [7, 9]), for: firstSource)
        state.setLibrary(ChannelLibrary(favoriteIDs: [9], recentIDs: [7]), for: secondSource)

        let restored = try JSONDecoder().decode(SourceLibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.library(for: firstSource).favoriteIDs, [7])
        XCTAssertEqual(restored.library(for: firstSource).recentIDs, [7, 9])
        XCTAssertEqual(restored.library(for: secondSource).favoriteIDs, [9])
        XCTAssertEqual(restored.library(for: secondSource).recentIDs, [7])
        XCTAssertEqual(restored.library(for: nil), ChannelLibrary())
    }

    func testLegacyLibraryBelongsOnlyToThePreviouslyPersistedSource() {
        let originalSource = UUID()
        let anotherSource = UUID()
        var state = SourceLibraryState()
        XCTAssertFalse(state.migrateLegacy(favorites: [7], recents: [7, 9, 7], ownerID: nil))
        XCTAssertEqual(state.library(for: anotherSource), ChannelLibrary())

        XCTAssertTrue(state.migrateLegacy(favorites: [7], recents: [7, 9, 7], ownerID: originalSource))
        XCTAssertEqual(state.library(for: originalSource), ChannelLibrary(favoriteIDs: [7], recentIDs: [7, 9]))
        XCTAssertEqual(state.library(for: anotherSource), ChannelLibrary())
    }

    func testLegacyMigrationDoesNotOverwriteAnExistingSourceLibrary() {
        let source = UUID()
        var state = SourceLibraryState()
        state.setLibrary(ChannelLibrary(favoriteIDs: [11], recentIDs: [12]), for: source)
        XCTAssertTrue(state.migrateLegacy(favorites: [7], recents: [9], ownerID: source))
        XCTAssertEqual(state.library(for: source), ChannelLibrary(favoriteIDs: [11], recentIDs: [12]))
    }

    func testRecentHistoryMovesRepeatedChannelToFrontAndBoundsHistory() {
        var library = ChannelLibrary()
        for id in 1...35 { library.addRecent(id) }
        library.addRecent(20)
        XCTAssertEqual(library.recentIDs.first, 20)
        XCTAssertEqual(library.recentIDs.count, 30)
        XCTAssertEqual(library.recentIDs.filter { $0 == 20 }.count, 1)
        XCTAssertFalse(library.recentIDs.contains(5))
    }
}
