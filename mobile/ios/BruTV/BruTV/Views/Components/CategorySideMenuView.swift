import SwiftUI

public struct CategoryMenuItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let iconURL: URL?
    public let count: Int?
    public let systemFallbackIcon: String

    public init(
        id: String,
        name: String,
        iconURL: URL? = nil,
        count: Int? = nil,
        systemFallbackIcon: String = "tv"
    ) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.count = count
        self.systemFallbackIcon = systemFallbackIcon
    }
}

private enum LayoutMetrics {
    #if os(tvOS)
    static let iconSize: CGFloat = 48
    static let fontSize: CGFloat = 22
    static let countFontSize: CGFloat = 16
    static let rowPaddingV: CGFloat = 10
    static let rowPaddingH: CGFloat = 14
    static let cornerRadius: CGFloat = 12
    static let indicatorWidth: CGFloat = 5
    static let indicatorHeight: CGFloat = 32
    static let headerFontSize: CGFloat = 20
    static let headerIconSize: CGFloat = 18
    static let headerPaddingH: CGFloat = 20
    static let headerPaddingV: CGFloat = 16
    static let vStackSpacing: CGFloat = 8
    #else
    static let iconSize: CGFloat = 30
    static let fontSize: CGFloat = 13
    static let countFontSize: CGFloat = 11
    static let rowPaddingV: CGFloat = 6
    static let rowPaddingH: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let indicatorWidth: CGFloat = 3
    static let indicatorHeight: CGFloat = 22
    static let headerFontSize: CGFloat = 11
    static let headerIconSize: CGFloat = 12
    static let headerPaddingH: CGFloat = 14
    static let headerPaddingV: CGFloat = 10
    static let vStackSpacing: CGFloat = 4
    #endif
}

public struct CategorySideMenuView: View {
    public let title: String
    public let items: [CategoryMenuItem]
    @Binding public var selectedID: String
    public var onSelect: (String) -> Void

    @FocusState private var focusedID: String?
    @ObservedObject private var localization = LocalizationManager.shared

    public init(
        title: String = "CATEGORIES".localized,
        items: [CategoryMenuItem],
        selectedID: Binding<String>,
        onSelect: @escaping (String) -> Void = { _ in }
    ) {
        self.title = title
        self.items = items
        self._selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Category Section Header
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: LayoutMetrics.headerIconSize, weight: .bold))
                Text(title)
                    .font(.system(size: LayoutMetrics.headerFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: LayoutMetrics.countFontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.12))
                    .cornerRadius(6)
            }
            .padding(.horizontal, LayoutMetrics.headerPaddingH)
            .padding(.vertical, LayoutMetrics.headerPaddingV)

            Divider().background(Color.white.opacity(0.08))

            // Scrollable Category Items
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: LayoutMetrics.vStackSpacing) {
                        ForEach(items) { item in
                            categoryRow(item: item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.rowPaddingH)
                    .padding(.vertical, LayoutMetrics.rowPaddingV)
                }
                .onAppear {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
                .onChange(of: selectedID) { _, newID in
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        .background(Color(white: 0.06))
    }

    private func categoryRow(item: CategoryMenuItem) -> some View {
        let isSelected = selectedID == item.id
        #if os(tvOS)
        let isFocusedRow = focusedID == item.id
        #else
        let isFocusedRow = false
        #endif

        return Button {
            selectedID = item.id
            onSelect(item.id)
        } label: {
            HStack(spacing: LayoutMetrics.rowPaddingH) {
                // Leading Selected Pill Indicator
                Capsule()
                    .fill(isSelected ? Color.cyan : Color.clear)
                    .frame(width: LayoutMetrics.indicatorWidth, height: LayoutMetrics.indicatorHeight)

                // Category Icon (First Channel / Media Poster or Fallback)
                ZStack {
                    RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius - 2)
                        .fill(Color.black.opacity(0.6))

                    CachedAsyncImage(url: item.iconURL) {
                        Image(systemName: item.systemFallbackIcon)
                            .font(.system(size: LayoutMetrics.fontSize))
                            .foregroundColor(.gray)
                    }
                    .padding(3)
                }
                .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
                .cornerRadius(LayoutMetrics.cornerRadius - 2)
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius - 2)
                        .stroke(isSelected ? Color.cyan.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                )

                // Category Name
                Text(item.name)
                    .font(.system(size: LayoutMetrics.fontSize, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : Color(white: 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                // Item Count
                if let count = item.count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: LayoutMetrics.countFontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(isSelected ? .cyan : .gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(isSelected ? 0.12 : 0.05))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, LayoutMetrics.rowPaddingH)
            .padding(.vertical, LayoutMetrics.rowPaddingV)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius)
                    .fill(
                        isSelected
                            ? Color.cyan.opacity(0.18)
                            : (isFocusedRow ? Color.white.opacity(0.12) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius)
                    .stroke(
                        isSelected
                            ? Color.cyan.opacity(0.7)
                            : (isFocusedRow ? Color.white.opacity(0.4) : Color.white.opacity(0.04)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            #if os(tvOS)
            .scaleEffect(isFocusedRow ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocusedRow)
            #endif
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focused($focusedID, equals: item.id)
        #endif
        .accessibilityIdentifier("categoryItem_\(item.id)")
    }
}
