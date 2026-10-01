import XCTest
import SwiftUI
@testable import GrokDesktop

/// A reply's table in a view too narrow for it. A window being laid out measures its transcript a
/// few points wide on the way to its real width; Crok Desktop 1.2.1 gave the table's columns no
/// width at all there, and TextKit never returned from laying it out: opening a task whose reply
/// had a table, or launching with one selected, hung the app at full CPU with no window.
@MainActor
final class TableLayoutTests: XCTestCase {
    func testColumnsAlwaysFitAndNoneComesToNothing() {
        // Per column: its longest cell on one line, and its longest word.
        let tables: [(widest: [CGFloat], words: [CGFloat])] = [
            ([12, 12], [12, 12]),
            ([80, 420], [60, 70]),
            ([300, 2, 300], [90, 2, 40]),
            (Array(repeating: 140, count: 12), Array(repeating: 55, count: 12)),
            ([2, 2, 2], [2, 2, 2]),
        ]
        for (widest, words) in tables {
            let table = MarkdownTextTable(widest: widest, words: words, inset: 8.5)
            let borders = 8.5 * 2 * CGFloat(widest.count)
            for available in stride(from: table.minimumWidth, through: 1_600, by: 7) {
                let widths = table.contentWidths(in: available)
                XCTAssertEqual(widths.count, widest.count)
                XCTAssertTrue(widths.allSatisfy { $0 >= MarkdownTextTable.narrowestColumn }, "\(widest) in \(available): \(widths)")
                XCTAssertLessThanOrEqual(widths.reduce(0, +) + borders, available, "\(widest) fits in \(available): \(widths)")
            }
            // With room for everything, the columns are as wide as their content.
            XCTAssertEqual(table.contentWidths(in: widest.reduce(0, +) + borders + 40), widest.map { max($0, MarkdownTextTable.narrowestColumn) })
            // Narrower than it can be: the columns keep their minimum instead of vanishing.
            XCTAssertTrue(table.contentWidths(in: 3).allSatisfy { $0 >= MarkdownTextTable.narrowestColumn })
        }
    }

    /// The main window with a saved task selected whose reply has a table, as a launch lays it out.
    /// A regression here does not fail: it never returns.
    func testOpeningATaskWhoseReplyHasATableLaysOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-table-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replies = [
            "Two modules.\n\n| Module | What it does |\n| --- | --- |\n| Parser | Turns the Markdown source into blocks and inlines |\n| Renderer | Lays the blocks out as attributed text |",
            "| a | b |\n| - | - |\n| 1 | 2 |",
            "Wide.\n\n|" + (1...14).map { " Column \($0) |" }.joined() + "\n|" + String(repeating: " --- |", count: 14) + "\n|" + (1...14).map { " value \($0) |" }.joined() + "\n\nAfter the table.",
        ]
        let project = Project(path: directory.path)
        let now = Date()
        let task = Conversation(projectID: project.id, title: "Tables", messages: replies.flatMap {
            [Message(kind: .user, text: "And this one?", createdAt: now), Message(kind: .assistant, text: $0, createdAt: now)]
        })
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        let host = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        host.frame = CGRect(x: 0, y: 0, width: 1320, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let start = Date()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the window lays out at once")
        window.contentView = nil
        store.shutdown()
    }
}
