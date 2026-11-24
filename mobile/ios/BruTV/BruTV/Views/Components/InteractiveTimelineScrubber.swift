import SwiftUI
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

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
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var tvScrubCommitTask: Task<Void, Never>?
    #endif

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

    private func triggerHaptic(heavy: Bool = false) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let generator = UIImpactFeedbackGenerator(style: heavy ? .medium : .light)
        generator.impactOccurred()
        #endif
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
            #if os(tvOS)
            let tvFocused = isFocused
            #else
            let tvFocused = false
            #endif
            let tooltipTime = isDragging ? dragValue : (tvFocused ? activeValue : hoverTime)
            let targetX = isDragging ? dragLocationX : (tvFocused ? progressWidth : hoverLocationX)
            let tooltipX = min(max(32, targetX), width - 32)
            let isActive = isHovering || isDragging || tvFocused
            let trackHeight: CGFloat = isActive ? 7 : 5

            ZStack(alignment: .leading) {
                // Generous hit target area
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 32)
                    .contentShape(Rectangle())

                // Track container
                ZStack(alignment: .leading) {
                    // Background Track
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .overlay(
                            Capsule()
                                .stroke(tvFocused ? Color.cyan.opacity(0.7) : Color.white.opacity(0.08), lineWidth: tvFocused ? 1.5 : 0.5)
                        )
                        .frame(height: trackHeight)

                    // Optional Buffered Track
                    if let buffered = bufferedValue, buffered > range.lowerBound {
                        let bufferedFrac = min(max(0, (buffered - range.lowerBound) / span), 1.0)
                        Capsule()
                            .fill(Color.white.opacity(0.32))
                            .frame(width: bufferedFrac * width, height: trackHeight)
                    }

                    // Progress Track
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#00E5FF"), Color(hex: "#0077ED")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(
                            color: Color.cyan.opacity(isActive ? 0.6 : 0.25),
                            radius: isActive ? 4 : 2,
                            x: 0,
                            y: 0
                        )
                        .frame(width: max(0, progressWidth), height: trackHeight)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isActive)

                // Scrubber Thumb
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: (isDragging || tvFocused) ? 16 : (isHovering ? 14 : 12),
                        height: (isDragging || tvFocused) ? 16 : (isHovering ? 14 : 12)
                    )
                    .overlay(
                        Circle().stroke(Color.cyan, lineWidth: 2)
                    )
                    .shadow(
                        color: Color.cyan.opacity(isActive ? 0.75 : 0.35),
                        radius: isActive ? 6 : 2
                    )
                    .position(x: min(max(0, progressWidth), width), y: 16)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isActive)

                // Floating Time Tooltip on Hover, Drag, or tvOS Focus
                if isActive {
                    HStack(spacing: 3) {
                        Text(formatTime(tooltipTime))
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(hex: "#0a0f1d").opacity(0.92))
                            .background(Capsule().fill(.ultraThinMaterial))
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
            .frame(height: 32)
            #if os(tvOS)
            .focusable(true)
            .focused($isFocused)
            .onMoveCommand { direction in
                let step = max(10.0, min(60.0, span * 0.02))
                switch direction {
                case .left:
                    adjustTVScrub(delta: -step, span: span, width: width)
                case .right:
                    adjustTVScrub(delta: step, span: span, width: width)
                default:
                    if isDragging {
                        commitTVScrub()
                    }
                }
            }
            .onTapGesture {
                if isDragging {
                    commitTVScrub()
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused && isDragging {
                    commitTVScrub()
                }
            }
            #else
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let frac = min(max(0, gesture.location.x / width), 1.0)
                        let time = range.lowerBound + frac * span
                        if !isDragging {
                            triggerHaptic(heavy: false)
                        }
                        isDragging = true
                        dragLocationX = gesture.location.x
                        dragValue = time
                        onScrubbingChanged?(true, time)
                    }
                    .onEnded { gesture in
                        let frac = min(max(0, gesture.location.x / width), 1.0)
                        let time = range.lowerBound + frac * span
                        isDragging = false
                        triggerHaptic(heavy: true)
                        onScrubbingChanged?(false, time)
                        onSeek(time)
                    }
            )
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
        .frame(height: 32)
    }

    #if os(tvOS)
    private func adjustTVScrub(delta: Double, span: Double, width: CGFloat) {
        let base = isDragging ? dragValue : value
        let target = min(range.upperBound, max(range.lowerBound, base + delta))
        isDragging = true
        dragValue = target
        let frac = min(max(0, (target - range.lowerBound) / span), 1.0)
        dragLocationX = frac * width
        onScrubbingChanged?(true, target)
        tvScrubCommitTask?.cancel()
        tvScrubCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            commitTVScrub()
        }
    }

    private func commitTVScrub() {
        tvScrubCommitTask?.cancel()
        tvScrubCommitTask = nil
        guard isDragging else { return }
        let target = dragValue
        isDragging = false
        onScrubbingChanged?(false, target)
        onSeek(target)
    }
    #endif
}
