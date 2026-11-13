import CoreGraphics
import ImageIO
import XCTest

final class BruTVMacCaptureTests: XCTestCase {
    func testCaptureNativeMacScreenshots() throws {
        continueAfterFailure = false
        for (name, section) in [("01_login", ""), ("02_channels", "Live TV"), ("03_settings", "Settings")] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-session", "--no-splash", "--native-mac-capture-window", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if !section.isEmpty {
                app.launchArguments += ["--ui-fixtures", "--demo-login", "--section", section]
            }
            app.launch()
            defer { app.terminate() }
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
            if section == "Live TV" {
                XCTAssertTrue(app.buttons.matching(identifier: "channelCard").firstMatch.waitForExistence(timeout: 30))
            } else if section == "Settings" {
                XCTAssertTrue(app.buttons["shareLoginQRButton"].waitForExistence(timeout: 20))
            } else {
                XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
            }
            let geometry = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    abs(window.frame.width - 1280) < 1 && abs(window.frame.height - 800) < 1
                }, object: window
            )
            XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 10), .completed)
            let screenshot = window.screenshot()
            let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertTrue([(1280, 800), (2560, 1600)].contains { $0.0 == image.width && $0.1 == image.height }, "Native window capture must have an accepted 16:10 size, got \(image.width)x\(image.height)")
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
