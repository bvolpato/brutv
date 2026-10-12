import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BruTV

final class SourceRegressionTests: XCTestCase {
    func testGetPhpLoginPreservesPanelPrefixAndEncodedPlusCredentials() {
        let link = LoginLink.fromPlaylistURL(
            "https://provider.example/panel/get.php?username=user%2Btag&password=pass%2Bword&type=m3u_plus"
        )

        XCTAssertEqual(
            link,
            .xtream(server: "https://provider.example/panel", username: "user+tag", password: "pass+word")
        )
    }

    func testStreamURLsEncodeCredentialPathSegmentsAndRejectZeroIDs() {
        let client = XtreamCodesClient(
            serverURLString: "https://provider.example/panel",
            username: "user/name+tag",
            password: "pass word/secret+"
        )

        XCTAssertEqual(
            client.liveStreamURL(streamID: 17)?.absoluteString,
            "https://provider.example/panel/live/user%2Fname%2Btag/pass%20word%2Fsecret%2B/17.m3u8"
        )
        XCTAssertEqual(
            client.vodStreamURL(streamID: 17, containerExtension: "mkv")?.absoluteString,
            "https://provider.example/panel/movie/user%2Fname%2Btag/pass%20word%2Fsecret%2B/17.mkv"
        )
        XCTAssertNil(client.liveStreamURL(streamID: 0))
    }

    func testAPIQueryPercentEncodesLiteralPlusInCredentials() async throws {
        let requests = RequestLog()
        StubURLProtocol.install { request in
            requests.append(request)
            return StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        defer { StubURLProtocol.install(nil) }
        let client = XtreamCodesClient(
            serverURLString: "https://provider.example/panel",
            username: "user+tag",
            password: "pass+word",
            session: makeStubSession()
        )

        _ = try await client.fetchLiveStreams()

        let requestURL = try XCTUnwrap(requests.requests.first?.url)
        let query = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(query.contains("username=user%2Btag"), query)
        XCTAssertTrue(query.contains("password=pass%2Bword"), query)
    }

    func testXtreamCatalogsFilterMalformedZeroAndDuplicateIDsKeepingFirst() async throws {
        StubURLProtocol.install { request in
            let action = request.url.flatMap { url in
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "action" })?.value
            }
            let body: String
            switch action {
            case "get_live_categories":
                body = #"[{"category_id":"bad","category_name":"Malformed"},{"category_id":"0","category_name":"Zero"},{"category_id":"2","category_name":"First live group"},{"category_id":2,"category_name":"Duplicate live group"}]"#
            case "get_live_streams":
                body = #"[{"stream_id":"bad","name":"Malformed"},{"stream_id":0,"name":"Zero"},{"stream_id":"17","name":"First live"},{"stream_id":17,"name":"Duplicate live"}]"#
            case "get_vod_categories":
                body = #"[{"category_id":"0","category_name":"Zero"},{"category_id":"3","category_name":"First movie group"},{"category_id":3,"category_name":"Duplicate movie group"}]"#
            case "get_vod_streams":
                body = #"[{"stream_id":"broken","name":"Malformed"},{"stream_id":"0","name":"Zero"},{"stream_id":31,"name":"First movie"},{"stream_id":"31","name":"Duplicate movie"}]"#
            case "get_series_categories":
                body = #"[{"category_id":"oops","category_name":"Malformed"},{"category_id":4,"category_name":"First series group"},{"category_id":"4","category_name":"Duplicate series group"}]"#
            case "get_series":
                body = #"[{"series_id":"bad","name":"Malformed"},{"series_id":0,"name":"Zero"},{"series_id":"41","name":"First series"},{"series_id":41,"name":"Duplicate series"}]"#
            default:
                body = "[]"
            }
            return StubResponse(statusCode: 200, body: Data(body.utf8))
        }
        defer { StubURLProtocol.install(nil) }
        let client = XtreamCodesClient(
            serverURLString: "https://provider.example",
            username: "dummy-user",
            password: "dummy-pass",
            session: makeStubSession()
        )

        let liveCategories = try await client.fetchLiveCategories()
        let live = try await client.fetchLiveStreams()
        let vodCategories = try await client.fetchVODCategories()
        let movies = try await client.fetchVODStreams()
        let seriesCategories = try await client.fetchSeriesCategories()
        let series = try await client.fetchSeries()

        XCTAssertEqual(liveCategories.map(\.id), ["2"])
        XCTAssertEqual(liveCategories.first?.name, "First live group")
        XCTAssertEqual(live.map(\.id), [17])
        XCTAssertEqual(live.first?.name, "First live")
        XCTAssertEqual(vodCategories.map(\.id), ["3"])
        XCTAssertEqual(vodCategories.first?.name, "First movie group")
        XCTAssertEqual(movies.map(\.id), [31])
        XCTAssertEqual(movies.first?.name, "First movie")
        XCTAssertEqual(seriesCategories.map(\.id), ["4"])
        XCTAssertEqual(seriesCategories.first?.name, "First series group")
        XCTAssertEqual(series.map(\.id), [41])
        XCTAssertEqual(series.first?.name, "First series")
    }

    func testHLSMediaManifestIsRejectedAsAnIPTVPlaylist() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        https://cdn.example/segment.ts
        #EXT-X-ENDLIST
        """
        XCTAssertThrowsError(try M3UPlaylistParser.parseValidated(Data(playlist.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("HLS"), error.localizedDescription)
        }
        StubURLProtocol.install { _ in
            return StubResponse(statusCode: 200, body: Data(playlist.utf8))
        }
        defer { StubURLProtocol.install(nil) }
        let client = XtreamCodesClient(session: makeStubSession())
        client.updatePlaylist(url: "https://provider.example/list.m3u")

        do {
            _ = try await client.loadPlaylist()
            XCTFail("An HLS media manifest must not be presented as a channel list")
        } catch let XtreamError.decodingError(message) {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("HLS"), message)
        }
    }

    func testOldInFlightCatalogCannotPopulateCacheAfterSourceSwitch() async throws {
        let gate = RequestGate()
        let requests = RequestLog()
        StubURLProtocol.install { request in
            requests.append(request)
            if request.url?.host == "old.example" {
                gate.entered.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                return StubResponse(statusCode: 200, body: Data(#"[{"stream_id":11,"name":"Old source"}]"#.utf8))
            }
            return StubResponse(statusCode: 200, body: Data(#"[{"stream_id":22,"name":"New source"}]"#.utf8))
        }
        defer {
            gate.release.signal()
            StubURLProtocol.install(nil)
        }
        let client = XtreamCodesClient(
            serverURLString: "https://old.example",
            username: "old-user",
            password: "old-pass",
            session: makeStubSession()
        )

        let oldRequest = Task { try await client.fetchLiveStreams() }
        let started = await Task.detached(priority: .utility) {
            gate.entered.wait(timeout: .now() + 5) == .success
        }.value
        XCTAssertTrue(started, "The old source request should reach the URL stub")
        client.updateCredentials(serverURL: "https://new.example", user: "new-user", pass: "new-pass")
        gate.release.signal()
        do {
            _ = try await oldRequest.value
        } catch is CancellationError {
            // A transport that cancels requests when its source is replaced is also valid.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports request cancellation as URLError on some platforms.
        }

        let newResult = try await client.fetchLiveStreams()

        XCTAssertEqual(newResult.map(\.id), [22])
        XCTAssertEqual(newResult.first?.name, "New source")
        XCTAssertTrue(requests.requests.contains { $0.url?.host == "new.example" })
    }

    func testIndependentClientStartsBlankAndUsesInjectedSession() async throws {
        let requests = RequestLog()
        StubURLProtocol.install { request in
            requests.append(request)
            return StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        defer { StubURLProtocol.install(nil) }
        let active = XtreamCodesClient(
            serverURLString: "https://active.example",
            username: "active-user",
            password: "active-pass",
            session: makeStubSession()
        )
        let candidate = active.makeIndependentClient()

        XCTAssertEqual(candidate.serverURLString, "")
        XCTAssertEqual(candidate.username, "")
        XCTAssertEqual(candidate.password, "")
        candidate.updateCredentials(serverURL: "https://candidate.example", user: "candidate-user", pass: "candidate-pass")
        _ = try await candidate.fetchLiveStreams()
        XCTAssertEqual(requests.requests.first?.url?.host, "candidate.example")
    }

    func testAdoptingLoadedPlaylistReusesItsCache() async throws {
        let requests = RequestLog()
        StubURLProtocol.install { request in
            requests.append(request)
            let playlist = "#EXTM3U\n#EXTINF:-1,Family channel\nhttps://cdn.example/family.m3u8\n"
            return StubResponse(statusCode: 200, body: Data(playlist.utf8))
        }
        defer { StubURLProtocol.install(nil) }
        let session = makeStubSession()
        let active = XtreamCodesClient(session: session)
        let candidate = active.makeIndependentClient()
        candidate.updatePlaylist(url: "https://provider.example/list.m3u")

        let imported = try await candidate.loadPlaylist()
        active.adoptSource(from: candidate)
        let adopted = try await active.loadPlaylist()

        XCTAssertEqual(imported, adopted)
        XCTAssertTrue(active.isPlaylistMode)
        XCTAssertEqual(active.playlistURLString, "https://provider.example/list.m3u")
        XCTAssertEqual(requests.requests.count, 1)
    }
}

private struct StubResponse {
    let statusCode: Int
    let body: Data
}

private final class StubURLProtocol: URLProtocol {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((URLRequest) -> StubResponse)?

        func install(_ handler: ((URLRequest) -> StubResponse)?) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
        }

        func respond(to request: URLRequest) -> StubResponse {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            return handler?(request) ?? StubResponse(statusCode: 500, body: Data())
        }
    }

    private static let storage = Storage()

    static func install(_ handler: ((URLRequest) -> StubResponse)?) {
        storage.install(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = Self.storage.respond(to: request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedRequests.append(request)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }
}

private final class RequestGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}
