import AppKit
import Foundation

extension AppStore {
    var availableCommands: [SlashCommand] {
        var commands = DesktopCommands.catalog.filter { command in
            guard !command.isHidden else { return false }
            // As in the terminal: /announcements only while there are some.
            if command.name == "announcements" && !features.account.hasSessionAnnouncements { return false }
            guard let tool = MediaCommand.requiredTool(command.name) else { return true }
            return run.availableTools?.contains(tool) == true
        }
        for command in run.commands {
            if let index = commands.firstIndex(where: { $0.name == command.name }) {
                // Keep native panels, but show the runtime's argument contract.
                if commands[index].argumentHint == nil, command.name != "plugins" { commands[index].argumentHint = command.argumentHint }
            } else { commands.append(command) }
        }
        return commands
    }

    /// Sends a command the harness implements, bypassing native handling of the same name.
    func forwardToHarness(_ name: String, arguments: String) {
        guard !run.isRunning, !run.isConfiguring else { banner = "Wait for the current turn to finish or stop it before running /\(name)."; return }
        let previousDraft = draft
        let previousProjectID = state.selectedProjectID
        draft = "/\(name)" + (arguments.isEmpty ? "" : " \(arguments)")
        send(bypassDesktopCommands: true)
        if !previousDraft.isEmpty, SlashCommand.split(previousDraft) == nil,
           state.selectedProjectID == previousProjectID, draft.isEmpty {
            draft = previousDraft; drafts[draftLocation] = previousDraft
        }
    }

    /// Sends text as an ordinary prompt even though it starts with a slash.
    func sendLiteralPrompt(_ text: String) {
        guard !run.isRunning, !run.isConfiguring else { return }
        send(displayText: text, promptText: text)
    }

    func open(_ window: DesktopWindow) { windowRequest = window }

    func pendingFeature(_ command: String) {
        banner = "\(command) is not available in this build of Grok Desktop yet."
    }

    func executeCommand(name: String, arguments: String = "") {
        if run.isRunning {
            switch DesktopCommands.turnPolicy(name, arguments: arguments) {
            case .waitForIdle:
                banner = "Wait for the current turn to finish or stop it before running /\(name)."; return
            case .queue:
                let text = "/\(name)" + (arguments.isEmpty ? "" : " \(arguments)")
                if let id = state.selectedConversationID, features.composer.enqueue(text, conversationID: id) { return }
            case .runNow: break
            }
        }
        if handleDesktopCommand(name, arguments: arguments) { return }
        if name == "goal", ["status", "pause", "resume", "clear"].contains(arguments), run.isRunning {
            goalAction(arguments); return
        }
        guard !run.isRunning, !run.isConfiguring else { banner = "Wait for the current turn to finish or stop it before running /\(name)."; return }
        let previousDraft = draft
        let previousProjectID = state.selectedProjectID
        draft = "/\(name)" + (arguments.isEmpty ? "" : " \(arguments)")
        send()
        if !previousDraft.isEmpty, SlashCommand.split(previousDraft) == nil,
           state.selectedProjectID == previousProjectID, draft.isEmpty {
            draft = previousDraft; drafts[draftLocation] = previousDraft
        }
    }

    func loadCommands(_ client: ACPClient, id: UUID, project: Project) async throws {
        var params: [String: Any] = ["cwd": project.path]
        if let session = task(id)?.sessionID { params["sessionId"] = session }
        let response = try ExtensionResponse.unwrap(try await client.request("_x.ai/commands/list", params: params))
        guard clients[id] === client else { throw CancellationError() }
        runs[id, default: RunState()].commands = SlashCommand.parse(response["commands"] as? [[String: Any]] ?? [])
        runs[id]?.commandsLoaded = true
        runs[id]?.availableTools = response["tools"] as? [String] ?? runs[id]?.availableTools
    }

    func refreshCommands() async {
        guard let project else { return }
        do {
            if let id = state.selectedConversationID, let client = clients[id], loaded.contains(id) {
                try await loadCommands(client, id: id, project: project)
            } else {
                let client = ACPClient()
                let clientID = UUID(); auxiliaryClients[clientID] = client
                defer { client.stop(); auxiliaryClients.removeValue(forKey: clientID) }
                try client.start(executable: binaryPath, cwd: project.path)
                let initial = try await initialize(client)
                try await authenticate(client, initial: initial)
                let response = try ExtensionResponse.unwrap(try await client.request("_x.ai/commands/list", params: ["cwd": project.path]))
                guard self.project?.id == project.id else { return }
                catalogRun.commands = SlashCommand.parse(response["commands"] as? [[String: Any]] ?? [])
                catalogRun.commandsLoaded = true
                catalogRun.availableTools = response["tools"] as? [String]
                commandCatalogProjectID = project.id
            }
        } catch { banner = "Could not load commands: \(error.localizedDescription)" }
    }

    @discardableResult
    func ensureConversation(title: String) -> UUID? {
        if let id = state.selectedConversationID { return id }
        guard let project else { return nil }
        let item = Conversation(projectID: project.id, title: title, modelID: state.selectedModelID, reasoningID: state.selectedReasoningID)
        state.conversations.insert(item, at: 0)
        state.selectedConversationID = item.id
        save()
        return item.id
    }

    func featureSession() async throws -> (ACPClient, UUID, String) {
        guard project != nil, let id = ensureConversation(title: "New task") else { throw DesktopError.message("Open a project first.") }
        let (client, session) = try await session(for: id)
        return (client, id, session)
    }

    /// A live harness session for a task, which need not be the selected one. A running turn
    /// keeps its connection, so side lanes such as `/btw` reach it without interrupting.
    func session(for id: UUID) async throws -> (ACPClient, String) {
        guard let task = task(id), let project = state.projects.first(where: { $0.id == task.projectID }) else {
            throw DesktopError.message("This task is no longer available.")
        }
        if let client = clients[id], loaded.contains(id), let session = self.task(id)?.sessionID { return (client, session) }
        guard runs[id]?.isRunning != true else { throw DesktopError.message("The task is still connecting. Try again when it is ready.") }
        let operationID = beginOperation(id, phase: "Connecting")
        runs[id]?.isConfiguring = true
        defer { finishOperation(id, operationID: operationID) }
        do {
            let client = try await connect(id: id, project: project, operationID: operationID)
            try checkOperation(id, operationID: operationID)
            guard let session = self.task(id)?.sessionID else { throw DesktopError.message("The runtime did not create a session.") }
            runs[id]?.phase = "Ready"
            return (client, session)
        } catch {
            if operationIDs[id] == operationID { discardConnection(id); runs[id]?.phase = "Needs attention" }
            throw error
        }
    }

    func enterPlanMode(description: String = "") {
        guard !run.isRunning, !run.isConfiguring, let id = ensureConversation(title: description.isEmpty ? "Plan" : String(description.prefix(64))) else { return }
        if description.isEmpty {
            if let command = SlashCommand.split(draft), command.name == "plan", command.arguments.isEmpty { draft = "" }
            setSessionOption(key: "mode", value: "plan")
        }
        else {
            pendingModes[id] = "plan"
            draft = description; send()
        }
    }

    func createGoal(objective: String, tokenBudget: Int? = nil) {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { featureError = "Enter a goal objective."; return }
        guard tokenBudget == nil || tokenBudget! > 0 else { featureError = "The token budget must be positive."; return }
        executeCommand(name: "goal", arguments: text + (tokenBudget.map { " --budget \($0)" } ?? ""))
    }

    func goalAction(_ action: String) {
        guard ["status", "pause", "resume", "clear"].contains(action) else { return }
        guard run.isRunning else { executeCommand(name: "goal", arguments: action); return }
        if action == "status" { featureRows = goalRows(); return }
        if action == "resume" { featureError = "The goal is already running."; return }
        guard let id = state.selectedConversationID, let project, run.goal != nil else { featureError = "This task does not have an active goal."; return }
        // The harness queues prompt requests behind a running turn. Cancel is its
        // immediate control path and durably pauses the active goal.
        let previousOperation = operations[id]
        cancel()
        guard action == "clear" else { return }
        Task {
            await previousOperation?.value
            guard task(id) != nil, runs[id]?.isRunning != true else { return }
            let operationID = beginOperation(id, phase: "Clearing goal")
            defer { finishOperation(id, operationID: operationID) }
            do {
                let client = try await connect(id: id, project: project, operationID: operationID)
                guard let session = task(id)?.sessionID else { return }
                _ = try await client.request("session/prompt", params: ["sessionId": session, "prompt": [["type": "text", "text": "/goal clear"]]], timeout: 60)
                try checkOperation(id, operationID: operationID)
                runs[id]?.phase = "Ready"
            } catch {
                if operationIDs[id] == operationID { runs[id]?.phase = "Needs attention"; featureError = "Could not clear goal: \(error.localizedDescription)" }
            }
        }
    }

    func updateSubagent(_ value: [String: Any], id: UUID) {
        guard let agentID = value["subagent_id"] as? String ?? value["subagentId"] as? String else { return }
        var agents = runs[id]?.subagents ?? []
        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            let incomingAttempt = value["attempt_id"] as? String ?? value["attemptId"] as? String
            if value["sessionUpdate"] as? String == "subagent_spawned" {
                if incomingAttempt != agents[index].attemptID { agents[index] = SubagentState(id: agentID) }
                agents[index].status = "running"
            } else if let incomingAttempt, let currentAttempt = agents[index].attemptID, incomingAttempt != currentAttempt { return }
            agents[index].update(value)
        }
        else { var agent = SubagentState(id: agentID); agent.update(value); agents.append(agent) }
        runs[id, default: RunState()].subagents = agents
    }

    func receiveFeatureNotification(_ method: String, params: [String: Any], id: UUID) -> Bool {
        if ["x.ai/mcp/servers_updated", "x.ai/mcp/tools_changed", "x.ai/mcp/server_status"].contains(method) {
            if state.selectedConversationID == id, featurePanel == .mcps, !featureLoading {
                featureNotificationRefresh?.cancel()
                featureNotificationRefresh = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    guard let self, self.state.selectedConversationID == id, self.featurePanel == .mcps, !self.featureLoading else { return }
                    await self.refreshFeatures(.mcps)
                }
            }
            return true
        }
        if method == "x.ai/session_notification", let nested = params["params"] as? [String: Any] {
            return receiveFeatureNotification(method, params: nested, id: id)
        }
        if let session = params["sessionId"] as? String, let expected = task(id)?.sessionID, session != expected { return true }
        if features.handle(method: method, params: params, update: params["update"] as? [String: Any], conversationID: id) { return true }
        guard ["x.ai/session/update", "x.ai/session_notification", "session/update"].contains(method), let update = params["update"] as? [String: Any] else { return false }
        if consumeAdvancedUpdate(update, id: id) { return true }
        switch update["sessionUpdate"] as? String {
        case "goal_updated":
            runs[id, default: RunState()].goal = GoalState(update)
            if state.selectedConversationID == id, featurePanel == .goals { featureRows = goalRows() }
            return true
        case "subagent_spawned", "subagent_progress", "subagent_finished":
            updateSubagent(update, id: id)
            if state.selectedConversationID == id, featurePanel == .agents { featureRows = runs[id]?.subagents.map(\.row) ?? [] }
            return true
        default: return false
        }
    }

    func refreshAfterRewind(id: UUID, conversationChanged: Bool) async {
        let projectID = task(id)?.projectID
        if conversationChanged {
            discardConnection(id)
            runs[id]?.plan = []; runs[id]?.subagents = []; runs[id]?.goal = nil
            if state.selectedConversationID == id {
                savedPlanContent = nil; savedPlanError = nil
                await loadImportedConversation()
            }
        }
        if projectID == state.selectedProjectID { await refreshWorkspace() }
    }
}
