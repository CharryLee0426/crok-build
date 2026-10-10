import Foundation

struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var argumentHint: String? = nil
    var source: String = "Harness"
    var aliases: [String] = []
    var skillPath: String? = nil
    /// Hidden commands run when typed but are never listed, as in the terminal.
    var isHidden = false
    var isSkill: Bool { skillPath != nil }
    /// Commands whose arguments are required are completed in the composer rather than run.
    var requiresArguments: Bool { argumentHint?.hasPrefix("<") == true }

    static func parse(_ values: [[String: Any]]) -> [SlashCommand] {
        values.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let meta = item["_meta"] as? [String: Any] ?? [:]
            let input = item["input"] as? [String: Any] ?? [:]
            let builtinAliases = ["always-approve": ["yolo"], "memory": ["mem"], "plugins": ["plugin"], "session-info": ["status", "info"]]
            return SlashCommand(name: name, description: item["description"] as? String ?? "",
                argumentHint: input["hint"] as? String,
                source: meta["pluginName"] as? String ?? meta["scope"] as? String ?? "Harness",
                aliases: meta["aliases"] as? [String] ?? (meta["path"] == nil ? builtinAliases[name] ?? [] : []), skillPath: meta["path"] as? String)
        }
    }

    static func split(_ text: String) -> (name: String, arguments: String)? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("/") else { return nil }
        let parts = input.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = parts.first, !name.isEmpty else { return nil }
        return (String(name), parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }
}

/// What the ranked command list was built from. While these stand, the index is reused.
struct CommandIndexKey: Equatable {
    var commands: [SlashCommand]
    var tools: [String]?
    var hasAnnouncements: Bool
}

/// A command list prepared for ranking: the lowercased names, aliases and descriptions are
/// made once, when the catalog changes, not for every command on every keystroke.
struct CommandIndex {
    struct Entry {
        let command: SlashCommand
        /// The lowercased name first, then the lowercased aliases.
        let names: [String]
        let description: String
    }

    let commands: [SlashCommand]
    private let entries: [Entry]

    init(_ commands: [SlashCommand]) {
        self.commands = commands
        entries = commands.map { command in
            Entry(command: command, names: [command.name.lowercased()] + command.aliases.map { $0.lowercased() },
                  description: command.description.lowercased())
        }
    }

    static let empty = CommandIndex([])

    /// The query as ranked: trimmed, lowercased, without the leading slash.
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Exact name or alias, then prefix, then substring, then a description mention, then the
    /// query's characters in order within a name. Within a tier the catalog's order holds, so
    /// the buckets replace a sort.
    func matches(query: String) -> [SlashCommand] {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return commands }
        var buckets: [[SlashCommand]] = Array(repeating: [], count: 5)
        for entry in entries {
            guard let tier = Self.tier(entry, query: query) else { continue }
            buckets[tier].append(entry.command)
        }
        return buckets.flatMap { $0 }
    }

    private static func tier(_ entry: Entry, query: String) -> Int? {
        var prefix = false, substring = false
        for name in entry.names {
            if name == query { return 0 }
            if !prefix, name.hasPrefix(query) { prefix = true }
            else if !prefix, !substring, name.contains(query) { substring = true }
        }
        if prefix { return 1 }
        if substring { return 2 }
        if entry.description.contains(query) { return 3 }
        for name in entry.names where isSubsequence(query, of: name) { return 4 }
        return nil
    }

    private static func isSubsequence(_ query: String, of name: String) -> Bool {
        var remaining = query.unicodeScalars[...]
        for character in name.unicodeScalars where remaining.first == character { remaining = remaining.dropFirst() }
        return remaining.isEmpty
    }
}

enum FeaturePanel: String, CaseIterable, Identifiable {
    case mcps, skills, agents, agentDefinitions, goals, workflows, plugins, marketplace, hooks, memory, personas, plan, models, reasoning, history, transcript
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mcps: return "MCP servers"
        case .agents: return "Subagents"
        case .agentDefinitions: return "Agent definitions"
        case .goals: return "Goal"
        case .reasoning: return "Thinking level"
        case .history: return "Task history"
        default: return rawValue.capitalized
        }
    }
}

struct FeatureRow: Identifiable {
    var id: String
    var title: String
    var subtitle: String = ""
    var detail: String = ""
    var enabled: Bool? = nil
    var actions: [String] = []
    var payload: [String: Any] = [:]
}

struct GoalState {
    var id: String
    var objective: String
    var status: String
    var phase: String
    var tokenBudget: Int?
    var tokensUsed: Int
    var elapsedMS: Int
    var detail: String
    var isActive: Bool { status == "active" }
    var isPaused: Bool { status.contains("paused") || status == "blocked" || status == "budget_limited" }

    init(_ value: [String: Any]) {
        id = value["goal_id"] as? String ?? value["goalId"] as? String ?? "goal"
        objective = value["objective"] as? String ?? ""
        status = value["status"] as? String ?? "active"
        phase = value["phase"] as? String ?? "idle"
        tokenBudget = value["token_budget"] as? Int ?? value["tokenBudget"] as? Int
        tokensUsed = value["tokens_used"] as? Int ?? value["tokensUsed"] as? Int ?? 0
        elapsedMS = value["elapsed_ms"] as? Int ?? value["elapsedMs"] as? Int ?? 0
        detail = value["pause_message"] as? String ?? value["last_event_detail"] as? String ?? ""
    }
}

struct SubagentState: Identifiable {
    var id: String
    var title: String = "Subagent"
    var agentType: String = ""
    var status: String = "running"
    var tokensUsed: Int = 0
    var toolCalls: Int = 0
    var turns: Int = 0
    var detail: String = ""
    var address: String?
    var attemptID: String?

    mutating func update(_ value: [String: Any]) {
        title = value["description"] as? String ?? title
        agentType = value["subagent_type"] as? String ?? value["subagentType"] as? String ?? agentType
        status = value["status"] as? String ?? status
        tokensUsed = value["tokens_used"] as? Int ?? value["tokensUsed"] as? Int ?? tokensUsed
        toolCalls = value["tool_call_count"] as? Int ?? value["toolCallCount"] as? Int ?? value["tool_calls"] as? Int ?? value["toolCalls"] as? Int ?? toolCalls
        turns = value["turn_count"] as? Int ?? value["turnCount"] as? Int ?? value["turns"] as? Int ?? turns
        detail = value["output"] as? String ?? value["error"] as? String ?? value["failureError"] as? String ?? value["cancelReason"] as? String ?? detail
        address = value["agentAddress"] as? String ?? value["agent_address"] as? String ?? address
        attemptID = value["attempt_id"] as? String ?? value["attemptId"] as? String ?? attemptID
    }

    var row: FeatureRow {
        FeatureRow(id: id, title: title, subtitle: "\(agentType) · \(status)",
            detail: detail.isEmpty ? "\(turns) turns · \(toolCalls) tool calls · \(tokensUsed) tokens" : detail,
            actions: status == "running" ? ["Inspect", "Stop"] + (address == nil ? [] : ["Message"]) : ["Inspect"])
    }
}

enum ExtensionResponse {
    /// ACP extensions use both bare objects and ExtMethodResult envelopes.
    static func unwrap(_ value: [String: Any]) throws -> [String: Any] {
        if let message = value["error"] as? String { throw DesktopError.message(message) }
        if let error = value["error"] as? [String: Any] {
            throw DesktopError.message(error["message"] as? String ?? "The runtime rejected the request.")
        }
        let result = value["result"] as? [String: Any] ?? value
        if let status = result["status"] as? String,
           ["validation_error", "internal_error", "not_found", "unsupported", "confirmation_required"].contains(status) {
            throw DesktopError.message(result["message"] as? String ?? status.replacingOccurrences(of: "_", with: " "))
        }
        return result
    }
}
