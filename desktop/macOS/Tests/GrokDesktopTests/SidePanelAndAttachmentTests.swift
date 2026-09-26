import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrokDesktop

/// Prompt attachments, side chats, the Files tab's index, and the terminal, without a harness.
@MainActor
final class SidePanelAndAttachmentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> (AppStore, Project) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        return (store, project)
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(width), alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: max(1, width / 64), height: height))
        }
        return PromptAttachmentsModel.encode(context.makeImage()!, as: .png)!
    }

    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    // MARK: Attachments

    func testPromptBlocksCarryTextImagesFilesAndFolders() throws {
        var image = PromptAttachment(kind: .image, name: "shot.png", url: nil)
        image.imageData = Data([1, 2, 3]); image.mimeType = "image/png"
        let file = PromptAttachment(kind: .file, name: "main.swift", url: URL(fileURLWithPath: "/tmp/project/main.swift"), byteCount: 12)
        let folder = PromptAttachment(kind: .folder, name: "Sources", url: URL(fileURLWithPath: "/tmp/project/Sources", isDirectory: true))
        let blocks = PromptBlocks.make(text: "Look at these", attachments: [image, file, folder])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "image", "resource_link", "resource_link"])
        XCTAssertEqual(blocks[0]["text"] as? String, "Look at these")
        XCTAssertEqual(blocks[1]["data"] as? String, "AQID")
        XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/png")
        XCTAssertNil(blocks[1]["uri"], "images travel as data, as the terminal sends them")
        XCTAssertEqual(blocks[2]["uri"] as? String, "file:///tmp/project/main.swift")
        XCTAssertEqual(blocks[2]["name"] as? String, "main.swift")
        XCTAssertEqual(blocks[2]["size"] as? Int, 12)
        XCTAssertNil(blocks[2]["_meta"], "a file link without _meta lets the harness inline small text files")
        XCTAssertEqual((blocks[3]["_meta"] as? [String: String])?["x.ai/kind"], "directory")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["prompt": blocks]))

        XCTAssertEqual(PromptBlocks.make(text: "", attachments: [file]).map { $0["type"] as? String }, ["resource_link"],
                       "an attachment-only prompt sends no empty text block")
        let plain = PromptBlocks.make(text: "/gboom go", meta: ["displayText": "/gboom go"], attachments: [])
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual((plain[0]["_meta"] as? [String: String])?["displayText"], "/gboom go")
        var preparing = PromptAttachment(kind: .image, name: "pending.png", url: nil)
        XCTAssertTrue(preparing.isPreparing)
        XCTAssertNil(preparing.promptBlock, "an image is only sent once it is encoded")
        preparing.failure = "unreadable"
        XCTAssertFalse(preparing.isPreparing)
    }

    func testSmallImagesAreSentAsTheyAreAndLargeOnesDownscaled() throws {
        let small = Self.png(width: 64, height: 48)
        let kept = try XCTUnwrap(PromptAttachmentsModel.prepare(.data(small)))
        XCTAssertEqual(kept.data, small)
        XCTAssertEqual(kept.mimeType, "image/png")
        XCTAssertNotNil(kept.thumbnail)
        XCTAssertNotNil(kept.thumbnailData)

        let large = Self.png(width: 4_000, height: 2_500)
        let scaled = try XCTUnwrap(PromptAttachmentsModel.prepare(.data(large)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(scaled.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(max(width, height), Int(PromptAttachmentsModel.maximumImageSide))
        XCTAssertEqual(Double(width) / Double(height), 1.6, accuracy: 0.01)
        XCTAssertLessThanOrEqual(scaled.data.count, PromptAttachmentsModel.maximumImageBytes)
        let thumbnail = try XCTUnwrap(scaled.thumbnail)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), Int(PromptAttachmentsModel.thumbnailSide))

        XCTAssertNil(PromptAttachmentsModel.prepare(.data(Data("not an image".utf8))))
    }

    func testAttachmentsAreSortedByKindAndKeptWithTheirDraft() async throws {
        let (store, project) = makeStore()
        let model = store.features.attachments
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        let picture = directory.appendingPathComponent("picture.png")
        try Self.png(width: 32, height: 32).write(to: picture)
        let folder = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        model.add(urls: [notes, picture, folder, notes])
        XCTAssertEqual(model.current.map(\.kind), [.file, .image, .folder], "a file already attached is not added twice")
        XCTAssertEqual(model.current.first?.byteCount, 5)
        try await eventually { !model.isPreparing }
        XCTAssertNotNil(model.current[1].imageData)
        XCTAssertEqual(model.current[1].mimeType, "image/png")

        let task = Conversation(projectID: project.id, title: "Another task")
        store.state.conversations = [task]
        store.selectConversation(task)
        XCTAssertTrue(model.current.isEmpty, "each task's draft has its own attachments")
        store.newTask()
        XCTAssertEqual(model.current.count, 3)
        model.remove(model.current[0].id)
        XCTAssertEqual(model.current.map(\.kind), [.image, .folder])
        let taken = model.take(from: store.draftLocation)
        XCTAssertEqual(taken.count, 2)
        XCTAssertTrue(model.current.isEmpty)
        model.restore(taken, to: store.draftLocation)
        XCTAssertEqual(model.current.count, 2)
    }

    func testAttachingNeedsAProjectAndIsBounded() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState()
        let file = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        store.features.attachments.add(urls: [file])
        XCTAssertTrue(store.features.attachments.current.isEmpty)
        XCTAssertEqual(store.banner, "Open a project before attaching files.")

        let (bounded, _) = makeStore()
        let urls = try (0...PromptAttachmentsModel.limit).map { index -> URL in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("\(index)".utf8).write(to: url)
            return url
        }
        bounded.features.attachments.add(urls: urls)
        XCTAssertEqual(bounded.features.attachments.current.count, PromptAttachmentsModel.limit)
        XCTAssertEqual(bounded.banner, "A prompt can carry up to \(PromptAttachmentsModel.limit) attachments.")
    }

    func testPastingFilesAndImagesAttachesButTextPastesAsText() throws {
        let (store, _) = makeStore()
        let model = store.features.attachments
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.grok.desktop.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertFalse(model.paste(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("Quarterly numbers", forType: .string)
        pasteboard.setData(Data("{\\rtf1 Quarterly numbers}".utf8), forType: .rtf)
        pasteboard.setData(Self.png(width: 16, height: 16), forType: .png)
        XCTAssertFalse(model.paste(from: pasteboard), "rich text copied with a picture of itself pastes as text")
        XCTAssertTrue(model.current.isEmpty)

        pasteboard.clearContents()
        pasteboard.setData(Self.png(width: 40, height: 30), forType: .png)
        XCTAssertTrue(model.paste(from: pasteboard))
        XCTAssertEqual(model.current.map(\.kind), [.image])
        let saved = try XCTUnwrap(model.current.first?.url)
        XCTAssertTrue(PromptAttachmentsModel.isScratch(saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "a pasted image is saved so Quick Look can show it")

        let file = directory.appendingPathComponent("copied.md")
        try Data("# Copied".utf8).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertTrue(model.paste(from: pasteboard))
        XCTAssertEqual(model.current.map(\.name), [model.current[0].name, "copied.md"])
        XCTAssertTrue(PromptAttachmentsModel.carriesAttachments(pasteboard))
    }

    func testReplayedPromptsShowTheirAttachments() {
        var messages: [Message] = []
        let png = Self.png(width: 48, height: 24)
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "What is in these?"]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": ["type": "resource_link", "uri": "file:///tmp/project/Sources", "name": "Sources",
                                                                             "_meta": ["x.ai/kind": "directory"]]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": ["type": "resource_link", "uri": "file:///tmp/project/main.swift", "name": "main.swift"]], to: &messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "What is in these?")
        XCTAssertEqual(messages[0].attachments?.map(\.kind), [.image, .folder, .file])
        XCTAssertNotNil(messages[0].attachments?[0].thumbnail)
        XCTAssertEqual(messages[0].attachments?[2].path, "/tmp/project/main.swift")

        TranscriptReducer.apply(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "A gradient."]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]], to: &messages)
        XCTAssertEqual(messages.map(\.kind), [.user, .assistant, .user])
        XCTAssertEqual(messages[2].text, "", "an attachment-only prompt starts its own message")
        XCTAssertEqual(messages[2].attachments?.count, 1)
    }

    func testSentAttachmentsSurviveSavingAndOldStateStillLoads() throws {
        let message = Message(kind: .user, text: "See attached", createdAt: Date(),
                              attachments: [MessageAttachment(kind: .file, name: "a.txt", path: "/tmp/a.txt"), MessageAttachment(kind: .image, name: "Image", thumbnail: Data([7]))])
        var task = Conversation(projectID: UUID(), title: "Attachments", messages: [message])
        task.sideChat = [SideChatMessage(role: .question, text: "Why?"), SideChatMessage(role: .answer, text: "Because.")]
        let data = try JSONEncoder().encode(DesktopState(conversations: [task]))
        let decoded = try JSONDecoder().decode(DesktopState.self, from: data)
        XCTAssertEqual(decoded.conversations[0].messages[0].attachments, message.attachments)
        XCTAssertEqual(decoded.conversations[0].sideChat?.map(\.text), ["Why?", "Because."])

        let legacy = #"{"conversations":[{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","title":"Old","messages":[{"id":"\#(UUID().uuidString)","kind":"user","text":"hi"}],"updatedAt":0,"isArchived":false,"isPinned":false}]}"#
        let old = try JSONDecoder().decode(DesktopState.self, from: Data(legacy.utf8))
        XCTAssertNil(old.conversations[0].messages[0].attachments)
        XCTAssertNil(old.conversations[0].sideChat)
    }

    // MARK: Side chat

    func testSideQuestionsCarryRecentExchangesForFollowUps() {
        func message(_ role: SideChatMessage.Role, _ text: String) -> SideChatMessage { SideChatMessage(role: role, text: text) }
        XCTAssertEqual(SideChatModel.prompt("first", after: []), "first")
        let history = [message(.question, "a"), message(.answer, "A"), message(.question, "b"), message(.failure, "timed out"),
                       message(.question, "c"), message(.answer, "C")]
        let prompt = SideChatModel.prompt("d", after: history)
        XCTAssertTrue(prompt.hasPrefix("Earlier side questions in this chat, for context:"))
        XCTAssertTrue(prompt.contains("Q: a\nA: A\n\nQ: c\nA: C"), "exchanges keep their order")
        XCTAssertFalse(prompt.contains("timed out"), "failed questions are left out")
        XCTAssertTrue(prompt.hasSuffix("New side question: d"))

        let long = (0..<10).flatMap { [message(.question, "question \($0)"), message(.answer, String(repeating: "x", count: 1_900))] }
        let bounded = SideChatModel.prompt("next", after: long)
        XCTAssertLessThanOrEqual(bounded.count, SideChatModel.contextCharacters + 200)
        XCTAssertTrue(bounded.contains("Q: question 9"))
        XCTAssertFalse(bounded.contains("Q: question 0\n"), "older exchanges past the budget are dropped")
    }

    func testSideChatsAreSavedWithTheirTaskAndClearable() {
        let (store, project) = makeStore()
        let task = Conversation(projectID: project.id, title: "Parser")
        store.state.conversations = [task]
        store.setSideChat([SideChatMessage(role: .question, text: "Where is the lexer?")], for: task.id)
        XCTAssertEqual(store.task(task.id)?.sideChat?.count, 1)
        XCTAssertEqual(store.features.sideChat.thread(task.id).map(\.text), ["Where is the lexer?"])
        store.features.sideChat.clear(task.id)
        XCTAssertNil(store.task(task.id)?.sideChat)
        XCTAssertTrue(store.features.sideChat.thread(task.id).isEmpty)
    }

    func testBtwOpensTheSideChatForTheSelectedTask() {
        let (store, project) = makeStore()
        store.executeCommand(name: "btw", arguments: "what is left?")
        XCTAssertEqual(store.banner, "Open a task to ask a side question about it.")
        XCTAssertFalse(store.showInspector)

        let task = Conversation(projectID: project.id, title: "Parser")
        store.state.conversations = [task]
        store.selectConversation(task)
        store.executeCommand(name: "btw")
        XCTAssertTrue(store.showInspector)
        XCTAssertEqual(store.sidePanelTab, .sideChat)
        store.executeCommand(name: "changes")
        XCTAssertEqual(store.sidePanelTab, .files)
        XCTAssertEqual(store.features.files.scope, .changes)
        store.executeCommand(name: "terminal")
        XCTAssertEqual(store.sidePanelTab, .terminal)
    }

    // MARK: Files

    func testFileIndexBuildsAFolderFirstTreeAndSearchesPaths() {
        let index = ProjectFileIndex(root: "/p", files: ["README.md", "Sources/App/main.swift", "Sources/App/View.swift", "Tests/AppTests.swift", "b.txt"], isTruncated: false)
        XCTAssertEqual(index.rows(expanded: []).map(\.entry.path), ["Sources", "Tests", "b.txt", "README.md"])
        let open = index.rows(expanded: ["Sources", "Sources/App"])
        XCTAssertEqual(open.map(\.entry.path), ["Sources", "Sources/App", "Sources/App/main.swift", "Sources/App/View.swift", "Tests", "b.txt", "README.md"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 2, 2, 0, 0, 0])
        XCTAssertEqual(index.rows(expanded: ["Sources/App"]).count, 4, "a closed parent hides open children")
        XCTAssertEqual(index.search("view").first, "Sources/App/View.swift")
        XCTAssertEqual(index.search("readme"), ["README.md"])
        XCTAssertEqual(index.search("sam"), ["Sources/App/main.swift"], "characters in order match across folders")
        XCTAssertTrue(index.search("zzz").isEmpty)
    }

    func testFilePreviewReadsTextImagesAndBinaries() throws {
        let text = directory.appendingPathComponent("main.swift")
        try Data("let x = 1\n".utf8).write(to: text)
        guard case .text(let content, let language, let truncated) = FilesPanelModel.readPreview(text.path) else { return XCTFail("expected text") }
        XCTAssertEqual(content, "let x = 1\n")
        XCTAssertEqual(language, "swift")
        XCTAssertFalse(truncated)

        let image = directory.appendingPathComponent("picture.png")
        try Self.png(width: 20, height: 10).write(to: image)
        guard case .image(let picture, _) = FilesPanelModel.readPreview(image.path) else { return XCTFail("expected image") }
        XCTAssertEqual(picture.size.width, 20)

        let binary = directory.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: binary)
        guard case .binary(let bytes) = FilesPanelModel.readPreview(binary.path) else { return XCTFail("expected binary") }
        XCTAssertEqual(bytes, 4)
    }

    func testGitStatusBadges() {
        XCTAssertEqual(FileStatusBadge.letter("??"), "U")
        XCTAssertEqual(FileStatusBadge.letter(" M"), "M")
        XCTAssertEqual(FileStatusBadge.letter("A "), "A")
        XCTAssertEqual(FileStatusBadge.letter("D "), "D")
        XCTAssertEqual(FileStatusBadge.description("R "), "Renamed")
    }

    // MARK: Terminal

    func testTerminalEnvironmentAdvertisesColoursAndDropsDesktopOverrides() {
        let environment = TerminalSessions.environment(shell: "/bin/zsh")
        XCTAssertTrue(environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(environment.contains("COLORTERM=truecolor"))
        XCTAssertTrue(environment.contains("TERM_PROGRAM=GrokDesktop"))
        XCTAssertTrue(environment.contains("SHELL=/bin/zsh"))
        XCTAssertTrue(environment.contains { $0.hasPrefix("HOME=") })
        XCTAssertTrue(environment.contains { $0.hasPrefix("LANG=") || $0.hasPrefix("LC_ALL=") })
        XCTAssertFalse(environment.contains { $0.hasPrefix("CROK_DESKTOP_") })
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: TerminalSessions.loginShell))
        XCTAssertEqual(TerminalPalette.light.count, 16)
        XCTAssertEqual(TerminalPalette.dark.count, 16)
    }

    func testTerminalRunsAShellInTheProjectFolder() async throws {
        let (_, project) = makeStore()
        let sessions = TerminalSessions()
        // Not the user's shell: its startup files are not part of this test.
        sessions.shell = "/bin/sh"
        defer { sessions.terminateAll() }
        let terminal = sessions.ensureTerminal(for: project)
        XCTAssertTrue(sessions.ensureTerminal(for: project) === terminal, "each project keeps one shell")
        XCTAssertEqual(sessions.status(for: project)?.directory, project.path)
        terminal.send(txt: "echo grok-terminal-$((40 + 2)); pwd\r")
        func screen() -> String { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        try await eventually(timeout: 20) { screen().contains("grok-terminal-42") }
        XCTAssertTrue(screen().contains(URL(fileURLWithPath: project.path).resolvingSymlinksInPath().lastPathComponent))

        terminal.send(txt: "exit\r")
        try await eventually(timeout: 10) { sessions.status(for: project)?.hasExited == true }
        sessions.restart(project)
        XCTAssertFalse(sessions.status(for: project)?.hasExited ?? true)
        XCTAssertFalse(sessions.terminal(for: project) === terminal)
    }
}
