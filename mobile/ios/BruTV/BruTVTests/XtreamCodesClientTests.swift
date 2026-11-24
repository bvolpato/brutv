import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BruTV

final class XtreamCodesClientTests: XCTestCase {
    func testLiveStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let hlsURL = client.liveStreamURL(streamID: 62169, format: .hls)
        XCTAssertEqual(hlsURL?.absoluteString, "http://provider.example.test/live/fixture-user/fixture-password/62169.m3u8")

        let tsURL = client.liveStreamURL(streamID: 62169, format: .ts)
        XCTAssertEqual(tsURL?.absoluteString, "http://provider.example.test/live/fixture-user/fixture-password/62169.ts")
    }

    func testVODStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let vodURL = client.vodStreamURL(streamID: 1325116, containerExtension: "mp4")
        XCTAssertEqual(vodURL?.absoluteString, "http://provider.example.test/movie/fixture-user/fixture-password/1325116.mp4")
    }

    func testSeriesStreamURLGeneration() {
        let client = XtreamCodesClient(
            serverURLString: "http://provider.example.test",
            username: "fixture-user",
            password: "fixture-password"
        )

        let seriesURL = client.seriesStreamURL(streamID: 22615, containerExtension: "mp4")
        XCTAssertEqual(seriesURL?.absoluteString, "http://provider.example.test/series/fixture-user/fixture-password/22615.mp4")
    }

    func testSeriesDetailsDecoding() throws {
        let json = """
        {
          "seasons": [],
          "info": {
            "name": "Altered Carbon",
            "cover": "http://img.example.test/cover.jpg",
            "plot": "In a futuristic world where consciousness is digitized...",
            "cast": "Joel Kinnaman",
            "director": "Laeta Kalogridis",
            "genre": "Sci-Fi",
            "rating": "8.0"
          },
          "episodes": {
            "1": [
              {
                "id": "22615",
                "episode_num": "1",
                "title": "Out of the Past",
                "container_extension": "mp4",
                "season": "1",
                "info": {
                  "duration": "55m",
                  "duration_secs": "3300",
                  "movie_image": "http://img.example.test/ep1.jpg",
                  "plot": "Takeshi Kovacs is awakened...",
                  "rating": "8.5"
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let details = try JSONDecoder().decode(SeriesDetails.self, from: json)
        XCTAssertEqual(details.info?.name, "Altered Carbon")
        XCTAssertEqual(details.info?.rating, "8.0")
        XCTAssertEqual(details.episodes.count, 1)

        let season1 = try XCTUnwrap(details.episodes["1"])
        XCTAssertEqual(season1.count, 1)
        XCTAssertEqual(season1[0].id, 22615)
        XCTAssertEqual(season1[0].episodeNum, 1)
        XCTAssertEqual(season1[0].title, "Out of the Past")
        XCTAssertEqual(season1[0].containerExtension, "mp4")
        XCTAssertEqual(season1[0].season, 1)
        XCTAssertEqual(season1[0].info?.duration, "55m")
        XCTAssertEqual(season1[0].info?.durationSecs, 3300)
    }

    func testAuthResponseDecoding() throws {
        let expiration = Int(Date().timeIntervalSince1970) + 3_600
        let json = """
        {
          "user_info": {
            "username": "fixture-user",
            "password": "fixture-password",
            "message": "",
            "auth": 1,
            "status": "Active",
            "exp_date": "\(expiration)",
            "is_trial": "0",
            "active_cons": "0",
            "created_at": "1765202020",
            "max_connections": "1",
            "allowed_output_formats": ["m3u8", "ts", "rtmp"]
          },
          "server_info": {
            "url": "provider.example.test",
            "port": "80",
            "https_port": "25463",
            "server_protocol": "http",
            "rtmp_port": "25462",
            "timezone": "America/Sao_Paulo",
            "timestamp_now": 1791787563,
            "time_now": "2026-10-12 03:46:03",
            "process": true
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.userInfo.username, "fixture-user")
        XCTAssertEqual(response.userInfo.status, "Active")
        XCTAssertEqual(response.userInfo.auth, 1)
        XCTAssertEqual(response.userInfo.maxConnectionsCount, 1)
        XCTAssertFalse(response.userInfo.isExpired)
        XCTAssertEqual(response.serverInfo.url, "provider.example.test")
    }

    func testUserInfoDecodesFlexibleAuthAndConnectionFields() throws {
        func decodeUser(_ json: String) throws -> UserInfo {
            try JSONDecoder().decode(UserInfo.self, from: Data(json.utf8))
        }

        let boolTrue = try decodeUser(#"{"username":"u","auth":true,"status":"Active","is_trial":true,"active_cons":2,"max_connections":4}"#)
        XCTAssertEqual(boolTrue.auth, 1)
        XCTAssertEqual(boolTrue.isTrial, "1")
        XCTAssertEqual(boolTrue.activeCons, "2")
        XCTAssertEqual(boolTrue.maxConnections, "4")
        XCTAssertEqual(boolTrue.maxConnectionsCount, 4)

        let boolFalse = try decodeUser(#"{"username":"u","auth":false,"status":"Active","is_trial":false,"active_cons":false,"max_connections":0}"#)
        XCTAssertEqual(boolFalse.auth, 0)
        XCTAssertEqual(boolFalse.isTrial, "0")
        XCTAssertEqual(boolFalse.activeCons, "0")
        XCTAssertEqual(boolFalse.maxConnections, "0")
        XCTAssertNil(boolFalse.maxConnectionsCount)

        let stringTrue = try decodeUser(#"{"username":"u","auth":"TRUE","status":"Active","max_connections":" 3 "}"#)
        XCTAssertEqual(stringTrue.auth, 1)
        XCTAssertEqual(stringTrue.maxConnectionsCount, 3)

        let stringOne = try decodeUser(#"{"username":"u","auth":"1","status":"Active","max_connections":"unlimited"}"#)
        XCTAssertEqual(stringOne.auth, 1)
        XCTAssertNil(stringOne.maxConnectionsCount)

        let stringZero = try decodeUser(#"{"username":"u","auth":"0","status":"Active","max_connections":"-2"}"#)
        XCTAssertEqual(stringZero.auth, 0)
        XCTAssertNil(stringZero.maxConnectionsCount)
    }

    func testParseRetryAfterHandlesSecondsHTTPDateClampingAndInvalidHeaders() throws {
        // Delta-seconds
        XCTAssertEqual(XtreamCodesClient.parseRetryAfter("4"), 4.0)
        XCTAssertEqual(XtreamCodesClient.parseRetryAfter(" 0 "), 0.0)
        XCTAssertEqual(XtreamCodesClient.parseRetryAfter("120", maxDelay: 10.0), 10.0)

        // HTTP-date (IMF-fixdate)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 10
        components.day = 21
        components.hour = 7
        components.minute = 28
        components.second = 0
        let now = try XCTUnwrap(components.date)

        XCTAssertEqual(
            try XCTUnwrap(XtreamCodesClient.parseRetryAfter("Wed, 21 Oct 2026 07:28:06 GMT", now: now, maxDelay: 10.0)),
            6.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(XtreamCodesClient.parseRetryAfter("Wed, 21 Oct 2026 07:29:00 GMT", now: now, maxDelay: 10.0)),
            10.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(XtreamCodesClient.parseRetryAfter("Wed, 21 Oct 2026 07:27:50 GMT", now: now, maxDelay: 10.0)),
            0.0,
            accuracy: 0.01
        )

        // Invalid / absent
        XCTAssertNil(XtreamCodesClient.parseRetryAfter(nil))
        XCTAssertNil(XtreamCodesClient.parseRetryAfter(""))
        XCTAssertNil(XtreamCodesClient.parseRetryAfter("   "))
        XCTAssertNil(XtreamCodesClient.parseRetryAfter("-5"))
        XCTAssertNil(XtreamCodesClient.parseRetryAfter("not-a-valid-header"))
    }

    func testLiveStreamQualityDetection() {
        let fhdStream = LiveStream(id: 1, name: "Globo SP FHD")
        XCTAssertEqual(fhdStream.quality, .fhd)
        XCTAssertEqual(fhdStream.cleanName, "Globo SP")

        let hdStream = LiveStream(id: 2, name: "SBT HD")
        XCTAssertEqual(hdStream.quality, .hd)
        XCTAssertEqual(hdStream.cleanName, "SBT")

        let uhdStream = LiveStream(id: 3, name: "Record 4K")
        XCTAssertEqual(uhdStream.quality, .uhd4k)
        XCTAssertEqual(uhdStream.cleanName, "Record")

        let sdStream = LiveStream(id: 4, name: "Band")
        XCTAssertEqual(sdStream.quality, .sd)
        XCTAssertEqual(sdStream.cleanName, "Band")
    }

    func testVODDetailsDecodingAndPlot() throws {
        let json = """
        {
          "info": {
            "name": "Inception",
            "plot": "A thief who steals corporate secrets through dream-sharing technology...",
            "cast": "Leonardo DiCaprio",
            "director": "Christopher Nolan",
            "genre": "Action, Sci-Fi",
            "rating": "8.8"
          }
        }
        """.data(using: .utf8)!

        let details = try JSONDecoder().decode(VODDetails.self, from: json)
        XCTAssertEqual(details.info?.name, "Inception")
        XCTAssertEqual(details.info?.director, "Christopher Nolan")
        XCTAssertEqual(details.info?.rating, "8.8")
        XCTAssertTrue(details.info?.plot?.contains("dream-sharing") == true)

        let streamJSON = """
        {
          "stream_id": 991,
          "name": "Inception",
          "stream_icon": "http://img.example.test/inception.jpg",
          "rating": 8.8,
          "plot": "A thief who steals corporate secrets..."
        }
        """.data(using: .utf8)!
        let stream = try JSONDecoder().decode(VODStream.self, from: streamJSON)
        XCTAssertEqual(stream.id, 991)
        XCTAssertEqual(stream.name, "Inception")
        XCTAssertEqual(stream.rating, "8.8")
        XCTAssertEqual(stream.plot, "A thief who steals corporate secrets...")
    }

    func testDefaultSessionUsesDedicatedNoCacheConfiguration() {
        let session = XtreamCodesClient.makeDefaultSession()
        XCTAssertFalse(session === URLSession.shared)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 60)
    }

    func testRetriesTransientCloudflareAndNetworkErrorsThenSucceeds() async throws {
        let script = RetryStubScript(steps: [
            .http(522, Data()),
            .http(524, Data()),
            .http(200, Data(#"[{"category_id":"1","category_name":"Sports"}]"#.utf8)),
        ])
        RetryStubURLProtocol.install(script)
        defer { RetryStubURLProtocol.install(nil) }

        let client = XtreamCodesClient(
            serverURLString: "https://provider.example.test",
            username: "fixture-user",
            password: "fixture-password",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )

        let categories = try await client.fetchLiveCategories()
        XCTAssertEqual(categories.map(\.name), ["Sports"])
        XCTAssertEqual(script.requestCount, 3)

        // Also verifies transient URLError(.timedOut) retries and succeeds.
        let netScript = RetryStubScript(steps: [
            .error(URLError(.timedOut)),
            .http(200, Data(#"[{"category_id":"2","category_name":"Movies"}]"#.utf8)),
        ])
        RetryStubURLProtocol.install(netScript)
        let vodCats = try await client.fetchVODCategories()
        XCTAssertEqual(vodCats.map(\.name), ["Movies"])
        XCTAssertEqual(netScript.requestCount, 2)
    }

    func testDoesNotRetryNonTransientHTTPStatusAndStopsAfterTwoRetries() async throws {
        let forbiddenScript = RetryStubScript(steps: [.http(403, Data())])
        RetryStubURLProtocol.install(forbiddenScript)
        defer { RetryStubURLProtocol.install(nil) }

        let client = XtreamCodesClient(
            serverURLString: "https://provider.example.test",
            username: "fixture-user",
            password: "fixture-password",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )

        do {
            _ = try await client.fetchLiveCategories()
            XCTFail("Expected HTTP 403 to throw immediately without retrying")
        } catch let XtreamError.serverError(code) {
            XCTAssertEqual(code, 403)
        }
        XCTAssertEqual(forbiddenScript.requestCount, 1)

        // Persistent 503 must stop after 2 retries (3 total requests).
        let outageScript = RetryStubScript(steps: [.http(503, Data()), .http(503, Data()), .http(503, Data()), .http(200, Data("[]".utf8))])
        RetryStubURLProtocol.install(outageScript)
        do {
            _ = try await client.fetchVODCategories()
            XCTFail("Expected HTTP 503 after bounded retries")
        } catch let XtreamError.serverError(code) {
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(outageScript.requestCount, 3)
    }

    func testRetriesHonorRetryAfterHeaderWhenPresent() async throws {
        let script = RetryStubScript(steps: [
            .httpWithHeaders(429, ["Retry-After": "4"], Data()),
            .http(503, Data()),
            .http(200, Data(#"[{"category_id":"1","category_name":"News"}]"#.utf8)),
        ])
        RetryStubURLProtocol.install(script)
        defer { RetryStubURLProtocol.install(nil) }

        let recordedDelays = RecordedRetryDelays()
        let client = XtreamCodesClient(
            serverURLString: "https://provider.example.test",
            username: "fixture-user",
            password: "fixture-password",
            session: makeRetryStubSession(),
            retrySleepWithDelay: { attempt, delay in
                recordedDelays.record(attempt: attempt, delay: delay)
            }
        )

        let categories = try await client.fetchLiveCategories()
        XCTAssertEqual(categories.map(\.name), ["News"])
        let delays = recordedDelays.snapshot()
        XCTAssertEqual(delays.count, 2)
        XCTAssertEqual(delays[0].attempt, 1)
        XCTAssertEqual(delays[0].delay, 4.0)
        XCTAssertEqual(delays[1].attempt, 2)
        XCTAssertNil(delays[1].delay)
    }

    func testDiskCatalogCacheServesFreshAndStaleWhileRevalidateAndInvalidates() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("brutv-disk-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let profileID = UUID()

        let firstPayload = Data(#"[{"stream_id":"101","num":"1","name":"News HD","category_id":"10","stream_icon":" https://img.example.test/news logo.png "},{"stream_id":102,"num":2,"name":"Sports 4K","category_id":20}]"#.utf8)
        let secondPayload = Data(#"[{"stream_id":103,"num":3,"name":"Movies FHD","category_id":"30"}]"#.utf8)

        let script = RetryStubScript(steps: [.http(200, firstPayload)])
        RetryStubURLProtocol.install(script)
        defer { RetryStubURLProtocol.install(nil) }

        // 1. Cold fetch populates disk cache and pre-indexes categories + IDs
        let client1 = XtreamCodesClient(
            serverURLString: "https://cache-test.example.test",
            username: "u",
            password: "p",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )
        client1.configureDiskCache(profileID: profileID, baseDirectory: tempDir, freshTTL: 900, staleTTL: 86_400)

        let all1 = try await client1.fetchLiveStreams()
        XCTAssertEqual(all1.map(\.id), [101, 102])
        XCTAssertEqual(script.requestCount, 1)

        // Category lookups and liveStreamIndex must hit pre-indexed RAM in O(1) without extra network calls.
        let cat10 = try await client1.fetchLiveStreams(categoryID: "10")
        XCTAssertEqual(cat10.map(\.id), [101])
        let emptyCat = try await client1.fetchLiveStreams(categoryID: "999")
        XCTAssertTrue(emptyCat.isEmpty)
        let index = try await client1.liveStreamIndex()
        XCTAssertEqual(index[102]?.quality, .uhd4k)
        XCTAssertEqual(script.requestCount, 1)

        // 2. Fresh cold-start client reads directly from disk cache with 0 network calls.
        let freshScript = RetryStubScript(steps: [.http(500, Data())])
        RetryStubURLProtocol.install(freshScript)
        let client2 = XtreamCodesClient(
            serverURLString: "https://cache-test.example.test",
            username: "u",
            password: "p",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )
        client2.configureDiskCache(profileID: profileID, baseDirectory: tempDir, freshTTL: 900, staleTTL: 86_400)
        let diskHit = try await client2.fetchLiveStreams()
        XCTAssertEqual(diskHit.map(\.id), [101, 102])
        XCTAssertEqual(freshScript.requestCount, 0)

        // 3. Stale-while-revalidate returns cached payload immediately and refreshes in background.
        let swrScript = RetryStubScript(steps: [.http(200, secondPayload)])
        RetryStubURLProtocol.install(swrScript)
        let client3 = XtreamCodesClient(
            serverURLString: "https://cache-test.example.test",
            username: "u",
            password: "p",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )
        client3.configureDiskCache(profileID: profileID, baseDirectory: tempDir, freshTTL: 0, staleTTL: 86_400)
        let staleImmediate = try await client3.fetchLiveStreams()
        XCTAssertEqual(staleImmediate.map(\.id), [101, 102])

        // Wait briefly for background revalidation to finish and update cache.
        for _ in 0..<20 where swrScript.requestCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(swrScript.requestCount, 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let revalidated = try await client3.fetchLiveStreams()
        XCTAssertEqual(revalidated.map(\.id), [103])

        // 4. Explicit clearCache(includeDisk: true) removes disk cache so next fetch hits network.
        let refreshScript = RetryStubScript(steps: [.http(200, firstPayload)])
        RetryStubURLProtocol.install(refreshScript)
        client3.clearCache(includeDisk: true)
        let afterClear = try await client3.fetchLiveStreams()
        XCTAssertEqual(afterClear.map(\.id), [101, 102])
        XCTAssertEqual(refreshScript.requestCount, 1)
    }

    func testInFlightCoalescingSharesSingleRequestAcrossConcurrentCallers() async throws {
        let payload = Data(#"[{"category_id":"1","category_name":"Sports"},{"category_id":"2","category_name":"News"}]"#.utf8)
        let script = RetryStubScript(steps: [.http(200, payload), .http(500, Data())], delayMs: 80)
        RetryStubURLProtocol.install(script)
        defer { RetryStubURLProtocol.install(nil) }

        let client = XtreamCodesClient(
            serverURLString: "https://coalesce.example.test",
            username: "u",
            password: "p",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )

        async let first = client.fetchLiveCategories()
        async let second = client.fetchLiveCategories()
        async let third = client.fetchLiveCategories()
        let results = try await (first, second, third)

        XCTAssertEqual(results.0.map(\.id), ["1", "2"])
        XCTAssertEqual(results.1.map(\.id), ["1", "2"])
        XCTAssertEqual(results.2.map(\.id), ["1", "2"])
        XCTAssertEqual(script.requestCount, 1, "Concurrent identical calls must coalesce into one network request")
    }

    func testBoundedLRUCacheEvictsLeastRecentlyUsedEntries() {
        var cache = BoundedLRUCache<Int, String>(capacity: 3)
        cache.set("a", for: 1)
        cache.set("b", for: 2)
        cache.set("c", for: 3)
        // Touch key 1 so key 2 becomes least recently used.
        XCTAssertEqual(cache.value(for: 1), "a")
        cache.set("d", for: 4)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 1), "a")
        XCTAssertEqual(cache.value(for: 3), "c")
        XCTAssertEqual(cache.value(for: 4), "d")
    }

    func testShortEPGDecodesBase64TitlesAndCachesResult() async throws {
        let titleB64 = Data("Evening News".utf8).base64EncodedString()
        let descB64 = Data("Top headlines tonight".utf8).base64EncodedString()
        let json = """
        {
          "epg_listings": [
            {
              "id": "55",
              "title": "\(titleB64)",
              "description": "\(descB64)",
              "start_timestamp": "1760000000",
              "stop_timestamp": "1760003600",
              "channel_id": "ch1"
            }
          ]
        }
        """
        let script = RetryStubScript(steps: [.http(200, Data(json.utf8))])
        RetryStubURLProtocol.install(script)
        defer { RetryStubURLProtocol.install(nil) }

        let client = XtreamCodesClient(
            serverURLString: "https://epg.example.test",
            username: "u",
            password: "p",
            session: makeRetryStubSession(),
            retrySleep: { _ in }
        )

        let listings = try await client.fetchShortEPG(streamID: 42, limit: 2)
        XCTAssertEqual(listings.count, 1)
        XCTAssertEqual(listings[0].title, "Evening News")
        XCTAssertEqual(listings[0].description, "Top headlines tonight")
        XCTAssertEqual(listings[0].startTimestamp, 1_760_000_000)
        XCTAssertEqual(listings[0].stopTimestamp, 1_760_003_600)
        XCTAssertFalse(listings[0].timeRangeString.isEmpty)

        // Second call within TTL must hit RAM cache.
        let cached = try await client.fetchShortEPG(streamID: 42, limit: 2)
        XCTAssertEqual(cached, listings)
        XCTAssertEqual(script.requestCount, 1)
    }

    func testFlexibleJSONDecodePrecomputedFieldsAndSeriesCoverURLSanitization() throws {
        let seriesJSON = Data("""
        [
          {
            "series_id": "777",
            "name": "São Paulo Stories",
            "cover": "  https://img.example.test/my cover.jpg  ",
            "rating": "8.7/10",
            "category_id": 42
          },
          {
            "series_id": 778,
            "name": "Null Fields Show",
            "cover": null,
            "rating": 9.2,
            "category_id": "43"
          }
        ]
        """.utf8)

        let items = try SeriesItem.decodeArray(from: seriesJSON)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, 777)
        XCTAssertEqual(items[0].categoryId, "42")
        XCTAssertEqual(items[0].ratingValue, 8.7, accuracy: 0.001)
        XCTAssertEqual(items[0].normalizedSearchText, "sao paulo stories")
        XCTAssertEqual(items[0].coverURL?.absoluteString, "https://img.example.test/my%20cover.jpg")
        XCTAssertEqual(items[1].id, 778)
        XCTAssertEqual(items[1].ratingValue, 9.2, accuracy: 0.001)
        XCTAssertNil(items[1].coverURL)

        // Single-pass M3U parser produces identical deduplicated LiveStreams as legacy flow.
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="c1" group-title="Sports",Channel One FHD
        https://cdn.example/live/1.m3u8
        #EXTINF:-1 tvg-id="c1" group-title="Sports",Channel One Duplicate
        https://cdn.example/live/1.m3u8
        #EXTINF:-1 group-title="Movies",Movie One
        https://cdn.example/movie/99.mp4
        """
        let streams = try M3UPlaylistParser.parseLiveStreamsValidated(Data(m3u.utf8))
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0].cleanName, "Channel One")
        XCTAssertEqual(streams[0].quality, .fhd)
        XCTAssertEqual(streams[0].categoryId, "Sports")
    }
}

private final class RecordedRetryDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(attempt: Int, delay: TimeInterval?)] = []

    func record(attempt: Int, delay: TimeInterval?) {
        lock.lock()
        entries.append((attempt, delay))
        lock.unlock()
    }

    func snapshot() -> [(attempt: Int, delay: TimeInterval?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private enum RetryStubStep {
    case http(Int, Data)
    case httpWithHeaders(Int, [String: String], Data)
    case error(Error)
}

private final class RetryStubScript: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [RetryStubStep]
    private var count = 0
    let delayMs: UInt32

    init(steps: [RetryStubStep], delayMs: UInt32 = 0) {
        self.steps = steps
        self.delayMs = delayMs
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() -> RetryStubStep {
        if delayMs > 0 {
            usleep(delayMs * 1000)
        }
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return steps.isEmpty ? .http(500, Data()) : steps.removeFirst()
    }
}

private final class RetryStubURLProtocol: URLProtocol {
    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var script: RetryStubScript?

        func set(_ script: RetryStubScript?) {
            lock.lock()
            self.script = script
            lock.unlock()
        }

        func next() -> RetryStubStep {
            lock.lock()
            let s = script
            lock.unlock()
            return s?.next() ?? .http(500, Data())
        }
    }

    private static let holder = Holder()
    static func install(_ script: RetryStubScript?) { holder.set(script) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch Self.holder.next() {
        case .error(let err):
            client?.urlProtocol(self, didFailWithError: err)
        case .http(let status, let data):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .httpWithHeaders(let status, let headers, let data):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private func makeRetryStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RetryStubURLProtocol.self]
    return URLSession(configuration: config)
}
