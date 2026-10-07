import Foundation

// MARK: - /fork

/// `/fork [--worktree|--no-worktree] [directive]`, parsed like the terminal: flags come first, and the
/// first word that is not a flag starts the directive, so a directive may itself begin with `--`.
struct SessionForkArguments: Equatable {
    /// nil when neither flag was given; the worktree question or `[hints].fork_worktree_mode` decides.
    var worktree: Bool?
    var directive: String?

    static func parse(_ arguments: String) throws -> SessionForkArguments {
        var worktree: Bool?
        var rest = Substring(arguments).drop(while: \.isWhitespace)
        flags: while !rest.isEmpty {
            let flag = rest.prefix { !$0.isWhitespace }
            let after = rest.dropFirst(flag.count).drop(while: \.isWhitespace)
            switch flag {
            case "--worktree":
                if worktree == false { throw DesktopError.message("--worktree and --no-worktree are mutually exclusive") }
                if worktree == true { throw DesktopError.message("--worktree specified twice") }
                worktree = true
            case "--no-worktree":
                if worktree == true { throw DesktopError.message("--worktree and --no-worktree are mutually exclusive") }
                if worktree == false { throw DesktopError.message("--no-worktree specified twice") }
                worktree = false
            case "--at":
                throw DesktopError.message("--at is not supported in this version")
            default:
                break flags
            }
            rest = after
        }
        let directive = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionForkArguments(worktree: worktree, directive: directive.isEmpty ? nil : directive)
    }
}

/// `[hints].fork_worktree_mode`: whether `/fork` in a git repository asks about a worktree.
enum SessionForkWorktreeMode: String {
    case ask, always, never

    /// The legacy `worktree_mode` key applies when the fork key is absent; unknown values mean
    /// never, as in the terminal.
    static func read(_ config: GrokConfig) -> SessionForkWorktreeMode {
        guard let value = config.string("fork_worktree_mode", in: "hints") ?? config.string("worktree_mode", in: "hints") else { return .ask }
        return SessionForkWorktreeMode(rawValue: value) ?? .never
    }
}

/// The four answers to "Run this fork in an isolated git worktree?".
enum SessionForkChoice: String, CaseIterable, Identifiable {
    case yes, no, always, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .always: return "Always worktree"
        case .never: return "Never worktree"
        }
    }

    var detail: String {
        switch self {
        case .yes: return "Fork in a new isolated git worktree"
        case .no: return "Fork in the current cwd"
        case .always: return "Use worktree and stop asking (reset in config.toml)"
        case .never: return "Skip worktree and stop asking (reset in config.toml)"
        }
    }

    var symbol: String {
        switch self {
        case .yes: return "arrow.triangle.branch"
        case .no: return "folder"
        case .always: return "checkmark.circle"
        case .never: return "nosign"
        }
    }

    var usesWorktree: Bool { self == .yes || self == .always }
    var persistedMode: SessionForkWorktreeMode? { self == .always ? .always : self == .never ? .never : nil }
}

enum SessionWorktreeDetection {
    /// Mirrors the terminal's `parent_session_is_worktree`: the session summary records a worktree,
    /// or the folder's `.git` is a file (a linked worktree) or carries Crok's worktree marker.
    static func isWorktree(sessionDirectory: URL?, cwd: String) -> Bool {
        if let summary = sessionDirectory?.appendingPathComponent("summary.json"),
           let data = try? Data(contentsOf: summary),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if object["session_kind"] as? String == "worktree" { return true }
            if let source = object["source_workspace_dir"] as? String, !source.isEmpty { return true }
            if let label = object["worktree_label"] as? String, !label.isEmpty { return true }
        }
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { return true }
                let marker = (try? String(contentsOf: git.appendingPathComponent("grok-worktree-source"), encoding: .utf8)) ?? ""
                return !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
    }

    /// Whether `path` is inside a git work tree. Runs git off the main thread.
    static func isRepository(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--is-inside-work-tree"]
            var environment = ProcessInfo.processInfo.environment
            for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 && String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }.value
    }
}

// MARK: - /rename

/// `/rename <title> | --auto`, validated like the terminal and the harness's title boundary.
enum SessionRenameRequest: Equatable {
    case title(String)
    case auto

    static let maximumLength = 100
    static let usage = "Usage: /rename <new title> | --auto"

    static func parse(_ arguments: String) throws -> SessionRenameRequest {
        let title = sanitize(arguments)
        if isAutoVerb(title) || isAutoVerb(arguments) { return .auto }
        if autoVerbHasTrailingText(arguments) || autoVerbHasTrailingText(title) { throw DesktopError.message("--auto takes no title") }
        if title.isEmpty { throw DesktopError.message(usage) }
        if title.unicodeScalars.count > maximumLength { throw DesktopError.message("title too long (max \(maximumLength) characters)") }
        return .title(title)
    }

    /// Drops control characters and bidirectional overrides, then trims.
    static func sanitize(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars where !isForbidden(scalar) { scalars.append(scalar) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    private static func isAutoVerb(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) == "--auto" }

    private static func autoVerbHasTrailingText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("--auto") else { return false }
        return trimmed.dropFirst(6).first?.isWhitespace == true
    }
}

// MARK: - /resume

/// One saved harness session, from `_x.ai/session/list` or `_x.ai/session/search`.
struct HarnessSessionRow: Identifiable, Equatable {
    let id: String
    var title: String
    var firstPrompt: String?
    var cwd: String
    var updatedAt: Date?
    var messageCount: Int?
    var branch: String?
    var modelID: String?
    var source: String?
    var summary: String?
    var worktreeLabel: String?
    var snippet: String?

    var isRemoteOnly: Bool { source == "remote" }

    /// A wrapped `session/list` result: `{sessions, nextCursor?}` with camelCase rows.
    static func parseList(_ result: [String: Any]) -> (rows: [HarnessSessionRow], nextCursor: String?) {
        let rows = (result["sessions"] as? [[String: Any]] ?? []).compactMap { item -> HarnessSessionRow? in
            guard let id = item["sessionId"] as? String, !id.isEmpty else { return nil }
            let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = (item["firstPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return HarnessSessionRow(
                id: id, title: displayTitle(summary: summary, firstPrompt: prompt), firstPrompt: prompt,
                cwd: item["cwd"] as? String ?? "",
                updatedAt: date(item["lastActiveAt"] as? String) ?? date(item["updatedAt"] as? String),
                messageCount: (item["numMessages"] as? NSNumber)?.intValue,
                branch: nonEmpty(item["branch"] as? String), modelID: nonEmpty(item["modelId"] as? String),
                source: item["source"] as? String,
                summary: nonEmpty(item["lastRecap"] as? String) ?? nonEmpty(item["lastTurnSummary"] as? String),
                worktreeLabel: nonEmpty(item["worktreeLabel"] as? String))
        }
        let cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (rows, cursor)
    }

    /// A wrapped `session/search` result: `{results:[{sessionId, cwd, summary, updatedAt, snippet?}], bootstrapping}`.
    static func parseSearch(_ result: [String: Any]) -> (rows: [HarnessSessionRow], bootstrapping: Bool) {
        var seen: Set<String> = []
        let rows = (result["results"] as? [[String: Any]] ?? []).compactMap { item -> HarnessSessionRow? in
            guard let id = item["sessionId"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return HarnessSessionRow(id: id, title: displayTitle(summary: summary, firstPrompt: nil), cwd: item["cwd"] as? String ?? "",
                                     updatedAt: date(item["updatedAt"] as? String),
                                     snippet: nonEmpty(item["snippet"] as? String).map(cleanSnippet))
        }
        return (rows, result["bootstrapping"] as? Bool ?? false)
    }

    static func displayTitle(summary: String, firstPrompt: String?) -> String {
        if !summary.isEmpty { return String(summary.prefix(200)) }
        if let prompt = firstPrompt?.split(whereSeparator: \.isNewline).first, !prompt.isEmpty { return String(prompt.prefix(64)) }
        return "Crok task"
    }

    /// Search snippets mark matches with brackets or HTML; the list shows them as plain text.
    private static func cleanSnippet(_ text: String) -> String {
        text.replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - /tasks and /workflow runs

/// A workflow run as reported by `workflow_updated` (snake_case fields).
struct SessionWorkflowRun: Identifiable, Equatable {
    struct Phase: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var state: String
    }

    struct Agent: Equatable, Identifiable {
        var id: String
        var label: String
        var phase: String?
        var model: String?
        var state: String
        var tokensUsed: Int
        var durationMS: Int
    }

    let id: String
    var revision: Int
    var name: String
    var objective: String
    var status: String
    var phases: [Phase]
    var currentPhase: String?
    var agentBudget: Int?
    var agentsUsed: Int
    var agentsReserved: Int
    var agentsRemaining: Int?
    var agentUsageIncomplete: Bool
    var elapsedMS: Int
    var agents: [Agent]
    var lastEventDetail: String?
    var pauseMessage: String?
    var resultSummary: String?
    var receivedAt: Date

    init?(_ value: [String: Any], now: Date) {
        guard let id = value["run_id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        revision = Self.int(value["revision"]) ?? 0
        name = value["name"] as? String ?? "workflow"
        objective = value["objective"] as? String ?? ""
        status = value["status"] as? String ?? "active"
        phases = (value["phases"] as? [[String: Any]] ?? []).compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            return Phase(title: title, state: item["state"] as? String ?? "pending")
        }
        currentPhase = (value["current_phase"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        agentBudget = Self.int(value["agent_budget"])
        agentsUsed = Self.int(value["agents_used"]) ?? 0
        agentsReserved = Self.int(value["agents_reserved"]) ?? 0
        agentsRemaining = Self.int(value["agents_remaining"])
        agentUsageIncomplete = value["agent_usage_incomplete"] as? Bool ?? false
        elapsedMS = Self.int(value["elapsed_ms"]) ?? 0
        agents = (value["agents"] as? [[String: Any]] ?? []).compactMap { item in
            guard let agentID = item["agent_id"] as? String else { return nil }
            return Agent(id: agentID, label: item["label"] as? String ?? agentID, phase: item["phase"] as? String, model: item["model"] as? String,
                         state: item["state"] as? String ?? "pending", tokensUsed: Self.int(item["tokens_used"]) ?? 0, durationMS: Self.int(item["duration_ms"]) ?? 0)
        }
        lastEventDetail = value["last_event_detail"] as? String
        pauseMessage = (value["pause_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        resultSummary = (value["result_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        receivedAt = now
    }

    var isActive: Bool { status == "active" }
    var isTerminal: Bool { ["interrupted", "complete", "failed", "cancelled"].contains(status) }
    var runningAgents: Int { agents.filter { $0.state == "running" }.count }
    var finishedAgents: Int { agents.filter { ["complete", "completed", "done", "failed", "cancelled"].contains($0.state) }.count }

    func canPause(managed: Bool) -> Bool { managed && isActive }
    /// A budget-limited run can resume once its budget is raised, as in the terminal.
    func canResume(managed: Bool) -> Bool {
        managed && ["user_paused", "back_off_paused", "no_progress_paused", "infra_paused", "blocked", "failed", "cancelled", "budget_limited"].contains(status)
    }
    func canStop(managed: Bool) -> Bool { managed && !isTerminal }
    func canSave(managed: Bool) -> Bool { managed }

    /// The terminal's one-line activity: the phase and running agents while active, otherwise the status.
    var activityLabel: String {
        guard isActive else { return status.replacingOccurrences(of: "_", with: " ") }
        let agentsText: String? = runningAgents == 0 ? nil : runningAgents == 1 ? "1 agent" : "\(runningAgents) agents"
        switch (currentPhase, agentsText) {
        case let (phase?, agents?): return "\(phase) · \(agents)"
        case let (phase?, nil): return phase
        case let (nil, agents?): return agents
        default: return "running"
        }
    }

    /// Elapsed time including the time since the last update while the run is active.
    func liveElapsed(now: Date) -> TimeInterval {
        Double(elapsedMS) / 1000 + (isActive ? max(0, now.timeIntervalSince(receivedAt)) : 0)
    }

    /// The warning line under a paused, budget-limited, or failed run.
    var statusNote: String? {
        if status == "budget_limited" {
            if agentsUsed >= 1_024 { return "Budget limited: maximum agent budget reached; start a new run." }
            if let pauseMessage { return "Budget limited: raise the agent budget to continue. \(pauseMessage)" }
            return "Budget limited: raise the agent budget above \(agentsUsed) to continue."
        }
        if let pauseMessage { return "\(SessionText.capitalizedFirst(status.replacingOccurrences(of: "_", with: " "))): \(pauseMessage)" }
        if status == "failed" { return "Failed: Resume replays the run from its journal." }
        return nil
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}

/// A `/loop` or other scheduled prompt, from `scheduled_task_*` notifications.
struct SessionScheduledTask: Identifiable, Equatable {
    let id: String
    var prompt: String
    var schedule: String
    var nextFireAt: Date?
    var tag = "loop"
    var lastSubagentID: String?
    var firesCount = 0
}

/// A backgrounded shell command or monitor, from `background_tasks` snapshots or `_x.ai/task/list`.
struct SessionBackgroundTask: Identifiable, Equatable {
    let id: String
    var title: String
    var command: String
    var isMonitor: Bool
    var status: String
    var startedAt: Date?
    var endedAt: Date?
    var exitCode: Int?
    var outputFile: String?
    var output: String?

    var isRunning: Bool { status == "running" }

    /// A `background_tasks` row (snake_case `BackgroundTaskRow`).
    init?(row value: [String: Any]) {
        guard let id = value["task_id"] as? String else { return nil }
        self.id = id
        command = value["display_command"] as? String ?? value["command"] as? String ?? ""
        title = Self.oneLine((value["description"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? command)
        isMonitor = value["kind"] as? String == "monitor"
        status = value["status"] as? String ?? "running"
        startedAt = HarnessSessionRow.date(value["started_at"] as? String)
        endedAt = HarnessSessionRow.date(value["ended_at"] as? String)
        exitCode = SessionWorkflowRun.int(value["exit_code"])
        outputFile = value["output_file"] as? String
    }

    /// A `_x.ai/task/list` entry (snake_case `TaskSnapshot`, times as `{secs_since_epoch, nanos_since_epoch}`).
    init?(snapshot value: [String: Any]) {
        guard let id = value["task_id"] as? String else { return nil }
        self.id = id
        command = value["display_command"] as? String ?? value["command"] as? String ?? ""
        title = Self.oneLine(command)
        isMonitor = value["kind"] as? String == "monitor"
        let completed = value["completed"] as? Bool ?? false
        exitCode = SessionWorkflowRun.int(value["exit_code"])
        status = !completed ? "running" : (exitCode ?? 0) == 0 && value["signal"] as? String == nil ? "completed" : "failed"
        startedAt = Self.systemTime(value["start_time"])
        endedAt = Self.systemTime(value["end_time"])
        outputFile = (value["output_file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        output = (value["output"] as? String).flatMap { $0.isEmpty ? nil : String($0.suffix(4_000)) }
    }

    private static func systemTime(_ value: Any?) -> Date? {
        guard let value = value as? [String: Any], let seconds = SessionWorkflowRun.int(value["secs_since_epoch"]) else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(SessionWorkflowRun.int(value["nanos_since_epoch"]) ?? 0) / 1e9)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? text
    }
}

/// What a task has running in the background: workflows, scheduled prompts, and shell tasks.
/// Built from harness notifications, so it follows the same last-wins and revision rules as the terminal.
struct SessionTaskBoard: Equatable {
    var workflows: [SessionWorkflowRun] = []
    var scheduled: [SessionScheduledTask] = []
    var background: [SessionBackgroundTask] = []
    /// Background task IDs the user asked to stop; shown as "stopping" until a snapshot says otherwise.
    var stopping: Set<String> = []
    private var workflowRevisions: [String: Int] = [:]
    private var clearedWorkflows: Set<String> = []

    static let updateKinds: Set<String> = ["workflow_updated", "scheduled_task_created", "scheduled_task_fired", "scheduled_task_deleted", "background_tasks"]

    var isEmpty: Bool { workflows.isEmpty && scheduled.isEmpty && background.isEmpty }
    var hasLiveWork: Bool { background.contains(where: \.isRunning) || !scheduled.isEmpty || workflows.contains(where: \.isActive) }

    /// Applies one session update. Returns false when the update does not belong to the board or is stale.
    @discardableResult
    mutating func apply(_ update: [String: Any], now: Date = Date()) -> Bool {
        switch update["sessionUpdate"] as? String {
        case "workflow_updated":
            guard let run = SessionWorkflowRun(update, now: now) else { return false }
            return applyWorkflow(run)
        case "scheduled_task_created":
            guard let id = update["task_id"] as? String else { return false }
            let next = HarnessSessionRow.date(update["next_fire_at"] as? String)
            if let index = scheduled.firstIndex(where: { $0.id == id }) {
                scheduled[index].prompt = update["prompt"] as? String ?? scheduled[index].prompt
                scheduled[index].schedule = update["human_schedule"] as? String ?? scheduled[index].schedule
                scheduled[index].nextFireAt = next
            } else {
                scheduled.append(SessionScheduledTask(id: id, prompt: update["prompt"] as? String ?? "", schedule: update["human_schedule"] as? String ?? "", nextFireAt: next))
            }
            return true
        case "scheduled_task_fired":
            guard let id = update["task_id"] as? String else { return false }
            let next = HarnessSessionRow.date(update["next_fire_at"] as? String)
            let subagent = update["subagent_id"] as? String
            if let index = scheduled.firstIndex(where: { $0.id == id }) {
                scheduled[index].nextFireAt = next
                scheduled[index].firesCount += 1
                if let subagent { scheduled[index].lastSubagentID = subagent }
            } else {
                // A fire for a task this client never saw created still belongs in the list.
                scheduled.append(SessionScheduledTask(id: id, prompt: update["prompt"] as? String ?? "", schedule: update["human_schedule"] as? String ?? "",
                                                      nextFireAt: next, lastSubagentID: subagent, firesCount: 1))
            }
            return true
        case "scheduled_task_deleted":
            guard let id = update["task_id"] as? String else { return false }
            scheduled.removeAll { $0.id == id }
            return true
        case "background_tasks":
            // Last-wins: the snapshot replaces the list, and `tasks: []` clears it.
            background = (update["tasks"] as? [[String: Any]] ?? []).compactMap(SessionBackgroundTask.init(row:))
            stopping.formIntersection(background.filter(\.isRunning).map(\.id))
            return true
        default:
            return false
        }
    }

    /// Replaces background tasks with an authoritative `_x.ai/task/list` answer.
    mutating func replaceBackground(withTaskList tasks: [[String: Any]]) {
        background = tasks.compactMap(SessionBackgroundTask.init(snapshot:))
        stopping.formIntersection(background.filter(\.isRunning).map(\.id))
    }

    private mutating func applyWorkflow(_ run: SessionWorkflowRun) -> Bool {
        if run.status != "cleared" {
            if let last = workflowRevisions[run.id] {
                if run.revision == 0 && last > 0 { return false }
                if run.revision > 0 && run.revision <= last { return false }
            }
            if run.revision == 0 && clearedWorkflows.contains(run.id) { return false }
        }
        if run.revision > 0 { workflowRevisions[run.id] = run.revision }
        if run.status == "cleared" {
            clearedWorkflows.insert(run.id)
            workflows.removeAll { $0.id == run.id }
        } else if let index = workflows.firstIndex(where: { $0.id == run.id }) {
            workflows[index] = run
        } else {
            workflows.append(run)
        }
        return true
    }

    /// Active runs first, then the most recently updated, as in the terminal.
    var sortedWorkflows: [SessionWorkflowRun] {
        workflows.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
            return lhs.id < rhs.id
        }
    }

    var sortedBackground: [SessionBackgroundTask] {
        background.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast) }
            return lhs.id < rhs.id
        }
    }

    var sortedScheduled: [SessionScheduledTask] {
        scheduled.sorted { ($0.tag, $0.schedule, $0.id) < ($1.tag, $1.schedule, $1.id) }
    }
}

// MARK: - /doctor

/// `/doctor [fix [name]]`.
enum DoctorRequest: Equatable {
    case report
    case listFixes
    case fix(DoctorFixSpec)

    static let usage = "Usage: /doctor [fix [ssh-wrap|tmux-clipboard|dcs-passthrough|tmux-extended-keys]]"

    static func parse(_ arguments: String) throws -> DoctorRequest {
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        switch tokens.count {
        case 0: return .report
        case 1 where tokens[0] == "fix": return .listFixes
        case 2 where tokens[0] == "fix":
            guard let spec = DoctorFixSpec.resolve(tokens[1]) else {
                throw DesktopError.message("`\(tokens[1])` is not an available Doctor fix. Run `crok doctor fix` to list available fixes.\n\(usage)")
            }
            return .fix(spec)
        default: throw DesktopError.message(usage)
        }
    }
}

/// An automatic fix `crok doctor fix` can apply. They configure the terminal, so they run in Terminal.
struct DoctorFixSpec: Equatable, Identifiable {
    let handle: String
    let label: String
    var id: String { "terminal.\(handle)" }
    var command: String { "crok doctor fix \(handle)" }

    static let registry = [
        DoctorFixSpec(handle: "ssh-wrap", label: "Set up local SSH wrapping"),
        DoctorFixSpec(handle: "tmux-clipboard", label: "Enable tmux clipboard forwarding"),
        DoctorFixSpec(handle: "dcs-passthrough", label: "Enable tmux DCS passthrough"),
        DoctorFixSpec(handle: "tmux-extended-keys", label: "Enable tmux extended keys"),
        DoctorFixSpec(handle: "tmux-truecolor", label: "Enable tmux truecolor passthrough"),
    ]

    /// Accepts the short handle or the full id, e.g. `tmux-clipboard` or `terminal.tmux-clipboard`.
    static func resolve(_ value: String) -> DoctorFixSpec? {
        registry.first { value == $0.handle || value == $0.id }
    }
}

/// `crok doctor --json` (schema version 1, camelCase). Every field is optional so a newer
/// harness that adds or drops facts still decodes.
struct DoctorReport: Decodable, Equatable {
    struct RuntimeFact: Decodable, Equatable {
        var status: String?
        var value: String?
        var text: String {
            switch status {
            case "available": return value ?? "Available"
            case "no_reply": return "No reply"
            default: return "Unavailable"
            }
        }
    }

    struct Terminal: Decodable, Equatable { var name: String?; var xtversion: RuntimeFact? }
    struct Multiplexer: Decodable, Equatable { var kind: String?; var byobu: String? }
    struct Color: Decodable, Equatable { var level: RuntimeFact?; var availableThemes: [String]?; var totalThemes: Int? }
    struct Keyboard: Decodable, Equatable { var cmd: String?; var opt: String?; var os: String? }
    struct Newline: Decodable, Equatable { var kind: String?; var version: String?; var terminalName: String? }
    struct Clipboard: Decodable, Equatable {
        var nativeRoute: Bool?
        var nativeTool: String?
        var nativePreflight: String?
        var tmuxRoute: Bool?
        var osc52Route: Bool?
        var osc52Capability: String?
        var wrapSink: Bool?
        var displayServer: String?
        var containerNoDisplay: Bool?
        var dataControl: String?
        var delivery: String?
        var fix: String?
    }
    struct Voice: Decodable, Equatable { var status: String?; var name: String?; var detail: String?; var error: String? }

    struct Facts: Decodable, Equatable {
        var terminal: Terminal?
        var multiplexer: Multiplexer?
        var ssh: Bool?
        var color: Color?
        var keyboard: Keyboard?
        var newline: Newline?
        var clipboard: Clipboard?
        var voice: Voice?
    }

    struct Remediation: Decodable, Equatable { var fix: String?; var configPath: String? }
    struct AutomaticRemediation: Decodable, Equatable { var fixId: String?; var command: String? }

    struct Finding: Decodable, Equatable, Identifiable {
        var id: String
        var disposition: String?
        var message: String?
        var remediation: Remediation?
        var automaticRemediation: AutomaticRemediation?
        var note: String?

        var isIssue: Bool { disposition == "issue" }
        /// The area before the dot, e.g. `voice` in `voice.no-input-device`.
        var area: String { id.split(separator: ".").first.map(String.init) ?? id }
        var automaticFix: DoctorFixSpec? {
            automaticRemediation?.fixId.flatMap(DoctorFixSpec.resolve)
        }
    }

    struct ProbeNote: Decodable, Equatable { var probe: String?; var status: String?; var message: String? }
    struct Counts: Decodable, Equatable { var issues: Int?; var recommendations: Int?; var probeNotes: Int? }

    var schemaVersion: String?
    var facts: Facts?
    var findings: [Finding]?
    var probeNotes: [ProbeNote]?
    var counts: Counts?

    var allFindings: [Finding] { findings ?? [] }
    var issueCount: Int { counts?.issues ?? allFindings.filter(\.isIssue).count }
    var recommendationCount: Int { counts?.recommendations ?? allFindings.filter { !$0.isIssue }.count }

    static func decode(_ data: Data) throws -> DoctorReport {
        do { return try JSONDecoder().decode(DoctorReport.self, from: data) }
        catch { throw DesktopError.message("crok doctor returned a report this version of Crok Desktop cannot read.") }
    }

    /// Facts grouped the way the terminal's Environment block lists them.
    var factGroups: [(title: String, symbol: String, rows: [(String, String)])] {
        guard let facts else { return [] }
        var groups: [(String, String, [(String, String)])] = []
        var terminal: [(String, String)] = []
        if let name = facts.terminal?.name { terminal.append(("Terminal", Self.humanize(name))) }
        if let xtversion = facts.terminal?.xtversion { terminal.append(("XTVERSION", xtversion.text)) }
        if let multiplexer = facts.multiplexer?.kind {
            terminal.append(("Multiplexer", Self.humanize(multiplexer) + (facts.multiplexer?.byobu.map { " (byobu · \($0))" } ?? "")))
        }
        if let ssh = facts.ssh { terminal.append(("SSH", ssh ? "Yes" : "No")) }
        if let level = facts.color?.level { terminal.append(("Color", Self.humanize(level.text))) }
        if let themes = facts.color?.availableThemes, let total = facts.color?.totalThemes {
            terminal.append(("Themes", themes.isEmpty ? "None of \(total) available" : "\(themes.count) of \(total): " + themes.joined(separator: ", ")))
        }
        if let keyboard = facts.keyboard {
            terminal.append(("Cmd / Opt", "\(Self.humanize(keyboard.cmd ?? "unknown")) / \(Self.humanize(keyboard.opt ?? "unknown"))"))
        }
        if let newline = facts.newline?.kind { terminal.append(("Shift+Enter", Self.humanize(newline))) }
        if !terminal.isEmpty { groups.append(("Terminal", "terminal", terminal)) }
        if let clipboard = facts.clipboard {
            var rows: [(String, String)] = []
            if let delivery = clipboard.delivery { rows.append(("Delivery", Self.humanize(delivery))) }
            if let route = clipboard.nativeRoute { rows.append(("Native copy", route ? (clipboard.nativeTool.map { "Yes · \($0)" } ?? "Yes") : "No")) }
            if let preflight = clipboard.nativePreflight { rows.append(("Native check", Self.humanize(preflight))) }
            if let osc = clipboard.osc52Route { rows.append(("OSC 52", osc ? "Yes" : "No") ) }
            if let capability = clipboard.osc52Capability { rows.append(("OSC 52 support", Self.humanize(capability))) }
            if let tmux = clipboard.tmuxRoute { rows.append(("tmux buffer", tmux ? "Yes" : "No")) }
            if let server = clipboard.displayServer { rows.append(("Display server", Self.humanize(server))) }
            if let fix = clipboard.fix, !fix.isEmpty { rows.append(("Fix", fix)) }
            groups.append(("Clipboard", "doc.on.clipboard", rows))
        }
        if let voice = facts.voice {
            var rows = [("Input device", voice.status == "available" ? (voice.name ?? "Available") : "Missing")]
            if let detail = voice.detail, !detail.isEmpty { rows.append(("Detail", detail)) }
            if let error = voice.error, !error.isEmpty { rows.append(("Error", error)) }
            groups.append(("Voice", "mic", rows))
        }
        return groups
    }

    /// `no_kitty_keyboard_protocol` → "No kitty keyboard protocol".
    static func humanize(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return SessionText.capitalizedFirst(spaced)
    }
}

// MARK: - /trace

enum TraceExport {
    /// `crok trace view <session directory> --format html -o <file>`. The directory is passed
    /// rather than the session ID so the CLI reads exactly the session the desktop resolved.
    static func arguments(source: String, output: String) -> [String] {
        ["trace", "view", source, "--format", "html", "-o", output]
    }

    /// A private scratch file for one export; the page embeds the whole transcript.
    static func outputFile(sessionID: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CrokDesktopTraces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = String(sessionID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }.prefix(120))
        return directory.appendingPathComponent("\(safe.isEmpty ? "trace" : safe)-\(UUID().uuidString.prefix(8)).html")
    }

    /// The last meaningful lines of the CLI's error output, for the failure view.
    static func errorSummary(status: Int32, stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("Trace saved to") }
        return lines.isEmpty ? "crok trace view exited with status \(status)." : lines.suffix(6).joined(separator: "\n")
    }
}

enum SessionText {
    /// Uppercases only the first character, leaving acronyms and paths alone.
    static func capitalizedFirst(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}
