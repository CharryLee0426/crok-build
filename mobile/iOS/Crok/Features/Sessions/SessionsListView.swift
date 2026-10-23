import SwiftUI

/// The Sessions tab (mobile/DESIGN.md "Sessions tab"): the selected computer's projects as groups with topics, in the
/// order people put them in (shared with the web and the other phones), its archived sessions in the first row, and a
/// search over its sessions. The title is the computer and opens the switcher, like an account in Telegram.
struct SessionsListView: View {
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openSessionRoute) private var openRoute
    @Environment(\.openLinkComputer) private var openLinkComputer
    @State private var query = ""
    @State private var showsNewSession = false
    /// The project picked in the compose sheet; its screen opens once the sheet is gone.
    @State private var pickedTarget: NewSessionTarget?
    @State private var actionError: RelayError?
    @State private var editMode: EditMode = .inactive

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        // Read while the view is installed: the sheet's closures run later, outside `body`.
        let openRoute = self.openRoute
        let groups = engine.selectedGroups
        return list(groups)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search sessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    editButton(groups)
                }
                ToolbarItem(placement: .principal) {
                    ComputerTitleMenu()
                }
                if !isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsNewSession = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(engine.selectedComputer == nil)
                        .accessibilityLabel(Text("New Session"))
                        .accessibilityIdentifier("composeButton")
                    }
                }
                if isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Read All") {
                            markRead(ReadAll.unreadIDs(in: groups))
                        }
                        .disabled(ReadAll.unreadIDs(in: groups).isEmpty)
                        .accessibilityIdentifier("readAllButton")
                        Spacer()
                        Button("Sort by Recent Activity") {
                            run(.projectsByActivity)
                        }
                        .disabled(groups.count < 2)
                        .accessibilityIdentifier("sortProjectsButton")
                    }
                }
            }
            .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
            .environment(\.editMode, $editMode)
            .onAppear { engine.archivedList.start() }
            .onChange(of: isSearching) { _, searching in
                if searching { editMode = .inactive }
            }
            .onChange(of: engine.selectedComputerId) { _, _ in
                editMode = .inactive
                query = ""
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
                NewSessionPicker(groups: groups) { target in pickedTarget = target }
            }
            .relayErrorAlert($actionError)
    }

    // MARK: List

    private var archivedRows: [SessionRow] {
        guard let id = engine.selectedComputerId else { return [] }
        return (engine.archivedList.value ?? []).filter { $0.deviceId == id }
    }

    private func list(_ groups: [ProjectGroup]) -> some View {
        let archived = archivedRows
        let results = isSearching
            ? SessionSearch.filter(groups, query: query).flatMap(\.sessions) : []
        return List {
            if isSearching {
                ForEach(results) { row in
                    SessionLink(row: row, showsProject: true, onError: { actionError = $0 })
                }
            } else {
                if !archived.isEmpty && !isEditing {
                    RowLink(value: ArchivedRoute(deviceId: archived[0].deviceId)) {
                        ArchivedSessionsRow(rows: archived)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
                }
                ForEach(groups) { group in
                    projectLink(group, among: groups)
                }
                .onMove(perform: isEditing ? { source, destination in
                    let keys = ProjectOrder.moved(groups.map(\.key), fromOffsets: source, toOffset: destination)
                    run(.projects(keys))
                } : nil)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isSearching && results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !isSearching && groups.isEmpty && archived.isEmpty {
                emptyState
            }
        }
    }

    private func projectLink(_ group: ProjectGroup, among groups: [ProjectGroup]) -> some View {
        RowLink(value: ProjectRoute(key: group.key)) {
            ForumRowView(group: group)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if group.unreadCount > 0 {
                Button {
                    markRead(ReadAll.unreadIDs(in: [group]))
                } label: {
                    Label("Read", systemImage: "checkmark.bubble.fill")
                }
                .tint(Theme.accent)
            }
        }
        .contextMenu {
            projectMenu(group, among: groups)
        }
    }

    /// A project's long-press menu: a new session in it, read it, move it, sort its sessions by activity.
    @ViewBuilder
    private func projectMenu(_ group: ProjectGroup, among groups: [ProjectGroup]) -> some View {
        Button {
            openRoute(.new(NewSessionRoute(target: NewSessionTarget(group: group))))
        } label: {
            Label("New Session", systemImage: "square.and.pencil")
        }
        .disabled(!group.deviceOnline)
        Button {
            markRead(ReadAll.unreadIDs(in: [group]))
        } label: {
            Label("Mark as Read", systemImage: "checkmark.bubble")
        }
        .disabled(group.unreadCount == 0)
        Divider()
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
    }

    // MARK: Toolbar

    @ViewBuilder
    private func editButton(_ groups: [ProjectGroup]) -> some View {
        if isEditing {
            Button {
                withAnimation(.snappy) { editMode = .inactive }
            } label: {
                Text("Done").fontWeight(.semibold)
            }
            .accessibilityIdentifier("reorderDone")
        } else {
            Button("Edit") {
                withAnimation(.snappy) { editMode = .active }
            }
            .disabled(isSearching || groups.isEmpty)
            .accessibilityIdentifier("editButton")
        }
    }

    private func run(_ change: ListReorder) {
        Task { actionError = await engine.reorder(change) }
    }

    private func markRead(_ ids: [DocID]) {
        Task { actionError = await engine.markRead(ids) }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if engine.groupList.isLoading && engine.groupList.value == nil {
            ProgressView()
        } else if let computer = engine.selectedComputer {
            ContentUnavailableView {
                Label("No sessions on \(computer.name) yet", systemImage: "terminal")
            } actions: {
                if computer.online {
                    Button("New Session") { showsNewSession = true }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.onAccent)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No computers yet", systemImage: "desktopcomputer")
            } description: {
                Text("On your computer, run crok remote login (or open Crok Desktop › Settings › Remote control). Sessions you work on there show up here.")
            } actions: {
                Button("Link a computer") { openLinkComputer() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityIdentifier("emptyLinkComputer")
            }
        }
    }
}

/// A list row that opens `value`, without the disclosure chevron (Telegram's lists have none): the link sits invisible
/// behind the row, and the list's cell selection follows it.
struct RowLink<Value: Hashable, Label: View>: View {
    let value: Value
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .background {
                NavigationLink(value: value) { EmptyView() }
                    .opacity(0)
            }
    }
}

/// A project's screen on the Sessions stack.
struct ProjectRoute: Hashable {
    let key: String
}

/// A computer's archived sessions on the Sessions stack.
struct ArchivedRoute: Hashable {
    let deviceId: DocID
}

/// The Sessions tab's title: the selected computer and its status; a tap opens the computer switcher.
struct ComputerTitleMenu: View {
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openLinkComputer) private var openLinkComputer

    var body: some View {
        let computer = engine.selectedComputer
        let engine = self.engine
        let openLinkComputer = self.openLinkComputer
        ConnectionTitleView(
            title: computer?.name ?? String(localized: "Sessions"), connection: engine.connection,
            subtitle: computer.map { AnyView(ComputerStatusText(computer: $0)) }, chevron: computer != nil)
            .accessibilityHidden(true)
            .overlay {
                UIMenuButtonOverlay(
                    accessibilityLabel: computer?.name ?? String(localized: "Sessions"),
                    // The connection state while the relay is not live, as the title shows it.
                    accessibilityValue: engine.connection.title ?? computer.map { ComputerSwitcherItems.subtitle($0) },
                    identifier: "computerTitle"
                ) {
                    ComputerSwitcherMenu.make(engine: engine) { openLinkComputer() }
                }
            }
    }
}

/// "Online" in the accent colour, or "last seen …".
struct ComputerStatusText: View {
    let computer: ComputerAccount

    var body: some View {
        Group {
            if computer.online {
                Text("Online")
                    .foregroundStyle(Theme.accent)
            } else if let lastSeen = computer.lastSeen {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(RelativeTime.lastSeen(lastSeen, now: context.date))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("offline")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// The second line of a computer in the switcher (`ComputerSwitcherMenu`).
enum ComputerSwitcherItems {
    /// "3 unread", else "Online" or "last seen …".
    static func subtitle(_ computer: ComputerAccount, now: Date = Date()) -> String {
        if computer.unread > 0 { return String(localized: "\(computer.unread) unread") }
        if computer.online { return String(localized: "Online") }
        if let lastSeen = computer.lastSeen { return RelativeTime.lastSeen(lastSeen, now: now) }
        return String(localized: "offline")
    }
}

/// A session row that opens the session, with its swipe actions and long-press menu (pin, stop, read, archive, and
/// moving it within its project).
struct SessionLink: View {
    @Environment(CrokEngine.self) private var engine
    let row: SessionRow
    /// The project it sits in, for Move Up / Move Down; nil in a flat list.
    var group: ProjectGroup?
    var showsProject = false
    var canReorder = false
    let onError: (RelayError?) -> Void

    var body: some View {
        RowLink(value: SessionRoute.session(row.id)) {
            SessionRowView(row: row, showsProject: showsProject)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !row.archived {
                Button {
                    act { await engine.setPinned(row.id, !row.pinned) }
                } label: {
                    Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(Theme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                act { await engine.setArchived(row.id, !row.archived) }
            } label: {
                Label(row.archived ? "Unarchive" : "Archive", systemImage: row.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
            }
            .tint(.gray)
            if row.isRunning {
                Button(role: .destructive) {
                    act { await engine.stopTurn(row.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(Theme.danger)
            }
        }
        .contextMenu {
            if !row.archived {
                Button {
                    act { await engine.setPinned(row.id, !row.pinned) }
                } label: {
                    Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin")
                }
            }
            if row.isRunning {
                Button(role: .destructive) {
                    act { await engine.stopTurn(row.id) }
                } label: {
                    Label("Stop", systemImage: "stop")
                }
            }
            if row.unreadCount > 0 {
                Button {
                    act { await engine.markRead([row.id]) }
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.bubble")
                }
            }
            Button {
                act { await engine.setArchived(row.id, !row.archived) }
            } label: {
                Label(row.archived ? "Unarchive" : "Archive", systemImage: row.archived ? "tray.and.arrow.up" : "archivebox")
            }
            if let group, canReorder {
                Divider()
                let up = ProjectOrder.sessionIDs(group.sessions, moving: row.id, by: -1)
                let down = ProjectOrder.sessionIDs(group.sessions, moving: row.id, by: 1)
                Button {
                    if let up { act { await engine.reorder(.sessions(projectKey: group.key, ids: up)) } }
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(up == nil)
                Button {
                    if let down { act { await engine.reorder(.sessions(projectKey: group.key, ids: down)) } }
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(down == nil)
            }
        }
    }

    private func act(_ work: @escaping @MainActor () async -> RelayError?) {
        Task { onError(await work()) }
    }
}

extension View {
    /// "Couldn't do that" with the relay's message.
    func relayErrorAlert(_ error: Binding<RelayError?>) -> some View {
        alert(
            "Couldn't do that", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}
