// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BruTVCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "BruTVCore", targets: ["BruTV"])],
    targets: [
        .target(
            name: "BruTV",
            path: "BruTV",
            exclude: [
                "AppRootView.swift", "BruTVApp.swift", "BruTV.entitlements", "BruTVCatalyst.entitlements",
                "Info.plist", "Resources", "Views",
                "Services/AccountStore.swift", "Services/FavoritesStore.swift",
                "Services/HLSBufferEngine.swift", "Services/PlaybackManager.swift", "Services/LiveTimeshiftServer.swift",
            ],
            sources: [
                "Models/AccountModels.swift", "Models/ChannelModels.swift",
                "Models/EPGModels.swift", "Models/PlayerSettings.swift",
                "Services/LoginLink.swift", "Services/M3UPlaylistParser.swift",
                "Services/XtreamCodesClient.swift",
                "Services/SourceLibraryState.swift", "Services/PlaybackPolicy.swift", "Services/LiveTimeshift.swift",
                "Services/MPEGTSRelay.swift",
            ]
        ),
        .testTarget(
            name: "BruTVCoreTests",
            dependencies: ["BruTV"],
            path: "BruTVTests",
            exclude: [
                "BufferEngineTests.swift", "FavoritesStoreTests.swift", "AccountFlowTests.swift",
            ],
            sources: [
                "SourceLoginTests.swift", "XtreamCodesClientTests.swift",
                "SourceRegressionTests.swift",
                "SourceLibraryStateTests.swift", "PlaybackPolicyTests.swift", "LiveTimeshiftTests.swift",
                "MPEGTSRelayTests.swift",
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
