import SwiftUI

/// A project's sessions (Telegram's topic list of a group, mobile/DESIGN.md "Project screen"), in the project's order
/// with pinned ones first, searchable; Reorder moves them.
struct ProjectSessionsView: View {
    let projectKey: String
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openSessionRoute) private var openRoute
    @State private var query = ""
    @State private var actionError: RelayError?
    @State private var editMode: EditMode = .inactive

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        let group = engine.groups.first(where: { $0.key == projectKey })
        let rows = (group?.sessions ?? []).filter { SessionSearch.matches($0, query) }
        return List {
            ForEach(rows) { row in
                SessionLink(row: row, group: group, canReorder: !isSearching, onError: { actionError = $0 })
            }
            .onMove(perform: isEditing ? { source, destination in
                guard let group else { return }
                let ids = ProjectOrder.moved(group.sessions.map(\.id), fromOffsets: source, toOffset: destination)
                run(.sessions(projectKey: group.key, ids: ids))
            } : nil)
        }
        .listStyle(.plain)
        .overlay {
            if isSearching && rows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if group == nil {
                ContentUnavailableView("No sessions yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search sessions"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionTitleView(
                    title: group?.name ?? "", connection: engine.connection,
                    subtitle: group.map { group in
                        AnyView(
                            Text("\(group.sessions.count) sessions · \(group.deviceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1))
                    })
            }
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy) { editMode = .inactive }
                    } label: {
                        Text("Done").fontWeight(.semibold)
                    }
                    .accessibilityIdentifier("reorderDone")
                }
            } else if let group {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            markRead(ReadAll.unreadIDs(in: [group]))
                        } label: {
                            Label("Mark All as Read", systemImage: "checkmark.bubble")
                        }
                        .disabled(group.unreadCount == 0)
                        Button {
                            withAnimation(.snappy) { editMode = .active }
                        } label: {
                            Label("Reorder", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(isSearching || group.sessions.count < 2)
                        .accessibilityIdentifier("reorderButton")
                        Button {
                            run(.sessionsByActivity(projectKey: group.key))
                        } label: {
                            Label("Sort by Recent Activity", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                    .accessibilityIdentifier("projectMenu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openRoute(.new(NewSessionRoute(target: NewSessionTarget(group: group))))
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!group.deviceOnline)
                    .accessibilityLabel(Text("New Session"))
                    .accessibilityIdentifier("newSessionInProject")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: isSearching) { _, searching in
            if searching { editMode = .inactive }
        }
        .relayErrorAlert($actionError)
    }

    private func run(_ change: ListReorder) {
        Task { actionError = await engine.reorder(change) }
    }

    private func markRead(_ ids: [DocID]) {
        Task { actionError = await engine.markRead(ids) }
    }
}

/// A computer's archived sessions (Telegram's Archived Chats).
struct ArchivedSessionsView: View {
    let deviceId: DocID
    @Environment(CrokEngine.self) private var engine
    @State private var query = ""
    @State private var actionError: RelayError?

    var body: some View {
        let rows = (engine.archivedList.value ?? [])
            .filter { $0.deviceId == deviceId && SessionSearch.matches($0, query) }
        let computer = engine.computerAccounts.first(where: { $0.id == deviceId })
        return List {
            ForEach(rows) { row in
                SessionLink(row: row, showsProject: true, onError: { actionError = $0 })
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView {
                        Label("No archived sessions", systemImage: "archivebox")
                    } description: {
                        Text("Swipe left on a session to archive it.")
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search sessions"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionTitleView(
                    title: String(localized: "Archived Sessions"), connection: engine.connection,
                    subtitle: computer.map { computer in
                        AnyView(Text(computer.name).font(.caption).foregroundStyle(.secondary).lineLimit(1))
                    })
            }
        }
        .onAppear { engine.archivedList.start() }
        .relayErrorAlert($actionError)
    }
}
