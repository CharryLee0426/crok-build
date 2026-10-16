import SwiftUI

/// Renders an assistant reply: prose with inline Markdown (bold, italics, `code`, links), headings, lists and quotes;
/// fenced code blocks monospaced in a scrollable box.
struct MarkdownText: View {
    let text: String
    var foreground: Color = Theme.agentBubbleText

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .foregroundStyle(foreground)
                        .tint(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    /// Inline Markdown per line, with line-level structure (headings, bullets, quotes) applied by hand, because
    /// `Text` ignores block-level presentation intents.
    static func attributed(_ prose: String) -> AttributedString {
        var result = AttributedString()
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            var piece: AttributedString
            switch MarkdownBlocks.classify(line) {
            case .heading(let level, let text):
                piece = inline(text)
                piece.font = level <= 2 ? Font.headline : Font.subheadline.weight(.semibold)
            case .bullet(let indent, let text):
                piece = AttributedString(String(repeating: "    ", count: indent) + "•  ") + inline(text)
            case .numbered(let indent, let number, let text):
                piece = AttributedString(String(repeating: "    ", count: indent) + number + ".  ") + inline(text)
            case .quote(let text):
                piece = AttributedString("▎ ") + inline(text)
                piece.foregroundColor = Color.secondary
            case .rule:
                piece = AttributedString("———")
                piece.foregroundColor = Color.secondary
            case .text(let text):
                piece = inline(text)
            case .blank:
                piece = AttributedString()
            }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        // Inline code: monospaced with a faint background.
        for run in parsed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                parsed[run.range].font = Font.system(.callout, design: .monospaced)
                parsed[run.range].backgroundColor = Theme.codeBackground
            }
        }
        return parsed
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.agentBubbleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
        }
    }
}
