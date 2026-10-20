import XCTest

/// Replies in Markdown (relay/DESIGN.md §5) in demo mode: the showcase reply (relay/scripts/markdown-showcase.md) from
/// end to start in light and dark, its wide table and formula scrolled sideways, Copy on a code block, and a reply
/// streaming in through an unclosed fence and an unclosed `$$`. Screenshots as in `DemoTourUITests`
/// (`TEST_RUNNER_CROK_SCREENSHOT_DIR`).
@MainActor
final class MarkdownUITests: XCTestCase {
    private func launch(appearance: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CrokDemo", "YES", "-CrokAppearance", appearance]
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

    /// One slow drag of about half a screen (no fling), so consecutive screenshots overlap.
    private func drag(_ app: XCUIApplication, down: Bool) {
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let (from, to) = down ? (top, bottom) : (bottom, top)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    /// The transcript opens at the reply's end; drag up through it to the prompt above it.
    private func tour(_ app: XCUIApplication, _ prefix: String) {
        snap("\(prefix)-00")
        let prompt = app.staticTexts["Show me every kind of Markdown you can write."]
        for step in 1...14 {
            drag(app, down: true)
            snap(String(format: "%@-%02d", prefix, step))
            if prompt.exists && prompt.isHittable { break }
        }
    }

    func testShowcaseLight() {
        let app = launch(appearance: "light")
        openShowcase(app)
        tour(app, "md-light")
    }

    func testShowcaseDark() {
        let app = launch(appearance: "dark")
        openShowcase(app)
        tour(app, "md-dark")
    }

    func testWideContentScrollsInsideTheBubble() {
        let app = launch(appearance: "light")
        openShowcase(app)
        // From the end, up to the wide formula, then the wide table.
        let formula = app.descendants(matching: .any).matching(identifier: "displayMath").element(boundBy: 2)
        for _ in 0..<6 where !(formula.exists && formula.isHittable) { drag(app, down: true) }
        XCTAssertTrue(formula.isHittable)
        snap("md-wide-formula")
        formula.swipeLeft()
        snap("md-wide-formula-scrolled")

        let table = app.descendants(matching: .any).matching(identifier: "markdownTable").element(boundBy: 1)
        for _ in 0..<8 where !(table.exists && table.isHittable) { drag(app, down: true) }
        XCTAssertTrue(table.isHittable)
        snap("md-wide-table")
        table.swipeLeft()
        snap("md-wide-table-scrolled")

        // Copy on the nearest code block (just above the tables) says "Copied" for a moment.
        let copyButtons = app.buttons.matching(identifier: "copyCodeButton")
        for _ in 0..<3 where !copyButtons.allElementsBoundByIndex.contains(where: \.isHittable) { drag(app, down: true) }
        let copy = copyButtons.allElementsBoundByIndex.first { $0.isHittable }
        guard let copy else { return XCTFail("no code block on screen") }
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2))
        snap("md-copied")
        XCTAssertTrue(app.buttons["Copied"].waitForNonExistence(timeout: 4))
    }

    func testStreamingReply() {
        let app = launch(appearance: "light")
        let flaky = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(flaky.waitForExistence(timeout: 10))
        flaky.tap()
        let stop = element(app, "stopButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))
        let field = element(app, "composerField")
        field.tap()
        field.typeText("Why did it flake?")
        element(app, "sendButton").tap()
        snap("md-stream-sent")
        XCTAssertTrue(app.staticTexts["Why did it flake?"].waitForExistence(timeout: 5))
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the turn runs: Stop is back")
        // The reply streams nine words every 0.45 s; catch it half-way through the fence and the formula.
        for index in 0..<16 {
            Thread.sleep(forTimeInterval: 0.35)
            snap(String(format: "md-stream-%02d", index))
            if !stop.exists { break }
        }
        let end = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ran the test 50 times")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "displayMath").waitForExistence(timeout: 5))
        snap("md-stream-done")
    }
}
