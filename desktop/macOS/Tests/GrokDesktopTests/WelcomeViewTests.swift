import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

final class WelcomeViewTests: XCTestCase {
    private func date(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour, minute: minute))!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testTheGreetingFollowsTheClock() {
        let expected: [(Int, Int, String)] = [
            (5, 0, "Good morning"), (11, 59, "Good morning"),
            (12, 0, "Good afternoon"), (16, 59, "Good afternoon"),
            (17, 0, "Good evening"), (21, 59, "Good evening"),
            (22, 0, "Good night"), (0, 0, "Good night"), (4, 59, "Good night"),
        ]
        for (hour, minute, greeting) in expected {
            XCTAssertEqual(WelcomeGreeting.text(at: date(hour: hour, minute: minute), calendar: utc), greeting, "at \(hour):\(minute)")
        }
    }

    func testSizesFollowTheRoomAndStayInRange() {
        let narrow = WelcomeMetrics(size: CGSize(width: 300, height: 480))
        let wide = WelcomeMetrics(size: CGSize(width: 1_400, height: 900))
        let huge = WelcomeMetrics(size: CGSize(width: 3_000, height: 2_000))
        XCTAssertEqual(narrow.greetingSize, WelcomeMetrics.greetingRange.lowerBound, "a narrow column keeps a legible greeting")
        XCTAssertEqual(huge.greetingSize, WelcomeMetrics.greetingRange.upperBound, "full screen does not blow it up")
        XCTAssertLessThan(narrow.greetingSize, wide.greetingSize)
        for metrics in [narrow, wide, huge] {
            XCTAssertTrue(WelcomeMetrics.tickerRange.contains(metrics.tickerSize))
            XCTAssertLessThan(metrics.tickerSize, metrics.greetingSize * 0.5, "the starters stay secondary to the greeting")
        }
        // A short window keeps the greeting and lets the mark go.
        let short = WelcomeMetrics(size: CGSize(width: 1_000, height: 300))
        XCTAssertFalse(short.showsMark)
        XCTAssertLessThanOrEqual(short.greetingSize, 300 * 0.13 + 1)
        XCTAssertTrue(wide.showsMark)
        // Degenerate sizes while the window is first laid out.
        XCTAssertEqual(WelcomeMetrics(size: .zero).greetingSize, WelcomeMetrics.greetingRange.lowerBound)
    }

    func testTheStartersKeepTheirPrompts() {
        XCTAssertEqual(WelcomeStarter.all.map(\.title), ["Explore the codebase", "Build something", "Review changes"])
        XCTAssertTrue(WelcomeStarter.all.allSatisfy { !$0.prompt.isEmpty && NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    func testTheScriptFacesShipWithMacOS() {
        XCTAssertNotNil(WelcomeHandwriting.greetingFaces.lazy.compactMap { NSFont(name: $0, size: 40) }.first)
        XCTAssertNotNil(WelcomeHandwriting.secondaryFaces.lazy.compactMap { NSFont(name: $0, size: 20) }.first)
    }
}

/// PNGs of the new-task page at the sizes a window gives it, written when CROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class WelcomeViewSnapshotTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-welcome-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }

    private func makeStore(project: Bool) -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
        guard project else { store.state = DesktopState(); return store }
        let app = Project(path: "/tmp/qwen_image_2_1_workspace")
        store.state = DesktopState(projects: [app], conversations: [], selectedProjectID: app.id, selectedConversationID: nil)
        return store
    }

    func testTheWelcomeAtEverySize() throws {
        let sizes: [(String, CGSize)] = [("wide", CGSize(width: 1_100, height: 560)), ("medium", CGSize(width: 680, height: 480)),
                                         ("narrow", CGSize(width: 400, height: 460)), ("short", CGSize(width: 900, height: 300)),
                                         ("fullscreen", CGSize(width: 1_700, height: 900))]
        for (name, size) in sizes {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let store = makeStore(project: true)
                try SnapshotRenderer.write(WelcomeView().foregroundStyle(Theme.ink).desktopEnvironment(store), size: size, appearance: appearance,
                                           to: output.appendingPathComponent("welcome-\(name)-\(suffix).png"))
            }
        }
        let store = makeStore(project: false)
        try SnapshotRenderer.write(WelcomeView().foregroundStyle(Theme.ink).desktopEnvironment(store), size: CGSize(width: 680, height: 480), appearance: .darkAqua,
                                   to: output.appendingPathComponent("welcome-no-project-dark.png"))
    }

    /// Every greeting in the widest one, the longest that must fit a narrow column.
    func testEveryGreetingAndStarter() throws {
        let view = VStack(spacing: 18) {
            ForEach(["Good morning", "Good afternoon", "Good evening", "Good night"], id: \.self) { text in
                Text(text).font(WelcomeHandwriting.greeting(size: 34)).lineLimit(1).minimumScaleFactor(0.5)
            }
            ForEach(WelcomeStarter.all) { starter in
                Label(starter.title, systemImage: starter.symbol).font(WelcomeHandwriting.secondary(size: 16)).foregroundStyle(Theme.muted)
            }
        }
        .padding(24).frame(width: 336).foregroundStyle(Theme.ink)
        try SnapshotRenderer.write(view, size: CGSize(width: 336, height: 420), appearance: .darkAqua, to: output.appendingPathComponent("welcome-faces-dark.png"))
    }
}
