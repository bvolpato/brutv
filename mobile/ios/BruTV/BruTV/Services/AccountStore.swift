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

    private let defaults: UserDefaults
    private let favorites: FavoritesStore
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
        if ProcessInfo.processInfo.arguments.contains("--reset-session") {
            userDefaults.removeObject(forKey: userDefaultsKey)
        }
        loadPersistedState()
        self.favorites.selectSource(currentProfile?.id)
        if shouldRestoreSession {
            restoreSession()
        }
    }

    private func loadPersistedState() {
        if let data = defaults.data(forKey: userDefaultsKey),
           let profile = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            currentProfile = profile
        }
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            savedProfiles = profiles
        }
    }

    private func persistState() {
        if let currentProfile, let data = try? JSONEncoder().encode(currentProfile) {
            defaults.set(data, forKey: userDefaultsKey)
        } else {
            defaults.removeObject(forKey: userDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(savedProfiles) {
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
        defaults.removeObject(forKey: userDefaultsKey)
        client.adoptSource(from: client.makeIndependentClient())
    }
}
