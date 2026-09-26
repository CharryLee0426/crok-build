import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Renders the session sheets and the trace window to PNGs when GROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
@MainActor
final class SessionSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-session-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRenderSessionSheetSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["GROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set GROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let store = makeStore()
        let model = store.features.sessions
        let panels: [(String, AnyView, CGSize)] = [
            ("fork", AnyView(ForkSheet(arguments: "Explore the rate limiter in a separate branch")), CGSize(width: 540, height: 560)),
            ("resume", AnyView(ResumeSheet()), CGSize(width: 760, height: 640)),
            ("dashboard", AnyView(DashboardSheet()), CGSize(width: 780, height: 660)),
            ("tasks", AnyView(TasksSheet()), CGSize(width: 720, height: 600)),
            ("doctor", AnyView(DoctorSheet(arguments: "")), CGSize(width: 740, height: 680)),
            ("doctor-fix", AnyView(DoctorSheet(arguments: "fix tmux-clipboard")), CGSize(width: 740, height: 680)),
        ]
        for (name, view, size) in panels {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try SnapshotRenderer.write(view.desktopEnvironment(store).frame(width: size.width, height: size.height), size: size, appearance: appearance,
                                           to: URL(fileURLWithPath: output).appendingPathComponent("session-\(name)-\(suffix).png"))
            }
        }
        // Workflow controls are live once the task's own turn has finished.
        if let id = store.state.selectedConversationID { store.runs[id]?.isRunning = false }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(WorkflowRunsSheet().desktopEnvironment(store).frame(width: 760, height: 640), size: CGSize(width: 760, height: 640), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent("session-workflow-runs-\(suffix).png"))
        }
        let states: [(String, TraceViewState)] = [
            ("loading", .loading(directory: "/Users/me/.grok/sessions/%2FUsers%2Fme%2Fcode%2Fgrok-desktop/0199a2c4-7d1e-7b3a-9f10-5e2d8c4b1a77")),
            ("failed", .failed(directory: "/Users/me/.grok/sessions/%2FUsers%2Fme%2Fcode%2Fgrok-desktop/0199a2c4-7d1e-7b3a-9f10-5e2d8c4b1a77",
                               error: "Error: could not read events.jsonl\ncaused by: unexpected end of file at line 1842")),
            ("unrecorded", .unavailable("This session has not been recorded yet")),
        ]
        for (name, state) in states {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = TraceWindowContent(state: state, title: "Render tables and math", revision: 0, reload: {}, openInBrowser: {}, save: {})
                try SnapshotRenderer.write(view.frame(width: 900, height: 560), size: CGSize(width: 900, height: 560), appearance: appearance,
                                           to: URL(fileURLWithPath: output).appendingPathComponent("session-trace-\(name)-\(suffix).png"))
            }
        }
        _ = model
    }

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let model = store.features.sessions
        model.harnessRequestsEnabled = false
        let app = Project(path: "/Users/me/code/grok-desktop"), api = Project(path: "/Users/me/code/billing-api")
        let now = Date()
        func task(_ project: Project, _ title: String, minutesAgo: Double, session: String? = nil, messages: [Message] = []) -> Conversation {
            Conversation(projectID: project.id, title: title, sessionID: session ?? UUID().uuidString.lowercased(), messages: messages, updatedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        let waiting = task(api, "Fix invoice rounding", minutesAgo: 2)
        let working = task(app, "Render tables and math", minutesAgo: 1, messages: [
            Message(kind: .user, text: "Render Markdown tables and LaTeX in the transcript."),
            Message(kind: .assistant, text: "I'll start with the table layout.\n\nUpdating `MarkdownView.swift` so columns size to their content…"),
        ])
        let idle = task(app, "Stream reasoning faster", minutesAgo: 25, messages: [
            Message(kind: .assistant, text: "Done — the reasoning view now streams without stalling, even for 50k-token thoughts."),
        ])
        let finished = task(app, "Explore the parser (fork)", minutesAgo: 8, messages: [
            Message(kind: .assistant, text: "## Summary\n- The tokenizer can be split out cleanly; I left a plan in PLAN.md."),
        ])
        let failed = task(api, "Migrate the webhook retries", minutesAgo: 40, messages: [
            Message(kind: .user, text: "Move retries to the new queue."),
        ])
        let inactive = [
            task(app, "Add a command palette", minutesAgo: 60 * 26, messages: [Message(kind: .assistant, text: "The palette now ranks exact matches first.")]),
            task(api, "Review the billing export", minutesAgo: 60 * 24 * 3),
            task(app, "Polish the sidebar", minutesAgo: 60 * 24 * 9, session: "saved-1"),
        ]
        store.state = DesktopState(projects: [app, api], conversations: [waiting, working, idle, finished, failed] + inactive,
                                   selectedProjectID: app.id, selectedConversationID: working.id, deletedSessionIDs: ["saved-3"])
        store.runs[waiting.id] = RunState()
        store.runs[waiting.id]?.approvals = [Approval(requestID: 1, title: "Allow npm test to run?", detail: "npm test", options: [])]
        store.runs[working.id] = RunState()
        store.runs[working.id]?.isRunning = true
        store.runs[working.id]?.phase = "Working"
        store.runs[failed.id] = RunState()
        store.runs[failed.id]?.phase = "Needs attention"
        store.clients[idle.id] = ACPClient(); store.loaded.insert(idle.id)
        store.clients[working.id] = ACPClient(); store.loaded.insert(working.id)
        store.unreadConversationIDs = [finished.id]

        var researcher = SubagentState(id: "sub-1", title: "Survey table renderers", agentType: "explore", status: "running", tokensUsed: 18_400, toolCalls: 9, turns: 4)
        researcher.address = "sub-1"
        store.runs[working.id]?.subagents = [researcher, SubagentState(id: "sub-2", title: "Check KaTeX licensing", agentType: "general", status: "completed", tokensUsed: 6_200, toolCalls: 3, turns: 2)]
        let session = working.sessionID ?? ""
        let updates: [[String: Any]] = [
            ["sessionUpdate": "workflow_updated", "run_id": "wf-1", "revision": 4, "name": "deep-research", "objective": "Compare Markdown table renderers and recommend one for the transcript.",
             "status": "active", "phases": [["title": "Plan", "state": "complete"], ["title": "Research", "state": "active"], ["title": "Synthesize", "state": "pending"]],
             "current_phase": "Research", "agent_budget": 12, "agents_used": 5, "agents_reserved": 2, "elapsed_ms": 312_000,
             "agents": [["agent_id": "a1", "label": "planner", "phase": "Plan", "state": "complete", "model": "grok-code-fast", "tokens_used": 4_100, "duration_ms": 41_000],
                        ["agent_id": "a2", "label": "researcher-1", "phase": "Research", "state": "running", "model": "grok-4", "tokens_used": 22_000, "duration_ms": 180_000],
                        ["agent_id": "a3", "label": "researcher-2", "phase": "Research", "state": "running", "model": "grok-4", "tokens_used": 15_300, "duration_ms": 150_000]]],
            ["sessionUpdate": "workflow_updated", "run_id": "wf-0", "revision": 9, "name": "release-notes", "objective": "Draft release notes for 1.0.41.",
             "status": "user_paused", "pause_message": "Paused by you", "phases": [["title": "Collect", "state": "complete"], ["title": "Draft", "state": "pending"]],
             "agent_budget": 4, "agents_used": 1, "elapsed_ms": 95_000, "agents": [["agent_id": "b1", "label": "collector", "phase": "Collect", "state": "complete", "tokens_used": 3_000, "duration_ms": 60_000]]],
            ["sessionUpdate": "background_tasks", "tasks": [
                ["task_id": "t-1", "command": "npm run dev", "description": "Start the preview server", "cwd": app.path, "kind": "bash", "status": "running", "started_at": iso(now.addingTimeInterval(-754))],
                ["task_id": "t-2", "command": "tail -f build.log", "cwd": app.path, "kind": "monitor", "status": "running", "started_at": iso(now.addingTimeInterval(-300))],
                ["task_id": "t-3", "command": "swift test", "cwd": app.path, "kind": "bash", "status": "failed", "started_at": iso(now.addingTimeInterval(-900)), "ended_at": iso(now.addingTimeInterval(-840)), "exit_code": 1],
            ]],
            ["sessionUpdate": "scheduled_task_created", "task_id": "loop-1", "prompt": "check the deploy status and summarize any failures", "human_schedule": "every 30 minutes", "next_fire_at": iso(now.addingTimeInterval(1_260))],
        ]
        for update in updates { _ = model.handle(method: "x.ai/session_notification", params: ["sessionId": session], update: update, conversationID: working.id) }

        model.resumeRows = [
            HarnessSessionRow(id: "saved-1", title: "Polish the sidebar", firstPrompt: "Polish the sidebar spacing", cwd: app.path, updatedAt: now.addingTimeInterval(-9 * 86_400),
                              messageCount: 42, branch: "main", modelID: "grok-code-fast", source: "local", summary: "Tightened row spacing and added the Recents fold."),
            HarnessSessionRow(id: "saved-2", title: "Investigate the flaky ACP timeout test", cwd: app.path, updatedAt: now.addingTimeInterval(-3 * 3_600),
                              messageCount: 18, branch: "fix/acp-timeout", modelID: "grok-4", source: "local"),
            HarnessSessionRow(id: "saved-3", title: "Prototype voice input", cwd: app.path, updatedAt: now.addingTimeInterval(-2 * 86_400),
                              messageCount: 7, source: "both", worktreeLabel: "voice-prototype"),
            HarnessSessionRow(id: "saved-4", title: "Upgrade to the new ACP schema", cwd: "/Users/me/code/grok-desktop-worktrees/acp", updatedAt: now.addingTimeInterval(-40 * 86_400),
                              messageCount: 64, source: "remote"),
        ]
        model.resumeCursor = "next"
        if let report = try? DoctorReport.decode(Data(SessionFeatureTests.doctorSample.utf8)) { model.doctorReport = report }
        model.desktopChecks = [
            DoctorDesktopCheck(id: "runtime", title: "Grok runtime", value: "Version 1.0.41 (ef60bab1fc85) [stable]", detail: "~/Applications/Grok Desktop.app/Contents/Resources/grok", status: .ok, symbol: "cpu"),
            DoctorDesktopCheck.signIn([.codex: AccountStatus(state: .connected, identity: "dev@example.com", detail: "Signed in")]),
            DoctorDesktopCheck.microphone(.denied),
            DoctorDesktopCheck.notifications(.notDetermined),
        ]
        return store
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
