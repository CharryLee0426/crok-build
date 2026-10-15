import SwiftUI

/// The chat list: every mirrored session, filtered by computer (Telegram's folder tabs), with search.
struct SessionsListView: View {
    @Environment(CrokEngine.self) private var engine
    @State private var filter: SessionFilter = .all
    @State private var query = ""
    @State private var showsLink = false
    @State private var actionError: RelayError?

    var body: some View {
        let rows = visibleRows
        List {
            ForEach(rows) { row in
                NavigationLink(value: SessionRoute(id: row.id)) {
                    SessionRowView(row: row)
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
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty { emptyState }
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
        }
        .onChange(of: filter) { _, newValue in
            if newValue == .archived { engine.archivedList.start() }
        }
        .onChange(of: engine.computers.map(\.id)) { _, ids in
            if case .computer(let id) = filter, !ids.contains(id) { filter = .all }
        }
        .sheet(isPresented: $showsLink) {
            NavigationStack { LinkComputerView(showsClose: true) }
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

    private var sourceRows: [SessionRow] {
        switch filter {
        case .archived: engine.archivedList.value ?? []
        case .all: engine.sessionList.value ?? []
        case .computer(let id): (engine.sessionList.value ?? []).filter { $0.deviceId == id }
        }
    }

    private var visibleRows: [SessionRow] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sourceRows }
        return sourceRows.filter { row in
            [row.title, row.folderName, row.deviceName, row.preview ?? "", row.model ?? ""].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if filter == .archived {
            ContentUnavailableView {
                Label("No archived sessions", systemImage: "archivebox")
            } description: {
                Text("Swipe left on a session to archive it.")
            }
        } else if engine.sessionList.isLoading && engine.sessionList.value == nil {
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
