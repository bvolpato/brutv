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

    public var tabTitle: String {
        self == .home ? "BruTV" : title
    }

    public var iconName: String {
        switch self {
        case .home: return "play.rectangle"
        case .liveTV: return "antenna.radiowaves.left.and.right"
        case .movies: return "film"
        case .series: return "rectangle.stack"
        case .favorites: return "heart"
        case .settings: return "gearshape"
        }
    }
}

public struct MainContentView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            adaptiveLayout

            if #unavailable(iOS 26.1) {
                if showsMiniPlayer {
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

    private var showsMiniPlayer: Bool {
        !isPlayerFullScreen && (playback.currentStream != nil || playback.currentVOD != nil)
    }

    #if !os(tvOS)
    @ViewBuilder
    private var adaptiveLayout: some View {
        if #available(iOS 26.1, *) {
            iphoneLayout
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.never)
                .tabViewBottomAccessory(isEnabled: showsMiniPlayer) {
                    miniPlayerBar
                }
        } else if #available(iOS 18.0, *) {
            iphoneLayout
                .tabViewStyle(.sidebarAdaptable)
        } else {
            ipadLayout
        }
    }
    #endif

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

            NavigationStack {
                SettingsView()
            }
                .tabItem {
                    Label(NavigationSection.settings.title, systemImage: NavigationSection.settings.iconName)
                }
                .tag(NavigationSection.settings)
        }
    }
    #endif

    // The iOS 17 fallback keeps the same tab content mounted while its sidebar resizes.
    private var ipadLayout: some View {
        HStack(spacing: 0) {
            legacySidebar
                .frame(width: horizontalSizeClass == .regular ? (dynamicTypeSize.isAccessibilitySize ? 280 : 224) : 0)
                .clipped()
                .accessibilityHidden(horizontalSizeClass != .regular)
                .background(Color(hex: "#0e1422"))

            Divider()
                .frame(width: horizontalSizeClass == .regular ? 1 : 0)

            iphoneLayout
                .toolbar(horizontalSizeClass == .regular ? .hidden : .visible, for: .tabBar)
        }
    }

    private var legacySidebar: some View {
        VStack(spacing: 0) {
            sidebarButton(.home)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(NavigationSection.allCases.filter { $0 != .home }) { section in
                        sidebarButton(section)
                    }
                }
                .padding(.vertical, 10)
            }

            if let profile = account.currentProfile {
                Divider()
                    .padding(.horizontal, 16)
                Label(
                    profile.name.isEmpty ? (profile.username.isEmpty ? "Connected".localized : profile.username) : profile.name,
                    systemImage: "person.crop.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func sidebarButton(_ section: NavigationSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            Label(section.tabTitle, systemImage: section.iconName)
                .symbolVariant(isSelected ? .fill : .none)
                .font(section == .home ? .title3.weight(.bold) : .body.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.cyan : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.cyan.opacity(0.15) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel(section == .home ? "BruTV Home".localized : section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(section.rawValue)NavButton")
        .help(section.title)
    }

    // Shared tab content stays mounted when the system moves the navigation controls.
    private var iphoneLayout: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                HomeView(onNavigate: { selectedSection = $0 })
            }
            .tabItem {
                Label(NavigationSection.home.tabTitle, systemImage: NavigationSection.home.iconName)
            }
            .tag(NavigationSection.home)

            NavigationStack {
                LiveTVView()
            }
            .tabItem {
                Label(NavigationSection.liveTV.tabTitle, systemImage: NavigationSection.liveTV.iconName)
            }
            .tag(NavigationSection.liveTV)

            NavigationStack {
                VODView()
            }
            .tabItem {
                Label(NavigationSection.movies.tabTitle, systemImage: NavigationSection.movies.iconName)
            }
            .tag(NavigationSection.movies)

            NavigationStack {
                SeriesView()
            }
            .tabItem {
                Label(NavigationSection.series.tabTitle, systemImage: NavigationSection.series.iconName)
            }
            .tag(NavigationSection.series)

            NavigationStack {
                FavoritesView(onNavigate: { selectedSection = $0 })
            }
            .tabItem {
                Label(NavigationSection.favorites.tabTitle, systemImage: NavigationSection.favorites.iconName)
            }
            .tag(NavigationSection.favorites)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(NavigationSection.settings.tabTitle, systemImage: NavigationSection.settings.iconName)
            }
            .tag(NavigationSection.settings)
        }
        .tint(.cyan)
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

            if horizontalSizeClass == .regular && playback.currentStream != nil && playback.activePlaylist.count > 1 {
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

            if horizontalSizeClass == .regular && playback.currentStream != nil && playback.activePlaylist.count > 1 {
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
