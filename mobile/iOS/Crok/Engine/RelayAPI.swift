import Foundation

// The typed facades screens use (Telegram's TelegramEngine idea: `engine.sessions`, `engine.commands`, …). A live
// relay (ConvexMobile) and the demo relay both implement them, so every screen runs unchanged in demo mode.

/// A live query: a new value whenever the relay's result changes. It ends by throwing a `RelayError` when the query
/// fails (ConvexMobile completes a subscription on its first error); `LiveQuery` subscribes again.
typealias RelayStream<T> = AsyncThrowingStream<T, Error>

protocol SessionsAPI: Sendable {
    func list(archived: Bool) -> RelayStream<[SessionRow]>
    func get(_ sessionDocId: DocID) -> RelayStream<SessionDetail>
    /// Newest first. `endCursor` pins where a page ends, so pages stay contiguous as new events arrive.
    func events(_ sessionDocId: DocID, cursor: String?, endCursor: String?, numItems: Int) -> RelayStream<EventsPage>
    func markRead(_ sessionDocId: DocID) async throws
    func watch(_ sessionDocId: DocID) async throws
    func setPinned(_ sessionDocId: DocID, _ pinned: Bool) async throws
    func setArchived(_ sessionDocId: DocID, _ archived: Bool) async throws
    func remove(_ sessionDocId: DocID) async throws
}

protocol CommandsAPI: Sendable {
    func sendPrompt(_ sessionDocId: DocID, text: String, clientId: String) async throws -> DocID
    func stop(_ sessionDocId: DocID) async throws -> DocID
    func requestInfo(_ sessionDocId: DocID) async throws -> DocID
    func get(_ commandId: DocID) -> RelayStream<CommandRecord?>
    func forSession(_ sessionDocId: DocID) -> RelayStream<[PromptCommand]>
    func retry(_ commandId: DocID) async throws
    func discard(_ commandId: DocID) async throws
}

protocol DevicesAPI: Sendable {
    func list() -> RelayStream<[DeviceRow]>
    func rename(_ deviceId: DocID, name: String) async throws
    func revoke(_ deviceId: DocID) async throws
    func revokeOthers() async throws -> Int
}

protocol AccountAPI: Sendable {
    func me() -> RelayStream<AccountInfo?>
    func pendingLogin(userCode: String) -> RelayStream<PendingLoginInfo?>
    func approve(userCode: String) async throws -> ApprovedDevice
    func deny(userCode: String) async throws
}

/// What the backend reports about its link to the relay.
enum ConnectionSignal: Sendable, Equatable {
    case network(available: Bool)
    case socket(connected: Bool)
}

/// One signed-in account's link to the relay. `CrokEngine` owns exactly one and tears it down on sign-out.
protocol RelayBackend: AnyObject, Sendable {
    var sessions: any SessionsAPI { get }
    var commands: any CommandsAPI { get }
    var devices: any DevicesAPI { get }
    var account: any AccountAPI { get }

    /// Network and socket changes, starting with the current state.
    func connectionSignals() -> AsyncStream<ConnectionSignal>
    /// Authenticates (retrying while offline) and lets queries run. Returns when authenticated or revoked.
    func start() async
    /// Signs the client out and stops every subscription.
    func shutdown() async
}

/// The device sign-in calls, made over the HTTP API (no auth needed).
protocol DeviceAuthService: Sendable {
    func start(kind: DeviceKind, name: String, platform: String, client: String) async throws -> DeviceAuthStart
    func poll(deviceCode: String) async throws -> DeviceAuthPoll
    func logout(refreshToken: String) async throws
}

struct LiveDeviceAuthService: DeviceAuthService {
    var http: ConvexHTTPClient

    func start(kind: DeviceKind, name: String, platform: String, client: String) async throws -> DeviceAuthStart {
        try await http.mutation(
            "deviceAuth:start",
            ["kind": .string(kind.rawValue), "name": .string(name), "platform": .string(platform), "client": .string(client)])
    }

    func poll(deviceCode: String) async throws -> DeviceAuthPoll {
        try await http.mutation("deviceAuth:poll", ["deviceCode": .string(deviceCode)])
    }

    func refresh(refreshToken: String) async throws -> DeviceAccessToken {
        try await http.mutation("deviceAuth:refresh", ["refreshToken": .string(refreshToken)])
    }

    func logout(refreshToken: String) async throws {
        let _: Nothing = try await http.mutation("deviceAuth:logout", ["refreshToken": .string(refreshToken)])
    }
}
