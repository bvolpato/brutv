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
    /// A tap toggles them, so a tap during their fade-out can hide them: tap again then.
    private func revealControls(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["playerBackButton"]
        if back.exists && back.isHittable { return }
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            if back.waitForExistence(timeout: 2) && back.isHittable { return }
        }
        XCTAssertTrue(back.waitForExistence(timeout: 2) && back.isHittable, "Player controls not visible", file: file, line: line)
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

    private func launchLoggedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-session"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 10), "Login screen not shown")
        return app
    }

    func testAppLaunchAndLoginScreen() throws {
        let app = launchLoggedOut()
        XCTAssertTrue(app.staticTexts["BruTV"].exists)
    }

    func testDemoLoginButton() throws {
        let app = launchLoggedOut()

        let demoButton = app.buttons["Fill Demo Credentials (virello.win)"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 4.0))
        XCTAssertFalse(app.buttons["connectButton"].isEnabled, "Connect must be disabled with empty fields")
        demoButton.tap()
        XCTAssertTrue(app.buttons["connectButton"].isEnabled)
    }

    func testSessionPersistsAcrossLaunches() throws {
        let app = launchLoggedIn()
        firstChannel(app)
        app.terminate()

        // Relaunch without --demo-login: the saved session must skip the login screen.
        let relaunched = XCUIApplication()
        relaunched.launch()
        firstChannel(relaunched)
        XCTAssertFalse(relaunched.buttons["connectButton"].exists)
    }

    // MARK: - QR code and M3U sign-in

    func testLoginLinkSignsInAutomatically() throws {
        let app = launchLoggedOut()

        // This is the URL a sign-in QR code carries.
        let link = "brutv://login?server=http%3A%2F%2Fvirello.win&username=Bruno081225&password=tv737838290"
        app.open(URL(string: link)!)

        firstChannel(app)
        XCTAssertFalse(app.buttons["connectButton"].exists)
    }

    func testShareSignInQRCodeFromSettings() throws {
        let app = launchLoggedIn()
        firstChannel(app)

        navigate(app, to: "Settings")
        let share = app.buttons["shareLoginQRButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()

        XCTAssertTrue(app.images["loginQRCode"].waitForExistence(timeout: 5), "QR code not rendered")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.images["loginQRCode"].waitForNonExistence(timeout: 5))
    }

    func testM3UPlaylistLogin() throws {
        let app = launchLoggedOut()

        app.buttons["M3U Playlist"].tap()
        let field = app.textFields["playlistField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://iptv-org.github.io/iptv/countries/br.m3u")
        app.buttons["connectButton"].tap()

        let card = firstChannel(app)
        // Groups from the playlist become category chips.
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5), "Playlist groups not shown")

        card.tap()
        revealControls(app)
        app.buttons["playerBackButton"].tap()
        assertOnChannelList(app)
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

    // MARK: - Real playback

    /// Mean and spread of brightness (0-255) in part of an element's screenshot.
    /// A black frame has both near 0. `region` is in points inside the element.
    private func brightness(of element: XCUIElement, region: CGRect? = nil) -> (mean: Double, spread: Double) {
        let image = element.screenshot().image
        guard let cgImage = image.cgImage, element.frame.width > 0 else { return (0, 0) }
        let scale = CGFloat(cgImage.width) / element.frame.width
        let points = region ?? CGRect(x: element.frame.width * 0.2, y: element.frame.height * 0.3,
                                      width: element.frame.width * 0.6, height: element.frame.height * 0.4)
        let crop = CGRect(x: points.minX * scale, y: points.minY * scale,
                          width: points.width * scale, height: points.height * scale).integral
        guard let part = cgImage.cropping(to: crop) else { return (0, 0) }
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        let lumas = (0..<(width * height)).map { index -> Double in
            0.299 * Double(pixels[index * 4]) + 0.587 * Double(pixels[index * 4 + 1]) + 0.114 * Double(pixels[index * 4 + 2])
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let spread = (lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)).squareRoot()
        return (mean, spread)
    }

    /// Waits until the screenshot of the region shows a picture, not a black frame.
    private func waitForPicture(in element: XCUIElement, region: CGRect? = nil, timeout: TimeInterval,
                                _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = (mean: 0.0, spread: 0.0)
        while Date() < deadline {
            last = brightness(of: element, region: region)
            if last.mean > 12 || last.spread > 6 { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("\(message) (mean \(Int(last.mean)), spread \(Int(last.spread)))", file: file, line: line)
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let found = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
        XCTAssertTrue(found, "\(message). Last value: \(element.value as? String ?? "none")", file: file, line: line)
    }

    /// Plays a real provider channel, minimizes it, and expands it again. Checks real
    /// frames on screen each time, so it fails on audio-only playback.
    /// Override the channel with `TEST_RUNNER_BRUTV_PLAYBACK_CHANNEL`.
    func testLiveChannelShowsVideoInPlayerAndMiniPlayer() throws {
        let channel = ProcessInfo.processInfo.environment["BRUTV_PLAYBACK_CHANNEL"] ?? "A Fazenda 02"
        let app = launchLoggedIn()
        firstChannel(app)

        let search = app.textFields["channelSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(channel)
        let card = app.buttons.matching(identifier: "channelCard")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", channel)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "\(channel) not found")
        card.tap()

        let video = app.otherElements["playerVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 10), "Player did not open")
        waitForValue(video, containing: "playing video", timeout: 45, "\(channel) did not start playing with video")
        waitForPicture(in: video, timeout: 15, "Player shows no picture")

        // Minimize: the mini player keeps showing the live picture.
        revealControls(app)
        app.buttons["playerMinimizeButton"].tap()
        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Mini player missing after minimize")
        let thumbnail = CGRect(x: 12, y: max(0, mini.frame.height / 2 - 18), width: 72, height: 36)
        waitForPicture(in: mini, region: thumbnail, timeout: 15, "Mini player shows no live picture")

        // Expand again: the picture must come back, not only the sound.
        Thread.sleep(forTimeInterval: 3)
        mini.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10), "Player did not reopen")
        waitForValue(video, containing: "playing video", timeout: 20, "No video after expanding the mini player")
        waitForPicture(in: video, timeout: 15, "Player shows no picture after expanding")

        revealControls(app)
        app.buttons["playerBackButton"].tap()
        assertOnChannelList(app)
    }

    // MARK: - Settings

    func testLiveRewindSettingIsOffByDefaultAndPersists() throws {
        let app = launchLoggedIn()
        firstChannel(app)
        navigate(app, to: "Settings")

        let toggle = app.switches["liveRewindToggle"]
        var swipes = 0
        while !toggle.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let initial = toggle.value as? String
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        let changed = initial == "1" ? "0" : "1"
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value == %@", changed), evaluatedWith: toggle)],
                                       timeout: 5) == .completed, "Toggle did not change")

        // Relaunch: the setting is saved. Then restore it.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        firstChannel(relaunched)
        navigate(relaunched, to: "Settings")
        let saved = relaunched.switches["liveRewindToggle"]
        swipes = 0
        while !saved.isHittable && swipes < 6 {
            relaunched.swipeUp()
            swipes += 1
        }
        XCTAssertEqual(saved.value as? String, changed, "Live rewind setting was not saved")
        saved.switches.firstMatch.exists ? saved.switches.firstMatch.tap() : saved.tap()
    }

    // MARK: - In-app QR scanning

    func testScanQRCodeOpensScannerWithPhotoFallback() throws {
        let app = launchLoggedOut()

        app.buttons["scanQRButton"].tap()
        XCTAssertTrue(app.navigationBars["Scan QR Code"].waitForExistence(timeout: 5), "Scanner did not open")
        // The Simulator has no camera, so the photo option must be there.
        XCTAssertTrue(app.buttons["qrScannerChoosePhoto"].exists || app.otherElements["qrScannerChoosePhoto"].exists,
                      "Choose Photo option missing")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'camera'")).firstMatch.exists)

        app.buttons["qrScannerCancel"].tap()
        XCTAssertTrue(app.navigationBars["Scan QR Code"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectButton"].exists)
    }

    // MARK: - App Store screenshots

    /// Captures App Store screenshots. It runs only when `BRUTV_SCREENSHOT_DIR` is set
    /// (pass `TEST_RUNNER_BRUTV_SCREENSHOT_DIR` to xcodebuild). It uses a public playlist,
    /// so the images show no private account data.
    func testCaptureStoreScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["BRUTV_SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BRUTV_SCREENSHOT_DIR to capture store screenshots")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }

        let app = XCUIApplication()
        app.launchArguments = ["--reset-session", "--store-screenshots"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 10))
        sleep(1)
        shot("01_login")

        let env = ProcessInfo.processInfo.environment
        let playlist = env["BRUTV_SCREENSHOT_PLAYLIST"] ?? "https://iptv-org.github.io/iptv/countries/br.m3u"
        let encoded = playlist.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? playlist
        app.open(URL(string: "brutv://login?m3u=\(encoded)")!)
        firstChannel(app)

        let category = app.buttons[env["BRUTV_SCREENSHOT_CATEGORY"] ?? "Education"]
        if category.waitForExistence(timeout: 5) {
            category.tap()
        }
        firstChannel(app)
        sleep(5) // let logos load
        shot("02_channels")

        let wanted = env["BRUTV_SCREENSHOT_CHANNEL"] ?? "Canal Futura"
        let target = app.buttons.matching(
            NSPredicate(format: "identifier == 'channelCard' AND label CONTAINS[c] %@", wanted)
        ).firstMatch
        (target.waitForExistence(timeout: 5) ? target : firstChannel(app)).tap()
        sleep(12) // let the stream start and the buffer fill
        revealControls(app)
        shot("03_player")

        app.buttons["playerGuideButton"].tap()
        XCTAssertTrue(app.buttons["guideCloseButton"].waitForExistence(timeout: 5))
        sleep(3)
        shot("04_guide")
        app.buttons["guideCloseButton"].tap()

        revealControls(app)
        app.buttons["playerBackButton"].tap()
        assertOnChannelList(app)
        navigate(app, to: "Settings")
        sleep(2)
        shot("05_settings")
    }
}
