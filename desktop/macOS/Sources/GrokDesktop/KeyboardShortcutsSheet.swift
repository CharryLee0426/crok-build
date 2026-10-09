import SwiftUI

/// Every key Crok Desktop responds to, grouped like the terminal's shortcuts cheatsheet.
enum KeyboardShortcutCatalog {
    struct Entry: Identifiable {
        var id: String { action }
        let action: String
        /// Key glyphs, shown as separate caps; a leading "/" marks a command instead of a key.
        let keys: [String]
    }

    struct Group: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let entries: [Entry]
    }

    /// The sheet's two columns, balanced by length.
    static var columns: [[Group]] {
        let byTitle = Dictionary(uniqueKeysWithValues: groups.map { ($0.title, $0) })
        return [["General", "Task", "Tutorial"], ["Prompt", "Palette and lists", "Theme picker"]].map { $0.compactMap { byTitle[$0] } }
    }

    static let groups: [Group] = [
        Group(title: "General", symbol: "macwindow", entries: [
            Entry(action: "New task", keys: ["⌘", "N"]),
            Entry(action: "Open project…", keys: ["⇧", "⌘", "O"]),
            Entry(action: "Search tasks", keys: ["⌘", "K"]),
            Entry(action: "Command palette", keys: ["⇧", "⌘", "P"]),
            Entry(action: "Show or hide the sidebar", keys: ["⌘", "B"]),
            Entry(action: "Settings", keys: ["⌘", ","]),
            Entry(action: "Keyboard shortcuts", keys: ["⌘", "/"]),
            Entry(action: "Quit", keys: ["⌘", "Q"]),
        ]),
        Group(title: "Task", symbol: "bubble.left.and.text.bubble.right", entries: [
            Entry(action: "Plan mode", keys: ["⌥", "⌘", "P"]),
            Entry(action: "Stop the running turn", keys: ["⌘", "."]),
            Entry(action: "Files, side chat, terminal, and browser", keys: ["⌘", "J"]),
            Entry(action: "Terminal", keys: ["⌃", "`"]),
            Entry(action: "Browser", keys: ["⌥", "⌘", "B"]),
            Entry(action: "Close the browser's tab", keys: ["⌘", "W"]),
            Entry(action: "Git Graph", keys: ["⌥", "⌘", "G"]),
            Entry(action: "Ask a side question", keys: ["/btw"]),
            Entry(action: "Find in the conversation", keys: ["/find"]),
            Entry(action: "Jump to a turn", keys: ["/jump"]),
        ]),
        Group(title: "Prompt", symbol: "text.cursor", entries: [
            Entry(action: "Send", keys: ["↵"]),
            Entry(action: "New line", keys: ["⇧", "↵"]),
            Entry(action: "New line, as in the terminal", keys: ["⌃", "J"]),
            Entry(action: "Attach photos and files", keys: ["⌘", "U"]),
            Entry(action: "Paste a copied image or file", keys: ["⌘", "V"]),
            Entry(action: "Send, with /multiline on", keys: ["⌘", "↵"]),
            Entry(action: "New line, with /multiline on", keys: ["↵"]),
            Entry(action: "Commands and skills", keys: ["/"]),
            Entry(action: "Choose a command", keys: ["↑", "↓"]),
            Entry(action: "Complete a command", keys: ["⇥"]),
            Entry(action: "Close the command menu", keys: ["esc"]),
        ]),
        Group(title: "Palette and lists", symbol: "command", entries: [
            Entry(action: "Move the selection", keys: ["↑", "↓"]),
            Entry(action: "Run or open the selection", keys: ["↵"]),
            Entry(action: "Close", keys: ["esc"]),
        ]),
        Group(title: "Theme picker", symbol: "paintpalette", entries: [
            Entry(action: "Preview the next theme", keys: ["↑", "↓"]),
            Entry(action: "Apply", keys: ["↵"]),
            Entry(action: "Cancel and revert", keys: ["esc"]),
        ]),
        Group(title: "Tutorial", symbol: "graduationcap", entries: [
            Entry(action: "Previous or next topic", keys: ["←", "→"]),
            Entry(action: "Open the topic's guide", keys: ["d"]),
            Entry(action: "Back to the topic list", keys: ["esc"]),
        ]),
    ]
}

struct KeyboardShortcutsSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extras: ExtrasFeatureModel

    var body: some View {
        DesktopPanel(title: "Keyboard shortcuts", subtitle: "Type / in the prompt, or press ⇧⌘P, for every command.", width: 760, height: 620, onClose: { store.sheet = nil }) {
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(KeyboardShortcutCatalog.columns.enumerated()), id: \.offset) { _, groups in column(groups) }
                }.padding(24)
            }
        } footer: {
            Button { store.sheet = nil; extras.openGuide(title: "Keyboard Shortcuts") } label: {
                Label("Terminal key reference", systemImage: "book")
            }
            Spacer()
            Button("Done") { store.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }

    private func column(_ groups: [KeyboardShortcutCatalog.Group]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.title, systemImage: group.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        .padding(.bottom, 2)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Theme.line.opacity(0.5)) }
                            HStack(spacing: 10) {
                                Text(entry.action).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 8)
                                ShortcutKeyCaps(keys: entry.keys)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(entry.action): \(entry.keys.joined(separator: " "))")
                        }
                    }
                    .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Keys drawn as small caps; a slash command is shown as text.
struct ShortcutKeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key.hasPrefix("/") && key.count > 1 {
                    Text(key).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent)
                } else {
                    Text(key).font(.system(size: 12, weight: .medium, design: key.count > 2 ? .default : .rounded))
                        .frame(minWidth: 14).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line, lineWidth: 0.5))
                }
            }
        }.foregroundStyle(Theme.ink)
    }
}
