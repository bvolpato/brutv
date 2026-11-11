import SwiftUI

@main
struct BruTVApp: App {
    init() {
        #if targetEnvironment(macCatalyst)
        configureCatalystLifecycle()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
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
