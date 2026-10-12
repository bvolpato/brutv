import SwiftUI

public struct FavoritesView: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var playback = PlaybackManager.shared

    @State private var favoriteStreams: [LiveStream] = []
    @State private var recentStreams: [LiveStream] = []
    @State private var isLoading: Bool = false

    private let client = AccountStore.shared.client

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Favorites Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                            Text("Favorite Channels")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(favoriteStreams.count)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                        }

                        if favoriteStreams.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "heart.slash")
                                    .font(.system(size: 28))
                                    .foregroundColor(.gray)
                                Text("No favorites added yet")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Tap the heart icon on any channel to pin it here.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color(white: 0.08))
                            .cornerRadius(14)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(favoriteStreams) { stream in
                                    ChannelCardView(
                                        stream: stream,
                                        isSelected: playback.currentStream?.id == stream.id
                                    ) {
                                        playback.play(stream: stream, from: favoriteStreams)
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
                            Text("Recently Watched")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            if !recentStreams.isEmpty {
                                Button("Clear") {
                                    favorites.clearRecents()
                                    recentStreams.removeAll()
                                }
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            }
                        }

                        if recentStreams.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tv")
                                    .font(.system(size: 28))
                                    .foregroundColor(.gray)
                                Text("No recently watched channels")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color(white: 0.08))
                            .cornerRadius(14)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(recentStreams) { stream in
                                    ChannelCardView(
                                        stream: stream,
                                        isSelected: playback.currentStream?.id == stream.id
                                    ) {
                                        playback.play(stream: stream, from: recentStreams)
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
        .navigationTitle("Favorites & History")
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
