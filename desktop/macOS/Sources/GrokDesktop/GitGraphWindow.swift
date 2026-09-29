import AppKit
import SwiftUI

/// The lane colours, bright enough to tell apart on the window's glass in either appearance.
enum GitGraphPalette {
    static let colors: [Color] = [
        Theme.adaptive(0x1C7ED6, 0x4DABF7), // blue
        Theme.adaptive(0x2B8A3E, 0x69DB7C), // green
        Theme.adaptive(0xE8590C, 0xFF922B), // orange
        Theme.adaptive(0xAE3EC9, 0xDA77F2), // grape
        Theme.adaptive(0x0B7285, 0x3BC9DB), // cyan
        Theme.adaptive(0xC2255C, 0xF06595), // pink
        Theme.adaptive(0x9C6F00, 0xFCC419), // yellow
        Theme.adaptive(0x5F3DC4, 0x9775FA), // violet
        Theme.adaptive(0x087F5B, 0x38D9A9), // teal
        Theme.adaptive(0xC92A2A, 0xFF6B6B), // red
        Theme.adaptive(0x364FC7, 0x748FFC), // indigo
        Theme.adaptive(0x5C940D, 0xA9E34B), // lime
    ]
    static let tag = Theme.adaptive(0x9C6F00, 0xFCC419)

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }

    /// A stable colour for a person, from their email.
    static func color(for key: String) -> Color {
        color(key.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }
}

/// `/git-graph`: the selected project's history as a coloured graph of branches and merges,
/// with the selected commit's files and changes beside it.
struct GitGraphWindow: View {
    @EnvironmentObject var model: GitGraphModel

    var body: some View {
        VStack(spacing: 0) {
            GitGraphHeader()
            Divider()
            if let error = model.actionError {
                SessionErrorStrip(message: error).overlay(alignment: .topTrailing) {
                    IconButton(icon: "xmark", help: "Dismiss", size: 24) { model.actionError = nil }.padding(8)
                }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 520)
        .glassWindowBackground()
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Reading the history…").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            }
        case .notRepository(let message):
            SessionEmptyState(symbol: "arrow.triangle.branch", title: "No Git repository here", detail: message)
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.orange).accessibilityHidden(true)
                Text("Could not read the history.").font(.system(size: 14, weight: .medium))
                Text(message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: 560, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                Button("Try again") { Task { await model.reload() } }.buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
            }.padding(40)
        case .loaded:
            if let graph = model.graph, !model.entries.isEmpty {
                GitGraphSplit {
                    GitGraphList(graph: graph)
                } detail: {
                    if let entry = model.selectedEntry {
                        GitCommitDetailView(entry: entry, headID: graph.headID, branch: graph.currentBranch)
                    } else {
                        SessionEmptyState(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Select a commit")
                    }
                }
            } else {
                SessionEmptyState(symbol: "arrow.triangle.branch", title: "No commits yet",
                                  detail: model.scope == .all ? "Commits you make in this repository will show up here." : "Try All to include every branch.")
            }
        }
    }
}

private struct GitGraphHeader: View {
    @EnvironmentObject var model: GitGraphModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Git Graph").font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(-1)
            Spacer(minLength: 12)
            Picker("Show", selection: $model.scope) {
                ForEach(GitGraphScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("All: every branch, remote branch, and tag · Local: your own branches · Current: the checked-out branch's history")
            NativeSearchField(text: $model.query, placeholder: "Search history", onEscape: { model.query = "" },
                              onSubmit: { model.nextMatch() }, onMove: { model.nextMatch($0) }, focusesOnAppear: false)
                .frame(width: 230, height: 32)
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(model.matches.isEmpty ? "No matches" : model.matchPosition.map { "\($0) of \(model.matches.count)" } ?? "\(model.matches.count) found")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).fixedSize()
                IconButton(icon: "chevron.up", help: "Previous match", size: 26) { model.nextMatch(-1) }.disabled(model.matches.isEmpty)
                IconButton(icon: "chevron.down", help: "Next match", size: 26) { model.nextMatch(1) }.disabled(model.matches.isEmpty)
            }
            if model.isLoading || model.switching { ProgressView().controlSize(.small).frame(width: 20) }
            IconButton(icon: "arrow.clockwise", help: "Reload · ⌘R") { Task { await model.reload() } }
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.surface)
    }

    private var subtitle: String {
        guard let graph = model.graph else { return model.projectName }
        var parts = [model.projectName]
        if let branch = graph.currentBranch { parts.append("on \(branch)") } else if let head = graph.headID { parts.append("detached at \(head.prefix(7))") }
        let commits = graph.commits.filter { !$0.isUncommitted }.count
        parts.append("\(commits)\(graph.hasMore ? "+" : "") commits")
        parts.append(graph.branchCount == 1 ? "1 branch" : "\(graph.branchCount) branches")
        if graph.remoteCount > 0 { parts.append("\(graph.remoteCount) remote") }
        if graph.tagCount > 0 { parts.append(graph.tagCount == 1 ? "1 tag" : "\(graph.tagCount) tags") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private let defaultGitGraphDetailWidth: Double = 400

/// The commit list beside the details, with a divider that drags to resize the details.
private struct GitGraphSplit<List: View, Detail: View>: View {
    @AppStorage("gitGraphDetailWidth") private var detailWidth = defaultGitGraphDetailWidth
    @State private var dragStart: CGFloat?
    @State private var showsResizeCursor = false
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let width = Self.clamp(CGFloat(detailWidth), total: total)
            HStack(spacing: 0) {
                list().frame(width: max(0, total - width - 1))
                Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
                    .overlay {
                        Color.clear.frame(width: 9).contentShape(Rectangle())
                            .onHover { inside in
                                guard inside != showsResizeCursor else { return }
                                showsResizeCursor = inside
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    detailWidth = Double(Self.clamp(start - value.translation.width, total: total))
                                }
                                .onEnded { _ in dragStart = nil })
                            .onTapGesture(count: 2) { detailWidth = defaultGitGraphDetailWidth }
                            .help("Drag to resize · double-click to reset")
                    }
                detail().frame(width: width).frame(maxHeight: .infinity)
            }
        }
        .onDisappear { if showsResizeCursor { NSCursor.pop(); showsResizeCursor = false } }
    }

    /// The details keep at least 300 points and leave the list at least 460.
    static func clamp(_ width: CGFloat, total: CGFloat) -> CGFloat {
        min(max(width, 300), max(300, total - 461))
    }
}

// MARK: - Commit list

/// How a list row's width is shared. The graph gets about a third, its lanes narrowing (down to
/// 7 points) before any are clipped, and the description always keeps room: author, then hash,
/// then date make way on a narrow pane. Nothing in a row is ever wider than the list.
struct GitGraphColumnLayout: Equatable {
    static let inset: CGFloat = 4
    static let maxLaneWidth: CGFloat = 16
    static let minLaneWidth: CGFloat = 7
    static let leading: CGFloat = 6
    static let trailing: CGFloat = 12
    static let minDescription: CGFloat = 240
    static let minGraph: CGFloat = 56
    static let rowHeight: CGFloat = 30

    var graph: CGFloat
    var laneWidth: CGFloat
    /// Lanes drawn; lanes past this are clipped behind a fade.
    var visibleLanes: Int
    var lanes: Int
    var description: CGFloat
    /// Zero when the column is hidden.
    var author: CGFloat
    var date: CGFloat
    var hash: CGFloat

    var isClipped: Bool { visibleLanes < lanes }

    static func make(width: CGFloat, lanes: Int) -> Self {
        let available = max(0, width - leading - trailing)
        let lanes = max(1, lanes)
        let budget = max(inset * 2 + maxLaneWidth, (available * 0.3).rounded(.down))
        var laneWidth = maxLaneWidth
        var visible = lanes
        if inset * 2 + maxLaneWidth * CGFloat(lanes) > budget {
            // Half-point steps keep lines on the pixel grid of a Retina display.
            laneWidth = max(minLaneWidth, (((budget - inset * 2) / CGFloat(lanes)) * 2).rounded(.down) / 2)
            visible = max(1, min(lanes, Int((budget - inset * 2) / laneWidth)))
        }
        // At least wide enough for the column's title.
        let graph = max(minGraph, inset * 2 + laneWidth * CGFloat(visible))
        var author: CGFloat = 130, hash: CGFloat = 64, date: CGFloat = 80
        func description() -> CGFloat { available - graph - author - hash - date }
        if description() < minDescription { author = 0 }
        if description() < minDescription { hash = 0 }
        if description() < minDescription { date = 0 }
        return Self(graph: graph, laneWidth: laneWidth, visibleLanes: visible, lanes: lanes,
                    description: max(0, description()), author: author, date: date, hash: hash)
    }
}

private struct GitGraphList: View {
    @EnvironmentObject var model: GitGraphModel
    let graph: GitGraph
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = GitGraphColumnLayout.make(width: geometry.size.width, lanes: graph.laneCount)
            let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
            // Rows from the uncommitted changes down to HEAD carry that lane dashed.
            let uncommittedColor = model.entries.first.flatMap { $0.commit.isUncommitted ? $0.row.color : nil }
            let headIndex = model.entries.first { $0.id == graph.headID }?.index ?? model.entries.count
            VStack(spacing: 0) {
                header(layout)
                Divider().overlay(Theme.line.opacity(0.4))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.entries) { entry in
                                GitGraphRowView(entry: entry, layout: layout,
                                                isHead: entry.id == graph.headID, isSelected: entry.id == model.selectedID,
                                                isDimmed: searching && !model.isMatch(entry.id),
                                                dashedColor: entry.index <= headIndex ? uncommittedColor : nil)
                                    .id(entry.id)
                            }
                            if graph.hasMore {
                                Button { model.loadMore() } label: {
                                    Label("Load \(GitGraphModel.pageSize) more commits", systemImage: "arrow.down.circle")
                                        .font(.system(size: 13, weight: .medium))
                                }.buttonStyle(SubtleButtonStyle()).padding(.vertical, 16).disabled(model.isLoading)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: model.scrollRequest) { _, request in
                        guard let request else { return }
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(request.id, anchor: .center) }
                    }
                }
                // Clicking a commit takes the keyboard back from the search field, for the arrow keys.
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.pageDown) { model.moveSelection(15); return .handled }
        .onKeyPress(.pageUp) { model.moveSelection(-15); return .handled }
        .onKeyPress(.home) { model.moveSelection(-model.entries.count); return .handled }
        .onKeyPress(.end) { model.moveSelection(model.entries.count); return .handled }
        .onAppear { focused = true }
    }

    private func header(_ layout: GitGraphColumnLayout) -> some View {
        HStack(spacing: 0) {
            Text("Graph").padding(.leading, GitGraphColumnLayout.inset)
                .frame(width: layout.graph, alignment: .leading)
                .help(layout.isClipped ? "\(layout.lanes) lanes; widen the list or choose Local to see them all" : "\(layout.lanes) lanes")
            Text("Description").frame(width: layout.description, alignment: .leading)
            if layout.author > 0 { Text("Author").frame(width: layout.author, alignment: .leading) }
            if layout.date > 0 { Text("Date").frame(width: layout.date, alignment: .leading) }
            if layout.hash > 0 { Text("Commit").frame(width: layout.hash, alignment: .leading) }
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
        .padding(.leading, GitGraphColumnLayout.leading).padding(.trailing, GitGraphColumnLayout.trailing)
        .frame(height: 28)
    }
}

private struct GitGraphRowView: View {
    @EnvironmentObject var model: GitGraphModel
    let entry: GitGraphEntry
    let layout: GitGraphColumnLayout
    let isHead: Bool
    let isSelected: Bool
    let isDimmed: Bool
    var dashedColor: Int?
    @State private var hovered = false

    var body: some View {
        let commit = entry.commit
        HStack(spacing: 0) {
            GitGraphLanes(row: entry.row, node: node, layout: layout, dashedColor: dashedColor)
                .frame(width: layout.graph, height: GitGraphColumnLayout.rowHeight)
            // A search dims the text of other commits but never the graph, so the lanes stay whole.
            columns(commit).opacity(isDimmed ? 0.35 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
        .padding(.leading, GitGraphColumnLayout.leading).padding(.trailing, GitGraphColumnLayout.trailing)
        .frame(height: GitGraphColumnLayout.rowHeight)
        .background {
            ZStack {
                if entry.index % 2 == 1 { Theme.tableStripe }
                if isSelected {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.17))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.hover.opacity(0.8)).padding(.horizontal, 3).padding(.vertical, 1)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.select(entry.id) }
        .contextMenu { if !commit.isUncommitted { GitCommitActions(commit: commit) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Everything right of the graph, each in the width the layout gives it.
    private func columns(_ commit: GitCommit) -> some View {
        HStack(spacing: 0) {
            description(commit)
                .padding(.trailing, 10)
                .frame(width: layout.description, alignment: .leading).clipped()
            if layout.author > 0 {
                // The stack stays even when empty (the uncommitted row), so the column keeps its width.
                HStack(spacing: 6) {
                    if !commit.isUncommitted {
                        GitAuthorAvatar(name: commit.author, key: commit.email, size: 17)
                        Text(commit.author).truncationMode(.tail)
                    }
                }
                .padding(.trailing, 8)
                .frame(width: layout.author, alignment: .leading).clipped()
            }
            if layout.date > 0 {
                Text(commit.isUncommitted ? "" : GitDateFormat.relative(commit.date)).monospacedDigit()
                    .frame(width: layout.date, alignment: .leading).help(GitDateFormat.full(commit.date))
            }
            if layout.hash > 0 {
                Text(commit.isUncommitted ? "" : commit.shortID).font(.system(size: 11.5, design: .monospaced))
                    .frame(width: layout.hash, alignment: .leading)
            }
        }
    }

    /// Up to two branch or tag badges, a "+N" for the rest, then the subject in what is left.
    private func description(_ commit: GitCommit) -> some View {
        let badges = GitRefBadge.badges(for: commit.refs)
        let shown = layout.description >= 400 ? 2 : 1
        let hidden = badges.dropFirst(shown)
        let color = GitGraphPalette.color(entry.row.color)
        let badgeWidth = min(220, max(96, (layout.description - 10) * (min(shown, badges.count) > 1 ? 0.38 : 0.5)))
        return HStack(spacing: 5) {
            ForEach(badges.prefix(shown)) { badge in
                GitRefBadge(badge: badge, color: color, maxWidth: badgeWidth, compact: true)
            }
            if !hidden.isEmpty {
                Text("+\(hidden.count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(color.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .help(hidden.map(\.label).joined(separator: "\n"))
            }
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .font(.system(size: 13, weight: isHead ? .semibold : .regular))
                .italic(commit.isUncommitted)
                .foregroundStyle(commit.isUncommitted ? Theme.muted : Theme.ink)
                .truncationMode(.tail)
                .help(commit.subject)
        }
    }

    private var node: GitGraphLanes.Node {
        let commit = entry.commit
        if commit.isUncommitted { return .uncommitted }
        if isHead { return .head }
        return commit.isMerge ? .merge : .commit
    }

    private var accessibilityText: String {
        let commit = entry.commit
        if commit.isUncommitted { return commit.subject }
        let refs = commit.refs.map(\.name).joined(separator: ", ")
        return [commit.subject, refs.isEmpty ? nil : "Refs: \(refs)", "by \(commit.author)", GitDateFormat.relative(commit.date), commit.shortID]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

/// A row's slice of the graph: the lanes crossing it, curves into and out of its lanes, and the
/// commit's node, scaled to the layout's lane width. Lanes past the visible ones run out under a
/// fade at the right edge.
struct GitGraphLanes: View {
    enum Node: Equatable { case commit, merge, head, uncommitted }

    let row: GitGraphRow
    let node: Node
    let layout: GitGraphColumnLayout
    /// The lane from the uncommitted changes down to HEAD, drawn dashed like its node.
    var dashedColor: Int?

    var body: some View {
        let offscreen = row.column >= layout.visibleLanes
        Canvas { context, size in draw(in: &context, size: size) }
            .mask {
                if layout.isClipped {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .trailing) {
                // A commit on a clipped lane still shows which branch it is on.
                if offscreen {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(GitGraphPalette.color(row.color)).padding(.trailing, 1)
                }
            }
            .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let lane = layout.laneWidth
        let height = size.height
        let mid = height / 2
        let visible = layout.visibleLanes
        let radius = min(mid - 2, 7, lane)
        let lineWidth: CGFloat = lane >= 12 ? 2 : 1.6
        // Lanes past the visible ones are drawn to just beyond the edge, under the fade.
        func x(_ index: Int) -> CGFloat {
            GitGraphColumnLayout.inset + lane * (CGFloat(min(index, visible)) + 0.5)
        }
        /// `dashed` nil: dashed only on the uncommitted lane.
        func stroke(_ path: Path, _ color: Int, dashed: Bool? = nil) {
            let dashes = dashed ?? (color == dashedColor)
            context.stroke(path, with: .color(GitGraphPalette.color(color)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dashes ? [2, 3.5] : []))
        }
        func line(_ index: Int, from top: CGFloat, to bottom: CGFloat, color: Int, dashed: Bool? = nil) {
            var path = Path()
            path.move(to: CGPoint(x: x(index), y: top))
            path.addLine(to: CGPoint(x: x(index), y: bottom))
            stroke(path, color, dashed: dashed)
        }

        for index in row.above.indices where index < visible && row.passesThrough(index) {
            if let color = row.above[index] { line(index, from: 0, to: height, color: color) }
        }
        let column = row.column
        let center = x(column)
        if row.up, column < row.above.count, let color = row.above[column] { line(column, from: 0, to: mid, color: color) }
        if row.down, column < row.below.count, let color = row.below[column] {
            // HEAD's own history below it is solid, though its lane arrives dashed.
            line(column, from: mid, to: height, color: color, dashed: node == .uncommitted)
        }
        // A child on another lane joins the node: down its lane, then a rounded turn across.
        for edge in row.mergesIn {
            let edgeX = x(edge.lane)
            var path = Path()
            if edge.lane < visible && edgeX != center {
                let toward: CGFloat = center > edgeX ? 1 : -1
                path.move(to: CGPoint(x: edgeX, y: 0))
                path.addLine(to: CGPoint(x: edgeX, y: mid - radius))
                path.addQuadCurve(to: CGPoint(x: edgeX + toward * radius, y: mid), control: CGPoint(x: edgeX, y: mid))
            } else {
                path.move(to: CGPoint(x: edgeX, y: mid))
            }
            path.addLine(to: CGPoint(x: center, y: mid))
            stroke(path, edge.color)
        }
        // Another parent: across from the node, then a rounded turn down its lane.
        for edge in row.branchesOut {
            let edgeX = x(edge.lane)
            var path = Path()
            path.move(to: CGPoint(x: center, y: mid))
            if edge.lane < visible && edgeX != center {
                let toward: CGFloat = center > edgeX ? 1 : -1
                path.addLine(to: CGPoint(x: edgeX + toward * radius, y: mid))
                path.addQuadCurve(to: CGPoint(x: edgeX, y: mid + radius), control: CGPoint(x: edgeX, y: mid))
                path.addLine(to: CGPoint(x: edgeX, y: height))
            } else {
                path.addLine(to: CGPoint(x: edgeX, y: mid))
            }
            stroke(path, edge.color)
        }

        guard column < visible else { return }
        let color = GitGraphPalette.color(row.color)
        let dot = min(4.5, lane * 0.3 + 0.8)
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center - radius, y: mid - radius, width: radius * 2, height: radius * 2))
        }
        // Hollow nodes clear the lines under them, so the row's background shows through.
        func clear(_ radius: CGFloat) {
            var eraser = context
            eraser.blendMode = .clear
            eraser.fill(circle(radius), with: .color(.black))
        }
        switch node {
        case .commit:
            context.fill(circle(dot), with: .color(color))
        case .merge:
            clear(dot + 1)
            context.stroke(circle(dot - 0.25), with: .color(color), lineWidth: lineWidth + 0.2)
        case .head:
            context.fill(circle(dot + 3.5), with: .color(color.opacity(0.28)))
            context.fill(circle(dot + 1), with: .color(color))
            context.fill(circle(max(1.5, dot * 0.45)), with: .color(.white))
        case .uncommitted:
            clear(dot + 1.5)
            context.stroke(circle(dot + 0.25), with: .color(color), style: StrokeStyle(lineWidth: 1.8, dash: [2.2, 2.2]))
        }
    }
}

// MARK: - Badges

struct GitRefBadge: View {
    /// A branch together with the remote branches of the same name on the same commit, or a tag.
    struct Model: Identifiable, Equatable {
        let ref: GitRef
        /// Remotes whose branch of this name points here too, shown as small cloud labels.
        var remotes: [String] = []
        /// What double-clicking switches to: the branch, or for a remote-only badge, `origin/<name>` when present.
        var target: GitRef
        var id: String { "\(ref.kind.rawValue):\(ref.name)" }
        var label: String { remotes.isEmpty ? ref.name : "\(ref.name) (\(remotes.joined(separator: ", ")))" }
    }

    @EnvironmentObject var model: GitGraphModel
    let badge: Model
    /// The commit's lane colour.
    let color: Color
    var maxWidth: CGFloat = .infinity
    /// In list rows: remote names give way to a cloud glyph, and a remote branch shows its name
    /// without the remote, so the part that tells branches apart survives truncation.
    var compact = false

    /// Branches absorb the remote branches of the same name (`main ☁ origin`), and the same
    /// remote branch on several remotes is one badge (`fix ☁ origin fork`). Current branch first,
    /// then other branches, remote-only branches, and tags.
    static func badges(for refs: [GitRef]) -> [Model] {
        var remotesByBranch: [String: [String]] = [:]
        var remoteOrder: [String] = []
        for ref in refs where ref.kind == .remote {
            let branch = remoteBranchName(ref.name)
            if remotesByBranch[branch] == nil { remoteOrder.append(branch) }
            remotesByBranch[branch, default: []].append(remoteName(ref.name))
        }
        var badges: [Model] = []
        var absorbed = Set<String>()
        for ref in refs where ref.kind == .head || ref.kind == .local {
            let remotes = remotesByBranch[ref.name] ?? []
            if !remotes.isEmpty { absorbed.insert(ref.name) }
            badges.append(Model(ref: ref, remotes: remotes, target: ref))
        }
        for branch in remoteOrder where !absorbed.contains(branch) {
            let remotes = remotesByBranch[branch] ?? []
            let preferred = remotes.contains("origin") ? "origin" : remotes.first ?? ""
            let target = GitRef(name: "\(preferred)/\(branch)", kind: .remote)
            if remotes.count == 1 {
                badges.append(Model(ref: target, target: target))
            } else {
                badges.append(Model(ref: GitRef(name: branch, kind: .remote), remotes: remotes, target: target))
            }
        }
        for ref in refs where ref.kind == .tag { badges.append(Model(ref: ref, target: ref)) }
        return badges
    }

    static func remoteName(_ name: String) -> String { name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name }
    static func remoteBranchName(_ name: String) -> String {
        let parts = name.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : name
    }

    var body: some View {
        let ref = badge.ref
        let tint = ref.kind == .tag ? GitGraphPalette.tag : color
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text(shortensRemote ? Self.remoteBranchName(badge.target.name) : ref.name)
                .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if compact {
                if ref.kind != .remote && !badge.remotes.isEmpty {
                    Image(systemName: "cloud.fill").font(.system(size: 7.5)).opacity(0.8)
                }
                if badge.remotes.count > 1 {
                    Text("\(badge.remotes.count)").font(.system(size: 9.5, weight: .bold)).opacity(0.8)
                }
            } else {
                ForEach(badge.remotes, id: \.self) { remote in
                    HStack(spacing: 2) {
                        Image(systemName: "cloud.fill").font(.system(size: 7.5))
                        Text(remote).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }.opacity(0.8)
                }
            }
        }
        .padding(.horizontal, 6).frame(height: 18)
        .foregroundStyle(ref.kind == .head ? Color.white : tint)
        .background(ref.kind == .head ? tint : tint.opacity(0.15), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(ref.kind == .remote ? 0.75 : 0.35),
                                   style: StrokeStyle(lineWidth: 1, dash: ref.kind == .remote ? [3, 2] : []))
        }
        // As wide as its name needs, up to `maxWidth`; longer names are shortened in the middle.
        .frame(maxWidth: maxWidth)
        .fixedSize()
        .help(help)
        .onTapGesture(count: 2) { if canSwitch { model.switchTo(badge.target) } }
    }

    /// A remote branch drops its remote in a row, unless a local branch has the same name
    /// (`origin/main` beside `main`), where the remote is what tells them apart.
    private var shortensRemote: Bool {
        compact && badge.ref.kind == .remote && !model.hasLocalBranch(Self.remoteBranchName(badge.target.name))
    }

    private var symbol: String {
        switch badge.ref.kind {
        case .head: return "checkmark"
        case .local: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .tag: return "tag.fill"
        }
    }

    private var canSwitch: Bool {
        badge.ref.kind == .local || (badge.ref.kind == .remote && !model.hasLocalBranch(Self.remoteBranchName(badge.target.name)))
    }

    private var help: String {
        switch badge.ref.kind {
        case .head: return "\(badge.label) · the current branch"
        case .local: return "\(badge.label) · double-click to switch to it"
        case .remote:
            return canSwitch ? "\(badge.label) · double-click to check out \(badge.target.name) as \(Self.remoteBranchName(badge.target.name))" : badge.label
        case .tag: return "Tag \(badge.ref.name)"
        }
    }
}

struct GitAuthorAvatar: View {
    let name: String
    let key: String
    var size: CGFloat = 18

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(GitGraphPalette.color(for: key.isEmpty ? name : key), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Copy and branch actions for a commit, in its context menu.
private struct GitCommitActions: View {
    @EnvironmentObject var model: GitGraphModel
    let commit: GitCommit

    var body: some View {
        Button("Copy Commit Hash", systemImage: "number") { model.copy(commit.id) }
        Button("Copy Short Hash") { model.copy(commit.shortID) }
        Button("Copy Subject", systemImage: "text.quote") { model.copy(commit.subject) }
        let local = commit.refs.filter { $0.kind == .local }
        let remote = commit.refs.filter { $0.kind == .remote && !model.hasLocalBranch(GitRefBadge.remoteBranchName($0.name)) }
        if !local.isEmpty || !remote.isEmpty {
            Divider()
            ForEach(local, id: \.name) { ref in
                Button("Switch to \(ref.name)", systemImage: "arrow.triangle.branch") { model.switchTo(ref) }
            }
            ForEach(remote, id: \.name) { ref in
                Button("Check Out \(ref.name) as \(GitRefBadge.remoteBranchName(ref.name))", systemImage: "cloud") { model.switchTo(ref) }
            }
        }
    }
}

// MARK: - Details

private struct GitCommitDetailView: View {
    @EnvironmentObject var model: GitGraphModel
    let entry: GitGraphEntry
    let headID: String?
    let branch: String?

    var body: some View {
        // The commit's details scroll on top; a selected file's diff takes most of the rest.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary
                        if !entry.commit.isUncommitted { metadata }
                        files
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: model.selectedFile == nil ? geometry.size.height : max(180, geometry.size.height * 0.42))
                if model.selectedFile != nil {
                    Divider().overlay(Theme.line.opacity(0.4))
                    diff.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var summary: some View {
        let commit = entry.commit
        return VStack(alignment: .leading, spacing: 8) {
            let badges = GitRefBadge.badges(for: commit.refs)
            if !badges.isEmpty {
                FlowBadges(badges: badges, color: GitGraphPalette.color(entry.row.color))
            }
            Text(commit.isUncommitted ? "Uncommitted changes" : commit.subject)
                .font(.system(size: 16, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if commit.isUncommitted {
                Text(branch.map { "Changes in the working tree on \($0), not yet committed." } ?? "Changes in the working tree, not yet committed.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else if !commit.body.isEmpty {
                Text(commit.body).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var metadata: some View {
        let commit = entry.commit
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Commit")
                HStack(spacing: 6) {
                    Text(commit.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    IconButton(icon: "doc.on.doc", help: "Copy commit hash", size: 22) { model.copy(commit.id) }
                }
            }
            if !commit.parents.isEmpty {
                GridRow {
                    label(commit.parents.count == 1 ? "Parent" : "Parents")
                    HStack(spacing: 6) {
                        ForEach(commit.parents, id: \.self) { parent in
                            Button(String(parent.prefix(7))) { model.select(parent, scroll: true) }
                                .buttonStyle(.link).font(.system(size: 12, design: .monospaced))
                                .help("Go to \(parent.prefix(7))")
                        }
                        if commit.isMerge { Text("merge").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted) }
                    }
                }
            }
            GridRow {
                label("Author")
                HStack(spacing: 7) {
                    GitAuthorAvatar(name: commit.author, key: commit.email, size: 18)
                    Text(commit.author).font(.system(size: 12.5, weight: .medium))
                    Text(commit.email).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }.textSelection(.enabled)
            }
            GridRow {
                label("Date")
                let relative = GitDateFormat.relative(commit.date)
                // Past a week the relative form is only the date again.
                Text(relative.hasSuffix("ago") || relative == "just now" ? "\(GitDateFormat.full(commit.date)) · \(relative)" : GitDateFormat.full(commit.date))
                    .font(.system(size: 12.5))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).gridColumnAlignment(.trailing)
    }

    @ViewBuilder private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Changed files").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                if !model.files.isEmpty {
                    Text("\(model.files.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.hover, in: Capsule())
                    Spacer(minLength: 4)
                    Text("+\(model.files.reduce(0) { $0 + $1.additions })").foregroundStyle(Theme.green)
                    Text("−\(model.files.reduce(0) { $0 + $1.deletions })").foregroundStyle(Theme.red)
                }
            }.font(.system(size: 11.5, design: .monospaced))
            if model.filesLoading && model.files.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            } else if let error = model.filesError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red)
            } else if model.files.isEmpty {
                Text(entry.commit.isMerge ? "No changes against the first parent." : "No file changes.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(model.files) { file in GitCommitFileRow(file: file, selected: model.selectedFile == file.path) }
                }
                if model.selectedFile == nil {
                    Text("Select a file to see its changes.").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder private var diff: some View {
        if let file = model.selectedFile {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(Theme.muted)
                    Text(file).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    IconButton(icon: "doc.on.doc", help: "Copy path", size: 24) { model.copy(file) }
                    IconButton(icon: "xmark", help: "Close diff", size: 24) { model.selectFile(nil) }
                }.padding(.horizontal, 12).frame(height: 36)
                Divider().overlay(Theme.line.opacity(0.4))
                ReadOnlyTextView(text: model.diffText, style: .diff, wrapsLines: false, sizing: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.codeBackground.opacity(0.6))
        }
    }
}

private struct GitCommitFileRow: View {
    @EnvironmentObject var model: GitGraphModel
    let file: GitCommitFile
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        Button { model.selectFile(selected ? nil : file.path) } label: {
            HStack(spacing: 8) {
                FileStatusBadge(status: file.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
                    if file.path.contains("/") {
                        Text((file.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Group {
                    if file.isBinary { Text("binary").foregroundStyle(Theme.muted) }
                    else {
                        Text("+\(file.additions)").foregroundStyle(Theme.green)
                        Text("−\(file.deletions)").foregroundStyle(Theme.red)
                    }
                }.font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            .background(selected ? Theme.accent.opacity(0.16) : hovered ? Theme.hover.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(file.path)
        .contextMenu { Button("Copy Path", systemImage: "doc.on.doc") { model.copy(file.path) } }
    }
}

/// Badges that wrap onto more lines when the pane is narrow.
private struct FlowBadges: View {
    let badges: [GitRefBadge.Model]
    let color: Color

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(badges) { GitRefBadge(badge: $0, color: color, maxWidth: 320) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
