import XCTest
@testable import GrokDesktop

/// Attachments and side chats against the offline ACP fixture.
@MainActor
final class AttachmentIntegrationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let store: AppStore

        init() throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-attachment-acp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/mock-grok.py")
            let original = try String(contentsOf: fixtureURL, encoding: .utf8)
            let source = original.components(separatedBy: "if __name__ == \"__main__\":")[0]
                .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
            // Logs every client message, and holds prompts that mention `fixture:slow`.
            let harness = #"""
LOG = os.path.join(os.path.dirname(__file__), "requests.jsonl")
class LoggingHarness(MockHarness):
    def handle(self, message):
        with open(LOG, "a") as handle:
            handle.write(json.dumps(message) + "\n")
        super().handle(message)
    def prompt(self, request_id, params, stop):
        if "fixture:slow" in "".join(block.get("text", "") for block in params.get("prompt", [])):
            stop.wait(1.0)
        super().prompt(request_id, params, stop)
LoggingHarness().run()
"""#
            let executable = directory.appendingPathComponent("fixture-grok")
            try (source + harness).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
            let project = Project(path: directory.path)
            store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        }

        func params(for method: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
                .filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
        }

        var promptBlocks: [[[String: Any]]] { params(for: "session/prompt").map { $0["prompt"] as? [[String: Any]] ?? [] } }

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

    func testAttachmentsTravelWithThePromptAndStayInTheTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let attachments = store.features.attachments
        let notes = fixture.directory.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: notes)
        let folder = fixture.directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        attachments.add(urls: [notes, folder])
        attachments.add(imageData: SidePanelAndAttachmentTests.png(width: 30, height: 20))
        try await eventually { !attachments.isPreparing }

        store.draft = "Summarize these"
        store.send()
        XCTAssertTrue(attachments.current.isEmpty, "sending hands the attachments to the prompt")
        try await eventually { fixture.promptBlocks.count == 1 && !store.run.isRunning }
        let blocks = try XCTUnwrap(fixture.promptBlocks.first)
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "resource_link", "resource_link", "image"])
        XCTAssertEqual(blocks[1]["uri"] as? String, notes.absoluteString)
        XCTAssertEqual((blocks[2]["_meta"] as? [String: String])?["x.ai/kind"], "directory")
        XCTAssertEqual(blocks[3]["mimeType"] as? String, "image/png")
        XCTAssertFalse((blocks[3]["data"] as? String ?? "").isEmpty)

        let messages = try XCTUnwrap(store.conversation?.messages)
        let prompt = try XCTUnwrap(messages.first { $0.kind == .user })
        XCTAssertEqual(prompt.text, "Summarize these")
        XCTAssertEqual(prompt.attachments?.map(\.kind), [.file, .folder, .image])
        XCTAssertNotNil(prompt.attachments?.last?.thumbnail)
        XCTAssertTrue(messages.contains { $0.kind == .assistant && $0.text.contains("Received 3 attachment(s): notes.md, Sources, image/png.") })
    }

    func testToolAndGeneratedImagesShowInTheTranscriptAndViewer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.features.attachments.add(imageData: SidePanelAndAttachmentTests.png(width: 30, height: 20))
        try await eventually { !store.features.attachments.isPreparing }
        store.draft = "fixture:image what changed?"
        store.send()
        try await eventually { fixture.promptBlocks.count == 1 && !store.run.isRunning }

        let messages = try XCTUnwrap(store.conversation?.messages)
        let read = try XCTUnwrap(messages.first { $0.toolID?.hasPrefix("fixture-read-image") == true })
        XCTAssertEqual(read.status, "completed")
        XCTAssertEqual(read.attachments?.map(\.name), ["screenshot.png"])
        XCTAssertEqual(read.attachments?.first?.pixelSize, CGSize(width: 240, height: 160))
        XCTAssertNotNil(read.attachments?.first?.fullImageURL)
        XCTAssertNil(read.detail?.range(of: "[Image]"))
        let generated = try XCTUnwrap(messages.first { $0.toolID?.hasPrefix("fixture-image-gen") == true }?.attachments?.first)
        XCTAssertEqual(generated.origin, .generated)
        XCTAssertEqual(generated.pixelSize, CGSize(width: 320, height: 320))

        // The sent image, the read screenshot, then the generated image.
        store.openImage(generated)
        XCTAssertEqual(store.imageViewer?.items.count, 3)
        XCTAssertEqual(store.imageViewer?.index, 2)
        XCTAssertEqual(store.imageViewer?.items[1].name, "screenshot.png")
        store.closeImageViewer()
        if let folder = generated.path.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
    }

    func testAnAttachmentOnlyPromptIsSentAndNamesTheTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let report = fixture.directory.appendingPathComponent("report.pdf")
        try Data("%PDF-1.4".utf8).write(to: report)
        store.features.attachments.add(urls: [report])
        store.draft = ""
        store.send()
        try await eventually { fixture.promptBlocks.count == 1 && !store.run.isRunning }
        XCTAssertEqual(fixture.promptBlocks.first?.map { $0["type"] as? String }, ["resource_link"])
        XCTAssertEqual(store.conversation?.title, "report.pdf")
    }

    func testAttachmentsQueuedDuringATurnAreSentWithTheirPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.draft = "fixture:slow first"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(store.state.selectedConversationID)

        let file = fixture.directory.appendingPathComponent("follow-up.txt")
        try Data("more".utf8).write(to: file)
        store.features.attachments.add(urls: [file])
        store.draft = "and this file"
        store.send()
        XCTAssertEqual(store.features.composer.queue.items(id).first?.attachments.map(\.name), ["follow-up.txt"])
        XCTAssertTrue(store.features.attachments.current.isEmpty)

        try await eventually(timeout: 12) { fixture.promptBlocks.count == 2 && !store.run.isRunning }
        XCTAssertEqual(fixture.promptBlocks[1].map { $0["type"] as? String }, ["text", "resource_link"])
        XCTAssertEqual(store.conversation?.messages.last { $0.kind == .user }?.attachments?.map(\.name), ["follow-up.txt"])
    }

    func testSideChatAnswersWithoutInterruptingTheTurn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let sideChat = store.features.sideChat
        store.draft = "fixture:slow working"
        store.send()
        try await eventually { store.run.phase == "Working" }
        let id = try XCTUnwrap(store.state.selectedConversationID)

        sideChat.ask("what are you doing?", in: id)
        XCTAssertTrue(sideChat.pending.contains(id))
        try await eventually { sideChat.thread(id).count == 2 }
        XCTAssertEqual(sideChat.thread(id).map(\.role), [.question, .answer])
        XCTAssertEqual(sideChat.thread(id).last?.text, "Offline fixture side answer to: what are you doing?")
        XCTAssertTrue(store.run.isRunning, "the side question did not stop the turn")

        sideChat.ask("and then?", in: id)
        try await eventually { sideChat.thread(id).count == 4 }
        let followUp = try XCTUnwrap(fixture.params(for: "_x.ai/btw").last?["question"] as? String)
        XCTAssertTrue(followUp.contains("Q: what are you doing?"), "a follow-up carries the earlier exchange")
        XCTAssertEqual(store.task(id)?.sideChat?.count, 4, "the side chat is saved with its task")
        try await eventually(timeout: 12) { !store.run.isRunning }
        XCTAssertFalse(store.conversation?.messages.contains { $0.text.contains("what are you doing?") } ?? true,
                       "side questions stay out of the task's conversation")
    }
}
