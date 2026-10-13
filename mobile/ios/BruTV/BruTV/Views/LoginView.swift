import SwiftUI

public struct LoginView: View {
    private enum LoginMode: String, CaseIterable, Identifiable {
        case xtream = "Xtream Codes"
        case m3u = "M3U Playlist"
        var id: String { rawValue }
    }

    @ObservedObject private var account = AccountStore.shared

    @State private var mode: LoginMode = .xtream
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var playlistURL: String = ""
    @State private var showPassword: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var signInGeneration = UUID()
    @State private var signInTask: Task<Void, Never>?
    @State private var showScanner = false

    public init() {}

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .xtream:
            return !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
        case .m3u:
            return !playlistURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public var body: some View {
        ZStack {
            // Background Gradient
            LinearGradient(
                colors: [Color(hex: "#090D16"), Color(hex: "#121A29"), Color(hex: "#0A0E18")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    // Branding & Logo
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan.opacity(0.8), Color.blue],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                                .shadow(color: .cyan.opacity(0.4), radius: 16, x: 0, y: 8)

                            Image(systemName: "tv.fill")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text("BruTV")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundColor(.white)

                        Text("State-of-the-Art Live IPTV & Streaming")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 40)

                    // Credentials Box
                    VStack(spacing: 16) {
                        Picker("Login type", selection: $mode) {
                            ForEach(LoginMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("loginModePicker")
                        .onChange(of: mode) { _, _ in errorMessage = nil }

                        if mode == .xtream {
                            xtreamFields
                        } else {
                            m3uFields
                        }

                        if let errorMessage {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                                Text(errorMessage)
                                    .font(.system(size: 13))
                                    .foregroundColor(.orange)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(8)
                        }

                        // Connect Button
                        Button {
                            submitLogin()
                        } label: {
                            HStack(spacing: 8) {
                                if isSubmitting {
                                    ProgressView()
                                        .tint(.black)
                                    Text("Connecting...")
                                        .font(.system(size: 16, weight: .bold))
                                } else {
                                    Label(
                                        mode == .xtream ? "Connect Server" : "Load Playlist",
                                        systemImage: mode == .xtream ? "server.rack" : "square.and.arrow.down"
                                    )
                                    .font(.system(size: 16, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(14)
                            .shadow(color: .cyan.opacity(0.3), radius: 10, x: 0, y: 4)
                        }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("connectButton")
                        .padding(.top, 4)

                        // Sign in from a QR code or a shared link
                        HStack(spacing: 10) {
                            Button {
                                showScanner = true
                            } label: {
                                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.cyan)
                            .accessibilityHint("Scan a BruTV sign-in QR code with the camera or from a photo.")
                            .accessibilityIdentifier("scanQRButton")

                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                Task { @MainActor in signIn(withPasted: text) }
                            }
                            .buttonBorderShape(.capsule)
                            .tint(.cyan)
                            .labelStyle(.titleAndIcon)
                            .accessibilityHint("Paste a BruTV sign-in link or playlist URL.")
                            .accessibilityIdentifier("pasteLoginLinkButton")
                        }

                        Text("Got a BruTV QR code? Tap Scan QR Code. Got a link? Copy it, then tap Paste.")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)

                        #if DEBUG
                        if mode == .xtream && !ProcessInfo.processInfo.arguments.contains("--store-screenshots") {
                            // Quick Demo Login Button (Debug builds only)
                            Button {
                                useDemoCredentials()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.cyan)
                                    Text("Fill Demo Credentials (example.invalid)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.cyan)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.cyan.opacity(0.12))
                                .cornerRadius(12)
                            }
                        }
                        #endif
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(white: 0.08).opacity(0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 20)

                    // Saved Profiles
                    if !account.savedProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SAVED PROFILES")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 4)

                            ForEach(account.savedProfiles) { profile in
                                Button {
                                    signIn(with: profile.loginLink)
                                } label: {
                                    HStack {
                                        Image(systemName: profile.kind == .m3u ? "list.bullet.rectangle" : "server.rack")
                                            .foregroundColor(.cyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                            Text(profile.kind == .m3u ? (profile.playlistURL ?? profile.serverURL) : profile.serverURL)
                                                .font(.system(size: 12))
                                                .foregroundColor(.gray)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(14)
                                    .background(Color(white: 0.1))
                                    .cornerRadius(12)
                                }
                            }
                        }
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 40)
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            LoginQRScannerView { link in
                signIn(withScanned: link)
            }
        }
    }

    // MARK: - Fields

    private var xtreamFields: some View {
        VStack(spacing: 16) {
            // Server URL
            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER ADDRESS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                HStack {
                    Image(systemName: "globe")
                        .foregroundColor(.cyan)
                        .frame(width: 20)
                    TextField("http://example.com:80", text: $serverURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("serverField")
                }
                .padding(14)
                .background(Color(white: 0.12))
                .cornerRadius(12)
            }

            // Username
            VStack(alignment: .leading, spacing: 6) {
                Text("USERNAME")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundColor(.cyan)
                        .frame(width: 20)
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("usernameField")
                }
                .padding(14)
                .background(Color(white: 0.12))
                .cornerRadius(12)
            }

            // Password
            VStack(alignment: .leading, spacing: 6) {
                Text("PASSWORD")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.cyan)
                        .frame(width: 20)
                    if showPassword {
                        TextField("Password", text: $password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .foregroundColor(.white)
                    } else {
                        SecureField("Password", text: $password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .foregroundColor(.white)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(showPassword ? .cyan : .gray)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    .accessibilityHint(showPassword ? "Hides your password." : "Shows your password.")
                }
                .padding(14)
                .background(Color(white: 0.12))
                .cornerRadius(12)
            }
        }
    }

    private var m3uFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLAYLIST URL")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.cyan)
                    .frame(width: 20)
                TextField("http://example.com/playlist.m3u", text: $playlistURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .foregroundColor(.white)
                    .accessibilityIdentifier("playlistField")
            }
            .padding(14)
            .background(Color(white: 0.12))
            .cornerRadius(12)

            Text("Paste an .m3u or .m3u8 link. Xtream get.php links unlock movies and series too.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
    }

    // MARK: - Actions

    #if DEBUG
    private func useDemoCredentials() {
        self.serverURL = ServerProfile.demo.serverURL
        self.username = ServerProfile.demo.username
        self.password = ServerProfile.demo.password
        self.errorMessage = nil
    }
    #endif

    private func submitLogin() {
        switch mode {
        case .xtream:
            signIn(with: .xtream(server: serverURL, username: username, password: password))
        case .m3u:
            signIn(with: .m3u(url: playlistURL))
        }
    }

    private func signIn(withPasted text: String) {
        guard let link = LoginLink(pasted: text) else {
            errorMessage = "The clipboard does not contain a BruTV link or playlist URL."
            return
        }
        signIn(withScanned: link)
    }

    /// Fills the form from a link, then signs in. Showing the values lets people see
    /// which account they are joining.
    private func signIn(withScanned link: LoginLink) {
        switch link {
        case let .xtream(server, user, pass):
            mode = .xtream
            serverURL = server
            username = user
            password = pass
        case let .m3u(url):
            mode = .m3u
            playlistURL = url
        }
        signIn(with: link)
    }

    private func signIn(with link: LoginLink) {
        signInTask?.cancel()
        let token = UUID()
        signInGeneration = token
        isSubmitting = true
        errorMessage = nil

        signInTask = Task {
            do {
                try await account.login(link: link)
            } catch is CancellationError {
            } catch {
                guard signInGeneration == token else { return }
                self.errorMessage = error.localizedDescription
            }
            guard signInGeneration == token else { return }
            self.isSubmitting = false
            self.signInTask = nil
        }
    }
}
