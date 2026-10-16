import Foundation

// Sessions on the person's other computers (relay/DESIGN.md §4, "Sessions on other computers"). While this
// Mac is signed in to remote control, a harness of its own keeps running in the background ("the remote
// host"): it makes the Mac reachable even with no task open, runs prompts other devices send to sessions
// nobody has open here, and lists the other computers' sessions for the sidebar. Opening one makes a task
// whose session id is `relay:<id>`; its harness serves it from the relay, and the computer that has the
// session does the work.

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

enum RemoteSessions {
    static let prefix = "relay:"
    /// The project every task from another computer belongs to. It is never listed with the projects.
    static let projectID = UUID(uuidString: "5E1A7E00-0000-4000-8000-0000000000C1")!

    static func isRemote(_ sessionID: String?) -> Bool { sessionID?.hasPrefix(prefix) == true }
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
