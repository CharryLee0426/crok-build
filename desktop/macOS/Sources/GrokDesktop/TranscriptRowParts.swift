import AppKit
import SwiftUI

// The pieces the transcript's AppKit rows are built from (see `TranscriptListView`).

/// Sizes the rows and the list share.
enum TranscriptMetrics {
    /// The column of rows is this wide at most, in the middle of the transcript.
    static let maxColumnWidth: CGFloat = 800
    static let horizontalPadding: CGFloat = 36
    static let topPadding: CGFloat = 34
    static let bottomPadding: CGFloat = 15
    /// Following stops this far from the end, and resumes within it.
    static let followDistance: CGFloat = 40
    /// Narrower than this the transcript is on its way to its real width, and waits for it.
    static let narrowestViewport: CGFloat = 120

    static func spacing(compact: Bool) -> CGFloat { compact ? 10 : 23 }

    static func columnWidth(in viewport: CGFloat) -> CGFloat {
        max(1, min(maxColumnWidth, viewport - horizontalPadding * 2))
    }
}

/// The folded reasoning block's glimpse of its newest lines while it streams.
enum ThoughtPreview {
    static let lines = 4
    /// Four lines of the 14 pt reasoning text (see `ReadOnlyTextView.Style.markdown`): each line
    /// with its 3 pt line spacing, the paragraph gaps between them (reasoning is mostly short
    /// paragraphs), and the text view's insets.
    static let height: CGFloat = {
        let font = NSFont.systemFont(ofSize: 14)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 3
        let paragraphGap = (font.pointSize * 0.6).rounded()
        return CGFloat(lines) * line + CGFloat(lines - 1) * paragraphGap + 4
    }()
}

@MainActor
enum TranscriptParts {
    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> TranscriptTextLabel {
        let label = TranscriptTextLabel()
        label.font = .systemFont(ofSize: size, weight: weight)
        label.color = color
        label.text = text
        return label
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    static func symbolView(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.image = symbol(name, size: size, weight: weight)
        view.contentTintColor = color
        return view
    }

    /// "3:07 PM" beside a prompt or a reply, with the terminal's "15:07:12 | Sep 23" on hover.
    static func timestamp(_ date: Date, into existing: TranscriptTextLabel?) -> TranscriptTextLabel {
        let label = existing ?? {
            let label = TranscriptTextLabel()
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.color = Theme.palette.mutedNS
            return label
        }()
        let text = TranscriptTimestamp.label(date)
        label.text = text
        label.toolTip = TranscriptTimestamp.tooltip(date)
        label.setAccessibilityLabel("Sent at \(text)")
        return label
    }

    /// A tool call's title: inline Markdown, e.g. ``Read `path` ``, whose code spans show as code.
    static func toolTitle(_ text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14)
        guard text.contains("`") || text.contains("*") else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Theme.palette.inkNS])
        }
        let rendered = MarkdownAttributedRenderer(fontSize: 14, color: Theme.palette.inkNS).render([.paragraph(MarkdownParser.parseInlines(text))])
        let title = NSMutableAttributedString()
        let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
            var attributes = attributes
            // The label wraps and truncates by its own rules, and is one button.
            attributes[.paragraphStyle] = nil
            attributes[.link] = nil
            let piece = rendered.attributedSubstring(from: range).string
            if attributes[.backgroundColor] != nil {
                // Code spans: a thin space of the code's background on either side, as padding.
                attributes[.font] = code
                title.append(NSAttributedString(string: "\u{2009}" + piece + "\u{2009}", attributes: attributes))
            } else {
                title.append(NSAttributedString(string: piece, attributes: attributes))
            }
        }
        return title
    }
}

/// A line or two of text that is not for selecting: a name, a status, a time, a title. It is
/// drawn as it is measured, with no margins of its own, and it truncates where it runs out of room.
final class TranscriptTextLabel: NSView {
    var font = NSFont.systemFont(ofSize: 13) { didSet { if font != oldValue { rebuild() } } }
    var color = NSColor.labelColor { didSet { if color != oldValue { rebuild() } } }
    var text = "" { didSet { if text != oldValue { rebuild() } } }
    /// Text with its own fonts and colours, in place of `text`.
    var attributedText: NSAttributedString? { didSet { rebuild() } }
    var maximumLines = 1

    private var shown = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func rebuild() {
        shown = attributedText ?? NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        setAccessibilityValue(shown.string)
        needsDisplay = true
    }

    /// The size the text takes in lines no longer than `width`, up to `maximumLines` of them.
    func size(fitting width: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        guard shown.length > 0 else { return NSSize(width: 0, height: ceil(NSLayoutManager().defaultLineHeight(for: font))) }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let line = shown.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: options)
        guard line.width > width else { return NSSize(width: ceil(line.width), height: ceil(line.height)) }
        guard maximumLines > 1 else { return NSSize(width: max(0, width), height: ceil(line.height)) }
        let wrapped = shown.boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: options)
        return NSSize(width: max(0, width), height: min(ceil(wrapped.height), ceil(line.height) * CGFloat(maximumLines)))
    }

    override func draw(_ dirtyRect: NSRect) {
        shown.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }
}

/// A rounded fill behind a row's content, with an optional hairline just inside its edge.
final class TranscriptFillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat

    init(color: NSColor, radius: CGFloat) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let stroke else { return }
        stroke.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// How a row is marked: the current find match gets an accent outline; the vim cursor a tint
/// and an accent bar. It reaches 9 pt past the row on every side.
final class TranscriptHighlightView: NSView {
    static let reach: CGFloat = 9
    var highlight: TranscriptRowHighlight = .none { didSet { if highlight != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Theme.palette.accentNS
        switch highlight {
        case .none: break
        case .match:
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 14, yRadius: 14)
            accent.fading(0.07).setFill()
            shape.fill()
            accent.fading(0.7).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        case .focus:
            Theme.palette.hoverNS.fading(0.6).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 8, width: 3, height: max(0, bounds.height - 16)), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The Crok mark beside a reply's name.
final class TranscriptMarkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Crok")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = min(bounds.width, bounds.height)
        Theme.palette.inkNS.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: size * 0.29, yRadius: size * 0.29).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inner = size * 0.76
        let rect = CGRect(x: (bounds.width - inner) / 2, y: (bounds.height - inner) / 2, width: inner, height: inner)
        context.addPath(GrokSymbol().path(in: rect).cgPath)
        context.setFillColor(Theme.palette.canvasNS.cgColor)
        context.fillPath()
    }
}

/// "Thinking" with its sparkle: muted, or in the thinking colours while the reasoning streams, when
/// the sparkle also turns. The text's gradient is still, as a moving one would redraw every frame;
/// the sparkle turns in Core Animation (see `ThinkingEffects`).
final class TranscriptThinkingTitle: NSView {
    var isStreaming = false {
        didSet {
            guard isStreaming != oldValue else { return }
            needsDisplay = true
            showSparkle()
        }
    }

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let sparkleImage = TranscriptParts.symbol("sparkle", size: 13)
    private let sparkle = TranscriptThinkingTitle.sparkleImage.map(TurningSymbolView.init(image:))
    private var text: String { isStreaming ? "Thinking…" : "Thinking" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if let sparkle { addSubview(sparkle) }
        showSparkle()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var contentSize: NSSize {
        let textSize = (text as NSString).size(withAttributes: [.font: Self.font])
        let image = Self.sparkleImage?.size ?? .zero
        return NSSize(width: ceil(image.width + 8 + textSize.width) + 1, height: ceil(max(image.height, textSize.height)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let sparkle, let image = Self.sparkleImage else { return }
        sparkle.frame = NSRect(x: 0, y: ((newSize.height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
    }

    private func showSparkle() {
        sparkle?.colors = isStreaming ? ThinkingPalette.nsColors : [Theme.palette.mutedNS]
        sparkle?.turns = isStreaming
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = Self.sparkleImage.map { $0.size.width + 8 } ?? 0
        let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: ceil(size.width), height: ceil(size.height))
        tinted(rect, in: context) { (text as NSString).draw(at: rect.origin, withAttributes: attributes) }
    }

    /// Draws a shape, then gives it its colour: the thinking colours across it while streaming, as
    /// the SwiftUI title had, and the muted colour otherwise.
    private func tinted(_ rect: NSRect, in context: CGContext, shape: () -> Void) {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        shape()
        context.setBlendMode(.sourceIn)
        if isStreaming, let gradient = NSGradient(colors: ThinkingPalette.nsColors) {
            gradient.draw(in: rect, angle: 0)
        } else {
            context.setFillColor(Theme.palette.mutedNS.cgColor)
            context.fill(rect)
        }
        context.endTransparencyLayer()
        context.setBlendMode(.normal)
    }
}

/// The header of a reasoning or tool block: the whole of it is the click target that opens and
/// closes the block. The row puts its own title inside, right of the chevron.
final class TranscriptFoldHeader: NSView {
    static let minHeight: CGFloat = 44
    /// Where a header's own content starts and ends.
    static let contentLeading: CGFloat = 42
    static let contentTrailing: CGFloat = 12

    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            showChevron()
        }
    }
    var onToggle: (() -> Void)?

    private let fill = TranscriptFillView(color: .clear, radius: 9)
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { showFill() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { showFill() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.isHidden = true
        addSubview(fill)
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = Theme.palette.mutedNS
        addSubview(chevron)
        showChevron()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func showChevron() {
        chevron.image = TranscriptParts.symbol(isOpen ? "chevron.down" : "chevron.right", size: 12, weight: .semibold)
        setAccessibilityValue(isOpen ? "Expanded" : "Collapsed")
        setAccessibilityHelp(isOpen ? "Collapse" : "Expand")
    }

    private func showFill() {
        let strength: CGFloat = isPressed ? 0.9 : isHovered ? 0.55 : 0
        fill.isHidden = strength == 0
        if strength > 0 { fill.color = Theme.palette.hoverNS.fading(strength) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fill.frame = bounds
        chevron.frame = NSRect(x: 12, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20)
    }

    /// The pointer is no longer known to be over the header: the transcript scrolled under it.
    func forgetHover() { isHovered = false; isPressed = false }

    // The title inside is part of the button. AppKit gives the point in the superview's coordinates, as the frame is.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseMoved(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseDragged(with event: NSEvent) { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}

/// A `ReadOnlyTextView` for AppKit: the same TextKit text view and coordinator, sized by the row
/// that owns it instead of by SwiftUI.
@MainActor
final class TranscriptTextBox: NSView {
    private let coordinator = ReadOnlyTextView.Coordinator()
    private let scroll: PassthroughScrollView
    let style: ReadOnlyTextView.Style
    /// The box grows with its text up to this height, then scrolls; infinite never scrolls.
    let maxHeight: CGFloat
    /// The text takes another height without having changed, as when an image in it has loaded.
    var onContentResized: (() -> Void)?

    /// `width` is the width the box will be placed at, when its owner knows: text given to a box
    /// that has its width is laid out once, at that width, and not first as wide as it would run.
    init(style: ReadOnlyTextView.Style, wrapsLines: Bool = true, maxHeight: CGFloat, showsScroller: Bool = true, width: CGFloat = 0) {
        self.style = style
        self.maxHeight = maxHeight
        scroll = ReadOnlyTextView.makeScrollView(style: style, wrapsLines: wrapsLines, showsScroller: showsScroller && maxHeight.isFinite, coordinator: coordinator)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(scroll)
        if width > 1 { setFrameSize(NSSize(width: min(width, 4_000), height: 1)) }
        coordinator.contentResized = { [weak self] in self?.onContentResized?() }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var textView: NSTextView? { coordinator.textView }

    /// Fades the box's top edge out, as for a glimpse of text whose lines scroll up out of it.
    var fadesTop = false {
        didSet {
            guard fadesTop != oldValue else { return }
            needsLayout = true
            showFade()
        }
    }
    private var fade: CAGradientLayer?
    /// How far down from the top the fade runs.
    private static let fadeHeight: CGFloat = 14

    override func layout() {
        super.layout()
        showFade()
    }

    private func showFade() {
        guard let layer else { return }
        guard fadesTop, bounds.height > 1 else {
            if let fade, layer.mask === fade { layer.mask = nil }
            return
        }
        let fade = self.fade ?? {
            let fade = CAGradientLayer()
            fade.colors = [NSColor.black.withAlphaComponent(0.15).cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            self.fade = fade
            return fade
        }()
        // In a window this view is flipped, and a gradient masking its layer runs down from the
        // view's top: that is what the window server draws (checked in pictures it took of the
        // list). The layer's own flags say otherwise until it has been displayed, and a picture
        // taken with `cacheDisplay` draws the mask the other way up, with the fade at the bottom.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(origin: .zero, size: bounds.size)
        fade.locations = [0, NSNumber(value: Double(min(1, Self.fadeHeight / bounds.height))), 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        if layer.mask !== fade { layer.mask = fade }
        CATransaction.commit()
    }
    /// The text will take another height once an image in it has loaded.
    var awaitsImage: Bool { coordinator.awaitsImage }

    func update(text: String, followsTail: Bool = false, isStreaming: Bool = false) {
        coordinator.update(text: text, style: style, followsTail: followsTail, measuresAll: !maxHeight.isFinite, isStreaming: isStreaming)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        let width = min(width, 4_000)
        // Text that shows whole is laid out once, in the view that shows it. Capped text is measured
        // apart, and only as far as its cap needs.
        if !maxHeight.isFinite, let height = coordinator.shownHeight(forWidth: width) { return height }
        return coordinator.height(forWidth: width, cap: maxHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if scroll.frame.size != newSize { scroll.frame = NSRect(origin: .zero, size: newSize) }
    }
}

/// Selectable text that is as large as what it says, for prompts and the app's own lines.
final class TranscriptSelectableText: NSTextView {
    static func make() -> TranscriptSelectableText {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        let view = TranscriptSelectableText(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        return view
    }

    private var shown = ""

    func show(_ text: String, font: NSFont, color: NSColor) {
        guard text != shown || textStorage?.length == 0 else { return }
        shown = text
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    /// The size the text takes when its lines may be `width` long.
    func fit(width: CGFloat) -> NSSize {
        guard let container = textContainer, let layoutManager else { return .zero }
        let size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        if container.size != size { container.size = size }
        layoutManager.ensureLayout(for: container)
        // Line by line: in a window the container's used rectangle is as wide as the container.
        var used = NSSize.zero
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { line, text, _, _, _ in
            used.width = max(used.width, text.maxX)
            used.height = max(used.height, line.maxY)
        }
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0 { used.height = max(used.height, extra.maxY) }
        return NSSize(width: min(ceil(used.width), max(1, width)), height: ceil(used.height))
    }
}

/// A SwiftUI leaf inside an AppKit row, at the size the row gives it: the images a tool returned
/// or a reply carried, and what a prompt was sent with. Its layout is its own and ends at its edge.
@MainActor
final class TranscriptHostedView: NSView {
    private let controller: NSHostingController<AnyView>

    init<Content: View>(_ content: Content) {
        controller = NSHostingController(rootView: AnyView(content))
        controller.sizingOptions = []
        super.init(frame: .zero)
        // Under the window's title bar the content must not make room for it.
        (controller.view as? NSHostingView<AnyView>)?.safeAreaRegions = []
        addSubview(controller.view)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show<Content: View>(_ content: Content) { controller.rootView = AnyView(content) }

    func size(fitting width: CGFloat) -> NSSize {
        let size = controller.sizeThatFits(in: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        return NSSize(width: min(ceil(size.width), max(1, width)), height: ceil(size.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if controller.view.frame.size != newSize { controller.view.frame = NSRect(origin: .zero, size: newSize) }
    }
}

/// The line under the rows while a turn runs: a spinner and what the turn is doing.
final class TranscriptStatusView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = TranscriptParts.label(size: 14, color: Theme.palette.mutedNS)

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            arrange()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = true
        spinner.sizeToFit()
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The spinner's and the text's height, with 5 pt above and below.
    var height: CGFloat { ceil(max(spinner.frame.height, label.size().height)) + 10 }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func arrange() {
        let size = label.size()
        spinner.setFrameOrigin(NSPoint(x: 0, y: ((bounds.height - spinner.frame.height) / 2).rounded()))
        label.frame = NSRect(x: spinner.frame.width + 9, y: ((bounds.height - size.height) / 2).rounded(),
                             width: min(size.width, max(0, bounds.width - spinner.frame.width - 9)), height: size.height)
    }
}
