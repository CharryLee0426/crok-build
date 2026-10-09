import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// PNGs of the AppKit transcript's rows beside the SwiftUI rows they replace, for visual review,
/// written when CROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class TranscriptListSnapshotTests: XCTestCase {
    private var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()) }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] != nil else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
    }

    private func write(_ view: NSView, to name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
    }

    /// The list, tall enough to show a transcript whole, with the given blocks open.
    private func renderList(_ messages: [Message], expanded: Set<UUID> = [], streaming: UUID? = nil, status: String? = nil, width: CGFloat, appearance: NSAppearance.Name, name: String) throws {
        let list = TranscriptListView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        // The window's canvas is behind the rows, which have no background of their own.
        let canvas = TranscriptFillView(color: Theme.palette.canvasNS, radius: 0)
        canvas.frame = list.frame
        list.autoresizingMask = [.width, .height]
        canvas.addSubview(list)
        let window = NSWindow(contentRect: list.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = canvas
        let display = TranscriptDisplay(conversation: UUID(), streamingID: streaming, showTimestamps: true, expanded: expanded, status: status)
        list.apply(messages: messages, display: display)
        // As tall as its rows, so one picture shows them all.
        for _ in 0..<4 {
            window.setContentSize(NSSize(width: width, height: max(600, list.documentHeight)))
            list.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        canvas.displayIfNeeded()
        try write(canvas, to: name)
        window.contentView = nil
    }

    /// The SwiftUI rows, as the transcript laid them out before.
    private func renderSwiftUI(_ messages: [Message], expanded: Set<UUID> = [], streaming: UUID? = nil, width: CGFloat, appearance: NSAppearance.Name, name: String) throws {
        let view = VStack(alignment: .leading, spacing: 23) {
            ForEach(messages) { message in
                let foldable = message.kind == .thought || message.kind == .tool
                MessageView(message: message, isStreaming: message.id == streaming,
                            timestamp: message.kind == .user || message.kind == .assistant ? message.createdAt : nil,
                            isExpanded: foldable ? expanded.contains(message.id) : nil, onExpand: { _, _ in })
            }
            Color.clear.frame(height: 1)
        }
        .frame(maxWidth: 800, alignment: .leading).padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 15).frame(maxWidth: .infinity)
        .foregroundStyle(Theme.ink).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        .frame(width: width).fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: view.background(Theme.canvas))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: width, height: max(600, host.fittingSize.height)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        host.layoutSubtreeIfNeeded()
        try write(host, to: name)
        window.contentView = nil
    }

    func testEveryKindOfRowBesideItsSwiftUIRow() throws {
        let messages = TranscriptListFixtures.showcase()
        let open = Set([messages[1].id, messages[2].id, messages[5].id])
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try renderList(messages, width: 900, appearance: appearance, name: "rows-appkit-\(suffix).png")
            try renderSwiftUI(messages, width: 900, appearance: appearance, name: "rows-swiftui-\(suffix).png")
            try renderList(messages, expanded: open, width: 900, appearance: appearance, name: "rows-open-appkit-\(suffix).png")
            try renderSwiftUI(messages, expanded: open, width: 900, appearance: appearance, name: "rows-open-swiftui-\(suffix).png")
        }
        // A narrow window: the long title and the table wrap.
        try renderList(messages, width: 560, appearance: .aqua, name: "rows-narrow-appkit.png")
        try renderSwiftUI(messages, width: 560, appearance: .aqua, name: "rows-narrow-swiftui.png")
    }

    func testRowsWithPicturesAndFiles() throws {
        let messages = TranscriptListFixtures.withAttachments()
        try renderList(messages, expanded: [messages[1].id], width: 900, appearance: .aqua, name: "attachments-appkit.png")
        try renderSwiftUI(messages, expanded: [messages[1].id], width: 900, appearance: .aqua, name: "attachments-swiftui.png")
        try renderList(messages, width: 520, appearance: .darkAqua, name: "attachments-narrow-appkit.png")
        try renderSwiftUI(messages, width: 520, appearance: .darkAqua, name: "attachments-narrow-swiftui.png")
    }

    func testReasoningWhileItStreams() throws {
        var messages = Array(TranscriptListFixtures.showcase().prefix(1))
        let thought = Message(kind: .thought, text: MarkdownTestDocuments.thinking(lines: 12), createdAt: TranscriptListFixtures.base)
        messages.append(thought)
        try renderList(messages, streaming: thought.id, status: "Thinking…", width: 900, appearance: .aqua, name: "streaming-appkit.png")
        try renderSwiftUI(messages, streaming: thought.id, width: 900, appearance: .aqua, name: "streaming-swiftui.png")
        try renderList(messages, expanded: [thought.id], streaming: thought.id, status: "Thinking…", width: 900, appearance: .darkAqua, name: "streaming-open-appkit.png")
    }

    func testToolCallsInEachState() throws {
        let base = TranscriptListFixtures.base
        let thought = Message(kind: .thought, text: MarkdownTestDocuments.thinking(lines: 6), createdAt: base)
        let messages = [
            Message(kind: .tool, text: "Run `crok mcp doctor runpod 2>&1 | tail -30`", toolID: "done", status: "completed",
                    detail: "runpod: reachable\nauth: oauth required", createdAt: base),
            Message(kind: .tool, text: "Run `swift test --filter Snapshot`", toolID: "failed", status: "failed", detail: "error: 2 tests failed", createdAt: base),
            Message(kind: .tool, text: "Run `npx -y skills list --global 2>&1 | grep -E '(runpod|flash)'`", toolID: "running", status: "in_progress", createdAt: base),
            Message(kind: .tool, text: "Read `desktop/macOS/Package.swift`", toolID: "pending", status: "pending", createdAt: base),
            thought,
        ]
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try renderList(messages, expanded: [messages[1].id], streaming: thought.id, status: "Working…", width: 900, appearance: appearance, name: "tools-running-\(suffix).png")
            try renderList(Array(messages.prefix(4)), width: 900, appearance: appearance, name: "tools-stopped-\(suffix).png")
        }
    }
}

/// The AppKit transcript by itself: what it lays out, what stays put, and what a long task costs.
/// The windows here are never on screen; a frame is a layout, as a visible window's display cycle runs it.
@MainActor
final class TranscriptListTests: XCTestCase {
    private var list: TranscriptListView!
    private var window: NSWindow!
    private var display = TranscriptDisplay(conversation: UUID())

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        list = nil
    }

    private func show(_ messages: [Message], size: NSSize = NSSize(width: 900, height: 700)) {
        list = TranscriptListView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(contentRect: list.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = list
        list.apply(messages: messages, display: display)
        settle()
    }

    private func apply(_ messages: [Message]) {
        list.apply(messages: messages, display: display)
        settle()
    }

    /// A frame, and what the main queue was asked to do after it.
    private func settle() {
        list.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        list.layoutSubtreeIfNeeded()
    }

    /// The work of a frame alone, in milliseconds: `change`, then the layout it calls for.
    private func frame(_ change: () -> Void) -> Double {
        let time = Self.milliseconds {
            change()
            list.layoutSubtreeIfNeeded()
        }
        settle()
        return time
    }

    private var clip: NSRect { list.scrollView.contentView.bounds }
    private var distanceFromEnd: CGFloat { list.documentHeight - clip.maxY }

    /// The reader scrolls: positive moves towards earlier messages. The view is moved as a scroll
    /// moves it, at once; a wheel event from a test is animated over later frames, at its own pace
    /// (`TranscriptLayoutTests` scrolls with those).
    private func scroll(_ points: CGFloat, times: Int = 1) {
        for _ in 0..<times {
            let clip = list.scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - points))
            list.scrollView.reflectScrolledClipView(clip)
            settle()
        }
    }

    /// Where a row's top is on screen: points below the top of the view.
    private func screenTop(of id: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        try XCTUnwrap(list.rowFrame(for: id), "the row is placed", file: file, line: line).minY - clip.minY
    }

    private static func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let ordered = values.sorted()
        return ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))]
    }

    // MARK: What is laid out

    func testALongSessionHasViewsOnlyForWhatIsInSight() throws {
        // 3,000 rounds: 3,000 reasoning blocks, 9,000 commands, 3,000 replies.
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        XCTAssertEqual(messages.count, 15_001)
        let opened = Self.milliseconds { show(messages) }
        print(String(format: "PERF transcript list: opening %d messages %.0f ms, %d rows have views, %d are measured", messages.count, opened, list.realizedRowCount, list.measuredRowCount))
        XCTAssertEqual(list.rowCount, messages.count)
        XCTAssertLessThan(list.realizedRowCount, 80, "only the rows near what is in sight have views")
        XCTAssertGreaterThan(list.realizedRowCount, 5)
        XCTAssertLessThanOrEqual(distanceFromEnd, 1, "it opens at its end")
        XCTAssertTrue(list.isFollowing)
        XCTAssertEqual(list.topVisibleRow.map { $0 > messages.count - 40 }, true, "its newest rows are in sight")
        XCTAssertLessThan(opened, 3_000, "a long task opens at once")
        // Folded reasoning that has finished is as tall whatever it holds: none of it is ever laid out to place it.
        XCTAssertGreaterThanOrEqual(list.measuredRowCount, 3_000)
    }

    func testEveryKindOfMessageHasItsRow() throws {
        let messages = TranscriptListFixtures.showcase()
        show(messages, size: NSSize(width: 900, height: 6_000))
        let kinds: [Message.Kind: TranscriptRowView.Type] = [.user: TranscriptUserRow.self, .assistant: TranscriptAssistantRow.self, .thought: TranscriptThoughtRow.self,
                                                             .tool: TranscriptToolRow.self, .system: TranscriptSystemRow.self]
        for message in messages {
            let row = try XCTUnwrap(list.rowView(for: message.id), "\(message.kind) has a view")
            XCTAssertTrue(type(of: row) == kinds[message.kind], "\(message.kind) is shown by \(type(of: row))")
            XCTAssertEqual(row.frame.height, try XCTUnwrap(list.rowFrame(for: message.id)).height, "the view is as tall as its row")
            XCTAssertGreaterThan(row.frame.height, 20)
        }
        // The reply with every Markdown format is one text view holding all of them.
        let reply = try XCTUnwrap(list.rowView(for: messages[9].id))
        func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
        let text = try XCTUnwrap(texts(reply).first).string
        for expected in ["Heading one", "strikethrough", "First bullet", "A finished task", "exponential", "A block quote", "A note callout", "struct Row", "plain code without a language", "The footnote's text."] {
            XCTAssertTrue(text.contains(expected), "the reply shows \(expected)")
        }
    }

    func testAReplyIsRenderedOnceWhenTheAppearanceChanges() throws {
        // Math is drawn for one appearance, so a reply renders again in another. It replaced
        // nothing when it did: the text was added after itself, and every reply said everything twice.
        let messages = [Message(kind: .user, text: "Explain"), Message(kind: .assistant, text: "One paragraph with $x^2$.\n\nAnother with `code`.\n\n- and a list")]
        show(messages)
        func text() throws -> String {
            func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
            return try XCTUnwrap(texts(try XCTUnwrap(list.rowView(for: messages[1].id))).first).string
        }
        let light = try text(), height = try XCTUnwrap(list.rowFrame(for: messages[1].id)).height
        XCTAssertTrue(light.contains("Another with code."))
        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            list.displayIfNeeded()
            settle()
            XCTAssertEqual(try text(), light, "the same text in \(appearance.rawValue)")
            XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: messages[1].id)).height, height, "at the same height")
        }
    }

    func testRowsMakeRoomForTheirPicturesAndFiles() throws {
        let messages = TranscriptListFixtures.withAttachments()
        show(messages, size: NSSize(width: 900, height: 3_000))
        func height(_ index: Int) throws -> CGFloat { try XCTUnwrap(list.rowFrame(for: messages[index].id)).height }
        XCTAssertGreaterThan(try height(0), 96 + 30 + 44, "a prompt shows its pictures, its files, and its text")
        XCTAssertGreaterThan(try height(1), TranscriptFoldHeader.minHeight + 240, "eight screenshots take two rows of tiles under the folded command")
        XCTAssertGreaterThan(try height(2), TranscriptFoldHeader.minHeight + 100, "one screenshot shows large")
        XCTAssertGreaterThan(try height(3), 300, "a generated image shows larger still under the reply")
        XCTAssertGreaterThan(try height(4), 150, "a reply that is only a picture has no empty text above it")
        // Narrower, the tiles wrap onto more rows.
        let wide = try height(1)
        window.setContentSize(NSSize(width: 480, height: 3_000))
        settle()
        XCTAssertGreaterThan(try height(1), wide)
    }

    // MARK: Following

    func testFollowedOutputStaysAtTheEnd() throws {
        var messages = TranscriptListFixtures.longSession(rounds: 60)
        show(messages)
        for round in 0..<30 {
            messages.append(Message(kind: .thought, text: TranscriptListFixtures.thought(round)))
            apply(messages)
            messages.append(Message(kind: .tool, text: "Run `make test`", toolID: "later-\(round)", status: "in_progress", detail: ""))
            apply(messages)
            messages[messages.count - 1].status = "completed"
            messages[messages.count - 1].detail = TranscriptListFixtures.toolOutput
            messages.append(Message(kind: .assistant, text: round % 5 == 0 ? TranscriptListFixtures.everyFormat : "Round \(round) is done."))
            apply(messages)
            XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1, "round \(round): the end is in sight")
        }
        XCTAssertTrue(list.isFollowing)
    }

    func testAStreamingReplyKeepsItsEndInSight() throws {
        var messages = TranscriptListFixtures.longSession(rounds: 20)
        show(messages)
        messages.append(Message(kind: .assistant, text: ""))
        display.streamingID = messages.last?.id
        display.status = "Working…"
        let reply = TranscriptListFixtures.everyFormat + "\n\n" + MarkdownTestDocuments.mixed(bytes: 4_000)
        var times: [Double] = []
        var offset = reply.startIndex
        while offset < reply.endIndex {
            let next = reply.index(offset, offsetBy: 24, limitedBy: reply.endIndex) ?? reply.endIndex
            messages[messages.count - 1].text += reply[offset..<next]
            offset = next
            times.append(frame { list.apply(messages: messages, display: display) })
            XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1, "the end of the reply is in sight as it grows")
        }
        print(String(format: "PERF transcript list: streaming a %d-byte reply in %d updates, update p50 %.1f p95 %.1f max %.1f ms",
                     reply.utf8.count, times.count, Self.percentile(times, 50), Self.percentile(times, 95), times.max() ?? 0))
        display.streamingID = nil
        display.status = nil
        apply(messages)
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1, "and when it has ended")
    }

    func testToolCallsShowWhetherTheyAreAtWork() throws {
        var messages = Array(TranscriptListFixtures.longSession(rounds: 2))
        messages.append(Message(kind: .tool, text: "Run `make test`", toolID: "running", status: "in_progress", detail: ""))
        messages.append(Message(kind: .tool, text: "Read `Package.swift`", toolID: "waiting", status: "pending", detail: ""))
        display.status = "Working…"
        show(messages)
        func tone(_ index: Int) throws -> TranscriptToolRow.Tone? {
            try XCTUnwrap(list.rowView(for: messages[index].id) as? TranscriptToolRow, "the call has a row").tone
        }
        let running = messages.count - 2, waiting = messages.count - 1
        XCTAssertEqual(try tone(running), .running, "an unfinished call spins while its turn runs")
        XCTAssertEqual(try tone(waiting), .running)
        let height = try XCTUnwrap(list.rowFrame(for: messages[running].id)).height

        messages[running].status = "completed"
        messages[waiting].status = "failed"
        apply(messages)
        XCTAssertEqual(try tone(running), .completed)
        XCTAssertEqual(try tone(waiting), .failed)
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: messages[running].id)).height, height, "finishing does not move what follows")

        // A turn that ends with a call unfinished, as a stop does, leaves it still.
        messages.append(Message(kind: .tool, text: "Run `sleep 60`", toolID: "stopped", status: "in_progress", detail: ""))
        apply(messages)
        let stopped = messages.count - 1
        XCTAssertEqual(try tone(stopped), .running)
        display.status = nil
        apply(messages)
        XCTAssertEqual(try tone(stopped), .idle)
        XCTAssertEqual(try tone(running), .completed, "finished calls keep their colour after the turn")
    }

    func testReasoningStreamsFoldedThenOpen() throws {
        var messages = Array(TranscriptListFixtures.longSession(rounds: 3))
        show(messages)
        messages.append(Message(kind: .thought, text: ""))
        let id = try XCTUnwrap(messages.last?.id)
        display.streamingID = id
        display.status = "Thinking…"
        let text = MarkdownTestDocuments.thinking(lines: 40)
        var heights: [CGFloat] = []
        for end in stride(from: 40, through: text.count, by: 40) {
            messages[messages.count - 1].text = String(text.prefix(end))
            apply(messages)
            heights.append(try XCTUnwrap(list.rowFrame(for: id)).height)
        }
        // Folded, the block shows four lines of its newest reasoning and no more, however much arrives.
        let tallest = try XCTUnwrap(heights.max())
        XCTAssertLessThanOrEqual(tallest, TranscriptFoldHeader.minHeight + ThoughtPreview.height + 20)
        XCTAssertEqual(heights.last, tallest, "it stays as tall once its glimpse is full")
        display.expanded = [id]
        apply(messages)
        XCTAssertGreaterThan(try XCTUnwrap(list.rowFrame(for: id)).height, tallest, "opened, it shows its text, up to its cap")
        display.streamingID = nil
        display.status = nil
        display.expanded = []
        apply(messages)
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: id)).height, TranscriptFoldHeader.minHeight, "finished and folded, it is its header")
    }

    // MARK: What stays put

    func testRowsArrivingUnderAReaderWhoScrolledUpDoNotMoveTheView() throws {
        var messages = TranscriptListFixtures.longSession(rounds: 60)
        show(messages)
        scroll(200, times: 8)
        XCTAssertFalse(list.isFollowing, "scrolled up, the output is not followed")
        XCTAssertGreaterThan(distanceFromEnd, 800)
        let top = try XCTUnwrap(list.topVisibleRow)
        let id = messages[top].id
        let before = try screenTop(of: id)
        for round in 0..<20 {
            messages.append(Message(kind: .tool, text: "Run `make test`", toolID: "later-\(round)", status: "completed", detail: TranscriptListFixtures.toolOutput))
            messages.append(Message(kind: .assistant, text: TranscriptListFixtures.everyFormat))
            apply(messages)
        }
        XCTAssertEqual(try screenTop(of: id), before, accuracy: 0.5, "what the reader is looking at has not moved")
        XCTAssertFalse(list.isFollowing)
        // Back at the end, the output is followed again.
        scroll(-4_000, times: 12)
        XCTAssertTrue(list.isFollowing, "scrolled back to the end: \(distanceFromEnd) from it")
        messages.append(Message(kind: .assistant, text: "One more."))
        apply(messages)
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1)
    }

    func testScrollingUpThroughRowsNeverLaidOutKeepsTheRowsInSightStill() throws {
        // Every reply here is tall and unlike its estimate, so each row that scrolls in changes the height above.
        let messages = (0..<300).flatMap { round -> [Message] in
            [Message(kind: .user, text: "Prompt \(round)"),
             Message(kind: .assistant, text: round % 2 == 0 ? TranscriptListFixtures.everyFormat : MarkdownTestDocuments.mixed(bytes: 1_500 + round * 7))]
        }
        show(messages)
        var jumps: [CGFloat] = []
        for _ in 0..<60 {
            let top = try XCTUnwrap(list.topVisibleRow)
            let id = messages[top].id
            let before = try screenTop(of: id)
            scroll(180)
            // The row that was first in sight moved down by what was scrolled, and by nothing else.
            jumps.append(abs(try screenTop(of: id) - before - 180))
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(jumps.max()), 1, "rows measured as they scroll in do not move the rows in sight")
        XCTAssertFalse(list.isFollowing)
    }

    func testJumpingToAMessageFarAwayPutsItsTopAtTheTop() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        show(messages)
        // A reply in the middle of the task, where nothing has been laid out.
        for index in [7_501, 40, 14_990, 0, 9_000] {
            let id = messages[index].id
            list.perform(TranscriptScrollRequest(serial: index, target: .message(id)))
            settle()
            let expected: CGFloat = index == 14_990 ? try screenTop(of: id) : 0
            XCTAssertEqual(try screenTop(of: id), expected, accuracy: 0.5, "message \(index) is at the top")
            XCTAssertNotNil(list.rowView(for: id), "and has its view")
            XCTAssertFalse(list.isFollowing)
            XCTAssertLessThan(list.realizedRowCount, 80)
        }
        XCTAssertEqual(list.topVisibleRow, 9_000)
        list.perform(TranscriptScrollRequest(serial: -1, target: .bottom))
        settle()
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1)
        XCTAssertTrue(list.isFollowing)
    }

    func testOpeningABlockKeepsItWhereItWas() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 40)
        show(messages)
        scroll(200, times: 3)
        let index = try XCTUnwrap((0..<messages.count).last { messages[$0].kind == .tool && list.rowView(for: messages[$0].id) != nil && (try? screenTop(of: messages[$0].id)).map { $0 > 60 && $0 < 400 } == true })
        let id = messages[index].id
        let before = try screenTop(of: id), folded = try XCTUnwrap(list.rowFrame(for: id)).height
        list.setExpanded(id, true)
        settle()
        XCTAssertEqual(try screenTop(of: id), before, accuracy: 0.5, "the block opens where it was clicked")
        XCTAssertGreaterThan(try XCTUnwrap(list.rowFrame(for: id)).height, folded + 20)
        list.setExpanded(id, false)
        settle()
        XCTAssertEqual(try screenTop(of: id), before, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: id)).height, folded)
    }

    // MARK: Clicks

    /// The middle of a block's header, in the window.
    private func headerCenter(of id: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let row = try XCTUnwrap(list.rowView(for: id), "the row is in sight", file: file, line: line)
        let header = try XCTUnwrap(row.subviews.first { $0 is TranscriptFoldHeader }, "the row has a header", file: file, line: line)
        return header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
    }

    /// A click as the window gets it: the window finds the view under it, which gets the mouse going down and up.
    /// A window takes clicks only on screen, so it is ordered in under the desktop, where nobody sees it.
    private func click(at point: NSPoint) throws {
        if !window.isVisible {
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.orderFrontRegardless()
        }
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (NSEvent.EventType.leftMouseUp, Float(0))] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)))
        }
        settle()
    }

    func testClickingAHeaderOpensAndClosesItsBlock() throws {
        // Reasoning that has finished, and commands that completed, are running, failed, and wait to run.
        let messages = TranscriptListFixtures.showcase()
        show(messages, size: NSSize(width: 900, height: 6_000))
        let frameView = try XCTUnwrap(window.contentView?.superview)
        for message in messages where message.kind == .thought || message.kind == .tool {
            let id = message.id, folded = try XCTUnwrap(list.rowFrame(for: id)).height
            let point = try headerCenter(of: id)
            XCTAssertTrue(frameView.hitTest(point) is TranscriptFoldHeader, "a click on the header of “\(message.text.prefix(24))” reaches the header")
            try click(at: point)
            XCTAssertEqual(list.rowView(for: id)?.model.isExpanded, true, "a click opens “\(message.text.prefix(24))”")
            XCTAssertGreaterThan(try XCTUnwrap(list.rowFrame(for: id)).height, folded + 10)
            try click(at: try headerCenter(of: id))
            XCTAssertEqual(list.rowView(for: id)?.model.isExpanded, false, "and another closes it")
            XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: id)).height, folded)
        }
    }

    func testReasoningOpensAndClosesByItsHeaderWhileItStreamsAndOnceItHasEnded() throws {
        var messages = TranscriptListFixtures.longSession(rounds: 20)
        show(messages)
        messages.append(Message(kind: .thought, text: MarkdownTestDocuments.thinking(lines: 12)))
        let id = try XCTUnwrap(messages.last?.id)
        display.streamingID = id
        display.status = "Thinking…"
        apply(messages)
        try click(at: try headerCenter(of: id))
        XCTAssertEqual(list.rowView(for: id)?.model.isExpanded, true, "while it streams, a click opens it")
        // The transcript model gives the list back what was clicked open.
        display.expanded = [id]
        display.streamingID = nil
        display.status = nil
        apply(messages)
        let open = try XCTUnwrap(list.rowFrame(for: id)).height
        try click(at: try headerCenter(of: id))
        XCTAssertEqual(list.rowView(for: id)?.model.isExpanded, false, "once it has ended, a click closes it")
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: id)).height, TranscriptFoldHeader.minHeight)
        display.expanded = []
        try click(at: try headerCenter(of: id))
        XCTAssertEqual(list.rowView(for: id)?.model.isExpanded, true, "and another opens it again")
        XCTAssertEqual(try XCTUnwrap(list.rowFrame(for: id)).height, open, accuracy: 0.5)
    }

    func testATranscriptThatWasReplacedShowsItsNewRows() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 50)
        show(messages)
        // A rewind: the task loses its last rounds.
        let shorter = Array(messages.prefix(120))
        apply(shorter)
        XCTAssertEqual(list.rowCount, 120)
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1)
        XCTAssertNil(list.rowView(for: messages[200].id), "rows that went away have no views")
        // A reload: the same rounds come back as other messages.
        let reloaded = TranscriptListFixtures.longSession(rounds: 50)
        apply(reloaded)
        XCTAssertEqual(list.rowCount, reloaded.count)
        XCTAssertNotNil(list.rowView(for: try XCTUnwrap(reloaded.last).id))
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1)
        // Another task.
        display.conversation = UUID()
        apply(TranscriptListFixtures.showcase())
        XCTAssertEqual(list.rowCount, 12)
        XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1)
    }

    func testAnUpdateFarUpALongTranscriptIsFoundFromWhereTheStoreSaysItFirstChanged() throws {
        var messages = TranscriptListFixtures.longSession(rounds: 200)
        show(messages)
        func shown(_ index: Int) throws -> Message {
            list.perform(TranscriptScrollRequest(serial: index, target: .message(messages[index].id)))
            settle()
            return try XCTUnwrap(list.rowView(for: messages[index].id), "row \(index) is in sight").model.message
        }
        // A command near the start finishes while the task's last reply grows: the first of the two is message 3.
        XCTAssertEqual(messages[3].kind, .tool)
        messages[3].status = "failed"
        messages[3].detail = "error: linking failed"
        messages[messages.count - 1].text += " And one more thing."
        list.apply(messages: messages, display: display, unchangedBefore: 3)
        settle()
        XCTAssertEqual(try shown(3).status, "failed")
        XCTAssertEqual(try shown(3).detail, "error: linking failed")
        XCTAssertTrue(try shown(messages.count - 1).text.hasSuffix("And one more thing."))
        // The messages before it are taken on trust, which is the saving: thousands of them are not compared for every update.
        messages[1].text = "Changed, but before where the list was told to look."
        list.apply(messages: messages, display: display, unchangedBefore: 3)
        settle()
        XCTAssertNotEqual(try shown(1).text, messages[1].text)
        // Told nothing, it compares them all.
        apply(messages)
        XCTAssertEqual(try shown(1).text, messages[1].text)
        // A count that is for another transcript is not trusted: the last of the messages it vouches for is another message.
        var reloaded = TranscriptListFixtures.longSession(rounds: 200)
        reloaded[5].text = "Reloaded."
        messages = reloaded
        list.apply(messages: messages, display: display, unchangedBefore: 500)
        settle()
        XCTAssertEqual(list.rowCount, messages.count)
        XCTAssertEqual(try shown(5).text, "Reloaded.")
    }

    // MARK: The window's size

    func testAFollowedTranscriptStaysAtItsEndAtEverySize() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        show(messages)
        var times: [Double] = []
        // Dragged narrower and wider, then to a screen's size and back, as entering and leaving full screen does.
        var sizes: [NSSize] = []
        for step in 0..<40 { sizes.append(NSSize(width: 900 - CGFloat(step) * 9, height: 700 - CGFloat(step % 7) * 11)) }
        for step in 0..<40 { sizes.append(NSSize(width: 540 + CGFloat(step) * 22, height: 640 + CGFloat(step) * 7)) }
        sizes += [NSSize(width: 2_560, height: 1_440), NSSize(width: 900, height: 700), NSSize(width: 1_728, height: 1_117), NSSize(width: 560, height: 650)]
        for size in sizes {
            times.append(frame { window.setContentSize(size) })
            XCTAssertLessThanOrEqual(abs(distanceFromEnd), 1, "at \(size) the end is in sight")
            XCTAssertEqual(list.topVisibleRow.map { $0 > messages.count - 60 }, true, "and its newest rows are")
            XCTAssertLessThan(list.realizedRowCount, 140)
        }
        print(String(format: "PERF transcript list: %d window sizes over %d messages, frame p50 %.1f p95 %.1f max %.1f ms",
                     sizes.count, messages.count, Self.percentile(times, 50), Self.percentile(times, 95), times.max() ?? 0))
        XCTAssertTrue(list.isFollowing)
    }

    func testAReaderInTheMiddleKeepsTheirPlaceAtEverySize() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        show(messages)
        let id = messages[6_001].id
        list.perform(TranscriptScrollRequest(serial: 1, target: .message(id)))
        settle()
        for size in [NSSize(width: 700, height: 700), NSSize(width: 560, height: 650), NSSize(width: 2_560, height: 1_440), NSSize(width: 900, height: 700), NSSize(width: 1_728, height: 1_117)] {
            window.setContentSize(size)
            settle()
            XCTAssertEqual(try screenTop(of: id), 0, accuracy: 0.5, "at \(size) the message the reader was at is still at the top")
            XCTAssertEqual(list.topVisibleRow, 6_001)
        }
        XCTAssertFalse(list.isFollowing)
    }

    func testWhatCoversTheTopKeepsTheRowsClearOfIt() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 30)
        show(messages)
        let id = messages[40].id
        list.perform(TranscriptScrollRequest(serial: 1, target: .message(id)))
        settle()
        // The find bar opens over the top of the list: the message moves down from under it.
        list.coveredTop = 62
        apply(messages)
        XCTAssertEqual(try screenTop(of: id), 62, accuracy: 0.5)
        list.coveredTop = 0
        apply(messages)
        XCTAssertEqual(try screenTop(of: id), 0, accuracy: 0.5)
        // At its very top a transcript rests with its first row under what covers it, and its padding.
        list.coveredTop = 62
        apply(messages)
        scroll(1_000_000)
        XCTAssertEqual(clip.minY, -62, accuracy: 0.5)
        XCTAssertEqual(try screenTop(of: messages[0].id), 62 + TranscriptMetrics.topPadding, accuracy: 0.5)
    }

    // MARK: A long task, end to end

    func testWhatARowCostsToBringIntoSight() throws {
        show([])
        func cost(_ name: String, _ message: Message, expanded: Bool = false) {
            var made: [Double] = [], measured: [Double] = [], placed: [Double] = []
            for _ in 0..<12 {
                let model = TranscriptRowModel(message: Message(kind: message.kind, text: message.text, status: message.status, detail: message.detail), isExpanded: expanded)
                var row: TranscriptRowView!
                made.append(Self.milliseconds { row = TranscriptRowView.make(model, list: nil, in: list, width: 800) })
                var height: CGFloat = 0
                measured.append(Self.milliseconds { height = row.height(forWidth: 800) })
                placed.append(Self.milliseconds {
                    row.frame = NSRect(x: 0, y: 0, width: 800, height: height)
                    row.arrange()
                    row.layoutSubtreeIfNeeded()
                    row.displayIfNeeded()
                })
                row.removeFromSuperview()
            }
            print(String(format: "PERF transcript row, %@: made %.2f ms, measured %.2f ms, placed and drawn %.2f ms (medians of 12)", name,
                         Self.percentile(made, 50), Self.percentile(measured, 50), Self.percentile(placed, 50)))
        }
        cost("folded reasoning", Message(kind: .thought, text: TranscriptListFixtures.thought(2)))
        cost("open reasoning, pages long", Message(kind: .thought, text: TranscriptListFixtures.thought(2)), expanded: true)
        cost("folded command", Message(kind: .tool, text: "Run `cargo test -p crate_7`", status: "completed", detail: TranscriptListFixtures.toolOutput))
        cost("open command, 600 lines", Message(kind: .tool, text: "Run `cargo test -p crate_7`", status: "completed", detail: String(repeating: TranscriptListFixtures.toolOutput + "\n", count: 15)), expanded: true)
        cost("prompt", Message(kind: .user, text: "Run the whole suite, fix what fails, repeat."))
        cost("short reply", Message(kind: .assistant, text: "Round 7 passed: **40 tests** in `crate_7`. Next I will look at `module_3.rs`."))
        cost("reply in every format", Message(kind: .assistant, text: TranscriptListFixtures.everyFormat))
        cost("reply of 6 kB", Message(kind: .assistant, text: MarkdownTestDocuments.mixed(bytes: 6_000)))
    }

    func testScrollingThroughALongSessionFromItsEndToItsStart() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        show(messages)
        var times: [Double] = []
        var steps = 0
        // Most of a page at a time, as holding Page Up does, through every row. Rows that come
        // into sight are laid out for the first time, and what was in sight moves by the scroll alone.
        var jumps = 0
        while clip.minY > 0.5, steps < 20_000 {
            let last = try XCTUnwrap(list.topVisibleRow, "step \(steps): rows are in sight")
            let id = messages[last].id
            let before = try screenTop(of: id), origin = clip.minY
            times.append(frame {
                let clip = list.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 600))
            })
            steps += 1
            // At the very start of the task the scroll stops short.
            if origin >= 600, abs(try screenTop(of: id) - before - 600) > 1 { jumps += 1 }
        }
        XCTAssertEqual(jumps, 0, "no step moved the rows in sight by anything but the scroll")
        XCTAssertEqual(list.topVisibleRow, 0, "the start of the task is reached")
        XCTAssertEqual(list.measuredRowCount, messages.count, "by then every row has been laid out")
        print(String(format: "PERF transcript list: scrolled %d messages in %d steps, step p50 %.1f p95 %.1f p99 %.1f max %.1f ms, total %.1f s",
                     messages.count, steps, Self.percentile(times, 50), Self.percentile(times, 95), Self.percentile(times, 99), times.max() ?? 0, times.reduce(0, +) / 1000))
        XCTAssertLessThan(list.realizedRowCount, 80)
    }
}
