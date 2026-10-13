import SwiftUI
import AVFoundation

@main
struct BruTVApp: App {
    init() {
        configureAudioSession()
        #if targetEnvironment(macCatalyst)
        configureCatalystLifecycle()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession setup error: \(error)")
        }
    }

    #if targetEnvironment(macCatalyst)
    private func configureCatalystLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let openWindows = UIApplication.shared.connectedScenes
                    .filter { $0.activationState != .unattached && $0.session.role == .windowApplication }
                if openWindows.isEmpty {
                    exit(0)
                }
            }
        }
    }
    #endif
}
