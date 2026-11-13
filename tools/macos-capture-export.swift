import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TestAttachments: Decodable {
    let attachments: [Attachment]
}

struct Attachment: Decodable {
    let exportedFileName: String
    let suggestedHumanReadableName: String
}

func captureError(_ message: String) -> NSError {
    NSError(domain: "MacCaptureExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

guard CommandLine.arguments.count == 3 else {
    throw captureError("Usage: macos-capture-export.swift ATTACHMENTS_DIRECTORY OUTPUT_DIRECTORY")
}
let attachments = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let manifest = try JSONDecoder().decode(
    [TestAttachments].self,
    from: Data(contentsOf: attachments.appendingPathComponent("manifest.json"))
)
let files = manifest.flatMap(\.attachments)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for name in ["01_login", "02_channels", "03_settings"] {
    let matches = files.filter {
        $0.suggestedHumanReadableName == name
            || $0.suggestedHumanReadableName.hasPrefix(name + "_")
            || $0.suggestedHumanReadableName == name + ".png"
    }
    guard matches.count == 1, let attachment = matches.first else {
        throw captureError("Expected one native screenshot attachment for \(name), found \(matches.count)")
    }
    guard attachment.exportedFileName == (attachment.exportedFileName as NSString).lastPathComponent else {
        throw captureError("Screenshot attachment has an invalid file name")
    }
    let sourceURL = attachments.appendingPathComponent(attachment.exportedFileName)
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw captureError("Cannot decode native screenshot \(name)")
    }
    guard [(1280, 800), (2560, 1600)].contains(where: { $0.0 == image.width && $0.1 == image.height }) else {
        throw captureError("Native screenshot \(name) has invalid dimensions: \(image.width)x\(image.height)")
    }
    let destinationURL = output.appendingPathComponent(name + ".jpg")
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        throw captureError("Cannot create JPEG for \(name)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw captureError("Cannot finish JPEG for \(name)")
    }
    print("Exported native screenshot \(name): \(image.width)x\(image.height)")
}
