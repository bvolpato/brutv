import SwiftUI

public struct HomeView: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var recentStreams: [LiveStream] = []
    @State private var favoriteStreams: [LiveStream] = []
    @State private var topRatedMovies: [VODStream] = []
    @State private var topRatedSeries: [SeriesItem] = []
    @State private var featuredMovie: VODStream?
    @State private var featuredMovieExcerpt: String?
    @State private var selectedMovie: VODStream?
    @State private var selectedSeries: SeriesItem?
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    private let client = AccountStore.shared.client
    public var onNavigate: ((NavigationSection) -> Void)?

    public init(onNavigate: ((NavigationSection) -> Void)? = nil) {
        self.onNavigate = onNavigate
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Top Header / Welcome
                welcomeHeader

                // Featured Hero Banner (if high rated movie/series available)
                if let featured = featuredMovie {
                    heroBanner(movie: featured)
                }

                // Recently Watched Channels
                recentChannelsSection

                // Favorite Channels
                favoriteChannelsSection

                // Top Rated Movies
                if !topRatedMovies.isEmpty {
                    topRatedMoviesSection
                }

                // Top Rated Series
                if !topRatedSeries.isEmpty {
                    topRatedSeriesSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 80)
        }
        .refreshable {
            await loadHomeContent(forceRefresh: true)
        }
        .background(Color(hex: "#060a12").ignoresSafeArea())
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedMovie) { movie in
            VODDetailView(movie: movie, selectedMovie: $selectedMovie)
        }
        .sheet(item: $selectedSeries) { series in
            SeriesDetailView(series: series, selectedSeries: $selectedSeries)
        }
        .task {
            await loadHomeContent()
        }
        .onChange(of: favorites.favoriteChannelIDs) { _, _ in
            Task { await refreshChannels() }
        }
        .onChange(of: favorites.recentChannelIDs) { _, _ in
            Task { await refreshChannels() }
        }
        .onChange(of: featuredMovie?.id) { _, _ in
            if let movie = featuredMovie {
                loadFeaturedExcerpt(for: movie)
            }
        }
    }

    // MARK: - Welcome Header
    private var welcomeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, Color(hex: "#0077ED")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("BruTV Home".localized)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                if let profile = account.currentProfile {
                    let viewerName = profile.name.isEmpty ? (profile.username.isEmpty ? "Viewer".localized : profile.username) : profile.name
                    Text(String(format: "Welcome back, %@".localized, viewerName))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gray)
                } else {
                    Text("Discover live channels, top movies and series".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.cyan)
                    .scaleEffect(0.85)
            } else {
                Button {
                    Task { await loadHomeContent(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh home recommendations".localized)
            }
        }
    }

    // MARK: - Hero Banner
    private func heroBanner(movie: VODStream) -> some View {
        ZStack(alignment: .leading) {
            // Ambient blurred background poster / gradient
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#101a2e"), Color(hex: "#0a0f1d")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let url = movie.iconURL {
                    CachedAsyncImage(url: url) {
                        Color.clear
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .blur(radius: 22)
                    .clipped()
                    .opacity(0.32)
                }

                LinearGradient(
                    colors: [
                        Color(hex: "#060a12").opacity(0.3),
                        Color(hex: "#060a12").opacity(0.75),
                        Color(hex: "#060a12").opacity(0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
            )

            // Crisp poster + details
            HStack(alignment: .center, spacing: 18) {
                if let url = movie.iconURL {
                    Button {
                        selectedMovie = movie
                    } label: {
                        CachedAsyncImage(url: url) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.08))
                        }
                        .frame(width: 104, height: 154)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("FEATURED MOVIE".localized)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.16))
                            .clipShape(Capsule())

                        if let rating = movie.rating, !rating.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                                Text(rating)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                        }
                    }

                    Text(movie.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let excerpt = featuredMovieExcerpt ?? movie.plot, !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 680, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button {
                            playback.playVOD(vod: movie)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Play Movie".localized)
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.cyan)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectedMovie = movie
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("More Info".localized)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18)
        }
        .frame(minHeight: 190)
    }

    // MARK: - Recently Watched Channels
    private var recentChannelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.cyan)
                    .font(.system(size: 15, weight: .semibold))
                Text("Recently Watched".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)

                if !recentStreams.isEmpty {
                    Text("\(recentStreams.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }

                Spacer()

                if !recentStreams.isEmpty, let onNavigate {
                    Button {
                        onNavigate(.favorites)
                    } label: {
                        HStack(spacing: 4) {
                            Text("See All".localized)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            if recentStreams.isEmpty {
                if isLoading && !favorites.recentChannelIDs.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(.cyan)
                        Text("Loading channels...".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(white: 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    emptyShelfCard(
                        icon: "tv",
                        title: "No channels watched yet".localized,
                        subtitle: "Tune into any Live TV channel to see your recent history here.".localized,
                        actionTitle: onNavigate != nil ? "Browse Live TV".localized : nil,
                        action: { onNavigate?(.liveTV) }
                    )
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(recentStreams) { stream in
                            homeChannelCard(stream: stream, playlist: recentStreams)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Favorite Channels
    private var favoriteChannelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 15, weight: .semibold))
                Text("Favorite Channels".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)

                if !favoriteStreams.isEmpty {
                    Text("\(favoriteStreams.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }

                Spacer()

                if !favoriteStreams.isEmpty, let onNavigate {
                    Button {
                        onNavigate(.favorites)
                    } label: {
                        HStack(spacing: 4) {
                            Text("See All".localized)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            if favoriteStreams.isEmpty {
                if isLoading && !favorites.favoriteChannelIDs.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(.cyan)
                        Text("Loading channels...".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(white: 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    emptyShelfCard(
                        icon: "heart.slash",
                        title: "No favorites added yet".localized,
                        subtitle: "Tap the heart icon on any channel to pin it right to your home screen.".localized,
                        actionTitle: onNavigate != nil ? "Browse Live TV".localized : nil,
                        action: { onNavigate?(.liveTV) }
                    )
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(favoriteStreams) { stream in
                            homeChannelCard(stream: stream, playlist: favoriteStreams)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Top Rated Movies
    private var topRatedMoviesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "film.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 15, weight: .semibold))
                Text("Top Rated Movies".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)

                Text("High Ratings".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.14))
                    .clipShape(Capsule())

                Spacer()

                if let onNavigate {
                    Button {
                        onNavigate(.movies)
                    } label: {
                        HStack(spacing: 4) {
                            Text("See All".localized)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(topRatedMovies) { movie in
                        moviePosterCard(movie: movie)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Top Rated Series
    private var topRatedSeriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.tv.fill")
                    .foregroundColor(Color(hex: "#A855F7"))
                    .font(.system(size: 15, weight: .semibold))
                Text("Top Rated Series".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)

                Text("Popular".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#C084FC"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#A855F7").opacity(0.15))
                    .clipShape(Capsule())

                Spacer()

                if let onNavigate {
                    Button {
                        onNavigate(.series)
                    } label: {
                        HStack(spacing: 4) {
                            Text("See All".localized)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(topRatedSeries) { series in
                        seriesPosterCard(series: series)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Cards

    private func homeChannelCard(stream: LiveStream, playlist: [LiveStream]) -> some View {
        let isCurrent = playback.currentStream?.id == stream.id
        let isFav = favorites.isFavorite(channelID: stream.id)

        return HStack(spacing: 8) {
            Button {
                playback.play(stream: stream, from: playlist)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.12))
                            .frame(width: 54, height: 54)

                        CachedAsyncImage(url: stream.iconURL) {
                            Image(systemName: "tv")
                                .font(.system(size: 20))
                                .foregroundColor(.cyan)
                        }
                        .frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(stream.cleanName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isCurrent ? .cyan : .white)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if stream.num > 0 {
                                Text("#\(stream.num)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            }

                            Text(stream.quality.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isCurrent ? .black : .cyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(isCurrent ? Color.cyan : Color.cyan.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Spacer(minLength: 0)

                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.system(size: 15))
                            .foregroundColor(.cyan)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                favorites.toggleFavorite(channelID: stream.id)
            } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .foregroundColor(isFav ? .red : .gray.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((isFav ? "Remove favorite" : "Add favorite").localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 268, height: 76)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCurrent ? Color.cyan : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func moviePosterCard(movie: VODStream) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    selectedMovie = movie
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(white: 0.12))
                            .frame(width: 130, height: 185)

                        CachedAsyncImage(url: movie.iconURL) {
                            Image(systemName: "film")
                                .font(.system(size: 24))
                                .foregroundColor(.gray)
                        }
                        .frame(width: 130, height: 185)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        if let rating = movie.rating, !rating.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.yellow)
                                Text(rating)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Quick-play button in top-right corner
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            playback.playVOD(vod: movie)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.cyan.opacity(0.92)))
                                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Play Movie".localized)
                        .padding(6)
                    }
                    Spacer()
                }
                .frame(width: 130, height: 185)
            }

            Button {
                selectedMovie = movie
            } label: {
                Text(movie.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 130, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func seriesPosterCard(series: SeriesItem) -> some View {
        Button {
            selectedSeries = series
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.12))
                        .frame(width: 130, height: 185)

                    CachedAsyncImage(url: series.coverURL) {
                        Image(systemName: "play.tv")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                    }
                    .frame(width: 130, height: 185)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if let rating = series.rating, !rating.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                            Text(rating)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

                Text(series.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func emptyShelfCard(
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Data Loading
    private func loadHomeContent(forceRefresh: Bool = false) async {
        if forceRefresh {
            client.clearCache()
        }
        isLoading = true
        defer { isLoading = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let allLive = (try? await client.fetchLiveStreams()) ?? []
                let streamMap = Dictionary(uniqueKeysWithValues: allLive.map { ($0.id, $0) })
                await MainActor.run {
                    self.recentStreams = favorites.recentChannelIDs.compactMap { streamMap[$0] }
                    self.favoriteStreams = favorites.favoriteChannelIDs.compactMap { streamMap[$0] }
                    TopShelfStore.shared.updateFavorites(channels: self.favoriteStreams)
                }
            }

            group.addTask {
                let allVOD = (try? await client.fetchVODStreams()) ?? []
                let ratedMovies = allVOD
                    .map { (movie: $0, score: parseRating($0.rating)) }
                    .sorted { $0.score > $1.score }
                let filteredRatedMovies = ratedMovies.filter { $0.score > 0 }.prefix(20).map(\.movie)
                let topMovies = !filteredRatedMovies.isEmpty ? Array(filteredRatedMovies) : Array(allVOD.prefix(20))

                await MainActor.run {
                    self.topRatedMovies = topMovies
                    self.featuredMovie = topMovies.first
                    if let first = topMovies.first {
                        self.loadFeaturedExcerpt(for: first)
                    }
                }
            }

            group.addTask {
                let allSeries = (try? await client.fetchSeries()) ?? []
                let ratedSeries = allSeries
                    .map { (series: $0, score: parseRating($0.rating)) }
                    .sorted { $0.score > $1.score }
                let filteredRatedSeries = ratedSeries.filter { $0.score > 0 }.prefix(20).map(\.series)
                let topSeries = !filteredRatedSeries.isEmpty ? Array(filteredRatedSeries) : Array(allSeries.prefix(20))

                await MainActor.run {
                    self.topRatedSeries = topSeries
                }
            }
        }
    }

    private func refreshChannels() async {
        do {
            let all = try await client.fetchLiveStreams()
            let streamMap = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

            await MainActor.run {
                self.recentStreams = favorites.recentChannelIDs.compactMap { streamMap[$0] }
                self.favoriteStreams = favorites.favoriteChannelIDs.compactMap { streamMap[$0] }
                TopShelfStore.shared.updateFavorites(channels: self.favoriteStreams)
            }
        } catch {
            print("Failed to refresh home channels: \(error)")
        }
    }

    private func parseRating(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        let cleaned = raw.components(separatedBy: "/").first ?? raw
        return Double(cleaned.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func loadFeaturedExcerpt(for movie: VODStream) {
        if let plot = movie.plot, !plot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            featuredMovieExcerpt = plot
            return
        }
        Task {
            if let details = try? await client.fetchVODDetails(vodID: movie.id),
               let plot = details.info?.plot, !plot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run {
                    self.featuredMovieExcerpt = plot
                }
            }
        }
    }
}
