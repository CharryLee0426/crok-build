import Foundation

/// One how-to guide from `$GROK_HOME/docs/user-guide`.
struct GuideDocument: Identifiable, Equatable {
    /// The file name, e.g. `06-theming.md`, which is also what guides link to.
    var id: String { fileName }
    let fileName: String
    let title: String
    let summary: String
    let content: String
}

/// What `/docs [web|title]` asks for (`xai-grok-pager/src/slash/commands/docs.rs`).
enum GuideDocsTarget: Equatable {
    case browse
    case web
    case guide(String)
    case unknown(String)

    static let onlineURL = URL(string: "https://docs.x.ai/build/overview")!

    init(arguments: String) {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty || ["how-to", "howto", "guides", "guide", "list", "tui"].contains(lower) { self = .browse }
        else if ["web", "online", "browser", "site", "www"].contains(lower) { self = .web }
        else if let entry = GuideLibrary.entry(matching: trimmed) { self = .guide(entry.fileName) }
        else { self = .unknown(trimmed) }
    }

    /// The terminal's message, with the target quoted the way Rust's `{:?}` prints it.
    static func unknownMessage(_ target: String) -> String {
        let quoted = "\"" + target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "Unknown docs target \(quoted). Try /docs, /docs web, or a guide title (e.g. /docs Getting Started)."
    }
}

/// The guides every `grok` process start (including `grok agent stdio`) extracts to
/// `$GROK_HOME/docs/user-guide/NN-*.md`, listed in the terminal's order (`xai-grok-pager/src/docs.rs`).
enum GuideLibrary {
    struct Entry {
        let fileName: String
        let title: String
        let summary: String
    }

    static let catalog: [Entry] = [
        Entry(fileName: "01-getting-started.md", title: "Getting Started", summary: "Installation, first launch, and basic interaction"),
        Entry(fileName: "02-authentication.md", title: "Authentication", summary: "Sign in to OpenRouter or OpenAI Codex"),
        Entry(fileName: "03-keyboard-shortcuts.md", title: "Keyboard Shortcuts", summary: "Complete reference for all TUI key bindings"),
        Entry(fileName: "04-slash-commands.md", title: "Slash Commands", summary: "All / commands, including goals, research, and workflow management"),
        Entry(fileName: "05-configuration.md", title: "Configuration", summary: "config.toml, pager.toml, environment variables, file locations"),
        Entry(fileName: "06-theming.md", title: "Theming and Appearance", summary: "Themes, color support, pager.toml customization"),
        Entry(fileName: "07-mcp-servers.md", title: "MCP Servers", summary: "Setting up external tool integrations via MCP"),
        Entry(fileName: "08-skills.md", title: "Skills", summary: "Creating and using reusable prompt packages"),
        Entry(fileName: "09-plugins.md", title: "Plugins and Marketplace", summary: "Installing, managing, and creating plugin packages"),
        Entry(fileName: "10-hooks.md", title: "Hooks", summary: "Project lifecycle scripts for pre/post tool-use events"),
        Entry(fileName: "11-custom-models.md", title: "Custom Models", summary: "BYOK, Ollama, OpenAI-compatible endpoints"),
        Entry(fileName: "12-project-rules.md", title: "Project Rules (AGENTS.md)", summary: "Per-directory instructions and precedence rules"),
        Entry(fileName: "13-memory.md", title: "Memory", summary: "Cross-session knowledge persistence and search"),
        Entry(fileName: "14-headless-mode.md", title: "Headless Mode and Scripting", summary: "Non-interactive CLI for automation and CI/CD"),
        Entry(fileName: "15-agent-mode.md", title: "Agent Mode and IDE Integration", summary: "ACP stdio transport, WebSocket relay, SDK integration"),
        Entry(fileName: "16-subagents.md", title: "Subagents and Personas", summary: "Spawning parallel child agents with specialized roles"),
        Entry(fileName: "17-sessions.md", title: "Session Management", summary: "Save, load, resume, rewind, and compact sessions"),
        Entry(fileName: "18-sandbox.md", title: "Sandbox Mode", summary: "OS-level filesystem and network isolation"),
        Entry(fileName: "19-plan-mode.md", title: "Plan Mode", summary: "Structured planning with approval dialogs"),
        Entry(fileName: "20-background-tasks.md", title: "Background Tasks and Monitoring", summary: "Background commands, /loop, monitor, scheduler"),
        Entry(fileName: "21-terminal-support.md", title: "Terminal Support and Troubleshooting", summary: "tmux, Byobu, Zellij, SSH, truecolor, clipboard, and diagnostics"),
        Entry(fileName: "22-permissions-and-safety.md", title: "Permissions and Safety", summary: "Modes, authorization order, allow/ask/deny rules, matching, and hooks"),
        Entry(fileName: "23-dashboard.md", title: "Agent Dashboard", summary: "Live multi-session roster: peek, dispatch, pin, stop, and search"),
        Entry(fileName: "24-monitoring-usage.md", title: "Monitoring Usage (External OpenTelemetry)", summary: "Export usage metrics to a customer OpenTelemetry collector"),
        Entry(fileName: "25-status-line.md", title: "Status Line", summary: "A bottom row of live session context, or the output of your own script"),
        Entry(fileName: "26-config-reference.md", title: "Configuration Reference", summary: "Field list for config.toml, managed_config.toml, and requirements.toml"),
        Entry(fileName: "27-grok-clone.md", title: "grok clone", summary: "Depth-1 Grove clone, --full-history, and safe deepen/switch commands"),
    ]

    static func directory(home: URL = GrokPaths.home) -> URL {
        home.appendingPathComponent("docs", isDirectory: true).appendingPathComponent("user-guide", isDirectory: true)
    }

    /// A guide title as `/docs <title>` takes it: exact (ignoring case) first, then a unique-enough prefix.
    static func entry(matching title: String) -> Entry? {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        return catalog.first { $0.title.lowercased() == query }
            ?? catalog.first { $0.title.lowercased().hasPrefix(query) }
            ?? catalog.first { ($0.fileName as NSString).deletingPathExtension == query || $0.fileName == query }
    }

    /// Reads the extracted guides, or nil when the folder does not exist yet. Files the catalog
    /// does not know (a newer harness) follow it, titled by their first heading.
    static func load(from directory: URL) -> [GuideDocument]? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
        let files = Set(names.filter { $0.hasSuffix(".md") && $0 != "README.md" })
        func read(_ name: String) -> String? {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
        }
        var guides: [GuideDocument] = catalog.compactMap { entry in
            guard files.contains(entry.fileName), let content = read(entry.fileName) else { return nil }
            return GuideDocument(fileName: entry.fileName, title: entry.title, summary: entry.summary, content: content)
        }
        let known = Set(catalog.map(\.fileName))
        for name in files.subtracting(known).sorted() {
            guard let content = read(name) else { continue }
            let heading = content.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let title = heading ?? (name as NSString).deletingPathExtension
            guides.append(GuideDocument(fileName: name, title: title, summary: "", content: content))
        }
        return guides
    }

    // MARK: Search

    struct SearchHit: Equatable {
        let guide: GuideDocument
        /// Where the match is in the text, when it is not in the title or summary.
        let snippet: String?
        let count: Int
    }

    /// Guides whose title, summary, or text contain the query (ignoring case), title matches first.
    static func search(_ query: String, in guides: [GuideDocument]) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return guides.map { SearchHit(guide: $0, snippet: nil, count: 0) } }
        var titled: [SearchHit] = [], textual: [SearchHit] = []
        for guide in guides {
            let ranges = occurrences(of: query, in: guide.content, limit: 99)
            if guide.title.localizedCaseInsensitiveContains(query) || guide.summary.localizedCaseInsensitiveContains(query) {
                titled.append(SearchHit(guide: guide, snippet: nil, count: ranges.count))
            } else if let first = ranges.first {
                textual.append(SearchHit(guide: guide, snippet: snippet(around: first, in: guide.content), count: ranges.count))
            }
        }
        return titled + textual
    }

    static func occurrences(of query: String, in text: String, limit: Int) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while result.count < limit, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }

    /// One line of context around a match, with Markdown punctuation that reads as noise removed.
    static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var before = String(text[lineStart..<range.lowerBound])
        var after = String(text[range.upperBound..<lineEnd])
        if before.count > 48 { before = "…" + before.suffix(47) }
        if after.count > 72 { after = String(after.prefix(71)) + "…" }
        let line = before + String(text[range]) + after
        return line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>|-* ").union(.whitespaces))
    }

    // MARK: Sections

    struct Section: Identifiable, Equatable {
        let id: Int
        let text: String
        /// Anchors of every heading inside the section, for `file.md#anchor` links.
        let anchors: [String]
    }

    /// Splits a guide at its top three heading levels so a long guide renders lazily and a
    /// link can scroll to a heading. Fenced code is never split.
    static func sections(of content: String) -> [Section] {
        var sections: [Section] = []
        var lines: [String] = [], anchors: [String] = []
        var fence: String?
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { sections.append(Section(id: sections.count, text: text, anchors: anchors)) }
            lines = []; anchors = []
        }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
            } else if let (level, title) = heading(line) {
                if level <= 3 { flush() }
                anchors.append(slug(title))
            }
            lines.append(line)
        }
        flush()
        return sections
    }

    /// Joins the hard-wrapped lines of each paragraph, list item, and quote. The guides wrap at
    /// about 75 columns, and the Markdown renderer keeps single newlines (as chat replies want),
    /// which would leave ragged lines in a wider column. Code, tables, and hard breaks are kept.
    static func reflow(_ markdown: String) -> String {
        var output: [String] = []
        var fence: String?
        var joinable = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                output.append(line); joinable = false; continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                output.append(line); joinable = false; continue
            }
            let quoted = trimmed.hasPrefix(">")
            let content = quoted ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            if joinable, let previous = output.last, !content.isEmpty, !startsBlock(content),
               quoted == previous.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                output[output.count - 1] = previous + " " + content
            } else {
                output.append(line)
            }
            let hardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            joinable = !content.isEmpty && !hardBreak && !content.hasPrefix("|") && !content.hasPrefix("#") && !content.hasPrefix("<")
                && !isRule(content) && !(line.hasPrefix("    ") && output.last == line && !startsList(trimmed))
        }
        return output.joined(separator: "\n")
    }

    private static func startsBlock(_ content: String) -> Bool {
        content.hasPrefix("#") || content.hasPrefix("|") || content.hasPrefix("<") || content.hasPrefix("```") || content.hasPrefix("~~~")
            || isRule(content) || startsList(content)
    }

    private static func startsList(_ content: String) -> Bool {
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") { return true }
        let digits = content.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = content.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func isRule(_ content: String) -> Bool {
        let characters = content.filter { $0 != " " }
        guard characters.count >= 3, let first = characters.first, "-*_=".contains(first) else { return false }
        return characters.allSatisfy { $0 == first }
    }

    static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    /// GitHub's heading anchors: lowercased, punctuation dropped, spaces as hyphens.
    static func slug(_ title: String) -> String {
        var result = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" { result.append(character) }
            else if character == " " { result.append("-") }
        }
        return result
    }
}
