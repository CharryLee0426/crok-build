import SwiftUI
import AppKit

/// The scrolling conversation: messages, reasoning, and tool calls, with the find bar above it
/// and the turn timeline beside it.
struct TranscriptView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tools: TranscriptToolsModel
    @State private var followOutput = true
    @AppStorage("compactConversation") private var compactConversation = false

    var body: some View {
        let messages = store.conversation?.messages ?? []
        HStack(spacing: 0) {
            transcript(messages)
            if tools.showTimeline {
                let turns = TranscriptTurns.list(messages)
                if turns.count >= 2 {
                    TranscriptTimelineRail(
                        ticks: TranscriptTimelineLayout.ticks(messages: messages, turns: turns, expanded: tools.expandedMessageIDs, compact: compactConversation),
                        viewport: tools.viewport,
                        onSelect: { tools.jumpToTurn($0) }
                    ).equatable()
                }
            }
        }
        .background { TranscriptHostProbe(tools: tools) }
        .background { shortcuts }
        .onAppear { tools.loadPreferencesIfNeeded() }
    }

    /// ⌘F opens the find bar while the conversation is on screen; ⌘G and ⇧⌘G step through matches.
    @ViewBuilder private var shortcuts: some View {
        Button("") { tools.openFind("") }.keyboardShortcut("f").hidden()
        if tools.findPresented {
            Button("") { tools.moveFind(1) }.keyboardShortcut("g").hidden()
            Button("") { tools.moveFind(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).hidden()
        }
    }

    private func transcript(_ messages: [Message]) -> some View {
        let streamingID = store.run.isRunning ? messages.last?.id : nil
        let showTimestamps = tools.showTimestamps
        let matchID = tools.currentFindMessageID
        let focusID = tools.vimMode ? tools.vimFocusID : nil
        let expanded = tools.expandedMessageIDs
        let tools = self.tools
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compactConversation ? 10 : 23) {
                    ForEach(messages) { message in
                        let foldable = message.kind == .thought || message.kind == .tool
                        let stamped = showTimestamps && (message.kind == .user || message.kind == .assistant)
                        MessageView(message: message, isStreaming: message.id == streamingID,
                                    timestamp: stamped ? message.createdAt : nil,
                                    highlight: message.id == matchID ? .match : message.id == focusID ? .focus : .none,
                                    isExpanded: foldable ? expanded.contains(message.id) : nil,
                                    onExpand: { id, open in tools.setExpanded(id, open) }).equatable()
                    }
                    if store.run.isRunning {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.mini)
                            Text(store.run.approvals.isEmpty && store.run.questions.isEmpty ? store.run.phase + "…" : "Waiting for your response")
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 5)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                .frame(maxWidth: 800, alignment: .leading).padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 15).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                if tools.findPresented { TranscriptFindBar() }
            }
            // A revision number is cheap to compare; the streaming text itself can be megabytes.
            .onChange(of: store.transcriptRevision(of: store.state.selectedConversationID)) { _, _ in
                if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                tools.transcriptDidChange()
            }
            .onChange(of: store.state.selectedConversationID) { _, _ in
                followOutput = true
                proxy.scrollTo("bottom", anchor: .bottom)
                tools.conversationDidChange()
            }
            .onChange(of: tools.scrollRequest) { _, request in
                guard let request else { return }
                switch request.target {
                case .bottom:
                    followOutput = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                case .message(let id):
                    followOutput = false
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: followOutput) { _, following in tools.recordFollowing(following, messageCount: messages.count) }
            .modifier(PauseFollowingWhileScrolling(followOutput: $followOutput))
            .modifier(TranscriptScrollObserver(messages: messages, tools: tools))
            .overlay(alignment: .bottomTrailing) {
                if store.run.isRunning {
                    Button { followOutput.toggle(); if followOutput { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label(followOutput ? "Following" : "Follow output", systemImage: followOutput ? "arrow.down.to.line" : "arrow.down")
                            .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7).glassSurface(in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(Theme.muted).padding(.trailing, 22)
                }
            }
        }
    }
}

struct MessageView: View, Equatable {
    let message: Message
    /// This is the newest message of a turn that is still producing output.
    var isStreaming = false
    /// When the message was sent; shown on prompts and replies while timestamps are on.
    var timestamp: Date?
    var highlight: TranscriptRowHighlight = .none
    /// Whether a reasoning or tool block is open. Nil keeps that state in the row itself.
    var isExpanded: Bool?
    var onExpand: (@MainActor (UUID, Bool) -> Void)?
    /// Past this size a prompt (usually pasted logs) is shown in a scrolling text view.
    private static let longPromptBytes = 8_000

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.message, b = rhs.message
        return lhs.isStreaming == rhs.isStreaming && lhs.timestamp == rhs.timestamp && lhs.highlight == rhs.highlight && lhs.isExpanded == rhs.isExpanded
            && a.id == b.id && a.kind == b.kind && a.status == b.status && a.toolID == b.toolID
            && same(a.text, b.text) && (a.detail == nil) == (b.detail == nil) && same(a.detail ?? "", b.detail ?? "")
            && a.attachments?.map(\.id) == b.attachments?.map(\.id)
    }

    /// Streamed text only grows, so the length usually settles it without reading the text.
    private nonisolated static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.count == rhs.utf8.count && lhs == rhs }

    var body: some View {
        content
            .background { TranscriptRowHighlightView(highlight: highlight) }
            .accessibilityAddTraits(highlight == .none ? [] : .isSelected)
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .user:
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 48)
                if let timestamp { TranscriptTimestampLabel(date: timestamp).padding(.top, 16) }
                VStack(alignment: .trailing, spacing: 8) {
                    if let attachments = message.attachments, !attachments.isEmpty { SentAttachmentsView(attachments: attachments) }
                    if !message.text.isEmpty {
                        Group {
                            if message.text.utf8.count > Self.longPromptBytes {
                                ReadOnlyTextView(text: message.text, style: .body, sizing: .fitContent(maxHeight: 420))
                            } else {
                                Text(message.text).font(.system(size: 16)).textSelection(.enabled)
                            }
                        }.padding(.horizontal, 17).padding(.vertical, 13).background(Theme.sidebar).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    GrokMark(size: 18); Text("Crok").font(.system(size: 13, weight: .semibold))
                    if let timestamp { Spacer(minLength: 8); TranscriptTimestampLabel(date: timestamp) }
                }
                MarkdownReply(text: message.text)
            }
        case .thought:
            ThoughtView(message: message, isStreaming: isStreaming, expanded: isExpanded, onExpand: onExpand)
        case .tool:
            ToolCallView(message: message, expanded: isExpanded, onExpand: onExpand)
        case .system:
            HStack(alignment: .top, spacing: 9) { Image(systemName: "exclamationmark.circle"); Text(message.text).textSelection(.enabled) }.font(.system(size: 14)).foregroundStyle(Theme.muted).padding(13).background(Theme.sidebar).clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

/// The current find match gets an accent outline; the vim cursor a tint and an accent bar.
private struct TranscriptRowHighlightView: View {
    let highlight: TranscriptRowHighlight

    var body: some View {
        switch highlight {
        case .none: EmptyView()
        case .match:
            RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
                .padding(-9)
        case .focus:
            RoundedRectangle(cornerRadius: 14).fill(Theme.hover.opacity(0.6))
                .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 8).padding(.leading, 3) }
                .padding(-9)
        }
    }
}

/// "3:07 PM", with the terminal's "15:07:12 | Sep 23" on hover.
struct TranscriptTimestampLabel: View {
    let date: Date

    var body: some View {
        let label = TranscriptTimestamp.label(date)
        Text(label).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
            .lineLimit(1).fixedSize()
            .help(TranscriptTimestamp.tooltip(date))
            .accessibilityLabel("Sent at \(label)")
    }
}

/// Open state lives in the transcript model when the row has one, and in the row otherwise.
private struct FoldState {
    let id: UUID
    let expanded: Bool?
    let onExpand: (@MainActor (UUID, Bool) -> Void)?

    func binding(_ local: Binding<Bool>) -> Binding<Bool> {
        guard let expanded, let onExpand else { return local }
        let id = self.id
        // Bindings are set on the main thread, from the fold's button.
        return Binding(get: { expanded }, set: { value in MainActor.assumeIsolated { onExpand(id, value) } })
    }
}

private struct ThoughtView: View {
    let message: Message
    let isStreaming: Bool
    var expanded: Bool?
    var onExpand: (@MainActor (UUID, Bool) -> Void)?
    @State private var localExpanded = false

    var body: some View {
        let isExpanded = FoldState(id: message.id, expanded: expanded, onExpand: onExpand).binding($localExpanded)
        FoldableSection(isExpanded: isExpanded) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                Text(isStreaming ? "Thinking…" : "Thinking").fontWeight(.medium).layoutPriority(1)
                if isStreaming && !isExpanded.wrappedValue {
                    // A glimpse of the newest reasoning, without laying out the rest of it.
                    Text(Self.latestLine(of: message.text)).lineLimit(1).truncationMode(.head).opacity(0.75)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 13)).foregroundStyle(Theme.muted)
        } content: {
            ReadOnlyTextView(text: message.text, style: .markdown, sizing: .fitContent(maxHeight: 360), followsTail: isStreaming)
                .padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 12)
        }
        .background(Theme.sidebar.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    static func latestLine(of text: String) -> String {
        let tail = text.suffix(240)
        guard let line = tail.split(whereSeparator: \.isNewline).last else { return "" }
        // The glimpse reads as prose: `**Planning**` shows as "Planning".
        return MarkdownParser.plainText(MarkdownParser.parse(String(line))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ToolCallView: View {
    let message: Message
    var expanded: Bool?
    var onExpand: (@MainActor (UUID, Bool) -> Void)?
    @State private var localExpanded = false

    var body: some View {
        FoldableSection(isExpanded: FoldState(id: message.id, expanded: expanded, onExpand: onExpand).binding($localExpanded)) {
            HStack(spacing: 8) {
                Image(systemName: message.status == "completed" ? "checkmark.circle" : message.status == "failed" ? "xmark.circle" : "terminal")
                    .foregroundStyle(message.status == "failed" ? .red : Theme.muted)
                Text(Self.title(message.text)).lineLimit(2)
                Spacer()
                Text((message.status ?? "pending").replacingOccurrences(of: "_", with: " ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.font(.system(size: 14))
        } content: {
            Group {
                if let detail = message.detail, !detail.isEmpty {
                    ReadOnlyTextView(text: detail, style: .monospaced, wrapsLines: false, sizing: .fitContent(maxHeight: 260))
                } else {
                    Text("No additional output.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 14).padding(.bottom, 12)
        }
        .background(Theme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Tool titles use inline Markdown, e.g. ``Read `path` ``: code spans show as code.
    static func title(_ text: String) -> AttributedString {
        guard text.contains("`") || text.contains("*") else { return AttributedString(text) }
        var result = AttributedString()
        for segment in MarkdownInlineBuilder(fontSize: 14).segments(MarkdownParser.parseInlines(text)) {
            switch segment {
            case .text(let run): result.append(run)
            case .math(let latex): result.append(AttributedString("$\(latex)$"))
            case .symbol: break
            }
        }
        return result
    }
}

/// Stops following streamed output while the reader scrolls, and resumes it when they
/// come to rest at the end of the transcript.
private struct PauseFollowingWhileScrolling: ViewModifier {
    @Binding var followOutput: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting: followOutput = false
                case .idle:
                    let geometry = context.geometry
                    followOutput = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                default: break
                }
            }
        } else {
            content
        }
    }
}

/// Tells the transcript tools which rows are on screen (for /jump, vim keys, and the timeline)
/// and, for /debug, where the transcript is scrolled. Needs macOS 15; earlier systems start
/// /jump at the last turn and show no scroll metrics.
private struct TranscriptScrollObserver: ViewModifier {
    let messages: [Message]
    let tools: TranscriptToolsModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.02) { ids in
                    let visible = Set(ids)
                    let top = messages.firstIndex { visible.contains($0.id) }
                    tools.visibleMessagesChanged(topIndex: top, topID: top.map { messages[$0].id })
                }
                .onScrollGeometryChange(for: TranscriptScrollSample.self) { geometry in
                    TranscriptScrollSample(offsetY: geometry.contentOffset.y, contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height)
                } action: { _, sample in
                    tools.recordScroll(sample)
                }
                .onScrollPhaseChange { _, phase in tools.recordScrollPhase(Self.name(phase)) }
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private static func name(_ phase: ScrollPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .tracking: return "tracking"
        case .interacting: return "interacting"
        case .decelerating: return "decelerating"
        case .animating: return "animating"
        @unknown default: return "other"
        }
    }
}
