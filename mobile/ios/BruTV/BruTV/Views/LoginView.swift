import SwiftUI

public struct LoginView: View {
    @ObservedObject private var account = AccountStore.shared

    @State private var serverURL: String = "http://virello.win"
    @State private var username: String = "Bruno081225p2"
    @State private var password: String = "tv8392602653"
    @State private var showPassword: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init() {}

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
                                    .foregroundColor(.white)
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
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(14)
                            .background(Color(white: 0.12))
                            .cornerRadius(12)
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
                            HStack {
                                if isSubmitting {
                                    ProgressView()
                                        .tint(.black)
                                        .padding(.trailing, 6)
                                }
                                Text(isSubmitting ? "Connecting..." : "Connect Server")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(14)
                            .shadow(color: .cyan.opacity(0.3), radius: 10, x: 0, y: 4)
                        }
                        .disabled(isSubmitting || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                        .padding(.top, 4)

                        // Quick Demo Login Button
                        Button {
                            useDemoCredentials()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.cyan)
                                Text("Fill Demo Credentials (virello.win)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.cyan)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(12)
                        }
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
                                    serverURL = profile.serverURL
                                    username = profile.username
                                    password = profile.password
                                    submitLogin()
                                } label: {
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .foregroundColor(.cyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                            Text(profile.serverURL)
                                                .font(.system(size: 12))
                                                .foregroundColor(.gray)
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
    }

    private func useDemoCredentials() {
        self.serverURL = "http://virello.win"
        self.username = "Bruno081225p2"
        self.password = "tv8392602653"
        self.errorMessage = nil
    }

    private func submitLogin() {
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await account.login(
                    serverURL: serverURL,
                    username: username,
                    password: password
                )
                await MainActor.run {
                    self.isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSubmitting = false
                }
            }
        }
    }
}
