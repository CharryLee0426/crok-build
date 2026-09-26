import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Parsing, reducers, and formatting behind /fork, /rename, /resume, /tasks, /workflow runs, /doctor, and /trace.
@MainActor
final class SessionFeatureTests: XCTestCase {
    // MARK: /fork arguments

    func testForkArgumentsReadFlagsBeforeTheDirective() throws {
        XCTAssertEqual(try SessionForkArguments.parse(""), SessionForkArguments(worktree: nil, directive: nil))
        XCTAssertEqual(try SessionForkArguments.parse("explore the rate-limit hypothesis"), SessionForkArguments(worktree: nil, directive: "explore the rate-limit hypothesis"))
        XCTAssertEqual(try SessionForkArguments.parse("--worktree"), SessionForkArguments(worktree: true, directive: nil))
        XCTAssertEqual(try SessionForkArguments.parse("--no-worktree"), SessionForkArguments(worktree: false, directive: nil))
        XCTAssertEqual(try SessionForkArguments.parse("--worktree investigate the bug"), SessionForkArguments(worktree: true, directive: "investigate the bug"))
        XCTAssertEqual(try SessionForkArguments.parse("  --no-worktree   try the other fix  "), SessionForkArguments(worktree: false, directive: "try the other fix"))
        // Only leading words are flags; a directive may mention them or start with `--`.
        XCTAssertEqual(try SessionForkArguments.parse("fix --worktree handling"), SessionForkArguments(worktree: nil, directive: "fix --worktree handling"))
        XCTAssertEqual(try SessionForkArguments.parse("--verbose output please"), SessionForkArguments(worktree: nil, directive: "--verbose output please"))
    }

    func testForkArgumentErrorsMatchTheTerminal() {
        func message(_ text: String) -> String? {
            do { _ = try SessionForkArguments.parse(text); return nil } catch { return error.localizedDescription }
        }
        XCTAssertEqual(message("--worktree --no-worktree"), "--worktree and --no-worktree are mutually exclusive")
        XCTAssertEqual(message("--no-worktree --worktree go"), "--worktree and --no-worktree are mutually exclusive")
        XCTAssertEqual(message("--worktree --worktree"), "--worktree specified twice")
        XCTAssertEqual(message("--no-worktree --no-worktree"), "--no-worktree specified twice")
        XCTAssertEqual(message("--at 3 retry"), "--at is not supported in this version")
    }

    func testForkWorktreeModeReadsHintsWithLegacyFallback() {
        XCTAssertEqual(SessionForkWorktreeMode.read(GrokConfig(text: "")), .ask)
        XCTAssertEqual(SessionForkWorktreeMode.read(GrokConfig(text: "[hints]\nfork_worktree_mode = \"always\"\n")), .always)
        XCTAssertEqual(SessionForkWorktreeMode.read(GrokConfig(text: "[hints]\nworktree_mode = \"never\"\n")), .never)
        XCTAssertEqual(SessionForkWorktreeMode.read(GrokConfig(text: "[hints]\nworktree_mode = \"never\"\nfork_worktree_mode = \"ask\"\n")), .ask)
        XCTAssertEqual(SessionForkWorktreeMode.read(GrokConfig(text: "[hints]\nfork_worktree_mode = \"sometimes\"\n")), .never, "Unknown values mean never, as in the terminal")
    }

    func testForkChoicesUseTheTerminalWording() {
        XCTAssertEqual(SessionForkChoice.allCases.map(\.title), ["Yes", "No", "Always worktree", "Never worktree"])
        XCTAssertEqual(SessionForkChoice.allCases.map(\.detail), [
            "Fork in a new isolated git worktree", "Fork in the current cwd",
            "Use worktree and stop asking (reset in config.toml)", "Skip worktree and stop asking (reset in config.toml)",
        ])
        XCTAssertEqual(SessionForkChoice.allCases.map(\.usesWorktree), [true, false, true, false])
        XCTAssertEqual(SessionForkChoice.allCases.map(\.persistedMode), [nil, nil, .always, .never])
    }

    func testWorktreeDetectionReadsTheSummaryAndGitLayout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain/src", isDirectory: true)
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("../.git"), withIntermediateDirectories: true)
        XCTAssertFalse(SessionWorktreeDetection.isWorktree(sessionDirectory: nil, cwd: plain.path))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: /elsewhere/.git/worktrees/linked\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionWorktreeDetection.isWorktree(sessionDirectory: nil, cwd: linked.path))
        let marked = root.appendingPathComponent("marked", isDirectory: true)
        try FileManager.default.createDirectory(at: marked.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "/source/repo\n".write(to: marked.appendingPathComponent(".git/grok-worktree-source"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionWorktreeDetection.isWorktree(sessionDirectory: nil, cwd: marked.path))
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try #"{"session_kind":"worktree"}"#.write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionWorktreeDetection.isWorktree(sessionDirectory: session, cwd: plain.path))
    }

    // MARK: /rename

    func testRenameValidationMatchesTheTerminal() {
        enum Outcome: Equatable { case success(SessionRenameRequest), failure(String) }
        func parse(_ text: String) -> Outcome {
            do { return .success(try SessionRenameRequest.parse(text)) } catch { return .failure(error.localizedDescription) }
        }
        XCTAssertEqual(parse("  Ship the parser  "), .success(.title("Ship the parser")))
        XCTAssertEqual(parse("Tab\tand\u{7}bell"), .success(.title("Tabandbell")))
        XCTAssertEqual(parse("Left\u{202E}to right\u{2066}"), .success(.title("Leftto right")))
        XCTAssertEqual(parse("--auto"), .success(.auto))
        XCTAssertEqual(parse("--auto\u{7}"), .success(.auto))
        XCTAssertEqual(parse("--automatic naming"), .success(.title("--automatic naming")))
        XCTAssertEqual(parse("--auto please"), .failure("--auto takes no title"))
        XCTAssertEqual(parse("--auto\tmore"), .failure("--auto takes no title"))
        XCTAssertEqual(parse(""), .failure("Usage: /rename <new title> | --auto"))
        XCTAssertEqual(parse("\u{1B}\u{7}"), .failure("Usage: /rename <new title> | --auto"))
        XCTAssertEqual(parse(String(repeating: "é", count: 100)), .success(.title(String(repeating: "é", count: 100))))
        XCTAssertEqual(parse(String(repeating: "a", count: 101)), .failure("title too long (max 100 characters)"))
    }

    // MARK: /resume parsing

    func testSessionListRowsParseTheWrappedCamelCaseShape() {
        let page = HarnessSessionRow.parseList([
            "sessions": [
                ["sessionId": "s-1", "summary": "Refactor the parser", "firstPrompt": "Please refactor", "updatedAt": "2026-09-20T08:00:00.250Z",
                 "createdAt": "2026-09-19T08:00:00Z", "cwd": "/work/app", "source": "local", "numMessages": 12, "branch": "main",
                 "modelId": "grok-code", "lastTurnSummary": "Split the tokenizer out"],
                ["sessionId": "s-2", "summary": "", "firstPrompt": "Fix the flaky test\nIt fails on CI", "updatedAt": "2026-09-18T08:00:00Z",
                 "cwd": "/work/app", "source": "remote", "numMessages": 0, "lastActiveAt": "2026-09-21T09:30:00Z"],
                ["summary": "No id"],
            ],
            "nextCursor": "page-2",
        ])
        XCTAssertEqual(page.nextCursor, "page-2")
        XCTAssertEqual(page.rows.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(page.rows[0].title, "Refactor the parser")
        XCTAssertEqual(page.rows[0].messageCount, 12)
        XCTAssertEqual(page.rows[0].branch, "main")
        XCTAssertEqual(page.rows[0].modelID, "grok-code")
        XCTAssertEqual(page.rows[0].summary, "Split the tokenizer out")
        XCTAssertEqual(page.rows[0].updatedAt, HarnessSessionRow.date("2026-09-20T08:00:00.250Z"))
        XCTAssertNotNil(page.rows[0].updatedAt)
        XCTAssertEqual(page.rows[1].title, "Fix the flaky test", "An untitled session uses its first prompt line")
        XCTAssertTrue(page.rows[1].isRemoteOnly)
        XCTAssertEqual(page.rows[1].updatedAt, HarnessSessionRow.date("2026-09-21T09:30:00Z"), "Last activity wins over the update time")
        XCTAssertNil(HarnessSessionRow.parseList(["sessions": [], "nextCursor": ""]).nextCursor)
    }

    func testSessionSearchResultsParseSnippetsAndBootstrapping() {
        let parsed = HarnessSessionRow.parseSearch([
            "results": [
                ["sessionId": "s-2", "cwd": "/work/app", "summary": "Fix the flaky test", "updatedAt": "2026-09-20T08:00:00Z", "score": 2.5,
                 "matchedFields": ["content"], "snippet": "the <mark>flaky</mark>\ntest"],
                ["sessionId": "s-2", "cwd": "/work/app", "summary": "Duplicate", "updatedAt": "2026-09-20T08:00:00Z"],
                ["sessionId": "s-3", "cwd": "/other", "summary": "", "updatedAt": "bad date"],
            ],
            "bootstrapping": true,
        ])
        XCTAssertTrue(parsed.bootstrapping)
        XCTAssertEqual(parsed.rows.map(\.id), ["s-2", "s-3"])
        XCTAssertEqual(parsed.rows[0].snippet, "the flaky test")
        XCTAssertEqual(parsed.rows[1].title, "Grok task")
        XCTAssertNil(parsed.rows[1].updatedAt)
    }

    // MARK: Task board reducers

    func testWorkflowUpdatesFollowRevisionsAndClears() throws {
        var board = SessionTaskBoard()
        let first = workflowUpdate(revision: 2, status: "active", phase: "Research")
        XCTAssertTrue(board.apply(first))
        XCTAssertEqual(board.workflows.count, 1)
        XCTAssertEqual(board.workflows[0].name, "deep-research")
        XCTAssertEqual(board.workflows[0].phases.map(\.title), ["Research", "Write"])
        XCTAssertEqual(board.workflows[0].agents.map(\.label), ["researcher", "writer"])
        XCTAssertEqual(board.workflows[0].agentBudget, 8)
        XCTAssertEqual(board.workflows[0].activityLabel, "Research · 1 agent")
        XCTAssertFalse(board.apply(workflowUpdate(revision: 1, status: "complete")), "An older revision is ignored")
        XCTAssertFalse(board.apply(workflowUpdate(revision: 0, status: "complete")), "An unversioned update cannot replace a versioned one")
        XCTAssertTrue(board.apply(workflowUpdate(revision: 3, status: "user_paused", pause: "Paused by you")))
        XCTAssertEqual(board.workflows[0].status, "user_paused")
        XCTAssertEqual(board.workflows[0].activityLabel, "user paused")
        XCTAssertEqual(board.workflows[0].statusNote, "User paused: Paused by you")
        XCTAssertTrue(board.workflows[0].canResume(managed: true))
        XCTAssertFalse(board.workflows[0].canPause(managed: true))
        XCTAssertFalse(board.workflows[0].canResume(managed: false))
        XCTAssertTrue(board.apply(workflowUpdate(revision: 0, status: "cleared")))
        XCTAssertTrue(board.workflows.isEmpty)
        XCTAssertFalse(board.apply(workflowUpdate(revision: 0, status: "active")), "A cleared run does not come back from an unversioned replay")
    }

    func testScheduledTasksAreCreatedFiredAndDeleted() {
        var board = SessionTaskBoard()
        board.apply(["sessionUpdate": "scheduled_task_created", "task_id": "loop-1", "prompt": "check deploy status", "human_schedule": "every 30 minutes", "next_fire_at": "2026-09-23T10:30:00Z"])
        XCTAssertEqual(board.scheduled.map(\.id), ["loop-1"])
        XCTAssertEqual(board.scheduled[0].tag, "loop")
        XCTAssertEqual(board.scheduled[0].schedule, "every 30 minutes")
        board.apply(["sessionUpdate": "scheduled_task_fired", "task_id": "loop-1", "prompt": "check deploy status", "human_schedule": "every 30 minutes",
                     "next_fire_at": "2026-09-23T11:00:00Z", "subagent_id": "sub-9"])
        XCTAssertEqual(board.scheduled[0].firesCount, 1)
        XCTAssertEqual(board.scheduled[0].lastSubagentID, "sub-9")
        XCTAssertEqual(board.scheduled[0].nextFireAt, HarnessSessionRow.date("2026-09-23T11:00:00Z"))
        board.apply(["sessionUpdate": "scheduled_task_fired", "task_id": "loop-2", "prompt": "unseen", "human_schedule": "every hour"])
        XCTAssertEqual(board.scheduled.count, 2, "A fire for an unknown task still lists it")
        board.apply(["sessionUpdate": "scheduled_task_deleted", "task_id": "loop-1", "reason": "deleted"])
        XCTAssertEqual(board.scheduled.map(\.id), ["loop-2"])
        XCTAssertTrue(board.hasLiveWork)
    }

    func testBackgroundTaskSnapshotsAreLastWins() {
        var board = SessionTaskBoard()
        board.apply(["sessionUpdate": "background_tasks", "tasks": [
            ["task_id": "t-1", "command": "npm run dev", "cwd": "/w", "kind": "bash", "status": "running", "started_at": "2026-09-23T10:00:00Z", "description": "Start the dev server"],
            ["task_id": "t-2", "command": "tail -f log", "cwd": "/w", "kind": "monitor", "status": "completed", "started_at": "2026-09-23T09:00:00Z", "ended_at": "2026-09-23T09:05:00Z", "exit_code": 0],
        ]])
        XCTAssertEqual(board.background.map(\.title), ["Start the dev server", "tail -f log"])
        XCTAssertTrue(board.background[1].isMonitor)
        XCTAssertEqual(board.sortedBackground.first?.id, "t-1")
        board.stopping.insert("t-1")
        board.apply(["sessionUpdate": "background_tasks", "tasks": []])
        XCTAssertTrue(board.background.isEmpty)
        XCTAssertTrue(board.stopping.isEmpty)
        board.replaceBackground(withTaskList: [
            ["task_id": "bg-1", "command": "cargo build", "cwd": "/w", "start_time": ["secs_since_epoch": 1_790_000_000, "nanos_since_epoch": 0], "completed": false, "output": "Compiling…"],
            ["task_id": "bg-2", "command": "false", "cwd": "/w", "start_time": ["secs_since_epoch": 1_790_000_000, "nanos_since_epoch": 0], "completed": true, "exit_code": 1],
            ["task_id": "bg-3", "command": "true\n# second line", "cwd": "/w", "completed": true, "exit_code": 0],
        ])
        XCTAssertEqual(board.background.map(\.status), ["running", "failed", "completed"])
        XCTAssertEqual(board.background[0].startedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(board.background[2].title, "true")
        XCTAssertFalse(board.apply(["sessionUpdate": "agent_message_chunk"]))
    }

    func testDashboardGroupsFollowTheTerminalOrder() {
        var waiting = RunState(); waiting.questions = [QuestionRequest(requestID: 1, questions: [])]
        var working = RunState(); working.isRunning = true
        var failed = RunState(); failed.phase = "Needs attention"
        XCTAssertEqual(DashboardEntry.classify(run: waiting, isLive: true, isUnread: true, hasLiveWork: true), .needsInput)
        XCTAssertEqual(DashboardEntry.classify(run: working, isLive: true, isUnread: false, hasLiveWork: false), .working)
        XCTAssertEqual(DashboardEntry.classify(run: RunState(), isLive: true, isUnread: false, hasLiveWork: true), .working, "Live background work keeps a task working")
        XCTAssertEqual(DashboardEntry.classify(run: RunState(), isLive: false, isUnread: false, hasLiveWork: true), .inactive)
        XCTAssertEqual(DashboardEntry.classify(run: failed, isLive: false, isUnread: true, hasLiveWork: false), .failed)
        XCTAssertEqual(DashboardEntry.classify(run: nil, isLive: false, isUnread: true, hasLiveWork: false), .completed)
        XCTAssertEqual(DashboardEntry.classify(run: RunState(), isLive: true, isUnread: false, hasLiveWork: false), .idle)
        var board = SessionTaskBoard()
        board.apply(["sessionUpdate": "scheduled_task_created", "task_id": "l", "prompt": "p", "human_schedule": "every 5 minutes"])
        board.apply(["sessionUpdate": "background_tasks", "tasks": [["task_id": "m", "command": "tail", "cwd": "/", "kind": "monitor", "status": "running", "started_at": "2026-09-23T10:00:00Z"]]])
        XCTAssertEqual(DashboardEntry.liveWorkSummary(board), "1 monitor · 1 loop still running")
    }

    // MARK: /doctor

    func testDoctorRequestsAndFixNames() {
        XCTAssertEqual(try DoctorRequest.parse(""), .report)
        XCTAssertEqual(try DoctorRequest.parse("fix"), .listFixes)
        XCTAssertEqual(try DoctorRequest.parse("fix tmux-clipboard"), .fix(DoctorFixSpec.resolve("tmux-clipboard")!))
        XCTAssertEqual(try DoctorRequest.parse("fix terminal.ssh-wrap"), .fix(DoctorFixSpec.resolve("ssh-wrap")!))
        XCTAssertEqual(try DoctorRequest.parse("fix tmux-truecolor"), .fix(DoctorFixSpec.resolve("terminal.tmux-truecolor")!))
        XCTAssertThrowsError(try DoctorRequest.parse("fix nope")) { error in
            XCTAssertEqual(error.localizedDescription, "`nope` is not an available Doctor fix. Run `grok doctor fix` to list available fixes.\nUsage: /doctor [fix [ssh-wrap|tmux-clipboard|dcs-passthrough|tmux-extended-keys]]")
        }
        XCTAssertThrowsError(try DoctorRequest.parse("status")) { XCTAssertEqual($0.localizedDescription, DoctorRequest.usage) }
        XCTAssertThrowsError(try DoctorRequest.parse("fix a b")) { XCTAssertEqual($0.localizedDescription, DoctorRequest.usage) }
    }

    func testDoctorJSONDecodesTheCapturedReport() throws {
        let report = try DoctorReport.decode(Data(Self.doctorSample.utf8))
        XCTAssertEqual(report.schemaVersion, "1")
        XCTAssertEqual(report.facts?.terminal?.name, "unknown")
        XCTAssertEqual(report.facts?.terminal?.xtversion?.text, "Unavailable")
        XCTAssertEqual(report.facts?.clipboard?.nativeTool, "pbcopy")
        XCTAssertEqual(report.facts?.clipboard?.delivery, "confirmed")
        XCTAssertEqual(report.facts?.voice?.status, "missing")
        XCTAssertEqual(report.facts?.newline?.kind, "no_kitty_keyboard_protocol")
        XCTAssertNil(report.facts?.keyboard)
        XCTAssertEqual(report.allFindings.map(\.id), ["terminal.newline-fallback", "voice.no-input-device"])
        XCTAssertEqual(report.allFindings.map(\.area), ["terminal", "voice"])
        XCTAssertEqual(report.allFindings.map(\.isIssue), [false, true])
        XCTAssertEqual(report.issueCount, 1)
        XCTAssertEqual(report.recommendationCount, 1)
        XCTAssertEqual(report.probeNotes?.count, 4)
        XCTAssertEqual(report.factGroups.map(\.title), ["Terminal", "Clipboard", "Voice"])
        XCTAssertTrue(report.factGroups[0].rows.contains { $0.0 == "Shift+Enter" && $0.1 == "No kitty keyboard protocol" })
    }

    func testDoctorFindingsCarryRemediationsAndAutomaticFixes() throws {
        let report = try DoctorReport.decode(Data(#"""
        {"schemaVersion":"1","facts":{"terminal":{"name":"iterm2","xtversion":{"status":"available","value":"iTerm2 3.5"}},
         "multiplexer":{"kind":"tmux","byobu":null},"ssh":true,"color":{"level":{"status":"available","value":"truecolor"},"availableThemes":["Grok Night"],"totalThemes":5},
         "keyboard":{"cmd":"delivered","opt":"meta","os":"macos"},"newline":{"kind":"vte","version":"7600"},"clipboard":{"nativeRoute":false,"nativeTool":"","nativePreflight":"not_applicable",
         "tmuxRoute":true,"osc52Route":true,"osc52Capability":"supported","wrapSink":false,"displayServer":"none","containerNoDisplay":false,"dataControl":"not_applicable","delivery":"unverified","fix":"set -g set-clipboard on"}},
         "findings":[{"id":"clipboard.delivery-unverified","disposition":"issue","message":"Copy may not reach your computer","remediation":{"fix":"set -g set-clipboard on","configPath":"~/.tmux.conf"},
          "automaticRemediation":{"fixId":"terminal.tmux-clipboard","command":"grok doctor fix terminal.tmux-clipboard"},"note":null}],
         "probeNotes":[],"counts":{"issues":1,"recommendations":0,"probeNotes":0},"futureField":{"ignored":true}}
        """#.utf8))
        let finding = try XCTUnwrap(report.allFindings.first)
        XCTAssertEqual(finding.remediation?.configPath, "~/.tmux.conf")
        XCTAssertEqual(finding.automaticFix?.handle, "tmux-clipboard")
        XCTAssertEqual(report.facts?.terminal?.xtversion?.text, "iTerm2 3.5")
        XCTAssertTrue(report.factGroups[0].rows.contains { $0.0 == "Multiplexer" && $0.1 == "Tmux" })
        XCTAssertThrowsError(try DoctorReport.decode(Data("not json".utf8)))
    }

    func testDoctorTerminalScriptQuotesTheRuntimePath() throws {
        let fix = try XCTUnwrap(DoctorFixSpec.resolve("tmux-extended-keys"))
        let script = DoctorTerminalScript.contents(binary: "/Applications/Grok Desktop.app/Contents/Resources/it's/grok", fix: fix)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("'/Applications/Grok Desktop.app/Contents/Resources/it'\\''s/grok' doctor fix tmux-extended-keys\n"))
        XCTAssertTrue(script.contains("print -r -- 'Grok Doctor · Enable tmux extended keys'"))
        let url = try DoctorTerminalScript.write(binary: "/usr/local/bin/grok", fix: fix)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "command")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testDesktopChecksDescribePermissionsAndSignIn() {
        XCTAssertEqual(DoctorDesktopCheck.microphone(.authorized).status, .ok)
        XCTAssertEqual(DoctorDesktopCheck.microphone(.denied).status, .problem)
        XCTAssertEqual(DoctorDesktopCheck.microphone(.notDetermined).value, "Not requested yet")
        XCTAssertEqual(DoctorDesktopCheck.notifications(.denied).value, "Off")
        XCTAssertEqual(DoctorDesktopCheck.signIn([:]).value, "Not signed in")
        XCTAssertEqual(DoctorDesktopCheck.signIn([:]).detail, "Open Settings and sign in to OpenRouter or OpenAI Codex.")
        XCTAssertEqual(DoctorDesktopCheck.signIn([.codex: AccountStatus(state: .connected, identity: "dev@example.com", detail: "Signed in")]).value, "Signed in · OpenAI Codex")
        XCTAssertEqual(DoctorDesktopCheck.signIn([.openrouter: AccountStatus(state: .connected), .codex: AccountStatus(state: .connected)]).value,
                       "Signed in · OpenRouter, OpenAI Codex")
        XCTAssertEqual(DoctorDesktopCheck.signIn([.codex: AccountStatus(state: .expired)]).status, .warning)
    }

    // MARK: /trace

    func testTraceCommandUsesTheSessionDirectoryAndPrivateOutput() throws {
        XCTAssertEqual(TraceExport.arguments(source: "/home/.grok/sessions/%2Fw/abc", output: "/tmp/t.html"),
                       ["trace", "view", "/home/.grok/sessions/%2Fw/abc", "--format", "html", "-o", "/tmp/t.html"])
        let output = try TraceExport.outputFile(sessionID: "../../evil id")
        XCTAssertFalse(output.lastPathComponent.contains("/"))
        XCTAssertTrue(output.lastPathComponent.hasPrefix("______evil_id-"))
        XCTAssertEqual(output.pathExtension, "html")
        let permissions = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        XCTAssertEqual(TraceExport.errorSummary(status: 1, stderr: "\nError: bad input\n  caused by: parse\nTrace saved to /x\n"), "Error: bad input\ncaused by: parse")
        XCTAssertEqual(TraceExport.errorSummary(status: 3, stderr: ""), "grok trace view exited with status 3.")
    }

    func testTraceAndDoctorRunTheCLIAndReportFailures() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-grok")
        try #"""
        #!/bin/sh
        here="$(dirname "$0")"
        if [ "$1" = "trace" ]; then
          printf '%s\n' "$@" > "$here/trace-args.txt"
          if [ -f "$3/fail" ]; then echo "Error: could not parse events.jsonl" >&2; exit 1; fi
          echo "<html><body>trace</body></html>" > "$7"
          echo "Trace saved to $7" >&2
          exit 0
        fi
        if [ "$1" = "doctor" ]; then cat "$here/doctor.json"; exit 0; fi
        if [ "$1" = "--version" ]; then echo "grok 9.9.9 (test) [stable]"; exit 0; fi
        exit 2
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Self.doctorSample.write(to: root.appendingPathComponent("doctor.json"), atomically: true, encoding: .utf8)
        let projectPath = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("grok-home", isDirectory: true)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let sessionDirectory = home.appendingPathComponent("sessions/\(projectPath.path.addingPercentEncoding(withAllowedCharacters: allowed)!)/trace-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let store = AppStore(stateFile: root.appendingPathComponent("state.json"), binaryPath: binary.path)
        let project = Project(path: projectPath.path)
        let recorded = Conversation(projectID: project.id, title: "Recorded task", sessionID: "trace-session")
        let unrecorded = Conversation(projectID: project.id, title: "Fresh task", sessionID: "unrecorded")
        store.state = DesktopState(projects: [project], conversations: [recorded, unrecorded], selectedProjectID: project.id)
        let model = store.features.sessions
        model.grokHome = { home }
        model.accountReader = { [:] }

        await model.loadTrace()
        XCTAssertEqual(model.trace, .unavailable("No active session to trace"))
        store.state.selectedConversationID = unrecorded.id
        await model.loadTrace()
        XCTAssertEqual(model.trace, .unavailable("This session has not been recorded yet"))
        store.state.selectedConversationID = recorded.id
        await model.loadTrace()
        guard case .loaded(let file, let directory, let session) = model.trace else { return XCTFail("Expected a loaded trace, got \(model.trace)") }
        XCTAssertEqual(directory, sessionDirectory.path)
        XCTAssertEqual(session, "trace-session")
        XCTAssertEqual(model.traceTitle, "Recorded task")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "<html><body>trace</body></html>\n")
        let arguments = try String(contentsOf: root.appendingPathComponent("trace-args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, TraceExport.arguments(source: sessionDirectory.path, output: file.path))
        try "".write(to: sessionDirectory.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
        await model.loadTrace()
        XCTAssertEqual(model.trace, .failed(directory: sessionDirectory.path, error: "Error: could not parse events.jsonl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "A failed reload removes the previous export")

        store.state.selectedConversationID = unrecorded.id
        model.openTrace()
        for _ in 0..<200 where store.banner == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.banner, "This session has not been recorded yet")
        XCTAssertNil(store.windowRequest)
        store.state.selectedConversationID = recorded.id
        model.openTrace()
        for _ in 0..<200 where store.windowRequest == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.windowRequest, .trace)

        await model.runDoctor()
        XCTAssertNil(model.doctorError)
        XCTAssertEqual(model.doctorReport?.allFindings.count, 2)
        XCTAssertEqual(model.desktopChecks.first?.value, "Version 9.9.9 (test) [stable]")
        XCTAssertEqual(model.desktopChecks.map(\.id), ["runtime", "sign-in", "microphone", "notifications"])

        model.openDoctor("fix nope")
        XCTAssertNil(store.sheet)
        XCTAssertTrue(store.banner?.hasPrefix("`nope` is not an available Doctor fix.") == true)
        model.openDoctor("fix tmux-clipboard")
        XCTAssertEqual(store.sheet, .doctor(arguments: "fix tmux-clipboard"))
    }

    // MARK: Helpers

    private func workflowUpdate(revision: Int, status: String, phase: String? = nil, pause: String? = nil) -> [String: Any] {
        var update: [String: Any] = [
            "sessionUpdate": "workflow_updated", "run_id": "wf-1", "revision": revision, "name": "deep-research",
            "objective": "Compare rate limiters", "status": status, "foreground": false,
            "phases": [["title": "Research", "state": "active"], ["title": "Write", "state": "pending"]],
            "agent_budget": 8, "agents_used": 2, "agents_reserved": 1, "elapsed_ms": 65_000,
            "agents": [["agent_id": "a1", "label": "researcher", "phase": "Research", "state": "running", "tokens_used": 1200, "duration_ms": 30_000],
                       ["agent_id": "a2", "label": "writer", "phase": "Write", "state": "pending"]],
        ]
        if let phase { update["current_phase"] = phase }
        if let pause { update["pause_message"] = pause }
        return update
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-session-unit-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Captured from `grok doctor --json` (grok 1.0.41) run outside a terminal on macOS.
    static let doctorSample = #"""
    {
      "schemaVersion": "1",
      "facts": {
        "terminal": { "name": "unknown", "xtversion": { "status": "unavailable", "value": null } },
        "multiplexer": { "kind": "undetected", "byobu": null },
        "ssh": false,
        "color": { "level": { "status": "unavailable", "value": null }, "availableThemes": [], "totalThemes": 5 },
        "keyboard": null,
        "newline": { "kind": "no_kitty_keyboard_protocol" },
        "clipboard": {
          "nativeRoute": true, "nativeTool": "pbcopy", "nativePreflight": "local_available", "tmuxRoute": false,
          "osc52Route": false, "osc52Capability": "unknown", "wrapSink": false, "displayServer": "quartz",
          "containerNoDisplay": false, "dataControl": "not_applicable", "delivery": "confirmed", "fix": null
        },
        "voice": { "status": "missing", "error": "mic device lookup did not start within 5s" }
      },
      "findings": [
        {
          "id": "terminal.newline-fallback", "disposition": "recommendation",
          "message": "Shift+Enter can't insert a newline because the keyboard protocol is unavailable",
          "remediation": null, "automaticRemediation": null,
          "note": "Use Alt+Enter to insert a newline. If your terminal supports the Kitty keyboard protocol, enable it and restart Grok."
        },
        {
          "id": "voice.no-input-device", "disposition": "issue",
          "message": "Voice dictation is unavailable: mic device lookup did not start within 5s",
          "remediation": null, "automaticRemediation": null,
          "note": "Connect or select a microphone in your system sound settings. On Linux, install a supported audio recorder if none was found on PATH. Then run `/doctor` or `grok doctor` again. Doctor can't detect denied macOS microphone access when the system returns silence; follow the message shown when dictation fails."
        }
      ],
      "probeNotes": [
        { "probe": "runtime.fullscreen-active", "status": "unavailable", "message": null },
        { "probe": "runtime.kitty-flags-pushed", "status": "unavailable", "message": null },
        { "probe": "runtime.xtversion", "status": "unavailable", "message": null },
        { "probe": "terminal.color", "status": "unavailable", "message": null }
      ],
      "counts": { "issues": 1, "recommendations": 1, "probeNotes": 4 }
    }
    """#
}
