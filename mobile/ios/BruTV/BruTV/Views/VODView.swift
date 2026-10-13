import SwiftUI

public struct VODView: View {
    @ObservedObject private var playback = PlaybackManager.shared

    @State private var categories: [VODCategory] = []
    @State private var selectedCategoryID: String = "all"
    @State private var movies: [VODStream] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private let client = AccountStore.shared.client

    public init() {}

    private var filteredMovies: [VODStream] {
        if searchText.isEmpty {
            return movies
        }
        return movies.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search and Category bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search movies...", text: $searchText)
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
                        .accessibilityHint("Removes the movie search text.")
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
                } else if filteredMovies.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No movies found")
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
                            ForEach(filteredMovies) { movie in
                                Button {
                                    playback.playVOD(vod: movie)
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

                                        Text(movie.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
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
        .navigationTitle("Movies (VOD)")
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
        }
    }

    private func loadCategories() async {
        do {
            let cats = try await client.fetchVODCategories()
            await MainActor.run {
                let allCat = VODCategory(id: "all", name: "All Movies")
                self.categories = [allCat] + cats
                loadMovies(categoryID: self.selectedCategoryID)
            }
        } catch {
            print("Failed to fetch VOD categories: \(error)")
        }
    }

    private func loadMovies(categoryID: String) {
        isLoading = true
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
}
