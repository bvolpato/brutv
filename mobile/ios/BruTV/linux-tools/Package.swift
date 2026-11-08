// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BruTVLinuxTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "prepare-xtool", targets: ["PrepareXtool"])],
    dependencies: [
        .package(
            url: "https://github.com/bvolpato/AssetKit",
            revision: "cc948c71491a78183a08759dc07d4faef07ecad4"
        )
    ],
    targets: [
        .executableTarget(name: "PrepareXtool", dependencies: ["AssetKit"])
    ]
)
