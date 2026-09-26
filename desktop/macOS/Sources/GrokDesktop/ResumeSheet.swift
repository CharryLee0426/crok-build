import AppKit
import SwiftUI

/// `/resume`: saved harness sessions for the selected project, with a full-text search across
/// every session. Choosing one opens it as a task (reusing the task already in the sidebar).
struct ResumeSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionFeatureModel
    @State private var query = ""
    @State private var highlighted: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    private var rows: [HarnessSessionRow] { isSearching ? sessions.searchRows : sessions.resumeRows }

    var body: some View {
        let known = knownSessions
        DesktopPanel(title: "Resume", subtitle: subtitle, width: 760, height: 640, onClose: close) {
            VStack(spacing: 0) {
                NativeSearchField(text: $query, placeholder: "Search titles and conversation content", onEscape: close,
                                  onSubmit: { if let row = highlightedRow { resume(row) } }, onMove: move)
                    .frame(height: 40).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
                Divider()
                if let error = isSearching ? sessions.searchError : sessions.resumeError {
                    SessionErrorStrip(message: error) { Task { await reload() } }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if isSearching && sessions.searchBootstrapping {
                                Label("The search index is still being built, so some sessions may be missing.", systemImage: "hourglass")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 4)
                            }
                            ForEach(rows) { row in
                                ResumeSessionRow(row: row, state: known[row.id], isHighlighted: highlightedRow?.id == row.id,
                                                 showsFolder: row.cwd != store.project?.path,
                                                 resume: { resume(row) }).equatable()
                                    .id(row.id)
                                    .onTapGesture(count: 2) { resume(row) }
                                    .onTapGesture { highlighted = row.id }
                            }
                            footerContent
                        }.padding(.horizontal, 24).padding(.vertical, 16)
                    }
                    .onChange(of: highlighted) { _, id in if let id { withAnimation(nil) { proxy.scrollTo(id) } } }
                }
            }
        } footer: {
            Text(countText).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Refresh") { Task { await reload() } }.disabled(sessions.resumeLoading)
            Button("Resume") { if let row = highlightedRow { resume(row) } }
                .disabled(highlightedRow == nil)
        }
        .task { await sessions.loadResumeSessions() }
        .task(id: trimmedQuery) {
            // Debounced: each keystroke cancels the previous wait.
            guard !trimmedQuery.isEmpty else { await sessions.searchSessions(""); return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await sessions.searchSessions(trimmedQuery)
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            if highlighted.map({ !ids.contains($0) }) ?? true { highlighted = ids.first }
        }
        .onDisappear { sessions.closeResume() }
    }

    private var subtitle: String {
        guard let project = store.project else { return "Find and resume a saved session." }
        return "Saved sessions in \(project.name). Search looks through every session."
    }

    @ViewBuilder private var footerContent: some View {
        let loading = isSearching ? (sessions.searchLoading || sessions.searchedQuery != trimmedQuery) : sessions.resumeLoading
        if loading && rows.isEmpty {
            ProgressView(isSearching ? "Searching sessions…" : "Loading sessions…").frame(maxWidth: .infinity).padding(30)
        } else if rows.isEmpty && (isSearching ? sessions.searchError : sessions.resumeError) == nil {
            SessionEmptyState(symbol: isSearching ? "magnifyingglass" : "clock.arrow.circlepath",
                              title: isSearching ? "No sessions match “\(trimmedQuery)”." : "No saved sessions in this project yet.",
                              detail: isSearching ? nil : "Sessions appear here after Crok has worked in this folder.")
        } else if !isSearching && sessions.resumeCursor != nil {
            HStack {
                Spacer()
                if sessions.resumeLoading { ProgressView().controlSize(.small) }
                else { Button("Load more") { Task { await sessions.loadResumeSessions(more: true) } }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)) }
                Spacer()
            }.padding(.top, 6)
        }
    }

    private var countText: String {
        if isSearching { return sessions.searchedQuery == trimmedQuery ? "\(rows.count) match\(rows.count == 1 ? "" : "es")" : "Searching…" }
        return "\(rows.count)\(sessions.resumeCursor == nil ? "" : "+") session\(rows.count == 1 ? "" : "s")"
    }

    /// How each listed session relates to the sidebar.
    private var knownSessions: [String: ResumeSessionRow.SidebarState] {
        var states: [String: ResumeSessionRow.SidebarState] = [:]
        for id in store.state.deletedSessionIDs { states[id] = .removed }
        for task in store.state.conversations { if let id = task.sessionID { states[id] = task.isArchived ? .archived : .inSidebar } }
        return states
    }

    private var highlightedRow: HarnessSessionRow? { rows.first { $0.id == highlighted } ?? rows.first }

    private func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted } ?? -1
        highlighted = rows[max(0, min(rows.count - 1, index + offset))].id
    }

    private func resume(_ row: HarnessSessionRow) { Task { await sessions.resumeSession(row) } }

    private func reload() async {
        if isSearching { await sessions.searchSessions(trimmedQuery) } else { await sessions.loadResumeSessions() }
    }

    private func close() { store.sheet = nil }
}

struct ResumeSessionRow: View, Equatable {
    enum SidebarState: Equatable { case inSidebar, archived, removed }

    let row: HarnessSessionRow
    let state: SidebarState?
    let isHighlighted: Bool
    let showsFolder: Bool
    let resume: () -> Void
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.state == rhs.state && lhs.isHighlighted == rhs.isHighlighted && lhs.showsFolder == rhs.showsFolder
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    badges
                }
                if let detail = row.snippet ?? row.summary ?? row.firstPrompt.flatMap({ $0 == row.title ? nil : $0 }) {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                metadata
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                IconButton(icon: "doc.on.doc", help: "Copy session ID", size: 28) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.id, forType: .string)
                }
                Button("Resume", action: resume).buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                    .help(row.isRemoteOnly ? "This session is stored remotely; resuming asks the harness to restore it." : "Open this session as a task")
            }
        }
        .sessionCard(highlighted: isHighlighted, padding: 14)
        .background(hovered && !isHighlighted ? Theme.hover.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
    }

    @ViewBuilder private var badges: some View {
        switch state {
        case .inSidebar?: SessionStatusPill(text: "In sidebar", tone: .accent)
        case .archived?: SessionStatusPill(text: "Archived", tone: .muted)
        case .removed?: SessionStatusPill(text: "Removed from sidebar", tone: .muted)
        case nil: EmptyView()
        }
        if row.isRemoteOnly { SessionStatusPill(text: "Remote", tone: .muted) }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            let parts = metadataParts
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·") }
                if let symbol = part.symbol {
                    Label(part.text, systemImage: symbol).labelStyle(ResumeMetadataLabelStyle())
                } else { Text(part.text) }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
    }

    private var metadataParts: [(text: String, symbol: String?)] {
        var parts: [(String, String?)] = []
        if let date = row.updatedAt { parts.append((RelativeTime.short(date, now: Date()) == "now" ? "just now" : RelativeTime.short(date, now: Date()) + " ago", "clock")) }
        if let count = row.messageCount, count > 0 { parts.append(("\(count) message\(count == 1 ? "" : "s")", nil)) }
        if let branch = row.worktreeLabel ?? row.branch { parts.append((branch, "arrow.triangle.branch")) }
        if showsFolder, !row.cwd.isEmpty { parts.append((URL(fileURLWithPath: row.cwd).lastPathComponent, "folder")) }
        if let model = row.modelID { parts.append((model, nil)) }
        return parts
    }
}

private struct ResumeMetadataLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 9)); configuration.title }
    }
}
