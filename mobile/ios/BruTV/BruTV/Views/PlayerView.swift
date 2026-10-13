import SwiftUI
import AVKit

public struct PlayerView: View {
    @Binding public var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var playback = PlaybackManager.shared
    @ObservedObject private var pictureInPicture = PictureInPictureModel.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var showControls: Bool = true
    @State private var showGuideDrawer: Bool = false
    @State private var controlsTimer: Timer?
    /// True when a double-click in the player put the Mac window in full screen.
    @State private var enteredMacFullScreen: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0

    public init(isPresented: Binding<Bool> = .constant(true)) {
        self._isPresented = isPresented
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
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

    /// Hands the provider URL to VLC through its x-callback URL. If VLC is not
    /// installed, opens its App Store page.
    private func openInVLC() {
        guard let source = playback.providerURL else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encoded = source.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed),
              let vlc = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") else { return }
        UIApplication.shared.open(vlc) { opened in
            guard !opened, let store = URL(string: "https://apps.apple.com/app/vlc-media-player/id650377962") else { return }
            UIApplication.shared.open(store)
        }
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
                showsNativeControls: false,
                allowsPictureInPicture: true,
                accessibilityIdentifier: "playerVideo",
                accessibilityStatus: playback.playbackState.testDescription
            )
            .ignoresSafeArea()

            // Fullscreen Gesture & Click Surface
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                #if targetEnvironment(macCatalyst)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        toggleMacFullScreen()
                    }
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if showControls && playback.playbackState == .playing {
                        scheduleControlsAutoHide()
                    } else {
                        controlsTimer?.invalidate()
                    }
                }
                #else
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if showControls && playback.playbackState == .playing {
                        scheduleControlsAutoHide()
                    } else {
                        controlsTimer?.invalidate()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            if value.translation.height > 80 {
                                dismissPlayer(stop: false)
                            } else if value.translation.width < -50 {
                                playback.nextChannel()
                                if playback.playbackState == .playing {
                                    scheduleControlsAutoHide()
                                }
                            } else if value.translation.width > 50 {
                                playback.previousChannel()
                                if playback.playbackState == .playing {
                                    scheduleControlsAutoHide()
                                }
                            }
                        }
                )
                #endif

            // Buffering Indicator
            if playback.playbackState == .buffering || playback.playbackState == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(1.3)
                    Text((playback.playbackState == .loading ? "Connecting to stream..." : "Buffering broadcast...").localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
            }

            // Error Overlay with direct Return to Channels
            if case .failed(let msg) = playback.playbackState {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Playback Error".localized)
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
                                Text(playback.currentVOD != nil ? "Back".localized : "Back to Channels".localized)
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityIdentifier("playerErrorBackButton")
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)

                        Button {
                            playback.retryCurrentPlayback()
                        } label: {
                            Label("Retry".localized, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .controlSize(.large)

                    if playback.providerURL != nil {
                        Button {
                            openInVLC()
                        } label: {
                            Label("Open in VLC".localized, systemImage: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .tint(.cyan)
                        .accessibilityIdentifier("playerOpenInVLCButton")
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
                        .contentShape(Rectangle())
                        #if targetEnvironment(macCatalyst)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                toggleMacFullScreen()
                            }
                        )
                        #endif
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls = false
                            }
                            controlsTimer?.invalidate()
                        }
                    bottomControlsBar
                }
                .transition(.opacity)
            }

            // Quick Channel Guide Drawer
            if showGuideDrawer {
                quickChannelDrawer
            }
        }
        #if targetEnvironment(macCatalyst)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !showControls {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                }
                if playback.playbackState == .playing {
                    scheduleControlsAutoHide()
                }
            case .ended:
                break
            }
        }
        #endif
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
        HStack(spacing: 10) {
            backToChannelsButton
            channelTitle
            Spacer(minLength: 8)
            minimizeButton
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 20)
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
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel(playback.currentVOD != nil ? "Back" : "Back to Channels")
        .help(playback.currentVOD != nil ? "Stop playback and return" : "Stop playback and return to channels")
        .accessibilityIdentifier("playerBackButton")
    }

    private var minimizeButton: some View {
        Button {
            dismissPlayer(stop: false)
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Minimize")
        .help("Keep playing in the mini player")
        .accessibilityIdentifier("playerMinimizeButton")
    }

    private var closeButton: some View {
        Button {
            dismissPlayer(stop: true)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Close Player")
        .help("Close player and stop playback")
        .accessibilityIdentifier("playerCloseButton")
    }

    private var channelTitle: some View {
        HStack(spacing: 8) {
            if let stream = playback.currentStream {
                CachedAsyncImage(url: stream.iconURL) {
                    Image(systemName: "tv")
                        .font(.system(size: 14))
                        .foregroundColor(.cyan)
                }
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            } else if let vod = playback.currentVOD {
                CachedAsyncImage(url: vod.iconURL) {
                    Image(systemName: vod.streamType == "series" ? "play.tv" : "film")
                        .font(.system(size: 14))
                        .foregroundColor(.cyan)
                }
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }

            Text(streamName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if playback.currentStream != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                    Text(playback.shouldShowGoLive ? "DELAYED" : "LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.3)))

                Text(qualityBadgeText)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan))
            } else if let vod = playback.currentVOD {
                Text(vod.streamType == "series" ? "SERIES" : "MOVIE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan))
            }
        }
    }

    private var bottomControlsBar: some View {
        VStack(spacing: 0) {
            if playback.currentVOD != nil {
                vodControlsDeck
            } else {
                liveControlsDeck
            }
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

    private var vodControlsDeck: some View {
        VStack(spacing: 10) {
            // Scrubber Row
            HStack(spacing: 10) {
                Text(formatTime(isScrubbing ? scrubTime : playback.vodCurrentTime))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(minWidth: 44, alignment: .leading)

                InteractiveTimelineScrubber(
                    value: isScrubbing ? scrubTime : playback.vodCurrentTime,
                    range: 0...max(1.0, playback.vodDuration),
                    onSeek: { targetTime in
                        isScrubbing = false
                        playback.seek(to: targetTime)
                        scheduleControlsAutoHide()
                    },
                    onScrubbingChanged: { scrubbing, previewTime in
                        isScrubbing = scrubbing
                        scrubTime = previewTime
                        if scrubbing {
                            controlsTimer?.invalidate()
                        }
                    },
                    formatTime: { seconds in
                        formatTime(seconds)
                    }
                )
                .accessibilityLabel("Playback progress scrubber")
                .accessibilityIdentifier("vodTimelineScrubber")

                Text(formatTime(playback.vodDuration))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(minWidth: 44, alignment: .trailing)
            }

            // Buttons Row
            HStack(spacing: 0) {
                // Left group
                HStack(spacing: 8) {
                    audioSubtitleMenu
                }

                Spacer(minLength: 8)

                // Center playback group
                HStack(spacing: 12) {
                    vodRewindButton
                    playPauseButton
                    vodForwardButton
                }

                Spacer(minLength: 8)

                // Right group
                HStack(spacing: 8) {
                    muteButton
                    moreOptionsMenu
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.90))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 6)
        .frame(maxWidth: 580)
    }

    private var liveControlsDeck: some View {
        VStack(spacing: 10) {
            if playback.settings.liveRewind {
                liveTimeshiftControls
            }

            HStack(spacing: 0) {
                // Left group
                HStack(spacing: 8) {
                    guideButton
                    audioSubtitleMenu
                }

                Spacer(minLength: 8)

                // Center playback group
                HStack(spacing: 12) {
                    prevChannelButton
                    playPauseButton
                    nextChannelButton
                }

                Spacer(minLength: 8)

                // Right group
                HStack(spacing: 8) {
                    muteButton
                    moreOptionsMenu
                }
            }

            compactBufferIndicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.90))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 6)
        .frame(maxWidth: 580)
    }

    private var vodRewindButton: some View {
        Button {
            playback.seekRelative(-10)
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "gobackward.10")
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Rewind 10 seconds")
    }

    private var vodForwardButton: some View {
        Button {
            playback.seekRelative(10)
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "goforward.10")
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Fast forward 10 seconds")
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayPause()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: playback.isPlaybackRequested ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .bold))
        }
        .buttonStyle(MediaControlButtonStyle(isPrimary: true, isCircular: true, size: 48))
        .accessibilityLabel(playback.isPlaybackRequested ? "Pause" : "Play")
        .help(playback.isPlaybackRequested ? "Pause playback" : "Resume playback")
        .accessibilityIdentifier("playerPlayPauseButton")
    }

    private var prevChannelButton: some View {
        Button {
            playback.previousChannel()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "backward.end.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Previous Channel")
        .help("Previous channel")
        .accessibilityIdentifier("playerPrevButton")
    }

    private var nextChannelButton: some View {
        Button {
            playback.nextChannel()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Next Channel")
        .help("Next channel")
        .accessibilityIdentifier("playerNextButton")
    }

    private var guideButton: some View {
        Button {
            withAnimation {
                showGuideDrawer.toggle()
            }
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: showGuideDrawer, isCircular: true, size: 38))
        .accessibilityLabel("Channel Guide")
        .help("Browse channels")
        .accessibilityIdentifier("playerGuideButton")
    }

    private var audioSubtitleMenu: some View {
        Menu {
            Section("Audio Track".localized) {
                if playback.availableAudioTracks.isEmpty {
                    Text("Default Audio".localized)
                } else {
                    ForEach(playback.availableAudioTracks) { track in
                        Button {
                            playback.selectAudioTrack(id: track.id)
                        } label: {
                            if track.isSelected {
                                Label(track.displayName, systemImage: "checkmark")
                            } else {
                                Text(track.displayName)
                            }
                        }
                    }
                }
            }

            Section("Subtitles".localized) {
                Button {
                    playback.selectSubtitle(id: nil)
                } label: {
                    if playback.selectedSubtitleID == nil {
                        Label("Off".localized, systemImage: "checkmark")
                    } else {
                        Text("Off".localized)
                    }
                }

                ForEach(playback.availableSubtitles) { track in
                    Button {
                        playback.selectSubtitle(id: track.id)
                    } label: {
                        if track.isSelected {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: playback.selectedSubtitleID != nil, isCircular: true, size: 38))
        .accessibilityLabel("Audio and Subtitles")
        .help("Select audio language and subtitles")
    }

    private var moreOptionsMenu: some View {
        Menu {
            Menu {
                ForEach(VideoAspectRatio.allCases) { ratio in
                    Button {
                        playback.aspectRatio = ratio
                    } label: {
                        if playback.aspectRatio == ratio {
                            Label(ratio.displayName, systemImage: "checkmark")
                        } else {
                            Text(ratio.displayName)
                        }
                    }
                }
            } label: {
                Label("Aspect: \(playback.aspectRatio.displayName)", systemImage: "aspectratio")
            }

            Section {
                Button {
                    playback.settings.showStatsHUD.toggle()
                } label: {
                    Label(playback.settings.showStatsHUD ? "Hide Stream Stats" : "Show Stream Stats",
                          systemImage: playback.settings.showStatsHUD ? "gauge.with.needle.fill" : "gauge.with.needle")
                }

                if PictureInPictureModel.isSupported {
                    Button {
                        pictureInPicture.toggle()
                    } label: {
                        Label(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture",
                              systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                    }
                    .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                }

                #if targetEnvironment(macCatalyst)
                Button {
                    toggleMacFullScreen()
                } label: {
                    Label(MacWindowFullScreen.isActive ? "Exit Full Screen" : "Enter Full Screen",
                          systemImage: MacWindowFullScreen.isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                #endif
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: playback.settings.showStatsHUD, isCircular: true, size: 38))
        .accessibilityLabel("More Options")
        .accessibilityIdentifier("playerMoreOptionsButton")
    }

    private var aspectRatioButton: some View {
        Button {
            cycleAspectRatio()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "aspectratio")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 38))
        .accessibilityLabel("Change Aspect Ratio")
        .accessibilityValue(playback.aspectRatio.displayName)
        .help("Aspect ratio: \(playback.aspectRatio.displayName)")
    }

    private var muteButton: some View {
        Button {
            playback.isMuted.toggle()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: playback.isMuted, isCircular: true, size: 38))
        .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
        .help(playback.isMuted ? "Unmute audio" : "Mute audio")
        .accessibilityIdentifier("playerMuteButton")
    }

    private var statsButton: some View {
        Button {
            playback.settings.showStatsHUD.toggle()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: playback.settings.showStatsHUD, isCircular: true, size: 38))
        .accessibilityLabel(playback.settings.showStatsHUD ? "Hide Stream Stats" : "Show Stream Stats")
        .help("Show or hide stream telemetry")
    }

    private var pipButton: some View {
        Button {
            pictureInPicture.toggle()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: pictureInPicture.isActive, isCircular: true, size: 38))
        .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
        .accessibilityLabel(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture")
        .help("Picture in Picture")
        .accessibilityIdentifier("playerPiPButton")
    }

    #if targetEnvironment(macCatalyst)
    private var fullscreenButton: some View {
        Button {
            toggleMacFullScreen()
            scheduleControlsAutoHide()
        } label: {
            Image(systemName: MacWindowFullScreen.isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(MediaControlButtonStyle(isActive: MacWindowFullScreen.isActive, isCircular: true, size: 38))
        .accessibilityLabel(MacWindowFullScreen.isActive ? "Exit Full Screen" : "Enter Full Screen")
        .help("Full Screen")
    }
    #endif

    private var compactBufferIndicator: some View {
        HStack(spacing: 6) {
            Text("Buffer \(playback.telemetry.bufferDurationFormatted)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Capsule()
                .fill(Color.white.opacity(0.12))
                .overlay(
                    GeometryReader { geo in
                        Capsule()
                            .fill(playback.telemetry.bufferDuration >= 3.0 ? Color.green : (playback.telemetry.bufferDuration >= 1.0 ? Color.yellow : Color.orange))
                            .frame(width: min(geo.size.width, max(2, geo.size.width * CGFloat(min(1.0, playback.telemetry.bufferDuration / 10.0)))))
                    }
                )
                .frame(height: 3)

            if !playback.telemetry.observedBitrateFormatted.isEmpty {
                Text(playback.telemetry.observedBitrateFormatted)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: 12)
        .padding(.top, 2)
    }

    private var liveTimeshiftControls: some View {
        Group {
            if playback.canSeekLive && (playback.liveSeekEnd - playback.liveSeekStart) >= 4 {
                VStack(spacing: 6) {
                    InteractiveTimelineScrubber(
                        value: playback.livePlayhead,
                        range: playback.liveSeekStart...max(playback.liveSeekStart + 0.1, playback.liveSeekEnd),
                        onSeek: { targetTime in
                            playback.seekLive(to: targetTime)
                            scheduleControlsAutoHide()
                        },
                        onScrubbingChanged: { scrubbing, _ in
                            if scrubbing {
                                controlsTimer?.invalidate()
                            }
                        },
                        formatTime: { targetTime in
                            let diff = playback.liveSeekEnd - targetTime
                            if diff < 2.0 {
                                return "LIVE"
                            } else {
                                return "-" + formatTime(diff)
                            }
                        }
                    )
                    .accessibilityLabel("Live rewind position")
                    .accessibilityIdentifier("playerLiveSeekSlider")

                    HStack(spacing: 8) {
                        Button {
                            playback.seekLive(by: -10)
                            scheduleControlsAutoHide()
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 30))
                        .accessibilityLabel("Rewind 10 seconds")

                        Button {
                            playback.seekLive(by: 10)
                            scheduleControlsAutoHide()
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(MediaControlButtonStyle(isCircular: true, size: 30))
                        .accessibilityLabel("Forward 10 seconds")

                        Spacer()

                        if playback.shouldShowGoLive {
                            Button {
                                playback.goLive()
                                scheduleControlsAutoHide()
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.red).frame(width: 5, height: 5)
                                    Text("GO LIVE")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(MediaControlButtonStyle(isActive: true, size: 28))
                            .accessibilityIdentifier("playerGoLiveButton")
                        } else {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                Text("LIVE".localized)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            } else if let reason = playback.liveBufferUnavailable, !reason.contains("too long") {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                    Text(reason.localized)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundColor(.orange.opacity(0.85))
            }
        }
    }

    private var quickChannelDrawer: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Channel Guide".localized)
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
                    .accessibilityLabel("Close Guide".localized)
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
    var isCircular = false
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: isCircular ? size : nil, height: isCircular ? size : nil)
            .frame(minWidth: isCircular ? size : 38, minHeight: isCircular ? size : 38)
            .foregroundColor(isPrimary ? .black : (isActive ? .cyan : .white))
            .background(
                Group {
                    if isCircular {
                        Circle()
                            .fill(isPrimary ? Color.cyan : (isActive ? Color.cyan.opacity(0.22) : Color.white.opacity(0.12)))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isPrimary ? Color.cyan : (isActive ? Color.cyan.opacity(0.22) : Color.white.opacity(0.12)))
                    }
                }
            )
            .overlay(
                Group {
                    if isCircular {
                        Circle()
                            .stroke(isActive ? Color.cyan.opacity(0.6) : Color.white.opacity(0.16), lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isActive ? Color.cyan.opacity(0.6) : Color.white.opacity(0.16), lineWidth: 1)
                    }
                }
            )
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
