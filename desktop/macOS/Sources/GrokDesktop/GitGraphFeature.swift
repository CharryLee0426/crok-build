import AppKit
import Combine
import SwiftUI

/// Asks the commit list to bring a commit into view; `serial` repeats a request for the same one.
struct GitGraphScrollRequest: Equatable {
    let id: String
    let serial: Int
}

/// A commit and its slice of the graph, as the list shows them.
struct GitGraphEntry: Identifiable, Equatable {
    var id: String { commit.id }
    let commit: GitCommit
    let row: GitGraphRow
}

/// The Git Graph window's state: the selected project's history, laid out in lanes, and the
/// commit and file being inspected. It follows the selected project and refreshes while open.
@MainActor
final class GitGraphModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case notRepository(String)
        case failed(String)
    }

    static let pageSize = 500

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var graph: GitGraph?
    @Published private(set) var entries: [GitGraphEntry] = []
    @Published var scope: GitGraphScope {
        didSet {
            guard scope != oldValue else { return }
            UserDefaults.standard.set(scope.rawValue, forKey: "gitGraphScope")
            limit = Self.pageSize
            Task { await reload() }
        }
    }
    @Published private(set) var selectedID: String?
    @Published var query = "" { didSet { if query != oldValue { updateMatches() } } }
    /// Commits the search matches, in list order.
    @Published private(set) var matches: [String] = []
    @Published private(set) var files: [GitCommitFile] = []
    @Published private(set) var filesLoading = false
    @Published private(set) var filesError: String?
    @Published private(set) var selectedFile: String?
    @Published private(set) var diffText = ""
    /// Why the last branch switch from the graph failed.
    @Published var actionError: String?
    @Published private(set) var switching = false
    /// A commit the list should scroll to, bumped for every request.
    @Published private(set) var scrollRequest: GitGraphScrollRequest?

    private weak var store: AppStore?
    private let service = WorkspaceService()
    private var limit = GitGraphModel.pageSize
    private var observers: Set<AnyCancellable> = []
    private var poll: Task<Void, Never>?
    private var signature: String?
    private var loadSerial = 0
    private var detailSerial = 0
    private var scrollSerial = 0
    private var isVisible = false
    private var matchSet: Set<String> = []

    init(store: AppStore) {
        self.store = store
        scope = UserDefaults.standard.string(forKey: "gitGraphScope").flatMap(GitGraphScope.init(rawValue:)) ?? .all
    }

    var projectName: String { store?.project?.name ?? "" }
    var selectedEntry: GitGraphEntry? { selectedID.flatMap { id in entries.first { $0.id == id } } }
    var isLoading: Bool { phase == .loading }
    func isMatch(_ id: String) -> Bool { matchSet.contains(id) }

    func open() { store?.open(.gitGraph) }

    func windowAppeared() {
        guard let store, !isVisible else { return }
        isVisible = true
        // Another project, another branch, or edits in the working tree all change what the graph shows.
        store.$state.map(\.selectedProjectID).removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.selectedID = nil
                    self?.limit = GitGraphModel.pageSize
                    await self?.reload()
                }
            }.store(in: &observers)
        store.$workspace.map { "\($0.rootPath ?? "")\u{0}\($0.branch)\u{0}\($0.changes.count)" }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.reload() } }
            .store(in: &observers)
        // Commits, fetches, and new branches move refs without touching the working tree.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.reloadIfRefsMoved()
            }
        }
        Task { await reload() }
    }

    func windowDisappeared() {
        isVisible = false
        observers.removeAll()
        poll?.cancel(); poll = nil
    }

    func reload() async {
        guard let store else { return }
        guard let project = store.project else {
            graph = nil; entries = []; phase = .notRepository("Open a project to see its history.")
            return
        }
        loadSerial += 1
        let serial = loadSerial
        if graph == nil { phase = .loading }
        let uncommitted = store.workspace.rootPath == nil ? 0 : store.workspace.changes.count
        let path = project.path
        async let loaded = service.graph(path: path, scope: scope, limit: limit, uncommitted: uncommitted)
        async let refs = service.refsSignature(path: path)
        let (result, newSignature) = await (loaded, refs)
        guard serial == loadSerial, store.project?.id == project.id else { return }
        signature = newSignature
        switch result {
        case .notRepository(let message):
            graph = nil; entries = []; selectedID = nil
            phase = .notRepository(message.isEmpty ? "This project is not a Git repository." : message)
        case .failed(let message):
            phase = .failed(message)
        case .loaded(let loadedGraph):
            apply(loadedGraph)
            phase = .loaded
        }
    }

    private func apply(_ newGraph: GitGraph) {
        let previous = selectedEntry?.commit
        graph = newGraph
        entries = zip(newGraph.commits, newGraph.rows).map { GitGraphEntry(commit: $0, row: $1) }
        updateMatches()
        if let selectedID, entries.contains(where: { $0.id == selectedID }) {
            // The same commit can come back changed: the uncommitted row lists other files now.
            if let current = selectedEntry?.commit, current != previous || current.isUncommitted { loadDetails(for: current, keepFile: true) }
        } else {
            select(entries.first { $0.commit.id == newGraph.headID }?.id ?? entries.first?.id)
        }
    }

    private func reloadIfRefsMoved() async {
        guard isVisible, let path = store?.project?.path, phase == .loaded else { return }
        let current = await service.refsSignature(path: path)
        if current != signature { await reload() }
    }

    func loadMore() {
        limit += Self.pageSize
        Task { await reload() }
    }

    // MARK: Selection

    func select(_ id: String?, scroll: Bool = false) {
        guard id != selectedID else { return }
        selectedID = id
        selectedFile = nil; diffText = ""
        if let id, scroll { requestScroll(to: id) }
        if let commit = selectedEntry?.commit { loadDetails(for: commit, keepFile: false) } else { files = []; filesError = nil }
    }

    func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let index = selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? -1
        let next = min(max(0, index + offset), entries.count - 1)
        select(entries[next].id, scroll: true)
    }

    private func requestScroll(to id: String) {
        scrollSerial += 1
        scrollRequest = GitGraphScrollRequest(id: id, serial: scrollSerial)
    }

    private func loadDetails(for commit: GitCommit, keepFile: Bool) {
        guard let store, let project = store.project else { return }
        detailSerial += 1
        let serial = detailSerial
        let keptFile = keepFile ? selectedFile : nil
        if commit.isUncommitted {
            files = store.workspace.changes.map {
                GitCommitFile(path: $0.path, status: FileStatusBadge.letter($0.status), additions: $0.additions, deletions: $0.deletions, isBinary: $0.isBinary)
            }
            filesLoading = false; filesError = nil
            if let keptFile, files.contains(where: { $0.path == keptFile }) { selectFile(keptFile, showsProgress: false) } else if keepFile { selectedFile = nil; diffText = "" }
            return
        }
        filesLoading = true; filesError = nil
        if !keepFile { files = [] }
        Task {
            let result = await service.commitFiles(path: project.path, commit: commit)
            guard serial == detailSerial else { return }
            filesLoading = false
            switch result {
            case .success(let loaded): files = loaded
            case .failure(let error): files = []; filesError = error.message
            }
            if let keptFile, files.contains(where: { $0.path == keptFile }) { selectFile(keptFile, showsProgress: false) }
        }
    }

    func selectFile(_ path: String?, showsProgress: Bool = true) {
        selectedFile = path
        guard let path, let commit = selectedEntry?.commit, let project = store?.project else { diffText = ""; return }
        if showsProgress { diffText = "Loading changes…" }
        let serial = detailSerial
        Task {
            let text = commit.isUncommitted
                ? await service.diff(path: project.path, file: path)
                : await service.commitDiff(path: project.path, commit: commit, file: path)
            guard serial == detailSerial, selectedFile == path else { return }
            if diffText != text { diffText = text }
        }
    }

    // MARK: Search

    private func updateMatches() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { matches = []; matchSet = []; return }
        matches = entries.filter { entry in
            let commit = entry.commit
            return commit.subject.localizedCaseInsensitiveContains(query)
                || commit.author.localizedCaseInsensitiveContains(query)
                || commit.email.localizedCaseInsensitiveContains(query)
                || (!commit.isUncommitted && commit.id.hasPrefix(query.lowercased()))
                || commit.refs.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }.map(\.id)
        matchSet = Set(matches)
        if let selectedID, matchSet.contains(selectedID) { return }
        if let first = matches.first { select(first, scroll: true) }
    }

    /// The position of the selected commit among the matches, from 1, or nil.
    var matchPosition: Int? { selectedID.flatMap { matches.firstIndex(of: $0) }.map { $0 + 1 } }

    func nextMatch(_ step: Int = 1) {
        guard !matches.isEmpty else { return }
        let position = selectedID.flatMap { matches.firstIndex(of: $0) }
        let next: Int
        if let position {
            next = (position + step + matches.count) % matches.count
        } else {
            // From a commit that doesn't match, go to the nearest match in that direction.
            let index = selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? -1
            let order = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
            next = step > 0
                ? matches.firstIndex { (order[$0] ?? 0) > index } ?? 0
                : matches.lastIndex { (order[$0] ?? 0) < index } ?? matches.count - 1
        }
        select(matches[next], scroll: true)
    }

    // MARK: Actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Switches to a branch shown on a commit: a local one, or a remote one as a new tracking branch.
    func switchTo(_ ref: GitRef) {
        guard let store, !switching, ref.kind == .local || ref.kind == .remote else { return }
        let branch = GitBranch(refName: (ref.kind == .remote ? "refs/remotes/" : "refs/heads/") + ref.name, name: ref.name,
                               isRemote: ref.kind == .remote, isCurrent: false, upstream: nil, ahead: 0, behind: 0, date: nil, subject: "")
        switching = true; actionError = nil
        Task {
            actionError = await store.switchBranch(to: branch)
            switching = false
            await reload()
        }
    }

    /// Whether a local branch named `name` exists, so a remote branch can't be checked out again under it.
    func hasLocalBranch(_ name: String) -> Bool {
        graph?.commits.contains { $0.refs.contains { ($0.kind == .local || $0.kind == .head) && $0.name == name } } ?? false
    }
}

// MARK: - Branch switching

extension AppStore {
    /// A task in the selected project is working; switching branches would change files under it.
    var isWorkingInProject: Bool {
        guard let id = state.selectedProjectID else { return false }
        return state.conversations.contains { $0.projectID == id && runs[$0.id]?.isRunning == true }
    }

    /// Returns nil on success, or why git refused.
    func switchBranch(to branch: GitBranch) async -> String? {
        guard let project else { return "Open a project first." }
        guard !isWorkingInProject else { return "Crok is working in this project. Switch branches when the task finishes." }
        let error = await WorkspaceService().switchBranch(path: project.path, to: branch)
        await refreshWorkspace()
        return error
    }

    /// Creates a branch at the current commit and switches to it. Returns nil on success.
    func createBranch(named name: String) async -> String? {
        guard let project else { return "Open a project first." }
        guard !isWorkingInProject else { return "Crok is working in this project. Create the branch when the task finishes." }
        let error = await WorkspaceService().createBranch(path: project.path, name: name)
        await refreshWorkspace()
        return error
    }
}
