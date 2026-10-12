import SwiftUI

public struct SeriesView: View {
    @State private var categories: [SeriesCategory] = []
    @State private var selectedCategoryID: String = ""
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
                            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                        }
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
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.06))

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
        .navigationTitle("TV Series")
        .sheet(item: $selectedSeries) { series in
            seriesDetailSheet(series: series)
        }
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
        }
    }

    private func seriesDetailSheet(series: SeriesItem) -> some View {
        ZStack {
            Color(hex: "#0E131F").ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(white: 0.15))
                                .frame(width: 120, height: 180)
                            CachedAsyncImage(url: series.coverURL) {
                                Image(systemName: "play.tv").foregroundColor(.gray)
                            }
                            .frame(width: 120, height: 180)
                            .cornerRadius(12)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(series.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)

                            if let rating = series.rating {
                                HStack {
                                    Image(systemName: "star.fill").foregroundColor(.yellow)
                                    Text("\(rating)/10").foregroundColor(.white).font(.system(size: 13, weight: .semibold))
                                }
                            }

                            if let genre = series.genre {
                                Text(genre)
                                    .font(.system(size: 12))
                                    .foregroundColor(.cyan)
                            }

                            if let director = series.director, !director.isEmpty {
                                Text("Director: \(director)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                        }
                    }

                    if let plot = series.plot, !plot.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Overview")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text(plot)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                                .lineSpacing(4)
                        }
                    }

                    if let cast = series.cast, !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cast")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text(cast)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }
        }
    }

    private func loadCategories() async {
        do {
            let cats = try await client.fetchSeriesCategories()
            await MainActor.run {
                self.categories = cats
                if let first = cats.first {
                    self.selectedCategoryID = first.id
                    loadSeries(categoryID: first.id)
                }
            }
        } catch {
            print("Failed to fetch series categories: \(error)")
        }
    }

    private func loadSeries(categoryID: String) {
        isLoading = true
        Task {
            do {
                let items = try await client.fetchSeries(categoryID: categoryID)
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
