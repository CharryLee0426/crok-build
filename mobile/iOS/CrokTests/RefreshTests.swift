import XCTest

@testable import Crok

/// Refresh of the session list (relay/DESIGN.md §3 `sessions:refresh` / `sessions:refreshState`): the answers, the
/// keeper's manual trigger, and the engine's wait.
final class RefreshDecodingTests: XCTestCase {
    func testRefreshAnswerDecodesFloats() throws {
        let json = #"{"asked":2.0,"offline":1.0,"at":1792098432719.0}"#
        let answer = try JSONDecoder().decode(RefreshAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(answer, RefreshAnswer(asked: 2, offline: 1, at: 1_792_098_432_719))
    }

    func testRefreshStateDecodesThePendingComputers() throws {
        let pending = try JSONDecoder().decode(RefreshState.self, from: Data(#"{"pending":["k57x","k58y"]}"#.utf8))
        XCTAssertEqual(pending.pending, ["k57x", "k58y"])
        let done = try JSONDecoder().decode(RefreshState.self, from: Data(#"{"pending":[]}"#.utf8))
        XCTAssertTrue(done.pending.isEmpty)
    }
}

final class RefreshKeeperTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func live() -> ConnectionKeeper {
        var keeper = ConnectionKeeper(now: t0)
        _ = keeper.networkChanged(available: true, now: t0)
        _ = keeper.synced(now: t0)
        return keeper
    }

    func testARefreshOnALiveConnectionDoesNothing() {
        var keeper = live()
        XCTAssertEqual(keeper.refreshRequested(now: at(5)), [])
        XCTAssertFalse(keeper.isRecovering)
        XCTAssertNil(keeper.lastTrigger)
    }

    func testARefreshWhileNotLiveRecoversAtOnceInsteadOfAtTheWatchdog() {
        var keeper = live()
        XCTAssertEqual(keeper.socketChanged(connected: false, now: at(10)), [])
        XCTAssertEqual(keeper.tick(now: at(12)), [], "the watchdog waits 20 s")
        XCTAssertEqual(keeper.refreshRequested(now: at(12)), [.refreshToken])
        XCTAssertEqual(keeper.lastTrigger, .manual)
        XCTAssertEqual(keeper.refreshRequested(now: at(13)), [], "one recovery at a time")
        XCTAssertEqual(keeper.refreshFinished(now: at(14)), [])
        XCTAssertEqual(keeper.tick(now: at(24)), [.replaceClient], "no sync within the window: a new client")
    }

    func testAnUnansweredRefreshMeansTheSocketIsDead() {
        var keeper = live()
        XCTAssertEqual(keeper.refreshUnanswered(now: at(30)), [.refreshToken])
        XCTAssertFalse(keeper.synced, "the title says Updating… until the socket proves itself")
        XCTAssertEqual(keeper.lastTrigger, .manual)
        XCTAssertEqual(keeper.refreshFinished(now: at(31)), [])
        XCTAssertEqual(keeper.synced(now: at(32)), [])
        XCTAssertFalse(keeper.isRecovering)
    }

    func testNoRefreshRecoveryWithoutNetwork() {
        var keeper = live()
        XCTAssertEqual(keeper.networkChanged(available: false, now: at(1)), [])
        XCTAssertEqual(keeper.refreshRequested(now: at(2)), [])
        XCTAssertEqual(keeper.refreshUnanswered(now: at(3)), [])
    }
}

/// A demo relay whose `sessions:refresh` and `sessions:refreshState` the test drives.
private final class RefreshingRelay: RelayBackend, SessionsAPI, @unchecked Sendable {
    let demo: DemoRelay
    private let lock = NSLock()
    private var sinks: [AsyncStream<ConnectionSignal>.Continuation] = []
    private var states: [AsyncThrowingStream<RefreshState, Error>.Continuation] = []
    private var _calls = 0
    private var _subscriptions = 0
    private var _ended = 0
    private var _authRefreshes = 0

    /// What `refresh` answers (nil: it never answers, like a call on a dead socket).
    var answer: Result<RefreshAnswer, Error>? = .success(RefreshAnswer(asked: 1, offline: 0, at: 1000))
    /// How long `refresh` takes.
    var delay: Duration = .milliseconds(20)

    @MainActor
    init() {
        demo = DemoRelay(world: DemoWorld())
    }

    var calls: Int { lock.withLock { _calls } }
    var subscriptions: Int { lock.withLock { _subscriptions } }
    var ended: Int { lock.withLock { _ended } }
    var authRefreshes: Int { lock.withLock { _authRefreshes } }

    /// Sends a `refreshState` value to every subscriber.
    func pending(_ ids: [DocID]) {
        for state in lock.withLock({ states }) { state.yield(RefreshState(pending: ids)) }
    }

    func send(_ signal: ConnectionSignal) {
        for sink in lock.withLock({ sinks }) { sink.yield(signal) }
    }

    var sessions: any SessionsAPI { self }
    var commands: any CommandsAPI { demo }
    var devices: any DevicesAPI { demo }
    var account: any AccountAPI { demo }
    func connectionSignals() -> AsyncStream<ConnectionSignal> {
        AsyncStream { continuation in lock.withLock { sinks.append(continuation) } }
    }
    func start() async {}
    func shutdown() async {}
    func refreshAuth() async throws { lock.withLock { _authRefreshes += 1 } }

    func refresh() async throws -> RefreshAnswer {
        lock.withLock { _calls += 1 }
        try await Task.sleep(for: delay)
        guard let answer = lock.withLock({ answer }) else {
            // A call on a dead socket: no answer, ever.
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return try answer.get()
    }

    func refreshState(since: Double) -> RelayStream<RefreshState> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                _subscriptions += 1
                states.append(continuation)
            }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._ended += 1 } }
        }
    }

    func groups() -> RelayStream<[ProjectGroup]> { demo.groups() }
    func list(archived: Bool) -> RelayStream<[SessionRow]> { demo.list(archived: archived) }
    func get(_ sessionDocId: DocID) -> RelayStream<SessionDetail> { demo.get(sessionDocId) }
    func reorderProjects(_ keys: [String]) async throws { try await demo.reorderProjects(keys) }
    func reorderSessions(projectKey: String, _ sessionDocIds: [DocID]) async throws {
        try await demo.reorderSessions(projectKey: projectKey, sessionDocIds)
    }
    func resetOrder(projectKey: String?) async throws { try await demo.resetOrder(projectKey: projectKey) }
    func transcript(_ sessionDocId: DocID, range: TranscriptRange) -> RelayStream<TranscriptChunk> {
        demo.transcript(sessionDocId, range: range)
    }
    func markRead(_ sessionDocId: DocID) async throws { try await demo.markRead(sessionDocId) }
    func watch(_ sessionDocId: DocID) async throws { try await demo.watch(sessionDocId) }
    func setPinned(_ sessionDocId: DocID, _ pinned: Bool) async throws { try await demo.setPinned(sessionDocId, pinned) }
    func setArchived(_ sessionDocId: DocID, _ archived: Bool) async throws { try await demo.setArchived(sessionDocId, archived) }
    func remove(_ sessionDocId: DocID) async throws { try await demo.remove(sessionDocId) }
    func create(
        deviceId: DocID, path: String, text: String?, model: String?, effort: String?, clientId: String,
        attachments: [AttachmentInput]
    ) async throws -> CreatedSession {
        try await demo.create(
            deviceId: deviceId, path: path, text: text, model: model, effort: effort, clientId: clientId,
            attachments: attachments)
    }
    func slashCommands(_ sessionDocId: DocID) -> RelayStream<SlashCommandList> { demo.slashCommands(sessionDocId) }
}

@MainActor
final class EngineRefreshTests: XCTestCase {
    private func makeEngine(_ relay: RefreshingRelay) -> CrokEngine {
        let credentials = StoredCredentials(
            serverURL: "https://relay", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.refresh.\(UUID().uuidString)")!)
        let engine = CrokEngine(
            backend: relay, credentials: credentials, isDemo: false, drafts: drafts, cache: nil, tickInterval: nil)
        engine.refreshMinimum = .zero
        engine.refreshTimeout = .seconds(5)
        return engine
    }

    /// Started, with a live socket: a Refresh needs no recovery.
    private func online(_ relay: RefreshingRelay, _ engine: CrokEngine) async {
        engine.start()
        await Task.yield()
        relay.send(.network(available: true))
        relay.send(.socket(connected: true))
        relay.send(.synced)
        await until("online") { engine.connection == .online }
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testDoneOnceEveryComputerHasListedItsSessions() async {
        let relay = RefreshingRelay()
        let engine = makeEngine(relay)
        await online(relay, engine)
        let refresh = Task { await engine.refreshSessions() }
        await until("the subscription") { relay.subscriptions == 1 }
        XCTAssertTrue(engine.isRefreshing)
        relay.pending(["mac-studio", "macbook"])
        relay.pending(["macbook"])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.isRefreshing, "one computer is still listing")
        relay.pending([])
        let outcome = await refresh.value
        XCTAssertEqual(outcome, .done)
        XCTAssertFalse(engine.isRefreshing)
        XCTAssertEqual(relay.calls, 1)
        await until("the subscription ends") { relay.ended == 1 }
        XCTAssertEqual(relay.authRefreshes, 0, "a live connection needs no recovery")
        await engine.shutdown()
    }

    func testAComputerThatNeverFinishesTimesOutAndTheSubscriptionEnds() async {
        let relay = RefreshingRelay()
        let engine = makeEngine(relay)
        engine.refreshTimeout = .milliseconds(300)
        await online(relay, engine)
        let refresh = Task { await engine.refreshSessions() }
        await until("the subscription") { relay.subscriptions == 1 }
        relay.pending(["old-crok"])
        let outcome = await refresh.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(engine.isRefreshing)
        await until("the subscription ends") { relay.ended == 1 }
        await engine.shutdown()
    }

    func testNoComputerOnlineSaysSoWithoutWaiting() async {
        let relay = RefreshingRelay()
        relay.answer = .success(RefreshAnswer(asked: 0, offline: 2, at: 1000))
        let engine = makeEngine(relay)
        await online(relay, engine)
        let outcome = await engine.refreshSessions()
        XCTAssertEqual(outcome, .noneOnline)
        XCTAssertEqual(relay.subscriptions, 0)
        await engine.shutdown()
    }

    func testASecondRefreshJoinsTheRunningOne() async {
        let relay = RefreshingRelay()
        relay.delay = .milliseconds(100)
        let engine = makeEngine(relay)
        await online(relay, engine)
        let first = Task { await engine.refreshSessions() }
        let second = Task { await engine.refreshSessions() }
        await until("the subscription") { relay.subscriptions == 1 }
        relay.pending([])
        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.done, .done])
        XCTAssertEqual(relay.calls, 1, "one request for both")
        XCTAssertEqual(relay.subscriptions, 1)
        // A later one asks again.
        let third = Task { await engine.refreshSessions() }
        await until("the second subscription") { relay.subscriptions == 2 }
        relay.pending([])
        let outcome = await third.value
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(relay.calls, 2)
        await engine.shutdown()
    }

    func testARelayErrorIsReturnedForTheAlert() async {
        let relay = RefreshingRelay()
        relay.answer = .failure(RelayError(.server, "No."))
        let engine = makeEngine(relay)
        await online(relay, engine)
        let outcome = await engine.refreshSessions()
        XCTAssertEqual(outcome, .failed(RelayError(.server, "No.")))
        XCTAssertFalse(engine.isRefreshing)
        await engine.shutdown()
    }

    func testAnUnansweredRefreshStopsWaitingAndRecoversTheConnection() async {
        let relay = RefreshingRelay()
        relay.answer = nil
        let engine = makeEngine(relay)
        engine.refreshTimeout = .milliseconds(300)
        await online(relay, engine)
        let outcome = await engine.refreshSessions()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(engine.isRefreshing)
        await until("the recovery") { relay.authRefreshes == 1 }
        XCTAssertEqual(relay.subscriptions, 0)
        await engine.shutdown()
    }

    func testARefreshWhileNotLiveStartsTheRecoveryAtOnce() async {
        let relay = RefreshingRelay()
        let engine = makeEngine(relay)
        engine.start()
        await Task.yield()
        relay.send(.network(available: true))
        // The socket never synced: "Connecting…".
        let refresh = Task { await engine.refreshSessions() }
        await until("the recovery") { relay.authRefreshes == 1 }
        await until("the subscription") { relay.subscriptions == 1 }
        relay.pending([])
        let outcome = await refresh.value
        XCTAssertEqual(outcome, .done)
        await engine.shutdown()
    }

    func testTheSpinnerShowsForAtLeastTheMinimum() async {
        let relay = RefreshingRelay()
        relay.answer = .success(RefreshAnswer(asked: 0, offline: 0, at: 1000))
        relay.delay = .zero
        let engine = makeEngine(relay)
        engine.refreshMinimum = .milliseconds(400)
        await online(relay, engine)
        let clock = ContinuousClock()
        let started = clock.now
        _ = await engine.refreshSessions()
        XCTAssertGreaterThanOrEqual(clock.now - started, .milliseconds(400))
        await engine.shutdown()
    }

    func testTheDemoRelayAnswersAtOnceWithItsOnlineComputers() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let answer = try await relay.refresh()
        let computers = world.devices.filter { $0.kind == .computer }
        XCTAssertEqual(answer.asked, Double(computers.filter(\.online).count))
        XCTAssertEqual(answer.offline, Double(computers.filter { !$0.online }.count))
        var states = relay.refreshState(since: answer.at).makeAsyncIterator()
        let state = try await states.next()
        XCTAssertEqual(state?.pending, [])
    }
}
