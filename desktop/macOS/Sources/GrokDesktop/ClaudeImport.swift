import CryptoKit
import Foundation

// `/import-claude`, reimplemented from the terminal's shell: `claude_import.rs` (scan and apply),
// `claude_import_state.rs` (the change-detection state file), and the path rules in the workspace's
// `claude_settings.rs`. There is no harness method for it; the terminal does all of this in-process.

/// Where an import reads and writes. Tests inject temporary directories; nothing here reads the
/// process environment except `current`.
struct ClaudeImportEnvironment {
    /// The home that holds `.claude/` and `.claude.json`.
    var home: URL
    /// `$CROK_HOME`, or `~/.crok`.
    var grokHome: URL
    /// The project directory the terminal would have as its working directory.
    var cwd: URL
    var now: () -> Date = Date.init

    static func current(projectPath: String?) -> ClaudeImportEnvironment {
        let environment = ProcessInfo.processInfo.environment
        // Node's `os.homedir()` (which Claude Code uses) honours $HOME, so this does too.
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return ClaudeImportEnvironment(home: home, grokHome: GrokPaths.home,
                                       cwd: URL(fileURLWithPath: projectPath ?? home.path, isDirectory: true))
    }

    var claudeDirectory: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var globalConfig: URL { grokHome.appendingPathComponent("config.toml") }
    var stateFile: URL { grokHome.appendingPathComponent("claude_import_state.json") }
}

// MARK: - Items

enum ClaudeRuleAction: String, Equatable { case allow, deny, ask }

/// The terminal's `ToolFilter`; raw values are the names it prints in the modal.
enum ClaudeToolFilter: String, Equatable {
    case any = "Any", bash = "Bash", edit = "Edit", read = "Read", grep = "Grep", mcp = "Mcp"
    case webFetch = "WebFetch", webSearch = "WebSearch", agentMessage = "AgentMessage"

    /// The name written back into `config.toml`.
    var configName: String {
        switch self {
        case .any: return ""
        case .mcp: return "MCPTool"
        default: return rawValue
        }
    }

    init?(claudeName: String) {
        switch claudeName {
        case "Bash": self = .bash
        case "Read": self = .read
        case "Edit", "Write": self = .edit
        case "MCPTool": self = .mcp
        case "Grep", "Glob": self = .grep
        case "WebFetch": self = .webFetch
        case "WebSearch": self = .webSearch
        case "AgentMessage", "SendSubagentMessage", "SendAgentMessage": self = .agentMessage
        default: return nil
        }
    }
}

struct ClaudePermissionRule: Equatable {
    var action: ClaudeRuleAction
    var tool: ClaudeToolFilter
    var pattern: String?
    /// `WebFetch(domain:…)` patterns match a host rather than a glob.
    var isDomain = false

    /// Parses a Claude rule string like the terminal's `parse_permission_rule`; nil when it would be skipped.
    init?(_ rule: String, action: ClaudeRuleAction) {
        self.action = action
        let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(rule.utf8)
        if let open = Self.firstUnescaped(UInt8(ascii: "("), in: bytes) {
            let prefix = String(decoding: bytes[..<open], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = Array(bytes[(open + 1)...])
            guard let close = Self.lastUnescaped(UInt8(ascii: ")"), in: rest) else { return nil }
            let content = String(decoding: rest[..<close], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty content or a lone wildcard makes the rule tool-wide.
            var pattern = content.isEmpty || content == "*" ? "" : Self.unescape(content)
            guard let tool = ClaudeToolFilter(claudeName: prefix) else { return nil }
            // `Bash(cmd:*)` means "commands starting with cmd".
            if tool == .bash, pattern.hasSuffix(":*") { pattern.removeLast(2) }
            if pattern.hasPrefix("domain:") { pattern.removeFirst(7); isDomain = true }
            self.tool = tool
            self.pattern = pattern.isEmpty ? nil : pattern
            return
        }
        if ["EnterWorktree", "NotebookEdit", "NotebookRead"].contains(rule) { return nil }
        if let tool = ClaudeToolFilter(claudeName: rule) { self.tool = tool; pattern = nil; return }
        // Claude's `mcp__server[__tool]` spelling becomes Crok's unprefixed `server__tool`.
        if rule.hasPrefix("mcp__"), rule.count > 5 {
            let rest = String(rule.dropFirst(5))
            tool = .mcp
            pattern = rest == "*" ? nil : rest.contains("__") ? rest : rest + "__*"
            return
        }
        tool = .any
        pattern = rule.isEmpty ? nil : rule
    }

    /// The compact form written into `[permission]` (the terminal's `format_rule_string`).
    var configString: String {
        switch (pattern, tool) {
        case (nil, .any): return "*"
        case (let pattern?, .any): return pattern
        case (nil, _): return tool.configName
        case (let pattern?, _): return "\(tool.configName)(\(isDomain ? "domain:" : "")\(pattern))"
        }
    }

    private static func unescaped(_ bytes: [UInt8], _ position: Int) -> Bool {
        var backslashes = 0, cursor = position
        while cursor > 0 && bytes[cursor - 1] == UInt8(ascii: "\\") { backslashes += 1; cursor -= 1 }
        return backslashes % 2 == 0
    }

    private static func firstUnescaped(_ target: UInt8, in bytes: [UInt8]) -> Int? {
        bytes.indices.first { bytes[$0] == target && unescaped(bytes, $0) }
    }

    private static func lastUnescaped(_ target: UInt8, in bytes: [UInt8]) -> Int? {
        bytes.indices.last { bytes[$0] == target && unescaped(bytes, $0) }
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        return text.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

enum ClaudeImportPathKind: Equatable { case skill, rule }

enum ClaudeImportItemKind: Int, CaseIterable, Comparable {
    case permission, envVar, mcpServer, hook, path

    var title: String {
        switch self {
        case .permission: return "Permissions"
        case .envVar: return "Env vars"
        case .mcpServer: return "MCP servers"
        case .hook: return "Hooks"
        case .path: return "Paths"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An MCP server definition, already converted to the `[mcp_servers.<name>]` lines Crok reads.
struct ClaudeMCPServer: Equatable {
    var lines: [String]
    /// The command line or URL, shown beside the name.
    var summary: String
}

enum ClaudeImportItem: Equatable {
    case permission(ClaudePermissionRule)
    case envVar(key: String, value: String)
    case mcpServer(name: String, server: ClaudeMCPServer)
    case hook(event: String, matcher: String?, command: String, timeout: UInt64?)
    case path(kind: ClaudeImportPathKind, path: String)

    var kind: ClaudeImportItemKind {
        switch self {
        case .permission: return .permission
        case .envVar: return .envVar
        case .mcpServer: return .mcpServer
        case .hook: return .hook
        case .path: return .path
        }
    }

    /// The row text, formatted exactly like the terminal's import modal.
    var label: String {
        switch self {
        case .permission(let rule):
            let action = rule.action.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
            return "\(action) \(rule.tool.rawValue)(\(rule.pattern ?? "*"))"
        case let .envVar(key, value):
            return "\(key) = \(ClaudeImportItem.debugQuoted(value))"
        case let .mcpServer(name, _):
            return name
        case let .hook(event, matcher, command, timeout):
            return "\(event)  matcher=\(matcher ?? "*") → \(command)\(timeout.map { " timeout=\($0)s" } ?? "")"
        case let .path(kind, path):
            return "\(kind == .skill ? "skill dir" : "rule dir"): \(path)"
        }
    }

    /// Rust's `{:?}` for strings: quoted, with quotes, backslashes, and control characters escaped.
    static func debugQuoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\0"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { result += "\\u{\(String(scalar.value, radix: 16))}" }
                else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }
}

enum ClaudeImportScope: Equatable { case global, project }

struct ClaudeImportPlan: Equatable {
    var global: [ClaudeImportItem] = []
    var project: [ClaudeImportItem] = []
    /// The git root of the working directory (or the directory itself), where project items go.
    var projectRoot: URL

    var isEmpty: Bool { global.isEmpty && project.isEmpty }
    var totalItems: Int { global.count + project.count }
    var projectConfigPath: String { projectRoot.appendingPathComponent(".grok").appendingPathComponent("config.toml").path }

    func items(_ scope: ClaudeImportScope) -> [ClaudeImportItem] { scope == .global ? global : project }

    /// Keeps only the items whose flat index (global first, then project) is selected.
    func filtered(_ selected: Set<Int>) -> ClaudeImportPlan {
        var plan = ClaudeImportPlan(projectRoot: projectRoot)
        plan.global = global.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        plan.project = project.enumerated().filter { selected.contains(global.count + $0.offset) }.map(\.element)
        return plan
    }
}

struct ClaudeImportResult: Equatable {
    var globalCount = 0
    var projectCount = 0
    var modifiedFiles: [String] = []
    var total: Int { globalCount + projectCount }
}

enum ClaudeImportError: LocalizedError {
    case invalidConfig(path: String, reason: String)
    case unsupportedConfig(path: String, reason: String)
    case invalidFile(path: String, reason: String)
    /// A table or key the import writes has the wrong type.
    case typeMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfig(path, reason):
            return "refusing to import: existing config at \(path) is not valid TOML (\(reason)). Fix the file (or move it aside) and retry."
        case let .unsupportedConfig(path, reason):
            return "refusing to import: \(path) cannot be edited safely (\(reason)). Edit it by hand, or run /import-claude in the terminal."
        case let .invalidFile(path, reason):
            return "\(path): \(reason)"
        case .typeMismatch(let message):
            return message
        }
    }
}

// MARK: - Scanning

enum ClaudeImportScanner {
    /// Everything importable, in the terminal's order: each settings file's permissions, env, and
    /// hooks (project files nearest-first, then `~/.claude`), then `~/.claude.json` servers (global),
    /// `.mcp.json` servers (project), and the skill and rule directories.
    static func scan(_ environment: ClaudeImportEnvironment) -> ClaudeImportPlan {
        var plan = ClaudeImportPlan(projectRoot: projectRoot(environment.cwd))
        var seen = Set<String>()
        for path in settingsPaths(environment) where seen.insert(path.path).inserted {
            guard let settings = readJSON(path) else { continue }
            let isGlobal = isInside(path, environment.claudeDirectory)
            var items: [ClaudeImportItem] = []
            if let permissions = settings["permissions"] {
                for action in [ClaudeRuleAction.allow, .deny, .ask] {
                    for rule in stringArray(permissions[action.rawValue]) {
                        if let parsed = ClaudePermissionRule(rule, action: action) { items.append(.permission(parsed)) }
                    }
                }
            }
            for (key, value) in settings["env"]?.objectEntries ?? [] {
                guard let text = envString(value) else { continue }
                items.append(.envVar(key: key, value: text))
            }
            items += hooks(in: settings)
            if isGlobal { plan.global += items } else { plan.project += items }
        }
        plan.global += claudeJSONServers(environment).map { .mcpServer(name: $0.name, server: $0.server) }
        plan.project += mcpJSONServers(environment).map { .mcpServer(name: $0.name, server: $0.server) }
        scanPathDirectories(environment, into: &plan)
        return plan
    }

    /// `.claude/settings{.local}.json` from the working directory up to the repo root, then `~/.claude`'s.
    static func settingsPaths(_ environment: ClaudeImportEnvironment) -> [URL] {
        projectSettingsPaths(environment) + [
            environment.claudeDirectory.appendingPathComponent("settings.local.json"),
            environment.claudeDirectory.appendingPathComponent("settings.json"),
        ]
    }

    private static func projectSettingsPaths(_ environment: ClaudeImportEnvironment) -> [URL] {
        // A home directory that is itself a git repository is not a project root, or `~/.claude`
        // would count as project settings for everything below it.
        let cwd = environment.cwd.standardizedFileURL
        let root = repoRoot(cwd).flatMap { sameFile($0, environment.home) ? nil : $0 } ?? cwd
        var paths: [URL] = []
        var current = cwd
        while true {
            let claude = current.appendingPathComponent(".claude", isDirectory: true)
            paths += [claude.appendingPathComponent("settings.local.json"), claude.appendingPathComponent("settings.json")]
            if current.path == root.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return paths
    }

    /// The nearest directory at or above `start` that has a `.git` entry.
    static func repoRoot(_ start: URL) -> URL? {
        var current = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// Where project settings are written: the git work tree, or the directory itself.
    static func projectRoot(_ cwd: URL) -> URL { repoRoot(cwd) ?? cwd }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Component-wise prefix test, like Rust's `Path::starts_with`.
    static func isInside(_ path: URL, _ directory: URL) -> Bool {
        let parts = path.standardizedFileURL.pathComponents, prefix = directory.standardizedFileURL.pathComponents
        return parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// A regular file's JSON; nil when missing, unreadable, not UTF-8, or not JSON.
    static func readJSON(_ url: URL) -> ClaudeJSON? {
        guard let data = ClaudeImportFiles.regularFileContents(url), String(data: data, encoding: .utf8) != nil else { return nil }
        return try? ClaudeJSON.parse(data)
    }

    private static func stringArray(_ value: ClaudeJSON?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// Env values: strings as-is, numbers and booleans in text form, anything else skipped.
    private static func envString(_ value: ClaudeJSON) -> String? {
        switch value {
        case .string(let text): return text
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    /// Each command-type hook handler becomes one item; other handler types are skipped.
    static func hooks(in settings: ClaudeJSON) -> [ClaudeImportItem] {
        var items: [ClaudeImportItem] = []
        for (event, groups) in settings["hooks"]?.objectEntries ?? [] {
            for group in groups.arrayValue ?? [] {
                let matcher = group["matcher"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                for handler in group["hooks"]?.arrayValue ?? [] {
                    guard handler["type"]?.stringValue == "command", let command = handler["command"]?.stringValue else { continue }
                    items.append(.hook(event: event, matcher: matcher, command: command, timeout: handler["timeout"]?.uint64Value))
                }
            }
        }
        return items
    }

    /// `~/.claude.json`: this project's servers first, then the user-level ones not already listed.
    /// The terminal files both under global, and so does this.
    static func claudeJSONServers(_ environment: ClaudeImportEnvironment) -> [(name: String, server: ClaudeMCPServer)] {
        guard let json = readJSON(environment.home.appendingPathComponent(".claude.json")) else { return [] }
        var result: [(name: String, server: ClaudeMCPServer)] = []
        var names = Set<String>()
        let project = json["projects"]?.objectEntries?.last { $0.key == environment.cwd.path }?.value
        for source in [project, json].compactMap({ $0 }) {
            for (name, entry) in source["mcpServers"]?.objectEntries ?? [] {
                guard let server = ClaudeMCPConverter.convert(entry), names.insert(name).inserted else { continue }
                result.append((name, server))
            }
        }
        return result
    }

    /// `.mcp.json` files from the working directory up to the git root; nearer files win a name.
    static func mcpJSONServers(_ environment: ClaudeImportEnvironment) -> [(name: String, server: ClaudeMCPServer)] {
        var result: [(name: String, server: ClaudeMCPServer)] = []
        var names = Set<String>()
        for directory in repoDirectoryChain(environment) {
            guard let json = readJSON(directory.appendingPathComponent(".mcp.json")) else { continue }
            for (name, entry) in json["mcpServers"]?.objectEntries ?? [] {
                guard let server = ClaudeMCPConverter.convert(entry), names.insert(name).inserted else { continue }
                result.append((name, server))
            }
        }
        return result
    }

    /// The working directory up to its git root (excluding a home directory that is a repository),
    /// nearest first; just the working directory outside a repository.
    static func repoDirectoryChain(_ environment: ClaudeImportEnvironment) -> [URL] {
        guard let root = repoRoot(environment.cwd), !sameFile(root, environment.home) else { return [environment.cwd] }
        var chain: [URL] = []
        var current = environment.cwd
        while true {
            chain.append(current)
            if sameFile(current, root) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return chain
    }

    /// `~/.claude/{skills,rules}` (global) and `<repo>/.claude/{skills,rules}` (project), skipping a
    /// project directory that is the same as a global one (running from the home directory).
    private static func scanPathDirectories(_ environment: ClaudeImportEnvironment, into plan: inout ClaudeImportPlan) {
        var globalDirectories = Set<String>()
        let kinds: [(ClaudeImportPathKind, String)] = [(.skill, "skills"), (.rule, "rules")]
        for (kind, name) in kinds {
            let directory = environment.claudeDirectory.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(directory) else { continue }
            globalDirectories.insert(directory.resolvingSymlinksInPath().path)
            plan.global.append(.path(kind: kind, path: directory.path))
        }
        for (kind, name) in kinds {
            let directory = plan.projectRoot.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            guard isDirectory(directory), !globalDirectories.contains(directory.resolvingSymlinksInPath().path) else { continue }
            plan.project.append(.path(kind: kind, path: directory.path))
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

// MARK: - MCP servers

/// Converts a Claude/`.mcp.json` server entry the way the terminal deserialises `McpServerConfig`
/// (stdio when it has `command`, otherwise HTTP when it has `url`), and writes the TOML it would
/// serialise, field for field. Entries it would reject are skipped.
enum ClaudeMCPConverter {
    static func convert(_ entry: ClaudeJSON) -> ClaudeMCPServer? {
        guard case .object = entry else { return nil }
        var lines: [String] = []
        let summary: String
        if let command = entry["command"]?.stringValue,
           let args = optionalStrings(entry["args"]), let env = optionalStringMap(entry["env"]), let cwd = optionalString(entry["cwd"]) {
            lines.append("command = \(GrokConfig.quote(command))")
            lines.append("args = \(array(args ?? []))")
            if let env = env ?? nil { lines.append("env = \(inlineTable(env.map { ($0.key, GrokConfig.quote($0.value)) }))") }
            if let cwd = cwd ?? nil { lines.append("cwd = \(GrokConfig.quote(cwd))") }
            summary = ([command] + (args ?? [])).joined(separator: " ")
        } else if let url = (entry["url"] ?? entry["urlTemplate"] ?? entry["url_template"])?.stringValue,
                  let type = optionalString(entry["type"]), let bearer = optionalString(entry["bearer_token_env_var"]),
                  let headers = optionalStringMap(entry["headers"]), let clientID = optionalString(entry["oauth_client_id"]),
                  let secret = optionalString(entry["oauth_client_secret_env_var"]), let scopes = optionalStrings(entry["oauth_scopes"]) {
            lines.append("url = \(GrokConfig.quote(url))")
            if let type = type ?? nil { lines.append("type = \(GrokConfig.quote(type))") }
            if let bearer = bearer ?? nil { lines.append("bearer_token_env_var = \(GrokConfig.quote(bearer))") }
            if let headers = headers ?? nil { lines.append("headers = \(inlineTable(headers.map { ($0.key, GrokConfig.quote($0.value)) }))") }
            if let clientID = clientID ?? nil { lines.append("oauth_client_id = \(GrokConfig.quote(clientID))") }
            if let secret = secret ?? nil { lines.append("oauth_client_secret_env_var = \(GrokConfig.quote(secret))") }
            if let scopes = scopes ?? nil { lines.append("oauth_scopes = \(array(scopes))") }
            summary = url
        } else {
            return nil
        }

        // Fields shared by both transports, after the transport's own.
        let enabled = entry["enabled"]
        guard enabled == nil || enabled?.boolValue != nil else { return nil }
        lines.append("enabled = \(enabled?.boolValue ?? true)")
        guard let oauth = optionalOAuth(entry["oauth"]), let setup = optionalSetup(entry["setup"]),
              let startup = optionalUInt(entry["startup_timeout_sec"]), let tool = optionalUInt(entry["tool_timeout_sec"]),
              let toolTimeouts = optionalUIntMap(entry["tool_timeouts"]), let exposeImages = optionalBool(entry["expose_image_base64"]) else { return nil }
        if let oauth = oauth ?? nil { lines.append("oauth = \(oauth)") }
        if let setup = setup ?? nil { lines.append("setup = \(setup)") }
        if let startup = startup ?? nil { lines.append("startup_timeout_sec = \(startup)") }
        if let tool = tool ?? nil { lines.append("tool_timeout_sec = \(tool)") }
        if let toolTimeouts = toolTimeouts ?? nil { lines.append("tool_timeouts = \(inlineTable(toolTimeouts.map { ($0.key, String($0.value)) }))") }
        if let exposeImages = exposeImages ?? nil { lines.append("expose_image_base64 = \(exposeImages)") }
        return ClaudeMCPServer(lines: lines, summary: summary)
    }

    // Each `optional…` returns nil when the field has the wrong type (rejecting the entry), and
    // `.some(nil)` when it is absent or null.

    private static func optionalString(_ value: ClaudeJSON?) -> String?? {
        guard let value, !value.isNull else { return .some(nil) }
        return value.stringValue.map { .some($0) }
    }

    private static func optionalBool(_ value: ClaudeJSON?) -> Bool?? {
        guard let value, !value.isNull else { return .some(nil) }
        return value.boolValue.map { .some($0) }
    }

    private static func optionalUInt(_ value: ClaudeJSON?) -> UInt64?? {
        guard let value, !value.isNull else { return .some(nil) }
        return value.uint64Value.map { .some($0) }
    }

    private static func optionalStrings(_ value: ClaudeJSON?) -> [String]?? {
        guard let value, !value.isNull else { return .some(nil) }
        guard let items = value.arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? .some(strings) : nil
    }

    private static func optionalStringMap(_ value: ClaudeJSON?) -> [(key: String, value: String)]?? {
        guard let value, !value.isNull else { return .some(nil) }
        guard let entries = value.objectEntries else { return nil }
        var result: [(key: String, value: String)] = []
        for entry in entries {
            guard let text = entry.value.stringValue else { return nil }
            result.append((entry.key, text))
        }
        return .some(result)
    }

    private static func optionalUIntMap(_ value: ClaudeJSON?) -> [(key: String, value: UInt64)]?? {
        guard let value, !value.isNull else { return .some(nil) }
        guard let entries = value.objectEntries else { return nil }
        var result: [(key: String, value: UInt64)] = []
        for entry in entries {
            guard let number = entry.value.uint64Value else { return nil }
            result.append((entry.key, number))
        }
        return .some(result)
    }

    /// `oauth = { clientId, clientSecretEnvVar, scopes, callbackPort }` (camelCase, as Crok reads it).
    private static func optionalOAuth(_ value: ClaudeJSON?) -> String?? {
        guard let value, !value.isNull else { return .some(nil) }
        guard case .object = value, let clientID = optionalString(value["clientId"]), let secret = optionalString(value["clientSecretEnvVar"]),
              let scopes = optionalStrings(value["scopes"]), let port = optionalUInt(value["callbackPort"]) else { return nil }
        if let port = port ?? nil, port > UInt64(UInt16.max) { return nil }
        var fields: [(String, String)] = []
        if let clientID = clientID ?? nil { fields.append(("clientId", GrokConfig.quote(clientID))) }
        if let secret = secret ?? nil { fields.append(("clientSecretEnvVar", GrokConfig.quote(secret))) }
        if let scopes = scopes ?? nil { fields.append(("scopes", array(scopes))) }
        if let port = port ?? nil { fields.append(("callbackPort", String(port))) }
        return .some(inlineTable(fields))
    }

    /// Crok's single-select `setup` block: `fields` (id, label, type "select", required, default,
    /// options) and `variables` (alias `values`) mapping each name to `{ from, map }`.
    private static func optionalSetup(_ value: ClaudeJSON?) -> String?? {
        guard let value, !value.isNull else { return .some(nil) }
        guard case .object = value, value["fields"] == nil || value["fields"]?.arrayValue != nil else { return nil }
        var fields: [String] = []
        for field in value["fields"]?.arrayValue ?? [] {
            guard let id = field["id"]?.stringValue, let label = field["label"]?.stringValue, field["type"]?.stringValue == "select",
                  field["required"] == nil || field["required"]?.boolValue != nil, let fallback = optionalString(field["default"]),
                  field["options"] == nil || field["options"]?.arrayValue != nil else { return nil }
            let required = field["required"]?.boolValue ?? false
            var options: [String] = []
            for option in field["options"]?.arrayValue ?? [] {
                guard let optionLabel = option["label"]?.stringValue, let optionValue = option["value"]?.stringValue else { return nil }
                options.append(inlineTable([("label", GrokConfig.quote(optionLabel)), ("value", GrokConfig.quote(optionValue))]))
            }
            var parts = [("id", GrokConfig.quote(id)), ("label", GrokConfig.quote(label)), ("type", "\"select\""), ("required", String(required))]
            if let fallback = fallback ?? nil { parts.append(("default", GrokConfig.quote(fallback))) }
            parts.append(("options", "[" + options.joined(separator: ", ") + "]"))
            fields.append(inlineTable(parts))
        }
        var variables: [(String, String)] = []
        for (name, derived) in (value["variables"] ?? value["values"])?.objectEntries ?? [] {
            guard let from = derived["from"]?.stringValue, let map = optionalStringMap(derived["map"]), let pairs = map else { return nil }
            variables.append((name, inlineTable([("from", GrokConfig.quote(from)), ("map", inlineTable(pairs.map { ($0.key, GrokConfig.quote($0.value)) }))])))
        }
        return .some(inlineTable([("fields", "[" + fields.joined(separator: ", ") + "]"), ("variables", inlineTable(variables))]))
    }

    static func array(_ values: [String]) -> String { "[" + values.map(GrokConfig.quote).joined(separator: ", ") + "]" }

    static func inlineTable(_ fields: [(String, String)]) -> String {
        fields.isEmpty ? "{}" : "{ " + fields.map { "\(ClaudeTOMLEditor.key($0.0)) = \($0.1)" }.joined(separator: ", ") + " }"
    }
}

// MARK: - Applying

enum ClaudeImporter {
    /// Writes a plan additively: global items to `$CROK_HOME/config.toml` and
    /// `$CROK_HOME/hooks/imported-from-claude.json`, project items to the same names under
    /// `<repoRoot>/.grok/`. Existing keys, servers, and rules are never overwritten. Every file is
    /// checked and edited in memory before any is written, so a bad file stops the whole import.
    static func apply(_ plan: ClaudeImportPlan, environment: ClaudeImportEnvironment) throws -> ClaudeImportResult {
        // Settings changes elsewhere in the app use the same lock, so none is lost mid-import.
        try GrokConfig.withWriteLock { try applyLocked(plan, environment: environment) }
    }

    private static func applyLocked(_ plan: ClaudeImportPlan, environment: ClaudeImportEnvironment) throws -> ClaudeImportResult {
        struct Write { let url: URL; var contents: String; let isConfig: Bool }
        // Keyed by path, so a project whose config is the global one (a home directory that is its
        // own project) edits the text the global pass produced, as the terminal's sequential writes do.
        var writes: [String: Write] = [:]
        var order: [String] = []
        func stage(_ url: URL, _ contents: String, isConfig: Bool) {
            if writes[url.path] == nil { order.append(url.path) }
            writes[url.path] = Write(url: url, contents: contents, isConfig: isConfig)
        }
        var result = ClaudeImportResult()
        let targets: [(ClaudeImportScope, [ClaudeImportItem], URL)] = [
            (.global, plan.global, environment.grokHome),
            (.project, plan.project, plan.projectRoot.appendingPathComponent(".grok", isDirectory: true)),
        ]
        for (scope, items, directory) in targets where !items.isEmpty {
            let configURL = directory.appendingPathComponent("config.toml")
            let (config, configCount) = try editedConfig(at: configURL, base: writes[configURL.path]?.contents, with: items)
            let hooksURL = directory.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent("imported-from-claude.json")
            let (hooks, hookCount) = try editedHooks(at: hooksURL, base: writes[hooksURL.path]?.contents, with: items)
            if configCount > 0, let config { stage(configURL, config, isConfig: true) }
            if let hooks { stage(hooksURL, hooks, isConfig: false) }
            if configCount > 0 { result.modifiedFiles.append(configURL.path) }
            if hookCount > 0 { result.modifiedFiles.append(hooksURL.path) }
            if scope == .global { result.globalCount = configCount + hookCount } else { result.projectCount = configCount + hookCount }
        }
        for path in order {
            guard let write = writes[path] else { continue }
            let inGrokHome = ClaudeImportScanner.isInside(write.url, environment.grokHome)
            try ClaudeImportFiles.write(Data(write.contents.utf8), to: write.url, privateDirectory: inGrokHome, privateFile: write.isConfig)
        }
        return result
    }

    /// The config text with the items merged in, and how many were added.
    static func editedConfig(at url: URL, base: String? = nil, with items: [ClaudeImportItem]) throws -> (String?, Int) {
        let original: String
        do { original = try base ?? ClaudeImportFiles.readText(url) ?? "" }
        catch { throw ClaudeImportError.invalidConfig(path: url.path, reason: error.localizedDescription) }
        var editor: ClaudeTOMLEditor
        do { editor = try ClaudeTOMLEditor(text: original) }
        catch let error as ClaudeTOMLError { throw ClaudeImportError.invalidConfig(path: url.path, reason: error.description) }

        var permissions: [ClaudeRuleAction: [String]] = [:]
        var env: [(key: String, value: String)] = []
        var servers: [(name: String, server: ClaudeMCPServer)] = []
        var skillDirectories: [String] = [], ruleDirectories: [String] = []
        for item in items {
            switch item {
            case .permission(let rule): permissions[rule.action, default: []].append(rule.configString)
            case let .envVar(key, value): env.append((key, value))
            case let .mcpServer(name, server): servers.append((name, server))
            case .hook: break
            case let .path(kind, path): if kind == .skill { skillDirectories.append(path) } else { ruleDirectories.append(path) }
            }
        }
        var count = 0
        do {
            for action in [ClaudeRuleAction.allow, .deny, .ask] {
                count += try editor.mergeStrings(permissions[action] ?? [], into: action.rawValue, of: "permission")
            }
            count += try editor.mergeStrings(skillDirectories, into: "extra_skill_dirs", of: "paths")
            count += try editor.mergeStrings(ruleDirectories, into: "extra_rule_dirs", of: "paths")
            count += try editor.addMissingStrings(env, to: "env")
            for (name, server) in servers {
                if try editor.addTable(name, in: "mcp_servers", lines: server.lines) { count += 1 }
            }
        } catch ClaudeTOMLError.type(let message) {
            throw ClaudeImportError.typeMismatch(message)
        } catch let error as ClaudeTOMLError {
            throw ClaudeImportError.unsupportedConfig(path: url.path, reason: error.description)
        }
        return (count > 0 ? editor.text : nil, count)
    }

    /// The hooks file with new `(event, matcher, command)` handlers appended (an existing one only has
    /// its timeout refreshed), and how many were added. Nil text means nothing changed.
    static func editedHooks(at url: URL, base: String? = nil, with items: [ClaudeImportItem]) throws -> (String?, Int) {
        let hooks: [(event: String, matcher: String?, command: String, timeout: UInt64?)] = items.compactMap {
            if case let .hook(event, matcher, command, timeout) = $0 { return (event, matcher, command, timeout) }
            return nil
        }
        guard !hooks.isEmpty else { return (nil, 0) }
        var root: ClaudeJSON = .object([])
        // Like the terminal, a malformed file is replaced rather than blocking the import.
        if let text = base ?? (try? ClaudeImportFiles.readText(url)) ?? nil, let parsed = try? ClaudeJSON.parse(text) { root = parsed }
        guard var rootPairs = root.objectEntries else { throw ClaudeImportError.invalidFile(path: url.path, reason: "root is not a JSON object") }
        var hooksPairs: [(key: String, value: ClaudeJSON)]
        if let index = rootPairs.firstIndex(where: { $0.key == "hooks" }) {
            guard let pairs = rootPairs[index].value.objectEntries else { throw ClaudeImportError.invalidFile(path: url.path, reason: "hooks is not a JSON object") }
            hooksPairs = pairs
        } else {
            hooksPairs = []
        }

        var count = 0, dirty = false
        for hook in hooks {
            var groups: [ClaudeJSON]
            let eventIndex = hooksPairs.firstIndex { $0.key == hook.event }
            if let eventIndex {
                guard let existing = hooksPairs[eventIndex].value.arrayValue else {
                    throw ClaudeImportError.invalidFile(path: url.path, reason: "hooks.\(hook.event) is not a JSON array")
                }
                groups = existing
            } else {
                groups = []
            }
            if refreshTimeout(in: &groups, matcher: hook.matcher, command: hook.command, timeout: hook.timeout) {
                dirty = true
            } else {
                var handler: [(key: String, value: ClaudeJSON)] = [("type", .string("command")), ("command", .string(hook.command))]
                if let timeout = hook.timeout { handler.append(("timeout", .number(String(timeout)))) }
                var group: [(key: String, value: ClaudeJSON)] = [("hooks", .array([.object(handler)]))]
                if let matcher = hook.matcher { group.append(("matcher", .string(matcher))) }
                groups.append(.object(group))
                count += 1
            }
            if let eventIndex { hooksPairs[eventIndex].value = .array(groups) } else { hooksPairs.append((hook.event, .array(groups))) }
        }
        guard count > 0 || dirty else { return (nil, 0) }
        if let index = rootPairs.firstIndex(where: { $0.key == "hooks" }) { rootPairs[index].value = .object(hooksPairs) }
        else { rootPairs.append(("hooks", .object(hooksPairs))) }
        return (ClaudeJSON.object(rootPairs).prettyPrinted, count)
    }

    /// Updates the timeout of an existing `(matcher, command)` handler; false when there is none.
    private static func refreshTimeout(in groups: inout [ClaudeJSON], matcher: String?, command: String, timeout: UInt64?) -> Bool {
        for groupIndex in groups.indices {
            guard var group = groups[groupIndex].objectEntries, groups[groupIndex]["matcher"]?.stringValue == matcher,
                  let handlersIndex = group.firstIndex(where: { $0.key == "hooks" }), var handlers = group[handlersIndex].value.arrayValue else { continue }
            for handlerIndex in handlers.indices {
                let handler = handlers[handlerIndex]
                guard handler["type"]?.stringValue == "command", handler["command"]?.stringValue == command,
                      var fields = handler.objectEntries else { continue }
                fields.removeAll { $0.key == "timeout" && timeout == nil }
                if let timeout {
                    if let index = fields.firstIndex(where: { $0.key == "timeout" }) { fields[index].value = .number(String(timeout)) }
                    else { fields.append(("timeout", .number(String(timeout)))) }
                }
                handlers[handlerIndex] = .object(fields)
                group[handlersIndex].value = .array(handlers)
                groups[groupIndex] = .object(group)
                return true
            }
        }
        return false
    }

    /// Writes `[claude_compat] imported = true` to the global config: the user's choice to stop Crok
    /// reading `.claude/` at runtime. Recorded even when nothing was imported.
    static func markImported(_ environment: ClaudeImportEnvironment) throws {
        try GrokConfig.withWriteLock { try markImportedLocked(environment) }
    }

    private static func markImportedLocked(_ environment: ClaudeImportEnvironment) throws {
        let url = environment.globalConfig
        var editor: ClaudeTOMLEditor
        do { editor = try ClaudeTOMLEditor(text: try ClaudeImportFiles.readText(url) ?? "") }
        catch let error as ClaudeTOMLError {
            throw ClaudeImportError.invalidConfig(path: url.path, reason: error.description)
        }
        let before = editor.text
        do { try editor.setTrue("imported", in: "claude_compat") }
        catch ClaudeTOMLError.type(let message) { throw ClaudeImportError.typeMismatch(message) }
        catch let error as ClaudeTOMLError { throw ClaudeImportError.unsupportedConfig(path: url.path, reason: error.description) }
        guard editor.text != before || !FileManager.default.fileExists(atPath: url.path) else { return }
        try ClaudeImportFiles.write(Data(editor.text.utf8), to: url, privateDirectory: true, privateFile: true)
    }
}

// MARK: - State file

/// `$CROK_HOME/claude_import_state.json`: hashes of the Claude settings seen at the last import or
/// dismissal, so the terminal does not offer the import again until they change.
enum ClaudeImportState {
    /// Records the current hashes for the global scope and this working directory.
    static func markImported(_ environment: ClaudeImportEnvironment) throws {
        var state = ClaudeImportFiles.regularFileContents(environment.stateFile).flatMap { try? ClaudeJSON.parse($0) } ?? .null
        if state["version"]?.uint64Value == nil { state = .object([("version", .number("1")), ("global", .null), ("projects", .object([]))]) }
        let timestamp = rfc3339(environment.now())
        func scope(_ hash: String) -> ClaudeJSON { .object([("last_hash", .string(hash)), ("last_checked", .string(timestamp))]) }
        var projects = state["projects"]?.objectEntries ?? []
        let key = environment.cwd.path
        let projectState = scope(hash(projectPaths(environment)))
        if let index = projects.firstIndex(where: { $0.key == key }) { projects[index].value = projectState } else { projects.append((key, projectState)) }
        let version = state["version"] ?? .number("1")
        let document = ClaudeJSON.object([("version", version), ("global", scope(hash(globalPaths(environment)))), ("projects", .object(projects))])
        try ClaudeImportFiles.write(Data(document.prettyPrinted.utf8), to: environment.stateFile, privateDirectory: true, privateFile: false)
    }

    static func globalPaths(_ environment: ClaudeImportEnvironment) -> [URL] {
        [environment.claudeDirectory.appendingPathComponent("settings.json"),
         environment.claudeDirectory.appendingPathComponent("settings.local.json"),
         environment.home.appendingPathComponent(".claude.json")]
    }

    /// Project settings files (excluding `~/.claude`) plus every `.mcp.json` candidate from the
    /// working directory up to the first directory with a `.git` entry.
    static func projectPaths(_ environment: ClaudeImportEnvironment) -> [URL] {
        var paths = ClaudeImportScanner.settingsPaths(environment).filter { !ClaudeImportScanner.isInside($0, environment.claudeDirectory) }
        var current = environment.cwd
        while true {
            paths.append(current.appendingPathComponent(".mcp.json"))
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return paths
    }

    /// `sha256:<hex>` over each existing file's path and contents, in path order (compared component by
    /// component, as Rust orders paths), each followed by a NUL byte.
    static func hash(_ paths: [URL]) -> String {
        let files = paths.compactMap { url in ClaudeImportFiles.regularFileContents(url).map { (url.path, $0) } }
            .sorted { lhs, rhs in
                let a = (lhs.0 as NSString).pathComponents, b = (rhs.0 as NSString).pathComponents
                for (x, y) in zip(a, b) where x != y { return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) }
                return a.count < b.count
            }
        var hasher = SHA256()
        for (path, contents) in files {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: contents)
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3339 in UTC with microseconds and a `+00:00` offset, as `chrono` writes it.
    static func rfc3339(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.string(from: date) + "+00:00"
    }
}

// MARK: - Files

enum ClaudeImportFiles {
    /// A regular file's bytes (following symlinks, which dotfile managers often use), or nil. Reading
    /// a FIFO would block, so anything else is treated as missing.
    static func regularFileContents(_ url: URL) -> Data? {
        guard isRegularFile(url) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    /// A file's UTF-8 text, or nil when it does not exist.
    static func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard isRegularFile(url) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        return text
    }

    /// Writes atomically. Files keep their permissions; new files under `$CROK_HOME` (which may hold
    /// secrets from imported env vars) are private to the user.
    static func write(_ data: Data, to link: URL, privateDirectory: Bool, privateFile: Bool) throws {
        let manager = FileManager.default
        // Write through a symlinked file (dotfiles setups) instead of replacing the link.
        let url = link.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: privateDirectory ? [.posixPermissions: 0o700] : nil)
        }
        let existing = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        try data.write(to: url, options: .atomic)
        if let permissions = existing ?? (privateFile ? NSNumber(value: 0o600) : nil) {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}
