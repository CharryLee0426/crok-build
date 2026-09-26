import XCTest
@testable import GrokDesktop

/// Fork, rename, delete, resume, and task controls against the offline ACP fixture, with the
/// session methods answered the way the shell answers them.
@MainActor
final class SessionHarnessTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let home: URL
        let defaultsName = "GrokDesktopSessions.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: AppStore
        let project: Project
        var model: SessionFeatureModel { store.features.sessions }

        /// `fail` maps a method to the `data` of the JSON-RPC error the fixture returns for it.
        init(fail: [String: String] = [:], worktree: String? = nil) throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
            // Resolved, so the path matches the harness's own view of its working directory.
            let created = FileManager.default.temporaryDirectory.appendingPathComponent("grok-session-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            directory = created.resolvingSymlinksInPath()
            home = directory.appendingPathComponent("grok-home", isDirectory: true)
            defaults = UserDefaults(suiteName: defaultsName)!
            let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
            let source = try String(contentsOf: fixtureURL, encoding: .utf8).components(separatedBy: "if __name__ == \"__main__\":")[0]
                .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
            let options = String(decoding: try JSONSerialization.data(withJSONObject: ["fail": fail, "worktree": worktree ?? ""], options: .withoutEscapingSlashes), as: UTF8.self)
            let harness = #"""
OPTIONS = json.loads(OPTIONS_JSON)

def saved(session_id, summary, messages, branch=None, first_prompt=None):
    row = {"sessionId": session_id, "summary": summary, "updatedAt": "2026-09-20T08:00:00Z", "createdAt": "2026-09-19T08:00:00Z",
           "cwd": os.getcwd(), "source": "local", "numMessages": messages, "modelId": "fixture-grok-build"}
    if branch: row["branch"] = branch
    if first_prompt: row["firstPrompt"] = first_prompt
    return row

class SessionHarness(MockHarness):
    def handle(self, message):
        with open(os.path.join(os.path.dirname(__file__), "requests.jsonl"), "a") as log:
            log.write(json.dumps(message) + "\n")
        method = message.get("method")
        rid = message.get("id")
        params = message.get("params", {})
        if method in OPTIONS["fail"]:
            self.emit({"id": rid, "error": {"code": -32600, "message": "Invalid request", "data": OPTIONS["fail"][method]}})
        elif method == "_x.ai/session/fork":
            new_id = "fork-of-" + params["sourceSessionId"]
            self.sessions[new_id] = {"sessionId": new_id, "cwd": params["newCwd"], "title": "Fork (fixture)", "updatedAt": "2026-09-22T10:00:00Z"}
            self.result(rid, {"newSessionId": new_id, "chatMessagesCopied": 2, "updatesCopied": 4, "planStateCopied": False,
                              "newCwd": params["newCwd"], "parentSessionId": params["sourceSessionId"]})
        elif method == "_x.ai/git/worktree/resume_session":
            path = OPTIONS["worktree"]
            self.result(rid, {"result": {"sessionId": "worktree-of-" + params["sessionId"], "worktreePath": path, "effectiveCwd": path,
                                         "remoteRestored": False, "parentSessionId": params["sessionId"], "chatMessagesCopied": 2, "updatesCopied": 4,
                                         "codeRestored": True, "restoreSummary": "checked out abc12345, staged: true"}, "error": None})
        elif method in ("_x.ai/session/rename", "_x.ai/session/delete"):
            self.result(rid, {"success": True})
        elif method == "_x.ai/session/list":
            if params.get("cursor") == "page-2":
                page = {"sessions": [saved("saved-3", "Third saved session", 2)]}
            else:
                page = {"sessions": [saved("saved-1", "Refactor the parser", 12, "main"), saved("saved-2", "", 3, None, "Fix the flaky test")], "nextCursor": "page-2"}
            self.result(rid, {"result": page, "error": None})
        elif method == "_x.ai/session/search":
            self.result(rid, {"result": {"results": [{"sessionId": "saved-2", "cwd": os.getcwd(), "summary": "Fix the flaky test", "updatedAt": "2026-09-20T08:00:00Z",
                                                      "score": 1.5, "matchedFields": ["content"], "snippet": "the <mark>flaky</mark> test"}], "bootstrapping": False}, "error": None})
        elif method == "_x.ai/task/list":
            start = {"secs_since_epoch": 1790000000, "nanos_since_epoch": 0}
            self.result(rid, {"result": {"tasks": [
                {"task_id": "bg-running", "command": "npm run dev", "cwd": os.getcwd(), "start_time": start, "end_time": None, "output": "", "output_file": "", "truncated": False, "exit_code": None, "signal": None, "completed": False},
                {"task_id": "bg-done", "command": "npm test", "cwd": os.getcwd(), "start_time": start, "end_time": start, "output": "ok", "output_file": "", "truncated": False, "exit_code": 0, "signal": None, "completed": True},
            ]}, "error": None})
        elif method == "_x.ai/task/kill":
            self.result(rid, {"result": {"taskId": params["taskId"], "outcome": "killed"}, "error": None})
        elif method == "_x.ai/scheduler/delete":
            self.result(rid, {"result": {"taskId": params["taskId"], "deleted": True}, "error": None})
        else:
            super().handle(message)

SessionHarness().run()
"""#.replacingOccurrences(of: "OPTIONS_JSON", with: String(decoding: try JSONSerialization.data(withJSONObject: options, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self))
            let executable = directory.appendingPathComponent("fixture-grok")
            try (source + harness).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: executable.path)
            project = Project(path: directory.path)
            store.state = DesktopState(projects: [project], selectedProjectID: project.id)
            let home = home
            model.configURL = { home.appendingPathComponent("config.toml") }
            model.grokHome = { home }
            model.accountReader = { [:] }
            model.confirmDelete = { _, _, completion in completion(true) }
        }

        var requests: [[String: Any]] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }

        func params(for method: String) -> [[String: Any]] {
            requests.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
        }

        /// Prompts sent to each session, in order.
        var prompts: [(session: String, text: String)] {
            params(for: "session/prompt").map { value in
                (value["sessionId"] as? String ?? "", (value["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined())
            }
        }

        /// Starts a task with a live session, like typing a first prompt.
        func startTask() async throws -> Conversation {
            store.draft = "Inspect the offline fixture"
            store.send()
            try await eventually { !self.store.run.isRunning && !self.prompts.isEmpty }
            return try XCTUnwrap(store.conversation)
        }

        func gitInit() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init", "-q", directory.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("git init failed") }
        }

        func cleanup() {
            model.closeResume()
            store.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Fork

    func testForkInPlaceCopiesTheSessionLoadsItAndSendsTheDirective() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = try await fixture.startTask()
        let parentSession = try XCTUnwrap(parent.sessionID)
        fixture.model.fork("--no-worktree Explore the parser")
        try await eventually { fixture.prompts.count == 2 && !fixture.store.run.isRunning }

        let fork = try XCTUnwrap(fixture.params(for: "_x.ai/session/fork").first)
        XCTAssertEqual(fork["sourceSessionId"] as? String, parentSession)
        XCTAssertEqual(fork["sourceCwd"] as? String, fixture.project.path)
        XCTAssertEqual(fork["newCwd"] as? String, fixture.project.path)
        XCTAssertEqual(fork["sessionKind"] as? String, "fork")
        XCTAssertNil(fork["sourceWorkspaceDir"])
        let child = try XCTUnwrap(fixture.store.conversation)
        XCTAssertNotEqual(child.id, parent.id)
        XCTAssertEqual(child.sessionID, "fork-of-\(parentSession)")
        XCTAssertEqual(child.projectID, fixture.project.id)
        XCTAssertTrue(fixture.store.loaded.contains(child.id))
        XCTAssertEqual(fixture.params(for: "session/load").last?["sessionId"] as? String, child.sessionID)
        XCTAssertEqual(fixture.prompts.last?.session, child.sessionID)
        XCTAssertEqual(fixture.prompts.last?.text, "Explore the parser")
        XCTAssertTrue(child.messages.contains { $0.kind == .system && $0.text == "Session fork-of-\(parentSession) (forked from \(parentSession)), use /dashboard to switch between sessions\n  (both agents share cwd)" })
        XCTAssertEqual(fixture.store.task(parent.id)?.messages.last?.text, "Forked: Explore the parser")
        XCTAssertEqual(fixture.store.task(parent.id)?.messages.last?.kind, .system)
    }

    func testForkGuardsAndFailuresMatchTheTerminal() async throws {
        let fixture = try Fixture(fail: ["_x.ai/session/fork": "source session not found"])
        defer { fixture.cleanup() }
        fixture.model.fork("")
        XCTAssertEqual(fixture.store.banner, "/fork only works inside a session")
        let pending = Conversation(projectID: fixture.project.id, title: "Starting")
        fixture.store.state.conversations = [pending]
        fixture.store.state.selectedConversationID = pending.id
        fixture.model.fork("")
        XCTAssertEqual(fixture.store.banner, "Cannot fork: session is still being created")
        fixture.model.fork("--worktree --worktree")
        XCTAssertEqual(fixture.store.banner, "--worktree specified twice")

        fixture.store.state.conversations = []
        fixture.store.state.selectedConversationID = nil
        let parent = try await fixture.startTask()
        fixture.model.fork("--worktree")
        try await eventually { fixture.store.banner == "Cannot create worktree: not in a git repository" }
        fixture.model.fork("try again")
        try await eventually { fixture.store.banner == "fork failed: source session not found" }
        XCTAssertEqual(fixture.store.state.conversations.map(\.id), [parent.id], "The placeholder is removed")
        XCTAssertEqual(fixture.store.state.selectedConversationID, parent.id)
        XCTAssertFalse(fixture.store.task(parent.id)?.messages.contains { $0.text.hasPrefix("Forked") } ?? true)
    }

    func testForkIntoAWorktreeOpensTheNewFolderAndReportsTheRestore() async throws {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("grok-session-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let fixture = try Fixture(worktree: worktree.resolvingSymlinksInPath().path)
        defer { fixture.cleanup() }
        try fixture.gitInit()
        let parent = try await fixture.startTask()
        fixture.model.fork("--worktree")
        try await eventually { fixture.store.state.conversations.count == 2 && fixture.store.conversation.map { fixture.store.loaded.contains($0.id) } == true }

        let request = try XCTUnwrap(fixture.params(for: "_x.ai/git/worktree/resume_session").first)
        XCTAssertEqual(request["sessionId"] as? String, parent.sessionID)
        XCTAssertEqual(request["sourceCwd"] as? String, fixture.project.path)
        XCTAssertEqual(request["copyMode"] as? String, "dirty")
        let child = try XCTUnwrap(fixture.store.conversation)
        let childProject = try XCTUnwrap(fixture.store.project)
        XCTAssertEqual(childProject.path, worktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(child.projectID, childProject.id)
        XCTAssertEqual(child.sessionID, "worktree-of-\(parent.sessionID ?? "")")
        let notes = child.messages.filter { $0.kind == .system }.map(\.text)
        XCTAssertTrue(notes.contains("Worktree ready: \(worktree.resolvingSymlinksInPath().path)"))
        XCTAssertTrue(notes.contains("✓ Code restored: checked out abc12345, staged: true"))
        XCTAssertTrue(notes.contains { $0.hasPrefix("Session worktree-of-") && !$0.contains("both agents share cwd") })
        XCTAssertEqual(fixture.store.task(parent.id)?.messages.last?.text, "Forked")
    }

    func testForkAsksInARepositoryAndRemembersTheAnswer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.gitInit()
        _ = try await fixture.startTask()
        fixture.model.fork("look elsewhere")
        try await eventually { fixture.store.sheet == .fork(arguments: "look elsewhere") }
        XCTAssertTrue(fixture.params(for: "_x.ai/session/fork").isEmpty)

        fixture.model.resolveFork(.never, arguments: "look elsewhere")
        XCTAssertNil(fixture.store.sheet)
        let config = try String(contentsOf: fixture.home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(config, "[hints]\nfork_worktree_mode = \"never\"\n")
        try await eventually { fixture.params(for: "_x.ai/session/fork").count == 1 && fixture.prompts.count == 2 && !fixture.store.run.isRunning }
        XCTAssertEqual(fixture.prompts.last?.text, "look elsewhere")

        // "Never worktree" skips the question from now on.
        fixture.model.fork("")
        try await eventually { fixture.params(for: "_x.ai/session/fork").count == 2 }
        XCTAssertNil(fixture.store.sheet)
    }

    // MARK: Rename

    func testRenameCallsTheHarnessAndResetsToAuto() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = Conversation(projectID: fixture.project.id, title: "Explore the desktop harness", sessionID: "fixture-history-001")
        fixture.store.state.conversations = [task]
        fixture.store.state.selectedConversationID = task.id

        fixture.model.rename("  Ship\u{7} the parser ")
        try await eventually { fixture.store.banner == "Session renamed to \"Ship the parser\"" }
        XCTAssertEqual(fixture.store.task(task.id)?.title, "Ship the parser")
        let rename = try XCTUnwrap(fixture.params(for: "_x.ai/session/rename").first)
        XCTAssertEqual(rename["sessionId"] as? String, "fixture-history-001")
        XCTAssertEqual(rename["title"] as? String, "Ship the parser")
        XCTAssertEqual(rename["cwd"] as? String, fixture.project.path)
        XCTAssertEqual(rename["kind"] as? String, "build")
        XCTAssertNil(rename["resetToAuto"])
        XCTAssertTrue(fixture.params(for: "session/load").isEmpty, "Renaming does not load the session")

        fixture.model.rename("--auto")
        try await eventually { fixture.store.banner == "Session title reset to auto" }
        let reset = try XCTUnwrap(fixture.params(for: "_x.ai/session/rename").last)
        XCTAssertEqual(reset["title"] as? String, "")
        XCTAssertEqual(reset["resetToAuto"] as? Bool, true)

        let count = fixture.params(for: "_x.ai/session/rename").count
        fixture.model.rename("--auto now")
        XCTAssertEqual(fixture.store.banner, "--auto takes no title")
        fixture.model.rename("")
        XCTAssertTrue(fixture.store.showRename, "A bare /rename opens the rename sheet")
        XCTAssertEqual(fixture.params(for: "_x.ai/session/rename").count, count)
    }

    func testRenameFailureKeepsTheLocalTitleAndLocalTasksRenameLocally() async throws {
        let fixture = try Fixture(fail: ["_x.ai/session/rename": "session not found: fixture-history-001"])
        defer { fixture.cleanup() }
        let saved = Conversation(projectID: fixture.project.id, title: "Old", sessionID: "fixture-history-001")
        let local = Conversation(projectID: fixture.project.id, title: "Draft task")
        fixture.store.state.conversations = [saved, local]
        fixture.model.applyRename(id: saved.id, title: "New")
        try await eventually { fixture.store.banner == "Couldn't rename session: session not found: fixture-history-001" }
        XCTAssertEqual(fixture.store.task(saved.id)?.title, "New")
        fixture.model.applyRename(id: local.id, title: "Local only")
        try await eventually { fixture.store.banner == "Session renamed to \"Local only\"" }
        XCTAssertEqual(fixture.store.task(local.id)?.title, "Local only")
        XCTAssertEqual(fixture.params(for: "_x.ai/session/rename").count, 1)
    }

    // MARK: Delete

    func testDeleteCancelsStopsBackgroundTasksAndDeletesThroughTheLiveSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try await fixture.startTask()
        let session = try XCTUnwrap(task.sessionID)
        fixture.model.deleteCurrent()
        try await eventually { fixture.store.task(task.id) == nil }

        XCTAssertEqual(fixture.store.banner, "Session deleted")
        XCTAssertNil(fixture.store.state.selectedConversationID)
        XCTAssertTrue(fixture.store.state.deletedSessionIDs.contains(session))
        let sequence = fixture.requests.compactMap { $0["method"] as? String }
            .filter { ["session/cancel", "_x.ai/task/list", "_x.ai/task/kill", "_x.ai/session/delete"].contains($0) }
        XCTAssertEqual(sequence, ["session/cancel", "_x.ai/task/list", "_x.ai/task/kill", "_x.ai/session/delete"])
        let cancel = try XCTUnwrap(fixture.params(for: "session/cancel").first)
        XCTAssertEqual((cancel["_meta"] as? [String: Any])?["cancelSubagents"] as? Bool, true)
        let kill = try XCTUnwrap(fixture.params(for: "_x.ai/task/kill").first)
        XCTAssertEqual(kill["taskId"] as? String, "bg-running", "Only running tasks are stopped")
        XCTAssertEqual(kill["source"] as? String, "teardown")
        let delete = try XCTUnwrap(fixture.params(for: "_x.ai/session/delete").first)
        XCTAssertEqual(delete["sessionId"] as? String, session)
        XCTAssertEqual(delete["cwd"] as? String, fixture.project.path)
        XCTAssertNil(fixture.store.clients[task.id])
    }

    func testDeleteFailureKeepsTheTask() async throws {
        let fixture = try Fixture(fail: ["_x.ai/session/delete": "remote delete failed"])
        defer { fixture.cleanup() }
        let saved = Conversation(projectID: fixture.project.id, title: "Saved", sessionID: "fixture-history-001")
        fixture.store.state.conversations = [saved]
        fixture.store.state.selectedConversationID = saved.id
        var confirmations: [(String, Bool)] = []
        fixture.model.confirmDelete = { title, hasSession, completion in confirmations.append((title, hasSession)); completion(true) }
        fixture.model.deleteCurrent()
        try await eventually { fixture.store.banner == "Couldn't delete session: remote delete failed" }
        XCTAssertEqual(confirmations.map(\.0), ["Saved"])
        XCTAssertEqual(confirmations.map(\.1), [true])
        XCTAssertNotNil(fixture.store.task(saved.id))
        XCTAssertFalse(fixture.store.state.deletedSessionIDs.contains("fixture-history-001"))
        XCTAssertTrue(fixture.params(for: "session/cancel").isEmpty, "A session that is not open has no turn to cancel")

        fixture.model.confirmDelete = { _, _, completion in completion(false) }
        fixture.model.deleteCurrent()
        XCTAssertEqual(fixture.params(for: "_x.ai/session/delete").count, 1, "Cancel keeps the session")

        let local = Conversation(projectID: fixture.project.id, title: "Never sent")
        fixture.store.state.conversations.append(local)
        await fixture.model.performDelete(local.id)
        XCTAssertNil(fixture.store.task(local.id))
        XCTAssertEqual(fixture.store.banner, "Session deleted")
    }

    // MARK: Resume

    func testResumeListsPagesSearchesAndOpensSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.loadResumeSessions()
        XCTAssertNil(model.resumeError)
        XCTAssertEqual(model.resumeRows.map(\.id), ["saved-1", "saved-2"])
        XCTAssertEqual(model.resumeRows.map(\.title), ["Refactor the parser", "Fix the flaky test"])
        XCTAssertEqual(model.resumeCursor, "page-2")
        let list = try XCTUnwrap(fixture.params(for: "_x.ai/session/list").first)
        XCTAssertEqual(list["cwd"] as? String, fixture.project.path)
        XCTAssertEqual(list["limit"] as? Int, 30)
        await model.loadResumeSessions(more: true)
        XCTAssertEqual(model.resumeRows.map(\.id), ["saved-1", "saved-2", "saved-3"])
        XCTAssertNil(model.resumeCursor)
        XCTAssertEqual(fixture.params(for: "_x.ai/session/list").last?["cursor"] as? String, "page-2")

        await model.searchSessions("flaky")
        XCTAssertEqual(model.searchRows.map(\.id), ["saved-2"])
        XCTAssertEqual(model.searchRows.first?.snippet, "the flaky test")
        let search = try XCTUnwrap(fixture.params(for: "_x.ai/session/search").first)
        XCTAssertEqual(search["query"] as? String, "flaky")
        XCTAssertEqual(search["limit"] as? Int, 20)
        XCTAssertEqual(search["includeContent"] as? Bool, true)
        XCTAssertEqual(fixture.params(for: "initialize").count, 1, "The sheet reuses one connection")

        fixture.store.state.deletedSessionIDs = ["saved-2"]
        fixture.store.sheet = .resume
        await model.resumeSession(model.resumeRows[1])
        XCTAssertNil(fixture.store.sheet)
        let resumed = try XCTUnwrap(fixture.store.conversation)
        XCTAssertEqual(resumed.sessionID, "saved-2")
        XCTAssertEqual(resumed.title, "Fix the flaky test")
        XCTAssertEqual(resumed.projectID, fixture.project.id)
        XCTAssertFalse(fixture.store.state.deletedSessionIDs.contains("saved-2"), "Resuming brings back a session removed from the sidebar")
        XCTAssertTrue(fixture.store.loaded.contains(resumed.id))
        XCTAssertEqual(fixture.params(for: "session/load").last?["sessionId"] as? String, "saved-2")

        fixture.store.newTask()
        await model.resumeSession(model.resumeRows[1])
        XCTAssertEqual(fixture.store.state.conversations.filter { $0.sessionID == "saved-2" }.count, 1, "An existing task is reused")
        XCTAssertEqual(fixture.store.state.selectedConversationID, resumed.id)

        model.closeResume()
        try await eventually { fixture.store.auxiliaryClients.isEmpty }
    }

    // MARK: Dashboard

    func testDashboardStopsATaskThatIsNotOnScreenAndRepliesToIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Wait for me fixture:wait"
        store.send()
        try await eventually { store.run.isRunning && store.run.phase == "Working" }
        let id = try XCTUnwrap(store.state.selectedConversationID)
        let session = try XCTUnwrap(store.task(id)?.sessionID)
        store.newTask()
        XCTAssertEqual(DashboardEntry.build(store: store, boards: fixture.model.boards, deleting: []).first { $0.id == id }?.group, .working)

        fixture.model.stopTask(id)
        try await eventually { store.runs[id]?.isRunning == false }
        XCTAssertEqual(store.runs[id]?.phase, "Stopped")
        XCTAssertEqual(fixture.params(for: "session/cancel").first?["sessionId"] as? String, session)
        XCTAssertNil(store.state.selectedConversationID, "Stopping from the dashboard does not change the task on screen")

        fixture.model.reply(to: id, text: "  Now summarize  ")
        XCTAssertEqual(store.state.selectedConversationID, id)
        try await eventually { fixture.prompts.count == 2 && store.runs[id]?.isRunning == false }
        XCTAssertEqual(fixture.prompts.last?.session, session)
        XCTAssertEqual(fixture.prompts.last?.text, "Now summarize")
        let entry = try XCTUnwrap(DashboardEntry.build(store: store, boards: fixture.model.boards, deleting: []).first { $0.id == id })
        XCTAssertEqual(entry.group, .idle)
        XCTAssertTrue(entry.preview.hasPrefix("The installed app uses its bundled Crok runtime"), entry.preview)
    }

    // MARK: Tasks

    func testTaskControlsUseTheSessionScopedMethods() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try await fixture.startTask()
        let session = try XCTUnwrap(task.sessionID)
        let model = fixture.model

        // Notifications arrive through the store's routing, as the harness sends them.
        _ = fixture.store.receiveFeatureNotification("x.ai/session_notification", params: ["sessionId": session, "update": [
            "sessionUpdate": "scheduled_task_created", "task_id": "loop-1", "prompt": "check deploy status", "human_schedule": "every 30 minutes",
        ]], id: task.id)
        XCTAssertEqual(model.board(for: task.id).scheduled.map(\.id), ["loop-1"])

        await model.refreshBackgroundTasks()
        XCTAssertEqual(model.board(for: task.id).background.map(\.id), ["bg-running", "bg-done"])
        XCTAssertEqual(model.board(for: task.id).background.map(\.status), ["running", "completed"])

        model.stopBackgroundTask("bg-running", conversationID: task.id)
        XCTAssertTrue(model.board(for: task.id).stopping.contains("bg-running"))
        try await eventually { !fixture.params(for: "_x.ai/task/kill").isEmpty }
        let kill = try XCTUnwrap(fixture.params(for: "_x.ai/task/kill").first)
        XCTAssertEqual(kill["sessionId"] as? String, session)
        XCTAssertEqual(kill["taskId"] as? String, "bg-running")
        XCTAssertNil(kill["source"], "A single stop is a client UI kill")

        model.deleteScheduledTask("loop-1", conversationID: task.id)
        try await eventually { model.board(for: task.id).scheduled.isEmpty }
        let delete = try XCTUnwrap(fixture.params(for: "_x.ai/scheduler/delete").first)
        XCTAssertEqual(delete["sessionId"] as? String, session)
        XCTAssertEqual(delete["taskId"] as? String, "loop-1")
        XCTAssertNil(model.tasksError)
    }
}

@MainActor
private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
}
