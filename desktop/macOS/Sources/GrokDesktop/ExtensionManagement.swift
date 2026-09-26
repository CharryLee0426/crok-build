import Foundation
import AppKit

// MARK: - Wire payloads

/// `_x.ai/plugins/action` actions: tagged by `type`, snake_case fields.
enum PluginsWireAction: Equatable {
    case reload
    case install(source: String)
    case uninstall(pluginID: String, confirmed: Bool)
    case update(pluginID: String?)
    case add(path: String)
    case remove(path: String)
    case enable(pluginID: String)
    case disable(pluginID: String)

    var wire: [String: Any] {
        switch self {
        case .reload: return ["type": "reload"]
        case .install(let source): return ["type": "install", "source": source]
        case .uninstall(let id, let confirmed): return ["type": "uninstall", "plugin_id": id, "confirmed": confirmed]
        case .update(let id): return id.map { ["type": "update", "plugin_id": $0] } ?? ["type": "update"]
        case .add(let path): return ["type": "add", "path": path]
        case .remove(let path): return ["type": "remove", "path": path]
        case .enable(let id): return ["type": "enable", "plugin_id": id]
        case .disable(let id): return ["type": "disable", "plugin_id": id]
        }
    }

    /// The same action with the confirmation the harness asked for.
    var confirmed: PluginsWireAction? {
        if case .uninstall(let id, false) = self { return .uninstall(pluginID: id, confirmed: true) }
        return nil
    }
}

/// `_x.ai/hooks/action` actions.
enum HooksWireAction: Equatable {
    case reload, trust, untrust
    case add(path: String)
    case remove(path: String)
    case enable(hookName: String)
    case disable(hookName: String)
    case toggleSource(hookNames: [String], disable: Bool)

    var wire: [String: Any] {
        switch self {
        case .reload: return ["type": "reload"]
        case .trust: return ["type": "trust"]
        case .untrust: return ["type": "untrust"]
        case .add(let path): return ["type": "add", "path": path]
        case .remove(let path): return ["type": "remove", "path": path]
        case .enable(let name): return ["type": "enable", "hook_name": name]
        case .disable(let name): return ["type": "disable", "hook_name": name]
        case .toggleSource(let names, let disable): return ["type": "toggle_source", "hook_names": names, "disable": disable]
        }
    }
}

/// `_x.ai/marketplace/action` actions. Sources are identified by their canonical URL or path.
enum MarketplaceWireAction: Equatable {
    case refresh(source: String?)
    case install(source: String, plugin: String)
    case update(source: String, plugin: String)
    case uninstall(source: String, plugin: String)
    case addSource(url: String)
    case removeSource(source: String)

    var wire: [String: Any] {
        switch self {
        case .refresh(let source): return source.map { ["type": "refresh", "source_url_or_path": $0] } ?? ["type": "refresh"]
        case .install(let source, let plugin): return ["type": "install", "source_url_or_path": source, "plugin_relative_path": plugin]
        case .update(let source, let plugin): return ["type": "update", "source_url_or_path": source, "plugin_relative_path": plugin]
        case .uninstall(let source, let plugin): return ["type": "uninstall", "source_url_or_path": source, "plugin_relative_path": plugin]
        case .addSource(let url): return ["type": "add_source", "url": url]
        case .removeSource(let source): return ["type": "remove_source", "source_url_or_path": source]
        }
    }

    /// What the panel shows while the action runs, as in the terminal.
    var pendingLabel: String {
        switch self {
        case .refresh: return "Refreshing..."
        case .install: return "Installing..."
        case .update: return "Updating..."
        case .uninstall: return "Uninstalling..."
        case .addSource: return "Adding source..."
        case .removeSource: return "Removing source..."
        }
    }
}

/// The shared `ActionOutcome` of the hooks, plugins, and marketplace actions.
struct ExtensionActionOutcome: Equatable {
    var status: String
    var message: String
    var requiresReload = false
    var requiresRestart = false

    var succeeded: Bool { status == "success" }
    var needsConfirmation: Bool { status == "confirmation_required" }

    /// Unwraps the `{result, error}` envelope without treating a non-success status as an error,
    /// because `confirmation_required` must reach the caller.
    static func parse(_ response: [String: Any]) throws -> ExtensionActionOutcome {
        if let message = response["error"] as? String { throw DesktopError.message(message) }
        if let error = response["error"] as? [String: Any] { throw DesktopError.message(error["message"] as? String ?? "The runtime rejected the request.") }
        let result = response["result"] as? [String: Any] ?? response
        guard let status = result["status"] as? String else { throw DesktopError.message("The harness returned an unexpected reply.") }
        return ExtensionActionOutcome(status: status, message: result["message"] as? String ?? "",
            requiresReload: result["requiresReload"] as? Bool ?? false, requiresRestart: result["requiresRestart"] as? Bool ?? false)
    }
}

enum ExtensionErrorText {
    /// ACP errors often carry the useful detail in `data` (for example "session not found: …").
    static func describe(_ error: Error) -> String {
        if case ACPClientError.remote(let code, let message, let data) = error {
            if code == -32601 { return "This version of the Grok harness doesn't support that request." }
            if let detail = data as? String, !detail.isEmpty, detail != message { return "\(message): \(detail)" }
            return message
        }
        return error.localizedDescription
    }
}

// MARK: - MCP servers

/// The terminal's one-field MCP form: "https://... or command [args...]" plus an optional name.
struct MCPAddRequest: Equatable {
    var name: String
    var url: String?
    var command: String?
    var arguments: [String] = []

    static func parse(urlOrCommand: String, name: String) -> MCPAddRequest? {
        let parts = urlOrCommand.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = parts.first else { return nil }
        let isURL = first.hasPrefix("http://") || first.hasPrefix("https://")
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = !trimmedName.isEmpty ? trimmedName : isURL ? derivedName(first) : first
        return isURL ? MCPAddRequest(name: resolvedName, url: first)
            : MCPAddRequest(name: resolvedName, command: first, arguments: Array(parts.dropFirst()))
    }

    /// `https://mcp.linear.app/mcp` becomes `linear`; `https://example.com/mcp` becomes `example`.
    static func derivedName(_ url: String) -> String {
        let afterScheme = url.components(separatedBy: "://").dropFirst().first ?? url
        let host = afterScheme.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            .first { !$0.isEmpty && $0 != "mcp" && $0 != "www" } ?? "server"
    }

    /// The flattened `mcp/upsert` configuration.
    var configuration: [String: Any] {
        var value: [String: Any] = ["server_name": name, "enabled": true]
        if let url { value["url"] = url } else { value["command"] = command ?? ""; value["args"] = arguments }
        return value
    }
}

extension AppStore {
    func addMCPServer(name: String, transport: String, endpoint: String, arguments: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !endpoint.isEmpty else { featureError = "Enter a server name and connection details."; return }
        var configuration: [String: Any] = ["server_name": name, "enabled": true]
        if transport == "http" {
            guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                featureError = "Enter an HTTP or HTTPS server URL."; return
            }
            configuration["url"] = endpoint
        } else {
            configuration["command"] = endpoint
            // One argument per line avoids silently invoking a shell or guessing quoting.
            configuration["args"] = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        upsertMCPServer(configuration)
    }

    /// Adds a server from the terminal-style form. Returns false when the input is unusable.
    @discardableResult
    func addMCPServer(urlOrCommand: String, name: String) -> Bool {
        guard let request = MCPAddRequest.parse(urlOrCommand: urlOrCommand, name: name) else {
            featureError = "Required: URL / Command"; return false
        }
        if let url = request.url, URL(string: url)?.host == nil { featureError = "Enter an HTTP or HTTPS server URL."; return false }
        upsertMCPServer(request.configuration)
        features.extensions.notice = ExtensionNotice(panel: .mcps, text: "Added MCP server “\(request.name)”.")
        return true
    }

    private func upsertMCPServer(_ configuration: [String: Any]) {
        performFeatureAction(.mcps) { client, _, session in
            var params = configuration; params["session_id"] = session
            _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/upsert", params: params, timeout: 60))
        }
    }

    func removeMCPServer(_ name: String) {
        performFeatureAction(.mcps) { client, _, session in
            _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/delete", params: ["session_id": session, "server_name": name]))
        }
    }

    func toggleMCPTool(server: String, tool: String, enabled: Bool) {
        performFeatureAction(.mcps) { client, _, session in
            _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/toggle_tool", params: ["session_id": session, "server_name": server, "tool_name": tool, "enabled": enabled]))
        }
    }

    // MARK: Skills

    func addSkillFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = true
        picker.message = "Choose a skill folder or SKILL.md file."; picker.prompt = "Add skill"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        addSkillPath(url.path)
    }

    func addSkillPath(_ path: String) {
        guard let cwd = project?.path else { featureError = "Open a project first."; return }
        performFeatureAction(.skills) { client, _, _ in
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/skills/add", params: ["cwd": cwd, "path": path]))
            if let message = result["message"] as? String { self.features.extensions.notice = ExtensionNotice(panel: .skills, text: message) }
        }
    }

    /// Removes a custom discovery path (`[skills].paths`).
    func removeSkillPath(_ path: String) {
        guard let cwd = project?.path else { featureError = "Open a project first."; return }
        performFeatureAction(.skills) { client, _, _ in
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/skills/remove", params: ["cwd": cwd, "path": path]))
            if let message = result["message"] as? String { self.features.extensions.notice = ExtensionNotice(panel: .skills, text: message) }
        }
    }

    /// Restores the default skills configuration.
    func resetSkillsConfig() {
        guard let cwd = project?.path else { featureError = "Open a project first."; return }
        performFeatureAction(.skills) { client, _, _ in
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/skills/reset", params: ["cwd": cwd]))
            self.features.extensions.notice = ExtensionNotice(panel: .skills, text: result["message"] as? String ?? "Custom skills config reset")
        }
    }

    // MARK: Plugins and hooks

    /// Runs a plugins action. `confirmation_required` asks the user through the panel and, once
    /// confirmed, sends the same action again with `confirmed: true`.
    func runPluginsAction(_ action: PluginsWireAction) {
        runOutcomeAction(.plugins, method: "plugins/action", action: action.wire, retry: action.confirmed.map { confirmed in { self.runPluginsAction(confirmed) } })
    }

    func runHooksAction(_ action: HooksWireAction) {
        runOutcomeAction(.hooks, method: "hooks/action", action: action.wire, retry: nil)
    }

    private func runOutcomeAction(_ panel: FeaturePanel, method: String, action: [String: Any], retry: (() -> Void)?) {
        let extensions = features.extensions
        extensions.notice = nil
        performFeatureAction(panel) { client, _, session in
            let outcome = try ExtensionActionOutcome.parse(try await client.request("_x.ai/\(method)", params: ["sessionId": session, "action": action], timeout: 300))
            if outcome.needsConfirmation {
                if let retry { extensions.pendingConfirmation = ExtensionConfirmation(panel: panel, message: outcome.message, confirmTitle: "Continue", run: retry); return }
                throw DesktopError.message(outcome.message)
            }
            guard outcome.succeeded else { throw DesktopError.message(outcome.message.isEmpty ? outcome.status.replacingOccurrences(of: "_", with: " ") : outcome.message) }
            if outcome.requiresReload {
                _ = try? await client.request("_x.ai/plugins/action", params: ["sessionId": session, "action": PluginsWireAction.reload.wire], timeout: 120)
            }
            var text = outcome.message
            if outcome.requiresRestart { text += (text.isEmpty ? "" : "\n") + "Start a new task for the change to take effect." }
            if !text.isEmpty { extensions.notice = ExtensionNotice(panel: panel, text: text) }
        }
    }
}

struct MCPToolChoice: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let enabled: Bool

    static func from(_ row: FeatureRow) -> [MCPToolChoice] {
        let session = row.payload["session"] as? [String: Any] ?? [:]
        return (session["tools"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return MCPToolChoice(name: name, description: item["description"] as? String ?? "", enabled: item["enabled"] as? Bool ?? true)
        }
    }
}
