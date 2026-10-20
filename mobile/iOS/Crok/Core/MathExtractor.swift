import Foundation

/// One piece of LaTeX math found in a reply.
struct MathSpan: Equatable, Sendable {
    /// The TeX between the delimiters, trimmed.
    let tex: String
    /// `$$…$$` on its own line or `\[…\]`: a centred block of its own. Otherwise math in the text.
    let display: Bool
    /// The span as written, delimiters included; put back wherever math cannot render (code, a link URL, raw HTML).
    let source: String
}

/// A reply with its math swapped for placeholders.
struct MathExtraction: Equatable, Sendable {
    let text: String
    let spans: [MathSpan]
}

/// Finds math before Markdown parsing (relay/DESIGN.md §5 "Replies in Markdown", rules 1–7): otherwise `\(` would lose
/// its backslash and `_` / `*` in TeX would turn into emphasis. Each span becomes a placeholder the parser treats as an
/// ordinary word — inline `U+E000 <index> U+E001`, display `U+E002 <index> U+E003` — which the renderer swaps back.
/// The web (relay/lib) and Android implement the same scanner.
enum MathExtractor {
    static let inlineOpen: Unicode.Scalar = "\u{E000}"
    static let inlineClose: Unicode.Scalar = "\u{E001}"
    static let displayOpen: Unicode.Scalar = "\u{E002}"
    static let displayClose: Unicode.Scalar = "\u{E003}"

    static func extract(_ source: String) -> MathExtraction {
        let s = Array(source.unicodeScalars)
        let n = s.count
        var out = String.UnicodeScalarView()
        var spans: [MathSpan] = []
        var i = 0
        var atLineStart = true
        var fence: (marker: Unicode.Scalar, count: Int)?

        func emit(_ tex: String, display: Bool, from start: Int, to end: Int) {
            out.append(display ? displayOpen : inlineOpen)
            out.append(contentsOf: String(spans.count).unicodeScalars)
            out.append(display ? displayClose : inlineClose)
            spans.append(MathSpan(tex: tex, display: display, source: String(String.UnicodeScalarView(s[start..<end]))))
        }

        while i < n {
            if atLineStart {
                atLineStart = false
                let end = lineEnd(s, from: i)
                let content = contentStart(s, from: i, to: end)
                if let open = fence {
                    // Rule 1: everything up to the closing fence is copied untouched.
                    if isClosingFence(s, at: content, end: end, open) { fence = nil }
                    out.append(contentsOf: s[i..<end])
                    i = end
                    continue
                }
                if let opened = openingFence(s, at: content, end: end) {
                    fence = opened
                    out.append(contentsOf: s[i..<end])
                    i = end
                    continue
                }
            }
            let c = s[i]
            switch c {
            case "\n":
                out.append(c)
                i += 1
                atLineStart = true
            case "\\":
                guard i + 1 < n else {
                    out.append(c)
                    i += 1
                    break
                }
                let d = s[i + 1]
                if d == "(" || d == "[" {
                    // Rule 3: `\[…\]` is always display math, `\(…\)` always inline.
                    if let close = backslashClose(s, from: i + 2, close: d == "(" ? ")" : "]"),
                        let tex = texContent(s, from: i + 2, to: close, opener: i)
                    {
                        emit(tex, display: d == "[", from: i, to: close + 2)
                        i = close + 2
                        break
                    }
                }
                if d == "\n" {
                    // A hard line break: the newline still starts the next line.
                    out.append(c)
                    i += 1
                } else {
                    // Rule 1: an escape is copied as is (`\$` stays a dollar for the parser to unescape).
                    out.append(c)
                    out.append(d)
                    i += 2
                }
            case "`":
                var run = 0
                while i + run < n && s[i + run] == "`" { run += 1 }
                if let end = codeSpanEnd(s, from: i + run, run: run) {
                    out.append(contentsOf: s[i..<end])
                    i = end
                } else {
                    out.append(contentsOf: s[i..<(i + run)])
                    i += run
                }
            case "$":
                if i + 1 < n && s[i + 1] == "$" {
                    // Rule 2: `$$` to the next `$$`; a block when it has its line(s) to itself.
                    if let close = doubleDollarClose(s, from: i + 2), let tex = texContent(s, from: i + 2, to: close, opener: i) {
                        let display = startsLine(s, at: i) && onlySpacesToLineEnd(s, from: close + 2)
                        emit(tex, display: display, from: i, to: close + 2)
                        i = close + 2
                    } else {
                        out.append(c)
                        out.append(c)
                        i += 2
                    }
                } else if let close = singleDollarClose(s, from: i + 1), let tex = texContent(s, from: i + 1, to: close, opener: i) {
                    // Rule 4: the pandoc rule, so money and shell variables stay dollars.
                    emit(tex, display: false, from: i, to: close + 1)
                    i = close + 1
                } else {
                    out.append(c)
                    i += 1
                }
            default:
                out.append(c)
                i += 1
            }
        }
        return MathExtraction(text: String(out), spans: spans)
    }

    /// Puts the original source back for every placeholder in `text` (for code, link URLs and raw HTML).
    static func restore(_ text: String, spans: [MathSpan]) -> String {
        guard !spans.isEmpty, text.unicodeScalars.contains(where: { $0 == inlineOpen || $0 == displayOpen }) else { return text }
        var out = String.UnicodeScalarView()
        for segment in segments(text, spanCount: spans.count) {
            switch segment {
            case .text(let piece): out.append(contentsOf: piece.unicodeScalars)
            case .math(let index, _): out.append(contentsOf: spans[index].source.unicodeScalars)
            }
        }
        return String(out)
    }

    enum Segment: Equatable, Sendable {
        case text(String)
        case math(Int, display: Bool)
    }

    /// Splits text at its placeholders. A malformed placeholder (or an index out of range) stays text.
    static func segments(_ text: String, spanCount: Int) -> [Segment] {
        let s = Array(text.unicodeScalars)
        guard s.contains(where: { $0 == inlineOpen || $0 == displayOpen }) else { return text.isEmpty ? [] : [.text(text)] }
        var result: [Segment] = []
        var buffer = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == inlineOpen || c == displayOpen {
                let close = c == inlineOpen ? inlineClose : displayClose
                var j = i + 1
                var value = 0
                while j < s.count && isDigit(s[j]) && value < 1_000_000 {
                    value = value * 10 + Int(s[j].value - 48)
                    j += 1
                }
                if j > i + 1, j < s.count, s[j] == close, value < spanCount {
                    if !buffer.isEmpty {
                        result.append(.text(String(buffer)))
                        buffer = String.UnicodeScalarView()
                    }
                    result.append(.math(value, display: c == displayOpen))
                    i = j + 1
                    continue
                }
            }
            buffer.append(c)
            i += 1
        }
        if !buffer.isEmpty { result.append(.text(String(buffer))) }
        return result
    }

    // MARK: - Scanning helpers

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    /// Index of the line's "\n" (or the end).
    private static func lineEnd(_ s: [Unicode.Scalar], from: Int) -> Int {
        var i = from
        while i < s.count && s[i] != "\n" { i += 1 }
        return i
    }

    private static func lineStart(_ s: [Unicode.Scalar], before index: Int) -> Int {
        var i = index
        while i > 0 && s[i - 1] != "\n" { i -= 1 }
        return i
    }

    /// Where a line's content starts after leading spaces, `>` markers and a list marker (never past `end`).
    private static func contentStart(_ s: [Unicode.Scalar], from: Int, to end: Int) -> Int {
        var i = from
        func skipSpaces() { while i < end && isSpace(s[i]) { i += 1 } }
        skipSpaces()
        while i < end && s[i] == ">" {
            i += 1
            skipSpaces()
        }
        // A list marker: -, *, + or 1–9 digits with . or ), then a space.
        var j = i
        if j < end && (s[j] == "-" || s[j] == "*" || s[j] == "+") {
            j += 1
        } else {
            var digits = 0
            while j < end && isDigit(s[j]) && digits < 9 {
                j += 1
                digits += 1
            }
            if digits > 0 && j < end && (s[j] == "." || s[j] == ")") { j += 1 } else { j = i }
        }
        if j > i && j < end && isSpace(s[j]) {
            i = j
            skipSpaces()
        }
        return i
    }

    /// The number of `>` markers at the start of the line holding `index`.
    private static func quoteDepth(_ s: [Unicode.Scalar], lineOf index: Int) -> Int {
        var i = lineStart(s, before: index)
        var depth = 0
        while i < s.count {
            if isSpace(s[i]) {
                i += 1
            } else if s[i] == ">" {
                depth += 1
                i += 1
            } else {
                break
            }
        }
        return depth
    }

    private static func openingFence(_ s: [Unicode.Scalar], at start: Int, end: Int) -> (marker: Unicode.Scalar, count: Int)? {
        guard start < end, s[start] == "`" || s[start] == "~" else { return nil }
        let marker = s[start]
        var i = start
        while i < end && s[i] == marker { i += 1 }
        let count = i - start
        guard count >= 3 else { return nil }
        // A backtick fence's info string has no backticks (otherwise it is inline code).
        if marker == "`" && s[i..<end].contains("`") { return nil }
        return (marker, count)
    }

    private static func isClosingFence(_ s: [Unicode.Scalar], at start: Int, end: Int, _ open: (marker: Unicode.Scalar, count: Int)) -> Bool {
        var i = start
        while i < end && s[i] == open.marker { i += 1 }
        guard i - start >= open.count else { return false }
        while i < end && isSpace(s[i]) { i += 1 }
        return i == end
    }

    /// Whether the line from `index` on is blank (spaces and `>` markers only).
    private static func isBlankLine(_ s: [Unicode.Scalar], from index: Int) -> Bool {
        var i = index
        while i < s.count && s[i] != "\n" {
            if !isSpace(s[i]) && s[i] != ">" && s[i] != "\r" { return false }
            i += 1
        }
        return true
    }

    /// Index after the closing run of exactly `run` backticks, not across a blank line.
    private static func codeSpanEnd(_ s: [Unicode.Scalar], from: Int, run: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == "\n" {
                if isBlankLine(s, from: i + 1) { return nil }
                i += 1
            } else if s[i] == "`" {
                var j = i
                while j < s.count && s[j] == "`" { j += 1 }
                if j - i == run { return j }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the `\` of the closing `\)` / `\]`, single newlines allowed, not a blank line.
    private static func backslashClose(_ s: [Unicode.Scalar], from: Int, close: Unicode.Scalar) -> Int? {
        var i = from
        while i < s.count {
            let c = s[i]
            if c == "\n" {
                if isBlankLine(s, from: i + 1) { return nil }
                i += 1
            } else if c == "\\" {
                if i + 1 < s.count && s[i + 1] == close { return i }
                i += 2
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the closing `$$`, single newlines allowed, not a blank line.
    private static func doubleDollarClose(_ s: [Unicode.Scalar], from: Int) -> Int? {
        var i = from
        while i < s.count {
            let c = s[i]
            if c == "\n" {
                if isBlankLine(s, from: i + 1) { return nil }
                i += 1
            } else if c == "\\" {
                i += 2
            } else if c == "$" && i + 1 < s.count && s[i + 1] == "$" {
                return i
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the `$` closing inline math opened just before `from` (rule 4), on the same line.
    private static func singleDollarClose(_ s: [Unicode.Scalar], from: Int) -> Int? {
        guard from < s.count, !isWhitespace(s[from]) else { return nil }
        var i = from
        while i < s.count {
            let c = s[i]
            // The search stops at a backtick: a closer is never taken from inside a later code span.
            if c == "\n" || c == "`" { return nil }
            if c == "\\" {
                i += 2
                continue
            }
            if c == "$" && i > from && !isWhitespace(s[i - 1]) && !(i + 1 < s.count && isDigit(s[i + 1])) {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Whether only spaces, `>` markers or a list marker come before `index` on its line.
    private static func startsLine(_ s: [Unicode.Scalar], at index: Int) -> Bool {
        let start = lineStart(s, before: index)
        return contentStart(s, from: start, to: index) == index
    }

    private static func onlySpacesToLineEnd(_ s: [Unicode.Scalar], from: Int) -> Bool {
        var i = from
        while i < s.count && s[i] != "\n" {
            if !isSpace(s[i]) && s[i] != "\r" { return false }
            i += 1
        }
        return true
    }

    /// Rule 5: the trimmed TeX; continuation lines drop as many `>` markers as the opening line had. Nil when empty.
    private static func texContent(_ s: [Unicode.Scalar], from: Int, to end: Int, opener: Int) -> String? {
        let depth = quoteDepth(s, lineOf: opener)
        var lines = String(String.UnicodeScalarView(s[from..<end])).components(separatedBy: "\n")
        if depth > 0 {
            for index in lines.indices.dropFirst() {
                var line = Substring(lines[index])
                for _ in 0..<depth {
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                    guard trimmed.first == ">" else { break }
                    line = trimmed.dropFirst()
                    if line.first == " " { line = line.dropFirst() }
                }
                lines[index] = String(line)
            }
        }
        let tex = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return tex.isEmpty ? nil : tex
    }
}
