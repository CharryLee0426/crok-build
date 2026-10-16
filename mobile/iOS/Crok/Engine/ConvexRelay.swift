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

/// The relay over ConvexMobile: one WebSocket client per signed-in account, authenticated with the device's JWT.
final class ConvexRelay: RelayBackend, SessionsAPI, CommandsAPI, DevicesAPI, AccountAPI, @unchecked Sendable {
    private let client: ConvexClientWithAuth<DeviceAccessToken>
    private let provider: DeviceAuthProvider
    private let gate = AuthGate()
    private let hub = QueryHub()
    private let lock = NSLock()
    private var stopped = false
    private var monitors: [NWPathMonitor] = []

    init(serverURL: URL, credentials: StoredCredentials, initialToken: DeviceAccessToken?, onRevoked: @escaping @Sendable () -> Void) {
        let service = LiveDeviceAuthService(http: ConvexHTTPClient(deploymentURL: serverURL))
        provider = DeviceAuthProvider(
            service: service, refreshToken: credentials.refreshToken, initialToken: initialToken, onRevoked: onRevoked)
        client = ConvexClientWithAuth(deploymentUrl: serverURL.absoluteString, authProvider: provider)
    }

    var sessions: any SessionsAPI { self }
    var commands: any CommandsAPI { self }
    var devices: any DevicesAPI { self }
    var account: any AccountAPI { self }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: Lifecycle

    func start() async {
        var attempt = 0
        while !isStopped {
            switch await client.login() {
            case .success:
                await gate.open()
                return
            case .failure(let error):
                if (error as? RelayError)?.isRevoked == true { return }
                attempt += 1
                try? await Task.sleep(for: Backoff.delay(attempt: attempt))
            }
        }
    }

    func shutdown() async {
        let monitors = lock.withLock {
            stopped = true
            let current = self.monitors
            self.monitors.removeAll()
            return current
        }
        for monitor in monitors { monitor.cancel() }
        hub.removeAll()
        provider.cancelTimer()
        await client.logout()
        await gate.open()
    }

    func connectionSignals() -> AsyncStream<ConnectionSignal> {
        let box = CancelBox()
        let monitor = NWPathMonitor()
        lock.lock()
        monitors.append(monitor)
        lock.unlock()
        let socket = client.watchWebSocketState()
        return AsyncStream { continuation in
            continuation.yield(.socket(connected: false))
            monitor.pathUpdateHandler = { path in
                continuation.yield(.network(available: path.status == .satisfied))
            }
            monitor.start(queue: DispatchQueue(label: "dev.chenli.crok.path"))
            box.set(
                socket.sink { state in
                    switch state {
                    case .connected: continuation.yield(.socket(connected: true))
                    case .connecting: continuation.yield(.socket(connected: false))
                    }
                })
            continuation.onTermination = { _ in
                box.cancel()
                monitor.cancel()
            }
        }
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

    /// A live query, shared through the hub with everyone watching the same query and arguments.
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
                let client = self.client
                hub.attach(
                    key: key, id: id,
                    onValue: { value in
                        if let typed = value as? T { continuation.yield(typed) }
                    },
                    onError: { error in continuation.finish(throwing: error) },
                    start: { deliver, fail in
                        let convexArgs: [String: ConvexEncodable?] = args.mapValues { $0 }
                        return client.subscribe(to: name, with: convexArgs, yielding: T.self).sink(
                            receiveCompletion: { completion in
                                switch completion {
                                case .finished: fail(RelayError(.server, String(localized: "Something went wrong on the relay.")))
                                case .failure(let error): fail(Self.relayError(error))
                                }
                            },
                            receiveValue: { value in deliver(value) })
                    })
            }
            continuation.onTermination = { _ in
                task.cancel()
                hub.detach(key: key, id: id)
            }
        }
    }

    private func call<T: Decodable & Sendable>(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        await gate.wait()
        if isStopped { throw RelayError(.unauthenticated, String(localized: "Signed out.")) }
        do {
            let convexArgs: [String: ConvexEncodable?] = args.mapValues { $0 }
            return try await client.mutation(name, with: convexArgs)
        } catch {
            throw Self.relayError(error)
        }
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
