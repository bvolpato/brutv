import SwiftUI

public struct SeriesView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var categories: [SeriesCategory] = []
    @State private var selectedCategoryID: String = "all"
    @State private var seriesList: [SeriesItem] = []
    @State private var searchText: String = ""
    @State private var sortOrder: CatalogSortOrder = .defaultOrder
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedSeries: SeriesItem?

    private let client = AccountStore.shared.client

    public init() {}

    private var filteredSeries: [SeriesItem] {
        let base: [SeriesItem]
        if searchText.isEmpty {
            base = seriesList
        } else {
            base = seriesList.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                    TextField("Search series...".localized, text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("seriesSearchField")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search".localized)
                        .accessibilityHint("Removes the series search text.".localized)
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
                                loadSeries(categoryID: cat.id)
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

                // Sort Pills & Series Count
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
                        Text("\(filteredSeries.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.9))
                        Text("series".localized)
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
                        Text("Loading series...".localized)
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
                            loadSeries(categoryID: selectedCategoryID)
                        } label: {
                            Label("Retry".localized, systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        Spacer()
                    }
                } else if filteredSeries.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "play.tv")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No series found".localized)
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
                                    loadSeries(categoryID: "all")
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
                            ForEach(filteredSeries) { item in
                                Button {
                                    selectedSeries = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack(alignment: .bottomTrailing) {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(white: 0.12))
                                                .aspectRatio(2/3, contentMode: .fit)

                                            CachedAsyncImage(url: item.coverURL) {
                                                Image(systemName: "play.tv")
                                                    .font(.system(size: 28))
                                                    .foregroundColor(.gray)
                                            }
                                            .cornerRadius(12)

                                            if let rating = item.rating, !rating.isEmpty {
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

                                        Text(item.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(2)

                                        if let genre = item.genre, !genre.isEmpty {
                                            Text(genre)
                                                .font(.system(size: 11))
                                                .foregroundColor(.gray)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
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
        .sheet(item: $selectedSeries) { series in
            SeriesDetailView(series: series, selectedSeries: $selectedSeries)
        }
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
        }
    }

    private func loadCategories() async {
        let allSeriesCat = SeriesCategory(id: "all", name: "All Series")
        do {
            let cats = try await client.fetchSeriesCategories()
            await MainActor.run {
                self.categories = [allSeriesCat] + cats
                if self.selectedCategoryID.isEmpty {
                    self.selectedCategoryID = "all"
                }
                loadSeries(categoryID: self.selectedCategoryID)
            }
        } catch {
            await MainActor.run {
                self.categories = [allSeriesCat]
                if self.selectedCategoryID.isEmpty {
                    self.selectedCategoryID = "all"
                }
                loadSeries(categoryID: self.selectedCategoryID)
            }
        }
    }

    private func loadSeries(categoryID: String) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let catArg = categoryID == "all" ? nil : categoryID
                let items = try await client.fetchSeries(categoryID: catArg)
                await MainActor.run {
                    self.seriesList = items
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

public struct SeriesDetailView: View {
    public let series: SeriesItem
    @Binding public var selectedSeries: SeriesItem?
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var details: SeriesDetails?
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var selectedSeason: String = ""

    private let client = AccountStore.shared.client

    public init(series: SeriesItem, selectedSeries: Binding<SeriesItem?>) {
        self.series = series
        self._selectedSeries = selectedSeries
    }

    private var availableSeasons: [String] {
        guard let details = details else { return [] }
        return details.episodes.keys.sorted { (a, b) -> Bool in
            if let numA = Int(a), let numB = Int(b) {
                return numA < numB
            }
            return a < b
        }
    }

    private var currentEpisodes: [SeriesEpisode] {
        guard let details = details, let list = details.episodes[selectedSeason] else {
            return []
        }
        return list.sorted { $0.episodeNum < $1.episodeNum }
    }

    private var seriesPlot: String? {
        details?.info?.plot ?? series.plot
    }

    private var seriesCast: String? {
        details?.info?.cast ?? series.cast
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0E131F").ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection

                        if let plot = seriesPlot, !plot.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Overview".localized)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                Text(plot)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineSpacing(4)
                            }
                        }

                        if let cast = seriesCast, !cast.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Cast".localized)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                Text(cast)
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                            }
                        }

                        Divider().background(Color.white.opacity(0.1))

                        episodesSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle(series.name)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        selectedSeries = nil
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
                    .frame(width: 120, height: 180)
                CachedAsyncImage(url: series.coverURL) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)
                }
                .frame(width: 120, height: 180)
                .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(series.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                if let rating = details?.info?.rating ?? series.rating, !rating.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 13))
                        Text(rating.contains("/") ? rating : "\(rating)/10")
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }

                if let genre = details?.info?.genre ?? series.genre, !genre.isEmpty {
                    Text(genre)
                        .font(.system(size: 13))
                        .foregroundColor(.cyan)
                }

                if let director = details?.info?.director ?? series.director, !director.isEmpty {
                    Text(String(format: "Director: %@".localized, director))
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                if let firstEpisode = currentEpisodes.first {
                    Button {
                        playEpisode(firstEpisode)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("\("Watch Series".localized) • S\(firstEpisode.season)E\(firstEpisode.episodeNum)")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.cyan)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView().tint(.cyan)
                    Text("Loading seasons & episodes...".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
            } else if let error = errorMessage {
                VStack(spacing: 10) {
                    Text(String(format: "Failed to load episodes: %@".localized, error))
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    Button("Retry".localized) {
                        Task { await loadDetails() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if availableSeasons.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.gray)
                    Text("No episodes available".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Seasons".localized)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableSeasons, id: \.self) { season in
                                let isSelected = selectedSeason == season
                                let displayName = seasonLabel(season)
                                Button {
                                    selectedSeason = season
                                } label: {
                                    Text(displayName)
                                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? Color.cyan : Color(white: 0.15))
                                        .foregroundColor(isSelected ? .black : .white)
                                        .cornerRadius(20)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Episodes".localized)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(currentEpisodes.count == 1 ? "1 episode".localized : String(format: "%d episodes".localized, currentEpisodes.count))
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }

                    ForEach(currentEpisodes) { episode in
                        episodeRow(episode)
                    }
                }
            }
        }
    }

    private func seasonLabel(_ season: String) -> String {
        return String(format: "Season %@".localized, season)
    }

    private func episodeRow(_ episode: SeriesEpisode) -> some View {
        let isPlaying = playback.currentVOD?.id == episode.id && playback.currentVOD?.streamType == "series"
        return Button {
            playEpisode(episode)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .center) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.18))
                        .frame(width: 110, height: 62)

                    if let imageURL = episodeImageURL(episode) {
                        CachedAsyncImage(url: imageURL) {
                            Image(systemName: "play.tv")
                                .foregroundColor(.gray)
                        }
                        .frame(width: 110, height: 62)
                        .cornerRadius(8)
                    }

                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 32, height: 32)
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.cyan)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("E\(episode.episodeNum)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(isPlaying ? .black : .cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isPlaying ? Color.cyan : Color.cyan.opacity(0.15))
                            .cornerRadius(4)

                        Text(episode.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isPlaying ? .cyan : .white)
                            .lineLimit(1)

                        Spacer()

                        if let duration = episodeDuration(episode) {
                            Text(duration)
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }

                    if let plot = episode.info?.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(10)
            .background(isPlaying ? Color.cyan.opacity(0.10) : Color(white: 0.10))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isPlaying ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func episodeImageURL(_ episode: SeriesEpisode) -> URL? {
        guard let img = episode.info?.movieImage, !img.isEmpty else { return nil }
        return URL(string: img)
    }

    private func episodeDuration(_ episode: SeriesEpisode) -> String? {
        if let secs = episode.info?.durationSecs, secs > 0 {
            let mins = secs / 60
            return String(format: "%d min".localized, mins)
        }
        if let dur = episode.info?.duration, !dur.isEmpty {
            return dur
        }
        return nil
    }

    private func playEpisode(_ episode: SeriesEpisode) {
        let episodes = currentEpisodes
        let seriesTitle = series.name
        selectedSeries = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            playback.playEpisode(episode: episode, seriesName: seriesTitle, seasonEpisodes: episodes)
        }
    }

    private func loadDetails() async {
        isLoading = true
        errorMessage = nil
        do {
            let res = try await client.fetchSeriesDetails(seriesID: series.id)
            await MainActor.run {
                self.details = res
                self.isLoading = false
                let sortedSeasons = res.episodes.keys.sorted { (a, b) -> Bool in
                    if let numA = Int(a), let numB = Int(b) {
                        return numA < numB
                    }
                    return a < b
                }
                if let firstSeason = sortedSeasons.first {
                    self.selectedSeason = firstSeason
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
