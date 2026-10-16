import SwiftUI

/// One transcript item: a day header, a bubble, a thought, a tool card, or a notice.
struct TranscriptRow: View {
    let item: TranscriptItem
    let model: SessionViewModel

    var body: some View {
        switch item.kind {
        case .day:
            DayHeader(date: item.date)
        case .user(let message):
            UserBubble(message: message, date: item.date, position: item.position, model: model)
        case .assistant(let text):
            AssistantBubble(id: item.id, text: text, date: item.date, position: item.position, model: model)
        case .thought(let text):
            ThoughtRow(text: text)
        case .tool(let call):
            ToolCard(call: call)
        case .notice(let text, let style):
            NoticeCapsule(text: text, style: style)
        }
    }
}

private struct DayHeader: View {
    let date: Date

    var body: some View {
        Text(RelativeTime.dayHeader(date, now: Date()))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.noticeText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.noticeBackground, in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

/// Bubble corners: a smaller radius where neighbours of one group touch (Telegram's merged bubbles).
private struct BubbleShape: Shape {
    let outgoing: Bool
    let position: TranscriptItem.Position

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18
        let small: CGFloat = 6
        let topNear = position.startsGroup ? big : small
        let bottomNear = position.endsGroup ? big : small
        let radii = outgoing
            ? RectangleCornerRadii(topLeading: big, bottomLeading: big, bottomTrailing: bottomNear, topTrailing: topNear)
            : RectangleCornerRadii(topLeading: topNear, bottomLeading: bottomNear, bottomTrailing: big, topTrailing: big)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

private struct UserBubble: View {
    let message: UserMessage
    let date: Date
    let position: TranscriptItem.Position
    let model: SessionViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            if message.tick == .failed {
                Menu {
                    if let error = message.error {
                        Text(error)
                    }
                    Button {
                        Task { await model.retry(message) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        Task { await model.discard(message) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.danger)
                }
                .accessibilityLabel(Text("Not sent. Retry or delete."))
                .accessibilityIdentifier("failedPromptMenu")
            }
            VStack(alignment: .trailing, spacing: 3) {
                if message.isRemote && position.startsGroup {
                    HStack(spacing: 3) {
                        Image(systemName: "iphone")
                        if let label = message.fromLabel {
                            Text("from \(label)")
                        } else {
                            Text("from a phone or the web")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.userBubbleText.opacity(0.65))
                }
                Text(message.text)
                    .foregroundStyle(Theme.userBubbleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(date, format: .dateTime.hour().minute())
                    if let tick = message.tick, tick != .failed {
                        DeliveryTickView(tick: tick, color: Theme.userBubbleText.opacity(0.75))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.userBubbleText.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.userBubble, in: BubbleShape(outgoing: true, position: position))
            .opacity(message.isPending && message.tick == .sending ? 0.85 : 1)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userBubble")
    }
}

private struct AssistantBubble: View {
    let id: DocID
    let text: String
    let date: Date
    let position: TranscriptItem.Position
    let model: SessionViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if model.revealing.contains(id) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        MarkdownText(text: model.revealedText(id, full: text, at: context.date))
                    }
                } else if text.isEmpty {
                    WorkingIndicator(showsText: false)
                        .padding(.vertical, 4)
                } else {
                    MarkdownText(text: text)
                }
                if position.endsGroup {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.agentBubble, in: BubbleShape(outgoing: false, position: position))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Spacer(minLength: 28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistantBubble")
    }
}

/// Reasoning, collapsed to one grey row until tapped.
private struct ThoughtRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                        Text("Thought")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("thoughtRow")
                if expanded {
                    Text(MarkdownText.inline(text))
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Spacer(minLength: 28)
        }
    }
}

/// A tool call as a compact card: icon, title, status; tap for the detail.
private struct ToolCard: View {
    let call: ToolCall
    @State private var expanded = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard !call.detail.isEmpty else { return }
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(for: call.toolKind))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26, height: 26)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(call.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? 3 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ToolStatusView(status: call.status)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toolCard")
                if expanded {
                    Divider().padding(.leading, 10)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(call.detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(10)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            Spacer(minLength: 28)
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.left.arrow.right"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct ToolStatusView: View {
    let status: ToolStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Pending"))
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Running"))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityLabel(Text("Completed"))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityLabel(Text("Failed"))
        case .other:
            EmptyView()
        }
    }
}

private struct NoticeCapsule: View {
    let text: String
    let style: NoticeStyle

    var body: some View {
        HStack(spacing: 5) {
            switch style {
            case .stopped: Image(systemName: "stop.fill")
            case .error: Image(systemName: "exclamationmark.triangle.fill")
            case .system: EmptyView()
            }
            Text(text)
                .multilineTextAlignment(.center)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(style == .error ? Theme.danger : Theme.noticeText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(style == .error ? Theme.danger.opacity(0.12) : Theme.noticeBackground, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("notice-\(text)")
    }
}
