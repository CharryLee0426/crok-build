import XCTest

/// The o11y tab in demo mode (mobile/DESIGN.md "o11y"): every page, the range control, a chart's callout, the phone on
/// its side, dark, German and Chinese, and the states without a page. Screenshots go to `$CROK_SCREENSHOT_DIR` when
/// set (`TEST_RUNNER_CROK_SCREENSHOT_DIR=…` on xcodebuild), as in DemoTourUITests.
final class O11yUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extra: [String] = [], appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CrokDemo", "YES", "-CrokAppearance", appearance, "-crok.selectedComputer", "mbp"] + extra
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

    /// The third tab, right of Profile.
    private func openO11y(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertEqual(tabBar.buttons.count, 3, "Sessions, Profile, o11y")
        XCTAssertEqual(tabBar.buttons.element(boundBy: 2).label, "o11y")
        tabBar.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.element("o11yLink-overview").waitForExistence(timeout: 10))
    }

    /// Opens a page from the home page's links (scrolling to it when it is below the fold).
    private func openPage(_ app: XCUIApplication, _ page: String) {
        let link = app.element("o11yLink-\(page)")
        XCTAssertTrue(link.waitForExistence(timeout: 10), page)
        var tries = 0
        while !link.isHittable && tries < 6 {
            app.swipeUp()
            tries += 1
        }
        link.tap()
        XCTAssertTrue(app.element("o11yPage-\(page)").waitForExistence(timeout: 10), page)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("o11yPage-home").waitForExistence(timeout: 5))
    }

    func testEveryPage() {
        let app = launch()
        openO11y(app)
        XCTAssertTrue(app.element("o11yPage-home").exists)
        snap("o11y-01-home")
        app.swipeUp()
        snap("o11y-02-home-links")
        app.swipeDown()
        app.swipeDown()

        openPage(app, "overview")
        XCTAssertTrue(app.element("o11yRange").exists, "the overview offers 1h, 6h and 24h")
        XCTAssertTrue(app.element("openInGrafana").exists)
        snap("o11y-03-overview")
        app.swipeUp()
        snap("o11y-04-overview-charts")
        app.swipeUp()
        snap("o11y-05-overview-rankings")
        app.swipeUp()
        snap("o11y-06-overview-latest")
        back(app)

        let pages = ["claude", "openrouter", "crok", "harness", "history", "explorer", "evaluators", "guards", "experiments",
                     "agents", "conversations", "slos", "alerts"]
        for (n, page) in pages.enumerated() {
            openPage(app, page)
            snap(String(format: "o11y-%02d-%@", 7 + n * 2, page))
            app.swipeUp()
            snap(String(format: "o11y-%02d-%@-more", 8 + n * 2, page))
            back(app)
            app.swipeDown()
            app.swipeDown()
        }
    }

    func testRangeAndChartCallout() {
        let app = launch()
        openO11y(app)
        openPage(app, "overview")
        let range = app.element("o11yRange")
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        range.buttons["6h"].tap()
        XCTAssertTrue(app.waitFor(5) { range.buttons["6h"].isSelected }, "6h picked")
        // The relay's spend-per-day chart: a tap shows its values.
        let chart = app.element("o11ySection-2")
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).tap()
        snap("o11y-30-overview-callout")
        app.terminate()

        // The range is remembered for the page.
        let again = launch()
        openO11y(again)
        openPage(again, "overview")
        XCTAssertTrue(again.element("o11yRange").buttons["6h"].isSelected)
        again.element("o11yRange").buttons["24h"].tap()
    }

    /// A swipe that starts on a chart scrolls the page (the chart's own touches wait for a hold).
    func testASwipeOnAChartScrollsThePage() {
        let app = launch()
        openO11y(app)
        openPage(app, "harness")
        let chart = app.element("o11ySection-1")
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let before = chart.frame.minY
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)))
        XCTAssertTrue(app.waitFor(3) { chart.frame.minY < before - 100 }, "the page scrolled: \(before) → \(chart.frame.minY)")
    }

    /// On its side: four stats a row, charts across, the other sections two by two. (XCUITest's swipes and drags land
    /// in the wrong place while the simulator is on its side, so each page is pictured from its top.)
    func testOnItsSide() {
        let app = launch()
        openO11y(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.element("o11yLink-overview").waitForExistence(timeout: 5))
        snap("o11y-40-landscape-home")
        for (n, page) in ["overview", "history", "guards", "explorer", "agents"].enumerated() {
            XCUIDevice.shared.orientation = .portrait
            openPage(app, page)
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.element("o11yPage-\(page)").waitForExistence(timeout: 5))
            snap("o11y-\(41 + n)-landscape-\(page)")
            XCUIDevice.shared.orientation = .portrait
            back(app)
        }
        openPage(app, "evaluators")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.element("o11yPage-evaluators").waitForExistence(timeout: 5))
        snap("o11y-46-landscape-evaluators")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.element("o11yPage-evaluators").waitForExistence(timeout: 5))
        snap("o11y-47-portrait-again")
    }

    func testDark() {
        let app = launch(appearance: "dark")
        openO11y(app)
        snap("o11y-50-dark-home")
        openPage(app, "overview")
        snap("o11y-51-dark-overview")
        app.swipeUp()
        snap("o11y-52-dark-overview-charts")
        back(app)
        openPage(app, "history")
        snap("o11y-53-dark-history")
    }

    /// German has the longest words, Chinese the densest: nothing cut off.
    func testLocalized() {
        for (language, locale) in [("de", "de_DE"), ("zh-Hans", "zh_CN")] {
            let app = launch(["-AppleLanguages", "(\(language))", "-AppleLocale", locale])
            openO11y(app)
            snap("o11y-60-\(language)-home")
            openPage(app, "overview")
            snap("o11y-61-\(language)-overview")
            app.swipeUp()
            snap("o11y-62-\(language)-overview-charts")
            back(app)
            openPage(app, "evaluators")
            snap("o11y-63-\(language)-evaluators")
            app.terminate()
        }
    }

    func testStatesWithoutAPage() {
        for state in ["unconfigured", "forbidden"] {
            let app = launch(["-CrokDemoO11y", state])
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
            tabBar.buttons.element(boundBy: 2).tap()
            let empty = app.element("o11yEmptyState")
            XCTAssertTrue(empty.waitForExistence(timeout: 10), state)
            XCTAssertTrue(empty.label.contains(state == "forbidden" ? "not available" : "not set up"), empty.label)
            snap("o11y-70-\(state)")
            app.terminate()
        }
    }
}
