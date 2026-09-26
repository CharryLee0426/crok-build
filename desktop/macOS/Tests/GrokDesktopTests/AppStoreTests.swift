import Combine
import XCTest
@testable import GrokDesktop

@MainActor
final class AppStoreTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let defaultsName = "GrokDesktopTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: AppStore
        let conversationID: UUID

        init(firstLoad: String, existingMessages: [Message] = [], advertiseAuth: Bool = true, configDelay: Double = 0, rejectConfig: Bool = false,
             prompt: String = #"chunk("agent_message_chunk", "New answer")"#) throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-store-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: defaultsName)!
            let executable = directory.appendingPathComponent("fixture-grok")
            let source = #"""
#!/usr/bin/python3
import json, pathlib, sys, time
root = pathlib.Path(__file__).parent
counter = root / "attempt"
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
def emit(value):
    print(json.dumps(value), flush=True)
def reply(request, value):
    emit({"jsonrpc": "2.0", "id": request["id"], "result": value})
model_id = "fixture-build"
effort_id = "medium"
def models():
    return {"currentModelId": model_id, "availableModels": [
        {"modelId": name, "name": name, "_meta": {"supportsReasoningEffort": True, "reasoningEffort": effort_id, "reasoningEfforts": ["low", "medium", "high"]}}
        for name in ["fixture-build", "fixture-fast"]]}
def config():
    return {"configOptions": [
        {"id": "model", "type": "select", "currentValue": model_id, "options": [{"value": name, "name": name} for name in ["fixture-build", "fixture-fast"]]},
        {"id": "reasoning_effort", "type": "select", "currentValue": effort_id, "options": [{"value": name, "name": name.title()} for name in ["low", "medium", "high"]]}]}
def chunk(kind, text):
    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "existing-session", "update": {"sessionUpdate": kind, "content": {"type": "text", "text": text}}}})
for line in sys.stdin:
    request = json.loads(line)
    with (root / "requests.jsonl").open("a") as log:
        log.write(json.dumps(request) + "\n")
    method = request.get("method")
    if method == "initialize":
        reply(request, {"authMethods": [{"id": "xai.api_key"}] if ADVERTISE_AUTH else [], "_meta": {"modelState": models()}})
    elif method == "authenticate":
        reply(request, {})
    elif method == "_x.ai/models/list":
        reply(request, {"result": models()})
    elif method == "_x.ai/commands/list":
        reply(request, {"commands": []})
    elif method == "session/list":
        reply(request, {"sessions": [{"sessionId": "existing-session", "title": "Imported task"}]})
    elif method == "session/new":
        reply(request, {"sessionId": "new-session", "models": models(), **config()})
    elif method == "session/set_config_option":
        time.sleep(CONFIG_DELAY)
        if REJECT_CONFIG:
            emit({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32602, "message": "Unsupported setting"}})
        else:
            value = request["params"]["value"]
            assert isinstance(value, str), "ACP config value must be a string"
            if request["params"]["configId"] == "model":
                model_id = value
            else:
                effort_id = value
            reply(request, config())
    elif method == "session/load":
        if attempt == 1:
            FIRST_LOAD
        chunk("user_message_chunk", "Original question")
        chunk("agent_message_chunk", "Complete answer")
        reply(request, {"models": models(), **config()})
    elif method == "session/prompt":
        PROMPT
        reply(request, {"stopReason": "end_turn"})
    elif method is not None and "id" in request:
        emit({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unsupported fixture method"}})
"""#
                .replacingOccurrences(of: "CONFIG_DELAY", with: String(configDelay))
                .replacingOccurrences(of: "REJECT_CONFIG", with: rejectConfig ? "True" : "False")
                .replacingOccurrences(of: "ADVERTISE_AUTH", with: advertiseAuth ? "True" : "False")
                .replacingOccurrences(of: "FIRST_LOAD", with: firstLoad.replacingOccurrences(of: "\n", with: "\n            "))
                .replacingOccurrences(of: "PROMPT", with: prompt.replacingOccurrences(of: "\n", with: "\n        "))
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: executable.path)
            let project = Project(path: directory.path)
            let conversation = Conversation(projectID: project.id, sessionID: "existing-session", messages: existingMessages)
            conversationID = conversation.id
            store.state = DesktopState(projects: [project], conversations: [conversation], selectedProjectID: project.id, selectedConversationID: conversation.id)
        }

        var requests: [[String: Any]] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }

        func cleanup() {
            store.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    func testCancelDuringReconnectCannotPromptOrCleanUpNextSend() async throws {
        let fixture = try Fixture(firstLoad: "time.sleep(20)", existingMessages: [Message(kind: .assistant, text: "Prior turn")])
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Cancelled prompt"
        store.send()
        try await eventually { fixture.requests.contains { $0["method"] as? String == "session/load" } }
        store.cancel()
        XCTAssertFalse(store.run.isRunning)
        XCTAssertEqual(store.run.phase, "Stopped")
        // Restart immediately, before the cancelled continuation has had a chance to unwind.
        store.draft = "Next prompt"
        store.send()
        try await eventually { !store.run.isRunning }
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertFalse(store.conversation!.messages.contains { $0.kind == .system })
        let prompts = fixture.requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 1)
        let prompt = ((prompts.first?["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(prompt, "Next prompt")
        for authentication in fixture.requests.filter({ $0["method"] as? String == "authenticate" }) {
            XCTAssertEqual(((authentication["params"] as? [String: Any])?["_meta"] as? [String: Any])?["headless"] as? Bool, true)
        }
    }

    func testFailedImportDiscardsPartialReplayAndCanReloadWithoutDuplicates() async throws {
        let fixture = try Fixture(firstLoad: #"""
chunk("user_message_chunk", "Partial question")
chunk("agent_message_chunk", "Partial answer")
emit({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32603, "message": "Fixture load failed"}})
continue
"""#)
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.loadImportedConversation()
        XCTAssertTrue(store.conversation!.messages.isEmpty)
        XCTAssertEqual(store.run.phase, "Needs attention")
        XCTAssertFalse(store.run.isRunning)
        XCTAssertEqual(store.banner, "Fixture load failed")
        await store.loadImportedConversation()
        XCTAssertEqual(store.conversation!.messages.map(\.text), ["Original question", "Complete answer"])
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertNil(store.banner)
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "session/load" }.count, 2)
    }

    func testCancellingImportClearsPendingApprovalAndAllowsRetry() async throws {
        let fixture = try Fixture(firstLoad: #"""
chunk("agent_message_chunk", "Partial answer")
emit({"jsonrpc": "2.0", "id": "trust-1", "method": "x.ai/folder_trust/request", "params": {"cwd": str(root), "configKinds": ["agents"]}})
time.sleep(20)
"""#)
        defer { fixture.cleanup() }
        let store = fixture.store
        let importing = Task { await store.loadImportedConversation() }
        try await eventually { !store.run.approvals.isEmpty }
        store.cancel()
        await importing.value
        XCTAssertEqual(store.run.phase, "Stopped")
        XCTAssertFalse(store.run.isRunning)
        XCTAssertTrue(store.run.approvals.isEmpty)
        XCTAssertTrue(store.run.questions.isEmpty)
        XCTAssertTrue(store.conversation!.messages.isEmpty)
        XCTAssertNil(store.banner)
        await store.loadImportedConversation()
        XCTAssertEqual(store.conversation!.messages.map(\.text), ["Original question", "Complete answer"])
    }

    func testUnavailableAuthenticationExplainsHowToRecover() async throws {
        let fixture = try Fixture(firstLoad: "pass", advertiseAuth: false)
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.loadImportedConversation()
        XCTAssertEqual(store.run.phase, "Needs attention")
        XCTAssertTrue(store.banner?.contains("Open Settings and sign in") == true)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "session/load" })
    }

    func testTaskDraftsSurviveRepeatedClicksAndTaskSwitching() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        let first = store.conversation!
        let second = Conversation(projectID: first.projectID, title: "Second task")
        store.state.conversations.append(second)
        store.draft = "First task draft"
        store.selectConversation(first)
        XCTAssertEqual(store.draft, "First task draft")
        store.selectConversation(second)
        XCTAssertEqual(store.draft, "")
        store.draft = "Second task draft"
        store.selectConversation(first)
        XCTAssertEqual(store.draft, "First task draft")
        store.selectConversation(second)
        XCTAssertEqual(store.draft, "Second task draft")
    }

    func testNewTaskDraftsArePerProjectAndSendingClearsOriginalDraft() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        let firstProject = store.project!
        let secondProject = Project(path: fixture.directory.appendingPathComponent("second-project").path)
        store.state.projects.append(secondProject)
        store.newTask()
        store.draft = "First project idea"
        store.newTask()
        XCTAssertEqual(store.draft, "First project idea")
        store.selectProject(secondProject.id)
        XCTAssertEqual(store.draft, "")
        store.draft = "Second project idea"
        store.selectProject(firstProject.id)
        XCTAssertEqual(store.draft, "First project idea")
        store.send()
        store.cancel()
        XCTAssertEqual(store.draft, "")
        store.newTask()
        XCTAssertEqual(store.draft, "", "Sending must clear the source new-task draft")
        store.selectProject(secondProject.id)
        XCTAssertEqual(store.draft, "Second project idea")
    }

    func testCrossProjectTaskSelectionImmediatelyClearsOldInspector() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        let secondProject = Project(path: fixture.directory.appendingPathComponent("second-project").path)
        let second = Conversation(projectID: secondProject.id)
        store.state.projects.append(secondProject)
        store.state.conversations.append(second)
        store.workspace = GitWorkspaceSnapshot(branch: "previous-branch", changes: [])
        store.selectedFile = "previous-file.swift"
        store.diffText = "Previous project changes"
        store.selectConversation(second)
        XCTAssertEqual(store.workspace.branch, "")
        XCTAssertNil(store.selectedFile)
        XCTAssertEqual(store.diffText, "")
    }

    func testReconnectRestoresHarnessTranscriptAndPreservesUnsentPrompt() async throws {
        let fixture = try Fixture(firstLoad: "pass", existingMessages: [Message(kind: .assistant, text: "Interrupted local output")])
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Follow up"
        store.send()
        try await eventually { !store.run.isRunning }
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertEqual(store.conversation!.messages.map(\.text), ["Original question", "Complete answer", "Follow up", "New answer"])
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "session/prompt" }.count, 1)
    }

    func testStreamedChunksAreBatchedAndCompleteWhenTheTurnEnds() async throws {
        let fixture = try Fixture(firstLoad: "pass", prompt: """
        for index in range(400):
            chunk("agent_thought_chunk", f"step {index}; ")
        for index in range(400):
            chunk("agent_message_chunk", f"word{index} ")
        """)
        defer { fixture.cleanup() }
        let store = fixture.store
        var publishes = 0
        let observer = store.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }
        store.draft = "Think it through"
        store.send()
        try await eventually { !store.run.isRunning }
        // Every chunk is present as soon as the turn is reported finished.
        let messages = store.conversation!.messages
        XCTAssertEqual(messages.map(\.kind), [.user, .assistant, .user, .thought, .assistant])
        XCTAssertEqual(messages[3].text, (0..<400).map { "step \($0); " }.joined())
        XCTAssertEqual(messages[4].text, (0..<400).map { "word\($0) " }.joined())
        // 800 chunks must not mean 800 re-renders of every view observing the store.
        XCTAssertLessThan(publishes, 100)
    }

    func testSaveWritesInBackgroundAndFlushWritesImmediately() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        let file = fixture.directory.appendingPathComponent("state.json")
        store.state.conversations[0].title = "Saved in the background"
        store.save()
        try await eventually { (try? String(contentsOf: file, encoding: .utf8))?.contains("Saved in the background") == true }
        store.state.conversations[0].title = "Flushed on demand"
        store.save()
        store.flush()
        let saved = try JSONDecoder().decode(DesktopState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.conversations.map(\.title), ["Flushed on demand"])
    }

    func testPreparingReopenedTaskPopulatesModelsWithoutSendingPrompt() async throws {
        let fixture = try Fixture(firstLoad: "pass", existingMessages: [Message(kind: .assistant, text: "Saved answer")])
        defer { fixture.cleanup() }
        await fixture.store.prepareSessionOptions()
        await fixture.store.loadImportedConversation()
        XCTAssertEqual(fixture.store.run.modelID, "fixture-build")
        XCTAssertEqual(fixture.store.run.reasoningOptions.map(\.id), ["low", "medium", "high"])
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "session/load" }.count, 1)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "session/prompt" })
    }

    func testNewTaskSelectionsAreAppliedBeforePromptAndSurviveRestart() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        store.newTask()
        await store.prepareSessionOptions()
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "session/new" })
        store.setModel(try XCTUnwrap(store.run.models.first { $0.id == "fixture-fast" }))
        store.setReasoning(try XCTUnwrap(store.run.reasoningOptions.first { $0.id == "high" }))
        store.draft = "Use my settings"
        store.send()
        try await eventually { !store.run.isRunning }
        XCTAssertEqual(store.run.modelID, "fixture-fast")
        XCTAssertEqual(store.run.reasoningID, "high")
        let relevant = fixture.requests.filter { ["session/set_config_option", "session/prompt"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(relevant.map { $0["method"] as? String }, ["session/set_config_option", "session/set_config_option", "session/prompt"])
        let firstParams = relevant.first?["params"] as? [String: Any]
        XCTAssertEqual(firstParams?["configId"] as? String, "model")
        XCTAssertEqual(firstParams?["value"] as? String, "fixture-fast")
        store.shutdown()
        let reopened = AppStore(stateFile: fixture.directory.appendingPathComponent("state.json"), defaults: fixture.defaults, binaryPath: store.binaryPath)
        defer { reopened.shutdown() }
        await reopened.prepareSessionOptions()
        XCTAssertEqual(reopened.run.modelID, "fixture-fast")
        XCTAssertEqual(reopened.run.reasoningID, "high")
        reopened.newTask()
        await reopened.prepareSessionOptions()
        XCTAssertEqual(reopened.run.modelID, "fixture-fast")
        XCTAssertEqual(reopened.run.reasoningID, "high")
    }

    func testConfigurationChangeBlocksOverlappingChoiceAndSend() async throws {
        let fixture = try Fixture(firstLoad: "pass", configDelay: 0.15)
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.prepareSessionOptions()
        store.setModel(try XCTUnwrap(store.run.models.first { $0.id == "fixture-fast" }))
        XCTAssertTrue(store.run.isConfiguring)
        store.setReasoning(try XCTUnwrap(store.run.reasoningOptions.first { $0.id == "high" }))
        store.draft = "Wait until settings are confirmed"
        store.send()
        XCTAssertEqual(store.draft, "Wait until settings are confirmed")
        try await eventually { !store.run.isConfiguring }
        XCTAssertEqual(store.run.modelID, "fixture-fast")
        XCTAssertEqual(store.conversation?.modelID, "fixture-fast")
        XCTAssertEqual(fixture.requests.filter { $0["method"] as? String == "session/set_config_option" }.count, 1)
        XCTAssertFalse(fixture.requests.contains { $0["method"] as? String == "session/prompt" })
    }

    func testRejectedConfigurationRetainsConfirmedSelectionAndExplainsFailure() async throws {
        let fixture = try Fixture(firstLoad: "pass", rejectConfig: true)
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.prepareSessionOptions()
        store.setModel(try XCTUnwrap(store.run.models.first { $0.id == "fixture-fast" }))
        try await eventually { !store.run.isConfiguring }
        XCTAssertEqual(store.run.modelID, "fixture-build")
        XCTAssertEqual(store.conversation?.modelID, "fixture-build")
        XCTAssertTrue(store.banner?.contains("Unsupported setting") == true)
    }

    func testDeletionRemovesTaskStateAndCannotBeResurrectedByImportAfterRestart() async throws {
        let fixture = try Fixture(firstLoad: "pass")
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.prepareSessionOptions()
        store.draft = "Discard this draft"
        store.deleteConversation(fixture.conversationID)
        XCTAssertNil(store.conversation)
        XCTAssertTrue(store.state.conversations.isEmpty)
        XCTAssertNil(store.runs[fixture.conversationID])
        XCTAssertEqual(store.draft, "")
        let reopened = AppStore(stateFile: fixture.directory.appendingPathComponent("state.json"), defaults: fixture.defaults, binaryPath: store.binaryPath)
        defer { reopened.shutdown() }
        reopened.syncHistory()
        try await eventually { !reopened.syncing }
        XCTAssertTrue(reopened.state.conversations.isEmpty)
        XCTAssertTrue(reopened.state.deletedSessionIDs.contains("existing-session"))
    }

    func testDeletionCannotInterruptRunningTask() async throws {
        let fixture = try Fixture(firstLoad: "time.sleep(20)")
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "Active task"
        store.send()
        store.deleteConversation(fixture.conversationID)
        XCTAssertNotNil(store.conversation)
        XCTAssertTrue(store.state.deletedSessionIDs.isEmpty)
        store.cancel()
    }

    func testOldHistoryDecodesWithoutNewPreferencesOrTombstones() throws {
        let old = Data(#"{"projects":[],"conversations":[]}"#.utf8)
        let state = try JSONDecoder().decode(DesktopState.self, from: old)
        XCTAssertNil(state.selectedModelID)
        XCTAssertTrue(state.deletedSessionIDs.isEmpty)
    }

    func testReasoningMetadataHonorsCustomIDsAndUnsupportedModels() {
        let models = SessionOptions.models(["availableModels": [
            ["modelId": "reasoner", "_meta": ["supportsReasoningEffort": true, "reasoningEffort": "high", "reasoningEfforts": [["id": "deep", "value": "high", "label": "Deep thinking"], ["value": "medium"]]]],
            ["modelId": "plain", "_meta": ["supportsReasoningEffort": false, "reasoningEfforts": ["high"]]]
        ]])
        XCTAssertEqual(models[0].reasoningOptions.map(\.id), ["deep", "medium"])
        XCTAssertEqual(models[0].defaultReasoningID, "deep")
        XCTAssertTrue(models[1].reasoningOptions.isEmpty)
    }
}
