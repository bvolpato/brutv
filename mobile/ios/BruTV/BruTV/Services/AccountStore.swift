import Foundation
import Combine

@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore()

    @Published public private(set) var currentProfile: ServerProfile?
    @Published public private(set) var authResponse: AuthResponse?
    @Published public private(set) var savedProfiles: [ServerProfile] = []
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    public let client: XtreamCodesClient

    private let userDefaultsKey = "brutv.account.currentProfile"
    private let profilesKey = "brutv.account.savedProfiles"

    public init(client: XtreamCodesClient = XtreamCodesClient()) {
        self.client = client
        if ProcessInfo.processInfo.arguments.contains("--reset-session") {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
        loadPersistedState()
        restoreSession()
    }

    private func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let profile = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            self.currentProfile = profile
        }
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            self.savedProfiles = profiles
        }
    }

    private func persistState() {
        if let currentProfile, let data = try? JSONEncoder().encode(currentProfile) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(savedProfiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    /// Reopens the last session without a login screen. The account is checked in the
    /// background; only a definite auth rejection signs the user out, not a network error.
    private func restoreSession() {
        guard let profile = currentProfile else { return }

        switch profile.kind {
        case .xtream:
            client.updateCredentials(serverURL: profile.serverURL, user: profile.username, pass: profile.password)
            isAuthenticated = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.authResponse = try await self.client.authenticate()
                } catch XtreamError.authenticationFailed {
                    self.logout()
                } catch {
                    // Offline or server hiccup: keep the session.
                }
            }
        case .m3u:
            client.updatePlaylist(url: profile.playlistURL ?? profile.serverURL)
            isAuthenticated = true
        }
    }

    // MARK: - Sign in

    public func login(serverURL: String, username: String, password: String, saveProfile: Bool = true) async throws {
        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }

        client.updateCredentials(serverURL: serverURL, user: username, pass: password)

        do {
            let response = try await client.authenticate()
            self.authResponse = response

            let profile = ServerProfile(
                name: username,
                serverURL: serverURL,
                username: username,
                password: password,
                lastConnected: Date(),
                isActive: true
            )
            activate(profile, save: saveProfile)
        } catch {
            self.errorMessage = error.localizedDescription
            self.isAuthenticated = false
            throw error
        }
    }

    /// Signs in with an M3U playlist URL. Xtream `get.php` playlist URLs use the Xtream API instead.
    public func login(playlistURL: String, saveProfile: Bool = true) async throws {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .xtream(server, user, pass) = LoginLink.fromPlaylistURL(trimmed) {
            try await login(serverURL: server, username: user, password: pass, saveProfile: saveProfile)
            return
        }

        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }

        client.updatePlaylist(url: trimmed)
        do {
            try await client.loadPlaylist()
            self.authResponse = nil
            activate(.playlist(url: trimmed), save: saveProfile)
        } catch {
            self.errorMessage = error.localizedDescription
            self.isAuthenticated = false
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

    private func activate(_ profile: ServerProfile, save: Bool) {
        self.currentProfile = profile
        self.isAuthenticated = true
        if save {
            var profiles = savedProfiles.filter { !$0.sameSource(as: profile) }
            profiles.insert(profile, at: 0)
            self.savedProfiles = profiles
        }
        persistState()
    }

    public func logout() {
        self.isAuthenticated = false
        self.authResponse = nil
        self.currentProfile = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        client.clearCache()
    }
}
