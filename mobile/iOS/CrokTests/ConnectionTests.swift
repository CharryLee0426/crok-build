import Combine
import XCTest

@testable import Crok

/// relay/DESIGN.md §5 "Staying connected": the keeper's rules, step by step.
final class ConnectionKeeperTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A keeper that has synced once, with the network up.
    private func live() -> ConnectionKeeper {
        var keeper = ConnectionKeeper(now: t0)
        XCTAssertEqual(keeper.networkChanged(available: true, now: t0), [])
        XCTAssertEqual(keeper.synced(now: t0), [])
        return keeper
    }

    func testForegroundRefreshesAndALiveSocketEndsTheRecovery() {
        var keeper = live()
        keeper.enteredBackground()
        XCTAssertEqual(keeper.becameActive(now: at(600)), [.refreshToken])
        XCTAssertFalse(keeper.synced, "the title says Updating… until the socket proves itself")
        XCTAssertEqual(keeper.lastTrigger, .foreground)
        XCTAssertEqual(keeper.synced(now: at(600.3)), [])
        XCTAssertEqual(keeper.refreshFinished(now: at(600.4)), [])
        XCTAssertFalse(keeper.isRecovering)
        XCTAssertEqual(keeper.tick(now: at(700)), [], "nothing to replace")
    }

    func testASocketThatDoesNotSyncWithinTenSecondsOfTheRefreshIsReplaced() {
        var keeper = live()
        keeper.enteredBackground()
        XCTAssertEqual(keeper.becameActive(now: at(600)), [.refreshToken])
        XCTAssertEqual(keeper.tick(now: at(601)), [], "still refreshing")
        XCTAssertEqual(keeper.refreshFinished(now: at(602)), [])
        XCTAssertEqual(keeper.tick(now: at(611.9)), [], "inside the sync window")
        XCTAssertEqual(keeper.tick(now: at(612)), [.replaceClient])
        XCTAssertEqual(keeper.tick(now: at(613)), [], "one replacement at a time")
        XCTAssertEqual(keeper.becameActive(now: at(613)), [], "a trigger during the replacement waits for it")
        XCTAssertEqual(keeper.replaceFinished(now: at(614)), [])
        XCTAssertFalse(keeper.synced, "the new client has synced nothing yet")
        XCTAssertEqual(keeper.synced(now: at(615)), [])
        XCTAssertFalse(keeper.isRecovering)
    }

    func testAFailedRefreshStillWaitsForTheSocketBeforeReplacing() {
        var keeper = live()
        XCTAssertEqual(keeper.pathChanged(now: at(1)), [.refreshToken])
        // The refresh failed (the engine reports it the same way); data arriving in the window still counts.
        XCTAssertEqual(keeper.refreshFinished(now: at(2)), [])
        XCTAssertEqual(keeper.synced(now: at(5)), [])
        XCTAssertEqual(keeper.tick(now: at(20)), [])
        XCTAssertFalse(keeper.isRecovering)
    }

    func testNotSyncedForTwentySecondsWhileTheNetworkIsUpStartsARecovery() {
        var keeper = live()
        XCTAssertEqual(keeper.socketChanged(connected: false, now: at(10)), [])
        XCTAssertEqual(keeper.socketChanged(connected: true, now: at(11)), [], "connected, but no results yet")
        XCTAssertEqual(keeper.tick(now: at(29.9)), [])
        XCTAssertEqual(keeper.tick(now: at(30)), [.refreshToken])
        XCTAssertEqual(keeper.lastTrigger, .stalled)
    }

    func testAFlappingSocketDoesNotPostponeTheWatchdog() {
        var keeper = live()
        XCTAssertEqual(keeper.socketChanged(connected: false, now: at(0)), [])
        for second in stride(from: 1.0, to: 20, by: 2) {
            _ = keeper.socketChanged(connected: true, now: at(second))
            _ = keeper.socketChanged(connected: false, now: at(second + 1))
        }
        XCTAssertEqual(keeper.tick(now: at(20)), [.refreshToken], "measured from the first drop")
    }

    func testNothingHappensWithoutNetworkAndItsReturnStartsARecovery() {
        var keeper = live()
        XCTAssertEqual(keeper.networkChanged(available: false, now: at(5)), [])
        XCTAssertFalse(keeper.synced)
        XCTAssertEqual(keeper.tick(now: at(300)), [], "no watchdog while waiting for network")
        keeper.enteredBackground()
        XCTAssertEqual(keeper.becameActive(now: at(310)), [], "nor on foreground")
        XCTAssertEqual(keeper.networkChanged(available: true, now: at(320)), [.refreshToken])
        XCTAssertEqual(keeper.lastTrigger, .network)
        XCTAssertEqual(keeper.networkChanged(available: true, now: at(321)), [], "a repeat of the same state is no news")
    }

    func testTheWatchdogCountsFromTheNetworksReturn() {
        var keeper = live()
        _ = keeper.networkChanged(available: false, now: at(0))
        XCTAssertEqual(keeper.networkChanged(available: true, now: at(100)), [.refreshToken])
        XCTAssertEqual(keeper.refreshFinished(now: at(101)), [])
        XCTAssertEqual(keeper.synced(now: at(102)), [])
        XCTAssertEqual(keeper.socketChanged(connected: false, now: at(103)), [])
        XCTAssertEqual(keeper.tick(now: at(122)), [])
        XCTAssertEqual(keeper.tick(now: at(123)), [.refreshToken])
    }

    func testUnauthenticatedRefreshesThenReplacesAtOnceButNotTooOften() {
        var keeper = live()
        XCTAssertEqual(keeper.unauthenticated(now: at(0)), [.refreshToken])
        XCTAssertEqual(keeper.refreshFinished(now: at(1)), [.replaceClient], "no sync window: the client is replaced")
        XCTAssertEqual(keeper.replaceFinished(now: at(2)), [])
        XCTAssertEqual(keeper.synced(now: at(3)), [])
        XCTAssertEqual(keeper.unauthenticated(now: at(5)), [.refreshToken])
        XCTAssertEqual(keeper.refreshFinished(now: at(6)), [], "too soon after the last replacement")
        XCTAssertEqual(keeper.tick(now: at(10)), [], "the probe window")
        XCTAssertEqual(keeper.synced(now: at(11)), [])
        XCTAssertEqual(keeper.tick(now: at(16.9)), [])
        XCTAssertEqual(keeper.tick(now: at(17)), [.refreshToken], "the wanted replacement once 15 s have passed")
        XCTAssertEqual(keeper.refreshFinished(now: at(18)), [.replaceClient])
    }

    func testUnauthenticatedDuringARefreshUpgradesItToAReplacement() {
        var keeper = live()
        keeper.enteredBackground()
        XCTAssertEqual(keeper.becameActive(now: at(0)), [.refreshToken])
        XCTAssertEqual(keeper.unauthenticated(now: at(0.5)), [])
        XCTAssertEqual(keeper.refreshFinished(now: at(1)), [.replaceClient])
    }

    func testUnauthenticatedWhileProbingReplacesAtOnce() {
        var keeper = live()
        XCTAssertEqual(keeper.pathChanged(now: at(0)), [.refreshToken])
        XCTAssertEqual(keeper.refreshFinished(now: at(1)), [])
        XCTAssertEqual(keeper.unauthenticated(now: at(2)), [.replaceClient])
    }

    func testRecoveriesPauseInTheBackground() {
        var keeper = live()
        _ = keeper.socketChanged(connected: false, now: at(0))
        keeper.enteredBackground()
        XCTAssertEqual(keeper.tick(now: at(60)), [])
        XCTAssertEqual(keeper.unauthenticated(now: at(61)), [])
        XCTAssertEqual(keeper.becameActive(now: at(62)), [.refreshToken])
        XCTAssertEqual(keeper.refreshFinished(now: at(63)), [.replaceClient], "the UNAUTHENTICATED seen meanwhile")
    }
}

/// The hub moves every subscription to a new client and keeps what observers have.
final class QueryHubRestartTests: XCTestCase {
    func testRestartAllResubscribesKeepingValuesAndDroppingTheOldRun() {
        let hub = QueryHub()
        let fake = QueryHubTests.FakeSubscription()
        let seen = QueryHubTests.Recorder()
        hub.attach(key: "k", id: UUID(), onValue: seen.value, onError: seen.error, start: fake.start)
        let oldDeliver = fake.deliver
        let oldFail = fake.fail
        oldDeliver?(1)
        hub.restartAll()
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.cancels, 1, "the old client's subscription is cancelled")
        oldDeliver?(99)
        oldFail?(RelayError(.server, "late"))
        XCTAssertEqual(seen.values, [1], "nothing from the old run")
        XCTAssertEqual(seen.errors, [])
        XCTAssertEqual(hub.count, 1)
        fake.deliver?(2)
        XCTAssertEqual(seen.values, [1, 2])
        let late = QueryHubTests.Recorder()
        hub.attach(key: "k", id: UUID(), onValue: late.value, onError: late.error, start: fake.start)
        XCTAssertEqual(late.values, [2])
        XCTAssertEqual(fake.starts, 2, "a screen opened after the restart shares the new subscription")
    }

    func testAnEndedEntryIsNotRestarted() {
        let hub = QueryHub()
        let fake = QueryHubTests.FakeSubscription()
        hub.attach(key: "k", id: UUID(), onValue: { _ in }, onError: { _ in }, start: fake.start)
        fake.fail?(RelayError(.notFound, "gone"))
        hub.restartAll()
        XCTAssertEqual(fake.starts, 1)
    }
}

/// One refresh at a time, shared by every client generation.
final class DeviceTokenSourceTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    static func token(_ n: Int, minutesLeft: Double = 60) -> DeviceAccessToken {
        DeviceAccessToken(deviceId: "d", accessToken: "jwt-\(n)", accessTokenExpiresAt: Date().milliseconds + minutesLeft * 60_000)
    }

    func testConcurrentCallersShareOneRefreshAndARecentTokenIsReused() async throws {
        let fetches = Counter()
        let source = DeviceTokenSource(
            refreshToken: "crr", initialToken: nil,
            fetch: { _ in
                let n = fetches.next()
                try await Task.sleep(for: .milliseconds(100))
                return Self.token(n)
            }, onRevoked: {})
        async let a = source.fresh(maxAge: 0)
        async let b = source.fresh(maxAge: 0)
        let (first, second) = try await (a, b)
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(first, second)
        let reused = try await source.fresh(maxAge: 30)
        XCTAssertEqual(reused, first)
        XCTAssertEqual(fetches.count, 1, "refreshed moments ago")
        _ = try await source.fresh(maxAge: 0)
        XCTAssertEqual(fetches.count, 2)
    }

    func testRevokedSignsOutOnceAndStopsAsking() async {
        let fetches = Counter()
        let revocations = Counter()
        let source = DeviceTokenSource(
            refreshToken: "crr", initialToken: nil,
            fetch: { _ in
                _ = fetches.next()
                throw RelayError(.revoked, "This device was signed out.")
            }, onRevoked: { _ = revocations.next() })
        for _ in 0..<3 {
            do {
                _ = try await source.fresh(maxAge: 0)
                XCTFail("expected REVOKED")
            } catch {
                XCTAssertEqual(error.relayCode, .revoked)
            }
        }
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(revocations.count, 1)
    }

    func testAReconnectFallsBackToAStillValidTokenWhenTheRefreshFails() async throws {
        let source = DeviceTokenSource(
            refreshToken: "crr", initialToken: Self.token(0, minutesLeft: 30),
            fetch: { _ in throw RelayError(.network, "offline") }, onRevoked: {})
        let provider = DeviceAuthProvider(tokens: source)
        let token = try await provider.loginFromCache(onIdToken: { _ in })
        XCTAssertEqual(token.accessToken, "jwt-0", "not ConvexMobile's cached one, which may have expired")
        provider.cancelTimer()

        let expired = DeviceTokenSource(
            refreshToken: "crr", initialToken: Self.token(0, minutesLeft: -5),
            fetch: { _ in throw RelayError(.network, "offline") }, onRevoked: {})
        do {
            _ = try await DeviceAuthProvider(tokens: expired).loginFromCache(onIdToken: { _ in })
            XCTFail("an expired token is no fallback")
        } catch {
            XCTAssertEqual(error.relayCode, .network)
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date()
        var now: Date { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
    }

    func testLoginUsesAFreshTokenAndPushFreshHandsANewOneToTheClient() async throws {
        let fetches = Counter()
        let clock = Clock()
        let source = DeviceTokenSource(
            refreshToken: "crr", initialToken: Self.token(0),
            fetch: { _ in Self.token(fetches.next()) }, onRevoked: {}, now: { clock.now })
        let provider = DeviceAuthProvider(tokens: source)
        let pushed = PushedTokens()
        let token = try await provider.login(onIdToken: { pushed.append($0) })
        XCTAssertEqual(token.accessToken, "jwt-0", "the token sign-in just handed out")
        XCTAssertEqual(fetches.count, 0)
        clock.advance(6)
        try await provider.pushFresh()
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(pushed.values, ["jwt-1"])
        provider.cancelTimer()
    }

    final class PushedTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String?] = []
        var values: [String?] { lock.withLock { _values } }
        func append(_ value: String?) { lock.withLock { _values.append(value) } }
    }
}

/// A backend whose socket can be alive or dead, for the engine's recovery wiring.
private final class FakeSocketRelay: RelayBackend, @unchecked Sendable {
    let demo: DemoRelay
    private let lock = NSLock()
    private var sinks: [AsyncStream<ConnectionSignal>.Continuation] = []
    private var _refreshes = 0
    private var _replacements = 0
    /// Whether a pushed token gets fresh results (a live socket) or nothing (a dead one).
    var socketAlive = true
    /// Whether a new client syncs.
    var newClientWorks = true

    @MainActor
    init() {
        demo = DemoRelay(world: DemoWorld())
    }

    var refreshes: Int { lock.withLock { _refreshes } }
    var replacements: Int { lock.withLock { _replacements } }

    var sessions: any SessionsAPI { demo }
    var commands: any CommandsAPI { demo }
    var devices: any DevicesAPI { demo }
    var account: any AccountAPI { demo }

    func connectionSignals() -> AsyncStream<ConnectionSignal> {
        AsyncStream { continuation in
            lock.withLock { sinks.append(continuation) }
        }
    }

    func send(_ signal: ConnectionSignal) {
        for sink in lock.withLock({ sinks }) { sink.yield(signal) }
    }

    func start() async {}
    func shutdown() async {}

    func refreshAuth() async throws {
        lock.withLock { _refreshes += 1 }
        if lock.withLock({ socketAlive }) { send(.synced) }
    }

    func replaceClient() async {
        lock.withLock { _replacements += 1 }
        send(.socket(connected: false))
        if lock.withLock({ newClientWorks }) {
            send(.socket(connected: true))
            send(.synced)
        }
    }
}

/// The engine runs the keeper: scene phase, signals, the watchdog, and `UNAUTHENTICATED` from queries.
@MainActor
final class EngineConnectionTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 2_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeEngine(_ relay: FakeSocketRelay, clock: Clock) -> CrokEngine {
        let credentials = StoredCredentials(
            serverURL: "https://relay", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.connection.\(UUID().uuidString)")!)
        return CrokEngine(
            backend: relay, credentials: credentials, isDemo: false, drafts: drafts, cache: nil, now: { clock.now },
            tickInterval: nil)
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Started, network up, socket connected, results in.
    private func online(_ relay: FakeSocketRelay, _ engine: CrokEngine) async {
        engine.start()
        await Task.yield()
        relay.send(.network(available: true))
        relay.send(.socket(connected: true))
        relay.send(.synced)
        await until("online") { engine.connection == .online }
    }

    func testForegroundWithALiveSocketOnlyRefreshesTheToken() async {
        let relay = FakeSocketRelay()
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        engine.scenePhaseChanged(active: true)
        XCTAssertEqual(relay.refreshes, 0, "launching is not returning to the foreground")
        engine.scenePhaseChanged(active: false)
        clock.advance(3600)
        engine.scenePhaseChanged(active: true)
        await until("the refresh") { relay.refreshes == 1 && !engine.keeper.isRecovering }
        clock.advance(30)
        engine.tickConnection()
        XCTAssertEqual(relay.replacements, 0)
        XCTAssertEqual(engine.connection, .online)
        await engine.shutdown()
    }

    func testForegroundWithADeadSocketReplacesTheClientAfterTheSyncWindow() async {
        let relay = FakeSocketRelay()
        relay.socketAlive = false
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        engine.scenePhaseChanged(active: false)
        clock.advance(3600)
        engine.scenePhaseChanged(active: true)
        await until("the refresh") { relay.refreshes == 1 }
        await until("the sync window") { engine.keeper.isRecovering && engine.connection == .updating }
        clock.advance(9)
        engine.tickConnection()
        XCTAssertEqual(relay.replacements, 0)
        clock.advance(1.5)
        engine.tickConnection()
        await until("a new client") { relay.replacements == 1 }
        await until("online on the new client") { engine.connection == .online && !engine.keeper.isRecovering }
        await engine.shutdown()
    }

    func testAStalledConnectionRecoversWithoutAnyAppEvent() async {
        let relay = FakeSocketRelay()
        relay.socketAlive = false
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        relay.send(.socket(connected: false))
        await until("connecting") { engine.connection == .connecting }
        clock.advance(19)
        engine.tickConnection()
        XCTAssertEqual(relay.refreshes, 0)
        clock.advance(1)
        engine.tickConnection()
        await until("the refresh") { relay.refreshes == 1 && engine.keeper.isRecovering }
        try? await Task.sleep(for: .milliseconds(100))
        clock.advance(10)
        engine.tickConnection()
        await until("a new client") { relay.replacements == 1 }
        await until("online") { engine.connection == .online }
        await engine.shutdown()
    }

    func testWaitingForNetworkDoesNothingUntilTheNetworkReturns() async {
        let relay = FakeSocketRelay()
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        relay.send(.network(available: false))
        await until("waiting for network") { engine.connection == .waitingForNetwork }
        clock.advance(120)
        engine.tickConnection()
        XCTAssertEqual(relay.refreshes, 0)
        relay.send(.network(available: true))
        await until("the refresh") { relay.refreshes == 1 }
        await until("online") { engine.connection == .online }
        await engine.shutdown()
    }

    func testUnauthenticatedFromAQueryRefreshesAndReplacesTheClient() async {
        let relay = FakeSocketRelay()
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        let failing = LiveQuery<Int>(engine: engine) {
            RelayStream { $0.finish(throwing: RelayError(.unauthenticated, "Sign in first.")) }
        }
        failing.start()
        await until("a new client") { relay.refreshes >= 1 && relay.replacements == 1 }
        XCTAssertEqual(failing.error?.code, .unauthenticated)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(relay.replacements, 1, "not again within 15 s, however often the query fails")
        failing.stop()
        await engine.shutdown()
    }

    func testAQueryWaitingOutItsBackoffTriesAgainOnTheNewClient() async {
        let relay = FakeSocketRelay()
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        await online(relay, engine)
        let attempts = DeviceTokenSourceTests.Counter()
        let query = LiveQuery<Int>(engine: engine) {
            let n = attempts.next()
            return RelayStream { continuation in
                if n < 3 {
                    continuation.finish(throwing: RelayError(.network, "Can't reach the relay."))
                } else {
                    continuation.yield(n)
                }
            }
        }
        query.start()
        // Two failures put it into a 2 s backoff.
        await until("two attempts") { attempts.count == 2 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(attempts.count, 2)
        relay.send(.socket(connected: false))
        engine.handleUnauthenticated()
        await until("the value from the new client") { query.value == 3 }
        query.stop()
        await engine.shutdown()
    }

    func testReplaysDoNotCountAsSync() async {
        // A screen that attaches to a shared query gets its last value replayed; only results from the socket (the
        // backend's `.synced`) make the title say online.
        let relay = FakeSocketRelay()
        let clock = Clock()
        let engine = makeEngine(relay, clock: clock)
        engine.start()
        await Task.yield()
        relay.send(.network(available: true))
        relay.send(.socket(connected: true))
        let query = LiveQuery<Int>(engine: engine) { RelayStream { $0.yield(1) } }
        query.start()
        await until("the replayed value") { query.value == 1 }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(engine.connection, .updating)
        relay.send(.synced)
        await until("online") { engine.connection == .online }
        query.stop()
        await engine.shutdown()
    }
}
