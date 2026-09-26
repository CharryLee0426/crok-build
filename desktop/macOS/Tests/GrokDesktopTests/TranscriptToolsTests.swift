import AppKit
import XCTest
@testable import GrokDesktop

/// Transcript commands: /copy, /export, /find, /jump, /timeline, /timestamps, /expand,
/// /vim-mode, /history, /transcript, and /debug.
@MainActor
final class TranscriptToolsTests: XCTestCase {
    private var directory: URL!
    private var defaultsName: String!
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "GrokDesktopTranscriptTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.grok.desktop.tests.\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var grokHome: URL { directory.appendingPathComponent("grok-home", isDirectory: true) }
    private var projectPath: String { directory.appendingPathComponent("project", isDirectory: true).path }

    /// A store with one task in a temporary project, and a transcript model that only touches temporary files.
    private func makeFixture(messages: [Message] = [], sessionID: String? = nil, binary: String = "/usr/bin/false") throws -> (AppStore, TranscriptToolsModel) {
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: binary)
        let project = Project(path: projectPath)
        let task = Conversation(projectID: project.id, title: "Render tables", sessionID: sessionID, messages: messages)
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        let tools = TranscriptToolsModel(store: store, defaults: defaults, configURL: directory.appendingPathComponent("config.toml"))
        tools.grokHomeOverride = grokHome
        tools.environment = [:]
        tools.pasteboard = pasteboard
        return (store, tools)
    }

    /// Waits for a command's background work, including work it hands on (an export's clipboard delivery).
    private func finish(_ tools: TranscriptToolsModel) async {
        while let work = tools.pendingWork {
            await work.value
            if tools.pendingWork == work { break }
        }
    }

    private static let sample: [Message] = [
        Message(kind: .user, text: "Render the tables\nwith borders"),
        Message(kind: .thought, text: "Planning the **table** layout"),
        Message(kind: .assistant, text: "First reply"),
        Message(kind: .tool, text: "Read `Sources/App.swift`", status: "completed", detail: "struct App {}"),
        Message(kind: .assistant, text: "Second reply"),
        Message(kind: .user, text: "   \n\n  Now add **math**  "),
        Message(kind: .assistant, text: "Here is $x^2$ and a [link](https://x.ai)."),
        Message(kind: .system, text: "Could not save task history"),
    ]

    // MARK: /copy

    func testCopyArgumentsFollowTheTerminal() throws {
        XCTAssertEqual(try TranscriptCopyRequest.parse(""), TranscriptCopyRequest(index: 1, path: nil))
        XCTAssertEqual(try TranscriptCopyRequest.parse("  2  "), TranscriptCopyRequest(index: 2, path: nil))
        XCTAssertEqual(try TranscriptCopyRequest.parse("out.txt"), TranscriptCopyRequest(index: 1, path: "out.txt"))
        XCTAssertEqual(try TranscriptCopyRequest.parse("2 out.txt"), TranscriptCopyRequest(index: 2, path: "out.txt"))
        XCTAssertEqual(try TranscriptCopyRequest.parse("3   my notes/reply one.md "), TranscriptCopyRequest(index: 3, path: "my notes/reply one.md"))
        XCTAssertEqual(try TranscriptCopyRequest.parse("notes about 2"), TranscriptCopyRequest(index: 1, path: "notes about 2"))
        XCTAssertEqual(try TranscriptCopyRequest.parse("-1"), TranscriptCopyRequest(index: 1, path: "-1"), "Not an unsigned count, so a file name")
        XCTAssertEqual(try TranscriptCopyRequest.parse("99999999999999999999999"), TranscriptCopyRequest(index: 1, path: "99999999999999999999999"))
        XCTAssertThrowsError(try TranscriptCopyRequest.parse("0")) { error in
            XCTAssertEqual(error.localizedDescription, "Usage: /copy [N] [file] where N is 1 (latest), 2, 3, ...")
        }
        XCTAssertThrowsError(try TranscriptCopyRequest.parse("0 out.txt"))
    }

    func testCopyCountsAssistantBlocksNewestFirstAndNeverCopiesOtherKinds() {
        func pick(_ index: Int, _ messages: [Message]) -> String {
            switch TranscriptCopyRequest.select(index, from: messages) {
            case .success(let text): return text
            case .failure(let error): return "error: " + (error.errorDescription ?? "")
            }
        }
        XCTAssertEqual(pick(1, Self.sample), "Here is $x^2$ and a [link](https://x.ai).")
        XCTAssertEqual(pick(2, Self.sample), "Second reply", "A reply split by a tool call counts twice")
        XCTAssertEqual(pick(3, Self.sample), "First reply")
        XCTAssertEqual(pick(4, Self.sample), "error: Only 3 assistant messages available to copy")
        XCTAssertEqual(pick(2, [Message(kind: .assistant, text: "only")]), "error: Only 1 assistant message available to copy")
        XCTAssertEqual(pick(1, [Message(kind: .user, text: "hi"), Message(kind: .thought, text: "hmm")]), "error: No assistant messages to copy")
        XCTAssertEqual(pick(1, [Message(kind: .assistant, text: "")]), "error: Assistant message is empty")
    }

    func testClipboardStatsCountBytesAndLinesLikeTheTerminal() {
        XCTAssertEqual(TranscriptClipboard.statsSuffix("one"), " (3 chars, 1 line)")
        XCTAssertEqual(TranscriptClipboard.statsSuffix("a\nb\n"), " (4 chars, 2 lines)")
        XCTAssertEqual(TranscriptClipboard.statsSuffix("a\n\nb"), " (4 chars, 3 lines)")
        XCTAssertEqual(TranscriptClipboard.statsSuffix(""), " (0 chars, 0 lines)")
        XCTAssertEqual(TranscriptClipboard.statsSuffix("é"), " (2 chars, 1 line)", "chars is the UTF-8 byte count")
    }

    func testBackupAndDisplayPaths() {
        let home = "/Users/tester"
        let defaultGrok = URL(fileURLWithPath: home + "/.crok")
        XCTAssertEqual(TranscriptClipboard.backupURL(environment: [:], grokHome: defaultGrok).path, home + "/.crok/last-copy.txt")
        XCTAssertEqual(TranscriptClipboard.backupURL(environment: ["CROK_COPY_FILE": "  /tmp/copy.txt "], grokHome: defaultGrok).path, "/tmp/copy.txt")
        XCTAssertEqual(TranscriptClipboard.backupURL(environment: ["CROK_COPY_FILE": " "], grokHome: defaultGrok).path, home + "/.crok/last-copy.txt")
        XCTAssertEqual(TranscriptClipboard.displayPath(defaultGrok.appendingPathComponent("last-copy.txt"), grokHome: defaultGrok, home: home), "~/.crok/last-copy.txt")
        let relocated = URL(fileURLWithPath: "/Volumes/data/grok")
        XCTAssertEqual(TranscriptClipboard.displayPath(relocated.appendingPathComponent("last-copy.txt"), grokHome: relocated, home: home), "$CROK_HOME/last-copy.txt")
        XCTAssertEqual(TranscriptClipboard.displayPath(URL(fileURLWithPath: home + "/notes/a.md"), grokHome: defaultGrok, home: home), "~/notes/a.md")
        XCTAssertEqual(TranscriptClipboard.displayPath(URL(fileURLWithPath: "/tmp/a.md"), grokHome: defaultGrok, home: home), "/tmp/a.md")
        XCTAssertEqual(TranscriptClipboard.resolve("out/reply.md", relativeTo: "/work/app").path, "/work/app/out/reply.md")
        XCTAssertEqual(TranscriptClipboard.resolve("/abs/reply.md", relativeTo: "/work/app").path, "/abs/reply.md")
        XCTAssertEqual(TranscriptClipboard.resolve("~/reply.md", relativeTo: "/work/app").path, NSHomeDirectory() + "/reply.md")
    }

    func testCopyToFileWritesAPrivateFileBesideTheProject() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.copy("2 exports/second reply.md")
        await finish(tools)
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent("exports/second reply.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Second reply")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(store.banner, "Copied to \(url.path) (12 chars, 1 line)")

        // An existing, wider file is tightened too.
        try "old".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        tools.copy("1 exports/second reply.md")
        await finish(tools)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Here is $x^2$ and a [link](https://x.ai).")
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
    }

    func testCopyToClipboardAlsoWritesTheBackupFile() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.copy("")
        await finish(tools)
        let latest = "Here is $x^2$ and a [link](https://x.ai)."
        XCTAssertEqual(pasteboard.string(forType: .string), latest)
        let backup = grokHome.appendingPathComponent("last-copy.txt")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), latest)
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertEqual(store.banner, "Copied to clipboard (also saved to \(TranscriptClipboard.displayPath(backup, grokHome: grokHome)))\(TranscriptClipboard.statsSuffix(latest))")

        let custom = directory.appendingPathComponent("custom/copy.txt")
        tools.environment = ["CROK_COPY_FILE": custom.path]
        tools.copy("3")
        await finish(tools)
        XCTAssertEqual(pasteboard.string(forType: .string), "First reply")
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "First reply")

        tools.copy("0")
        XCTAssertEqual(store.banner, TranscriptCopyRequest.usage)
        tools.copy("9")
        XCTAssertEqual(store.banner, "Only 3 assistant messages available to copy")
    }

    // MARK: /export

    func testLocalExportMatchesTheTerminalFormat() {
        let expected = """
        ## User

        Render the tables
        with borders

        ## Assistant

        First reply

        ## Tools

        - Read: Sources/App.swift

        ## Assistant

        Second reply

        ## User

           \n\n  Now add **math**  \n\n## Assistant

        Here is $x^2$ and a [link](https://x.ai).
        """
        XCTAssertEqual(TranscriptMarkdownExport.render(Self.sample), expected)
        XCTAssertEqual(TranscriptMarkdownExport.render([]), "")
        XCTAssertEqual(TranscriptMarkdownExport.render([Message(kind: .thought, text: "x"), Message(kind: .system, text: "y")]), "")
    }

    func testReasoningBetweenRepliesKeepsOneAssistantHeader() {
        let messages = [Message(kind: .user, text: "q"), Message(kind: .assistant, text: "a"), Message(kind: .thought, text: "t"),
                        Message(kind: .assistant, text: "b"), Message(kind: .tool, text: "Execute `swift test`"), Message(kind: .tool, text: "grep_pattern")]
        XCTAssertEqual(TranscriptMarkdownExport.render(messages), "## User\n\nq\n\n## Assistant\n\na\n\nb\n\n## Tools\n\n- Execute: swift test\n- Tool: grep_pattern")
    }

    func testToolSummariesRecoverTheTerminalShapes() {
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("Read `a.swift`"), "Read: a.swift")
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("Edit `a.swift`"), "Edit: a.swift")
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("Execute `ls -la`"), "Execute: ls -la")
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("List `src`"), "ListDir: src")
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("Web search: \"swift regex\""), "WebSearch: swift regex")
        XCTAssertEqual(TranscriptMarkdownExport.toolSummary("Updating plan"), "Tool: Updating plan")
    }

    func testExportUsesTheCLIAndFallsBackToTheLocalRenderer() async throws {
        let script = directory.appendingPathComponent("fake-grok")
        try """
        #!/bin/sh
        if [ "$1" = "export" ] && [ "$2" = "session-ok" ]; then printf '## User\\n\\nfrom the cli\\n\\n## Assistant\\n\\nexported\\n'; exit 0; fi
        echo "Error: Session '$2' not found." >&2; exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let (store, tools) = try makeFixture(messages: Self.sample, sessionID: "session-ok", binary: script.path)
        tools.export("transcripts/today.md")
        await finish(tools)
        let file = URL(fileURLWithPath: projectPath).appendingPathComponent("transcripts/today.md")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "## User\n\nfrom the cli\n\n## Assistant\n\nexported")
        XCTAssertEqual(store.banner, "Conversation exported to \(file.path)")

        tools.export("")
        await finish(tools)
        let markdown = "## User\n\nfrom the cli\n\n## Assistant\n\nexported"
        XCTAssertEqual(pasteboard.string(forType: .string), markdown)
        XCTAssertEqual(store.banner, "Conversation copied to clipboard (also saved to \(TranscriptClipboard.displayPath(grokHome.appendingPathComponent("last-copy.txt"), grokHome: grokHome)))\(TranscriptClipboard.statsSuffix(markdown))")

        // An unknown session makes the CLI fail; the same format is rendered locally.
        store.state.conversations[0].sessionID = "session-missing"
        let fallback = await tools.exportMarkdown(for: store.state.conversations[0].id)
        XCTAssertEqual(fallback.source, .local)
        XCTAssertEqual(fallback.markdown, TranscriptMarkdownExport.render(Self.sample))
    }

    func testExportMessagesForEmptyAndMissingConversations() async throws {
        let (store, tools) = try makeFixture(messages: [Message(kind: .thought, text: "only reasoning")])
        tools.export("")
        await finish(tools)
        XCTAssertEqual(store.banner, "No conversation content to export")
        store.state.selectedConversationID = nil
        tools.export("x.md")
        XCTAssertEqual(store.banner, "No active session to export")
        tools.openTranscriptWindow()
        XCTAssertEqual(store.banner, "No conversation transcript to view yet")
        XCTAssertNil(store.windowRequest)
    }

    func testExportReportsWriteFailures() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        let blocker = URL(fileURLWithPath: projectPath).appendingPathComponent("blocker")
        try "file".write(to: blocker, atomically: true, encoding: .utf8)
        tools.export("blocker/inside/out.md")
        await finish(tools)
        XCTAssertEqual(store.banner, "Failed to create directory: Not a directory (os error 20)")
    }

    func testTranscriptDocumentSplitsExportSections() {
        let sections = TranscriptDocumentSection.parse(TranscriptMarkdownExport.render(Self.sample))
        XCTAssertEqual(sections.map(\.kind), [.user, .assistant, .tools, .assistant, .user, .assistant])
        XCTAssertEqual(sections[0].body, "Render the tables\nwith borders")
        XCTAssertEqual(sections[2].body, "- Read: Sources/App.swift")
        // A heading-like line inside a paragraph is not a section break.
        let quoted = TranscriptDocumentSection.parse("## Assistant\n\nsee this:\n## User\nstays")
        XCTAssertEqual(quoted.count, 1)
        XCTAssertEqual(TranscriptWindow.fileName(for: "Fix a/b: tests"), "Fix a-b- tests.md")
        XCTAssertEqual(TranscriptWindow.fileName(for: "  "), "transcript.md")
    }

    func testTranscriptWindowLoadsTheSelectedTask() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.openTranscriptWindow()
        XCTAssertEqual(store.windowRequest, .transcript)
        await finish(tools)
        guard case .loaded(let document) = tools.document else { return XCTFail("Expected a loaded transcript, got \(tools.document)") }
        XCTAssertEqual(document.markdown, TranscriptMarkdownExport.render(Self.sample))
        XCTAssertEqual(document.title, "Render tables")
        XCTAssertEqual(document.source, .local)
    }

    // MARK: /find

    func testFindUsesSmartCaseRegularExpressions() {
        XCTAssertEqual(TranscriptSearchMatcher("reply").count(in: "Reply, reply, REPLY"), 3)
        XCTAssertEqual(TranscriptSearchMatcher("Reply").count(in: "Reply, reply, REPLY"), 1, "An uppercase letter makes the search case-sensitive")
        XCTAssertEqual(TranscriptSearchMatcher("re.ly").count(in: "reply rely"), 1)
        XCTAssertEqual(TranscriptSearchMatcher(#"\d+"#).count(in: "a1 b22 c"), 2)
        XCTAssertEqual(TranscriptSearchMatcher("a*").count(in: "bbb"), 0, "Empty matches never count")
        let invalid = TranscriptSearchMatcher("(unclosed")
        XCTAssertTrue(invalid.isInvalid)
        XCTAssertEqual(invalid.count(in: "(unclosed"), 0)
        XCTAssertFalse(TranscriptSearchMatcher("").isInvalid)
    }

    func testFindCountsEveryOccurrenceAcrossMessagesInOrder() {
        let documents = Self.sample.map(TranscriptSearchDocument.make)
        let result = TranscriptSearch.run(query: "reply", documents: documents)
        XCTAssertEqual(result.matches.map(\.messageID), [Self.sample[2].id, Self.sample[4].id])
        XCTAssertEqual(TranscriptSearch.run(query: "table", documents: documents).matches.count, 2, "Prompt and reasoning both count")
        XCTAssertEqual(TranscriptSearch.run(query: "struct App", documents: documents).matches.map(\.messageID), [Self.sample[3].id], "Tool output is searched")
        XCTAssertEqual(TranscriptSearch.run(query: "\\*\\*", documents: documents).matches.map(\.messageID), [Self.sample[5].id, Self.sample[5].id], "Markdown markup is not searched, prompts are")
        XCTAssertEqual(TranscriptSearch.run(query: "https", documents: documents).matches.count, 0, "Link targets are not shown, so not found")
        XCTAssertTrue(TranscriptSearch.run(query: "[", documents: documents).isInvalid)
        XCTAssertEqual(TranscriptSearch.step(nil, by: 1, count: 3), 0)
        XCTAssertEqual(TranscriptSearch.step(2, by: 1, count: 3), 0, "Next wraps past the end")
        XCTAssertEqual(TranscriptSearch.step(0, by: -1, count: 3), 2, "Previous wraps past the front")
        XCTAssertNil(TranscriptSearch.step(0, by: 1, count: 0))
    }

    func testPlainTextStripsMarkdown() {
        let markdown = """
        # Title ##
        Some **bold**, *italic*, `code`, ~~old~~ and [a link](https://x.ai) with snake_case_name.
        > quoted
        - [x] done item
        1. first
        | a | b |
        |---|:-:|
        | 1 | 2 |
        ```swift
        let **x** = 1
        ```
        ---
        ![alt text](image.png)
        """
        XCTAssertEqual(TranscriptPlainText.strip(markdown), """
        Title
        Some bold, italic, code, old and a link with snake_case_name.
        quoted
        done item
        first
        a\tb
        1\t2
        let **x** = 1
        alt text
        """)
    }

    func testFindBarNavigatesMatchesAndRevealsFoldedBlocks() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.openFind("table")
        XCTAssertTrue(tools.findPresented)
        try await eventually { tools.findMatches.count == 2 }
        XCTAssertEqual(tools.findCursor, 0)
        XCTAssertEqual(tools.findStatus, "1 of 2")
        XCTAssertEqual(tools.currentFindMessageID, Self.sample[0].id)
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[0].id))
        XCTAssertEqual(tools.highlight(for: Self.sample[0].id), .match)

        tools.submitFind(backwards: false)
        XCTAssertEqual(tools.currentFindMessageID, Self.sample[1].id)
        XCTAssertTrue(tools.isExpanded(Self.sample[1].id), "A match in folded reasoning opens it")
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[1].id))
        tools.submitFind(backwards: false)
        XCTAssertEqual(tools.findCursor, 0, "Wraps to the first match")
        tools.submitFind(backwards: true)
        XCTAssertEqual(tools.findStatus, "2 of 2")

        tools.findQuery = "("
        try await eventually { tools.findInvalid }
        XCTAssertEqual(tools.findStatus, "Invalid pattern")
        XCTAssertTrue(tools.findMatches.isEmpty)
        tools.findQuery = "nothing like this"
        try await eventually { !tools.findInvalid && tools.findStatus == "No matches" }

        tools.findQuery = ""
        tools.submitFind(backwards: false)
        XCTAssertFalse(tools.findPresented, "Return on an empty query closes the bar")

        store.state.selectedConversationID = nil
        tools.openFind("x")
        XCTAssertEqual(store.banner, "No conversation to search yet")
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    // MARK: /jump and the timeline

    func testTurnPreviewsFollowTheTerminal() {
        XCTAssertEqual(TranscriptTurns.preview("  \n\n  first line  \nsecond"), "first line")
        XCTAssertEqual(TranscriptTurns.preview("\r\n  windows line\r\n"), "windows line")
        XCTAssertEqual(TranscriptTurns.preview(""), "")
        XCTAssertEqual(TranscriptTurns.preview("\n\n\n"), "")
        XCTAssertEqual(TranscriptTurns.preview(String(repeating: " ", count: 5_000) + "\nlate line"), "late line")
        XCTAssertEqual(TranscriptTurns.preview(String(repeating: "x", count: 9_000)).unicodeScalars.count, 120)
        let long = String(repeating: "a", count: 130)
        let preview = TranscriptTurns.preview(long)
        XCTAssertEqual(preview.unicodeScalars.count, 120)
        XCTAssertEqual(preview, String(repeating: "a", count: 119) + "…")
        XCTAssertEqual(TranscriptTurns.preview(String(repeating: "b", count: 120)), String(repeating: "b", count: 120), "Exactly at the cap is kept whole")

        let turns = TranscriptTurns.list(Self.sample + [Message(kind: .user, text: "  \n ")])
        XCTAssertEqual(turns.map(\.number), [1, 2, 3])
        XCTAssertEqual(turns.map(\.messageIndex), [0, 5, 8])
        XCTAssertEqual(turns.map(\.displayPreview), ["Render the tables", "Now add **math**", "(no preview)"])
        XCTAssertEqual(TranscriptTurns.turn(containing: 4, in: turns), 0)
        XCTAssertEqual(TranscriptTurns.turn(containing: 5, in: turns), 1)
        XCTAssertEqual(TranscriptTurns.turn(containing: 7, in: turns), 1)
    }

    func testJumpPreviewsTurnsAndRestoresOnCancel() throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.isFollowingOutput = false
        tools.visibleMessagesChanged(topIndex: 3, topID: Self.sample[3].id)
        tools.openJump()
        XCTAssertEqual(store.sheet, .jump)
        let state = try XCTUnwrap(tools.jump)
        XCTAssertEqual(state.turns.count, 2)
        XCTAssertEqual(state.selected, 0, "Starts at the turn on screen")
        tools.moveJump(to: 1)
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[5].id), "Moving the cursor scrolls live")
        tools.cancelJump()
        XCTAssertNil(tools.jump)
        XCTAssertNil(store.sheet)
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[3].id), "Esc restores where the reader was")

        tools.isFollowingOutput = true
        tools.openJump()
        tools.moveJump(to: 0)
        tools.cancelJump()
        XCTAssertEqual(tools.scrollRequest?.target, .bottom, "A reader who was following output goes back to the end")

        tools.openJump()
        tools.moveJump(to: 1)
        tools.commitJump()
        XCTAssertNil(store.sheet)
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[5].id))

        store.state.conversations[0].messages = Array(Self.sample.prefix(4))
        tools.openJump()
        XCTAssertEqual(store.banner, "Nothing to jump to yet")
        XCTAssertNil(tools.jump)
    }

    func testTimelineTicksFollowConversationOrder() {
        let turns = TranscriptTurns.list(Self.sample)
        let ticks = TranscriptTimelineLayout.ticks(messages: Self.sample, turns: turns, expanded: [], compact: false)
        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks[0].position, 0)
        XCTAssertGreaterThan(ticks[1].position, 0.4)
        XCTAssertLessThan(ticks[1].position, 1)
        let opened = TranscriptTimelineLayout.ticks(messages: Self.sample, turns: turns, expanded: [Self.sample[1].id, Self.sample[3].id], compact: false)
        XCTAssertGreaterThan(opened[1].position, ticks[1].position, "Open blocks push later turns down")
    }

    // MARK: Preferences

    func testDisplayPreferencesPersistToConfigAndDefaults() throws {
        let (store, tools) = try makeFixture()
        let config = directory.appendingPathComponent("config.toml")
        try "# Crok settings\n[ui]\ntheme = \"grokday\"\n\n[models]\ndefault = \"grok-4\"\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertTrue(tools.showTimestamps, "Timestamps default to on")
        XCTAssertFalse(tools.showTimeline)
        XCTAssertFalse(tools.vimMode)

        tools.toggleTimestamps()
        XCTAssertEqual(store.banner, "✓ Timestamps: off")
        tools.toggleTimeline()
        XCTAssertEqual(store.banner, "✓ Timeline sidebar: on")
        tools.toggleVimMode()
        XCTAssertEqual(store.banner, "Vim mode: on")
        tools.waitForConfigWrites()

        let saved = GrokConfig(url: config)
        XCTAssertEqual(saved.bool("show_timestamps", in: "ui"), false)
        XCTAssertEqual(saved.bool("show_timeline", in: "ui"), true)
        XCTAssertEqual(saved.bool("vim_mode", in: "ui"), true)
        XCTAssertEqual(saved.string("theme", in: "ui"), "grokday")
        XCTAssertEqual(saved.string("default", in: "models"), "grok-4")
        XCTAssertTrue(saved.text.hasPrefix("# Crok settings\n[ui]\ntheme = \"grokday\""))
        XCTAssertEqual(defaults.object(forKey: "showTimestamps") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "showTimeline") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "transcriptVimMode") as? Bool, true)

        // A fresh model reads the mirror at once.
        let reopened = TranscriptToolsModel(store: store, defaults: defaults, configURL: config)
        XCTAssertFalse(reopened.showTimestamps)
        XCTAssertTrue(reopened.showTimeline)
        XCTAssertTrue(reopened.vimMode)
    }

    func testPreferencesAdoptChangesMadeInTheTerminal() async throws {
        let (_, tools) = try makeFixture()
        let config = directory.appendingPathComponent("config.toml")
        try "[ui]\nshow_timestamps = false\nshow_timeline = true\n".write(to: config, atomically: true, encoding: .utf8)
        tools.loadPreferencesIfNeeded()
        await tools.pendingWork?.value
        XCTAssertFalse(tools.showTimestamps)
        XCTAssertTrue(tools.showTimeline)
        XCTAssertFalse(tools.vimMode, "Absent keys keep their current value")
        XCTAssertEqual(defaults.object(forKey: "showTimeline") as? Bool, true)
    }

    // MARK: /expand and vim keys

    func testExpandWalksBackThroughFoldedBlocks() throws {
        let messages = Self.sample + [Message(kind: .tool, text: "Execute `true`", status: "completed")]
        let (store, tools) = try makeFixture(messages: messages)
        tools.expandNext()
        XCTAssertTrue(tools.isExpanded(messages[3].id), "The newest tool block with output opens first")
        XCTAssertEqual(tools.scrollRequest?.target, .message(messages[3].id))
        tools.expandNext()
        XCTAssertTrue(tools.isExpanded(messages[1].id))
        tools.expandNext()
        XCTAssertEqual(store.banner, "Nothing left to expand")
        tools.setExpanded(messages[3].id, false)
        tools.expandNext()
        XCTAssertTrue(tools.isExpanded(messages[3].id), "A block closed again is the newest folded one")
    }

    func testVimKeysMoveTheCursorAndCopy() async throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        XCTAssertFalse(tools.handleVimKey(.down), "Keys pass through while vim mode is off")
        tools.setVimMode(true)
        tools.visibleMessagesChanged(topIndex: 2, topID: Self.sample[2].id)
        tools.handleVimKey(.down)
        XCTAssertEqual(tools.vimFocusID, Self.sample[2].id, "The cursor starts at the top of the view")
        tools.handleVimKey(.down)
        XCTAssertEqual(tools.vimFocusID, Self.sample[3].id)
        XCTAssertEqual(tools.highlight(for: Self.sample[3].id), .focus)
        tools.handleVimKey(.up); tools.handleVimKey(.up); tools.handleVimKey(.up); tools.handleVimKey(.up)
        XCTAssertEqual(tools.vimFocusID, Self.sample[0].id, "k stops at the first message")
        tools.handleVimKey(.bottom)
        XCTAssertEqual(tools.vimFocusID, Self.sample.last?.id)
        XCTAssertEqual(tools.scrollRequest?.target, .bottom)
        tools.handleVimKey(.top)
        XCTAssertEqual(tools.scrollRequest?.target, .message(Self.sample[0].id))
        tools.handleVimKey(.yank)
        await finish(tools)
        XCTAssertEqual(pasteboard.string(forType: .string), "Render the tables\nwith borders")
        XCTAssertEqual(store.banner, "Copied to clipboard")
        XCTAssertTrue(tools.handleVimKey(.escape))
        XCTAssertNil(tools.vimFocusID)
        XCTAssertFalse(tools.handleVimKey(.escape), "Esc with nothing focused reaches the rest of the app")
        tools.setVimMode(false)
        XCTAssertEqual(store.banner, "Vim mode: off")
    }

    // MARK: /history

    func testPromptHistoryParsingAndRanking() {
        XCTAssertEqual(TranscriptPromptHistory.prompts(from: ["prompts": ["b", "a", "b", "  ", 3]]), ["b", "a"])
        XCTAssertEqual(TranscriptPromptHistory.prompts(from: ["result": ["prompts": ["wrapped"]]]), ["wrapped"])
        XCTAssertEqual(TranscriptPromptHistory.prompts(from: [:]), [])

        let prompts = ["refactor the parser", "fix the flaky test", "add a timeline rail", "Fix login", "explain fixtures"]
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "").map(\.text), prompts, "No query keeps recency order")
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "fix").map(\.text), ["fix the flaky test", "Fix login", "explain fixtures"],
                       "Word-start matches first, then recency; smart case")
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "Fix").map(\.text), ["Fix login"])
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "tmln").map(\.text), ["add a timeline rail"], "Letters in order match fuzzily")
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "flaky fix").map(\.text), ["fix the flaky test"], "Every word must match")
        XCTAssertEqual(TranscriptPromptHistory.rank(prompts, query: "fix").first?.highlights, [0, 1, 2])
        XCTAssertEqual(TranscriptPromptHistory.rank((0..<300).map { "prompt \($0)" }, query: "prompt").count, 100)
    }

    func testHistoryComesFromTheHarnessAndFallsBackToThisTask() async throws {
        let fixture = try makeHarness(historyFails: false)
        let (store, tools) = try makeFixture(messages: Self.sample, binary: fixture.path)
        tools.openHistory()
        XCTAssertEqual(store.sheet, .history)
        await finish(tools)
        XCTAssertEqual(tools.history.prompts, ["fix the flaky test", "add a timeline", "explain the export format"])
        XCTAssertNil(tools.history.notice)
        let request = try XCTUnwrap(requests(fixture).first { $0["method"] as? String == "_x.ai/prompt_history" })
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, projectPath)
        XCTAssertNil(params["filter_session_id"], "All tasks in the project")
        XCTAssertTrue(store.auxiliaryClients.isEmpty, "The short-lived connection is closed")

        tools.insertHistory("add a timeline")
        XCTAssertEqual(store.draft, "add a timeline")
        XCTAssertNil(store.sheet)

        let failing = try makeHarness(historyFails: true)
        // The model holds its store weakly, so the test keeps this one alive.
        let (fallbackStore, fallback) = try makeFixture(messages: Self.sample, binary: failing.path)
        fallback.openHistory()
        await finish(fallback)
        XCTAssertEqual(fallbackStore.sheet, .history)
        XCTAssertEqual(fallback.history.prompts, ["   \n\n  Now add **math**  ", "Render the tables\nwith borders"])
        XCTAssertTrue(fallback.history.notice?.hasPrefix("Prompt history is unavailable") == true)
    }

    private func makeHarness(historyFails: Bool) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        let folder = directory.appendingPathComponent("harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).components(separatedBy: "if __name__ == \"__main__\":")[0]
            .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let harness = """
        class TranscriptHarness(MockHarness):
            def handle(self, message):
                with open(os.path.join(os.path.dirname(__file__), "requests.jsonl"), "a") as log:
                    log.write(json.dumps(message) + "\\n")
                if message.get("method") == "_x.ai/prompt_history":
                    if \(historyFails ? "True" : "False"):
                        self.error(message["id"], -32601, "Method not found")
                    else:
                        self.result(message["id"], {"prompts": ["fix the flaky test", "add a timeline", "fix the flaky test", "  ", "explain the export format"]})
                    return
                super().handle(message)
        TranscriptHarness().run()
        """
        let executable = folder.appendingPathComponent("fixture-grok")
        try (source + harness).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func requests(_ executable: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("requests.jsonl")) else { return [] }
        return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    // MARK: /debug

    func testDebugTogglesAndScrollLog() throws {
        let (store, tools) = try makeFixture(messages: Self.sample)
        tools.debug("")
        XCTAssertEqual(store.banner, "debug toggles: scroll off · fps off · log off. Toggle with /debug <scroll|fps|log>")
        tools.debug("scroll")
        tools.debug("fps")
        XCTAssertTrue(tools.debugScroll)
        XCTAssertTrue(tools.debugFPS)
        tools.debug("verbose")
        XCTAssertEqual(store.banner, "Unknown /debug option 'verbose'. Usage: /debug [scroll|fps|log]")

        tools.debug("log")
        let url = try XCTUnwrap(tools.scrollLogURL)
        XCTAssertEqual(store.banner, "scroll log: recording to \(url.path)")
        XCTAssertEqual(url.deletingLastPathComponent().path, grokHome.appendingPathComponent("logs").path)
        XCTAssertNotNil(url.lastPathComponent.range(of: #"^scroll-log-\d{8}-\d{6}\.jsonl$"#, options: .regularExpression))
        tools.recordScroll(TranscriptScrollSample(offsetY: 120, contentHeight: 4_000, viewportHeight: 700))
        tools.recordScrollPhase("interacting")
        XCTAssertEqual(tools.debugHUD.scroll?.offsetY, 120)
        tools.debug("")
        XCTAssertEqual(store.banner, "debug toggles: scroll on · fps on · log on. Toggle with /debug <scroll|fps|log>")
        tools.debug("log")
        XCTAssertEqual(store.banner, "scroll log: off")
        XCTAssertNil(tools.scrollLogURL)

        let deadline = Date().addingTimeInterval(3)
        var lines: [[String: Any]] = []
        while Date() < deadline {
            let data = (try? Data(contentsOf: url)) ?? Data()
            lines = data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            if lines.count >= 3 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(lines.map { $0["evt"] as? String }, ["start", "scroll", "phase"])
        XCTAssertEqual(lines[1]["offset_y"] as? Double, 120)
        XCTAssertNotNil(lines[2]["ts_ms"] as? Int)
    }

    func testFrameStatsFormatting() {
        XCTAssertEqual(TranscriptDebugFormat.frameLine([]), "fps:- p50:- p95:-")
        XCTAssertEqual(TranscriptDebugFormat.frameLine([16, 16, 16, 20]), "fps:59 p50:16.0ms p95:19.4ms")
        XCTAssertEqual(TranscriptDebugFormat.percentile([1, 2, 3, 4], 50), 2.5)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(TranscriptDebugFormat.scrollLogURL(grokHome: URL(fileURLWithPath: "/g"), date: date).path, "/g/logs/scroll-log-20260921-141320.jsonl")
    }

    func testTimestampTooltipMatchesTheTerminal() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3; components.hour = 15; components.minute = 7; components.second = 12
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(TranscriptTimestamp.tooltip(date), "15:07:12 | Sep 03")
        XCTAssertFalse(TranscriptTimestamp.label(date).isEmpty)
    }

    func testMessageRowsCompareTheirDisplayState() {
        let message = Self.sample[1]
        XCTAssertEqual(MessageView(message: message), MessageView(message: message))
        XCTAssertNotEqual(MessageView(message: message, isExpanded: true), MessageView(message: message, isExpanded: false))
        XCTAssertNotEqual(MessageView(message: message, highlight: .match), MessageView(message: message))
        XCTAssertNotEqual(MessageView(message: message, timestamp: Date()), MessageView(message: message))
    }
}
