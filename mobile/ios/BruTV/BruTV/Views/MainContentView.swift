import SwiftUI

public enum NavigationSection: String, CaseIterable, Identifiable {
    case liveTV = "Live TV"
    case movies = "Movies"
    case series = "Series"
    case favorites = "Favorites"
    case settings = "Settings"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSection: NavigationSection? = .liveTV
    @State private var isPlayerFullScreen: Bool = false

    private var tabSelection: Binding<NavigationSection> {
        Binding(
            get: { selectedSection ?? .liveTV },
            set: { selectedSection = $0 }
        )
    }

    public init() {}

    public var body: some View {
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
    }

    // iPad Multi-Column Sidebar Layout
    private var ipadLayout: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(NavigationSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.rawValue, systemImage: section.iconName)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("BruTV")
        } detail: {
            NavigationStack {
                detailView(for: selectedSection ?? .liveTV)
            }
        }
    }

    // iPhone Tab View Layout
    private var iphoneLayout: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                LiveTVView()
            }
            .tabItem {
                Label("Live TV", systemImage: "tv.fill")
            }
            .tag(NavigationSection.liveTV)

            NavigationStack {
                VODView()
            }
            .tabItem {
                Label("Movies", systemImage: "film.fill")
            }
            .tag(NavigationSection.movies)

            NavigationStack {
                SeriesView()
            }
            .tabItem {
                Label("Series", systemImage: "play.tv.fill")
            }
            .tag(NavigationSection.series)

            NavigationStack {
                FavoritesView()
            }
            .tabItem {
                Label("Favorites", systemImage: "heart.fill")
            }
            .tag(NavigationSection.favorites)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(NavigationSection.settings)
        }
        .tint(.cyan)
    }

    @ViewBuilder
    private func detailView(for section: NavigationSection) -> some View {
        switch section {
        case .liveTV:
            LiveTVView()
        case .movies:
            VODView()
        case .series:
            SeriesView()
        case .favorites:
            FavoritesView()
        case .settings:
            SettingsView()
        }
    }

    // Mini Player bar
    private var miniPlayerBar: some View {
        Button {
            isPlayerFullScreen = true
        } label: {
            HStack(spacing: 12) {
                if let stream = playback.currentStream {
                    CachedAsyncImage(url: stream.iconURL) {
                        Image(systemName: "tv")
                            .foregroundColor(.cyan)
                    }
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stream.cleanName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("Live • \(playback.telemetry.bufferDurationFormatted) buffered")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                } else if let vod = playback.currentVOD {
                    Image(systemName: "film")
                        .foregroundColor(.cyan)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(vod.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("Movie Playing")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play or Pause")
                .accessibilityIdentifier("miniPlayerPlayPause")

                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("miniPlayerClose")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: "#101624").opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("miniPlayer")
    }
}
