import XCTest

/// End to end against a real relay (the Debug build's `CrokRelayURL`, by default a local `npx convex dev`). Skipped
/// unless `CROK_LIVE_RELAY=1` (pass `TEST_RUNNER_CROK_LIVE_RELAY=1` to xcodebuild). Someone has to approve the sign-in:
/// the test writes the user code to `$CROK_SCREENSHOT_DIR/live-user-code.txt` and waits up to three minutes. A computer
/// must mirror a session titled "Fix the login redirect" and answer prompts (see README.md, "Checking against a real
/// relay").
final class LiveRelayUITests: XCTestCase {
    private var outputDir: URL? {
        ProcessInfo.processInfo.environment["CROK_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Waits until `condition` holds, sampling every 100 ms; returns whether it did.
    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// The browser sheet on its own: the consent alert, the sheet, closing it, and the app still waiting.
    func testBrowserSheetCanBeClosed() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CROK_LIVE_RELAY"] == "1", "set CROK_LIVE_RELAY=1")
        let app = XCUIApplication()
        app.launchArguments = ["-CrokResetState", "YES", "-CrokAppearance", "light"]
        app.launch()
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertShown = springboard.alerts.firstMatch.waitForExistence(timeout: 10)
        print("CROK_LIVE_CONSENT_ALERT=\(alertShown)")
        snap("live-sheet-1-consent")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.69, dy: 0.584)).tap()
        for second in 1...4 {
            Thread.sleep(forTimeInterval: 1)
            snap("live-sheet-2-after-\(second)s")
        }
        // The sheet's close (X) button, top left; the system then reports a cancelled sign-in and polling goes on.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.1255)).tap()
        Thread.sleep(forTimeInterval: 2)
        snap("live-sheet-3-closed")
        XCTAssertTrue(element(app, "userCode").exists, "still waiting for approval after the sheet closed")
        element(app, "cancelSignInButton").tap()
    }

    /// With the app already signed in (run `testSignInAndControlASession` first): the info sheet on its own.
    func testInfoSheetWhileSignedIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CROK_LIVE_RELAY"] == "1", "set CROK_LIVE_RELAY=1")
        let app = XCUIApplication()
        app.launchArguments = ["-CrokAppearance", "light"]
        app.launch()
        let session = app.staticTexts["Fix the login redirect"]
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()
        XCTAssertTrue(element(app, "sessionInfoButton").waitForExistence(timeout: 10))
        element(app, "sessionInfoButton").tap()
        Thread.sleep(forTimeInterval: 1)
        snap("live-info-debug-1s")
        Thread.sleep(forTimeInterval: 5)
        snap("live-info-debug-6s")
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 15))
    }

    func testSignInAndControlASession() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CROK_LIVE_RELAY"] == "1", "set CROK_LIVE_RELAY=1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CrokResetState", "YES", "-CrokAppearance", "light"]
        app.launch()

        // Welcome → start the device sign-in.
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        snap("live-01-welcome")
        continueButton.tap()

        // ASWebAuthenticationSession first asks to use the relay's web host. The alert belongs to another process
        // on iOS 26, so it is tapped by position: "Continue" is the right-hand button in the middle of the screen.
        Thread.sleep(forTimeInterval: 3)
        snap("live-02-browser-consent")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.69, dy: 0.584)).tap()
        // The browser sheet: no web app runs locally, so the page cannot load. Close it; polling goes on.
        Thread.sleep(forTimeInterval: 4)
        snap("live-03-browser-sheet")
        // The sheet's close (X) button, top left; the system then reports a cancelled sign-in and polling goes on.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.1255)).tap()
        Thread.sleep(forTimeInterval: 2)
        snap("live-03b-browser-closed")
        let code = element(app, "userCode")
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        snap("live-04-waiting-for-approval")
        let userCode = code.label.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(userCode.range(of: #"^[A-Z]{4}-[A-Z]{4}$"#, options: .regularExpression) != nil, userCode)
        if let dir = outputDir {
            try userCode.write(to: dir.appendingPathComponent("live-user-code.txt"), atomically: true, encoding: .utf8)
        }
        print("CROK_LIVE_USER_CODE=\(userCode)")

        // Approved from outside (npx convex run deviceAuth:approve): the app polls and lands on Sessions.
        let session = app.staticTexts["Fix the login redirect"]
        XCTAssertTrue(session.waitForExistence(timeout: 180), "approve \(userCode) and run the fake computer")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10), "the title settles on Sessions")
        snap("live-05-sessions")

        // Open it: the transcript the computer pushed.
        session.tap()
        let field = element(app, "composerField")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "planBar").waitForExistence(timeout: 10))
        snap("live-06-session")

        // A prompt: clock → ✓ → ✓✓, with the reply streaming in.
        field.tap()
        field.typeText("Run the auth tests")
        element(app, "sendButton").tap()
        var seen = Set<String>()
        let finished = wait(30) {
            for tick in ["sending", "delivered", "done"] where element(app, "tick-\(tick)").exists { seen.insert(tick) }
            return seen.contains("done")
        }
        print("CROK_LIVE_TICKS=\(seen.sorted())")
        XCTAssertTrue(finished, "ticks seen: \(seen)")
        XCTAssertTrue(seen.contains("delivered") || seen.contains("sending"), "an earlier tick was visible: \(seen)")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Done for now")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        snap("live-07-reply")

        // A slow reply, stopped from the phone.
        field.tap()
        field.typeText("Write a slow, long summary")
        element(app, "sendButton").tap()
        let stop = element(app, "stopButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let streaming = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Write a slow, long summary")).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        snap("live-08-streaming-with-stop")
        stop.tap()
        XCTAssertTrue(element(app, "notice-Stopped").waitForExistence(timeout: 15))
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        snap("live-09-stopped")

        // Session info, refreshed from the computer.
        element(app, "sessionInfoButton").tap()
        XCTAssertTrue(element(app, "infoDone").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["grok-code-fast-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 15))
        snap("live-10-info")
        app.swipeUp()
        snap("live-11-info-usage")
        element(app, "infoDone").tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Devices: this phone and the computer.
        app.tabBars.buttons.element(boundBy: 1).tap()
        element(app, "devicesRow").tap()
        XCTAssertTrue(app.staticTexts["Test MacBook"].waitForExistence(timeout: 10))
        snap("live-12-devices")
    }
}
