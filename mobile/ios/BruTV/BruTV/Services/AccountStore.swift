import Foundation
import Combine
#if canImport(Security)
import Security
#endif

/// Stores per-profile sensitive secrets (Xtream passwords and credentialed M3U URLs) in Keychain
/// on Apple platforms, with graceful fallback when Keychain entitlements are absent in unsigned test hosts.
private enum AccountCredentialVault {
    struct SecretPayload: Codable {
        var password: String
        var playlistURL: String?
    }

    #if canImport(Security)
    private static let service = "com.bvolpato.brutv.credentials"

    @discardableResult
    static func save(_ payload: SecretPayload, for profileID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        let account = profileID.uuidString
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    static func load(for profileID: UUID) -> SecretPayload? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SecretPayload.self, from: data)
    }

    static func delete(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #else
    @discardableResult
    static func save(_ payload: SecretPayload, for profileID: UUID) -> Bool { false }
    static func load(for profileID: UUID) -> SecretPayload? { nil }
    static func delete(for profileID: UUID) {}
    #endif

    /// Redacts credentials/query tokens from a playlist URL before storing metadata in UserDefaults.
    static func redactedPlaylistDisplayURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), let host = components.host else {
            return ""
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? host
    }
}

@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore(client: makeApplicationClient())

    private static func makeApplicationClient() -> XtreamCodesClient {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let hasProvider = ["BRUTV_PLAYBACK_SERVER", "BRUTV_PLAYBACK_USERNAME", "BRUTV_PLAYBACK_PASSWORD"]
            .allSatisfy { !(environment[$0] ?? "").isEmpty }
        let isDemo = arguments.contains("--demo-login") || arguments.contains("--play-demo")
        if arguments.contains("--ui-fixtures") || (isDemo && !hasProvider) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UITestSourceProtocol.self]
            return XtreamCodesClient(session: URLSession(configuration: configuration))
        }
        #endif
        return XtreamCodesClient()
    }

    @Published public private(set) var currentProfile: ServerProfile?
    @Published public private(set) var authResponse: AuthResponse?
    @Published public private(set) var savedProfiles: [ServerProfile] = []
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?
    /// Incremented whenever the user explicitly refreshes catalog listings so mounted tabs reload.
    @Published public private(set) var catalogRefreshRevision: UInt64 = 0

    public let client: XtreamCodesClient

    private let defaults: UserDefaults
    private let favorites: FavoritesStore
    private let useKeychain: Bool
    private let userDefaultsKey = "brutv.account.currentProfile"
    private let profilesKey = "brutv.account.savedProfiles"
    private var generation = UUID()
    private var restoreTask: Task<Void, Never>?
    private var loginTask: Task<AuthResponse?, Error>?

    public init(
        client: XtreamCodesClient = XtreamCodesClient(),
        userDefaults: UserDefaults = .standard,
        favorites: FavoritesStore? = nil,
        shouldRestoreSession: Bool = true
    ) {
        self.client = client
        self.defaults = userDefaults
        self.favorites = favorites ?? FavoritesStore.shared
        self.useKeychain = (userDefaults === UserDefaults.standard)
        if ProcessInfo.processInfo.arguments.contains("--reset-session") {
            userDefaults.removeObject(forKey: userDefaultsKey)
        }
        loadPersistedState()
        self.favorites.selectSource(currentProfile?.id)
        if userDefaults === UserDefaults.standard {
            WatchProgressStore.shared.selectSource(currentProfile?.id)
            TopShelfStore.shared.selectProfile(currentProfile?.id)
            client.configureDiskCache(profileID: currentProfile?.id)
        }
        if shouldRestoreSession {
            restoreSession()
        }
    }

    private func hydrateFromKeychain(_ profile: ServerProfile) -> (profile: ServerProfile, migrated: Bool) {
        guard useKeychain else { return (profile, false) }
        var hydrated = profile
        var migrated = false

        if let secret = AccountCredentialVault.load(for: profile.id) {
            if hydrated.kind == .xtream {
                if hydrated.password.isEmpty {
                    hydrated.password = secret.password
                } else {
                    // Legacy plaintext password still existed in UserDefaults; overwrite Keychain and scrub UserDefaults.
                    if AccountCredentialVault.save(
                        AccountCredentialVault.SecretPayload(password: hydrated.password, playlistURL: nil),
                        for: profile.id
                    ) {
                        migrated = true
                    }
                }
            } else if hydrated.kind == .m3u, let fullPlaylist = secret.playlistURL, !fullPlaylist.isEmpty {
                hydrated.playlistURL = fullPlaylist
                hydrated.serverURL = fullPlaylist
            }
        } else {
            // Transparently migrate plaintext UserDefaults credentials into Keychain.
            let payload = AccountCredentialVault.SecretPayload(
                password: hydrated.password,
                playlistURL: hydrated.kind == .m3u ? (hydrated.playlistURL ?? hydrated.serverURL) : nil
            )
            let hasSecret = !payload.password.isEmpty || (payload.playlistURL != nil && !(payload.playlistURL!.isEmpty))
            if hasSecret, AccountCredentialVault.save(payload, for: profile.id) {
                migrated = true
            }
        }
        return (hydrated, migrated)
    }

    private func scrubForDefaults(_ profile: ServerProfile) -> ServerProfile {
        guard useKeychain else { return profile }
        let payload = AccountCredentialVault.SecretPayload(
            password: profile.password,
            playlistURL: profile.kind == .m3u ? (profile.playlistURL ?? profile.serverURL) : nil
        )
        let savedToKeychain = AccountCredentialVault.save(payload, for: profile.id)
        guard savedToKeychain else {
            // Keep credentials in UserDefaults only if Keychain is unavailable (e.g. unsigned test host).
            return profile
        }
        var sanitized = profile
        sanitized.password = ""
        if sanitized.kind == .m3u {
            let redacted = AccountCredentialVault.redactedPlaylistDisplayURL(profile.playlistURL ?? profile.serverURL)
            sanitized.playlistURL = redacted
            sanitized.serverURL = redacted
        }
        return sanitized
    }

    private func loadPersistedState() {
        var needsMigrationRewrite = false
        if let data = defaults.data(forKey: userDefaultsKey),
           let profile = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            let result = hydrateFromKeychain(profile)
            currentProfile = result.profile
            needsMigrationRewrite = needsMigrationRewrite || result.migrated
        }
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            var hydratedProfiles: [ServerProfile] = []
            hydratedProfiles.reserveCapacity(profiles.count)
            for profile in profiles {
                let result = hydrateFromKeychain(profile)
                hydratedProfiles.append(result.profile)
                needsMigrationRewrite = needsMigrationRewrite || result.migrated
            }
            savedProfiles = hydratedProfiles
        }
        if needsMigrationRewrite {
            persistState()
        }
    }

    private func persistState() {
        if let currentProfile {
            let sanitized = scrubForDefaults(currentProfile)
            if let data = try? JSONEncoder().encode(sanitized) {
                defaults.set(data, forKey: userDefaultsKey)
            }
        } else {
            defaults.removeObject(forKey: userDefaultsKey)
        }
        let sanitizedProfiles = savedProfiles.map { scrubForDefaults($0) }
        if let data = try? JSONEncoder().encode(sanitizedProfiles) {
            defaults.set(data, forKey: profilesKey)
        }
    }

    private func beginSessionChange() -> UUID {
        restoreTask?.cancel()
        restoreTask = nil
        loginTask?.cancel()
        loginTask = nil
        generation = UUID()
        return generation
    }

    /// Reopens the last session without a login screen. Only a definite auth rejection signs out.
    private func restoreSession() {
        guard let profile = currentProfile else { return }
        let token = beginSessionChange()
        let candidate = client.makeIndependentClient()
        configure(candidate, for: profile)
        if defaults === UserDefaults.standard {
            candidate.configureDiskCache(profileID: profile.id)
        }
        client.adoptSource(from: candidate)
        isAuthenticated = true
        guard profile.kind == .xtream else { return }

        restoreTask = Task { [weak self] in
            do {
                let response = try await candidate.authenticate()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.authResponse = response
                self.restoreTask = nil
            } catch XtreamError.authenticationFailed {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.logout()
            } catch {
                guard let self, self.generation == token else { return }
                self.restoreTask = nil
                // Offline or server hiccup: keep the persisted session.
            }
        }
    }

    private func configure(_ client: XtreamCodesClient, for profile: ServerProfile) {
        switch profile.kind {
        case .xtream:
            client.updateCredentials(serverURL: profile.serverURL, user: profile.username, pass: profile.password)
        case .m3u:
            client.updatePlaylist(url: profile.playlistURL ?? profile.serverURL)
        }
    }

    // MARK: - Sign in

    public func login(serverURL: String, username: String, password: String, saveProfile: Bool = true) async throws {
        let candidate = client.makeIndependentClient()
        candidate.updateCredentials(serverURL: serverURL, user: username, pass: password)
        let profile = ServerProfile(
            name: candidate.username,
            serverURL: candidate.serverURLString,
            username: candidate.username,
            password: candidate.password,
            lastConnected: Date(),
            isActive: true
        )
        try await signIn(candidate: candidate, profile: profile, saveProfile: saveProfile)
    }

    /// Xtream `get.php` playlist URLs use the Xtream API instead.
    public func login(playlistURL: String, saveProfile: Bool = true) async throws {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .xtream(server, user, pass) = LoginLink.fromPlaylistURL(trimmed) {
            try await login(serverURL: server, username: user, password: pass, saveProfile: saveProfile)
            return
        }
        let candidate = client.makeIndependentClient()
        candidate.updatePlaylist(url: trimmed)
        try await signIn(candidate: candidate, profile: .playlist(url: trimmed), saveProfile: saveProfile)
    }

    private func signIn(candidate: XtreamCodesClient, profile: ServerProfile, saveProfile: Bool) async throws {
        try Task.checkCancellation()
        let token = beginSessionChange()
        isLoading = true
        errorMessage = nil
        defer {
            if generation == token {
                isLoading = false
                loginTask = nil
            }
        }

        let task = Task<AuthResponse?, Error> {
            try Task.checkCancellation()
            switch profile.kind {
            case .xtream:
                return try await candidate.authenticate()
            case .m3u:
                try await candidate.loadPlaylist()
                return nil
            }
        }
        loginTask = task
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            client.adoptSource(from: candidate)
            authResponse = response
            activate(profile, save: saveProfile)
        } catch {
            guard generation == token, !Task.isCancelled, !task.isCancelled else {
                throw CancellationError()
            }
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Signs in from a scanned QR code or opened `brutv://login` link.
    public func login(link: LoginLink) async throws {
        switch link {
        case let .xtream(server, username, password):
            try await login(serverURL: server, username: username, password: password)
        case let .m3u(url):
            try await login(playlistURL: url)
        }
    }

    public func login(profile: ServerProfile) async throws {
        try await login(link: profile.loginLink)
    }

    public func switchProfile(to profile: ServerProfile) async throws {
        if currentProfile?.id == profile.id && isAuthenticated { return }
        try await login(profile: profile)
    }

    public func renameProfile(_ profile: ServerProfile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) {
            savedProfiles[idx].name = trimmed
        }
        if currentProfile?.id == profile.id {
            currentProfile?.name = trimmed
        }
        persistState()
    }

    public func deleteProfile(_ profile: ServerProfile) {
        savedProfiles.removeAll { $0.id == profile.id }
        if useKeychain {
            AccountCredentialVault.delete(for: profile.id)
        }
        if defaults === UserDefaults.standard {
            client.clearDiskCache(for: profile.id)
            WatchProgressStore.shared.clear(sourceID: profile.id)
            TopShelfStore.shared.clearProfile(profile.id)
        }
        if currentProfile?.id == profile.id {
            logout()
        } else {
            persistState()
        }
    }

    /// Clears RAM & on-disk catalog caches and broadcasts a refresh revision so mounted tabs reload.
    public func refreshCatalog() {
        client.clearCache(includeDisk: true)
        catalogRefreshRevision &+= 1
    }

    #if DEBUG
    public func loginWithDemo() async throws {
        let demo = ServerProfile.demo
        try await login(
            serverURL: demo.serverURL,
            username: demo.username,
            password: demo.password,
            saveProfile: true
        )
    }
    #endif

    private func existingProfile(for profile: ServerProfile) -> ServerProfile? {
        let profiles = (currentProfile.map { [$0] } ?? []) + savedProfiles
        return profiles.first { $0.sameSource(as: profile) }
    }

    private func activate(_ candidate: ServerProfile, save: Bool) {
        let existing = existingProfile(for: candidate)
        let profile = ServerProfile(
            id: existing?.id ?? candidate.id,
            name: existing?.name ?? candidate.name,
            serverURL: candidate.serverURL,
            username: candidate.username,
            password: candidate.password,
            lastConnected: candidate.lastConnected,
            isActive: true,
            kind: candidate.kind,
            playlistURL: candidate.playlistURL
        )
        currentProfile = profile
        favorites.selectSource(profile.id)
        if defaults === UserDefaults.standard {
            WatchProgressStore.shared.selectSource(profile.id)
            TopShelfStore.shared.selectProfile(profile.id)
            client.configureDiskCache(profileID: profile.id)
        }
        isAuthenticated = true
        if save {
            var profiles = savedProfiles.filter { $0.id != profile.id && !$0.sameSource(as: profile) }
            profiles.insert(profile, at: 0)
            savedProfiles = profiles
        }
        persistState()
    }

    public func logout() {
        _ = beginSessionChange()
        isLoading = false
        errorMessage = nil
        isAuthenticated = false
        authResponse = nil
        currentProfile = nil
        favorites.selectSource(nil)
        if defaults === UserDefaults.standard {
            WatchProgressStore.shared.selectSource(nil)
            TopShelfStore.shared.selectProfile(nil)
            client.configureDiskCache(profileID: nil)
        }
        defaults.removeObject(forKey: userDefaultsKey)
        client.adoptSource(from: client.makeIndependentClient())
    }
}

#if DEBUG
/// Offline transport used only by explicitly launched UI tests.
private final class UITestSourceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "ui-fixture.example.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let body: Data
            if url.path.hasSuffix(".m3u") {
                body = Data("""
                #EXTM3U
                #EXTINF:-1 tvg-id="fixture-1" group-title="General",Fixture One HD
                \(try Self.audioURL().absoluteString)
                #EXTINF:-1 tvg-id="fixture-2" group-title="General",Fixture Two HD
                \(try Self.audioURL().absoluteString)
                """.utf8)
            } else {
                let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "action" })?.value
                let object: Any
                switch action {
                case "get_live_categories":
                    object = [["category_id": "general", "category_name": "General"]]
                case "get_live_streams":
                    let audio = try Self.audioURL().absoluteString
                    object = [
                        ["stream_id": 1, "name": "Fixture One HD", "category_id": "general", "brutv_direct_url": audio],
                        ["stream_id": 2, "name": "Fixture Two HD", "category_id": "general", "brutv_direct_url": audio],
                    ]
                case "get_vod_categories", "get_vod_streams", "get_series_categories", "get_series":
                    object = []
                case "get_short_epg":
                    object = ["epg_listings": []]
                case nil:
                    object = ["user_info": ["username": "fixture-user", "auth": 1, "status": "Active"], "server_info": [:]]
                default:
                    client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                    return
                }
                body = try JSONSerialization.data(withJSONObject: object)
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func audioURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brutv-ui-fixture.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleBytes: UInt32 = 16_000 * 120 * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(sampleBytes + 36)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(sampleBytes)
        data.append(Data(repeating: 0, count: Int(sampleBytes)))
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
