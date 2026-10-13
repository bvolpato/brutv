import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingLogoutAlert = false
    @State private var showingClearCacheAlert = false
    @State private var showingQRCode = false

    public init() {}

    public var body: some View {
        Form {
            // Language & Region Selection
            Section(
                header: Text("LANGUAGE & REGION".localized),
                footer: Text("Choose the language for BruTV interface and menus.".localized)
            ) {
                Picker("Language".localized, selection: $localization.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            // Account Information
            Section(header: Text("ACCOUNT & SUBSCRIPTION".localized)) {
                if let user = account.authResponse?.userInfo {
                    HStack {
                        Text("Username".localized)
                        Spacer()
                        Text(user.username)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Status".localized)
                        Spacer()
                        Text(user.status)
                            .foregroundColor(user.status.lowercased() == "active" ? .green : .red)
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Text("Expires".localized)
                        Spacer()
                        Text(user.expirationFormatted)
                            .foregroundColor(.gray)
                    }

                    if let maxCons = user.maxConnections {
                        HStack {
                            Text("Max Connections".localized)
                            Spacer()
                            Text(maxCons)
                                .foregroundColor(.gray)
                        }
                    }
                }

                if let current = account.currentProfile {
                    HStack {
                        Text("Source".localized)
                        Spacer()
                        Text(current.kind == .m3u ? "M3U Playlist".localized : "Xtream Codes".localized)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text(current.kind == .m3u ? "Playlist".localized : "Server Address".localized)
                        Spacer()
                        Text(current.kind == .m3u ? (current.playlistURL ?? current.serverURL) : current.serverURL)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button {
                        showingQRCode = true
                    } label: {
                        Label("Share Sign-In QR Code".localized, systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("shareLoginQRButton")
                }
            }

            // State-of-the-Art Buffering Engine
            Section(
                header: Text("PLAYBACK & BUFFERING ENGINE".localized),
                footer: Text("Ultra Low Latency (1.5s) delivers near-live sports broadcast timing. Balanced (4.0s) ensures zero stuttering on regular broadband. High Stability (10.0s) protects against cellular jitter.".localized)
            ) {
                Picker("Buffer Profile".localized, selection: $playback.settings.bufferProfile) {
                    ForEach(BufferProfile.allCases) { profile in
                        Text(profile.title.localized).tag(profile)
                    }
                }

                Picker("Stream Protocol".localized, selection: $playback.settings.preferredFormat) {
                    ForEach(StreamFormatPreference.allCases) { fmt in
                        Text(fmt.displayName.localized).tag(fmt)
                    }
                }

                Toggle("Stream Telemetry HUD".localized, isOn: $playback.settings.showStatsHUD)
                Toggle("Hardware Acceleration".localized, isOn: $playback.settings.hardwareAcceleration)
            }

            Section(header: Text("LIVE REWIND".localized), footer: Text("When on, BruTV records live channels on this device so you can pause and rewind. Channels take longer to start, because BruTV records about 30 seconds first, and some providers are too slow for it. When off, channels start right away, and you can pause briefly within the provider's own live window. Up to 10 minutes is kept within a 256 MiB temporary-file limit. Closing playback or changing channels deletes the recording.".localized)) {
                Toggle(isOn: $playback.settings.liveRewind) {
                    Label("Pause & Rewind Live TV".localized, systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("liveRewindToggle")
            }

            // Cache & Maintenance
            Section(header: Text("CACHE & DATA".localized)) {
                Button {
                    showingClearCacheAlert = true
                } label: {
                    Label("Clear Logo & Poster Cache".localized, systemImage: "trash")
                }

                Button {
                    account.client.clearCache()
                } label: {
                    Label("Refresh Channel Listings".localized, systemImage: "arrow.clockwise")
                }
            }

            // Session
            Section {
                Button(role: .destructive) {
                    showingLogoutAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Log Out & Switch Server".localized, systemImage: "rectangle.portrait.and.arrow.right")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings & Engine".localized)
        .sheet(isPresented: $showingQRCode) {
            if let profile = account.currentProfile {
                LoginQRCodeView(link: profile.loginLink, title: profile.name)
            }
        }
        .alert("Clear Image Cache".localized, isPresented: $showingClearCacheAlert) {
            Button("Clear".localized, role: .destructive) {
                // Clear cache
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("This will clear temporarily cached channel logos and movie covers.".localized)
        }
        .alert("Log Out".localized, isPresented: $showingLogoutAlert) {
            Button("Log Out".localized, role: .destructive) {
                playback.stop()
                account.logout()
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("Are you sure you want to log out of this IPTV server?".localized)
        }
    }
}
