import AppKit

// The cards a reply's TextKit rendering draws in place of the SwiftUI renderer's views, so the
// reply stays one text view that a selection can cross.

extension NSColor {
    /// The colour at a fraction of its own opacity, like SwiftUI's `opacity(_:)`. `withAlphaComponent`
    /// replaces the opacity instead, which darkens translucent system colours such as `separatorColor`.
    func fading(_ fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance { resolved = self.usingColorSpace(.sRGB) ?? self }
            return resolved.withAlphaComponent(resolved.alphaComponent * fraction)
        }
    }
}

extension NSTextBlock {
    /// The block within the frame TextKit draws it in, which includes its margins.
    func frameInsideMargins(_ frame: NSRect) -> NSRect {
        let left = width(for: .margin, edge: .minX), top = width(for: .margin, edge: .minY)
        return NSRect(x: frame.minX + left, y: frame.minY + top,
                      width: max(0, frame.width - left - width(for: .margin, edge: .maxX)),
                      height: max(0, frame.height - top - width(for: .margin, edge: .maxY)))
    }
}

/// A code block: a rounded card whose header band names the language. The band is the block's
/// top padding, so the name is drawn rather than typed and stays out of selections and copies;
/// `MarkdownSourceTextView` places the Copy button over it.
final class MarkdownCodeCard: NSTextBlock {
    let code: String
    let title: String
    let headerHeight: CGFloat
    private let inset: CGFloat
    private let radius: CGFloat
    private let titleFont: NSFont

    /// `gapBelow` is the line spacing the text around the card has under each line, which the card's own last line lacks.
    init(code: String, title: String, fontSize: CGFloat, gapBelow: CGFloat) {
        self.code = code
        self.title = title
        headerHeight = (fontSize * 2.125).rounded()
        inset = (fontSize * 0.8125).rounded()
        radius = (fontSize * 0.625).rounded()
        titleFont = .systemFont(ofSize: max(11, (fontSize * 0.75).rounded()), weight: .medium)
        super.init()
        let vertical = (fontSize * 0.6875).rounded()
        setWidth(headerHeight + vertical, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(inset, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(inset, type: .absoluteValueType, for: .padding, edge: .maxX)
        setWidth(gapBelow, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    required init?(coder: NSCoder) { nil }

    /// Cards do not change once rendered, and a copy would not carry the code.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let card = frameInsideMargins(frameRect).insetBy(dx: 0.25, dy: 0.25)
        let shape = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        Theme.codeBackgroundNS.setFill()
        shape.fill()
        Theme.palette.lineNS.fading(0.35).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        Theme.palette.lineNS.fading(0.4).setFill()
        NSRect(x: card.minX, y: card.minY + headerHeight, width: card.width, height: 0.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: Theme.palette.mutedNS]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: card.minX + inset, y: card.minY + ((headerHeight - size.height) / 2).rounded()), withAttributes: attributes)
    }
}

/// A GitHub callout: a tinted rounded card with a bar in its colour along the leading edge.
final class MarkdownCalloutCard: NSTextBlock {
    let tint: NSColor

    init(tint: NSColor, gapBelow: CGFloat) {
        self.tint = tint
        super.init()
        setWidth(17, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(gapBelow, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    required init?(coder: NSCoder) { nil }

    override func copy(with zone: NSZone? = nil) -> Any { self }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let card = frameInsideMargins(frameRect)
        let shape = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        tint.fading(0.07).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        tint.fading(0.8).setFill()
        NSRect(x: card.minX, y: card.minY, width: 3, height: card.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A table sized like a web page's: columns take their content's width when it fits, and in a
/// narrower view the long columns wrap first while short ones keep whole words. TextKit asks for
/// each cell's rectangle as it lays out, so the columns follow the view as it resizes.
final class MarkdownTextTable: NSTextTable {
    /// Per column, the width of its longest cell on one line, and of its longest word.
    private let widest: [CGFloat]
    private let words: [CGFloat]
    /// Padding and border on each side of a cell's content.
    private let inset: CGFloat

    init(widest: [CGFloat], words: [CGFloat], inset: CGFloat) {
        self.widest = widest
        self.words = words
        self.inset = inset
        super.init()
        numberOfColumns = widest.count
    }

    required init?(coder: NSCoder) { nil }

    override func copy(with zone: NSZone? = nil) -> Any { self }

    /// Content widths for the columns in `available` points, shared out as CSS's automatic table layout does.
    func contentWidths(in available: CGFloat) -> [CGFloat] {
        let space = max(0, available - inset * 2 * CGFloat(widest.count))
        let most = widest.reduce(0, +), least = words.reduce(0, +)
        if most <= space { return widest }
        // Whole points keep the borders between columns sharp.
        guard least < space, most > least else {
            return least > 0 ? words.map { ($0 * space / least).rounded(.down) } : widest.map { _ in (space / CGFloat(max(1, widest.count))).rounded(.down) }
        }
        let share = (space - least) / (most - least)
        return zip(words, widest).map { ($0 + ($1 - $0) * share).rounded(.down) }
    }

    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect, textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        var cell = super.rect(for: block, layoutAt: startingPoint, in: rect, textContainer: textContainer, characterRange: charRange)
        let widths = contentWidths(in: rect.width)
        guard block.startingColumn < widths.count else { return cell }
        cell.origin.x = rect.minX + widths[..<block.startingColumn].reduce(0) { $0 + $1 + inset * 2 } + inset
        cell.size.width = widths[block.startingColumn]
        return cell
    }
}

/// An image paragraph: the image at its own size, within 560 × 420 pt and the line's width.
/// A click opens it in the image viewer, or the default app when there is none.
final class MarkdownImageCell: NSTextAttachmentCell {
    /// Shows a reply's image; the store sets it to open its viewer.
    @MainActor static var open: ((URL, NSImage) -> Void)?
    private let url: URL?

    init(image: NSImage, url: URL) {
        self.url = url
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        url = nil
        super.init(coder: coder)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let available = max(1, lineFrag.width - textContainer.lineFragmentPadding * 2)
        let scale = min(1, min(560, available) / size.width, 420 / size.height)
        return NSRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: cellFrame, xRadius: 8, yRadius: 8).addClip()
        image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func wantsToTrackMouse() -> Bool { url != nil }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let url else { return true }
        MainActor.assumeIsolated {
            if let open = Self.open, let image { open(url, image) } else if url.scheme != "data" { NSWorkspace.shared.open(url) }
        }
        return true
    }
}

/// Images shown in replies, read off the main thread and kept for the session.
@MainActor
final class MarkdownImageCache {
    static let shared = MarkdownImageCache()
    private let images = NSCache<NSURL, NSImage>()
    private var waiting: [URL: [() -> Void]] = [:]
    private var unavailable: Set<URL> = []

    func image(for url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    /// Calls `loaded` once the image can be shown; one that cannot be read stays a link.
    func load(_ url: URL, then loaded: @escaping () -> Void) {
        guard image(for: url) == nil, !unavailable.contains(url) else { return }
        if waiting[url] != nil { waiting[url]?.append(loaded); return }
        waiting[url] = [loaded]
        Task {
            let image = await Self.read(url)
            let callbacks = waiting.removeValue(forKey: url) ?? []
            guard let image else { unavailable.insert(url); return }
            images.setObject(image, forKey: url as NSURL)
            callbacks.forEach { $0() }
        }
    }

    private nonisolated static func read(_ url: URL) async -> NSImage? {
        let image: NSImage?
        if url.isFileURL {
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        } else if let data = decodeDataURL(url) {
            image = await Task.detached(priority: .utility) { NSImage(data: data) }.value
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
            image = NSImage(data: data)
        } else {
            image = nil
        }
        return image?.isValid == true ? image : nil
    }

    /// The bytes of a base64 `data:image/…` URL, which a reply (or a tool) can inline.
    nonisolated static func decodeDataURL(_ url: URL) -> Data? {
        guard url.scheme?.lowercased() == "data" else { return nil }
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ","), text[..<comma].lowercased().hasSuffix(";base64"),
              text[..<comma].lowercased().hasPrefix("data:image/") else { return nil }
        let payload = String(text[text.index(after: comma)...]).removingPercentEncoding ?? String(text[text.index(after: comma)...])
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }
}

/// The Copy button over a code card's header band.
final class CodeCopyButton: NSButton {
    var code = ""
    var pasteboard = NSPasteboard.general
    private var restore: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = Theme.palette.mutedNS
        target = self
        action = #selector(copyCode)
        show(copied: false)
    }

    required init?(coder: NSCoder) { nil }

    /// The text view's I-beam would otherwise show over the button.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func copyCode() {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        show(copied: true)
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(copied: false) }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func show(copied: Bool) {
        let title = copied ? "Copied" : "Copy"
        image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.palette.mutedNS])
        setAccessibilityLabel(copied ? "Copied" : "Copy code")
        toolTip = title
        superview?.needsLayout = true
    }
}
