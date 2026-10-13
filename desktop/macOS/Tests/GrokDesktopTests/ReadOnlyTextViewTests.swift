import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

final class TextDeltaTests: XCTestCase {
    func testAppendedSuffixIsFoundForStreamedText() {
        XCTAssertEqual(TextDelta.appendedSuffix(from: "Checking ", to: "Checking the files."), "the files.")
        XCTAssertEqual(TextDelta.appendedSuffix(from: "思考中", to: "思考中… 🦊 done"), "… 🦊 done")
    }

    func testReplacedOrUnchangedTextIsNotTreatedAsAnAppend() {
        XCTAssertNil(TextDelta.appendedSuffix(from: "Reading README", to: "Reading LICENSE file"))
        XCTAssertNil(TextDelta.appendedSuffix(from: "Same", to: "Same"))
        XCTAssertNil(TextDelta.appendedSuffix(from: "Longer text", to: "Longer"))
        XCTAssertNil(TextDelta.appendedSuffix(from: "", to: "Fresh"))
    }
}

@MainActor
final class ReadOnlyTextViewTests: XCTestCase {
    private struct Harness: View {
        var text: String
        var isExpanded = true
        var followsTail = true

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    Text("Header")
                    if isExpanded {
                        ReadOnlyTextView(text: text, style: .prose, sizing: .fitContent(maxHeight: 360), followsTail: followsTail)
                    }
                    Text("Footer")
                }.frame(width: 600)
            }
        }
    }

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func host(_ view: Harness) -> NSHostingView<Harness> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        settle(host)
        return host
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    private static let paragraph = "Reasoning about the request, the constraints, and the code it touches. "

    private func assertEndIsVisible(_ textView: NSTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let layoutManager = try XCTUnwrap(textView.layoutManager), container = try XCTUnwrap(textView.textContainer)
        let length = textView.string.utf16.count
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
        let last = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let visible = try XCTUnwrap(textView.enclosingScrollView).contentView.bounds
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(NSPoint(x: visible.midX, y: last.midY)), "The newest line is in view: \(last) within \(visible)", file: file, line: line)
    }

    func testLongStreamingReasoningIsCappedAndAppendedInPlace() throws {
        var text = String(repeating: Self.paragraph, count: 30_000) // About 2 MB.
        let host = host(Harness(text: text))
        let textView = try XCTUnwrap(textView(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertEqual(scroll.frame.height, 360, accuracy: 1)
        try assertEndIsVisible(textView)
        // A selection only survives appends, not replacement of the whole text.
        textView.setSelectedRange(NSRange(location: 10, length: 20))
        for index in 0..<40 {
            text += "chunk \(index) "
            host.rootView = Harness(text: text)
            settle(host)
        }
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 20))
        XCTAssertEqual(scroll.frame.height, 360, accuracy: 1)
        try assertEndIsVisible(textView)
    }

    func testShortTextGrowsToFitWithoutScrolling() throws {
        let host = host(Harness(text: "A short thought."))
        let scroll = try XCTUnwrap(textView(in: host)?.enclosingScrollView)
        XCTAssertLessThan(scroll.frame.height, 60)
        XCTAssertGreaterThan(scroll.frame.height, 10)
    }

    func testFoldingAndUnfoldingWhileStreamingShowsTheLatestText() throws {
        // Expanding or collapsing a long thought while it streamed used to take the app down.
        var text = String(repeating: Self.paragraph, count: 15_000)
        let host = host(Harness(text: text))
        for index in 0..<12 {
            text += String(repeating: "more reasoning \(index) ", count: 500)
            let isExpanded = index.isMultiple(of: 2)
            host.rootView = Harness(text: text, isExpanded: isExpanded)
            settle(host)
            guard isExpanded else { continue }
            let shown = try XCTUnwrap(textView(in: host))
            XCTAssertEqual(shown.string, text)
            XCTAssertEqual(shown.enclosingScrollView?.frame.height ?? 0, 360, accuracy: 1)
            try assertEndIsVisible(shown)
        }
    }

    func testLinksAreDrawnInTheLinkColour() throws {
        let box = TranscriptTextBox(style: .reply(.response), maxHeight: .infinity, width: 400)
        box.update(text: "See [the docs](https://example.com).")
        let textView = try XCTUnwrap(box.textView)
        XCTAssertEqual(textView.linkTextAttributes?[.foregroundColor] as? NSColor, Theme.linkNS)
        XCTAssertNotEqual(Theme.linkNS, Theme.accentNS)
    }

    func testDiffTextIsColouredByLineKind() throws {
        let diff = "@@ -1,2 +1,2 @@\n-old line\n+new line\n context"
        let host = NSHostingView(rootView: ReadOnlyTextView(text: diff, style: .diff, wrapsLines: false, sizing: .fill).frame(width: 400, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        settle(host)
        let storage = try XCTUnwrap(textView(in: host)?.textStorage)
        let color = { (line: String) in storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: line).location, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color("+new"), Theme.greenNS)
        XCTAssertEqual(color("@@"), Theme.accentNS)
        XCTAssertEqual(color(" context"), .secondaryLabelColor)
        XCTAssertNotEqual(color("-old"), color(" context"))
    }
}
