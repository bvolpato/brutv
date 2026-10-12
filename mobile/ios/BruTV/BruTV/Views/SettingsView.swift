import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var playback = PlaybackManager.shared

    @State private var showingLogoutAlert = false
    @State private var showingClearCacheAlert = false
    @State private var showingQRCode = false

    public init() {}

    public var body: some View {
        Form {
            // Account Information
            Section(header: Text("ACCOUNT & SUBSCRIPTION")) {
                if let user = account.authResponse?.userInfo {
                    HStack {
                        Text("Username")
                        Spacer()
                        Text(user.username)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        Text(user.status)
                            .foregroundColor(user.status.lowercased() == "active" ? .green : .red)
                            .fontWeight(.semibold)
                    }

                    HStack {
                        Text("Expires")
                        Spacer()
                        Text(user.expirationFormatted)
                            .foregroundColor(.gray)
                    }

                    if let maxCons = user.maxConnections {
                        HStack {
                            Text("Max Connections")
                            Spacer()
                            Text(maxCons)
                                .foregroundColor(.gray)
                        }
                    }
                }

                if let current = account.currentProfile {
                    HStack {
                        Text("Source")
                        Spacer()
                        Text(current.kind == .m3u ? "M3U Playlist" : "Xtream Codes")
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text(current.kind == .m3u ? "Playlist" : "Server Address")
                        Spacer()
                        Text(current.kind == .m3u ? (current.playlistURL ?? current.serverURL) : current.serverURL)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button {
                        showingQRCode = true
                    } label: {
                        Label("Share Sign-In QR Code", systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("shareLoginQRButton")
                }
            }

            // State-of-the-Art Buffering Engine
            Section(
                header: Text("PLAYBACK & BUFFERING ENGINE"),
                footer: Text("Ultra Low Latency (1.5s) delivers near-live sports broadcast timing. Balanced (4.0s) ensures zero stuttering on regular broadband. High Stability (10.0s) protects against cellular jitter.")
            ) {
                Picker("Buffer Profile", selection: $playback.settings.bufferProfile) {
                    ForEach(BufferProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }

                Picker("Stream Protocol", selection: $playback.settings.preferredFormat) {
                    ForEach(StreamFormatPreference.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }

                Toggle("Stream Telemetry HUD", isOn: $playback.settings.showStatsHUD)
                Toggle("Hardware Acceleration", isOn: $playback.settings.hardwareAcceleration)
            }

            Section(header: Text("LIVE REWIND"), footer: Text("Pause keeps capturing supported HLS streams while BruTV is active. Up to 10 minutes is retained within a 256 MiB total temporary-file limit, including recently served segments. The retained window can be shorter for high-bitrate streams. iPhone and iPad may suspend capture when paused in the background or when locked. Closing playback or changing channels deletes the buffer.")) {
                Label("10 minutes / 256 MiB maximum", systemImage: "clock.arrow.circlepath")
            }

            // Cache & Maintenance
            Section(header: Text("CACHE & DATA")) {
                Button {
                    showingClearCacheAlert = true
                } label: {
                    Label("Clear Logo & Poster Cache", systemImage: "trash")
                }

                Button {
                    account.client.clearCache()
                } label: {
                    Label("Refresh Channel Listings", systemImage: "arrow.clockwise")
                }
            }

            // Session
            Section {
                Button(role: .destructive) {
                    showingLogoutAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Log Out & Switch Server", systemImage: "rectangle.portrait.and.arrow.right")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings & Engine")
        .sheet(isPresented: $showingQRCode) {
            if let profile = account.currentProfile {
                LoginQRCodeView(link: profile.loginLink, title: profile.name)
            }
        }
        .alert("Clear Image Cache", isPresented: $showingClearCacheAlert) {
            Button("Clear", role: .destructive) {
                // Clear cache
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear temporarily cached channel logos and movie covers.")
        }
        .alert("Log Out", isPresented: $showingLogoutAlert) {
            Button("Log Out", role: .destructive) {
                playback.stop()
                account.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to log out of this IPTV server?")
        }
    }
}
