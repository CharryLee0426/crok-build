import Foundation
import XCTest
@testable import GrokDesktop

final class TranscriptReducerTests: XCTestCase {
    func testStreamingPreservesRoleBoundariesAndUnicode() {
        var messages: [Message] = []
        for (kind, text) in [
            ("user_message_chunk", "Inspect this project."),
            ("agent_thought_chunk", "Checking "), ("agent_thought_chunk", "the files."),
            ("agent_message_chunk", "Hello "), ("agent_message_chunk", "世界 🦊"),
            ("user_message_chunk", "Continue."), ("agent_message_chunk", "Done."),
        ] {
            TranscriptReducer.apply(["sessionUpdate": kind, "content": ["type": "text", "text": text]], to: &messages)
        }
        XCTAssertEqual(messages.map(\.kind), [.user, .thought, .assistant, .user, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Inspect this project.", "Checking the files.", "Hello 世界 🦊", "Continue.", "Done."])
    }

    func testToolPartialUpdatesMergeByIdentityWithoutErasingExistingDetails() {
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "read-1", "title": "Read README", "status": "in_progress"], to: &messages)
        let originalID = messages[0].id
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "read-1", "content": [["type": "content", "content": ["type": "text", "text": "Project documentation"]]]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Read complete."]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "read-1", "status": "completed"], to: &messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, originalID)
        XCTAssertEqual(messages[0].text, "Read README")
        XCTAssertEqual(messages[0].detail, "Project documentation")
        XCTAssertEqual(messages[0].status, "completed")
        XCTAssertEqual(messages[1].text, "Read complete.")
    }

    func testInterleavedToolUpdatesDoNotOverwriteAnotherTool() {
        var messages: [Message] = []
        for id in ["first", "second"] {
            TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": id, "title": id, "status": "in_progress"], to: &messages)
        }
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "first", "status": "failed"], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "second", "title": "Second completed", "status": "completed"], to: &messages)
        XCTAssertEqual(messages.map(\.status), ["failed", "completed"])
        XCTAssertEqual(messages.map(\.text), ["first", "Second completed"])
    }

    func testUpdateCanCreateToolWhenInitialNotificationWasNotPresent() {
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "replayed", "status": "completed", "content": [["type": "diff", "path": "Sources/App.swift", "newText": "let greeting = \"hello\""]]], to: &messages)
        XCTAssertEqual(messages.first?.toolID, "replayed")
        XCTAssertEqual(messages.first?.kind, .tool)
        XCTAssertEqual(messages.first?.status, "completed")
        XCTAssertTrue(messages.first?.detail?.contains("Sources/App.swift") == true)
        XCTAssertTrue(messages.first?.detail?.contains("let greeting") == true)
    }

    func testUnknownEmptyAndMalformedUpdatesDoNotInsertBlankMessages() {
        var messages = [Message(kind: .assistant, text: "Existing response")]
        for update: [String: Any] in [
            ["sessionUpdate": "future_extension", "content": ["text": "Ignore"]],
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": ""]],
            ["sessionUpdate": "tool_call_update", "status": "completed"],
            ["sessionUpdate": "plan", "entries": []],
        ] {
            TranscriptReducer.apply(update, to: &messages)
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Existing response")
    }

    func testEmbeddedResourcesHaveReadableTranscriptFallbacks() {
        XCTAssertEqual(TranscriptReducer.text(from: ["type": "resource", "resource": ["uri": "file:///notes.md", "text": "Design notes"]]), "Design notes")
        XCTAssertEqual(TranscriptReducer.text(from: ["type": "resource", "resource": ["uri": "file:///attachment.bin"]]), "file:///attachment.bin")
        XCTAssertEqual(TranscriptReducer.text(from: ["type": "image", "data": "unused"]), "[Image]")
    }
}

@MainActor
final class HarnessFixtureTests: XCTestCase {
    private func connect() async throws -> ACPClient {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The offline harness fixture requires /usr/bin/python3.")
        }
        let client = ACPClient()
        try client.start(executable: "/usr/bin/python3", cwd: NSTemporaryDirectory(), arguments: [fixture.path, "agent", "stdio"])
        let initial = try await client.request("initialize", params: ["protocolVersion": 1], timeout: 5)
        XCTAssertEqual((initial["_meta"] as? [String: Any])?["defaultAuthMethodId"] as? String, "xai.api_key")
        _ = try await client.request("authenticate", params: ["methodId": "xai.api_key"], timeout: 5)
        return client
    }

    func testHistoryReplayStreamingAndModelSelectionThroughRealPipes() async throws {
        let client = try await connect()
        defer { client.stop() }
        var messages: [Message] = []
        client.onNotification = { method, params in
            if method == "session/update", let update = params["update"] as? [String: Any] {
                TranscriptReducer.apply(update, to: &messages)
            }
        }
        let listing = try await client.request("session/list", timeout: 5)
        let history = try XCTUnwrap((listing["sessions"] as? [[String: Any]])?.first)
        let historyID = try XCTUnwrap(history["sessionId"] as? String)
        _ = try await client.request("session/load", params: ["sessionId": historyID, "cwd": NSTemporaryDirectory(), "mcpServers": []], timeout: 5)
        XCTAssertEqual(messages.map(\.kind), [.user, .assistant])
        XCTAssertTrue(messages[1].text.contains("offline fixture history"))

        messages = []
        let session = try await client.request("session/new", params: ["cwd": NSTemporaryDirectory(), "mcpServers": []], timeout: 5)
        let id = try XCTUnwrap(session["sessionId"] as? String)
        _ = try await client.request("session/set_model", params: ["sessionId": id, "modelId": "fixture-grok-fast"], timeout: 5)
        _ = try await client.request("session/set_mode", params: ["sessionId": id, "modeId": "plan"], timeout: 5)
        let result = try await client.request("session/prompt", params: ["sessionId": id, "prompt": [["type": "text", "text": "Preview the desktop."]]], timeout: 5)
        XCTAssertEqual(result["stopReason"] as? String, "end_turn")
        XCTAssertEqual(messages.filter { $0.kind == .assistant }.count, 1)
        XCTAssertTrue(messages.last?.text.contains("offline test fixture") == true)
        let tool = try XCTUnwrap(messages.first { $0.kind == .tool })
        XCTAssertEqual(tool.status, "completed")
        XCTAssertTrue(tool.detail?.contains("No commands were executed") == true)
    }

    func testPermissionQuestionAndPlanRepliesUnblockPrompt() async throws {
        let client = try await connect()
        defer { client.stop() }
        var handledMethods: [String] = []
        client.onRequest = { id, method, params in
            handledMethods.append(method)
            do {
                switch method {
                case "session/request_permission":
                    let options = params["options"] as? [[String: Any]] ?? []
                    XCTAssertTrue(options.contains { $0["optionId"] as? String == "allow" })
                    try client.respond(id: id, result: ["outcome": ["outcome": "selected", "optionId": "allow"]])
                case "x.ai/ask_user_question":
                    try client.respond(id: id, result: ["outcome": "accepted", "answers": ["Which fixture should we explore?": ["Conversation"]]])
                case "x.ai/exit_plan_mode":
                    XCTAssertTrue((params["planContent"] as? String)?.contains("Offline fixture plan") == true)
                    try client.respond(id: id, result: ["outcome": "approved"])
                case "x.ai/folder_trust/request":
                    try client.respond(id: id, result: ["outcome": "reject"])
                default: XCTFail("Unexpected method: \(method)")
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        let session = try await client.request("session/new", params: ["cwd": NSTemporaryDirectory(), "mcpServers": []], timeout: 5)
        let id = try XCTUnwrap(session["sessionId"] as? String)
        let result = try await client.request("session/prompt", params: ["sessionId": id, "prompt": [["type": "text", "text": "fixture:permission fixture:question fixture:plan fixture:trust"]]], timeout: 5)
        XCTAssertEqual(result["stopReason"] as? String, "end_turn")
        XCTAssertEqual(handledMethods, ["session/request_permission", "x.ai/ask_user_question", "x.ai/exit_plan_mode", "x.ai/folder_trust/request"])
    }

    func testCancellationReleasesPendingPermissionAndAllowsNextTurn() async throws {
        let client = try await connect()
        defer { client.stop() }
        let session = try await client.request("session/new", params: ["cwd": NSTemporaryDirectory(), "mcpServers": []], timeout: 5)
        let id = try XCTUnwrap(session["sessionId"] as? String)
        var permissionSeen = false
        client.onRequest = { requestID, method, _ in
            XCTAssertEqual(method, "session/request_permission")
            permissionSeen = true
            do {
                try client.notify("session/cancel", params: ["sessionId": id])
                try client.respond(id: requestID, result: ["outcome": ["outcome": "cancelled"]])
            } catch { XCTFail(error.localizedDescription) }
        }
        let cancelled = try await client.request("session/prompt", params: ["sessionId": id, "prompt": [["type": "text", "text": "fixture:permission"]]], timeout: 5)
        XCTAssertTrue(permissionSeen)
        XCTAssertEqual(cancelled["stopReason"] as? String, "cancelled")
        let next = try await client.request("session/prompt", params: ["sessionId": id, "prompt": [["type": "text", "text": "Continue after stopping."]]], timeout: 5)
        XCTAssertEqual(next["stopReason"] as? String, "end_turn")
    }
}
