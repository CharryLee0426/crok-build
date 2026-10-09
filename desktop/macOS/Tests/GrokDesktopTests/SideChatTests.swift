import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The side chat in AppKit: the keys its field takes, how the field grows, what the pane does with
/// a question and with each task's draft, and what its list lays out. The windows are never on screen.
@MainActor
final class SideChatTests: XCTestCase {
    private static let nowhere = NSRange(location: NSNotFound, length: 0)
    private var window: NSWindow?
    private var store: AppStore?
    private var directory: URL?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        store?.shutdown()
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func host(_ view: NSView, size: NSSize) {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        settle()
    }

    /// A frame, and what the main queue was asked to do after it.
    private func settle() {
        window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func key(_ characters: String, ignoring: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code))
    }

    private func returnKey(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent { try key("\r", ignoring: "\r", code: 36, modifiers) }
    private func controlJ() throws -> NSEvent { try key("\n", ignoring: "j", code: 38, .control) }

    private static func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let ordered = values.sorted()
        return ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))]
    }

    private static var isOptimized: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// About a megabyte of log lines, as a pasted crash log is.
    private static func paste(bytes: Int) -> String {
        var text = "", line = 0
        while text.utf8.count < bytes {
            text += "2026-10-08T19:\(line % 60):\(line % 60) ERROR [module.\(line % 17)] request \(line) failed: connection reset after \(line * 3) ms\n"
            line += 1
        }
        return text
    }

    /// A store with a project and `tasks`, the first of them selected, and a side chat pane showing it.
    private func makePane(_ tasks: [Conversation], size: NSSize = NSSize(width: 400, height: 720)) -> (AppStore, SideChatPaneView) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-side-chat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let owned = tasks.map { task -> Conversation in var task = task; task.projectID = project.id; return task }
        store.state = DesktopState(projects: [project], conversations: owned, selectedProjectID: project.id, selectedConversationID: owned.first?.id)
        self.store = store
        let pane = SideChatPaneView(model: store.features.sideChat)
        host(pane, size: size)
        if let first = owned.first { show(first.id, in: pane) }
        return (store, pane)
    }

    /// What SwiftUI passes the pane when the side chat changes.
    private func show(_ id: UUID, in pane: SideChatPaneView) {
        guard let model = store?.features.sideChat else { return }
        pane.show(conversationID: id, title: store?.task(id)?.title ?? "", messages: model.thread(id), isPending: model.pending.contains(id), focusRequest: model.focusRequest)
        settle()
    }

    private func eventually(timeout: TimeInterval = 8, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    // MARK: Keys

    func testReturnAsksAndShiftReturnOptionReturnAndControlJStartNewLines() throws {
        let composer = SideChatComposerView()
        var asked = 0
        composer.onSend = { asked += 1 }
        host(composer, size: NSSize(width: 380, height: 120))
        let editor = composer.textView
        window?.makeFirstResponder(editor)
        editor.insertText("first", replacementRange: Self.nowhere)
        editor.keyDown(with: try returnKey(.shift))
        editor.insertText("second", replacementRange: Self.nowhere)
        editor.keyDown(with: try returnKey(.option))
        editor.insertText("third", replacementRange: Self.nowhere)
        editor.keyDown(with: try controlJ())
        editor.insertText("fourth", replacementRange: Self.nowhere)
        XCTAssertEqual(editor.string, "first\nsecond\nthird\nfourth", "⇧↵, ⌥↵, and ⌃J each start a line")
        XCTAssertEqual(asked, 0)

        editor.keyDown(with: try returnKey())
        XCTAssertEqual(asked, 1, "Return asks")
        editor.keyDown(with: try key("\u{3}", ignoring: "\u{3}", code: 76, .numericPad))
        XCTAssertEqual(asked, 2, "so does Enter")
        XCTAssertEqual(editor.string, "first\nsecond\nthird\nfourth", "the field is emptied by the pane, once the question is asked")

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.nowhere)
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try controlJ())
        XCTAssertEqual(asked, 2, "while an input method composes, its keys are its own")
    }

    func testThePromptTakesTheSameNewLineKeys() throws {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        var submitted = 0
        editor.onSubmit = { submitted += 1 }
        host(editor, size: NSSize(width: 320, height: 80))
        window?.makeFirstResponder(editor)
        editor.insertText("a", replacementRange: Self.nowhere)
        editor.keyDown(with: try controlJ())
        editor.keyDown(with: try returnKey(.option))
        editor.keyDown(with: try returnKey(.shift))
        XCTAssertEqual(editor.string, "a\n\n\n")
        XCTAssertEqual(submitted, 0)
        editor.keyDown(with: try returnKey())
        XCTAssertEqual(submitted, 1)

        // With /multiline on, Return starts a line and ⌘↵ sends.
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "composerMultiline")
        defaults.set(true, forKey: "composerMultiline")
        defer { if let previous { defaults.set(previous, forKey: "composerMultiline") } else { defaults.removeObject(forKey: "composerMultiline") } }
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try controlJ())
        XCTAssertEqual(editor.string, "a\n\n\n\n\n")
        XCTAssertEqual(submitted, 1)
        editor.keyDown(with: try returnKey(.command))
        XCTAssertEqual(submitted, 2)
    }

    func testTheSideChatFieldLeavesThePromptsFocusRequestsAlone() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let prompt = SubmitTextView(frame: NSRect(x: 0, y: 120, width: 400, height: 60))
        let composer = SideChatComposerView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        container.addSubview(prompt)
        container.addSubview(composer)
        host(container, size: container.frame.size)
        window?.makeFirstResponder(composer.textView)
        NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
        XCTAssertTrue(window?.firstResponder === prompt, "asking for the prompt focuses the prompt, not the side chat's field")
    }

    // MARK: The field

    func testTheFieldGrowsWithItsTextToSixLinesThenScrolls() throws {
        let composer = SideChatComposerView()
        host(composer, size: NSSize(width: 380, height: 40))
        let width: CGFloat = 380
        let one = composer.preferredHeight(forWidth: width)
        XCTAssertEqual(one, 37, accuracy: 3, "one line, as tall as the SwiftUI field was")
        composer.setText("one\ntwo\nthree")
        let three = composer.preferredHeight(forWidth: width)
        composer.setText((1...6).map(String.init).joined(separator: "\n"))
        let six = composer.preferredHeight(forWidth: width)
        composer.setText((1...20).map(String.init).joined(separator: "\n"))
        let twenty = composer.preferredHeight(forWidth: width)
        XCTAssertGreaterThan(three, one)
        XCTAssertGreaterThan(six, three)
        XCTAssertEqual(twenty, six, "past six lines the field scrolls")
        composer.setText("one\n")
        XCTAssertGreaterThan(composer.preferredHeight(forWidth: width), one, "a trailing newline is a line")
        composer.setText(String(repeating: "wraps ", count: 40))
        XCTAssertGreaterThan(composer.preferredHeight(forWidth: width), one, "a long line wraps")
        XCTAssertGreaterThan(composer.preferredHeight(forWidth: 200), composer.preferredHeight(forWidth: 600), "and wraps sooner in a narrower panel")

        // A pasted megabyte is not laid out to be measured: it is taller than six lines at any width.
        let paste = Self.paste(bytes: 1_000_000)
        let pasted = Self.milliseconds { composer.setText(paste) }
        XCTAssertEqual(composer.preferredHeight(forWidth: width), six)
        composer.setText("")
        XCTAssertEqual(composer.preferredHeight(forWidth: width), one)
        print(String(format: "PERF side chat field: a megabyte replaces the text and is measured in %.1f ms", pasted))
    }

    func testTypingAfterALongPasteStaysCheap() throws {
        let composer = SideChatComposerView()
        host(composer, size: NSSize(width: 380, height: 125))
        window?.makeFirstResponder(composer.textView)
        let editor = composer.textView
        let paste = Self.paste(bytes: 1_000_000)
        let pasted = Self.milliseconds {
            editor.insertText(paste, replacementRange: Self.nowhere)
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.contentView?.displayIfNeeded()
        }
        var keystrokes: [Double] = []
        for character in " - why does this keep failing?" {
            keystrokes.append(Self.milliseconds {
                editor.insertText(String(character), replacementRange: Self.nowhere)
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.contentView?.displayIfNeeded()
            })
        }
        XCTAssertTrue(composer.question.hasSuffix("why does this keep failing?"))
        XCTAssertTrue(composer.sendButton.isEnabled)
        let p50 = Self.percentile(keystrokes, 50), longest = keystrokes.max() ?? 0
        print(String(format: "PERF side chat field: pasting a megabyte %.0f ms; a keystroke after it p50 %.2f ms, max %.1f ms", pasted, p50, longest))
        XCTAssertLessThan(longest, 250, "a keystroke is not a pause")
        if Self.isOptimized { XCTAssertLessThan(p50, 16, "a keystroke fits in a frame") }
    }

    // MARK: The pane

    func testAskingShowsTheQuestionAtTheEndAndEmptiesTheField() async throws {
        let task = Conversation(projectID: UUID(), title: "Parser")
        let (store, pane) = makePane([task])
        let model = store.features.sideChat
        XCTAssertEqual(pane.list.rowCount, 1, "the intro, before the first question")
        XCTAssertTrue(pane.clearButton.isHidden)
        let editor = pane.composer.textView
        window?.makeFirstResponder(editor)
        XCTAssertFalse(pane.composer.sendButton.isEnabled)
        editor.insertText("Where is the lexer?", replacementRange: Self.nowhere)
        XCTAssertTrue(pane.composer.sendButton.isEnabled)

        editor.keyDown(with: try returnKey())
        XCTAssertEqual(model.thread(task.id).map(\.text), ["Where is the lexer?"])
        XCTAssertTrue(model.pending.contains(task.id))
        XCTAssertEqual(editor.string, "", "the question left the field")
        settle()
        XCTAssertEqual(pane.list.rowCount, 2, "the question and Crok is answering…")
        XCTAssertLessThanOrEqual(pane.list.distanceFromBottom, 1)
        XCTAssertFalse(pane.clearButton.isHidden)
        XCTAssertFalse(pane.clearButton.isEnabled, "a side chat being answered is not cleared")

        editor.insertText("And the parser?", replacementRange: Self.nowhere)
        XCTAssertFalse(pane.composer.sendButton.isEnabled)
        editor.keyDown(with: try returnKey())
        XCTAssertEqual(editor.string, "And the parser?", "a question waits while the last is answered")
        XCTAssertEqual(model.thread(task.id).count, 1)

        // This store's harness cannot start, so the question fails, with Retry.
        try await eventually { !model.pending.contains(task.id) }
        show(task.id, in: pane)
        XCTAssertEqual(model.thread(task.id).map(\.role), [.question, .failure])
        XCTAssertEqual(pane.list.rowCount, 2)
        XCTAssertTrue(pane.composer.sendButton.isEnabled, "the waiting question can be asked now")
        XCTAssertTrue(pane.clearButton.isEnabled)
    }

    func testRetryAsksAgainAndClearEmptiesTheSideChat() async throws {
        let question = SideChatMessage(role: .question, text: "Why is the build slow?")
        let failure = SideChatMessage(role: .failure, text: "Crok did not respond to x.ai/btw in time.")
        var task = Conversation(projectID: UUID(), title: "Build")
        task.sideChat = [question, failure]
        let (store, pane) = makePane([task])
        let model = store.features.sideChat
        let row = try XCTUnwrap(pane.list.rowView(for: failure.id) as? SideChatFailureRow)
        XCTAssertTrue(row.retryButton.accessibilityPerformPress())
        XCTAssertEqual(model.thread(task.id).map(\.text), ["Why is the build slow?"], "the failed exchange is asked again")
        XCTAssertNotEqual(model.thread(task.id).first?.id, question.id)
        XCTAssertTrue(model.pending.contains(task.id))
        XCTAssertEqual(pane.list.rowCount, 2, "the question and Crok is answering…")

        try await eventually { !model.pending.contains(task.id) }
        show(task.id, in: pane)
        XCTAssertTrue(pane.clearButton.accessibilityPerformPress())
        XCTAssertTrue(model.thread(task.id).isEmpty)
        XCTAssertNil(store.task(task.id)?.sideChat)
        XCTAssertEqual(pane.list.rowCount, 1, "the intro again")
        XCTAssertTrue(pane.clearButton.isHidden)
    }

    func testEachTaskKeepsItsOwnDraft() throws {
        let tasks = [Conversation(projectID: UUID(), title: "Parser"), Conversation(projectID: UUID(), title: "Lexer")]
        let (store, pane) = makePane(tasks)
        let model = store.features.sideChat
        let editor = pane.composer.textView
        editor.insertText("about the parser", replacementRange: Self.nowhere)
        show(tasks[1].id, in: pane)
        XCTAssertEqual(pane.composer.question, "", "another task's side chat starts from its own draft")
        editor.insertText("about the lexer", replacementRange: Self.nowhere)
        show(tasks[0].id, in: pane)
        XCTAssertEqual(pane.composer.question, "about the parser")

        // The tab closes: the pane goes, and what was typed stays with the task.
        pane.keepDraft()
        XCTAssertEqual(model.drafts[tasks[0].id], "about the parser")
        XCTAssertEqual(model.drafts[tasks[1].id], "about the lexer")
        let reopened = SideChatPaneView(model: model)
        host(reopened, size: NSSize(width: 400, height: 720))
        show(tasks[1].id, in: reopened)
        XCTAssertEqual(reopened.composer.question, "about the lexer")
    }

    func testALongPastedQuestionShowsInABoxThatScrolls() throws {
        let short = SideChatMessage(role: .question, text: "What failed?")
        let long = SideChatMessage(role: .question, text: Self.paste(bytes: 1_000_000))
        let answer = SideChatMessage(role: .answer, text: "The connection pool is exhausted.\n\n```swift\nlet pool = Pool(size: 4)\n```")
        var task = Conversation(projectID: UUID(), title: "Crash")
        task.sideChat = [short, answer, long]
        let opened = Self.milliseconds { _ = makePane([task]) }
        let pane = try XCTUnwrap(window?.contentView as? SideChatPaneView)
        let boxed = try XCTUnwrap(pane.list.rowView(for: long.id) as? SideChatQuestionRow)
        XCTAssertTrue(boxed.isBoxed)
        XCTAssertLessThanOrEqual(boxed.frame.height, SideChatQuestionRow.longTextHeight + 16, "a pasted log takes a few lines of the panel, and scrolls")
        let plain = try XCTUnwrap(pane.list.rowView(for: short.id) as? SideChatQuestionRow)
        XCTAssertFalse(plain.isBoxed)
        XCTAssertLessThan(plain.frame.height, 40)
        XCTAssertNotNil(pane.list.rowView(for: answer.id) as? SideChatAnswerRow)
        print(String(format: "PERF side chat: opening a side chat with a megabyte question %.0f ms", opened))
        XCTAssertLessThan(opened, 2_000)
    }

    // MARK: The list

    private func longSideChat(rounds: Int) -> [SideChatMessage] {
        (0..<rounds).flatMap { round in
            [SideChatMessage(role: .question, text: "Question \(round): what does `Module\(round % 12)` do?"),
             SideChatMessage(role: .answer, text: MarkdownTestDocuments.mixed(bytes: 1_200 + (round % 5) * 400))]
        }
    }

    func testALongSideChatHasViewsOnlyForWhatIsInSight() throws {
        let list = SideChatListView()
        host(list, size: NSSize(width: 400, height: 640))
        let messages = longSideChat(rounds: 300)
        let opened = Self.milliseconds {
            list.show(messages, isPending: false)
            settle()
        }
        XCTAssertEqual(list.rowCount, 600)
        XCTAssertLessThan(list.realizedRowCount, 30, "only the rows near what is in sight have views")
        XCTAssertGreaterThan(list.realizedRowCount, 0)
        XCTAssertLessThanOrEqual(list.distanceFromBottom, 1, "it opens at its end")
        XCTAssertTrue(list.isFollowing)

        var resizes: [Double] = []
        for step in 0..<10 {
            resizes.append(Self.milliseconds {
                window?.setContentSize(NSSize(width: 340 + CGFloat(step % 3) * 120, height: 640))
                settle()
            })
            XCTAssertLessThanOrEqual(list.distanceFromBottom, 1, "the end stays in sight as the panel is resized")
        }
        XCTAssertLessThan(list.realizedRowCount, 30)
        print(String(format: "PERF side chat list: opening 600 messages %.0f ms; a resize p50 %.1f ms, max %.1f ms",
                     opened, Self.percentile(resizes, 50), resizes.max() ?? 0))
    }

    func testAReaderScrolledUpStaysPutAndAQuestionBringsTheEndBack() throws {
        let list = SideChatListView()
        host(list, size: NSSize(width: 400, height: 640))
        var messages = longSideChat(rounds: 20)
        list.show(messages, isPending: false)
        settle()
        let clip = list.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 1_500))
        list.scrollView.reflectScrolledClipView(clip)
        settle()
        XCTAssertFalse(list.isFollowing)
        // The row at the top of what is in sight; an answer can be taller than the view.
        let anchor = try XCTUnwrap(messages.first { message in list.rowFrame(for: message.id).map { $0.maxY > clip.bounds.minY } == true })
        let top = try XCTUnwrap(list.rowFrame(for: anchor.id)).minY - clip.bounds.minY

        messages.append(SideChatMessage(role: .answer, text: MarkdownTestDocuments.mixed(bytes: 3_000)))
        list.show(messages, isPending: false)
        settle()
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: anchor.id)).minY - clip.bounds.minY, top, accuracy: 0.5, "an answer below does not move what is read")
        XCTAssertFalse(list.isFollowing)

        messages.append(SideChatMessage(role: .question, text: "And then?"))
        list.show(messages, isPending: true, scrollsToEnd: true)
        settle()
        XCTAssertLessThanOrEqual(list.distanceFromBottom, 1, "asking brings the end into sight")
        XCTAssertTrue(list.isFollowing)
    }
}

/// The side chat in the main window, as it is used: a task's conversation beside it, a long log
/// pasted into its field round after round, sent with Return, answered by the offline harness
/// (which repeats the question), and the window resized. A real window under the desktop, as
/// `TranscriptWindowTests` opens one, driven by the run loop; set CROK_DESKTOP_UI_TESTS=1. The
/// SwiftUI side chat it replaced stalled for a quarter of a second at every keystroke after such a
/// paste, and for up to a second as an answer arrived. CROK_SIDE_CHAT_PASTE_BYTES (200000) sizes the
/// paste, CROK_SIDE_CHAT_ROUNDS (5) the rounds. With CROK_DESKTOP_WINDOW_SHOTS=<folder> the window
/// server pictures the window after the first answer, and with lines typed in the field.
@MainActor
final class SideChatWindowTests: XCTestCase {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private var directory: URL!
    private var store: AppStore!
    private var window: NSWindow!
    private let stalls = MainThreadWatchdog()
    private let hang = TraceSessionReplayTests.MainThreadWatchdog()

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_UI_TESTS"] != nil else {
            throw XCTSkip("Set CROK_DESKTOP_UI_TESTS=1 to send long pastes through the side chat in a window (about half a minute)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-side-chat-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let executable = directory.appendingPathComponent("fixture-grok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
    }

    override func tearDown() async throws {
        stalls.stop()
        hang.stop()
        window?.orderOut(nil)
        window?.contentView = nil
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The run loop for `seconds`, as an app's runs between events.
    private func spin(_ seconds: Double, _ note: String) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            hang.mark(note)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private var field: SubmitTextView? {
        func find(_ view: NSView) -> SideChatComposerView? { (view as? SideChatComposerView) ?? view.subviews.lazy.compactMap(find).first }
        return window.contentView.flatMap(find)?.textView
    }

    /// The window as the window server draws it, glass included, when CROK_DESKTOP_WINDOW_SHOTS names a folder.
    private func picture(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_WINDOW_SHOTS"] else { return }
        // Still there on macOS 27, though the SDK no longer declares it (see `TranscriptWindowTests`).
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let image = try XCTUnwrap(capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue(), "the window server pictured the window")
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    func testLongPastesRoundAfterRoundStayResponsive() throws {
        let environment = ProcessInfo.processInfo.environment
        let bytes = Int(environment["CROK_SIDE_CHAT_PASTE_BYTES"] ?? "") ?? 200_000
        let rounds = Int(environment["CROK_SIDE_CHAT_ROUNDS"] ?? "") ?? 5
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1320, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        window.orderFrontRegardless()
        hang.start(limit: 15, report: directory.appendingPathComponent("hang-sample.txt"))
        spin(1, "launch")
        let configured = Date().addingTimeInterval(20)
        while store.run.isConfiguring && Date() < configured { spin(0.1, "configuring") }
        store.draft = "hello"
        store.send()
        let started = Date().addingTimeInterval(20)
        while (store.run.isRunning || store.state.selectedConversationID == nil) && Date() < started { spin(0.1, "first prompt") }
        let id = try XCTUnwrap(store.state.selectedConversationID)
        store.showSidePanel(.sideChat)
        spin(0.8, "side chat open")
        let editor = try XCTUnwrap(field, "the side chat's field is the AppKit text view")
        let sideChat = store.features.sideChat

        var line = 0, paste = ""
        while paste.utf8.count < bytes {
            paste += "2026-10-08T19:\(line % 60):\(line % 60) ERROR [module.\(line % 17)] request \(line) failed: `connection reset` after \(line * 3) ms, retrying\n"
            line += 1
        }
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        stalls.start(every: .milliseconds(20))
        var worst = (paste: 0.0, typing: 0.0, answer: 0.0, resize: 0.0)
        for round in 0..<rounds {
            window.makeFirstResponder(editor)
            _ = stalls.drain()
            editor.insertText("Round \(round): why does this keep failing?\n" + paste, replacementRange: editor.selectedRange())
            spin(0.4, "round \(round): paste")
            let pasted = stalls.drain()
            for character in " Thanks!" {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                spin(0.03, "round \(round): typing")
            }
            spin(0.2, "round \(round): typing")
            let typing = stalls.drain()
            editor.keyDown(with: returnKey)
            XCTAssertEqual(editor.string, "", "round \(round): Return asked the question")
            let deadline = Date().addingTimeInterval(30)
            while sideChat.thread(id).count < 2 * (round + 1) && Date() < deadline { spin(0.05, "round \(round): answer") }
            spin(0.6, "round \(round): answer")
            let answered = stalls.drain()
            XCTAssertEqual(sideChat.thread(id).last?.role, .answer, "round \(round) was answered")
            if round == 0 {
                try picture("side-chat-long-paste-answered")
                editor.insertText("A follow-up\nover a few lines,\nwith ⇧↵ between them", replacementRange: editor.selectedRange())
                spin(0.3, "round 0: lines typed")
                try picture("side-chat-field-lines")
                editor.selectAll(nil)
                editor.delete(nil)
            }
            for step in 0..<6 {
                window.setContentSize(NSSize(width: 1320 - CGFloat(step % 2 == 0 ? 160 : 0), height: 800 - CGFloat(step % 3) * 40))
                spin(0.1, "round \(round): resize")
            }
            let resized = stalls.drain()
            worst = (max(worst.paste, pasted), max(worst.typing, typing), max(worst.answer, answered), max(worst.resize, resized))
            print(String(format: "PERF side chat window round %d (%d KB pasted): longest main-thread stall pasting %.0f ms, typing %.0f ms, asking and answering %.0f ms, resizing %.0f ms",
                         round, bytes / 1_000, pasted, typing, answered, resized))
        }
        XCTAssertEqual(sideChat.thread(id).count, 2 * rounds)
        XCTAssertLessThan(worst.typing, 400, "typing after a long paste never stalls the window")
        XCTAssertLessThan(worst.paste, 600)
    }
}
