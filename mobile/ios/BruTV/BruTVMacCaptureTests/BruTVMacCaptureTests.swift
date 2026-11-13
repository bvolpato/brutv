import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class BruTVMacCaptureTests: XCTestCase {
    func testCaptureNativeMacScreenshots() throws {
        continueAfterFailure = false
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["BRUTV_MAC_SCREENSHOT_DIR"])
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, section) in [("01_login", ""), ("02_channels", "Live TV"), ("03_settings", "Settings")] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-session", "--ui-fixtures", "--no-splash", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if !section.isEmpty {
                app.launchArguments += ["--demo-login", "--section", section]
            }
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
            if section == "Live TV" {
                XCTAssertTrue(app.buttons.matching(identifier: "channelCard").firstMatch.waitForExistence(timeout: 30))
            } else if section == "Settings" {
                XCTAssertTrue(app.buttons["logoutButton"].waitForExistence(timeout: 20))
            } else {
                XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
            }
            for _ in 0..<3 where abs(window.frame.width - 1280) > 1 || abs(window.frame.height - 800) > 1 {
                let frame = window.frame
                let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                origin.withOffset(CGVector(dx: frame.width - 2, dy: frame.height - 2))
                    .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 1278, dy: 798)))
            }
            let screenshot = window.screenshot()
            let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertTrue([(1280, 800), (2560, 1600)].contains { $0.0 == image.width && $0.1 == image.height }, "Native window capture must have an accepted 16:10 size, got \(image.width)x\(image.height)")
            let url = directory.appendingPathComponent("\(name).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
