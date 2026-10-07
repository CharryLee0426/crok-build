import SwiftUI

/// Where a task stands, in the terminal dashboard's order: Needs input → Working → Idle →
/// Inactive → Completed → Failed.
enum DashboardGroup: Int, CaseIterable, Identifiable {
    case needsInput, working, idle, inactive, completed, failed
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .inactive: return "Inactive"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var tone: SessionTone {
        switch self {
        case .needsInput: return .orange
        case .working: return .accent
        case .idle, .inactive: return .muted
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// One task on the dashboard, reduced to plain values so rows re-render only when they change.
struct DashboardEntry: Identifiable, Equatable {
    let id: UUID
    var title: String
    var projectName: String
    var group: DashboardGroup
    var activity: String
    var preview: String
    var updatedAt: Date
    var isSelected: Bool
    var isRunning: Bool
    var isDeleting: Bool

    /// Needs input wins over everything; a connected task with background work (a monitor, a
    /// `/loop`, a workflow) stays Working after its turn ends, as in the terminal.
    static func classify(run: RunState?, isLive: Bool, isUnread: Bool, hasLiveWork: Bool) -> DashboardGroup {
        if let run, !run.approvals.isEmpty || !run.questions.isEmpty { return .needsInput }
        if run?.isRunning == true || run?.isConfiguring == true || (isLive && hasLiveWork) { return .working }
        if run?.phase == "Needs attention" { return .failed }
        if isUnread { return .completed }
        return isLive ? .idle : .inactive
    }

    @MainActor
    static func build(store: AppStore, boards: [UUID: SessionTaskBoard], deleting: Set<UUID>) -> [DashboardEntry] {
        let projects = Dictionary(store.state.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return store.state.conversations.filter { !$0.isArchived }.map { task in
            let run = store.runs[task.id]
            let isLive = store.clients[task.id] != nil && store.loaded.contains(task.id)
            let board = boards[task.id] ?? SessionTaskBoard()
            let group = classify(run: run, isLive: isLive, isUnread: store.unreadConversationIDs.contains(task.id), hasLiveWork: board.hasLiveWork)
            return DashboardEntry(id: task.id, title: task.title, projectName: projects[task.projectID] ?? "",
                                  group: group, activity: activity(group: group, run: run, board: board),
                                  preview: preview(task: task, run: run), updatedAt: task.updatedAt,
                                  isSelected: store.state.selectedConversationID == task.id,
                                  isRunning: run?.isRunning == true, isDeleting: deleting.contains(task.id))
        }.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group.rawValue < rhs.group.rawValue }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func activity(group: DashboardGroup, run: RunState?, board: SessionTaskBoard) -> String {
        switch group {
        case .needsInput: return "Awaiting your input"
        case .working:
            if run?.isRunning == true || run?.isConfiguring == true { return run?.phase ?? "Working" }
            return liveWorkSummary(board)
        case .idle: return "Idle"
        case .inactive: return "Not connected"
        case .completed: return "Finished"
        case .failed: return "Needs attention"
        }
    }

    /// "1 monitor · 2 loops still running".
    static func liveWorkSummary(_ board: SessionTaskBoard) -> String {
        let running = board.background.filter(\.isRunning)
        let monitors = running.filter(\.isMonitor).count, tasks = running.count - monitors
        let workflows = board.workflows.filter(\.isActive).count
        var parts: [String] = []
        func add(_ count: Int, _ noun: String) { if count > 0 { parts.append("\(count) \(noun)\(count == 1 ? "" : "s")") } }
        add(workflows, "workflow"); add(tasks, "task"); add(monitors, "monitor"); add(board.scheduled.count, "loop")
        return parts.isEmpty ? "Working" : parts.joined(separator: " · ") + " still running"
    }

    /// What the task needs, or the last thing Crok said.
    static func preview(task: Conversation, run: RunState?) -> String {
        if let approval = run?.approvals.first { return approval.title }
        if let question = run?.questions.first?.questions.first { return question.question }
        if let reply = task.messages.last(where: { $0.kind == .assistant }), let line = lastLine(reply.text) { return line }
        if let prompt = task.messages.last(where: { $0.kind == .user }), let line = lastLine(prompt.text) { return "You: " + line }
        return ""
    }

    private static func lastLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }
            // Show the line as it reads, without Markdown punctuation.
            trimmed = MarkdownParser.plainText(MarkdownParser.parse(String(trimmed.prefix(400)))).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(240)) }
        }
        return nil
    }
}

/// `/dashboard`: every task across projects, grouped by what it needs from you.
struct DashboardSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionFeatureModel
    @State private var search = ""
    @State private var collapsed: Set<DashboardGroup> = [.inactive]
    @State private var showsAllInactive = false
    @State private var editor: DashboardEditor?

    private static let inactiveLimit = 20

    var body: some View {
        let entries = DashboardEntry.build(store: store, boards: sessions.boards, deleting: sessions.deleting)
        let visible = search.isEmpty ? entries : entries.filter { "\($0.title) \($0.projectName) \($0.preview)".localizedCaseInsensitiveContains(search) }
        DesktopPanel(title: "Dashboard", subtitle: "Switch between your tasks and see which need you.", width: 780, height: 660, onClose: close) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    NativeSearchField(text: $search, placeholder: "Search tasks", onEscape: close).frame(height: 40)
                    summaryChips(entries)
                }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
                Divider()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(DashboardGroup.allCases) { group in
                                let rows = visible.filter { $0.group == group }
                                if !rows.isEmpty { section(group, rows: rows, now: context.date) }
                            }
                            if visible.isEmpty {
                                SessionEmptyState(symbol: search.isEmpty ? "person.2" : "magnifyingglass",
                                                  title: search.isEmpty ? "No tasks yet." : "No matching tasks.",
                                                  detail: search.isEmpty ? "Start a task and it will appear here." : nil)
                            }
                        }.padding(.horizontal, 24).padding(.vertical, 14)
                    }
                }
            }
        } footer: {
            Text(footerText(entries)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Resume…") { store.sheet = .resume }.disabled(store.project == nil)
            Button("New task") { store.sheet = nil; store.newTask() }
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }

    private func summaryChips(_ entries: [DashboardEntry]) -> some View {
        let count = { (group: DashboardGroup) in entries.filter { $0.group == group }.count }
        return HStack(spacing: 6) {
            if count(.needsInput) > 0 { SessionStatusPill(text: "\(count(.needsInput)) need input", tone: .orange) }
            if count(.working) > 0 { SessionStatusPill(text: "\(count(.working)) working", tone: .accent) }
            if count(.idle) > 0 { SessionStatusPill(text: "\(count(.idle)) idle", tone: .muted) }
        }.fixedSize()
    }

    private func footerText(_ entries: [DashboardEntry]) -> String {
        let projects = Set(entries.map(\.projectName)).count
        return "\(entries.count) task\(entries.count == 1 ? "" : "s") in \(projects) project\(projects == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func section(_ group: DashboardGroup, rows: [DashboardEntry], now: Date) -> some View {
        let isCollapsed = collapsed.contains(group) && search.isEmpty
        Button {
            FoldMotion.toggle { if collapsed.remove(group) == nil { collapsed.insert(group) } }
        } label: {
            HStack(spacing: 6) {
                Text(group.title)
                Text("\(rows.count)").monospacedDigit().opacity(0.75)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            .padding(.leading, 12).padding(.top, 10).padding(.bottom, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(rows.count)")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        if !isCollapsed {
            let limited = group == .inactive && !showsAllInactive && search.isEmpty ? Array(rows.prefix(Self.inactiveLimit)) : rows
            ForEach(limited) { entry in
                VStack(spacing: 0) {
                    DashboardRow(entry: entry, now: now, actions: actions(for: entry)).equatable()
                    if editor?.id == entry.id { editorView(for: entry) }
                }
            }
            if limited.count < rows.count {
                Button("Show \(rows.count - limited.count) more") { showsAllInactive = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.leading, 4).padding(.vertical, 4)
            }
        }
    }

    private func actions(for entry: DashboardEntry) -> DashboardRow.Actions {
        DashboardRow.Actions(
            open: { sessions.open(entry.id) },
            stop: { sessions.stopTask(entry.id) },
            reply: { toggleEditor(.reply, for: entry) },
            rename: { toggleEditor(.rename, for: entry) },
            delete: { sessions.requestDelete(entry.id) })
    }

    private func toggleEditor(_ mode: DashboardEditor.Mode, for entry: DashboardEntry) {
        if editor?.id == entry.id && editor?.mode == mode { editor = nil }
        else { editor = DashboardEditor(id: entry.id, mode: mode, text: mode == .rename ? entry.title : "") }
    }

    private func editorView(for entry: DashboardEntry) -> some View {
        let mode = editor?.mode ?? .reply
        let text = Binding(get: { editor?.text ?? "" }, set: { editor?.text = $0 })
        let submit = {
            guard let current = editor, !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            editor = nil
            if current.mode == .reply { sessions.reply(to: entry.id, text: current.text) }
            else { sessions.applyRename(id: entry.id, title: current.text) }
        }
        return HStack(alignment: .bottom, spacing: 10) {
            DesktopTextField(mode == .reply ? "Reply to this task" : "Task title", text: text,
                             symbol: mode == .reply ? "arrowshape.turn.up.left" : "pencil")
                .onSubmit(submit)
            Button("Cancel") { editor = nil }
            // A reply to a working task waits in its queue, like one typed in the composer.
            Button(mode == .rename ? "Rename" : entry.isRunning ? "Queue" : "Send", action: submit)
                .disabled((editor?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    private func close() { store.sheet = nil }
}

struct DashboardEditor: Equatable {
    enum Mode: Equatable { case reply, rename }
    let id: UUID
    let mode: Mode
    var text: String
}

/// The terminal's state glyphs: a spinner while working, a filled dot for states that want
/// attention, and a hollow circle for idle and inactive tasks.
struct DashboardStateGlyph: View {
    let group: DashboardGroup

    var body: some View {
        Group {
            switch group {
            case .working: ProgressView().controlSize(.mini).scaleEffect(0.75)
            case .idle, .inactive: Circle().strokeBorder(Theme.muted, lineWidth: 1.2)
            default: Circle().fill(group.tone.color)
            }
        }
        .frame(width: 8, height: 8).frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct DashboardRow: View, Equatable {
    struct Actions {
        let open: () -> Void
        let stop: () -> Void
        let reply: () -> Void
        let rename: () -> Void
        let delete: () -> Void
    }

    let entry: DashboardEntry
    let now: Date
    let actions: Actions
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && RelativeTime.short(lhs.entry.updatedAt, now: lhs.now) == RelativeTime.short(rhs.entry.updatedAt, now: rhs.now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashboardStateGlyph(group: entry.group).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    if entry.isSelected { SessionStatusPill(text: "On screen", tone: .accent) }
                    Spacer(minLength: 6)
                    Text(RelativeTime.short(entry.updatedAt, now: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    if !entry.projectName.isEmpty {
                        Label(entry.projectName, systemImage: "folder").labelStyle(DashboardCaptionLabelStyle())
                        Text("·")
                    }
                    Text(entry.activity).foregroundStyle(entry.group == .working || entry.group == .idle || entry.group == .inactive ? Theme.muted : entry.group.tone.color)
                }.font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                if !entry.preview.isEmpty {
                    Text(entry.preview).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                }
            }
            HStack(spacing: 0) {
                IconButton(icon: "arrow.up.right.square", help: "Open task", size: 26, action: actions.open)
                if entry.isRunning { IconButton(icon: "stop.circle", help: "Stop", size: 26, action: actions.stop) }
                else { IconButton(icon: "arrowshape.turn.up.left", help: "Reply", size: 26, action: actions.reply) }
                IconButton(icon: "pencil", help: "Rename", size: 26, action: actions.rename)
                IconButton(icon: "trash", help: "Delete", size: 26, action: actions.delete).disabled(entry.isDeleting)
            }.opacity(hovered || entry.isSelected ? 1 : 0.55)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hovered ? Theme.hover.opacity(0.55) : entry.group == .needsInput ? Color.orange.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: actions.open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.group.title), \(entry.activity)")
    }
}

private struct DashboardCaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 9)); configuration.title.lineLimit(1).truncationMode(.middle) }
    }
}
