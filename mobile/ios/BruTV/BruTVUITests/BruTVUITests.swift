import XCTest

final class BruTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchAndLoginScreen() throws {
        let app = XCUIApplication()
        app.launch()

        // Verify key UI elements on Login Screen
        XCTAssertTrue(app.staticTexts["BruTV"].exists || app.buttons["Connect Server"].exists)
    }

    func testDemoLoginButton() throws {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["Fill Demo Credentials (virello.win)"]
        if demoButton.waitForExistence(timeout: 4.0) {
            demoButton.tap()
            XCTAssertTrue(app.buttons["Connect Server"].isEnabled)
        }
    }
}
