import XCTest

final class BruTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launchLoggedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-login"]
        app.launch()
        return app
    }

    @discardableResult
    private func firstChannel(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let card = app.buttons.matching(identifier: "channelCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Channel list did not load", file: file, line: line)
        return card
    }

    private func openFirstChannel(_ app: XCUIApplication) {
        firstChannel(app).tap()
        revealControls(app)
    }

    /// Controls auto-hide 5s after playback starts. Tap the video to bring them back.
    private func revealControls(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["playerBackButton"]
        if !back.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Player controls not visible", file: file, line: line)
    }

    private func assertOnChannelList(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.buttons["playerBackButton"].waitForNonExistence(timeout: 5),
            "Player is still on screen",
            file: file,
            line: line
        )
        let card = firstChannel(app, file: file, line: line)
        XCTAssertTrue(card.isHittable, "Channel list is not interactive", file: file, line: line)
    }

    /// iPhone uses a tab bar. iPad and Mac use a sidebar, which can be collapsed in portrait.
    private func navigate(_ app: XCUIApplication, to section: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[section]
        if tab.waitForExistence(timeout: 2) {
            tab.tap()
            return
        }

        func sidebarItem() -> XCUIElement {
            let cell = app.collectionViews.cells.containing(.staticText, identifier: section).firstMatch
            if cell.exists { return cell }
            return app.collectionViews.buttons[section].firstMatch
        }

        if !sidebarItem().waitForExistence(timeout: 2) {
            for toggleID in ["ToggleSidebar", "Show Sidebar"] {
                let toggle = app.buttons[toggleID].firstMatch
                if toggle.exists {
                    toggle.tap()
                    break
                }
            }
        }
        let item = sidebarItem()
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Cannot find section \(section)", file: file, line: line)
        item.tap()
    }

    // MARK: - Login

    func testAppLaunchAndLoginScreen() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["BruTV"].exists || app.buttons["Connect Server"].exists)
    }

    func testDemoLoginButton() throws {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["Fill Demo Credentials (example.invalid)"]
        if demoButton.waitForExistence(timeout: 4.0) {
            demoButton.tap()
            XCTAssertTrue(app.buttons["Connect Server"].isEnabled)
        }
    }

    // MARK: - Player exits

    func testChannelsButtonReturnsToChannelList() throws {
        let app = launchLoggedIn()
        openFirstChannel(app)

        app.buttons["playerBackButton"].tap()
        assertOnChannelList(app)
        XCTAssertFalse(app.buttons["miniPlayer"].exists, "Back to Channels must stop playback")
    }

    func testCloseButtonReturnsToChannelList() throws {
        let app = launchLoggedIn()
        openFirstChannel(app)

        app.buttons["playerCloseButton"].tap()
        assertOnChannelList(app)
    }

    func testMinimizeShowsMiniPlayerAndReopens() throws {
        let app = launchLoggedIn()
        openFirstChannel(app)

        app.buttons["playerMinimizeButton"].tap()
        assertOnChannelList(app)

        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Mini player missing after minimize")

        // Reopen full screen from the mini player.
        mini.tap()
        revealControls(app)

        // Minimize again, then stop from the mini player.
        app.buttons["playerMinimizeButton"].tap()
        let miniClose = app.buttons["miniPlayerClose"]
        XCTAssertTrue(miniClose.waitForExistence(timeout: 5))
        miniClose.tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5), "Mini player still visible after stop")
        firstChannel(app)
    }

    // MARK: - Zapping and guide

    func testZappingAndChannelGuide() throws {
        let app = launchLoggedIn()
        openFirstChannel(app)

        app.buttons["playerNextButton"].tap()
        revealControls(app)
        app.buttons["playerPrevButton"].tap()
        revealControls(app)

        app.buttons["playerGuideButton"].tap()
        let guideClose = app.buttons["guideCloseButton"]
        XCTAssertTrue(guideClose.waitForExistence(timeout: 5), "Channel guide did not open")

        // Pick another channel from the guide; the drawer must close.
        let guideCards = app.buttons.matching(identifier: "channelCard")
        XCTAssertTrue(guideCards.firstMatch.waitForExistence(timeout: 5))
        let target = guideCards.count > 1 ? guideCards.element(boundBy: 1) : guideCards.firstMatch
        target.tap()
        XCTAssertTrue(guideClose.waitForNonExistence(timeout: 5), "Guide did not close after selection")

        revealControls(app)
        app.buttons["playerBackButton"].tap()
        assertOnChannelList(app)
    }

    // MARK: - Browsing

    func testSearchFiltersChannels() throws {
        let app = launchLoggedIn()
        firstChannel(app)

        let search = app.textFields["channelSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Globo")

        let globo = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Globo'")).firstMatch
        XCTAssertTrue(globo.waitForExistence(timeout: 10), "No Globo channel after search")
        firstChannel(app)
    }

    func testSectionNavigation() throws {
        let app = launchLoggedIn()
        firstChannel(app)

        for name in ["Movies", "Series", "Favorites", "Settings", "Live TV"] {
            navigate(app, to: name)
        }
        firstChannel(app)
    }

    func testLogoutReturnsToLoginScreen() throws {
        let app = launchLoggedIn()
        firstChannel(app)

        navigate(app, to: "Settings")

        let logout = app.buttons["Log Out & Switch Server"]
        var swipes = 0
        while !logout.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(logout.isHittable, "Logout button not reachable")
        logout.tap()

        let confirm = app.alerts.buttons["Log Out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["Connect Server"].waitForExistence(timeout: 10), "Login screen not shown after logout")
    }
}
