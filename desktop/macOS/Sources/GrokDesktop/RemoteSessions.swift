import Foundation

// Sessions on the person's other computers (relay/DESIGN.md §4, "Sessions on other computers"). While this
// Mac is signed in to remote control, a harness of its own keeps running in the background ("the remote
// host"): it makes the Mac reachable even with no task open, runs prompts other devices send to sessions
// nobody has open here, and lists the other computers' sessions for the sidebar. Opening one makes a task
// whose session id is `relay:<id>`; its harness serves it from the relay, and the computer that has the
// session does the work.

/// The figures a session's computer last reported, as `x.ai/remote/sessions` carries them.
struct RemoteSessionUsage: Equatable, Sendable {
    /// The whole prompt, cached parts included.
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    /// The session's average output speed.
    var tokensPerSecond: Double?

    init(json: [String: Any]) {
        inputTokens = (json["inputTokens"] as? NSNumber)?.intValue ?? 0
        outputTokens = (json["outputTokens"] as? NSNumber)?.intValue ?? 0
        cachedTokens = (json["cachedTokens"] as? NSNumber)?.intValue ?? 0
        if let rate = (json["outputTokensPerSecond"] as? NSNumber)?.doubleValue, rate.isFinite, rate > 0 {
            tokensPerSecond = rate
        }
    }

    /// The harness's buckets: `input` is the uncached part of the prompt.
    var counts: TokenCounts {
        TokenCounts(input: max(0, inputTokens - cachedTokens), output: outputTokens, cacheRead: cachedTokens)
    }
}

/// One session of another computer, as `x.ai/remote/sessions` lists it.
struct RemoteSessionEntry: Identifiable, Equatable, Sendable {
    /// `relay:<id>`, the session id a task opens it by.
    var sessionID: String
    var title: String
    var cwd: String
    var status: String
    /// A crok there has it open.
    var running: Bool
    var lastActivityAt: Date
    var model: String?
    var preview: String?
    /// The branch its folder has checked out, when that computer last reported one.
    var gitBranch: String?
    /// Its token figures, refreshed at the end of each turn there.
    var usage: RemoteSessionUsage?
    var id: String { sessionID }

    var isWorking: Bool { status == "running" }
    var needsInput: Bool { status == "waiting" }

    init?(json: [String: Any]) {
        guard let sessionID = RemoteAccount.text(json["sessionId"]), sessionID.hasPrefix(RemoteSessions.prefix) else { return nil }
        self.sessionID = sessionID
        cwd = json["cwd"] as? String ?? ""
        title = RemoteAccount.text(json["title"]) ?? URL(fileURLWithPath: cwd).lastPathComponent
        status = json["status"] as? String ?? "idle"
        running = json["running"] as? Bool ?? false
        lastActivityAt = Date(timeIntervalSince1970: ((json["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        model = RemoteAccount.text(json["model"])
        preview = RemoteAccount.text(json["preview"])
        gitBranch = RemoteAccount.text(json["gitBranch"])
        usage = (json["usage"] as? [String: Any]).map(RemoteSessionUsage.init(json:))
    }
}

/// A folder of another computer and its sessions, in the relay's order.
struct RemoteProjectGroup: Identifiable, Equatable, Sendable {
    var key: String
    var name: String
    var path: String
    var sessions: [RemoteSessionEntry]
    var id: String { key }
}

/// Another computer of the person's, with its folders.
struct RemoteComputer: Identifiable, Equatable, Sendable {
    var deviceID: String
    var name: String
    var online: Bool
    var projects: [RemoteProjectGroup]
    var id: String { deviceID }

    var sessions: [RemoteSessionEntry] { projects.flatMap(\.sessions) }

    /// `x.ai/remote/sessions`'s `computers`.
    static func list(_ payload: [String: Any]) -> [RemoteComputer] {
        (payload["computers"] as? [[String: Any]] ?? []).compactMap { computer in
            guard let deviceID = RemoteAccount.text(computer["deviceId"]) else { return nil }
            let projects = (computer["projects"] as? [[String: Any]] ?? []).map { project in
                RemoteProjectGroup(key: project["key"] as? String ?? UUID().uuidString, name: project["name"] as? String ?? "",
                                   path: project["path"] as? String ?? "",
                                   sessions: (project["sessions"] as? [[String: Any]] ?? []).compactMap(RemoteSessionEntry.init(json:)))
            }
            return RemoteComputer(deviceID: deviceID, name: RemoteAccount.text(computer["deviceName"]) ?? "", online: computer["online"] as? Bool ?? false,
                                  projects: projects)
        }
    }
}

/// What a task opened from another computer remembers about where the session lives.
struct RemoteTaskInfo: Codable, Equatable, Sendable {
    var computer: String
    var deviceID: String
    var cwd: String
}

/// Where a new task on another computer starts: that computer and one of its folders.
struct RemoteNewTask: Hashable, Sendable {
    var deviceID: String
    var computer: String
    var path: String
    var folderName: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum RemoteSessions {
    static let prefix = "relay:"
    /// The project every task from another computer belongs to. It is never listed with the projects.
    static let projectID = UUID(uuidString: "5E1A7E00-0000-4000-8000-0000000000C1")!
    /// A new task's first turn, until the viewer names the prompt the computer runs it under.
    static let startingTurn = "remote-starting"

    static func isRemote(_ sessionID: String?) -> Bool { sessionID?.hasPrefix(prefix) == true }

    static func offline(_ computer: String) -> String {
        L10n.t("remote_new_task_offline", "{computer} is offline: start crok or Crok Desktop there.", ["computer": computer])
    }

    /// Whether the viewer's announced prompt is the one a new task sent (the relay trims it).
    static func samePrompt(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The banner for a session that did not start on `computer`. The relay's `OFFLINE` gets the app's
    /// own words; anything else (`INVALID`: not a full path, a prompt too long) keeps the relay's reason.
    static func startFailure(_ error: Error, computer: String) -> String {
        if case ACPClientError.remote(_, let message, let data) = error {
            let code = (data as? [String: Any]).flatMap { RemoteAccount.text($0["code"]) }
            // The viewer passes the relay's message on; its code only when it keeps one.
            if code == "OFFLINE" || message.hasSuffix("is offline: start crok or Crok Desktop there.") { return offline(computer) }
        }
        return L10n.t("remote_new_task_failed", "Could not start the task on {computer}: {error}", ["computer": computer, "error": error.localizedDescription])
    }
}

extension AppStore {
    /// Tasks opened from other computers run their harness in a folder of the app's own: the session's
    /// own folder is on the other computer.
    var remoteProject: Project {
        Project(id: RemoteSessions.projectID, path: stateFileDirectory.appendingPathComponent("remote-tasks", isDirectory: true).path)
    }

    /// A project by id, the remote tasks' one included.
    func projectRecord(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        if id == RemoteSessions.projectID { return remoteProject }
        return state.projects.first { $0.id == id }
    }

    /// The task already open for a session of another computer.
    func remoteTask(sessionID: String) -> Conversation? {
        state.conversations.first { $0.sessionID == sessionID && !$0.isArchived }
    }

    /// Opens a session of another computer as a task (or selects the one already open).
    func openRemoteSession(_ entry: RemoteSessionEntry, on computer: RemoteComputer) {
        if let existing = state.conversations.first(where: { $0.sessionID == entry.sessionID }) {
            if existing.isArchived, let index = state.conversations.firstIndex(where: { $0.id == existing.id }) {
                state.conversations[index].isArchived = false
            }
            selectConversation(existing)
            return
        }
        try? FileManager.default.createDirectory(atPath: remoteProject.path, withIntermediateDirectories: true)
        var task = Conversation(projectID: RemoteSessions.projectID, title: String(entry.title.prefix(200)), sessionID: entry.sessionID)
        task.updatedAt = entry.lastActivityAt
        task.remote = RemoteTaskInfo(computer: computer.name, deviceID: computer.deviceID, cwd: entry.cwd)
        state.conversations.insert(task, at: 0)
        DesktopLog.info("remote.open_session", session: entry.sessionID, ["computer": computer.name])
        selectConversation(task)
        applyRemoteEntry(entry, to: task.id)
    }

    /// The listed session with this id, if the remote host has reported it.
    func remoteEntry(sessionID: String) -> RemoteSessionEntry? {
        remoteComputers.lazy.flatMap(\.sessions).first { $0.sessionID == sessionID }
    }

    /// A session's figures and branch as its computer last reported them: the footer shows them before the task
    /// connects, and again each time the relay says they changed.
    func applyRemoteEntry(_ entry: RemoteSessionEntry, to id: UUID) {
        if let usage = entry.usage { features.tokens.noteRemoteUsage(usage, conversationID: id) }
        guard id == state.selectedConversationID, let branch = entry.gitBranch, !branch.isEmpty else { return }
        let snapshot = GitWorkspaceSnapshot(branch: branch, changes: workspace.changes, isRemote: true)
        if workspace != snapshot { workspace = snapshot }
    }

    /// Every listed session that has an open task: its token figures, and the selected task's branch.
    func applyRemoteSessionInfo(_ computers: [RemoteComputer]) {
        let entries = Dictionary(computers.flatMap(\.sessions).map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        for task in state.conversations where task.remote != nil {
            guard let session = task.sessionID, let entry = entries[session] else { continue }
            applyRemoteEntry(entry, to: task.id)
        }
    }

    /// `_x.ai/session/info` for a session of another computer: what the relay knows about its branch, figures and
    /// context window. The list may not carry the session yet (a task started from this Mac), so ask once when its
    /// harness connects.
    func noteRemoteInfo(client: ACPClient, session: String, conversationID id: UUID) async {
        guard let response = try? await client.request("_x.ai/session/info", params: ["sessionId": session]),
              let result = try? ExtensionResponse.unwrap(response) else { return }
        if let usage = result["usage"] as? [String: Any] {
            features.tokens.noteRemoteUsage(RemoteSessionUsage(json: usage), conversationID: id)
        }
        let info = UsageSessionInfo(result)
        features.tokens.noteContext(info.context, conversationID: id)
        guard id == state.selectedConversationID, let branch = info.branch, !branch.isEmpty else { return }
        let snapshot = GitWorkspaceSnapshot(branch: branch, changes: workspace.changes, isRemote: true)
        if workspace != snapshot { workspace = snapshot }
    }

    // MARK: New tasks on other computers

    /// The computer and folder the task on screen starts in when its first prompt is sent: a new task
    /// opened from the sidebar, or a task whose start there failed and so has no session yet.
    var remoteStartTarget: RemoteNewTask? {
        if let task = conversation {
            guard let remote = task.remote, task.sessionID == nil else { return nil }
            return RemoteNewTask(deviceID: remote.deviceID, computer: remote.computer, path: remote.cwd)
        }
        return state.selectedProjectID == RemoteSessions.projectID ? remoteNewTask : nil
    }

    /// Sidebar › Other computers › a folder › New task: an empty task whose first prompt starts a
    /// session on that computer, in that folder.
    func newRemoteTask(on computer: RemoteComputer, in project: RemoteProjectGroup) {
        guard computer.online else { banner = RemoteSessions.offline(computer.name); return }
        drafts[draftLocation] = draft
        remoteNewTask = RemoteNewTask(deviceID: computer.deviceID, computer: computer.name, path: project.path)
        state.selectedProjectID = RemoteSessions.projectID; state.selectedConversationID = nil
        draft = drafts[draftLocation] ?? ""; search = ""; showArchived = false; selectedFile = nil; diffText = ""
        workspace = GitWorkspaceSnapshot(branch: "", changes: [])
        save()
    }

    /// Sends a new task's first prompt to another computer: `x.ai/remote/new_session` through the
    /// remote host starts the session there, then the task opens it like any session of another
    /// computer. The prompt shows here at once; the computer runs it, and the viewer reports its turn
    /// (`x.ai/remote/prompt`, then `x.ai/session/prompt_complete`).
    func startRemoteTask(_ prompt: String, sending text: String, target: RemoteNewTask, attachments: [PromptAttachment],
                         draftLocation location: DraftLocation, clearsDraft: Bool) {
        guard attachments.isEmpty else {
            banner = L10n.t("remote_new_task_no_attachments", "Attachments cannot be sent to another computer. Remove them and send again."); return
        }
        if let computer = remoteComputers.first(where: { $0.deviceID == target.deviceID }), !computer.online {
            banner = RemoteSessions.offline(computer.name); return
        }
        guard remoteHost != nil, remoteHostReady else {
            banner = L10n.t("remote_new_task_no_host", "Remote control is not connected on this Mac. Check Settings › Remote control, then send again."); return
        }
        var id = state.selectedConversationID
        if id == nil {
            try? FileManager.default.createDirectory(atPath: remoteProject.path, withIntermediateDirectories: true)
            var task = Conversation(projectID: RemoteSessions.projectID, title: String(prompt.prefix(64)))
            task.remote = RemoteTaskInfo(computer: target.computer, deviceID: target.deviceID, cwd: target.path)
            state.conversations.insert(task, at: 0); id = task.id; state.selectedConversationID = task.id
        }
        guard let id else { return }
        let optimistic = Message(kind: .user, text: prompt, createdAt: Date())
        append(optimistic, to: id)
        if clearsDraft {
            drafts.removeValue(forKey: location); drafts.removeValue(forKey: .conversation(id))
            draft = ""
        }
        banner = nil
        DesktopLog.info("remote.new_task", ["computer": target.computer, "task": id.uuidString])
        let operationID = beginOperation(id, phase: "Starting")
        operations[id] = Task {
            defer { finishOperation(id, operationID: operationID) }
            do {
                let session = try await requestRemoteSession(target, text: text)
                try checkOperation(id, operationID: operationID)
                guard let index = state.conversations.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                state.conversations[index].sessionID = session
                save()
                DesktopLog.info("remote.new_session", session: session, ["computer": target.computer, "task": id.uuidString])
                // The computer runs the prompt; until the viewer names that turn, the end of any turn ends it.
                remoteFirstPrompts[id] = text
                remoteTurns[id] = RemoteSessions.startingTurn
                pendingPrompts[id] = optimistic
                runs[id]?.phase = "Working"
                _ = try await connect(id: id, project: remoteProject, operationID: operationID)
                try checkOperation(id, operationID: operationID)
            } catch {
                guard operationIDs[id] == operationID else { return }
                if remoteTurns[id] == RemoteSessions.startingTurn { remoteTurns.removeValue(forKey: id) }
                remoteFirstPrompts.removeValue(forKey: id)
                let stopped = error is CancellationError || cancellationRequested.contains(id)
                runs[id]?.phase = stopped ? "Stopped" : "Needs attention"
                if !stopped {
                    let message = RemoteSessions.startFailure(error, computer: target.computer)
                    var context = DesktopLog.context(for: error)
                    context["task"] = id.uuidString; context["computer"] = target.computer
                    DesktopLog.error("remote.new_session_failed", session: task(id)?.sessionID, context)
                    if state.selectedConversationID == id { banner = message }
                    append(Message(kind: .system, text: message, createdAt: Date()), to: id)
                }
                discardConnection(id)
            }
        }
    }

    /// `x.ai/remote/new_session {deviceId, path, text}` through the remote host: the relay adds the
    /// session at once and a crok of that computer picks it up. The answer is its `relay:` id.
    func requestRemoteSession(_ target: RemoteNewTask, text: String) async throws -> String {
        guard let client = remoteHost, remoteHostReady else {
            throw DesktopError.message(L10n.t("remote_new_task_no_host", "Remote control is not connected on this Mac. Check Settings › Remote control, then send again."))
        }
        let response = try await client.request("_x.ai/remote/new_session", params: ["deviceId": target.deviceID, "path": target.path, "text": text], timeout: 45)
        let payload = try ExtensionResponse.unwrap(response)
        guard let session = RemoteAccount.text(payload["sessionId"]), RemoteSessions.isRemote(session) else {
            throw DesktopError.message(L10n.t("remote_new_task_no_session", "The relay did not say which session it started. Try again."))
        }
        return session
    }

    /// A new task's first turn whose prompt the viewer never announced, because the computer had
    /// started it before the task opened the session (it came with the history), ends when the list
    /// of other computers shows the session at rest.
    func settleStartingTurns(_ computers: [RemoteComputer]) {
        let starting = remoteTurns.filter { $0.value == RemoteSessions.startingTurn }.map(\.key)
        guard !starting.isEmpty else { return }
        let entries = Dictionary(computers.flatMap(\.sessions).map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in starting {
            guard let session = task(id)?.sessionID, let entry = entries[session] else { continue }
            // A session the computer has just taken may show idle for a moment before its prompt runs.
            if entry.status == "error" || (entry.status == "idle" && entry.preview != nil) {
                finishRemoteTurn(promptID: nil, stopReason: nil, id: id)
            }
        }
    }

    // MARK: Models of other computers

    /// The computer whose models the composer lists: the task on screen's, or the one a new task
    /// there starts on. Nil for this Mac's own tasks.
    var selectedRemoteDeviceID: String? {
        if let task = conversation { return task.remote?.deviceID }
        return state.selectedProjectID == RemoteSessions.projectID ? remoteNewTask?.deviceID : nil
    }

    /// Keeps the models a computer offers, so its tasks name and list them before their session
    /// loads next time. This Mac's own catalog is `rememberModelCatalog`'s.
    func rememberRemoteModels(_ models: [ModelOption], deviceID: String) {
        guard !models.isEmpty, state.remoteModelCatalogs[deviceID] != models else { return }
        state.remoteModelCatalogs[deviceID] = models
        save()
    }

    /// `model_changed` in a session of another computer: its model or thinking level was changed
    /// elsewhere (on that computer, a phone, the web). The `config_option_update` that comes with it
    /// carries the new choices. Returns whether it was one.
    func applyRemoteModelChange(_ update: [String: Any], id: UUID) -> Bool {
        guard update["sessionUpdate"] as? String == "model_changed", task(id)?.remote != nil,
              let model = RemoteAccount.text(update["model_id"] ?? update["modelId"]) else { return false }
        var run = runs[id, default: RunState()]
        let option = run.models.first { $0.id == model }
        if run.modelID != model { run.reasoningOptions = option?.reasoningOptions ?? [] }
        run.modelID = model
        run.reasoningID = RemoteAccount.text(update["reasoning_effort"] ?? update["reasoningEffort"]) ?? option?.defaultReasoningID ?? ""
        runs[id] = run
        if loaded.contains(id) { persistSessionOptions(id) }
        return true
    }

    // MARK: The remote host

    /// Starts the loop that keeps the remote host running while this Mac is signed in and sharing.
    func startRemoteHost() {
        guard remoteHostLoop == nil, NSClassFromString("XCTestCase") == nil else { return }
        remoteHostLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tendRemoteHost()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Starts or stops the host to match the sign-in, and keeps the list of other computers current.
    func tendRemoteHost() {
        remoteControl.refreshIfChanged()
        let wanted = remoteControl.isSignedIn && remoteControl.enabled && FileManager.default.isExecutableFile(atPath: binaryPath)
        guard wanted else {
            if remoteHost != nil { stopRemoteHost() }
            if !remoteComputers.isEmpty { remoteComputers = [] }
            return
        }
        if remoteHost == nil {
            if let retry = remoteHostRetryAt, retry > Date() { return }
            launchRemoteHost()
        } else if remoteHostReady, Date().timeIntervalSince(remoteSessionsAskedAt ?? .distantPast) > 240 {
            // The list keeps coming for ten minutes after it was last asked for.
            Task { await askRemoteSessions() }
        }
    }

    private func launchRemoteHost() {
        let client = ACPClient()
        let hostID = remoteHostID
        remoteHost = client
        remoteHostReady = false
        client.onNotification = { [weak self, weak client] method, params in
            guard let self, let client, self.remoteHost === client else { return }
            let method = method.hasPrefix("_") ? String(method.dropFirst()) : method
            switch method {
            case "x.ai/remote/status":
                self.noteRemoteStatus(RemoteBridgeStatus(params: params), from: hostID)
            case "x.ai/remote/sessions_changed":
                self.noteRemoteComputers(params)
            default:
                break
            }
        }
        client.onRequest = { [weak client] requestID, method, _ in
            // Sessions the host runs for other devices answer their own requests; nothing here asks.
            try? client?.respondError(id: requestID, code: -32601, message: "The remote host answers no requests: \(method)")
        }
        client.onDisconnect = { [weak self, weak client] _ in
            guard let self, let client, self.remoteHost === client else { return }
            self.remoteHost = nil
            self.remoteHostReady = false
            self.noteRemoteStatus(nil, from: hostID)
            self.remoteHostRetryAt = Date().addingTimeInterval(10)
            DesktopLog.info("remote.host_exit")
        }
        do {
            try FileManager.default.createDirectory(atPath: remoteProject.path, withIntermediateDirectories: true)
            try client.start(executable: binaryPath, cwd: remoteProject.path)
        } catch {
            remoteHost = nil
            remoteHostRetryAt = Date().addingTimeInterval(30)
            DesktopLog.warn("remote.host_start_failed", ["error": error.localizedDescription])
            return
        }
        DesktopLog.info("remote.host_start")
        Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await self.initialize(client)
                // Without a model provider the host still links this Mac and lists the other computers.
                try? await self.authenticate(client, initial: initial)
                guard self.remoteHost === client else { return }
                self.remoteHostReady = true
                await self.askRemoteSessions()
            } catch {
                guard self.remoteHost === client else { return }
                DesktopLog.warn("remote.host_init_failed", ["error": error.localizedDescription])
                self.stopRemoteHost()
                self.remoteHostRetryAt = Date().addingTimeInterval(30)
            }
        }
    }

    func stopRemoteHost() {
        let client = remoteHost
        remoteHost = nil
        remoteHostReady = false
        noteRemoteStatus(nil, from: remoteHostID)
        client?.stop()
    }

    /// `x.ai/remote/sessions {watch: true}`: the list now, and `x.ai/remote/sessions_changed` after each change.
    func askRemoteSessions() async {
        guard let client = remoteHost, remoteHostReady else { return }
        remoteSessionsAskedAt = Date()
        guard let response = try? await client.request("_x.ai/remote/sessions", params: ["watch": true], timeout: 30),
              let payload = try? ExtensionResponse.unwrap(response) else { return }
        guard remoteHost === client else { return }
        noteRemoteComputers(payload)
    }

    func noteRemoteComputers(_ payload: [String: Any]) {
        let computers = RemoteComputer.list(payload)
        if computers != remoteComputers { remoteComputers = computers }
        applyRemoteSessionInfo(computers)
        settleStartingTurns(computers)
    }

    /// `x.ai/remote/permission_resolved`: another device answered a request a task still shows.
    func dropAnsweredApproval(_ params: [String: Any], id: UUID) {
        guard let toolCall = RemoteAccount.text(params["toolCallId"]) else { return }
        let answered = runs[id]?.approvals.filter { $0.toolCallID == toolCall } ?? []
        guard !answered.isEmpty else { return }
        for approval in answered {
            try? clients[id]?.respond(id: approval.requestID, result: ["outcome": ["outcome": "cancelled"]])
        }
        runs[id]?.approvals.removeAll { $0.toolCallID == toolCall }
        if state.selectedConversationID == id { banner = L10n.t("remote_answered_elsewhere", "Answered on another device.") }
    }
}
