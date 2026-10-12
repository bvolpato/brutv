import SwiftUI

public struct ChannelCardView: View {
    public let stream: LiveStream
    public let isSelected: Bool
    public let onSelect: () -> Void

    @ObservedObject private var favorites = FavoritesStore.shared

    public init(stream: LiveStream, isSelected: Bool = false, onSelect: @escaping () -> Void) {
        self.stream = stream
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var isFav: Bool {
        favorites.isFavorite(channelID: stream.id)
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Channel Logo
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.12))
                        .frame(width: 58, height: 58)

                    CachedAsyncImage(url: stream.iconURL) {
                        ZStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "tv")
                                .font(.system(size: 18))
                                .foregroundColor(.cyan)
                        }
                    }
                    .frame(width: 48, height: 48)
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
                            .foregroundColor(.white)
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

                    Text("Live Broadcast")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                // Favorite Toggle Button
                Button {
                    favorites.toggleFavorite(channelID: stream.id)
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                        .foregroundColor(isFav ? .red : .gray.opacity(0.6))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.cyan.opacity(0.2) : Color(white: 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.cyan : Color.white.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
