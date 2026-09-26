import AppKit
import SwiftUI

// `/import-claude`: the terminal's import modal as a sheet. The scan, merge, marker, and state file
// live in ClaudeImport.swift; this file holds the flow and the checkbox tree.

/// The command's flow, matching the terminal: scan first; when nothing is importable, record the
/// choice and say so; otherwise show the sheet with everything selected.
@MainActor
enum ClaudeImportFlow {
    /// A plan scanned by `begin`, handed to the sheet it opens.
    private static var pending: (plan: ClaudeImportPlan, environment: ClaudeImportEnvironment)?

    nonisolated static let nothingFound = "No Claude settings found to import."
    nonisolated static let nothingSelected = "No items selected."

    static func begin(store: AppStore) {
        let environment = ClaudeImportEnvironment.current(projectPath: store.project?.path)
        Task { [weak store] in
            let plan = await Task.detached { ClaudeImportScanner.scan(environment) }.value
            guard let store else { return }
            if plan.isEmpty {
                await recordChoice(environment)
                store.banner = nothingFound
            } else {
                pending = (plan, environment)
                store.sheet = .importClaude
            }
        }
    }

    static func takePending() -> (plan: ClaudeImportPlan, environment: ClaudeImportEnvironment)? {
        defer { pending = nil }
        return pending
    }

    /// Records the current Claude settings as seen and writes the `[claude_compat]` marker, which the
    /// terminal does whether or not anything was imported. Failures only affect re-prompting, so they
    /// are not reported (the terminal logs them).
    nonisolated static func recordChoice(_ environment: ClaudeImportEnvironment) async {
        await Task.detached {
            try? ClaudeImportState.markImported(environment)
            try? ClaudeImporter.markImported(environment)
        }.value
    }

    /// Applies the selection and returns the notice the terminal shows.
    nonisolated static func importSelection(_ plan: ClaudeImportPlan, selected: Set<Int>, environment: ClaudeImportEnvironment) async -> String {
        await Task.detached {
            let filtered = plan.filtered(selected)
            var summary = nothingSelected
            if !filtered.isEmpty {
                do {
                    let result = try ClaudeImporter.apply(filtered, environment: environment)
                    summary = "Imported \(result.total) of \(plan.totalItems) setting(s)."
                        + result.modifiedFiles.map { "\nUpdated: \($0)" }.joined()
                } catch {
                    return "Failed to import Claude settings: \(error.localizedDescription)"
                }
            }
            try? ClaudeImportState.markImported(environment)
            try? ClaudeImporter.markImported(environment)
            return summary
        }.value
    }
}

// MARK: - Model

/// One row of the tree: a scope, a kind of setting within it, or an item.
enum ClaudeImportRow: Hashable, Identifiable {
    case scope(ClaudeImportScope)
    case group(ClaudeImportScope, ClaudeImportItemKind)
    /// An item by its flat index (global items first, then project items).
    case item(Int)

    var id: Self { self }
    var isHeader: Bool { if case .item = self { return false }; return true }
}

enum ClaudeImportCheck { case on, off, mixed }

@MainActor
final class ClaudeImportModel: ObservableObject {
    enum Phase: Equatable { case scanning, ready, importing }

    @Published private(set) var phase = Phase.scanning
    @Published private(set) var plan: ClaudeImportPlan?
    @Published var selected: Set<Int> = []
    @Published private(set) var collapsed: Set<ClaudeImportRow> = []
    @Published var focus: ClaudeImportRow?
    private(set) var environment: ClaudeImportEnvironment?
    private var loadStarted = false

    init() {}

    /// A model already holding a plan (for previews, tests, and the flow's pre-scanned plan).
    init(plan: ClaudeImportPlan, environment: ClaudeImportEnvironment) {
        show(plan, environment: environment)
    }

    private func show(_ plan: ClaudeImportPlan, environment: ClaudeImportEnvironment) {
        self.plan = plan
        self.environment = environment
        selected = Set(0..<plan.totalItems)
        phase = .ready
        focus = rows.first { !$0.isHeader } ?? rows.first
    }

    func load(store: AppStore) async {
        guard phase == .scanning, plan == nil, !loadStarted else { return }
        loadStarted = true
        if let pending = ClaudeImportFlow.takePending() { show(pending.plan, environment: pending.environment); return }
        let environment = ClaudeImportEnvironment.current(projectPath: store.project?.path)
        let plan = await Task.detached { ClaudeImportScanner.scan(environment) }.value
        if plan.isEmpty {
            await ClaudeImportFlow.recordChoice(environment)
            store.banner = ClaudeImportFlow.nothingFound
            if store.sheet == .importClaude { store.sheet = nil }
        } else {
            show(plan, environment: environment)
        }
    }

    func confirm(store: AppStore) async {
        guard phase == .ready, let plan, let environment else { return }
        phase = .importing
        let summary = await ClaudeImportFlow.importSelection(plan, selected: selected, environment: environment)
        store.banner = summary
        if store.sheet == .importClaude { store.sheet = nil }
    }

    // MARK: Tree

    var totalCount: Int { plan?.totalItems ?? 0 }
    var selectedCount: Int { selected.count }

    func offset(_ scope: ClaudeImportScope) -> Int { scope == .global ? 0 : plan?.global.count ?? 0 }

    func item(_ index: Int) -> ClaudeImportItem? {
        guard let plan else { return nil }
        return index < plan.global.count ? plan.global[safe: index] : plan.project[safe: index - plan.global.count]
    }

    /// The flat indices under a header.
    func indices(_ row: ClaudeImportRow) -> [Int] {
        guard let plan else { return [] }
        switch row {
        case .scope(let scope): return Array(offset(scope)..<offset(scope) + plan.items(scope).count)
        case let .group(scope, kind):
            return plan.items(scope).enumerated().filter { $0.element.kind == kind }.map { offset(scope) + $0.offset }
        case .item(let index): return [index]
        }
    }

    /// Scopes, then kinds in the terminal's order (permissions, env, MCP, hooks, paths), then items
    /// in scan order, leaving out whatever sits under a folded header.
    var rows: [ClaudeImportRow] {
        guard let plan else { return [] }
        var rows: [ClaudeImportRow] = []
        for scope in [ClaudeImportScope.global, .project] where !plan.items(scope).isEmpty {
            rows.append(.scope(scope))
            if collapsed.contains(.scope(scope)) { continue }
            let kinds = Set(plan.items(scope).map(\.kind)).sorted()
            for kind in kinds {
                let group = ClaudeImportRow.group(scope, kind)
                rows.append(group)
                if !collapsed.contains(group) { rows += indices(group).map(ClaudeImportRow.item) }
            }
        }
        return rows
    }

    func check(_ row: ClaudeImportRow) -> ClaudeImportCheck {
        let indices = indices(row)
        let count = indices.filter(selected.contains).count
        return count == 0 ? .off : count == indices.count ? .on : .mixed
    }

    /// Items flip; a header selects everything under it unless it all is selected already.
    func toggle(_ row: ClaudeImportRow) {
        let indices = indices(row)
        if case .item(let index) = row { if !selected.insert(index).inserted { selected.remove(index) }; return }
        if indices.allSatisfy(selected.contains) { selected.subtract(indices) } else { selected.formUnion(indices) }
    }

    func selectAll() { selected = Set(0..<totalCount) }
    func selectNone() { selected = [] }

    func isCollapsed(_ row: ClaudeImportRow) -> Bool { collapsed.contains(row) }

    func setCollapsed(_ row: ClaudeImportRow, _ folded: Bool) {
        guard row.isHeader else { return }
        if folded { collapsed.insert(row) } else { collapsed.remove(row) }
        if let focus, !rows.contains(focus) { self.focus = row }
    }

    /// The nearest header above a row.
    func parent(of row: ClaudeImportRow) -> ClaudeImportRow? {
        let rows = rows
        guard let position = rows.firstIndex(of: row) else { return nil }
        return rows[..<position].last { header in
            switch (header, row) {
            case (.scope, .group), (.scope, .item), (.group, .item): return true
            default: return false
            }
        }
    }

    // MARK: Keyboard

    func moveFocus(_ step: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        guard let focus, let position = rows.firstIndex(of: focus) else { self.focus = rows.first; return }
        self.focus = rows[min(max(position + step, 0), rows.count - 1)]
    }

    func focusEdge(last: Bool) { focus = last ? rows.last : rows.first }

    /// ← folds an open header, otherwise moves to the parent header.
    func foldOrParent() {
        guard let focus else { return }
        if focus.isHeader && !isCollapsed(focus) { setCollapsed(focus, true) }
        else if let parent = parent(of: focus) { self.focus = parent }
    }

    /// → opens a folded header.
    func unfold() {
        guard let focus, focus.isHeader else { return }
        setCollapsed(focus, false)
    }

    // MARK: Labels

    /// The header text, as the terminal writes it.
    func label(_ row: ClaudeImportRow) -> String {
        switch row {
        case .scope(.global): return "Global  ~/.crok/config.toml"
        case .scope(.project): return "Project  \(plan?.projectConfigPath ?? "")"
        case let .group(_, kind): return "\(kind.title) (\(indices(row).count))"
        case .item(let index): return item(index)?.label ?? ""
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Sheet

/// `/import-claude`: imports Claude Code settings into Grok's configuration.
struct ImportClaudeSheet: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model: ClaudeImportModel
    @FocusState private var listFocused: Bool

    init() { _model = StateObject(wrappedValue: ClaudeImportModel()) }

    /// A sheet showing a known plan, without scanning (snapshots and tests).
    init(model: ClaudeImportModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        DesktopPanel(title: "Import Claude settings",
                     subtitle: "Bring your Claude Code permissions, environment, MCP servers, hooks, and skill folders into Crok. Settings Crok already has are left as they are.",
                     width: 760, height: 620, onClose: close) {
            content
        } footer: {
            footer
        }
        .task { await model.load(store: store) }
    }

    @ViewBuilder private var content: some View {
        if model.plan == nil {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Looking for Claude settings…").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.rows) { row in
                            ClaudeImportRowView(model: model, row: row, focused: model.focus == row)
                                .id(row)
                                .padding(.top, row.isScopeHeader && row != model.rows.first ? 14 : 0)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .focusable()
                .focused($listFocused)
                .help("↑↓ move · Space toggles · ←→ fold · A all · N none · Return imports")
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end, .space]) { press in
                    switch press.key {
                    case .upArrow: model.moveFocus(-1)
                    case .downArrow: model.moveFocus(1)
                    case .leftArrow: FoldMotion.toggle { model.foldOrParent() }
                    case .rightArrow: FoldMotion.toggle { model.unfold() }
                    case .home: model.focusEdge(last: false)
                    case .end: model.focusEdge(last: true)
                    default: if let focus = model.focus { model.toggle(focus) }
                    }
                    if let focus = model.focus { proxy.scrollTo(focus) }
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "ajknhlgG")) { press in
                    switch press.characters {
                    case "a": model.selectAll()
                    case "n": model.selectNone()
                    case "j": model.moveFocus(1)
                    case "k": model.moveFocus(-1)
                    case "h": FoldMotion.toggle { model.foldOrParent() }
                    case "l": FoldMotion.toggle { model.unfold() }
                    case "g": model.focusEdge(last: false)
                    default: model.focusEdge(last: true)
                    }
                    // Only keyboard moves scroll; hovering also moves focus and must not jump the list.
                    if let focus = model.focus { proxy.scrollTo(focus) }
                    return .handled
                }
                .onAppear { listFocused = true }
                .onChange(of: model.phase) { _, phase in if phase == .ready { listFocused = true } }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        Button("All") { model.selectAll() }
            .help("Select every setting · A")
            .disabled(model.phase != .ready)
        Button("None") { model.selectNone() }
            .help("Clear the selection · N")
            .disabled(model.phase != .ready)
        Text(model.plan == nil ? "" : "\(model.selectedCount) of \(model.totalCount) selected")
            .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
            .padding(.leading, 4)
        Spacer()
        Button("Cancel", action: close)
        Button {
            Task { await model.confirm(store: store) }
        } label: {
            HStack(spacing: 7) {
                if model.phase == .importing { ProgressView().controlSize(.mini) }
                Text("Import \(model.selectedCount)")
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.phase != .ready)
        .accessibilityLabel("Import \(model.selectedCount) settings")
    }

    private func close() {
        guard model.phase != .importing else { return }
        store.sheet = nil
    }
}

private extension ClaudeImportRow {
    var isScopeHeader: Bool { if case .scope = self { return true }; return false }
}

private struct ClaudeImportRowView: View {
    @ObservedObject var model: ClaudeImportModel
    let row: ClaudeImportRow
    let focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if row.isHeader {
                Button { FoldMotion.toggle { model.setCollapsed(row, !model.isCollapsed(row)) } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(model.isCollapsed(row) ? 0 : 90))
                        .frame(width: 18, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isCollapsed(row) ? "Expand" : "Collapse")
                .accessibilityLabel(model.isCollapsed(row) ? "Expand \(model.label(row))" : "Collapse \(model.label(row))")
            }
            Button { model.focus = row; model.toggle(row) } label: {
                HStack(spacing: 9) {
                    ClaudeImportCheckbox(state: model.check(row))
                    title
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.label(row))
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isToggle)
        }
        .padding(.leading, indent)
        .padding(.trailing, 10)
        .padding(.vertical, 1)
        .background(focused ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { if $0 { model.focus = row } }
    }

    private var indent: CGFloat {
        switch row {
        case .scope: return 4
        case .group: return 26
        case .item: return 74
        }
    }

    private var accessibilityValue: String {
        switch model.check(row) {
        case .on: return "Selected"
        case .off: return "Not selected"
        case .mixed: return "Partly selected"
        }
    }

    @ViewBuilder private var title: some View {
        switch row {
        case .scope(let scope):
            HStack(spacing: 10) {
                Text(scope == .global ? "Global" : "Project").font(.system(size: 14, weight: .semibold))
                Text(scope == .global ? "~/.crok/config.toml" : model.plan?.projectConfigPath ?? "")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .group:
            Text(model.label(row)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.85))
        case .item(let index):
            itemTitle(model.item(index))
        }
    }

    @ViewBuilder private func itemTitle(_ item: ClaudeImportItem?) -> some View {
        switch item {
        case .permission(let rule)?:
            // The pager's `allow Bash(pattern)`, with the action tinted.
            let label = item?.label ?? ""
            let action = String(label.prefix(5)), rest = String(label.dropFirst(6))
            (Text(action).foregroundColor(actionColor(rule.action)) + Text(" ") + Text(rest))
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        case .mcpServer(let name, let server)?:
            HStack(spacing: 10) {
                Text(name).font(.system(size: 12.5, design: .monospaced))
                Text(server.summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
        case let item?:
            Text(item.label).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(item.label)
        case nil:
            EmptyView()
        }
    }

    private func actionColor(_ action: ClaudeRuleAction) -> Color {
        switch action {
        case .allow: return Theme.green
        case .deny: return Color(nsColor: .systemRed)
        case .ask: return Color(nsColor: .systemOrange)
        }
    }
}

/// A tri-state checkbox mark: on, off, or partly on for a header.
struct ClaudeImportCheckbox: View {
    let state: ClaudeImportCheck

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(state == .off ? Theme.muted : Theme.accent)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}
