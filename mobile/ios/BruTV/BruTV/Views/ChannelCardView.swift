import SwiftUI

public struct ChannelCardView: View {
    public let stream: LiveStream
    public let isSelected: Bool
    public let onSelect: () -> Void

    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var isHovered: Bool = false
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    public init(stream: LiveStream, isSelected: Bool = false, onSelect: @escaping () -> Void) {
        self.stream = stream
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var isFav: Bool {
        favorites.isFavorite(channelID: stream.id)
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    // Channel Logo
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(white: 0.12))
                            .frame(width: 46, height: 46)

                        CachedAsyncImage(url: stream.iconURL) {
                            ZStack {
                                Circle()
                                    .fill(Color.cyan.opacity(0.15))
                                    .frame(width: 30, height: 30)
                                Image(systemName: "tv")
                                    .font(.system(size: 16))
                                    .foregroundColor(.cyan)
                            }
                        }
                        .frame(width: 38, height: 38)
                    }

                    // Channel Info
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if stream.num > 0 {
                                Text("\(stream.num)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                            }

                            Text(stream.cleanName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(isSelected ? .cyan : .white)
                                .lineLimit(1)

                            Spacer()

                            // Quality Badge
                            Text(stream.quality.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color(hex: stream.quality.badgeColorHex))
                                )
                        }

                        if isSelected {
                            HStack(spacing: 5) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.cyan)
                                Text("Playing now".localized)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.cyan)
                            }
                        }
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: "Play %@".localized, stream.cleanName))
            .accessibilityValue(stream.num > 0 ? String(format: "Channel %d, %@".localized, stream.num, stream.quality.rawValue) : stream.quality.rawValue)
            .accessibilityIdentifier("channelCard")

            Button {
                favorites.toggleFavorite(channelID: stream.id)
            } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFav ? .red : .white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isFav ? Color.red.opacity(0.12) : Color.white.opacity(0.06))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .accessibilityLabel(isFav ? String(format: "Remove %@ from Favorites".localized, stream.cleanName) : String(format: "Add %@ to Favorites".localized, stream.cleanName))
            .help(isFav ? "Remove favorite".localized : "Add favorite".localized)
            .accessibilityIdentifier("favoriteButton")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                #if os(tvOS)
                .fill(isSelected ? Color.cyan.opacity(0.3) : (isFocused ? Color.white.opacity(0.2) : Color(white: 0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color.cyan : (isFocused ? Color.cyan : Color.white.opacity(0.08)), lineWidth: (isSelected || isFocused) ? 2 : 1)
                )
                .scaleEffect(isFocused ? 1.04 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
                #else
                .fill(isSelected ? Color.cyan.opacity(0.2) : (isHovered ? Color(white: 0.13) : Color(white: 0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color.cyan : (isHovered ? Color.cyan.opacity(0.45) : Color.white.opacity(0.08)), lineWidth: isSelected ? 1.5 : 1)
                )
                #endif
        )
        #if !os(tvOS)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        #endif
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
