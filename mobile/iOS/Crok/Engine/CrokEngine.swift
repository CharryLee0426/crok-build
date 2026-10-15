import Foundation
import Observation

/// One signed-in account (Telegram's AccountContext + TelegramEngine): owns the relay backend, the connection state,
/// the shared session and device lists, and the prompts this phone is sending. Created on sign-in, torn down on
/// sign-out; screens reach the relay only through it.
@MainActor
@Observable
final class CrokEngine {
    let backend: any RelayBackend
    let credentials: StoredCredentials
    let isDemo: Bool

    /// What the titles show, with the 0.3 s delay applied.
    private(set) var connection: ConnectionStatus = .connecting
    /// Prompts sent from this phone that the transcript may not show yet, per session.
    private(set) var localPrompts: [DocID: [LocalPrompt]] = [:]

    let sessionList: LiveQuery<[SessionRow]>
    let archivedList: LiveQuery<[SessionRow]>
    let deviceList: LiveQuery<[DeviceRow]>
    let account: LiveQuery<AccountInfo?>

    @ObservationIgnored let drafts: DraftStore
    @ObservationIgnored private let cache: SessionListCache?
    @ObservationIgnored private var networkAvailable = true
    @ObservationIgnored private var socketConnected = false
    @ObservationIgnored private var synced = false
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var delayedStatus: DelayedConnectionStatus?
    @ObservationIgnored private var revokedHandled = false
    @ObservationIgnored private var cacheSaveTask: Task<Void, Never>?
    /// Called once when the relay says this device was signed out.
    @ObservationIgnored var onRevoked: (@MainActor () -> Void)?

    var sessions: any SessionsAPI { backend.sessions }
    var commands: any CommandsAPI { backend.commands }
    var devices: any DevicesAPI { backend.devices }
    var accountAPI: any AccountAPI { backend.account }

    init(backend: any RelayBackend, credentials: StoredCredentials, isDemo: Bool, drafts: DraftStore = DraftStore(),
         cache: SessionListCache? = .standard)
    {
        self.backend = backend
        self.credentials = credentials
        self.isDemo = isDemo
        self.drafts = drafts
        self.cache = cache
        let cached = cache?.load(deviceId: credentials.deviceId)
        sessionList = LiveQuery(engine: nil, initial: cached?.sessions) { backend.sessions.list(archived: false) }
        archivedList = LiveQuery(engine: nil) { backend.sessions.list(archived: true) }
        deviceList = LiveQuery(engine: nil, initial: cached?.computers) { backend.devices.list() }
        account = LiveQuery(engine: nil) { backend.account.me() }
    }

    // MARK: Lifecycle

    func start() {
        // LiveQuery holds the engine weakly; attach it now that `self` exists.
        sessionList.setEngine(self)
        archivedList.setEngine(self)
        deviceList.setEngine(self)
        account.setEngine(self)
        // Cold start shows "Connecting…" at once (like Telegram at launch); later drops wait 0.3 s.
        connection = .connecting
        delayedStatus = DelayedConnectionStatus(initial: .connecting) { [weak self] status in
            self?.connection = status
        }
        let signals = backend.connectionSignals()
        connectionTask = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                switch signal {
                case .network(let available):
                    self.networkAvailable = available
                    if !available { self.synced = false }
                case .socket(let connected):
                    if connected != self.socketConnected { self.synced = false }
                    self.socketConnected = connected
                }
                self.recomputeConnection()
            }
        }
        sessionList.onValue = { [weak self] rows in self?.scheduleCacheSave(sessions: rows) }
        deviceList.onValue = { [weak self] _ in self?.scheduleCacheSave(sessions: nil) }
        sessionList.start()
        deviceList.start()
        account.start()
        let backend = self.backend
        startTask = Task {
            await backend.start()
        }
    }

    /// Stops every subscription and signs the client out. The engine is unusable afterwards.
    func shutdown() async {
        connectionTask?.cancel()
        startTask?.cancel()
        cacheSaveTask?.cancel()
        delayedStatus?.cancel()
        sessionList.stop()
        archivedList.stop()
        deviceList.stop()
        account.stop()
        await backend.shutdown()
    }

    /// A query delivered data: the socket is up and the first sync happened.
    func noteDataReceived() {
        guard !synced || !socketConnected else { return }
        socketConnected = true
        synced = true
        recomputeConnection()
    }

    func handleRevoked() {
        guard !revokedHandled else { return }
        revokedHandled = true
        onRevoked?()
    }

    private func recomputeConnection() {
        let status = ConnectionStatus.derive(
            networkAvailable: networkAvailable, socketConnected: socketConnected, synced: synced)
        delayedStatus?.update(status)
    }

    private func scheduleCacheSave(sessions: [SessionRow]?) {
        guard let cache, !isDemo else { return }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let rows = sessions ?? self.sessionList.value ?? []
            let computers = (self.deviceList.value ?? []).filter { $0.kind == .computer }
            let deviceId = self.credentials.deviceId
            Task.detached(priority: .utility) {
                cache.save(deviceId: deviceId, sessions: rows, computers: computers)
            }
        }
    }

    // MARK: Lookups

    func sessionRow(_ id: DocID) -> SessionRow? {
        sessionList.value?.first(where: { $0.id == id }) ?? archivedList.value?.first(where: { $0.id == id })
    }

    var computers: [DeviceRow] {
        (deviceList.value ?? []).filter { $0.kind == .computer }
    }

    // MARK: Actions

    /// Runs a relay call; `REVOKED` signs out, other failures are returned for the caller to show.
    @discardableResult
    func perform(_ work: @escaping @Sendable () async throws -> Void) async -> RelayError? {
        do {
            try await work()
            return nil
        } catch {
            let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
            if relayError.isRevoked { handleRevoked() }
            return relayError
        }
    }

    func setPinned(_ id: DocID, _ pinned: Bool) async -> RelayError? {
        optimisticallyUpdate(id) { $0.pinned = pinned }
        let sessions = self.sessions
        return await perform { try await sessions.setPinned(id, pinned) }
    }

    func setArchived(_ id: DocID, _ archived: Bool) async -> RelayError? {
        let sessions = self.sessions
        return await perform { try await sessions.setArchived(id, archived) }
    }

    func stopTurn(_ id: DocID) async -> RelayError? {
        let commands = self.commands
        return await perform { _ = try await commands.stop(id) }
    }

    private func optimisticallyUpdate(_ id: DocID, _ change: (inout SessionRow) -> Void) {
        guard var rows = sessionList.value, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        rows.sort { a, b in a.pinned != b.pinned ? a.pinned : a.lastActivityAt > b.lastActivityAt }
        sessionList.override(rows)
    }

    // MARK: Prompts

    /// Shows the prompt at once and sends it; the bubble's ticks follow `commands:forSession`.
    func sendPrompt(_ text: String, to sessionDocId: DocID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prompt = LocalPrompt(
            clientId: UUID().uuidString.lowercased(), text: trimmed, createdAt: Date().milliseconds)
        localPrompts[sessionDocId, default: []].append(prompt)
        deliver(prompt.clientId, in: sessionDocId)
    }

    private func deliver(_ clientId: String, in sessionDocId: DocID) {
        guard let prompt = localPrompts[sessionDocId]?.first(where: { $0.clientId == clientId }) else { return }
        let commands = self.commands
        Task { [weak self] in
            do {
                let commandId = try await commands.sendPrompt(sessionDocId, text: prompt.text, clientId: clientId)
                self?.updatePrompt(clientId, in: sessionDocId) {
                    $0.commandId = commandId
                    $0.failure = nil
                }
            } catch {
                let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
                if relayError.isRevoked {
                    self?.handleRevoked()
                    return
                }
                self?.updatePrompt(clientId, in: sessionDocId) { $0.failure = relayError.message }
            }
        }
    }

    private func updatePrompt(_ clientId: String, in sessionDocId: DocID, _ change: (inout LocalPrompt) -> Void) {
        guard var prompts = localPrompts[sessionDocId], let index = prompts.firstIndex(where: { $0.clientId == clientId })
        else { return }
        change(&prompts[index])
        localPrompts[sessionDocId] = prompts
    }

    /// Retry for a failed bubble: a prompt the relay rejected is resent with `commands:retry`; one that never reached
    /// the relay is sent again with the same client id.
    func retryPrompt(_ message: UserMessage, in sessionDocId: DocID) async -> RelayError? {
        if let clientId = message.clientId, let local = localPrompts[sessionDocId]?.first(where: { $0.clientId == clientId }),
            local.commandId == nil
        {
            updatePrompt(clientId, in: sessionDocId) { $0.failure = nil }
            deliver(clientId, in: sessionDocId)
            return nil
        }
        guard let commandId = message.commandId else { return nil }
        let commands = self.commands
        return await perform { try await commands.retry(commandId) }
    }

    /// Delete for a failed bubble.
    func discardPrompt(_ message: UserMessage, in sessionDocId: DocID) async -> RelayError? {
        if let clientId = message.clientId {
            localPrompts[sessionDocId]?.removeAll(where: { $0.clientId == clientId })
        }
        guard let commandId = message.commandId else { return nil }
        let commands = self.commands
        return await perform { try await commands.discard(commandId) }
    }

    /// Drops optimistic prompts once the transcript shows them.
    func pruneLocalPrompts(in sessionDocId: DocID, deliveredCommandIds: Set<DocID>) {
        guard let prompts = localPrompts[sessionDocId], !prompts.isEmpty else { return }
        let kept = prompts.filter { prompt in
            guard let commandId = prompt.commandId else { return true }
            return !deliveredCommandIds.contains(commandId)
        }
        if kept.count != prompts.count { localPrompts[sessionDocId] = kept }
    }
}
