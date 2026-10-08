import SwiftUI
import AppKit

/// The scrolling conversation: messages, reasoning, and tool calls, with the find bar above it
/// and the turn timeline beside it. The rows themselves are AppKit (see `TranscriptListView`).
struct TranscriptView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tools: TranscriptToolsModel
    @StateObject private var follow = TranscriptFollowState()
    @State private var timeline = TranscriptTimelineMemo()
    @State private var findBarHeight: CGFloat = 62
    @AppStorage("compactConversation") private var compactConversation = false

    var body: some View {
        HStack(spacing: 0) {
            // The transcript fills the room it is given, whatever is in it, so it is laid over a
            // view that does just that, and nothing around it asks it how large it would be.
            Color.clear.overlay { transcript }
            if tools.showTimeline {
                let messages = store.conversation?.messages ?? []
                let ticks = timeline.ticks(conversation: store.state.selectedConversationID, revision: store.transcriptRevision(of: store.state.selectedConversationID),
                                           messages: messages, expanded: tools.expandedMessageIDs, compact: compactConversation)
                if ticks.count >= 2 {
                    TranscriptTimelineRail(
                        ticks: ticks,
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

    private var transcript: some View {
        let id = store.state.selectedConversationID
        let run = store.run
        let conversation = store.conversation
        let display = TranscriptDisplay(
            conversation: id,
            streamingID: run.isRunning ? conversation?.messages.last?.id : nil,
            showTimestamps: tools.showTimestamps,
            matchID: tools.currentFindMessageID,
            focusID: tools.vimMode ? tools.vimFocusID : nil,
            expanded: tools.expandedMessageIDs,
            compact: compactConversation,
            status: run.isRunning ? (run.approvals.isEmpty && run.questions.isEmpty ? run.phase + "…" : "Waiting for your response") : nil)
        // A revision number is cheap to compare; the streaming text itself can be megabytes.
        return ZStack(alignment: .top) {
            // The rows run under the window's title bar and under the find bar, as far as the
            // glass over them; the list keeps its rows clear of both when it rests at its top.
            TranscriptList(store: store, tools: tools, follow: follow, display: display,
                           revision: store.transcriptRevision(of: id), count: conversation?.messages.count ?? 0,
                           scrollRequest: tools.scrollRequest, coveredTop: tools.findPresented ? findBarHeight : 0)
                .ignoresSafeArea(.container, edges: .top)
            if tools.findPresented {
                TranscriptFindBar().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { findBarHeight = $0 }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if run.isRunning { TranscriptFollowButton(state: follow) }
        }
    }
}

/// Over the transcript while a turn runs: whether new output is followed, and a click to change that.
private struct TranscriptFollowButton: View {
    @ObservedObject var state: TranscriptFollowState

    var body: some View {
        Button { state.toggle() } label: {
            Label(state.isFollowing ? "Following" : "Follow output", systemImage: state.isFollowing ? "arrow.down.to.line" : "arrow.down")
                .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7).glassSurface(in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(Theme.muted).padding(.trailing, 22)
    }
}

/// The timeline's ticks, kept between renders. Placing them reads the whole transcript, so
/// while it streams they are placed again at most once a second.
@MainActor
final class TranscriptTimelineMemo {
    private struct Key: Equatable {
        var conversation: UUID?
        var expanded: Set<UUID>
        var compact: Bool
    }
    private var key: Key?
    private var revision = -1
    private var placedAt = Date.distantPast
    private var cached: [TranscriptTimelineTick] = []

    func ticks(conversation: UUID?, revision: Int, messages: [Message], expanded: Set<UUID>, compact: Bool) -> [TranscriptTimelineTick] {
        let key = Key(conversation: conversation, expanded: expanded, compact: compact)
        let now = Date()
        if key == self.key, revision == self.revision || now.timeIntervalSince(placedAt) < 1 { return cached }
        let turns = TranscriptTurns.list(messages)
        cached = TranscriptTimelineLayout.ticks(messages: messages, turns: turns, expanded: expanded, compact: compact)
        self.key = key; self.revision = revision; placedAt = now
        return cached
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
                if !message.text.isEmpty || message.attachments?.isEmpty != false { MarkdownReply(text: message.text, isStreaming: isStreaming) }
                if let images = message.attachments, !images.isEmpty { TranscriptImageGrid(attachments: images) }
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
    @State private var previewHeight: CGFloat = 0

    /// While reasoning streams, the folded block shows its newest lines (see `ThoughtPreview`).
    static let previewHeight = ThoughtPreview.height
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        let isExpanded = FoldState(id: message.id, expanded: expanded, onExpand: onExpand).binding($localExpanded)
        VStack(alignment: .leading, spacing: 0) {
            FoldableSection(isExpanded: isExpanded) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                        Text(isStreaming ? "Thinking…" : "Thinking").fontWeight(.medium)
                    }
                    // A still gradient: animating it would run SwiftUI every frame (see ThinkingEffects).
                    .foregroundStyle(isStreaming ? AnyShapeStyle(ThinkingPalette.gradient) : AnyShapeStyle(Theme.muted))
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }.font(.system(size: 13)).foregroundStyle(Theme.muted)
            } content: {
                ReadOnlyTextView(text: message.text, style: .markdown, sizing: .fitContent(maxHeight: 360), followsTail: isStreaming, isStreaming: isStreaming)
                    .padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 12)
            }
            if isStreaming && !isExpanded.wrappedValue && !message.text.isEmpty {
                preview
            }
            if isStreaming {
                ThinkingProgressBar().padding(.horizontal, 14).padding(.bottom, 8).padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .background(Theme.sidebar.opacity(0.4), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .thinkingLiquid(isStreaming, cornerRadius: Self.cornerRadius)
        .animation(.easeOut(duration: 0.2), value: isStreaming)
    }

    /// The newest reasoning, four lines tall at most, kept scrolled to its end as it streams.
    /// Once it fills, its top edge fades so the lines seem to scroll up out of it.
    private var preview: some View {
        let full = previewHeight >= Self.previewHeight - 1
        return ReadOnlyTextView(text: message.text, style: .markdown, sizing: .fitContent(maxHeight: Self.previewHeight),
                                followsTail: true, isStreaming: true, showsScroller: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(full ? 0.15 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                }
            }
            .padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 6).padding(.top, -4)
            .accessibilityLabel("Latest reasoning")
    }
}

private struct ToolCallView: View {
    let message: Message
    var expanded: Bool?
    var onExpand: (@MainActor (UUID, Bool) -> Void)?
    @State private var localExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section
            // What the tool returned as images stays in sight while the call is folded.
            if let images = message.attachments, !images.isEmpty {
                TranscriptImageGrid(attachments: images)
                    .padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
        .background(Theme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }

    private var section: some View {
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
                } else if message.attachments?.isEmpty != false {
                    Text("No additional output.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 14).padding(.bottom, message.attachments?.isEmpty == false && message.detail?.isEmpty != false ? 0 : 12)
        }
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
