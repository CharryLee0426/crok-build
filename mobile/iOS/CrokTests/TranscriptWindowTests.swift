import XCTest

@testable import Crok

/// The transcript window over `sessions:transcript` (relay/DESIGN.md §3 "Loading long transcripts"): opening on the
/// newest items, the live end, splitting it, older parts, and starting over after a burst or a replaced transcript.
@MainActor
final class TranscriptWindowTests: XCTestCase {
    /// Answers `sessions:transcript` as the relay does, from `events`; `flush()` re-sends every live query's answer.
    @MainActor
    final class FakeRelay {
        var events: [TranscriptEvent] = []
        /// Every range ever asked for, in order.
        private(set) var asked: [TranscriptRange] = []
        private var streams: [Int: (TranscriptRange, RelayStream<TranscriptChunk>.Continuation)] = [:]
        private var nextStream = 0

        var open: [TranscriptRange] { streams.keys.sorted().map { streams[$0]!.0 } }

        func add(_ count: Int, text: String = "reply", kind: EventKind = .assistant) {
            let start = (events.map(\.seq).max() ?? 0) + 1
            for seq in Int(start)..<(Int(start) + count) {
                events.append(
                    TranscriptEvent(
                        id: "e\(seq)", seq: Double(seq), key: "k\(seq)", kind: kind, text: text, at: Double(seq) * 1000))
            }
        }

        func chunk(_ range: TranscriptRange) -> TranscriptChunk {
            let inRange = events
                .filter { e in (range.afterSeq.map { e.seq > $0 } ?? true) && (range.throughSeq.map { e.seq <= $0 } ?? true) }
                .sorted { $0.seq > $1.seq }
            var picked: [TranscriptEvent] = []
            var text = 0
            for event in inRange.prefix(range.limit) {
                if !picked.isEmpty && text + event.text.utf16.count > 400_000 { break }
                text += event.text.utf16.count
                picked.append(event)
            }
            return TranscriptChunk(events: picked, more: inRange.count > picked.count)
        }

        func make(_ range: TranscriptRange) -> RelayStream<TranscriptChunk> {
            asked.append(range)
            let id = nextStream
            nextStream += 1
            return AsyncThrowingStream { continuation in
                streams[id] = (range, continuation)
                continuation.onTermination = { _ in Task { @MainActor in self.streams[id] = nil } }
                continuation.yield(chunk(range))
            }
        }

        func flush() {
            for (range, continuation) in streams.values { continuation.yield(chunk(range)) }
        }
    }

    private var relay: FakeRelay!
    private var window: TranscriptWindow!

    override func setUp() async throws {
        relay = FakeRelay()
    }

    override func tearDown() async throws {
        window?.stop()
        window = nil
    }

    private func start() {
        let relay = self.relay!
        window = TranscriptWindow(engine: nil) { range in relay.make(range) }
        window.start()
    }

    /// Waits until `condition` holds, checking every 10 ms; returns whether it did.
    private func eventually(_ timeout: Double = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// No part waits for its first answer and nothing is being replaced.
    private func settled() async throws -> Bool {
        try await eventually {
            window.retiring.isEmpty && window.parts.allSatisfy { $0.chunk != nil } && !window.parts.contains { $0.role == .opening }
        }
    }

    private var shownSeqs: [Double] { window.events.values.map(\.seq).sorted() }

    func testOpensOnTheNewestAndKeepsALiveEndFromThere() async throws {
        relay.add(100)
        start()
        let ready = try await settled()
        XCTAssertTrue(ready)
        XCTAssertEqual(relay.asked.first, TranscriptRange(limit: 40))
        XCTAssertEqual(shownSeqs, (61...100).map(Double.init))
        XCTAssertTrue(window.hasOlder)
        XCTAssertTrue(window.loaded)
        // The opening query is gone; the live end runs from the oldest item shown.
        let handedOver = try await eventually { self.relay.open == [TranscriptRange(afterSeq: 60, limit: 200)] }
        XCTAssertTrue(handedOver, "\(relay.open)")

        relay.add(3)
        relay.flush()
        let grew = try await eventually { self.shownSeqs.last == 103 }
        XCTAssertTrue(grew)
        XCTAssertEqual(shownSeqs.count, 43, "nothing slides out of the window")
    }

    func testTheLiveEndSplitsWhenItHoldsTooManyItems() async throws {
        relay.add(40)
        start()
        var ready = try await settled()
        XCTAssertTrue(ready)
        relay.add(45)  // 85 in the live end: more than 80
        relay.flush()
        ready = try await eventually { self.window.parts.count == 2 && self.window.retiring.isEmpty }
        XCTAssertTrue(ready)
        let split = try await eventually {
            Set(self.relay.open)
                == [TranscriptRange(afterSeq: 45, limit: 200), TranscriptRange(afterSeq: 0, throughSeq: 45, limit: 200)]
        }
        XCTAssertTrue(split, "the newest 40 stay live; the rest is a fixed part: \(relay.open)")
        XCTAssertEqual(shownSeqs, (1...85).map(Double.init), "every item still shows")

        // A streamed reply re-sends only the live end now: the fixed part's range ends below it.
        XCTAssertEqual(window.parts.first?.role, .live)
        XCTAssertEqual(window.parts.first?.range.afterSeq, 45)
    }

    func testTheLiveEndSplitsWhenItHoldsTooMuchText() async throws {
        let long = String(repeating: "x", count: 30_000)
        relay.add(4, text: long)
        start()
        var ready = try await settled()
        XCTAssertTrue(ready)
        relay.add(4, text: long)  // 240 000 characters in 8 items
        relay.flush()
        ready = try await eventually { self.window.parts.count == 2 && self.window.retiring.isEmpty }
        XCTAssertTrue(ready)
        let live = try XCTUnwrap(window.parts.first)
        XCTAssertEqual(live.role, .live)
        XCTAssertEqual(live.chunk?.events.count, 4, "half the text stays live")
        XCTAssertEqual(shownSeqs, (1...8).map(Double.init))
    }

    func testOlderPartsLoadUntilTheBeginning() async throws {
        relay.add(130)
        start()
        var ready = try await settled()
        XCTAssertTrue(ready)
        window.loadOlder()
        XCTAssertTrue(window.isLoadingOlder)
        ready = try await eventually { !self.window.isLoadingOlder }
        XCTAssertTrue(ready)
        XCTAssertEqual(relay.asked.last, TranscriptRange(throughSeq: 90, limit: 60))
        XCTAssertEqual(shownSeqs, (31...130).map(Double.init))
        XCTAssertTrue(window.hasOlder)
        window.loadOlder()
        ready = try await eventually { !self.window.isLoadingOlder && !self.window.hasOlder }
        XCTAssertTrue(ready, "the beginning of the session")
        XCTAssertEqual(shownSeqs, (1...130).map(Double.init))
        window.loadOlder()
        XCTAssertFalse(window.isLoadingOlder, "nothing older to ask for")
    }

    func testABurstLargerThanTheLiveEndStartsOver() async throws {
        relay.add(10)
        start()
        var ready = try await settled()
        XCTAssertTrue(ready)
        relay.add(250)  // the phone slept through a busy turn
        relay.flush()
        ready = try await eventually { self.window.restarts == 1 }
        XCTAssertTrue(ready)
        ready = try await settled()
        XCTAssertTrue(ready)
        XCTAssertEqual(shownSeqs, (221...260).map(Double.init), "the newest again")
        XCTAssertTrue(window.hasOlder)
    }

    func testAReplacedTranscriptStartsOver() async throws {
        relay.add(100)
        start()
        var ready = try await settled()
        XCTAssertTrue(ready)
        window.loadOlder()
        ready = try await eventually { !self.window.isLoadingOlder }
        XCTAssertTrue(ready)
        // The computer resyncs: every item goes, new ones follow from the next seq.
        relay.events.removeAll()
        for seq in 101...120 {
            relay.events.append(
                TranscriptEvent(id: "r\(seq)", seq: Double(seq), key: "k\(seq)", kind: .assistant, text: "again", at: 0))
        }
        relay.flush()
        ready = try await eventually { self.window.restarts >= 1 }
        XCTAssertTrue(ready)
        ready = try await settled()
        XCTAssertTrue(ready)
        XCTAssertEqual(shownSeqs, (101...120).map(Double.init))
        XCTAssertFalse(window.hasOlder)
    }

    func testAnEmptySessionWaitsForItsFirstItems() async throws {
        start()
        var ready = try await eventually { self.window.loaded }
        XCTAssertTrue(ready)
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertFalse(window.hasOlder)
        relay.add(2)
        relay.flush()
        ready = try await settled()
        XCTAssertTrue(ready)
        XCTAssertEqual(shownSeqs, [1, 2])
        ready = try await eventually { self.relay.open == [TranscriptRange(afterSeq: 0, limit: 200)] }
        XCTAssertTrue(ready, "\(relay.open)")
    }

    /// A tool call's row: running only while the turn runs, stopped after it (mobile/DESIGN.md "Thinking and tool
    /// calls").
    func testToolRowStates() {
        XCTAssertEqual(ToolRowState(.inProgress, turnRunning: true), .running)
        XCTAssertEqual(ToolRowState(.pending, turnRunning: true), .running)
        XCTAssertEqual(ToolRowState(.inProgress, turnRunning: false), .stopped)
        XCTAssertEqual(ToolRowState(.pending, turnRunning: false), .stopped)
        XCTAssertEqual(ToolRowState(.completed, turnRunning: true), .completed)
        XCTAssertEqual(ToolRowState(.failed, turnRunning: false), .failed)
        XCTAssertEqual(ToolRowState(ToolStatus("weird"), turnRunning: true), .other)
    }

    /// Status only: a thought has no text, a tool keeps its title (or its detail's first line, or "Tool call").
    func testThoughtsAndToolsAreStatusOnlyItems() {
        let thought = TranscriptEvent(id: "t", seq: 1, key: "t", kind: .thought, text: "", at: 0)
        XCTAssertEqual(TranscriptBuilder.item(for: thought, command: nil)?.kind, .thought)
        let titled = TranscriptEvent(
            id: "a", seq: 2, key: "a", kind: .tool, text: "", title: "Execute `git status`", toolKind: "execute",
            status: "completed", at: 0)
        XCTAssertEqual(
            TranscriptBuilder.item(for: titled, command: nil)?.kind,
            .tool(ToolCall(title: "Execute `git status`", toolKind: "execute", status: .completed)))
        let untitled = TranscriptEvent(id: "b", seq: 3, key: "b", kind: .tool, text: "", at: 0)
        guard case .tool(let call) = TranscriptBuilder.item(for: untitled, command: nil)?.kind else {
            return XCTFail("a tool item")
        }
        XCTAssertEqual(call.title, "Tool call")
        XCTAssertEqual(call.toolKind, "other")
    }

    /// `code` spans in a tool title are monospaced; an unpaired backtick stays text.
    func testToolTitleCodeSpans() {
        let title = ToolTitle.attributed("Execute `git status` now")
        XCTAssertEqual(String(title.characters), "Execute \u{2009}git status\u{2009} now")
        let code = title.runs.filter { $0.font != nil }
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(String(ToolTitle.attributed("Odd ` tick").characters), "Odd ` tick")
    }

    /// A long reply reveals in steps of a hundredth of its length (the Markdown cache then parses each step once).
    func testLongRepliesRevealInSteps() {
        XCTAssertEqual(SessionViewModel.revealStep(1_234, of: 1_500), 1_234, "short replies: every character")
        XCTAssertEqual(SessionViewModel.revealStep(12_345, of: 30_000), 12_300)
        let steps = Set((0...30_000).map { SessionViewModel.revealStep($0, of: 30_000) })
        XCTAssertLessThanOrEqual(steps.count, 101)
    }

    /// Thoughts and tool calls come without their text; a tool without a title is named by its detail's first line.
    func testTheDemoRelayAnswersLikeTheRelay() throws {
        let world = DemoWorld()
        let id = try XCTUnwrap(world.sessions.first(where: { $0.events.contains { $0.kind == .tool } })?.detail.id)
        let chunk = try world.transcript(id, range: TranscriptRange(limit: 200))
        XCTAssertFalse(chunk.events.isEmpty)
        for event in chunk.events where event.kind == .thought || event.kind == .tool {
            XCTAssertEqual(event.text, "")
        }
        XCTAssertTrue(chunk.events.filter { $0.kind == .tool }.allSatisfy { !($0.title ?? "").isEmpty })
        XCTAssertEqual(chunk.events.map(\.seq), chunk.events.map(\.seq).sorted(by: >), "newest first")
    }
}
