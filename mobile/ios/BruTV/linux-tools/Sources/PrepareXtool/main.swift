import AssetKit
import Foundation

struct PreparationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func writePlist(_ value: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
}

func loadPlist(_ url: URL) throws -> [String: Any] {
    guard
        let result = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: Any]
    else {
        throw PreparationError("Expected a plist dictionary: \(url.path)")
    }
    return result
}

func expand(_ value: Any, settings: [String: String]) throws -> Any {
    if let string = value as? String {
        var result = string
        for (key, value) in settings {
            result = result.replacingOccurrences(of: "$(\(key))", with: value)
        }
        guard !result.contains("$(") else {
            throw PreparationError("Unresolved Xcode build setting: \(result)")
        }
        return result
    }
    if let values = value as? [Any] {
        return try values.map { try expand($0, settings: settings) }
    }
    if let values = value as? [String: Any] {
        return try values.mapValues { try expand($0, settings: settings) }
    }
    return value
}

func releaseSettings(project: URL) throws -> [String: String] {
    let source = try String(contentsOf: project, encoding: .utf8)
    let pattern =
        #"buildSettings = \{([^}]*INFOPLIST_FILE = BruTV/Info\.plist;[^}]*)\};\s*name = Release;"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard
        let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
        let range = Range(match.range(at: 1), in: source)
    else {
        throw PreparationError(
            "Cannot locate BruTV's iOS Release build settings in \(project.path)")
    }
    var settings: [String: String] = [:]
    for entry in source[range].split(separator: ";") {
        let pair = entry.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                in: CharacterSet(charactersIn: "\""))
        }
        if pair.count == 2 { settings[pair[0]] = pair[1] }
    }
    return settings
}

func validateSourceParity(project: URL, sources: URL) throws {
    let source = try String(contentsOf: project, encoding: .utf8)
    let phase = try NSRegularExpression(
        pattern: #"(?m)^\s*APPSOURCES /\* Sources \*/ = \{([^}]+)\};"#)
    guard
        let match = phase.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
        let range = Range(match.range(at: 1), in: source)
    else {
        throw PreparationError("Cannot locate BruTV's app source build phase")
    }
    let names = try NSRegularExpression(pattern: #"/\* ([^/]+\.swift) in Sources \*/"#)
    let phaseText = String(source[range])
    let expected = Set(
        names.matches(in: phaseText, range: NSRange(phaseText.startIndex..., in: phaseText))
            .compactMap {
                Range($0.range(at: 1), in: phaseText).map { String(phaseText[$0]) }
            })
    guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    else {
        throw PreparationError("Cannot enumerate BruTV's staged app sources")
    }
    let actual = Set(
        files.compactMap {
            ($0 as? URL).flatMap { $0.pathExtension == "swift" ? $0.lastPathComponent : nil }
        })
    guard actual == expected else {
        throw PreparationError(
            "SwiftPM/Xcode source mismatch. Missing: \(expected.subtracting(actual).sorted()); extra: \(actual.subtracting(expected).sorted())"
        )
    }
}

func validateIcon(_ url: URL, pointSize: String, scale: String) throws {
    let data = try Data(contentsOf: url)
    guard data.count >= 33, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
        throw PreparationError("App icon is not a PNG: \(url.path)")
    }
    func uint32(at index: Int) -> Int {
        data[index..<(index + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    let dimensions = pointSize.split(separator: "x").compactMap { Double($0) }
    guard dimensions.count == 2, let multiplier = Double(scale.dropLast()),
        Double(uint32(at: 16)) == dimensions[0] * multiplier,
        Double(uint32(at: 20)) == dimensions[1] * multiplier
    else {
        throw PreparationError(
            "App icon pixel dimensions do not match \(pointSize) at \(scale): \(url.path)")
    }
    guard [0, 2].contains(data[25]) else {
        throw PreparationError(
            "App icons must have no alpha channel or palette transparency: \(url.path)")
    }
    var position = 8
    while position + 12 <= data.count {
        let length = uint32(at: position)
        let type = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
        guard length <= data.count - position - 12 else {
            throw PreparationError("Invalid PNG chunk in app icon: \(url.path)")
        }
        guard type != "tRNS" else {
            throw PreparationError("App icons must have no transparency: \(url.path)")
        }
        position += length + 12
    }
}

@main
struct PrepareXtool {
    static func main() async {
        do {
            try await prepare()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func prepare() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw PreparationError(
                "Usage: prepare-xtool <BruTV project directory> <output directory> ios|macos")
        }
        let platform = CommandLine.arguments[3]
        guard ["ios", "macos"].contains(platform) else {
            throw PreparationError("No verified asset compiler is available for \(platform)")
        }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            .standardizedFileURL
        guard output.path != source.path, !source.path.hasPrefix(output.path + "/") else {
            throw PreparationError("The output directory must not contain the source project")
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        // Replace only staged inputs. xtool and Swift retain their own build caches.
        for name in ["Package.swift", "BruTV", "Assets.xcassets"] {
            let destination = output.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        }
        try fm.copyItem(
            at: source.appendingPathComponent("Package.swift"),
            to: output.appendingPathComponent("Package.swift"))
        try fm.copyItem(
            at: source.appendingPathComponent("BruTV"), to: output.appendingPathComponent("BruTV"))
        try validateSourceParity(
            project: source.appendingPathComponent("BruTV.xcodeproj/project.pbxproj"),
            sources: output.appendingPathComponent("BruTV"))

        let originalAssets = source.appendingPathComponent("BruTV/Resources/Assets.xcassets")
        let catalog = output.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
        for asset in try fm.contentsOfDirectory(at: originalAssets, includingPropertiesForKeys: nil)
        where asset.lastPathComponent != "TVAppIcon.brandassets" {
            try fm.copyItem(at: asset, to: catalog.appendingPathComponent(asset.lastPathComponent))
        }
        let contentsURL = catalog.appendingPathComponent("AppIcon.appiconset/Contents.json")
        guard
            var iconContents = try JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL))
                as? [String: Any],
            var images = iconContents["images"] as? [[String: Any]]
        else {
            throw PreparationError("AppIcon Contents.json must contain an images array")
        }
        // Xcode's single-size universal entry implies scale 1x; AssetKit requires it explicitly.
        for index in images.indices where images[index]["scale"] == nil {
            guard images[index]["idiom"] as? String == "universal",
                images[index]["size"] as? String == "1024x1024"
            else {
                throw PreparationError("AppIcon entry has no explicit scale: \(images[index])")
            }
            images[index]["scale"] = "1x"
        }
        for image in images {
            guard let filename = image["filename"] as? String,
                let size = image["size"] as? String,
                let scale = image["scale"] as? String
            else {
                throw PreparationError("AppIcon entry has no filename, size, or scale: \(image)")
            }
            try validateIcon(
                catalog.appendingPathComponent("AppIcon.appiconset/\(filename)"), pointSize: size,
                scale: scale)
        }
        iconContents["images"] = images
        try JSONSerialization.data(
            withJSONObject: iconContents, options: [.prettyPrinted, .sortedKeys]
        ).write(to: contentsURL)

        let defaults = try releaseSettings(
            project: source.appendingPathComponent("BruTV.xcodeproj/project.pbxproj"))
        let environment = ProcessInfo.processInfo.environment
        guard let defaultBuild = defaults["CURRENT_PROJECT_VERSION"],
            let defaultVersion = defaults["MARKETING_VERSION"],
            let defaultBundleID = defaults["PRODUCT_BUNDLE_IDENTIFIER"],
            let minimumOS = defaults["IPHONEOS_DEPLOYMENT_TARGET"]
        else {
            throw PreparationError(
                "BruTV's Release build settings are missing version, bundle ID, or minimum OS")
        }
        guard minimumOS == "17.0" else {
            throw PreparationError(
                "Update Package.swift's xtool deployment target for iOS \(minimumOS) before building"
            )
        }
        let bundleID = environment["IOS_BUNDLE_ID"] ?? defaultBundleID
        let settings = [
            "DEVELOPMENT_LANGUAGE": "en", "EXECUTABLE_NAME": "BruTV", "PRODUCT_NAME": "BruTV",
            "PRODUCT_BUNDLE_IDENTIFIER": bundleID,
            "CURRENT_PROJECT_VERSION": environment["IOS_BUILD_NUMBER"] ?? defaultBuild,
            "MARKETING_VERSION": environment["IOS_MARKETING_VERSION"] ?? defaultVersion,
        ]
        guard
            var info = try expand(
                loadPlist(source.appendingPathComponent("BruTV/Info.plist")), settings: settings)
                as? [String: Any]
        else {
            throw PreparationError("BruTV Info.plist must contain a dictionary")
        }
        info["MinimumOSVersion"] = minimumOS
        info["UIDeviceFamily"] = [1, 2]

        let compiled = try await XCAssetCompiler(deploymentTarget: minimumOS).compile(
            catalog: catalog)
        guard let icons = compiled.appIconBundle, icons.primaryIconName == "AppIcon" else {
            throw PreparationError("AssetKit did not compile the AppIcon catalog")
        }
        try compiled.carData.write(
            to: output.appendingPathComponent("Assets.car"), options: .atomic)
        for (key, value) in icons.infoPlistAdditions { info[key] = value }
        for file in icons.looseFiles {
            try file.data.write(to: output.appendingPathComponent(file.name), options: .atomic)
        }
        if platform == "macos" {
            for key in ["MinimumOSVersion", "UIDeviceFamily", "LSRequiresIPhoneOS"] {
                info.removeValue(forKey: key)
            }
            info["LSMinimumSystemVersion"] = "14.0"
            info["CFBundleSupportedPlatforms"] = ["MacOSX"]
            info["CFBundleIconFile"] = "AppIcon"
            let png = try Data(
                contentsOf: catalog.appendingPathComponent("AppIcon.appiconset/AppIcon1024.png"))
            func bigEndian(_ value: Int) -> Data {
                Data([
                    UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                    UInt8((value >> 8) & 255),
                    UInt8(value & 255),
                ])
            }
            // ICNS type ic10 contains a 1024px PNG. AppKit scales this source for smaller representations.
            let icns =
                Data("icns".utf8) + bigEndian(png.count + 16) + Data("ic10".utf8)
                + bigEndian(png.count + 8)
                + png
            try icns.write(to: output.appendingPathComponent("AppIcon.icns"), options: .atomic)
        }
        try writePlist(info, to: output.appendingPathComponent("Info.plist"))

        let privacyName = "PrivacyInfo.xcprivacy"
        let privacy = output.appendingPathComponent(privacyName)
        try Data(contentsOf: source.appendingPathComponent("BruTV/Resources/\(privacyName)")).write(
            to: privacy, options: .atomic)
        let resources =
            ["Assets.car", privacyName] + (platform == "macos" ? ["AppIcon.icns"] : [])
            + Set(icons.looseFiles.map(\.name)).sorted()
        // JSON scalars are YAML scalars too, including paths with spaces or punctuation.
        func yamlString(_ string: String) throws -> String {
            String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
        }
        let config = try """
        version: 1
        bundleID: \(yamlString(bundleID))
        product: BruTV
        infoPath: Info.plist
        skipLSP: true
        resources:
        \(resources.map { "  - \(try yamlString($0))" }.joined(separator: "\n"))

        """
        try config.write(
            to: output.appendingPathComponent("xtool.yml"), atomically: true, encoding: .utf8)
        print(
            "Prepared \(platform) \(settings["MARKETING_VERSION"]!) (\(settings["CURRENT_PROJECT_VERSION"]!)): \(output.path)"
        )
    }
}
