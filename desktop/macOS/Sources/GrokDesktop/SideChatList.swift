import AppKit

// A side chat's messages, in AppKit (see `SideChatListView`), built from the transcript's row parts.

/// Sizes the side chat's views share.
enum SideChatMetrics {
    static let fontSize: CGFloat = 13.5
    static let reply = MarkdownStyle(fontSize: 13.5, blockSpacing: 9)
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    static let spacing: CGFloat = 14
    /// Following stops this far from the end, and resumes within it.
    static let followDistance: CGFloat = 24
}

/// One row of a side chat.
enum SideChatRow {
    /// What a side chat is for, while it has no messages.
    case intro
    case message(SideChatMessage)
    /// "Crok is answering…", under the question being answered.
    case pending

    private static let introID = UUID()
    private static let pendingID = UUID()

    var id: UUID {
        switch self {
        case .intro: return Self.introID
        case .message(let message): return message.id
        case .pending: return Self.pendingID
        }
    }
}

/// A side chat's messages, laid out by hand as the transcript's are (see `TranscriptListView`).
///
/// The side chat used to be a SwiftUI lazy stack, which measures its rows again whenever an
/// estimate turns out wrong; with a long question pasted in and a few answers below it, typing
/// stalled the window for a second at a time. Here each row is measured once for a width, when it
/// first comes near what is in sight, and estimated until then; only the rows near what is in
/// sight have views. While the end is in sight it stays at the bottom as messages arrive;
/// otherwise the first row in sight stays where it is.
@MainActor
final class SideChatListView: NSView {
    let scrollView = NSScrollView()
    private let document = SideChatDocumentView()
    /// A failed question's Retry was clicked.
    var onRetry: ((SideChatMessage) -> Void)?

    private var rows: [SideChatRow] = []
    private var heights: [CGFloat] = []
    /// The width each row's height was measured at; negative while it is an estimate.
    private var measuredWidths: [CGFloat] = []
    private var indexByID: [UUID: Int] = [:]
    private var tops: [CGFloat] = []
    private var topsDirty = true
    private var contentHeight: CGFloat = 0
    /// The rows that have views: those in sight and a little beyond.
    private var realized: [UUID: SideChatRowView] = [:]
    private var columnWidth: CGFloat = 0

    private(set) var isFollowing = true
    private var isLayingOut = false
    private var needsFollowUp = false
    private var lastOrigin: CGFloat = 0
    private var lastViewport = NSSize.zero

    /// What stays where it is while the rows are laid out.
    private enum Anchor {
        /// The end of the content, at the bottom of the view.
        case bottom
        /// A row's top, `offset` points above the top of what is in sight.
        case row(UUID, offset: CGFloat)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: - What is shown

    /// Shows a side chat. Called for every change, with all of its messages: a message's text never
    /// changes, so the rows still there keep their views and heights. `scrollsToEnd` brings the end
    /// into sight and follows it, as after asking a question.
    func show(_ messages: [SideChatMessage], isPending: Bool, scrollsToEnd: Bool = false) {
        let next: [SideChatRow] = messages.isEmpty ? [.intro] : messages.map { .message($0) } + (isPending ? [.pending] : [])
        if scrollsToEnd { isFollowing = true }
        guard next.count != rows.count || zip(next, rows).contains(where: { $0.id != $1.id }) else {
            if scrollsToEnd { relayout(anchor: .bottom) }
            return
        }
        let held = isFollowing ? nil : positionAnchor()
        let oldHeights = heights, oldWidths = measuredWidths, oldIndex = indexByID
        rows = next
        indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        heights = rows.map { row in oldIndex[row.id].map { oldHeights[$0] } ?? estimatedHeight(row) }
        measuredWidths = rows.map { row in oldIndex[row.id].map { oldWidths[$0] } ?? -1 }
        for (id, view) in realized where indexByID[id] == nil {
            view.removeFromSuperview()
            realized[id] = nil
        }
        topsDirty = true
        relayout(anchor: held)
    }

    /// Forgets the rows shown, for another task's side chat, which opens at its end.
    func reset() {
        for view in realized.values { view.removeFromSuperview() }
        realized = [:]
        rows = []
        heights = []
        measuredWidths = []
        indexByID = [:]
        topsDirty = true
        isFollowing = true
    }

    /// A row takes another height without its message having changed: an image in an answer loaded.
    func rowResized(_ id: UUID) {
        guard let index = indexByID[id] else { return }
        measuredWidths[index] = -1
        relayout()
    }

    /// Roughly how tall a row is, until it has been laid out.
    private func estimatedHeight(_ row: SideChatRow) -> CGFloat {
        let width = max(columnWidth, 200)
        func lines(_ text: String, characterWidth: CGFloat, in width: CGFloat) -> CGFloat {
            max(1, (CGFloat(text.utf8.count) * characterWidth / max(width, 80)).rounded(.up))
        }
        switch row {
        case .intro: return 96
        case .pending: return 16
        case .message(let message):
            switch message.role {
            case .question: return min(lines(message.text, characterWidth: 7, in: width - 60) * 17, SideChatQuestionRow.longTextHeight) + 16
            case .answer: return 28 + lines(message.text, characterWidth: 7, in: width) * 20
            case .failure: return 20 + max(31, lines(message.text, characterWidth: 6.5, in: width - 110) * 16)
            }
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout()
    }

    private var distanceFromEnd: CGFloat { contentHeight - scrollView.contentView.bounds.maxY }

    private func recomputeTops() {
        topsDirty = false
        tops.removeAll(keepingCapacity: true)
        tops.reserveCapacity(heights.count)
        var y = SideChatMetrics.verticalPadding
        for height in heights {
            tops.append(y)
            y += height + SideChatMetrics.spacing
        }
        contentHeight = y - (heights.isEmpty ? 0 : SideChatMetrics.spacing) + SideChatMetrics.verticalPadding
    }

    /// The first row that ends below `y`, or the row count when none does.
    private func firstRow(endingAfter y: CGFloat) -> Int {
        var low = 0, high = min(tops.count, heights.count)
        while low < high {
            let middle = (low + high) / 2
            if tops[middle] + heights[middle] > y { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The rows that reach into the band from `start` to `end`.
    private func rows(from start: CGFloat, to end: CGFloat) -> Range<Int> {
        let first = firstRow(endingAfter: start)
        var low = first, high = min(tops.count, heights.count)
        while low < high {
            let middle = (low + high) / 2
            if tops[middle] >= end { high = middle } else { low = middle + 1 }
        }
        return first..<low
    }

    /// The first row in sight and how far above the top of the view it starts, preferring a row
    /// whose height is known: rows above it that are measured for the first time then move nothing.
    private func positionAnchor() -> Anchor {
        let count = min(tops.count, rows.count)
        guard count > 0 else { return .bottom }
        let bounds = scrollView.contentView.bounds
        let first = min(firstRow(endingAfter: bounds.minY), count - 1)
        var index = first
        while index < count, tops[index] < bounds.maxY {
            if measuredWidths[index] == columnWidth { return .row(rows[index].id, offset: bounds.minY - tops[index]) }
            index += 1
        }
        return .row(rows[first].id, offset: bounds.minY - tops[first])
    }

    private func origin(for anchor: Anchor, viewport: NSSize) -> CGFloat {
        let most = max(0, contentHeight - viewport.height)
        switch anchor {
        case .bottom:
            return most.rounded()
        case .row(let id, let offset):
            guard let index = indexByID[id], index < tops.count else { return min(max(scrollView.contentView.bounds.minY, 0), most).rounded() }
            return min(max(tops[index] + offset, 0), most).rounded()
        }
    }

    /// Gives a row its view and has the view say how tall the row is, unless that is known for
    /// this width. Returns whether the height changed.
    private func measure(_ index: Int) -> Bool {
        let row = rows[index]
        let view = realized[row.id] ?? {
            let view = SideChatRowView.make(row, list: self, in: document, width: columnWidth)
            realized[row.id] = view
            return view
        }()
        guard measuredWidths[index] != columnWidth else { return false }
        let height = view.height(forWidth: columnWidth)
        measuredWidths[index] = columnWidth
        guard height != heights[index] else { return false }
        heights[index] = height
        topsDirty = true
        return true
    }

    /// Places the rows. `anchor` stays where it is; without one that is the end of the content
    /// while it is followed, and the first row in sight otherwise. `scrolled` is the reader moving
    /// the view, which is then left where they put it unless a height changed.
    private func relayout(anchor requested: Anchor? = nil, scrolled: Bool = false) {
        guard !isLayingOut else { needsFollowUp = true; return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.size
        guard viewport.width > 40, viewport.height > 1, !rows.isEmpty else { return }
        isLayingOut = true
        defer {
            isLayingOut = false
            if needsFollowUp {
                needsFollowUp = false
                DispatchQueue.main.async { [weak self] in self?.relayout() }
            }
        }

        let anchor = requested ?? (isFollowing ? .bottom : positionAnchor())
        columnWidth = max(1, viewport.width - SideChatMetrics.horizontalPadding * 2)
        if topsDirty || tops.count != heights.count { recomputeTops() }
        let beyond = min(400, viewport.height * 0.5)
        var origin = self.origin(for: anchor, viewport: viewport)
        var settled = false, moved = false
        // Laying a row out can change its height, which moves the rows after it and so which rows
        // are in sight. Each row is measured once for a width, so this ends; the limit is for the
        // frame it runs in.
        for _ in 0..<8 {
            var changed = false
            for index in rows(from: origin - beyond, to: origin + viewport.height + beyond) where measure(index) { changed = true }
            guard changed else { settled = true; break }
            moved = true
            recomputeTops()
            origin = self.origin(for: anchor, viewport: viewport)
        }
        if !settled { needsFollowUp = true }

        let size = NSSize(width: viewport.width, height: max(1, contentHeight))
        if document.frame.size != size { document.setFrameSize(size) }
        var shown = Set<UUID>()
        for index in rows(from: origin - beyond, to: origin + viewport.height + beyond) {
            let id = rows[index].id
            guard let view = realized[id] else { continue }
            shown.insert(id)
            let frame = NSRect(x: SideChatMetrics.horizontalPadding, y: tops[index], width: columnWidth, height: heights[index])
            if view.frame != frame { view.frame = frame }
            view.arrange()
        }
        if shown.count != realized.count {
            for (id, view) in realized where !shown.contains(id) {
                view.removeFromSuperview()
                realized[id] = nil
            }
        }
        if !scrolled || moved, abs(clip.bounds.minY - origin) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
        }
        scrollView.reflectScrolledClipView(clip)
        lastOrigin = clip.bounds.minY
        lastViewport = clip.bounds.size
    }

    // MARK: - Scrolling

    @objc private func clipBoundsChanged(_ notification: Notification) {
        guard !isLayingOut else { return }
        let bounds = scrollView.contentView.bounds
        guard bounds.size == lastViewport else { relayout(); return }
        let old = lastOrigin
        lastOrigin = bounds.minY
        // Moving away from the end stops following; coming back to it follows again.
        if bounds.minY < old - 0.5, distanceFromEnd > 0.5 { isFollowing = false }
        else if bounds.minY > old + 0.5, distanceFromEnd <= SideChatMetrics.followDistance { isFollowing = true }
        relayout(anchor: positionAnchor(), scrolled: true)
    }

    // MARK: - For tests

    var rowCount: Int { rows.count }
    /// How many rows have views.
    var realizedRowCount: Int { realized.count }
    /// The height of all the rows, as far as they are known.
    var documentHeight: CGFloat { contentHeight }
    var distanceFromBottom: CGFloat { distanceFromEnd }
    func rowView(for id: UUID) -> SideChatRowView? { realized[id] }
    func rowFrame(for id: UUID) -> NSRect? {
        guard let index = indexByID[id], index < tops.count else { return nil }
        return NSRect(x: SideChatMetrics.horizontalPadding, y: tops[index], width: columnWidth, height: heights[index])
    }
}

/// Holds the rows; its origin is its top.
final class SideChatDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Rows

/// One row of a side chat, laid out by hand: it says how tall it is at a width, and puts its
/// subviews where they go at the size the list gives it. A message never changes, so a row shows
/// it once.
@MainActor
class SideChatRowView: NSView {
    let id: UUID
    weak var list: SideChatListView?
    private var arrangedSize = NSSize(width: -1, height: -1)

    /// A row for `row`, in `superview` when there is one. It goes there before it shows its
    /// message, so an answer is rendered once, for the appearance it will be seen in.
    static func make(_ row: SideChatRow, list: SideChatListView?, in superview: NSView? = nil, width: CGFloat = 0) -> SideChatRowView {
        let view: SideChatRowView
        switch row {
        case .intro: view = SideChatIntroRow(id: row.id, list: list)
        case .pending: view = SideChatPendingRow(id: row.id, list: list)
        case .message(let message):
            switch message.role {
            case .question: view = SideChatQuestionRow(message: message, list: list)
            case .answer: view = SideChatAnswerRow(message: message, list: list)
            case .failure: view = SideChatFailureRow(message: message, list: list)
            }
        }
        // Its width too, when that is known: an answer is then laid out once, at that width.
        if width > 1 { view.setFrameSize(NSSize(width: width, height: 0)) }
        superview?.addSubview(view)
        view.show()
        return view
    }

    init(id: UUID, list: SideChatListView?) {
        self.id = id
        self.list = list
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    final func height(forWidth width: CGFloat) -> CGFloat { ceil(layoutContent(width: width, place: false)) }

    /// Puts the row's subviews where they go in its current size.
    final func arrange() {
        guard bounds.size != arrangedSize else { return }
        arrangedSize = bounds.size
        _ = layoutContent(width: bounds.width, place: true)
    }

    /// Shows the row's content, once the row is in the list.
    func show() {}
    /// The row's height at `width`; with `place`, its subviews are put there too.
    func layoutContent(width: CGFloat, place: Bool) -> CGFloat { 0 }

    /// Something in the row takes another height without the message having changed.
    final func contentResized() {
        arrangedSize = NSSize(width: -1, height: -1)
        list?.rowResized(id)
    }
}

/// A question: a bubble at the trailing edge, as wide as its text. A long one (usually something
/// pasted) shows in a box that scrolls past a few lines, and is measured from its start alone.
final class SideChatQuestionRow: SideChatRowView {
    /// Past this many bytes or lines, a question is shown in the scrolling box.
    static let longTextBytes = 800
    static let longTextLines = 14
    /// The tallest the box grows before it scrolls.
    static let longTextHeight: CGFloat = 240

    private let message: SideChatMessage
    private let bubble = TranscriptFillView(color: Theme.palette.sidebarNS, radius: 13)
    private var text: TranscriptSelectableText?
    private var box: TranscriptTextBox?

    init(message: SideChatMessage, list: SideChatListView?) {
        self.message = message
        super.init(id: message.id, list: list)
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { nil }

    static func isLong(_ text: String) -> Bool {
        if text.utf8.count > longTextBytes { return true }
        var lines = 1
        for byte in text.utf8 where byte == 0x0A {
            lines += 1
            if lines > longTextLines { return true }
        }
        return false
    }

    /// Whether the question shows in the scrolling box.
    var isBoxed: Bool { box != nil }

    override func show() {
        if Self.isLong(message.text) {
            let box = TranscriptTextBox(style: .plain(SideChatMetrics.fontSize), maxHeight: Self.longTextHeight, width: max(1, bounds.width - 60))
            box.setAccessibilityLabel("Side question")
            addSubview(box)
            box.update(text: message.text)
            self.box = box
        } else {
            let view = TranscriptSelectableText.make()
            view.setAccessibilityLabel("Side question")
            addSubview(view)
            view.show(message.text, font: .systemFont(ofSize: SideChatMetrics.fontSize), color: Theme.palette.inkNS)
            text = view
        }
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        // A 36 pt margin at the leading edge; 12 pt and 8 pt inside the bubble.
        let inner = max(1, width - 36 - 24)
        var size = NSSize.zero
        if let box { size = NSSize(width: inner, height: box.height(forWidth: inner)) }
        else if let text { size = text.fit(width: inner) }
        let height = size.height + 16
        guard place else { return height }
        let bubbleFrame = NSRect(x: width - size.width - 24, y: 0, width: size.width + 24, height: height)
        bubble.frame = bubbleFrame
        let textFrame = NSRect(x: bubbleFrame.minX + 12, y: 8, width: size.width, height: size.height)
        text?.frame = textFrame
        box?.frame = textFrame
        return height
    }
}

/// An answer: the Crok mark and name, a Copy button, and the answer as one TextKit text view, as
/// the transcript's replies are.
final class SideChatAnswerRow: SideChatRowView {
    private static let headerHeight: CGFloat = 22
    private static let markSize: CGFloat = 15

    private let message: SideChatMessage
    private let mark = TranscriptMarkView()
    private let name = TranscriptParts.label("Crok", size: 11.5, weight: .semibold, color: Theme.palette.inkNS)
    private let copy = SideChatButton(style: .icon("doc.on.doc", size: 22), help: "Copy answer")
    private var reply: TranscriptTextBox?

    init(message: SideChatMessage, list: SideChatListView?) {
        self.message = message
        super.init(id: message.id, list: list)
        copy.action = { [text = message.text] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        addSubview(mark)
        addSubview(name)
        addSubview(copy)
    }

    required init?(coder: NSCoder) { nil }

    override func show() {
        let box = TranscriptTextBox(style: .reply(SideChatMetrics.reply), maxHeight: .infinity, width: bounds.width)
        box.onContentResized = { [weak self] in self?.contentResized() }
        addSubview(box)
        box.update(text: message.text)
        reply = box
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let replyY = Self.headerHeight + 6
        let replyHeight = reply?.height(forWidth: width) ?? 0
        let height = replyY + replyHeight
        guard place else { return height }
        mark.frame = NSRect(x: 0, y: ((Self.headerHeight - Self.markSize) / 2).rounded(), width: Self.markSize, height: Self.markSize)
        let nameSize = name.size()
        name.frame = NSRect(x: Self.markSize + 6, y: ((Self.headerHeight - nameSize.height) / 2).rounded(), width: nameSize.width, height: nameSize.height)
        copy.frame = NSRect(x: width - Self.headerHeight, y: 0, width: Self.headerHeight, height: Self.headerHeight)
        reply?.frame = NSRect(x: 0, y: replyY, width: width, height: replyHeight)
        return height
    }
}

/// A question that got no answer: why, and a Retry button that asks it again.
final class SideChatFailureRow: SideChatRowView {
    private let message: SideChatMessage
    private let card = TranscriptFillView(color: Theme.palette.sidebarNS, radius: 10)
    private let icon = TranscriptParts.symbolView("exclamationmark.triangle", size: 13, color: .systemOrange)
    private let text = TranscriptSelectableText.make()
    let retryButton = SideChatButton(style: .titled("Retry"), help: "Ask the question again")

    init(message: SideChatMessage, list: SideChatListView?) {
        self.message = message
        super.init(id: message.id, list: list)
        retryButton.setAccessibilityLabel("Retry")
        retryButton.action = { [weak self] in
            guard let self else { return }
            self.list?.onRetry?(self.message)
        }
        addSubview(card)
        addSubview(icon)
        addSubview(text)
        addSubview(retryButton)
    }

    required init?(coder: NSCoder) { nil }

    override func show() {
        text.show(message.text, font: .systemFont(ofSize: 12.5), color: Theme.palette.mutedNS)
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let iconSize = icon.image?.size ?? NSSize(width: 15, height: 14)
        let retrySize = retryButton.intrinsicContentSize
        // 10 pt inside the card; 8 pt after the icon; at least 20 pt between the text and Retry.
        let textX = 10 + ceil(iconSize.width) + 8
        let textSize = text.fit(width: max(1, width - textX - 20 - retrySize.width - 10))
        let height = 10 + max(ceil(iconSize.height), textSize.height, retrySize.height) + 10
        guard place else { return height }
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        icon.frame = NSRect(x: 10, y: 10, width: ceil(iconSize.width), height: ceil(iconSize.height))
        text.frame = NSRect(x: textX, y: 10, width: textSize.width, height: textSize.height)
        retryButton.frame = NSRect(x: width - 10 - retrySize.width, y: 10, width: retrySize.width, height: retrySize.height)
        return height
    }
}

/// "Crok is answering…" with a spinner, under the question being answered.
final class SideChatPendingRow: SideChatRowView {
    private let spinner = NSProgressIndicator()
    private let label = TranscriptParts.label("Crok is answering…", size: 12.5, color: Theme.palette.mutedNS)

    override init(id: UUID, list: SideChatListView?) {
        super.init(id: id, list: list)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.sizeToFit()
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let size = label.size()
        let height = ceil(max(spinner.frame.height, size.height))
        guard place else { return height }
        spinner.setFrameOrigin(NSPoint(x: 2, y: ((height - spinner.frame.height) / 2).rounded()))
        let labelX = 2 + spinner.frame.width + 8
        label.frame = NSRect(x: labelX, y: ((height - size.height) / 2).rounded(), width: min(size.width, max(0, width - labelX)), height: size.height)
        return height
    }
}

/// What a side chat is for, before its first question.
final class SideChatIntroRow: SideChatRowView {
    private let icon = TranscriptParts.symbolView("bubble.left.and.text.bubble.right", size: 20, weight: .light, color: Theme.palette.accentNS)
    private let title = TranscriptParts.label("Ask on the side", size: 14, weight: .semibold, color: Theme.palette.inkNS)
    private let detail = TranscriptParts.label("Crok answers from this task's conversation without interrupting what it is doing. Nothing here changes the task.",
                                               size: 12.5, color: Theme.palette.mutedNS)

    override init(id: UUID, list: SideChatListView?) {
        super.init(id: id, list: list)
        detail.maximumLines = 8
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutContent(width: CGFloat, place: Bool) -> CGFloat {
        let iconSize = icon.image?.size ?? NSSize(width: 24, height: 20)
        let titleSize = title.size(fitting: width), detailSize = detail.size(fitting: width)
        let iconFrame = NSRect(x: 0, y: 12, width: ceil(iconSize.width), height: ceil(iconSize.height))
        let titleFrame = NSRect(x: 0, y: iconFrame.maxY + 8, width: titleSize.width, height: titleSize.height)
        let detailFrame = NSRect(x: 0, y: titleFrame.maxY + 8, width: detailSize.width, height: detailSize.height)
        guard place else { return detailFrame.maxY + 12 }
        icon.frame = iconFrame
        title.frame = titleFrame
        detail.frame = detailFrame
        return detailFrame.maxY + 12
    }
}
