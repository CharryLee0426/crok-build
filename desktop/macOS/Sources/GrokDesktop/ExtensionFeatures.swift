import AppKit
import SwiftUI

/// A result line shown at the top of an extension panel.
struct ExtensionNotice: Equatable {
    var panel: FeaturePanel
    var text: String
    var isError = false
}

/// A question the harness or a destructive action needs answered before it runs.
struct ExtensionConfirmation: Identifiable {
    let id = UUID()
    var panel: FeaturePanel
    var message: String
    var detail: String? = nil
    var confirmTitle: String
    var destructive = true
    var run: () -> Void
}

/// Memory notes and maintenance, extension management panels, and importing Claude settings.
@MainActor
final class ExtensionFeatureModel: ObservableObject {
    weak var store: AppStore?
    let memory: MemoryPanelModel
    let marketplace: MarketplacePanelModel

    @Published var notice: ExtensionNotice?
    @Published var pendingConfirmation: ExtensionConfirmation?
    /// `hooks/list` extras: project trust and config files that failed to load.
    @Published var hooksTrusted: Bool?
    @Published var hooksLoadErrors: [String] = []
    /// `skills/config`: where skills are discovered.
    @Published var skillsDiscovery: SkillsDiscovery?
    /// `[agent] name` and `[subagents.toggle]` from config.toml.
    @Published var agentConfig = AgentConfigSnapshot()
    /// The agent running the selected task (`session/info.agentName`).
    @Published var activeAgent: String?

    /// Which panel, project, and task `store.featureRows` currently describe.
    var rowsKey: String?
    /// Files the selected task's tools read or edited, oldest first, for `/remember` context.
    private(set) var recentToolFiles: [UUID: [String]] = [:]
    private var recordedToolCalls: [UUID: Set<String>] = [:]

    init(store: AppStore) {
        self.store = store
        memory = MemoryPanelModel(store: store)
        marketplace = MarketplacePanelModel(store: store)
    }

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool {
        guard let update, let kind = update["sessionUpdate"] as? String else { return false }
        switch kind {
        case "tool_call", "tool_call_update":
            recordToolFile(update, conversationID: conversationID)
            return false
        case "memory_files":
            memory.receive(MemoryListing(update), conversationID: conversationID)
            return true
        case "hooks_changed", "plugins_changed":
            refreshIfShowing(kind == "hooks_changed" ? .hooks : .plugins, conversationID: conversationID)
            return false
        default:
            return false
        }
    }

    // MARK: Commands

    /// `/memory`, alias `/mem`.
    func memoryCommand(_ arguments: String) {
        guard arguments.isEmpty else {
            store?.banner = "/memory takes no arguments. Open it, then use the Memory switch to turn memory on or off."
            return
        }
        store?.featurePanel = .memory
    }
    /// `/remember [text]`.
    func openRemember(_ text: String) { store?.sheet = .remember(text: text) }
    /// `/flush`.
    func flushMemory() { memory.flush() }
    /// `/dream`.
    func dreamMemory() { memory.dream() }
    /// `/import-claude`.
    func openImportClaude() {
        // Scans first, like the terminal; the sheet opens only when there is something to import.
        guard let store else { return }
        ClaudeImportFlow.begin(store: store)
    }

    // MARK: Remember context

    /// Up to five recent prompts and twenty recent files, like the terminal's rewrite context.
    func rememberContext(conversationID: UUID?) -> String {
        guard let store else { return "" }
        let conversation = conversationID.flatMap { id in store.state.conversations.first { $0.id == id } }
        let prompts = (conversation?.messages ?? []).filter { $0.kind == .user }.map(\.text)
        let files = conversationID.flatMap { recentToolFiles[$0] } ?? []
        let branch = store.workspace.branch.isEmpty ? nil : store.workspace.branch
        return RememberContext.summary(cwd: store.project?.path ?? "", branch: branch, prompts: prompts, files: files)
    }

    private func recordToolFile(_ update: [String: Any], conversationID: UUID) {
        guard let callID = update["toolCallId"] as? String, recordedToolCalls[conversationID]?.contains(callID) != true,
              let path = RememberContext.toolFilePath(update) else { return }
        recordedToolCalls[conversationID, default: []].insert(callID)
        var files = recentToolFiles[conversationID] ?? []
        files.append(path)
        if files.count > 200 { files.removeFirst(files.count - 200) }
        recentToolFiles[conversationID] = files
    }

    private func refreshIfShowing(_ panel: FeaturePanel, conversationID: UUID) {
        guard let store, store.featurePanel == panel, store.state.selectedConversationID == conversationID, !store.featureLoading else { return }
        Task { await store.refreshFeatures(panel) }
    }

    // MARK: Agent definitions

    func reloadAgentConfig(url: URL = GrokPaths.configFile) {
        agentConfig = AgentConfigSnapshot.load(url: url)
    }

    /// `s` in the terminal's Agents tab: sets or clears `[agent] name`.
    func toggleDefaultAgent(_ row: FeatureRow, available: [String], url: URL = GrokPaths.configFile) {
        guard row.payload["plugin"] as? String == nil else {
            notice = ExtensionNotice(panel: .agentDefinitions, text: "Plugin agents can't be the session default — they are spawned as subagents via the Task tool.")
            return
        }
        let name = row.payload["name"] as? String ?? row.title
        let clearing = AgentConfigSnapshot.load(url: url).configuredDefault == name
        do {
            try AgentConfigWriter.setDefault(clearing ? nil : name, url: url)
            reloadAgentConfig(url: url)
            let resolved = AgentConfigWriter.resolvedDefault(configured: agentConfig.configuredDefault, available: available)
            notice = ExtensionNotice(panel: .agentDefinitions, text: clearing ? "Cleared: new sessions use '\(resolved)'" : "New sessions will start with '\(resolved)'")
        } catch {
            notice = ExtensionNotice(panel: .agentDefinitions, text: error.localizedDescription, isError: true)
        }
    }

    /// `t` in the terminal's Agents tab: `[subagents.toggle] <name> = bool`.
    func setAgentEnabled(_ name: String, enabled: Bool, url: URL = GrokPaths.configFile) {
        do {
            try AgentConfigWriter.setEnabled(name, enabled: enabled, url: url)
            reloadAgentConfig(url: url)
            notice = ExtensionNotice(panel: .agentDefinitions, text: "\(enabled ? "Enabled" : "Disabled") '\(name)' — applies to new sessions")
        } catch {
            notice = ExtensionNotice(panel: .agentDefinitions, text: error.localizedDescription, isError: true)
        }
    }
}
