// swift-tools-version: 5.9

import Foundation
import PackageDescription

// xtool links an automatic library product into its generated app executable.
// Keep the default package portable so Linux core tests do not import UIKit.
let package: Package
if ProcessInfo.processInfo.environment["BRUTV_XTOOL"] == "1" {
    package = Package(
        name: "BruTV",
        platforms: [.iOS(.v17), .tvOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
        products: [.library(name: "BruTV", targets: ["BruTV"])],
        targets: [
            .target(
                name: "BruTV",
                path: "BruTV",
                exclude: [
                    "BruTV.entitlements", "BruTVCatalyst.entitlements", "BruTV-tvOS.entitlements",
                    "Info.plist", "Info-tvOS.plist", "Resources",
                ]
            )
        ],
        swiftLanguageVersions: [.v5]
    )
} else {
    package = Package(
        name: "BruTVCore",
        platforms: [.macOS(.v13), .iOS(.v17), .tvOS(.v17)],
        products: [.library(name: "BruTVCore", targets: ["BruTV"])],
        targets: [
            .target(
                name: "BruTV",
                path: "BruTV",
                exclude: [
                    "AppRootView.swift", "BruTVApp.swift", "BruTV.entitlements",
                    "BruTVCatalyst.entitlements",
                    "BruTV-tvOS.entitlements", "Info-tvOS.plist",
                    "Info.plist", "Resources", "Views",
                    "Services/AccountStore.swift", "Services/FavoritesStore.swift",
                    "Services/HLSBufferEngine.swift", "Services/PlaybackManager.swift",
                    "Services/LiveTimeshiftServer.swift",
                    "Services/LocalizationManager.swift",
                ],
                sources: [
                    "Models/AccountModels.swift", "Models/ChannelModels.swift",
                    "Models/EPGModels.swift", "Models/PlayerSettings.swift",
                    "Services/LoginLink.swift", "Services/M3UPlaylistParser.swift",
                    "Services/XtreamCodesClient.swift",
                    "Services/SourceLibraryState.swift", "Services/PlaybackPolicy.swift",
                    "Services/LiveTimeshift.swift",
                    "Services/MPEGTSRelay.swift", "Services/TopShelfStore.swift",
                ]
            ),
            .testTarget(
                name: "BruTVCoreTests",
                dependencies: ["BruTV"],
                path: "BruTVTests",
                exclude: [
                    "BufferEngineTests.swift", "FavoritesStoreTests.swift",
                    "AccountFlowTests.swift",
                ],
                sources: [
                    "SourceLoginTests.swift", "XtreamCodesClientTests.swift",
                    "SourceRegressionTests.swift",
                    "SourceLibraryStateTests.swift", "PlaybackPolicyTests.swift",
                    "LiveTimeshiftTests.swift",
                    "MPEGTSRelayTests.swift", "TopShelfStoreTests.swift",
                ]
            ),
        ],
        swiftLanguageVersions: [.v5]
    )
}
