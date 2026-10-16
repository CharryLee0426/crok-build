import Foundation

/// Splits an assistant reply into prose and fenced code blocks. Prose keeps its inline Markdown (rendered with
/// `AttributedString(markdown:)`); code is shown monospaced. An unclosed fence (a reply still streaming) runs to the
/// end of the text.
enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, code: String)
}

enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: Substring?
        var language: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                    code.removeAll()
                    fence = nil
                    language = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let marker = trimmed.first!
                let run = trimmed.prefix(while: { $0 == marker })
                fence = run
                let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
                language = info.isEmpty ? nil : String(info.split(separator: " ").first ?? "")
                continue
            }
            if trimmed.isEmpty {
                flushProse()
            } else {
                prose.append(line)
            }
        }
        if fence != nil {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return blocks
    }

    /// One prose line, classified for rendering.
    enum Line: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case quote(String)
        case rule
        case text(String)
        case blank
    }

    static func classify(_ line: String) -> Line {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        if body.isEmpty { return .blank }
        if body.hasPrefix("#") {
            let hashes = body.prefix(while: { $0 == "#" }).count
            let rest = body.dropFirst(hashes)
            if hashes <= 6, rest.first == " " { return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces)) }
        }
        if body == "---" || body == "***" || body == "___" { return .rule }
        if let first = body.first, first == "-" || first == "*" || first == "+", body.dropFirst().first == " " {
            return .bullet(indent: indent / 2, text: String(body.dropFirst(2)))
        }
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let marker = after.first, marker == "." || marker == ")", after.dropFirst().first == " " {
                return .numbered(indent: indent / 2, number: String(digits), text: String(after.dropFirst(2)))
            }
        }
        if body.hasPrefix(">") { return .quote(body.dropFirst().trimmingCharacters(in: .whitespaces)) }
        return .text(String(line))
    }
}
