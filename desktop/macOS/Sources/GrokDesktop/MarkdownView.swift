import AppKit
import SwiftUI

/// Visual parameters shared by the SwiftUI and TextKit Markdown renderers.
struct MarkdownStyle: Equatable {
    var fontSize: CGFloat = 16
    /// Thinking uses secondary text so it reads as subordinate to the answer.
    var secondary = false
    var blockSpacing: CGFloat = 14

    static let response = MarkdownStyle()
    static let panel = MarkdownStyle(fontSize: 14, blockSpacing: 11)
    static let thinking = MarkdownStyle(fontSize: 14, secondary: true, blockSpacing: 9)

    func headingSize(_ level: Int) -> CGFloat {
        let scale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1.0, 0.95]
        return (fontSize * scale[min(max(level, 1), 6) - 1]).rounded()
    }
    var codeSize: CGFloat { (fontSize * 0.84).rounded() }
    var lineSpacing: CGFloat { (fontSize * 0.3).rounded() }
}

/// Full Markdown for replies and panels: GFM tables, task lists, callouts, LaTeX math, and
/// syntax-highlighted code. Streaming re-parses only the newest block, and each block view is
/// equatable, so earlier blocks are neither parsed nor laid out again while a reply grows.
struct MarkdownContent: View {
    var text: String
    var style: MarkdownStyle = .response
    @State private var cache = MarkdownDocumentCache()

    var body: some View {
        MarkdownBlocksView(blocks: cache.blocks(for: text), style: style)
            .textSelection(.enabled)
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A reply, drawn as one TextKit text view so a selection can run across paragraphs, lists,
/// tables, and code, and copy them together. Streaming re-renders only the newest blocks.
struct MarkdownReply: View {
    var text: String
    var style: MarkdownStyle = .response
    /// The reply is still arriving (see `ReadOnlyTextView.isStreaming`).
    var isStreaming = false

    var body: some View {
        ReadOnlyTextView(text: text, style: .reply(style), sizing: .fitContent(maxHeight: .infinity), isStreaming: isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    var spacing: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: spacing ?? style.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, style: style).equatable()
            }
        }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let style: MarkdownStyle

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.block == rhs.block }

    var body: some View {
        switch block {
        case .heading(let level, let content):
            MarkdownInlineText(inlines: content, style: style, size: style.headingSize(level), weight: level <= 3 ? .semibold : .medium)
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            MarkdownParagraphView(inlines: content, style: style)
        case .code(let language, let code, let isClosed):
            // A display-math block still streaming arrives as open LaTeX code.
            MarkdownCodeBlockView(language: language, code: code, isClosed: isClosed, fontSize: style.codeSize)
        case .math(let latex):
            MarkdownMathBlockView(latex: latex, style: style)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, style: style, spacing: style.blockSpacing * 0.7)
                .foregroundStyle(Theme.muted)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Theme.line.frame(width: 3).clipShape(Capsule()) }
        case .callout(let kind, let title, let blocks):
            MarkdownCalloutView(kind: kind, title: title, blocks: blocks, style: style)
        case .list(let list):
            MarkdownListView(list: list, style: style)
        case .table(let table):
            MarkdownTableView(table: table, style: style)
        case .thematicBreak:
            Theme.line.frame(height: 1).padding(.vertical, 6)
        case .html(let html):
            Text(html).font(.system(size: style.codeSize, design: .monospaced)).foregroundStyle(Theme.muted)
        case .footnoteDefinition(let label, let blocks):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(label).").font(.system(size: style.fontSize * 0.85, weight: .medium)).foregroundStyle(Theme.muted)
                MarkdownBlocksView(blocks: blocks, style: MarkdownStyle(fontSize: style.fontSize * 0.85, secondary: true, blockSpacing: 6))
            }
        }
    }
}

// MARK: - Inline text

/// A paragraph, split around display math written inline (`… $$x$$ …`) and shown as an
/// image when it is nothing but an image.
private struct MarkdownParagraphView: View {
    let inlines: [MarkdownInline]
    let style: MarkdownStyle

    var body: some View {
        let pieces = Self.split(inlines)
        if pieces.count == 1, case .text(let content) = pieces[0] {
            if let image = content.soleImage {
                MarkdownImageView(source: image.source, alt: image.alt)
            } else {
                MarkdownInlineText(inlines: content, style: style)
            }
        } else {
            VStack(alignment: .leading, spacing: style.blockSpacing * 0.6) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let content): MarkdownInlineText(inlines: content, style: style)
                    case .math(let latex): MarkdownMathBlockView(latex: latex, style: style)
                    }
                }
            }
        }
    }

    private enum Piece { case text([MarkdownInline]), math(String) }

    private static func split(_ inlines: [MarkdownInline]) -> [Piece] {
        var pieces: [Piece] = [], current: [MarkdownInline] = []
        func flush() {
            while let first = current.first, first.isBreak { current.removeFirst() }
            while let last = current.last, last.isBreak { current.removeLast() }
            if !current.isEmpty { pieces.append(.text(current)) }
            current = []
        }
        for inline in inlines {
            if case .displayMath(let latex) = inline { flush(); pieces.append(.math(latex)) } else { current.append(inline) }
        }
        flush()
        return pieces.isEmpty ? [.text([])] : pieces
    }
}

extension Array where Element == MarkdownInline {
    /// The image a paragraph holds when it holds nothing else; it is shown as the image itself.
    var soleImage: (source: String, alt: String)? {
        let meaningful = filter {
            if case .text(let text) = $0 { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return !$0.isBreak
        }
        guard meaningful.count == 1, case .image(let source, _, let alt) = meaningful[0] else { return nil }
        return (source, alt)
    }
}

private extension MarkdownInline {
    var isBreak: Bool {
        switch self { case .softBreak, .lineBreak: return true; default: return false }
    }
}

/// Inline Markdown as one `Text`, so selection and wrapping behave like ordinary prose.
/// Inline math is typeset to an image and sits on the text baseline.
struct MarkdownInlineText: View {
    let inlines: [MarkdownInline]
    let style: MarkdownStyle
    var size: CGFloat?
    var weight: Font.Weight = .regular
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fontSize = size ?? style.fontSize
        let segments = MarkdownInlineBuilder(fontSize: fontSize, weight: weight, secondary: style.secondary).segments(inlines)
        composed(segments, fontSize: fontSize)
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(style.secondary ? Theme.muted : Theme.ink)
            .lineSpacing(style.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composed(_ segments: [MarkdownInlineBuilder.Segment], fontSize: CGFloat) -> Text {
        if segments.count == 1, case .text(let run) = segments[0] { return Text(run) }
        let color = MarkdownColors.resolved(style.secondary ? .secondaryLabelColor : .labelColor, dark: colorScheme == .dark)
        return segments.reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .text(let run):
                return Text("\(text)\(Text(run))")
            case .symbol(let name):
                return Text("\(text)\(Text(Image(systemName: name)))")
            case .math(let latex):
                guard let math = MathRenderer.render(latex, fontSize: fontSize * 1.05, color: color, display: false) else {
                    return Text("\(text)\(Text(MarkdownInlineBuilder.codeRun("$\(latex)$", fontSize: fontSize)))")
                }
                let image = Text(Image(nsImage: math.image)).baselineOffset(-math.descent)
                return Text("\(text)\(image)")
            }
        }
    }
}

/// Converts inline nodes into styled runs for SwiftUI `Text`.
struct MarkdownInlineBuilder {
    enum Segment { case text(AttributedString), math(String), symbol(String) }

    let fontSize: CGFloat
    var weight: Font.Weight = .regular
    var secondary = false

    private struct Traits {
        var bold = false, italic = false, strike = false, superscript = false
        var link: URL?
    }

    /// Formatting tags that carry no text of their own. Other inline HTML stays visible.
    private static let silentTags: Set<String> = ["kbd", "sup", "sub", "span", "b", "i", "u", "em", "strong", "small", "mark", "ins", "del", "s", "abbr", "cite", "q", "font", "code", "tt", "var", "samp", "a", "details", "summary", "center", "div", "p"]

    func segments(_ inlines: [MarkdownInline]) -> [Segment] {
        var result: [Segment] = []
        var run = AttributedString()
        func flushRun() { if !run.characters.isEmpty { result.append(.text(run)); run = AttributedString() } }
        func visit(_ inlines: [MarkdownInline], _ traits: Traits) {
            for inline in inlines {
                switch inline {
                case .text(let text): run.append(styled(text, traits))
                case .emphasis(let children): var next = traits; next.italic = true; visit(children, next)
                case .strong(let children): var next = traits; next.bold = true; visit(children, next)
                case .strikethrough(let children): var next = traits; next.strike = true; visit(children, next)
                case .code(let code):
                    var piece = Self.codeRun(code, fontSize: fontSize)
                    if let link = traits.link { piece.link = link; piece.foregroundColor = Theme.accent }
                    run.append(piece)
                case .math(let latex), .displayMath(let latex):
                    flushRun(); result.append(.math(latex))
                case .link(let destination, _, let children):
                    var next = traits; next.link = Self.url(destination)
                    if children.isEmpty { run.append(styled(destination, next)) } else { visit(children, next) }
                case .image(let source, _, let alt):
                    flushRun(); result.append(.symbol("photo"))
                    var next = traits; next.link = Self.url(source)
                    run.append(styled(" " + (alt.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : alt), next))
                case .footnoteReference(let label):
                    var next = traits; next.superscript = true
                    run.append(styled("[\(label)]", next))
                case .html(let html):
                    let name = html.trimmingCharacters(in: CharacterSet(charactersIn: "</> ")).split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init)?.lowercased() ?? ""
                    if !Self.silentTags.contains(name) { run.append(styled(html, traits)) }
                case .softBreak, .lineBreak:
                    // Chat replies use single newlines as line breaks, as GitHub comments do.
                    run.append(styled("\n", traits))
                }
            }
        }
        visit(inlines, Traits())
        flushRun()
        return result.isEmpty ? [.text(AttributedString())] : result
    }

    private func styled(_ text: String, _ traits: Traits) -> AttributedString {
        var piece = AttributedString(text)
        let size = traits.superscript ? fontSize * 0.72 : fontSize
        var font = Font.system(size: size, weight: traits.bold ? Font.Weight.heavier(weight, .semibold) : weight)
        if traits.italic { font = font.italic() }
        piece.font = font
        if traits.superscript { piece.baselineOffset = fontSize * 0.35 }
        if traits.strike { piece.strikethroughStyle = .single }
        if let link = traits.link {
            piece.link = link
            piece.foregroundColor = Theme.accent
        }
        return piece
    }

    static func codeRun(_ code: String, fontSize: CGFloat) -> AttributedString {
        // Non-breaking spaces keep the padding attached to the code.
        var piece = AttributedString("\u{2009}" + code + "\u{2009}")
        piece.font = .system(size: (fontSize * 0.88).rounded(), design: .monospaced)
        piece.backgroundColor = Theme.inlineCode
        return piece
    }

    static func url(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.hasPrefix("www.") { return URL(string: "https://" + trimmed) }
        return URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed)
    }
}

private extension Font.Weight {
    static func heavier(_ lhs: Font.Weight, _ rhs: Font.Weight) -> Font.Weight {
        let order: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return (order.firstIndex(of: lhs) ?? 3) >= (order.firstIndex(of: rhs) ?? 3) ? lhs : rhs
    }
}

enum MarkdownColors {
    /// A dynamic system colour resolved for one appearance, for rendering math images.
    static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var result = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}

// MARK: - Blocks

private struct MarkdownListView: View {
    let list: MarkdownList
    let style: MarkdownStyle
    @Environment(\.markdownListDepth) private var depth

    var body: some View {
        VStack(alignment: .leading, spacing: list.isTight ? style.fontSize * 0.35 : style.blockSpacing * 0.8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    MarkdownBlocksView(blocks: item.content, style: style, spacing: list.isTight ? style.fontSize * 0.35 : style.blockSpacing * 0.8)
                        .environment(\.markdownListDepth, depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        let color = style.secondary ? Theme.muted : Theme.ink
        if let done = item.task {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: style.fontSize * 0.95))
                .foregroundStyle(done ? Theme.accent : Theme.muted)
                .frame(minWidth: style.fontSize * 1.1, alignment: .leading)
                .accessibilityLabel(done ? "Completed" : "Not completed")
        } else if list.ordered {
            Text(verbatim: "\(list.start + index).")
                .font(.system(size: style.fontSize).monospacedDigit())
                .foregroundStyle(color.opacity(0.75))
                .frame(minWidth: style.fontSize * (list.start + list.items.count > 9 ? 1.6 : 1.1), alignment: .trailing)
        } else {
            Text(verbatim: ["•", "◦", "▪︎"][depth % 3])
                .font(.system(size: style.fontSize, weight: .bold))
                .foregroundStyle(color.opacity(0.6))
                .frame(minWidth: style.fontSize * 0.8, alignment: .center)
        }
    }
}

private struct MarkdownListDepthKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var markdownListDepth: Int {
        get { self[MarkdownListDepthKey.self] }
        set { self[MarkdownListDepthKey.self] = newValue }
    }
}

private struct MarkdownCalloutView: View {
    let kind: String
    let title: String?
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle

    private var appearance: (label: String, symbol: String, color: Color) {
        switch kind {
        case "tip": return ("Tip", "lightbulb", Theme.green)
        case "important": return ("Important", "exclamationmark.bubble", .purple)
        case "warning": return ("Warning", "exclamationmark.triangle", .orange)
        case "caution": return ("Caution", "exclamationmark.octagon", .red)
        default: return ("Note", "info.circle", .blue)
        }
    }

    var body: some View {
        let look = appearance
        VStack(alignment: .leading, spacing: style.blockSpacing * 0.6) {
            Label(title ?? look.label, systemImage: look.symbol)
                .font(.system(size: style.fontSize * 0.9, weight: .semibold))
                .foregroundStyle(look.color)
            MarkdownBlocksView(blocks: blocks, style: style, spacing: style.blockSpacing * 0.7)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { look.color.opacity(0.8).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MarkdownCodeBlockView: View, Equatable {
    let language: String?
    let code: String
    var isClosed = true
    var fontSize: CGFloat = 13
    /// Past this size a block is shown in a text view that lays out and draws only what is visible.
    static let largeCodeLength = 12_000

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.isClosed == rhs.isClosed && lhs.fontSize == rhs.fontSize
            && lhs.code.utf8.count == rhs.code.utf8.count && lhs.code == rhs.code
    }

    var body: some View {
        let resolved = language.flatMap(SyntaxHighlighter.language(for:)) ?? (language == nil && isClosed ? SyntaxHighlighter.detectLanguage(code) : nil)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(resolved?.displayName ?? language ?? "Code").font(.system(size: 12, weight: .medium))
                if !isClosed { ProgressView().controlSize(.mini) }
                Spacer()
                CopyButton(text: code)
            }
            .foregroundStyle(Theme.muted).padding(.leading, 13).padding(.trailing, 6).frame(height: 34)
            Theme.line.opacity(0.4).frame(height: 0.5)
            if code.utf16.count > Self.largeCodeLength {
                ReadOnlyTextView(text: code, style: .code(language: isClosed ? resolved?.id : nil), wrapsLines: false, sizing: .fitContent(maxHeight: 560))
                    .padding(.vertical, 10).padding(.leading, 13)
            } else {
                ScrollView(.horizontal) {
                    Text(SyntaxHighlighter.swiftUIAttributedString(code, language: resolved))
                        .font(.system(size: fontSize, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.horizontal, 13).padding(.vertical, 11)
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(resolved?.displayName ?? "Code") block")
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12)).padding(.horizontal, 7).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(copied ? "Copied" : label)
    }
}

struct MarkdownMathBlockView: View {
    let latex: String
    let style: MarkdownStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = MarkdownColors.resolved(style.secondary ? .secondaryLabelColor : .labelColor, dark: colorScheme == .dark)
        if let math = MathRenderer.render(latex, fontSize: style.fontSize * 1.12, color: color, display: true) {
            let image = Image(nsImage: math.image)
                .accessibilityLabel(latex)
                .contextMenu {
                    Button("Copy LaTeX") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latex, forType: .string) }
                }
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal) { image.padding(.vertical, 2) }
            }
            .padding(.vertical, 4)
            .help(latex)
        } else {
            MarkdownCodeBlockView(language: "latex", code: latex, fontSize: style.codeSize)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle

    var body: some View {
        // In the middle when it fits, as display math is; a wider table scrolls sideways.
        ViewThatFits(in: .horizontal) {
            grid.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
            ScrollView(.horizontal) { grid }.scrollIndicators(.automatic)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    self.cell(cell, column: column, header: true)
                }
            }
            .background(Theme.tableHeader)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                Theme.line.opacity(0.45).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column, header: false)
                    }
                }
                .background(index % 2 == 1 ? Theme.tableStripe : Color.clear)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(1)
    }

    private func cell(_ content: [MarkdownInline], column: Int, header: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .none
        let horizontal: HorizontalAlignment = alignment == .center ? .center : alignment == .right ? .trailing : .leading
        return MarkdownCappedWidth(maxWidth: 340) {
            MarkdownInlineText(inlines: content, style: MarkdownStyle(fontSize: style.fontSize * 0.92, secondary: style.secondary),
                               weight: header ? .semibold : .regular)
                .multilineTextAlignment(alignment == .center ? .center : alignment == .right ? .trailing : .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: horizontal, vertical: .top))
        .gridColumnAlignment(horizontal)
        .overlay(alignment: .trailing) {
            if column < table.header.count - 1 { Theme.line.opacity(0.35).frame(width: 0.5) }
        }
    }
}

/// Gives content its ideal width up to a cap, so long table cells wrap instead of running on.
struct MarkdownCappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct MarkdownImageView: View {
    let source: String
    let alt: String
    @State private var local: NSImage?
    @State private var failed = false

    private var url: URL? { MarkdownInlineBuilder.url(source) }

    var body: some View {
        Group {
            if let url, !url.isFileURL, ["http", "https"].contains(url.scheme ?? "") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: placeholder
                    default: ProgressView().frame(height: 80)
                    }
                }
            } else if let local {
                Image(nsImage: local).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(maxWidth: 560, maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
        .help(alt.isEmpty ? source : alt)
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .frame(maxWidth: .infinity)
        .task(id: source) {
            guard let url, url.isFileURL else { return }
            let image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            local = image; failed = image == nil
        }
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: failed ? "photo.badge.exclamationmark" : "photo")
            .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(10)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
