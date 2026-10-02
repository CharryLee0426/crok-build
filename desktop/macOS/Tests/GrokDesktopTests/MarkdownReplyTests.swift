import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Replies are one TextKit text view, so a selection runs across every block and copies them together.
@MainActor
final class MarkdownReplyTests: XCTestCase {
    private var window: NSWindow?
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("GrokMarkdownReplyTests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        pasteboard.releaseGlobally()
    }

    private struct Harness: View {
        var text: String
        var body: some View {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Header")
                    MarkdownReply(text: text)
                    Text("Footer")
                }.frame(width: 640)
            }
        }
    }

    private func host(_ text: String) -> NSHostingView<Harness> {
        let host = NSHostingView(rootView: Harness(text: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        settle(host)
        return host
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }

    private func textView(in view: NSView) -> MarkdownSourceTextView? {
        if let textView = view as? MarkdownSourceTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    private func copySelection(_ textView: NSTextView) throws -> String {
        pasteboard.clearContents()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, type: .string))
        return try XCTUnwrap(pasteboard.string(forType: .string))
    }

    func testOneSelectionCopiesEveryBlockOfAReply() throws {
        let host = host(MarkdownRenderingTests.sample)
        let textView = try XCTUnwrap(textView(in: host))
        textView.selectAll(nil)
        let copied = try copySelection(textView)
        for expected in ["Sorting benchmark", "merge sort ran in $O(n \\log n)$ time", "Algorithm", "Build the input", "random",
                         "[x]\tmeasured", "[ ]\tplotted", "Timings are medians", "$$\\bar{x}", "func mergeSort", "return values // \"sorted\"", "See the docs."] {
            XCTAssertTrue(copied.contains(expected), "\(expected) is copied: \(copied)")
        }
        XCTAssertFalse(copied.contains("Swift"), "The code card's language label is drawn, not copied")
        XCTAssertFalse(copied.contains("\u{FFFC}"), "Drawn symbols copy as text or not at all")
    }

    func testASelectionCanStartInProseAndEndInsideCode() throws {
        let text = "Run this first:\n\n```sh\nmake build\nmake test\n```\n\nThen deploy."
        let host = host(text)
        let textView = try XCTUnwrap(textView(in: host))
        let string = textView.string as NSString
        let start = string.range(of: "first").location
        let end = NSMaxRange(string.range(of: "make build"))
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(try copySelection(textView), "first:\nmake build")
    }

    func testEachCodeCardHasACopyButtonThatCopiesItsCode() throws {
        let text = "Two blocks:\n\n```swift\nlet a = 1\n```\n\nand\n\n```\nplain text\n```"
        let host = host(text)
        let textView = try XCTUnwrap(textView(in: host))
        let buttons = textView.copyButtons
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            XCTAssertGreaterThan(button.frame.width, 20)
            XCTAssertTrue(textView.bounds.contains(button.frame), "\(button.frame) sits inside \(textView.bounds)")
            XCTAssertGreaterThan(button.frame.midX, textView.bounds.midX, "The button sits at the card's trailing edge")
        }
        XCTAssertLessThan(buttons[0].frame.minY, buttons[1].frame.minY)
        buttons[1].pasteboard = pasteboard
        buttons[1].performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "plain text")
        XCTAssertEqual(buttons[1].accessibilityLabel(), "Copied")
    }

    func testTableColumnsFitTheirContentAndWrapTheLongestFirst() {
        let table = MarkdownTextTable(widest: [50, 80, 300], words: [50, 40, 70], inset: 12.5)
        XCTAssertEqual(table.contentWidths(in: 600), [50, 80, 300], "A table that fits is as wide as its content")
        let narrow = table.contentWidths(in: 300)
        XCTAssertEqual(narrow[0], 50, "A column of single words keeps them whole")
        XCTAssertGreaterThanOrEqual(narrow[1], 40)
        XCTAssertLessThan(narrow[2], 200, "The long column wraps")
        XCTAssertLessThanOrEqual(narrow.reduce(0, +), 300 - 12.5 * 6)
    }

    func testATableNarrowerThanTheReplySitsInItsMiddle() throws {
        let table = MarkdownTextTable(widest: [50, 80, 300], words: [50, 40, 70], inset: 12.5)
        XCTAssertEqual(table.leadingSpace(before: table.contentWidths(in: 705), in: 705), 100)
        XCTAssertEqual(table.leadingSpace(before: table.contentWidths(in: 300), in: 300), 0, accuracy: 2, "A table that wraps fills the view")

        let host = host("Counts:\n\n| Area | Files |\n| --- | --- |\n| Sources | 7 |\n| Tests | 6 |\n\nDone.")
        let textView = try XCTUnwrap(textView(in: host))
        let layout = try XCTUnwrap(textView.layoutManager)
        /// The line a cell's text is on, which is as wide as the cell's content.
        func cell(_ text: String) -> NSRect {
            let index = (textView.string as NSString).range(of: text).location
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        let leading = cell("Area").minX, trailing = textView.bounds.width - cell("Files").maxX
        XCTAssertGreaterThan(leading, 150, "The table does not start at the reply's leading edge")
        XCTAssertEqual(leading, trailing, accuracy: 2)
        XCTAssertEqual(cell("Tests").minX, leading, "Rows line up")
    }

    func testRepliesGrowWithoutAnInnerScroller() throws {
        let long = (1...400).map { "Paragraph \($0) of a long reply that keeps going." }.joined(separator: "\n\n")
        let host = host(long)
        let textView = try XCTUnwrap(textView(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertGreaterThan(scroll.frame.height, 8_000, "Replies are not capped")
        XCTAssertEqual(scroll.frame.height, textView.frame.height, accuracy: 2)
        XCTAssertEqual(textView.string.components(separatedBy: "\n").count, 400)
    }

    private struct StreamingHarness: View {
        var text: String
        var body: some View { MarkdownReply(text: text).frame(width: 600) }
    }

    func testStreamedReplyMatchesAFreshRender() throws {
        let host = NSHostingView(rootView: StreamingHarness(text: ""))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1_200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        let characters = Array(MarkdownRenderingTests.sample)
        var index = 0
        while index < characters.count {
            index = min(characters.count, index + 29)
            host.rootView = StreamingHarness(text: String(characters[..<index]))
            host.layoutSubtreeIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let textView = try XCTUnwrap(textView(in: host))
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fresh = MarkdownAttributedRenderer.reply(.response, dark: dark).render(MarkdownParser.parse(MarkdownRenderingTests.sample))
        XCTAssertEqual(textView.string, fresh.string)
        XCTAssertEqual(textView.copyButtons.count, 1)
    }

    func testStreamingALongReplyStaysIncremental() throws {
        let document = MarkdownTestDocuments.mixed(bytes: 60_000)
        let host = NSHostingView(rootView: StreamingHarness(text: ""))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        let characters = Array(document)
        var index = 0, steps = 0
        // Streamed output reaches the view in batches, at most every 33 ms.
        let total = MarkdownPerformanceTests.milliseconds {
            while index < characters.count {
                index = min(characters.count, index + 240)
                host.rootView = StreamingHarness(text: String(characters[..<index]))
                host.layoutSubtreeIfNeeded()
                steps += 1
            }
        }
        let textView = try XCTUnwrap(textView(in: host))
        XCTAssertEqual(textView.string, MarkdownAttributedRenderer.reply(.response, dark: textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            .render(MarkdownParser.parse(document)).string)
        print("PERF streaming reply \(document.utf8.count) bytes in \(steps) updates: \(String(format: "%.2f", total / Double(steps))) ms/update")
        if MarkdownPerformanceTests.isOptimized { XCTAssertLessThan(total / Double(steps), 16) }
    }

    /// Writes PNGs of a narrow reply, as in the side chat, when GROK_DESKTOP_SNAPSHOT_DIR is set.
    func testRenderNarrowReplySnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let text = """
        The window is set up in `main.swift`:

        ```swift
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ```

        | Setting | Debug build | Release build | Notes |
        |---|---|---|---|
        | Flicker | yes | no | Only when the window first appears on an external display |

        > [!TIP]
        > Turn off *Reduce motion* to see the animation.
        """
        let reply = MarkdownReply(text: text, style: MarkdownStyle(fontSize: 13.5, blockSpacing: 9)).padding(14).frame(width: 340, alignment: .topLeading)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(reply, size: CGSize(width: 340, height: 520), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent("markdown-reply-narrow-\(name).png"))
        }
    }

    func testAnImageParagraphShowsTheImageOnceLoaded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-reply-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chart.png")
        let image = NSImage(size: NSSize(width: 300, height: 200), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)

        let host = host("Before\n\n![Chart](\(file.path))\n\nAfter")
        let textView = try XCTUnwrap(textView(in: host))
        let deadline = Date().addingTimeInterval(5)
        var cell: MarkdownImageCell?
        var position = NSRange()
        while cell == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            settle(host)
            textView.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { value, range, _ in
                if let found = (value as? NSTextAttachment)?.attachmentCell as? MarkdownImageCell { cell = found; position = range }
            }
        }
        XCTAssertNotNil(cell, "The link becomes the image")
        settle(host)
        let layout = try XCTUnwrap(textView.layoutManager), container = try XCTUnwrap(textView.textContainer)
        let drawn = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: position, actualCharacterRange: nil), in: container)
        XCTAssertEqual(drawn.width, 300, accuracy: 1)
        XCTAssertEqual(drawn.midX, textView.bounds.midX, accuracy: 1, "The image sits in the middle of the reply")
        // The image arrives after the reply was first measured; SwiftUI must measure it again.
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertGreaterThan(scroll.frame.height, 240, "The reply grows to fit the image")
        XCTAssertEqual(scroll.frame.height, textView.frame.height, accuracy: 2)
        textView.selectAll(nil)
        XCTAssertTrue(try copySelection(textView).contains("![Chart](\(file.path))"))
    }
}
