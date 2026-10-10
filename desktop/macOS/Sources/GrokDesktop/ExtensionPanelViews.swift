import AppKit
import SwiftUI

// MARK: - Shared pieces

extension View {
    /// The card every extension row sits on, matching the FeatureBrowser's rows.
    func extensionCard(highlighted: Bool = false) -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Theme.accent.opacity(0.55) : Theme.line.opacity(0.3), lineWidth: highlighted ? 1 : 0.5))
    }
}

/// A small capsule label for scopes, versions, counts, and states.
struct ExtensionBadge: View {
    enum Tone { case neutral, accent, warning }
    let text: String
    var symbol: String? = nil
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tone == .accent ? Theme.accent : tone == .warning ? Color.orange : Theme.muted)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tone == .accent ? Theme.accent.opacity(0.13) : tone == .warning ? Color.orange.opacity(0.13) : Theme.hover.opacity(0.8), in: Capsule())
    }
}

struct ExtensionGroupHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            if let count { Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.muted.opacity(0.8)) }
            Spacer(minLength: 8)
            trailing()
        }.padding(.top, 4).padding(.horizontal, 2)
    }
}

extension ExtensionGroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) { self.init(title: title, count: count, trailing: { EmptyView() }) }
}

/// All / Enabled / Disabled, like the terminal's `f` key.
struct ExtensionFilterBar: View {
    @Binding var filter: ExtensionFilter
    var summary: String

    var body: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(ExtensionFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

/// An informational or warning callout inside a panel.
struct ExtensionCallout<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var warning = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(warning ? Color.orange : Theme.accent).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(14)
        .background((warning ? Color.orange : Theme.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((warning ? Color.orange : Theme.accent).opacity(0.25), lineWidth: 0.5))
        .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
    }
}

extension ExtensionCallout where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, warning: Bool = false) {
        self.init(symbol: symbol, title: title, detail: detail, warning: warning, actions: { EmptyView() })
    }
}

struct ExtensionEmptyState: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(Theme.muted)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(35)
    }
}

/// A path in a monospaced caption that can be opened in Finder.
struct ExtensionPathLine: View {
    let path: String
    var body: some View {
        HStack(spacing: 6) {
            Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Show in Finder").accessibilityLabel("Show \(path) in Finder")
        }
    }
}

// MARK: - Plugins

struct PluginsPanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let rows: [FeatureRow]
    let disabled: Bool
    @Binding var filter: ExtensionFilter

    private var visible: [FeatureRow] { rows.filter { filter.matches($0.enabled) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !rows.isEmpty {
                ExtensionFilterBar(filter: $filter, summary: "\(rows.filter { $0.enabled != false }.count) of \(rows.count) enabled")
            }
            let groups = Dictionary(grouping: visible) { PluginGroupLabel.group($0.payload).key }
                .map { (key: $0.key, info: PluginGroupLabel.group($0.value[0].payload), rows: $0.value) }
                .sorted { ($0.info.rank, $0.info.label) < ($1.info.rank, $1.info.label) }
            ForEach(groups, id: \.key) { group in
                ExtensionGroupHeader(title: group.info.label, count: group.rows.count)
                ForEach(group.rows) { PluginCard(row: $0, disabled: disabled) }
            }
            if !rows.isEmpty && visible.isEmpty {
                ExtensionEmptyState(symbol: "line.3.horizontal.decrease.circle", text: "No \(filter.rawValue.lowercased()) plugins.")
            }
        }
    }
}

private struct PluginCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let row: FeatureRow
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3) }
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { row.enabled ?? true }, set: { _ in store.toggleFeature(row, panel: .plugins) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(disabled)
                    .accessibilityLabel("Enable \(row.title)")
            }
            let badges = PluginGroupLabel.badges(row.payload)
            if !badges.isEmpty {
                HStack(spacing: 6) { ForEach(badges, id: \.self) { ExtensionBadge(text: $0, tone: $0.hasSuffix("blocked") ? .warning : .neutral) } }
            }
            if let conflict = row.payload["conflict"] as? String, !conflict.isEmpty {
                Label(conflict, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let root = row.payload["root"] as? String { ExtensionPathLine(path: root) }
                Spacer(minLength: 8)
                Button("Update") { store.runPluginsAction(.update(pluginID: row.id)) }.disabled(disabled)
                    .help("Fetch the latest version from the plugin's source")
                Button("Uninstall…") {
                    extensions.pendingConfirmation = ExtensionConfirmation(panel: .plugins, message: "Uninstall plugin \"\(row.title)\"?", confirmTitle: "Uninstall") {
                        store.runPluginsAction(.uninstall(pluginID: row.id, confirmed: false))
                    }
                }.disabled(disabled)
            }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
        }.extensionCard()
    }
}

// MARK: - Hooks

struct HooksPanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let rows: [FeatureRow]
    let disabled: Bool
    @Binding var filter: ExtensionFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let trusted = extensions.hooksTrusted {
                if trusted {
                    ExtensionCallout(symbol: "checkmark.shield", title: "This project is trusted", detail: "Hooks defined in this repository can run.") {
                        Button("Untrust") { store.runHooksAction(.untrust) }.disabled(disabled)
                    }
                } else {
                    ExtensionCallout(symbol: "exclamationmark.shield", title: "This project isn't trusted", detail: "Hooks defined in this repository won't run until you trust it.", warning: true) {
                        Button("Trust project") { store.runHooksAction(.trust) }.disabled(disabled)
                    }
                }
            }
            if !extensions.hooksLoadErrors.isEmpty {
                ExtensionCallout(symbol: "exclamationmark.triangle", title: extensions.hooksLoadErrors.count == 1 ? "A hook configuration couldn't be loaded" : "\(extensions.hooksLoadErrors.count) hook configurations couldn't be loaded",
                                 detail: extensions.hooksLoadErrors.joined(separator: "\n"), warning: true)
            }
            if !rows.isEmpty {
                ExtensionFilterBar(filter: $filter, summary: "\(rows.filter { $0.enabled != false }.count) of \(rows.count) enabled")
            }
            ForEach(HookSourceGroup.groups(rows)) { group in
                let hooks = group.hooks.filter { filter.matches($0.enabled) }
                if !hooks.isEmpty { HookGroupView(group: group, hooks: hooks, disabled: disabled) }
            }
        }
    }
}

private struct HookGroupView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let group: HookSourceGroup
    let hooks: [FeatureRow]
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtensionGroupHeader(title: group.label, count: group.hooks.count) {
                if group.pinned { ExtensionBadge(text: "Managed", symbol: "lock.fill") }
                if group.removable {
                    IconButton(icon: "trash", help: "Remove hook source", size: 26) {
                        extensions.pendingConfirmation = ExtensionConfirmation(panel: .hooks, message: "Remove hook source \"\(group.label)\"?",
                            detail: group.sourceDir, confirmTitle: "Remove") { store.runHooksAction(.remove(path: group.sourceDir)) }
                    }.disabled(disabled)
                }
                Toggle("All hooks in \(group.label)", isOn: Binding(get: { group.anyEnabled }, set: { _ in
                    store.runHooksAction(.toggleSource(hookNames: group.hooks.map(\.id), disable: group.anyEnabled))
                })).toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(disabled || group.hooks.allSatisfy { $0.payload["pinned"] as? Bool == true })
                    .help(group.anyEnabled ? "Disable every hook from this source" : "Enable every hook from this source")
            }
            ForEach(hooks) { HookRow(row: $0, disabled: disabled) }
        }
    }
}

private struct HookRow: View {
    @EnvironmentObject var store: AppStore
    let row: FeatureRow
    let disabled: Bool
    private var pinned: Bool { row.payload["pinned"] as? Bool == true }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.payload["handlerType"] as? String == "http" ? "network" : "terminal")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 18).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.subtitle).font(.system(size: 14, weight: .semibold))
                    if let matcher = row.payload["matcher"] as? String, !matcher.isEmpty { ExtensionBadge(text: matcher) }
                    if pinned { ExtensionBadge(text: "Pinned", symbol: "lock.fill") }
                }
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if let timeout = (row.payload["timeoutMs"] as? NSNumber)?.intValue, timeout > 0 {
                    Text("Timeout \(timeout >= 1000 ? "\(timeout / 1000)s" : "\(timeout)ms")").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { row.enabled ?? true }, set: { _ in store.toggleFeature(row, panel: .hooks) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(disabled || pinned)
                .help(pinned ? "Enforced by managed policy" : "")
                .accessibilityLabel("Enable \(row.subtitle) hook")
        }.extensionCard()
    }
}

// MARK: - Skills

struct SkillsPanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let rows: [FeatureRow]
    let disabled: Bool
    @Binding var filter: ExtensionFilter
    @State private var showSources: Bool

    init(rows: [FeatureRow], disabled: Bool, filter: Binding<ExtensionFilter>, showSources: Bool = false) {
        self.rows = rows; self.disabled = disabled; _filter = filter
        _showSources = State(initialValue: showSources)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if let discovery = extensions.skillsDiscovery { sources(discovery) }
            if !rows.isEmpty {
                ExtensionFilterBar(filter: $filter, summary: "\(rows.filter { $0.enabled != false }.count) of \(rows.count) enabled")
            }
            let visible = rows.filter { filter.matches($0.enabled) }
            let groups = Dictionary(grouping: visible, by: groupLabel).sorted { groupRank($0.key) < groupRank($1.key) || (groupRank($0.key) == groupRank($1.key) && $0.key < $1.key) }
            ForEach(groups, id: \.key) { group in
                ExtensionGroupHeader(title: group.key, count: group.value.count)
                ForEach(group.value) { SkillCard(row: $0, disabled: disabled) }
            }
        }
    }

    private func groupLabel(_ row: FeatureRow) -> String {
        if let plugin = row.payload["plugin_name"] as? String { return "Plugin: \(plugin)" }
        let scope = row.payload["scope"] as? String ?? "user"
        return scope == "local" ? "Project" : scope.capitalized
    }

    private func groupRank(_ label: String) -> Int {
        label.hasPrefix("Plugin: ") ? 3 : ["Project": 0, "User": 1, "Bundled": 2][label] ?? 2
    }

    private func sources(_ discovery: SkillsDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldableSection(isExpanded: $showSources) {
                HStack {
                    Text("Discovery sources").font(.system(size: 13, weight: .semibold))
                    Text("\(discovery.totalSkills) skills loaded").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered automatically").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    ForEach(discovery.automatic) { source in sourceLine(source.path, count: source.count, removable: false) }
                    if discovery.automatic.isEmpty { Text("No automatically discovered directories.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    if !discovery.custom.isEmpty {
                        Text("Custom paths").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                        ForEach(discovery.custom) { source in sourceLine(source.path, count: source.count, removable: true) }
                    }
                    if !discovery.ignored.isEmpty {
                        Text("Ignored").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                        ForEach(discovery.ignored, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted) }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
            }
        }
        .background(Theme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.3), lineWidth: 0.5))
    }

    private func sourceLine(_ path: String, count: Int, removable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: removable ? "folder.badge.plus" : "folder").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 18).accessibilityHidden(true)
            Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(count == 1 ? "1 skill" : "\(count) skills").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            if removable {
                IconButton(icon: "minus.circle", help: "Remove this path", size: 24) { store.removeSkillPath(path) }.disabled(disabled)
            }
        }
    }
}

private struct SkillCard: View {
    @EnvironmentObject var store: AppStore
    let row: FeatureRow
    let disabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    Text("/" + (row.payload["invocation"] as? String ?? row.id)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
                    if row.payload["user_invocable"] as? Bool == false { ExtensionBadge(text: "Model only") }
                }
                if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled) }
                if let path = row.payload["path"] as? String, path.hasPrefix("/") { ExtensionPathLine(path: path) }
            }
            Spacer(minLength: 12)
            if row.actions.contains("Use") {
                Button("Use") {
                    store.invokeFeature(row, panel: .skills, action: "Use")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
                }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).disabled(disabled)
            }
            Toggle("Enabled", isOn: Binding(get: { row.enabled ?? true }, set: { _ in store.toggleFeature(row, panel: .skills) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(disabled).padding(.top, 4)
                .accessibilityLabel("Enable \(row.title)")
        }.extensionCard()
    }
}

// MARK: - Workflows

struct WorkflowsPanelView: View {
    @EnvironmentObject var store: AppStore
    let rows: [FeatureRow]
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(row.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                                if let source = row.payload["source"] as? String, !source.isEmpty { ExtensionBadge(text: source.capitalized) }
                            }
                            if !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled) }
                        }
                        Spacer()
                        Button("Use") {
                            store.invokeFeature(row, panel: .workflows, action: "Use")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
                        }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).disabled(disabled)
                    }
                    if let when = row.payload["when_to_use"] as? String, !when.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("When to use").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                            Text(when).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    if let path = row.payload["path"] as? String, !path.isEmpty { ExtensionPathLine(path: path) }
                }.extensionCard()
            }
        }
    }
}

// MARK: - Marketplace

struct MarketplacePanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    @ObservedObject var model: MarketplacePanelModel
    let search: String
    let disabled: Bool

    private func matches(_ plugin: MarketplacePluginItem) -> Bool {
        search.isEmpty || ([plugin.name, plugin.description ?? "", plugin.category ?? "", plugin.author ?? ""] + plugin.tags)
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending = model.pending, store.featureLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(pending).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            if model.loaded && model.sources.isEmpty {
                ExtensionEmptyState(symbol: "shippingbox", text: "No marketplace sources yet.\nAdd one below with owner/repo, a git URL, or a local path.")
            }
            ForEach(model.sources) { source in
                let plugins = source.plugins.filter(matches)
                if search.isEmpty || !plugins.isEmpty { sourceSection(source, plugins: plugins) }
            }
        }
    }

    private func sourceSection(_ source: MarketplaceSourceItem, plugins: [MarketplacePluginItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: source.kind == "local" ? "folder" : "shippingbox").font(.system(size: 12)).foregroundStyle(Theme.muted).accessibilityHidden(true)
                Text(source.name).font(.system(size: 13, weight: .semibold))
                Text(source.urlOrPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                IconButton(icon: "arrow.clockwise", help: "Refresh \(source.name)", size: 26) { model.perform(.refresh(source: source.urlOrPath)) }.disabled(disabled)
                IconButton(icon: "trash", help: "Remove source", size: 26) {
                    extensions.pendingConfirmation = ExtensionConfirmation(panel: .marketplace, message: "Remove source \"\(source.name)\" and uninstall all its plugins?", confirmTitle: "Remove source") {
                        model.perform(.removeSource(source: source.urlOrPath))
                    }
                }.disabled(disabled)
            }.padding(.horizontal, 2)
            if let error = source.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if plugins.isEmpty {
                Text("This source doesn't list any plugins.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(plugins) { MarketplacePluginCard(plugin: $0, model: model, disabled: disabled) }
        }
    }
}

private struct MarketplacePluginCard: View {
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let plugin: MarketplacePluginItem
    @ObservedObject var model: MarketplacePanelModel
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(plugin.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                        status
                    }
                    if let description = plugin.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer()
                actions
            }
            let badges = self.badges
            if !badges.isEmpty { HStack(spacing: 6) { ForEach(badges, id: \.self) { ExtensionBadge(text: $0) } } }
        }.extensionCard()
    }

    @ViewBuilder private var status: some View {
        switch plugin.installStatus {
        case "installed": ExtensionBadge(text: "Installed" + (plugin.installedVersion.map { " · v\($0)" } ?? ""), symbol: "checkmark", tone: .accent)
        case "update_available":
            let versions = [plugin.installedVersion, plugin.version].compactMap { $0 }
            ExtensionBadge(text: "Update available" + (versions.isEmpty ? "" : " · " + versions.joined(separator: " → ")), symbol: "arrow.up.circle", tone: .warning)
        default: if let version = plugin.version { ExtensionBadge(text: "v\(version)") }
        }
    }

    private var badges: [String] {
        var badges: [String] = []
        if let category = plugin.category, !category.isEmpty { badges.append(category) }
        if let components = plugin.components { badges.append(components) }
        else {
            if plugin.skillCount > 0 { badges.append(plugin.skillCount == 1 ? "1 skill" : "\(plugin.skillCount) skills") }
            if plugin.hasAgents { badges.append("Agents") }
            if plugin.hasHooks { badges.append("Hooks") }
            if plugin.hasMcp { badges.append("MCP") }
        }
        if let author = plugin.author, !author.isEmpty { badges.append("by \(author)") }
        return badges
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if plugin.hasUpdate {
                Button("Update") { model.perform(.update(source: plugin.source, plugin: plugin.relativePath), plugin: plugin) }.disabled(disabled)
            }
            if plugin.isInstalled {
                Button("Uninstall…") {
                    extensions.pendingConfirmation = ExtensionConfirmation(panel: .marketplace, message: "Uninstall marketplace plugin \"\(plugin.name)\"?", confirmTitle: "Uninstall") {
                        model.perform(.uninstall(source: plugin.source, plugin: plugin.relativePath), plugin: plugin)
                    }
                }.disabled(disabled)
            } else {
                Button("Install") { model.perform(.install(source: plugin.source, plugin: plugin.relativePath), plugin: plugin) }.disabled(disabled)
            }
        }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
    }
}
