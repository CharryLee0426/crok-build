import SwiftUI

/// One `/tutorial` page. The text is the terminal's, generated into `TutorialContent.swift`.
struct GrokTutorialTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let blurb: String
    /// The guide "Go deeper" opens, by its title in `GuideLibrary.catalog`.
    let goDeeper: String?
    let content: String

    /// The page without its leading `# ` heading, which the window shows as the title.
    var body: String {
        guard let newline = content.firstIndex(of: "\n"), content.hasPrefix("# ") else { return content }
        return String(content[content.index(after: newline)...]).trimmingCharacters(in: .newlines)
    }

    /// How the desktop differs, for pages that describe terminal keys or screens.
    var desktopNote: String? {
        switch id {
        case "02-first-prompt":
            return "Press ↵ to send and ⇧↵ for a new line (with /multiline, ↵ adds a line and ⌘↵ sends). Stop a running turn with ⌘. or the stop button, and quit with ⌘Q."
        case "03-attach-and-paste":
            return "Drag images, files, or folders onto the conversation, paste a screenshot with ⌘V, or choose + › Add photos & files (⌘U); they preview above the prompt until you send. To run commands yourself, press ⌃` for the terminal in the side panel."
        case "04-navigation":
            return "Scroll the conversation with your trackpad or mouse. ⌘B shows or hides the sidebar, ⌘J the side panel with files, side chat, and terminal, and ⌘K searches your tasks; /find and /jump move through long conversations."
        case "05-slash-commands":
            return "⇧⌘P opens the command palette (the terminal's Ctrl+P), and Keyboard Shortcuts in the palette lists every key."
        case "06-worktrees":
            return "⌘N starts a new task, /fork --worktree branches this conversation into its own worktree, and /dashboard shows every task."
        case "07-plan-and-permissions":
            return "⌥⌘P enters plan mode, the mode menu under the prompt switches permission modes, and approvals appear as cards in the conversation."
        case "08-make-it-yours":
            return "Open Settings with ⌘, — the theme you pick there or with /theme is shared with the terminal."
        case "09-where-next":
            return "/help or ⇧⌘P opens the command palette, and /docs opens the guides in their own window."
        default:
            return nil
        }
    }
}

/// `/tutorial`: the terminal's "Welcome to Crok Build" topics, with ✓ marks for pages already read.
struct TutorialWindow: View {
    @EnvironmentObject var extras: ExtrasFeatureModel
    /// Nil shows the welcome page, like the terminal's topic list.
    @State private var index: Int?
    @FocusState private var focused: Bool

    private let topics = GrokTutorial.topics

    init(initialTopic: Int? = nil) { _index = State(initialValue: initialTopic) }

    var body: some View {
        HStack(spacing: 0) {
            topicList.frame(width: 280)
            Divider()
            Group {
                if let index, topics.indices.contains(index) { TutorialPage(topic: topics[index], index: index, count: topics.count, move: open) }
                else { welcome }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 540)
        .glassWindowBackground()
        .foregroundStyle(Theme.ink)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { advance(); return .handled }
        .onKeyPress(.leftArrow) {
            if let index, index > 0 { open(index - 1) }
            return .handled
        }
        .onKeyPress("d") {
            // The terminal's "d go deeper".
            guard let index, topics.indices.contains(index), let guide = topics[index].goDeeper else { return .ignored }
            extras.openGuide(title: guide)
            return .handled
        }
        .onExitCommand { index = nil }
        .onAppear {
            focused = true
            if let index, topics.indices.contains(index) { extras.markTutorialTopicExplored(topics[index].id) }
        }
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Crok Build").font(.system(size: 18, weight: .semibold))
                Text("Quick tips to get the most out of Crok Build.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(topics.enumerated()), id: \.element.id) { offset, topic in
                        TutorialTopicRow(topic: topic, number: offset + 1, explored: extras.exploredTutorialTopics.contains(topic.id),
                                         isSelected: offset == index) { open(offset) }
                    }
                }.padding(8)
            }
            Divider()
            TutorialProgress(explored: extras.exploredTutorialTopics.count, total: topics.count)
                .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .background(SidebarMaterial())
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            GrokMark(size: 54)
            Text("Welcome to Crok Build").font(.system(size: 26, weight: .semibold))
            VStack(spacing: 4) {
                Text("Quick tips to get the most out of Crok Build.")
                Text("Pick a topic. Close the window when you're done.")
            }.font(.system(size: 14)).foregroundStyle(Theme.muted)
            Button { open(firstUnexplored) } label: {
                Label(extras.exploredTutorialTopics.isEmpty ? "Start with “\(topics[0].title)”" : "Continue with “\(topics[firstUnexplored].title)”",
                      systemImage: "arrow.right")
            }
            .buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium)).padding(.top, 6)
            if extras.exploredTutorialTopics.count == topics.count {
                Button("Start over") { extras.resetTutorialProgress() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(40)
    }

    private var firstUnexplored: Int {
        topics.firstIndex { !extras.exploredTutorialTopics.contains($0.id) } ?? 0
    }

    private func open(_ target: Int?) {
        guard let target, topics.indices.contains(target) else { index = nil; return }
        index = target
        extras.markTutorialTopicExplored(topics[target].id)
    }

    /// `→` reads on to the next topic, and back to the list after the last one.
    private func advance() {
        guard let index else { open(firstUnexplored); return }
        open(index + 1 < topics.count ? index + 1 : nil)
    }
}

private struct TutorialTopicRow: View {
    let topic: GrokTutorialTopic
    let number: Int
    let explored: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().fill(explored ? Theme.green.opacity(0.16) : Theme.hover)
                    if explored { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.green) }
                    else { Text("\(number)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted) }
                }.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic.title).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).lineLimit(2)
                    Text(topic.blurb).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(topic.title), \(topic.blurb)")
        .accessibilityValue(explored ? "Explored" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TutorialProgress: View {
    let explored: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(explored)/\(total) explored").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hover)
                    Capsule().fill(Theme.green).frame(width: geometry.size.width * CGFloat(explored) / CGFloat(max(1, total)))
                }
            }.frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(explored) of \(total) topics explored")
    }
}

private struct TutorialPage: View {
    @EnvironmentObject var extras: ExtrasFeatureModel
    let topic: GrokTutorialTopic
    let index: Int
    let count: Int
    let move: (Int?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Topic \(index + 1) of \(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    Text(topic.title).font(.system(size: 26, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let note = topic.desktopNote { TutorialDesktopNote(text: note) }
                    MarkdownContent(text: GuideLibrary.reflow(topic.body), style: .panel)
                    if let guide = topic.goDeeper { TutorialGoDeeper(guide: guide) { extras.openGuide(title: guide) } }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .id("\(topic.id)#\(extras.themeRevision)")
            Divider()
            HStack(spacing: 10) {
                Button { move(index - 1) } label: { Text("← back") }.disabled(index == 0)
                Spacer(minLength: 8)
                Button { move(index + 1 < count ? index + 1 : nil) } label: {
                    Text(index + 1 < count ? "→ next: \(GrokTutorial.topics[index + 1].title)" : "→ done").lineLimit(1)
                }
                .keyboardShortcut(.defaultAction)
                .layoutPriority(1)
            }
            .buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
}

/// The terminal's "d go deeper": the full guide behind a topic, in the Guides window.
private struct TutorialGoDeeper: View {
    let guide: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "book").font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go deeper").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(guide).font(.system(size: 14, weight: .medium))
                }
                Spacer(minLength: 4)
                Text("d").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.input, in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(hovered ? Theme.hover : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line.opacity(0.7), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.top, 8)
        .accessibilityLabel("Go deeper: \(guide) guide")
    }
}

private struct TutorialDesktopNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "macwindow").font(.system(size: 14)).foregroundStyle(Theme.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("On Crok Desktop").font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
