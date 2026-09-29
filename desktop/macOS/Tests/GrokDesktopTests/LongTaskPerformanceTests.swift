import XCTest
@testable import GrokDesktop

/// Tasks that run for hours: thousands of rounds of reasoning, tool calls, and replies.
///
/// The PERF lines are the numbers the long-task report quotes; run them optimized with
/// `swift test -c release --filter LongTask`. Time bounds are asserted only in optimized
/// builds and leave several times the measured headroom. The end-to-end scenarios (a live
/// app, measured from outside) are in `scripts/perf/run-perf.sh`.
@MainActor
final class LongTaskPerformanceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-long-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var stateFile: URL { directory.appendingPathComponent("state.json") }

    // MARK: Fixtures

    /// The session updates of one round, chunked as a model streams them (the `fixture:long`
    /// round of `mock-grok.py`).
    static func round(_ index: Int) -> [[String: Any]] {
        let thought = "Round \(index + 1): the last run of `crate_\(index % 37)` left \(index % 5) warnings. Checking whether the change in `src/lib.rs` explains them before touching the tests."
        let output = (0..<40).map { "test crate_\(index % 37)::case_\($0) ... ok (\((index * 7 + $0) % 90) ms)" }.joined(separator: "\n")
        let reply = "Round \(index + 1) passed: **40 tests**. Next I will look at `module_\(index % 11).rs`:\n\n- keep the fixture offline\n\n```rust\nfn round_\(index)() -> usize { \(index) }\n```"
        func chunks(_ text: String, _ kind: String) -> [[String: Any]] {
            stride(from: 0, to: text.count, by: 24).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: min(24, text.count - offset))
                return ["sessionUpdate": kind, "content": ["type": "text", "text": String(text[start..<end])]]
            }
        }
        let tool = "long-tool-\(index)"
        return chunks(thought, "agent_thought_chunk")
            + [["sessionUpdate": "tool_call", "toolCallId": tool, "title": "Run `cargo test`", "status": "in_progress"],
               ["sessionUpdate": "tool_call_update", "toolCallId": tool, "status": "completed",
                "content": [["type": "content", "content": ["type": "text", "text": output]]]]]
            + chunks(reply, "agent_message_chunk")
    }

    /// A finished long task: a prompt, then `rounds` rounds of three messages.
    static func transcript(rounds: Int) -> [Message] {
        var messages = [Message(kind: .user, text: "Run the whole suite, fix what fails, repeat.")]
        for index in 0..<rounds { for update in round(index) { TranscriptReducer.apply(update, to: &messages) } }
        return messages
    }

    private func store(with messages: [Message]) -> (AppStore, UUID) {
        let store = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Long task", sessionID: "long", messages: messages)
        store.state.projects = [project]
        store.state.conversations = [task] + (0..<30).map { Conversation(projectID: project.id, title: "Short \($0)", messages: Self.transcript(rounds: 3)) }
        store.state.selectedProjectID = project.id
        store.state.selectedConversationID = task.id
        return (store, task.id)
    }

    private static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static var isOptimized: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    // MARK: Streaming

    /// Each round costs the same at round 3,000 as at round 1: finding the tool call a result
    /// belongs to no longer searches the whole transcript.
    func testStreamingCostDoesNotGrowWithTheTranscript() {
        let updates = (0..<3_000).map(Self.round)
        var messages: [Message] = []
        var first = 0.0, last = 0.0
        let total = Self.milliseconds {
            for (index, round) in updates.enumerated() {
                let time = Self.milliseconds { for update in round { TranscriptReducer.apply(update, to: &messages) } }
                if index < 300 { first += time }
                if index >= 2_700 { last += time }
            }
        }
        XCTAssertEqual(messages.count, 9_000)
        XCTAssertEqual(messages.filter { $0.kind == .tool }.count, 3_000)
        XCTAssertTrue(messages.filter { $0.kind == .tool }.allSatisfy { $0.status == "completed" && $0.detail?.isEmpty == false })
        print("PERF reduce 3,000 rounds: \(String(format: "%.0f", total)) ms; first 300 \(String(format: "%.1f", first)) ms, last 300 \(String(format: "%.1f", last)) ms")
        if Self.isOptimized {
            XCTAssertLessThan(total, 1_500)
            XCTAssertLessThan(last, first * 3 + 20, "a round late in the task costs about what an early one did")
        }
    }

    func testAToolUpdateStillFindsAnOldCall() {
        var messages = Self.transcript(rounds: 200)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "long-tool-3", "status": "failed"], to: &messages)
        XCTAssertEqual(messages.first { $0.toolID == "long-tool-3" }?.status, "failed")
        XCTAssertEqual(messages.count, 601, "an update never adds a row")
        // A repeated `tool_call` for a recent call updates it rather than adding a row.
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "long-tool-199", "title": "Retitled"], to: &messages)
        XCTAssertEqual(messages.count, 601)
        XCTAssertEqual(messages.last { $0.toolID == "long-tool-199" }?.text, "Retitled")
    }

    // MARK: Saving

    /// Saving while a long task streams writes the changed tail, not the whole history, and the
    /// state file no longer carries transcripts.
    func testSavingALongTaskWritesOnlyWhatChanged() throws {
        let (store, id) = store(with: Self.transcript(rounds: 3_000))
        let full = try Self.milliseconds { store.flush() }
        let file = TranscriptArchive(stateFile: stateFile).file(for: id)
        let written = try Data(contentsOf: file)
        XCTAssertLessThan(try Data(contentsOf: stateFile).count, 64_000, "the state file lists tasks without their messages")

        var tail: [Double] = []
        for round in 3_000..<3_020 {
            let index = store.state.conversations.firstIndex { $0.id == id }!
            var messages = store.state.conversations[index].messages
            for update in Self.round(round) { TranscriptReducer.apply(update, to: &messages) }
            store.state.conversations[index].messages = messages
            tail.append(Self.milliseconds { store.flush() })
        }
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after.prefix(written.count), written, "the lines already written stay as they were")
        let median = tail.sorted()[tail.count / 2]
        print("PERF save 9,001-message task: first \(String(format: "%.0f", full)) ms, then \(String(format: "%.1f", median)) ms per streamed round (\(written.count / 1_000) KB file)")
        if Self.isOptimized { XCTAssertLessThan(median, max(full / 5, 15)) }

        let reopened = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        let saved = reopened.state.conversations.first { $0.id == id }!.messages
        XCTAssertEqual(saved.count, 9_061)
        XCTAssertTrue(zip(saved, store.state.conversations.first { $0.id == id }!.messages).allSatisfy { TranscriptArchive.same($0.0, $0.1) })
    }

    /// The same saves with every transcript in one JSON file, as before: the reference the report
    /// compares against.
    func testWholeStateEncodingForReference() throws {
        let (store, _) = store(with: Self.transcript(rounds: 3_000))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        _ = try encoder.encode(store.state)
        var samples: [Double] = []
        for _ in 0..<5 { samples.append(try Self.milliseconds { _ = try encoder.encode(store.state) }) }
        let data = try encoder.encode(store.state)
        let decode = try Self.milliseconds { _ = try JSONDecoder().decode(DesktopState.self, from: data) }
        print("PERF whole-state JSON (v1.1 format), 9,001-message task: encode \(String(format: "%.0f", samples.sorted()[2])) ms per save, decode \(String(format: "%.0f", decode)) ms, \(data.count / 1_000) KB")
    }

    func testLaunchReadsTranscriptFiles() throws {
        let (store, id) = store(with: Self.transcript(rounds: 3_000))
        store.flush()
        let launch = Self.milliseconds { _ = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false") }
        let reopened = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(reopened.task(id)?.messages.count, 9_001)
        XCTAssertEqual(reopened.state.conversations.filter { $0.messages.count == 10 }.count, 30)
        print("PERF launch with a 9,001-message task: \(String(format: "%.0f", launch)) ms to load state and transcripts")
        if Self.isOptimized { XCTAssertLessThan(launch, 2_000) }
    }

    // MARK: The transcript archive

    func testAStateFileWithTranscriptsInsideLoadsAndMovesThemOut() throws {
        let messages = Self.transcript(rounds: 5)
        let project = Project(path: directory.path)
        var legacy = DesktopState()
        legacy.projects = [project]
        legacy.conversations = [Conversation(projectID: project.id, title: "Old", messages: messages)]
        try JSONEncoder().encode(legacy).write(to: stateFile)
        let store = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(store.state.conversations[0].messages.count, 16)
        store.flush()
        let slim = try JSONDecoder().decode(DesktopState.self, from: Data(contentsOf: stateFile))
        XCTAssertTrue(slim.conversations[0].messages.isEmpty)
        XCTAssertEqual(AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false").state.conversations[0].messages.map(\.text), messages.map(\.text))
    }

    func testALineCutShortByACrashIsDroppedAndTheFileRewritten() throws {
        let (store, id) = store(with: Self.transcript(rounds: 10))
        store.flush()
        let file = TranscriptArchive(stateFile: stateFile).file(for: id)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"id":"half a mess"#.utf8)); try handle.close()
        let reopened = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(reopened.task(id)?.messages.count, 31)
        reopened.append(Message(kind: .user, text: "Next"), to: id)
        reopened.flush()
        XCTAssertEqual(AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false").task(id)?.messages.last?.text, "Next")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }.count, 32)
    }

    func testDeletingATaskRemovesItsTranscript() throws {
        let (store, id) = store(with: Self.transcript(rounds: 2))
        store.flush()
        let file = TranscriptArchive(stateFile: stateFile).file(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        store.deleteConversation(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAShorterTranscriptTruncatesItsFile() throws {
        let (store, id) = store(with: Self.transcript(rounds: 20))
        store.flush()
        let index = store.state.conversations.firstIndex { $0.id == id }!
        store.state.conversations[index].messages.removeLast(30)
        store.flush()
        XCTAssertEqual(AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false").task(id)?.messages.count, 31)
    }

    // MARK: The transcript window

    func testALongTranscriptShowsItsNewestMessages() {
        var page = TranscriptPage()
        XCTAssertEqual(page.start(count: 0), 0)
        XCTAssertEqual(page.start(count: 100), 0)
        XCTAssertEqual(page.start(count: TranscriptPage.size + TranscriptPage.step - 1), 0)
        // Following output, at least `size` of the newest show, and the window moves on a step at a time.
        for count in [9_001, 9_050, 9_100, 9_119, 9_120, 9_121, 9_400] {
            let start = page.start(count: count)
            XCTAssertGreaterThanOrEqual(count - start, TranscriptPage.size, "count \(count)")
            XCTAssertLessThan(count - start, TranscriptPage.size + TranscriptPage.step, "count \(count)")
            XCTAssertEqual(start % TranscriptPage.step, 0, "count \(count)")
        }
        XCTAssertEqual(page.start(count: 9_001), page.start(count: 9_100), "one more message does not move the first row")
        // Scrolled up, it holds its first message.
        page.hold(count: 9_100)
        let held = page.start(count: 9_100)
        XCTAssertEqual(page.start(count: 9_400), held)
        page.showEarlier(count: 9_400)
        XCTAssertEqual(page.start(count: 9_400), held - TranscriptPage.page)
        // Back at the end, the newest again.
        page.follow(count: 9_400)
        XCTAssertEqual(page.start(count: 9_400), TranscriptPage.followingStart(count: 9_400))
    }

    /// Rows leaving the top of the window make SwiftUI estimate the rest again, and a transcript
    /// that did it with every message went blank (1.2.0); its rows are laid out afresh instead,
    /// and only then.
    func testTheRowsAreLaidOutAfreshOnlyWhenTheWindowMovesOn() {
        var page = TranscriptPage()
        XCTAssertEqual(page.identity(count: 1_080), page.identity(count: 1_081), "one more message keeps the rows")
        let moved = (1_000...1_400).filter { page.identity(count: $0) != page.identity(count: $0 - 1) }
        XCTAssertFalse(moved.isEmpty)
        XCTAssertEqual(moved, moved.filter { page.start(count: $0) != page.start(count: $0 - 1) }, "identity changes exactly when the first row does")
        XCTAssertLessThanOrEqual(moved.count, 400 / TranscriptPage.step + 1)
        // Scrolled up, the rows on screen are kept however far the output runs.
        page.hold(count: 1_400)
        let reading = page.identity(count: 1_400)
        XCTAssertEqual(page.identity(count: 3_000), reading)
        page.showEarlier(count: 3_000)
        XCTAssertEqual(page.identity(count: 3_000), reading, "earlier rows are added above the reader, who stays put")
        // Back at the newest, the rows above went away: afresh.
        page.follow(count: 3_000)
        XCTAssertNotEqual(page.identity(count: 3_000), reading)
        // A blank transcript lays out afresh while following, never under a reader who scrolled up.
        let following = page.identity(count: 3_000)
        page.refresh()
        XCTAssertNotEqual(page.identity(count: 3_000), following)
        page.hold(count: 3_000)
        let held = page.identity(count: 3_000)
        page.refresh()
        XCTAssertEqual(page.identity(count: 3_000), held)
    }

    func testFindAndJumpWidenTheWindowToTheirTarget() {
        var page = TranscriptPage()
        XCTAssertFalse(page.reveal(9_000, count: 9_001), "a message on screen needs no change")
        XCTAssertTrue(page.reveal(12, count: 9_001))
        XCTAssertEqual(page.start(count: 9_001), 0)
        page.follow(count: 9_001)
        XCTAssertTrue(page.reveal(5_000, count: 9_001))
        XCTAssertEqual(page.start(count: 9_001), 4_980)
    }
}
