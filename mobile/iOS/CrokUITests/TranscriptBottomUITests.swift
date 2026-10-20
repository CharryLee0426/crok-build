import XCTest

/// The transcript's bottom when the last reply is taller than the screen (the showcase reply in demo mode): the session
/// opens on the reply's end, a short drag up inside that reply brings the scroll-to-bottom button, and the button
/// brings the end back. Screenshots as in `DemoTourUITests` (`TEST_RUNNER_CROK_SCREENSHOT_DIR`).
@MainActor
final class TranscriptBottomUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CrokDemo", "YES", "-CrokAppearance", "light"] + extra
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

    private func openShowcase(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        app.buttons["Studio"].firstMatch.tap()
        let row = app.staticTexts["Refactor the pager's scroll model"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element(app, "offlineNotice").waitForExistence(timeout: 5))
    }

    /// The reply's last line.
    private func lastLine(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Heading 6")).firstMatch
    }

    /// The top of what sits over the transcript's bottom: the offline notice, or the composer's field.
    private func bottomBarTop(_ app: XCUIApplication) -> CGFloat {
        let notice = element(app, "offlineNotice")
        return notice.exists ? notice.frame.minY : element(app, "composerField").frame.minY
    }

    /// The reply's last line is on screen, just above the bar (no blank stretch under it, nothing of it hidden).
    private func assertAtEnd(_ app: XCUIApplication, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let last = lastLine(app)
        XCTAssertTrue(last.waitForExistence(timeout: 3), "\(context): the last line exists", file: file, line: line)
        let gap = bottomBarTop(app) - last.frame.maxY
        XCTAssertTrue(last.isHittable, "\(context): the last line is on screen (gap \(gap))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(gap, -1, "\(context): the last line is not under the bar", file: file, line: line)
        XCTAssertLessThan(gap, 60, "\(context): no blank stretch under the last line", file: file, line: line)
    }

    /// A slow drag (no fling) of `fraction` of the window's height; `down` moves the finger down (toward older items).
    private func drag(_ app: XCUIApplication, down: Bool, fraction: CGFloat) {
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4 + fraction))
        let (from, to) = down ? (top, bottom) : (bottom, top)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    func testOpensOnTheEndOfALongLastReply() {
        let app = launch()
        openShowcase(app)
        // Rows measure and math renders after the first frame: the end must hold through that.
        Thread.sleep(forTimeInterval: 1.5)
        snap("bottom-open")
        assertAtEnd(app, "opened")
        XCTAssertFalse(element(app, "scrollToBottom").exists, "at the end: no scroll-to-bottom button")
    }

    /// As over the relay: answers come after a network delay, and the transcript arrives in pages (older ones loaded
    /// as the top comes into view).
    func testOpensOnTheEndWithLatencyAndPages() {
        let app = launch(["-CrokPageSize", "2", "-CrokDemoLatency", "600"])
        openShowcase(app)
        Thread.sleep(forTimeInterval: 3)
        snap("bottom-open-latency")
        assertAtEnd(app, "opened over the network")
        XCTAssertFalse(element(app, "scrollToBottom").exists, "at the end: no scroll-to-bottom button")
    }

    /// A long session (pages of earlier prompts, tool calls and replies above the showcase), over the network.
    func testOpensOnTheEndOfALongSession() {
        let app = launch(["-CrokDemoHistory", "120", "-CrokDemoLatency", "400"])
        openShowcase(app)
        Thread.sleep(forTimeInterval: 3)
        snap("bottom-open-history")
        assertAtEnd(app, "opened a long session")
        XCTAssertFalse(element(app, "scrollToBottom").exists, "at the end: no scroll-to-bottom button")
    }

    /// A reply much taller than the screen streams in: the transcript keeps its end in sight all the way.
    func testFollowsALongReplyStreamingIn() {
        let app = launch()
        let flaky = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(flaky.waitForExistence(timeout: 10))
        flaky.tap()
        let stop = element(app, "stopButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))
        let field = element(app, "composerField")
        field.tap()
        field.typeText("Show me the showcase")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts["Show me the showcase"].waitForExistence(timeout: 10), "the prompt is in")
        // The reply streams for several seconds (slow simulators answer queries late meanwhile): snap until its end is in.
        for index in 0..<60 where !lastLine(app).exists {
            Thread.sleep(forTimeInterval: 0.5)
            if index % 4 == 0 { snap(String(format: "bottom-stream-%02d", index)) }
        }
        XCTAssertTrue(stop.waitForNonExistence(timeout: 20), "the reply finished")
        Thread.sleep(forTimeInterval: 1.5)
        snap("bottom-stream-done")
        assertAtEnd(app, "after streaming")
        XCTAssertFalse(element(app, "scrollToBottom").exists, "at the end: no scroll-to-bottom button")
    }

    func testButtonAppearsInsideALongLastReplyAndReturnsToItsEnd() {
        let app = launch()
        openShowcase(app)
        Thread.sleep(forTimeInterval: 1.5)
        // A short drag up: still inside the last reply, but its end is off screen.
        drag(app, down: true, fraction: 0.2)
        snap("bottom-dragged")
        let button = element(app, "scrollToBottom")
        XCTAssertTrue(button.waitForExistence(timeout: 3), "the scroll-to-bottom button shows")
        XCTAssertFalse(lastLine(app).isHittable, "the end is off screen")
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 3), "the button goes once the end is back")
        Thread.sleep(forTimeInterval: 0.6)
        snap("bottom-returned")
        assertAtEnd(app, "after the button")

        // Far up (several screens), then the button again.
        for _ in 0..<4 { drag(app, down: true, fraction: 0.45) }
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        snap("bottom-returned-far")
        assertAtEnd(app, "after the button from far up")
    }
}
