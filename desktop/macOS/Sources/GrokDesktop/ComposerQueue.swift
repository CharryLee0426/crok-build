import AppKit
import SwiftUI

/// A prompt the desktop holds until the task's running turn ends (`/queue`).
struct ComposerQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    var text: String
    var attachments: [PromptAttachment]

    init(id: UUID = UUID(), text: String, attachments: [PromptAttachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }

    /// The first line, and how many more follow it, as the terminal's queue rows show them.
    var firstLine: String { text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text }
    var extraLineCount: Int { max(0, text.split(separator: "\n", omittingEmptySubsequences: false).count - 1) }
    var extraLinesLabel: String? { extraLineCount == 0 ? nil : "+\(extraLineCount) more line\(extraLineCount == 1 ? "" : "s")" }
    /// `/compact` runs natively after the turn instead of being sent as a prompt.
    var compactInstructions: String? {
        guard let command = SlashCommand.split(text), command.name == "compact" else { return nil }
        return command.arguments
    }
}

/// Every task's queued prompts, in send order, and which queues wait for the user after a Stop.
struct ComposerQueueBook: Equatable {
    private(set) var entries: [UUID: [ComposerQueuedPrompt]] = [:]
    /// Queues that do not drain on their own: the user stopped the turn they were waiting for.
    private(set) var paused: Set<UUID> = []

    func items(_ conversationID: UUID?) -> [ComposerQueuedPrompt] { conversationID.flatMap { entries[$0] } ?? [] }
    func isPaused(_ conversationID: UUID) -> Bool { paused.contains(conversationID) }

    @discardableResult
    mutating func append(_ text: String, attachments: [PromptAttachment] = [], to conversationID: UUID) -> ComposerQueuedPrompt {
        let entry = ComposerQueuedPrompt(text: text, attachments: attachments)
        entries[conversationID, default: []].append(entry)
        return entry
    }

    @discardableResult
    mutating func remove(_ entryID: UUID, from conversationID: UUID) -> ComposerQueuedPrompt? {
        guard let index = entries[conversationID]?.firstIndex(where: { $0.id == entryID }) else { return nil }
        let entry = entries[conversationID]?.remove(at: index)
        prune(conversationID)
        return entry
    }

    /// Replaces an entry's text; an empty edit removes it, unless the entry carries attachments.
    mutating func update(_ entryID: UUID, text: String, in conversationID: UUID) {
        guard let index = entries[conversationID]?.firstIndex(where: { $0.id == entryID }) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entries[conversationID]?[index].attachments.isEmpty != false {
            remove(entryID, from: conversationID)
        } else { entries[conversationID]?[index].text = text }
    }

    /// Moves an entry up (negative) or down (positive), clamped to the queue.
    mutating func move(_ entryID: UUID, by offset: Int, in conversationID: UUID) {
        guard var list = entries[conversationID], let index = list.firstIndex(where: { $0.id == entryID }) else { return }
        let target = min(max(0, index + offset), list.count - 1)
        guard target != index else { return }
        list.insert(list.remove(at: index), at: target)
        entries[conversationID] = list
    }

    mutating func moveToFront(_ entryID: UUID, in conversationID: UUID) {
        guard let index = entries[conversationID]?.firstIndex(where: { $0.id == entryID }) else { return }
        move(entryID, by: -index, in: conversationID)
    }

    mutating func popNext(for conversationID: UUID) -> ComposerQueuedPrompt? {
        guard let first = entries[conversationID]?.first else { return nil }
        entries[conversationID]?.removeFirst()
        prune(conversationID)
        return first
    }

    mutating func pause(_ conversationID: UUID) { paused.insert(conversationID) }
    mutating func resume(_ conversationID: UUID) { paused.remove(conversationID) }

    mutating func clear(_ conversationID: UUID) {
        entries.removeValue(forKey: conversationID)
        paused.remove(conversationID)
    }

    private mutating func prune(_ conversationID: UUID) {
        if entries[conversationID]?.isEmpty == true {
            entries.removeValue(forKey: conversationID)
            paused.remove(conversationID)
        }
    }

    /// Whether a queue may send its next prompt now. A queue drains on its own only after a turn
    /// ends normally ("Ready"); after a Stop or an error it waits, unless the user asked to send.
    static func mayDispatch(isRunning: Bool, phase: String, paused: Bool, sendNow: Bool) -> Bool {
        guard !isRunning else { return false }
        if sendNow { return true }
        return !paused && phase == "Ready"
    }
}

/// The harness's own queue for a session, from `x.ai/queue/changed` (camelCase `QueueChanged`).
struct HarnessPromptQueue: Equatable {
    struct Entry: Identifiable, Equatable {
        var id: String
        var version: Int
        var owner: String?
        var kind: String
        var text: String
        var position: Int
    }
    var entries: [Entry] = []
    var runningPromptID: String?
    var runningText: String?

    init(entries: [Entry] = [], runningPromptID: String? = nil, runningText: String? = nil) {
        self.entries = entries
        self.runningPromptID = runningPromptID
        self.runningText = runningText
    }

    init(_ params: [String: Any]) {
        runningPromptID = params["runningPromptId"] as? String
        runningText = params["runningText"] as? String
        entries = (params["entries"] as? [[String: Any]] ?? []).compactMap { value -> Entry? in
            guard let id = value["id"] as? String, id != runningPromptID else { return nil }
            let combined = (value["combinedTexts"] as? [String] ?? []).filter { !$0.isEmpty }
            let text = combined.count >= 2 ? combined.joined(separator: "\n") : value["text"] as? String ?? ""
            return Entry(id: id, version: Self.integer(value["version"]) ?? 0, owner: value["owner"] as? String,
                         kind: value["kind"] as? String ?? "prompt", text: text, position: Self.integer(value["position"]) ?? 0)
        }.sorted { $0.position < $1.position }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

// MARK: - Queue panel

/// Queued prompts for the selected task, directly above the composer.
struct ComposerQueuePanel: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var composer: ComposerFeatureModel
    let conversationID: UUID
    let isRunning: Bool
    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var highlighted = false
    @FocusState private var editorFocused: Bool

    private var entries: [ComposerQueuedPrompt] { composer.queue.items(conversationID) }
    private var harnessEntries: [HarnessPromptQueue.Entry] { composer.harnessQueues[conversationID]?.entries ?? [] }
    private var paused: Bool { composer.queue.isPaused(conversationID) }

    var body: some View {
        Fold(isExpanded: $composer.queuePanelExpanded) { toggle, isOpen in
            header(toggle: toggle, isOpen: isOpen)
        } content: {
            Divider().opacity(0.6)
            // A short queue shows every row; a long one scrolls so the transcript keeps its room.
            if entries.count + harnessEntries.count <= 4 && editingID == nil {
                rows
            } else {
                ScrollView { rows }.frame(height: 216)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(highlighted ? Theme.accent.opacity(0.7) : Theme.line.opacity(0.7), lineWidth: highlighted ? 1.5 : 0.5))
        .onChange(of: composer.queueFocusRequest) { _, _ in flash() }
        // An entry left mid-edit must not stay held forever.
        .onDisappear { if let editingID { composer.releaseQueued(editingID, in: conversationID) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued prompts")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if editingID == entry.id { editor(entry) } else { row(entry, index: index) }
            }
            if !harnessEntries.isEmpty {
                Text("Queued in the Crok session").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).padding(.top, entries.isEmpty ? 2 : 8).padding(.bottom, 2)
                ForEach(harnessEntries) { entry in harnessRow(entry) }
            }
        }.padding(6)
    }

    private func header(toggle: @escaping () -> Void, isOpen: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.line.last.and.arrowtriangle.forward").font(.system(size: 13)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Queued").font(.system(size: 13, weight: .semibold))
            Text("\(entries.count + harnessEntries.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.vertical, 1.5).background(Theme.hover, in: Capsule())
            Text(statusText).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 4)
            if paused && !isRunning && !entries.isEmpty {
                Button("Send next") { composer.resumeQueue(conversationID) }
                    .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).controlSize(.small)
            }
            if !entries.isEmpty {
                IconButton(icon: "trash", help: "Clear queued prompts", size: 26) { composer.clearQueue(conversationID) }
            }
            IconButton(icon: isOpen ? "chevron.down" : "chevron.up", help: isOpen ? "Collapse queue" : "Expand queue", size: 26, action: toggle)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
    }

    private var statusText: String {
        if entries.isEmpty { return "Held by the Crok session" }
        if isRunning { return "Sends when Crok finishes" }
        guard paused else { return "Sending…" }
        return store.runs[conversationID]?.phase == "Stopped" ? "Paused because the turn was stopped" : "Paused because the last turn didn't finish"
    }

    private func row(_ entry: ComposerQueuedPrompt, index: Int) -> some View {
        ComposerQueueRow(index: index, entry: entry, isFirst: index == 0, isLast: index == entries.count - 1, canSendNow: store.project != nil) { action in
            switch action {
            case .edit:
                if let editing = editingID { composer.releaseQueued(editing, in: conversationID) }
                composer.holdQueued(entry.id)
                editText = entry.text; editingID = entry.id
                DispatchQueue.main.async { editorFocused = true }
            case .moveUp: composer.moveQueued(entry.id, by: -1, in: conversationID)
            case .moveDown: composer.moveQueued(entry.id, by: 1, in: conversationID)
            case .copy: composer.copyToPasteboard(entry.text)
            case .sendNow: composer.sendQueuedNow(entry.id, in: conversationID)
            case .delete: composer.removeQueued(entry.id, from: conversationID)
            }
        }
    }

    private func editor(_ entry: ComposerQueuedPrompt) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Queued prompt", text: $editText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...8)
                .focused($editorFocused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .modifier(InputSurface(focused: editorFocused))
                .onSubmit { save(entry) }
                .onExitCommand { cancelEditing(entry) }
            HStack(spacing: 8) {
                Text("↵ Save  ·  esc Cancel").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { cancelEditing(entry) }
                Button("Save") { save(entry) }.disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).controlSize(.small)
        }.padding(8).background(Theme.hover.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func save(_ entry: ComposerQueuedPrompt) {
        composer.updateQueued(entry.id, text: editText, in: conversationID)
        editingID = nil
    }

    private func cancelEditing(_ entry: ComposerQueuedPrompt) {
        composer.releaseQueued(entry.id, in: conversationID)
        editingID = nil
    }

    private func harnessRow(_ entry: HarnessPromptQueue.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind == "prompt" ? "text.bubble" : "terminal").font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ComposerQueuedPrompt(text: entry.text).firstLine).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Text([entry.owner.map { "From \($0)" }, ComposerQueuedPrompt(text: entry.text).extraLinesLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            IconButton(icon: "doc.on.doc", help: "Copy", size: 24) { composer.copyToPasteboard(entry.text) }
            IconButton(icon: "xmark", help: "Remove from queue", size: 24) { composer.removeHarnessQueued(entry, conversationID: conversationID) }
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func flash() {
        composer.queuePanelExpanded = true
        highlighted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { highlighted = false }
    }
}

enum ComposerQueueAction { case edit, moveUp, moveDown, copy, sendNow, delete }

/// One queued prompt: its position, first line, and hover actions.
struct ComposerQueueRow: View {
    let index: Int
    let entry: ComposerQueuedPrompt
    let isFirst: Bool
    let isLast: Bool
    let canSendNow: Bool
    let perform: (ComposerQueueAction) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("#\(index + 1)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.muted).frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if entry.compactInstructions != nil {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                    if !entry.attachments.isEmpty {
                        Label("\(entry.attachments.count)", systemImage: "paperclip").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                            .labelStyle(.titleAndIcon)
                            .help(entry.attachments.map(\.name).joined(separator: ", "))
                            .accessibilityLabel("\(entry.attachments.count) attachments")
                    }
                    Text(entry.firstLine.isEmpty ? (entry.attachments.isEmpty ? " " : entry.attachments.map(\.name).joined(separator: ", ")) : entry.firstLine)
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                }
                if let more = entry.extraLinesLabel { Text(more).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                IconButton(icon: "paperplane", help: "Send now (stops the current turn)", size: 26) { perform(.sendNow) }.disabled(!canSendNow)
                IconButton(icon: "pencil", help: "Edit", size: 26) { perform(.edit) }
                IconButton(icon: "chevron.up", help: "Move up", size: 26) { perform(.moveUp) }.disabled(isFirst)
                IconButton(icon: "chevron.down", help: "Move down", size: 26) { perform(.moveDown) }.disabled(isLast)
                IconButton(icon: "doc.on.doc", help: "Copy", size: 26) { perform(.copy) }
                IconButton(icon: "xmark", help: "Remove from queue", size: 26) { perform(.delete) }
            }.opacity(hovered ? 1 : 0.0001)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hovered ? Theme.hover.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { perform(.edit) }
        .contextMenu {
            Button("Send Now") { perform(.sendNow) }.disabled(!canSendNow)
            Button("Edit") { perform(.edit) }
            Divider()
            Button("Move Up") { perform(.moveUp) }.disabled(isFirst)
            Button("Move Down") { perform(.moveDown) }.disabled(isLast)
            Divider()
            Button("Copy") { perform(.copy) }
            Button("Remove", role: .destructive) { perform(.delete) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued prompt \(index + 1): \(entry.text)")
        .accessibilityAction(named: "Send now") { perform(.sendNow) }
        .accessibilityAction(named: "Edit") { perform(.edit) }
        .accessibilityAction(named: "Move up") { perform(.moveUp) }
        .accessibilityAction(named: "Move down") { perform(.moveDown) }
        .accessibilityAction(named: "Remove") { perform(.delete) }
    }
}
