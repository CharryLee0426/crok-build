import XCTest
import SwiftUI
@testable import GrokDesktop

/// The transcript takes the room it is given, and the views around it lay out without measuring
/// its rows. Crok Desktop 1.2.2 let them: the transcript's size was what its rows measured, a
/// lazy stack's estimate, and on macOS 26 the window's layout and that estimate went round each
/// other without end once a prompt was sent, the main thread never coming back from one layout.
///
/// The windows here are never on screen: a frame is a layout and a draw, as the display cycle of
/// a visible window runs them.
@MainActor
final class TranscriptLayoutTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var host: NSHostingView<AnyView>!
    private var window: NSWindow!

    override func tearDown() async throws {
        window?.contentView = nil
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private static let longReply = (1...9).map { "Paragraph \($0) of a long reply: " + String(repeating: "some words that fill the line and wrap to the next one, ", count: 6) }.joined(separator: "\n\n")

    /// Rounds of a prompt, a tool call and a reply; every third reply is far taller than the window.
    private static func rounds(_ count: Int, named name: String = "Prompt") -> [Message] {
        let now = Date()
        return (0..<count).flatMap { round in
            [Message(kind: .user, text: "\(name) \(round)", createdAt: now),
             Message(kind: .tool, text: "Read `Sources/File\(round).swift`", status: "completed", detail: "one\ntwo", createdAt: now),
             Message(kind: .assistant, text: round % 3 == 2 ? longReply : "Round \(round) is done.", createdAt: now)]
        }
    }

    /// A store with a task for each transcript, the first of them selected.
    @discardableResult
    private func tasks(_ transcripts: [Message]...) throws -> [Conversation] {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = Project(path: directory.path)
        let tasks = transcripts.enumerated().map { Conversation(projectID: project.id, title: "Task \($0.offset)", messages: $0.element) }
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: tasks, selectedProjectID: project.id, selectedConversationID: tasks[0].id)
        return tasks
    }

    /// The conversation, the transcript above the composer, in a window that is never on screen.
    private func showConversation() {
        host = NSHostingView(rootView: AnyView(ConversationView().desktopEnvironment(store).background(Theme.canvas)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settle()
    }

    /// Frames, with what the main queue was asked to do between them.
    private func settle(frames: Int = 15) {
        for _ in 0..<frames {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private var tools: TranscriptToolsModel { store.features.transcript }

    /// How far the transcript is scrolled from the end of its content.
    private func distanceFromTheEnd(file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let sample = try XCTUnwrap(tools.lastScrollSample, "the transcript says where it is scrolled", file: file, line: line)
        return sample.contentHeight - sample.offsetY - sample.viewportHeight
    }

    /// The scroll view of the transcript: the one with the tallest document that is not a text view's.
    private var transcriptScrollView: NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(host).filter { !($0 is PassthroughScrollView) }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    func testTheTranscriptIsAsLargeAsItsRoomWhateverItsRowsMeasure() throws {
        // What a view would like to be is what a stack asks it when it lays out, and what the
        // scroll view answered with its rows' heights: thousands of points for this task.
        func ideal(_ transcript: [Message]) throws -> CGSize {
            try tasks(transcript)
            let view = NSHostingView(rootView: AnyView(TranscriptView().desktopEnvironment(store)))
            defer { store.shutdown() }
            return view.fittingSize
        }
        let long = try ideal(Self.rounds(40))
        let short = try ideal(Self.rounds(1))
        XCTAssertEqual(long, short, "forty rounds and one would like the same room")
        XCTAssertLessThan(long.height, 100, "and not the height of their rows: \(long)")
    }

    func testAPromptSentUnderALongReplyIsLaidOutAtOnce() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Where the transcript is scrolled is reported on macOS 15 and later") }
        // What 1.2.2 was showing when it stopped answering: short rows, a reply taller than the
        // window at the end, the output followed, and one more prompt.
        let task = try tasks(Self.rounds(15))[0]
        showConversation()
        XCTAssertLessThanOrEqual(try distanceFromTheEnd(), 1, "at the end when it opens")
        let started = Date()
        store.append(Message(kind: .user, text: "One more prompt", createdAt: Date()), to: task.id)
        settle(frames: 6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the prompt's row is laid out in a few frames")
        // A scroll to the end rests on its last row, the padding under the rows out of sight.
        XCTAssertLessThanOrEqual(try distanceFromTheEnd(), 16, "and the prompt is in sight")
        XCTAssertTrue(tools.isFollowingOutput)
    }

    func testTheConversationLaysOutAgainAsTheWindowIsResizedWithALongTranscript() throws {
        // Every size lays the conversation out again, the composer under the transcript with it.
        try tasks(Self.rounds(60))
        showConversation()
        let started = Date()
        for step in 0..<40 {
            host.frame = CGRect(x: 0, y: 0, width: 900 - Double(step) * 6, height: 760 - Double(step % 7) * 9)
            window.setContentSize(host.frame.size)
            settle(frames: 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "forty sizes are laid out in as many frames")
        XCTAssertEqual(tools.viewport.topMessageIndex.map { $0 >= 170 }, true, "the newest rows are on screen: top row \(String(describing: tools.viewport.topMessageIndex)) of 180")
    }

    func testATranscriptTheReaderScrolledUpStaysWhereItIsAsRowsArrive() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Where the transcript is scrolled is reported on macOS 15 and later") }
        let task = try tasks(Self.rounds(15))[0]
        showConversation()
        // The reader scrolls up from the end, with the scroll wheel.
        let scroll = try XCTUnwrap(transcriptScrollView, "the transcript's scroll view")
        for _ in 0..<10 {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 200, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
            scroll.scrollWheel(with: event)
            settle(frames: 1)
        }
        settle()
        XCTAssertFalse(tools.isFollowingOutput, "scrolled up, the output is not followed")
        let offset = try XCTUnwrap(tools.lastScrollSample).offsetY
        XCTAssertGreaterThan(try distanceFromTheEnd(), 500, "well above the end")
        for round in 0..<4 {
            store.append(Message(kind: .user, text: "Later prompt \(round)", createdAt: Date()), to: task.id)
            store.append(Message(kind: .assistant, text: "Later reply \(round).", createdAt: Date()), to: task.id)
            settle(frames: 4)
        }
        XCTAssertEqual(try XCTUnwrap(tools.lastScrollSample).offsetY, offset, accuracy: 1, "the rows that arrived did not move what the reader is looking at")
    }

    func testTheStoreSaysWhereATranscriptFirstChanged() throws {
        // What shows a long task compares only the messages from there on, not all of them, for every update.
        let task = try tasks(Self.rounds(4))[0]
        let start = store.transcriptRevision(of: task.id)
        XCTAssertEqual(store.transcriptFirstChange(of: task.id, since: start), Int.max, "nothing changed since")
        store.append(Message(kind: .user, text: "One more"), to: task.id)
        XCTAssertEqual(store.transcriptFirstChange(of: task.id, since: start), 12, "the message that was added")
        let later = store.transcriptRevision(of: task.id)
        store.append(Message(kind: .assistant, text: "Done."), to: task.id)
        XCTAssertEqual(store.transcriptFirstChange(of: task.id, since: start), 12, "the first of the two")
        XCTAssertEqual(store.transcriptFirstChange(of: task.id, since: later), 13)
        XCTAssertNil(store.transcriptFirstChange(of: task.id, since: later + 5), "a revision it never had")
        // Further back than it keeps track, any message may have changed.
        for index in 0..<300 { store.append(Message(kind: .assistant, text: "Reply \(index)"), to: task.id) }
        XCTAssertNil(store.transcriptFirstChange(of: task.id, since: start))
        XCTAssertEqual(store.transcriptFirstChange(of: task.id, since: store.transcriptRevision(of: task.id) - 3), store.task(task.id).map { $0.messages.count - 3 })
        XCTAssertNil(store.transcriptFirstChange(of: UUID(), since: 0).flatMap { $0 == Int.max ? nil : $0 }, "a task it has no changes for has none to report")
    }

    func testAnotherTaskOpensAtItsEnd() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Where the transcript is scrolled is reported on macOS 15 and later") }
        let tasks = try tasks(Self.rounds(15), Self.rounds(9, named: "Another prompt"))
        showConversation()
        store.selectConversation(tasks[1])
        settle()
        XCTAssertLessThanOrEqual(try distanceFromTheEnd(), 16, "the other task opens at its end")
        XCTAssertEqual(tools.viewport.topMessageIndex.map { $0 >= 24 }, true, "its newest rows are on screen: top row \(String(describing: tools.viewport.topMessageIndex)) of 27")
        store.selectConversation(tasks[0])
        settle()
        XCTAssertLessThanOrEqual(try distanceFromTheEnd(), 16, "and so does the first, shown again")
    }
}
