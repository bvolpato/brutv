import SwiftUI

public enum NavigationSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case liveTV = "Live TV"
    case movies = "Movies"
    case series = "Series"
    case favorites = "Favorites"
    case settings = "Settings"

    public var id: String { rawValue }

    public var title: String {
        rawValue.localized
    }

    public var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .liveTV: return "tv.fill"
        case .movies: return "film.fill"
        case .series: return "play.tv.fill"
        case .favorites: return "heart.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

public struct MainContentView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSection: NavigationSection? = {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--section"), idx + 1 < args.count {
            let val = args[idx + 1]
            if let match = NavigationSection.allCases.first(where: { $0.rawValue == val || $0.id == val }) {
                return match
            }
        }
        return .home
    }()
    @State private var isPlayerFullScreen: Bool = false

    private var tabSelection: Binding<NavigationSection> {
        Binding(
            get: { selectedSection ?? .home },
            set: { selectedSection = $0 }
        )
    }

    public init() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--section"), idx + 1 < args.count {
            let val = args[idx + 1]
            if let match = NavigationSection.allCases.first(where: { $0.rawValue == val || $0.id == val }) {
                _selectedSection = State(initialValue: match)
            }
        }
    }

    public var body: some View {
        #if os(tvOS)
        tvosLayout
            .tint(.cyan)
            .fullScreenCover(isPresented: $isPlayerFullScreen) {
                PlayerView(isPresented: $isPlayerFullScreen)
            }
            .onChange(of: playback.currentStream) { _, stream in
                if stream != nil {
                    isPlayerFullScreen = true
                } else if playback.currentVOD == nil {
                    isPlayerFullScreen = false
                }
            }
            .onChange(of: playback.currentVOD) { _, vod in
                if vod != nil {
                    isPlayerFullScreen = true
                } else if playback.currentStream == nil {
                    isPlayerFullScreen = false
                }
            }
        #else
        ZStack(alignment: .bottom) {
            // Adaptive iPad Split View vs iPhone Tab View
            if horizontalSizeClass == .regular {
                ipadLayout
            } else {
                iphoneLayout
            }

            // Floating Mini-Player bar when a stream is playing and not fullscreen
            if playback.currentStream != nil || playback.currentVOD != nil {
                if !isPlayerFullScreen {
                    miniPlayerBar
                        .padding(.bottom, horizontalSizeClass == .regular ? 16 : 56)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .tint(.cyan)
        .fullScreenCover(isPresented: $isPlayerFullScreen) {
            PlayerView(isPresented: $isPlayerFullScreen)
        }
        .onChange(of: playback.currentStream) { _, stream in
            if stream != nil {
                isPlayerFullScreen = true
            } else if playback.currentVOD == nil {
                isPlayerFullScreen = false
            }
        }
        .onChange(of: playback.currentVOD) { _, vod in
            if vod != nil {
                isPlayerFullScreen = true
            } else if playback.currentStream == nil {
                isPlayerFullScreen = false
            }
        }
        #endif
    }

    #if os(tvOS)
    private var tvosLayout: some View {
        TabView(selection: tabSelection) {
            HomeView(onNavigate: { section in selectedSection = section })
                .tabItem {
                    Label(NavigationSection.home.title, systemImage: NavigationSection.home.iconName)
                }
                .tag(NavigationSection.home)

            LiveTVView()
                .tabItem {
                    Label(NavigationSection.liveTV.title, systemImage: NavigationSection.liveTV.iconName)
                }
                .tag(NavigationSection.liveTV)

            VODView()
                .tabItem {
                    Label(NavigationSection.movies.title, systemImage: NavigationSection.movies.iconName)
                }
                .tag(NavigationSection.movies)

            SeriesView()
                .tabItem {
                    Label(NavigationSection.series.title, systemImage: NavigationSection.series.iconName)
                }
                .tag(NavigationSection.series)

            FavoritesView()
                .tabItem {
                    Label(NavigationSection.favorites.title, systemImage: NavigationSection.favorites.iconName)
                }
                .tag(NavigationSection.favorites)

            SettingsView()
                .tabItem {
                    Label(NavigationSection.settings.title, systemImage: NavigationSection.settings.iconName)
                }
                .tag(NavigationSection.settings)
        }
    }
    #endif

    // iPad / Mac Multi-Column Persistent Navigation Rail Layout
    private var ipadLayout: some View {
        HStack(spacing: 0) {
            // Fixed Navigation Rail (cannot be collapsed or accidentally hidden)
            VStack(spacing: 0) {
                // Top brand mark / Home button
                Button {
                    selectedSection = .home
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.cyan, Color(hex: "#0077ED")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("BruTV")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(selectedSection == .home ? .cyan : .white)
                    }
                    .frame(width: 76, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedSection == .home ? Color.cyan.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selectedSection == .home ? Color.cyan.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(NavigationSection.allCases.filter { $0 != .home }) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: section.iconName)
                                        .font(.system(size: 22, weight: .semibold))
                                        .frame(width: 32, height: 26)
                                        .foregroundColor(selectedSection == section ? .cyan : .secondary)

                                    Text(section.title)
                                        .font(.system(size: 11, weight: selectedSection == section ? .bold : .medium))
                                        .foregroundColor(selectedSection == section ? .white : .secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(width: 76, height: 58)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selectedSection == section ? Color.cyan.opacity(0.18) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(selectedSection == section ? Color.cyan.opacity(0.35) : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("\(section.rawValue)NavButton")
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                }

                Spacer()

                if let profile = account.currentProfile {
                    Divider()
                        .padding(.horizontal, 10)

                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 7, height: 7)

                        Text(profile.name.isEmpty ? (profile.username.isEmpty ? "Connected".localized : profile.username) : profile.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            .frame(width: 88)
            .background(Color(hex: "#0e1422"))

            Divider()

            NavigationStack {
                detailView(for: selectedSection ?? .home)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // iPhone Tab View Layout
    private var iphoneLayout: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                HomeView(onNavigate: { selectedSection = $0 })
            }
            .tabItem {
                Label("BruTV", systemImage: "play.tv.fill")
            }
            .tag(NavigationSection.home)

            NavigationStack {
                LiveTVView()
            }
            .tabItem {
                Label("Live TV".localized, systemImage: "tv.fill")
            }
            .tag(NavigationSection.liveTV)

            NavigationStack {
                VODView()
            }
            .tabItem {
                Label("Movies".localized, systemImage: "film.fill")
            }
            .tag(NavigationSection.movies)

            NavigationStack {
                SeriesView()
            }
            .tabItem {
                Label("Series".localized, systemImage: "play.tv.fill")
            }
            .tag(NavigationSection.series)

            NavigationStack {
                FavoritesView(onNavigate: { selectedSection = $0 })
            }
            .tabItem {
                Label("Favorites".localized, systemImage: "heart.fill")
            }
            .tag(NavigationSection.favorites)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings".localized, systemImage: "gearshape.fill")
            }
            .tag(NavigationSection.settings)
        }
        .tint(.cyan)
    }

    @ViewBuilder
    private func detailView(for section: NavigationSection) -> some View {
        switch section {
        case .home:
            HomeView(onNavigate: { selectedSection = $0 })
        case .liveTV:
            LiveTVView()
        case .movies:
            VODView()
        case .series:
            SeriesView()
        case .favorites:
            FavoritesView(onNavigate: { selectedSection = $0 })
        case .settings:
            SettingsView()
        }
    }

    /// A 16:9 live picture of what is playing. The placeholder (channel logo) shows
    /// until the first video frame arrives, and for audio-only streams.
    private func miniPlayerThumbnail<Placeholder: View>(@ViewBuilder placeholder: () -> Placeholder) -> some View {
        ZStack {
            Color.white.opacity(0.08)
            placeholder()
            VideoPlayerContainer(
                player: playback.player,
                aspectRatio: .fill,
                accessibilityIdentifier: "miniPlayerVideo",
                accessibilityStatus: playback.playbackState.testDescription
            )
            .allowsHitTesting(false)
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func formatMiniTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // Mini Player bar
    private var miniPlayerBar: some View {
        HStack(spacing: 10) {
            Button {
                isPlayerFullScreen = true
            } label: {
                HStack(spacing: 12) {
                    if let stream = playback.currentStream {
                        miniPlayerThumbnail {
                            CachedAsyncImage(url: stream.iconURL) {
                                Image(systemName: "tv")
                                    .foregroundColor(.cyan)
                            }
                            .padding(10)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(stream.cleanName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if playback.settings.showStatsHUD {
                                Text("\("Live".localized) • \(playback.telemetry.bufferDurationFormatted) \("buffered".localized)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.cyan)
                            } else {
                                Text("Live TV".localized)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.cyan.opacity(0.85))
                            }
                        }
                    } else if let vod = playback.currentVOD {
                        miniPlayerThumbnail {
                            if let iconURL = vod.iconURL {
                                CachedAsyncImage(url: iconURL) {
                                    Image(systemName: vod.streamType == "series" ? "play.tv" : "film")
                                        .foregroundColor(.cyan)
                                }
                            } else {
                                Image(systemName: vod.streamType == "series" ? "play.tv" : "film")
                                    .foregroundColor(.cyan)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(vod.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            let statusLabel = vod.streamType == "series"
                                ? (playback.isPlaybackRequested ? "Series Playing".localized : "Paused".localized)
                                : (playback.isPlaybackRequested ? "Movie Playing".localized : "Paused".localized)
                            if playback.vodDuration > 0 {
                                Text("\(statusLabel) • \(formatMiniTime(playback.vodCurrentTime)) / \(formatMiniTime(playback.vodDuration))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            } else {
                                Text(statusLabel)
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full screen player".localized)
            .accessibilityIdentifier("miniPlayer")

            if playback.currentStream != nil && playback.activePlaylist.count > 1 {
                Button {
                    playback.previousChannel()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle())
                .accessibilityLabel("Previous Channel".localized)
                .help("Previous channel".localized)
            }

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaybackRequested ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(MediaControlButtonStyle(isPrimary: true))
            .accessibilityLabel((playback.isPlaybackRequested ? "Pause" : "Play").localized)
            .help((playback.isPlaybackRequested ? "Pause playback" : "Resume playback").localized)
            .accessibilityIdentifier("miniPlayerPlayPause")

            if playback.currentStream != nil && playback.activePlaylist.count > 1 {
                Button {
                    playback.nextChannel()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle())
                .accessibilityLabel("Next Channel".localized)
                .help("Next channel".localized)
            }

            Button {
                playback.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(MediaControlButtonStyle())
            .accessibilityLabel("Stop".localized)
            .help("Stop playback".localized)
            .accessibilityIdentifier("miniPlayerClose")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: "#101624").opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        )
    }
}
