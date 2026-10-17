import SwiftUI

/// The chat list (relay/DESIGN.md §5 "The session list"): every session on every computer, running or only on the
/// computer's disk, in one section per project, filtered by computer (Telegram's folder tabs), with search. Projects
/// and sessions keep the order people put them in, shared with the web and the other phones.
struct SessionsListView: View {
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openSessionRoute) private var openRoute
    @State private var filter: SessionFilter = .all
    @State private var query = ""
    @State private var showsLink = false
    @State private var showsNewSession = false
    /// The project picked in the compose sheet; its screen opens once the sheet is gone.
    @State private var pickedTarget: NewSessionTarget?
    @State private var actionError: RelayError?
    @State private var editMode: EditMode = .inactive
    /// Projects showing every session instead of the first five (for this visit only).
    @State private var showsAll: Set<String> = []

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isEditing: Bool { editMode.isEditing }
    /// Reordering is off in the Archived tab and while searching (a filtered list has no places to move to).
    private var canReorder: Bool { filter != .archived && !isSearching }

    var body: some View {
        // Read while the view is installed: the sheet's closures run later, outside `body`.
        let openRoute = self.openRoute
        return Group {
            if filter == .archived {
                archivedList
            } else {
                groupedList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterTabs(selection: $filter, computers: engine.computers)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search sessions"))
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionTitleView(title: String(localized: "Sessions"), connection: engine.connection)
            }
            ToolbarItem(placement: .topBarTrailing) {
                listMenu
            }
            if !isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsNewSession = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(Text("New Session"))
                    .accessibilityIdentifier("composeButton")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: filter) { _, newValue in
            if newValue == .archived {
                engine.archivedList.start()
                editMode = .inactive
            }
        }
        .onChange(of: isSearching) { _, searching in
            if searching { editMode = .inactive }
        }
        .onChange(of: engine.computers.map(\.id)) { _, ids in
            if case .computer(let id) = filter, !ids.contains(id) { filter = .all }
        }
        .sheet(isPresented: $showsLink) {
            NavigationStack { LinkComputerView(showsClose: true) }
        }
        .sheet(
            isPresented: $showsNewSession,
            onDismiss: {
                // Pushed once the sheet is gone (a push while it is still going away is lost).
                if let target = pickedTarget {
                    pickedTarget = nil
                    openRoute(.new(NewSessionRoute(target: target)))
                }
            }
        ) {
            NewSessionPicker(groups: engine.groups) { target in pickedTarget = target }
        }
        .alert(
            "Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: Lists

    /// The current tab's projects (a computer tab keeps only that computer's), in the list's order.
    private var tabGroups: [ProjectGroup] {
        let all = engine.groups
        if case .computer(let id) = filter { return all.filter { $0.deviceId == id } }
        return all
    }

    private var groupedList: some View {
        let groups = SessionSearch.filter(tabGroups, query: query)
        return List {
            if isEditing && groups.count > 1 {
                Section {
                    ForEach(groups) { group in
                        ProjectReorderRow(group: group, showsComputer: filter == .all)
                    }
                    .onMove { source, destination in
                        let keys = ProjectOrder.moved(groups.map(\.key), fromOffsets: source, toOffset: destination)
                        run(.projects(keys))
                    }
                } header: {
                    Text("Projects")
                }
            }
            ForEach(groups) { group in
                section(group, among: groups)
            }
        }
        .listStyle(.plain)
        .overlay {
            if groups.isEmpty { emptyState }
        }
    }

    private var archivedList: some View {
        let rows = (engine.archivedList.value ?? []).filter { SessionSearch.matches($0, query) }
        return List {
            ForEach(rows) { row in
                sessionLink(row, in: nil)
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty { emptyState }
        }
    }

    // MARK: Sections

    /// One project: its header, then its first five sessions and "Show N more" (every session while searching or
    /// reordering).
    private func section(_ group: ProjectGroup, among groups: [ProjectGroup]) -> some View {
        let collapsed = engine.isCollapsed(group.key) && !isSearching
        let showsEverySession = isSearching || isEditing || showsAll.contains(group.key)
        let rows = showsEverySession ? group.sessions : Array(group.sessions.prefix(ProjectOrder.previewLimit))
        let hidden = group.sessions.count - ProjectOrder.previewLimit
        return Section {
            if !collapsed {
                ForEach(rows) { row in
                    sessionLink(row, in: group)
                }
                .onMove(perform: isEditing ? { source, destination in
                    let ids = ProjectOrder.moved(group.sessions.map(\.id), fromOffsets: source, toOffset: destination)
                    run(.sessions(projectKey: group.key, ids: ids))
                } : nil)
                if !isSearching && !isEditing && hidden > 0 {
                    showMoreButton(group, hidden: hidden)
                }
            }
        } header: {
            ProjectSectionHeader(
                group: group, showsComputer: filter == .all, collapsed: collapsed,
                onToggle: {
                    withAnimation(.snappy) { engine.toggleCollapsed(group.key) }
                },
                onNewSession: group.deviceOnline && !isEditing ? { startSession(in: NewSessionTarget(group: group)) } : nil,
                menu: { projectMenu(group, among: groups, collapsed: collapsed) })
        }
    }

    private func showMoreButton(_ group: ProjectGroup, hidden: Int) -> some View {
        let expanded = showsAll.contains(group.key)
        return Button {
            withAnimation(.snappy) {
                if expanded { showsAll.remove(group.key) } else { showsAll.insert(group.key) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                if expanded {
                    Text("Show less")
                } else {
                    Text("Show \(hidden) more")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .moveDisabled(true)
        .accessibilityIdentifier("showMore-\(group.name)")
    }

    /// A section header's menu: a new session in the project, move it, sort its sessions by activity, collapse it.
    @ViewBuilder
    private func projectMenu(_ group: ProjectGroup, among groups: [ProjectGroup], collapsed: Bool) -> some View {
        Button {
            startSession(in: NewSessionTarget(group: group))
        } label: {
            Label("New Session", systemImage: "square.and.pencil")
        }
        .disabled(!group.deviceOnline)
        Divider()
        if canReorder {
            let keys = groups.map(\.key)
            Button {
                if let next = ProjectOrder.keys(keys, moving: group.key, by: -1) { run(.projects(next)) }
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(ProjectOrder.keys(keys, moving: group.key, by: -1) == nil)
            Button {
                if let next = ProjectOrder.keys(keys, moving: group.key, by: 1) { run(.projects(next)) }
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(ProjectOrder.keys(keys, moving: group.key, by: 1) == nil)
            Button {
                run(.sessionsByActivity(projectKey: group.key))
            } label: {
                Label("Sort by Recent Activity", systemImage: "clock.arrow.circlepath")
            }
            Divider()
        }
        Button {
            withAnimation(.snappy) { engine.toggleCollapsed(group.key) }
        } label: {
            if collapsed {
                Label("Expand", systemImage: "chevron.down")
            } else {
                Label("Collapse", systemImage: "chevron.up")
            }
        }
    }

    // MARK: Rows

    private func sessionLink(_ row: SessionRow, in group: ProjectGroup?) -> some View {
        NavigationLink(value: SessionRoute.session(row.id)) {
            SessionRowView(row: row, grouped: group != nil)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { actionError = await engine.setPinned(row.id, !row.pinned) }
            } label: {
                Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { actionError = await engine.setArchived(row.id, !row.archived) }
            } label: {
                Label(row.archived ? "Unarchive" : "Archive", systemImage: row.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
            }
            .tint(.gray)
            if row.isRunning {
                Button(role: .destructive) {
                    Task { actionError = await engine.stopTurn(row.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(Theme.danger)
            }
        }
        .contextMenu {
            Button {
                Task { actionError = await engine.setPinned(row.id, !row.pinned) }
            } label: {
                Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin")
            }
            if row.isRunning {
                Button(role: .destructive) {
                    Task { actionError = await engine.stopTurn(row.id) }
                } label: {
                    Label("Stop", systemImage: "stop")
                }
            }
            Button {
                Task { actionError = await engine.setArchived(row.id, !row.archived) }
            } label: {
                Label(row.archived ? "Unarchive" : "Archive", systemImage: row.archived ? "tray.and.arrow.up" : "archivebox")
            }
            if let group, canReorder {
                Divider()
                let up = ProjectOrder.sessionIDs(group.sessions, moving: row.id, by: -1)
                let down = ProjectOrder.sessionIDs(group.sessions, moving: row.id, by: 1)
                Button {
                    if let up { run(.sessions(projectKey: group.key, ids: up)) }
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(up == nil)
                Button {
                    if let down { run(.sessions(projectKey: group.key, ids: down)) }
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(down == nil)
            }
        }
    }

    // MARK: Toolbar

    /// "Done" while reordering; otherwise the list's menu: Reorder, Sort Projects by Recent Activity.
    @ViewBuilder
    private var listMenu: some View {
        if isEditing {
            Button {
                withAnimation(.snappy) { editMode = .inactive }
            } label: {
                Text("Done").fontWeight(.semibold)
            }
            .accessibilityIdentifier("reorderDone")
        } else if filter != .archived {
            Menu {
                Button {
                    withAnimation(.snappy) { editMode = .active }
                } label: {
                    Label("Reorder", systemImage: "arrow.up.arrow.down")
                }
                .disabled(!canReorder || tabGroups.isEmpty)
                .accessibilityIdentifier("reorderButton")
                Button {
                    run(.projectsByActivity)
                } label: {
                    Label("Sort Projects by Recent Activity", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!canReorder || tabGroups.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("listMenu")
        }
    }

    private func run(_ change: ListReorder) {
        Task { actionError = await engine.reorder(change) }
    }

    /// The new-session screen for a project (its "+", its menu, or the compose button's picker).
    private func startSession(in target: NewSessionTarget) {
        openRoute(.new(NewSessionRoute(target: target)))
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search(text: query)
        } else if filter == .archived {
            ContentUnavailableView {
                Label("No archived sessions", systemImage: "archivebox")
            } description: {
                Text("Swipe left on a session to archive it.")
            }
        } else if engine.groupList.isLoading && engine.groupList.value == nil {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "terminal")
            } description: {
                Text("On your computer, run crok remote login (or open Crok Desktop › Settings › Remote control). Sessions you work on there show up here.")
            } actions: {
                Button("Link a computer") { showsLink = true }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityIdentifier("emptyLinkComputer")
            }
        }
    }
}

enum SessionFilter: Hashable {
    case all
    case computer(DocID)
    case archived
}

/// A project's section header: folder, name, the computer on the All tab, the session count, and a chevron; a tap
/// collapses or expands it. The "⋯" button opens the project's menu (a context menu, or a `Menu` with a primary
/// action, does not open on a List section header).
struct ProjectSectionHeader<MenuItems: View>: View {
    let group: ProjectGroup
    let showsComputer: Bool
    let collapsed: Bool
    let onToggle: () -> Void
    /// "+": a new session in this project (only while its computer is online).
    var onNewSession: (() -> Void)?
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        HStack(spacing: 2) {
            toggle
            if let onNewSession {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("New Session"))
                .accessibilityIdentifier("newSession-\(group.name)")
            }
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("projectMenu-\(group.name)")
        }
        .textCase(nil)
    }

    private var toggle: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.avatarColor(for: group.name))
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if showsComputer {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(group.deviceOnline ? Theme.online : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(group.deviceName)
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(verbatim: "\(group.sessions.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(group.sessions.count) sessions"))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(collapsed ? Text("Expand") : Text("Collapse"))
        .accessibilityIdentifier("projectHeader-\(group.name)")
    }
}

/// A project in Reorder mode's "Projects" section, dragged by its handle.
private struct ProjectReorderRow: View {
    let group: ProjectGroup
    let showsComputer: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.avatarColor(for: group.name))
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if showsComputer {
                    Text(group.deviceName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(group.sessions.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("\(group.sessions.count) sessions"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectReorderRow-\(group.name)")
    }
}

/// "All" · one tab per computer · "Archived" (Telegram's chat folders).
struct FilterTabs: View {
    @Binding var selection: SessionFilter
    let computers: [DeviceRow]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab(.all) { Text("All") }
                ForEach(computers) { computer in
                    tab(.computer(computer.id)) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(computer.online ? Theme.online : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(computer.name)
                        }
                    }
                }
                tab(.archived) { Label("Archived", systemImage: "archivebox") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ value: SessionFilter, @ViewBuilder label: () -> some View) -> some View {
        let selected = selection == value
        return Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            label()
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Theme.onAccent : Color.primary)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
