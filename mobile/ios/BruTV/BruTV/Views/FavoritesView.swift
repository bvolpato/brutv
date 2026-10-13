import SwiftUI

public struct FavoritesView: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var favoriteStreams: [LiveStream] = []
    @State private var recentStreams: [LiveStream] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false

    private let client = AccountStore.shared.client
    public var onNavigate: ((NavigationSection) -> Void)?

    public init(onNavigate: ((NavigationSection) -> Void)? = nil) {
        self.onNavigate = onNavigate
    }

    private var filteredFavoriteStreams: [LiveStream] {
        guard !searchText.isEmpty else { return favoriteStreams }
        return favoriteStreams.filter {
            $0.cleanName.localizedCaseInsensitiveContains(searchText) ||
            "\($0.num)".contains(searchText)
        }
    }

    private var filteredRecentStreams: [LiveStream] {
        guard !searchText.isEmpty else { return recentStreams }
        return recentStreams.filter {
            $0.cleanName.localizedCaseInsensitiveContains(searchText) ||
            "\($0.num)".contains(searchText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !favoriteStreams.isEmpty || !recentStreams.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Filter favorites or recents...".localized, text: $searchText)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .frame(minWidth: 32, minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search".localized)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Favorites Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                            Text("Favorite Channels".localized)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(filteredFavoriteStreams.count)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                        }

                        if favoriteStreams.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "heart.slash")
                                    .font(.system(size: 28))
                                    .foregroundColor(.gray)
                                Text("No favorites added yet".localized)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Tap the heart icon on any channel to pin it here.".localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)

                                if let onNavigate {
                                    Button {
                                        onNavigate(.liveTV)
                                    } label: {
                                        Text("Browse Live TV".localized)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.cyan)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(Color.cyan.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color(white: 0.08))
                            .cornerRadius(14)
                        } else if filteredFavoriteStreams.isEmpty {
                            Text("No channels found".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(filteredFavoriteStreams) { stream in
                                    ChannelCardView(
                                        stream: stream,
                                        isSelected: playback.currentStream?.id == stream.id
                                    ) {
                                        playback.play(stream: stream, from: filteredFavoriteStreams)
                                    }
                                }
                            }
                        }
                    }

                    // Recents Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.cyan)
                            Text("Recently Watched".localized)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            if !recentStreams.isEmpty {
                                Button {
                                    favorites.clearRecents()
                                    recentStreams.removeAll()
                                } label: {
                                    Label("Clear".localized, systemImage: "trash")
                                        .font(.system(size: 13))
                                        .foregroundColor(.gray)
                                        .padding(.horizontal, 8)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                            }
                        }

                        if recentStreams.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tv")
                                    .font(.system(size: 28))
                                    .foregroundColor(.gray)
                                Text("No recently watched channels".localized)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color(white: 0.08))
                            .cornerRadius(14)
                        } else if filteredRecentStreams.isEmpty {
                            Text("No channels found".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(filteredRecentStreams) { stream in
                                    ChannelCardView(
                                        stream: stream,
                                        isSelected: playback.currentStream?.id == stream.id
                                    ) {
                                        playback.play(stream: stream, from: filteredRecentStreams)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadStreams()
        }
        .onChange(of: favorites.favoriteChannelIDs) { _, _ in
            Task { await loadStreams() }
        }
        .onChange(of: favorites.recentChannelIDs) { _, _ in
            Task { await loadStreams() }
        }
    }

    private func loadStreams() async {
        do {
            let all = try await client.fetchLiveStreams()
            let streamMap = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

            await MainActor.run {
                self.favoriteStreams = favorites.favoriteChannelIDs.compactMap { streamMap[$0] }
                self.recentStreams = favorites.recentChannelIDs.compactMap { streamMap[$0] }
            }
        } catch {
            print("Failed to load favorite stream objects: \(error)")
        }
    }
}
