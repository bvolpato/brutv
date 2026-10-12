import SwiftUI

public struct AppRootView: View {
    @ObservedObject private var account = AccountStore.shared

    public init() {}

    public var body: some View {
        Group {
            if account.isAuthenticated {
                MainContentView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            handleLaunchArguments()
        }
    }

    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-login") {
            Task {
                try? await account.loginWithDemo()
            }
        }
    }
}
