import SwiftUI

public struct SeriesView: View {
    @State private var categories: [SeriesCategory] = []
    @State private var selectedCategoryID: String = "all"
    @State private var seriesList: [SeriesItem] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var selectedSeries: SeriesItem?

    private let client = AccountStore.shared.client

    public init() {}

    private var filteredSeries: [SeriesItem] {
        if searchText.isEmpty {
            return seriesList
        }
        return seriesList.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search and Category bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search series...", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .accessibilityHint("Removes the series search text.")
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
                                Text(cat.name)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.06).ignoresSafeArea(edges: .top))

            Divider().background(Color.white.opacity(0.1))

            Group {
                if isLoading {
                    Spacer()
                    ProgressView().tint(.cyan).scaleEffect(1.3)
                    Spacer()
                } else if filteredSeries.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "play.tv")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No series found")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Spacer()
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
        do {
            let cats = try await client.fetchSeriesCategories()
            await MainActor.run {
                var allCategories = [SeriesCategory(id: "all", name: "All Series")]
                allCategories.append(contentsOf: cats)
                self.categories = allCategories
                if self.selectedCategoryID.isEmpty {
                    self.selectedCategoryID = "all"
                }
                loadSeries(categoryID: self.selectedCategoryID)
            }
        } catch {
            print("Failed to fetch series categories: \(error)")
        }
    }

    private func loadSeries(categoryID: String) {
        isLoading = true
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
                    self.isLoading = false
                }
            }
        }
    }
}

public struct SeriesDetailView: View {
    public let series: SeriesItem
    @Binding public var selectedSeries: SeriesItem?
    @ObservedObject private var playback = PlaybackManager.shared

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
                                Text("Overview")
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
                                Text("Cast")
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
                    .accessibilityLabel("Close")
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
                        Text("\(rating)/10")
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
                    Text("Director: \(director)")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
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
                    Text("Loading seasons & episodes...")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
            } else if let error = errorMessage {
                VStack(spacing: 10) {
                    Text("Failed to load episodes: \(error)")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    Button("Retry") {
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
                    Text("No episodes available")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Seasons")
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
                        Text("Episodes")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(currentEpisodes.count) episodes")
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
        if let num = Int(season) {
            return "Season \(num)"
        }
        return "Season \(season)"
    }

    private func episodeRow(_ episode: SeriesEpisode) -> some View {
        Button {
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.cyan)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("E\(episode.episodeNum)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(4)

                        Text(episode.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
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
            .background(Color(white: 0.10))
            .cornerRadius(10)
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
            return "\(mins) min"
        }
        if let dur = episode.info?.duration, !dur.isEmpty {
            return dur
        }
        return nil
    }

    private func playEpisode(_ episode: SeriesEpisode) {
        selectedSeries = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            playback.playEpisode(episode: episode, seriesName: series.name)
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
