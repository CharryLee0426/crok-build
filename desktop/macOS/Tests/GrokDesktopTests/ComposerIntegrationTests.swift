import XCTest
@testable import GrokDesktop

/// Queue, compaction, permission, and model commands against the offline ACP fixture.
@MainActor
final class ComposerIntegrationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let store: AppStore
        let config: URL
        var composer: ComposerFeatureModel { store.features.composer }

        init() throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-composer-acp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/mock-grok.py")
            let original = try String(contentsOf: fixtureURL, encoding: .utf8)
            let source = original.components(separatedBy: "if __name__ == \"__main__\":")[0]
                .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
            // Logs every client message and every prompt result in arrival order, holds prompts that
            // mention `fixture:slow` so a follow-up can be queued, and answers compaction.
            let composerHarness = #"""
import time
LOG = os.path.join(os.path.dirname(__file__), "requests.jsonl")
def log(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps(entry) + "\n")
class ComposerHarness(MockHarness):
    def handle(self, message):
        log(message)
        if message.get("method") == "_x.ai/compact_conversation":
            params = message.get("params", {})
            def finish():
                time.sleep(0.3)
                if params.get("userContext") == "fail":
                    self.error(message["id"], -32000, "context window is empty")
                else:
                    self.result(message["id"], {})
            threading.Thread(target=finish, daemon=True).start()
            return
        super().handle(message)
    def prompt(self, request_id, params, stop):
        text = "".join(block.get("text", "") for block in params.get("prompt", []))
        if "fixture:slow" in text:
            stop.wait(1.0)
        super().prompt(request_id, params, stop)
    def result(self, request_id, value):
        if isinstance(value, dict) and "stopReason" in value:
            log({"event": "prompt_result", "id": request_id, "stopReason": value["stopReason"]})
        super().result(request_id, value)
fixture = ComposerHarness()
fixture.run()
"""#
            let executable = directory.appendingPathComponent("fixture-grok")
            try (source + composerHarness).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
            let project = Project(path: directory.path)
            store.state = DesktopState(projects: [project], selectedProjectID: project.id)
            config = directory.appendingPathComponent("config.toml")
            store.features.composer.configURL = config
            store.features.composer.reloadPreferences()
        }

        var log: [[String: Any]] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }

        func params(for method: String) -> [[String: Any]] {
            log.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
        }

        var prompts: [String] {
            params(for: "session/prompt").map { value in
                (value["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            }
        }

        var conversationID: UUID? { store.state.selectedConversationID }

        func cleanup() {
            store.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func eventually(timeout: TimeInterval = 8, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    private func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func testPromptSentDuringATurnIsQueuedAndSentAfterTheTurnFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:slow first"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)

        store.draft = "second prompt"
        store.send()
        XCTAssertEqual(store.draft, "", "Return while running queues the prompt and clears the composer")
        XCTAssertEqual(fixture.composer.queue.items(id).map(\.text), ["second prompt"])
        XCTAssertEqual(fixture.prompts, ["fixture:slow first"])

        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts, ["fixture:slow first", "second prompt"])
        XCTAssertTrue(fixture.composer.queue.items(id).isEmpty)
        let log = fixture.log
        let firstResult = try XCTUnwrap(log.firstIndex { $0["event"] as? String == "prompt_result" })
        let secondPrompt = try XCTUnwrap(log.lastIndex { $0["method"] as? String == "session/prompt" })
        XCTAssertLessThan(firstResult, secondPrompt, "the queued prompt is sent only after the first turn finished")
        XCTAssertEqual(store.conversation?.messages.filter { $0.kind == .user }.map(\.text), ["fixture:slow first", "second prompt"])
        XCTAssertFalse(store.conversation?.messages.contains { $0.kind == .system } ?? true)
        XCTAssertEqual(store.run.phase, "Ready")
    }

    func testCommandsTypedMidTurnRunQueueOrWaitWithoutLosingTheDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:slow first"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)

        // Needs an idle task: the draft stays and the user is told why.
        for command in ["/plan refactor the parser", "/imagine a red fox", "/flush"] {
            store.draft = command
            store.send()
            XCTAssertEqual(store.draft, command)
            XCTAssertEqual(store.banner, "Wait for the current turn to finish or stop it before running /\(command.dropFirst().split(separator: " ")[0]).")
        }
        XCTAssertTrue(fixture.composer.queue.items(id).isEmpty)

        // Native panels open at once.
        store.draft = "/usage"
        store.send()
        XCTAssertEqual(store.sheet, .usage(.usage))
        XCTAssertEqual(store.draft, "")
        store.sheet = nil

        // Harness commands wait in the queue, whether typed or picked from a menu.
        store.draft = "/fixture-echo"
        store.send()
        store.executeCommand(name: "fixture-echo")
        XCTAssertEqual(fixture.composer.queue.items(id).map(\.text), ["/fixture-echo", "/fixture-echo"])
        try await eventually(timeout: 12) { fixture.prompts.count == 3 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts, ["fixture:slow first", "/fixture-echo", "/fixture-echo"])
    }

    func testPromptQueuedWhileHistoryLoadsIsSentWhenLoadingEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "start"
        store.send()
        try await eventually { fixture.prompts.count == 1 && !store.run.isRunning }
        let id = try XCTUnwrap(fixture.conversationID)

        let loading = store.beginOperation(id, phase: "Loading history")
        store.draft = "follow up"
        store.send()
        XCTAssertEqual(fixture.composer.queue.items(id).map(\.text), ["follow up"])
        store.runs[id]?.phase = "Ready"
        store.finishOperation(id, operationID: loading)
        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts.last, "follow up")
        XCTAssertTrue(fixture.composer.queue.items(id).isEmpty)
    }

    func testQueuePausesVisiblyWhenTheOperationBeforeItFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "start"
        store.send()
        try await eventually { fixture.prompts.count == 1 && !store.run.isRunning }
        let id = try XCTUnwrap(fixture.conversationID)

        let failing = store.beginOperation(id, phase: "Working")
        store.draft = "waits for the user"
        store.send()
        store.runs[id]?.phase = "Needs attention"
        store.finishOperation(id, operationID: failing)
        try await pause(0.3)
        XCTAssertTrue(fixture.composer.queue.isPaused(id), "the panel offers Send next instead of claiming to send")
        XCTAssertEqual(fixture.prompts.count, 1)
        fixture.composer.resumeQueue(id)
        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts.last, "waits for the user")
    }

    func testDashboardReplyKeepsTheTaskDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "start"
        store.send()
        try await eventually { fixture.prompts.count == 1 && !store.run.isRunning }
        let id = try XCTUnwrap(fixture.conversationID)
        store.draft = "half-written draft"
        store.features.sessions.reply(to: id, text: "reply from the dashboard")
        XCTAssertEqual(store.draft, "half-written draft")
        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts.last, "reply from the dashboard")
        XCTAssertEqual(store.draft, "half-written draft")
    }

    func testStoppedTurnKeepsTheQueueUntilTheUserSendsNext() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:wait"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)
        store.draft = "after the stop"
        store.send()
        store.cancel()
        try await eventually { !store.run.isRunning }
        try await pause(0.4)
        XCTAssertEqual(fixture.prompts, ["fixture:wait"], "a stopped turn does not drain the queue")
        XCTAssertEqual(fixture.composer.queue.items(id).map(\.text), ["after the stop"])
        XCTAssertTrue(fixture.composer.queue.isPaused(id))

        fixture.composer.resumeQueue(id)
        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.prompts.last, "after the stop")
        XCTAssertTrue(fixture.composer.queue.items(id).isEmpty)
    }

    func testSendNowStopsTheTurnAndSendsThatEntryFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:wait"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)
        for text in ["first queued", "second queued"] { store.draft = text; store.send() }
        let second = try XCTUnwrap(fixture.composer.queue.items(id).last)

        fixture.composer.sendQueuedNow(second.id, in: id)
        try await eventually { fixture.prompts.count == 3 && !store.run.isRunning && fixture.composer.queue.items(id).isEmpty }
        XCTAssertEqual(fixture.prompts, ["fixture:wait", "second queued", "first queued"])
        XCTAssertEqual(fixture.params(for: "session/cancel").count, 1)
    }

    func testQueuedPromptOfABackgroundTaskStillSends() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:slow background"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)
        store.draft = "continue in the background"
        store.send()
        store.newTask()
        store.draft = "An unsent draft elsewhere"
        try await eventually { fixture.prompts.count == 2 && store.runs[id]?.isRunning == false }
        XCTAssertEqual(fixture.prompts.last, "continue in the background")
        XCTAssertEqual(store.draft, "An unsent draft elsewhere", "dispatching a queued prompt never touches the composer")
        XCTAssertTrue(store.unreadConversationIDs.contains(id))
    }

    func testCompactSendsTheExtensionRequestAndReportsTheOutcome() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Inspect the fixture"
        store.send()
        try await eventually { !store.run.isRunning && fixture.prompts.count == 1 }
        let id = try XCTUnwrap(fixture.conversationID)
        let session = try XCTUnwrap(store.conversation?.sessionID)

        store.draft = "/compact keep the API notes"
        store.send()
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(fixture.composer.compactions[id]?.message, "Compacting conversation…")
        XCTAssertTrue(store.run.isRunning, "compaction holds the task like a turn")
        try await eventually { if case .completed = fixture.composer.compactions[id] { return true }; return false }
        XCTAssertTrue(fixture.composer.compactions[id]?.message.hasPrefix("Compaction completed in ") == true)
        XCTAssertEqual(fixture.params(for: "_x.ai/compact_conversation").last as NSDictionary?,
                       ["sessionId": session, "userContext": "keep the API notes"] as NSDictionary)
        XCTAssertEqual(fixture.prompts, ["Inspect the fixture"], "compaction is not sent as a prompt")

        try await eventually { !store.run.isRunning }
        fixture.composer.compact("")
        try await eventually { fixture.params(for: "_x.ai/compact_conversation").count == 2 }
        XCTAssertEqual(fixture.params(for: "_x.ai/compact_conversation").last as NSDictionary?, ["sessionId": session] as NSDictionary)
        try await eventually { !store.run.isRunning }
        fixture.composer.compact("fail")
        try await eventually { fixture.composer.compactions[id] == .failed("context window is empty") }
        XCTAssertEqual(fixture.composer.compactions[id]?.message, "Compaction failed - context window is empty")
        fixture.composer.dismissCompaction(id)
        XCTAssertNil(fixture.composer.compactions[id])
    }

    func testCompactDuringATurnRunsAfterIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:slow"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(fixture.conversationID)
        store.draft = "/compact focus on tests"
        store.send()
        XCTAssertEqual(fixture.composer.queue.items(id).map(\.text), ["/compact focus on tests"])
        store.draft = "then continue"
        store.send()
        try await eventually { fixture.prompts.count == 2 && !store.run.isRunning }
        let methods = fixture.log.compactMap { $0["method"] as? String }.filter { ["session/prompt", "_x.ai/compact_conversation"].contains($0) }
        XCTAssertEqual(methods, ["session/prompt", "_x.ai/compact_conversation", "session/prompt"])
        XCTAssertEqual(fixture.params(for: "_x.ai/compact_conversation").first?["userContext"] as? String, "focus on tests")
        XCTAssertEqual(fixture.prompts.last, "then continue")
    }

    func testPermissionModeNotifiesRunningHarnessesAndSeedsNewSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Inspect the fixture"
        store.send()
        try await eventually { !store.run.isRunning && fixture.prompts.count == 1 }
        XCTAssertNil(fixture.params(for: "session/new").first?["_meta"], "no mode is imposed before the user picks one")

        store.draft = "/yolo"
        store.send()
        try await eventually { fixture.params(for: "_x.ai/yolo_mode_changed").count == 1 }
        XCTAssertEqual(fixture.params(for: "_x.ai/yolo_mode_changed").first as NSDictionary?,
                       ["yolo_mode": true, "auto_mode": false, "permission_mode": "always-approve"] as NSDictionary)
        XCTAssertEqual(store.banner, "⚠ Always-approve ON: all tool actions auto-run")
        XCTAssertEqual(GrokConfig(url: fixture.config).string("permission_mode", in: "ui"), "always-approve")

        store.draft = "/auto"
        store.send()
        try await eventually { fixture.params(for: "_x.ai/yolo_mode_changed").count == 2 }
        XCTAssertEqual(fixture.params(for: "_x.ai/yolo_mode_changed").last as NSDictionary?,
                       ["yolo_mode": false, "auto_mode": true, "permission_mode": "auto"] as NSDictionary)
        XCTAssertEqual(store.banner, "✓ Permission mode: Auto (classifier)")

        store.newTask()
        store.draft = "A new task"
        store.send()
        try await eventually { fixture.params(for: "session/new").count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.params(for: "session/new").last?["_meta"] as? NSDictionary, ["yoloMode": false, "autoMode": true] as NSDictionary)
    }

    func testAlwaysApproveAnswersWaitingPermissionRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:permission"
        store.send()
        try await eventually { store.run.approvals.count == 1 }
        fixture.composer.setAlwaysApprove("on")
        try await eventually { !store.run.isRunning }
        XCTAssertTrue(store.conversation?.messages.contains { $0.detail?.contains("\"optionId\": \"allow\"") == true } == true,
                      "the waiting request was answered with allow once")
    }

    func testModelAndEffortCommandsSwitchPersistAndReportErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Inspect the fixture"
        store.send()
        try await eventually { !store.run.isRunning && fixture.prompts.count == 1 }

        store.draft = "/model grok fast (fixture) high"
        store.send()
        try await eventually { store.banner == "Switched to Grok Fast (fixture) (high effort)" }
        XCTAssertEqual(store.run.modelID, "fixture-grok-fast")
        XCTAssertEqual(store.run.reasoningID, "high")
        try await eventually { GrokConfig(url: fixture.config).string("default_reasoning_effort", in: "models") == "high" }
        XCTAssertEqual(GrokConfig(url: fixture.config).string("default", in: "models"), "fixture-grok-fast")
        let options = fixture.params(for: "session/set_config_option").map { "\($0["configId"] ?? "")=\($0["value"] ?? "")" }
        XCTAssertEqual(options, ["model=fixture-grok-fast", "reasoning_effort=high"], "model first, then effort")

        store.draft = "/effort Low"
        store.send()
        try await eventually { store.banner == "Switched to Grok Fast (fixture) (low effort)" }
        store.draft = "/effort ultra"
        store.send()
        XCTAssertEqual(store.banner, "unknown effort level 'ultra'; use one of: low, medium, high")
        store.draft = "/m nope"
        store.send()
        XCTAssertEqual(store.banner, "Unknown model: nope")
        store.draft = "/effort"
        store.send()
        XCTAssertEqual(store.featurePanel, .reasoning, "bare /effort opens the picker")
        XCTAssertEqual(fixture.prompts.count, 1, "model commands never reach the model")
    }

    func testHarnessQueueNotificationsShowAndRemoveEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Inspect the fixture"
        store.send()
        try await eventually { !store.run.isRunning && fixture.prompts.count == 1 }
        let id = try XCTUnwrap(fixture.conversationID)
        let session = try XCTUnwrap(store.conversation?.sessionID)
        XCTAssertTrue(store.features.handle(method: "x.ai/queue/changed", params: [
            "sessionId": session, "entries": [["id": "q1", "version": 2, "owner": "grok-shell", "kind": "prompt", "text": "from the terminal", "position": 0]],
        ], update: nil, conversationID: id))
        let entry = try XCTUnwrap(fixture.composer.harnessQueues[id]?.entries.first)
        fixture.composer.showQueue()
        XCTAssertNil(store.banner)
        fixture.composer.removeHarnessQueued(entry, conversationID: id)
        try await eventually { !fixture.params(for: "_x.ai/queue/remove").isEmpty }
        XCTAssertEqual(fixture.params(for: "_x.ai/queue/remove").first as NSDictionary?, ["sessionId": session, "id": "q1", "expectedVersion": 2] as NSDictionary)
        _ = store.features.handle(method: "x.ai/queue/changed", params: ["sessionId": session, "entries": []], update: nil, conversationID: id)
        XCTAssertNil(fixture.composer.harnessQueues[id])
    }
}
