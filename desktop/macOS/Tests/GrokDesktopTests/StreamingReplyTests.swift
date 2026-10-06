import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// A reply while it is still arriving. A line can mean one thing until its next characters make
/// it another: `* **` is a rule until it is `* **Parser**`. Crok Desktop 1.2.2 rendered each
/// partial text as it stood, so a reply whose list items all began in bold drew a rule, a TextKit
/// text block, and took it away again before every item.
@MainActor
final class StreamingReplyTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    /// Shaped like a reply that grouped its findings by owner: every item begins in bold, at the
    /// top level, nested, and inside a quote.
    static let grouped = """
    Grouped by owner, then by severity:

    ### Avery（第1-11项）

    * **P1：Parser #2**：the last token is dropped, and the cursor stays where it was.
    * **P2：Renderer #11**：layout passes; one edge keeps a white line.

    ### Blake（第12-22项）

    * **P0：Loader #24**：starts before its data, and stops at once.
      * **Nested**：still an item of the list.
    - **Dashes**：as a list marker.

    > * **Quoted**：an item inside a quote.

    One thing cuts across owners: `Try again` sometimes cannot be clicked.
    """

    private func prefixes(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return (0...scalars.count).map { end in
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[..<end])
            return String(view)
        }
    }

    private func hasRule(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .thematicBreak: return true
            case .list(let list): return list.items.contains { hasRule($0.content) }
            case .quote(let inner), .callout(_, _, let inner), .footnoteDefinition(_, let inner): return hasRule(inner)
            default: return false
            }
        }
    }

    func testALastLineThatIsOnlyRuleCharactersWaits() {
        let cases: [(text: String, shown: String)] = [
            ("Intro\n\n* **", "Intro\n\n"),
            ("Intro\n\n*", "Intro\n\n"),
            ("Intro\n\n* *", "Intro\n\n"),
            ("Intro\n\n* **P1", "Intro\n\n* **P1"),
            ("Intro\n\n* **\n", "Intro\n\n* **\n"),
            ("Title\n-", "Title\n"),
            ("Title\n==", "Title\n"),
            ("Title\n- one", "Title\n- one"),
            ("Above\n\n---", "Above\n\n"),
            ("Above\n\n---\n", "Above\n\n---\n"),
            ("Above\n\n___ ", "Above\n\n"),
            ("- item\n  * **", "- item\n"),
            ("> quoted\n> ---", "> quoted\n"),
            // An indent or a quote marker alone waits too: a rule character after it would take it back.
            ("> quoted\n> ", "> quoted\n"),
            ("- item\n  ", "- item\n"),
            ("- item\n  text", "- item\n  text"),
            ("---", ""),
            ("", ""),
            ("Plain text", "Plain text"),
            ("Ends in a dash -", "Ends in a dash -"),
            ("| a | b |\n|---|---", "| a | b |\n|---|---"),
            ("第一项\n\n* **", "第一项\n\n"),
        ]
        for (text, shown) in cases {
            XCTAssertEqual(StreamingMarkdown.settled(text), shown, "\(text.debugDescription)")
        }
        // What waiting spares: partial texts that read as something their next characters undo.
        XCTAssertTrue(hasRule(MarkdownParser.parse("Intro\n\n* **")))
        XCTAssertFalse(hasRule(MarkdownParser.parse("Intro\n\n* **P1")))
        XCTAssertTrue(hasRule(MarkdownParser.parse("Intro\n\n***")))
        XCTAssertFalse(hasRule(MarkdownParser.parse("Intro\n\n***Note")))
        XCTAssertEqual(StreamingMarkdown.settled("Intro\n\n***"), "Intro\n\n")
        guard case .heading = MarkdownParser.parse("Total\n=").first else { return XCTFail("`Total` over `=` reads as a heading") }
        guard case .paragraph = MarkdownParser.parse("Total\n= 42").first else { return XCTFail("`Total` over `= 42` is a paragraph") }
    }

    /// Streamed text only ever adds to what is shown, so the parser carries on from where it was.
    func testWhatIsShownOnlyEverGrows() {
        for document in [Self.grouped, MarkdownRenderingTests.sample, "Title\n===\n\ntext\n- - -\n* * *\n\n> ---\n> a\n\n--"] {
            var previous = ""
            for prefix in prefixes(document) {
                let shown = StreamingMarkdown.settled(prefix)
                XCTAssertTrue(prefix.utf8.starts(with: shown.utf8), "what is shown is part of the text")
                XCTAssertTrue(shown.utf8.starts(with: previous.utf8), "\(shown.suffix(20).debugDescription) continues \(previous.suffix(20).debugDescription)")
                previous = shown
            }
            XCTAssertEqual(StreamingMarkdown.settled(document + "\n"), document + "\n", "a finished line is shown")
        }
    }

    func testNoPartialTextOfAGroupedReplyShowsARule() {
        XCTAssertFalse(hasRule(MarkdownParser.parse(Self.grouped)), "the finished reply has no rule")
        var transient = 0
        for prefix in prefixes(Self.grouped) {
            if hasRule(MarkdownParser.parse(prefix)) { transient += 1 }
            XCTAssertFalse(hasRule(MarkdownParser.parse(StreamingMarkdown.settled(prefix))), "\(prefix.suffix(24).debugDescription) shows no rule")
        }
        // The three `* **` items at the top level, the nested one, and the quoted one.
        XCTAssertEqual(transient, 5, "as it stands, a partial text reads as a rule before every `*` item that begins in bold")
    }

    private struct Harness: View {
        var text: String
        var isStreaming: Bool
        var body: some View { MarkdownReply(text: text, isStreaming: isStreaming).frame(width: 600) }
    }

    private func host(_ view: Harness) -> NSHostingView<Harness> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1_200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func textView(in view: NSView) -> MarkdownSourceTextView? {
        if let textView = view as? MarkdownSourceTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    /// The paragraphs TextKit lays out inside a text block: a rule, a quote, a card, a table cell.
    private func textBlockParagraphs(_ textView: NSTextView) -> Int {
        guard let storage = textView.textStorage else { return 0 }
        var count = 0
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { count += 1 }
        }
        return count
    }

    func testAStreamingReplyNeverLaysOutARuleItWillNotKeep() throws {
        // Without the quote, which is a text block of its own, the finished reply has none.
        let reply = Self.grouped.replacingOccurrences(of: "> * **Quoted**：an item inside a quote.\n\n", with: "")
        let host = host(Harness(text: "", isStreaming: true))
        for prefix in prefixes(reply) {
            host.rootView = Harness(text: prefix, isStreaming: true)
            host.layoutSubtreeIfNeeded()
            let textView = try XCTUnwrap(textView(in: host))
            XCTAssertEqual(textBlockParagraphs(textView), 0, "no text block after \(prefix.suffix(24).debugDescription)")
        }
        host.rootView = Harness(text: reply, isStreaming: false)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(textView(in: host))
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        XCTAssertEqual(textView.string, MarkdownAttributedRenderer.reply(.response, dark: dark).render(MarkdownParser.parse(reply)).string,
                       "the finished reply is the one a fresh render gives")
    }

    func testTheEndOfAStreamShowsALineThatWasWaiting() throws {
        let reply = "All done.\n\n---"
        let host = host(Harness(text: reply, isStreaming: true))
        let textView = try XCTUnwrap(textView(in: host))
        XCTAssertEqual(textView.string, "All done.")
        XCTAssertEqual(textBlockParagraphs(textView), 0)
        // The turn ends with no more text: the line is what it says.
        host.rootView = Harness(text: reply, isStreaming: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(textBlockParagraphs(textView), 1, "the rule is drawn once the reply is finished")
        // A reply that goes on instead shows the line as soon as it has ended.
        host.rootView = Harness(text: reply + "\n\nMore.", isStreaming: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(textBlockParagraphs(textView), 1)
        XCTAssertTrue(textView.string.hasSuffix("More."))
    }
}
