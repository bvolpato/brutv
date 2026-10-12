import SwiftUI
import AVKit

public struct PlayerView: View {
    @Binding public var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var playback = PlaybackManager.shared
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
                        Label("Back to Channels", systemImage: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(MediaControlButtonStyle())
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

                        Button {
                            playback.retryCurrentPlayback()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .controlSize(.large)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backToChannelsButton
                channelTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 16)
                minimizeButton
                closeButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    backToChannelsButton
                    Spacer(minLength: 8)
                    minimizeButton
                    closeButton
                }
                channelTitle
            }
        }
        .padding(.horizontal, 16)
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
            Label("Channels", systemImage: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
        }
        .buttonStyle(MediaControlButtonStyle())
        .help("Stop playback and return to channels")
        .accessibilityIdentifier("playerBackButton")
    }

    private var minimizeButton: some View {
        Button {
            dismissPlayer(stop: false)
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle())
        .accessibilityLabel("Minimize")
        .help("Keep playing in the mini player")
        .accessibilityIdentifier("playerMinimizeButton")
    }

    private var closeButton: some View {
        Button {
            dismissPlayer(stop: true)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle())
        .accessibilityLabel("Close Player")
        .help("Close player and stop playback")
        .accessibilityIdentifier("playerCloseButton")
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

            if playback.currentStream != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text(playback.shouldShowGoLive ? "DELAYED" : "LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.red.opacity(0.3)))

                Text(qualityBadgeText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.cyan))
            }
        }
    }

    private var bottomControlsBar: some View {
        VStack(spacing: 14) {
            if playback.currentStream != nil { liveTimeshiftControls }
            HStack(spacing: 8) {
                Button {
                    withAnimation {
                        showGuideDrawer.toggle()
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle(isActive: showGuideDrawer))
                .accessibilityLabel("Channel Guide")
                .help("Browse channels")
                .accessibilityIdentifier("playerGuideButton")

                Spacer(minLength: 0)

                Button {
                    playback.previousChannel()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle())
                .accessibilityLabel("Previous Channel")
                .help("Previous channel")
                .accessibilityIdentifier("playerPrevButton")

                Button {
                    playback.togglePlayPause()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: playback.isPlaybackRequested ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(MediaControlButtonStyle(isPrimary: true))
                .accessibilityLabel(playback.isPlaybackRequested ? "Pause" : "Play")
                .help(playback.isPlaybackRequested ? "Pause playback" : "Resume playback")
                .accessibilityIdentifier("playerPlayPauseButton")

                Button {
                    playback.nextChannel()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle())
                .accessibilityLabel("Next Channel")
                .help("Next channel")
                .accessibilityIdentifier("playerNextButton")

                Spacer(minLength: 0)

                Button {
                    playback.isMuted.toggle()
                    scheduleControlsAutoHide()
                } label: {
                    Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle(isActive: playback.isMuted))
                .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
                .help(playback.isMuted ? "Unmute audio" : "Mute audio")
                .accessibilityIdentifier("playerMuteButton")
            }
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button {
                    playback.settings.showStatsHUD.toggle()
                    scheduleControlsAutoHide()
                } label: {
                    Label("Stats", systemImage: "gauge.with.needle")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(MediaControlButtonStyle(isActive: playback.settings.showStatsHUD))
                .accessibilityLabel(playback.settings.showStatsHUD ? "Hide Stream Stats" : "Show Stream Stats")
                .help("Show or hide stream telemetry")

                Button {
                    cycleAspectRatio()
                    scheduleControlsAutoHide()
                } label: {
                    Label("Aspect", systemImage: "aspectratio")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(MediaControlButtonStyle())
                .accessibilityLabel("Change Aspect Ratio")
                .accessibilityValue(playback.aspectRatio.displayName)
                .help("Aspect ratio: \(playback.aspectRatio.displayName)")
            }
            .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                Text("Buffer: \(playback.telemetry.bufferDurationFormatted)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

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
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var liveTimeshiftControls: some View {
        VStack(spacing: 8) {
            if playback.canSeekLive {
                Slider(value: Binding(get: { playback.livePlayhead }, set: { playback.seekLive(to: $0) }),
                       in: playback.liveSeekStart...max(playback.liveSeekStart + 0.1, playback.liveSeekEnd))
                    .tint(.cyan)
                    .accessibilityLabel("Live rewind position")
                    .accessibilityIdentifier("playerLiveSeekSlider")
                HStack(spacing: 12) {
                    Button { playback.seekLive(by: -10); scheduleControlsAutoHide() } label: {
                        Label("10s", systemImage: "gobackward.10")
                    }
                    .buttonStyle(MediaControlButtonStyle())
                    .accessibilityLabel("Rewind 10 seconds")
                    Button { playback.seekLive(by: 10); scheduleControlsAutoHide() } label: {
                        Label("10s", systemImage: "goforward.10")
                    }
                    .buttonStyle(MediaControlButtonStyle())
                    .accessibilityLabel("Forward 10 seconds")
                    Spacer(minLength: 0)
                    if playback.shouldShowGoLive {
                        Button { playback.goLive(); scheduleControlsAutoHide() } label: {
                            Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(MediaControlButtonStyle(isActive: true))
                        .accessibilityIdentifier("playerGoLiveButton")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                if let reason = playback.liveBufferUnavailable {
                    Text("Rewind unavailable. \(reason)")
                } else {
                    Text(String(format: "Saved %.0fs · %.1f MiB", playback.liveBuffer.duration,
                                Double(playback.liveBuffer.bytes) / 1_048_576))
                    Spacer(minLength: 0)
                    Text(playback.liveBehindSeconds > 1 ? String(format: "%.0fs behind", playback.liveBehindSeconds) : "Live")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.8))
            if let notice = playback.liveBuffer.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 520)
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
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(MediaControlButtonStyle())
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

struct MediaControlButtonStyle: ButtonStyle {
    var isPrimary = false
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .foregroundColor(isPrimary ? .black : (isActive ? .cyan : .white))
            .background(
                RoundedRectangle(cornerRadius: isPrimary ? 22 : 14, style: .continuous)
                    .fill(isPrimary ? Color.cyan : (isActive ? Color.cyan.opacity(0.18) : Color.white.opacity(0.12)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: isPrimary ? 22 : 14, style: .continuous)
                    .stroke(isActive ? Color.cyan.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: isPrimary ? 22 : 14, style: .continuous))
            .hoverEffect(.highlight)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
