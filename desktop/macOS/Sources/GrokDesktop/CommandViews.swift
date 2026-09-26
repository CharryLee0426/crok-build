import SwiftUI
import AppKit

extension FeaturePanel {
    var subtitle: String {
        switch self {
        case .mcps: return "Connect Grok to tools and data in your workspace."
        case .skills: return "Reusable instructions, discovered from your project and plugins."
        case .agents: return "Follow the agents working alongside this task."
        case .agentDefinitions: return "Agent roles available to the harness. Changes apply to new sessions."
        case .personas: return "Specialized instructions for subagents."
        case .goals: return "Keep working toward an objective across turns."
        case .plan: return "Review the steps before implementation."
        case .workflows: return "Launch a workflow or check its progress."
        case .plugins: return "Extensions loaded by your Grok harness."
        case .marketplace: return "Plugins available from your marketplace sources."
        case .hooks: return "Actions triggered by events in the harness."
        case .memory: return "What Grok remembers across sessions, for this task's workspace and everywhere."
        case .models: return "Choose the model for your next message."
        case .reasoning: return "Control how much the selected model thinks."
        case .history: return "Choose a prompt to reuse it in the composer."
        case .transcript: return "Search the messages in this task."
        }
    }
    var isLocal: Bool { [.plan, .models, .reasoning, .history, .transcript].contains(self) }
    /// Panels whose content is drawn by a dedicated view rather than generic rows.
    var hasDedicatedView: Bool { [.plugins, .hooks, .skills, .workflows, .marketplace, .agentDefinitions, .personas].contains(self) }
}

struct FeatureBrowser: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let panel: FeaturePanel
    @State private var search = ""
    @State private var objective = ""
    @State private var budget = ""
    @State private var actionInput = ""
    @State private var expanded: Set<String> = []
    @State private var messageRecipient: String?
    @State private var showAddMCP = false
    @State private var mcpName = ""
    @State private var mcpEndpoint = ""
    @State private var removeServer: FeatureRow?
    @State private var filter = ExtensionFilter.all
    @State private var creatingPersona = false
    /// The footer field: plugin source, marketplace source, or hook path.
    @State private var sourceInput = ""

    /// The extra flags open a form up front (used by previews and snapshot tests).
    private let expandSkillSources: Bool

    init(panel: FeaturePanel, showAddMCP: Bool = false, creatingPersona: Bool = false, expandSkillSources: Bool = false) {
        self.panel = panel
        self.expandSkillSources = expandSkillSources
        _showAddMCP = State(initialValue: showAddMCP)
        _creatingPersona = State(initialValue: creatingPersona)
    }

    private var rows: [FeatureRow] {
        store.featureRows.filter { search.isEmpty || "\($0.title) \($0.subtitle) \($0.detail)".localizedCaseInsensitiveContains(search) }
    }
    private var controlsDisabled: Bool { store.featureLoading || store.run.isConfiguring }
    private var isLoading: Bool { panel == .memory ? extensions.memory.loading : store.featureLoading }
    private var width: CGFloat { panel == .memory ? 940 : 720 }
    private var contentHeight: CGFloat {
        switch panel {
        case .mcps where showAddMCP: return 430
        case .personas where creatingPersona: return 520
        case .plugins, .hooks, .skills, .marketplace, .agentDefinitions, .personas, .workflows: return 440
        default: return 360
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if panel != .goals && panel != .plan {
                NativeSearchField(text: $search, placeholder: panel == .memory ? "Filter notes" : "Search \(panel.title.lowercased())", onEscape: { store.featurePanel = nil },
                                  onMove: panel == .memory ? { extensions.memory.moveSelection(by: $0, filter: search) } : nil)
                    .frame(height: 40).padding(.horizontal, 24).padding(.bottom, 20)
            }
            Divider()
            messageBar
            if panel == .memory {
                MemoryPanelView(model: extensions.memory, filter: search).frame(height: 480)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !panel.isLocal {
                            ForEach(store.run.approvals) { ApprovalCard(approval: $0) }
                            ForEach(store.run.questions) { QuestionCard(request: $0) }
                        }
                        if panel.isLocal { localContent } else { remoteContent }
                    }.padding(24)
                }.frame(height: contentHeight)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 20)
        }.frame(width: width).glassSheetBackground()
            .task(id: panel) {
                extensions.notice = nil
                if panel == .plan { await store.loadSavedPlan() }
                else if !panel.isLocal { await store.refreshFeatures(panel) }
            }
            .confirmationDialog("Remove MCP server \"\(removeServer?.title ?? "")\"?", isPresented: Binding(get: { removeServer != nil }, set: { if !$0 { removeServer = nil } }), titleVisibility: .visible) {
                if let server = removeServer { Button("Remove \(server.title)", role: .destructive) { store.removeMCPServer(server.id); removeServer = nil } }
            } message: { Text("The server will be removed from your Grok configuration. You can add it again later.") }
            .confirmationDialog(extensions.pendingConfirmation?.message ?? "", isPresented: Binding(get: { extensions.pendingConfirmation?.panel == panel }, set: { if !$0 { extensions.pendingConfirmation = nil } }), titleVisibility: .visible) {
                if let confirmation = extensions.pendingConfirmation {
                    Button(confirmation.confirmTitle, role: confirmation.destructive ? .destructive : nil) {
                        extensions.pendingConfirmation = nil
                        confirmation.run()
                    }
                }
            } message: { if let detail = extensions.pendingConfirmation?.detail { Text(detail) } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(panel.title).font(.system(size: 23, weight: .semibold))
                Text(panel.subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !panel.isLocal {
                if isLoading && (panel == .memory || !store.featureRows.isEmpty || panel == .marketplace) {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    IconButton(icon: "arrow.clockwise", help: "Refresh \(panel.title)") {
                        Task { await store.refreshFeatures(panel) }
                    }.disabled(controlsDisabled)
                }
            }
            IconButton(icon: "xmark", help: "Close") { store.featurePanel = nil }.keyboardShortcut(.cancelAction)
        }.padding(24)
    }

    @ViewBuilder private var messageBar: some View {
        if let error = store.featureError, !panel.isLocal, panel != .memory {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                Text(error).textSelection(.enabled)
                Spacer()
                Button("Retry") { Task { await store.refreshFeatures(panel) } }
                    .buttonStyle(SubtleButtonStyle())
            }.font(.system(size: 13)).padding(.horizontal, 24).padding(.vertical, 16).background(Theme.hover.opacity(0.55))
        } else if let notice = extensions.notice, notice.panel == panel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(notice.isError ? Color.red : Theme.green)
                Text(notice.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                IconButton(icon: "xmark", help: "Dismiss", size: 22) { extensions.notice = nil }
            }.font(.system(size: 13)).padding(.horizontal, 24).padding(.vertical, 12).background(Theme.hover.opacity(0.4))
        }
    }

    private var emptyLabel: String {
        switch panel {
        case .agents: return "No subagents are running in this task."
        case .goals: return "No goal has been set for this task."
        case .hooks: return "No hooks are configured."
        case .plugins: return "No plugins are installed. Install one below or browse the marketplace."
        case .workflows: return "No saved workflows in this workspace."
        case .personas: return "No personas available."
        default: return "No \(panel.title.lowercased()) available in this workspace."
        }
    }

    @ViewBuilder private var remoteContent: some View {
        if panel == .goals { goalForm }
        if panel == .mcps, showAddMCP { mcpForm }
        if store.featureLoading && store.featureRows.isEmpty && !(panel == .marketplace && extensions.marketplace.loaded) {
            ProgressView("Loading \(panel.title.lowercased())…").frame(maxWidth: .infinity).padding(25)
        }
        switch panel {
        case .plugins: PluginsPanelView(rows: rows, disabled: controlsDisabled, filter: $filter)
        case .hooks: HooksPanelView(rows: rows, disabled: controlsDisabled, filter: $filter)
        case .skills: SkillsPanelView(rows: rows, disabled: controlsDisabled, filter: $filter, showSources: expandSkillSources)
        case .workflows: WorkflowsPanelView(rows: rows, disabled: controlsDisabled)
        case .marketplace: MarketplacePanelView(model: extensions.marketplace, search: search, disabled: controlsDisabled)
        case .agentDefinitions: AgentDefinitionsPanelView(rows: rows, disabled: controlsDisabled)
        case .personas: PersonasPanelView(rows: rows, disabled: controlsDisabled, creating: $creatingPersona)
        default: ForEach(rows) { row in featureRow(row) }
        }
        if rows.isEmpty && !store.featureLoading && store.featureError == nil && panel != .marketplace {
            VStack(spacing: 10) {
                Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 25)).foregroundStyle(Theme.muted)
                Text(search.isEmpty ? emptyLabel : "No matching results").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity).padding(35)
        }
    }

    @ViewBuilder private var localContent: some View {
        switch panel {
        case .models, .reasoning:
            let options = panel == .models ? store.run.models : store.run.reasoningOptions
            ForEach(options.filter { search.isEmpty || "\($0.name) \($0.id)".localizedCaseInsensitiveContains(search) }) { option in
                Button {
                    if panel == .models { store.setModel(option) } else { store.setReasoning(option) }
                    store.featurePanel = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(option.name).fontWeight(.medium); Text(option.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted) }
                        Spacer()
                        if option.id == (panel == .models ? store.run.modelID : store.run.reasoningID) { Image(systemName: "checkmark") }
                    }.padding(13).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.run.isRunning || controlsDisabled)
            }
            if options.isEmpty { Text("No choices are available for this session.").foregroundStyle(Theme.muted).padding(20) }
        case .plan:
            if store.savedPlanLoading { ProgressView("Loading saved plan…").padding(20) }
            if let error = store.savedPlanError { Text(error).foregroundStyle(Theme.muted).padding(10) }
            if let content = store.savedPlanContent { MarkdownContent(text: content, style: .panel).padding(10) }
            if store.run.plan.isEmpty && store.savedPlanContent == nil && !store.savedPlanLoading { Text("No saved plan yet. Use /plan to ask Grok to prepare a plan.").foregroundStyle(Theme.muted).padding(20) }
            ForEach(store.run.plan) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : "circle")
                    Text(entry.content).textSelection(.enabled)
                    Spacer()
                    Text(entry.status.replacingOccurrences(of: "_", with: " ")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }.padding(10)
            }
            ForEach(store.run.approvals.filter { $0.options.contains { $0.id.hasPrefix("plan:") } }) { ApprovalCard(approval: $0) }
        case .history, .transcript:
            let messages = (store.conversation?.messages ?? []).filter { (panel != .history || $0.kind == .user) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
            if messages.isEmpty { Text("No matching messages.").foregroundStyle(Theme.muted).padding(20) }
            ForEach(messages) { message in
                if panel == .history {
                    Button { store.draft = message.text; store.featurePanel = nil; focusComposer() } label: {
                        Text(message.text).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else { MessageView(message: message).padding(.vertical, 8) }
            }
        default: EmptyView()
        }
    }

    private var goalForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            DesktopTextField("What should Grok work toward?", text: $objective, title: "Objective", symbol: "scope", multiline: true)
            HStack(alignment: .bottom, spacing: 16) {
                DesktopTextField("e.g. 100000", text: $budget, title: "Token budget (optional)", symbol: "number")
                    .frame(width: 250)
                Spacer()
                Button {
                    let suffix = budget.isEmpty ? "" : " --budget \(budget)"
                    store.featurePanel = nil
                    store.executeCommand(name: "goal", arguments: objective + suffix)
                } label: { Text("Start goal").frame(height: 28) }
                    .buttonStyle(SubtleButtonStyle()).disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!budget.isEmpty && (Int(budget) ?? 0) <= 0) || store.run.isRunning || controlsDisabled)
            }
        }.padding(20).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line.opacity(0.35), lineWidth: 0.5))
    }

    private func featureRow(_ row: FeatureRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled) }
                }
                Spacer()
                if let enabled = row.enabled {
                    Toggle("Enabled", isOn: Binding(get: { enabled }, set: { _ in store.toggleFeature(row, panel: panel) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(controlsDisabled)
                        .accessibilityLabel("Enable \(row.title)")
                }
            }
            if !row.detail.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(row.id) }, set: { if $0 { expanded.insert(row.id) } else { expanded.remove(row.id) } })) {
                    Text(row.detail).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: { Text("Details").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            if panel == .mcps {
                let tools = MCPToolChoice.from(row)
                if !tools.isEmpty {
                    DisclosureGroup("Tools · \(tools.count)") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(tools) { tool in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                        Text(tool.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3)
                                    }
                                    Spacer()
                                    Toggle("Enable \(tool.name)", isOn: Binding(get: { tool.enabled }, set: { enabled in store.toggleMCPTool(server: row.id, tool: tool.name, enabled: enabled) }))
                                        .toggleStyle(.switch).labelsHidden().controlSize(.mini).disabled(controlsDisabled || row.enabled == false)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            if !row.actions.isEmpty || (panel == .mcps && row.payload["source"] as? String == "local") {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    rowActions(row)
                }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
            }
            if messageRecipient == row.id {
                Divider().padding(.vertical, 2)
                DesktopTextField("Add context or give a follow-up instruction", text: $actionInput,
                                 title: "Message to subagent", symbol: "text.bubble", multiline: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { messageRecipient = nil }
                    Button("Send message") {
                        store.invokeFeature(row, panel: panel, action: "Message", arguments: actionInput)
                        actionInput = ""; messageRecipient = nil
                    }.disabled(actionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlsDisabled)
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }.padding(18).background(Theme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder private func rowActions(_ row: FeatureRow) -> some View {
        ForEach(row.actions, id: \.self) { action in
            if action == "Message" {
                Button("Message") { messageRecipient = row.id; actionInput = "" }.disabled(controlsDisabled)
            } else {
                Button(action) {
                    store.invokeFeature(row, panel: panel, action: action)
                    if ["Use", "Run"].contains(action) { store.featurePanel = nil; focusComposer() }
                }.disabled(controlsDisabled || (["Use", "Run", "Restart"].contains(action) && row.enabled == false))
            }
        }
        if panel == .mcps, row.payload["source"] as? String == "local" {
            IconButton(icon: "trash", help: "Remove server") { removeServer = row }.disabled(controlsDisabled)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch panel {
            case .plugins:
                sourceField(title: "Install a plugin", placeholder: "owner/repo, URL, or local path", symbol: "puzzlepiece.extension", action: "Install") {
                    store.runPluginsAction(.install(source: sourceInput.trimmingCharacters(in: .whitespacesAndNewlines))); sourceInput = ""
                }
            case .marketplace:
                sourceField(title: "Add a marketplace source", placeholder: "owner/repo, git URL, or local path", symbol: "shippingbox", action: "Add source") {
                    extensions.marketplace.perform(.addSource(url: sourceInput.trimmingCharacters(in: .whitespacesAndNewlines))); sourceInput = ""
                }
            case .hooks:
                sourceField(title: "Add a hook directory", placeholder: "~/.grok/hooks/my-hooks", symbol: "folder.badge.plus", action: "Add path", browse: true) {
                    let path = (sourceInput.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                    store.runHooksAction(.add(path: path)); sourceInput = ""
                }
            default: EmptyView()
            }
            HStack(spacing: 12) {
                footerActions
                Spacer(minLength: 0)
                Button("Done") { store.featurePanel = nil }.keyboardShortcut(.defaultAction)
            }
        }.buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
    }

    @ViewBuilder private var footerActions: some View {
        switch panel {
        case .mcps:
            Button(showAddMCP ? "Cancel adding" : "Add server") { showAddMCP.toggle() }.disabled(controlsDisabled)
        case .skills:
            Button("Add skill…") { store.addSkillFolder() }.disabled(controlsDisabled)
            Button("Reset…") {
                extensions.pendingConfirmation = ExtensionConfirmation(panel: .skills, message: "Reset skill discovery to the defaults?",
                    detail: "Custom skill paths and ignored paths are removed from config.toml.", confirmTitle: "Reset") { store.resetSkillsConfig() }
            }.disabled(controlsDisabled)
        case .plugins:
            Button("Update all") { store.runPluginsAction(.update(pluginID: nil)) }.disabled(controlsDisabled || store.featureRows.isEmpty)
            Button("Reload plugins") { store.runPluginsAction(.reload) }.disabled(controlsDisabled)
            Button("Marketplace…") { store.featurePanel = .marketplace }
        case .marketplace:
            Button("Refresh sources") { extensions.marketplace.perform(.refresh(source: nil)) }.disabled(controlsDisabled)
        case .hooks:
            Button("Reload hooks") { store.runHooksAction(.reload) }.disabled(controlsDisabled)
        case .workflows:
            Button("View running workflows") { runArgumentCommand("workflow", "runs") }
        case .personas:
            Button { creatingPersona = true } label: { Label("New persona", systemImage: "plus") }.disabled(creatingPersona || store.project == nil)
        case .goals:
            Text("Goal availability and budgets are controlled by the harness.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .plan:
            Button("Start planning") { store.featurePanel = nil; store.executeCommand(name: "plan") }
        case .memory:
            Text("Notes are stored under \((GrokPaths.home.path as NSString).abbreviatingWithTildeInPath)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        default:
            Text(store.project?.name ?? "No project selected").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private func sourceField(title: String, placeholder: String, symbol: String, action: String, browse: Bool = false, submit: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            DesktopTextField(placeholder, text: $sourceInput, title: title, symbol: symbol)
            if browse {
                Button { chooseHookDirectory() } label: { Text("Choose…").frame(height: 28) }
            }
            Button(action: submit) { Text(action).frame(height: 28) }
                .disabled(sourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlsDisabled)
        }
    }

    private func chooseHookDirectory() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.directoryURL = GrokPaths.home.appendingPathComponent("hooks")
        picker.message = "Choose a hook directory inside \((GrokPaths.home.path as NSString).abbreviatingWithTildeInPath)."; picker.prompt = "Choose"
        if picker.runModal() == .OK, let url = picker.url { sourceInput = (url.path as NSString).abbreviatingWithTildeInPath }
    }

    private func runArgumentCommand(_ name: String, _ arguments: String) {
        store.featurePanel = nil; store.executeCommand(name: name, arguments: arguments)
    }
    private func focusComposer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
    }

    /// The terminal's one-field form: a URL for a remote server, or a command with its arguments.
    private var mcpForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add MCP server").font(.system(size: 15, weight: .semibold))
            DesktopTextField("https://... or command [args...]", text: $mcpEndpoint, title: "URL / Command", symbol: "link",
                             hint: "A URL connects to a remote server; anything else runs as a local command with its arguments.")
            DesktopTextField("Auto generated by URL", text: $mcpName, title: "Name", symbol: "server.rack")
            HStack(alignment: .center, spacing: 16) {
                Text("Configure credentials through your harness environment.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    if store.addMCPServer(urlOrCommand: mcpEndpoint, name: mcpName) { mcpEndpoint = ""; mcpName = ""; showAddMCP = false }
                } label: {
                    Text("Save server").frame(height: 28)
                }.buttonStyle(SubtleButtonStyle())
                    .disabled(mcpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlsDisabled)
            }
        }.padding(20).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line.opacity(0.35), lineWidth: 0.5))
    }
}
