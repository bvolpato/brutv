import XCTest
@testable import BruTV

final class TopShelfStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "BruTV.TopShelfStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testRecordContinueWatchingPrependsAndDeduplicates() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TopShelfStore(userDefaults: defaults)

        store.recordContinueWatching(id: "1", title: "Live One", subtitle: "HD", imageURLString: "https://example.com/1.png", kind: "live")
        store.recordContinueWatching(id: "2", title: "Movie Two", subtitle: "8.5", imageURLString: "https://example.com/2.png", kind: "vod")
        store.recordContinueWatching(id: "1", title: "Live One", subtitle: "HD", imageURLString: "https://example.com/1.png", kind: "live")

        let payload = store.loadPayload()
        XCTAssertEqual(payload.continueWatching.count, 2)
        XCTAssertEqual(payload.continueWatching.first?.id, "1")
        XCTAssertEqual(payload.continueWatching.first?.kind, "live")
        XCTAssertEqual(payload.continueWatching.first?.playURL?.absoluteString, "brutv://play?id=1&type=live")
        XCTAssertEqual(payload.continueWatching.last?.id, "2")
        XCTAssertEqual(payload.continueWatching.last?.kind, "vod")
    }

    func testRecordContinueWatchingCappedAtTwenty() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TopShelfStore(userDefaults: defaults)

        for i in 1...25 {
            store.recordContinueWatching(id: "\(i)", title: "Item \(i)", kind: "vod")
        }

        let payload = store.loadPayload()
        XCTAssertEqual(payload.continueWatching.count, 20)
        XCTAssertEqual(payload.continueWatching.first?.id, "25")
        XCTAssertEqual(payload.continueWatching.last?.id, "6")
    }

    func testUpdateFavoritesTransformsLiveStreams() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TopShelfStore(userDefaults: defaults)

        let streams = (1...25).map { idx in
            LiveStream(
                id: idx,
                name: "Channel \(idx)",
                streamType: "live",
                iconURLString: "https://example.com/icon\(idx).png",
                categoryId: "1"
            )
        }

        store.updateFavorites(channels: streams)

        let payload = store.loadPayload()
        XCTAssertEqual(payload.favorites.count, 20)
        XCTAssertEqual(payload.favorites.first?.id, "1")
        XCTAssertEqual(payload.favorites.first?.title, "Channel 1")
        XCTAssertEqual(payload.favorites.first?.playURL?.absoluteString, "brutv://play?id=1&type=live")
        XCTAssertEqual(payload.favorites.first?.displayURL?.absoluteString, "brutv://channel?id=1&type=live")
    }

    func testProfileScopingIsolatesPayloadsAndClearsOnLogout() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TopShelfStore(userDefaults: defaults)
        let profileA = UUID()
        let profileB = UUID()

        store.selectProfile(profileA)
        store.recordContinueWatching(id: "10", title: "Profile A Movie", kind: "vod")
        XCTAssertEqual(store.loadPayload().continueWatching.map(\.id), ["10"])

        // Switching to Profile B shows clean slate and does not leak Profile A.
        store.selectProfile(profileB)
        XCTAssertTrue(store.loadPayload().continueWatching.isEmpty)
        store.recordContinueWatching(id: "20", title: "Profile B Show", kind: "series")
        XCTAssertEqual(store.loadPayload().continueWatching.map(\.id), ["20"])

        // Logout clears active Top Shelf payload immediately.
        store.selectProfile(nil)
        XCTAssertTrue(store.loadPayload().continueWatching.isEmpty)
        XCTAssertTrue(store.loadPayload().favorites.isEmpty)

        // Switching back to Profile A restores its saved Top Shelf items.
        store.selectProfile(profileA)
        XCTAssertEqual(store.loadPayload().continueWatching.map(\.id), ["10"])
    }
}
