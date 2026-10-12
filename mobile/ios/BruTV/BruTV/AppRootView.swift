import SwiftUI

public struct AppRootView: View {
    @ObservedObject private var account = AccountStore.shared

    @State private var isSigningInFromLink = false
    @State private var linkError: String?
    @State private var linkGeneration = UUID()
    @State private var linkTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        ZStack {
            Group {
                if account.isAuthenticated {
                    MainContentView()
                        // Rebuild cached channel lists when a link switches accounts.
                        .id(account.currentProfile?.id)
                } else {
                    LoginView()
                }
            }

            if isSigningInFromLink {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(1.4)
                    Text("Signing in to BruTV...")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1)))
                .accessibilityIdentifier("linkSigningIn")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            handleLaunchArguments()
        }
        .onOpenURL { url in
            handle(url: url)
        }
        .alert(
            "Could not sign in",
            isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }

    private func handleLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-login") {
            Task {
                try? await account.loginWithDemo()
            }
        }
        #endif
    }

    private func handle(url: URL) {
        guard let link = LoginLink(url: url) else {
            linkError = "This BruTV link is not valid."
            return
        }
        PlaybackManager.shared.stop()
        linkTask?.cancel()
        let token = UUID()
        linkGeneration = token
        linkError = nil
        isSigningInFromLink = true
        linkTask = Task {
            do {
                try await account.login(link: link)
            } catch is CancellationError {
            } catch {
                guard linkGeneration == token else { return }
                linkError = error.localizedDescription
            }
            guard linkGeneration == token else { return }
            isSigningInFromLink = false
            linkTask = nil
        }
    }
}
