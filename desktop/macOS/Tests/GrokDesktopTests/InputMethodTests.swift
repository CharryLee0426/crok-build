import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Input methods (pinyin, kana, Hangul) show marked text before any character is committed, and
/// report no text change until then. The composer and search fields must keep that composition.
@MainActor
final class InputMethodTests: XCTestCase {
    private final class DraftModel: ObservableObject {
        @Published var draft = ""
    }

    private struct Harness: View {
        @ObservedObject var model: DraftModel
        /// Changing it makes SwiftUI update the editor, as any published change in the app does.
        var revision = 0

        var body: some View {
            PromptEditor(text: $model.draft, placeholder: "Ask Crok \(revision)", onSubmit: {})
                .frame(width: 420, height: 76)
        }
    }

    private static let nowhere = NSRange(location: NSNotFound, length: 0)
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
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

    private func editor(in view: NSView) -> SubmitTextView? {
        if let editor = view as? SubmitTextView { return editor }
        for subview in view.subviews { if let found = editor(in: subview) { return found } }
        return nil
    }

    func testCompositionSurvivesUpdatesAndCommitsIntoTheDraft() throws {
        let model = DraftModel()
        let host = host(Harness(model: model))
        let editor = try XCTUnwrap(editor(in: host))
        window?.makeFirstResponder(editor)
        XCTAssertTrue(editor.showsPlaceholder)

        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.nowhere)
        XCTAssertFalse(editor.showsPlaceholder, "The placeholder hides as soon as composing starts")
        XCTAssertEqual(model.draft, "", "Marked text is not part of the draft")

        // Any refresh of the composer used to replace the editor's text with the stale draft.
        host.rootView = Harness(model: model, revision: 1)
        settle(host)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "n")

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.nowhere)
        host.rootView = Harness(model: model, revision: 2)
        settle(host)
        XCTAssertEqual(editor.string, "ni", "The first letter is kept")

        editor.insertText("你", replacementRange: Self.nowhere)
        XCTAssertEqual(model.draft, "你")
        XCTAssertFalse(editor.hasMarkedText())

        editor.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0), replacementRange: Self.nowhere)
        XCTAssertEqual(model.draft, "你")
        XCTAssertEqual(editor.committedString, "你")
        host.rootView = Harness(model: model, revision: 3)
        settle(host)
        editor.insertText("好", replacementRange: Self.nowhere)
        XCTAssertEqual(model.draft, "你好")
        XCTAssertEqual(editor.string, "你好")
    }

    func testANewDraftReplacesAComposition() throws {
        let model = DraftModel()
        model.draft = "First task"
        let host = host(Harness(model: model))
        let editor = try XCTUnwrap(editor(in: host))
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.nowhere)
        XCTAssertEqual(editor.string, "First taskni")

        // Switching tasks shows that task's draft; the composition must not carry over or leak back.
        model.draft = "Second task"
        settle(host)
        XCTAssertEqual(editor.string, "Second task")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(model.draft, "Second task")
    }

    func testDeletingTheLastCommittedCharacterBringsThePlaceholderBack() throws {
        let model = DraftModel()
        let host = host(Harness(model: model))
        let editor = try XCTUnwrap(editor(in: host))
        window?.makeFirstResponder(editor)
        editor.insertText("a", replacementRange: Self.nowhere)
        XCTAssertFalse(editor.showsPlaceholder)
        editor.deleteBackward(nil)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(editor.showsPlaceholder)
    }

    func testCommittedStringLeavesOutMarkedTextWhereverItSits() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: Self.nowhere)
        XCTAssertEqual(view.string, "azhongb")
        XCTAssertEqual(view.committedString, "ab")
        view.unmarkText()
        XCTAssertEqual(view.committedString, "azhongb")
    }

    func testSearchFieldsKeepACompositionUnlessTheirTextChanges() throws {
        let field = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.nowhere)

        field.showText("")
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "n")

        field.showText("models")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(field.stringValue, "models")
    }
}
