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
        let wide = ["|" + (1...14).map { " Column \($0) |" }.joined(), "|" + String(repeating: " --- |", count: 14),
                    "|" + (1...14).map { " value \($0) |" }.joined()].joined(separator: "\n")
        let replies = [
            "Two modules.\n\n| Module | What it does |\n| --- | --- |\n| Parser | Turns the Markdown source into blocks and inlines |\n| Renderer | Lays the blocks out as attributed text |",
            "| a | b |\n| - | - |\n| 1 | 2 |",
            "Wide.\n\n\(wide)\n\nAfter the table.",
            // The indent or padding around these tables takes room from them first; 1.2.2 measured them without it and never returned.
            Self.tableInAList,
            Self.tableInANestedList,
            "> | a | b |\n> | - | - |\n> | 1 | 2 |",
            "> [!TIP]\n> Compare:\n>\n> | Option | Cost |\n> | --- | --- |\n> | fast | high |\n> | slow | low |",
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

    private static let plainTable = "Two modules.\n\n| Module | What it does |\n| --- | --- |\n| Parser | Turns the Markdown source into blocks |\n| Renderer | Lays the blocks out |\n\nAfter."
    private static let tableInAList = "- Results:\n\n  | Case | Result |\n  | --- | --- |\n  | one | ok |\n  | two | failed |\n\n- Next item"
    private static let tableInANestedList = "1. First\n   - Inner\n\n     | A | B | C |\n     | - | - | - |\n     | 1 | 2 | 3 |\n"
    private static let tableInACallout = "> [!TIP]\n> Compare:\n>\n> | Option | Cost |\n> | --- | --- |\n> | fast | high |\n> | slow | low |"

    private func narrowest(_ markdown: String) -> CGFloat {
        MarkdownTextTable.narrowestLayoutWidth(in: MarkdownAttributedRenderer.reply(.response, dark: false).render(MarkdownParser.parse(markdown)))
    }

    /// What is around a table takes its room from the container before the table gets any.
    func testATableInAListOrAQuoteNeedsTheRoomAroundItToo() {
        XCTAssertEqual(narrowest("Only a paragraph, a list:\n\n- one\n- two\n\n```sh\necho code\n```"), 0, "Text without a table lays out in any width")
        let plain = narrowest(Self.plainTable)
        // Two columns: each its padding and borders and the least a column keeps.
        XCTAssertEqual(plain, 2 * (12.5 * 2 + MarkdownTextTable.narrowestColumn) + 2)
        XCTAssertGreaterThan(narrowest(Self.tableInAList), plain, "A list item's indent comes first")
        XCTAssertGreaterThan(narrowest(Self.tableInANestedList), narrowest("| A | B | C |\n| - | - | - |\n| 1 | 2 | 3 |"))
        // A callout's padding is 17 and 14 points.
        XCTAssertEqual(narrowest(Self.tableInACallout), plain + 31)
        // Of several tables, the one that needs most.
        XCTAssertEqual(narrowest(Self.plainTable + "\n\n" + Self.tableInACallout), plain + 31)
    }

    func testTheShownTextsContainerFollowsItsViewDownToAFloor() {
        let container = MinimumWidthTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.minimumWidth = 60
        XCTAssertEqual(container.size.width, 0, "No width is no limit, as before the view is placed")
        container.size = NSSize(width: 800, height: 10_000)
        XCTAssertEqual(container.size.width, 800)
        container.size = NSSize(width: 28, height: 10_000)
        XCTAssertEqual(container.size.width, 60, "Narrower than its text fits, it stays where the text fits")
        container.minimumWidth = 90
        XCTAssertEqual(container.size.width, 90, "A wider table arriving raises the floor at once")
        container.minimumWidth = 0
        XCTAssertEqual(container.size.width, 28, "Without a table it follows the view again")
        XCTAssertEqual(container.size.height, 10_000)
    }

    private struct Reply: View {
        var text: String
        var width: CGFloat
        var body: some View { MarkdownReply(text: text).frame(width: width) }
    }

    private struct Reasoning: View {
        var text: String
        var body: some View { ReadOnlyTextView(text: text, style: .markdown, sizing: .fitContent(maxHeight: 360)).frame(width: 640) }
    }

    /// A table inside a list item, a quote, or a callout, drawn. Crok Desktop 1.2.2 drew these with
    /// collapsed borders, for which TextKit asks the list item's or the quote's block for its table:
    /// an exception while drawing, which ends the app. Under XCTest it ends the test run.
    func testATableInsideAListAQuoteOrACalloutDraws() throws {
        let quoted = "> | a | b |\n> | - | - |\n> | 1 | 2 |"
        for markdown in [Self.tableInAList, Self.tableInANestedList, Self.tableInACallout, quoted] {
            let views: [NSView] = [NSHostingView(rootView: Reply(text: markdown, width: 640)), NSHostingView(rootView: Reasoning(text: markdown))]
            for host in views {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let textView = try XCTUnwrap(textView(in: host))
                XCTAssertGreaterThan(textView.frame.height, 40, "The table is laid out")
                window.contentView = nil
            }
        }
    }

    private func textView(in view: NSView) -> MarkdownSourceTextView? {
        if let textView = view as? MarkdownSourceTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    /// A reply placed and drawn in a view too narrow for its table, as a side panel squeezes one or a
    /// layout passes through on its way. In 1.2.2 the shown text followed the view to any width, and a
    /// table whose last column began past the edge was never laid out: an eight-column table in a
    /// view under 216 points. A regression here does not fail: it never returns.
    func testAReplyWithATableLaysOutAndDrawsInAViewOfAnyWidth() throws {
        let eight = "|" + (1...8).map { " H\($0) |" }.joined() + "\n|" + String(repeating: " - |", count: 8) + "\n|" + (1...8).map { " v\($0) |" }.joined()
        let widths: [CGFloat] = stride(from: 2, through: 140, by: 3).map { CGFloat($0) } + [180, 215, 283, 400, 800]
        for markdown in [Self.plainTable, eight, Self.tableInAList, Self.tableInANestedList, Self.tableInACallout] {
            let host = NSHostingView(rootView: Reply(text: markdown, width: 400))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let textView = try XCTUnwrap(textView(in: host))
            let container = try XCTUnwrap(textView.textContainer as? MinimumWidthTextContainer)
            let floor = container.minimumWidth
            XCTAssertGreaterThan(floor, 0, "The reply's tables set a floor")
            let start = Date()
            for width in widths {
                host.rootView = Reply(text: markdown, width: width)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                XCTAssertGreaterThanOrEqual(container.size.width, floor, "At \(width) points the text is laid out where its table fits")
                if width >= floor { XCTAssertEqual(container.size.width, width, accuracy: 0.5, "With room, the text is as wide as its view") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
            window.contentView = nil
        }
    }
}
