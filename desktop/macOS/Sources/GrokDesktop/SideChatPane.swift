import AppKit
import SwiftUI

/// A task's side chat in AppKit: what it is about, its messages (`SideChatListView`), and the
/// field to ask in. SwiftUI gives it the room it has and the side chat's state (see
/// `SideChatView`); nothing in it is sized by SwiftUI.
@MainActor
final class SideChatPaneView: NSView {
    private static let headerHeight: CGFloat = 36

    private let model: SideChatModel
    private let title = NSTextField(labelWithString: "")
    let clearButton = SideChatButton(style: .icon("trash", size: 24), help: "Clear this side chat")
    let list = SideChatListView()
    let composer = SideChatComposerView()
    private(set) var conversationID: UUID?
    private var messages: [SideChatMessage] = []
    private var isPending = false
    private var shownFocusRequest: Int?

    init(model: SideChatModel) {
        self.model = model
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = Theme.palette.mutedNS
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        clearButton.action = { [weak self] in
            guard let self, let id = self.conversationID else { return }
            self.model.clear(id)
            self.showModel()
        }
        list.onRetry = { [weak self] failure in
            guard let self, let id = self.conversationID else { return }
            self.model.retry(failure, in: id)
            self.showModel()
        }
        composer.onSend = { [weak self] in self?.send() }
        composer.onHeightChange = { [weak self] in self?.needsLayout = true }
        for view in [title, clearButton, list, composer] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows a task's side chat as it is now. Called whenever SwiftUI updates the tab; showing what
    /// is already shown does nothing.
    func show(conversationID id: UUID, title taskTitle: String, messages: [SideChatMessage], isPending: Bool, focusRequest: Int) {
        if id != conversationID {
            keepDraft()
            conversationID = id
            self.messages = []
            list.reset()
            composer.setText(model.drafts[id] ?? "")
        }
        let label = "About \u{201C}\(taskTitle)\u{201D}"
        if title.stringValue != label {
            title.stringValue = label
            title.toolTip = label
        }
        apply(messages, isPending: isPending)
        if let shown = shownFocusRequest, shown != focusRequest { composer.focus() }
        shownFocusRequest = focusRequest
    }

    /// Keeps what is typed as the task's draft, for when its side chat shows again.
    func keepDraft() {
        guard let id = conversationID else { return }
        let text = composer.question
        model.drafts[id] = text.isEmpty ? nil : text
    }

    private func apply(_ messages: [SideChatMessage], isPending: Bool) {
        // A question that was not there before was just asked, here or with /btw: the end comes into sight.
        let asked = messages.last?.role == .question && messages.last?.id != self.messages.last?.id
        self.messages = messages
        self.isPending = isPending
        composer.isPending = isPending
        if clearButton.isHidden != messages.isEmpty {
            clearButton.isHidden = messages.isEmpty
            needsLayout = true
        }
        clearButton.isEnabled = !isPending
        list.show(messages, isPending: isPending, scrollsToEnd: asked)
    }

    /// Shows what the model has now, without waiting for SwiftUI to pass it on.
    private func showModel() {
        guard let id = conversationID else { return }
        apply(model.thread(id), isPending: model.pending.contains(id))
    }

    private func send() {
        guard let id = conversationID, !isPending, composer.hasQuestion, model.ask(composer.question, in: id) else { return }
        composer.setText("")
        showModel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // As the tab opens, its field takes the keyboard.
        DispatchQueue.main.async { [weak self] in self?.composer.focus() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    override func layout() {
        super.layout()
        arrange()
    }

    private func arrange() {
        let width = bounds.width, height = bounds.height
        // 14 pt at the sides of the header, 6 pt above and below the Clear button.
        clearButton.frame = NSRect(x: width - 14 - 24, y: 6, width: 24, height: 24)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let titleEnd = clearButton.isHidden ? width - 14 : clearButton.frame.minX - 10
        title.frame = NSRect(x: 14, y: ((Self.headerHeight - titleHeight) / 2).rounded(), width: max(0, titleEnd - 14), height: titleHeight)
        // The field has 10 pt around it.
        let fieldWidth = max(1, width - 20)
        let fieldHeight = composer.preferredHeight(forWidth: fieldWidth)
        let field = NSRect(x: 10, y: height - 10 - fieldHeight, width: fieldWidth, height: fieldHeight)
        if composer.frame != field { composer.frame = field }
        let listFrame = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, field.minY - 10 - Self.headerHeight))
        if list.frame != listFrame { list.frame = listFrame }
    }
}

/// The field a side question is typed in, on the app's glass. It grows with its text to six lines,
/// then scrolls. Return asks; ⇧↵, ⌥↵, and ⌃J start a new line (see `SubmitTextView`), and an input
/// method's Return still commits what it composed.
@MainActor
final class SideChatComposerView: NSView, NSTextViewDelegate {
    static let maxLines = 6
    private static let font = NSFont.systemFont(ofSize: SideChatMetrics.fontSize)
    private static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
    /// The text's distance from the card's leading edge, the send button's from its trailing edge,
    /// and both from its top and bottom; the gap between them; and the button's size.
    private static let leading: CGFloat = 12, trailing: CGFloat = 6, vertical: CGFloat = 5, gap: CGFloat = 8, button: CGFloat = 26
    /// Space above and below the text, inside what scrolls.
    private static let textInset: CGFloat = 5
    /// Past this many characters the text is taller than six lines at any width the field can have:
    /// a long paste is not laid out to find that out.
    private static let measuredLength = 4_000

    let textView: SubmitTextView
    private let scroll = NSScrollView()
    private let glass = SideChatGlassView(cornerRadius: 18)
    let sendButton = SideChatButton(style: .send, help: "Ask · ↵")
    /// Its own, so that replacing the text cannot leave undo steps behind for text that is gone.
    private let undo = UndoManager()
    /// Return, or the send button.
    var onSend: (() -> Void)?
    /// The field wants another height.
    var onHeightChange: (() -> Void)?
    /// While a question is answered, another waits.
    var isPending = false { didSet { if isPending != oldValue { refreshSendButton() } } }
    private var wantedHeight: CGFloat?

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // A long paste is laid out only as far as it is seen.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = SubmitTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        textView.followsComposerFocus = false
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Self.font
        textView.textColor = Theme.palette.inkNS
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Self.textInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.placeholder = "Ask a side question…"
        textView.setAccessibilityLabel("Side question")
        textView.onSubmit = { [weak self] in self?.onSend?() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = textView
        sendButton.setAccessibilityLabel("Ask side question")
        sendButton.action = { [weak self] in self?.onSend?() }
        addSubview(glass)
        addSubview(scroll)
        addSubview(sendButton)
        refreshSendButton()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// What is typed, less what an input method is still composing.
    var question: String { textView.committedString }

    /// Whether what is typed is more than space.
    var hasQuestion: Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        return storage.mutableString.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location != NSNotFound
    }

    /// Replaces what is typed: another task's draft, or nothing once a question is asked.
    func setText(_ text: String) {
        if textView.hasMarkedText() { textView.unmarkText() }
        textView.string = text
        undo.removeAllActions()
        refreshSendButton()
        refreshHeight()
    }

    func focus() {
        guard let window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
    }

    /// How tall the field is at `width`: its text's height, from one line to six.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        max(textHeight(forWidth: textWidth(for: width)), Self.button) + Self.vertical * 2
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - Self.leading - Self.gap - Self.button - Self.trailing)
    }

    /// The text's height in the field, with its insets: one line at least, six at most.
    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        let least = Self.lineHeight + Self.textInset * 2
        let most = Self.lineHeight * CGFloat(Self.maxLines) + Self.textInset * 2
        guard let storage = textView.textStorage, storage.length > 0 else { return least }
        guard storage.length <= Self.measuredLength else { return most }
        // Measured in the layout that shows the text, at the width it will be shown at.
        if scroll.frame.width != width { scroll.setFrameSize(NSSize(width: width, height: max(scroll.frame.height, 1))) }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer, container.containerSize.width > 1 else { return least }
        layoutManager.ensureLayout(for: container)
        let used = ceil(layoutManager.usedRect(for: container).height) + Self.textInset * 2
        return min(most, max(least, used))
    }

    private func refreshHeight() {
        let height = preferredHeight(forWidth: bounds.width > 1 ? bounds.width : 320)
        guard height != wantedHeight else { return }
        wantedHeight = height
        onHeightChange?()
    }

    private func refreshSendButton() {
        sendButton.isEnabled = !isPending && hasQuestion
    }

    func textDidChange(_ notification: Notification) {
        refreshSendButton()
        refreshHeight()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func arrange() {
        glass.frame = bounds
        scroll.frame = NSRect(x: Self.leading, y: Self.vertical, width: textWidth(for: bounds.width), height: max(1, bounds.height - Self.vertical * 2))
        // The text view fills what is in sight, so a click under a short question still edits it.
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        if textView.frame.height < scroll.contentSize.height { textView.setFrameSize(NSSize(width: textView.frame.width, height: scroll.contentSize.height)) }
        sendButton.frame = NSRect(x: bounds.width - Self.trailing - Self.button, y: bounds.height - Self.vertical - Self.button, width: Self.button, height: Self.button)
    }

    /// A click in the card's margin edits the question too.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}

/// The app's glass behind the side chat's field: the surface the prompt sits on (see
/// `glassSurface`), drawn at the size AppKit gives it. Clicks go to what is over it.
@MainActor
final class SideChatGlassView: NSView {
    private let host: NSHostingView<SideChatGlass>

    init(cornerRadius: CGFloat) {
        host = NSHostingView(rootView: SideChatGlass(cornerRadius: cornerRadius))
        host.sizingOptions = []
        host.safeAreaRegions = []
        super.init(frame: .zero)
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        host.frame = bounds
    }
}

private struct SideChatGlass: View {
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear.glassSurface(cornerRadius: cornerRadius)
    }
}

/// A button the side chat draws itself: an icon with a fill under the pointer (as `IconButton`),
/// the round send button, or a quiet titled button (as `SubtleButtonStyle`).
@MainActor
final class SideChatButton: NSView {
    enum Style {
        case icon(String, size: CGFloat)
        case send
        case titled(String)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    let style: Style
    var action: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            setAccessibilityEnabled(isEnabled)
            showState()
        }
    }
    private let symbol = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    init(style: Style, help: String) {
        self.style = style
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(help)
        switch style {
        case .icon(let name, let size): symbol.image = TranscriptParts.symbol(name, size: (size * 0.47).rounded(), weight: .medium)
        case .send: symbol.image = TranscriptParts.symbol("arrow.up", size: 12, weight: .semibold)
        case .titled: break
        }
        if symbol.image != nil {
            symbol.imageScaling = .scaleNone
            addSubview(symbol)
        }
        showState()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .icon(_, let size): return NSSize(width: size, height: size)
        case .send: return NSSize(width: 26, height: 26)
        case .titled(let title):
            let size = (title as NSString).size(withAttributes: [.font: Self.titleFont])
            return NSSize(width: ceil(size.width) + 26, height: ceil(size.height) + 16)
        }
    }

    private func showState() {
        switch style {
        case .icon:
            symbol.contentTintColor = Theme.palette.mutedNS
            symbol.alphaValue = isEnabled ? 1 : 0.4
        case .send:
            symbol.contentTintColor = Theme.palette.canvasNS
        case .titled:
            alphaValue = isEnabled ? 1 : 0.45
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        symbol.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .icon(_, let size):
            guard isEnabled, isHovered || isPressed else { return }
            Theme.palette.hoverNS.fading(0.8).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: size / 4, yRadius: size / 4).fill()
        case .send:
            (isEnabled ? Theme.palette.inkNS : Theme.palette.mutedNS.fading(0.35)).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        case .titled(let title):
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
            (isEnabled && (isHovered || isPressed) ? Theme.palette.hoverNS : Theme.palette.surfaceNS).setFill()
            shape.fill()
            Theme.palette.lineNS.setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: Theme.palette.inkNS]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()), withAttributes: attributes)
        }
    }

    // The symbol is part of the button. AppKit gives the point in the superview's coordinates, as the frame is.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = isEnabled }
    override func mouseDragged(with event: NSEvent) { isPressed = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside && isEnabled { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}
