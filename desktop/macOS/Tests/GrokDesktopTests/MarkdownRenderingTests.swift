import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    static let sample = #"""
    # Sorting benchmark

    The **quick** result: merge sort ran in $O(n \log n)$ time, while *insertion* sort was ~~fast~~ slow.

    | Algorithm | Average | Stable |
    |:----------|:-------:|-------:|
    | Merge     | $n \log n$ | yes |
    | Quick     | `n log n` | no |

    1. Build the input
       - random
       - sorted
    2. Run each sort

    - [x] measured
    - [ ] plotted

    > [!NOTE]
    > Timings are medians of five runs.

    $$
    \bar{x} = \frac{1}{n}\sum_{i=1}^{n} x_i
    $$

    ```swift
    func mergeSort(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return values }
        return values // "sorted"
    }
    ```

    ---

    See [the docs](https://docs.x.ai/build/overview).
    """#

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func textBlocks(_ text: NSAttributedString) -> [NSTextBlock] {
        var blocks: [NSTextBlock] = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            blocks += (value as? NSParagraphStyle)?.textBlocks ?? []
        }
        return blocks
    }

    func testAttributedRendererBuildsTablesCodeListsAndCallouts() {
        let blocks = MarkdownParser.parse(Self.sample)
        let rendered = MarkdownAttributedRenderer(fontSize: 14, color: .secondaryLabelColor).render(blocks)
        let string = rendered.string
        XCTAssertTrue(string.contains("Sorting benchmark"))
        XCTAssertFalse(string.contains("**"), "Emphasis markers are not shown")
        XCTAssertTrue(string.contains("Algorithm") && string.contains("Stable"))
        XCTAssertTrue(string.contains("•\t") || string.contains("◦\t"), "Bullets hang in the list indent")
        XCTAssertTrue(string.contains("1.\t"))
        XCTAssertTrue(string.contains("☑\t") && string.contains("☐\t"))
        XCTAssertTrue(string.contains("func mergeSort"))
        let styles = textBlocks(rendered)
        XCTAssertTrue(styles.contains { $0 is NSTextTableBlock }, "Tables use TextKit table blocks")
        XCTAssertTrue(styles.contains { !($0 is NSTextTableBlock) && $0.backgroundColor != nil }, "Code sits in a filled block")
    }

    func testInlineAndDisplayMathBecomeAttachmentsThatCopyAsLaTeX() throws {
        try XCTSkipUnless(MathRenderer.isAvailable, "Requires STIX Two Math")
        let text = "Euler: $e^{i\\pi} + 1 = 0$ holds.\n\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$"
        let rendered = MarkdownAttributedRenderer(fontSize: 14, color: .labelColor).render(MarkdownParser.parse(text))
        var attachments = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        XCTAssertEqual(attachments, 2)

        let textView = MarkdownSourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.textStorage?.setAttributedString(rendered)
        textView.setSelectedRange(NSRange(location: 0, length: rendered.length))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GrokMarkdownTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, type: .string))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("$e^{i\\pi} + 1 = 0$"), copied)
        XCTAssertTrue(copied.contains("$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$"), copied)
        pasteboard.releaseGlobally()
    }

    private struct StreamingHarness: View {
        var text: String
        var body: some View {
            ReadOnlyTextView(text: text, style: .markdown, sizing: .fitContent(maxHeight: 2_000), followsTail: true)
                .frame(width: 600)
        }
    }

    func testStreamedMarkdownMatchesAFreshRender() throws {
        let host = NSHostingView(rootView: StreamingHarness(text: ""))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        let characters = Array(Self.sample)
        var index = 0
        while index < characters.count {
            index = min(characters.count, index + 37)
            host.rootView = StreamingHarness(text: String(characters[..<index]))
            host.layoutSubtreeIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let textView = try XCTUnwrap(Self.textView(in: host))
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fresh = MarkdownAttributedRenderer(fontSize: 14, color: .secondaryLabelColor, dark: dark).render(MarkdownParser.parse(Self.sample))
        XCTAssertEqual(textView.string, fresh.string)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    /// Writes PNGs of a rendered reply, of reasoning, and of a panel when CROK_DESKTOP_SNAPSHOT_DIR is set.
    func testRenderMarkdownSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let reply = Message(kind: .assistant, text: Self.sample)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(MessageView(message: reply).padding(28).frame(width: 760, alignment: .topLeading),
                                       size: CGSize(width: 760, height: 1_250), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent("markdown-reply-\(name).png"))
            try SnapshotRenderer.write(ReadOnlyTextView(text: Self.sample, style: .markdown, sizing: .fitContent(maxHeight: 1_100)).padding(28).frame(width: 700, alignment: .topLeading),
                                       size: CGSize(width: 700, height: 1_150), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent("markdown-thinking-\(name).png"))
            try SnapshotRenderer.write(MarkdownContent(text: Self.sample, style: .panel).padding(28).frame(width: 700, alignment: .topLeading),
                                       size: CGSize(width: 700, height: 1_000), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent("markdown-panel-\(name).png"))
        }
    }
}
