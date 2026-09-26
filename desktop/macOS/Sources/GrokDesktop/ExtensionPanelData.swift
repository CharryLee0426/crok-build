import Foundation

/// The terminal's `f` filter on the Plugins, Hooks, and Skills tabs.
enum ExtensionFilter: String, CaseIterable, Identifiable {
    case all = "All", enabled = "Enabled", disabled = "Disabled"
    var id: String { rawValue }
    func matches(_ enabled: Bool?) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return enabled != false
        case .disabled: return enabled == false
        }
    }
}

/// `skills/config`: automatic discovery directories, custom paths, and ignored paths.
struct SkillsDiscovery: Equatable {
    struct Source: Identifiable, Equatable {
        let path: String
        let count: Int
        var id: String { path }
    }
    var automatic: [Source] = []
    var custom: [Source] = []
    var ignored: [String] = []
    var totalSkills = 0

    static func parse(_ result: [String: Any]) -> SkillsDiscovery {
        let skills = (result["skills"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let custom = (result["paths"] as? [String] ?? []).map { path in Source(path: path, count: skills.filter { $0.hasPrefix(path) }.count) }
        return SkillsDiscovery(automatic: automaticSources(result["message"] as? String ?? ""), custom: custom,
                               ignored: result["ignore"] as? [String] ?? [], totalSkills: (result["totalSkills"] as? NSNumber)?.intValue ?? skills.count)
    }

    /// The shell reports automatic sources only in its message: "  • <dir>  (<n> skills)".
    static func automaticSources(_ message: String) -> [Source] {
        var sources: [Source] = []
        var inSection = false
        for line in message.components(separatedBy: "\n") {
            if line.hasPrefix("Skill discovery sources:") { inSection = true; continue }
            guard inSection else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\u{2022} ") else { break }
            let body = trimmed.dropFirst(2)
            if let open = body.range(of: "  (", options: .backwards) {
                let count = Int(body[open.upperBound...].prefix { $0.isNumber }) ?? 0
                sources.append(Source(path: String(body[..<open.lowerBound]), count: count))
            } else {
                sources.append(Source(path: String(body), count: 0))
            }
        }
        return sources
    }
}

/// How the terminal names a hook's source directory.
enum HookSourceLabel {
    enum Kind { case plugin, global, claude, project, custom }

    static func describe(_ sourceDir: String, grokHome: URL = GrokPaths.home, home: URL = AgentCatalog.userHome) -> (label: String, kind: Kind) {
        let grok = grokHome.standardizedFileURL.path
        let components = URL(fileURLWithPath: sourceDir).standardizedFileURL.pathComponents
        for subdirectory in ["plugins", "installed-plugins"] {
            let prefix = grok + "/" + subdirectory + "/"
            if sourceDir.hasPrefix(prefix), let name = sourceDir.dropFirst(prefix.count).split(separator: "/").first { return ("Plugin: \(name)", .plugin) }
            if let index = components.indices.dropLast(2).first(where: { components[$0] == ".grok" && components[$0 + 1] == subdirectory }) {
                return ("Plugin: \(components[index + 2])", .plugin)
            }
        }
        let global = grok + "/hooks"
        if sourceDir == global || sourceDir.hasPrefix(global + "/") { return ("Global hooks", .global) }
        if sourceDir.contains("/.claude/") { return ("Claude settings", .claude) }
        if sourceDir.hasSuffix("/.grok/hooks") || sourceDir.contains("/.grok/hooks/") { return ("Project hooks", .project) }
        if sourceDir.hasPrefix(grok + "/") {
            let prefix = ProcessInfo.processInfo.environment["CROK_HOME"].map { _ in "$CROK_HOME" } ?? "~/.crok"
            return ("Custom: \(prefix)/\(sourceDir.dropFirst(grok.count + 1))", .custom)
        }
        let homePath = home.standardizedFileURL.path
        if sourceDir == homePath { return ("Custom: ~", .custom) }
        if sourceDir.hasPrefix(homePath + "/") { return ("Custom: ~/\(sourceDir.dropFirst(homePath.count + 1))", .custom) }
        return ("Custom: \(sourceDir)", .custom)
    }

    /// Display names for `HookEvent` wire values.
    static func event(_ value: String) -> String {
        [
            "session_start": "Session Start", "session_end": "Session End", "stop": "Stop", "stop_failure": "Stop Failure",
            "stop_cancelled": "Stop Cancelled", "pre_tool_use": "Pre-Tool Use", "post_tool_use": "Post-Tool Use",
            "post_tool_use_failure": "Post-Tool Use Failure", "permission_denied": "Permission Denied",
            "user_prompt_submit": "Prompt Submit", "notification": "Notification", "subagent_start": "Subagent Start",
            "subagent_stop": "Subagent Stop", "pre_compact": "Pre-Compact", "post_compact": "Post-Compact",
        ][value] ?? value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Hooks from one source directory, toggled together with `toggle_source`.
struct HookSourceGroup: Identifiable {
    let sourceDir: String
    let label: String
    let hooks: [FeatureRow]
    var id: String { sourceDir }
    var removable: Bool { hooks.contains { $0.payload["removable"] as? Bool == true } }
    var pinned: Bool { hooks.contains { $0.payload["pinned"] as? Bool == true } }
    /// Direction comes from the hooks policy does not pin; an all-pinned group reads as enabled.
    var anyEnabled: Bool {
        let unpinned = hooks.filter { $0.payload["pinned"] as? Bool != true }
        return unpinned.isEmpty || unpinned.contains { $0.enabled != false }
    }

    static func groups(_ rows: [FeatureRow]) -> [HookSourceGroup] {
        var order: [String] = []
        var grouped: [String: [FeatureRow]] = [:]
        for row in rows {
            let source = row.payload["sourceDir"] as? String ?? ""
            if grouped[source] == nil { order.append(source) }
            grouped[source, default: []].append(row)
        }
        return order.map { HookSourceGroup(sourceDir: $0, label: HookSourceLabel.describe($0).label, hooks: grouped[$0] ?? []) }
    }
}

/// The Plugins tab's source groups, from `origin` (older shells: scope and marketplace source).
enum PluginGroupLabel {
    static func group(_ plugin: [String: Any]) -> (rank: Int, key: String, label: String) {
        let origin = plugin["origin"] as? [String: Any]
        switch origin?["type"] as? String {
        case "project_grok"?: return (0, "origin:project", "Project")
        case "project_claude"?: return (1, "origin:project-claude", "Project (Claude)")
        case "user_grok"?: return (2, "origin:user", "User")
        case "user_claude"?: return (3, "origin:user-claude", "User (Claude)")
        case "claude_installed"?:
            guard let marketplace = origin?["marketplace"] as? String else { return (3, "origin:user-claude", "User (Claude)") }
            return (4, "claude-mp:\(marketplace)", marketplace)
        case "claude_marketplace"?:
            let marketplace = origin?["marketplace"] as? String ?? "Marketplace"
            return (4, "claude-mp:\(marketplace)", marketplace)
        case "marketplace_install"?:
            guard let source = origin?["source_name"] as? String else { return (6, "origin:direct", "Direct installs") }
            return (5, "grok-mp:\(source)", source)
        case "cli_override"?: return (7, "origin:cli", "CLI override")
        case "config_path"?: return (8, "origin:config", "Custom paths")
        default:
            switch plugin["scope"] as? String {
            case "project": return (0, "origin:project", "Project")
            case "cli": return (7, "origin:cli", "CLI override")
            case "config": return (8, "origin:config", "Custom paths")
            default:
                guard let source = plugin["marketplaceSource"] as? String else { return (2, "origin:user", "User") }
                if source.hasPrefix("git: ") { return (6, "origin:direct", "Direct installs") }
                return (5, "grok-mp:\(source)", source)
            }
        }
    }

    /// Short capability badges for a plugin row.
    static func badges(_ plugin: [String: Any]) -> [String] {
        func count(_ key: String) -> Int { (plugin[key] as? NSNumber)?.intValue ?? 0 }
        var badges: [String] = []
        if let version = plugin["version"] as? String, !version.isEmpty { badges.append("v\(version)") }
        let skills = count("skillCount"), agents = count("agentCount"), hooks = count("hookCount"), servers = count("mcpServerCount")
        if skills > 0 { badges.append(skills == 1 ? "1 skill" : "\(skills) skills") }
        if agents > 0 { badges.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        if hooks > 0 { badges.append(hooks == 1 ? "1 hook" : "\(hooks) hooks") }
        if servers > 0 { badges.append(servers == 1 ? "1 MCP server" : "\(servers) MCP servers") }
        if plugin["hookStatus"] as? String == "blocked" { badges.append("Hooks blocked") }
        if plugin["mcpStatus"] as? String == "blocked" { badges.append("MCP blocked") }
        return badges
    }
}
