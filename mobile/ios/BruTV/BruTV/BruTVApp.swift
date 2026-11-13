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
                #if DEBUG && targetEnvironment(macCatalyst)
                .onAppear(perform: configureNativeCaptureWindow)
                #endif
        }
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    @MainActor
    private func configureNativeCaptureWindow() {
        guard ProcessInfo.processInfo.arguments.contains("--native-mac-capture-window") else { return }
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            print("Native capture geometry before request: \(scene.effectiveGeometry.systemFrame), content: \(scene.windows.first?.bounds ?? .zero)")
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 40, y: 40, width: 1280, height: 800))) { error in
                print("Native capture geometry request failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

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
