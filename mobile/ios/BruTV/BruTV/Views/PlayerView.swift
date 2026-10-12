import SwiftUI
import AVKit

public struct PlayerView: View {
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var showControls: Bool = true
    @State private var showGuideDrawer: Bool = false
    @State private var controlsTimer: Timer?

    public init() {}

    private var streamName: String {
        if let live = playback.currentStream {
            return live.cleanName
        } else if let vod = playback.currentVOD {
            return vod.name
        }
        return "Now Playing"
    }

    private var qualityBadgeText: String {
        playback.currentStream?.quality.rawValue ?? "HD"
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video Canvas
            VideoPlayerContainer(
                player: playback.player,
                aspectRatio: playback.aspectRatio,
                showsNativeControls: false
            )
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls {
                    scheduleControlsAutoHide()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        if value.translation.width < -50 {
                            // Swipe Left -> Next Channel
                            playback.nextChannel()
                            scheduleControlsAutoHide()
                        } else if value.translation.width > 50 {
                            // Swipe Right -> Previous Channel
                            playback.previousChannel()
                            scheduleControlsAutoHide()
                        }
                    }
            )

            // Buffering Indicator
            if playback.playbackState == .buffering || playback.playbackState == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(1.4)
                    Text(playback.playbackState == .loading ? "Connecting to stream..." : "Buffering live broadcast...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                }
            }

            // Error Overlay
            if case .failed(let msg) = playback.playbackState {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Playback Error")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 12) {
                        Button("Retry") {
                            if let s = playback.currentStream {
                                playback.play(stream: s)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)

                        Button("Close") {
                            playback.stop()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.88))
                )
            }

            // HUD Telemetry Overlay (Top-Right)
            if playback.settings.showStatsHUD {
                VStack {
                    HStack {
                        Spacer()
                        TechStatsHUD(telemetry: playback.telemetry)
                            .padding(.top, 60)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }

            // Overlay Controls
            if showControls {
                VStack {
                    topControlsBar
                    Spacer()
                    bottomControlsBar
                }
                .transition(.opacity)
            }

            // Quick Channel Guide Drawer
            if showGuideDrawer {
                quickChannelDrawer
            }
        }
        .onAppear {
            scheduleControlsAutoHide()
        }
        .onDisappear {
            controlsTimer?.invalidate()
        }
    }

    private var topControlsBar: some View {
        HStack(spacing: 12) {
            Button {
                playback.stop()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.85))
            }

            // Channel Logo & Title
            if let stream = playback.currentStream {
                CachedAsyncImage(url: stream.iconURL) {
                    Image(systemName: "tv")
                        .font(.system(size: 16))
                        .foregroundColor(.cyan)
                }
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(streamName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    // LIVE indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.3)))

                    // Quality Badge
                    Text(qualityBadgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan))
                }
            }

            Spacer()

            // HUD Toggle
            Button {
                playback.settings.showStatsHUD.toggle()
                scheduleControlsAutoHide()
            } label: {
                Image(systemName: playback.settings.showStatsHUD ? "gauge.with.needle.fill" : "gauge.with.needle")
                    .font(.system(size: 18))
                    .foregroundColor(playback.settings.showStatsHUD ? .cyan : .white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }

            // Aspect Ratio Toggle
            Button {
                cycleAspectRatio()
                scheduleControlsAutoHide()
            } label: {
                Image(systemName: "aspectratio")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomControlsBar: some View {
        VStack(spacing: 12) {
            // Buffer bar
            HStack(spacing: 10) {
                Text("Buffer: \(playback.telemetry.bufferDurationFormatted)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule()
                            .fill(playback.telemetry.bufferDuration >= 3.0 ? Color.green : Color.yellow)
                            .frame(width: min(geo.size.width, geo.size.width * CGFloat(playback.telemetry.bufferDuration / 10.0)))
                    }
                }
                .frame(height: 4)

                Text(playback.telemetry.observedBitrateFormatted)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 20)

            // Playback and Zapping controls
            HStack(spacing: 32) {
                // Channel Guide Drawer
                Button {
                    withAnimation {
                        showGuideDrawer.toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 20))
                        Text("Channels")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.white)
                }

                Spacer()

                // Previous Channel
                Button {
                    playback.previousChannel()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

                // Play / Pause
                Button {
                    playback.togglePlayPause()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: playback.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.cyan)
                }

                // Next Channel
                Button {
                    playback.nextChannel()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

                Spacer()

                // Mute Toggle
                Button {
                    playback.isMuted.toggle()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var quickChannelDrawer: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Channel Guide")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        withAnimation { showGuideDrawer = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Divider().background(Color.white.opacity(0.15))

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(playback.activePlaylist) { ch in
                            ChannelCardView(
                                stream: ch,
                                isSelected: playback.currentStream?.id == ch.id
                            ) {
                                playback.play(stream: ch)
                                withAnimation { showGuideDrawer = false }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
            .frame(width: 320)
            .background(Color(white: 0.1).opacity(0.95))
            .transition(.move(edge: .trailing))
        }
    }

    private func cycleAspectRatio() {
        switch playback.aspectRatio {
        case .fit: playback.aspectRatio = .fill
        case .fill: playback.aspectRatio = .sixteenByNine
        case .sixteenByNine: playback.aspectRatio = .fourByThree
        case .fourByThree: playback.aspectRatio = .fit
        }
    }

    private func scheduleControlsAutoHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                if !showGuideDrawer {
                    withAnimation {
                        showControls = false
                    }
                }
            }
        }
    }
}
