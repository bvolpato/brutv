import XCTest

final class BruTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launchLoggedIn(keepPlayerControlsVisible: Bool = true, disableLiveRewind: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-session", "--ui-fixtures", "--demo-login", "--no-splash", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if keepPlayerControlsVisible {
            app.launchArguments.append("--ui-keep-player-controls-visible")
        }
        if disableLiveRewind {
            app.launchArguments.append("--ui-disable-live-rewind")
        }
        app.launch()
        return app
    }

    private func localizedCandidates(_ text: String) -> [String] {
        switch text {
        case "Settings": return ["Settings", "Configurações"]
        case "Live TV": return ["Live TV", "TV ao Vivo"]
        case "Movies": return ["Movies", "Filmes"]
        case "Series": return ["Series", "Séries"]
        case "Favorites": return ["Favorites", "Favoritos"]
        case "Home": return ["BruTV", "Home", "Início"]
        default: return [text]
        }
    }

    @discardableResult
    private func firstChannel(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let card = app.buttons.matching(identifier: "channelCard").firstMatch
        if !card.exists {
            for name in ["Live TV", "TV ao Vivo"] {
                let liveTab = app.tabBars.buttons[name]
                if liveTab.waitForExistence(timeout: 1) {
                    liveTab.tap()
                    break
                }
            }
            if !card.exists {
                navigate(app, to: "Live TV", file: file, line: line)
            }
        }
        if !card.exists {
            let allChannels = app.buttons["ALL CHANNELS"]
            if allChannels.waitForExistence(timeout: 5) {
                allChannels.tap()
            }
        }
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

    private func snapshotDescendants(_ element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        element.children.flatMap { [$0] + snapshotDescendants($0) }
    }

    private func tapSwitchControl(_ app: XCUIApplication, identifier: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        let snapshot = try window.snapshot()
        let elements = snapshotDescendants(snapshot)
        let rows = elements.filter { $0.elementType == .switch && $0.identifier == identifier }
        let row = try XCTUnwrap(rows.count == 1 ? rows.first : nil,
                               "Expected one switch row for \(identifier)", file: file, line: line)
        // SwiftUI exposes the labelled row separately from the native switch. Its reported
        // AX parent can be inconsistent, so use one snapshot and the control's actual frame.
        let controls = elements.filter {
            $0.elementType == .switch && $0.identifier != identifier && row.frame.contains($0.frame)
        }
        let control = try XCTUnwrap(controls.count == 1 ? controls.first : nil,
                                   "Expected one native switch inside \(identifier)", file: file, line: line)
        let frame = control.frame
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, snapshot.frame.contains(frame) else {
            XCTFail("Native switch \(identifier) has invalid or off-window geometry: \(frame)", file: file, line: line)
            return
        }
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - snapshot.frame.minX, dy: frame.midY - snapshot.frame.minY))
            .tap()
    }

    private func assertButtonsFitWindow(_ app: XCUIApplication, identifiers: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try app.windows.firstMatch.snapshot()
        let buttons = snapshotDescendants(snapshot).filter { $0.elementType == .button }
        for identifier in identifiers {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists && button.isHittable, "\(identifier) is not reachable", file: file, line: line)
            let frame = try XCTUnwrap(buttons.first { $0.identifier == identifier }, "\(identifier) is missing from the window snapshot", file: file, line: line).frame
            XCTAssertGreaterThanOrEqual(frame.minX, snapshot.frame.minX, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, snapshot.frame.maxX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, snapshot.frame.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, snapshot.frame.maxY, file: file, line: line)
        }
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

    /// Resolve native tabs and adaptive sidebar items across window sizes.
    private func navigate(_ app: XCUIApplication, to section: String, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = localizedCandidates(section)

        for name in candidates {
            let tab = app.tabBars.buttons[name]
            if tab.waitForExistence(timeout: 1) {
                tab.tap()
                return
            }
        }

        let more = app.tabBars.buttons["More"]
        let morePT = app.tabBars.buttons["Mais"]
        if more.waitForExistence(timeout: 1) || morePT.waitForExistence(timeout: 1) {
            let moreBtn = more.exists ? more : morePT
            moreBtn.tap()
            for name in candidates {
                let row = app.staticTexts[name]
                if row.waitForExistence(timeout: 2) {
                    row.tap()
                    return
                }
                let cell = app.cells.containing(.staticText, identifier: name).firstMatch
                if cell.waitForExistence(timeout: 2) {
                    cell.tap()
                    return
                }
            }
        }

        func sidebarItem() -> XCUIElement? {
            for name in candidates {
                let navBtn = app.buttons["\(name)NavButton"]
                if navBtn.exists { return navBtn }
                let cell = app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
                if cell.exists { return cell }
                let generalBtn = app.buttons[name].firstMatch
                if generalBtn.exists { return generalBtn }
            }
            return nil
        }

        if sidebarItem()?.waitForExistence(timeout: 2) != true {
            for toggleID in ["ToggleSidebar", "Show Sidebar"] {
                let toggle = app.buttons[toggleID].firstMatch
                if toggle.exists {
                    toggle.tap()
                    break
                }
            }
        }
        if let item = sidebarItem() {
            item.tap()
            return
        }
        XCTFail("Cannot find section \(section)", file: file, line: line)
    }

    // MARK: - Login

    private func launchLoggedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-session", "--ui-fixtures", "--ui-keep-player-controls-visible", "--no-splash", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

        let demoButton = app.buttons["Fill Test Credentials"]
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
        relaunched.launchArguments = ["--ui-fixtures", "--no-splash"]
        relaunched.launch()
        firstChannel(relaunched)
        XCTAssertFalse(relaunched.buttons["connectButton"].exists)
    }

    // MARK: - QR code and M3U sign-in

    func testLoginLinkSignsInAutomatically() throws {
        let app = launchLoggedOut()

        // This is the URL a sign-in QR code carries.
        let link = "brutv://login?server=https%3A%2F%2Fui-fixture.example.test&username=fixture-user&password=fixture-password"
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
        field.typeText("https://ui-fixture.example.test/channels.m3u")
        app.buttons["connectButton"].tap()

        navigate(app, to: "Live TV")
        let category = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "categoryItem_General", "General")
        ).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5), "Playlist groups not shown")
        category.tap()
        let card = firstChannel(app)

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
        search.typeText("Fixture One")

        let fixture = app.buttons.matching(identifier: "channelCard")
            .matching(NSPredicate(format: "label CONTAINS[c] 'Fixture One'")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 10), "No matching channel after search")
        XCTAssertFalse(app.buttons.matching(identifier: "channelCard")
            .matching(NSPredicate(format: "label CONTAINS[c] 'Fixture Two'")).firstMatch.exists)
        firstChannel(app)
    }

    func testSectionNavigation() throws {
        let app = launchLoggedIn()
        firstChannel(app)

        for name in ["Home", "Movies", "Series", "Favorites", "Settings", "Live TV"] {
            navigate(app, to: name)
        }
        firstChannel(app)
    }

    func testNavigationAndPlaybackSurviveResizing() throws {
        let app = launchLoggedOut()
        app.open(URL(string: "brutv://login?server=https%3A%2F%2Fui-fixture.example.test&username=fixture-user&password=fixture-password")!)
        firstChannel(app)
        let search = app.textFields["channelSearchField"]
        search.tap()
        search.typeText("Fixture One")
        firstChannel(app).tap()
        revealControls(app)
        app.buttons["playerMinimizeButton"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Opening a channel must dismiss the search keyboard")

        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let mini = app.buttons["miniPlayer"]
            let reachable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"),
                object: mini
            )
            XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, "Mini player is not reachable after rotation")
            navigate(app, to: "Movies")
            XCTAssertTrue(app.textFields["movieSearchField"].waitForExistence(timeout: 5), "Movies did not open after rotation")
            navigate(app, to: "Series")
            XCTAssertTrue(app.textFields["seriesSearchField"].waitForExistence(timeout: 5), "Series did not open after rotation")
            navigate(app, to: "Live TV")
            XCTAssertEqual(search.value as? String, "Fixture One", "Resizing discarded the channel filter")
            XCTAssertEqual(app.buttons.matching(identifier: "channelCard").count, 1)
            XCTAssertTrue(mini.exists && mini.isHittable, "Section navigation interrupted the mini player")
        }

        app.buttons["miniPlayer"].tap()
        revealControls(app)
        XCTAssertTrue(app.buttons["playerPlayPauseButton"].isHittable)
    }

    func testPlayerControlsFitAfterRotation() throws {
        let app = launchLoggedIn()
        openFirstChannel(app)
        app.buttons["playerPlayPauseButton"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            revealControls(app)
            var previousFrame: CGRect?
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    defer { previousFrame = frame }
                    // A Split View window can remain tall when the device is in landscape.
                    return frame.width > 0 && frame.height > 0 && frame == previousFrame
                },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, "Window did not finish rotating")
            try assertButtonsFitWindow(app, identifiers: ["playerBackButton", "playerCloseButton", "playerGuideButton", "playerPrevButton", "playerPlayPauseButton", "playerNextButton", "playerMuteButton", "playerMoreOptionsButton"])
            app.buttons["playerGuideButton"].tap()
            let guideClose = app.buttons["guideCloseButton"]
            XCTAssertTrue(guideClose.waitForExistence(timeout: 5), "Channel guide did not open after rotation")
            try assertButtonsFitWindow(app, identifiers: ["guideCloseButton"])
            guideClose.tap()
            XCTAssertTrue(guideClose.waitForNonExistence(timeout: 5), "Channel guide did not close after rotation")
        }
    }

    func testPlayerControlsAutoHideAndRevealDuringPlayback() throws {
        let app = launchLoggedIn(keepPlayerControlsVisible: false, disableLiveRewind: true)
        firstChannel(app).tap()
        let back = app.buttons["playerBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Player controls did not appear")
        let video = app.otherElements["playerVideo"]
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "playing"),
            object: video
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed, "Local fixture did not start playing with live rewind disabled")
        XCTAssertTrue(back.waitForNonExistence(timeout: 10), "Player controls did not auto-hide")
        XCTAssertTrue((video.value as? String)?.hasPrefix("playing") == true, "Auto-hide interrupted playback")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Tapping the player did not reveal controls")
    }

    func testLogoutReturnsToLoginScreen() throws {
        let app = launchLoggedIn()

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
        let pixelCount = width * height
        var lumas = [Double]()
        lumas.reserveCapacity(pixelCount)
        for pixelIndex in 0..<pixelCount {
            let offset = pixelIndex * 4
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let luma = 0.299 * red + 0.587 * green + 0.114 * blue
            lumas.append(luma)
        }

        let sampleCount = Double(lumas.count)
        var lumaSum = 0.0
        for luma in lumas {
            lumaSum += luma
        }
        let mean = lumaSum / sampleCount
        var squaredDeviationSum = 0.0
        for luma in lumas {
            let difference = luma - mean
            squaredDeviationSum += difference * difference
        }
        let variance = squaredDeviationSum / sampleCount
        let spread = variance.squareRoot()
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
        let environment = ProcessInfo.processInfo.environment
        let keys = ["BRUTV_PLAYBACK_SERVER", "BRUTV_PLAYBACK_USERNAME", "BRUTV_PLAYBACK_PASSWORD", "BRUTV_PLAYBACK_CHANNEL"]
        guard keys.allSatisfy({ !(environment[$0] ?? "").isEmpty }),
              let channel = environment["BRUTV_PLAYBACK_CHANNEL"] else {
            throw XCTSkip("Set BRUTV_PLAYBACK_SERVER, USERNAME, PASSWORD and CHANNEL for provider video validation")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--reset-session", "--demo-login", "--no-splash"]
        app.launchEnvironment = Dictionary(uniqueKeysWithValues: keys.map { ($0, environment[$0]!) })
        app.launch()
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

    func testLiveRewindSettingPersistsAcrossLaunches() throws {
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
        try tapSwitchControl(app, identifier: "liveRewindToggle")
        let changed = initial == "1" ? "0" : "1"
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value == %@", changed), evaluatedWith: toggle)],
                                       timeout: 5) == .completed, "Toggle did not change")

        // Relaunch: the setting is saved. Then restore it.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["--ui-fixtures", "--no-splash"]
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
        try tapSwitchControl(relaunched, identifier: "liveRewindToggle")
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
        _ = app.buttons["playerBackButton"].waitForNonExistence(timeout: 5)
        sleep(1)
        navigate(app, to: "Settings")
        sleep(2)
        shot("05_settings")
    }
}
