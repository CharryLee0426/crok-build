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

    func testContextHelpSpellsTheWindowOut() {
        XCTAssertEqual(TokenFormat.contextHelp(ContextUsage(used: 42_100, window: 272_000)), """
            Context window: 15% full
            42,100 of 272,000 tokens used, 229,900 free
            Click to see how it is allocated
            """)
        XCTAssertEqual(TokenFormat.contextAccessibilityValue(ContextUsage(used: 42_100, window: 272_000)), "15% full, 42,100 of 272,000 tokens")
        // A model the catalog does not size, and a task that has not reported.
        XCTAssertEqual(TokenFormat.contextHelp(ContextUsage(used: 42_100)), "Context window: 42,100 tokens used\nClick to see how it is allocated")
        XCTAssertEqual(TokenFormat.contextHelp(nil), "Context window: not measured yet\nClick to see how it is allocated")
        XCTAssertEqual(TokenFormat.contextAccessibilityValue(nil), "Not measured yet")
        // A context can outgrow its window; nothing is free then.
        XCTAssertEqual(ContextUsage(used: 300, window: 200).fraction, 1.5)
        XCTAssertTrue(TokenFormat.contextHelp(ContextUsage(used: 300, window: 200)).contains("300 of 200 tokens used, 0 free"))
    }

    // MARK: Notifications

    private func makeStore() -> (AppStore, UUID) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: UserDefaults(suiteName: defaultsName)!, binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Task", sessionID: "session-1")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        // Never the real home's session records.
        store.features.tokens.harnessRecord = { _, _ in nil }
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

        // The figures are saved with the task.
        let firstSaved = SavedTokenUsage(TokenCounts(input: 400, output: 100, cacheRead: 1_400, cacheCreation: 200), tokensPerSecond: 61.5)
        XCTAssertEqual(store.task(id)?.tokenUsage, firstSaved)

        // A new harness process: the figures stay until it reports. Its session total covers the
        // session since it began, so it replaces them rather than adding to them.
        tokens.harnessDidStart(conversationID: id)
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false)?.outputTokens, 100)
        _ = store.receiveFeatureNotification("x.ai/session_notification", params: completed(
            ["input_tokens": 410, "output_tokens": 120, "cache_read_input_tokens": 1_400, "cache_creation_input_tokens": 200], rate: 30), id: id)
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false),
                       TokenReadout(inputTokens: 2_010, outputTokens: 120, cachedTokens: 1_400, cacheHitRate: 1_400.0 / 2_010.0, rate: .measured(30)))
        XCTAssertEqual(store.task(id)?.tokenUsage, SavedTokenUsage(TokenCounts(input: 410, output: 120, cacheRead: 1_400, cacheCreation: 200), tokensPerSecond: 30))
    }

    func testSavedFiguresGiveWayToTheHarnessTotal() {
        var meter = TokenMeter(saved: SavedTokenUsage(TokenCounts(input: 50, output: 500, cacheRead: 950), tokensPerSecond: 40))
        meter.carryOver()
        XCTAssertEqual(meter.readout(turnRunning: false)?.outputTokens, 500)
        // A harness without session totals: its responses add to what was there.
        var summed = meter
        summed.completeResponse(usage: TokenCounts(input: 5, output: 10), sessionUsage: nil, tokensPerSecond: nil)
        XCTAssertEqual(summed.readout(turnRunning: false)?.outputTokens, 510)
        meter.completeResponse(usage: TokenCounts(input: 5, output: 10), sessionUsage: TokenCounts(input: 55, output: 510, cacheRead: 950), tokensPerSecond: 45)
        XCTAssertEqual(meter.readout(turnRunning: false),
                       TokenReadout(inputTokens: 1_005, outputTokens: 510, cachedTokens: 950, cacheHitRate: 950.0 / 1_005.0, rate: .measured(45)))
    }

    // MARK: Coming back to a task

    func testATaskOpenedAgainShowsItsSavedFiguresAtOnce() {
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let tokens = store.features.tokens
        store.state.conversations[0].tokenUsage = SavedTokenUsage(TokenCounts(input: 400, output: 100, cacheRead: 1_400, cacheCreation: 200), tokensPerSecond: 61.5)
        tokens.restore(conversationID: id)
        let saved = TokenReadout(inputTokens: 2_000, outputTokens: 100, cachedTokens: 1_400, cacheHitRate: 0.7, rate: .measured(61.5))
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false), saved)
        // What this app counted since stands; opening the task again does not reset it.
        store.state.conversations[0].tokenUsage = SavedTokenUsage(TokenCounts(output: 1))
        tokens.restore(conversationID: id)
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false), saved)
    }

    func testTheHarnessRecordStandsInForATaskThatSavedNothing() throws {
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let tokens = store.features.tokens
        var record: SavedTokenUsage? = SavedTokenUsage(TokenCounts(input: 100, output: 500, cacheRead: 900), averageTokensPerSecond: 50)
        var asked: [String] = []
        tokens.harnessRecord = { cwd, session in asked.append("\(cwd)|\(session)"); return record }
        store.selectConversation(try XCTUnwrap(store.task(id)))
        XCTAssertEqual(asked, ["\(directory.path)|session-1"])
        XCTAssertEqual(tokens.meters[id]?.readout(turnRunning: false),
                       TokenReadout(inputTokens: 1_000, outputTokens: 500, cachedTokens: 900, cacheHitRate: 0.9, rate: .average(50)))

        // A task whose saved figures fall behind the harness's record (the terminal went on with it)
        // shows the record, with the last speed this app measured.
        let (other, otherID) = makeStore()
        defer { other.shutdown() }
        other.features.tokens.harnessRecord = { _, _ in record }
        other.state.conversations[0].tokenUsage = SavedTokenUsage(TokenCounts(input: 10, output: 20), tokensPerSecond: 70)
        other.features.tokens.restore(conversationID: otherID)
        XCTAssertEqual(other.features.tokens.meters[otherID]?.readout(turnRunning: false)?.outputTokens, 500)
        XCTAssertEqual(other.features.tokens.meters[otherID]?.readout(turnRunning: false)?.rate, .measured(70))

        // Nothing saved and no record: nothing to show.
        record = nil
        let (empty, emptyID) = makeStore()
        defer { empty.shutdown() }
        empty.features.tokens.harnessRecord = { _, _ in record }
        empty.features.tokens.restore(conversationID: emptyID)
        empty.features.tokens.harnessDidStart(conversationID: emptyID)
        XCTAssertNil(empty.features.tokens.meters[emptyID])
    }

    func testTheHarnessUsageFileIsReadFromTheSessionDirectory() throws {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cwd = "/Users/someone/My Project"
        let encoded = "%2FUsers%2Fsomeone%2FMy%20Project"
        let session = home.appendingPathComponent("sessions/\(encoded)/session-9", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("""
            {"sessionId": "session-9", "session": {"inputTokens": 20327191, "outputTokens": 485353, "cachedReadTokens": 19157626,
             "cacheCreationTokens": 1169285, "modelCalls": 134, "decodeDurationMs": 9700000, "decodeOutputTokens": 485000}}
            """.utf8).write(to: session.appendingPathComponent("usage.json"))
        let usage = try XCTUnwrap(SavedTokenUsage.harnessRecord(cwd: cwd, sessionID: "session-9", home: home))
        // `inputTokens` there is the whole prompt; the meter keeps the uncached part apart.
        XCTAssertEqual(usage.counts, TokenCounts(input: 280, output: 485_353, cacheRead: 19_157_626, cacheCreation: 1_169_285))
        XCTAssertEqual(usage.averageTokensPerSecond, 50)
        XCTAssertNil(usage.tokensPerSecond)
        // A record written before speeds were kept has none; an empty one counts as no record.
        XCTAssertNil(SavedTokenUsage(harnessUsageFile: Data(#"{"session": {"outputTokens": 5, "modelCalls": 1}}"#.utf8))?.averageTokensPerSecond)
        XCTAssertNil(SavedTokenUsage(harnessUsageFile: Data(#"{"session": {}}"#.utf8)))
        XCTAssertNil(SavedTokenUsage.harnessRecord(cwd: cwd, sessionID: "missing", home: home))
    }

    func testAnAverageSpeedReadsAsAnAverage() {
        let readout = TokenReadout(inputTokens: 10, outputTokens: 5, cachedTokens: 0, cacheHitRate: nil, rate: .average(48.2))
        XCTAssertEqual(TokenFormat.rate(.average(48.2)), "48 tok/s")
        XCTAssertTrue(TokenFormat.help(readout).contains("Speed: 48 tokens per second on average this session"))
    }

    // MARK: Cache diagnostics

    private func started(_ cacheMiss: [String: Any]?, session: String = "session-1") -> [String: Any] {
        var update: [String: Any] = ["sessionUpdate": "response_started", "message_id": "msg_1", "model": "claude-opus-5-5",
                                     "input_tokens": 42, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 41_850]
        update["cache_miss"] = cacheMiss
        return ["sessionId": session, "update": update]
    }

    /// Anthropic's cache diagnostics: a response whose request differed from the one before it puts
    /// a line in the transcript saying what changed. Every other response adds nothing.
    func testAPromptCacheMissIsWrittenIntoTheTranscript() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.auto) }
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let lines = { store.state.conversations.first { $0.id == id }?.messages.filter { $0.kind == .system }.map(\.text) ?? [] }

        XCTAssertFalse(store.receiveFeatureNotification("x.ai/session_notification", params: started(nil), id: id))
        // A kind this build does not know says nothing rather than something wrong.
        XCTAssertFalse(store.receiveFeatureNotification("x.ai/session_notification", params: started(["changed": "weather", "missed_input_tokens": 9]), id: id))
        // A subagent's request is not this task's.
        _ = store.receiveFeatureNotification("x.ai/session_notification", params: started(["changed": "tools", "missed_input_tokens": 9], session: "child"), id: id)
        XCTAssertEqual(lines(), [])

        XCTAssertTrue(store.receiveFeatureNotification("x.ai/session_notification", params: started(["changed": "system", "missed_input_tokens": 41_850]), id: id))
        XCTAssertEqual(lines(), ["Prompt cache: the system prompt changed since the previous request. About \(41_850.formatted()) input tokens after the change were not read from the cache."])

        // Without a size, only what changed. Each part of a request has its own wording, in each language.
        XCTAssertEqual(PromptCacheMiss(["changed": "messages"])?.text, "Prompt cache: earlier messages changed since the previous request.")
        L10n.setLanguage(.de)
        XCTAssertEqual(PromptCacheMiss(["changed": "model", "missed_input_tokens": 7])?.text,
                       "Prompt-Cache: Das Modell hat sich seit der vorherigen Anfrage geändert. Etwa 7 Eingabe-Tokens nach der Änderung wurden nicht aus dem Cache gelesen.")
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(PromptCacheMiss(["changed": "tools", "missed_input_tokens": 7])?.text,
                       "提示缓存：工具列表与上一次请求相比有变化。变化之后约有 7 个输入 token 未从缓存读取。")
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

    func testTheContextFigureFollowsUpdatesCompactionsAndContext() async throws {
        let (store, id) = makeStore()
        defer { store.shutdown() }
        let tokens = store.features.tokens
        // Every update carries the figure, chunks included, so it is published on the meter's interval.
        _ = store.receiveFeatureNotification("session/update", params: [
            "sessionId": "session-1", "_meta": ["totalTokens": 40_000, "promptId": "p1"],
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Working"]]], id: id)
        XCTAssertNil(tokens.contexts[id])
        try await Task.sleep(nanoseconds: TokenMeterModel.publishInterval * 3)
        XCTAssertEqual(tokens.contexts[id], ContextUsage(used: 40_000))

        // Context measures the window as well, and shows at once.
        var measured = UsageContextSnapshot()
        measured.used = 41_000
        measured.total = 272_000
        tokens.noteContext(measured, conversationID: id)
        XCTAssertEqual(tokens.contexts[id], ContextUsage(used: 41_000, window: 272_000))
        // A harness that sent no breakdown changes nothing.
        tokens.noteContext(UsageContextSnapshot(), conversationID: id)
        XCTAssertEqual(tokens.contexts[id], ContextUsage(used: 41_000, window: 272_000))

        // A compaction reports nothing else, so its result shows at once.
        _ = store.receiveFeatureNotification("x.ai/session_notification", params: [
            "sessionId": "session-1", "update": ["sessionUpdate": "auto_compact_completed", "tokens_before": 41_000, "tokens_after": 9_000]], id: id)
        XCTAssertEqual(tokens.contexts[id], ContextUsage(used: 9_000, window: 272_000))

        // The next harness loads the same conversation, so the figure stays.
        tokens.harnessDidStart(conversationID: id)
        XCTAssertEqual(tokens.contexts[id], ContextUsage(used: 9_000, window: 272_000))
    }
}
