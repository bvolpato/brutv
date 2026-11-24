import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showingLogoutAlert = false
    @State private var showingClearCacheAlert = false
    @State private var showingQRCode = false
    @State private var switchingProfileID: UUID?
    @State private var switchError: String?
    @State private var statusFeedback: String?

    public init() {}

    private var liveRewindFooter: String {
        #if os(tvOS)
        return "Compatible live channels keep a temporary local buffer for pause and rewind. Playback starts when the first recorded segment is available; startup time depends on the provider. The buffer keeps up to 10 minutes within 96 MiB and is deleted when playback closes or changes channels. Unsupported streams use ordinary playback.".localized
        #else
        return "Compatible live channels keep a temporary local buffer for pause and rewind. Playback starts when the first recorded segment is available; startup time depends on the provider. The buffer keeps up to 10 minutes within 256 MiB and is deleted when playback closes or changes channels. Unsupported streams use ordinary playback.".localized
        #endif
    }

    public var body: some View {
        Form {
            // Language & Region Selection
            Section(
                header: Text("LANGUAGE & REGION".localized),
                footer: Text("Choose the language for BruTV interface and menus.".localized)
            ) {
                #if os(tvOS)
                Picker("Language".localized, selection: $localization.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.inline)
                #else
                Picker("Language".localized, selection: $localization.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                #endif
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

            // In-App Profile Switcher
            if account.savedProfiles.count > 1 {
                Section(header: Text("SWITCH PROFILE".localized)) {
                    ForEach(account.savedProfiles) { profile in
                        let isCurrent = account.currentProfile?.id == profile.id
                        Button {
                            guard !isCurrent, switchingProfileID == nil else { return }
                            switchToProfile(profile)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: profile.kind == .m3u ? "list.bullet.rectangle" : "server.rack")
                                    .foregroundColor(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(profile.kind == .m3u ? "M3U Playlist".localized : profile.serverURL)
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if switchingProfileID == profile.id {
                                    ProgressView().tint(.cyan)
                                } else if isCurrent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                        .disabled(isCurrent || switchingProfileID != nil)
                    }
                }
            }

            Section(
                header: Text("PLAYBACK & BUFFERING ENGINE".localized),
                footer: Text("Buffer profiles request more or less video ahead of playback. The actual delay and stability depend on the stream, connection, and device.".localized)
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

                Picker("Default Aspect Ratio".localized, selection: $playback.settings.defaultAspectRatio) {
                    ForEach(VideoAspectRatio.allCases) { ratio in
                        Text(ratio.displayName.localized).tag(ratio)
                    }
                }

                Toggle("Auto-Play Next Episode".localized, isOn: $playback.settings.autoPlayNextEpisode)
                Toggle("Stream Telemetry HUD".localized, isOn: $playback.settings.showStatsHUD)
            }

            Section(header: Text("LIVE REWIND".localized), footer: Text(liveRewindFooter)) {
                Toggle(isOn: $playback.settings.liveRewind) {
                    Label("Pause & Rewind Live TV".localized, systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("liveRewindToggle")
            }

            Section(header: Text("PLAYBACK HEALTH".localized)) {
                NavigationLink {
                    PlaybackDiagnosticsView()
                } label: {
                    Label("Playback diagnostics".localized, systemImage: "waveform.path.ecg")
                }
                .accessibilityIdentifier("playbackDiagnosticsButton")
            }

            // Cache & Maintenance
            Section(header: Text("CACHE & DATA".localized)) {
                Button {
                    showingClearCacheAlert = true
                } label: {
                    Label("Clear Logo & Poster Cache".localized, systemImage: "trash")
                }

                Button {
                    account.refreshCatalog()
                    showFeedback("Channel listings refreshed".localized)
                } label: {
                    Label("Refresh Channel Listings".localized, systemImage: "arrow.clockwise")
                }

                if let statusFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(statusFeedback)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .transition(.opacity)
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
        .alert(
            "Could not switch profile".localized,
            isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })
        ) {
            Button("OK".localized, role: .cancel) {}
        } message: {
            Text(switchError ?? "")
        }
        .alert("Clear Image Cache".localized, isPresented: $showingClearCacheAlert) {
            Button("Clear".localized, role: .destructive) {
                ImageCache.shared.clear()
                showFeedback("Image cache cleared".localized)
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

    private func switchToProfile(_ profile: ServerProfile) {
        switchingProfileID = profile.id
        playback.stop()
        Task {
            do {
                try await account.switchProfile(to: profile)
            } catch is CancellationError {
            } catch {
                switchError = error.localizedDescription
            }
            switchingProfileID = nil
        }
    }

    private func showFeedback(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            statusFeedback = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if statusFeedback == message {
                withAnimation(.easeInOut(duration: 0.25)) {
                    statusFeedback = nil
                }
            }
        }
    }
}
