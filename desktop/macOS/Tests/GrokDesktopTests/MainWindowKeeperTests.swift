import AppKit
import XCTest
@testable import GrokDesktop

/// The main window's close button hides it and the app keeps running; the Dock icon brings it back.
@MainActor
final class MainWindowKeeperTests: XCTestCase {
    private var directory: URL!
    private var stores: [AppStore] = []
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-main-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.shutdown() }
        stores = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString)/state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        store.features.browser.makeDataStore = { .nonPersistent() }
        stores.append(store)
        return store
    }

    /// A real window under the desktop, where it is on screen but nobody sees it.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    func testTheCloseButtonHidesTheMainWindowAndTheDockIconBringsItBack() throws {
        let store = makeStore(), window = makeWindow()
        var closes = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.mainWindow = window
        let delegate = AppDelegate()
        delegate.store = store
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "closing windows never quits")

        // On screen, the Dock icon has nothing to bring back and leaves the click to AppKit.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.performClick(nil)
        XCTAssertFalse(window.isVisible, "the close button hides the window")
        XCTAssertEqual(closes, 0, "the window is not closed, so its views, terminals and pages live on")

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "the app brought the window back itself")
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(store.showMainWindow(), "already on screen")

        // Pressed again after the window came back, the button still only hides it.
        close.performClick(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(store.showMainWindow())
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(closes, 0)
    }

    func testCommandWLeavesTheHiddenMainWindowsBrowserTabs() throws {
        let store = makeStore(), window = makeWindow()
        let browser = store.features.browser
        store.mainWindow = window
        browser.prepare()
        browser.newTab()
        store.showInspector = true
        store.sidePanelTab = .browser

        // With the window on screen, ⌘W with nothing else in front closes the browser's tab.
        store.closeFrontmost(nil)
        XCTAssertEqual(browser.pages.count, 1)

        browser.newTab()
        try XCTUnwrap(window.standardWindowButton(.closeButton)).performClick(nil)
        store.closeFrontmost(nil)
        XCTAssertEqual(browser.pages.count, 2, "no window has the keyboard, and the hidden window's tabs stay")
    }
}
