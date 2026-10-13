import SwiftUI

public struct AppRootView: View {
    @ObservedObject private var account = AccountStore.shared

    @State private var isSigningInFromLink = false
    @State private var linkError: String?
    @State private var linkGeneration = UUID()
    @State private var linkTask: Task<Void, Never>?
    @State private var showSplash = true

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

            if showSplash {
                BruTVSplashScreen()
                    .transition(.opacity)
                    .zIndex(100)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showSplash = false
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            handleLaunchArguments()
            scheduleSplashDismissal()
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

    private func scheduleSplashDismissal() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--no-splash") {
            showSplash = false
            return
        }
        #endif
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.35)) {
                showSplash = false
            }
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

public struct BruTVSplashScreen: View {
    public init() {}

    public var body: some View {
        ZStack {
            Color(hex: "#090D16")
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Gradient badge with Play arrow matching Android & app icon
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#55E2D1"), Color(hex: "#167E74")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 76, height: 76)
                        .shadow(color: Color(hex: "#55E2D1").opacity(0.35), radius: 18, x: 0, y: 8)

                    Image(systemName: "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(Color(hex: "#06201F"))
                        .offset(x: 2)
                }

                Text("BruTV")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(-0.5)

                Text("IPTV that just works.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(hex: "#55E2D1"))

                Spacer().frame(height: 12)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#55E2D1")))
                    .scaleEffect(1.1)
            }
        }
        .accessibilityIdentifier("splashScreen")
    }
}
