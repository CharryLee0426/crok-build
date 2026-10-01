import XCTest
@testable import GrokDesktop

/// The composer footer's token figures: the meter's arithmetic, its formatting, and what it
/// takes from the harness's notifications.
@MainActor
final class TokenMeterTests: XCTestCase {
    private var directory: URL!
    private var defaultsName = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-token-meter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "GrokDesktopTokenMeter.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Meter

    func testAnUntouchedMeterDrawsNothing() {
        XCTAssertNil(TokenMeter().readout(turnRunning: true))
    }

    func testSessionTotalsReplaceRatherThanAdd() {
        var meter = TokenMeter()
        let first = TokenCounts(input: 100, output: 20, cacheRead: 300)
        meter.completeResponse(usage: first, sessionUsage: first, tokensPerSecond: 40)
        // The second total already holds the first response, and a subagent's spend on top.
        meter.completeResponse(usage: TokenCounts(input: 50, output: 10, cacheRead: 400),
                               sessionUsage: TokenCounts(input: 1_000, output: 90, cacheRead: 2_800, cacheCreation: 200), tokensPerSecond: 55.5)
        XCTAssertEqual(meter.readout(turnRunning: false),
                       TokenReadout(inputTokens: 4_000, outputTokens: 90, cachedTokens: 2_800, cacheHitRate: 0.7, rate: .measured(55.5)))
    }

    func testAHarnessWithoutSessionTotalsHasItsResponsesSummed() {
        var meter = TokenMeter()
        meter.completeResponse(usage: TokenCounts(input: 100, output: 20, cacheRead: 300), sessionUsage: nil, tokensPerSecond: nil)
        meter.completeResponse(usage: TokenCounts(input: 50, output: 10, cacheRead: 500, cacheCreation: 50), sessionUsage: nil, tokensPerSecond: nil)
        XCTAssertEqual(meter.readout(turnRunning: false),
                       TokenReadout(inputTokens: 1_000, outputTokens: 30, cachedTokens: 800, cacheHitRate: 0.8, rate: nil))
    }

    func testAStreamIsEstimatedUntilItsResponseCompletes() {
        var meter = TokenMeter()
        meter.completeResponse(usage: nil, sessionUsage: TokenCounts(input: 10, output: 100), tokensPerSecond: 30)
        meter.noteStream(bytes: 40, promptID: "p1", at: 100)
        // Too short a window to trust: the last measured rate stands, but the output already counts.
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 110)
        XCTAssertEqual(meter.readout(turnRunning: true)?.rate, .measured(30))

        meter.noteStream(bytes: 800, promptID: "p1", at: 102)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 310)
        // 800 bytes after the first chunk, over two seconds.
        XCTAssertEqual(meter.readout(turnRunning: true)?.rate, .estimated(100))

        meter.completeResponse(usage: nil, sessionUsage: TokenCounts(input: 10, output: 290), tokensPerSecond: 88)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 290)
        XCTAssertEqual(meter.readout(turnRunning: true)?.rate, .measured(88))
    }

    func testAStoppedStreamStopsCountingAndDoesNotLeakIntoTheNextTurn() {
        var meter = TokenMeter()
        meter.noteStream(bytes: 400, promptID: "p1", at: 0)
        meter.noteStream(bytes: 400, promptID: "p1", at: 4)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 200)
        // The turn was stopped: no completion arrives, and the harness counted nothing.
        XCTAssertNil(meter.readout(turnRunning: false))

        meter.noteStream(bytes: 40, promptID: "p2", at: 60)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 10)
        XCTAssertNil(meter.readout(turnRunning: true)?.rate)
    }

    func testAToolCallChunkWithoutAPromptIDJoinsTheStreamInFlight() {
        var meter = TokenMeter()
        meter.noteStream(bytes: 40, promptID: nil, at: 0)
        meter.noteStream(bytes: 40, promptID: "p1", at: 1)
        meter.noteStream(bytes: 40, promptID: nil, at: 2)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 30)
        // The stream took the ID it was given, so the next turn's first chunk still restarts it.
        meter.noteStream(bytes: 40, promptID: "p2", at: 3)
        XCTAssertEqual(meter.readout(turnRunning: true)?.outputTokens, 10)
        meter.endStream()
        XCTAssertNil(meter.readout(turnRunning: true))
    }

    func testAMeaninglessRateKeepsTheLastGoodOne() {
        var meter = TokenMeter()
        let total = TokenCounts(input: 1, output: 1)
        meter.completeResponse(usage: nil, sessionUsage: total, tokensPerSecond: 42)
        meter.completeResponse(usage: nil, sessionUsage: total, tokensPerSecond: .nan)
        meter.completeResponse(usage: nil, sessionUsage: total, tokensPerSecond: 0)
        XCTAssertEqual(meter.readout(turnRunning: false)?.rate, .measured(42))
    }

    // MARK: Formatting

    func testCountsStayWithinFourCharacters() {
        XCTAssertEqual([0, 999, 1_200, 9_940, 12_000, 999_000, 1_234_567, 12_000_000].map(TokenFormat.count),
                       ["0", "999", "1.2K", "9.9K", "12K", "999K", "1.2M", "12M"])
    }

    func testRateKeepsATenthOnlyBelowTen() {
        XCTAssertEqual([0, 9.94, 9.96, 142.6, 1e9, -3].map { TokenFormat.rate($0) }, ["0.0", "9.9", "10", "143", "9999", "0.0"])
        XCTAssertEqual(TokenFormat.rate(.measured(61.2)), "61 tok/s")
        XCTAssertEqual(TokenFormat.rate(.estimated(8.44)), "~8.4 tok/s")
    }

    func testHelpSpellsTheFiguresOut() {
        let readout = TokenReadout(inputTokens: 1_234_567, outputTokens: 45_300, cachedTokens: 1_024_000, cacheHitRate: 0.8294, rate: .measured(61.2))
        XCTAssertEqual(TokenFormat.help(readout), """
            Input: 1,234,567 tokens this session
            Cache hit rate: 83% (1,024,000 tokens read from cache)
            Output: 45,300 tokens
            Speed: 61 tokens per second in the last response
            Click for session usage · /usage
            """)
        XCTAssertEqual(TokenFormat.accessibilityLabel(readout),
                       "Token usage: 1,234,567 input tokens, 45,300 output tokens, 83% cache hit rate, 61 tokens per second. Show session usage")
    }

    // MARK: Notifications

    private func makeStore() -> (AppStore, UUID) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: UserDefaults(suiteName: defaultsName)!, binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Task", sessionID: "session-1")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        return (store, task.id)
    }

    private func completed(_ sessionUsage: [String: Any]?, rate: Double? = nil, session: String = "session-1") -> [String: Any] {
        var update: [String: Any] = ["sessionUpdate": "response_completed", "usage": ["input_tokens": 10, "output_tokens": 5]]
        update["session_usage"] = sessionUsage
        update["tokens_per_sec"] = rate
        return ["sessionId": session, "update": update]
    }

    func testAResponseCompletedUpdateSetsTheFiguresAtOnce() {
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let tokens = store.features.tokens
        // The meter watches without consuming, so the update still reaches whoever handles it next.
        XCTAssertFalse(store.receiveFeatureNotification("x.ai/session_notification", params: completed(
            ["input_tokens": 400, "output_tokens": 100, "cache_read_input_tokens": 1_400, "cache_creation_input_tokens": 200], rate: 61.5), id: id))
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false),
                       TokenReadout(inputTokens: 2_000, outputTokens: 100, cachedTokens: 1_400, cacheHitRate: 0.7, rate: .measured(61.5)))

        // Another session's response, a subagent's say, is not this task's.
        _ = store.receiveFeatureNotification("x.ai/session_notification", params: completed(["output_tokens": 9_999], session: "child"), id: id)
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false)?.outputTokens, 100)

        // A new harness process counts from zero.
        tokens.harnessDidStart(conversationID: id)
        XCTAssertNil(tokens.meters[id])
    }

    func testStreamedChunksAreEstimatedAndPublishedOnAnInterval() async throws {
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let tokens = store.features.tokens
        var now: TimeInterval = 50
        tokens.clock = { now }
        func chunk(_ kind: String, _ text: String) -> [String: Any] {
            ["sessionId": "session-1", "_meta": ["promptId": "p1"], "update": ["sessionUpdate": kind, "content": ["type": "text", "text": text]]]
        }
        _ = store.receiveFeatureNotification("session/update", params: chunk("agent_thought_chunk", String(repeating: "t", count: 40)), id: id)
        now = 52
        _ = store.receiveFeatureNotification("session/update", params: chunk("agent_message_chunk", String(repeating: "m", count: 400)), id: id)
        _ = store.receiveFeatureNotification("x.ai/session_notification", params: [
            "sessionId": "session-1", "update": ["sessionUpdate": "tool_call_delta_chunk", "tool_index": 0, "arguments_delta": String(repeating: "a", count: 400)]], id: id)
        // Chunks are batched, so nothing is on screen until the interval passes.
        XCTAssertNil(tokens.meters[id])
        try await Task.sleep(nanoseconds: TokenMeterModel.publishInterval * 3)
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: true),
                       TokenReadout(inputTokens: 0, outputTokens: 210, cachedTokens: 0, cacheHitRate: nil, rate: .estimated(100)))

        // A replayed history is not a stream.
        store.replaying.insert(id)
        _ = store.receiveFeatureNotification("session/update", params: chunk("agent_message_chunk", String(repeating: "r", count: 4_000)), id: id)
        store.replaying.remove(id)
        _ = store.receiveFeatureNotification("x.ai/session/update", params: ["sessionId": "session-1", "update": ["sessionUpdate": "turn_completed", "prompt_id": "p1", "stop_reason": "cancelled"]], id: id)
        XCTAssertNil(tokens.meters[id]?.readout(turnRunning: true))
    }
}
