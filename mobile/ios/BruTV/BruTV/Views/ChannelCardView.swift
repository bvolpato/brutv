import SwiftUI

public extension StreamQuality {
    /// Precomputed static colors so channel cells never invoke `Scanner` / `Color(hex:)` per render.
    static let allBadgeColor = Color(.sRGB, red: 113/255, green: 128/255, blue: 150/255, opacity: 1)
    static let uhd4kBadgeColor = Color(.sRGB, red: 128/255, green: 90/255, blue: 213/255, opacity: 1)
    static let fhdBadgeColor = Color(.sRGB, red: 49/255, green: 130/255, blue: 206/255, opacity: 1)
    static let hdBadgeColor = Color(.sRGB, red: 56/255, green: 161/255, blue: 105/255, opacity: 1)
    static let sdBadgeColor = Color(.sRGB, red: 221/255, green: 107/255, blue: 32/255, opacity: 1)

    var badgeColor: Color {
        switch self {
        case .all: return Self.allBadgeColor
        case .uhd4k: return Self.uhd4kBadgeColor
        case .fhd: return Self.fhdBadgeColor
        case .hd: return Self.hdBadgeColor
        case .sd: return Self.sdBadgeColor
        }
    }
}

#if os(tvOS)
private struct TVFocusableCardButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVFocusableCardBody(configuration: configuration, isSelected: isSelected)
    }

    private struct TVFocusableCardBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? Color.cyan.opacity(0.3) : (isFocused ? Color.white.opacity(0.2) : Color(white: 0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSelected ? Color.cyan : (isFocused ? Color.cyan : Color.white.opacity(0.08)), lineWidth: (isSelected || isFocused) ? 2 : 1)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.04 : 1.0))
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
    }
}

private struct TVFocusableFavoriteButtonStyle: ButtonStyle {
    let isFavorite: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVFocusableFavoriteBody(configuration: configuration, isFavorite: isFavorite)
    }

    private struct TVFocusableFavoriteBody: View {
        let configuration: Configuration
        let isFavorite: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFavorite ? Color.red.opacity(isFocused ? 0.35 : 0.14) : Color.white.opacity(isFocused ? 0.24 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isFocused ? Color.cyan : Color.clear, lineWidth: isFocused ? 2 : 0)
                        )
                )
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif

public struct ChannelCardView: View {
    public let stream: LiveStream
    public let isSelected: Bool
    public let isFavorite: Bool
    public let onToggleFavorite: (() -> Void)?
    public let onSelect: () -> Void

    @State private var isHovered: Bool = false

    public init(
        stream: LiveStream,
        isSelected: Bool = false,
        isFavorite: Bool = false,
        onToggleFavorite: (() -> Void)? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.stream = stream
        self.isSelected = isSelected
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onSelect = onSelect
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: 8) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(TVFocusableCardButtonStyle(isSelected: isSelected))
            .accessibilityLabel(String(format: "Play %@".localized, stream.cleanName))
            .accessibilityValue(stream.num > 0 ? String(format: "Channel %d, %@".localized, stream.num, stream.quality.rawValue) : stream.quality.rawValue)
            .accessibilityIdentifier("channelCard")

            Button {
                if let onToggleFavorite {
                    onToggleFavorite()
                } else {
                    FavoritesStore.shared.toggleFavorite(channelID: stream.id)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFavorite ? .red : .white.opacity(0.75))
                    .frame(width: 52, height: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(TVFocusableFavoriteButtonStyle(isFavorite: isFavorite))
            .accessibilityLabel(isFavorite ? String(format: "Remove %@ from Favorites".localized, stream.cleanName) : String(format: "Add %@ to Favorites".localized, stream.cleanName))
            .accessibilityIdentifier("favoriteButton")
        }
        #else
        HStack(spacing: 0) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: "Play %@".localized, stream.cleanName))
            .accessibilityValue(stream.num > 0 ? String(format: "Channel %d, %@".localized, stream.num, stream.quality.rawValue) : stream.quality.rawValue)
            .accessibilityIdentifier("channelCard")

            Button {
                if let onToggleFavorite {
                    onToggleFavorite()
                } else {
                    FavoritesStore.shared.toggleFavorite(channelID: stream.id)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFavorite ? .red : .white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isFavorite ? Color.red.opacity(0.12) : Color.white.opacity(0.06))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .accessibilityLabel(isFavorite ? String(format: "Remove %@ from Favorites".localized, stream.cleanName) : String(format: "Add %@ to Favorites".localized, stream.cleanName))
            .help(isFavorite ? "Remove favorite".localized : "Add favorite".localized)
            .accessibilityIdentifier("favoriteButton")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.cyan.opacity(0.2) : (isHovered ? Color(white: 0.13) : Color(white: 0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color.cyan : (isHovered ? Color.cyan.opacity(0.45) : Color.white.opacity(0.08)), lineWidth: isSelected ? 1.5 : 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        #endif
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            // Channel Logo
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.12))
                    .frame(width: 46, height: 46)

                CachedAsyncImage(url: stream.iconURL, targetPixelSize: 128) {
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

                    // Quality Badge (static precomputed Color)
                    Text(stream.quality.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(stream.quality.badgeColor)
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
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
