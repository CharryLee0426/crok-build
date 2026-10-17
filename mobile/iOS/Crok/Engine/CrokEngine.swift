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
    /// Sessions this phone started (`sessions:create`), by client id.
    private(set) var startedSessions: [String: DocID] = [:]

    /// The main list as the relay sends it (`sessions:groups`); screens read `groups`.
    let groupList: LiveQuery<[ProjectGroup]>
    let archivedList: LiveQuery<[SessionRow]>
    let deviceList: LiveQuery<[DeviceRow]>
    let account: LiveQuery<AccountInfo?>

    @ObservationIgnored let drafts: DraftStore
    @ObservationIgnored private let collapsedStore: CollapsedProjectsStore
    @ObservationIgnored private let cache: SessionListCache?
    /// Network, sync and the recovery steps (relay/DESIGN.md §5 "Staying connected").
    @ObservationIgnored private(set) var keeper: ConnectionKeeper
    @ObservationIgnored private var socketConnected = false
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var delayedStatus: DelayedConnectionStatus?
    @ObservationIgnored private var revokedHandled = false
    @ObservationIgnored private var cacheSaveTask: Task<Void, Never>?
    @ObservationIgnored private var wentToBackground = false
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let tickInterval: Duration?
    /// Live queries to wake when the connection comes back, so none sits out a long backoff.
    @ObservationIgnored private var liveQueries: [ObjectIdentifier: WeakQuery] = [:]
    /// Called once when the relay says this device was signed out.
    @ObservationIgnored var onRevoked: (@MainActor () -> Void)?

    var sessions: any SessionsAPI { backend.sessions }
    var commands: any CommandsAPI { backend.commands }
    var devices: any DevicesAPI { backend.devices }
    var accountAPI: any AccountAPI { backend.account }

    /// - Parameters:
    ///   - now: the clock the connection keeper runs on (tests pass their own).
    ///   - tickInterval: how often the keeper's watchdog runs; nil for none (tests call `tickConnection`).
    init(backend: any RelayBackend, credentials: StoredCredentials, isDemo: Bool, drafts: DraftStore = DraftStore(),
         cache: SessionListCache? = .standard, now: @escaping () -> Date = Date.init, tickInterval: Duration? = .seconds(1))
    {
        self.backend = backend
        self.credentials = credentials
        self.isDemo = isDemo
        self.drafts = drafts
        self.cache = cache
        self.now = now
        self.tickInterval = tickInterval
        keeper = ConnectionKeeper(now: now())
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
                self.handle(signal)
            }
        }
        if let tickInterval {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: tickInterval)
                    self?.tickConnection()
                }
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
        tickTask?.cancel()
        cacheSaveTask?.cancel()
        delayedStatus?.cancel()
        groupList.stop()
        archivedList.stop()
        deviceList.stop()
        account.stop()
        await backend.shutdown()
    }

    func handleRevoked() {
        guard !revokedHandled else { return }
        revokedHandled = true
        onRevoked?()
    }

    // MARK: Connection

    /// The app came back to the foreground, or went to the background (`scenePhase`).
    func scenePhaseChanged(active: Bool) {
        if active {
            guard wentToBackground else { return }
            wentToBackground = false
            run(keeper.becameActive(now: now()))
        } else {
            wentToBackground = true
            keeper.enteredBackground()
        }
        recomputeConnection()
    }

    /// A query or call answered `UNAUTHENTICATED`: refresh the token and replace the client.
    func handleUnauthenticated() {
        run(keeper.unauthenticated(now: now()))
        recomputeConnection()
    }

    /// The keeper's watchdog; runs every second (`tickInterval`).
    func tickConnection() {
        run(keeper.tick(now: now()))
        recomputeConnection()
    }

    func handle(_ signal: ConnectionSignal) {
        let now = now()
        switch signal {
        case .network(let available):
            run(keeper.networkChanged(available: available, now: now))
        case .pathChanged:
            run(keeper.pathChanged(now: now))
        case .socket(let connected):
            socketConnected = connected
            run(keeper.socketChanged(connected: connected, now: now))
        case .synced:
            // Results came over the socket, so it is up even if its state change is still on the way.
            socketConnected = true
            run(keeper.synced(now: now))
        }
        recomputeConnection()
    }

    func register(_ query: RetryableQuery) {
        liveQueries = liveQueries.filter { $0.value.query != nil }
        liveQueries[ObjectIdentifier(query)] = WeakQuery(query: query)
    }

    private func run(_ actions: [ConnectionKeeper.Action]) {
        let backend = self.backend
        for action in actions {
            switch action {
            case .refreshToken:
                Task { [weak self] in
                    // REVOKED reaches the app through the token source; anything else just means no proof of life.
                    try? await backend.refreshAuth()
                    guard let self else { return }
                    self.run(self.keeper.refreshFinished(now: self.now()))
                    self.recomputeConnection()
                }
            case .replaceClient:
                Task { [weak self] in
                    await backend.replaceClient()
                    guard let self else { return }
                    self.run(self.keeper.replaceFinished(now: self.now()))
                    for query in self.liveQueries.values { query.query?.retryNow() }
                    self.recomputeConnection()
                }
            }
        }
    }

    private func recomputeConnection() {
        let status = ConnectionStatus.derive(
            networkAvailable: keeper.networkAvailable, socketConnected: socketConnected, synced: keeper.synced)
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
            if relayError.code == .unauthenticated { handleUnauthenticated() }
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

    /// Answers a session's pending permission request, as if clicked on its computer.
    func answer(_ id: DocID, interactionId: String, optionId: String) async -> RelayError? {
        let commands = self.commands
        return await perform { _ = try await commands.answer(id, interactionId: interactionId, optionId: optionId) }
    }

    // MARK: New sessions

    /// Starts a session in `target` with `text` as its first prompt (`sessions:create`). The prompt is kept as this
    /// phone's optimistic bubble in the new session, under the same client id as the relay's `create` command, so its
    /// ticks follow `commands:forSession`. The same client id never makes two sessions.
    func startSession(in target: NewSessionTarget, text: String?, clientId: String) async -> Result<DocID, RelayError> {
        if let started = startedSessions[clientId] { return .success(started) }
        let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAt = Date().milliseconds
        let sessions = self.sessions
        do {
            let created = try await sessions.create(
                deviceId: target.deviceId, path: target.path, text: prompt?.isEmpty == false ? prompt : nil,
                clientId: clientId)
            startedSessions[clientId] = created.sessionDocId
            if let prompt, !prompt.isEmpty {
                localPrompts[created.sessionDocId, default: []].append(
                    LocalPrompt(clientId: clientId, text: prompt, createdAt: sentAt, commandId: created.commandId))
            }
            return .success(created.sessionDocId)
        } catch {
            let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
            if relayError.isRevoked { handleRevoked() }
            if relayError.code == .unauthenticated { handleUnauthenticated() }
            return .failure(relayError)
        }
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
                if relayError.code == .unauthenticated { self?.handleUnauthenticated() }
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

/// A live query the engine may wake, held weakly.
@MainActor
struct WeakQuery {
    weak var query: RetryableQuery?
}
