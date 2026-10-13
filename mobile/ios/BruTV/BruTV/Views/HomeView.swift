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
    @State private var selectedSeries: SeriesItem?
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    private let client = AccountStore.shared.client

    public init() {}

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
        .background(Color(hex: "#060a12").ignoresSafeArea())
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
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
                    Task { await loadHomeContent() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh home recommendations")
            }
        }
    }

    // MARK: - Hero Banner
    private func heroBanner(movie: VODStream) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Background poster / gradient
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
                    .clipped()
                    .opacity(0.28)
                }

                LinearGradient(
                    colors: [
                        Color(hex: "#060a12").opacity(0.1),
                        Color(hex: "#060a12").opacity(0.7),
                        Color(hex: "#060a12").opacity(0.96)
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

            // Content
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
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .frame(minHeight: 210)
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
            }

            if recentStreams.isEmpty {
                emptyShelfCard(
                    icon: "tv",
                    title: "No channels watched yet".localized,
                    subtitle: "Tune into any Live TV channel to see your recent history here.".localized
                )
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
            }

            if favoriteStreams.isEmpty {
                emptyShelfCard(
                    icon: "heart.slash",
                    title: "No favorites added yet".localized,
                    subtitle: "Tap the heart icon on any channel to pin it right to your home screen.".localized
                )
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

        return Button {
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

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 16))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 260, height: 76)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isCurrent ? Color.cyan : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func moviePosterCard(movie: VODStream) -> some View {
        Button {
            playback.playVOD(vod: movie)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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

                Text(movie.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
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

    private func emptyShelfCard(icon: String, title: String, subtitle: String) -> some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Data Loading
    private func loadHomeContent() async {
        isLoading = true
        defer { isLoading = false }

        async let liveTask: [LiveStream] = (try? await client.fetchLiveStreams()) ?? []
        async let vodTask: [VODStream] = (try? await client.fetchVODStreams()) ?? []
        async let seriesTask: [SeriesItem] = (try? await client.fetchSeries()) ?? []

        let (allLive, allVOD, allSeries) = await (liveTask, vodTask, seriesTask)

        await MainActor.run {
            // Populate recent & favorites
            let streamMap = Dictionary(uniqueKeysWithValues: allLive.map { ($0.id, $0) })
            self.recentStreams = favorites.recentChannelIDs.compactMap { streamMap[$0] }
            self.favoriteStreams = favorites.favoriteChannelIDs.compactMap { streamMap[$0] }

            // Filter & sort movies by rating
            let ratedMovies = allVOD
                .map { (movie: $0, score: parseRating($0.rating)) }
                .sorted { $0.score > $1.score }

            let filteredRatedMovies = ratedMovies.filter { $0.score > 0 }.prefix(20).map(\.movie)
            if !filteredRatedMovies.isEmpty {
                self.topRatedMovies = Array(filteredRatedMovies)
            } else {
                self.topRatedMovies = Array(allVOD.prefix(20))
            }

            self.featuredMovie = self.topRatedMovies.first
            if let first = self.featuredMovie {
                self.loadFeaturedExcerpt(for: first)
            }

            // Filter & sort series by rating
            let ratedSeries = allSeries
                .map { (series: $0, score: parseRating($0.rating)) }
                .sorted { $0.score > $1.score }

            let filteredRatedSeries = ratedSeries.filter { $0.score > 0 }.prefix(20).map(\.series)
            if !filteredRatedSeries.isEmpty {
                self.topRatedSeries = Array(filteredRatedSeries)
            } else {
                self.topRatedSeries = Array(allSeries.prefix(20))
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
