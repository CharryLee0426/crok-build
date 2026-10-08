import AppKit
import SwiftUI

/// How the transcript is shown, apart from its messages.
struct TranscriptDisplay: Equatable {
    var conversation: UUID?
    /// The newest message of a turn that is still producing output.
    var streamingID: UUID?
    var showTimestamps = true
    var matchID: UUID?
    var focusID: UUID?
    /// Reasoning and tool blocks that are open.
    var expanded: Set<UUID> = []
    var compact = false
    /// The line under the rows while a turn runs ("Working…"); nil when none does.
    var status: String?
}

/// Whether the transcript follows new output, for the button over it.
@MainActor
final class TranscriptFollowState: ObservableObject {
    @Published fileprivate(set) var isFollowing = true
    fileprivate weak var list: TranscriptListView?

    /// Follows the output, or stops.
    func toggle() { list?.toggleFollowing() }
}

/// The conversation's rows, in AppKit.
///
/// The rows used to be a SwiftUI lazy stack in a scroll view. A lazy stack estimates the height
/// of the rows it has not laid out, and lays out again when an estimate turns out wrong; on
/// macOS 26 that went round with the layout of the window around it without end, in one
/// transaction that never came back. Here nothing asks anything for its size in a loop. The list
/// keeps every row's height (measured once it has been on screen, estimated until then), places
/// the rows near what is in sight by hand, and makes views only for those. A task of thousands
/// of messages costs an array of heights; what is laid out is what is on screen.
///
/// What stays put when heights change is decided here too. While the output is followed, the end
/// of the content stays at the bottom. Otherwise the first row in sight stays where it is: rows
/// that are measured, opened, or still arriving above or below it do not move it.
@MainActor
final class TranscriptListView: NSView {
    let scrollView = TranscriptScrollView()
    private let document = TranscriptDocumentView()
    private let statusView = TranscriptStatusView()

    weak var tools: TranscriptToolsModel?
    weak var follow: TranscriptFollowState? { didSet { follow?.list = self } }
    var openImage: OpenImageAction?
    /// How much of the list's top is covered by something over it, below the window's title bar: the find bar.
    var coveredTop: CGFloat = 0

    /// What the list knows of a row besides its message and its height.
    private struct RowState {
        /// The width the height was measured at; negative while it is an estimate.
        var measuredWidth: CGFloat = -1
        /// The row changed since it was measured.
        var stale = true
        /// The height holds at every width (see `TranscriptRowModel.fixedHeight`).
        var fixed = false
        /// The height was measured while the row waited for an image (see `TranscriptRowView.isHeightSettled`).
        var unsettled = false
    }

    private var display = TranscriptDisplay()
    // The list's own copy of the transcript, kept in step message by message. Holding the
    // store's array instead would make every streamed update copy it whole.
    private var messages: [Message] = []
    private var heights: [CGFloat] = []
    private var states: [RowState] = []
    private var indexByID: [UUID: Int] = [:]
    /// Where each row starts, as last placed. `topsDirty` when heights changed since.
    private var tops: [CGFloat] = []
    private var topsDirty = true
    private var statusTop: CGFloat = 0
    private var contentHeight: CGFloat = 0
    /// The rows that have views: those in sight and a little beyond.
    private var realized: [UUID: TranscriptRowView] = [:]
    private var columnWidth: CGFloat = 0

    private(set) var isFollowing = true
    private var isLayingOut = false
    private var needsFollowUp = false
    private var lastOrigin: CGFloat = 0
    private var lastViewport = NSSize.zero
    private var lastInset: CGFloat = 0
    private var lastSample: TranscriptScrollSample?
    private var lastVisible: Int?? = .none
    private var phase = "idle"
    private var scrollEnd: DispatchWorkItem?
    private var pending = Reports()
    private var windowObservers: [NSObjectProtocol] = []
    private var widthSettled: DispatchWorkItem?

    /// What the transcript tools hear of a moment after it happened: they publish to SwiftUI,
    /// which a layout that SwiftUI itself is running must not do.
    private struct Reports {
        var scheduled = false
        var conversationChanged = false
        var transcriptChanged = false
        var visible: (index: Int?, id: UUID?)?
        var following: Bool?
    }

    /// What stays where it is while the rows are laid out.
    private enum Anchor {
        /// The end of the content, at the bottom of the view.
        case bottom
        /// A row's top, `offset` points above the top of what is in sight.
        case row(UUID, offset: CGFloat)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        // The rows are kept clear of what covers the list's top here, where it is known (see `topInset`).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        statusView.isHidden = true
        document.addSubview(statusView)
        scrollView.onWheel = { [weak self] event in self?.wheel(event) }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { nil }

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }

    // MARK: - What is shown

    /// Shows a transcript. Called for every change, with all of the messages: the list finds what
    /// changed, which for a task that is streaming is its last message. `unchangedBefore` is how
    /// many of the first messages are known to be as they were when the list last saw them (see
    /// `AppStore.transcriptFirstChange`); without it every message is compared.
    func apply(messages new: [Message], display next: TranscriptDisplay, unchangedBefore: Int? = nil) {
        let old = display
        display = next
        if next.conversation != old.conversation {
            removeRows(from: 0)
            setFollowing(true)
            lastVisible = .none
            pending.conversationChanged = true
            scheduleReports()
        }
        // What stays put is found before the rows change. Opening or closing a block keeps it
        // where the reader clicked it, followed or not.
        let folded = next.expanded != old.expanded, wasFollowing = isFollowing
        let held = wasFollowing && !folded ? nil : positionAnchor(inset: lastInset)
        let toggled = folded ? next.expanded.symmetricDifference(old.expanded).filter { realized[$0] != nil } : []
        let before = toggled.isEmpty ? nil : FoldStart(rows: realized.mapValues(\.frame), status: statusView.frame, origin: scrollView.contentView.bounds.minY)

        var changed = false
        var index = 0
        let shared = min(messages.count, new.count)
        if let unchangedBefore, next.conversation == old.conversation {
            // Taken on trust up to there, as long as the last of them is still the message it was.
            let start = min(unchangedBefore, shared)
            if start == 0 || messages[start - 1].id == new[start - 1].id { index = start }
        }
        while index < shared, messages[index].id == new[index].id {
            if !Self.same(messages[index], new[index]) {
                messages[index] = new[index]
                invalidate(index)
                changed = true
            }
            index += 1
        }
        // Past the first message that is another one, the transcript was replaced (a reload, a rewind).
        if index < messages.count {
            removeRows(from: index)
            changed = true
        }
        if index < new.count {
            messages.reserveCapacity(new.count)
            heights.reserveCapacity(new.count)
            states.reserveCapacity(new.count)
            for position in index..<new.count { append(new[position]) }
            changed = true
        }

        if next.showTimestamps != old.showTimestamps {
            for index in messages.indices where messages[index].kind == .user || messages[index].kind == .assistant { invalidate(index) }
        }
        if next.streamingID != old.streamingID {
            for id in [old.streamingID, next.streamingID] { invalidate(id) }
        }
        if folded {
            for id in next.expanded.symmetricDifference(old.expanded) { invalidate(id) }
        }
        if next.matchID != old.matchID || next.focusID != old.focusID {
            for id in Set([old.matchID, next.matchID, old.focusID, next.focusID].compactMap { $0 }) {
                if let index = indexByID[id] { realized[id]?.configure(model(at: index)) }
            }
        }
        if next.compact != old.compact || (next.status == nil) != (old.status == nil) { topsDirty = true }
        if let status = next.status { statusView.text = status }

        if changed {
            pending.transcriptChanged = true
            scheduleReports()
        }
        relayout(anchor: held)
        if folded, wasFollowing { setFollowing(distanceFromEnd <= TranscriptMetrics.followDistance) }
        if let before { animateFold(of: Set(toggled), from: before) }
    }

    /// Where the rows were on screen before a block opened or closed.
    private struct FoldStart {
        var rows: [UUID: NSRect]
        var status: NSRect
        var origin: CGFloat
    }

    /// Opening or closing a block moves the rows after it. They are placed where they end up, at
    /// once, and Core Animation carries them there from where they were while it uncovers the
    /// block from its top: nothing is laid out during the motion, however long the block (see `FoldMotion`).
    private func animateFold(of toggled: Set<UUID>, from start: FoldStart) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin = scrollView.contentView.bounds.minY
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        func slide(_ view: NSView, from old: NSRect) {
            guard let layer = view.layer else { return }
            // How far above where it now is the view was, on screen.
            let offset = (old.minY - start.origin) - (view.frame.minY - origin)
            guard abs(offset) > 0.5, abs(offset) < 4_000 else { return }
            // The layer is placed in its superlayer's coordinates, which run down the screen or up it.
            let down = layer.superlayer?.contentsAreFlipped() ?? true
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = down ? offset : -offset
            animation.toValue = 0
            animation.isAdditive = true
            animation.duration = Self.foldDuration
            animation.timingFunction = timing
            layer.add(animation, forKey: "fold.slide")
        }
        for (id, view) in realized {
            guard let old = start.rows[id] else { continue }
            slide(view, from: old)
            guard toggled.contains(id), view.frame.height > old.height + 0.5, let layer = view.layer else { continue }
            // The opened block is uncovered from its top: a mask as tall as it was grows to what it is.
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            let room: CGFloat = 24
            let down = layer.contentsAreFlipped()
            mask.anchorPoint = CGPoint(x: 0, y: down ? 0 : 1)
            mask.position = CGPoint(x: -room, y: down ? -room : view.bounds.height + room)
            mask.bounds = CGRect(x: 0, y: 0, width: view.bounds.width + room * 2, height: view.bounds.height + room * 2)
            layer.mask = mask
            let grow = CABasicAnimation(keyPath: "bounds.size.height")
            grow.fromValue = old.height + room
            grow.toValue = view.bounds.height + room * 2
            grow.duration = Self.foldDuration
            grow.timingFunction = timing
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak layer, weak mask] in
                if let layer, let mask, layer.mask === mask { layer.mask = nil }
            }
            mask.add(grow, forKey: "fold.reveal")
            CATransaction.commit()
        }
        if !statusView.isHidden { slide(statusView, from: start.status) }
    }

    /// As long as `FoldMotion` takes everywhere else.
    private static let foldDuration: CFTimeInterval = 0.26

    /// Scrolls where the transcript tools ask: find, /jump, the timeline, and vim keys.
    func perform(_ request: TranscriptScrollRequest) {
        switch request.target {
        case .bottom:
            setFollowing(true)
            relayout(anchor: .bottom)
        case .message(let id):
            guard indexByID[id] != nil else { return }
            setFollowing(false)
            relayout(anchor: .row(id, offset: 0))
        }
    }

    func toggleFollowing() {
        setFollowing(!isFollowing)
        if isFollowing { relayout(anchor: .bottom) }
    }

    /// A row's header was clicked.
    func setExpanded(_ id: UUID, _ open: Bool) {
        if let tools { tools.setExpanded(id, open); return }
        var next = display
        if open { next.expanded.insert(id) } else { next.expanded.remove(id) }
        apply(messages: messages, display: next)
    }

    /// A row takes another height without its message having changed: an image in it loaded.
    func rowResized(_ id: UUID) {
        guard let index = indexByID[id] else { return }
        states[index].stale = true
        relayout()
    }

    /// Whether two messages show the same thing. Streamed text only grows, so its length usually
    /// settles it without reading the text; text that is the same storage is not read either.
    private static func same(_ a: Message, _ b: Message) -> Bool {
        guard a.kind == b.kind, a.status == b.status, a.toolID == b.toolID, a.createdAt == b.createdAt,
              a.text.utf8.count == b.text.utf8.count, (a.detail?.utf8.count ?? -1) == (b.detail?.utf8.count ?? -1),
              (a.attachments?.count ?? -1) == (b.attachments?.count ?? -1) else { return false }
        guard a.text == b.text, a.detail == b.detail else { return false }
        if let left = a.attachments, let right = b.attachments {
            for index in left.indices where left[index].id != right[index].id { return false }
        }
        return true
    }

    private func model(at index: Int) -> TranscriptRowModel {
        let message = messages[index]
        let foldable = message.kind == .thought || message.kind == .tool
        let stamped = display.showTimestamps && (message.kind == .user || message.kind == .assistant)
        return TranscriptRowModel(message: message, isStreaming: message.id == display.streamingID, timestamp: stamped ? message.createdAt : nil,
                                  highlight: message.id == display.matchID ? .match : message.id == display.focusID ? .focus : .none,
                                  isExpanded: foldable && display.expanded.contains(message.id))
    }

    private func append(_ message: Message) {
        let index = messages.count
        messages.append(message)
        indexByID[message.id] = index
        let model = self.model(at: index)
        if let fixed = model.fixedHeight {
            heights.append(fixed)
            states.append(RowState(stale: false, fixed: true))
        } else {
            heights.append(ceil(model.estimatedHeight(width: columnWidth)))
            states.append(RowState())
        }
        topsDirty = true
    }

    private func removeRows(from index: Int) {
        guard index < messages.count else { return }
        for position in index..<messages.count {
            let id = messages[position].id
            indexByID[id] = nil
            if let view = realized.removeValue(forKey: id) { view.removeFromSuperview() }
        }
        messages.removeSubrange(index...)
        heights.removeSubrange(index...)
        states.removeSubrange(index...)
        topsDirty = true
    }

    private func invalidate(_ id: UUID?) {
        if let id, let index = indexByID[id] { invalidate(index) }
    }

    /// A row's message or look changed: its view shows it, and its height is measured again.
    private func invalidate(_ index: Int) {
        let model = self.model(at: index)
        if let fixed = model.fixedHeight {
            if heights[index] != fixed { heights[index] = fixed; topsDirty = true }
            states[index] = RowState(stale: false, fixed: true)
        } else {
            states[index].stale = true
            states[index].fixed = false
        }
        realized[model.message.id]?.configure(model)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
        guard let window else { return }
        // The title bar comes and goes with full screen and with the toolbar, without the list's size changing.
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        }
        relayout()
    }

    /// How much of the list's top is covered: the window's title bar and toolbar where the list
    /// runs under them, in a window or in full screen, and the find bar below that.
    private var topInset: CGFloat {
        var inset = coveredTop
        if let window {
            let frame = convert(bounds, to: nil)
            inset += max(0, frame.maxY - window.contentLayoutRect.maxY)
        }
        return inset.rounded()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        relayout()
    }

    private var distanceFromEnd: CGFloat { contentHeight - scrollView.contentView.bounds.maxY }

    /// Lays out the rows beyond what is in sight once the width has stopped changing.
    private func settleWidth() {
        widthSettled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.widthSettled = nil
            self.relayout()
        }
        widthSettled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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

    /// The first row in sight and how far above the top of the view it starts, as last placed.
    /// A row whose height is known is preferred to one that is still an estimate: scrolled into
    /// rows that were never laid out, the view holds on to a row the reader was already looking
    /// at, and the new rows take their real heights above it.
    private func positionAnchor(inset: CGFloat) -> Anchor {
        let count = min(tops.count, messages.count)
        guard count > 0 else { return .bottom }
        let bounds = scrollView.contentView.bounds
        let top = bounds.minY + inset
        let first = min(firstRow(endingAfter: top), count - 1)
        var index = first
        while index < count, tops[index] < bounds.maxY {
            let state = states[index]
            if state.fixed || (!state.stale && state.measuredWidth == columnWidth) { return .row(messages[index].id, offset: top - tops[index]) }
            index += 1
        }
        return .row(messages[first].id, offset: top - tops[first])
    }

    private func recomputeTops() {
        topsDirty = false
        let spacing = TranscriptMetrics.spacing(compact: display.compact)
        tops.removeAll(keepingCapacity: true)
        tops.reserveCapacity(heights.count)
        var y = TranscriptMetrics.topPadding
        for index in heights.indices {
            tops.append(y)
            y += heights[index] + spacing
        }
        if display.status != nil {
            statusTop = y
            y += statusView.height + spacing
        }
        // The content ends a point below its last row's spacing, as the SwiftUI transcript's end marker did.
        contentHeight = y + 1 + TranscriptMetrics.bottomPadding
    }

    private func origin(for anchor: Anchor, viewport: NSSize, inset: CGFloat) -> CGFloat {
        let least = -inset
        let most = max(least, contentHeight - viewport.height)
        switch anchor {
        case .bottom:
            return most.rounded()
        case .row(let id, let offset):
            guard let index = indexByID[id], index < tops.count else { return min(max(scrollView.contentView.bounds.minY, least), most).rounded() }
            return min(max(tops[index] + offset - inset, least), most).rounded()
        }
    }

    /// Gives a row its view and has the view say how tall the row is, unless that is known for
    /// this width. Returns whether the height changed.
    private func measure(_ index: Int) -> Bool {
        let id = messages[index].id
        let view: TranscriptRowView
        var created = false
        if let existing = realized[id] { view = existing } else {
            view = TranscriptRowView.make(model(at: index), list: self, in: document, width: columnWidth)
            realized[id] = view
            created = true
        }
        let state = states[index]
        guard !state.fixed, state.stale || state.measuredWidth != columnWidth || (created && state.unsettled) else { return false }
        let height = view.height(forWidth: columnWidth)
        states[index].measuredWidth = columnWidth
        states[index].stale = false
        states[index].unsettled = !view.isHeightSettled
        guard height != heights[index] else { return false }
        heights[index] = height
        topsDirty = true
        return true
    }

    /// Places the rows. `anchor` stays where it is; without one that is the end of the content
    /// while the output is followed, and the first row in sight otherwise. `scrolled` is the
    /// reader moving the view, which is then left where they put it unless a height changed.
    private func relayout(anchor requested: Anchor? = nil, scrolled: Bool = false) {
        guard !isLayingOut else { needsFollowUp = true; return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.size
        guard viewport.width >= TranscriptMetrics.narrowestViewport, viewport.height > 1 else { return }
        isLayingOut = true
        defer {
            isLayingOut = false
            if needsFollowUp {
                needsFollowUp = false
                DispatchQueue.main.async { [weak self] in self?.relayout() }
            }
        }

        let inset = topInset
        let anchor = requested ?? (isFollowing ? .bottom : positionAnchor(inset: lastInset))
        lastInset = inset
        if scrollView.contentInsets.top != inset { scrollView.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0) }
        let width = TranscriptMetrics.columnWidth(in: viewport.width)
        let resizing = inLiveResize || (width != columnWidth && columnWidth > 0)
        columnWidth = width
        if topsDirty || tops.count != heights.count { recomputeTops() }
        // Rows a little beyond what is in sight are ready before they scroll in. While the width
        // is changing (the window dragged to another size, on its way into full screen, a side
        // panel sliding in) only what is in sight is laid out, frame after frame; the rows beyond
        // follow once it has come to rest.
        let beyond = resizing ? 0 : min(600, viewport.height * 0.75)
        if resizing { settleWidth() }
        var origin = self.origin(for: anchor, viewport: viewport, inset: inset)
        var settled = false, moved = false
        // Laying a row out can change its height, which moves the rows after it and so which rows
        // are in sight. Each row is measured once for a width, so this ends; the limit is for the
        // frame it runs in.
        for _ in 0..<12 {
            var changed = false
            for index in rows(from: origin - beyond, to: origin + viewport.height + beyond) where measure(index) { changed = true }
            guard changed else { settled = true; break }
            moved = true
            recomputeTops()
            origin = self.origin(for: anchor, viewport: viewport, inset: inset)
        }
        if !settled { needsFollowUp = true }

        let size = NSSize(width: viewport.width, height: max(1, contentHeight))
        if document.frame.size != size { document.setFrameSize(size) }
        let x = ((viewport.width - columnWidth) / 2).rounded(.down)
        var shown = Set<UUID>()
        for index in rows(from: origin - beyond, to: origin + viewport.height + beyond) {
            let id = messages[index].id
            guard let view = realized[id] else { continue }
            shown.insert(id)
            let frame = NSRect(x: x, y: tops[index], width: columnWidth, height: heights[index])
            if view.frame != frame { view.frame = frame }
            view.arrange()
        }
        if shown.count != realized.count {
            for (id, view) in realized where !shown.contains(id) {
                view.removeFromSuperview()
                realized[id] = nil
            }
        }
        if display.status != nil {
            let frame = NSRect(x: x, y: statusTop, width: columnWidth, height: statusView.height)
            if statusView.frame != frame { statusView.frame = frame }
            if statusView.isHidden { statusView.isHidden = false }
        } else if !statusView.isHidden {
            statusView.isHidden = true
        }
        if !scrolled || moved, abs(clip.bounds.minY - origin) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
        }
        scrollView.reflectScrolledClipView(clip)
        lastOrigin = clip.bounds.minY
        lastViewport = clip.bounds.size
        report()
    }

    // MARK: - Scrolling

    @objc private func clipBoundsChanged(_ notification: Notification) {
        guard !isLayingOut else { return }
        let bounds = scrollView.contentView.bounds
        guard bounds.size == lastViewport else { relayout(); return }
        let old = lastOrigin
        lastOrigin = bounds.minY
        // Moving away from the end stops following; coming back to it follows again. Coming back
        // from past the end, as a scroll that bounced does, is neither.
        if bounds.minY < old - 0.5, distanceFromEnd > 0.5 { setFollowing(false) }
        else if bounds.minY > old + 0.5, distanceFromEnd <= TranscriptMetrics.followDistance { setFollowing(true) }
        for view in realized.values { view.forgetHover() }
        relayout(anchor: positionAnchor(inset: lastInset), scrolled: true)
    }

    private func wheel(_ event: NSEvent) {
        scrollEnd?.cancel()
        scrollEnd = nil
        let ended: NSEvent.Phase = [.ended, .cancelled]
        let name: String?
        if !event.momentumPhase.isDisjoint(with: [.began, .changed]) { name = "decelerating" }
        else if !event.phase.isDisjoint(with: [.began, .changed]) { name = "interacting" }
        else if event.phase.contains(.mayBegin) { name = "tracking" }
        else if !event.momentumPhase.isDisjoint(with: ended) { name = "idle"; scrollEnded() }
        else if !event.phase.isDisjoint(with: ended) {
            name = "idle"
            // A flick carries on by itself: the scroll has ended only if nothing follows.
            let work = DispatchWorkItem { [weak self] in self?.scrollEnded() }
            scrollEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else { name = nil }
        if let name { record(phase: name) }
    }

    @objc private func liveScrollStarted(_ notification: Notification) { record(phase: "interacting") }

    @objc private func liveScrollEnded(_ notification: Notification) {
        record(phase: "idle")
        scrollEnded()
    }

    private func record(phase name: String) {
        guard name != phase else { return }
        phase = name
        tools?.recordScrollPhase(name)
    }

    /// The reader's scroll came to rest: near the end, the output is followed again.
    private func scrollEnded() {
        scrollEnd?.cancel()
        scrollEnd = nil
        let wasFollowing = isFollowing
        setFollowing(distanceFromEnd <= TranscriptMetrics.followDistance)
        if isFollowing, !wasFollowing || distanceFromEnd > 0.5 { relayout(anchor: .bottom) }
    }

    private func setFollowing(_ following: Bool) {
        guard following != isFollowing else { return }
        isFollowing = following
        tools?.recordFollowing(following, messageCount: messages.count)
        pending.following = following
        scheduleReports()
    }

    // MARK: - What the tools hear

    private func report() {
        let bounds = scrollView.contentView.bounds
        let sample = TranscriptScrollSample(offsetY: bounds.minY, contentHeight: contentHeight, viewportHeight: bounds.height)
        if sample != lastSample {
            lastSample = sample
            tools?.recordScroll(sample)
        }
        // The first row with a sliver in sight under the title bar: a fiftieth of it, a point at least.
        let top = bounds.minY + lastInset, bottom = bounds.maxY
        var visible: Int?
        var index = firstRow(endingAfter: top)
        while index < min(tops.count, heights.count), tops[index] < bottom {
            let inSight = min(bottom, tops[index] + heights[index]) - max(top, tops[index])
            if inSight >= max(1, heights[index] * 0.02) { visible = index; break }
            index += 1
        }
        if lastVisible != .some(visible) {
            lastVisible = .some(visible)
            pending.visible = (visible, visible.map { messages[$0].id })
            scheduleReports()
        }
    }

    private func scheduleReports() {
        guard !pending.scheduled else { return }
        pending.scheduled = true
        DispatchQueue.main.async { [weak self] in self?.sendReports() }
    }

    private func sendReports() {
        let reports = pending
        pending = Reports()
        if reports.conversationChanged { tools?.conversationDidChange() }
        if reports.transcriptChanged { tools?.transcriptDidChange() }
        if let visible = reports.visible { tools?.visibleMessagesChanged(topIndex: visible.index, topID: visible.id) }
        if let following = reports.following, let follow, follow.isFollowing != following { follow.isFollowing = following }
    }

    // MARK: - For tests

    /// How many rows have views.
    var realizedRowCount: Int { realized.count }
    var rowCount: Int { messages.count }
    /// The height of all the rows, as far as they are known.
    var documentHeight: CGFloat { contentHeight }
    /// A row's view, when it is in sight.
    func rowView(for id: UUID) -> TranscriptRowView? { realized[id] }
    /// Where a row is in the content, as last placed.
    func rowFrame(for id: UUID) -> NSRect? {
        guard let index = indexByID[id], index < tops.count else { return nil }
        return NSRect(x: 0, y: tops[index], width: columnWidth, height: heights[index])
    }
    /// The first row with something in sight, as the transcript tools hear it.
    var topVisibleRow: Int? { lastVisible ?? nil }
    /// How many rows have been laid out for the current width, or need no laying out.
    var measuredRowCount: Int { states.reduce(0) { $0 + ($1.fixed || (!$1.stale && $1.measuredWidth == columnWidth) ? 1 : 0) } }
}

/// The transcript's scroll view. Its scrolling runs on the main thread with the events that
/// drive it, so a row is laid out before the frame that shows it.
final class TranscriptScrollView: NSScrollView {
    /// A scroll event, after the view has moved for it.
    var onWheel: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onWheel?(event)
    }
}

/// Holds the rows; its origin is its top.
final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The AppKit transcript in SwiftUI. It takes the room it is given and reads the messages from
/// the store when it is updated, so SwiftUI neither measures the rows nor keeps a copy of them.
struct TranscriptList: NSViewRepresentable {
    let store: AppStore
    let tools: TranscriptToolsModel
    let follow: TranscriptFollowState
    var display: TranscriptDisplay
    /// These change with the transcript, so the view is updated when it does.
    var revision: Int
    var count: Int
    var scrollRequest: TranscriptScrollRequest?
    /// How much of the list's top the find bar covers, below the window's title bar.
    var coveredTop: CGFloat = 0

    final class Coordinator {
        var handledScroll: Int?
        /// The transcript the list was last given: whose, and at which revision.
        var shown: (conversation: UUID?, revision: Int)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptListView {
        let view = TranscriptListView()
        view.tools = tools
        view.follow = follow
        // A scroll asked for before this view existed was not asked of it.
        context.coordinator.handledScroll = scrollRequest?.serial
        return view
    }

    func updateNSView(_ view: TranscriptListView, context: Context) {
        view.tools = tools
        view.follow = follow
        view.openImage = store.openImageAction
        view.coveredTop = coveredTop
        // What the store knows to be unchanged since the list last looked is not compared again.
        let shown = context.coordinator.shown
        let unchanged = shown.flatMap { $0.conversation == display.conversation ? store.transcriptFirstChange(of: display.conversation, since: $0.revision) : nil }
        context.coordinator.shown = (display.conversation, store.transcriptRevision(of: display.conversation))
        view.apply(messages: store.conversation?.messages ?? [], display: display, unchangedBefore: unchanged)
        if let request = scrollRequest, request.serial != context.coordinator.handledScroll {
            context.coordinator.handledScroll = request.serial
            view.perform(request)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptListView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
        return CGSize(width: size.width.isFinite ? size.width : 320, height: size.height.isFinite ? size.height : 240)
    }
}
