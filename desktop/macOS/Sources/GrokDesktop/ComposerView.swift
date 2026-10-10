import SwiftUI
import AppKit

/// The prompt editor with its command menu, model and thinking pickers, permissions, dictation,
/// queue, and send control.
struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var features: ComposerFeatureModel
    @EnvironmentObject var attachments: PromptAttachmentsModel
    @ObservedObject private var language = L10n.state
    /// A drag over the card, and one over the text view, which handles its own drops.
    @State private var cardDropTargeted = false
    @State private var editorDropTargeted = false
    @State private var showModels = false
    @State private var showTools = false
    @State private var showReasoning = false
    @State private var showModes = false
    @State private var showPermissions = false
    @State private var showCompactOptions = false
    @State private var modelSearch = ""
    @State private var selectedCommand = 0
    @State private var dismissedCommandDraft: String?
    @State private var hoveringEditor = false

    var body: some View {
        VStack(spacing: 10) {
            if let id = store.state.selectedConversationID {
                if let status = features.compactions[id] {
                    ComposerCompactionRow(status: status, onStop: { store.cancel() }, onDismiss: { features.dismissCompaction(id) })
                }
                if !features.queue.items(id).isEmpty || features.harnessQueues[id]?.entries.isEmpty == false {
                    ComposerQueuePanel(conversationID: id, isRunning: store.run.isRunning).id(id)
                }
            }
            editorCard
            footer
        }
        .background {
            if voiceAvailable && features.voiceShortcutEnabled {
                Button("Dictate") { features.toggleVoice() }.keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
            }
        }
        .onChange(of: store.state.selectedConversationID) { _, _ in
            showModels = false; showTools = false; showReasoning = false; showModes = false; showPermissions = false; showCompactOptions = false
            // Dictation belongs to the prompt it started in.
            if features.voice.isActive { features.voice.cancel() }
        }
        .onChange(of: store.draft) { previous, value in
            selectedCommand = 0
            dismissedCommandDraft = nil
            if value.hasPrefix("/") && !previous.hasPrefix("/") { Task { await store.refreshCommands() } }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if store.project != nil { ComposerGitFooter() }
    }

    private var optionsDisabled: Bool { store.run.isRunning || store.run.isConfiguring }
    /// Native commands run at once, even mid-turn; prompts and harness commands wait in the queue.
    private var turnPolicy: DesktopCommands.TurnPolicy {
        guard let command = SlashCommand.split(store.draft) else { return .queue }
        return DesktopCommands.turnPolicy(command.name, arguments: command.arguments)
    }
    private var isLiveCommand: Bool { turnPolicy == .runNow }
    private var hasDraftText: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A prompt can be only attachments, once every image is ready to send.
    private var hasContent: Bool { hasDraftText || (!attachments.current.isEmpty && !attachments.isPreparing) }
    /// While a task runs, Return adds the prompt to its queue (or steers the turn).
    private var canQueue: Bool {
        hasContent && store.run.isRunning && !store.run.isConfiguring && turnPolicy == .queue && store.state.selectedConversationID != nil && store.project != nil
    }
    private var canSend: Bool {
        // Return on a command that needs an idle task explains why instead of doing nothing.
        hasContent && store.project != nil && (!optionsDisabled || (store.run.isRunning && turnPolicy != .queue) || canQueue)
    }
    private var voiceAvailable: Bool { store.harnessMeta.voiceMode && store.project != nil }
    private var draftLineCount: Int { store.draft.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var selectedModelName: String {
        store.run.models.first { $0.id == store.run.modelID }?.name ?? (store.run.modelID.isEmpty ? L10n.t("choose_model", "Choose model") : store.run.modelID)
    }
    private var selectedModelWindow: Int? { store.run.models.first { $0.id == store.run.modelID }?.contextWindow }
    private var filteredModels: [ModelOption] {
        store.run.models.filter { modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.id.localizedCaseInsensitiveContains(modelSearch) }
    }
    private var reasoningName: String {
        let id = store.run.reasoningID
        if let option = store.run.reasoningOptions.first(where: { $0.id == id }) { return L10n.reasoningName(id: id, fallback: option.name) }
        if !id.isEmpty { return L10n.reasoningName(id: id, fallback: id == "xhigh" ? "Extra high" : id.capitalized) }
        return store.run.models.isEmpty || !store.run.reasoningOptions.isEmpty
            ? L10n.t("effort_default", "Default") : L10n.t("effort_not_supported", "Not supported")
    }

    private var editorCard: some View {
        let lines = draftLineCount
        let pending = attachments.current
        let padding: CGFloat = 16
        return VStack(alignment: .leading, spacing: 12) {
            VoiceRecordingRow(voice: features.voice) { features.stopVoice() }
            if !pending.isEmpty {
                ComposerAttachmentStrip(attachments: pending, bleed: padding, onRemove: { attachments.remove($0) }, onPreview: { attachments.preview($0) })
                    .padding(.bottom, -4)
                    // Each draft's strip is scrolled on its own.
                    .id(store.draftLocation)
            }
            PromptEditor(text: $store.draft, placeholder: placeholder, onSubmit: submitDraft, onCommandKey: handleComposerKey,
                         onTextView: { [weak model = features] view in model?.promptTextView = view },
                         onPasteAttachments: { [weak attachments] pasteboard in attachments?.paste(from: pasteboard) ?? false },
                         onDropAttachments: { [weak attachments] pasteboard in attachments?.drop(from: pasteboard) ?? false },
                         onAttachmentDragChanged: { targeted in editorDropTargeted = targeted })
            .frame(height: lines > 3 ? 120 : 76)
            .overlay(alignment: .topTrailing) {
                if hoveringEditor || lines > 3 {
                    IconButton(icon: "arrow.up.left.and.arrow.down.right", help: "Edit in a larger editor", size: 24) {
                        features.openEditPrompt(keepDraft: true)
                    }
                    .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: 8, y: -8)
                }
            }
            .onHover { hoveringEditor = $0 }
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 6) {
                    toolsButton
                    if geometry.size.width < 460 {
                        compactOptionsButton(iconOnly: geometry.size.width < 260)
                    } else {
                        modelPicker
                        reasoningPicker
                        permissionPicker
                        modePicker
                    }
                    Spacer(minLength: 0)
                    if store.run.isConfiguring {
                        ProgressView().controlSize(.small).frame(width: 20, height: 30)
                            .help("Updating conversation settings…").accessibilityLabel("Updating conversation settings")
                    }
                    if store.project != nil, let id = store.state.selectedConversationID {
                        ComposerContextRing(conversationID: id, catalogWindow: selectedModelWindow)
                    }
                    if voiceAvailable {
                        VoiceMicButton(voice: features.voice, shortcut: features.voiceShortcutEnabled ? ComposerFeatureModel.voiceShortcut : nil) {
                            features.toggleVoice()
                        }
                    }
                    sendControls
                }
            }.frame(height: 30)
        }.padding(padding).glassSurface(cornerRadius: 24)
            .overlay { if cardDropTargeted || editorDropTargeted { AttachmentDropOverlay(cornerRadius: 24) } }
            .onDrop(of: [.fileURL, .image], isTargeted: $cardDropTargeted) { providers in attachments.add(providers: providers) }
            .quickLookPreview($attachments.previewURL)
            .overlay(alignment: .top) {
                if showSlashCommands {
                    VStack(spacing: 0) {
                        HStack { Text("Commands & skills").fontWeight(.medium); Spacer(); Text("↑↓ Select  ·  ⇥ Complete  ·  esc Close") }
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(12)
                        Divider()
                        CommandList(commands: slashCommands, selected: selectedCommand, onSelect: chooseCommand)
                            .frame(height: min(300, max(80, CGFloat(slashCommands.count) * 65)))
                    }
                    .glassSurface(cornerRadius: 14)
                    // Sits just above the card, however tall attachments make it. An overlay ignores alignment
                    // guides its content sets, so the menu rises from a frame of no height at the card's top.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                    .frame(height: 0, alignment: .bottom)
                }
            }
    }

    private var placeholder: String {
        if store.run.isRunning && store.conversation != nil {
            return features.followUpBehavior == .steer
                ? L10n.t("placeholder_steer", "Steer Crok while it works…") : L10n.t("placeholder_queue", "Queue a follow-up…")
        }
        return store.conversation == nil
            ? L10n.t("placeholder_new", "Ask Crok to build, fix, or explore anything…") : L10n.t("placeholder_continue", "Continue the conversation…")
    }

    private var showSlashCommands: Bool {
        let value = store.draft
        return value.hasPrefix("/") && !value.dropFirst().contains(where: \.isWhitespace) && dismissedCommandDraft != value
    }
    private var slashCommands: [SlashCommand] { DesktopCommands.matches(store.availableCommands, query: store.draft) }
    private func submitDraft() {
        // Return while dictating keeps the words heard so far, stops, and sends. With OpenRouter the last
        // words are transcribed after the stop, so Return only stops; the next Return sends.
        if features.voice.finalArrivesAfterStop { features.stopVoice(); return }
        if features.voice.isActive { features.finishVoiceForSubmit() }
        if showSlashCommands && slashCommands.indices.contains(selectedCommand) { chooseCommand(slashCommands[selectedCommand]) }
        else if let command = SlashCommand.split(store.draft), command.name == "btw" || (command.name == "goal" && ["status", "pause", "resume", "clear"].contains(command.arguments)) {
            store.draft = ""; store.executeCommand(name: command.name, arguments: command.arguments)
        }
        else if canSend { store.send() }
    }
    private func handleComposerKey(_ code: UInt16) -> Bool {
        if code == 53, features.voice.isActive { features.stopVoice(); return true }
        guard showSlashCommands else { return false }
        switch code {
        case 125: selectedCommand = min(selectedCommand + 1, max(0, slashCommands.count - 1))
        case 126: selectedCommand = max(0, selectedCommand - 1)
        case 48:
            if slashCommands.indices.contains(selectedCommand) {
                store.draft = "/\(slashCommands[selectedCommand].name) "
            }
        case 53: dismissedCommandDraft = store.draft
        default: return false
        }
        return true
    }
    private func chooseCommand(_ command: SlashCommand) {
        if store.run.isRunning && !command.requiresArguments && !(command.isSkill && command.argumentHint != nil) {
            // Mid-turn, the command runs, queues, or explains why it must wait, like typed text.
            store.draft = "/\(command.name)"
            store.send()
            return
        }
        if command.requiresArguments || command.isSkill && command.argumentHint != nil {
            store.draft = "/\(command.name) "
            NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
        } else {
            store.draft = ""
            store.executeCommand(name: command.name)
        }
    }
    private var toolsButton: some View {
        Button { showTools.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30).contentShape(Circle())
        }.buttonStyle(ComposerControlStyle()).help("Attach files, or use commands, skills, and tools")
            .accessibilityLabel("Add attachments, tools, and commands")
            .popover(isPresented: $showTools, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    toolAction(L10n.t("add_photos_files", "Add photos & files"), symbol: "paperclip") { attachments.chooseFiles() }
                        .disabled(store.project == nil)
                    toolAction(L10n.t("add_folder", "Add folder"), symbol: "folder.badge.plus") { attachments.chooseFolder() }
                        .disabled(store.project == nil)
                    Divider().padding(.vertical, 5)
                    Text(L10n.t("tools_commands", "Tools & commands")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(12)
                    toolAction(L10n.t("commands_row", "Commands"), symbol: "command", shortcut: "⇧⌘P") { store.showCommandPalette = true }
                    Divider().padding(.vertical, 5)
                    toolAction(L10n.t("plan_mode_row", "Plan mode"), symbol: "list.bullet.clipboard") { store.executeCommand(name: "plan") }
                    toolAction(L10n.t("goal", "Goal"), symbol: "scope") { store.featurePanel = .goals }
                    toolAction("MCP servers", symbol: "externaldrive.connected.to.line.below") { store.featurePanel = .mcps }
                    toolAction("Skills", symbol: "sparkles") { store.featurePanel = .skills }
                    toolAction("Subagents", symbol: "person.2") { store.featurePanel = .agents }
                    toolAction("Workflows", symbol: "arrow.triangle.branch") { store.featurePanel = .workflows }
                    Divider().padding(.vertical, 5)
                    toolAction("Edit in larger editor", symbol: "arrow.up.left.and.arrow.down.right") { features.openEditPrompt(keepDraft: true) }
                    if store.conversation != nil {
                        toolAction("Compact conversation", symbol: "arrow.down.right.and.arrow.up.left") { features.compact("") }
                    }
                    if voiceAvailable {
                        toolAction("Dictate", symbol: "mic", shortcut: features.voiceShortcutEnabled ? ComposerFeatureModel.voiceShortcut : nil) { features.toggleVoice() }
                    }
                }.padding(6).frame(width: 268)
            }
    }

    private func toolAction(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            showTools = false
            DispatchQueue.main.async { action() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(Theme.muted).frame(width: 19)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }.font(.system(size: 14))
        }.buttonStyle(PopoverRowStyle())
    }

    private var modelPicker: some View {
        Button {
            modelSearch = ""
            showModels.toggle()
            if store.run.models.isEmpty { Task { await store.prepareSessionOptions() } }
        } label: {
            ComposerControlLabel(title: selectedModelName, symbol: "cpu")
        }.buttonStyle(ComposerControlStyle(filled: true)).disabled(optionsDisabled || store.project == nil)
            .help("Model: \(selectedModelName)").accessibilityLabel("Model: \(selectedModelName)")
            .popover(isPresented: $showModels, arrowEdge: .top) { modelPopover }
    }

    private func compactOptionsButton(iconOnly: Bool) -> some View {
        Button { showCompactOptions.toggle() } label: {
            if iconOnly {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                    .frame(width: 30, height: 30).contentShape(Circle())
            } else {
                ComposerControlLabel(title: selectedModelName, symbol: "slider.horizontal.3")
            }
        }.buttonStyle(ComposerControlStyle(filled: true)).disabled(store.project == nil)
            .help("Model, thinking level, permissions, and mode").accessibilityLabel("Conversation settings: \(selectedModelName), \(reasoningName), \(features.permissionMode.title)")
            .popover(isPresented: $showCompactOptions, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("conversation_settings", "Conversation settings")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(12)
                    compactOptionRow(L10n.t("model", "Model"), value: selectedModelName, symbol: "cpu", panel: .models)
                        .disabled(optionsDisabled)
                    compactOptionRow(L10n.t("thinking", "Thinking"), value: reasoningName, symbol: "brain", panel: .reasoning)
                        .disabled(optionsDisabled || store.run.reasoningOptions.isEmpty)
                    Divider().padding(.vertical, 5)
                    ComposerPermissionMenu(current: features.permissionMode, autoAvailable: features.autoModeAvailable, showsHeader: true) { mode in
                        showCompactOptions = false
                        features.setPermissionMode(mode)
                    }
                    if !store.run.modes.isEmpty {
                        Divider().padding(.vertical, 5)
                        Text("Mode").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(12)
                        ForEach(store.run.modes) { mode in
                            Button { showCompactOptions = false; store.setMode(mode) } label: {
                                HStack {
                                    Text(mode.name)
                                    Spacer()
                                    if mode.id == store.run.modeID { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }.font(.system(size: 14))
                            }.buttonStyle(PopoverRowStyle()).disabled(optionsDisabled)
                        }
                    }
                }.padding(6).frame(width: 300)
            }
    }

    private func compactOptionRow(_ title: String, value: String, symbol: String, panel: FeaturePanel) -> some View {
        Button {
            showCompactOptions = false
            DispatchQueue.main.async { store.featurePanel = panel }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(Theme.muted).frame(width: 19)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(value).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }.buttonStyle(PopoverRowStyle())
    }

    private var modelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a model").font(.system(size: 16, weight: .semibold)).padding([.horizontal, .top], 16)
            NativeSearchField(text: $modelSearch, placeholder: "Search models or providers", onEscape: { showModels = false })
                .frame(height: 40).padding(12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    if filteredModels.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(Theme.muted)
                            Text(store.run.isConfiguring ? "Loading models…" : store.run.models.isEmpty ? "Models are unavailable" : "No matching models")
                                .font(.system(size: 14, weight: .medium))
                            if store.run.models.isEmpty && !store.run.isConfiguring {
                                Button("Try again") { Task { await store.prepareSessionOptions() } }
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 48)
                    }
                    ForEach(filteredModels) { model in
                        Button {
                            store.setModel(model)
                            showModels = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                                    Text(model.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if model.id == store.run.modelID { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(optionsDisabled)
                            .background(model.id == store.run.modelID ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(7)
            }.frame(height: 320)
            Divider()
            Text("Model changes apply to your next message. /model <name> [effort] switches from the prompt.").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(14)
        }.frame(width: 400)
    }

    private var reasoningPicker: some View {
        Button { showReasoning.toggle() } label: {
            ComposerControlLabel(title: reasoningName, symbol: "brain")
        }.buttonStyle(ComposerControlStyle()).fixedSize(horizontal: true, vertical: false)
            .disabled(optionsDisabled || store.run.reasoningOptions.isEmpty)
            .help(store.run.reasoningOptions.isEmpty ? "This model does not offer an adjustable thinking level." : "Choose how much the model thinks before answering.")
            .accessibilityLabel("Thinking level: \(reasoningName)")
            .popover(isPresented: $showReasoning, arrowEdge: .top) {
                optionPopover(L10n.t("thinking_level", "Thinking level"), options: store.run.reasoningOptions, selected: store.run.reasoningID,
                              name: { L10n.reasoningName(id: $0.id, fallback: $0.name) }) { option in
                    showReasoning = false
                    store.setReasoning(option)
                }
            }
    }

    /// Ask / Auto / Always approve, as its icon alone; the title is in its help. Changes apply to running tasks immediately.
    private var permissionPicker: some View {
        let mode = features.permissionMode
        return Button { showPermissions.toggle() } label: {
            Image(systemName: mode.symbol).font(.system(size: 13))
                .foregroundStyle(mode.isAlwaysApprove ? ComposerPalette.warning : Theme.muted)
                .frame(width: 30, height: 30).contentShape(Circle())
                .background(mode.isAlwaysApprove ? ComposerPalette.warning.opacity(0.14) : .clear, in: Circle())
        }
        .buttonStyle(ComposerControlStyle())
        .disabled(store.project == nil)
        .help("Permissions: \(mode.title). \(mode.detail)")
        .accessibilityLabel("Permissions: \(mode.title)")
        .popover(isPresented: $showPermissions, arrowEdge: .top) {
            ComposerPermissionMenu(current: mode, autoAvailable: features.autoModeAvailable) { choice in
                showPermissions = false
                features.setPermissionMode(choice)
            }.padding(6).frame(width: 320)
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        if !store.run.modes.isEmpty {
            Button { showModes.toggle() } label: {
                ComposerControlLabel(title: store.run.modes.first { $0.id == store.run.modeID }?.name ?? "Mode")
            }.buttonStyle(ComposerControlStyle()).fixedSize(horizontal: true, vertical: false)
                .disabled(optionsDisabled).help("Conversation mode").accessibilityLabel("Conversation mode")
                .popover(isPresented: $showModes, arrowEdge: .top) {
                    optionPopover("Conversation mode", options: store.run.modes, selected: store.run.modeID) { mode in
                        showModes = false
                        store.setMode(mode)
                    }
                }
        }
    }

    private func optionPopover(_ title: String, options: [ModelOption], selected: String,
                               name: @escaping (ModelOption) -> String = { $0.name },
                               choose: @escaping (ModelOption) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(12)
            ForEach(options) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        Text(name(option)).font(.system(size: 14))
                        Spacer()
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent).opacity(option.id == selected ? 1 : 0)
                    }
                }.buttonStyle(PopoverRowStyle()).disabled(optionsDisabled)
            }
        }.padding(6).frame(width: 240)
    }

    @ViewBuilder
    private var sendControls: some View {
        if store.run.isRunning && !isLiveCommand {
            if canQueue {
                circleButton(symbol: "stop.fill", primary: false, help: "Stop task · ⌘.", label: "Stop task") { store.cancel() }
                circleButton(symbol: features.followUpBehavior == .steer ? "arrow.turn.down.right" : "text.line.last.and.arrowtriangle.forward",
                             primary: true, help: features.followUpBehavior == .steer ? "Steer the running turn · ↵" : "Add to queue · ↵",
                             label: features.followUpBehavior == .steer ? "Steer the running turn" : "Add to queue") { submitDraft() }
            } else {
                circleButton(symbol: "stop.fill", primary: true, help: "Stop task · ⌘.", label: "Stop task") { store.cancel() }
            }
        } else {
            circleButton(symbol: "arrow.up", primary: true, enabled: canSend, help: "Send message", label: "Send message") {
                if canSend { submitDraft() }
            }
        }
    }

    private func circleButton(symbol: String, primary: Bool, enabled: Bool = true, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: primary ? 12 : 10, weight: .semibold)).foregroundStyle(primary ? Theme.canvas : Theme.ink)
                .frame(width: primary ? 30 : 26, height: primary ? 30 : 26)
                .background(primary ? (enabled ? Theme.ink : Theme.muted.opacity(0.35)) : Theme.hover, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled)
            .help(help)
            .accessibilityLabel(label)
    }
}

/// The permission choices shown from the composer.
struct ComposerPermissionMenu: View {
    let current: ComposerPermissionMode
    let autoAvailable: Bool
    var showsHeader = true
    let choose: (ComposerPermissionMode) -> Void
    @ObservedObject private var language = L10n.state

    private var modes: [ComposerPermissionMode] { [.ask] + (autoAvailable || current == .auto ? [.auto] : []) + [.alwaysApprove] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsHeader {
                Text(L10n.t("permissions", "Permissions")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            }
            ForEach(modes) { mode in
                let selected = mode == current || (mode == .ask && current == .standard)
                let warning = mode.isAlwaysApprove
                Button { choose(mode) } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: mode.symbol).font(.system(size: 14))
                            .foregroundStyle(warning ? ComposerPalette.warning : Theme.muted).frame(width: 19)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).font(.system(size: 14, weight: .medium)).foregroundStyle(warning ? ComposerPalette.warning : Theme.ink)
                            Text(mode.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .opacity(selected ? 1 : 0)
                    }
                }.buttonStyle(PopoverRowStyle())
                    .accessibilityLabel("\(mode.title). \(mode.detail)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Text("Takes effect right away, including in running tasks.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
    }
}

/// "Compacting conversation…" and its outcome, above the composer.
struct ComposerCompactionRow: View {
    let status: ComposerCompactionStatus
    var onStop: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            Text(status.message).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .running(let started) = status {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, context.date.timeIntervalSince(started))
                    Text(seconds < 60 ? "\(Int(seconds))s" : ComposerFormat.duration(seconds)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Button("Stop", action: onStop).buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                    .help("Cancel compaction")
            } else {
                IconButton(icon: "xmark", help: "Dismiss", size: 24, action: onDismiss)
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
        .frame(minHeight: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.7), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ComposerPalette.warning)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(Theme.muted)
        }
    }
}

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var onSubmit: () -> Void
    var onCommandKey: ((UInt16) -> Bool)? = nil
    /// Hands out the text view so dictation can insert at the cursor.
    var onTextView: ((NSTextView) -> Void)? = nil
    /// Pasted and dropped files and images; return true when they became attachments.
    var onPasteAttachments: ((NSPasteboard) -> Bool)? = nil
    var onDropAttachments: ((NSPasteboard) -> Bool)? = nil
    var onAttachmentDragChanged: ((Bool) -> Void)? = nil
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = SubmitTextView(); editor.delegate = context.coordinator; editor.onSubmit = onSubmit; editor.onCommandKey = onCommandKey
        editor.onPasteAttachments = onPasteAttachments; editor.onDropAttachments = onDropAttachments; editor.onAttachmentDragChanged = onAttachmentDragChanged
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 16); editor.textColor = .labelColor; editor.backgroundColor = .clear
        editor.textContainerInset = NSSize(width: 0, height: 7); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Message Crok")
        editor.placeholder = placeholder
        scroll.documentView = editor
        onTextView?(editor)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        context.coordinator.parent = self
        context.coordinator.isShowingDraft = true
        editor.showDraft(text)
        context.coordinator.isShowingDraft = false
        editor.placeholder = placeholder
        editor.onSubmit = onSubmit
        editor.onCommandKey = onCommandKey
        editor.onPasteAttachments = onPasteAttachments
        editor.onDropAttachments = onDropAttachments
        editor.onAttachmentDragChanged = onAttachmentDragChanged
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        /// Replacing a composition reports a change of its own, which must not overwrite the new draft.
        var isShowingDraft = false
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !isShowingDraft, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.committedString
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCommandKey: ((UInt16) -> Bool)?
    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    var onDropAttachments: ((NSPasteboard) -> Bool)?
    var onAttachmentDragChanged: ((Bool) -> Void)?
    /// Takes the keyboard focus when the app asks for the prompt (`grokFocusComposer`). The side
    /// chat's field is focused by its own requests instead.
    var followsComposerFocus = true
    private var focusObserver: NSObjectProtocol?
    /// Drawn by the text view rather than SwiftUI so it hides as soon as an input method starts
    /// composing, before anything is committed to the draft.
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            if isEmpty { needsDisplay = true }
        }
    }
    private var placeholderShown = true
    /// Marked text counts as content, so the placeholder is gone while an input method composes.
    var showsPlaceholder: Bool { isEmpty && !placeholder.isEmpty }
    /// Read from the storage's length: `string` copies all of the text, which a long paste makes a megabyte.
    private var isEmpty: Bool { (textStorage?.length ?? 0) == 0 }

    override var string: String {
        didSet { refreshPlaceholder() }
    }

    /// Shows the draft unless the editor already does. The draft holds committed text only, so marked
    /// text (pinyin before a character is chosen) is kept unless the draft itself changed.
    func showDraft(_ draft: String) {
        if hasMarkedText() {
            guard committedString != draft else { return }
            inputContext?.discardMarkedText()
        }
        if string != draft { string = draft }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshPlaceholder()
    }

    override func didChangeText() {
        super.didChangeText()
        refreshPlaceholder()
    }

    /// TextKit redraws only the glyphs that changed, which would leave part of the placeholder behind.
    private func refreshPlaceholder() {
        let shown = isEmpty
        guard shown != placeholderShown else { return }
        placeholderShown = shown
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder, let container = textContainer else { return }
        let origin = textContainerOrigin, padding = container.lineFragmentPadding
        let rect = NSRect(x: origin.x + padding, y: origin.y, width: max(0, bounds.width - origin.x * 2 - padding * 2), height: max(0, bounds.height - origin.y))
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: font ?? NSFont.systemFont(ofSize: 16), .foregroundColor: Theme.palette.mutedNS])
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + PromptAttachmentsModel.imageTypes
    }

    override func paste(_ sender: Any?) {
        if onPasteAttachments?(.general) == true { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropAttachments != nil, PromptAttachmentsModel.carriesAttachments(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        onAttachmentDragChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropAttachments != nil, PromptAttachmentsModel.carriesAttachments(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onAttachmentDragChanged?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onDropAttachments, PromptAttachmentsModel.carriesAttachments(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        onAttachmentDragChanged?(false)
        return onDropAttachments(sender.draggingPasteboard)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onAttachmentDragChanged?(false)
        super.concludeDragOperation(sender)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        guard followsComposerFocus else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: .grokFocusComposer, object: nil, queue: .main) { [weak self] _ in
            // Refocusing the focused editor would end a composition in progress.
            guard let self, self.window?.firstResponder !== self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty && onCommandKey?(event.keyCode) == true { return }
        if !hasMarkedText() && Self.startsNewLine(event) { insertNewline(nil); return }
        let multiline = UserDefaults.standard.bool(forKey: "composerMultiline")
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) && (!multiline || event.modifierFlags.contains(.command)) && !hasMarkedText() { onSubmit?() }
        else { super.keyDown(with: event) }
    }

    /// ⌃J and ⌥↵ start a new line, as they do in the terminal's prompt. The text system binds ⌃J
    /// to nothing, and the Return check after this one would send ⌥↵. ⇧↵ reaches the text view,
    /// which inserts a newline.
    static func startsNewLine(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control { return event.charactersIgnoringModifiers?.lowercased() == "j" }
        return modifiers == .option && (event.keyCode == 36 || event.keyCode == 76)
    }
}
