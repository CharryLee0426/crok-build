import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Fork, resume, rename, delete, the session dashboard, tasks, workflow runs, traces, and diagnostics.
@MainActor
final class SessionFeatureModel: ObservableObject {
    weak var store: AppStore?

    /// Background work per task (workflows, scheduled prompts, shell tasks), from harness notifications.
    @Published private(set) var boards: [UUID: SessionTaskBoard] = [:]
    @Published private(set) var tasksLoading = false
    @Published var tasksError: String?
    /// Subagents the user asked to stop, shown as "stopping" until the harness reports them finished.
    @Published private(set) var stoppingSubagents: Set<String> = []

    @Published var resumeRows: [HarnessSessionRow] = []
    @Published var resumeCursor: String?
    @Published private(set) var resumeLoading = false
    @Published private(set) var resumeError: String?
    @Published var searchRows: [HarnessSessionRow] = []
    @Published private(set) var searchLoading = false
    @Published var searchBootstrapping = false
    @Published private(set) var searchError: String?
    /// The query the search rows answer; they are stale while it differs from the field.
    @Published var searchedQuery = ""
    /// The resume sheet's own connection, shared by listing, paging, and search while it is open.
    private var resumeConnection: (cwd: String, start: Task<(ACPClient, UUID), Error>)?
    private var resumeRequestID: UUID?
    private var searchRequestID: UUID?

    @Published private(set) var deleting: Set<UUID> = []

    @Published private(set) var trace = TraceViewState.idle
    @Published private(set) var traceTitle = ""
    @Published private(set) var traceRevision = 0
    private var traceRequestID: UUID?
    private var traceSelection: AnyCancellable?
    private var traceFile: URL?

    @Published var doctorReport: DoctorReport?
    @Published private(set) var doctorLoading = false
    @Published var doctorError: String?
    @Published var desktopChecks: [DoctorDesktopCheck] = []
    private var doctorRequestID: UUID?

    /// Where `config.toml` and session directories live. Tests point these at temporary folders.
    var configURL: () -> URL = { GrokPaths.configFile }
    var grokHome: () -> URL = { GrokPaths.home }
    /// Reads which accounts are signed in, for the doctor's desktop checks.
    var accountReader: () -> [AccountProvider: AccountStatus] = { AccountStatusReader().read() }
    /// Snapshot tests render seeded state; with this off, sheets never start the harness or CLI.
    var harnessRequestsEnabled = true
    /// Asks before a permanent delete. The app shows an alert; tests answer directly.
    var confirmDelete: (_ title: String, _ hasSession: Bool, _ completion: @escaping (Bool) -> Void) -> Void = { title, hasSession, completion in
        SessionFeatureModel.presentDeleteAlert(title: title, hasSession: hasSession, completion: completion)
    }

    init(store: AppStore) { self.store = store }

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    /// Workflow, scheduler, and background-task updates are recorded but not consumed, so other
    /// features can render the same events.
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool {
        guard let update, let kind = update["sessionUpdate"] as? String, SessionTaskBoard.updateKinds.contains(kind) else { return false }
        var board = boards[conversationID] ?? SessionTaskBoard()
        if board.apply(update) { boards[conversationID] = board }
        return false
    }

    func board(for id: UUID?) -> SessionTaskBoard { id.flatMap { boards[$0] } ?? SessionTaskBoard() }

    // MARK: - Entry points

    /// `/fork [--worktree|--no-worktree] [directive]`.
    func fork(_ arguments: String) {
        guard let store else { return }
        let parsed: SessionForkArguments
        do { parsed = try SessionForkArguments.parse(arguments) } catch { store.banner = error.localizedDescription; return }
        guard let parent = store.conversation else { store.banner = "/fork only works inside a session"; return }
        guard parent.sessionID != nil, let project = project(of: parent) else { store.banner = "Cannot fork: session is still being created"; return }
        Task {
            let inRepository = await SessionWorktreeDetection.isRepository(project.path)
            guard store.state.selectedConversationID == parent.id else { return }
            switch parsed.worktree {
            case true? where !inRepository:
                store.banner = "Cannot create worktree: not in a git repository"
            case let worktree?:
                await performFork(parentID: parent.id, worktree: worktree, directive: parsed.directive)
            case nil where !inRepository:
                await performFork(parentID: parent.id, worktree: false, directive: parsed.directive)
            case nil:
                switch SessionForkWorktreeMode.read(GrokConfig(url: configURL())) {
                case .always: await performFork(parentID: parent.id, worktree: true, directive: parsed.directive)
                case .never: await performFork(parentID: parent.id, worktree: false, directive: parsed.directive)
                case .ask: store.sheet = .fork(arguments: arguments)
                }
            }
        }
    }
    /// `/resume`.
    func openResume() {
        guard let store else { return }
        guard store.project != nil else { store.banner = "Open a project first."; return }
        store.sheet = .resume
    }
    /// `/dashboard`, aliases `/agents-dashboard` and `/sessions`.
    func openDashboard() { store?.sheet = .dashboard }
    /// `/tasks`.
    func openTasks() { store?.sheet = .tasks }
    /// `/workflow runs`.
    func openWorkflowRuns() { store?.sheet = .workflowRuns }
    /// `/trace`. Like the terminal, it refuses before opening anything when there is nothing to read.
    func openTrace() {
        guard let store else { return }
        guard let task = store.conversation, let session = task.sessionID, let project = project(of: task) else {
            store.banner = "No active session to trace"; return
        }
        let home = grokHome()
        Task {
            let directory = await Task.detached(priority: .userInitiated) { GrokPaths.sessionDirectory(cwd: project.path, sessionID: session, home: home) }.value
            guard store.state.selectedConversationID == task.id else { return }
            guard directory != nil else { store.banner = "This session has not been recorded yet"; return }
            store.open(.trace)
            // An open window keeps its view, so ask it to read the newly requested session.
            if traceSelection != nil { await loadTrace() }
        }
    }
    /// `/doctor [fix [name]]`, aliases `/terminal-setup`, `/terminal-check`, `/terminal-info`.
    func openDoctor(_ arguments: String) {
        guard let store else { return }
        do { _ = try DoctorRequest.parse(arguments) } catch { store.banner = error.localizedDescription; return }
        store.sheet = .doctor(arguments: arguments)
    }
    /// `/rename <title> | --auto`, alias `/title`. With no title the rename sheet opens, prefilled
    /// with the current title the way the terminal suggests it.
    func rename(_ arguments: String) {
        guard let store else { return }
        guard let id = store.state.selectedConversationID else { store.banner = "No active session"; return }
        if arguments.isEmpty { store.showRename = true } else { applyRename(id: id, title: arguments) }
    }
    /// Renames a task from the rename sheet or `/rename <title>`.
    func applyRename(id: UUID, title: String) {
        guard let store else { return }
        do {
            let request = try SessionRenameRequest.parse(title)
            Task { await performRename(id: id, request: request) }
        } catch { store.banner = error.localizedDescription }
    }
    /// `/delete`.
    func deleteCurrent() {
        guard let store else { return }
        guard let id = store.state.selectedConversationID else { store.banner = "No active session to delete"; return }
        requestDelete(id)
    }

    // MARK: - Rename

    func performRename(id: UUID, request: SessionRenameRequest) async {
        guard let store, let task = store.task(id) else { return }
        // Optimistic, as in the terminal: a failed harness rename keeps the new local title.
        if case .title(let title) = request { store.renameConversation(id, title: title) }
        guard let session = task.sessionID, let project = project(of: task) else {
            switch request {
            case .title(let title): store.banner = "Session renamed to \"\(title)\""
            case .auto: store.banner = "Couldn't reset session title: this task has not started a session yet"
            }
            return
        }
        var params: [String: Any] = ["sessionId": session, "cwd": project.path, "kind": "build"]
        switch request {
        case .title(let title): params["title"] = title
        case .auto: params["title"] = ""; params["resetToAuto"] = true
        }
        do {
            let result = try await withHarness(for: id, cwd: project.path) { client, _ in
                try await client.request("_x.ai/session/rename", params: params)
            }
            try Self.requireSuccess(result, fallback: "The harness did not confirm the new title.")
            switch request {
            case .title(let title): store.banner = "Session renamed to \"\(title)\""
            case .auto: store.banner = "Session title reset to auto"
            }
        } catch {
            store.banner = request == .auto ? "Couldn't reset session title: \(Self.describe(error))" : "Couldn't rename session: \(Self.describe(error))"
        }
    }

    // MARK: - Delete

    /// Confirms, then deletes the task's harness session and its desktop record.
    func requestDelete(_ id: UUID) {
        guard let store, let task = store.task(id) else { return }
        guard store.runs[id]?.questions.isEmpty ?? true else { store.banner = "Finish answering the current question first"; return }
        guard !deleting.contains(id) else { return }
        confirmDelete(task.title, task.sessionID != nil) { [weak self] confirmed in
            guard confirmed else { return }
            Task { await self?.performDelete(id) }
        }
    }

    /// The terminal's sequence: cancel the turn and its subagents, stop running background tasks,
    /// delete the session in the harness, and only then forget it locally.
    func performDelete(_ id: UUID) async {
        guard let store, let task = store.task(id), !deleting.contains(id) else { return }
        guard let session = task.sessionID, let project = project(of: task) else {
            store.stopOperation(id, phase: "Stopped")
            store.deleteConversation(id)
            boards[id] = nil
            store.banner = "Session deleted"
            return
        }
        deleting.insert(id)
        defer { deleting.remove(id) }
        store.banner = "Deleting session…"
        do {
            let result = try await withHarness(for: id, cwd: project.path) { client, isLive -> [String: Any] in
                if isLive {
                    try? client.notify("session/cancel", params: ["sessionId": session, "_meta": ["cancelSubagents": true]])
                    for taskID in await self.runningBackgroundTaskIDs(client, conversationID: id, session: session) {
                        _ = try? await client.request("_x.ai/task/kill", params: ["sessionId": session, "taskId": taskID, "source": "teardown"])
                    }
                }
                return try await client.request("_x.ai/session/delete", params: ["sessionId": session, "cwd": project.path], timeout: 120)
            }
            try Self.requireSuccess(result, fallback: "The harness did not delete the session.")
            store.stopOperation(id, phase: "Stopped")
            store.deleteConversation(id)
            boards[id] = nil
            store.banner = "Session deleted"
        } catch {
            store.banner = "Couldn't delete session: \(Self.describe(error))"
        }
    }

    private func runningBackgroundTaskIDs(_ client: ACPClient, conversationID: UUID, session: String) async -> [String] {
        do {
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/task/list", params: ["sessionId": session]))
            if let tasks = result["tasks"] as? [[String: Any]] {
                return tasks.compactMap(SessionBackgroundTask.init(snapshot:)).filter(\.isRunning).map(\.id)
            }
        } catch { /* Fall back to the last snapshot the harness pushed. */ }
        return board(for: conversationID).background.filter(\.isRunning).map(\.id)
    }

    static func presentDeleteAlert(title: String, hasSession: Bool, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this session permanently?"
        alert.informativeText = hasSession
            ? "Delete removes the history of “\(title)” and returns home. Cancel keeps the session."
            : "“\(title)” has not started a session yet. Delete removes it from Crok Desktop."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: - Fork

    /// Answers the worktree question from the fork sheet.
    func resolveFork(_ choice: SessionForkChoice, arguments: String) {
        guard let store else { return }
        store.sheet = nil
        guard let parentID = store.state.selectedConversationID else { return }
        let directive = (try? SessionForkArguments.parse(arguments))?.directive
        if let mode = choice.persistedMode {
            do { try GrokConfig.update(url: configURL()) { try $0.set("fork_worktree_mode", to: .string(mode.rawValue), in: "hints") } }
            catch { store.banner = "Couldn't save the worktree preference: \(error.localizedDescription)" }
        }
        Task { await performFork(parentID: parentID, worktree: choice.usesWorktree, directive: directive) }
    }

    /// Forks a task's session into a new task, in place or in a new git worktree, then loads it
    /// and sends the directive as its first prompt.
    func performFork(parentID: UUID, worktree: Bool, directive: String?) async {
        guard let store, let parent = store.task(parentID), let parentSession = parent.sessionID, let project = project(of: parent) else { return }
        // A placeholder task shows progress right away; a worktree can take a while to prepare.
        let child = Conversation(projectID: project.id, title: String((parent.title + " (fork)").prefix(200)), modelID: parent.modelID, reasoningID: parent.reasoningID)
        store.state.conversations.insert(child, at: 0)
        let operationID = store.beginOperation(child.id, phase: worktree ? "Creating worktree" : "Forking")
        store.runs[child.id]?.isConfiguring = true
        store.selectConversation(child)
        if worktree { store.append(Message(kind: .system, text: "Creating worktree…", createdAt: Date()), to: child.id) }
        do {
            let home = grokHome()
            // A parent that is itself a worktree tells the harness where its workspace lives.
            let parentIsWorktree = worktree ? false : await Task.detached(priority: .userInitiated) {
                SessionWorktreeDetection.isWorktree(sessionDirectory: GrokPaths.sessionDirectory(cwd: project.path, sessionID: parentSession, home: home), cwd: project.path)
            }.value
            let outcome = try await withHarness(for: parentID, cwd: project.path) { client, _ -> ForkOutcome in
                worktree
                    ? try await Self.forkIntoWorktree(client, session: parentSession, cwd: project.path)
                    : try await Self.forkInPlace(client, session: parentSession, cwd: project.path, isWorktree: parentIsWorktree)
            }
            store.finishOperation(child.id, operationID: operationID)
            guard let index = store.state.conversations.firstIndex(where: { $0.id == child.id }) else { return }
            store.state.conversations[index].sessionID = outcome.sessionID
            if outcome.cwd != project.path {
                store.state.conversations[index].projectID = self.project(forPath: outcome.cwd).id
            }
            store.append(Message(kind: .system, text: directive.map { "Forked: \($0)" } ?? "Forked", createdAt: Date()), to: parentID)
            if store.state.selectedConversationID == child.id, let bound = store.task(child.id), bound.projectID != store.state.selectedProjectID {
                store.selectConversation(bound)
            }
            await loadConversation(child.id)
            // After the load, which replaces the transcript with the harness's copy.
            var notes: [String] = []
            if let path = outcome.worktreePath {
                notes.append("Worktree ready: \(path)")
                switch (outcome.codeRestored, outcome.restoreSummary) {
                case (true, let summary?): notes.append("✓ Code restored: \(summary)")
                case (false, let summary?): notes.append("⚠ Code restore failed: \(summary)")
                default: break
                }
            }
            notes.append("Session \(outcome.sessionID) (forked from \(parentSession)), use /dashboard to switch between sessions" + (worktree ? "" : "\n  (both agents share cwd)"))
            for note in notes { store.append(Message(kind: .system, text: note, createdAt: Date()), to: child.id) }
            if let directive {
                if store.state.selectedConversationID == child.id, store.loaded.contains(child.id) {
                    store.send(displayText: directive, bypassDesktopCommands: true)
                } else {
                    store.drafts[.conversation(child.id)] = directive
                }
            }
        } catch {
            store.finishOperation(child.id, operationID: operationID)
            let wasSelected = store.state.selectedConversationID == child.id
            store.deleteConversation(child.id)
            if wasSelected, let parent = store.task(parentID) { store.selectConversation(parent) }
            store.banner = (worktree ? "couldn't resume worktree session: " : "fork failed: ") + Self.describe(error)
        }
    }

    struct ForkOutcome {
        var sessionID: String
        var cwd: String
        var worktreePath: String?
        var codeRestored = false
        var restoreSummary: String?
    }

    static func forkInPlace(_ client: ACPClient, session: String, cwd: String, isWorktree: Bool) async throws -> ForkOutcome {
        var params: [String: Any] = ["sourceSessionId": session, "sourceCwd": cwd, "newCwd": cwd, "sessionKind": "fork"]
        if isWorktree { params["sourceWorkspaceDir"] = cwd }
        let response = try await client.request("_x.ai/session/fork", params: params, timeout: 120)
        if let error = response["error"], !(error is NSNull) {
            throw DesktopError.message((error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "\(error)")
        }
        guard let sessionID = response["newSessionId"] as? String ?? (response["result"] as? [String: Any])?["newSessionId"] as? String else {
            throw DesktopError.message("fork response missing newSessionId")
        }
        return ForkOutcome(sessionID: sessionID, cwd: response["newCwd"] as? String ?? cwd)
    }

    /// `git/worktree/resume_session` copies the parent into a new session inside a fresh worktree.
    static func forkIntoWorktree(_ client: ACPClient, session: String, cwd: String) async throws -> ForkOutcome {
        let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/git/worktree/resume_session", params: [
            "sessionId": session, "sourceCwd": cwd, "copyMode": "dirty",
        ], timeout: 900))
        guard let path = result["worktreePath"] as? String else { throw DesktopError.message("response missing worktreePath") }
        return ForkOutcome(sessionID: result["sessionId"] as? String ?? session, cwd: result["effectiveCwd"] as? String ?? path, worktreePath: path,
                           codeRestored: result["codeRestored"] as? Bool ?? false, restoreSummary: result["restoreSummary"] as? String)
    }

    /// Loads one task's session, like `AppStore.loadImportedConversation` but for any task, so a
    /// selection change while a fork or resume finishes cannot load the wrong one.
    func loadConversation(_ id: UUID) async {
        guard let store, let task = store.task(id), task.sessionID != nil, !store.loaded.contains(id),
              store.runs[id]?.isRunning != true, let project = project(of: task) else { return }
        let operationID = store.beginOperation(id, phase: "Loading history")
        store.importing.insert(id)
        store.importBuffers[id] = []
        defer { store.finishOperation(id, operationID: operationID) }
        do {
            _ = try await store.connect(id: id, project: project, operationID: operationID)
            try store.checkOperation(id, operationID: operationID)
            store.runs[id]?.phase = "Ready"
            store.save()
        } catch {
            guard store.operationIDs[id] == operationID else { return }
            store.runs[id]?.phase = error is CancellationError ? "Stopped" : "Needs attention"
            if !(error is CancellationError) { store.banner = error.localizedDescription }
            store.discardConnection(id)
        }
    }

    // MARK: - Resume

    /// Loads the first page of saved sessions for the selected project, or the next page.
    func loadResumeSessions(more: Bool = false) async {
        guard harnessRequestsEnabled else { return }
        guard let store, let project = store.project else { resumeError = "Open a project first."; return }
        if more && resumeCursor == nil { return }
        let requestID = UUID()
        resumeRequestID = requestID
        resumeLoading = true
        if !more { resumeError = nil }
        defer { if resumeRequestID == requestID { resumeLoading = false } }
        do {
            let client = try await resumeClient(cwd: project.path)
            var params: [String: Any] = ["cwd": project.path, "limit": 30, "headless": "exclude"]
            if more, let cursor = resumeCursor { params["cursor"] = cursor }
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/session/list", params: params, timeout: 60))
            guard resumeRequestID == requestID, store.project?.id == project.id else { return }
            let page = HarnessSessionRow.parseList(result)
            if more {
                let known = Set(resumeRows.map(\.id))
                resumeRows += page.rows.filter { !known.contains($0.id) }
            } else { resumeRows = page.rows }
            resumeCursor = page.nextCursor
        } catch {
            guard resumeRequestID == requestID else { return }
            resumeError = Self.describe(error)
        }
    }

    /// Searches every saved session's titles and content. Empty queries clear the results.
    func searchSessions(_ query: String) async {
        guard harnessRequestsEnabled else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        searchRequestID = requestID
        guard !query.isEmpty else {
            searchRows = []; searchedQuery = ""; searchLoading = false; searchError = nil; searchBootstrapping = false
            return
        }
        guard let store, let project = store.project else { return }
        searchLoading = true; searchError = nil
        defer { if searchRequestID == requestID { searchLoading = false } }
        do {
            let client = try await resumeClient(cwd: project.path)
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/session/search", params: [
                "query": query, "limit": 20, "includeContent": true, "headless": "exclude",
            ], timeout: 60))
            guard searchRequestID == requestID else { return }
            let parsed = HarnessSessionRow.parseSearch(result)
            searchRows = parsed.rows; searchBootstrapping = parsed.bootstrapping; searchedQuery = query
        } catch {
            guard searchRequestID == requestID else { return }
            searchRows = []; searchedQuery = query
            searchError = Self.describe(error)
        }
    }

    /// Opens a saved session as a desktop task, reusing the task when it is already in the sidebar.
    func resumeSession(_ row: HarnessSessionRow) async {
        guard let store else { return }
        store.sheet = nil
        if let index = store.state.conversations.firstIndex(where: { $0.sessionID == row.id }) {
            store.state.conversations[index].isArchived = false
            store.selectConversation(store.state.conversations[index])
            await loadConversation(store.state.conversations[index].id)
            return
        }
        // Choosing a session explicitly brings back one that was removed from the sidebar.
        store.state.deletedSessionIDs.remove(row.id)
        let cwd = row.cwd.isEmpty ? (store.project?.path ?? "") : row.cwd
        guard !cwd.isEmpty else { return }
        let task = Conversation(projectID: project(forPath: cwd).id, title: row.title, sessionID: row.id, updatedAt: row.updatedAt ?? Date())
        store.state.conversations.insert(task, at: 0)
        store.selectConversation(task)
        await loadConversation(task.id)
    }

    func closeResume() {
        resumeRequestID = nil; searchRequestID = nil
        resumeLoading = false; searchLoading = false
        dropResumeConnection()
    }

    /// Concurrent requests (the list and a search) share one starting connection.
    private func resumeClient(cwd: String) async throws -> ACPClient {
        if let connection = resumeConnection, connection.cwd == cwd, let started = try? await connection.start.value, started.0.isRunning {
            return started.0
        }
        dropResumeConnection()
        let start = Task { try await self.startAuxiliaryClient(cwd: cwd) }
        resumeConnection = (cwd, start)
        do { return try await start.value.0 } catch {
            if resumeConnection?.start == start { resumeConnection = nil }
            throw error
        }
    }

    private func dropResumeConnection() {
        guard let start = resumeConnection?.start else { return }
        resumeConnection = nil
        Task { if let started = try? await start.value { stopAuxiliary(started.0, key: started.1) } }
    }

    // MARK: - Tasks and workflows

    /// Refreshes the selected task's background tasks from the harness when it is connected.
    /// A task without a live connection has nothing running, so no process is started for it.
    func refreshBackgroundTasks() async {
        guard harnessRequestsEnabled, let store, let id = store.state.selectedConversationID, let session = store.task(id)?.sessionID,
              let client = store.clients[id], store.loaded.contains(id) else { return }
        tasksLoading = true; tasksError = nil
        defer { tasksLoading = false }
        do {
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/task/list", params: ["sessionId": session]))
            guard let tasks = result["tasks"] as? [[String: Any]] else { throw DesktopError.message("The harness did not return background tasks.") }
            var board = boards[id] ?? SessionTaskBoard()
            board.replaceBackground(withTaskList: tasks)
            boards[id] = board
        } catch {
            tasksError = "Could not load background tasks: \(Self.describe(error))"
        }
    }

    func stopBackgroundTask(_ taskID: String, conversationID: UUID) {
        guard let live = liveSession(conversationID) else { tasksError = "This task is no longer connected."; return }
        boards[conversationID, default: SessionTaskBoard()].stopping.insert(taskID)
        Task {
            do {
                _ = try ExtensionResponse.unwrap(try await live.client.request("_x.ai/task/kill", params: ["sessionId": live.session, "taskId": taskID]))
                await refreshBackgroundTasks()
            } catch {
                boards[conversationID]?.stopping.remove(taskID)
                tasksError = "Could not stop the task: \(Self.describe(error))"
            }
        }
    }

    func stopSubagent(_ subagentID: String, conversationID: UUID) {
        guard let store, let live = liveSession(conversationID) else { tasksError = "This task is no longer connected."; return }
        stoppingSubagents.insert(subagentID)
        Task {
            defer { stoppingSubagents.remove(subagentID) }
            do {
                let result = try ExtensionResponse.unwrap(try await live.client.request("_x.ai/subagent/cancel", params: ["subagentId": subagentID]))
                guard let index = store.runs[conversationID]?.subagents.firstIndex(where: { $0.id == subagentID }) else { return }
                let outcome = result["outcome"] as? [String: Any]
                switch outcome?["kind"] as? String {
                case "already_finished": store.runs[conversationID]?.subagents[index].status = outcome?["status"] as? String ?? "completed"
                case "not_found": store.runs[conversationID]?.subagents[index].status = "unavailable"
                default: if result["cancelled"] as? Bool == true { store.runs[conversationID]?.subagents[index].status = "cancelled" }
                }
            } catch {
                tasksError = "Could not stop the subagent: \(Self.describe(error))"
            }
        }
    }

    func deleteScheduledTask(_ taskID: String, conversationID: UUID) {
        guard let live = liveSession(conversationID) else { tasksError = "This task is no longer connected."; return }
        Task {
            do {
                let result = try ExtensionResponse.unwrap(try await live.client.request("_x.ai/scheduler/delete", params: ["sessionId": live.session, "taskId": taskID]))
                if result["deleted"] as? Bool == false { tasksError = "The scheduled task had already finished." }
                boards[conversationID]?.scheduled.removeAll { $0.id == taskID }
            } catch {
                tasksError = "Could not delete the scheduled task: \(Self.describe(error))"
            }
        }
    }

    /// Whether the harness offers `/workflow` management in the selected task.
    var workflowManagementAvailable: Bool {
        guard let run = store?.run else { return false }
        return !run.commandsLoaded || run.commands.contains { $0.name == "workflow" }
    }

    /// Pause, resume, stop, or save a workflow run: `/workflow <op> <run>`, as the terminal sends.
    func workflowAction(_ operation: String, run: SessionWorkflowRun) {
        store?.forwardToHarness("workflow", arguments: "\(operation) \(run.name)")
    }

    private func liveSession(_ id: UUID) -> (client: ACPClient, session: String)? {
        guard let store, let client = store.clients[id], store.loaded.contains(id), let session = store.task(id)?.sessionID else { return nil }
        return (client, session)
    }

    // MARK: - Dashboard

    /// Stops a task's turn. The selected task uses the composer's Stop; others are cancelled directly.
    func stopTask(_ id: UUID) {
        guard let store, store.runs[id]?.isRunning == true else { return }
        if store.state.selectedConversationID == id { store.cancel(); return }
        guard let client = store.clients[id], store.loaded.contains(id), !store.importing.contains(id),
              let session = store.task(id)?.sessionID else { store.stopOperation(id, phase: "Stopped"); return }
        store.cancellationRequested.insert(id)
        for approval in store.runs[id]?.approvals ?? [] {
            let folder = approval.options.contains { $0.id.hasPrefix("folder:") }
            let plan = approval.options.contains { $0.id.hasPrefix("plan:") }
            try? client.respond(id: approval.requestID, result: folder ? ["outcome": "reject"] : plan ? ["outcome": "cancelled"] : ["outcome": ["outcome": "cancelled"]])
        }
        for question in store.runs[id]?.questions ?? [] { try? client.respond(id: question.requestID, result: ["outcome": "cancelled"]) }
        store.runs[id]?.approvals = []; store.runs[id]?.questions = []
        do { try client.notify("session/cancel", params: ["sessionId": session]) } catch { store.stopOperation(id, phase: "Stopped"); return }
        store.runs[id]?.phase = "Stopping"
        // Recover from a harness that never ends the turn, as the composer's Stop does.
        let operationID = store.operationIDs[id]
        Task { [weak self, weak client] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let store = self?.store, let client, store.operationIDs[id] == operationID, store.clients[id] === client,
                  store.runs[id]?.isRunning == true else { return }
            store.stopOperation(id, phase: "Stopped")
        }
    }

    /// Sends a reply to a task from the dashboard: it becomes the selected task, then the prompt is sent.
    func reply(to id: UUID, text: String) {
        guard let store, let task = store.task(id) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.selectConversation(task)
        store.send(displayText: text)
    }

    func open(_ id: UUID) {
        guard let store, let task = store.task(id) else { return }
        store.sheet = nil
        store.selectConversation(task)
    }

    // MARK: - Trace

    func traceWindowAppeared() {
        guard let store else { return }
        traceSelection = store.$state.map(\.selectedConversationID).removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.loadTrace() }
        }
        Task { await loadTrace() }
    }

    func traceWindowDisappeared() {
        traceSelection = nil
        traceRequestID = nil
        replaceTraceFile(with: nil)
        trace = .idle
    }

    /// Exports the selected task's trace to a private HTML file with `crok trace view`.
    func loadTrace() async {
        guard harnessRequestsEnabled, let store else { return }
        let requestID = UUID()
        traceRequestID = requestID
        guard let task = store.conversation, let session = task.sessionID, let project = project(of: task) else {
            traceTitle = store.conversation?.title ?? ""
            replaceTraceFile(with: nil)
            trace = .unavailable("No active session to trace")
            return
        }
        traceTitle = task.title
        let home = grokHome()
        let directory = await Task.detached(priority: .userInitiated) { GrokPaths.sessionDirectory(cwd: project.path, sessionID: session, home: home) }.value
        guard traceRequestID == requestID else { return }
        guard let directory else {
            replaceTraceFile(with: nil)
            trace = .unavailable("This session has not been recorded yet")
            return
        }
        trace = .loading(directory: directory.path)
        do {
            let output = try TraceExport.outputFile(sessionID: session)
            let result = try await GrokCLI.run(store.binaryPath, arguments: TraceExport.arguments(source: directory.path, output: output.path), cwd: project.path, timeout: 180)
            guard traceRequestID == requestID else { try? FileManager.default.removeItem(at: output); return }
            guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
                try? FileManager.default.removeItem(at: output)
                throw DesktopError.message(TraceExport.errorSummary(status: result.status, stderr: result.stderr))
            }
            replaceTraceFile(with: output)
            traceRevision += 1
            trace = .loaded(file: output, directory: directory.path, sessionID: session)
        } catch {
            guard traceRequestID == requestID else { return }
            replaceTraceFile(with: nil)
            trace = .failed(directory: directory.path, error: error.localizedDescription)
        }
    }

    private func replaceTraceFile(with file: URL?) {
        if let old = traceFile, old != file { try? FileManager.default.removeItem(at: old) }
        traceFile = file
    }

    func saveTrace() {
        guard case .loaded(let file, _, let session) = trace else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session).html"
        panel.allowedContentTypes = [.html]
        panel.message = "The page includes the session's recorded content. Review it before sharing."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: file, to: destination)
        } catch { store?.banner = "Could not save the trace: \(error.localizedDescription)" }
    }

    func openTraceInBrowser() {
        guard case .loaded(let file, _, _) = trace else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: - Doctor

    func runDoctor() async {
        guard harnessRequestsEnabled, let store else { return }
        let requestID = UUID()
        doctorRequestID = requestID
        doctorLoading = true; doctorError = nil
        defer { if doctorRequestID == requestID { doctorLoading = false } }
        let checks = await DoctorDesktopCheck.collect(binaryPath: store.binaryPath, agentVersion: store.harnessMeta.agentVersion, accounts: accountReader())
        guard doctorRequestID == requestID else { return }
        desktopChecks = checks
        do {
            let cwd = store.project?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            let result = try await GrokCLI.run(store.binaryPath, arguments: ["doctor", "--json"], cwd: cwd, timeout: 60)
            guard doctorRequestID == requestID else { return }
            guard !result.stdout.isEmpty else {
                throw DesktopError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "crok doctor exited with status \(result.status)." : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            doctorReport = try DoctorReport.decode(result.stdout)
        } catch {
            guard doctorRequestID == requestID else { return }
            doctorError = error.localizedDescription
        }
    }

    /// Terminal fixes change terminal and shell configuration, so they run where the user can
    /// review and confirm them: in Terminal, with the terminal's own `crok doctor fix` prompt.
    func runFixInTerminal(_ fix: DoctorFixSpec) {
        guard let store else { return }
        do {
            let script = try DoctorTerminalScript.write(binary: store.binaryPath, fix: fix)
            NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
        } catch { store.banner = "Couldn't open Terminal: \(error.localizedDescription)" }
    }

    // MARK: - Harness connections

    /// Runs `body` on the task's live connection when it has one, so the harness that holds the
    /// session applies the change; otherwise on a short-lived connection that never loads it.
    func withHarness<T>(for conversationID: UUID?, cwd: String, _ body: (ACPClient, _ isLive: Bool) async throws -> T) async throws -> T {
        guard let store else { throw CancellationError() }
        if let id = conversationID, let client = store.clients[id], store.loaded.contains(id) { return try await body(client, true) }
        let (client, key) = try await startAuxiliaryClient(cwd: cwd)
        defer { stopAuxiliary(client, key: key) }
        return try await body(client, false)
    }

    private func startAuxiliaryClient(cwd: String) async throws -> (ACPClient, UUID) {
        guard let store else { throw CancellationError() }
        guard FileManager.default.isExecutableFile(atPath: store.binaryPath) else {
            throw DesktopError.message("The bundled Crok runtime is missing. Reinstall Crok Desktop.")
        }
        let client = ACPClient(), key = UUID()
        store.auxiliaryClients[key] = client
        do {
            try client.start(executable: store.binaryPath, cwd: cwd)
            let initial = try await store.initialize(client)
            try await store.authenticate(client, initial: initial)
            return (client, key)
        } catch {
            stopAuxiliary(client, key: key)
            throw error
        }
    }

    private func stopAuxiliary(_ client: ACPClient, key: UUID) {
        client.stop()
        store?.auxiliaryClients.removeValue(forKey: key)
    }

    // MARK: - Helpers

    func project(of task: Conversation) -> Project? { store?.state.projects.first { $0.id == task.projectID } }

    /// The desktop project for a folder, added to the sidebar when it is new (for example a fork's worktree).
    func project(forPath path: String) -> Project {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let store else { return Project(path: normalized) }
        if let existing = store.state.projects.first(where: { $0.path == path || $0.path == normalized }) { return existing }
        let project = Project(path: normalized)
        store.state.projects.append(project)
        store.save()
        return project
    }

    /// `session/rename` and `session/delete` answer `{success:true}`; errors may also arrive wrapped.
    static func requireSuccess(_ response: [String: Any], fallback: String) throws {
        if let message = response["error"] as? String { throw DesktopError.message(message) }
        if let error = response["error"] as? [String: Any] { throw DesktopError.message(error["message"] as? String ?? fallback) }
        let result = response["result"] as? [String: Any] ?? response
        if result["success"] as? Bool == false { throw DesktopError.message(fallback) }
    }

    /// The harness puts the useful part of an ACP error in `data`, for example "session not found: …".
    static func describe(_ error: Error) -> String {
        if case ACPClientError.remote(_, let message, let data) = error {
            if let text = data as? String, !text.isEmpty { return text }
            if let object = data as? [String: Any], let text = object["message"] as? String ?? object["error"] as? String, !text.isEmpty { return text }
            return message
        }
        return error.localizedDescription
    }
}
