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
            Group {
                if message.attachments.isEmpty {
                    textContent
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    mediaContent
                }
            }
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

extension UserBubble {
    private var images: [MessageAttachment] { message.attachments.filter(\.showsAsImage) }
    private var files: [MessageAttachment] { message.attachments.filter { !$0.showsAsImage } }
    private var hasText: Bool { !message.text.isEmpty }

    private var showsSender: Bool { message.isRemote && position.startsGroup }

    fileprivate var senderLabel: some View {
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

    fileprivate var meta: some View {
        HStack(spacing: 4) {
            Text(date, format: .dateTime.hour().minute())
            if let tick = message.tick, tick != .failed {
                DeliveryTickView(tick: tick, color: palette.userBubbleMeta)
            }
        }
        .font(.caption2)
        .foregroundStyle(palette.userBubbleMeta)
    }

    fileprivate var textContent: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if showsSender { senderLabel }
            Text(message.text)
                .foregroundStyle(palette.userBubbleText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            meta
        }
    }

    /// Photos and files above the text, like Telegram's media with a caption; a bubble of images alone carries its
    /// time on a dark pill over the last image.
    fileprivate var mediaContent: some View {
        let imageOnly = !images.isEmpty && files.isEmpty && !hasText
        // As wide as the images (plus their inset), or as the file rows.
        let width: CGFloat = images.isEmpty ? 270 : MediaGrid.width(for: images) + 6
        return VStack(alignment: .leading, spacing: 0) {
            if showsSender {
                senderLabel
                    .padding(.horizontal, 9)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            if !images.isEmpty {
                MediaGrid(images: images) { model.openImage($0, in: message) }
                    .overlay(alignment: .bottomTrailing) {
                        if imageOnly {
                            HStack(spacing: 4) {
                                Text(date, format: .dateTime.hour().minute())
                                if let tick = message.tick, tick != .failed {
                                    DeliveryTickView(tick: tick, color: .white)
                                }
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.45), in: Capsule())
                            .padding(7)
                            .allowsHitTesting(false)
                        }
                    }
                    .padding(3)
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(files) { file in
                        MessageFileRow(
                            attachment: file, computerName: model.computerName, textColor: palette.userBubbleText,
                            metaColor: palette.userBubbleMeta)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, images.isEmpty ? 7 : 6)
            }
            if hasText {
                Text(message.text)
                    .foregroundStyle(palette.userBubbleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
            }
            if !imageOnly {
                meta
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 10)
                    .padding(.top, 3)
                    .padding(.bottom, 7)
            }
        }
        .frame(width: width, alignment: .leading)
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
