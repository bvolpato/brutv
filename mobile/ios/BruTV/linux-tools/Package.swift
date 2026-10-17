// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BruTVLinuxTools",
    products: [.executable(name: "prepare-xtool", targets: ["PrepareXtool"])],
    dependencies: [
        .package(
            url: "https://github.com/xtool-org/AssetKit",
            revision: "e763558b55fcbb5a443b1d7b2c6f0972d8bd14f7"
        )
    ],
    targets: [
        .executableTarget(name: "PrepareXtool", dependencies: ["AssetKit"])
    ]
)
