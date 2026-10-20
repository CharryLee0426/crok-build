import SwiftUI
import UIKit

/// Renders an assistant reply: CommonMark + GFM with LaTeX math, drawn natively (relay/DESIGN.md §5 "Replies in
/// Markdown"). Wide content never leaves the bubble: code blocks, tables and display math scroll sideways in place.
struct MarkdownText: View {
    let text: String
    var foreground: Color = Theme.agentBubbleText
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let document = MarkdownCache.document(for: text)
        MarkdownBlocks(
            blocks: document.blocks,
            style: MarkdownStyle(math: document.math, foreground: foreground, dynamicTypeSize: dynamicTypeSize))
    }

    /// Inline Markdown only (bold, italics, `code`, links), for one-paragraph uses such as a thought.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in parsed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                parsed[run.range].font = Font.system(.callout, design: .monospaced)
                parsed[run.range].backgroundColor = Theme.codeBackground
            }
        }
        return parsed
    }
}

/// What every block of one reply shares. Equatable, so while a reply streams the blocks that did not change are
/// not drawn again (`MarkdownBlockView` compares its block and this).
struct MarkdownStyle: Equatable {
    /// The reply's math; blocks refer to it by index.
    let math: [MathSpan]
    var foreground: Color
    /// The body font size (Dynamic Type), which math follows.
    var mathSize: CGFloat
    var listDepth = 0
    /// Inline math wider than this (60 % of the screen) is shown as a display block instead.
    let wideMath: CGFloat

    @MainActor
    init(math: [MathSpan], foreground: Color, dynamicTypeSize: DynamicTypeSize) {
        self.math = math
        self.foreground = foreground
        mathSize = Self.pointSize(.body, dynamicTypeSize)
        wideMath = 0.6 * Self.screenWidth
    }

    func with(foreground: Color? = nil, mathSize: CGFloat? = nil, listDepth: Int? = nil) -> MarkdownStyle {
        var copy = self
        if let foreground { copy.foreground = foreground }
        if let mathSize { copy.mathSize = mathSize }
        if let listDepth { copy.listDepth = listDepth }
        return copy
    }

    static func pointSize(_ style: UIFont.TextStyle, _ dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
    }

    @MainActor
    static var screenWidth: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.screen.bounds.width ?? 390
    }
}

/// Parsed replies, so a transcript row that is drawn again does not parse again.
@MainActor
enum MarkdownCache {
    private final class Entry {
        let document: MDDocument
        init(_ document: MDDocument) { self.document = document }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 120
        return cache
    }()

    static func document(for text: String) -> MDDocument {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.document }
        let document = MDDocument.parse(text)
        cache.setObject(Entry(document), forKey: key)
        return document
    }
}

struct MarkdownBlocks: View {
    let blocks: [MDBlock]
    let style: MarkdownStyle
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], style: style).equatable()
            }
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MDBlock
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            MarkdownParagraph(inlines: inlines, style: style)
        case .heading(let level, let inlines):
            InlineRenderer.text(inlines, style: style)
                .font(Self.headingFont(level))
                .foregroundStyle(level == 6 ? Color.secondary : style.foreground)
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, style: style.with(foreground: .secondary))
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                }
        case .list(let list):
            MarkdownListView(list: list, style: style)
        case .rule:
            Rectangle().fill(Theme.tableBorder).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 3)
        case .table(let table):
            MarkdownTableView(table: table, style: style)
        case .math(let index):
            DisplayMathView(span: style.math[index], style: style)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        case 4: .body.weight(.semibold)
        default: .subheadline.weight(.semibold)
        }
    }
}

/// A paragraph; inline math too wide for a line (60 % of the screen) breaks out into a display block.
private struct MarkdownParagraph: View {
    let inlines: [MDInline]
    let style: MarkdownStyle

    private enum Piece {
        case text([MDInline])
        case math(Int)
    }

    var body: some View {
        let pieces = self.pieces()
        if pieces.count == 1, case .text(let run) = pieces[0] {
            line(run)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pieces.indices, id: \.self) { index in
                    switch pieces[index] {
                    case .text(let run): line(run)
                    case .math(let math): DisplayMathView(span: style.math[math], style: style)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ run: [MDInline]) -> some View {
        let text = InlineRenderer.text(run, style: style)
            .foregroundStyle(style.foreground)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
        if Self.containsMath(run) {
            // VoiceOver reads the TeX rather than "image".
            text.accessibilityLabel(Text(verbatim: MDDocument.plainText(run, math: style.math)))
        } else {
            text
        }
    }

    private static func containsMath(_ inlines: [MDInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .math: true
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                containsMath(children)
            default: false
            }
        }
    }

    private func pieces() -> [Piece] {
        let wide = inlines.contains { inline in
            guard case .math(let index) = inline else { return false }
            return MathRenderer.render(style.math[index].tex, display: false, fontSize: style.mathSize).width > style.wideMath
        }
        guard wide else { return [.text(inlines)] }
        var pieces: [Piece] = []
        var current: [MDInline] = []
        func flush() {
            while current.first == .lineBreak { current.removeFirst() }
            while current.last == .lineBreak { current.removeLast() }
            if !current.isEmpty { pieces.append(.text(current)) }
            current = []
        }
        for inline in inlines {
            if case .math(let index) = inline,
                MathRenderer.render(style.math[index].tex, display: false, fontSize: style.mathSize).width > style.wideMath
            {
                flush()
                pieces.append(.math(index))
            } else {
                current.append(inline)
            }
        }
        flush()
        return pieces
    }
}

/// Inline Markdown → one `Text`: attributed runs, with inline math as template images on the text's baseline.
@MainActor
enum InlineRenderer {
    static func text(_ inlines: [MDInline], style: MarkdownStyle) -> Text {
        var builder = Builder(style: style)
        builder.add(inlines, AttributeContainer())
        return builder.finish()
    }

    @MainActor
    private struct Builder {
        let style: MarkdownStyle
        var result: Text?
        var buffer = AttributedString()

        mutating func add(_ inlines: [MDInline], _ attributes: AttributeContainer) {
            for inline in inlines {
                switch inline {
                case .text(let text):
                    append(text, attributes)
                case .code(let code):
                    var monospaced = attributes
                    monospaced.font = .system(.callout, design: .monospaced)
                    monospaced.backgroundColor = Theme.codeBackground
                    append(code, monospaced)
                case .emphasis(let children):
                    add(children, Self.adding(.emphasized, to: attributes))
                case .strong(let children):
                    add(children, Self.adding(.stronglyEmphasized, to: attributes))
                case .strikethrough(let children):
                    var struck = attributes
                    struck.strikethroughStyle = .single
                    add(children, struck)
                case .link(let url, let children):
                    var link = attributes
                    link.link = url
                    add(children, link)
                case .lineBreak:
                    append("\n", attributes)
                case .math(let index):
                    math(style.math[index], attributes)
                }
            }
        }

        static func adding(_ intent: InlinePresentationIntent, to attributes: AttributeContainer) -> AttributeContainer {
            var copy = attributes
            copy.inlinePresentationIntent = (attributes.inlinePresentationIntent ?? []).union(intent)
            return copy
        }

        mutating func append(_ string: String, _ attributes: AttributeContainer) {
            buffer += AttributedString(string, attributes: attributes)
        }

        mutating func math(_ span: MathSpan, _ attributes: AttributeContainer) {
            let rendered = MathRenderer.render(span.tex, display: false, fontSize: style.mathSize)
            guard let image = rendered.image else {
                // TeX SwiftMath cannot draw: its source, monospaced and muted.
                var source = attributes
                source.font = .system(.callout, design: .monospaced)
                source.foregroundColor = .secondary
                append(span.source, source)
                return
            }
            flush()
            push(Text(Image(uiImage: image).renderingMode(.template)).baselineOffset(-rendered.baseline))
        }

        mutating func flush() {
            guard !buffer.characters.isEmpty else { return }
            push(Text(buffer))
            buffer = AttributedString()
        }

        mutating func push(_ piece: Text) {
            result = result.map { $0 + piece } ?? piece
        }

        mutating func finish() -> Text {
            flush()
            return result ?? Text(verbatim: "")
        }
    }
}

private struct MarkdownListView: View {
    let list: MDList
    let style: MarkdownStyle

    var body: some View {
        let nested = style.with(listDepth: style.listDepth + 1)
        let markerWidth = self.markerWidth
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: marker(item, index))
                        .monospacedDigit()
                        .foregroundStyle(item.task == true ? Theme.accent : Color.secondary)
                        .frame(minWidth: markerWidth, alignment: list.ordered && item.task == nil ? .trailing : .leading)
                    if item.blocks.isEmpty {
                        Spacer(minLength: 0)
                    } else {
                        MarkdownBlocks(blocks: item.blocks, style: nested, spacing: 6)
                    }
                }
            }
        }
    }

    private func marker(_ item: MDListItem, _ index: Int) -> String {
        if let task = item.task { return task ? "☑" : "☐" }
        if list.ordered { return "\(list.start + index)." }
        return ["•", "◦", "▪"][style.listDepth % 3]
    }

    private var markerWidth: CGFloat {
        guard list.ordered else { return 12 }
        let widest = String(repeating: "8", count: String(list.start + max(list.items.count - 1, 0)).count) + "."
        let font = UIFont.monospacedDigitSystemFont(ofSize: style.mathSize, weight: .regular)
        return ceil((widest as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MDTable
    let style: MarkdownStyle
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Cell {
        let inlines: [MDInline]
        let header: Bool
        let alignment: MDAlignment
    }

    var body: some View {
        // A table that fits keeps the bubble snug; a wider one scrolls sideways inside it.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdownTable")
    }

    private var cells: [Cell] {
        let columns = table.alignments.count
        var cells: [Cell] = []
        for column in 0..<columns {
            cells.append(Cell(inlines: table.header[column], header: true, alignment: table.alignments[column]))
        }
        for row in table.rows {
            for column in 0..<columns {
                cells.append(Cell(inlines: row[column], header: false, alignment: table.alignments[column]))
            }
        }
        return cells
    }

    private var grid: some View {
        let cellStyle = style.with(mathSize: MarkdownStyle.pointSize(.subheadline, dynamicTypeSize))
        let cells = self.cells
        return TableGridLayout(columns: max(table.alignments.count, 1), maxColumnWidth: 260, line: 1 / displayScale) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                InlineRenderer.text(cell.inlines, style: cellStyle)
                    .font(.subheadline)
                    .fontWeight(cell.header ? .semibold : nil)
                    .foregroundStyle(style.foreground)
                    .tint(Theme.accent)
                    .multilineTextAlignment(Self.textAlignment(cell.alignment))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.frameAlignment(cell.alignment))
                    .background(cell.header ? Theme.tableHeader : Theme.agentBubble)
            }
        }
        .background(Theme.tableBorder)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func textAlignment(_ alignment: MDAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func frameAlignment(_ alignment: MDAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Cells in row-major order. A column is as wide as its widest cell's single line, capped at `maxColumnWidth`
/// (longer cells wrap); a row is as tall as its tallest cell. `line`-wide gaps let the background show as grid lines.
struct TableGridLayout: Layout {
    let columns: Int
    let maxColumnWidth: CGFloat
    let line: CGFloat

    struct Cache {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { measure(subviews) }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ subviews: Subviews) -> Cache {
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(maxColumnWidth, ceil(ideal)))
        }
        let rows = (subviews.count + columns - 1) / columns
        var heights = Array(repeating: CGFloat(0), count: rows)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], ceil(height))
        }
        return Cache(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(
            width: cache.widths.reduce(0, +) + line * CGFloat(cache.widths.count + 1),
            height: cache.heights.reduce(0, +) + line * CGFloat(cache.heights.count + 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY + line
        for (row, height) in cache.heights.enumerated() {
            var x = bounds.minX + line
            for (column, width) in cache.widths.enumerated() {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
                x += width + line
            }
            y += height + line
        }
    }
}

// MARK: - Math

private struct DisplayMathView: View {
    let span: MathSpan
    let style: MarkdownStyle

    var body: some View {
        let rendered = MathRenderer.render(span.tex, display: true, fontSize: style.mathSize * 1.12)
        if let image = rendered.image {
            let picture = Image(uiImage: image)
                .renderingMode(.template)
                .foregroundStyle(style.foreground)
                .accessibilityLabel(Text(verbatim: span.tex))
            // Centred when it fits; otherwise it scrolls sideways inside the bubble.
            ViewThatFits(in: .horizontal) {
                picture.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { picture }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("displayMath")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: span.source)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// MARK: - Code

/// Highlighted code, cached by language and text (a streaming reply re-renders 30 times a second).
@MainActor
enum CodeHighlight {
    private final class Entry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 200
        return cache
    }()

    static func attributed(_ code: String, language: String?) -> AttributedString {
        guard let language, SyntaxHighlighter.knows(language) else { return AttributedString(code) }
        let key = "\(language.lowercased())\u{0}\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let text = code as NSString
        var out = AttributedString()
        var cursor = 0
        for run in SyntaxHighlighter.highlight(code, language: language) where run.location >= cursor {
            if run.location > cursor {
                out += AttributedString(text.substring(with: NSRange(location: cursor, length: run.location - cursor)))
            }
            var piece = AttributedString(text.substring(with: NSRange(location: run.location, length: run.length)))
            piece.foregroundColor = Theme.syntax(run.token)
            if run.token == .comment { piece.inlinePresentationIntent = .emphasized }
            out += piece
            cursor = run.location + run.length
        }
        if cursor < text.length { out += AttributedString(text.substring(from: cursor)) }
        cache.setObject(Entry(out), forKey: key)
        return out
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                codeBody
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codeBlock")
        .contextMenu {
            Button(action: copy) {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let language {
                Text(verbatim: language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: copy) {
                Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Theme.accent : Color.secondary)
            .accessibilityIdentifier("copyCodeButton")
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var codeBody: some View {
        if SyntaxHighlighter.grammar(for: language) === Grammars.diff {
            // Diffs line by line, so added and removed lines get a faint row behind them.
            let lines = code.components(separatedBy: "\n")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    Text(CodeHighlight.attributed(line.isEmpty ? " " : line, language: language))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.agentBubbleText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.diffBackground(line))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        } else {
            Text(CodeHighlight.attributed(code, language: language))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.agentBubbleText)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private static func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++ ") { return Theme.diffInsertedBackground }
        if line.hasPrefix("-") && !line.hasPrefix("--- ") { return Theme.diffDeletedBackground }
        return .clear
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
