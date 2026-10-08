import AppKit
import SwiftUI

/// What one transcript row shows: a message and how it is shown right now.
struct TranscriptRowModel {
    var message: Message
    /// This is the newest message of a turn that is still producing output.
    var isStreaming = false
    /// When the message was sent; shown on prompts and replies while timestamps are on.
    var timestamp: Date?
    var highlight: TranscriptRowHighlight = .none
    /// Whether a reasoning or tool block is open.
    var isExpanded = false

    /// The height of a row that is as tall whatever its width and its text, so it never needs
    /// laying out to be placed: a folded reasoning block that has finished, which is most of a long task.
    var fixedHeight: CGFloat? {
        message.kind == .thought && !isStreaming && !isExpanded ? TranscriptFoldHeader.minHeight : nil
    }

    /// Roughly how tall the row is, until it has been laid out.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        let column = max(width, 240)
        func lines(_ text: String, characterWidth: CGFloat, in width: CGFloat) -> CGFloat {
            max(1, (CGFloat(text.utf8.count) * characterWidth / max(width, 80)).rounded(.up))
        }
        let images: CGFloat = message.attachments?.isEmpty == false ? 132 : 0
        switch message.kind {
        case .user:
            return min(lines(message.text, characterWidth: 8.5, in: column - 92) * 20 + 26, 446) + images
        case .assistant:
            return 30 + lines(message.text, characterWidth: 8, in: column) * 26 + (images > 0 ? images + 12 : 0)
        case .thought:
            let open = isExpanded ? min(360, lines(message.text, characterWidth: 7, in: column - 56) * 20) + 12 : 0
            return TranscriptFoldHeader.minHeight + open + (isStreaming ? ThoughtPreview.height + 14 : 0)
        case .tool:
            let open = isExpanded ? min(260, CGFloat((message.detail ?? "").utf8.count / 60 + 1) * 18) + 12 : 0
            return TranscriptFoldHeader.minHeight + open + (images > 0 ? images + 12 : 0)
        case .system:
            return 26 + lines(message.text, characterWidth: 7.5, in: column - 50) * 18
        }
    }
}

/// One row of the transcript. A row is laid out by hand: it says how tall it is at a width, and
/// puts its subviews where they go at the size the list gives it. Nothing in it sizes itself.
@MainActor
class TranscriptRowView: NSView {
    private(set) var model: TranscriptRowModel
    weak var list: TranscriptListView?
    private var highlightView: TranscriptHighlightView?
    private var arrangedSize = NSSize(width: -1, height: -1)
    private var needsArrange = true

    /// A row for a message, in `superview` when there is one. It goes there before it shows its
    /// message, so its text is rendered once, for the appearance it will be seen in.
    static func make(_ model: TranscriptRowModel, list: TranscriptListView?, in superview: NSView? = nil, width: CGFloat = 0) -> TranscriptRowView {
        let row: TranscriptRowView
        switch model.message.kind {
        case .user: row = TranscriptUserRow(model: model, list: list)
        case .assistant: row = TranscriptAssistantRow(model: model, list: list)
        case .thought: row = TranscriptThoughtRow(model: model, list: list)
        case .tool: row = TranscriptToolRow(model: model, list: list)
        case .system: row = TranscriptSystemRow(model: model, list: list)
        }
        // Its width too, when that is known: its text is then laid out once, at that width.
        if width > 1 { row.setFrameSize(NSSize(width: width, height: 0)) }
        superview?.addSubview(row)
        row.configure(model)
        return row
    }

    required init(model: TranscriptRowModel, list: TranscriptListView?) {
        self.model = model
        self.list = list
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows the row's message as it is now.
    final func configure(_ model: TranscriptRowModel) {
        self.model = model
        show(model)
        showHighlight()
        needsArrange = true
    }

    final func height(forWidth width: CGFloat) -> CGFloat { ceil(layoutContent(width: width, place: false)) }

    /// Puts the row's subviews where they go in its current size.
    final func arrange() {
        guard needsArrange || bounds.size != arrangedSize else { return }
        needsArrange = false
        arrangedSize = bounds.size
        _ = layoutContent(width: bounds.width, place: true)
        highlightView?.frame = bounds.insetBy(dx: -TranscriptHighlightView.reach, dy: -TranscriptHighlightView.reach)
    }

    /// The transcript scrolled: what follows the pointer is no longer under it.
    func forgetHover() {}

    /// Whether the height the row gave is the one it will keep. A reply still waiting for an
    /// image is measured again when it next comes into sight, loaded by then or not.
    var isHeightSettled: Bool { true }

    // MARK: For the rows

    /// Creates the subviews every state of the row has.
    func build() {}
    /// Shows `model`, adding and removing the subviews its state calls for.
    func show(_ model: TranscriptRowModel) {}
    /// The row's height at `width`; with `place`, its subviews are put there too.
    func layoutContent(width: CGFloat, place: Bool) -> CGFloat { 0 }

    /// Something in the row takes another height without the message having changed.
    final func contentResized() {
        needsArrange = true
        list?.rowResized(model.message.id)
    }

    final func imageGrid(_ attachments: [MessageAttachment]) -> some View {
        TranscriptImageGrid(attachments: attachments).environment(\.openImage, list?.openImage)
    }

    private func showHighlight() {
        guard model.highlight != .none else {
            highlightView?.removeFromSuperview()
            highlightView = nil
            setAccessibilitySelected(false)
            return
        }
        let view = highlightView ?? {
            let view = TranscriptHighlightView()
            addSubview(view, positioned: .below, relativeTo: subviews.first)
            highlightView = view
            return view
        }()
        view.highlight = model.highlight
        view.frame = bounds.insetBy(dx: -TranscriptHighlightView.reach, dy: -TranscriptHighlightView.reach)
        setAccessibilitySelected(true)
    }
}

// MARK: - Prompt

/// A prompt: a bubble at the trailing edge, as wide as its text, under what was sent with it.
final class TranscriptUserRow: TranscriptRowView {
    /// Past this size a prompt (usually pasted logs) is shown in a scrolling text view.
    static let longPromptBytes = 8_000

    private let bubble = TranscriptFillView(color: Theme.palette.sidebarNS, radius: 16)
    private var text: TranscriptSelectableText?
    private var longText: TranscriptTextBox?
    private var timestamp: TranscriptTextLabel?
    private var attachments: TranscriptHostedView?
    private var shownAttachments: [UUID] = []

    override func build() {
        addSubview(bubble)
    }

    override func show(_ model: TranscriptRowModel) {
        let message = model.message
        bubble.isHidden = message.text.isEmpty
        if message.text.isEmpty {
            text?.removeFromSuperview(); text = nil
            longText?.removeFromSuperview(); longText = nil
        } else if message.text.utf8.count > Self.longPromptBytes {
            text?.removeFromSuperview(); text = nil
            let box = longText ?? {
                let box = TranscriptTextBox(style: .body, maxHeight: 420)
                addSubview(box)
                longText = box
                return box
            }()
            box.update(text: message.text)
        } else {
            longText?.removeFromSuperview(); longText = nil
            let view = text ?? {
                let view = TranscriptSelectableText.make()
                addSubview(view)
                text = view
                return view
            }()
            view.show(message.text, font: .systemFont(ofSize: 16), color: Theme.palette.inkNS)
        }
        if let date = model.timestamp {
            let label = TranscriptParts.timestamp(date, into: timestamp)
            if timestamp == nil { addSubview(label); timestamp = label }
        } else {
            timestamp?.removeFromSuperview(); timestamp = nil
        }
        let sent = message.attachments ?? []
        if sent.isEmpty {
            attachments?.removeFromSuperview(); attachments = nil
            shownAttachments = []
        } else if shownAttachments != sent.map(\.id) {
            shownAttachments = sent.map(\.id)
            let content = SentAttachmentsView(attachments: sent).environment(\.openImage, list?.openImage)
            if let attachments { attachments.show(content) } else {
                let view = TranscriptHostedView(content)
                addSubview(view)
                attachments = view
            }
        }
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let stamp = timestamp?.size() ?? .zero
        // A 48 pt margin at the leading edge, then the time, then the prompt, 10 pt apart.
        let available = max(40, width - 48 - 10 - (timestamp == nil ? 0 : stamp.width + 10))
        var y: CGFloat = 0
        var stackWidth: CGFloat = 0
        var sentSize = NSSize.zero
        if let attachments {
            sentSize = attachments.size(fitting: available)
            stackWidth = sentSize.width
            y = sentSize.height
        }
        var textSize = NSSize.zero, bubbleY: CGFloat = 0
        if longText != nil || text != nil {
            let inner = max(1, available - 34)
            if let longText { textSize = NSSize(width: inner, height: longText.height(forWidth: inner)) }
            else if let text { textSize = text.fit(width: inner) }
            if y > 0 { y += 8 }
            bubbleY = y
            y += textSize.height + 26
            stackWidth = max(stackWidth, textSize.width + 34)
        }
        let height = max(y, timestamp == nil ? 0 : 16 + stamp.height)
        guard place else { return height }
        attachments?.frame = NSRect(x: width - sentSize.width, y: 0, width: sentSize.width, height: sentSize.height)
        let bubbleFrame = NSRect(x: width - textSize.width - 34, y: bubbleY, width: textSize.width + 34, height: textSize.height + 26)
        bubble.frame = bubbleFrame
        let textFrame = NSRect(x: bubbleFrame.minX + 17, y: bubbleY + 13, width: textSize.width, height: textSize.height)
        text?.frame = textFrame
        longText?.frame = textFrame
        timestamp?.frame = NSRect(x: width - stackWidth - 10 - stamp.width, y: 16, width: stamp.width, height: stamp.height)
        return height
    }
}

// MARK: - Reply

/// A reply: the Crok mark and name, the reply as one TextKit text view, and its images.
final class TranscriptAssistantRow: TranscriptRowView {
    private let mark = TranscriptMarkView()
    private let name = TranscriptParts.label("Crok", size: 13, weight: .semibold, color: Theme.palette.inkNS)
    private var timestamp: TranscriptTextLabel?
    private var reply: TranscriptTextBox?
    private var images: TranscriptHostedView?
    private var shownImages: [UUID] = []

    private static let headerHeight: CGFloat = 18

    override var isHeightSettled: Bool { reply?.awaitsImage != true }

    override func build() {
        addSubview(mark)
        addSubview(name)
    }

    override func show(_ model: TranscriptRowModel) {
        let message = model.message
        let pictures = (message.attachments ?? []).filter { $0.kind == .image }
        if !message.text.isEmpty || message.attachments?.isEmpty != false {
            let box = reply ?? {
                let box = TranscriptTextBox(style: .reply(.response), maxHeight: .infinity, width: bounds.width)
                box.onContentResized = { [weak self] in self?.contentResized() }
                addSubview(box)
                reply = box
                return box
            }()
            box.update(text: message.text, isStreaming: model.isStreaming)
        } else {
            reply?.removeFromSuperview(); reply = nil
        }
        if let date = model.timestamp {
            let label = TranscriptParts.timestamp(date, into: timestamp)
            if timestamp == nil { addSubview(label); timestamp = label }
        } else {
            timestamp?.removeFromSuperview(); timestamp = nil
        }
        if pictures.isEmpty {
            images?.removeFromSuperview(); images = nil
            shownImages = []
        } else if shownImages != pictures.map(\.id) {
            shownImages = pictures.map(\.id)
            if let images { images.show(imageGrid(pictures)) } else {
                let view = TranscriptHostedView(imageGrid(pictures))
                addSubview(view)
                images = view
            }
        }
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        var y = Self.headerHeight
        var replyFrame = NSRect.zero, imagesFrame = NSRect.zero
        if let reply {
            y += 12
            replyFrame = NSRect(x: 0, y: y, width: width, height: reply.height(forWidth: width))
            y = replyFrame.maxY
        }
        if let images {
            y += 12
            let size = images.size(fitting: width)
            imagesFrame = NSRect(x: 0, y: y, width: size.width, height: size.height)
            y = imagesFrame.maxY
        }
        guard place else { return y }
        mark.frame = NSRect(x: 0, y: 0, width: Self.headerHeight, height: Self.headerHeight)
        let nameSize = name.size()
        name.frame = NSRect(x: Self.headerHeight + 7, y: ((Self.headerHeight - nameSize.height) / 2).rounded(), width: nameSize.width, height: nameSize.height)
        if let timestamp {
            let size = timestamp.size()
            timestamp.frame = NSRect(x: width - size.width, y: ((Self.headerHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        reply?.frame = replyFrame
        images?.frame = imagesFrame
        return y
    }
}

// MARK: - Reasoning

/// A reasoning block: folded to its header, open to its text, and while it streams folded, a
/// glimpse of its newest lines with the thinking colours around it.
final class TranscriptThoughtRow: TranscriptRowView {
    private static let cornerRadius: CGFloat = 12

    private let card = TranscriptFillView(color: Theme.palette.sidebarNS.fading(0.4), radius: TranscriptThoughtRow.cornerRadius)
    private let header = TranscriptFoldHeader()
    private let title = TranscriptThinkingTitle()
    private var liquid: ThinkingLayerView?
    private var bar: ThinkingLayerView?
    private var text: TranscriptTextBox?
    private var preview: TranscriptTextBox?

    override func build() {
        addSubview(card)
        header.addSubview(title)
        header.onToggle = { [weak self] in
            guard let self else { return }
            self.list?.setExpanded(self.model.message.id, !self.model.isExpanded)
        }
        addSubview(header)
    }

    override func show(_ model: TranscriptRowModel) {
        let message = model.message, streaming = model.isStreaming
        title.isStreaming = streaming
        header.isOpen = model.isExpanded
        header.setAccessibilityLabel(streaming ? "Thinking…" : "Thinking")
        if model.isExpanded {
            let box = text ?? {
                let box = TranscriptTextBox(style: .markdown, maxHeight: 360, width: bounds.width - TranscriptFoldHeader.contentLeading - 14)
                box.onContentResized = { [weak self] in self?.contentResized() }
                addSubview(box)
                text = box
                return box
            }()
            box.update(text: message.text, followsTail: streaming, isStreaming: streaming)
        } else {
            text?.removeFromSuperview(); text = nil
        }
        if streaming && !model.isExpanded && !message.text.isEmpty {
            let box = preview ?? {
                let box = TranscriptTextBox(style: .markdown, maxHeight: ThoughtPreview.height, showsScroller: false, width: bounds.width - TranscriptFoldHeader.contentLeading - 14)
                box.setAccessibilityLabel("Latest reasoning")
                addSubview(box)
                preview = box
                return box
            }()
            box.update(text: message.text, followsTail: true, isStreaming: true)
        } else {
            preview?.removeFromSuperview(); preview = nil
        }
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if streaming {
            if liquid == nil {
                let view = ThinkingLayerView(kind: .card(cornerRadius: Self.cornerRadius), animated: animated)
                addSubview(view, positioned: .below, relativeTo: card)
                liquid = view
            }
            if bar == nil {
                let view = ThinkingLayerView(kind: .bar, animated: animated)
                addSubview(view)
                bar = view
            }
            liquid?.setAnimated(animated)
            bar?.setAnimated(animated)
        } else {
            liquid?.removeFromSuperview(); liquid = nil
            bar?.removeFromSuperview(); bar = nil
        }
    }

    override func forgetHover() { header.forgetHover() }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let inner = max(1, width - TranscriptFoldHeader.contentLeading - 14)
        var y = TranscriptFoldHeader.minHeight
        var textFrame = NSRect.zero, previewFrame = NSRect.zero, barFrame = NSRect.zero
        if let text {
            textFrame = NSRect(x: TranscriptFoldHeader.contentLeading, y: y, width: inner, height: text.height(forWidth: inner))
            y = textFrame.maxY + 12
        }
        if let preview {
            // Drawn 4 pt into the header's room, with 6 pt under it.
            previewFrame = NSRect(x: TranscriptFoldHeader.contentLeading, y: y - 4, width: inner, height: preview.height(forWidth: inner))
            y = previewFrame.maxY + 6
        }
        if bar != nil {
            barFrame = NSRect(x: 14, y: y + 2, width: max(1, width - 28), height: 2)
            y = barFrame.maxY + 8
        }
        guard place else { return y }
        header.frame = NSRect(x: 0, y: 0, width: width, height: TranscriptFoldHeader.minHeight)
        let titleSize = title.contentSize
        title.frame = NSRect(x: TranscriptFoldHeader.contentLeading, y: ((TranscriptFoldHeader.minHeight - titleSize.height) / 2).rounded(),
                             width: titleSize.width, height: titleSize.height)
        text?.frame = textFrame
        if let preview {
            preview.frame = previewFrame
            // Once the glimpse is full, its top edge fades so its lines seem to scroll up out of it.
            preview.fadesTop = previewFrame.height >= ThoughtPreview.height - 1
        }
        bar?.frame = barFrame
        card.frame = NSRect(x: 0, y: 0, width: width, height: y)
        liquid?.frame = card.frame.insetBy(dx: -ThinkingLayerView.glowRoom, dy: -ThinkingLayerView.glowRoom)
        return y
    }
}

// MARK: - Tool call

/// A tool call: its title and status, folded over what it printed; the images it returned stay
/// in sight under it.
final class TranscriptToolRow: TranscriptRowView {
    private let card = TranscriptFillView(color: Theme.palette.sidebarNS.fading(0.65), radius: 9)
    private let header = TranscriptFoldHeader()
    private let icon = NSImageView()
    private let title = TranscriptTextLabel()
    private let status = TranscriptParts.label(size: 12, color: Theme.palette.mutedNS)
    private var output: TranscriptTextBox?
    private var noOutput: TranscriptTextLabel?
    private var images: TranscriptHostedView?
    private var shownImages: [UUID] = []
    private var shownTitle = ""
    private var shownStatus: String?

    override func build() {
        addSubview(card)
        icon.imageScaling = .scaleNone
        title.font = .systemFont(ofSize: 14)
        title.maximumLines = 2
        for view in [icon, title, status] as [NSView] { header.addSubview(view) }
        header.onToggle = { [weak self] in
            guard let self else { return }
            self.list?.setExpanded(self.model.message.id, !self.model.isExpanded)
        }
        addSubview(header)
    }

    override func show(_ model: TranscriptRowModel) {
        let message = model.message
        if shownStatus != message.status || icon.image == nil {
            shownStatus = message.status
            let failed = message.status == "failed"
            icon.image = TranscriptParts.symbol(message.status == "completed" ? "checkmark.circle" : failed ? "xmark.circle" : "terminal", size: 14)
            icon.contentTintColor = failed ? .systemRed : Theme.palette.mutedNS
            status.text = (message.status ?? "pending").replacingOccurrences(of: "_", with: " ")
        }
        if shownTitle != message.text || title.attributedText == nil {
            shownTitle = message.text
            let text = TranscriptParts.toolTitle(message.text)
            title.attributedText = text
            header.setAccessibilityLabel(text.string)
        }
        header.isOpen = model.isExpanded
        let pictures = (message.attachments ?? []).filter { $0.kind == .image }
        let detail = message.detail ?? ""
        if model.isExpanded, !detail.isEmpty {
            noOutput?.removeFromSuperview(); noOutput = nil
            let box = output ?? {
                let box = TranscriptTextBox(style: .monospaced, wrapsLines: false, maxHeight: 260)
                addSubview(box)
                output = box
                return box
            }()
            box.update(text: detail)
        } else {
            output?.removeFromSuperview(); output = nil
            if model.isExpanded, message.attachments?.isEmpty != false {
                if noOutput == nil {
                    let label = TranscriptParts.label("No additional output.", size: 13, color: Theme.palette.mutedNS)
                    addSubview(label)
                    noOutput = label
                }
            } else {
                noOutput?.removeFromSuperview(); noOutput = nil
            }
        }
        if pictures.isEmpty {
            images?.removeFromSuperview(); images = nil
            shownImages = []
        } else if shownImages != pictures.map(\.id) {
            shownImages = pictures.map(\.id)
            if let images { images.show(imageGrid(pictures)) } else {
                let view = TranscriptHostedView(imageGrid(pictures))
                addSubview(view)
                images = view
            }
        }
    }

    override func forgetHover() { header.forgetHover() }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let iconSize = icon.image?.size ?? NSSize(width: 16, height: 16)
        let statusSize = status.size()
        // The icon, the title, and the status at the trailing edge, 8 pt apart and at least 8 pt between the last two.
        let titleX = TranscriptFoldHeader.contentLeading + ceil(iconSize.width) + 8
        let titleSize = title.size(fitting: max(20, width - TranscriptFoldHeader.contentTrailing - statusSize.width - 24 - titleX))
        let headerHeight = max(TranscriptFoldHeader.minHeight, ceil(max(iconSize.height, titleSize.height, statusSize.height)) + 16)
        var y = headerHeight
        var outputFrame = NSRect.zero, noOutputFrame = NSRect.zero, imagesFrame = NSRect.zero
        let hasImages = images != nil
        if model.isExpanded {
            let inner = max(1, width - 28)
            if let output {
                outputFrame = NSRect(x: 14, y: y, width: inner, height: output.height(forWidth: inner))
                y = outputFrame.maxY
            } else if let noOutput {
                let size = noOutput.size()
                noOutputFrame = NSRect(x: 14, y: y, width: min(size.width, inner), height: size.height)
                y = noOutputFrame.maxY
            }
            y += hasImages && output == nil ? 0 : 12
        }
        if let images {
            let size = images.size(fitting: max(1, width - TranscriptFoldHeader.contentLeading - 14))
            imagesFrame = NSRect(x: TranscriptFoldHeader.contentLeading, y: y, width: size.width, height: size.height)
            y = imagesFrame.maxY + 12
        }
        guard place else { return y }
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        icon.frame = NSRect(x: TranscriptFoldHeader.contentLeading, y: ((headerHeight - iconSize.height) / 2).rounded(), width: ceil(iconSize.width), height: ceil(iconSize.height))
        title.frame = NSRect(x: titleX, y: ((headerHeight - titleSize.height) / 2).rounded(), width: titleSize.width, height: titleSize.height)
        status.frame = NSRect(x: width - TranscriptFoldHeader.contentTrailing - statusSize.width, y: ((headerHeight - statusSize.height) / 2).rounded(),
                              width: statusSize.width, height: statusSize.height)
        output?.frame = outputFrame
        noOutput?.frame = noOutputFrame
        images?.frame = imagesFrame
        card.frame = NSRect(x: 0, y: 0, width: width, height: y)
        return y
    }
}

// MARK: - The app's own lines

/// A line from the app itself, usually that something failed: as wide as what it says.
final class TranscriptSystemRow: TranscriptRowView {
    private let card = TranscriptFillView(color: Theme.palette.sidebarNS, radius: 9)
    private let icon = TranscriptParts.symbolView("exclamationmark.circle", size: 14, color: Theme.palette.mutedNS)
    private let text = TranscriptSelectableText.make()

    override func build() {
        addSubview(card)
        addSubview(icon)
        addSubview(text)
    }

    override func show(_ model: TranscriptRowModel) {
        text.show(model.message.text, font: .systemFont(ofSize: 14), color: Theme.palette.mutedNS)
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let iconSize = icon.image?.size ?? NSSize(width: 16, height: 16)
        let textX = 13 + ceil(iconSize.width) + 9
        let textSize = text.fit(width: max(1, width - textX - 13))
        let height = 13 + max(ceil(iconSize.height), textSize.height) + 13
        guard place else { return height }
        card.frame = NSRect(x: 0, y: 0, width: min(width, textX + textSize.width + 13), height: height)
        icon.frame = NSRect(x: 13, y: 13, width: ceil(iconSize.width), height: ceil(iconSize.height))
        text.frame = NSRect(x: textX, y: 13, width: textSize.width, height: textSize.height)
        return height
    }
}
