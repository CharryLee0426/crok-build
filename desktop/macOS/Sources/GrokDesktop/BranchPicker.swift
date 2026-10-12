import SwiftUI

/// Under the composer: the project's branch, which opens the branch picker, the Git Graph, and the task's token figures.
/// A project outside Git has only the figures, and no row at all until there are some.
struct ComposerGitFooter: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var gitGraph: GitGraphModel
    @EnvironmentObject var tokens: TokenMeterModel
    @ObservedObject private var language = L10n.state
    @State private var showBranches = false

    var body: some View {
        let hasBranch = !store.workspace.branch.isEmpty
        let readout = store.state.selectedConversationID.flatMap { tokens.meters[$0] }?.readout(turnRunning: store.run.isRunning)
        if hasBranch || readout != nil {
            HStack(spacing: 2) {
                if hasBranch { git }
                if let readout { ComposerTokenStats(readout: readout) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12)).lineLimit(1).foregroundStyle(Theme.muted)
            .frame(height: 22)
        }
    }

    @ViewBuilder
    private var git: some View {
        if store.workspace.rootPath != nil {
            Button { showBranches.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(store.workspace.branch).fontWeight(.medium).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                }
            }
            .buttonStyle(FooterChipStyle(active: showBranches))
            .help("Switch branch")
            .accessibilityLabel("Branch \(store.workspace.branch). Switch branch")
            .popover(isPresented: $showBranches, arrowEdge: .top) { BranchPickerPopover(isPresented: $showBranches) }
            Button { gitGraph.open() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.merge")
                    Text("Git Graph").fontWeight(.medium)
                }
            }
            .buttonStyle(FooterChipStyle())
            .help("Browse commits, branches, and merges · /git-graph")
        } else {
            // Outside Git the snapshot carries the "No repository" marker, shown in the interface language.
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(store.workspace.branch == GitWorkspaceSnapshot.noRepository ? L10n.t("no_repository", "No repository") : store.workspace.branch)
                    .fontWeight(.medium).truncationMode(.middle)
            }.padding(.horizontal, 5)
        }
    }
}

/// A quiet footer control that shows it can be clicked only on hover.
struct FooterChipStyle: ButtonStyle {
    var active = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(hovered || active ? Theme.ink : Theme.muted)
            .background(configuration.isPressed || active ? Theme.hover : hovered ? Theme.hover.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

/// Lists the project's branches to switch to, and creates a branch from what's typed.
struct BranchPickerPopover: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool
    @State private var branches = GitBranchList()
    @State private var loading = true
    @State private var query = ""
    @State private var highlighted = 0
    /// The row being switched to, while git works.
    @State private var working: String?
    @State private var error: String?

    private enum Item: Identifiable, Equatable {
        case create(String)
        case branch(GitBranch)

        var id: String {
            switch self {
            case .create(let name): return "create:" + name
            case .branch(let branch): return branch.id
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ branch: GitBranch) -> Bool { trimmedQuery.isEmpty || branch.name.localizedCaseInsensitiveContains(trimmedQuery) }
    private var local: [GitBranch] { branches.local.filter(matches) }
    private var remote: [GitBranch] { branches.remote.filter(matches) }
    private var createName: String? {
        let name = trimmedQuery.replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, !branches.local.contains(where: { $0.name == name }) else { return nil }
        return name
    }
    private var items: [Item] { (createName.map { [Item.create($0)] } ?? []) + local.map(Item.branch) + remote.map(Item.branch) }
    private var busy: Bool { store.isWorkingInProject }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Switch branch").font(.system(size: 16, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding([.horizontal, .top], 16)
            NativeSearchField(text: $query, placeholder: "Find or create a branch", onEscape: { isPresented = false },
                              onSubmit: { if let item = items[safe: highlighted] { activate(item) } },
                              onMove: { move($0) })
                .frame(height: 40).padding(12)
            if busy {
                notice("Crok is working in this project. Switch branches when the task finishes.", symbol: "hourglass", color: Theme.muted)
            }
            if let error { notice(error, symbol: "exclamationmark.triangle.fill", color: Theme.red) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let name = createName {
                            createRow(name, highlighted: items.first == .create(name) && highlighted == 0)
                        }
                        if !local.isEmpty { sectionTitle("Local") }
                        ForEach(local) { branchRow($0) }
                        if !remote.isEmpty { sectionTitle("Remote") }
                        ForEach(remote) { branchRow($0) }
                        if items.isEmpty && !loading {
                            Text(branches.error ?? "No branches match “\(trimmedQuery)”.")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }.padding(7)
                }
                .onChange(of: highlighted) { _, index in
                    if let item = items[safe: index] { proxy.scrollTo(item.id) }
                }
            }
            .frame(height: 320)
            Divider()
            Text("Uncommitted changes come with you; Git stops a switch that would overwrite them.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(14)
        }
        .frame(width: 420)
        .task { await load() }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func load() async {
        guard let project = store.project else { loading = false; return }
        loading = true
        branches = await WorkspaceService().branches(path: project.path)
        loading = false
    }

    private func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        highlighted = min(max(0, highlighted + offset), items.count - 1)
    }

    private func activate(_ item: Item) {
        guard working == nil, !busy else { return }
        if case .branch(let branch) = item, branch.isCurrent { isPresented = false; return }
        working = item.id; error = nil
        Task {
            let failure: String?
            switch item {
            case .create(let name): failure = await store.createBranch(named: name)
            case .branch(let branch): failure = await store.switchBranch(to: branch)
            }
            working = nil
            if let failure {
                error = failure
                await load()
            } else {
                isPresented = false
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).padding(.horizontal, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func createRow(_ name: String, highlighted: Bool) -> some View {
        Button { activate(.create(name)) } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 19)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create branch “\(name)”").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text("From \(branches.current?.name ?? store.workspace.branch), and switch to it").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if working == Item.create(name).id { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(PopoverRowStyle())
        .background(highlighted ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        .disabled(busy || working != nil)
        .id(Item.create(name).id)
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        let isHighlighted = items[safe: highlighted]?.id == branch.id
        return Button { activate(.branch(branch)) } label: {
            HStack(spacing: 11) {
                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch").font(.system(size: 13))
                    .foregroundStyle(branch.isCurrent ? Theme.accent : Theme.muted).frame(width: 19)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(branch.name).font(.system(size: 14, weight: branch.isCurrent ? .semibold : .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        if branch.ahead > 0 { Text("↑\(branch.ahead)").help("\(branch.ahead) commits to push") }
                        if branch.behind > 0 { Text("↓\(branch.behind)").help("\(branch.behind) commits to pull") }
                    }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.muted)
                    Text(detail(branch)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if working == branch.id {
                    ProgressView().controlSize(.small)
                } else if branch.isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(PopoverRowStyle())
        .background(isHighlighted || branch.isCurrent ? Theme.hover.opacity(isHighlighted ? 1 : 0.5) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .disabled((busy && !branch.isCurrent) || working != nil)
        .help(branch.isRemote ? "Check out \(branch.name) as a local branch, \(branch.localName)" : branch.isCurrent ? "The current branch" : "Switch to \(branch.name)")
        .accessibilityAddTraits(branch.isCurrent ? .isSelected : [])
        .id(branch.id)
    }

    private func detail(_ branch: GitBranch) -> String {
        var parts: [String] = []
        if let date = branch.date { parts.append(GitDateFormat.relative(date)) }
        if !branch.subject.isEmpty { parts.append(branch.subject) }
        if branch.isRemote { parts.insert("Creates \(branch.localName)", at: 0) }
        return parts.joined(separator: " · ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
