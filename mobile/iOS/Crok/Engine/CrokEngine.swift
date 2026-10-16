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
    /// Moves sent to the relay and not confirmed yet; `groups` applies them over every value the relay sends meanwhile.
    private(set) var pendingReorders: [PendingReorder] = []
    /// Projects collapsed in the list (remembered on this phone).
    private(set) var collapsedProjects: Set<String>

    /// The main list as the relay sends it (`sessions:groups`); screens read `groups`.
    let groupList: LiveQuery<[ProjectGroup]>
    let archivedList: LiveQuery<[SessionRow]>
    let deviceList: LiveQuery<[DeviceRow]>
    let account: LiveQuery<AccountInfo?>

    @ObservationIgnored let drafts: DraftStore
    @ObservationIgnored private let collapsedStore: CollapsedProjectsStore
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
        collapsedStore = CollapsedProjectsStore(defaults: drafts.defaults)
        collapsedProjects = collapsedStore.load()
        let cached = cache?.load(deviceId: credentials.deviceId)
        groupList = LiveQuery(engine: nil, initial: cached?.groups) { backend.sessions.groups() }
        archivedList = LiveQuery(engine: nil) { backend.sessions.list(archived: true) }
        deviceList = LiveQuery(engine: nil, initial: cached?.computers) { backend.devices.list() }
        account = LiveQuery(engine: nil) { backend.account.me() }
    }

    // MARK: Lifecycle

    func start() {
        // LiveQuery holds the engine weakly; attach it now that `self` exists.
        groupList.setEngine(self)
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
        groupList.onValue = { [weak self] groups in self?.scheduleCacheSave(groups: groups) }
        deviceList.onValue = { [weak self] _ in self?.scheduleCacheSave(groups: nil) }
        groupList.start()
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
        groupList.stop()
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

    private func scheduleCacheSave(groups: [ProjectGroup]?) {
        guard let cache, !isDemo else { return }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let groups = groups ?? self.groupList.value ?? []
            let computers = (self.deviceList.value ?? []).filter { $0.kind == .computer }
            let deviceId = self.credentials.deviceId
            Task.detached(priority: .utility) {
                cache.save(deviceId: deviceId, groups: groups, computers: computers)
            }
        }
    }

    // MARK: Lookups

    /// The main list in the order to show: the relay's, with the moves it has not confirmed yet.
    var groups: [ProjectGroup] {
        pendingReorders.reduce(groupList.value ?? []) { ProjectOrder.apply($1.change, to: $0) }
    }

    func sessionRow(_ id: DocID) -> SessionRow? {
        for group in groupList.value ?? [] {
            if let row = group.sessions.first(where: { $0.id == id }) { return row }
        }
        return archivedList.value?.first(where: { $0.id == id })
    }

    /// Unread replies over every session in the main list (the Sessions tab's badge).
    var unreadTotal: Int {
        (groupList.value ?? []).reduce(0) { $0 + $1.unreadCount }
    }

    var computers: [DeviceRow] {
        (deviceList.value ?? []).filter { $0.kind == .computer }
    }

    // MARK: Collapsed projects

    func isCollapsed(_ projectKey: String) -> Bool {
        collapsedProjects.contains(projectKey)
    }

    func toggleCollapsed(_ projectKey: String) {
        if collapsedProjects.contains(projectKey) {
            collapsedProjects.remove(projectKey)
        } else {
            collapsedProjects.insert(projectKey)
        }
        collapsedStore.save(collapsedProjects)
    }

    // MARK: Order

    struct PendingReorder: Equatable, Sendable {
        let id = UUID()
        let change: ListReorder
    }

    /// Moves projects or sessions, or sorts them by recent activity: shown at once, then sent to the relay. A failure
    /// puts the relay's order back and is returned for the caller to show.
    func reorder(_ change: ListReorder) async -> RelayError? {
        let pending = PendingReorder(change: change)
        pendingReorders.append(pending)
        let sessions = self.sessions
        let error = await perform {
            switch change {
            case .projects(let keys): try await sessions.reorderProjects(keys)
            case .sessions(let projectKey, let ids): try await sessions.reorderSessions(projectKey: projectKey, ids)
            case .projectsByActivity: try await sessions.resetOrder(projectKey: nil)
            case .sessionsByActivity(let projectKey): try await sessions.resetOrder(projectKey: projectKey)
            }
        }
        if error == nil, let value = groupList.value {
            // Keep the move if the relay's next value is still on its way (applying it again changes nothing).
            groupList.override(ProjectOrder.apply(change, to: value))
        }
        pendingReorders.removeAll { $0.id == pending.id }
        return error
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
        if let groups = groupList.value { groupList.override(ProjectOrder.settingPinned(id, pinned, in: groups)) }
        let sessions = self.sessions
        let error = await perform { try await sessions.setPinned(id, pinned) }
        if error != nil { groupList.revertOverride() }
        return error
    }

    func setArchived(_ id: DocID, _ archived: Bool) async -> RelayError? {
        if archived, let groups = groupList.value { groupList.override(ProjectOrder.removing(id, from: groups)) }
        let sessions = self.sessions
        let error = await perform { try await sessions.setArchived(id, archived) }
        if error != nil { groupList.revertOverride() }
        return error
    }

    func stopTurn(_ id: DocID) async -> RelayError? {
        let commands = self.commands
        return await perform { _ = try await commands.stop(id) }
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
