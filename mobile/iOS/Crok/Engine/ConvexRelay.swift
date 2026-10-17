import Combine
import Foundation
import Network
@preconcurrency import ConvexMobile

extension JSONValue: ConvexEncodable {}

/// Opens once the client is authenticated; queries and mutations wait for it, so nothing runs as an anonymous caller.
actor AuthGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Keeps a Combine subscription alive until the async stream that wraps it ends.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: AnyCancellable?
    private var cancelled = false

    func set(_ value: AnyCancellable) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { value.cancel() } else { cancellable = value }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        cancellable?.cancel()
        cancellable = nil
    }
}

/// The relay over ConvexMobile: one WebSocket client at a time per signed-in account, authenticated with the device's
/// JWT. The client is replaceable (`replaceClient`): ConvexMobile's own reconnect can hang for good (its connect has no
/// timeout, and every query and mutation then waits behind it), so the engine's `ConnectionKeeper` swaps in a new one;
/// subscriptions move over through the `QueryHub`, and calls waiting on the old client are sent again on the new one.
final class ConvexRelay: RelayBackend, SessionsAPI, CommandsAPI, DevicesAPI, AccountAPI, @unchecked Sendable {
    /// One ConvexMobile client and its auth provider.
    private final class Generation: @unchecked Sendable {
        let number: Int
        let client: ConvexClientWithAuth<DeviceAccessToken>
        let provider: DeviceAuthProvider
        private let lock = NSLock()
        private var socketSink: AnyCancellable?
        private var retired = false
        private var retireWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        private var cancelledWaiters: Set<UUID> = []

        init(number: Int, serverURL: URL, tokens: DeviceTokenSource) {
            self.number = number
            provider = DeviceAuthProvider(tokens: tokens)
            client = ConvexClientWithAuth(deploymentUrl: serverURL.absoluteString, authProvider: provider)
        }

        func watchSocket(_ sink: AnyCancellable) {
            lock.withLock { socketSink = sink }
        }

        var isRetired: Bool { lock.withLock { retired } }

        /// Returns once this client is retired (at once if it already is), or when the waiting task is cancelled.
        func waitRetired() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        if retired || cancelledWaiters.remove(id) != nil { return true }
                        retireWaiters[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    if let waiter = retireWaiters.removeValue(forKey: id) { return waiter }
                    if !retired { cancelledWaiters.insert(id) }
                    return nil
                }
                waiter?.resume()
            }
        }

        func retire() {
            let (waiters, sink): ([CheckedContinuation<Void, Never>], AnyCancellable?) = lock.withLock {
                guard !retired else { return ([], nil) }
                retired = true
                let waiters = Array(retireWaiters.values)
                retireWaiters.removeAll()
                let sink = socketSink
                socketSink = nil
                return (waiters, sink)
            }
            sink?.cancel()
            provider.cancelTimer()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// A call that was waiting on a client that has since been replaced.
    private struct Replaced: Error {}

    /// How long a replacement client may take to sign in before the attempt is given up (the keeper tries again).
    static let replaceLoginTimeout: TimeInterval = 15

    private let serverURL: URL
    private let tokens: DeviceTokenSource
    private let gate = AuthGate()
    private let hub = QueryHub()
    private let lock = NSLock()
    private var stopped = false
    private var generation: Generation
    /// The newest client made, whose socket state the signals report (during a replacement, the one signing in).
    private var newestNumber: Int
    private var socketConnected = false
    private var signalSinks: [UUID: AsyncStream<ConnectionSignal>.Continuation] = [:]
    private var monitors: [NWPathMonitor] = []

    init(serverURL: URL, credentials: StoredCredentials, initialToken: DeviceAccessToken?, onRevoked: @escaping @Sendable () -> Void) {
        let http = LiveDeviceAuthService(http: ConvexHTTPClient(deploymentURL: serverURL))
        self.serverURL = serverURL
        tokens = DeviceTokenSource(
            refreshToken: credentials.refreshToken, initialToken: initialToken,
            fetch: { refreshToken in try await http.refresh(refreshToken: refreshToken) }, onRevoked: onRevoked)
        generation = Generation(number: 1, serverURL: serverURL, tokens: tokens)
        newestNumber = 1
        watchSocket(of: generation)
    }

    var sessions: any SessionsAPI { self }
    var commands: any CommandsAPI { self }
    var devices: any DevicesAPI { self }
    var account: any AccountAPI { self }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private var current: Generation {
        lock.withLock { generation }
    }

    // MARK: Lifecycle

    func start() async {
        var attempt = 0
        while !isStopped {
            let first = current
            switch await first.client.login() {
            case .success:
                await gate.open()
                return
            case .failure(let error):
                if (error as? RelayError)?.isRevoked == true { return }
                // A replacement signed in meanwhile (and opened the gate).
                if first !== current { return }
                attempt += 1
                try? await Task.sleep(for: Backoff.delay(attempt: attempt))
            }
        }
    }

    func shutdown() async {
        let (monitors, sinks, last) = lock.withLock {
            stopped = true
            let state = (self.monitors, Array(signalSinks.values), generation)
            self.monitors.removeAll()
            signalSinks.removeAll()
            return state
        }
        for monitor in monitors { monitor.cancel() }
        for sink in sinks { sink.finish() }
        hub.removeAll()
        last.retire()
        await last.client.logout()
        await gate.open()
    }

    func refreshAuth() async throws {
        guard !isStopped else { return }
        try await current.provider.pushFresh()
    }

    func replaceClient() async {
        guard !isStopped else { return }
        let number = lock.withLock { () -> Int in
            newestNumber += 1
            return newestNumber
        }
        let fresh = Generation(number: number, serverURL: serverURL, tokens: tokens)
        setSocket(connected: false)
        watchSocket(of: fresh)
        let signedIn: Bool
        do {
            signedIn = try await withTimeout(seconds: Self.replaceLoginTimeout) {
                switch await fresh.client.login() {
                case .success: true
                case .failure: false
                }
            }
        } catch {
            signedIn = false
        }
        guard signedIn, !isStopped else {
            // Give up on this one; the keeper tries again later. The old client stays meanwhile.
            fresh.retire()
            Self.dispose(fresh)
            lock.withLock { if newestNumber == number { newestNumber = generation.number } }
            return
        }
        let old = lock.withLock { () -> Generation in
            let old = generation
            generation = fresh
            return old
        }
        hub.restartAll()
        await gate.open()
        old.retire()
        Self.dispose(old)
    }

    /// Signs a retired client out and lets it go off the main thread: dropping ConvexMobile's Rust client shuts down
    /// its runtime, which blocks until its threads finish, and must not happen on a thread of that runtime.
    private static func dispose(_ retired: Generation) {
        Task.detached(priority: .utility) {
            _ = try? await withTimeout(seconds: 5) { await retired.client.logout() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                withExtendedLifetime(retired) {}
            }
        }
    }

    // MARK: Signals

    func connectionSignals() -> AsyncStream<ConnectionSignal> {
        let monitor = NWPathMonitor()
        return AsyncStream { continuation in
            let id = UUID()
            let connected = lock.withLock { () -> Bool in
                signalSinks[id] = continuation
                monitors.append(monitor)
                return socketConnected
            }
            continuation.yield(.socket(connected: connected))
            let lastPath = PathMemory()
            monitor.pathUpdateHandler = { path in
                let available = path.status == .satisfied
                let interface = path.availableInterfaces.first.map { "\($0.type):\($0.name)" }
                if lastPath.changed(available: available, interface: interface) {
                    continuation.yield(.pathChanged)
                } else {
                    continuation.yield(.network(available: available))
                }
            }
            monitor.start(queue: DispatchQueue(label: "dev.chenli.crok.path"))
            continuation.onTermination = { [weak self] _ in
                monitor.cancel()
                self?.lock.withLock { _ = self?.signalSinks.removeValue(forKey: id) }
            }
        }
    }

    /// Tells a network switch (still available, other interface) apart from the network coming and going.
    private final class PathMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var available: Bool?
        private var interface: String?

        func changed(available: Bool, interface: String?) -> Bool {
            lock.withLock {
                defer {
                    self.available = available
                    self.interface = interface
                }
                return self.available == true && available && self.interface != nil && interface != self.interface
            }
        }
    }

    private func broadcast(_ signal: ConnectionSignal) {
        let sinks = lock.withLock { Array(signalSinks.values) }
        for sink in sinks { sink.yield(signal) }
    }

    private func setSocket(connected: Bool) {
        lock.withLock { socketConnected = connected }
        broadcast(.socket(connected: connected))
    }

    private func watchSocket(of generation: Generation) {
        let number = generation.number
        let sink = generation.client.watchWebSocketState().sink { [weak self] state in
            guard let self, self.lock.withLock({ self.newestNumber == number }) else { return }
            switch state {
            case .connected: self.setSocket(connected: true)
            case .connecting: self.setSocket(connected: false)
            }
        }
        generation.watchSocket(sink)
    }

    // MARK: Transport

    static func relayError(_ error: Error) -> RelayError {
        if let relay = error as? RelayError { return relay }
        if let clientError = error as? ClientError {
            switch clientError {
            case .ConvexError(let data): return RelayError.fromConvexData(data)
            case .ServerError(let message): return RelayError(.server, RelayError.cleanServerMessage(message))
            case .InternalError(let message): return RelayError(.server, message)
            }
        }
        return RelayError.network(error)
    }

    /// A live query, shared through the hub with everyone watching the same query and arguments. It runs on whichever
    /// client is current, and moves to a new one when the client is replaced.
    private func observe<T: Decodable & Sendable>(_ name: String, _ args: [String: JSONValue] = [:]) -> RelayStream<T> {
        let key = QueryHub.key(name, args)
        let hub = self.hub
        return AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.gate.wait()
                guard !Task.isCancelled, !self.isStopped else {
                    continuation.finish()
                    return
                }
                hub.attach(
                    key: key, id: id,
                    onValue: { value in
                        if let typed = value as? T { continuation.yield(typed) }
                    },
                    onError: { error in continuation.finish(throwing: error) },
                    start: { [weak self] deliver, fail in
                        guard let self else { return AnyCancellable {} }
                        let convexArgs: [String: ConvexEncodable?] = args.mapValues { $0 }
                        return self.current.client.subscribe(to: name, with: convexArgs, yielding: T.self).sink(
                            receiveCompletion: { completion in
                                switch completion {
                                case .finished: fail(RelayError(.server, String(localized: "Something went wrong on the relay.")))
                                case .failure(let error): fail(Self.relayError(error))
                                }
                            },
                            receiveValue: { [weak self] value in
                                deliver(value)
                                self?.broadcast(.synced)
                            })
                    })
            }
            continuation.onTermination = { _ in
                task.cancel()
                hub.detach(key: key, id: id)
            }
        }
    }

    /// A mutation on the current client. If the client is replaced while the call waits (a stuck socket), it is sent
    /// again on the new one; calls that create things carry a client id, so a repeat is harmless.
    private func call<T: Decodable & Sendable>(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        await gate.wait()
        while true {
            if isStopped { throw RelayError(.unauthenticated, String(localized: "Signed out.")) }
            let generation = current
            do {
                return try await send(name, args, on: generation)
            } catch is Replaced {
                continue
            } catch {
                if generation.isRetired && !isStopped { continue }
                throw Self.relayError(error)
            }
        }
    }

    /// Runs one mutation on `generation`, giving up with `Replaced` as soon as that client is retired. A stuck
    /// ConvexMobile call cannot be cancelled, so it is left behind rather than awaited.
    private func send<T: Decodable & Sendable>(_ name: String, _ args: [String: JSONValue], on generation: Generation)
        async throws -> T
    {
        let client = UncheckedClient(client: generation.client)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let outcome = FirstOutcome(continuation)
            let mutation = Task {
                do {
                    let convexArgs: [String: ConvexEncodable?] = args.mapValues { $0 }
                    let value: T = try await client.client.mutation(name, with: convexArgs)
                    outcome.finish(.success(value))
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            let watcher = Task {
                await generation.waitRetired()
                guard !Task.isCancelled else { return }
                outcome.finish(.failure(Replaced()))
                mutation.cancel()
            }
            outcome.whenFinished { watcher.cancel() }
        }
    }

    /// Resumes a continuation with whichever result comes first.
    private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var cleanups: [@Sendable () -> Void] = []

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<T, Error>) {
            let (continuation, cleanups) = lock.withLock { () -> (CheckedContinuation<T, Error>?, [@Sendable () -> Void]) in
                let pending = (self.continuation, self.cleanups)
                self.continuation = nil
                self.cleanups.removeAll()
                return pending
            }
            guard let continuation else { return }
            continuation.resume(with: result)
            for cleanup in cleanups { cleanup() }
        }

        /// Runs `cleanup` once a result is in (at once if it already is).
        func whenFinished(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = lock.withLock { () -> Bool in
                guard continuation != nil else { return true }
                cleanups.append(cleanup)
                return false
            }
            if runNow { cleanup() }
        }
    }

    private struct UncheckedClient: @unchecked Sendable {
        let client: ConvexClientWithAuth<DeviceAccessToken>
    }

    private func run(_ name: String, _ args: [String: JSONValue] = [:]) async throws {
        let _: Nothing = try await call(name, args)
    }

    // MARK: SessionsAPI

    func groups() -> RelayStream<[ProjectGroup]> {
        observe("sessions:groups")
    }

    func list(archived: Bool) -> RelayStream<[SessionRow]> {
        observe("sessions:list", ["archived": .bool(archived)])
    }

    func reorderProjects(_ keys: [String]) async throws {
        try await run("sessions:reorderProjects", ["keys": .array(keys.map(JSONValue.string))])
    }

    func reorderSessions(projectKey: String, _ sessionDocIds: [DocID]) async throws {
        try await run(
            "sessions:reorderSessions",
            ["projectKey": .string(projectKey), "sessionDocIds": .array(sessionDocIds.map(JSONValue.string))])
    }

    func resetOrder(projectKey: String?) async throws {
        // An optional argument is left out, not sent as null.
        try await run("sessions:resetOrder", projectKey.map { ["projectKey": .string($0)] } ?? [:])
    }

    func get(_ sessionDocId: DocID) -> RelayStream<SessionDetail> {
        observe("sessions:get", ["sessionDocId": .string(sessionDocId)])
    }

    func events(_ sessionDocId: DocID, cursor: String?, endCursor: String?, numItems: Int) -> RelayStream<EventsPage> {
        var options: [String: JSONValue] = [
            "numItems": .number(Double(numItems)),
            "cursor": cursor.map(JSONValue.string) ?? .null,
        ]
        if let endCursor { options["endCursor"] = .string(endCursor) }
        return observe("sessions:events", ["sessionDocId": .string(sessionDocId), "paginationOpts": .object(options)])
    }

    func markRead(_ sessionDocId: DocID) async throws {
        try await run("sessions:markRead", ["sessionDocId": .string(sessionDocId)])
    }

    func watch(_ sessionDocId: DocID) async throws {
        try await run("sessions:watch", ["sessionDocId": .string(sessionDocId)])
    }

    func setPinned(_ sessionDocId: DocID, _ pinned: Bool) async throws {
        try await run("sessions:setPinned", ["sessionDocId": .string(sessionDocId), "pinned": .bool(pinned)])
    }

    func setArchived(_ sessionDocId: DocID, _ archived: Bool) async throws {
        try await run("sessions:setArchived", ["sessionDocId": .string(sessionDocId), "archived": .bool(archived)])
    }

    func remove(_ sessionDocId: DocID) async throws {
        try await run("sessions:remove", ["sessionDocId": .string(sessionDocId)])
    }

    func create(deviceId: DocID, path: String, text: String?, clientId: String) async throws -> CreatedSession {
        var args: [String: JSONValue] = ["deviceId": .string(deviceId), "path": .string(path), "clientId": .string(clientId)]
        if let text, !text.isEmpty { args["text"] = .string(text) }
        return try await call("sessions:create", args)
    }

    func slashCommands(_ sessionDocId: DocID) -> RelayStream<SlashCommandList> {
        observe("sessions:commands", ["sessionDocId": .string(sessionDocId)])
    }

    // MARK: CommandsAPI

    func sendPrompt(_ sessionDocId: DocID, text: String, clientId: String) async throws -> DocID {
        let ref: CommandRef = try await call(
            "commands:sendPrompt",
            ["sessionDocId": .string(sessionDocId), "text": .string(text), "clientId": .string(clientId)])
        return ref.commandId
    }

    func stop(_ sessionDocId: DocID) async throws -> DocID {
        let ref: CommandRef = try await call("commands:stop", ["sessionDocId": .string(sessionDocId)])
        return ref.commandId
    }

    func requestInfo(_ sessionDocId: DocID) async throws -> DocID {
        let ref: CommandRef = try await call("commands:requestInfo", ["sessionDocId": .string(sessionDocId)])
        return ref.commandId
    }

    func answer(_ sessionDocId: DocID, interactionId: String, optionId: String) async throws -> DocID {
        let ref: CommandRef = try await call(
            "commands:answer",
            ["sessionDocId": .string(sessionDocId), "interactionId": .string(interactionId), "optionId": .string(optionId)])
        return ref.commandId
    }

    func setConfig(_ sessionDocId: DocID, configId: ConfigOption, value: String) async throws -> DocID {
        let ref: CommandRef = try await call(
            "commands:setConfig",
            ["sessionDocId": .string(sessionDocId), "configId": .string(configId.rawValue), "value": .string(value)])
        return ref.commandId
    }

    func get(_ commandId: DocID) -> RelayStream<CommandRecord?> {
        observe("commands:get", ["commandId": .string(commandId)])
    }

    func forSession(_ sessionDocId: DocID) -> RelayStream<[PromptCommand]> {
        observe("commands:forSession", ["sessionDocId": .string(sessionDocId)])
    }

    func retry(_ commandId: DocID) async throws {
        try await run("commands:retry", ["commandId": .string(commandId)])
    }

    func discard(_ commandId: DocID) async throws {
        try await run("commands:discard", ["commandId": .string(commandId)])
    }

    // MARK: DevicesAPI

    func list() -> RelayStream<[DeviceRow]> {
        observe("devices:list")
    }

    func rename(_ deviceId: DocID, name: String) async throws {
        try await run("devices:rename", ["deviceId": .string(deviceId), "name": .string(name)])
    }

    func revoke(_ deviceId: DocID) async throws {
        try await run("devices:revoke", ["deviceId": .string(deviceId)])
    }

    func revokeOthers() async throws -> Int {
        let result: RevokeCount = try await call("devices:revokeOthers")
        return Int(result.count)
    }

    // MARK: AccountAPI

    func me() -> RelayStream<AccountInfo?> {
        observe("users:me")
    }

    func pendingLogin(userCode: String) -> RelayStream<PendingLoginInfo?> {
        observe("deviceAuth:pendingLogin", ["userCode": .string(userCode)])
    }

    func approve(userCode: String) async throws -> ApprovedDevice {
        try await call("deviceAuth:approve", ["userCode": .string(userCode)])
    }

    func deny(userCode: String) async throws {
        try await run("deviceAuth:deny", ["userCode": .string(userCode)])
    }
}

/// Exponential backoff with a cap, for reconnect and resubscribe loops.
enum Backoff {
    static func delay(attempt: Int, base: Double = 1, cap: Double = 30) -> Duration {
        let seconds = min(cap, base * pow(2, Double(max(0, attempt - 1))))
        return .milliseconds(Int(seconds * 1000))
    }
}
