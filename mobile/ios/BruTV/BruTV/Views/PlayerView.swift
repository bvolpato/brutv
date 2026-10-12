import SwiftUI
import AVKit

public struct PlayerView: View {
    @Binding public var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// iPhone portrait and narrow iPad split views.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var showControls: Bool = true
    @State private var showGuideDrawer: Bool = false
    @State private var controlsTimer: Timer?
    /// True when a double-click in the player put the Mac window in full screen.
    @State private var enteredMacFullScreen: Bool = false

    public init(isPresented: Binding<Bool> = .constant(true)) {
        self._isPresented = isPresented
    }

    private func dismissPlayer(stop: Bool = true) {
        controlsTimer?.invalidate()
        controlsTimer = nil
        exitMacFullScreenIfEntered()
        if stop {
            playback.stop()
        }
        isPresented = false
        dismiss()
    }

    /// Esc leaves full screen first. When the window is not full screen, it goes back to the channels.
    private func handleEscape() {
        #if targetEnvironment(macCatalyst)
        if MacWindowFullScreen.isActive {
            toggleMacFullScreen()
            return
        }
        #endif
        dismissPlayer(stop: true)
    }

    private func toggleMacFullScreen() {
        #if targetEnvironment(macCatalyst)
        let entering = !MacWindowFullScreen.isActive
        MacWindowFullScreen.toggle()
        enteredMacFullScreen = entering
        if entering && playback.playbackState == .playing {
            controlsTimer?.invalidate()
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
        }
        #endif
    }

    private func exitMacFullScreenIfEntered() {
        #if targetEnvironment(macCatalyst)
        if enteredMacFullScreen && MacWindowFullScreen.isActive {
            MacWindowFullScreen.toggle()
        }
        enteredMacFullScreen = false
        #endif
    }

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
            #if targetEnvironment(macCatalyst)
            // Declared before the single tap so a double-click is not read as two clicks.
            .onTapGesture(count: 2) {
                toggleMacFullScreen()
            }
            #endif
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls && playback.playbackState == .playing {
                    scheduleControlsAutoHide()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.height > 80 {
                            // Swipe Down -> Return to channels
                            dismissPlayer(stop: false)
                        } else if value.translation.width < -50 {
                            // Swipe Left -> Next Channel
                            playback.nextChannel()
                            if playback.playbackState == .playing {
                                scheduleControlsAutoHide()
                            }
                        } else if value.translation.width > 50 {
                            // Swipe Right -> Previous Channel
                            playback.previousChannel()
                            if playback.playbackState == .playing {
                                scheduleControlsAutoHide()
                            }
                        }
                    }
            )

            // Buffering Indicator with Cancel Button
            if playback.playbackState == .buffering || playback.playbackState == .loading {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(1.4)
                    Text(playback.playbackState == .loading ? "Connecting to stream..." : "Buffering live broadcast...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))

                    Button {
                        dismissPlayer(stop: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Back to Channels")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                    }
                    .accessibilityIdentifier("playerLoadingBackButton")
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.85))
                )
            }

            // Error Overlay with direct Return to Channels
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
                        Button {
                            dismissPlayer(stop: true)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back to Channels")
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityIdentifier("playerErrorBackButton")
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)

                        Button("Retry") {
                            playback.retryCurrentPlayback()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.92))
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
        .background(
            Group {
                Button("") {
                    handleEscape()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("") {
                    dismissPlayer(stop: true)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            .opacity(0)
        )
        .onAppear {
            if playback.playbackState == .playing {
                scheduleControlsAutoHide()
            }
        }
        .onChange(of: playback.playbackState) { _, newState in
            if newState == .playing {
                scheduleControlsAutoHide()
            } else {
                controlsTimer?.invalidate()
                showControls = true
            }
        }
        .onDisappear {
            controlsTimer?.invalidate()
            exitMacFullScreenIfEntered()
        }
    }

    private var topControlsBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                backToChannelsButton
                minimizeButton
                if !isCompact {
                    channelTitle
                }
                Spacer(minLength: 8)
                topActionButtons
            }
            if isCompact {
                channelTitle
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

    private var backToChannelsButton: some View {
        Button {
            dismissPlayer(stop: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                Text("Channels")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.65)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityIdentifier("playerBackButton")
    }

    private var minimizeButton: some View {
        Button {
            dismissPlayer(stop: false)
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .accessibilityLabel("Minimize")
        .accessibilityIdentifier("playerMinimizeButton")
    }

    private var channelTitle: some View {
        HStack(spacing: 10) {
            if let stream = playback.currentStream {
                CachedAsyncImage(url: stream.iconURL) {
                    Image(systemName: "tv")
                        .font(.system(size: 16))
                        .foregroundColor(.cyan)
                }
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }

            Text(streamName)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            // LIVE indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(.white)
            }
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.3)))

            // Quality Badge
            Text(qualityBadgeText)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.cyan))
        }
    }

    @ViewBuilder
    private var topActionButtons: some View {
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

            // Close Button
            Button {
                dismissPlayer(stop: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .accessibilityLabel("Close Player")
            .accessibilityIdentifier("playerCloseButton")
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
            HStack(spacing: isCompact ? 20 : 32) {
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
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundColor(.white)
                }
                .accessibilityIdentifier("playerGuideButton")

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
                .accessibilityLabel("Previous Channel")
                .accessibilityIdentifier("playerPrevButton")

                // Play / Pause
                Button {
                    playback.togglePlayPause()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: playback.isPlaybackRequested ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.cyan)
                }
                .accessibilityLabel("Play or Pause")
                .accessibilityIdentifier("playerPlayPauseButton")

                // Next Channel
                Button {
                    playback.nextChannel()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
                .accessibilityLabel("Next Channel")
                .accessibilityIdentifier("playerNextButton")

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
                .accessibilityLabel("Mute")
                .accessibilityIdentifier("playerMuteButton")
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
                    .accessibilityLabel("Close Guide")
                    .accessibilityIdentifier("guideCloseButton")
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
        guard playback.playbackState == .playing else {
            showControls = true
            return
        }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                if !showGuideDrawer && playback.playbackState == .playing {
                    withAnimation {
                        showControls = false
                    }
                }
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Controls macOS window full screen from Mac Catalyst.
///
/// UIKit has no API for this, so it reaches the AppKit window through the
/// Objective-C runtime and sends the public `toggleFullScreen:` action, the
/// same action as the green window button and View > Enter Full Screen.
enum MacWindowFullScreen {
    /// `NSWindowStyleMaskFullScreen`.
    private static let fullScreenStyleMask: UInt = 1 << 14

    private static var window: NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as AnyObject?,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject
        else { return nil }
        if let key = app.value(forKey: "keyWindow") as? NSObject { return key }
        if let main = app.value(forKey: "mainWindow") as? NSObject { return main }
        return (app.value(forKey: "windows") as? [NSObject])?
            .first { ($0.value(forKey: "isVisible") as? Bool) == true }
    }

    static var isActive: Bool {
        guard let mask = window?.value(forKey: "styleMask") as? UInt else { return false }
        return mask & fullScreenStyleMask != 0
    }

    static func toggle() {
        guard let window else { return }
        let selector = NSSelectorFromString("toggleFullScreen:")
        guard window.responds(to: selector) else { return }
        window.perform(selector, with: nil)
    }
}
#endif
