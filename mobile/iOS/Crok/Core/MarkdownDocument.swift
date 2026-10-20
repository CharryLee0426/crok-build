import Foundation
import Markdown

/// An assistant reply parsed for rendering (relay/DESIGN.md §5 "Replies in Markdown"): math is found first
/// (`MathExtractor`), then swift-markdown (cmark-gfm) parses CommonMark + GFM, and the tree is turned into these few
/// value types, which the views draw and the tests check.
struct MDDocument: Equatable, Sendable {
    var blocks: [MDBlock]
    var math: [MathSpan]
}

indirect enum MDBlock: Equatable, Sendable {
    case paragraph([MDInline])
    case heading(level: Int, [MDInline])
    case code(language: String?, code: String)
    case quote([MDBlock])
    case list(MDList)
    case rule
    case table(MDTable)
    /// Display math: an index into `MDDocument.math`.
    case math(Int)
}

struct MDList: Equatable, Sendable {
    var ordered: Bool
    var start: Int
    var items: [MDListItem]
}

struct MDListItem: Equatable, Sendable {
    /// Nil for an ordinary item; a task item is ☐ (false) or ☑ (true).
    var task: Bool?
    var blocks: [MDBlock]
}

enum MDAlignment: Equatable, Sendable {
    case leading, center, trailing
}

struct MDTable: Equatable, Sendable {
    var alignments: [MDAlignment]
    var header: [[MDInline]]
    var rows: [[[MDInline]]]
}

indirect enum MDInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strikethrough([MDInline])
    /// Only http, https and mailto links; anything else (often a path on the computer) is plain text.
    case link(URL, [MDInline])
    case lineBreak
    /// Inline math: an index into `MDDocument.math`.
    case math(Int)
}

extension MDDocument {
    static func parse(_ text: String) -> MDDocument {
        let extraction = MathExtractor.extract(text)
        // Smart punctuation off: `--flag` and "quotes" stay as the agent wrote them.
        let document = Markdown.Document(parsing: extraction.text, options: [.disableSmartOpts, .disableSourcePosOpts])
        let converter = MDConverter(math: extraction.spans)
        return MDDocument(blocks: converter.blocks(document.children), math: extraction.spans)
    }

    /// The text without markup, math as its TeX (for VoiceOver).
    static func plainText(_ inlines: [MDInline], math: [MathSpan]) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let text), .code(let text): out += text
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                out += plainText(children, math: math)
            case .lineBreak: out += "\n"
            case .math(let index): out += index < math.count ? math[index].tex : ""
            }
        }
        return out
    }
}

private struct MDConverter {
    let math: [MathSpan]
    /// Inside a link's text, bare URLs are not linked again.
    var inLink = false

    func blocks(_ children: MarkupChildren) -> [MDBlock] {
        children.flatMap { block($0) }
    }

    func block(_ markup: Markup) -> [MDBlock] {
        switch markup {
        case let paragraph as Markdown.Paragraph:
            return self.paragraph(paragraph.children)
        case let heading as Markdown.Heading:
            return [.heading(level: heading.level, inlines(heading.children))]
        case let code as Markdown.CodeBlock:
            var body = restore(code.code)
            if body.hasSuffix("\n") { body.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return [.code(language: language?.isEmpty == false ? language : nil, code: body)]
        case let quote as Markdown.BlockQuote:
            return [.quote(blocks(quote.children))]
        case let list as Markdown.OrderedList:
            return [.list(MDList(ordered: true, start: Int(list.startIndex), items: items(list.listItems)))]
        case let list as Markdown.UnorderedList:
            return [.list(MDList(ordered: false, start: 1, items: items(list.listItems)))]
        case is Markdown.ThematicBreak:
            return [.rule]
        case let table as Markdown.Table:
            return [.table(self.table(table))]
        case let html as Markdown.HTMLBlock:
            let inlines = htmlInlines(html.rawHTML.trimmingCharacters(in: .newlines))
            return inlines.isEmpty ? [] : [.paragraph(inlines)]
        default:
            // Directives and other extensions are not enabled; anything else shows as its text.
            let text = restore(markup.format()).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.paragraph([.text(text)])]
        }
    }

    /// A paragraph, split where a display-math placeholder sits: that math ends its line and stands on its own.
    func paragraph(_ children: MarkupChildren) -> [MDBlock] {
        var out: [MDBlock] = []
        var current: [MDInline] = []
        func flush() {
            while current.first == .lineBreak { current.removeFirst() }
            while current.last == .lineBreak { current.removeLast() }
            if case .text(let text)? = current.first, text.allSatisfy(\.isWhitespace) { current.removeFirst() }
            if case .text(let text)? = current.last, text.allSatisfy(\.isWhitespace) { current.removeLast() }
            if !current.isEmpty { out.append(.paragraph(current)) }
            current = []
        }
        for child in children {
            if let text = child as? Markdown.Text {
                for segment in MathExtractor.segments(text.string, spanCount: math.count) {
                    switch segment {
                    case .text(let piece): current.append(contentsOf: linkedText(piece))
                    case .math(let index, display: false): current.append(.math(index))
                    case .math(let index, display: true):
                        flush()
                        out.append(.math(index))
                    }
                }
            } else {
                current.append(contentsOf: inline(child))
            }
        }
        flush()
        return out
    }

    func inlines(_ children: MarkupChildren) -> [MDInline] {
        children.flatMap { inline($0) }
    }

    func inline(_ markup: Markup) -> [MDInline] {
        switch markup {
        case let text as Markdown.Text:
            return MathExtractor.segments(text.string, spanCount: math.count).flatMap { segment -> [MDInline] in
                switch segment {
                case .text(let piece): linkedText(piece)
                case .math(let index, _): [.math(index)]
                }
            }
        case is Markdown.SoftBreak, is Markdown.LineBreak:
            return [.lineBreak]
        case let code as Markdown.InlineCode:
            return [.code(restore(code.code))]
        case let emphasis as Markdown.Emphasis:
            return [.emphasis(inlines(emphasis.children))]
        case let strong as Markdown.Strong:
            return [.strong(inlines(strong.children))]
        case let strike as Markdown.Strikethrough:
            return [.strikethrough(inlines(strike.children))]
        case let link as Markdown.Link:
            var linkText = self
            linkText.inLink = true
            let children = linkText.inlines(link.children)
            guard let url = Self.safeURL(restore(link.destination ?? "")) else { return children }
            return [.link(url, children)]
        case let image as Markdown.Image:
            // Images are never fetched (an agent could leak data through the URL): a link "🖼 alt" instead.
            let source = restore(image.source ?? "")
            let alt = restore(image.plainText).trimmingCharacters(in: .whitespaces)
            let label = MDInline.text("🖼 " + (alt.isEmpty ? source : alt))
            guard let url = Self.safeURL(source) else { return [label] }
            return [.link(url, [label])]
        case let html as Markdown.InlineHTML:
            return Self.isBreak(html.rawHTML) ? [.lineBreak] : [.text(restore(html.rawHTML))]
        case let symbol as Markdown.SymbolLink:
            return [.code(symbol.destination ?? "")]
        default:
            let text = (markup as? PlainTextConvertibleMarkup)?.plainText ?? markup.format()
            return [.text(restore(text))]
        }
    }

    func items(_ listItems: some Sequence<Markdown.ListItem>) -> [MDListItem] {
        listItems.map { item in
            let task: Bool? =
                switch item.checkbox {
                case .checked?: true
                case .unchecked?: false
                case nil: nil
                }
            return MDListItem(task: task, blocks: blocks(item.children))
        }
    }

    func table(_ table: Markdown.Table) -> MDTable {
        let columns = max(table.maxColumnCount, 1)
        func padded(_ cells: [[MDInline]]) -> [[MDInline]] {
            cells.count >= columns ? Array(cells.prefix(columns)) : cells + Array(repeating: [], count: columns - cells.count)
        }
        func row(_ cells: some Sequence<Markdown.Table.Cell>) -> [[MDInline]] {
            padded(cells.map { $0.colspan == 0 ? [] : inlines($0.children) })
        }
        var alignments = table.columnAlignments.map { alignment -> MDAlignment in
            switch alignment {
            case .center?: .center
            case .right?: .trailing
            default: .leading
            }
        }
        if alignments.count < columns { alignments += Array(repeating: .leading, count: columns - alignments.count) }
        return MDTable(
            alignments: Array(alignments.prefix(columns)), header: row(table.head.cells),
            rows: table.body.rows.map { row($0.cells) })
    }

    /// Raw HTML is shown as its text; `<br>` is a line break.
    func htmlInlines(_ raw: String) -> [MDInline] {
        var out: [MDInline] = []
        let text = restore(raw)
        let lines = text.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { out.append(.lineBreak) }
            var rest = Substring(line)
            while let range = rest.range(of: #"<br\s*/?>"#, options: [.regularExpression, .caseInsensitive]) {
                if range.lowerBound > rest.startIndex { out.append(.text(String(rest[..<range.lowerBound]))) }
                out.append(.lineBreak)
                rest = rest[range.upperBound...]
            }
            if !rest.isEmpty { out.append(.text(String(rest))) }
        }
        return out
    }

    /// Plain text, with bare URLs linked the way GFM's autolink extension does (cmark's is not enabled here).
    func linkedText(_ piece: String) -> [MDInline] {
        guard !inLink, let regex = Self.bareURL else { return [.text(piece)] }
        let string = piece as NSString
        var out: [MDInline] = []
        var cursor = 0
        for match in regex.matches(in: piece, range: NSRange(location: 0, length: string.length)) {
            var candidate = string.substring(with: match.range)
            // Trailing punctuation ends the sentence, not the URL; so does a ")" without its "(".
            while let last = candidate.last {
                if "?!.,:;*_~'\"".contains(last) {
                    candidate.removeLast()
                } else if last == ")", candidate.filter({ $0 == "(" }).count < candidate.filter({ $0 == ")" }).count {
                    candidate.removeLast()
                } else {
                    break
                }
            }
            let length = (candidate as NSString).length
            let destination = candidate.lowercased().hasPrefix("www.") ? "http://" + candidate : candidate
            guard length > 0, let url = Self.safeURL(destination), url.host?.contains(".") == true else { continue }
            if match.range.location > cursor {
                out.append(.text(string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            out.append(.link(url, [.text(candidate)]))
            cursor = match.range.location + length
        }
        if cursor < string.length { out.append(.text(string.substring(from: cursor))) }
        return out
    }

    private static let bareURL = try? NSRegularExpression(
        pattern: #"(?<![\w/.@])(?:https?://|www\.)[^\s<]+"#, options: [.caseInsensitive])

    func restore(_ text: String) -> String {
        MathExtractor.restore(text, spans: math)
    }

    static func isBreak(_ html: String) -> Bool {
        html.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func safeURL(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return url
    }
}
