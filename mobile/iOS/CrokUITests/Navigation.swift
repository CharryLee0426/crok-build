import XCTest

/// Getting around the Sessions tab (mobile/DESIGN.md): the selected computer's projects, a project's sessions, the
/// computer switcher in the title, and search.
extension XCUIApplication {
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The selected computer's name in the Sessions tab's title.
    var computerTitle: XCUIElement { element("computerTitle") }

    /// Picks another computer from the title's menu (on the Sessions tab's root).
    func switchComputer(to name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(computerTitle.waitForExistence(timeout: 10), file: file, line: line)
        if computerTitle.label.hasPrefix(name) { return }
        computerTitle.tap()
        let item = buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) in the switcher", file: file, line: line)
        item.tap()
        XCTAssertTrue(
            waitFor(5) { self.computerTitle.label.hasPrefix(name) }, "switched to \(name)", file: file, line: line)
    }

    /// Opens a project from the Sessions tab's root.
    func openProject(_ name: String, on computer: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if let computer { switchComputer(to: computer, file: file, line: line) }
        let row = element("projectRow-\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "project \(name)", file: file, line: line)
        row.tap()
        XCTAssertTrue(navigationBars.staticTexts[name].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Opens a session from its project's screen (from the Sessions tab's root).
    func openSession(
        _ title: String, in project: String, on computer: String? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openProject(project, on: computer, file: file, line: line)
        tapSessionRow(title, file: file, line: line)
    }

    /// Taps a session row on screen (a project's screen, Archived, or search results).
    func tapSessionRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element("sessionRow-\(title)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "session \(title)", file: file, line: line)
        if !row.isHittable { swipeUp() }
        row.tap()
    }

    /// Finds a session with the Sessions tab's search and opens it (any project of the selected computer).
    func openSessionBySearch(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let search = searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), file: file, line: line)
        search.tap()
        search.typeText(title)
        tapSessionRow(title, file: file, line: line)
    }

    /// Back one screen.
    func goBack() {
        navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Waits until `condition` holds, sampling every 100 ms; returns whether it did.
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
