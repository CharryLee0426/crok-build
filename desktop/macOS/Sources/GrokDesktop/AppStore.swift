import AppKit
import Combine
import SwiftUI

/// The few flags the menu bar depends on. They are published apart from the store, which
/// changes many times a second while output streams, so menus are rebuilt only when they change.
@MainActor
final class MenuState: ObservableObject {
    @Published fileprivate(set) var isRunning = false
    @Published fileprivate(set) var hasProject = false
    @Published fileprivate(set) var isSyncing = false
}

@MainActor
final class AppStore: ObservableObject {
    @Published var state = DesktopState()
    @Published var runs: [UUID: RunState] = [:]
    @Published var draft = ""
    @Published var search = ""
    @Published var showSearch = false
    @Published var showSettings = false
    @Published var showRename = false
    /// The command sheet on screen, if any.
    @Published var sheet: DesktopSheet?
    /// A secondary window a command asked to open; the main window opens it.
    @Published var windowRequest: DesktopWindow?
    /// `/minimal`: the conversation alone, without the sidebar, inspector, or toolbar.
    @Published var minimalMode = false
    /// What the harness reported about itself and the signed-in account.
    @Published var harnessMeta = HarnessMeta()
    lazy var features = DesktopFeatures(store: self)
    /// The side panel beside the conversation: files, side chat, and terminal.
    @Published var showInspector = false
    @Published var sidePanelTab: SidePanelTab = .files {
        didSet { defaults.set(sidePanelTab.rawValue, forKey: "sidePanelTab") }
    }
    @Published var showArchived = false
    /// Recents lists every project's tasks, so it starts folded each launch.
    @Published var recentsExpanded = false
    /// Tasks whose turn finished while another task was on screen.
    @Published var unreadConversationIDs: Set<UUID> = []
    @Published var workspace = GitWorkspaceSnapshot(branch: "", changes: [])
    @Published var selectedFile: String?
    @Published var diffText = ""
    @Published var banner: String?
    @Published var syncing = false
    @Published var loginLog = ""
    @Published var loginRunning = false
    @Published var showCommandPalette = false
    @Published var featurePanel: FeaturePanel?
    @Published var featureRows: [FeatureRow] = []
    @Published var featureLoading = false
    @Published var featureError: String?
    @Published var savedPlanContent: String?
    @Published var savedPlanLoading = false
    @Published var savedPlanError: String?
    @Published var advancedContent: String?
    @Published var advancedLoading = false
    @Published var advancedError: String?
    @Published var advancedTitle = "Details"
    @Published var showAdvancedPanel = false
    var advancedRequestID: UUID?
    var savedPlanRequestID: UUID?
    @Published var rewindPoints: [RewindCheckpoint] = []
    @Published var rewindPreview: RewindPreview?
    var rewindConversationID: UUID?
    var pendingRecap: (conversationID: UUID, requestID: UUID)?
    var featureRequestID: UUID?
    var featureNotificationRefresh: Task<Void, Never>?
    var auxiliaryClients: [UUID: ACPClient] = [:]
    var pendingModes: [UUID: String] = [:]
    private(set) var binaryPath: String = ""
    @Published var catalogRun = RunState()
    var catalogProjectID: UUID?
    var commandCatalogProjectID: UUID?
    private var catalogLoadingProjectID: UUID?
    private var catalogClient: ACPClient?
    private let stateFile: URL
    private let defaults: UserDefaults
    enum DraftLocation: Hashable {
        case conversation(UUID)
        case newTask(UUID?)
    }
    var drafts: [DraftLocation: String] = [:]
    var draftLocation: DraftLocation {
        state.selectedConversationID.map(DraftLocation.conversation) ?? .newTask(state.selectedProjectID)
    }
    var clients: [UUID: ACPClient] = [:]
    var loaded: Set<UUID> = []
    var replaying: Set<UUID> = []
    var operations: [UUID: Task<Void, Never>] = [:]
    var operationIDs: [UUID: UUID] = [:]
    private var cancellationFallbacks: [UUID: Task<Void, Never>] = [:]
    var cancellationRequested: Set<UUID> = []
    var importBuffers: [UUID: [Message]] = [:]
    var pendingPrompts: [UUID: Message] = [:]
    private var historyClient: ACPClient?
    private var saveTask: Task<Void, Never>?
    private var saveDeadline: Date?
    /// Serializes state writes so the newest snapshot always lands last.
    private let persistence = DispatchQueue(label: "ai.grok.desktop.state", qos: .utility)
    private var pendingTranscript: [UUID: [[String: Any]]] = [:]
    private var transcriptFlush: Task<Void, Never>?
    private var transcriptRevisions: [UUID: Int] = [:]
    let menuState = MenuState()
    private var menuStateObserver: AnyCancellable?
    private var menuStateUpdateScheduled = false
    private var loginProcess: Process?
    private let git = WorkspaceService()

    var project: Project? { state.projects.first { $0.id == state.selectedProjectID } }
    var conversation: Conversation? { state.conversations.first { $0.id == state.selectedConversationID } }
    var run: RunState {
        var catalog = catalogRun
        if commandCatalogProjectID != state.selectedProjectID { catalog.commands = []; catalog.commandsLoaded = false; catalog.availableTools = nil }
        if let id = state.selectedConversationID {
            if let existing = runs[id] { return existing }
            var initial = catalog
            initial.isConfiguring = false
            initial.modelID = task(id)?.modelID ?? initial.modelID
            initial.reasoningID = task(id)?.reasoningID ?? initial.reasoningID
            return initial
        }
        return catalog
    }
    /// Tasks in a project folder, most recently updated first.
    func conversations(inProject id: UUID) -> [Conversation] {
        Self.newestFirst(state.conversations.filter { $0.projectID == id && !$0.isArchived })
    }
    /// Every active task across all projects, most recently updated first.
    var recentConversations: [Conversation] { Self.newestFirst(state.conversations.filter { !$0.isArchived }) }
    var pinnedConversations: [Conversation] { Self.newestFirst(state.conversations.filter { $0.isPinned && !$0.isArchived }) }
    var archivedConversations: [Conversation] { Self.newestFirst(state.conversations.filter(\.isArchived)) }
    /// Search covers every project; the archive toggle chooses which tasks are searched.
    var searchResults: [Conversation] {
        Self.newestFirst(state.conversations.filter { $0.isArchived == showArchived && $0.title.localizedCaseInsensitiveContains(search) })
    }
    nonisolated static func newestFirst(_ tasks: [Conversation]) -> [Conversation] {
        tasks.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
    func isProjectExpanded(_ id: UUID) -> Bool { !state.collapsedProjectIDs.contains(id) }
    func toggleProjectExpanded(_ id: UUID) {
        if state.collapsedProjectIDs.remove(id) == nil { state.collapsedProjectIDs.insert(id) }
        save()
    }

    init(stateFile: URL = DesktopPaths.stateFile, defaults: UserDefaults = .standard, binaryPath: String? = nil) {
        self.stateFile = stateFile
        self.defaults = defaults
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode(DesktopState.self, from: data) { state = saved }
        if state.projects.isEmpty {
            var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            while directory.path != "/" {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                    let project = Project(path: directory.path)
                    state.projects = [project]; state.selectedProjectID = project.id
                    break
                }
                directory.deleteLastPathComponent()
            }
        }
        self.binaryPath = binaryPath ?? ProcessInfo.processInfo.environment["GROK_DESKTOP_HARNESS"] ?? DesktopPaths.findHarness(in: state.projects.first?.path)
        if state.projects.contains(where: { $0.id == state.selectedProjectID }) == false { state.selectedProjectID = state.projects.first?.id }
        if let tab = defaults.string(forKey: "sidePanelTab").flatMap(SidePanelTab.init(rawValue:)) { sidePanelTab = tab }
        updateMenuState()
        menuStateObserver = objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                // The change has not landed yet; read it once the current burst is done.
                guard let self, !self.menuStateUpdateScheduled else { return }
                self.menuStateUpdateScheduled = true
                DispatchQueue.main.async { [weak self] in self?.updateMenuState() }
            }
        }
    }

    private func updateMenuState() {
        menuStateUpdateScheduled = false
        let isRunning = run.isRunning, hasProject = project != nil
        if menuState.isRunning != isRunning { menuState.isRunning = isRunning }
        if menuState.hasProject != hasProject { menuState.hasProject = hasProject }
        if menuState.isSyncing != syncing { menuState.isSyncing = syncing }
    }

    /// Coalesces bursts of changes into one write, which is encoded off the main thread.
    func save() {
        let now = Date()
        // Streaming output would postpone a plain debounce indefinitely, so bound the wait.
        let deadline = saveDeadline ?? now.addingTimeInterval(5)
        saveDeadline = deadline
        let delay = max(0, min(0.25, deadline.timeIntervalSince(now)))
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.takeSnapshot()
            self.persistence.async { [weak self] in
                do { try Self.write(snapshot.state, to: snapshot.file) }
                catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self?.banner = "Could not save task history: \(message)" }
                }
            }
        }
    }

    /// Writes the current state before returning, after any write already queued.
    func flush() {
        let snapshot = takeSnapshot()
        do { try persistence.sync { try Self.write(snapshot.state, to: snapshot.file) } }
        catch { banner = "Could not save task history: \(error.localizedDescription)" }
    }

    private func takeSnapshot() -> (state: DesktopState, file: URL) {
        saveTask?.cancel(); saveTask = nil; saveDeadline = nil
        return (state, stateFile)
    }

    nonisolated private static func write(_ state: DesktopState, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open project"; panel.message = "Choose the folder Grok will work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.resolvingSymlinksInPath().path
        let project = state.projects.first(where: { $0.path == path }) ?? Project(path: path)
        if !state.projects.contains(where: { $0.id == project.id }) { state.projects.append(project) }
        selectProject(project.id)
    }

    func selectProject(_ id: UUID) {
        drafts[draftLocation] = draft
        state.selectedProjectID = id; state.selectedConversationID = nil
        draft = drafts[draftLocation] ?? ""; search = ""; showArchived = false; selectedFile = nil; diffText = ""
        workspace = GitWorkspaceSnapshot(branch: "", changes: [])
        save(); Task { await refreshWorkspace() }
    }

    func selectConversation(_ task: Conversation) {
        drafts[draftLocation] = draft
        if state.selectedProjectID != task.projectID {
            workspace = GitWorkspaceSnapshot(branch: "", changes: [])
            selectedFile = nil; diffText = ""
        }
        state.selectedConversationID = task.id; state.selectedProjectID = task.projectID
        unreadConversationIDs.remove(task.id)
        draft = drafts[draftLocation] ?? ""; save(); Task { await refreshWorkspace() }
    }

    func newTask() {
        drafts[draftLocation] = draft
        state.selectedConversationID = nil
        draft = drafts[draftLocation] ?? ""; showArchived = false; save()
    }
    func renameConversation(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[i].title = String(title.prefix(200)); save()
    }
    func togglePin(_ id: UUID) {
        guard let i = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[i].isPinned.toggle(); save()
    }
    func archive(_ id: UUID) {
        guard runs[id]?.isRunning != true, let i = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[i].isArchived.toggle()
        if state.selectedConversationID == id { newTask() }
        stopOperation(id, phase: "Ready"); save()
    }

    func deleteConversation(_ id: UUID) {
        guard runs[id]?.isRunning != true, runs[id]?.isConfiguring != true,
              let conversation = task(id) else { return }
        if let session = conversation.sessionID { state.deletedSessionIDs.insert(session) }
        stopOperation(id, phase: "Ready")
        drafts.removeValue(forKey: .conversation(id))
        runs.removeValue(forKey: id)
        transcriptRevisions.removeValue(forKey: id)
        state.conversations.removeAll { $0.id == id }
        unreadConversationIDs.remove(id)
        if state.selectedConversationID == id {
            state.selectedConversationID = nil
            draft = drafts[draftLocation] ?? ""
        }
        // A tombstone must reach disk before a later history import can discover this session.
        flush()
    }

    func prepareSessionOptions() async {
        guard let project else { return }
        if conversation != nil {
            await loadImportedConversation()
            return
        }
        guard !(catalogRun.isConfiguring && catalogLoadingProjectID == project.id),
              catalogProjectID != project.id || catalogRun.models.isEmpty else { return }
        catalogRun.isConfiguring = true
        catalogLoadingProjectID = project.id
        let client = ACPClient()
        client.onNotification = { [weak self] method, params in
            self?.features.handleGlobal(method: method.hasPrefix("_") ? String(method.dropFirst()) : method, params: params)
        }
        catalogClient?.stop(); catalogClient = client
        defer {
            client.stop()
            if catalogClient === client { catalogClient = nil; catalogLoadingProjectID = nil; catalogRun.isConfiguring = false }
        }
        do {
            try client.start(executable: binaryPath, cwd: project.path)
            let initial = try await initialize(client)
            try await authenticate(client, initial: initial)
            let response = try await client.request("_x.ai/models/list", timeout: 60)
            if let error = response["error"] as? String { throw DesktopError.message(error) }
            if let error = response["error"] as? [String: Any] {
                throw DesktopError.message(error["message"] as? String ?? "The runtime could not load its models.")
            }
            guard let models = response["result"] as? [String: Any] else {
                throw DesktopError.message("The runtime returned an invalid model catalog.")
            }
            try Task.checkCancellation()
            guard self.project?.id == project.id else { return }
            catalogProjectID = project.id
            catalogRun.models = SessionOptions.models(models)
            let preferred = state.selectedModelID.flatMap { selected in
                catalogRun.models.first { $0.id == selected }?.id
            }
            catalogRun.modelID = preferred ?? models["currentModelId"] as? String ?? ""
            updateCatalogReasoning(preferred: state.selectedReasoningID)
            state.selectedModelID = catalogRun.modelID.isEmpty ? nil : catalogRun.modelID
            state.selectedReasoningID = catalogRun.reasoningID.isEmpty ? nil : catalogRun.reasoningID
            do {
                let commands = try ExtensionResponse.unwrap(try await client.request("_x.ai/commands/list", params: ["cwd": project.path]))
                guard self.project?.id == project.id else { return }
                catalogRun.commands = SlashCommand.parse(commands["commands"] as? [[String: Any]] ?? [])
                catalogRun.commandsLoaded = true
                catalogRun.availableTools = commands["tools"] as? [String]
                commandCatalogProjectID = project.id
            } catch { /* Model selection still works with an older harness. */ }
            save()
        } catch {
            if !(error is CancellationError), self.project?.id == project.id {
                banner = "Could not load model choices: \(error.localizedDescription)"
            }
        }
    }

    func send(displayText: String? = nil, promptText: String? = nil, requiredTool: String? = nil, bypassDesktopCommands: Bool = false) {
        let prompt = (displayText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let commandDraftLocation = draftLocation
        // Attachments belong to the composer's draft; text sent from elsewhere leaves them in place.
        let pendingAttachments = displayText == nil ? features.attachments.drafts[commandDraftLocation] ?? [] : []
        if promptText == nil, !bypassDesktopCommands, let command = SlashCommand.split(prompt) {
            // Mid-turn, native panels open at once; commands that need an idle task keep the draft.
            let policy: DesktopCommands.TurnPolicy = run.isRunning ? DesktopCommands.turnPolicy(command.name, arguments: command.arguments) : .runNow
            if policy == .waitForIdle {
                banner = "Wait for the current turn to finish or stop it before running /\(command.name)."
                return
            }
            if policy == .runNow, handleDesktopCommand(command.name, arguments: command.arguments) {
                drafts.removeValue(forKey: commandDraftLocation)
                if draftLocation == commandDraftLocation, draft.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { draft = "" }
                return
            }
        }
        if let command = SlashCommand.split(prompt), command.name == "goal", run.isRunning,
           ["status", "pause", "resume", "clear"].contains(command.arguments) {
            draft = ""; drafts.removeValue(forKey: commandDraftLocation)
            goalAction(command.arguments); return
        }
        if pendingAttachments.contains(where: \.isPreparing) {
            banner = "Images are still being prepared. Send again in a moment."
            return
        }
        if !prompt.isEmpty || !pendingAttachments.isEmpty, run.isRunning, let id = state.selectedConversationID,
           features.composer.enqueue(prompt, attachments: pendingAttachments, conversationID: id) {
            if displayText == nil { draft = ""; drafts.removeValue(forKey: commandDraftLocation) }
            _ = features.attachments.take(from: commandDraftLocation)
            return
        }
        guard !prompt.isEmpty || !pendingAttachments.isEmpty, let project, !run.isRunning, !run.isConfiguring else { return }
        if promptText == nil, !bypassDesktopCommands, let command = SlashCommand.split(prompt), run.commandsLoaded,
           !run.commands.contains(where: { $0.name == command.name || $0.aliases.contains(command.name) }) {
            banner = "Unknown command /\(command.name). Open the command menu to see commands available in this project."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            banner = "The bundled Grok runtime is missing. Reinstall Grok Desktop to start a task."; return
        }
        let sentDraftLocation = draftLocation
        let attachments = displayText == nil ? features.attachments.take(from: sentDraftLocation) : []
        var id = state.selectedConversationID
        if id == nil {
            let title = prompt.isEmpty ? attachments.first?.name ?? "New task" : prompt
            let task = Conversation(projectID: project.id, title: String(title.prefix(64)), modelID: state.selectedModelID, reasoningID: state.selectedReasoningID)
            state.conversations.insert(task, at: 0); id = task.id; state.selectedConversationID = task.id
        }
        guard let id else { return }
        let optimisticPrompt = Message(kind: .user, text: prompt, createdAt: Date(), attachments: attachments.isEmpty ? nil : attachments.map(\.messageAttachment))
        append(optimisticPrompt, to: id)
        pendingPrompts[id] = optimisticPrompt
        // Text sent from elsewhere (a dashboard reply, a media command) leaves the draft alone.
        if displayText == nil {
            drafts.removeValue(forKey: sentDraftLocation)
            drafts.removeValue(forKey: .conversation(id))
            draft = ""
        }
        banner = nil
        let operationID = beginOperation(id, phase: "Connecting")
        operations[id] = Task {
            defer { finishOperation(id, operationID: operationID) }
            do {
                let client = try await connect(id: id, project: project, operationID: operationID)
                try checkOperation(id, operationID: operationID)
                guard let session = task(id)?.sessionID else { throw DesktopError.message("The harness did not return a session ID.") }
                if let requiredTool, runs[id]?.availableTools?.contains(requiredTool) != true {
                    throw DesktopError.message("This runtime does not provide the \(requiredTool) tool required by \(prompt.components(separatedBy: " ").first ?? "this command").")
                }
                if promptText == nil, let command = SlashCommand.split(prompt),
                   runs[id]?.commands.contains(where: { $0.name == command.name || $0.aliases.contains(command.name) }) != true {
                    throw DesktopError.message("Command /\(command.name) is not available in this session.")
                }
                pendingPrompts.removeValue(forKey: id)
                runs[id]?.phase = "Working"
                let blocks = PromptBlocks.make(text: promptText ?? prompt, meta: promptText != nil ? ["displayText": prompt] : nil, attachments: attachments)
                let result = try await client.request("session/prompt", params: ["sessionId": session, "prompt": blocks], timeout: nil)
                try checkOperation(id, operationID: operationID)
                flushTranscript(id)
                let stopped = cancellationRequested.contains(id) || result["stopReason"] as? String == "cancelled"
                runs[id]?.phase = stopped ? "Stopped" : "Ready"
                runs[id]?.isRunning = false
                if let i = state.conversations.firstIndex(where: { $0.id == id }) { state.conversations[i].updatedAt = Date() }
                if state.selectedConversationID != id { unreadConversationIDs.insert(id) }
                save()
                features.composer.turnDidFinish(conversationID: id, stopped: stopped)
                await refreshWorkspace()
            } catch {
                guard operationIDs[id] == operationID else { return }
                let stopped = error is CancellationError || cancellationRequested.contains(id)
                runs[id]?.phase = stopped ? "Stopped" : "Needs attention"
                if !stopped {
                    append(Message(kind: .system, text: error.localizedDescription, createdAt: Date()), to: id)
                    if SlashCommand.split(prompt) != nil { banner = error.localizedDescription }
                }
                discardConnection(id)
            }
        }
    }

    func connect(id: UUID, project: Project, operationID: UUID) async throws -> ACPClient {
        try checkOperation(id, operationID: operationID)
        if let client = clients[id], loaded.contains(id) {
            if let mode = pendingModes[id] {
                _ = try await client.request("session/set_mode", params: ["sessionId": task(id)?.sessionID ?? "", "modeId": mode])
                try checkOperation(id, operationID: operationID)
                pendingModes.removeValue(forKey: id); runs[id]?.modeID = mode
            }
            return client
        }
        let client = ACPClient()
        client.onNotification = { [weak self, weak client] method, params in
            guard let self, let client, self.clients[id] === client else { return }
            self.receive(method, params: params, id: id)
        }
        client.onRequest = { [weak self, weak client] requestID, method, params in
            guard let self, let client, self.clients[id] === client else { return }
            self.handleRequest(requestID, method: method, params: params, id: id, client: client)
        }
        client.onDisconnect = { [weak self, weak client] _ in
            guard let self, let client, self.clients[id] === client else { return }
            self.loaded.remove(id)
            self.runs[id]?.phase = "Disconnected"
            self.runs[id]?.approvals = []; self.runs[id]?.questions = []
        }
        clients[id] = client
        try client.start(executable: binaryPath, cwd: project.path)
        let initial = try await initialize(client)
        try checkOperation(id, operationID: operationID)
        if let modelState = (initial["_meta"] as? [String: Any])?["modelState"] as? [String: Any] { applyModels(modelState, id: id) }
        if let commands = (initial["_meta"] as? [String: Any])?["availableCommands"] as? [[String: Any]] {
            runs[id, default: RunState()].commands = SlashCommand.parse(commands)
        }
        try await authenticate(client, initial: initial)
        try checkOperation(id, operationID: operationID)
        var params: [String: Any] = ["cwd": project.path, "mcpServers": []]
        let sessionMeta = features.composer.sessionMeta()
        if !sessionMeta.isEmpty { params["_meta"] = sessionMeta }
        let result: [String: Any]
        if let session = task(id)?.sessionID {
            params["sessionId"] = session
            importBuffers[id] = []
            replaying.insert(id)
            defer { if operationIDs[id] == operationID { replaying.remove(id) } }
            result = try await client.request("session/load", params: params, timeout: 120)
            try checkOperation(id, operationID: operationID)
            if let index = state.conversations.firstIndex(where: { $0.id == id }) {
                // The harness owns persisted history. Keep the visible prompt that has not been sent yet.
                pendingTranscript.removeValue(forKey: id)
                state.conversations[index].messages = (importBuffers[id] ?? []) + (pendingPrompts[id].map { [$0] } ?? [])
                transcriptRevisions[id, default: 0] += 1
            }
        } else {
            result = try await client.request("session/new", params: params, timeout: 120)
            try checkOperation(id, operationID: operationID)
            guard let session = result["sessionId"] as? String else { throw DesktopError.message("The harness did not return a session ID.") }
            if let i = state.conversations.firstIndex(where: { $0.id == id }) { state.conversations[i].sessionID = session }
        }
        try checkOperation(id, operationID: operationID)
        if let mode = (result["_meta"] as? [String: Any])?["x.ai/memoryMode"] as? String {
            features.extensions.memory.recordSessionMode(mode, conversationID: id)
        }
        if let models = result["models"] as? [String: Any] { applyModels(models, id: id) }
        if let modes = result["modes"] as? [String: Any] {
            runs[id, default: RunState()].modes = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap {
                guard let value = $0["id"] as? String else { return nil }; return ModelOption(id: value, name: $0["name"] as? String ?? value)
            }
            runs[id]?.modeID = modes["currentModeId"] as? String ?? ""
        }
        if let options = result["configOptions"] as? [[String: Any]] { applyConfigOptions(options, id: id) }
        if let desired = task(id)?.modelID, desired != runs[id]?.modelID {
            try await updateConfig(client, id: id, key: "model", value: desired)
            try checkOperation(id, operationID: operationID)
        }
        if let desired = task(id)?.reasoningID, desired != runs[id]?.reasoningID,
           runs[id]?.reasoningOptions.contains(where: { $0.id == desired }) == true {
            try await updateConfig(client, id: id, key: "reasoning_effort", value: desired)
            try checkOperation(id, operationID: operationID)
        }
        if let mode = pendingModes.removeValue(forKey: id) {
            _ = try await client.request("session/set_mode", params: ["sessionId": task(id)?.sessionID ?? "", "modeId": mode])
            try checkOperation(id, operationID: operationID)
            runs[id]?.modeID = mode
        }
        do { try await loadCommands(client, id: id, project: project) }
        catch { /* AvailableCommandsUpdate remains authoritative if pull is unsupported. */ }
        loaded.insert(id); persistSessionOptions(id); save(); return client
    }

    func initialize(_ client: ACPClient) async throws -> [String: Any] {
        let result = try await client.request("initialize", params: [
            "protocolVersion": 1,
            "clientInfo": ["name": "grok-desktop", "title": "Grok Desktop", "version": DesktopVersion.current],
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
                                   "_meta": ["x.ai/folderTrust": ["interactive": true]]],
            "_meta": ["clientType": "grok_desktop", "clientIdentifier": "grok-desktop", "clientVersion": DesktopVersion.current, "startupHints": ["nonInteractive": false]]
        ], timeout: 60)
        if let meta = result["_meta"] as? [String: Any] { harnessMeta.initialize = meta }
        if let methods = result["authMethods"] as? [[String: Any]] { harnessMeta.authMethods = methods }
        return result
    }

    func authenticate(_ client: ACPClient, initial: [String: Any]) async throws {
        let methods = initial["authMethods"] as? [[String: Any]] ?? []
        let preferred = (initial["_meta"] as? [String: Any])?["defaultAuthMethodId"] as? String
        let offered = Set(methods.compactMap { $0["id"] as? String })
        // `xai.api_key` is the harness's provider-credential method (OpenRouter, OpenAI Codex).
        let supported = ["xai.api_key"]
        let method = ([preferred].compactMap { $0 } + supported).first { supported.contains($0) && offered.contains($0) }
        guard let method else {
            throw DesktopError.message("No model provider is signed in. Open Settings and sign in to OpenRouter or OpenAI Codex under Accounts, then try again.")
        }
        let result = try await client.request("authenticate", params: ["methodId": method, "_meta": ["headless": true]], timeout: 60)
        if let meta = result["_meta"] as? [String: Any], !meta.isEmpty { harnessMeta.authenticate = meta }
    }

    private func receive(_ method: String, params: [String: Any], id: UUID) {
        let method = method.hasPrefix("_") ? String(method.dropFirst()) : method
        if let session = params["sessionId"] as? String, let expected = task(id)?.sessionID, session != expected { return }
        if receiveFeatureNotification(method, params: params, id: id) { return }
        if method == "x.ai/models/update" {
            runs[id, default: RunState()].models = SessionOptions.models(params)
            return
        }
        guard method == "session/update", let update = params["update"] as? [String: Any] else { return }
        let kind = update["sessionUpdate"] as? String ?? ""
        if kind == "available_commands_update" {
            runs[id, default: RunState()].commands = SlashCommand.parse(update["availableCommands"] as? [[String: Any]] ?? [])
            runs[id]?.commandsLoaded = true
            runs[id]?.availableTools = (update["_meta"] as? [String: Any])?["tools"] as? [String]
            return
        }
        if kind == "config_option_update", let options = update["configOptions"] as? [[String: Any]] {
            applyConfigOptions(options, id: id)
            if loaded.contains(id) { persistSessionOptions(id) }
        }
        if kind == "current_mode_update" { runs[id]?.modeID = update["currentModeId"] as? String ?? "" }
        if kind == "plan" {
            runs[id, default: RunState()].plan = (update["entries"] as? [[String: Any]] ?? []).enumerated().map {
                PlanEntry(id: $0.offset, content: $0.element["content"] as? String ?? "", status: $0.element["status"] as? String ?? "pending")
            }
        }
        guard let i = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        if kind == "session_info_update", let title = update["title"] as? String, !title.isEmpty { state.conversations[i].title = title }
        // Commit authoritative replay only once session/load succeeds; failed loads keep the local copy.
        if replaying.contains(id) {
            TranscriptReducer.apply(update, to: &importBuffers[id, default: []])
            return
        }
        if importing.contains(id) { return }
        // The user message is optimistically inserted when sending.
        if kind == "user_message_chunk", !replaying.contains(id) { return }
        // Chunks can arrive hundreds of times a second. Applying each one would re-render every
        // view that observes the store, so apply them in batches, at most once per frame.
        pendingTranscript[id, default: []].append(update)
        if transcriptFlush == nil {
            transcriptFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard !Task.isCancelled else { return }
                self?.flushTranscript()
            }
        }
    }

    /// Applies buffered streaming updates for one conversation, or for all of them.
    /// Anything that reads or replaces a transcript at a turn boundary flushes first.
    func flushTranscript(_ only: UUID? = nil) {
        var changed = false
        for id in only.map({ [$0] }) ?? Array(pendingTranscript.keys) {
            guard let updates = pendingTranscript.removeValue(forKey: id),
                  let i = state.conversations.firstIndex(where: { $0.id == id }) else { continue }
            var messages = state.conversations[i].messages
            let now = Date()
            for update in updates { TranscriptReducer.apply(update, to: &messages, date: now) }
            state.conversations[i].messages = messages
            transcriptRevisions[id, default: 0] += 1
            changed = true
        }
        if pendingTranscript.isEmpty { transcriptFlush?.cancel(); transcriptFlush = nil }
        if changed { save() }
    }

    /// Changes whenever the conversation's transcript does. Views compare this instead of text.
    func transcriptRevision(of id: UUID?) -> Int { id.flatMap { transcriptRevisions[$0] } ?? 0 }

    var importing: Set<UUID> = []
    private func handleRequest(_ requestID: Any, method: String, params: [String: Any], id: UUID, client: ACPClient) {
        let method = method.hasPrefix("_") ? String(method.dropFirst()) : method
        if method == "session/request_permission" {
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { value -> PermissionOption? in
                guard let optionID = value["optionId"] as? String else { return nil }
                return PermissionOption(id: optionID, name: value["name"] as? String ?? optionID, kind: value["kind"] as? String ?? "")
            }
            let detail: String
            if let input = tool["rawInput"], let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]) {
                detail = String(data: data, encoding: .utf8) ?? ""
            } else { detail = "Grok needs your permission to continue." }
            runs[id, default: RunState()].approvals.append(Approval(requestID: requestID, title: tool["title"] as? String ?? "Permission required", detail: detail, options: options))
        } else if method == "x.ai/folder_trust/request" {
            let kinds = (params["configKinds"] as? [String] ?? []).joined(separator: ", ")
            runs[id, default: RunState()].approvals.append(Approval(requestID: requestID, title: "Trust project configuration?",
                detail: "\(params["cwd"] as? String ?? "This project")\n\nThis folder contains \(kinds.isEmpty ? "local agent configuration" : kinds). Trust it only if you know its contents.",
                options: [PermissionOption(id: "folder:reject", name: "Skip configuration", kind: "reject_once"), PermissionOption(id: "folder:trust", name: "Trust project", kind: "allow_once")]))
        } else if method == "x.ai/exit_plan_mode" {
            runs[id, default: RunState()].approvals.append(Approval(requestID: requestID, title: "Ready to implement this plan?",
                detail: params["planContent"] as? String ?? "Grok has finished planning and is ready to make changes.",
                options: [PermissionOption(id: "plan:cancelled", name: "Keep planning", kind: "reject_once"), PermissionOption(id: "plan:approved", name: "Approve plan", kind: "allow_once")]))
        } else if method == "x.ai/ask_user_question" {
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { value -> AgentQuestion? in
                guard let question = value["question"] as? String else { return nil }
                return AgentQuestion(question: question, options: (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }, multiSelect: value["multiSelect"] as? Bool ?? false)
            }
            runs[id, default: RunState()].questions.append(QuestionRequest(requestID: requestID, questions: questions))
        } else {
            try? client.respondError(id: requestID, code: -32601, message: "Unsupported client method: \(method)")
        }
    }

    func approve(_ approval: Approval, option: PermissionOption) {
        guard let id = state.selectedConversationID, let client = clients[id],
              runs[id]?.approvals.contains(where: { $0.id == approval.id }) == true else { return }
        do {
            if option.id.hasPrefix("folder:") { try client.respond(id: approval.requestID, result: ["outcome": option.id == "folder:trust" ? "trust" : "reject"]) }
            else if option.id.hasPrefix("plan:") { try client.respond(id: approval.requestID, result: ["outcome": String(option.id.dropFirst(5))]) }
            else { try client.respond(id: approval.requestID, result: ["outcome": ["outcome": "selected", "optionId": option.id]]) }
            runs[id]?.approvals.removeAll { $0.id == approval.id }
        } catch { banner = error.localizedDescription }
    }

    func answer(_ request: QuestionRequest, answers: [String: [String]], notes: [String: String] = [:], cancelled: Bool = false) {
        guard let id = state.selectedConversationID, let client = clients[id],
              runs[id]?.questions.contains(where: { $0.id == request.id }) == true else { return }
        do {
            try client.respond(id: request.requestID, result: cancelled ? ["outcome": "cancelled"] : request.response(answers: answers, notes: notes))
            runs[id]?.questions.removeAll { $0.id == request.id }
        } catch { banner = error.localizedDescription }
    }

    func cancel() {
        guard let id = state.selectedConversationID, runs[id]?.isRunning == true else { return }
        guard let client = clients[id], loaded.contains(id), !importing.contains(id), let session = task(id)?.sessionID else {
            stopOperation(id, phase: "Stopped")
            return
        }
        cancellationRequested.insert(id)
        do {
            try client.notify("session/cancel", params: ["sessionId": session])
            for approval in runs[id]?.approvals ?? [] {
                let folder = approval.options.contains { $0.id.hasPrefix("folder:") }
                let plan = approval.options.contains { $0.id.hasPrefix("plan:") }
                try? client.respond(id: approval.requestID, result: folder ? ["outcome": "reject"] : plan ? ["outcome": "cancelled"] : ["outcome": ["outcome": "cancelled"]])
            }
            for question in runs[id]?.questions ?? [] { try? client.respond(id: question.requestID, result: ["outcome": "cancelled"]) }
            runs[id]?.approvals = []; runs[id]?.questions = []; runs[id]?.phase = "Stopping"
            // Give ACP cancellation a chance to persist the turn, then recover from an unresponsive harness.
            let operationID = operationIDs[id]
            cancellationFallbacks[id]?.cancel()
            cancellationFallbacks[id] = Task { [weak self, weak client] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, let client, self.operationIDs[id] == operationID,
                      self.clients[id] === client, self.runs[id]?.isRunning == true else { return }
                self.stopOperation(id, phase: "Stopped")
            }
        } catch { stopOperation(id, phase: "Stopped") }
    }

    func beginOperation(_ id: UUID, phase: String) -> UUID {
        flushTranscript(id)
        let operationID = UUID()
        operationIDs[id] = operationID
        cancellationFallbacks.removeValue(forKey: id)?.cancel()
        cancellationRequested.remove(id)
        runs[id, default: RunState()].isRunning = true
        runs[id]?.phase = phase
        runs[id]?.approvals = []; runs[id]?.questions = []
        return operationID
    }

    func checkOperation(_ id: UUID, operationID: UUID) throws {
        try Task.checkCancellation()
        guard operationIDs[id] == operationID else { throw CancellationError() }
    }

    func finishOperation(_ id: UUID, operationID: UUID) {
        guard operationIDs[id] == operationID else { return }
        flushTranscript(id)
        operationIDs.removeValue(forKey: id)
        operations.removeValue(forKey: id)
        cancellationFallbacks.removeValue(forKey: id)?.cancel()
        cancellationRequested.remove(id)
        runs[id]?.isRunning = false; runs[id]?.isConfiguring = false
        runs[id]?.approvals = []; runs[id]?.questions = []
        replaying.remove(id); importing.remove(id); importBuffers.removeValue(forKey: id); pendingPrompts.removeValue(forKey: id)
        features.composer.operationDidEnd(conversationID: id)
    }

    func discardConnection(_ id: UUID) {
        clients.removeValue(forKey: id)?.stop()
        loaded.remove(id)
        runs[id]?.approvals = []; runs[id]?.questions = []
    }

    func stopOperation(_ id: UUID, phase: String) {
        // Invalidate first: continuations from the old client must not clean up a new run.
        flushTranscript(id)
        operationIDs.removeValue(forKey: id)
        operations.removeValue(forKey: id)?.cancel()
        cancellationFallbacks.removeValue(forKey: id)?.cancel()
        cancellationRequested.remove(id)
        discardConnection(id)
        replaying.remove(id); importing.remove(id); importBuffers.removeValue(forKey: id); pendingPrompts.removeValue(forKey: id)
        runs[id]?.isRunning = false; runs[id]?.isConfiguring = false; runs[id]?.phase = phase
        features.composer.operationDidEnd(conversationID: id)
    }

    func setModel(_ model: ModelOption) {
        guard !run.isRunning, !run.isConfiguring else { return }
        guard run.models.contains(where: { $0.id == model.id }) else {
            banner = "That model is no longer available. Reload the model choices and try again."; return
        }
        if state.selectedConversationID == nil {
            catalogRun.modelID = model.id
            state.selectedModelID = model.id
            updateCatalogReasoning(preferred: state.selectedReasoningID)
            state.selectedReasoningID = catalogRun.reasoningID.isEmpty ? nil : catalogRun.reasoningID
            save()
        } else {
            setSessionOption(key: "model", value: model.id)
        }
    }

    func setReasoning(_ option: ModelOption) {
        guard !run.isRunning, !run.isConfiguring else { return }
        guard run.reasoningOptions.contains(where: { $0.id == option.id }) else {
            banner = "That thinking level is not supported by this model."; return
        }
        if state.selectedConversationID == nil {
            catalogRun.reasoningID = option.id
            state.selectedReasoningID = option.id
            save()
        } else {
            setSessionOption(key: "reasoning_effort", value: option.id)
        }
    }

    func setMode(_ mode: ModelOption) {
        if state.selectedConversationID == nil { _ = ensureConversation(title: "New task") }
        setSessionOption(key: "mode", value: mode.id)
    }

    private func updateCatalogReasoning(preferred: String?) {
        let model = catalogRun.models.first { $0.id == catalogRun.modelID }
        catalogRun.reasoningOptions = model?.reasoningOptions ?? []
        catalogRun.reasoningID = preferred.flatMap { candidate in
            catalogRun.reasoningOptions.first { $0.id == candidate }?.id
        } ?? model?.defaultReasoningID ?? ""
    }

    func setSessionOption(key: String, value: String) {
        guard let id = state.selectedConversationID, let project, !run.isRunning, !run.isConfiguring else { return }
        let operationID = beginOperation(id, phase: "Updating settings")
        runs[id]?.isConfiguring = true
        banner = nil
        operations[id] = Task {
            defer { finishOperation(id, operationID: operationID) }
            do {
                let client = try await connect(id: id, project: project, operationID: operationID)
                try checkOperation(id, operationID: operationID)
                if key == "mode" {
                    guard let session = task(id)?.sessionID else { throw DesktopError.message("The task has no session.") }
                    _ = try await client.request("session/set_mode", params: ["sessionId": session, "modeId": value])
                    try checkOperation(id, operationID: operationID)
                    runs[id]?.modeID = value
                } else {
                    try await updateConfig(client, id: id, key: key, value: value)
                    try checkOperation(id, operationID: operationID)
                    persistSessionOptions(id)
                    state.selectedModelID = runs[id]?.modelID
                    state.selectedReasoningID = runs[id]?.reasoningID.isEmpty == false ? runs[id]?.reasoningID : nil
                    catalogProjectID = project.id
                    catalogRun.models = runs[id]?.models ?? []
                    catalogRun.modelID = runs[id]?.modelID ?? ""
                    updateCatalogReasoning(preferred: state.selectedReasoningID)
                }
                runs[id]?.phase = "Ready"; save()
            } catch {
                guard operationIDs[id] == operationID else { return }
                runs[id]?.phase = "Needs attention"
                if !(error is CancellationError) { banner = "Could not change task settings: \(error.localizedDescription)" }
                // A timeout may have applied remotely. Reconnect before the next prompt to reconcile.
                discardConnection(id)
            }
        }
    }

    func updateConfig(_ client: ACPClient, id: UUID, key: String, value: String) async throws {
        guard let session = task(id)?.sessionID else { throw DesktopError.message("The task has no session.") }
        let result = try await client.request("session/set_config_option", params: [
            "sessionId": session, "configId": key, "value": value
        ])
        guard task(id) != nil, clients[id] === client else { throw CancellationError() }
        guard let options = result["configOptions"] as? [[String: Any]] else {
            throw DesktopError.message("The runtime did not confirm the updated task settings.")
        }
        applyConfigOptions(options, id: id)
        let confirmed = key == "model" ? runs[id]?.modelID : runs[id]?.reasoningID
        guard confirmed == value else { throw DesktopError.message("The runtime did not apply the selected setting. Try another option.") }
    }

    func persistSessionOptions(_ id: UUID) {
        guard let index = state.conversations.firstIndex(where: { $0.id == id }), let run = runs[id] else { return }
        state.conversations[index].modelID = run.modelID.isEmpty ? nil : run.modelID
        state.conversations[index].reasoningID = run.reasoningID.isEmpty ? nil : run.reasoningID
        save()
    }

    func applyModels(_ models: [String: Any], id: UUID) {
        runs[id, default: RunState()].models = SessionOptions.models(models)
        runs[id]?.modelID = models["currentModelId"] as? String ?? ""
        let selected = runs[id]?.models.first { $0.id == runs[id]?.modelID }
        runs[id]?.reasoningOptions = selected?.reasoningOptions ?? []
        runs[id]?.reasoningID = selected?.defaultReasoningID ?? ""
    }

    func applyConfigOptions(_ options: [[String: Any]], id: UUID) {
        if let model = options.first(where: { $0["id"] as? String == "model" }) {
            let catalog = runs[id]?.models ?? []
            runs[id, default: RunState()].models = SessionOptions.choices(model).map { option in
                catalog.first(where: { $0.id == option.id }) ?? option
            }
            runs[id]?.modelID = model["currentValue"] as? String ?? ""
        }
        let effort = options.first { $0["id"] as? String == "reasoning_effort" }
        runs[id, default: RunState()].reasoningOptions = effort.map(SessionOptions.choices) ?? []
        runs[id]?.reasoningID = effort?["currentValue"] as? String ?? ""
    }

    /// Imports saved harness sessions for the given projects (the selected one by default).
    func syncHistory(projects requested: [Project]? = nil) {
        let targets = requested ?? project.map { [$0] } ?? []
        guard !targets.isEmpty, !syncing else { return }
        syncing = true
        Task {
            defer { syncing = false }
            var failures: [String] = []
            for project in targets where state.projects.contains(where: { $0.id == project.id }) {
                let client = ACPClient()
                historyClient = client
                defer { client.stop(); if historyClient === client { historyClient = nil } }
                do {
                    try client.start(executable: binaryPath, cwd: project.path)
                    let initial = try await initialize(client)
                    try await authenticate(client, initial: initial)
                    var cursor: String?
                    repeat {
                        var params: [String: Any] = ["cwd": project.path]
                        if let cursor { params["cursor"] = cursor }
                        let response = try await client.request("session/list", params: params)
                        for session in response["sessions"] as? [[String: Any]] ?? [] {
                            guard let sessionID = session["sessionId"] as? String,
                                  !state.deletedSessionIDs.contains(sessionID),
                                  !state.conversations.contains(where: { $0.sessionID == sessionID }) else { continue }
                            let date = (session["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                            state.conversations.append(Conversation(projectID: project.id, title: session["title"] as? String ?? "Grok task", sessionID: sessionID, updatedAt: date))
                        }
                        cursor = response["nextCursor"] as? String
                    } while cursor != nil
                } catch {
                    failures.append(targets.count > 1 ? "\(project.name): \(error.localizedDescription)" : error.localizedDescription)
                }
            }
            save()
            if !failures.isEmpty { banner = "Could not import harness tasks: " + failures.joined(separator: "; ") }
        }
    }

    func loadImportedConversation() async {
        guard let task = conversation, !loaded.contains(task.id), let project, runs[task.id]?.isRunning != true else { return }
        banner = nil
        let operationID = beginOperation(task.id, phase: "Loading history")
        importing.insert(task.id)
        importBuffers[task.id] = []
        defer { finishOperation(task.id, operationID: operationID) }
        do {
            _ = try await connect(id: task.id, project: project, operationID: operationID)
            try checkOperation(task.id, operationID: operationID)
            runs[task.id]?.phase = "Ready"; save()
        } catch {
            guard operationIDs[task.id] == operationID else { return }
            runs[task.id]?.phase = error is CancellationError ? "Stopped" : "Needs attention"
            if !(error is CancellationError) { banner = error.localizedDescription }
            discardConnection(task.id)
        }
    }

    func refreshWorkspace() async {
        guard let project else { return }
        let snapshot = await git.inspect(path: project.path)
        guard self.project?.id == project.id else { return }
        // This runs every few seconds; publishing an unchanged snapshot would re-render the window.
        if workspace != snapshot { workspace = snapshot }
        if let file = selectedFile { await selectFile(file, showsProgress: false) }
    }
    func selectFile(_ file: String, showsProgress: Bool = true) async {
        guard let project else { return }
        if selectedFile != file { selectedFile = file }
        if showsProgress { diffText = "Loading changes…" }
        let result = await git.diff(path: project.path, file: file)
        guard selectedFile == file, self.project?.id == project.id else { return }
        if diffText != result { diffText = result }
    }
    func revealProject() { if let project { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } }

    /// Opens the side panel on a tab.
    func showSidePanel(_ tab: SidePanelTab) {
        sidePanelTab = tab
        if !showInspector { withAnimation(.easeInOut(duration: 0.18)) { showInspector = true } }
        if minimalMode { minimalMode = false }
    }

    func toggleSidePanel() {
        withAnimation(.easeInOut(duration: 0.18)) { showInspector.toggle() }
    }

    /// The side panel's terminal, in the selected project or the given one.
    func openTerminal(projectID: UUID? = nil) {
        if let projectID, projectID != state.selectedProjectID { selectProject(projectID) }
        guard project != nil else { banner = "Open a project to use the terminal."; return }
        showSidePanel(.terminal)
        features.terminals.requestFocus()
    }
    func login(provider: String) {
        guard !loginRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { loginLog = "The bundled Grok runtime is missing. Reinstall Grok Desktop."; return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = URL(fileURLWithPath: project?.path ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        process.arguments = ["login", provider]
        let output = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        loginLog = "Opening browser sign-in…"; loginRunning = true; loginProcess = process
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.loginLog = String(((self?.loginLog ?? "") + "\n" + text).suffix(12_000)) }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.loginRunning = false; self?.loginProcess = nil
                self?.loginLog += process.terminationStatus == 0 ? "\nSigned in. You can start a task." : "\nSign-in exited (\(process.terminationStatus))."
                if process.terminationStatus == 0 { self?.refreshModelsAfterLogin() }
            }
        }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; loginRunning = false; loginLog = error.localizedDescription }
    }
    private func refreshModelsAfterLogin() {
        catalogProjectID = nil
        commandCatalogProjectID = nil
        catalogClient?.stop(); catalogClient = nil
        catalogRun.isConfiguring = false; catalogLoadingProjectID = nil
        for id in Array(clients.keys) where runs[id]?.isRunning != true { discardConnection(id) }
        Task { await prepareSessionOptions() }
    }
    func cancelLogin() { loginProcess?.terminate() }
    func shutdown() {
        flushTranscript(); flush()
        featureNotificationRefresh?.cancel()
        for client in auxiliaryClients.values { client.stop() }
        auxiliaryClients.removeAll()
        for id in Set(clients.keys).union(operationIDs.keys) { stopOperation(id, phase: "Stopped") }
        historyClient?.stop(); historyClient = nil
        catalogClient?.stop(); catalogClient = nil
        loginProcess?.terminate()
        features.terminals.terminateAll()
    }
    func task(_ id: UUID) -> Conversation? { state.conversations.first { $0.id == id } }
    func append(_ message: Message, to id: UUID) {
        flushTranscript(id)
        guard let i = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[i].messages.append(message); state.conversations[i].updatedAt = Date(); save()
        transcriptRevisions[id, default: 0] += 1
    }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
