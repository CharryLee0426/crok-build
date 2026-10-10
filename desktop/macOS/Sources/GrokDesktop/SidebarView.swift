import SwiftUI

/// Codex-style navigation: project folders that collect their tasks, newest first, and a
/// folded Recents section that lists every project's tasks together. Folders, the tasks in a
/// folder, and pinned tasks can be dragged into the user's own order.
struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    /// Observed here, not through the store, so typing a search redraws only the sidebar.
    @EnvironmentObject var sidebarSearch: SidebarSearch
    /// Folders and Recents show a few tasks until the reader asks for the rest.
    @State private var expandedLists: Set<String> = []
    private static let folderLimit = 5
    private static let recentsLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                GrokMark(size: 26)
                Text("Crok").font(.system(size: 20, weight: .semibold))
                Text("BUILD").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
            VStack(spacing: 1) {
                SidebarNavigationRow(title: "New task", icon: "square.and.pencil", shortcut: "⌘N") { store.newTask() }
                SidebarNavigationRow(title: "Search", icon: "magnifyingglass", shortcut: "⌘K", isActive: store.showSearch) { store.showSearch.toggle() }
                SidebarNavigationRow(title: "Commands", icon: "command", shortcut: "⇧⌘P") { store.showCommandPalette = true }
                SidebarNavigationRow(title: "Skills & tools", icon: "square.grid.2x2") { store.featurePanel = .skills }
            }.padding(.horizontal, 10)
            if store.showSearch {
                NativeSearchField(text: $sidebarSearch.text, placeholder: store.showArchived ? "Search archived tasks" : "Search all tasks", onEscape: { store.showSearch = false })
                    .frame(height: 36).padding(.horizontal, 12).padding(.top, 8)
            }
            // Relative times ("5m", "2h") advance without any task changing.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    // Not lazy: the same task can appear under Pinned, its folder, and Recents.
                    VStack(alignment: .leading, spacing: 1) {
                        if !store.search.isEmpty { searchResults(now: context.date) }
                        else if store.showArchived { archived(now: context.date) }
                        else { workspace(now: context.date) }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            VStack(spacing: 1) {
                SidebarNavigationRow(title: store.showArchived ? "Back to projects" : "Archived", icon: store.showArchived ? "chevron.backward" : "archivebox",
                                     isActive: store.showArchived) { store.showArchived.toggle() }
                SidebarNavigationRow(title: "Settings", icon: "gearshape", shortcut: "⌘,") { store.showSettings = true }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(alignment: .top) { Theme.line.opacity(0.5).frame(height: 0.5) }
            if store.binaryPath.isEmpty {
                Label("Crok engine unavailable", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .help("The bundled Crok runtime is missing. Reinstall Crok Desktop.")
            }
        }.background { SidebarMaterial().ignoresSafeArea() }
    }

    // MARK: Sections

    @ViewBuilder
    private func workspace(now: Date) -> some View {
        let pinned = store.pinnedConversations.map(\.listing)
        if !pinned.isEmpty {
            SidebarSectionHeader(title: "Pinned")
                .contextMenu { sortMenu(.pinned) }
            ReorderableStack(items: pinned, onMove: { store.moveTask($0, to: $1, in: .pinned) }) { task, handle in
                taskRow(task, now: now, showsProject: true, indent: 8).modifier(handle)
            }
        }
        SidebarSectionHeader(title: "Projects") {
            if store.syncing {
                ProgressView().controlSize(.mini).frame(width: 24, height: 24).help("Importing harness tasks…")
            } else {
                IconButton(icon: "arrow.triangle.2.circlepath", help: "Import tasks from the harness for every project", size: 24) {
                    store.syncHistory(projects: store.state.projects)
                }.disabled(store.state.projects.isEmpty)
            }
            IconButton(icon: "folder.badge.plus", help: "Open project · ⇧⌘O", size: 24) { store.addProject() }
        }
        if store.state.projects.isEmpty {
            Button { store.addProject() } label: {
                Label("Open your first project", systemImage: "plus").font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 7)
            }.buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
        // A folder moves by its header; its tasks move within it.
        ReorderableStack(items: store.state.projects, onMove: { store.moveProject($0, to: $1) }) { project, handle in
            let tasks = store.conversations(inProject: project.id).map(\.listing)
            let expanded = Binding(get: { store.isProjectExpanded(project.id) },
                                   set: { if $0 != store.isProjectExpanded(project.id) { store.toggleProjectExpanded(project.id) } })
            Fold(isExpanded: expanded, spacing: 1) { toggle, isOpen in
                ProjectFolderRow(store: store, project: project, isExpanded: isOpen,
                                 isActive: store.state.selectedProjectID == project.id && store.state.selectedConversationID == nil,
                                 runningCount: tasks.filter { store.runs[$0.id]?.isRunning == true }.count,
                                 hasManualOrder: store.hasManualOrder(.project(project.id)), onToggle: toggle)
                    .equatable()
                    .modifier(handle)
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    limited(tasks, key: project.id.uuidString, limit: Self.folderLimit, indent: 30, reorder: .project(project.id)) {
                        taskRow($0, now: now, showsProject: false, indent: 30)
                    }
                    if tasks.isEmpty {
                        Text("No tasks yet").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .padding(.leading, 30).padding(.vertical, 5)
                    }
                }
            }
        }
        let recents = store.recentConversations.map(\.listing)
        Fold(isExpanded: $store.recentsExpanded, spacing: 1) { toggle, isOpen in
            SidebarSectionHeader(title: "Recents", count: recents.count, isExpanded: isOpen, onToggle: toggle)
                .padding(.top, 6)
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                limited(recents, key: "recents", limit: Self.recentsLimit, indent: 8) { taskRow($0, now: now, showsProject: true, indent: 8) }
                if recents.isEmpty { emptyNote("Your tasks will appear here.") }
            }
        }
    }

    @ViewBuilder
    private func archived(now: Date) -> some View {
        let tasks = store.archivedConversations.map(\.listing)
        SidebarSectionHeader(title: "Archived")
        ForEach(tasks) { taskRow($0, now: now, showsProject: true, indent: 8) }
        if tasks.isEmpty { emptyNote("Archived tasks will appear here.") }
    }

    @ViewBuilder
    private func searchResults(now: Date) -> some View {
        let tasks = store.searchResults.map(\.listing)
        SidebarSectionHeader(title: store.showArchived ? "Archived results" : "Results", count: tasks.count)
        ForEach(tasks) { taskRow($0, now: now, showsProject: true, indent: 8) }
        if tasks.isEmpty { emptyNote("No matching tasks.") }
    }

    /// The first few tasks of a list, and a button for the rest. A list with an order can be
    /// rearranged by dragging; the shown tasks are its first ones, so their places are its own.
    @ViewBuilder
    private func limited<Row: View>(_ tasks: [Conversation], key: String, limit: Int, indent: CGFloat, reorder: SidebarTaskList? = nil,
                                    @ViewBuilder row: @escaping (Conversation) -> Row) -> some View {
        let showsAll = expandedLists.contains(key)
        let shown = showsAll ? tasks : Array(tasks.prefix(limit))
        if let reorder {
            ReorderableStack(items: shown, onMove: { store.moveTask($0, to: $1, in: reorder) }) { task, handle in
                row(task).modifier(handle)
            }
        } else {
            ForEach(shown) { row($0) }
        }
        if tasks.count > limit {
            Button {
                FoldMotion.toggle { if showsAll { expandedLists.remove(key) } else { expandedLists.insert(key) } }
            } label: {
                Text(showsAll ? "Show less" : "Show \(tasks.count - limit) more")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.leading, indent).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func taskRow(_ task: Conversation, now: Date, showsProject: Bool, indent: CGFloat) -> some View {
        let run = store.runs[task.id]
        return TaskSidebarRow(store: store, task: task,
                              projectName: showsProject ? store.state.projects.first { $0.id == task.projectID }?.name : nil,
                              indent: indent, now: now,
                              isRunning: run?.isRunning == true, isConfiguring: run?.isConfiguring == true,
                              isSelected: task.id == store.state.selectedConversationID,
                              needsApproval: !(run?.approvals.isEmpty ?? true) || !(run?.questions.isEmpty ?? true),
                              isUnread: store.unreadConversationIDs.contains(task.id))
            .equatable()
    }

    @ViewBuilder
    private func sortMenu(_ list: SidebarTaskList) -> some View {
        Button("Sort by Recent Activity", systemImage: "clock.arrow.circlepath") { FoldMotion.toggle { store.sortByRecentActivity(list) } }
            .disabled(!store.hasManualOrder(list))
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 6)
    }
}

enum RelativeTime {
    /// Compact ages in the style of Codex: now, 5m, 3h, 2d, 3w, 4mo, 2y.
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3_600.0, day = 86_400.0
        if seconds < minute { return "now" }
        if seconds < hour { return "\(Int(seconds / minute))m" }
        if seconds < day { return "\(Int(seconds / hour))h" }
        if seconds < 7 * day { return "\(Int(seconds / day))d" }
        if seconds < 30 * day { return "\(Int(seconds / (7 * day)))w" }
        if seconds < 365 * day { return "\(max(1, Int(seconds / (30 * day))))mo" }
        return "\(Int(seconds / (365 * day)))y"
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let icon: String
    var shortcut = ""
    var isActive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title)
                Spacer()
                if hovered && !shortcut.isEmpty { Text(shortcut).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            .background(isActive ? Theme.hover : hovered ? Theme.hover.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    var count: Int? = nil
    /// Set for a section that folds, with the action that folds it.
    var isExpanded: Bool? = nil
    var onToggle: () -> Void = {}
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovered = false

    init(title: String, count: Int? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.count = count
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 4) {
            if let isExpanded {
                Button(action: onToggle) {
                    HStack(spacing: 5) {
                        Text(title)
                        if let count, count > 0, !isExpanded { Text("\(count)").monospacedDigit().opacity(0.8) }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(hovered || !isExpanded ? 1 : 0)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Fold \(title)" : "Show \(title)")
            } else {
                Text(title)
                if let count { Text("\(count)").monospacedDigit().opacity(0.8) }
                Spacer(minLength: 0)
            }
            accessory()
        }
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
        .padding(.leading, 8).padding(.top, 14).padding(.bottom, 2)
        .frame(minHeight: 28)
        .onHover { hovered = $0 }
    }
}

private extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: String, count: Int? = nil, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.init(title: title, count: count)
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }
}

/// Takes plain values rather than observing the store, so streamed output does not
/// re-render every folder.
private struct ProjectFolderRow: View, Equatable {
    let store: AppStore
    let project: Project
    let isExpanded: Bool
    let isActive: Bool
    let runningCount: Int
    /// Whether the folder's tasks are in an order the user dragged them into.
    let hasManualOrder: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.isExpanded == rhs.isExpanded && lhs.isActive == rhs.isActive && lhs.runningCount == rhs.runningCount
            && lhs.hasManualOrder == rhs.hasManualOrder
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Group {
                        if hovered {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        } else {
                            Image(systemName: "folder").font(.system(size: 13))
                        }
                    }
                    .foregroundStyle(Theme.muted).frame(width: 18)
                    Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !hovered && !isExpanded && runningCount > 0 {
                        ProgressView().controlSize(.mini).help("\(runningCount) running")
                    }
                }.padding(.leading, 8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.path)
            .accessibilityLabel("\(project.name) project")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if hovered {
                IconButton(icon: "square.and.pencil", help: "New task in \(project.name)", size: 24) { store.selectProject(project.id) }
                Menu { projectActions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Theme.muted).help("Project actions").accessibilityLabel("Actions for \(project.name)")
            }
        }
        .padding(.trailing, 4)
        .background(isActive ? Theme.hover.opacity(0.8) : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
        .contextMenu { projectActions }
    }

    @ViewBuilder
    private var projectActions: some View {
        Button("New Task", systemImage: "square.and.pencil") { store.selectProject(project.id) }
        Button("Import Harness Tasks", systemImage: "arrow.triangle.2.circlepath") { store.syncHistory(projects: [project]) }
            .disabled(store.syncing)
        // Dragging a task puts the folder in the user's order; this goes back to newest first.
        Button("Sort Tasks by Recent Activity", systemImage: "clock.arrow.circlepath") {
            FoldMotion.toggle { store.sortByRecentActivity(.project(project.id)) }
        }.disabled(!hasManualOrder)
        Divider()
        Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        Button("Open Terminal", systemImage: "terminal") { store.openTerminal(projectID: project.id) }
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        // Only the app's record of the project goes; its folder stays on disk.
        Button("Remove Project…", systemImage: "trash", role: .destructive) { store.requestRemoveProject(project.id) }
            .disabled(runningCount > 0)
    }
}

/// Rows take plain values rather than observing the store, so streamed output re-renders
/// only the row whose task changed, not the whole list.
private struct TaskSidebarRow: View, Equatable {
    let store: AppStore
    let task: Conversation
    let projectName: String?
    let indent: CGFloat
    let now: Date
    let isRunning: Bool
    let isConfiguring: Bool
    let isSelected: Bool
    let needsApproval: Bool
    let isUnread: Bool
    @State private var isHovered = false

    private var isBusy: Bool { isRunning || isConfiguring }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.task.id == rhs.task.id && lhs.task.title == rhs.task.title && lhs.task.isPinned == rhs.task.isPinned
            && lhs.task.isArchived == rhs.task.isArchived && lhs.task.updatedAt == rhs.task.updatedAt
            && lhs.projectName == rhs.projectName && lhs.indent == rhs.indent
            && RelativeTime.short(lhs.task.updatedAt, now: lhs.now) == RelativeTime.short(rhs.task.updatedAt, now: rhs.now)
            && lhs.isRunning == rhs.isRunning && lhs.isConfiguring == rhs.isConfiguring
            && lhs.isSelected == rhs.isSelected && lhs.needsApproval == rhs.needsApproval && lhs.isUnread == rhs.isUnread
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { store.selectConversation(task) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(task.title).font(.system(size: 13, weight: isUnread ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        if !isHovered { trailingStatus }
                    }
                    // Lists that mix projects name the task's folder underneath its title.
                    if let projectName {
                        Label(projectName, systemImage: "folder").labelStyle(SidebarCaptionLabelStyle())
                    }
                }
                .padding(.leading, indent).padding(.trailing, isHovered ? 2 : 8).padding(.vertical, projectName == nil ? 0 : 5)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.title)
            if isHovered {
                IconButton(icon: task.isPinned ? "pin.slash" : "pin", help: task.isPinned ? "Unpin task" : "Pin task", size: 22) { store.togglePin(task.id) }
                IconButton(icon: "archivebox", help: task.isArchived ? "Restore task" : "Archive task", size: 22) { store.archive(task.id) }
                    .disabled(isBusy)
                Menu { taskActions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Theme.muted).padding(.trailing, 4)
                .help("Task actions").accessibilityLabel("Actions for \(task.title)")
            }
        }
        .background(isSelected ? Theme.hover : isHovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .contextMenu { taskActions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if task.isPinned && projectName == nil {
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.muted).rotationEffect(.degrees(45))
        }
        if needsApproval {
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange).help("Needs your response")
        } else if isRunning || isConfiguring {
            ProgressView().controlSize(.mini).help("Working…")
        } else {
            if isUnread { Circle().fill(Theme.accent).frame(width: 6, height: 6).help("New activity") }
            Text(RelativeTime.short(task.updatedAt, now: now)).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.muted).help(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private var accessibilitySummary: String {
        var parts = [task.title]
        if let projectName { parts.append(projectName) }
        if needsApproval { parts.append("needs approval") } else if isRunning { parts.append("working") }
        else { parts.append(task.updatedAt.formatted(.relative(presentation: .named))) }
        if isUnread { parts.append("new activity") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var taskActions: some View {
        Button(task.isPinned ? "Unpin Task" : "Pin Task", systemImage: task.isPinned ? "pin.slash" : "pin") { store.togglePin(task.id) }
        Button("Rename…", systemImage: "pencil") { store.selectConversation(task); store.showRename = true }
        Button(task.isArchived ? "Restore Task" : "Archive Task", systemImage: "archivebox") { store.archive(task.id) }
            .disabled(isBusy)
        Divider()
        Button("Delete Task…", systemImage: "trash", role: .destructive) { store.features.sessions.requestDelete(task.id) }
            .disabled(isBusy)
    }
}

private struct SidebarCaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9))
            configuration.title.font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }.foregroundStyle(Theme.muted)
    }
}
