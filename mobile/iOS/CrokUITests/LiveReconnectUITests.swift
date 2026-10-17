import XCTest

/// relay/DESIGN.md §5 "Staying connected", against a real relay behind a proxy that can freeze. Skipped unless
/// `CROK_LIVE_RECONNECT=1` (pass `TEST_RUNNER_CROK_LIVE_RECONNECT=1` to xcodebuild).
///
/// Setup: a local relay with `node scripts/fake-computer.mjs` running (its session "Fix the login redirect" answers
/// prompts), and a freezable proxy in front of it, which the app signs in to (`CROK_LIVE_RELAY_URL`, default
/// `http://127.0.0.1:3290`). While the file `$CROK_LIVE_DIR/freeze` exists, the proxy keeps every open connection
/// silent for good (no data, no reset: a socket that died while the phone was suspended) and accepts new ones without
/// ever answering (a reconnect stuck in connect). The test creates and removes that file itself. It writes the phone's
/// sign-in code to `$CROK_LIVE_DIR/live-user-code.txt` and waits for someone to approve it.
///
/// Before the fix, the app never came back from the first scenario: ConvexMobile's reconnect hung on the frozen
/// connection forever, and every query and call waited behind it until the app was killed.
final class LiveReconnectUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var dir: URL { URL(fileURLWithPath: env["CROK_LIVE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp/crok-live") }
    private var freezeFile: URL { dir.appendingPathComponent("freeze") }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func freeze(_ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: freezeFile.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: freezeFile)
        }
        print("CROK_LIVE_FREEZE=\(on) at \(Date())")
    }

    /// Sends a prompt and waits for the fake computer's reply, which quotes it: proof the connection is live.
    private func roundTrip(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        let field = element(app, "composerField")
        guard field.waitForExistence(timeout: 5) else { return false }
        field.tap()
        field.typeText(text)
        element(app, "sendButton").tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You asked: “\(text)”")).firstMatch
        return reply.waitForExistence(timeout: timeout)
    }

    func testRecoversFromAFrozenSocketAndAfterTheBackground() throws {
        try XCTSkipUnless(env["CROK_LIVE_RECONNECT"] == "1", "set CROK_LIVE_RECONNECT=1")
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        freeze(false)
        let server = env["CROK_LIVE_RELAY_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:3290"
        let app = XCUIApplication()
        app.launchArguments = ["-CrokResetState", "YES", "-CrokNoBrowser", "YES", "-CrokAppearance", "light", "-CrokServer", server]
        app.launch()

        // Sign in; approved from outside.
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
        continueButton.tap()
        let code = element(app, "userCode")
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        let userCode = code.label.replacingOccurrences(of: " ", with: "")
        try userCode.write(to: dir.appendingPathComponent("live-user-code.txt"), atomically: true, encoding: .utf8)
        print("CROK_LIVE_USER_CODE=\(userCode)")
        let session = app.staticTexts["Fix the login redirect"]
        XCTAssertTrue(session.waitForExistence(timeout: 180), "approve \(userCode)")
        session.tap()
        XCTAssertTrue(roundTrip(app, "Before the freeze", timeout: 30))
        XCTAssertTrue(wait(10) { !self.element(app, "connectionTitle").exists }, "the header settles")
        snap("live-reconnect-1-synced")

        // 1. The socket dies without a word, and the reconnect hangs in connect.
        freeze(true)
        let noticed = Date()
        XCTAssertTrue(element(app, "connectionTitle").waitForExistence(timeout: 75), "the header says the link is down")
        print("CROK_LIVE_NOTICED_AFTER=\(Int(Date().timeIntervalSince(noticed)))s")
        snap("live-reconnect-2-frozen")
        Thread.sleep(forTimeInterval: 25)
        freeze(false)
        let unfrozen = Date()
        XCTAssertTrue(wait(90) { !self.element(app, "connectionTitle").exists }, "back by itself, no relaunch")
        print("CROK_LIVE_RECOVERED_AFTER_UNFREEZE=\(Int(Date().timeIntervalSince(unfrozen)))s")
        XCTAssertTrue(roundTrip(app, "After the freeze", timeout: 30), "prompts and replies flow again")
        snap("live-reconnect-3-recovered")

        // 2. Suspended in the background while the socket died; back in the foreground.
        freeze(true)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 10)
        freeze(false)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        let foreground = Date()
        XCTAssertTrue(roundTrip(app, "Back from the background", timeout: 45), "live again soon after returning")
        print("CROK_LIVE_ROUND_TRIP_AFTER_FOREGROUND=\(Int(Date().timeIntervalSince(foreground)))s")
        XCTAssertTrue(wait(10) { !self.element(app, "connectionTitle").exists })
        snap("live-reconnect-4-foreground")
    }
}
