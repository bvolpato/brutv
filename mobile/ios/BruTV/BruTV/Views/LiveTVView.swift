import SwiftUI

public struct LiveTVView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var categories: [LiveCategory] = []
    @State private var selectedCategoryID: String = "ALL"
    @State private var streams: [LiveStream] = []
    @State private var searchText: String = ""
    @State private var selectedQuality: StreamQuality = .all
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private let client = AccountStore.shared.client

    public init() {}

    private var filteredStreams: [LiveStream] {
        streams.filter { stream in
            // Search text filter
            if !searchText.isEmpty {
                let matchesName = stream.name.localizedCaseInsensitiveContains(searchText)
                if !matchesName { return false }
            }
            // Quality filter
            if selectedQuality != .all && stream.quality != selectedQuality {
                return false
            }
            return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Controls Bar (Search + Quality Filter)
            VStack(spacing: 10) {
                // Search Field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search channels...".localized, text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .accessibilityIdentifier("channelSearchField")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search".localized)
                        .accessibilityHint("Removes the channel search text.".localized)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.12))
                .cornerRadius(12)

                // Category Filter Scroll View
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip(id: "ALL", name: "All Channels".localized)

                        ForEach(categories) { cat in
                            categoryChip(id: cat.id, name: cat.name)
                        }
                    }
                }

                // Quality Filter Pills & Channel Count
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(StreamQuality.allCases, id: \.self) { quality in
                                qualityPill(quality)
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Text("\(filteredStreams.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.9))
                        Text("channels".localized)
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

            // Channel Content Area
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView()
                            .tint(.cyan)
                            .scaleEffect(1.3)
                        Text("Loading channels...".localized)
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
                            loadChannels(categoryID: selectedCategoryID)
                        } label: {
                            Label("Retry".localized, systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        Spacer()
                    }
                } else if filteredStreams.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "tv.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No channels found".localized)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                        Text("Try adjusting your search query or category filter.".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(filteredStreams) { stream in
                                ChannelCardView(
                                    stream: stream,
                                    isSelected: playback.currentStream?.id == stream.id
                                ) {
                                    playback.play(stream: stream, from: filteredStreams)
                                }
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
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
            if streams.isEmpty {
                loadChannels(categoryID: selectedCategoryID)
            }
        }
    }

    private func qualityPill(_ quality: StreamQuality) -> some View {
        let isSelected = selectedQuality == quality
        return Button {
            selectedQuality = quality
        } label: {
            Text(quality.rawValue)
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

    private func categoryChip(id: String, name: String) -> some View {
        let isSelected = selectedCategoryID == id
        return Button {
            selectedCategoryID = id
            loadChannels(categoryID: id)
        } label: {
            Text(name)
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

    private func loadCategories() async {
        do {
            let cats = try await client.fetchLiveCategories()
            // Priority order: Globo Sudeste, SBT, Record, Band, Abertos, Esportes, Premiere...
            let prioritizedNames = ["GLOBO SUDESTE", "SBT", "RECORD", "BAND", "ABERTOS", "ESPORTES", "PREMIERE", "ESPN"]
            let sorted = cats.sorted { a, b in
                let aName = a.name.uppercased()
                let bName = b.name.uppercased()
                let aIdx = prioritizedNames.firstIndex(where: { aName.contains($0) }) ?? 999
                let bIdx = prioritizedNames.firstIndex(where: { bName.contains($0) }) ?? 999
                if aIdx != bIdx { return aIdx < bIdx }
                return a.name < b.name
            }
            await MainActor.run {
                self.categories = sorted
            }
        } catch {
            print("Failed to fetch live categories: \(error)")
        }
    }

    private func loadChannels(categoryID: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let catIDParam = categoryID == "ALL" ? nil : categoryID
                let items = try await client.fetchLiveStreams(categoryID: catIDParam)
                await MainActor.run {
                    self.streams = items
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
        loadChannels(categoryID: selectedCategoryID)
    }
}
