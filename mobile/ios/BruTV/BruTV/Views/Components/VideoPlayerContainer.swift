import SwiftUI
import AVKit

public struct VideoPlayerContainer: UIViewControllerRepresentable {
    public let player: AVPlayer
    public let aspectRatio: VideoAspectRatio
    public let showsNativeControls: Bool

    public init(player: AVPlayer, aspectRatio: VideoAspectRatio = .fit, showsNativeControls: Bool = false) {
        self.player = player
        self.aspectRatio = aspectRatio
        self.showsNativeControls = showsNativeControls
    }

    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsNativeControls
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = true

        updateVideoGravity(controller: controller)
        return controller
    }

    public func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.showsPlaybackControls = showsNativeControls
        updateVideoGravity(controller: uiViewController)
    }

    private func updateVideoGravity(controller: AVPlayerViewController) {
        switch aspectRatio {
        case .fit, .sixteenByNine, .fourByThree:
            controller.videoGravity = .resizeAspect
        case .fill:
            controller.videoGravity = .resizeAspectFill
        }
    }
}
