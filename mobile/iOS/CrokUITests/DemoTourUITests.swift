import XCTest

/// Drives demo mode (`-CrokDemo YES`) through every main screen and saves a screenshot of each: as test attachments,
/// and as PNG files in `$CROK_SCREENSHOT_DIR` when set (pass `TEST_RUNNER_CROK_SCREENSHOT_DIR=…` to xcodebuild).
final class DemoTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CrokDemo", "YES", "-CrokAppearance", appearance] + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CROK_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The Settings tab: a tab bar on iPhone, the floating top bar on iPad (not an XCUI tab bar).
    private func openSettings(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            tabBar.buttons.element(boundBy: 1).tap()
        } else {
            app.buttons["Settings"].firstMatch.tap()
        }
    }

    func testSignInScreens() {
        let app = launch(["-CrokDemoSignIn", "YES"])
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        snap("01-welcome")
        continueButton.tap()
        let code = element(app, "userCode")
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertEqual(code.label, "B C D F - G H J K", "VoiceOver reads the code letter by letter")
        snap("02-waiting-for-approval")
        element(app, "cancelSignInButton").tap()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
    }

    func testSignInCompletesWhenApproved() {
        let app = launch(["-CrokDemoSignIn", "YES", "-CrokDemoApproveAfter", "1"])
        element(app, "continueButton").tap()
        XCTAssertTrue(element(app, "userCode").waitForExistence(timeout: 10))
        // Polling every 2 s picks up the approval and lands on the session list.
        XCTAssertTrue(app.staticTexts["Fix the flaky upload test"].waitForExistence(timeout: 15))
    }

    func testMainScreens() {
        let app = launch()
        let flaky = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(flaky.waitForExistence(timeout: 10))
        // The connection title settles on "Sessions".
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5))
        snap("03-sessions-light")

        // A running session: plan bar, transcript, Stop.
        flaky.tap()
        let stop = element(app, "stopButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "planBar").exists)
        snap("05-session-running")

        element(app, "planBar").tap()
        XCTAssertTrue(app.staticTexts["Reproduce the flaky upload test"].waitForExistence(timeout: 5))
        snap("06-session-plan-expanded")
        element(app, "planBar").tap()
        XCTAssertTrue(app.staticTexts["Reproduce the flaky upload test"].waitForNonExistence(timeout: 5))

        // The failed prompt offers Retry / Delete.
        let failed = element(app, "failedPromptMenu")
        XCTAssertTrue(failed.waitForExistence(timeout: 5))

        // Stop ends the turn: the Stop button goes away.
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))

        // Send a prompt: clock → ✓ → ✓✓, with the reply streaming in.
        let field = element(app, "composerField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Also run the download test")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts["Also run the download test"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "tick-sending").waitForExistence(timeout: 3) || element(app, "tick-delivered").exists)
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the turn runs: Stop is back")
        snap("07-session-streaming")
        let replyEnd = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ran the test 50 times")).firstMatch
        XCTAssertTrue(replyEnd.waitForExistence(timeout: 20))
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        XCTAssertTrue(replyEnd.isHittable, "the finished reply is on screen, above the keyboard")
        snap("08-session-reply-done")

        // Session info: refreshed from the computer.
        element(app, "sessionInfoButton").tap()
        XCTAssertTrue(app.staticTexts["Session info"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 10))
        snap("09-session-info")
        app.swipeUp()
        snap("10-session-info-more")
        element(app, "infoDone").tap()

        // An offline session is read-only.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let offline = app.staticTexts["Release notes for 1.5"]
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        offline.tap()
        XCTAssertTrue(element(app, "offlineNotice").waitForExistence(timeout: 5))
        snap("11-session-offline")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Settings, Devices, Link a computer.
        openSettings(app)
        XCTAssertTrue(element(app, "accountHeader").waitForExistence(timeout: 5))
        snap("12-settings")
        element(app, "devicesRow").tap()
        XCTAssertTrue(app.staticTexts["MacBook Pro"].waitForExistence(timeout: 5))
        snap("13-devices")
        element(app, "deviceRow-MacBook Pro").tap()
        XCTAssertTrue(element(app, "signOutDevice").waitForExistence(timeout: 5))
        snap("14-device-detail")
        app.buttons["Done"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        element(app, "linkComputerRow").tap()
        let codeField = element(app, "manualCodeField")
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        snap("15-link-computer")
        codeField.tap()
        codeField.typeText("bcdfghjk")
        element(app, "manualCodeContinue").tap()
        let approve = element(app, "approveButton")
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        snap("16-link-review")
        approve.tap()
        XCTAssertTrue(element(app, "linkResult").waitForExistence(timeout: 5))
        snap("17-link-done")
    }

    func testDarkScreens() {
        let app = launch(appearance: "dark")
        let flaky = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(flaky.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 5))
        snap("04-sessions-dark")
        flaky.tap()
        XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10))
        snap("05b-session-running-dark")
        element(app, "sessionInfoButton").tap()
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 10))
        snap("09b-session-info-dark")
        element(app, "infoDone").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSettings(app)
        XCTAssertTrue(element(app, "accountHeader").waitForExistence(timeout: 5))
        snap("12b-settings-dark")
    }

    /// German has the longest strings and Chinese the densest: check nothing is cut off.
    func testLocalizedScreens() {
        for (language, locale) in [("de", "de_DE"), ("zh-Hans", "zh_CN")] {
            let app = launch(["-AppleLanguages", "(\(language))", "-AppleLocale", locale])
            let flaky = app.staticTexts["Fix the flaky upload test"]
            XCTAssertTrue(flaky.waitForExistence(timeout: 10))
            snap("18-\(language)-sessions")
            flaky.tap()
            XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10))
            snap("19-\(language)-session")
            element(app, "sessionInfoButton").tap()
            XCTAssertTrue(element(app, "infoDone").waitForExistence(timeout: 5))
            snap("20-\(language)-info")
            element(app, "infoDone").tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.tabBars.buttons.element(boundBy: 1).tap()
            XCTAssertTrue(element(app, "accountHeader").waitForExistence(timeout: 5))
            snap("21-\(language)-settings")
            app.terminate()
        }
    }

    func testSignInScreensInJapanese() {
        let app = launch(["-CrokDemoSignIn", "YES", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"])
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        snap("22-ja-welcome")
        continueButton.tap()
        XCTAssertTrue(element(app, "userCode").waitForExistence(timeout: 10))
        snap("23-ja-waiting")
    }

    func testArchivedTabAndSearch() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fix the flaky upload test"].waitForExistence(timeout: 10))
        app.buttons["Archived"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Try a different diff renderer"].waitForExistence(timeout: 5))
        app.buttons["All"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("tokenizer")
        XCTAssertTrue(app.staticTexts["Benchmark the tokenizer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fix the flaky upload test"].exists)
    }
}
