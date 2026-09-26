import AppKit
import SwiftUI

/// Desktop equivalents of every terminal (pager) command, with the pager's names, aliases,
/// argument hints, and descriptions. Harness commands and user-invocable skills are merged
/// into this catalog by AppStore.
enum DesktopCommands {
    static let catalog: [SlashCommand] = [
        // Getting around.
        command("help", "Browse commands and keyboard shortcuts", aliases: ["commands", "?"]),
        command("tutorial", "Quick tips to get the most out of Grok Build", aliases: ["tour", "onboarding"]),
        command("settings", "Open settings", aliases: ["config", "preferences", "prefs"]),
        command("dashboard", "Switch between your tasks and see which need you", aliases: ["agents-dashboard", "sessions"]),
        command("workflows", "Browse and launch saved workflows"),
        command("plugins", "Manage installed plugins", aliases: ["plugin"]),
        command("btw", "Ask a side question without interrupting your task", hint: "<question>"),
        command("voice", "Dictate your prompt"),
        command("new", "Start a new task", aliases: ["clear"]),
        // Per turn.
        command("effort", "Set reasoning effort for the current model", hint: "[level]"),
        command("model", "Switch the active model", hint: "[model] [effort]", aliases: ["m"]),
        command("context", "Show context window usage"),
        command("compact", "Compact the conversation history", hint: "[instructions]"),
        command("fork", "Branch this conversation into a new task", hint: "[--worktree|--no-worktree] [directive]"),
        command("resume", "Find and resume a saved session"),
        // Steering the work in front of you.
        command("plan", "Plan before making changes", hint: "[description]"),
        command("view-plan", "Read the current plan", aliases: ["show-plan", "plan-view"]),
        command("remember", "Save a memory note", hint: "[note]"),
        command("memory", "Browse and manage memory", aliases: ["mem"]),
        command("flush", "Save conversation memory now"),
        command("dream", "Consolidate stored memory"),
        command("recap", "Summarize recent work in this task", aliases: ["summarize"]),
        command("rewind", "Restore a previous conversation checkpoint", aliases: ["undo"]),
        command("jump", "Jump to a turn in the conversation"),
        command("expand", "Expand the most recent folded block"),
        command("edit-prompt", "Write the prompt in a larger editor"),
        command("queue", "Show and edit queued prompts"),
        // This session and what came out of it.
        command("session-info", "Show details about this session", aliases: ["status", "info"]),
        command("share", "Share this session via URL"),
        command("rename", "Rename this task", hint: "<title> | --auto", aliases: ["title"]),
        command("history", "Search prompt history"),
        command("transcript", "View the conversation transcript", aliases: ["log"]),
        command("trace", "Explore this session's trace: timeline, transcript, and tool I/O"),
        command("export", "Export the conversation to a file or the clipboard", hint: "[filename]"),
        command("copy", "Copy the last response to the clipboard or a file", hint: "[N] [file]"),
        command("find", "Search the conversation", hint: "[text]"),
        command("usage", "Show token and cost usage for this session", aliases: ["cost"]),
        command("tasks", "Show background tasks, workflows, and subagents"),
        // Extending the agent.
        command("skills", "Browse, enable, and run skills"),
        command("mcps", "Manage MCP servers and their tools", aliases: ["mcp"]),
        command("hooks", "Manage hooks"),
        command("marketplace", "Browse and install plugins from marketplaces"),
        command("workflow", "Launch or manage a workflow", hint: "<name> [input] | runs | pause|resume|stop|save <run>"),
        command("personas", "Browse and edit subagent personas"),
        command("config-agents", "Manage agent definitions", aliases: ["agents"]),
        command("subagents", "Inspect and stop running subagents"),
        // Settings and display.
        command("theme", "Switch the color theme", hint: "[name]", aliases: ["t"]),
        command("auto", "Toggle auto mode (a classifier approves safe tools)"),
        command("always-approve", "Toggle approving every tool action", hint: "[on|off]", aliases: ["yolo"]),
        command("vim-mode", "Toggle vim-style transcript keys (j/k, g/G, y)"),
        command("multiline", "Toggle Return for new lines and ⌘Return to send", aliases: ["ml"]),
        command("compact-mode", "Toggle a denser conversation layout"),
        command("timestamps", "Toggle message timestamps"),
        command("toggle-mouse-reporting", "Toggle terminal mouse reporting"),
        command("minimal", "Show only the conversation"),
        command("fullscreen", "Leave minimal mode, or toggle full screen", aliases: ["full"]),
        command("timeline", "Toggle the turn timeline beside the conversation"),
        // Reached for occasionally.
        command("cd", "Switch the project folder for new tasks", hint: "[path]"),
        command("imagine", "Generate an image", hint: "<description>"),
        command("imagine-video", "Generate a video", hint: "<description>"),
        command("changes", "Inspect changes in this project", aliases: ["diff"]),
        command("terminal", "Open a terminal in this project"),
        // Docs, account, and one-off maintenance.
        command("docs", "Read the Grok Build guides", hint: "[web|title]", aliases: ["howto", "guides"]),
        command("release-notes", "Show what's new in this version", aliases: ["changelog"]),
        command("announcements", "Hide or show the announcement banner", hint: "<hide|show>"),
        command("feedback", "Send feedback to the Grok Build team", hint: "[text]"),
        command("doctor", "Check your environment and suggest fixes", hint: "[fix [name]]", aliases: ["terminal-setup", "terminal-check", "terminal-info"]),
        command("import-claude", "Import Claude settings into Grok"),
        command("login", "Sign in to OpenRouter or OpenAI Codex"),
        command("home", "Return to a new task without stopping this one", aliases: ["welcome"]),
        command("delete", "Delete this task"),
        command("exit", "Quit Grok Desktop", aliases: ["quit", "q"]),
        // Hidden, as in the terminal: they run when typed but are never listed.
        command("gboom", "Knee-deep in the tokens", hidden: true),
        command("scroll-debug", "Toggle the scroll HUD", hidden: true),
        command("debug", "Toggle debug overlays", hint: "[scroll|fps|log]", hidden: true),
    ]

    private static func command(_ name: String, _ description: String, hint: String? = nil, aliases: [String] = [], hidden: Bool = false) -> SlashCommand {
        SlashCommand(name: name, description: description, argumentHint: hint, source: "Desktop", aliases: aliases, isHidden: hidden)
    }

    /// What a command typed while a turn is streaming does.
    enum TurnPolicy: Equatable {
        /// Opens native UI or acts at once, without disturbing the turn.
        case runNow
        /// Harness commands and skills wait in the queue like prompts.
        case queue
        /// Needs the task to be idle; the draft is kept and the user is told why.
        case waitForIdle
    }

    static func turnPolicy(_ name: String, arguments: String) -> TurnPolicy {
        let name = canonical(name)
        switch name {
        case "goal": return arguments.isEmpty || ["status", "pause", "resume", "clear"].contains(arguments) ? .runNow : .queue
        case "plan", "imagine", "imagine-video", "flush", "dream", "rewind", "fork", "delete": return .waitForIdle
        case "model", "effort", "gboom", "scroll-debug": return arguments.isEmpty ? .runNow : .waitForIdle
        case "memory": return arguments.isEmpty ? .runNow : .queue
        case "workflow": return arguments == "runs" ? .runNow : .queue
        default: return catalog.contains { $0.name == name } ? .runNow : .queue
        }
    }

    static func canonical(_ name: String) -> String {
        catalog.first { $0.name == name || $0.aliases.contains(name) }?.name ?? name
    }

    static func matches(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !query.isEmpty else { return commands }
        func rank(_ command: SlashCommand) -> Int? {
            let names = [command.name.lowercased()] + command.aliases.map { $0.lowercased() }
            if names.contains(query) { return 0 }
            if names.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if names.contains(where: { $0.contains(query) }) { return 2 }
            if command.description.localizedCaseInsensitiveContains(query) { return 3 }
            for name in names {
                var remaining = query[...]
                for character in name where remaining.first == character { remaining = remaining.dropFirst() }
                if remaining.isEmpty { return 4 }
            }
            return nil
        }
        var ranked: [(score: Int, index: Int, command: SlashCommand)] = []
        for (index, command) in commands.enumerated() {
            if let score = rank(command) { ranked.append((score, index, command)) }
        }
        ranked.sort { lhs, rhs in lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score }
        return ranked.map { $0.command }
    }
}

extension SlashCommand {
    var symbol: String {
        switch DesktopCommands.canonical(name) {
        case "plan", "view-plan": return "list.bullet.clipboard"
        case "goal": return "scope"
        case "mcps": return "point.3.connected.trianglepath.dotted"
        case "skills": return "sparkles"
        case "subagents", "config-agents", "personas", "dashboard": return "person.2"
        case "workflows", "workflow": return "arrow.triangle.branch"
        case "plugins", "marketplace": return "puzzlepiece.extension"
        case "model", "effort": return "brain"
        case "settings", "hooks": return "slider.horizontal.3"
        case "new", "home": return "square.and.pencil"
        case "resume", "history", "transcript", "jump": return "clock.arrow.circlepath"
        case "find": return "magnifyingglass"
        case "copy", "export": return "doc.on.doc"
        case "voice": return "mic"
        case "theme": return "paintpalette"
        case "docs", "tutorial", "release-notes": return "book"
        case "feedback": return "exclamationmark.bubble"
        case "usage", "context", "session-info": return "gauge.with.dots.needle.33percent"
        case "trace": return "waveform.path.ecg"
        case "doctor": return "stethoscope"
        case "memory", "remember", "flush", "dream": return "brain.head.profile"
        case "queue": return "text.line.first.and.arrowtriangle.forward"
        case "tasks": return "checklist"
        case "fork": return "arrow.triangle.branch"
        case "auto", "always-approve": return "checkmark.shield"
        default: return isSkill ? "sparkles" : "command"
        }
    }
}

extension AppStore {
    /// Handles a command natively. Returns false only for commands the harness implements.
    func handleDesktopCommand(_ name: String, arguments: String) -> Bool {
        let command = DesktopCommands.canonical(name)
        let features = self.features
        switch command {
        case "help": showCommandPalette = true
        case "tutorial": features.extras.openTutorial()
        case "settings": showSettings = true
        case "dashboard": features.sessions.openDashboard()
        case "workflows": featurePanel = .workflows
        case "plugins": featurePanel = .plugins
        case "btw": askSideQuestion(arguments)
        case "voice": features.composer.toggleVoice()
        case "new", "home": newTask()
        case "effort": features.composer.setEffort(arguments)
        case "model": features.composer.setModel(arguments)
        case "context": features.account.openContext()
        case "compact": features.composer.compact(arguments)
        case "fork": features.sessions.fork(arguments)
        case "resume": features.sessions.openResume()
        case "plan": enterPlanMode(description: arguments)
        case "view-plan": featurePanel = .plan
        case "remember": features.extensions.openRemember(arguments)
        case "memory": features.extensions.memoryCommand(arguments)
        case "flush": features.extensions.flushMemory()
        case "dream": features.extensions.dreamMemory()
        case "recap": Task { await requestRecap() }
        case "rewind": Task { await loadRewindPoints() }
        case "jump": features.transcript.openJump()
        case "expand": features.transcript.expandNext()
        case "edit-prompt": features.composer.openEditPrompt(keepDraft: false)
        case "queue": features.composer.showQueue()
        case "session-info": features.account.openSessionInfo()
        case "share": banner = "Session sharing is temporarily disabled"
        case "rename": features.sessions.rename(arguments)
        case "history": features.transcript.openHistory()
        case "transcript": features.transcript.openTranscriptWindow()
        case "trace": features.sessions.openTrace()
        case "export": features.transcript.export(arguments)
        case "copy": features.transcript.copy(arguments)
        case "find": features.transcript.openFind(arguments)
        case "usage": features.account.usage(arguments)
        case "tasks": features.sessions.openTasks()
        case "skills": featurePanel = .skills
        case "mcps": featurePanel = .mcps
        case "hooks": featurePanel = .hooks
        case "marketplace": featurePanel = .marketplace
        case "workflow":
            guard arguments == "runs" else { return false }
            features.sessions.openWorkflowRuns()
        case "personas": featurePanel = .personas
        case "config-agents": featurePanel = .agentDefinitions
        case "subagents": featurePanel = .agents
        case "goal" where arguments.isEmpty: featurePanel = .goals
        case "theme": features.extras.theme(arguments)
        case "auto": features.composer.toggleAutoMode()
        case "always-approve": features.composer.setAlwaysApprove(arguments)
        case "vim-mode": features.transcript.toggleVimMode()
        case "multiline":
            let enabled = !UserDefaults.standard.bool(forKey: "composerMultiline")
            UserDefaults.standard.set(enabled, forKey: "composerMultiline")
            banner = "✓ Multiline input: \(enabled ? "on — ↵ inserts a line, ⌘↵ sends" : "off")"
        case "compact-mode":
            let enabled = !UserDefaults.standard.bool(forKey: "compactConversation")
            UserDefaults.standard.set(enabled, forKey: "compactConversation")
            banner = "✓ Compact mode: \(enabled ? "on" : "off")"
        case "timestamps": features.transcript.toggleTimestamps()
        case "toggle-mouse-reporting":
            banner = "Mouse reporting is a terminal setting. Grok Desktop always receives clicks, scrolling, and selection directly."
        case "minimal":
            if minimalMode { banner = "You're already in minimal mode." }
            else { minimalMode = true; showInspector = false; banner = "Switched to minimal mode · /fullscreen to go back" }
        case "fullscreen":
            if minimalMode { minimalMode = false; banner = "Switched to fullscreen mode · /minimal to go back" }
            else { NSApp.keyWindow?.toggleFullScreen(nil) }
        case "timeline": features.transcript.toggleTimeline()
        case "cd": changeProject(arguments)
        case "imagine": generateMedia(kind: "image", description: arguments)
        case "imagine-video": generateMedia(kind: "video", description: arguments)
        case "changes":
            features.files.scope = .changes
            showSidePanel(.files)
        case "terminal": openTerminal()
        case "docs": features.extras.openDocs(arguments)
        case "release-notes": features.account.openReleaseNotes()
        case "announcements": features.account.announcements(arguments)
        case "feedback": features.account.feedback(arguments)
        case "doctor": features.sessions.openDoctor(arguments)
        case "import-claude": features.extensions.openImportClaude()
        case "login": showSettings = true
        case "delete": features.sessions.deleteCurrent()
        case "exit": NSApp.terminate(nil)
        case "gboom":
            // With arguments the terminal sends the text to the model unchanged.
            guard arguments.isEmpty else { sendLiteralPrompt("/gboom " + arguments); return true }
            features.extras.openGboom()
        case "scroll-debug":
            guard arguments.isEmpty else { sendLiteralPrompt("/scroll-debug " + arguments); return true }
            features.transcript.debug("scroll")
        case "debug": features.transcript.debug(arguments)
        default: return false
        }
        return true
    }

    /// `/cd [path]`: chooses the project that new tasks start in; running tasks stay where they are.
    private func changeProject(_ arguments: String) {
        guard !arguments.isEmpty else { addProject(); return }
        let expanded = (arguments as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: project?.path ?? FileManager.default.currentDirectoryPath)
        let path = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { banner = "Not a directory: \(arguments)"; return }
        let item = state.projects.first(where: { $0.path == path }) ?? Project(path: path)
        if !state.projects.contains(where: { $0.id == item.id }) { state.projects.append(item) }
        selectProject(item.id)
        banner = "→ \((path as NSString).abbreviatingWithTildeInPath)"
    }
}
