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
        loadPersistedState()
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

    public func login(serverURL: String, username: String, password: String, saveProfile: Bool = true) async throws {
        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }

        client.updateCredentials(serverURL: serverURL, user: username, pass: password)

        do {
            let response = try await client.authenticate()
            self.authResponse = response
            self.isAuthenticated = true

            let profile = ServerProfile(
                name: username,
                serverURL: serverURL,
                username: username,
                password: password,
                lastConnected: Date(),
                isActive: true
            )
            self.currentProfile = profile

            if saveProfile {
                var profiles = self.savedProfiles.filter { $0.serverURL != serverURL || $0.username != username }
                profiles.insert(profile, at: 0)
                self.savedProfiles = profiles
            }
            persistState()
        } catch {
            self.errorMessage = error.localizedDescription
            self.isAuthenticated = false
            throw error
        }
    }

    public func loginWithDemo() async throws {
        let demo = ServerProfile.demo
        try await login(
            serverURL: demo.serverURL,
            username: demo.username,
            password: demo.password,
            saveProfile: true
        )
    }

    public func logout() {
        self.isAuthenticated = false
        self.authResponse = nil
        self.currentProfile = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        client.clearCache()
    }
}
