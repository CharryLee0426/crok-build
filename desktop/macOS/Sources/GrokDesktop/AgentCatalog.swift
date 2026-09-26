import Foundation

/// One agent definition in `/config-agents`.
struct AgentDefinitionEntry: Identifiable, Equatable {
    enum Scope: String {
        case builtIn = "Built-in", project = "Project", user = "User", bundled = "Bundled", plugin = "Plugin"
        /// Discovery priority: project over user over bundled over built-in.
        var priority: Int { [.project: 3, .user: 2, .bundled: 1][self] ?? 0 }
    }

    var name: String
    var description: String
    var scope: Scope
    var path: String?
    var pluginName: String?

    var id: String {
        switch scope {
        case .builtIn: return "builtin:\(name)"
        case .bundled: return "bundled:\(name)"
        case .plugin: return "plugin:\(name)"
        case .project, .user: return path ?? "\(scope.rawValue):\(name)"
        }
    }
}

/// Finds agent definitions the way the harness does: user-visible built-ins, then `.grok/agents`
/// and `.claude/agents` from the project up to its git root, `~/.grok/agents`, `~/.claude/agents`,
/// bundled agents, and finally plugin agents under `plugin:agent` names.
enum AgentCatalog {
    /// The user's home, honouring `HOME` like the harness does (so tests can point it elsewhere).
    static var userHome: URL {
        if let value = ProcessInfo.processInfo.environment["HOME"], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static let builtins: [(name: String, description: String)] = [
        ("grok-build", "Crok Build agent for software engineering tasks."),
        ("general-purpose", "General purpose agent for multi-step tasks."),
        ("explore", "Fast, read-only agent specialized for codebase exploration."),
        ("plan", "Software architect for planning implementation strategies."),
        ("browser-use", "Web browsing and interaction agent."),
    ]
    /// Built-ins the model can spawn; only project agents may shadow them.
    static let subagentBuiltins: Set<String> = ["general-purpose", "explore", "plan"]
    /// Every built-in name the harness resolves, including ones it does not list.
    static let resolvableBuiltins: Set<String> = [
        "grok-build", "grok-build-concise", "grok-build-plan", "grok-build-plan-no-subagents", "grok-build-ask-user",
        "codex", "opencode", "general-purpose", "explore", "plan", "browser-use", "grok-build-orchestrator",
    ]

    static func entries(cwd: URL, home: URL = AgentCatalog.userHome, grokHome: URL = GrokPaths.home,
                        bundledNames: [String] = [], pluginAgents: [(plugin: String, agent: String)] = []) -> [AgentDefinitionEntry] {
        var entries = builtins.map { AgentDefinitionEntry(name: $0.name, description: $0.description, scope: .builtIn) }
        for definition in discover(cwd: cwd, home: home, grokHome: grokHome) {
            if subagentBuiltins.contains(definition.name), definition.scope != .project { continue }
            if let index = entries.firstIndex(where: { $0.name == definition.name }) {
                if definition.scope.priority > entries[index].scope.priority { entries[index] = definition }
            } else {
                entries.append(definition)
            }
        }
        // The bundle catalog can name agents whose files are not extracted locally.
        for name in bundledNames where !entries.contains(where: { $0.name == name }) {
            entries.append(AgentDefinitionEntry(name: name, description: "", scope: .bundled))
        }
        for agent in pluginAgents {
            let name = "\(agent.plugin):\(agent.agent)"
            guard !entries.contains(where: { $0.name == name }) else { continue }
            entries.append(AgentDefinitionEntry(name: name, description: "Agent from the \(agent.plugin) plugin.", scope: .plugin, pluginName: agent.plugin))
        }
        return entries
    }

    /// Definition files in priority order; the first definition of a name wins.
    static func discover(cwd: URL, home: URL, grokHome: URL) -> [AgentDefinitionEntry] {
        var directories = projectDirectories(cwd: cwd).map { ($0, AgentDefinitionEntry.Scope.project) }
        let legacyGrok = home.appendingPathComponent(".grok", isDirectory: true)
        let includeLegacy = legacyGrok.standardizedFileURL.path != grokHome.standardizedFileURL.path
        directories.append((grokHome.appendingPathComponent("agents"), .user))
        if includeLegacy { directories.append((legacyGrok.appendingPathComponent("agents"), .user)) }
        directories.append((home.appendingPathComponent(".claude/agents"), .user))
        directories.append((grokHome.appendingPathComponent("bundled/agents"), .bundled))
        if includeLegacy { directories.append((legacyGrok.appendingPathComponent("bundled/agents"), .bundled)) }

        var seen = Set<String>()
        var result: [AgentDefinitionEntry] = []
        for (directory, scope) in directories {
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8), let front = frontMatter(text),
                      let name = front.name, !name.isEmpty, seen.insert(name).inserted else { continue }
                result.append(AgentDefinitionEntry(name: name, description: front.description ?? "", scope: scope, path: file.path))
            }
        }
        return result
    }

    /// `.grok/agents` and `.claude/agents` in each directory from `cwd` up to the git root.
    static func projectDirectories(cwd: URL) -> [URL] {
        var chain: [URL] = []
        var current = cwd.standardizedFileURL
        let manager = FileManager.default
        let home = userHome.standardizedFileURL.path
        var reachedRoot = false
        while true {
            chain.append(current)
            // A home directory that is itself a repository must not make home-level agents look project-local.
            if manager.fileExists(atPath: current.appendingPathComponent(".git").path), current.path != home { reachedRoot = true; break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        if !reachedRoot { chain = [cwd.standardizedFileURL] }
        return chain.flatMap { directory in
            [".grok/agents", ".claude/agents"].map { directory.appendingPathComponent($0, isDirectory: true) }
                .filter { var isDirectory: ObjCBool = false; return manager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
        }
    }

    /// `name` and `description` from YAML front matter delimited by `---` lines.
    static func frontMatter(_ text: String) -> (name: String?, description: String?)? {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix("---") else { return nil }
        let body = trimmed.dropFirst(3)
        guard let close = body.range(of: "\n---") else { return nil }
        var name: String?, description: String?
        let lines = body[..<close.lowerBound].components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                // A block scalar: the indented lines that follow.
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].isEmpty { block.append(lines[index].trimmingCharacters(in: .whitespaces)); index += 1 }
                value = block.joined(separator: value.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                value = unquoteYAML(value)
            }
            if key == "name" { name = value } else if key == "description" { description = value }
        }
        return (name, description)
    }

    private static func unquoteYAML(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
    }
}

/// `[agent] name` and `[subagents.toggle]` from config.toml.
struct AgentConfigSnapshot: Equatable {
    var configuredDefault: String?
    var toggles: [String: Bool] = [:]

    func isEnabled(_ name: String) -> Bool { toggles[name] ?? true }

    static func load(url: URL = GrokPaths.configFile) -> AgentConfigSnapshot {
        let config = GrokConfig(url: url)
        let name = config.string("name", in: "agent").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var toggles: [String: Bool] = [:]
        for (key, value) in ExtensionConfigTable.entries(in: "subagents.toggle", text: config.text) {
            if value == "true" { toggles[key] = true } else if value == "false" { toggles[key] = false }
        }
        return AgentConfigSnapshot(configuredDefault: name, toggles: toggles)
    }
}

/// Reads every `key = value` line of one `[table]`.
enum ExtensionConfigTable {
    static func entries(in table: String, text: String) -> [(String, String)] {
        var inside = false
        var result: [(String, String)] = []
        for line in text.components(separatedBy: "\n") {
            if let header = GrokConfig.headerName(line) { inside = header == table; continue }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[[") { inside = false; continue }
            if inside, let entry = GrokConfig.keyValue(line) { result.append(entry) }
        }
        return result
    }
}

enum AgentConfigWriter {
    static func setDefault(_ name: String?, url: URL = GrokPaths.configFile) throws {
        try GrokConfig.update(url: url) { config in
            if let name { try config.set("name", to: .string(name), in: "agent") }
            else { try config.remove("name", in: "agent") }
        }
    }

    static func setEnabled(_ name: String, enabled: Bool, url: URL = GrokPaths.configFile) throws {
        try GrokConfig.update(url: url) { config in
            // `toggle` written inside `[subagents]` (inline or dotted) would conflict with a new table header.
            if ExtensionConfigTable.entries(in: "subagents", text: config.text).contains(where: { $0.0 == "toggle" || $0.0.hasPrefix("toggle.") }) {
                throw GrokConfigError.unsupportedLayout("[subagents] defines toggle inline")
            }
            try config.set(name, to: .bool(enabled), in: "subagents.toggle")
        }
    }

    /// The agent new sessions start with: `[agent] name` when it resolves, then `GROK_AGENT`, then
    /// the harness default `grok-build-plan`.
    static func resolvedDefault(configured: String?, available: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let known = Set(available).union(AgentCatalog.resolvableBuiltins)
        if let configured, known.contains(configured) { return configured }
        switch environment["CROK_AGENT"]?.trimmingCharacters(in: .whitespaces) {
        case "browser-use"?, "browser_use"?: return "browser-use"
        case "grok-build-concise"?, "grok_build_concise"?: return "grok-build-concise"
        case let value? where value.hasPrefix("/"):
            let text = (try? String(contentsOfFile: value, encoding: .utf8)) ?? ""
            return AgentCatalog.frontMatter(text)?.name ?? "grok-build-plan"
        case let value? where !value.isEmpty: return known.contains(value) ? value : "grok-build-plan"
        default: return "grok-build-plan"
        }
    }
}
