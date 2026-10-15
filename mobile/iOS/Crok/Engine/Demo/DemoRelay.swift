import Foundation

/// The relay facades over `DemoWorld`, for `-CrokDemo YES` and the UI tests. No network.
final class DemoRelay: RelayBackend, SessionsAPI, CommandsAPI, DevicesAPI, AccountAPI, @unchecked Sendable {
    let world: DemoWorld

    @MainActor
    init(world: DemoWorld = DemoWorld()) {
        self.world = world
    }

    var sessions: any SessionsAPI { self }
    var commands: any CommandsAPI { self }
    var devices: any DevicesAPI { self }
    var account: any AccountAPI { self }

    func connectionSignals() -> AsyncStream<ConnectionSignal> {
        AsyncStream { continuation in
            continuation.yield(.network(available: true))
            continuation.yield(.socket(connected: true))
        }
    }

    func start() async {}
    func shutdown() async {}

    /// Emits `compute(world)` now and after every change, skipping repeats.
    private func observe<T: Sendable & Equatable>(_ compute: @escaping @MainActor (DemoWorld) throws -> T) -> RelayStream<T> {
        let world = self.world
        return AsyncThrowingStream { continuation in
            let id = UUID()
            Task { @MainActor in
                var last: T?
                let emit: @MainActor () -> Void = {
                    do {
                        let value = try compute(world)
                        if value != last {
                            last = value
                            continuation.yield(value)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                world.addObserver(id, emit)
                emit()
            }
            continuation.onTermination = { _ in
                Task { @MainActor in world.removeObserver(id) }
            }
        }
    }

    private func mutate<T: Sendable>(_ delay: Duration = .milliseconds(150), _ body: @escaping @MainActor (DemoWorld) throws -> T)
        async throws -> T
    {
        try await Task.sleep(for: delay)
        let world = self.world
        return try await MainActor.run {
            let result = try body(world)
            world.changed()
            return result
        }
    }

    // MARK: SessionsAPI

    func list(archived: Bool) -> RelayStream<[SessionRow]> { observe { $0.rows(archived: archived) } }

    func get(_ sessionDocId: DocID) -> RelayStream<SessionDetail> {
        observe { world in world.sessions[try world.index(of: sessionDocId)].detail }
    }

    func events(_ sessionDocId: DocID, cursor: String?, endCursor: String?, numItems: Int) -> RelayStream<EventsPage> {
        observe { try $0.eventsPage(sessionDocId, cursor: cursor, endCursor: endCursor, numItems: numItems) }
    }

    func markRead(_ sessionDocId: DocID) async throws {
        try await mutate(.zero) { world in world.sessions[try world.index(of: sessionDocId)].detail.unread = 0 }
    }

    func watch(_ sessionDocId: DocID) async throws {}

    func setPinned(_ sessionDocId: DocID, _ pinned: Bool) async throws {
        try await mutate { world in world.sessions[try world.index(of: sessionDocId)].detail.pinned = pinned }
    }

    func setArchived(_ sessionDocId: DocID, _ archived: Bool) async throws {
        try await mutate { world in
            let i = try world.index(of: sessionDocId)
            world.sessions[i].detail.archived = archived
            if archived { world.sessions[i].detail.pinned = false }
        }
    }

    func remove(_ sessionDocId: DocID) async throws {
        try await mutate { world in
            let i = try world.index(of: sessionDocId)
            if world.sessions[i].detail.online {
                throw RelayError(.invalid, "Close the session on the computer first, or archive it.")
            }
            world.sessions.remove(at: i)
        }
    }

    // MARK: CommandsAPI

    func sendPrompt(_ sessionDocId: DocID, text: String, clientId: String) async throws -> DocID {
        try await mutate(.milliseconds(350)) { world in
            let i = try world.index(of: sessionDocId)
            if let existing = world.sessions[i].commands.first(where: { $0.clientId == clientId }) { return existing.id }
            guard world.sessions[i].detail.online else {
                throw RelayError(.offline, "This session is not running on its computer right now.")
            }
            let id = world.newId("command")
            let now = Date().milliseconds
            world.sessions[i].commands.insert(
                PromptCommand(
                    id: id, clientId: clientId, text: text, status: .pending, error: nil, fromLabel: "Charlie's iPhone",
                    fromDeviceId: world.currentDeviceId, mine: true, createdAt: now, updatedAt: now), at: 0)
            world.runPrompt(sessionId: sessionDocId, commandId: id, text: text)
            return id
        }
    }

    func stop(_ sessionDocId: DocID) async throws -> DocID {
        try await mutate { world in
            world.stopTurn(sessionId: sessionDocId)
            return world.newId("command")
        }
    }

    func requestInfo(_ sessionDocId: DocID) async throws -> DocID {
        try await mutate { world in
            let id = world.newId("command")
            world.infoCommands[id] = CommandRecord(id: id, type: "info", status: .pending)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                world.infoCommands[id] = CommandRecord(id: id, type: "info", status: .done, result: world.info(for: sessionDocId))
                world.changed()
            }
            return id
        }
    }

    func get(_ commandId: DocID) -> RelayStream<CommandRecord?> { observe { $0.infoCommands[commandId] } }

    func forSession(_ sessionDocId: DocID) -> RelayStream<[PromptCommand]> {
        observe { world in world.sessions[try world.index(of: sessionDocId)].commands }
    }

    func retry(_ commandId: DocID) async throws {
        try await mutate { world in
            guard let i = world.sessions.firstIndex(where: { $0.commands.contains(where: { $0.id == commandId }) }),
                let command = world.sessions[i].commands.first(where: { $0.id == commandId })
            else { throw RelayError(.notFound, "No such prompt.") }
            world.setCommand(i, commandId, status: .pending)
            world.runPrompt(sessionId: world.sessions[i].detail.id, commandId: commandId, text: command.text)
        }
    }

    func discard(_ commandId: DocID) async throws {
        try await mutate { world in
            for i in world.sessions.indices { world.sessions[i].commands.removeAll(where: { $0.id == commandId && $0.status == .failed }) }
        }
    }

    // MARK: DevicesAPI

    func list() -> RelayStream<[DeviceRow]> { observe { $0.devices } }

    func rename(_ deviceId: DocID, name: String) async throws {
        try await mutate { world in
            if let i = world.devices.firstIndex(where: { $0.id == deviceId }) { world.devices[i].name = name }
        }
    }

    func revoke(_ deviceId: DocID) async throws {
        try await mutate { world in
            world.devices.removeAll(where: { $0.id == deviceId })
            for i in world.sessions.indices where world.sessions[i].detail.deviceId == deviceId {
                world.sessions[i].detail.online = false
                world.sessions[i].detail.status = .idle
            }
        }
    }

    func revokeOthers() async throws -> Int {
        try await mutate { world in
            let others = world.devices.filter { !$0.isCurrent }
            for device in others {
                world.devices.removeAll(where: { $0.id == device.id })
                for i in world.sessions.indices where world.sessions[i].detail.deviceId == device.id {
                    world.sessions[i].detail.online = false
                    world.sessions[i].detail.status = .idle
                }
            }
            return others.count
        }
    }

    // MARK: AccountAPI

    func me() -> RelayStream<AccountInfo?> { observe { $0.me } }

    func pendingLogin(userCode: String) -> RelayStream<PendingLoginInfo?> {
        observe { _ in
            guard UserCode.normalize(userCode) != nil else { return nil }
            let now = Date().milliseconds
            return PendingLoginInfo(
                userCode: userCode, kind: .computer, name: "Linux workstation", platform: "Linux 6.8 x86_64",
                client: "crok 1.0.45", createdAt: now - 40_000, expiresAt: now + 560_000, status: "pending")
        }
    }

    func approve(userCode: String) async throws -> ApprovedDevice {
        try await mutate(.milliseconds(500)) { world in
            let id = world.newId("device")
            world.devices.append(
                DeviceRow(
                    id: id, kind: .computer, name: "Linux workstation", platform: "Linux 6.8 x86_64", client: "crok 1.0.45",
                    createdAt: Date().milliseconds, lastSeenAt: Date().milliseconds, online: false, isCurrent: false,
                    liveSessionCount: 0))
            return ApprovedDevice(deviceId: id, kind: .computer, name: "Linux workstation")
        }
    }

    func deny(userCode: String) async throws {}
}

/// Device sign-in without a server: shows a code and, when asked to, approves it after a few seconds.
final class DemoDeviceAuthService: DeviceAuthService, @unchecked Sendable {
    private let approveAfter: TimeInterval?
    private let lock = NSLock()
    private var startedAt: Date?

    init(approveAfter: TimeInterval?) {
        self.approveAfter = approveAfter
    }

    func start(kind: DeviceKind, name: String, platform: String, client: String) async throws -> DeviceAuthStart {
        try await Task.sleep(for: .milliseconds(400))
        lock.withLock { startedAt = Date() }
        return DeviceAuthStart(
            deviceCode: "crd_demo", userCode: "BCDF-GHJK", verificationUrl: "https://crok.example/link",
            verificationUrlComplete: "https://crok.example/link?code=BCDF-GHJK", expiresAt: Date().milliseconds + 600_000,
            interval: 2)
    }

    func poll(deviceCode: String) async throws -> DeviceAuthPoll {
        let started = lock.withLock { startedAt ?? Date() }
        if let approveAfter, Date().timeIntervalSince(started) >= approveAfter {
            return .approved(
                DeviceApproval(
                    deviceId: "demo-phone", refreshToken: "crr_demo", accessToken: "demo.jwt.token",
                    accessTokenExpiresAt: Date().milliseconds + 3_600_000,
                    user: AccountUser(name: "Charlie Lee", email: "charlie@example.com", imageUrl: nil)))
        }
        return .pending
    }

    func logout(refreshToken: String) async throws {}
}
