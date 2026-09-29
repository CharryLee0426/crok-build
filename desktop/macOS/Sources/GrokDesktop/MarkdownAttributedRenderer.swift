import AppKit

/// Renders Markdown blocks into TextKit 1 attributed text: tables become `NSTextTable`s,
/// code blocks and quotes are `NSTextBlock`s, and math is typeset into attachments.
/// Used where text must stay in one text view: streamed reasoning, and replies, where a
/// selection can then run from a paragraph through a table or code block into the next.
///
/// Each top-level block renders independently, and every block after the first begins with
/// the newline that ends the previous one, so a streaming update can replace just the tail.
struct MarkdownAttributedRenderer {
    var fontSize: CGFloat = 14
    var color: NSColor = .secondaryLabelColor
    /// The appearance math images are drawn for; text colours stay dynamic.
    var dark = false
    /// Replies: headings and spacing follow the style, and code, callouts, and tables are cards
    /// like the SwiftUI renderer's. Reasoning leaves it nil and stays plain.
    var reply: MarkdownStyle?
    /// A loaded image for a paragraph that is only an image; without one it shows as a link.
    var image: ((URL) -> NSImage?)?

    static let latexAttribute = NSAttributedString.Key("GrokMarkdownLaTeX")
    /// What a copy puts on the pasteboard in place of the run, such as `[x]` for a drawn checkbox.
    static let copiedTextAttribute = NSAttributedString.Key("GrokMarkdownCopiedText")
    /// The `MarkdownCodeCard` a reply's code sits in; its Copy button copies the card's code.
    static let codeCardAttribute = NSAttributedString.Key("GrokMarkdownCodeCard")

    static func reply(_ style: MarkdownStyle, dark: Bool, image: ((URL) -> NSImage?)? = nil) -> MarkdownAttributedRenderer {
        MarkdownAttributedRenderer(fontSize: style.fontSize, color: style.secondary ? Theme.palette.mutedNS : Theme.palette.inkNS,
                                   dark: dark, reply: style, image: image)
    }

    func render(_ block: MarkdownBlock, isFirst: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        if !isFirst { output.append(NSAttributedString(string: "\n", attributes: baseAttributes(Context()))) }
        append(block, context: Context(), to: output)
        return output
    }

    func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() { output.append(render(block, isFirst: index == 0)) }
        return output
    }

    // MARK: Context

    private struct Context {
        var indent: CGFloat = 0
        var textBlocks: [NSTextBlock] = []
        var quoted = false
        var tight = false
    }

    private var lineSpacing: CGFloat { reply?.lineSpacing ?? (fontSize * 0.22).rounded() }
    // TextKit adds line spacing under a paragraph's last line too, where SwiftUI adds it only
    // between lines, so a reply's paragraph spacing leaves it out to match the SwiftUI renderer.
    private var spacing: CGFloat { reply.map { max(0, $0.blockSpacing - $0.lineSpacing) } ?? (fontSize * 0.6).rounded() }
    private var tightSpacing: CGFloat { reply.map { max(0, $0.fontSize * 0.35 - $0.lineSpacing) } ?? fontSize * 0.2 }
    /// Quotes and list markers.
    private var quietColor: NSColor { reply == nil ? .tertiaryLabelColor : Theme.palette.mutedNS }

    private func paragraphStyle(_ context: Context, firstIndent: CGFloat? = nil, headIndent: CGFloat? = nil,
                                alignment: NSTextAlignment = .natural, spacingAfter: CGFloat? = nil, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.firstLineHeadIndent = firstIndent ?? context.indent
        style.headIndent = headIndent ?? context.indent
        style.paragraphSpacing = spacingAfter ?? (context.tight ? tightSpacing : spacing)
        style.paragraphSpacingBefore = spacingBefore
        style.alignment = alignment
        style.textBlocks = context.textBlocks
        if let headIndent { style.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)] }
        return style
    }

    private func baseAttributes(_ context: Context, font: NSFont? = nil) -> [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: fontSize), .foregroundColor: context.quoted ? quietColor : color,
         .paragraphStyle: paragraphStyle(context)]
    }

    // MARK: Blocks

    private func append(_ block: MarkdownBlock, context: Context, to output: NSMutableAttributedString) {
        switch block {
        case .heading(let level, let content):
            let size = reply?.headingSize(level) ?? (fontSize * [1.35, 1.2, 1.1, 1.0, 1.0, 0.95][min(max(level, 1), 6) - 1]).rounded()
            let text = inlines(content, context: context, font: .systemFont(ofSize: size, weight: reply == nil || level <= 3 ? .semibold : .medium))
            let style = reply == nil ? paragraphStyle(context, spacingAfter: spacing * 0.6, spacingBefore: spacing * 0.5)
                : paragraphStyle(context, spacingBefore: level <= 2 ? 8 : 4)
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            output.append(text)
        case .paragraph(let content):
            if reply != nil, let sole = content.soleImage, let url = MarkdownInlineBuilder.url(sole.source), let loaded = image?(url) {
                appendImage(loaded, url: url, source: sole.source, alt: sole.alt, context: context, to: output)
            } else {
                output.append(inlines(content, context: context))
            }
        case .code(let language, let code, let isClosed):
            appendCode(code, language: language, isClosed: isClosed, context: context, to: output)
        case .math(let latex):
            appendDisplayMath(latex, context: context, to: output)
        case .quote(let blocks):
            var inner = boxed(quoteBlock(color: reply == nil ? .separatorColor : Theme.palette.lineNS), in: context)
            inner.quoted = true
            appendBlocks(blocks, context: inner, to: output)
        case .callout(let kind, let title, let blocks):
            appendCallout(kind: kind, title: title, blocks: blocks, context: context, to: output)
        case .list(let list):
            appendList(list, context: context, to: output)
        case .table(let table):
            appendTable(table, context: context, to: output)
        case .thematicBreak:
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(reply == nil ? .separatorColor : Theme.palette.lineNS, for: .maxY)
            let inner = boxed(rule, in: context)
            // Replies give the rule the SwiftUI renderer's 6 pt above and below.
            let style = reply.map { paragraphStyle(inner, spacingAfter: $0.blockSpacing + 6, spacingBefore: 6) } ?? paragraphStyle(inner)
            output.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style]))
        case .html(let html):
            appendCode(html, language: "html", context: context, to: output)
        case .footnoteDefinition(let label, let blocks):
            output.append(NSAttributedString(string: "\(label). ", attributes: baseAttributes(context, font: .systemFont(ofSize: fontSize * 0.85, weight: .medium))))
            var smaller = self
            smaller.fontSize = fontSize * 0.85
            if let reply {
                smaller.reply = MarkdownStyle(fontSize: reply.fontSize * 0.85, secondary: true, blockSpacing: 6)
                smaller.color = Theme.palette.mutedNS
            }
            for (index, child) in blocks.enumerated() {
                if index > 0 { output.append(newline(context)) }
                smaller.append(child, context: context, to: output)
            }
        }
    }

    private func appendBlocks(_ blocks: [MarkdownBlock], context: Context, to output: NSMutableAttributedString) {
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(newline(context)) }
            append(block, context: context, to: output)
        }
    }

    private func newline(_ context: Context) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: baseAttributes(context))
    }

    private func quoteBlock(color: NSColor) -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(color, for: .minX)
        block.setWidth(reply == nil ? 10 : 11, type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    /// Places a decorated block in the current context. A text block without an explicit
    /// width collapses and draws nothing, and its margin does not inset its background, so
    /// indentation (inside list items) comes from an undecorated outer block instead.
    private func boxed(_ block: NSTextBlock, in context: Context) -> Context {
        var inner = context
        if context.indent > 0 {
            let indent = NSTextBlock()
            indent.setValue(100, type: .percentageValueType, for: .width)
            indent.setWidth(context.indent, type: .absoluteValueType, for: .padding, edge: .minX)
            inner.textBlocks.append(indent)
        }
        block.setValue(100, type: .percentageValueType, for: .width)
        inner.textBlocks.append(block)
        inner.indent = 0
        return inner
    }

    private static func calloutColor(_ kind: String) -> NSColor {
        switch kind {
        case "tip": return Theme.greenNS
        case "important": return .systemPurple
        case "warning": return .systemOrange
        case "caution": return .systemRed
        default: return .systemBlue
        }
    }

    /// The SwiftUI renderer's callout labels and symbols.
    private static func calloutLook(_ kind: String) -> (label: String, symbol: String) {
        switch kind {
        case "tip": return ("Tip", "lightbulb")
        case "important": return ("Important", "exclamationmark.bubble")
        case "warning": return ("Warning", "exclamationmark.triangle")
        case "caution": return ("Caution", "exclamationmark.octagon")
        default: return ("Note", "info.circle")
        }
    }

    private func appendCallout(kind: String, title: String?, blocks: [MarkdownBlock], context: Context, to output: NSMutableAttributedString) {
        let tint = Self.calloutColor(kind)
        guard reply != nil else {
            let inner = boxed(quoteBlock(color: tint), in: context)
            output.append(NSAttributedString(string: title ?? kind.capitalized, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.92, weight: .semibold), .foregroundColor: tint,
                .paragraphStyle: paragraphStyle(inner, spacingAfter: fontSize * 0.25)
            ]))
            if !blocks.isEmpty { output.append(newline(inner)); appendBlocks(blocks, context: inner, to: output) }
            return
        }
        let look = Self.calloutLook(kind)
        let inner = boxed(MarkdownCalloutCard(tint: tint, gapBelow: lineSpacing), in: context)
        let font = NSFont.systemFont(ofSize: (fontSize * 0.9).rounded(), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint,
                                                          .paragraphStyle: paragraphStyle(inner, spacingAfter: (spacing * 0.6).rounded())]
        let label = NSMutableAttributedString()
        if let symbol = symbol(look.symbol, size: font.pointSize, color: tint, attributes: attributes) {
            label.append(symbol)
            label.append(NSAttributedString(string: " ", attributes: attributes))
        }
        label.append(NSAttributedString(string: title ?? look.label, attributes: attributes))
        output.append(label)
        if !blocks.isEmpty { output.append(newline(inner)); appendBlocks(blocks, context: inner, to: output) }
    }

    private func appendCode(_ code: String, language: String?, isClosed: Bool = true, context: Context, to output: NSMutableAttributedString) {
        // Replies name the language they detect, as the SwiftUI renderer does; reasoning highlights only fenced languages.
        let resolved = language.flatMap(SyntaxHighlighter.language(for:))
            ?? (reply != nil && language == nil && isClosed ? SyntaxHighlighter.detectLanguage(code) : nil)
        let box: NSTextBlock
        let font: NSFont
        let style = NSMutableParagraphStyle()
        if let reply {
            box = MarkdownCodeCard(code: code, title: resolved?.displayName ?? language ?? "Code", fontSize: fontSize, gapBelow: lineSpacing)
            font = .monospacedSystemFont(ofSize: reply.codeSize, weight: .regular)
            style.lineSpacing = 3
        } else {
            box = NSTextBlock()
            box.backgroundColor = Theme.codeBackgroundNS
            box.setWidth(8, type: .absoluteValueType, for: .padding)
            box.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            font = .monospacedSystemFont(ofSize: (fontSize * 0.9).rounded(), weight: .regular)
            style.lineSpacing = 2
        }
        let inner = boxed(box, in: context)
        let text = NSMutableAttributedString(attributedString: SyntaxHighlighter.attributedString(code.isEmpty ? " " : code, language: resolved, font: font))
        style.textBlocks = inner.textBlocks
        style.paragraphSpacing = 0
        let whole = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: style, range: whole)
        let plain = reply == nil ? NSColor.labelColor : color
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: plain, range: range) }
        }
        if reply != nil { text.addAttribute(Self.codeCardAttribute, value: box, range: whole) }
        output.append(text)
        // Spacing after the box belongs to its last paragraph.
        let last = (text.string as NSString).paragraphRange(for: NSRange(location: max(0, text.length - 1), length: 0))
        let closing = style.mutableCopy() as! NSMutableParagraphStyle
        closing.paragraphSpacing = spacing
        output.addAttribute(.paragraphStyle, value: closing, range: NSRange(location: output.length - text.length + last.location, length: last.length))
    }

    private func appendDisplayMath(_ latex: String, context: Context, to output: NSMutableAttributedString) {
        guard let attachment = mathAttachment(latex, display: true) else {
            appendCode(latex, language: "latex", context: context, to: output)
            return
        }
        let text = NSMutableAttributedString(attachment: attachment)
        let style = reply == nil ? paragraphStyle(context, alignment: .center)
            : paragraphStyle(context, alignment: .center, spacingAfter: spacing + 4, spacingBefore: 4)
        text.addAttributes([.paragraphStyle: style, Self.latexAttribute: "$$\(latex)$$"], range: NSRange(location: 0, length: text.length))
        output.append(text)
    }

    private func mathAttachment(_ latex: String, display: Bool, size: CGFloat? = nil) -> NSTextAttachment? {
        let resolved = MarkdownColors.resolved(color, dark: dark)
        guard let math = MathRenderer.render(latex, fontSize: (size ?? fontSize) * (display ? 1.1 : 1.05), color: resolved, display: display) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = math.image
        attachment.bounds = CGRect(x: 0, y: -math.descent, width: math.width, height: math.height)
        return attachment
    }

    /// An SF Symbol in one colour, centred on the text's capitals and left out of copies.
    private func symbol(_ name: String, size: CGFloat, color: NSColor, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)) else { return nil }
        // Drawn on demand, so a dynamic colour follows the appearance it is drawn in.
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: size)
        attachment.bounds = CGRect(x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        var runAttributes = attributes
        runAttributes[Self.copiedTextAttribute] = ""
        text.addAttributes(runAttributes, range: NSRange(location: 0, length: text.length))
        return text
    }

    private func appendImage(_ image: NSImage, url: URL, source: String, alt: String, context: Context, to output: NSMutableAttributedString) {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownImageCell(image: image, url: url)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes([.paragraphStyle: paragraphStyle(context), .toolTip: alt.isEmpty ? (url.scheme == "data" ? "Image" : source) : alt,
                            Self.copiedTextAttribute: "![\(alt)](\(source))"], range: NSRange(location: 0, length: text.length))
        output.append(text)
    }

    private func appendList(_ list: MarkdownList, context: Context, to output: NSMutableAttributedString) {
        let start = output.length
        defer { endSpacing(of: output, after: start, context: context) }
        let drawsCheckboxes = reply != nil && list.items.contains { $0.task != nil }
        let markerWidth = list.ordered ? fontSize * (list.start + list.items.count > 9 ? 1.9 : 1.5) : fontSize * (drawsCheckboxes ? 1.55 : 1.2)
        let depth = Int(context.indent / (fontSize * 1.5))
        for (index, item) in list.items.enumerated() {
            if index > 0 { output.append(newline(context)) }
            var inner = context
            inner.indent = context.indent + markerWidth
            inner.tight = list.isTight
            let markerStyle = paragraphStyle(inner, firstIndent: context.indent, headIndent: inner.indent)
            let marker = self.marker(list: list, item: item, index: index, depth: depth, style: markerStyle)
            var first = true
            for (blockIndex, block) in item.content.enumerated() {
                if blockIndex > 0 { output.append(newline(inner)) }
                let piece = NSMutableAttributedString()
                append(block, context: inner, to: piece)
                if first, case .paragraph = block {
                    // The marker hangs in the indent of the item's first paragraph.
                    piece.insert(marker, at: 0)
                    let firstParagraph = (piece.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    piece.addAttribute(.paragraphStyle, value: markerStyle, range: firstParagraph)
                } else if first {
                    let alone = NSMutableAttributedString(attributedString: marker)
                    alone.replaceCharacters(in: NSRange(location: alone.length - 1, length: 1), with: "\n")
                    output.append(alone)
                }
                first = false
                output.append(piece)
            }
            if item.content.isEmpty { output.append(marker) }
        }
    }

    /// A list's last paragraph is followed by whatever follows the list, not by another tight item.
    private func endSpacing(of output: NSMutableAttributedString, after start: Int, context: Context) {
        guard output.length > start else { return }
        let last = (output.string as NSString).paragraphRange(for: NSRange(location: output.length - 1, length: 0))
        guard last.location >= start, let style = output.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle else { return }
        let spaced = style.mutableCopy() as! NSMutableParagraphStyle
        spaced.paragraphSpacing = context.tight ? tightSpacing : spacing
        output.addAttribute(.paragraphStyle, value: spaced, range: last)
    }

    /// The bullet, number, or checkbox, followed by the tab that reaches the item's indent.
    private func marker(list: MarkdownList, item: MarkdownListItem, index: Int, depth: Int, style: NSParagraphStyle) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: quietColor, .paragraphStyle: style]
        let text = NSMutableAttributedString()
        if let done = item.task {
            if reply != nil, let box = symbol(done ? "checkmark.square.fill" : "square", size: fontSize * 0.95,
                                              color: done ? Theme.accentNS : Theme.palette.mutedNS, attributes: attributes) {
                let copied = NSMutableAttributedString(attributedString: box)
                copied.addAttribute(Self.copiedTextAttribute, value: done ? "[x]" : "[ ]", range: NSRange(location: 0, length: copied.length))
                text.append(copied)
            } else {
                text.append(NSAttributedString(string: done ? "☑" : "☐", attributes: attributes))
            }
        } else if list.ordered {
            if reply != nil {
                attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                attributes[.foregroundColor] = color.fading(0.75)
            }
            text.append(NSAttributedString(string: "\(list.start + index).", attributes: attributes))
        } else {
            if reply != nil {
                attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                attributes[.foregroundColor] = color.fading(0.6)
            }
            text.append(NSAttributedString(string: ["•", "◦", "▪"][depth % 3], attributes: attributes))
        }
        text.append(NSAttributedString(string: "\t", attributes: attributes))
        return text
    }

    private func appendTable(_ table: MarkdownTable, context: Context, to output: NSMutableAttributedString) {
        let columns = max(1, table.header.count)
        var outer = context.textBlocks
        if context.indent > 0 {
            let indent = NSTextBlock()
            indent.setValue(100, type: .percentageValueType, for: .width)
            indent.setWidth(context.indent, type: .absoluteValueType, for: .padding, edge: .minX)
            outer.append(indent)
        }
        let rows = [table.header] + table.rows
        let padding: (horizontal: CGFloat, vertical: CGFloat) = reply == nil ? (6, 6) : (12, 8)
        var plain = context
        plain.indent = 0
        plain.textBlocks = outer
        // Cells are rendered first, so a reply's table can size its columns to them.
        let texts = rows.enumerated().map { rowIndex, row in
            (0..<columns).map { column -> NSMutableAttributedString in
                let content = column < row.count ? row[column] : []
                return inlines(content.isEmpty ? [.text(" ")] : content, context: plain,
                               font: rowIndex == 0 ? .systemFont(ofSize: fontSize * 0.92, weight: .semibold) : .systemFont(ofSize: fontSize * 0.92))
            }
        }
        let textTable: NSTextTable
        if reply != nil {
            let widest = (0..<columns).map { column in texts.map { Self.naturalWidth($0[column]) }.max() ?? 0 }
            let words = (0..<columns).map { column in texts.map { Self.widestWord($0[column]) }.max() ?? 0 }
            textTable = MarkdownTextTable(widest: widest.map { $0 + 2 }, words: words.map { $0 + 2 }, inset: padding.horizontal + 0.5)
        } else {
            textTable = NSTextTable()
            textTable.numberOfColumns = columns
        }
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        for (rowIndex, row) in texts.enumerated() {
            for (column, text) in row.enumerated() {
                let cell = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(padding.horizontal, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(padding.horizontal, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(padding.vertical, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(padding.vertical, type: .absoluteValueType, for: .padding, edge: .maxY)
                if reply == nil {
                    cell.setBorderColor(.separatorColor)
                    if rowIndex == 0 { cell.backgroundColor = Theme.tableHeaderNS }
                } else {
                    cell.setBorderColor(Theme.palette.lineNS.fading(0.45))
                    cell.backgroundColor = rowIndex == 0 ? Theme.tableHeaderNS : rowIndex.isMultiple(of: 2) ? Theme.palette.tableStripeNS : nil
                }
                var inner = plain
                inner.textBlocks = outer + [cell]
                let alignment: NSTextAlignment = {
                    switch column < table.alignments.count ? table.alignments[column] : .none {
                    case .center: return .center
                    case .right: return .right
                    default: return .natural
                    }
                }()
                let style = paragraphStyle(inner, firstIndent: 0, alignment: alignment, spacingAfter: 0)
                text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                if rowIndex > 0 || column > 0 { output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
                output.append(text)
            }
        }
        // A table's own bottom margin is not honoured, so a short empty paragraph separates it from what follows.
        output.append(NSAttributedString(string: "\n\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: paragraphStyle(context, spacingAfter: spacing * 0.5)]))
    }

    /// The width a cell's text takes on one line.
    private static func naturalWidth(_ text: NSAttributedString) -> CGFloat {
        let line = NSMutableAttributedString(attributedString: text)
        line.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: line.length))
        return ceil(line.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin]).width)
    }

    /// The width of a cell's longest word, below which its words would break.
    private static func widestWord(_ text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { _, range, _, _ in
            widest = max(widest, naturalWidth(text.attributedSubstring(from: range)))
        }
        return widest
    }

    // MARK: Inlines

    private struct Traits {
        var bold = false, italic = false, code = false, strike = false, superscript = false
        var link: URL?
    }

    private func inlines(_ content: [MarkdownInline], context: Context, font base: NSFont? = nil) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        let baseFont = base ?? .systemFont(ofSize: fontSize)
        let attributes = baseAttributes(context, font: baseFont)
        func font(_ traits: Traits) -> NSFont {
            if traits.code { return .monospacedSystemFont(ofSize: (baseFont.pointSize * 0.9).rounded(), weight: .regular) }
            var result = traits.superscript ? NSFont.systemFont(ofSize: baseFont.pointSize * 0.72) : baseFont
            if traits.bold { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
            if traits.italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
            return result
        }
        func run(_ traits: Traits) -> [NSAttributedString.Key: Any] {
            var run = attributes
            run[.font] = font(traits)
            if traits.code { run[.backgroundColor] = Theme.inlineCodeNS }
            if traits.strike { run[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if traits.superscript { run[.baselineOffset] = baseFont.pointSize * 0.35 }
            if let link = traits.link { run[.link] = link }
            return run
        }
        func add(_ text: String, _ traits: Traits) {
            output.append(NSAttributedString(string: text, attributes: run(traits)))
        }
        func visit(_ nodes: [MarkdownInline], _ traits: Traits) {
            for node in nodes {
                switch node {
                case .text(let text): add(text, traits)
                case .emphasis(let children): var next = traits; next.italic = true; visit(children, next)
                case .strong(let children): var next = traits; next.bold = true; visit(children, next)
                case .strikethrough(let children): var next = traits; next.strike = true; visit(children, next)
                case .code(let code): var next = traits; next.code = true; add(code, next)
                case .math(let latex), .displayMath(let latex):
                    if let attachment = mathAttachment(latex, display: false, size: baseFont.pointSize) {
                        let piece = NSMutableAttributedString(attachment: attachment)
                        piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
                        piece.addAttribute(Self.latexAttribute, value: "$\(latex)$", range: NSRange(location: 0, length: piece.length))
                        output.append(piece)
                    } else {
                        var next = traits; next.code = true; add("$\(latex)$", next)
                    }
                case .link(let destination, _, let children):
                    var next = traits; next.link = MarkdownInlineBuilder.url(destination)
                    if children.isEmpty { add(destination, next) } else { visit(children, next) }
                case .image(let source, _, let alt):
                    var next = traits; next.link = MarkdownInlineBuilder.url(source)
                    let label = alt.isEmpty ? source : alt
                    if reply != nil, let photo = symbol("photo", size: baseFont.pointSize * 0.9, color: Theme.accentNS, attributes: run(next)) {
                        output.append(photo)
                        add(" " + label, next)
                    } else {
                        add("🖼 " + label, next)
                    }
                case .footnoteReference(let label): var next = traits; next.superscript = true; add("[\(label)]", next)
                case .html(let html): add(html, traits)
                case .softBreak, .lineBreak: add("\u{2028}", traits)
                }
            }
        }
        visit(content, Traits())
        if output.length == 0 { output.append(NSAttributedString(string: "", attributes: attributes)) }
        return output
    }
}
