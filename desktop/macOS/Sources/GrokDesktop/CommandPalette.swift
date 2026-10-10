import SwiftUI
import AppKit

struct CommandList: View {
    let commands: [SlashCommand]
    var selected: Int
    var onSelect: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        PaletteCommandRow(command: command, isSelected: index == selected) { onSelect(command) }.id(command.id)
                    }
                    if commands.isEmpty { Text("No matching commands").font(.system(size: 14)).foregroundStyle(Theme.muted).padding(30) }
                }.padding(6)
            }
            .onChange(of: selected) { _, value in
                if commands.indices.contains(value) { proxy.scrollTo(commands[value].id) }
            }
        }
    }
}

/// One command or skill in the composer menu and the palette.
struct PaletteCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.symbol).font(.system(size: 16)).foregroundStyle(Theme.muted).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("/" + command.name).font(.system(size: 14, weight: .medium))
                        if let hint = command.argumentHint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    Text(command.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(command.source).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.sidebar, in: Capsule())
            }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("/\(command.name). \(command.description). \(command.source)")
    }
}

/// The terminal palette's grouped actions (`default_palette_entries` in
/// `xai-grok-pager/src/views/modal.rs`), with desktop shortcuts. Entries without a desktop
/// counterpart (New Session in Worktree) or disabled there (Share Session) are left out.
struct CommandPaletteAction: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case session = "Session", context = "Context", modelAndInput = "Model & Input", tools = "Tools", other = "Other"
    }

    enum Perform: Equatable {
        /// Runs through the command router, as typing the command would.
        case command(String)
        /// Puts `/name ` in the prompt for the arguments, as the terminal's palette does.
        case prefill(String)
        case themePicker
        case keyboardShortcuts
        /// Opens the prompt editor with the current draft, unlike `/edit-prompt`.
        case editPrompt
    }

    var id: String { label }
    let label: String
    let shortcut: String
    let symbol: String
    let group: Group
    let perform: Perform

    private init(_ label: String, _ shortcut: String, _ symbol: String, _ group: Group, _ perform: Perform) {
        self.label = label; self.shortcut = shortcut; self.symbol = symbol; self.group = group; self.perform = perform
    }

    static let catalog: [CommandPaletteAction] = [
        .init("New Session", "⌘N", "square.and.pencil", .session, .command("new")),
        .init("Agent Dashboard", "/dashboard", "person.2", .session, .command("dashboard")),
        .init("Back to Home", "/home", "house", .session, .command("home")),
        .init("Delete This Session", "/delete", "trash", .session, .command("delete")),
        .init("Resume Session", "/resume", "clock.arrow.circlepath", .session, .command("resume")),
        .init("Rename Session", "/rename", "pencil", .session, .prefill("rename")),
        .init("Session Info", "/session-info", "info.circle", .session, .command("session-info")),
        .init("Send Feedback", "/feedback", "exclamationmark.bubble", .session, .command("feedback")),
        .init("Compact History", "/compact", "arrow.down.right.and.arrow.up.left", .context, .command("compact")),
        .init("Context Usage", "/context", "gauge.with.dots.needle.33percent", .context, .command("context")),
        .init("View Plan", "/view-plan", "list.bullet.clipboard", .context, .command("view-plan")),
        .init("Memory", "/memory", "brain.head.profile", .context, .command("memory")),
        .init("Switch Model", "/model", "brain", .modelAndInput, .command("model")),
        .init("Always Approve Mode", "/always-approve", "checkmark.shield", .modelAndInput, .command("always-approve")),
        .init("Multiline Input", "/multiline", "text.justify.left", .modelAndInput, .command("multiline")),
        .init("Edit Prompt in External Editor", "/edit-prompt", "rectangle.and.pencil.and.ellipsis", .modelAndInput, .editPrompt),
        .init("Hooks", "/hooks", "slider.horizontal.3", .tools, .command("hooks")),
        .init("Plugins", "/plugins", "puzzlepiece.extension", .tools, .command("plugins")),
        .init("Marketplace", "/marketplace", "bag", .tools, .command("marketplace")),
        .init("Skills", "/skills", "sparkles", .tools, .command("skills")),
        .init("Workflows", "/workflows", "arrow.triangle.branch", .tools, .command("workflows")),
        .init("MCP Servers", "/mcps", "point.3.connected.trianglepath.dotted", .tools, .command("mcps")),
        .init("Manage Agents", "/config-agents", "person.crop.rectangle.stack", .tools, .command("config-agents")),
        .init("Git Graph", "/git-graph", "arrow.triangle.merge", .tools, .command("git-graph")),
        .init("Browser", "/browser", "globe", .tools, .command("browser")),
        .init("Switch Theme", "/theme", "paintpalette", .other, .themePicker),
        .init("Settings", "⌘,", "gearshape", .other, .command("settings")),
        .init("Keyboard Shortcuts", "⌘/", "keyboard", .other, .keyboardShortcuts),
        .init("How-to Guides", "/docs", "book", .other, .command("docs")),
        .init("Tutorial", "/tutorial", "graduationcap", .other, .command("tutorial")),
        .init("Quit", "⌘Q", "power", .other, .command("exit")),
    ]

    /// Like the terminal: the label or the shortcut contains the query, ignoring case.
    static func matches(_ query: String) -> [CommandPaletteAction] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return catalog }
        return catalog.filter { $0.label.lowercased().contains(query) || $0.shortcut.lowercased().contains(query) }
    }
}

/// `/help` and ⇧⌘P: the grouped actions above every command and skill.
struct CommandPalette: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extras: ExtrasFeatureModel
    @State private var query: String
    @State private var selected = 0

    init(query: String = "") { _query = State(initialValue: query) }

    private enum Item: Identifiable {
        case action(CommandPaletteAction)
        case command(SlashCommand)
        var id: String {
            switch self {
            case .action(let action): return "action." + action.id
            case .command(let command): return "command." + command.id
            }
        }
    }

    private var actions: [CommandPaletteAction] { CommandPaletteAction.matches(query) }
    private var commands: [SlashCommand] { store.commandIndex.matches(query: query) }

    var body: some View {
        let actions = self.actions, commands = self.commands
        let items = actions.map(Item.action) + commands.map(Item.command)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NativeSearchField(text: $query, placeholder: "Search actions, commands, and skills", onEscape: { store.showCommandPalette = false },
                                  onSubmit: { accept(items) }, onMove: { move($0, count: items.count) }).frame(height: 40)
                Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 5))
            }.padding(20)
            Divider()
            list(actions: actions, commands: commands, items: items).frame(height: 420)
            Divider()
            HStack {
                Text(summary(actions: actions.count, commands: commands.count))
                Spacer()
                Text("↑↓ Navigate   ↵ Select")
            }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 660).glassSheetBackground()
            .onChange(of: query) { _, _ in selected = 0 }
            .task { await store.refreshCommands() }
    }

    private func summary(actions: Int, commands: Int) -> String {
        let counts = [actions > 0 ? "\(actions) action\(actions == 1 ? "" : "s")" : nil, "\(commands) command\(commands == 1 ? "" : "s")"]
        return counts.compactMap { $0 }.joined(separator: " · ")
    }

    private func list(actions: [CommandPaletteAction], commands: [SlashCommand], items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(CommandPaletteAction.Group.allCases, id: \.self) { group in
                        let members = actions.filter { $0.group == group }
                        if !members.isEmpty {
                            sectionHeader(group.rawValue)
                            ForEach(members) { action in
                                let index = actions.firstIndex(of: action) ?? 0
                                PaletteActionRow(action: action, isSelected: index == selected) { choose(.action(action)) }.id("action." + action.id)
                            }
                        }
                    }
                    if !commands.isEmpty {
                        if !actions.isEmpty { sectionHeader("Commands & skills") }
                        ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                            PaletteCommandRow(command: command, isSelected: actions.count + offset == selected) { choose(.command(command)) }
                                .id("command." + command.id)
                        }
                    }
                    if items.isEmpty { Text("No matching actions or commands").font(.system(size: 14)).foregroundStyle(Theme.muted).padding(30).frame(maxWidth: .infinity) }
                }.padding(6)
            }
            .onChange(of: selected) { _, value in
                if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.muted)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func move(_ delta: Int, count: Int) { selected = min(max(0, selected + delta), max(0, count - 1)) }

    private func accept(_ items: [Item]) { if items.indices.contains(selected) { choose(items[selected]) } }

    private func choose(_ item: Item) {
        store.showCommandPalette = false
        switch item {
        case .command(let command):
            if command.requiresArguments || command.isSkill && command.argumentHint != nil { prefill(command.name) }
            // Dismiss this sheet before presenting a destination sheet.
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { store.executeCommand(name: command.name) } }
        case .action(let action):
            if case .prefill(let name) = action.perform { prefill(name); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { perform(action.perform) }
        }
    }

    private func prefill(_ name: String) {
        store.draft = "/\(name) "
        DispatchQueue.main.async { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
    }

    private func perform(_ perform: CommandPaletteAction.Perform) {
        switch perform {
        case .command(let name): store.executeCommand(name: name)
        case .prefill(let name): prefill(name)
        case .themePicker: extras.openThemePicker()
        case .keyboardShortcuts: extras.openKeyboardShortcuts()
        case .editPrompt: store.features.composer.openEditPrompt(keepDraft: true)
        }
    }
}

private struct PaletteActionRow: View {
    let action: CommandPaletteAction
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol).font(.system(size: 15)).foregroundStyle(Theme.muted).frame(width: 24)
                Text(action.label).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                if action.shortcut.hasPrefix("/") {
                    Text(action.shortcut).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                } else {
                    ShortcutKeyCaps(keys: action.shortcut.map(String.init))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
        .accessibilityValue(action.shortcut)
    }
}
