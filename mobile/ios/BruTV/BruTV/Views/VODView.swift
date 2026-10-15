import SwiftUI

public enum CatalogSortOrder: String, CaseIterable, Identifiable {
    case defaultOrder = "Default"
    case topRated = "Top Rated"
    case alphabetical = "A–Z"

    public var id: String { rawValue }
}

public struct VODView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var categories: [VODCategory] = []
    @State private var selectedCategoryID: String = "all"
    @State private var movies: [VODStream] = []
    @State private var searchText: String = ""
    @State private var sortOrder: CatalogSortOrder = .defaultOrder
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedMovie: VODStream?

    private let client = AccountStore.shared.client

    public init() {}

    private var filteredMovies: [VODStream] {
        let base: [VODStream]
        if searchText.isEmpty {
            base = movies
        } else {
            base = movies.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        switch sortOrder {
        case .defaultOrder:
            return base
        case .topRated:
            return base.sorted { parseRating($0.rating) > parseRating($1.rating) }
        case .alphabetical:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func parseRating(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        let cleaned = raw.components(separatedBy: "/").first ?? raw
        return Double(cleaned.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search, Category, and Sort bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search movies...".localized, text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("movieSearchField")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search".localized)
                        .accessibilityHint("Removes the movie search text.".localized)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.12))
                .cornerRadius(12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { cat in
                            let isSelected = selectedCategoryID == cat.id
                            Button {
                                selectedCategoryID = cat.id
                                loadMovies(categoryID: cat.id)
                            } label: {
                                Text(cat.name.localized)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(isSelected ? Color.cyan : Color(white: 0.12))
                                    .foregroundColor(isSelected ? .black : .white)
                                    .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                }

                // Sort Pills & Movie Count
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(CatalogSortOrder.allCases) { order in
                                let isSelected = sortOrder == order
                                Button {
                                    sortOrder = order
                                } label: {
                                    Text(order.rawValue.localized)
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
                                        .foregroundColor(isSelected ? .black : .white)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(isSelected ? Color.cyan : Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Text("\(filteredMovies.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.9))
                        Text("movies".localized)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.gray)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.06).ignoresSafeArea(edges: .top))

            Divider().background(Color.white.opacity(0.1))

            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView().tint(.cyan).scaleEffect(1.3)
                        Text("Loading movies...".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            loadMovies(categoryID: selectedCategoryID)
                        } label: {
                            Label("Retry".localized, systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        Spacer()
                    }
                } else if filteredMovies.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No movies found".localized)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                        Text("Try adjusting your search query or category filter.".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        if !searchText.isEmpty || selectedCategoryID != "all" {
                            Button {
                                searchText = ""
                                if selectedCategoryID != "all" {
                                    selectedCategoryID = "all"
                                    loadMovies(categoryID: "all")
                                }
                            } label: {
                                Label("Reset Filters".localized, systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                            .padding(.top, 4)
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)],
                            spacing: 16
                        ) {
                            ForEach(filteredMovies) { movie in
                                vodPosterCard(movie: movie)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable {
                        await reloadAll()
                    }
                }
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedMovie) { movie in
            VODDetailView(movie: movie, selectedMovie: $selectedMovie)
        }
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
        }
    }

    private func vodPosterCard(movie: VODStream) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                selectedMovie = movie
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(white: 0.12))
                            .aspectRatio(2/3, contentMode: .fit)

                        CachedAsyncImage(url: movie.iconURL) {
                            Image(systemName: "film")
                                .font(.system(size: 28))
                                .foregroundColor(.gray)
                        }
                        .cornerRadius(12)

                        if let rating = movie.rating, !rating.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.yellow)
                                Text(rating)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(6)
                            .padding(6)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                    Text(movie.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)

            // Quick Play badge
            Button {
                playback.playVOD(vod: movie)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.cyan.opacity(0.92)))
                    .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(String(format: "Play %@".localized, movie.name))
            .help("Play Movie".localized)
        }
    }

    private func loadCategories() async {
        let allCat = VODCategory(id: "all", name: "All Movies")
        do {
            let cats = try await client.fetchVODCategories()
            await MainActor.run {
                self.categories = [allCat] + cats
                loadMovies(categoryID: self.selectedCategoryID)
            }
        } catch {
            await MainActor.run {
                self.categories = [allCat]
                loadMovies(categoryID: self.selectedCategoryID)
            }
        }
    }

    private func loadMovies(categoryID: String) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let items = try await client.fetchVODStreams(categoryID: categoryID == "all" ? nil : categoryID)
                await MainActor.run {
                    self.movies = items
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func reloadAll() async {
        client.clearCache()
        await loadCategories()
    }
}

public struct VODDetailView: View {
    public let movie: VODStream
    @Binding public var selectedMovie: VODStream?
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var details: VODDetails?
    @State private var isLoading: Bool = true

    private let client = AccountStore.shared.client

    public init(movie: VODStream, selectedMovie: Binding<VODStream?>) {
        self.movie = movie
        self._selectedMovie = selectedMovie
    }

    private var moviePlot: String? {
        let p = details?.info?.plot ?? movie.plot
        guard let trimmed = p?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var movieCast: String? {
        guard let c = details?.info?.cast?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        return c
    }

    private var movieDirector: String? {
        guard let d = details?.info?.director?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        return d
    }

    private var movieGenre: String? {
        guard let g = details?.info?.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
        return g
    }

    private var movieDuration: String? {
        guard let dur = details?.info?.duration?.trimmingCharacters(in: .whitespacesAndNewlines), !dur.isEmpty else { return nil }
        return dur
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0E131F").ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection

                        if let plot = moviePlot {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Overview".localized)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                Text(plot)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineSpacing(4)
                            }
                        } else if isLoading {
                            HStack(spacing: 10) {
                                ProgressView().tint(.cyan)
                                Text("Loading...".localized)
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 8)
                        }

                        if let cast = movieCast {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Cast".localized)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                Text(cast)
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(movie.name)
            #if !targetEnvironment(macCatalyst) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        selectedMovie = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close".localized)
                }
            }
        }
        .task {
            await loadDetails()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.15))
                    .frame(width: 130, height: 195)
                CachedAsyncImage(url: movie.iconURL) {
                    Image(systemName: "film")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)
                }
                .frame(width: 130, height: 195)
                .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(movie.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 10) {
                    if let rating = details?.info?.rating ?? movie.rating, !rating.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 13))
                            Text(rating)
                                .foregroundColor(.white)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }

                    if let duration = movieDuration {
                        Text("•")
                            .foregroundColor(.gray)
                        Text(duration)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }

                if let genre = movieGenre {
                    Text(genre)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.cyan)
                }

                if let director = movieDirector {
                    Text(String(format: "Director: %@".localized, director))
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                Button {
                    let target = movie
                    selectedMovie = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        playback.playVOD(vod: target)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Play Movie".localized)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.cyan)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
    }

    private func loadDetails() async {
        isLoading = true
        defer { isLoading = false }
        if let res = try? await client.fetchVODDetails(vodID: movie.id) {
            await MainActor.run {
                self.details = res
            }
        }
    }
}

