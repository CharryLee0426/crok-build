import SwiftUI
import AppKit

/// Selectable, read-only text for long or streaming content: replies, reasoning, tool output, and diffs.
///
/// SwiftUI `Text` lays out its whole string again on every change and draws it as one
/// layer, so a long reasoning stream stalls the main thread, and resizing it (expanding or
/// collapsing it) can bring the app down. This view uses TextKit 1 with a height cap: streamed
/// suffixes are appended, only new text is laid out, and only the visible region is drawn.
struct ReadOnlyTextView: NSViewRepresentable {
    enum Style: Equatable {
        /// Secondary 14 pt text, as for reasoning.
        case prose
        /// Primary 16 pt text, as for prompts.
        case body
        case monospaced
        /// Monospaced unified diff with coloured additions, removals, and hunk headers.
        case diff
        /// Secondary 14 pt Markdown with tables, code, and math, as for reasoning.
        case markdown
        /// Markdown for replies in the style's size: code, callouts, and tables are cards, and
        /// each code card has a Copy button.
        case reply(MarkdownStyle)
        /// Monospaced code, syntax-highlighted when a language is given.
        case code(language: String?)
    }
    enum Sizing: Equatable {
        /// Grow with the content up to a cap, then scroll internally. An infinite cap never
        /// scrolls, and measures all of the text rather than a prefix.
        case fitContent(maxHeight: CGFloat)
        /// Take the space offered by the parent.
        case fill

        var isUncapped: Bool { if case .fitContent(let maxHeight) = self { return !maxHeight.isFinite }; return false }
    }

    var text: String
    var style: Style = .prose
    var wrapsLines = true
    var sizing: Sizing = .fitContent(maxHeight: 320)
    /// Keep the newest text in view as it streams, until the reader scrolls away from the end.
    var followsTail = false
    /// A capped view scrolls internally; this hides its scroller, as for a glimpse of streaming text.
    var showsScroller = true
    /// Bumped when the content resizes without new text (an image loaded), so SwiftUI measures again.
    @State private var sizeRevision = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = style == .diff ? DiffLayoutManager() : NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = MinimumWidthTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Diff lines are inset inside their full-width background.
        container.lineFragmentPadding = style == .diff ? 12 : 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownSourceTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.linkTextAttributes = [.foregroundColor: Theme.accentNS, .cursor: NSCursor.pointingHand]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true

        let scroll = PassthroughScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = showsScroller && !sizing.isUncapped
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        context.coordinator.attach(scroll: scroll, textView: textView)
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.appearanceChanged() }
        configureWrapping(context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.wrapsLines != wrapsLines { configureWrapping(coordinator) }
        coordinator.update(text: text, style: style, followsTail: followsTail, measuresAll: sizing.isUncapped)
        // Read here so that bumping it updates this view.
        _ = sizeRevision
        coordinator.contentResized = { [sizeRevision = $sizeRevision] in sizeRevision.wrappedValue += 1 }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        switch sizing {
        case .fill:
            let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
            return CGSize(width: size.width.isFinite ? size.width : 320, height: size.height.isFinite ? size.height : 240)
        case .fitContent(let maxHeight):
            let width = min(proposal.width ?? 480, 4_000)
            guard width > 1 else { return CGSize(width: max(0, width), height: 0) }
            return CGSize(width: width, height: context.coordinator.height(forWidth: width, cap: maxHeight))
        }
    }

    private func configureWrapping(_ coordinator: Coordinator) {
        guard let scroll = coordinator.scroll, let textView = coordinator.textView, let container = textView.textContainer else { return }
        coordinator.wrapsLines = wrapsLines
        coordinator.measuredHeights.removeAll()
        scroll.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        container.widthTracksTextView = wrapsLines
        if !wrapsLines {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    @MainActor
    final class Coordinator {
        weak var scroll: PassthroughScrollView?
        weak var textView: NSTextView?
        var wrapsLines = true
        var measuredHeights: [CGFloat: CGFloat] = [:]
        var contentResized: (() -> Void)?
        private var applied = ""
        private var appliedStyle: Style?
        private var pendingScrollToEnd = false
        private var followsTail = false
        /// Markdown is rendered block by block; a streamed update replaces only changed blocks.
        private let markdown = MarkdownDocumentCache()
        private var renderedBlocks: [MarkdownBlock] = []
        private var blockOffsets: [Int] = []
        /// Per rendered block, the narrowest container its tables can be laid out in (0 without tables).
        private var blockNarrowest: [CGFloat] = []
        private var renderedDark: Bool?
        /// Sizes the view without touching the displayed layout, whose container follows the
        /// text view's width (zero, and so unbounded, until SwiftUI first places it). Only a
        /// prefix is measured: far less text than this already fills any height cap, and laying
        /// out a megabyte just to learn that it is taller than the cap takes a noticeable pause.
        private let measuringStorage = NSTextStorage()
        private let measuringLayout = NSLayoutManager()
        private let measuringContainer = NSTextContainer(containerSize: .zero)
        private static let measuredPrefix = 16_384
        /// Uncapped text measures all of itself.
        private var measuredLimit = measuredPrefix

        func attach(scroll: PassthroughScrollView, textView: NSTextView) {
            self.scroll = scroll
            self.textView = textView
            scroll.onTile = { [weak self] in self?.didTile() }
            measuringContainer.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 0
            measuringLayout.addTextContainer(measuringContainer)
            measuringStorage.addLayoutManager(measuringLayout)
        }

        func update(text: String, style: Style, followsTail: Bool, measuresAll: Bool = false) {
            guard let textView, let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
            // Contiguous layout keeps appends incremental and tail-following exact, and places the
            // Copy buttons of a reply's code cards exactly. Other static text only needs its
            // visible region laid out, however long it is.
            let contiguous = followsTail || style.isReply
            if layoutManager.allowsNonContiguousLayout == contiguous { layoutManager.allowsNonContiguousLayout = !contiguous }
            self.followsTail = followsTail
            measuredLimit = measuresAll ? Int.max : Self.measuredPrefix
            guard style != appliedStyle || text != applied else { return }
            // Following text starts at its end, then stays there until the reader scrolls away.
            let wasAtEnd = appliedStyle == nil || isScrolledToEnd
            var appended: String?
            /// Where a Markdown update began to differ from what was shown, if it did.
            var markdownChange: Int?
            if style.isMarkdown {
                if appliedStyle != style { forgetRendering() }
                markdownChange = renderMarkdown(text, style: style, into: storage)
            } else {
                (textView.textContainer as? MinimumWidthTextContainer)?.minimumWidth = 0
                appended = style == appliedStyle && style != .diff && !style.isHighlightedCode ? TextDelta.appendedSuffix(from: applied, to: text) : nil
                if let appended {
                    storage.append(NSAttributedString(string: appended, attributes: Self.attributes(for: style)))
                } else {
                    storage.setAttributedString(Self.attributedString(text, style: style))
                }
            }
            // The measured text is the displayed text's first `measuredLimit` characters. Appends
            // extend it until it is full, and after that leave it and its layout untouched.
            let prefix = min(storage.length, measuredLimit)
            if style.isMarkdown {
                // Streamed Markdown changes only its last blocks, so only the measured text from the
                // first change on is replaced, and laid out again. Past the measured prefix nothing
                // that sizes the view changed, so the measuring layout is kept.
                if let change = markdownChange {
                    let start = min(change, measuringStorage.length, prefix)
                    if start < measuringStorage.length || start < prefix {
                        measuringStorage.replaceCharacters(in: NSRange(location: start, length: measuringStorage.length - start),
                                                           with: storage.attributedSubstring(from: NSRange(location: start, length: prefix - start)))
                        measuredHeights.removeAll()
                    }
                }
            } else if appended == nil {
                measuringStorage.setAttributedString(storage.attributedSubstring(from: NSRange(location: 0, length: prefix)))
                measuredHeights.removeAll()
            } else if measuringStorage.length < prefix {
                let start = measuringStorage.length
                measuringStorage.append(storage.attributedSubstring(from: NSRange(location: start, length: prefix - start)))
                measuredHeights.removeAll()
            }
            applied = text
            appliedStyle = style
            if style.isReply { (textView as? MarkdownSourceTextView)?.codeCardsChanged() }
            if followsTail && wasAtEnd { scrollToEnd() }
        }

        /// Replaces the rendering from the first block that changed to the end.
        /// Returns the offset where the rendering changed, or nil when nothing did.
        @discardableResult
        private func renderMarkdown(_ text: String, style: Style, into storage: NSTextStorage) -> Int? {
            let blocks = markdown.blocks(for: text)
            let dark = textView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if renderedDark != dark { forgetRendering(); renderedDark = dark }
            var first = 0
            while first < blocks.count, first < renderedBlocks.count, blocks[first] == renderedBlocks[first] { first += 1 }
            if first == blocks.count, first == renderedBlocks.count, storage.length > 0 || blocks.isEmpty { return nil }
            let start = first < blockOffsets.count ? blockOffsets[first] : storage.length
            let renderer: MarkdownAttributedRenderer
            if case .reply(let markdownStyle) = style {
                renderer = .reply(markdownStyle, dark: dark) { [weak self] url in self?.image(url) }
            } else {
                renderer = MarkdownAttributedRenderer(fontSize: 14, color: .secondaryLabelColor, dark: dark)
            }
            let tail = NSMutableAttributedString()
            var offsets = Array(blockOffsets.prefix(first))
            var narrowest = Array(blockNarrowest.prefix(first))
            for index in first..<blocks.count {
                offsets.append(start + tail.length)
                let rendered = renderer.render(blocks[index], isFirst: index == 0)
                narrowest.append(MarkdownTextTable.narrowestLayoutWidth(in: rendered))
                tail.append(rendered)
            }
            // The shown text is never laid out narrower than its tables fit, however narrow the view
            // is for a moment: TextKit does not return from a table it cannot fit. The floor rises
            // before the new text arrives and falls only after the old text has gone.
            let container = textView?.textContainer as? MinimumWidthTextContainer
            let floor = narrowest.max() ?? 0
            if let container, floor > container.minimumWidth { container.minimumWidth = floor }
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            storage.endEditing()
            container?.minimumWidth = floor
            renderedBlocks = blocks
            blockOffsets = offsets
            blockNarrowest = narrowest
            return start
        }

        /// Renders every block again on the next update.
        private func forgetRendering() {
            renderedBlocks = []
            blockOffsets = []
            blockNarrowest = []
        }

        /// Math is drawn for one appearance, so Markdown renders again when it changes.
        func appearanceChanged() {
            guard let style = appliedStyle, style.isMarkdown, let storage = textView?.textStorage else { return }
            renderMarkdown(applied, style: style, into: storage)
            remeasureAll(storage)
        }

        private func remeasureAll(_ storage: NSTextStorage) {
            measuringStorage.setAttributedString(storage.attributedSubstring(from: NSRange(location: 0, length: min(storage.length, measuredLimit))))
            measuredHeights.removeAll()
            if appliedStyle?.isReply == true { (textView as? MarkdownSourceTextView)?.codeCardsChanged() }
        }

        /// A reply's image, once loaded; until then it shows as a link.
        private func image(_ url: URL) -> NSImage? {
            if let image = MarkdownImageCache.shared.image(for: url) { return image }
            MarkdownImageCache.shared.load(url) { [weak self] in self?.imageLoaded() }
            return nil
        }

        /// Shows a newly loaded image in place of its link, and has SwiftUI size the view again.
        private func imageLoaded() {
            guard let style = appliedStyle, style.isMarkdown, let storage = textView?.textStorage else { return }
            forgetRendering()
            renderMarkdown(applied, style: style, into: storage)
            remeasureAll(storage)
            contentResized?()
        }

        func height(forWidth width: CGFloat, cap: CGFloat) -> CGFloat {
            guard let textView else { return 0 }
            // Text beyond the prefix can only add height, so a partial measurement means the cap.
            if (textView.textStorage?.length ?? 0) > measuringStorage.length { return cap }
            if let cached = measuredHeights[width] { return min(cap, cached) }
            // A window being laid out measures its transcript a few points wide on the way to its real
            // width. A table cannot be laid out that narrow, and TextKit does not return from trying:
            // opening a task whose reply had a table hung the app. Such text is measured at the least it
            // fits, which for a table in a list item or a quote includes the indent around it.
            let narrowest = wrapsLines ? MarkdownTextTable.narrowestLayoutWidth(in: measuringStorage) : 0
            let size = NSSize(width: wrapsLines ? max(width, narrowest) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if measuringContainer.containerSize != size { measuringContainer.containerSize = size }
            measuringLayout.ensureLayout(for: measuringContainer)
            let used = measuringLayout.usedRect(for: measuringContainer)
            var height = used.height + textView.textContainerInset.height * 2
            if !wrapsLines, used.width > width, let scroll, scroll.scrollerStyle == .legacy, let scroller = scroll.horizontalScroller {
                height += scroller.frame.height
            }
            measuredHeights[width] = ceil(height)
            return min(cap, ceil(height))
        }

        private var isScrolledToEnd: Bool {
            guard let scroll, let textView else { return true }
            // Not placed yet, or still waiting to reach the end after being placed.
            if pendingScrollToEnd || scroll.frame.height < 1 { return true }
            return scroll.contentView.bounds.maxY >= textView.frame.height - 8
        }

        private func didTile() {
            guard pendingScrollToEnd else { return }
            scrollToEnd()
        }

        private func scrollToEnd() {
            guard let scroll, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            // Laying out at zero width would put every character on its own line.
            guard scroll.frame.width > 1, container.containerSize.width > 1 else { pendingScrollToEnd = true; return }
            pendingScrollToEnd = false
            layoutManager.ensureLayout(for: container)
            textView.sizeToFit()
            let clip = scroll.contentView
            // Scroll this clip view only: scrollRangeToVisible would also move the transcript.
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, textView.frame.height - clip.bounds.height)))
            scroll.reflectScrolledClipView(clip)
        }

        static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            switch style {
            case .prose:
                paragraph.lineSpacing = 3
                return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            case .body:
                paragraph.lineSpacing = 3
                return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            case .monospaced, .diff, .code:
                paragraph.lineSpacing = style == .monospaced ? 2 : 3
                return [.font: NSFont.monospacedSystemFont(ofSize: style == .diff ? 12 : 13, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            case .markdown:
                paragraph.lineSpacing = 3
                return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            case .reply(let markdown):
                paragraph.lineSpacing = markdown.lineSpacing
                return [.font: NSFont.systemFont(ofSize: markdown.fontSize), .foregroundColor: Theme.palette.inkNS, .paragraphStyle: paragraph]
            }
        }

        static func attributedString(_ text: String, style: Style) -> NSAttributedString {
            if case .code(let id?) = style, let language = SyntaxHighlighter.language(for: id) {
                let result = NSMutableAttributedString(attributedString: SyntaxHighlighter.attributedString(text, language: language, font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
                result.addAttribute(.paragraphStyle, value: attributes(for: style)[.paragraphStyle]!, range: NSRange(location: 0, length: result.length))
                return result
            }
            let result = NSMutableAttributedString(string: text, attributes: attributes(for: style))
            guard style == .diff else { return result }
            let source = result.string as NSString
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
                guard range.length > 0 else { return }
                let line = DiffLine(source.substring(with: NSRange(location: range.location, length: min(2, range.length))))
                result.addAttribute(.foregroundColor, value: line.foreground, range: range)
                if let background = line.background { result.addAttribute(.diffLineBackground, value: background, range: enclosing) }
            }
            return result
        }
    }
}

private extension ReadOnlyTextView.Style {
    var isHighlightedCode: Bool { if case .code(let language) = self { return language != nil }; return false }
    var isReply: Bool { if case .reply = self { return true }; return false }
    var isMarkdown: Bool { self == .markdown || isReply }
}

/// Copies typeset math as its LaTeX source and drawn symbols as text, places the Copy buttons
/// of code cards, and reports appearance changes so math redraws.
final class MarkdownSourceTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?
    private(set) var copyButtons: [CodeCopyButton] = []

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Code cards move when the text or its width changes; their buttons follow on the next layout.
    func codeCardsChanged() { needsLayout = true }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize.width != frame.width
        super.setFrameSize(newSize)
        if resized && !copyButtons.isEmpty { needsLayout = true }
    }

    override func layout() {
        super.layout()
        placeCopyButtons()
    }

    private func placeCopyButtons() {
        guard let storage = textStorage, let layoutManager else { return }
        var cards: [(card: MarkdownCodeCard, range: NSRange)] = []
        storage.enumerateAttribute(MarkdownAttributedRenderer.codeCardAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let card = value as? MarkdownCodeCard else { return }
            if let last = cards.last, last.card === card { cards[cards.count - 1].range = NSUnionRange(last.range, range) } else { cards.append((card, range)) }
        }
        while copyButtons.count > cards.count { copyButtons.removeLast().removeFromSuperview() }
        while copyButtons.count < cards.count {
            let button = CodeCopyButton()
            addSubview(button)
            copyButtons.append(button)
        }
        guard !cards.isEmpty, frame.width > 1, let container = textContainer else { return }
        let origin = textContainerOrigin
        for (button, entry) in zip(copyButtons, cards) {
            button.code = entry.card.code
            // The card's code fills its content area; the card adds its padding around that.
            let glyphs = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            var content = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in content = content.union(rect) }
            guard !content.isNull else { continue }
            let bounds = entry.card.boundsRect(forContentRect: content, in: NSRect(origin: .zero, size: container.size),
                                               textContainer: container, characterRange: entry.range)
            let card = entry.card.frameInsideMargins(bounds)
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: (origin.x + card.maxX - size.width - 6).rounded(),
                                  y: (origin.y + card.minY + (entry.card.headerHeight - size.height) / 2).rounded(),
                                  width: size.width, height: size.height)
        }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = NSMutableString()
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0 else { continue }
            if text.length > 0 { text.append("\n") }
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                if let source = attributes[MarkdownAttributedRenderer.latexAttribute] as? String ?? attributes[MarkdownAttributedRenderer.copiedTextAttribute] as? String {
                    text.append(source)
                } else {
                    // Line separators stand for soft breaks; zero-width spaces only space out tables.
                    text.append(storage.attributedSubstring(from: run).string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{200B}", with: ""))
                }
            }
        }
        guard text.length > 0 else { return super.writeSelection(to: pboard, type: type) }
        return pboard.setString(text as String, forType: .string)
    }
}

/// How streamed text changed since it was last shown.
enum TextDelta {
    /// The text added to the end of `old`, or nil when `new` does not continue it.
    static func appendedSuffix(from old: String, to new: String) -> String? {
        let oldBytes = old.utf8, newBytes = new.utf8
        guard !old.isEmpty, newBytes.count > oldBytes.count else { return nil }
        let contiguous = newBytes.withContiguousStorageIfAvailable { newBuffer in
            oldBytes.withContiguousStorageIfAvailable { oldBuffer in
                memcmp(newBuffer.baseAddress!, oldBuffer.baseAddress!, oldBuffer.count) == 0
            }
        } ?? nil
        guard contiguous ?? newBytes.starts(with: oldBytes) else { return nil }
        // `old` is valid UTF-8, so its length falls on a scalar boundary within `new`.
        return String(decoding: newBytes.dropFirst(oldBytes.count), as: UTF8.self)
    }
}

private struct DiffLine {
    var foreground: NSColor
    var background: NSColor?

    init(_ prefix: String) {
        if prefix.hasPrefix("+") { foreground = Theme.greenNS; background = Theme.greenNS.withAlphaComponent(0.08) }
        else if prefix.hasPrefix("-") { foreground = NSColor.systemRed.withAlphaComponent(0.85); background = NSColor.systemRed.withAlphaComponent(0.07) }
        else if prefix.hasPrefix("@@") { foreground = Theme.accentNS; background = nil }
        else { foreground = .secondaryLabelColor; background = nil }
    }
}

private extension NSAttributedString.Key {
    static let diffLineBackground = NSAttributedString.Key("GrokDiffLineBackground")
}

/// Fills added and removed diff lines across the full width, not only behind their glyphs.
private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let textView = firstTextView {
            let width = max(textView.bounds.width, textView.enclosingScrollView?.contentView.bounds.width ?? 0)
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
                let index = self.characterIndexForGlyph(at: glyphRange.location)
                guard index < storage.length,
                      let color = storage.attribute(.diffLineBackground, at: index, effectiveRange: nil) as? NSColor else { return }
                color.setFill()
                NSRect(x: 0, y: origin.y + rect.minY, width: width, height: rect.height).fill(using: .sourceOver)
            }
        }
        // Selection highlights draw on top of the line colour.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// A text container that follows its text view's width, but never below `minimumWidth`: the
/// narrowest its text can be laid out (see `MarkdownTextTable.narrowestLayoutWidth(in:)`). A view
/// narrower than that for a moment shows its text cut off at the edge instead of asking TextKit
/// for a layout it never returns from.
final class MinimumWidthTextContainer: NSTextContainer {
    /// The size last asked for, by the text view as it resizes or by the owner.
    private var requested: NSSize

    var minimumWidth: CGFloat = 0 {
        didSet { if minimumWidth != oldValue { apply() } }
    }

    override init(size: NSSize) {
        requested = size
        super.init(size: size)
    }

    required init(coder: NSCoder) {
        requested = .zero
        super.init(coder: coder)
    }

    override var size: NSSize {
        get { super.size }
        set { requested = newValue; apply() }
    }

    private func apply() {
        // No width means no limit, as before the view is first placed; that stays as it is.
        let width = requested.width > 0 ? max(requested.width, minimumWidth) : requested.width
        let floored = NSSize(width: width, height: requested.height)
        if super.size != floored { super.size = floored }
    }
}

/// Hands scrolling to the transcript when there is nothing to scroll here.
final class PassthroughScrollView: NSScrollView {
    var onTile: (() -> Void)?

    override func tile() {
        super.tile()
        onTile?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let document = documentView else { return super.scrollWheel(with: event) }
        let visible = contentView.bounds
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let canScroll = vertical
            ? document.frame.height > visible.height + 1
            : hasHorizontalScroller && document.frame.width > visible.width + 1
        if canScroll { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}
