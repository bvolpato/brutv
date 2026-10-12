import Foundation
import XCTest
@testable import BruTV

@MainActor
final class AccountFlowTests: XCTestCase {
    func testLogoutCancelsPendingLoginWithoutReactivatingTheSource() async {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let request = AccountRequestSlot(expectation(description: "Login request started"))
        fixture.handleRequests { request.capture($0) }
        let account = fixture.makeAccount()
        let login = Task { try await account.login(serverURL: fixture.server, username: "old", password: "test") }
        await fulfillment(of: [request.started], timeout: 3)

        account.logout()
        request.respond(auth: 1)
        await assertCancelled(login)

        XCTAssertFalse(account.isAuthenticated)
        XCTAssertNil(account.currentProfile)
        XCTAssertNil(account.authResponse)
        XCTAssertFalse(account.isLoading)
        XCTAssertNil(account.errorMessage)
        XCTAssertEqual(account.client.serverURLString, "")
        XCTAssertTrue(fixture.favorites.favoriteChannelIDs.isEmpty)
    }

    func testOlderLoginCannotClearLoadingOrReplaceNewerLogin() async throws {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let oldRequest = AccountRequestSlot(expectation(description: "Old login started"))
        let newRequest = AccountRequestSlot(expectation(description: "New login started"))
        fixture.handleRequests { protocolInstance in
            (protocolInstance.requestUsername == "old" ? oldRequest : newRequest).capture(protocolInstance)
        }
        let account = fixture.makeAccount()
        let oldLogin = Task { try await account.login(serverURL: fixture.server, username: "old", password: "test") }
        await fulfillment(of: [oldRequest.started], timeout: 3)
        let newLogin = Task { try await account.login(serverURL: fixture.server, username: "new", password: "test") }
        await fulfillment(of: [newRequest.started], timeout: 3)
        await assertCancelled(oldLogin)

        XCTAssertTrue(account.isLoading)
        XCTAssertNil(account.errorMessage)
        XCTAssertEqual(account.client.serverURLString, "")
        oldRequest.respond(auth: 1)
        newRequest.respond(auth: 1)
        try await newLogin.value

        XCTAssertEqual(account.currentProfile?.username, "new")
        XCTAssertEqual(account.authResponse?.userInfo.username, "new")
        XCTAssertEqual(account.client.username, "new")
        XCTAssertEqual(account.savedProfiles.map(\.username), ["new"])
        XCTAssertFalse(account.isLoading)
    }

    func testStaleRestoreRejectionCannotLogOutNewerSource() async throws {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let oldProfile = ServerProfile(serverURL: fixture.server, username: "old", password: "test")
        try fixture.persist(oldProfile)
        let restoreRequest = AccountRequestSlot(expectation(description: "Restore started"))
        let loginRequest = AccountRequestSlot(expectation(description: "New login started"))
        fixture.handleRequests { protocolInstance in
            (protocolInstance.requestUsername == "old" ? restoreRequest : loginRequest).capture(protocolInstance)
        }
        let account = fixture.makeAccount()
        await fulfillment(of: [restoreRequest.started], timeout: 3)
        let login = Task { try await account.login(serverURL: fixture.server, username: "new", password: "test") }
        await fulfillment(of: [loginRequest.started], timeout: 3)
        loginRequest.respond(auth: 1)
        try await login.value
        restoreRequest.respond(auth: 0)
        await Task.yield()

        XCTAssertTrue(account.isAuthenticated)
        XCTAssertEqual(account.currentProfile?.username, "new")
        XCTAssertEqual(account.authResponse?.userInfo.username, "new")
        XCTAssertEqual(account.client.username, "new")
        XCTAssertNil(account.errorMessage)
    }

    func testCallerCancellationDoesNotActivateOrPublishAnError() async {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let request = AccountRequestSlot(expectation(description: "Login started"))
        fixture.handleRequests { request.capture($0) }
        let account = fixture.makeAccount()
        let login = Task { try await account.login(serverURL: fixture.server, username: "cancelled", password: "test") }
        await fulfillment(of: [request.started], timeout: 3)
        login.cancel()
        await assertCancelled(login)

        XCTAssertNil(account.currentProfile)
        XCTAssertFalse(account.isAuthenticated)
        XCTAssertFalse(account.isLoading)
        XCTAssertNil(account.errorMessage)
        XCTAssertEqual(account.client.username, "")
    }

    func testFailedSignInPreservesThePreviouslyActiveSourceAndLibrary() async throws {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let original = ServerProfile.playlist(url: "https://playlist.example/family.m3u")
        try fixture.persist(original)
        fixture.favorites.selectSource(original.id)
        fixture.favorites.toggleFavorite(channelID: 7)
        fixture.handleRequests { $0.respond(auth: 0) }
        let account = fixture.makeAccount()
        do {
            try await account.login(serverURL: fixture.server, username: "rejected", password: "test")
            XCTFail("A rejected login must throw")
        } catch XtreamError.authenticationFailed {
        }

        XCTAssertTrue(account.isAuthenticated)
        XCTAssertEqual(account.currentProfile?.id, original.id)
        XCTAssertEqual(account.client.playlistURLString, original.playlistURL)
        XCTAssertEqual(fixture.favorites.favoriteChannelIDs, [7])
        XCTAssertNotNil(account.errorMessage)
    }

    func testSavedSourceKeepsItsIdentityAndLibraryAfterSigningInAgain() async throws {
        let fixture = AccountFixture()
        defer { fixture.cleanUp() }
        let original = ServerProfile(
            name: "Family", serverURL: "HTTPS://\(fixture.host.uppercased()):443/",
            username: "test", password: "test"
        )
        try fixture.persist(original)
        fixture.favorites.selectSource(original.id)
        fixture.favorites.toggleFavorite(channelID: 7)
        fixture.favorites.addRecent(channelID: 9)
        fixture.handleRequests { $0.respond(auth: 1) }
        let account = fixture.makeAccount(restore: false)

        try await account.login(playlistURL: "\(fixture.server):443/get.php?username=test&password=test&type=m3u_plus")
        XCTAssertEqual(account.currentProfile?.id, original.id)
        XCTAssertEqual(account.currentProfile?.name, "Family")
        XCTAssertEqual(account.savedProfiles.count, 1)
        XCTAssertEqual(fixture.favorites.favoriteChannelIDs, [7])
        account.logout()
        try await account.login(serverURL: fixture.server, username: "test", password: "test")
        XCTAssertEqual(account.currentProfile?.id, original.id)
        XCTAssertEqual(fixture.favorites.favoriteChannelIDs, [7])
        XCTAssertEqual(fixture.favorites.recentChannelIDs, [9])
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("An obsolete or cancelled login must not succeed", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }
}

@MainActor
private final class AccountFixture {
    let suiteName: String
    let host: String
    let defaults: UserDefaults
    let favorites: FavoritesStore
    let session: URLSession
    var server: String { "https://\(host)" }

    init() {
        let suite = "BruTV.AccountFlowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        suiteName = suite
        host = "account-\(UUID().uuidString.lowercased()).example"
        defaults = preferences
        favorites = FavoritesStore(userDefaults: preferences)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledAccountProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func persist(_ profile: ServerProfile) throws {
        defaults.set(try JSONEncoder().encode(profile), forKey: "brutv.account.currentProfile")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "brutv.account.savedProfiles")
    }

    func handleRequests(_ handler: @escaping (ControlledAccountProtocol) -> Void) {
        ControlledAccountProtocol.register(host: host, handler: handler)
    }

    func makeAccount(restore: Bool = true) -> AccountStore {
        AccountStore(
            client: XtreamCodesClient(session: session), userDefaults: defaults,
            favorites: favorites, shouldRestoreSession: restore
        )
    }

    func cleanUp() {
        session.invalidateAndCancel()
        ControlledAccountProtocol.unregister(host: host)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class AccountRequestSlot: @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var request: ControlledAccountProtocol?

    init(_ started: XCTestExpectation) { self.started = started }

    func capture(_ request: ControlledAccountProtocol) {
        lock.lock()
        self.request = request
        lock.unlock()
        started.fulfill()
    }

    func respond(auth: Int) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.respond(auth: auth)
    }
}

private final class ControlledAccountProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var handlers: [String: (ControlledAccountProtocol) -> Void] = [:]
    private let responseLock = NSLock()
    private var stopped = false

    var requestUsername: String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "username" })?.value ?? ""
    }

    static func register(host: String, handler: @escaping (ControlledAccountProtocol) -> Void) {
        registryLock.lock()
        handlers[host] = handler
        registryLock.unlock()
    }

    static func unregister(host: String) {
        registryLock.lock()
        handlers.removeValue(forKey: host)
        registryLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return request.url?.host.map { handlers[$0] != nil } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.registryLock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.registryLock.unlock()
        handler?(self)
    }

    override func stopLoading() {
        responseLock.lock()
        stopped = true
        responseLock.unlock()
    }

    func respond(auth: Int) {
        responseLock.lock()
        guard !stopped else {
            responseLock.unlock()
            return
        }
        stopped = true
        responseLock.unlock()
        let response = AuthResponse(userInfo: UserInfo(username: requestUsername, auth: auth), serverInfo: ServerInfo())
        let data = try! JSONEncoder().encode(response)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
