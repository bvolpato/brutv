import SwiftUI

public struct AppRootView: View {
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var localization = LocalizationManager.shared

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
                    Text("Signing in to BruTV...".localized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1)))
                .accessibilityIdentifier("linkSigningIn")
            }

            if showSplash {
                BruTVSplashScreen()
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .scale(scale: 1.08).combined(with: .opacity)
                        )
                    )
                    .zIndex(100)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.25)) {
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
            "Could not sign in".localized,
            isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
        ) {
            Button("OK".localized, role: .cancel) {}
        } message: {
            Text(linkError?.localized ?? "")
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
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeInOut(duration: 0.4)) {
                showSplash = false
            }
        }
    }

    private func handleLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--play-demo") {
            Task {
                try? await account.loginWithDemo()
                if let stream = (try? await account.client.fetchLiveStreams())?.first {
                    PlaybackManager.shared.play(stream: stream)
                }
            }
        } else if args.contains("--demo-login") {
            Task {
                try? await account.loginWithDemo()
            }
        }
        #endif
    }

    private func handle(url: URL) {
        if url.host == "play" || url.host == "channel" {
            handlePlaybackURL(url)
            return
        }
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

    private func handlePlaybackURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value
        let typeParam = components.queryItems?.first(where: { $0.name == "type" })?.value ?? "live"
        guard let idParam, !idParam.isEmpty else { return }

        Task { @MainActor in
            if typeParam == "live", let streamId = Int(idParam) {
                if let stream = (try? await account.client.fetchLiveStreams())?.first(where: { $0.id == streamId }) {
                    PlaybackManager.shared.play(stream: stream)
                }
            } else if typeParam == "vod", let vodId = Int(idParam) {
                if let vod = (try? await account.client.fetchVODStreams())?.first(where: { $0.id == vodId }) {
                    PlaybackManager.shared.playVOD(vod: vod)
                }
            }
        }
    }
}

public struct BruTVSplashScreen: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var hasAppeared = false
    @State private var pulseGlow = false
    @State private var shimmerOffset: CGFloat = -150

    public init() {}

    public var body: some View {
        ZStack {
            Color(hex: "#080B11")
                .ignoresSafeArea()

            // Ambient breathing background glow
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(hex: "#55E2D1").opacity(pulseGlow ? 0.22 : 0.08),
                    Color(hex: "#167E74").opacity(pulseGlow ? 0.09 : 0.02),
                    Color.clear
                ]),
                center: .center,
                startRadius: 8,
                endRadius: pulseGlow ? 250 : 160
            )
            .ignoresSafeArea()
            .scaleEffect(hasAppeared ? 1.0 : 0.8)

            VStack(spacing: 20) {
                // Gradient badge with Play arrow & shimmer
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#55E2D1"), Color(hex: "#167E74")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                        .shadow(
                            color: Color(hex: "#55E2D1").opacity(pulseGlow ? 0.55 : 0.28),
                            radius: pulseGlow ? 26 : 14,
                            x: 0,
                            y: 8
                        )

                    // Sweeping light highlight
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 44, height: 84)
                        .rotationEffect(.degrees(25))
                        .offset(x: shimmerOffset)
                        .mask(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .frame(width: 84, height: 84)
                        )

                    Image(systemName: "play.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(Color(hex: "#06201F"))
                        .offset(x: 3)
                }
                .scaleEffect(hasAppeared ? 1.0 : 0.7)
                .opacity(hasAppeared ? 1.0 : 0.0)

                VStack(spacing: 6) {
                    Text("BruTV")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(-0.6)
                        .scaleEffect(hasAppeared ? 1.0 : 0.92)
                        .opacity(hasAppeared ? 1.0 : 0.0)

                    Text("IPTV that just works.".localized)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(hex: "#55E2D1"))
                        .opacity(hasAppeared ? 1.0 : 0.0)
                        .offset(y: hasAppeared ? 0 : 8)
                }

                Spacer().frame(height: 10)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#55E2D1")))
                    .scaleEffect(1.05)
                    .opacity(hasAppeared ? 0.9 : 0.0)
            }
        }
        .accessibilityIdentifier("splashScreen")
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.72)) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulseGlow = true
            }
            withAnimation(.easeInOut(duration: 1.1).delay(0.25)) {
                shimmerOffset = 150
            }
        }
    }
}
