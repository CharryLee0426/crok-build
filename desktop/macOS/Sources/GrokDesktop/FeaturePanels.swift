import AppKit
import Foundation

/// Extension panels: MCP servers, skills, plugins, marketplace, hooks, memory, workflows, agents, personas.
extension AppStore {
    func refreshFeatures(_ panel: FeaturePanel) async {
        let extensions = features.extensions
        if panel == .memory { await extensions.memory.load(); return }
        let requestID = UUID()
        // Reloading the same panel keeps its rows on screen instead of flashing an empty list.
        let rowsKey = "\(panel.rawValue)|\(project?.id.uuidString ?? "")|\(state.selectedConversationID?.uuidString ?? "")"
        featureRequestID = requestID; featureLoading = true; featureError = nil
        if extensions.rowsKey != rowsKey { featureRows = [] }
        extensions.rowsKey = rowsKey
        defer { if featureRequestID == requestID { featureLoading = false } }
        guard let project else { featureError = "Open a project first."; featureRows = []; return }
        do {
            if [.plan, .models, .reasoning, .history, .transcript].contains(panel) { return }
            if panel == .goals { featureRows = goalRows(); return }
            var temporary: ACPClient?
            let temporaryID = UUID()
            defer { temporary?.stop(); auxiliaryClients.removeValue(forKey: temporaryID) }
            let client: ACPClient
            var session: String?
            var id = state.selectedConversationID
            if [.skills, .personas, .agentDefinitions].contains(panel), id == nil {
                let fresh = ACPClient(); temporary = fresh; client = fresh
                auxiliaryClients[temporaryID] = fresh
                try fresh.start(executable: binaryPath, cwd: project.path)
                let initial = try await initialize(fresh)
                try await authenticate(fresh, initial: initial)
            } else {
                let context = try await featureSession(); client = context.0; id = context.1; session = context.2
            }
            var params: [String: Any] = ["cwd": project.path]
            if let session { params["sessionId"] = session }
            let method: String
            switch panel {
            case .mcps: method = "mcp/list"
            case .skills: method = "skills/list"
            case .agents: method = "subagent/list_running"
            case .plugins: method = "plugins/list"
            case .marketplace: method = "marketplace/list"
            case .hooks: method = "hooks/list"
            case .workflows: method = "workflows/list"
            case .personas, .agentDefinitions: method = "bundle/status"
            default: return
            }
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/\(method)", params: params, timeout: method == "marketplace/list" ? 180 : 60))
            let isCurrent = { self.featureRequestID == requestID && self.project?.id == project.id && self.state.selectedConversationID == id }
            guard isCurrent() else { return }
            switch panel {
            case .agents:
                if let id {
                    for item in result["subagents"] as? [[String: Any]] ?? [] { updateSubagent(item, id: id) }
                    featureRows = runs[id]?.subagents.map(\.row) ?? []
                }
            case .marketplace:
                extensions.marketplace.apply(result)
                featureRows = []
            case .hooks:
                extensions.hooksTrusted = result["projectTrusted"] as? Bool
                extensions.hooksLoadErrors = result["loadErrors"] as? [String] ?? []
                featureRows = rows(for: panel, result: result, project: project)
            case .agentDefinitions:
                // Plugin agents are optional extras: an older harness without `plugins/list` still lists the rest.
                let plugins = try? ExtensionResponse.unwrap(try await client.request("_x.ai/plugins/list", params: ["sessionId": session ?? ""]))
                let active = await activeAgentName(id: id)
                guard isCurrent() else { return }
                extensions.reloadAgentConfig()
                extensions.activeAgent = active
                featureRows = agentDefinitionRows(bundle: result, plugins: plugins?["plugins"] as? [[String: Any]] ?? [], project: project)
            case .skills:
                featureRows = rows(for: panel, result: result, project: project)
                let config = try? ExtensionResponse.unwrap(try await client.request("_x.ai/skills/config", params: ["cwd": project.path], timeout: 60))
                guard isCurrent() else { return }
                extensions.skillsDiscovery = config.map(SkillsDiscovery.parse)
            default:
                featureRows = rows(for: panel, result: result, project: project)
            }
        } catch {
            if featureRequestID == requestID { featureError = error.localizedDescription }
        }
    }

    /// The agent running the selected task, when it is already connected (never starts a session).
    private func activeAgentName(id: UUID?) async -> String? {
        guard let id, let client = clients[id], loaded.contains(id), let session = task(id)?.sessionID,
              let info = try? ExtensionResponse.unwrap(try await client.request("_x.ai/session/info", params: ["sessionId": session])) else { return nil }
        return info["agentName"] as? String
    }

    private func rows(for panel: FeaturePanel, result: [String: Any], project: Project) -> [FeatureRow] {
        switch panel {
        case .mcps:
            return (result["servers"] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let session = item["session"] as? [String: Any] ?? [:]
                let tools = session["tools"] as? [[String: Any]] ?? []
                let detail = ([item["url"] as? String ?? item["command"] as? String ?? "", session["blockedReason"] as? String ?? ""] + tools.map { "\($0["name"] as? String ?? "Tool"): \($0["description"] as? String ?? "")" }).filter { !$0.isEmpty }.joined(separator: "\n")
                return FeatureRow(id: name, title: item["displayName"] as? String ?? name,
                    subtitle: "\(session["status"] as? String ?? "Configured") · \(tools.count) tools", detail: detail,
                    enabled: session["enabled"] as? Bool, actions: ["Restart"] + (session["authRequired"] as? Bool == true ? ["Sign in"] : []), payload: item)
            }
        case .skills:
            let skills = result["skills"] as? [[String: Any]] ?? []
            return skills.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let plugin = item["plugin_name"] as? String
                let path = item["path"] as? String
                let invocation = run.commands.first(where: { path != nil && $0.skillPath == path })?.name ?? "\(plugin ?? item["scope"] as? String ?? "user"):\(name)"
                var payload = item; payload["invocation"] = invocation
                let uniqueID = skills.filter { $0["name"] as? String == name }.count > 1 ? (path ?? invocation) : name
                return FeatureRow(id: uniqueID, title: item["display_name"] as? String ?? name,
                    subtitle: item["short_description"] as? String ?? item["description"] as? String ?? "",
                    detail: [plugin ?? item["scope"] as? String ?? "", item["path"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                    enabled: item["enabled"] as? Bool ?? true,
                    actions: item["user_invocable"] as? Bool == false || item["enabled"] as? Bool == false ? [] : ["Use"], payload: payload)
            }
        case .plugins, .hooks, .workflows:
            let key = panel.rawValue
            return (result[key] as? [[String: Any]] ?? []).enumerated().map { index, item in
                let name = item["name"] as? String ?? item["id"] as? String ?? "\(key) \(index + 1)"
                let enabled = panel == .workflows ? nil : item["enabled"] as? Bool ?? !(item["disabled"] as? Bool ?? false)
                let subtitle = panel == .hooks ? HookSourceLabel.event(item["event"] as? String ?? "") : item["description"] as? String ?? item["event"] as? String ?? ""
                return FeatureRow(id: item["id"] as? String ?? name, title: name, subtitle: subtitle,
                    detail: item["path"] as? String ?? item["root"] as? String ?? item["command"] as? String ?? item["url"] as? String ?? "",
                    enabled: enabled, actions: panel == .workflows ? ["Use"] : ["Reload"], payload: item)
            }
        case .personas:
            return personaRows(bundle: result, project: project)
        default: return []
        }
    }

    /// Built-ins, discovered definition files, bundled catalog names, and plugin agents, as the terminal lists them.
    private func agentDefinitionRows(bundle: [String: Any], plugins: [[String: Any]], project: Project) -> [FeatureRow] {
        let pluginAgents = plugins.filter { $0["enabled"] as? Bool != false }.flatMap { plugin in
            (plugin["agentNames"] as? [String] ?? []).map { (plugin: plugin["name"] as? String ?? "plugin", agent: $0) }
        }
        let entries = AgentCatalog.entries(cwd: URL(fileURLWithPath: project.path), bundledNames: bundle["agents"] as? [String] ?? [], pluginAgents: pluginAgents)
        let config = features.extensions.agentConfig
        return entries.map { entry in
            var payload: [String: Any] = ["kind": "agent", "name": entry.name, "scope": entry.scope.rawValue, "description": entry.description]
            if let path = entry.path { payload["path"] = path }
            if let plugin = entry.pluginName { payload["plugin"] = plugin }
            return FeatureRow(id: entry.id, title: entry.name, subtitle: entry.description, enabled: config.isEnabled(entry.name),
                              actions: ["Inspect"], payload: payload)
        }
    }

    /// Bundled personas first, then project and user persona files whose names are new.
    private func personaRows(bundle: [String: Any], project: Project) -> [FeatureRow] {
        let details = bundle["personaDetails"] as? [[String: Any]] ?? []
        let bundledDirectory = GrokPaths.home.appendingPathComponent("bundled/personas")
        var names = Set<String>()
        var rows: [FeatureRow] = (bundle["personas"] as? [String] ?? []).map { name in
            names.insert(name)
            let description = details.first(where: { $0["name"] as? String == name })?["description"] as? String ?? ""
            var payload: [String: Any] = ["kind": "persona", "name": name, "scope": "bundled", "description": description]
            let file = bundledDirectory.appendingPathComponent("\(name).toml")
            if FileManager.default.fileExists(atPath: file.path) { payload["path"] = file.path }
            return FeatureRow(id: "bundled:\(name)", title: name, subtitle: "Bundled", detail: description, actions: ["Inspect"], payload: payload)
        }
        for scope in [PersonaScope.project, .user] {
            let directory = PersonaStore.directory(scope, cwd: URL(fileURLWithPath: project.path))
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard !names.contains(name), let fields = PersonaStore.read(file) else { continue }
                names.insert(name)
                let description = fields.description.isEmpty ? Self.firstParagraph(fields.instructions) : fields.description
                rows.append(FeatureRow(id: file.path, title: name, subtitle: scope.title, detail: description, actions: ["Open"],
                    payload: ["kind": "persona", "name": name, "scope": scope.rawValue, "description": description, "path": file.path, "editable": true]))
            }
        }
        return rows
    }

    private static func firstParagraph(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").first?
            .replacingOccurrences(of: "\n", with: " ") ?? ""
    }

    func goalRows() -> [FeatureRow] {
        guard let goal = run.goal, goal.status != "cleared" else { return [] }
        return [FeatureRow(id: goal.id, title: goal.objective, subtitle: "\(goal.status) · \(goal.phase)",
            detail: "\(goal.tokensUsed) tokens" + (goal.tokenBudget.map { " of \($0)" } ?? "") + (goal.detail.isEmpty ? "" : "\n\(goal.detail)"),
            actions: ["Status"] + (goal.isActive ? ["Pause"] : goal.isPaused ? ["Resume"] : []) + ["Clear"])]
    }

    func toggleFeature(_ row: FeatureRow, panel: FeaturePanel) {
        guard let enabled = row.enabled else { return }
        if panel == .agentDefinitions {
            // Agent toggles live in config.toml and apply to new sessions; no harness call.
            features.extensions.setAgentEnabled(row.payload["name"] as? String ?? row.title, enabled: !enabled)
            if let index = featureRows.firstIndex(where: { $0.id == row.id }) {
                featureRows[index].enabled = features.extensions.agentConfig.isEnabled(row.payload["name"] as? String ?? row.title)
            }
            return
        }
        let cwd = project?.path ?? ""
        performFeatureAction(panel) { client, _, session in
            var params: [String: Any]
            let method: String
            switch panel {
            case .mcps: method = "mcp/toggle"; params = ["session_id": session, "server_name": row.id, "enabled": !enabled]
            case .skills: method = "skills/toggle"; params = ["name": row.payload["name"] as? String ?? row.id, "enabled": !enabled, "cwd": cwd]
            case .plugins: method = "plugins/action"; params = ["sessionId": session, "action": (enabled ? PluginsWireAction.disable(pluginID: row.id) : .enable(pluginID: row.id)).wire]
            case .hooks: method = "hooks/action"; params = ["sessionId": session, "action": (enabled ? HooksWireAction.disable(hookName: row.id) : .enable(hookName: row.id)).wire]
            case .memory: method = "memory/toggle"; params = ["sessionId": session, "enabled": !enabled]
            default: return
            }
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/\(method)", params: params))
            if [.plugins, .hooks].contains(panel), let message = result["message"] as? String, !message.isEmpty {
                self.features.extensions.notice = ExtensionNotice(panel: panel, text: message)
            }
        }
    }

    func invokeFeature(_ row: FeatureRow, panel: FeaturePanel, action: String, arguments: String = "") {
        let action = action.lowercased()
        if panel == .goals { goalAction(action); return }
        if action == "run" || action == "use" {
            featurePanel = nil
            if panel == .skills { draft = "/\(row.payload["invocation"] as? String ?? row.id) " + arguments }
            else if panel == .workflows { draft = "/workflow \(row.title) " + arguments }
            return
        }
        if action == "open", let path = row.payload["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return
        }
        if action == "inspect", [.personas, .agentDefinitions].contains(panel), row.payload["path"] != nil || row.payload["scope"] as? String == AgentDefinitionEntry.Scope.builtIn.rawValue || row.payload["plugin"] != nil {
            showLocalDefinition(row); return
        }
        performFeatureAction(panel, refresh: action != "inspect") { client, id, session in
            var result: [String: Any] = [:]
            switch (panel, action) {
            case (.mcps, "restart"):
                _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/toggle", params: ["session_id": session, "server_name": row.id, "enabled": false]))
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/toggle", params: ["session_id": session, "server_name": row.id, "enabled": true]))
            case (.mcps, "sign in"):
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/mcp/auth_trigger", params: ["session_id": session, "server_name": row.id], timeout: 120))
            case (.agents, "stop"):
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/subagent/cancel", params: ["subagentId": row.id]))
                if let outcome = result["outcome"] as? [String: Any], let index = self.runs[id]?.subagents.firstIndex(where: { $0.id == row.id }) {
                    if outcome["kind"] as? String == "already_finished" { self.runs[id]?.subagents[index].status = outcome["status"] as? String ?? "completed" }
                    else if outcome["kind"] as? String == "not_found" { self.runs[id]?.subagents[index].status = "unavailable" }
                }
            case (.agents, "inspect"):
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/subagent/get", params: ["subagentId": row.id, "block": false]))
                if let snapshot = result["snapshot"] as? [String: Any] { self.updateSubagent(snapshot, id: id) }
            case (.agents, "message"):
                guard !arguments.isEmpty, let address = self.runs[id]?.subagents.first(where: { $0.id == row.id })?.address else { throw DesktopError.message("Enter a message for an active subagent.") }
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/subagent/message", params: ["sessionId": session, "agentAddress": address, "content": [["type": "text", "text": arguments]]]))
                guard result["kind"] as? String == "accepted" else { throw DesktopError.message("The subagent did not accept the message (\(result["kind"] as? String ?? "unknown outcome")).") }
            case (.personas, "inspect"), (.agentDefinitions, "inspect"):
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/bundle/entry/get", params: ["kind": row.payload["kind"] as? String ?? "agents", "name": row.payload["name"] as? String ?? row.title]))
                if let content = result["content"] as? String { self.setDefinition(content, for: row.id) }
                result["message"] = nil
            case (.hooks, "reload"), (.plugins, "reload"):
                result = try ExtensionResponse.unwrap(try await client.request("_x.ai/\(panel.rawValue)/action", params: ["sessionId": session, "action": ["type": "reload"]]))
            default: throw DesktopError.message("This action is not available for \(panel.title).")
            }
            if let message = result["message"] as? String, !message.isEmpty {
                self.features.extensions.notice = ExtensionNotice(panel: panel, text: message)
            }
        }
    }

    /// Shows a definition that lives on disk (or is built in) without a harness round trip.
    private func showLocalDefinition(_ row: FeatureRow) {
        let name = row.payload["name"] as? String ?? row.title
        guard let path = row.payload["path"] as? String else {
            let description = row.payload["description"] as? String ?? row.subtitle
            let origin = (row.payload["plugin"] as? String).map { "Provided by the \($0) plugin and spawned as a subagent through the Task tool." } ?? "Built into Grok Build."
            setDefinition("# \(name)\n\n\(description.isEmpty ? "" : description + "\n\n")\(origin)", for: row.id)
            return
        }
        let rowID = row.id
        Task {
            let text = await Task.detached { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }.value
            setDefinition(text.isEmpty ? "The definition file could not be read:\n\(path)" : text, for: rowID)
        }
    }

    private func setDefinition(_ content: String, for rowID: String) {
        guard let index = featureRows.firstIndex(where: { $0.id == rowID }) else { return }
        featureRows[index].detail = content
        featureRows[index].payload["content"] = content
    }

    func performFeatureAction(_ panel: FeaturePanel, refresh: Bool = true, action: @escaping (ACPClient, UUID, String) async throws -> Void) {
        guard !featureLoading else { return }
        let requestID = UUID()
        featureRequestID = requestID
        let project = self.project
        let selectedID = state.selectedConversationID
        let selectedPanel = featurePanel
        featureLoading = true; featureError = nil
        Task {
            defer { if featureRequestID == requestID { featureLoading = false } }
            do {
                guard self.project?.id == project?.id, self.state.selectedConversationID == selectedID else { throw CancellationError() }
                let context = try await featureSession()
                guard self.project?.id == project?.id, self.state.selectedConversationID == context.1 else { throw CancellationError() }
                try await action(context.0, context.1, context.2)
                guard featureRequestID == requestID, self.project?.id == project?.id, self.state.selectedConversationID == context.1, self.featurePanel == selectedPanel else { return }
                if let project { try await loadCommands(context.0, id: context.1, project: project) }
                guard featureRequestID == requestID, self.state.selectedConversationID == context.1, self.featurePanel == selectedPanel else { return }
                if refresh { await refreshFeatures(panel) }
                else if panel == .agents { featureRows = runs[context.1]?.subagents.map(\.row) ?? [] }
            } catch {
                if featureRequestID == requestID, !(error is CancellationError), self.featurePanel == selectedPanel { featureError = error.localizedDescription }
            }
        }
    }
}
