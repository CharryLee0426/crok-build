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
        case .thought:
            ThoughtRow(active: model.activeThoughtID == item.id)
        case .tool(let call):
            ToolCard(call: call, turnRunning: model.toolRuns(at: item.seq))
        case .notice(let text, let style):
            NoticeCapsule(text: text, style: style)
        case .botCard(let card):
            BotCardView(card: card, choices: model.choices(for: card)) { choice in
                model.choose(choice, on: card)
            }
        }
    }
}

private struct DayHeader: View {
    let date: Date
    @Environment(\.sessionPalette) private var palette

    var body: some View {
        Text(RelativeTime.dayHeader(date, now: Date()))
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.serviceText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.serviceBackground, in: Capsule())
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
    @Environment(\.sessionPalette) private var palette

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
                    .foregroundStyle(palette.userBubbleText.opacity(0.65))
                }
                Text(message.text)
                    .foregroundStyle(palette.userBubbleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(date, format: .dateTime.hour().minute())
                    if let tick = message.tick, tick != .failed {
                        DeliveryTickView(tick: tick, color: palette.userBubbleMeta)
                    }
                }
                .font(.caption2)
                .foregroundStyle(palette.userBubbleMeta)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.userBubble, in: BubbleShape(outgoing: true, position: position))
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

private struct NoticeCapsule: View {
    let text: String
    let style: NoticeStyle
    @Environment(\.sessionPalette) private var palette

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
        .foregroundStyle(style == .error ? Theme.danger : palette.serviceText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            style == .error
                ? AnyShapeStyle(palette.onWallpaper ? Theme.card : Theme.danger.opacity(0.12))
                : AnyShapeStyle(palette.serviceBackground),
            in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("notice-\(text)")
    }
}
