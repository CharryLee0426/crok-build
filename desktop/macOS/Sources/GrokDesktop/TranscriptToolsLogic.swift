import AppKit
import Foundation

// Pure logic behind the transcript commands, kept free of views so it can be tested directly.

// MARK: - /copy

/// The arguments of `/copy [N] [file]`, parsed exactly as the terminal parses them.
struct TranscriptCopyRequest: Equatable {
    /// Assistant message blocks counted newest first; 1 is the latest.
    var index: Int
    /// The rest of the line after N (spaces included), or the whole line when it does not start with a count.
    var path: String?

    static let usage = "Usage: /copy [N] [file] where N is 1 (latest), 2, 3, ..."

    static func parse(_ arguments: String) throws -> TranscriptCopyRequest {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TranscriptCopyRequest(index: 1, path: nil) }
        let first: Substring
        var rest: String?
        if let space = trimmed.firstIndex(where: \.isWhitespace) {
            first = trimmed[..<space]
            let remainder = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = remainder.isEmpty ? nil : remainder
        } else {
            first = trimmed[...]
        }
        // Unsigned, like the terminal's `usize`: "-1" is a file name, not a count.
        guard let count = UInt(first) else { return TranscriptCopyRequest(index: 1, path: trimmed) }
        guard count > 0 else { throw DesktopError.message(usage) }
        return TranscriptCopyRequest(index: Int(clamping: count), path: rest)
    }

    /// The raw Markdown of the Nth newest assistant message. Reasoning, tool output, and prompts
    /// are never copied; a reply split by tool calls counts as several messages.
    static func select(_ index: Int, from messages: [Message]) -> Result<String, DesktopError> {
        let replies = messages.reversed().filter { $0.kind == .assistant }
        guard !replies.isEmpty else { return .failure(.message("No assistant messages to copy")) }
        guard index <= replies.count else {
            return .failure(.message("Only \(replies.count) assistant \(replies.count == 1 ? "message" : "messages") available to copy"))
        }
        let text = replies[index - 1].text
        guard !text.isEmpty else { return .failure(.message("Assistant message is empty")) }
        return .success(text)
    }
}

// MARK: - Clipboard and files

/// A POSIX error rendered the way the terminal prints `std::io::Error`.
struct TranscriptFileError: LocalizedError, Equatable {
    let code: Int32
    var errorDescription: String? { "\(String(cString: strerror(code))) (os error \(code))" }
}

/// Where a copy landed: the clipboard (with its backup file), only the backup file, or nowhere.
enum TranscriptCopyDelivery: Equatable {
    case clipboard(backup: URL?)
    case file(URL)
    case failed
}

enum TranscriptClipboard {
    /// " (N chars, M lines)". Like the terminal, "chars" is the UTF-8 byte count.
    static func statsSuffix(_ text: String) -> String {
        let lines = lineCount(text)
        return " (\(text.utf8.count) chars, \(lines) \(lines == 1 ? "line" : "lines"))"
    }

    /// Lines as Rust's `str::lines` counts them: a final newline does not start another line.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return newlines + (text.utf8.last == 10 ? 0 : 1)
    }

    /// `$GROK_COPY_FILE` (with `~` expanded), or `$GROK_HOME/last-copy.txt`.
    static func backupURL(environment: [String: String], grokHome: URL) -> URL {
        if let raw = environment["CROK_COPY_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return grokHome.appendingPathComponent("last-copy.txt")
    }

    /// Short form for messages: `~/.grok/…` (or `$GROK_HOME/…` when relocated), then `~/…`.
    static func displayPath(_ url: URL, grokHome: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.standardizedFileURL.path
        let grok = grokHome.standardizedFileURL.path
        let defaultGrok = (home as NSString).appendingPathComponent(".crok")
        if path == grok || path.hasPrefix(grok + "/") {
            let prefix = grok == defaultGrok ? "~/.crok" : "$CROK_HOME"
            return prefix + path.dropFirst(grok.count)
        }
        if !home.isEmpty, path == home || path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// A user-typed path: `~` expanded, relative paths resolved against the project folder.
    static func resolve(_ path: String, relativeTo base: String?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let root = URL(fileURLWithPath: base ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL
    }

    /// `mkdir -p`, reporting the failing call's errno.
    static func makeDirectories(_ url: URL, mode: mode_t = 0o755) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw TranscriptFileError(code: ENOTDIR)
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, !parent.path.isEmpty { try makeDirectories(parent, mode: mode) }
        if mkdir(url.path, mode) != 0, errno != EEXIST { throw TranscriptFileError(code: errno) }
    }

    /// Writes text in place. `ownerOnly` files are 0600 even when they already existed with
    /// wider permissions, because copied text can be sensitive and the backup path is predictable.
    static func write(_ text: String, to url: URL, ownerOnly: Bool) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, ownerOnly ? 0o600 : 0o666)
        guard descriptor >= 0 else { throw TranscriptFileError(code: errno) }
        defer { close(descriptor) }
        if ownerOnly, fchmod(descriptor, 0o600) != 0 { throw TranscriptFileError(code: errno) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw TranscriptFileError(code: errno)
                }
                offset += written
            }
        }
    }

    /// `/copy … file`: parents are created and the file is private to the user.
    static func writeCopyFile(_ text: String, to url: URL) throws {
        try makeDirectories(url.deletingLastPathComponent())
        try write(text, to: url, ownerOnly: true)
    }

    /// The backup written beside every clipboard copy; a missing parent is created 0700.
    static func writeBackup(_ text: String, to url: URL) throws {
        try makeDirectories(url.deletingLastPathComponent(), mode: 0o700)
        try write(text, to: url, ownerOnly: true)
    }

    static func setClipboard(_ text: String, pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func delivery(copied: Bool, backup: URL?) -> TranscriptCopyDelivery {
        if copied { return .clipboard(backup: backup) }
        if let backup { return .file(backup) }
        return .failed
    }

    /// The terminal's `/copy` messages.
    static func copyMessage(_ delivery: TranscriptCopyDelivery, stats: String, grokHome: URL) -> String {
        switch delivery {
        case .clipboard(let backup?): return "Copied to clipboard (also saved to \(displayPath(backup, grokHome: grokHome)))\(stats)"
        case .clipboard(nil): return "Copied to clipboard\(stats)"
        case .file(let url): return "Clipboard unreachable: wrote \(displayPath(url, grokHome: grokHome))\(stats)"
        case .failed: return "Copy failed\(stats)"
        }
    }

    /// The terminal's `/export` clipboard messages.
    static func exportMessage(_ delivery: TranscriptCopyDelivery, stats: String, grokHome: URL) -> String {
        switch delivery {
        case .clipboard(let backup?): return "Conversation copied to clipboard (also saved to \(displayPath(backup, grokHome: grokHome)))\(stats)"
        case .clipboard(nil): return "Conversation copied to clipboard\(stats)"
        case .file(let url): return "Clipboard unreachable: conversation written to \(displayPath(url, grokHome: grokHome))\(stats)"
        case .failed: return "Conversation copy failed\(stats)"
        }
    }
}

// MARK: - /export Markdown

/// The terminal's export format (`render_blocks_to_markdown`): `## User`, `## Assistant` (consecutive
/// replies merged, even across skipped reasoning), and `## Tools` with one line per call.
/// Reasoning and system notices are skipped. There is no title header.
enum TranscriptMarkdownExport {
    static func render(_ messages: [Message]) -> String {
        var out = ""
        var lastWasAgent = false
        var inTools = false
        for message in messages {
            switch message.kind {
            case .user:
                if inTools { out += "\n"; inTools = false }
                out += "## User\n\n" + message.text + "\n\n"
                lastWasAgent = false
            case .assistant:
                if !lastWasAgent {
                    if inTools { out += "\n"; inTools = false }
                    out += "## Assistant\n\n"
                }
                out += message.text + "\n\n"
                lastWasAgent = true
            case .tool:
                if !inTools { out += "## Tools\n\n"; inTools = true }
                out += "- " + toolSummary(message.text) + "\n"
                lastWasAgent = false
            case .thought, .system:
                break
            }
        }
        while let last = out.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { out.unicodeScalars.removeLast() }
        return out
    }

    /// The desktop keeps only a tool's title, so the terminal's summaries are recovered from the
    /// harness's title shapes (``Read `path` ``, ``Execute `cmd` ``, …); anything else is `Tool: <title>`.
    static func toolSummary(_ title: String) -> String {
        let forms: [(prefix: String, label: String)] = [("Read", "Read"), ("Edit", "Edit"), ("Execute", "Execute"), ("List", "ListDir")]
        for form in forms where title.hasPrefix(form.prefix + " `") && title.hasSuffix("`") && title.count > form.prefix.count + 3 {
            return "\(form.label): " + title.dropFirst(form.prefix.count + 2).dropLast()
        }
        if title.hasPrefix("Web search: \""), title.hasSuffix("\""), title.count > 14 {
            return "WebSearch: " + title.dropFirst(13).dropLast()
        }
        return "Tool: \(title)"
    }
}

// MARK: - Search (/find and the transcript window)

/// The terminal's matcher: a regular expression with smart case (case-insensitive unless the
/// query has an uppercase letter). An invalid pattern is flagged and matches nothing.
struct TranscriptSearchMatcher {
    let query: String
    let regex: NSRegularExpression?
    var isInvalid: Bool { !query.isEmpty && regex == nil }

    init(_ query: String) {
        self.query = query
        let caseInsensitive = !query.contains { $0.isUppercase }
        regex = query.isEmpty ? nil : try? NSRegularExpression(pattern: query, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Non-empty matches only: a pattern that can match nothing would otherwise match everywhere.
    func count(in text: String) -> Int {
        guard let regex, !text.isEmpty else { return 0 }
        var count = 0
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            if let match, match.range.length > 0 { count += 1 }
        }
        return count
    }
}

/// One occurrence of the query, located by the message it is in.
struct TranscriptFindMatch: Equatable {
    let messageID: UUID
    /// Occurrence within that message, from 0.
    let occurrence: Int
}

struct TranscriptSearchDocument {
    let id: UUID
    let text: String

    /// What a reader sees: rendered text for Markdown (replies and reasoning), the source for the rest.
    static func make(_ message: Message) -> TranscriptSearchDocument {
        switch message.kind {
        case .assistant, .thought: return TranscriptSearchDocument(id: message.id, text: TranscriptPlainText.strip(message.text))
        case .tool: return TranscriptSearchDocument(id: message.id, text: [message.text, message.detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        case .user, .system: return TranscriptSearchDocument(id: message.id, text: message.text)
        }
    }
}

enum TranscriptSearch {
    struct Result: Equatable {
        var matches: [TranscriptFindMatch] = []
        var isInvalid = false
    }

    static func run(query: String, documents: [TranscriptSearchDocument]) -> Result {
        let matcher = TranscriptSearchMatcher(query)
        guard !query.isEmpty else { return Result() }
        guard !matcher.isInvalid else { return Result(isInvalid: true) }
        var matches: [TranscriptFindMatch] = []
        for document in documents {
            let count = matcher.count(in: document.text)
            for occurrence in 0..<count { matches.append(TranscriptFindMatch(messageID: document.id, occurrence: occurrence)) }
        }
        return Result(matches: matches)
    }

    /// Next (`step` 1) or previous (-1) match, wrapping at either end.
    static func step(_ cursor: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let from = cursor ?? (step > 0 ? -1 : 0)
        return ((from + step) % count + count) % count
    }
}

/// Approximates the text a Markdown renderer shows, so a search does not match markup.
enum TranscriptPlainText {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }
    private static let heading = regex(#"^\s{0,3}#{1,6}(\s+|$)"#)
    private static let closingHashes = regex(#"\s+#+\s*$"#)
    private static let quote = regex(#"^\s{0,3}(>\s?)+"#)
    private static let listMarker = regex(#"^\s*(?:[-*+]|\d{1,9}[.)])\s+(?:\[[ xX]\]\s+)?"#)
    private static let thematicBreak = regex(#"^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$"#)
    private static let tableRule = regex(#"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#)
    private static let inline: [(NSRegularExpression?, String)] = [
        (regex(#"!\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (regex(#"\[([^\]]+)\]\([^)]*\)"#), "$1"),
        (regex(#"<((?:https?|mailto):[^>\s]+)>"#), "$1"),
        (regex(#"(`+)(.+?)\1"#), "$2"),
        (regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), "$2"),
        (regex(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#), "$1"),
        (regex(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#), "$1"),
        (regex(#"~~(?=\S)(.+?)(?<=\S)~~"#), "$1"),
        (regex(#"\\([\\`*_{}\[\]()#+\-.!|~>])"#), "$1"),
    ]

    static func strip(_ markdown: String) -> String {
        var output: [String] = []
        var fence: String?
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil } else { output.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                continue
            }
            if matches(thematicBreak, trimmed) || matches(tableRule, trimmed) && trimmed.contains("|") { continue }
            var text = replace(heading, in: line, with: "")
            if text != line { text = replace(closingHashes, in: text, with: "") }
            text = replace(quote, in: text, with: "")
            text = replace(listMarker, in: text, with: "")
            if text.contains("|") && trimmed.hasPrefix("|") {
                text = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\t")
            }
            for (pattern, template) in inline { text = replace(pattern, in: text, with: template) }
            output.append(text)
        }
        return output.joined(separator: "\n")
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

// MARK: - Turns (/jump and the timeline)

/// One turn of the conversation: a prompt and everything that answered it.
struct TranscriptTurn: Identifiable, Equatable {
    /// 1-based, as shown in the jump list.
    let number: Int
    let messageID: UUID
    let messageIndex: Int
    /// The first non-empty prompt line, capped at 120 characters.
    let preview: String
    let date: Date?
    var id: UUID { messageID }
    var displayPreview: String { preview.isEmpty ? "(no preview)" : preview }
}

enum TranscriptTurns {
    static let previewLimit = 120

    static func list(_ messages: [Message]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for (index, message) in messages.enumerated() where message.kind == .user {
            turns.append(TranscriptTurn(number: turns.count + 1, messageID: message.id, messageIndex: index,
                                        preview: preview(message.text), date: message.createdAt))
        }
        return turns
    }

    /// The terminal's `prompt_preview`: the first non-empty trimmed line; past the limit it keeps
    /// 119 characters and adds "…".
    static func preview(_ text: String) -> String {
        // The timeline asks on every render, so stop at the first non-empty line and never read
        // far into a long pasted prompt.
        var line = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            let window = rest.prefix(4_096)
            let end = window.firstIndex(where: \.isNewline) ?? window.endIndex
            let candidate = window[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { line = candidate; break }
            rest = rest[(end < rest.endIndex && end < window.endIndex ? rest.index(after: end) : end)...]
        }
        let scalars = line.unicodeScalars
        guard scalars.count > previewLimit else { return line }
        var capped = String.UnicodeScalarView(scalars.prefix(previewLimit - 1))
        capped.append("\u{2026}")
        return String(capped)
    }

    /// The turn owning a message: the last one whose prompt is at or above it (the first turn for
    /// anything before the first prompt).
    static func turn(containing messageIndex: Int, in turns: [TranscriptTurn]) -> Int? {
        guard !turns.isEmpty else { return nil }
        return turns.lastIndex { $0.messageIndex <= messageIndex } ?? 0
    }
}

/// A tick on the timeline rail.
struct TranscriptTimelineTick: Identifiable, Equatable {
    let turn: TranscriptTurn
    /// Where the turn starts, as a fraction of the conversation's estimated height.
    let position: CGFloat
    var id: UUID { turn.id }
}

enum TranscriptTimelineLayout {
    /// Ticks placed where each prompt sits in the conversation. Heights are estimated from text
    /// length, because the lazy transcript never lays out rows that are off screen.
    static func ticks(messages: [Message], turns: [TranscriptTurn], expanded: Set<UUID>, compact: Bool) -> [TranscriptTimelineTick] {
        guard !turns.isEmpty else { return [] }
        let spacing: CGFloat = compact ? 10 : 23
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(messages.count)
        var y: CGFloat = 0
        for message in messages {
            offsets.append(y)
            y += estimatedHeight(message, expanded: expanded.contains(message.id)) + spacing
        }
        let total = max(y - spacing, 1)
        return turns.map { turn in
            let offset = turn.messageIndex < offsets.count ? offsets[turn.messageIndex] : 0
            return TranscriptTimelineTick(turn: turn, position: min(max(offset / total, 0), 1))
        }
    }

    static func estimatedHeight(_ message: Message, expanded: Bool) -> CGFloat {
        let bytes = CGFloat(message.text.utf8.count)
        switch message.kind {
        case .user: return 50 + min(ceil(bytes / 70), 19) * 22
        case .assistant: return 42 + ceil(bytes / 90) * 26
        case .system: return 46 + ceil(bytes / 90) * 20
        case .thought: return expanded ? 60 + min(ceil(bytes / 100) * 20, 360) : 44
        case .tool:
            guard expanded else { return 44 }
            return 56 + min(CGFloat((message.detail ?? "").utf8.count) / 90 * 18, 260)
        }
    }
}

// MARK: - /history

enum TranscriptPromptHistory {
    /// Prompts from `_x.ai/prompt_history` (raw `{prompts}`, tolerating a `{result}` envelope),
    /// most recent first, without blanks or repeats.
    static func prompts(from response: [String: Any]) -> [String] {
        let payload = response["result"] as? [String: Any] ?? response
        return unique(payload["prompts"] as? [Any] ?? [])
    }

    static func unique(_ values: [Any]) -> [String] {
        var seen = Set<String>()
        var prompts: [String] = []
        for case let prompt as String in values where !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(prompt).inserted { prompts.append(prompt) }
        }
        return prompts
    }

    struct Match: Equatable, Identifiable {
        let index: Int
        let text: String
        /// Character offsets of the matched query letters.
        let highlights: [Int]
        let score: Int
        var id: Int { index }
    }

    static let resultLimit = 100
    /// Long pasted prompts are matched on their opening only.
    private static let matchPrefix = 4_000

    /// Fuzzy ranking: every space-separated word of the query must appear in order (smart case);
    /// contiguous and word-start matches rank first, then recency.
    static func rank(_ prompts: [String], query: String, limit: Int = resultLimit) -> [Match] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return prompts.prefix(limit).enumerated().map { Match(index: $0.offset, text: $0.element, highlights: [], score: 0) }
        }
        let caseInsensitive = !query.contains { $0.isUppercase }
        let needles = words.map { word in Array(caseInsensitive ? word.lowercased() : word) }
        var results: [Match] = []
        for (index, prompt) in prompts.enumerated() {
            let head = String(prompt.prefix(matchPrefix))
            let haystack = Array(caseInsensitive ? head.lowercased() : head)
            // Lowercasing can change the length of a few scripts; highlights then use the folded text's offsets.
            var score = 0
            var highlights: [Int] = []
            var matched = true
            for needle in needles {
                guard let found = match(needle, in: haystack) else { matched = false; break }
                score += found.score
                highlights += found.positions
            }
            if matched { results.append(Match(index: index, text: prompt, highlights: Array(Set(highlights)).sorted(), score: score)) }
        }
        results.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    private static func isBoundary(_ haystack: [Character], _ index: Int) -> Bool {
        index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber)
    }

    private static func match(_ needle: [Character], in haystack: [Character]) -> (score: Int, positions: [Int])? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        // A contiguous occurrence wins, preferring one at a word start.
        var best: Int?
        var start = 0
        while start + needle.count <= haystack.count {
            var length = 0
            while length < needle.count, haystack[start + length] == needle[length] { length += 1 }
            if length == needle.count {
                if best == nil { best = start }
                if isBoundary(haystack, start) { best = start; break }
            }
            start += 1
        }
        if let best {
            let bonus = (isBoundary(haystack, best) ? 40 : 0) + (best == 0 ? 20 : 0)
            return (1_000 + needle.count * 16 + bonus - min(best, 200) / 10, Array(best..<best + needle.count))
        }
        // Otherwise an in-order subsequence, scored by how tightly and where the letters land.
        var positions: [Int] = []
        var cursor = 0
        for character in needle {
            while cursor < haystack.count, haystack[cursor] != character { cursor += 1 }
            guard cursor < haystack.count else { return nil }
            positions.append(cursor)
            cursor += 1
        }
        var score = needle.count * 10
        for (offset, position) in positions.enumerated() {
            if isBoundary(haystack, position) { score += 8 }
            if offset > 0 {
                let gap = position - positions[offset - 1] - 1
                score += gap == 0 ? 12 : -min(gap, 20)
            }
        }
        return (score - min(positions[0], 200) / 20, positions)
    }
}

// MARK: - Timestamps

enum TranscriptTimestamp {
    private static let label: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private static let tooltip: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss | MMM dd"
        return formatter
    }()

    /// "3:07 PM", following the system's 12/24-hour setting.
    static func label(_ date: Date) -> String { label.string(from: date) }
    /// "15:07:12 | Sep 23", as in the terminal's hover.
    static func tooltip(_ date: Date) -> String { tooltip.string(from: date) }
}

// MARK: - /debug

enum TranscriptDebugFormat {
    /// "fps:60 p50:16.7ms p95:18.2ms" from frame intervals in milliseconds.
    static func frameLine(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "fps:- p50:- p95:-" }
        let sorted = samples.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let fps = mean > 1e-6 ? 1000 / mean : 0
        return String(format: "fps:%.0f p50:%.1fms p95:%.1fms", fps, percentile(sorted, 50), percentile(sorted, 95))
    }

    /// Linear-interpolation percentile of sorted values.
    static func percentile(_ sorted: [Double], _ percent: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = percent / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        guard lower + 1 < sorted.count else { return sorted[lower] }
        return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * (rank - Double(lower))
    }

    /// `$GROK_HOME/logs/scroll-log-YYYYMMDD-HHMMSS.jsonl`, stamped in UTC like the terminal's.
    static func scrollLogURL(grokHome: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return grokHome.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("scroll-log-\(formatter.string(from: date)).jsonl")
    }

    static func status(scroll: Bool, fps: Bool, log: Bool) -> String {
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        return "debug toggles: scroll \(on(scroll)) \u{00B7} fps \(on(fps)) \u{00B7} log \(on(log)). Toggle with /debug <scroll|fps|log>"
    }
}
