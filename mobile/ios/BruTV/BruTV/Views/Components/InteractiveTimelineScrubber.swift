import SwiftUI

public struct InteractiveTimelineScrubber: View {
    public let value: Double
    public let range: ClosedRange<Double>
    public var bufferedValue: Double? = nil
    public let onSeek: (Double) -> Void
    public var onScrubbingChanged: ((Bool, Double) -> Void)? = nil
    public var formatTime: (Double) -> String

    @State private var isHovering: Bool = false
    @State private var hoverLocationX: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var dragLocationX: CGFloat = 0
    @State private var dragValue: Double = 0

    public init(
        value: Double,
        range: ClosedRange<Double>,
        bufferedValue: Double? = nil,
        onSeek: @escaping (Double) -> Void,
        onScrubbingChanged: ((Bool, Double) -> Void)? = nil,
        formatTime: @escaping (Double) -> String
    ) {
        self.value = value
        self.range = range
        self.bufferedValue = bufferedValue
        self.onSeek = onSeek
        self.onScrubbingChanged = onScrubbingChanged
        self.formatTime = formatTime
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let span = max(0.001, range.upperBound - range.lowerBound)
            let activeValue = isDragging ? dragValue : value
            let progressFraction = min(max(0, (activeValue - range.lowerBound) / span), 1.0)
            let progressWidth = progressFraction * width

            let hoverFraction = min(max(0, hoverLocationX / width), 1.0)
            let hoverTime = range.lowerBound + hoverFraction * span
            let tooltipTime = isDragging ? dragValue : hoverTime
            let targetX = isDragging ? dragLocationX : hoverLocationX
            let tooltipX = min(max(32, targetX), width - 32)

            ZStack(alignment: .leading) {
                // Generous hit target area
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 28)
                    .contentShape(Rectangle())

                // Track container
                ZStack(alignment: .leading) {
                    // Background Track
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: isHovering || isDragging ? 6 : 4)

                    // Optional Buffered Track
                    if let buffered = bufferedValue, buffered > range.lowerBound {
                        let bufferedFrac = min(max(0, (buffered - range.lowerBound) / span), 1.0)
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: bufferedFrac * width, height: isHovering || isDragging ? 6 : 4)
                    }

                    // Progress Track
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, Color(hex: "#00B4D8")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, progressWidth), height: isHovering || isDragging ? 6 : 4)
                }
                .animation(.easeOut(duration: 0.15), value: isHovering || isDragging)

                // Scrubber Thumb
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: isDragging ? 16 : (isHovering ? 14 : 12),
                        height: isDragging ? 16 : (isHovering ? 14 : 12)
                    )
                    .overlay(
                        Circle().stroke(Color.cyan, lineWidth: 2)
                    )
                    .shadow(
                        color: Color.cyan.opacity(isDragging || isHovering ? 0.8 : 0.35),
                        radius: isDragging || isHovering ? 6 : 2
                    )
                    .position(x: min(max(0, progressWidth), width), y: 14)
                    .animation(.easeOut(duration: 0.1), value: isDragging || isHovering)

                // Floating Time Tooltip on Hover or Drag
                if isHovering || isDragging {
                    HStack(spacing: 3) {
                        Text(formatTime(tooltipTime))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(hex: "#0a0f1d").opacity(0.95))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.cyan.opacity(0.65), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 3)
                    .position(x: tooltipX, y: -14)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .frame(height: 28)
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let frac = min(max(0, gesture.location.x / width), 1.0)
                        let time = range.lowerBound + frac * span
                        isDragging = true
                        dragLocationX = gesture.location.x
                        dragValue = time
                        onScrubbingChanged?(true, time)
                    }
                    .onEnded { gesture in
                        let frac = min(max(0, gesture.location.x / width), 1.0)
                        let time = range.lowerBound + frac * span
                        isDragging = false
                        onScrubbingChanged?(false, time)
                        onSeek(time)
                    }
            )
            #endif
            #if !os(tvOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    hoverLocationX = location.x
                case .ended:
                    isHovering = false
                }
            }
            #endif
        }
        .frame(height: 28)
    }
}
