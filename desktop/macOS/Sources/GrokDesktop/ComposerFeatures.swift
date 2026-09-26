import AppKit
import SwiftUI

/// The prompt queue, voice input, permission modes, compaction, model and effort arguments, and prompt editing.
@MainActor
final class ComposerFeatureModel: ObservableObject {
    weak var store: AppStore?

    // MARK: State

    /// Prompts held until each task's running turn ends.
    @Published private(set) var queue = ComposerQueueBook()
    /// The harness's own queue per task, from `x.ai/queue/changed`.
    @Published private(set) var harnessQueues: [UUID: HarnessPromptQueue] = [:]
    @Published var queuePanelExpanded = true
    /// Bumped by `/queue` so the panel opens and draws attention to itself.
    @Published private(set) var queueFocusRequest = 0
    @Published private(set) var compactions: [UUID: ComposerCompactionStatus] = [:]

    @Published private(set) var permissionMode: ComposerPermissionMode = .ask
    /// Whether Auto is offered (`GROK_AUTO_PERMISSION_MODE`, `[auto_mode].enabled`, then the remote gate).
    @Published private(set) var autoModeAvailable = true
    @Published private(set) var followUpBehavior: ComposerFollowUpBehavior = .queue
    @Published private(set) var voiceShortcutEnabled = true
    @Published private(set) var voiceLanguage = "en"
    @Published private(set) var voiceModel = VoiceSTTSettings.defaultModel

    let voice = VoiceDictationController()
    /// The composer's text view, so dictation lands at the cursor.
    weak var promptTextView: NSTextView?

    /// `config.toml`. Under XCTest it stays nil unless a test supplies a file, so the suite never
    /// reads or writes the user's configuration.
    var configURL: URL? = ComposerFeatureModel.isRunningTests ? nil : GrokPaths.configFile
    static let voiceShortcut = "⇧⌘D"

    private var permissionModeExplicit = false
    private var configuredAutoGate: Bool?
    private var remoteAutoGate: Bool?
    private var remotePermissionMode: ComposerPermissionMode?
    private var permissionRequestID: UUID?
    private var modelRequestID: UUID?
    private var voiceStartID: UUID?
    private var sendNowRequested: Set<UUID> = []
    private var heldEntries: Set<UUID> = []
    private var operationWatchers: [UUID: Task<Void, Never>] = [:]
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil
    nonisolated private static let configQueue = DispatchQueue(label: "ai.grok.desktop.composer-config", qos: .userInitiated)

    init(store: AppStore) {
        self.store = store
        voice.insertFinal = { [weak self] text in self?.insertDictation(text) }
        voice.report = { [weak self] message in self?.store?.banner = message }
        reloadPreferences()
    }

    // MARK: Store hooks

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool {
        switch method {
        case "x.ai/queue/changed":
            let snapshot = HarnessPromptQueue(params)
            if snapshot.entries.isEmpty { harnessQueues.removeValue(forKey: conversationID) }
            else if harnessQueues[conversationID] != snapshot { harnessQueues[conversationID] = snapshot }
            return true
        case "x.ai/settings/update":
            applyRemoteSettings(params)
            return false
        default:
            return false
        }
    }

    /// Remote settings also arrive on connections that belong to no task.
    func handleGlobal(method: String, params: [String: Any]) -> Bool {
        if method == "x.ai/settings/update" { applyRemoteSettings(params) }
        return false
    }

    /// Called by `AppStore.send` while a turn is running. Return true when the prompt was queued.
    /// Prompts with attachments always queue: steering carries text only.
    func enqueue(_ prompt: String, attachments: [PromptAttachment] = [], conversationID: UUID) -> Bool {
        // A settings change is not a turn: Send stays blocked until the new settings are confirmed.
        guard let store, store.task(conversationID) != nil, store.runs[conversationID]?.isConfiguring != true else { return false }
        if followUpBehavior == .steer, attachments.isEmpty, SlashCommand.split(prompt) == nil, steer(prompt, conversationID: conversationID) { return true }
        queue.append(prompt, attachments: attachments, to: conversationID)
        queuePanelExpanded = true
        watch(conversationID)
        return true
    }

    /// Called whenever an operation on a task ends: a prompt turn, loading history, a settings
    /// change, or a stop. A queue waiting behind it continues if the task is ready; after a
    /// failure or a stop it pauses so the user decides (the panel offers Send next).
    func operationDidEnd(conversationID: UUID) {
        guard let store, !queue.items(conversationID).isEmpty else { return }
        if store.runs[conversationID]?.phase != "Ready", !sendNowRequested.contains(conversationID) { queue.pause(conversationID) }
        scheduleDrain(conversationID)
    }

    /// Called when a prompt turn ends, so a queued prompt can be sent next.
    func turnDidFinish(conversationID: UUID, stopped: Bool) {
        if stopped && !sendNowRequested.contains(conversationID) { queue.pause(conversationID) } else { queue.resume(conversationID) }
        scheduleDrain(conversationID)
    }

    /// Extra `_meta` for `session/new` and `session/load`: the permission mode, once the user has one.
    func sessionMeta() -> [String: Any] {
        guard permissionModeExplicit else { return [:] }
        return ["yoloMode": permissionMode == .alwaysApprove, "autoMode": permissionMode == .auto && autoModeAvailable]
    }

    // MARK: /queue

    /// `/queue`.
    func showQueue() {
        guard let store else { return }
        let id = store.state.selectedConversationID
        let harnessEntries = id.flatMap { harnessQueues[$0]?.entries } ?? []
        guard !queue.items(id).isEmpty || !harnessEntries.isEmpty else {
            store.banner = "Queue is empty."
            return
        }
        queuePanelExpanded = true
        queueFocusRequest += 1
    }

    func removeQueued(_ entryID: UUID, from conversationID: UUID) {
        heldEntries.remove(entryID)
        queue.remove(entryID, from: conversationID)
    }

    func updateQueued(_ entryID: UUID, text: String, in conversationID: UUID) {
        queue.update(entryID, text: text, in: conversationID)
        releaseQueued(entryID, in: conversationID)
    }

    func moveQueued(_ entryID: UUID, by offset: Int, in conversationID: UUID) { queue.move(entryID, by: offset, in: conversationID) }

    func clearQueue(_ conversationID: UUID) {
        for entry in queue.items(conversationID) { heldEntries.remove(entry.id) }
        queue.clear(conversationID)
        sendNowRequested.remove(conversationID)
    }

    /// Keeps an entry from being sent while it is edited in place.
    func holdQueued(_ entryID: UUID) { heldEntries.insert(entryID) }

    func releaseQueued(_ entryID: UUID, in conversationID: UUID) {
        guard heldEntries.remove(entryID) != nil else { return }
        scheduleDrain(conversationID)
    }

    /// Stops the running turn and sends this entry next.
    func sendQueuedNow(_ entryID: UUID, in conversationID: UUID) {
        guard let store else { return }
        queue.moveToFront(entryID, in: conversationID)
        heldEntries.remove(entryID)
        sendNowRequested.insert(conversationID)
        if store.runs[conversationID]?.isRunning == true, store.state.selectedConversationID == conversationID {
            watch(conversationID)
            store.cancel()
        } else {
            drain(conversationID)
        }
    }

    /// Sends the next entry of a queue that paused after a Stop.
    func resumeQueue(_ conversationID: UUID) {
        sendNowRequested.insert(conversationID)
        drain(conversationID)
    }

    /// `_x.ai/queue/remove` for an entry the harness holds (version-checked, so a stale remove is a no-op).
    func removeHarnessQueued(_ entry: HarnessPromptQueue.Entry, conversationID: UUID) {
        guard let store, let client = store.clients[conversationID], let session = store.task(conversationID)?.sessionID else {
            store?.banner = "This task is not connected to Grok."
            return
        }
        do { try client.notify("_x.ai/queue/remove", params: ["sessionId": session, "id": entry.id, "expectedVersion": entry.version]) }
        catch { store.banner = "Could not remove the queued prompt: \(error.localizedDescription)" }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store?.banner = "Copied to clipboard"
    }

    private func scheduleDrain(_ conversationID: UUID) {
        Task { @MainActor [weak self] in self?.drain(conversationID) }
    }

    /// Sends the next queued prompt when the task is idle and allowed to continue.
    private func drain(_ conversationID: UUID) {
        guard let store else { return }
        guard let task = store.task(conversationID) else { clearQueue(conversationID); return }
        // An archived task keeps its queue until it is restored.
        guard !task.isArchived else { return }
        guard let next = queue.items(conversationID).first else { sendNowRequested.remove(conversationID); return }
        let run = store.runs[conversationID]
        if run?.isRunning == true { watch(conversationID); return }
        guard ComposerQueueBook.mayDispatch(isRunning: false, phase: run?.phase ?? "Ready", paused: queue.isPaused(conversationID),
                                             sendNow: sendNowRequested.contains(conversationID)),
              !heldEntries.contains(next.id) else { return }
        sendNowRequested.remove(conversationID)
        queue.resume(conversationID)
        _ = queue.popNext(for: conversationID)
        if let instructions = next.compactInstructions { runCompaction(conversationID, instructions: instructions) }
        else { sendQueuedPrompt(next.text, attachments: next.attachments, to: conversationID) }
    }

    /// Operations other than prompt turns (loading history, changing settings, compacting) end
    /// without `turnDidFinish`, so a queue behind one waits for the operation itself.
    private func watch(_ conversationID: UUID) {
        guard operationWatchers[conversationID] == nil, let operation = store?.operations[conversationID] else { return }
        operationWatchers[conversationID] = Task { @MainActor [weak self] in
            await operation.value
            self?.operationWatchers[conversationID] = nil
            self?.drain(conversationID)
        }
    }

    /// Sends a queued prompt to its task, which need not be the selected one. This mirrors the
    /// prompt path of `AppStore.send` without touching the composer draft.
    private func sendQueuedPrompt(_ prompt: String, attachments: [PromptAttachment] = [], to id: UUID) {
        guard let store, let task = store.task(id), let project = store.state.projects.first(where: { $0.id == task.projectID }) else { return }
        guard FileManager.default.isExecutableFile(atPath: store.binaryPath) else {
            store.banner = "The bundled Grok runtime is missing. Reinstall Grok Desktop to start a task."; return
        }
        let message = Message(kind: .user, text: prompt, createdAt: Date(), attachments: attachments.isEmpty ? nil : attachments.map(\.messageAttachment))
        store.append(message, to: id)
        store.pendingPrompts[id] = message
        let operationID = store.beginOperation(id, phase: "Connecting")
        store.operations[id] = Task { [weak self, weak store] in
            guard let store else { return }
            defer { store.finishOperation(id, operationID: operationID) }
            do {
                let client = try await store.connect(id: id, project: project, operationID: operationID)
                try store.checkOperation(id, operationID: operationID)
                guard let session = store.task(id)?.sessionID else { throw DesktopError.message("The harness did not return a session ID.") }
                if let command = SlashCommand.split(prompt),
                   store.runs[id]?.commands.contains(where: { $0.name == command.name || $0.aliases.contains(command.name) }) != true {
                    throw DesktopError.message("Command /\(command.name) is not available in this session.")
                }
                store.pendingPrompts.removeValue(forKey: id)
                store.runs[id]?.phase = "Working"
                let result = try await client.request("session/prompt", params: ["sessionId": session, "prompt": PromptBlocks.make(text: prompt, attachments: attachments)], timeout: nil)
                try store.checkOperation(id, operationID: operationID)
                store.flushTranscript(id)
                let stopped = store.cancellationRequested.contains(id) || result["stopReason"] as? String == "cancelled"
                store.runs[id]?.phase = stopped ? "Stopped" : "Ready"
                store.runs[id]?.isRunning = false
                if let index = store.state.conversations.firstIndex(where: { $0.id == id }) { store.state.conversations[index].updatedAt = Date() }
                if store.state.selectedConversationID != id { store.unreadConversationIDs.insert(id) }
                store.save()
                self?.turnDidFinish(conversationID: id, stopped: stopped)
                await store.refreshWorkspace()
            } catch {
                guard store.operationIDs[id] == operationID else { return }
                let stopped = error is CancellationError || store.cancellationRequested.contains(id)
                store.runs[id]?.phase = stopped ? "Stopped" : "Needs attention"
                if !stopped { store.append(Message(kind: .system, text: error.localizedDescription, createdAt: Date()), to: id) }
                store.discardConnection(id)
            }
        }
    }

    /// `[ui].follow_up_behavior = "steer"`: adds the message to the running turn (`_x.ai/interject`).
    private func steer(_ prompt: String, conversationID id: UUID) -> Bool {
        guard let store, let client = store.clients[id], store.loaded.contains(id), store.runs[id]?.phase == "Working",
              let session = store.task(id)?.sessionID else { return false }
        let sent = Date()
        Task { [weak self, weak store] in
            do {
                _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/interject", params: ["sessionId": session, "text": prompt]))
                store?.append(Message(kind: .user, text: prompt, createdAt: sent), to: id)
            } catch {
                // The turn may have ended; the message is not lost, it runs next.
                guard let self, store?.task(id) != nil else { return }
                self.queue.append(prompt, to: id)
                self.scheduleDrain(id)
            }
        }
        return true
    }

    // MARK: /compact

    /// `/compact [instructions]`: compacts now, or after the running turn.
    func compact(_ instructions: String) {
        guard let store else { return }
        guard let id = store.state.selectedConversationID, store.task(id) != nil else { store.banner = "No active session"; return }
        if store.runs[id]?.isRunning == true {
            queue.append("/compact" + (instructions.isEmpty ? "" : " " + instructions), to: id)
            queuePanelExpanded = true
            watch(id)
            return
        }
        runCompaction(id, instructions: instructions)
    }

    /// Shows a fixed compaction status, for rendering snapshots.
    func showCompactionPreview(_ status: ComposerCompactionStatus, for conversationID: UUID) { compactions[conversationID] = status }

    func dismissCompaction(_ conversationID: UUID) {
        guard compactions[conversationID]?.isRunning == false else { return }
        compactions.removeValue(forKey: conversationID)
    }

    /// `_x.ai/compact_conversation {sessionId, userContext?}`, which answers `{}`.
    private func runCompaction(_ id: UUID, instructions: String) {
        guard let store, let task = store.task(id), let project = store.state.projects.first(where: { $0.id == task.projectID }) else { return }
        guard FileManager.default.isExecutableFile(atPath: store.binaryPath) else {
            store.banner = "The bundled Grok runtime is missing. Reinstall Grok Desktop to start a task."; return
        }
        let started = Date()
        compactions[id] = .running(started: started)
        let operationID = store.beginOperation(id, phase: "Compacting")
        store.operations[id] = Task { [weak self, weak store] in
            guard let store else { return }
            defer { store.finishOperation(id, operationID: operationID) }
            var outcome: ComposerCompactionStatus
            do {
                let client = try await store.connect(id: id, project: project, operationID: operationID)
                try store.checkOperation(id, operationID: operationID)
                guard let session = store.task(id)?.sessionID else { throw DesktopError.message("The harness did not return a session ID.") }
                var params: [String: Any] = ["sessionId": session]
                if !instructions.isEmpty { params["userContext"] = instructions }
                let response = try await client.request("_x.ai/compact_conversation", params: params, timeout: nil)
                try store.checkOperation(id, operationID: operationID)
                if response["error"] != nil { _ = try ExtensionResponse.unwrap(response) }
                outcome = .completed(Date().timeIntervalSince(started))
                store.runs[id]?.phase = "Ready"
            } catch {
                let cancelled = error is CancellationError || store.cancellationRequested.contains(id)
                outcome = cancelled ? .cancelled : .failed(error.localizedDescription)
                if store.operationIDs[id] == operationID {
                    store.runs[id]?.phase = cancelled ? "Stopped" : "Ready"
                    // A refusal from the harness leaves the connection usable; anything else reconnects next time.
                    if !cancelled, !Self.isHarnessRefusal(error) { store.discardConnection(id) }
                }
            }
            guard let self, self.compactions[id] == .running(started: started) else { return }
            self.compactions[id] = outcome
            self.turnDidFinish(conversationID: id, stopped: outcome == .cancelled)
            // Outcomes fade after a while; a failure stays until dismissed.
            if case .failed = outcome {} else { self.clearCompaction(id, after: 15, matching: outcome) }
        }
    }

    private static func isHarnessRefusal(_ error: Error) -> Bool {
        if error is DesktopError { return true }
        if let error = error as? ACPClientError, case .remote = error { return true }
        return false
    }

    private func clearCompaction(_ id: UUID, after seconds: Double, matching status: ComposerCompactionStatus) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.compactions[id] == status { self?.compactions.removeValue(forKey: id) }
        }
    }

    // MARK: /model and /effort

    /// `/effort <level>`.
    func setEffort(_ arguments: String) {
        guard let store else { return }
        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = store.run
        guard !run.modelID.isEmpty else { store.banner = "No active model"; return }
        if token.isEmpty {
            if run.reasoningOptions.isEmpty { store.banner = ComposerModelArguments.effortUsage(options: run.reasoningOptions, current: run.reasoningID) }
            else { store.featurePanel = .reasoning }
            return
        }
        switch ComposerModelArguments.resolveEffort(token, options: run.reasoningOptions) {
        case .failure(let message): store.banner = message.text
        case .success(let effort): switchModel(ComposerModelArguments.Choice(modelID: run.modelID, effortID: effort))
        }
    }

    /// `/model <name> [effort]`, alias `/m`.
    func setModel(_ arguments: String) {
        guard let store else { return }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.featurePanel = .models
            if store.run.models.isEmpty { Task { await store.prepareSessionOptions() } }
            return
        }
        guard !store.run.models.isEmpty else {
            store.banner = "Models are still loading. Try again in a moment."
            Task { await store.prepareSessionOptions() }
            return
        }
        switch ComposerModelArguments.resolveModel(trimmed, models: store.run.models) {
        case .failure(let message): store.banner = message.text
        case .success(let choice): switchModel(choice)
        }
    }

    /// Switches the model, then the effort, each through the store's settings path, and saves
    /// them as the defaults for new sessions the way the terminal does.
    private func switchModel(_ choice: ComposerModelArguments.Choice) {
        guard let store else { return }
        guard !store.run.isRunning, !store.run.isConfiguring else {
            store.banner = "Wait for the current turn to finish or stop it before switching models."; return
        }
        let conversationID = store.state.selectedConversationID
        let before = (model: store.run.modelID, effort: store.run.reasoningID)
        let requestID = UUID()
        modelRequestID = requestID
        Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }
            @MainActor func current() -> Bool { self.modelRequestID == requestID && store.state.selectedConversationID == conversationID }
            if choice.modelID != store.run.modelID {
                guard let option = store.run.models.first(where: { $0.id == choice.modelID }) else { return }
                store.setModel(option)
                if let id = conversationID { await store.operations[id]?.value }
                guard current(), store.run.modelID == choice.modelID else { return }
            }
            if let requested = choice.effortID {
                // The session's menu can differ from the catalog's, so resolve against it again.
                let options = store.run.reasoningOptions
                switch ComposerModelArguments.resolveEffort(requested, options: options) {
                case .failure(let message):
                    store.banner = message.text; return
                case .success(let effortID):
                    if effortID != store.run.reasoningID, let option = options.first(where: { $0.id == effortID }) {
                        store.setReasoning(option)
                        if let id = conversationID { await store.operations[id]?.value }
                        guard current(), store.run.reasoningID == option.id else { return }
                    }
                }
            }
            let run = store.run
            let name = run.models.first { $0.id == run.modelID }?.name ?? run.modelID
            let effort = run.reasoningID.isEmpty ? nil : ComposerModelArguments.effortWord(run.reasoningID, options: run.reasoningOptions)
            let description = effort.map { "\(name) (\($0) effort)" } ?? name
            guard run.modelID != before.model || run.reasoningID != before.effort else {
                store.banner = "Already using \(description)."; return
            }
            store.banner = "Switched to \(description)"
            self.persistModelDefault(modelID: run.modelID, effort: effort.flatMap(ComposerModelArguments.standardLevel), confirmation: "Switched to \(description)")
        }
    }

    private func persistModelDefault(modelID: String, effort: String?, confirmation: String) {
        guard let url = configURL, !modelID.isEmpty, modelID.utf8.count <= 256 else { return }
        Task { @MainActor [weak self] in
            do {
                try await Self.writeConfig(url) { config in
                    try config.set("default", to: .string(modelID), in: "models")
                    if let effort { try config.set("default_reasoning_effort", to: .string(effort), in: "models") }
                }
            } catch {
                if self?.store?.banner == confirmation { self?.store?.banner = "\(confirmation). Couldn't save it as the default: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Permission mode

    /// `/auto`: Auto ↔ Ask. Always-approve counts as not auto, so `/auto` switches into Auto.
    func toggleAutoMode() {
        guard permissionMode == .auto || autoModeAvailable else {
            store?.banner = "Auto permission mode is not available for this account."; return
        }
        setPermissionMode(permissionMode == .auto ? .ask : .auto)
    }

    /// `/always-approve [on|off]`, alias `/yolo`.
    func setAlwaysApprove(_ arguments: String) {
        if ComposerPermissionMode.alwaysApproveTarget(arguments, current: permissionMode) { setPermissionMode(.alwaysApprove) }
        else { setPermissionMode(.ask, confirmation: "✓ Always-approve: off") }
    }

    /// Applies a permission mode: saves `[ui].permission_mode`, then tells every running harness
    /// (`_x.ai/yolo_mode_changed`). A failed save restores the previous mode, as the terminal does.
    func setPermissionMode(_ requested: ComposerPermissionMode, confirmation: String? = nil) {
        guard let store else { return }
        let mode = requested == .auto && !autoModeAvailable ? .ask : requested
        let previous = (mode: permissionMode, explicit: permissionModeExplicit)
        permissionMode = mode
        permissionModeExplicit = true
        if mode == .alwaysApprove { approvePendingPermissionRequests() }
        let message = confirmation ?? mode.confirmation(planMode: store.run.modeID == "plan")
        let requestID = UUID()
        permissionRequestID = requestID
        let url = configURL
        Task { @MainActor [weak self] in
            do {
                if let url { try await Self.writeConfig(url) { try $0.set("permission_mode", to: .string(mode.rawValue), in: "ui") } }
                guard let self, self.permissionRequestID == requestID else { return }
                self.broadcastPermissionMode(mode)
                self.store?.banner = message
            } catch {
                guard let self, self.permissionRequestID == requestID else { return }
                self.permissionMode = previous.mode
                self.permissionModeExplicit = previous.explicit
                self.store?.banner = "Couldn't save the permission mode: \(error.localizedDescription)"
            }
        }
    }

    private func broadcastPermissionMode(_ mode: ComposerPermissionMode) {
        guard let store else { return }
        for (id, client) in store.clients where store.loaded.contains(id) {
            try? client.notify("_x.ai/yolo_mode_changed", params: mode.notificationParams)
        }
    }

    /// Turning always-approve on answers waiting tool permission requests with "allow once".
    private func approvePendingPermissionRequests() {
        guard let store else { return }
        for (id, run) in store.runs {
            guard let client = store.clients[id] else { continue }
            for approval in run.approvals {
                guard !approval.options.contains(where: { $0.id.hasPrefix("folder:") || $0.id.hasPrefix("plan:") }),
                      let option = approval.options.first(where: { $0.kind == "allow_once" }) ?? approval.options.first(where: { $0.kind.hasPrefix("allow") })
                else { continue }
                do {
                    try client.respond(id: approval.requestID, result: ["outcome": ["outcome": "selected", "optionId": option.id]])
                    store.runs[id]?.approvals.removeAll { $0.id == approval.id }
                } catch { continue }
            }
        }
    }

    private func applyRemoteSettings(_ params: [String: Any]) {
        if let enabled = params["auto_permission_mode_enabled"] as? Bool { remoteAutoGate = enabled }
        if let raw = params["permission_mode"] as? String { remotePermissionMode = ComposerPermissionMode(rawValue: raw) }
        updateAutoGate()
        if !permissionModeExplicit, let remote = remotePermissionMode { permissionMode = remote == .auto && !autoModeAvailable ? .ask : remote }
    }

    private func updateAutoGate() {
        let environment = ProcessInfo.processInfo.environment["GROK_AUTO_PERMISSION_MODE"].flatMap(Self.parseFlag)
        let available = environment ?? configuredAutoGate ?? remoteAutoGate ?? true
        if autoModeAvailable != available { autoModeAvailable = available }
        if !available && permissionMode == .auto { permissionMode = .ask }
    }

    private static func parseFlag(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    // MARK: Preferences

    /// Reads the composer's `config.toml` preferences.
    func reloadPreferences() {
        let config = configURL.map { GrokConfig(url: $0) } ?? GrokConfig(text: "")
        let configured = ComposerPermissionMode.configured(in: config)
        permissionModeExplicit = configured != nil
        permissionMode = configured ?? remotePermissionMode ?? .ask
        configuredAutoGate = config.bool("enabled", in: "auto_mode")
        followUpBehavior = config.string("follow_up_behavior", in: "ui").flatMap(ComposerFollowUpBehavior.init(rawValue:)) ?? .queue
        voiceShortcutEnabled = config.bool("voice_keybind_enabled", in: "ui") ?? true
        voiceLanguage = VoiceSTTSettings.canonicalLanguage(config.string("voice_stt_language", in: "ui") ?? config.string("language", in: "voice"))
        voiceModel = VoiceSTTSettings(config: config).model
        updateAutoGate()
    }

    func setFollowUpBehavior(_ behavior: ComposerFollowUpBehavior) {
        followUpBehavior = behavior
        persist("follow_up_behavior", .string(behavior.rawValue))
    }

    func setVoiceShortcutEnabled(_ enabled: Bool) {
        voiceShortcutEnabled = enabled
        persist("voice_keybind_enabled", .bool(enabled))
    }

    func setVoiceLanguage(_ code: String) {
        voiceLanguage = VoiceSTTSettings.canonicalLanguage(code)
        persist("voice_stt_language", .string(voiceLanguage))
    }

    /// Any OpenRouter transcription model slug; blank restores the default.
    func setVoiceModel(_ model: String) {
        let model = VoiceSTTSettings.canonicalModel(model)
        guard !model.contains(where: \.isWhitespace) else {
            store?.banner = "The dictation model must be an OpenRouter model ID such as openai/whisper-1."
            return
        }
        guard model != voiceModel else { return }
        voiceModel = model
        persist("voice_stt_model", .string(model))
    }

    private func persist(_ key: String, _ value: GrokConfigValue) {
        guard let url = configURL else { return }
        Task { @MainActor [weak self] in
            do { try await Self.writeConfig(url) { try $0.set(key, to: value, in: "ui") } }
            catch { self?.store?.banner = "Couldn't save the setting: \(error.localizedDescription)" }
        }
    }

    /// Serializes read-modify-write edits of `config.toml` off the main thread.
    nonisolated static func writeConfig(_ url: URL, _ change: @escaping @Sendable (inout GrokConfig) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configQueue.async {
                do { try GrokConfig.update(url: url, change); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: /voice

    /// `/voice`, the microphone button, and ⇧⌘D: start dictating, or stop.
    func toggleVoice() {
        guard let store else { return }
        if voice.isActive { voice.stop(); return }
        guard store.project != nil else { store.banner = "Open a project to dictate a prompt."; return }
        if !store.harnessMeta.initialize.isEmpty && !store.harnessMeta.voiceMode {
            store.banner = "Voice input is turned off for this account."; return
        }
        guard VoiceDictationController.canRequestMicrophone else {
            store.banner = "Voice input needs the Grok Desktop app: macOS grants microphone access only to the app bundle. Build it with scripts/build-app.sh and open the app to dictate."
            return
        }
        let startID = UUID()
        voiceStartID = startID
        voice.beginStarting()
        Task { @MainActor [weak self] in await self?.startVoice(startID) }
    }

    /// Stops dictation, keeping words that are still being finalized.
    func stopVoice() { if voice.isActive { voice.stop() } }

    /// Enter while dictating keeps the pending words, stops, and sends.
    func finishVoiceForSubmit() {
        guard voice.isActive else { return }
        voiceStartID = nil
        if let pending = voice.stopForSubmit() { insertDictation(pending) }
    }

    private func startVoice(_ startID: UUID) async {
        guard let store else { return }
        @MainActor func stillStarting() -> Bool { voiceStartID == startID && voice.phase == .starting }
        guard await VoiceDictationController.requestMicrophoneAccess() else {
            guard stillStarting() else { return }
            voice.cancel()
            store.banner = "Microphone access is off for Grok Desktop. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        let settings = VoiceSTTSettings(config: configURL.map { GrokConfig(url: $0) } ?? GrokConfig(text: ""))
        let key = await Task.detached(priority: .userInitiated) { VoiceOpenRouterCredential.read() }.value
        guard stillStarting() else { return }
        if !store.harnessMeta.initialize.isEmpty && !store.harnessMeta.voiceMode {
            voice.cancel()
            store.banner = "Voice input is turned off for this account."
            return
        }
        if let key {
            voice.startOpenRouter(key: key, settings: settings)
            return
        }
        // Without an OpenRouter key, transcribe on this Mac when it can.
        let language = VoiceSTTSettings.languageForAPI(settings.language)
        let onDevice = await VoiceDictationController.prepareOnDeviceRecognition(language: language)
        guard stillStarting() else { return }
        if onDevice { voice.startOnDevice(language: language); return }
        voice.cancel()
        store.banner = "Voice: dictation uses OpenRouter transcription. Sign in to OpenRouter in Settings (or set OPENROUTER_API_KEY)."
    }

    /// Inserts finalized dictation at the cursor, spaced as its own words; a blank draft is replaced.
    func insertDictation(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        if let view = promptTextView, view.window != nil {
            let string = view.string as NSString
            if view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                view.insertText(text, replacementRange: NSRange(location: 0, length: string.length))
            } else {
                let range = view.selectedRange()
                let base = string.replacingCharacters(in: range, with: "")
                view.insertText(VoiceTextInsertion.spaced(text, in: base, at: range.location), replacementRange: range)
            }
        } else {
            store.draft = VoiceTextInsertion.merge(text, into: store.draft, replacing: nil).text
        }
    }

    // MARK: /edit-prompt

    /// `/edit-prompt`: the slash form starts from an empty prompt; the composer's button keeps the draft.
    func openEditPrompt(keepDraft: Bool) {
        guard let store else { return }
        if voice.isActive { store.banner = ExternalPromptEditor.voiceMessage; return }
        store.sheet = .editPrompt(text: keepDraft ? store.draft : "")
    }

    /// "Use Prompt": the edited text replaces the composer draft.
    func useEditedPrompt(_ text: String) {
        guard let store else { return }
        store.draft = text
        store.sheet = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
    }
}
