import SwiftUI
import AVFoundation

@main
struct BruTVApp: App {
    init() {
        configureAudioSession()
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
}
