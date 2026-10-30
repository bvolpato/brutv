import SwiftUI

public struct LiveTVView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var categories: [LiveCategory] = []
    @State private var selectedCategoryID: String = "ALL"
    @State private var streams: [LiveStream] = []
    @State private var searchText: String = ""
    @State private var categorySearchText: String = ""
    @State private var selectedQuality: StreamQuality = .all
    @State private var showFavoritesOnly: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var categoryIcons: [String: URL] = [:]
    @State private var categoryCounts: [String: Int] = [:]
    @State private var allLoadedStreams: [LiveStream] = []
    @State private var showSideMenu: Bool = false
    @State private var hasPickedCategoryOnPhone: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-login") ||
           ProcessInfo.processInfo.arguments.contains("--store-screenshots") {
            return true
        }
        #endif
        return false
    }()

    private let client = AccountStore.shared.client

    public init() {}

    private var isAutomatedTestOrDemo: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--demo-login") ||
               ProcessInfo.processInfo.arguments.contains("--store-screenshots")
        #else
        return false
        #endif
    }

    private var availableQualities: [StreamQuality] {
        let qualitiesInStreams = Set(streams.map(\.quality))
        var list: [StreamQuality] = [.all]
        for q in [StreamQuality.uhd4k, .fhd, .hd, .sd] {
            if qualitiesInStreams.contains(q) {
                list.append(q)
            }
        }
        return list
    }

    private var filteredStreams: [LiveStream] {
        streams.filter { stream in
            if showFavoritesOnly && !favorites.isFavorite(channelID: stream.id) {
                return false
            }
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

    private var currentCategoryName: String {
        if selectedCategoryID == "ALL" {
            return "ALL CHANNELS".localized
        }
        return categories.first(where: { $0.id == selectedCategoryID })?.name ?? selectedCategoryID
    }

    private var menuItems: [CategoryMenuItem] {
        var items: [CategoryMenuItem] = []

        let allIcon = categoryIcons["ALL"] ?? allLoadedStreams.first(where: { $0.iconURL != nil })?.iconURL
        let allCount = allLoadedStreams.count > 0 ? allLoadedStreams.count : streams.count
        items.append(
            CategoryMenuItem(
                id: "ALL",
                name: "ALL CHANNELS".localized,
                iconURL: allIcon,
                count: allCount,
                systemFallbackIcon: "sparkles.tv"
            )
        )

        for cat in categories {
            let catIcon = categoryIcons[cat.id]
            let catCount = categoryCounts[cat.id]
            items.append(
                CategoryMenuItem(
                    id: cat.id,
                    name: cat.name,
                    iconURL: catIcon,
                    count: catCount,
                    systemFallbackIcon: "tv"
                )
            )
        }

        return items
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: 0) {
            CategorySideMenuView(
                title: "CATEGORIES".localized,
                items: menuItems,
                selectedID: $selectedCategoryID,
                onSelect: { catID in
                    loadChannels(categoryID: catID)
                }
            )
            .frame(width: 320)

            Divider().background(Color.white.opacity(0.12))

            VStack(spacing: 0) {
                topControlsBar(isCompact: false)
                Divider().background(Color.white.opacity(0.1))
                channelContentArea
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .navigationTitle("")
        .task {
            if categories.isEmpty {
                await loadCategories()
            }
            if streams.isEmpty {
                loadChannels(categoryID: selectedCategoryID)
            }
        }
        #else
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 700
            if isCompact && !hasPickedCategoryOnPhone {
                compactCategoryPickerView
            } else {
                HStack(spacing: 0) {
                    if !isCompact || showSideMenu {
                        CategorySideMenuView(
                            title: "CATEGORIES".localized,
                            items: menuItems,
                            selectedID: $selectedCategoryID,
                            onSelect: { catID in
                                hasPickedCategoryOnPhone = true
                                if isCompact {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showSideMenu = false
                                    }
                                }
                                loadChannels(categoryID: catID)
                            }
                        )
                        .frame(width: isCompact ? min(280, geometry.size.width * 0.78) : 250)
                        .transition(.move(edge: .leading))

                        Divider().background(Color.white.opacity(0.12))
                    }

                    VStack(spacing: 0) {
                        topControlsBar(isCompact: isCompact)
                        Divider().background(Color.white.opacity(0.1))
                        channelContentArea
                    }
                    .frame(maxWidth: .infinity)
                }
                .task {
                    if !isCompact && streams.isEmpty {
                        hasPickedCategoryOnPhone = true
                        loadChannels(categoryID: selectedCategoryID)
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
            if (hasPickedCategoryOnPhone || isAutomatedTestOrDemo) && streams.isEmpty {
                loadChannels(categoryID: selectedCategoryID)
            }
        }
        #endif
    }

    private var compactCategoryPickerView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live TV".localized)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                        Text("Select a Category".localized)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    if isLoading && categories.isEmpty {
                        ProgressView().tint(.cyan)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Category Search Field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search categories...".localized, text: $categorySearchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                    if !categorySearchText.isEmpty {
                        Button {
                            categorySearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .background(Color(white: 0.06).ignoresSafeArea(edges: .top))

            Divider().background(Color.white.opacity(0.1))

            // Scrollable Category Cards
            ScrollView {
                LazyVStack(spacing: 8) {
                    // "ALL CHANNELS" Featured Option
                    if categorySearchText.isEmpty || "All Channels".localizedCaseInsensitiveContains(categorySearchText) || "ALL CHANNELS".localizedCaseInsensitiveContains(categorySearchText) {
                        Button {
                            selectCategory(catID: "ALL")
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [.cyan, Color(hex: "#0077ED")],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "sparkles.tv")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ALL CHANNELS".localized)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.white)
                                    let count = allLoadedStreams.count > 0 ? allLoadedStreams.count : (categoryCounts["ALL"] ?? 0)
                                    if count > 0 {
                                        Text("\(count) \("channels".localized)")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.gray.opacity(0.8))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(white: 0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("ALL CHANNELS".localized)
                    }

                    // Individual Categories
                    let filteredCats = categories.filter {
                        categorySearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(categorySearchText)
                    }

                    ForEach(filteredCats) { cat in
                        Button {
                            selectCategory(catID: cat.id)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(width: 40, height: 40)

                                    if let icon = categoryIcons[cat.id] {
                                        CachedAsyncImage(url: icon) {
                                            Image(systemName: "tv")
                                                .font(.system(size: 16))
                                                .foregroundColor(.cyan)
                                        }
                                        .frame(width: 30, height: 30)
                                    } else {
                                        Image(systemName: "tv")
                                            .font(.system(size: 16))
                                            .foregroundColor(.cyan)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cat.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    if let count = categoryCounts[cat.id], count > 0 {
                                        Text("\(count) \("channels".localized)")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.gray.opacity(0.8))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(white: 0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cat.name)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable {
                await reloadAll()
            }
        }
    }

    private func selectCategory(catID: String) {
        selectedCategoryID = catID
        withAnimation(.easeInOut(duration: 0.25)) {
            hasPickedCategoryOnPhone = true
        }
        loadChannels(categoryID: catID)
    }

    private func topControlsBar(isCompact: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                #if !os(tvOS)
                if isCompact {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            hasPickedCategoryOnPhone = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text("Categories".localized)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.cyan.opacity(0.18))
                        .foregroundColor(.cyan)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Categories".localized)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSideMenu.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showSideMenu ? "sidebar.left" : "line.3.horizontal")
                                .font(.system(size: 13, weight: .bold))
                            Text(currentCategoryName)
                                .font(.system(size: 12, weight: .bold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.cyan.opacity(0.18))
                        .foregroundColor(.cyan)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showSideMenu ? "Hide Categories".localized : "Show Categories".localized)
                }
                #endif

                // Search Field
                HStack(spacing: 8) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(12)
            }

            // Quality Filter Pills & Channel Count
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(availableQualities, id: \.self) { quality in
                            qualityPill(quality)
                        }

                        Button {
                            showFavoritesOnly.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Favorites".localized)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(showFavoritesOnly ? Color.red.opacity(0.85) : Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(showFavoritesOnly ? Color.red : Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
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
        .padding(.vertical, 10)
        .background(Color(white: 0.06).ignoresSafeArea(edges: .top))
    }

    @ViewBuilder
    private var channelContentArea: some View {
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
                if !searchText.isEmpty || selectedQuality != .all || showFavoritesOnly || selectedCategoryID != "ALL" {
                    Button {
                        searchText = ""
                        selectedQuality = .all
                        showFavoritesOnly = false
                        if selectedCategoryID != "ALL" {
                            selectedCategoryID = "ALL"
                            loadChannels(categoryID: "ALL")
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
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 12)],
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

                    if categoryID == "ALL" {
                        self.allLoadedStreams = items
                    }

                    var icons = self.categoryIcons
                    var counts = self.categoryCounts

                    if icons["ALL"] == nil, let first = items.first(where: { $0.iconURL != nil })?.iconURL {
                        icons["ALL"] = first
                    }
                    if categoryID == "ALL" {
                        counts["ALL"] = items.count
                    } else {
                        counts[categoryID] = items.count
                        if icons[categoryID] == nil, let first = items.first(where: { $0.iconURL != nil })?.iconURL {
                            icons[categoryID] = first
                        }
                    }

                    for stream in items {
                        if categoryID == "ALL" {
                            counts[stream.categoryId, default: 0] += 1
                        }
                        if icons[stream.categoryId] == nil, let icon = stream.iconURL {
                            icons[stream.categoryId] = icon
                        }
                    }
                    self.categoryIcons = icons
                    self.categoryCounts = counts

                    if self.selectedQuality != .all && !self.availableQualities.contains(self.selectedQuality) {
                        self.selectedQuality = .all
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

    private func reloadAll() async {
        client.clearCache()
        await loadCategories()
        loadChannels(categoryID: selectedCategoryID)
    }
}
