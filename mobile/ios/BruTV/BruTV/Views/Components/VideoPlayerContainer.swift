import SwiftUI
import AVFoundation
import AVKit

/// Shows the shared `AVPlayer` through an `AVPlayerLayer`.
///
/// A plain layer, unlike `AVPlayerViewController`, can be removed and attached again
/// (full player, mini player) without losing the picture. If the layer stays without
/// a frame while the player is playing, it asks the player to redraw the current frame.
public struct VideoPlayerContainer: UIViewRepresentable {
    public let player: AVPlayer
    public let aspectRatio: VideoAspectRatio
    public let showsNativeControls: Bool
    /// When true, this layer is the source for Picture-in-Picture.
    public var allowsPictureInPicture: Bool
    /// Text that UI tests read through the accessibility value, for example "playing".
    public var accessibilityStatus: String?
    public var accessibilityIdentifier: String?

    public init(
        player: AVPlayer,
        aspectRatio: VideoAspectRatio = .fit,
        showsNativeControls: Bool = false,
        allowsPictureInPicture: Bool = false,
        accessibilityIdentifier: String? = nil,
        accessibilityStatus: String? = nil
    ) {
        self.player = player
        self.aspectRatio = aspectRatio
        self.showsNativeControls = showsNativeControls
        self.allowsPictureInPicture = allowsPictureInPicture
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityStatus = accessibilityStatus
    }

    public func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        update(view)
        return view
    }

    public func updateUIView(_ view: PlayerLayerView, context: Context) {
        update(view)
    }

    public static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.player = nil
        DispatchQueue.main.async {
            view.allowsPictureInPicture = false
        }
    }

    private func update(_ view: PlayerLayerView) {
        if view.player !== player {
            view.player = player
        }
        switch aspectRatio {
        case .fit, .sixteenByNine, .fourByThree:
            view.playerLayer.videoGravity = .resizeAspect
        case .fill:
            view.playerLayer.videoGravity = .resizeAspectFill
        }
        view.allowsPictureInPicture = allowsPictureInPicture
        view.testIdentifier = accessibilityIdentifier
        view.status = accessibilityStatus
    }
}

/// Holds the Picture-in-Picture controller of the full player, so the player
/// controls can show a PiP button and start or stop PiP.
@MainActor
public final class PictureInPictureModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    public static let shared = PictureInPictureModel()

    @Published public private(set) var isPossible = false
    @Published public private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard Self.isSupported, controller?.playerLayer !== layer else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        // Going to the Home Screen while a channel plays keeps it playing in PiP.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.isPossible != possible else { return }
                self.isPossible = possible
            }
        }
    }

    func detach(_ layer: AVPlayerLayer) {
        guard let controller, controller.playerLayer === layer else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        possibleObservation = nil
        self.controller = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller == nil else { return }
            if self.isPossible { self.isPossible = false }
            if self.isActive { self.isActive = false }
        }
    }

    public func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

public final class PlayerLayerView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }

    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var readyObservation: NSKeyValueObservation?
    private var redrawWorkItem: DispatchWorkItem?

    var allowsPictureInPicture = false {
        didSet {
            guard allowsPictureInPicture != oldValue else { return }
            updatePictureInPicture()
        }
    }

    var testIdentifier: String? {
        didSet {
            isAccessibilityElement = testIdentifier != nil
            accessibilityIdentifier = testIdentifier
            updateAccessibilityValue()
        }
    }

    var status: String? {
        didSet { updateAccessibilityValue() }
    }

    public var player: AVPlayer? {
        get { playerLayer.player }
        set {
            redrawWorkItem?.cancel()
            readyObservation = nil
            playerLayer.player = newValue
            guard newValue != nil else { return }
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateAccessibilityValue() }
            }
            scheduleRedrawCheck()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.backgroundColor = UIColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { scheduleRedrawCheck() }
        updatePictureInPicture()
    }

    private func updatePictureInPicture() {
        MainActor.assumeIsolated {
            if allowsPictureInPicture && window != nil {
                PictureInPictureModel.shared.attach(playerLayer)
            } else if !allowsPictureInPicture {
                PictureInPictureModel.shared.detach(playerLayer)
            }
        }
    }

    /// When a layer is attached to a player that is already playing, AVFoundation can keep
    /// playing audio without sending frames to the new layer. A seek to the current time
    /// makes it decode and draw again.
    private func scheduleRedrawCheck() {
        redrawWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, let player = self.player,
                  let item = player.currentItem, item.status == .readyToPlay,
                  player.timeControlStatus == .playing,
                  !self.playerLayer.isReadyForDisplay else { return }
            let now = item.currentTime()
            guard now.isValid, now.isNumeric else { return }
            item.seek(to: now, toleranceBefore: .positiveInfinity, toleranceAfter: .zero, completionHandler: nil)
        }
        redrawWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func updateAccessibilityValue() {
        guard testIdentifier != nil else { return }
        let frame = playerLayer.isReadyForDisplay ? "video" : "no-video"
        accessibilityValue = [status, frame].compactMap { $0 }.joined(separator: " ")
    }
}
