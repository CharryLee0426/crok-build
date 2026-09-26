import XCTest
@testable import GrokDesktop

/// Pure logic behind /memory, /remember, /config-agents, /personas, and the extension panels.
final class ExtensionFeatureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-extension-unit-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: Memory notes

    func testNoteNormalizationMatchesTheMemoryStore() {
        XCTAssertEqual(MemoryNoteStore.normalize("   "), "")
        XCTAssertEqual(MemoryNoteStore.normalize("  Use rg, not grep  "), "## Use rg, not grep")
        XCTAssertEqual(MemoryNoteStore.normalize("# Mine\nkeep"), "# Mine\nkeep")
        XCTAssertEqual(MemoryNoteStore.normalize("### Deep"), "### Deep")
        XCTAssertEqual(MemoryNoteStore.normalize("Deploys\n\n  Use the staging script first.  "), "## Deploys\n\nUse the staging script first.")
        XCTAssertEqual(MemoryNoteStore.normalize("Title\r\nBody"), "## Title\n\nBody", "CRLF splits at the newline like the terminal")
        let long = String(repeating: "x", count: 81)
        XCTAssertEqual(MemoryNoteStore.normalize("\(long)\nrest"), "## Note\n\n\(long)\nrest")
        let exactly = String(repeating: "y", count: 80)
        XCTAssertEqual(MemoryNoteStore.normalize("\(exactly)\nrest"), "## \(exactly)\n\nrest")
        // The 80 limit counts UTF-8 bytes: 27 three-byte characters are 81 bytes.
        let wide = String(repeating: "界", count: 27)
        XCTAssertEqual(MemoryNoteStore.normalize("\(wide)\nrest"), "## Note\n\n\(wide)\nrest")
    }

    func testLegacySaveAppendsToGlobalMemoryFile() throws {
        let file = try MemoryNoteStore.save("First note", mode: .legacy, home: directory)
        XCTAssertEqual(file, directory.appendingPathComponent("memory/MEMORY.md"))
        try MemoryNoteStore.save("Second\nwith body", mode: .legacy, home: directory)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "## First note\n\n## Second\n\nwith body")
        XCTAssertThrowsError(try MemoryNoteStore.save(" \n ", mode: .legacy, home: directory)) { error in
            XCTAssertEqual(error.localizedDescription, "Please provide a memory note.")
        }
    }

    func testV2SavePublishesAnImmutableInboxObservation() throws {
        let file = try MemoryNoteStore.save("Prefer small PRs", mode: .v2, home: directory)
        let inbox = directory.appendingPathComponent("memory-v2/global/observations/_inbox")
        XCTAssertEqual(file.deletingLastPathComponent().path, inbox.path)
        XCTAssertNotNil(file.lastPathComponent.range(of: #"^remember-[A-Za-z0-9]{6}\.md$"#, options: .regularExpression), file.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "## Prefer small PRs")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(names.count, 1, "The temporary file is removed after publishing: \(names)")
        for scope in ["topics", "archive"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory-v2/global/\(scope)").path))
        }
        XCTAssertThrowsError(try MemoryNoteStore.save(String(repeating: "a", count: 70_000), mode: .v2, home: directory)) { error in
            XCTAssertEqual(error.localizedDescription, "memory observation is 70003 bytes, exceeding the 65536-byte limit")
        }
    }

    func testV2SaveRefusesSymlinkedScope() throws {
        let elsewhere = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("memory-v2"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("memory-v2/global"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try MemoryNoteStore.save("note", mode: .v2, home: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testMemoryModeComesFromListingThenConfigThenDisk() throws {
        XCTAssertEqual(MemoryNoteStore.mode(forListedPaths: [directory.appendingPathComponent("memory-v2/global/MEMORY.md").path], home: directory), .v2)
        XCTAssertEqual(MemoryNoteStore.mode(forListedPaths: [directory.appendingPathComponent("memory/MEMORY.md").path], home: directory), .legacy)
        XCTAssertNil(MemoryNoteStore.mode(forListedPaths: ["/elsewhere/MEMORY.md"], home: directory))
        let config = directory.appendingPathComponent("config.toml")
        XCTAssertEqual(MemoryNoteStore.inferMode(home: directory, config: GrokConfig(url: config)), .legacy)
        try "[memory_v2]\nenabled = true\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(MemoryNoteStore.inferMode(home: directory, config: GrokConfig(url: config)), .v2)
        try "[memory_v2]\nenabled = false\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(MemoryNoteStore.inferMode(home: directory, config: GrokConfig(url: config)), .legacy)
        let state = directory.appendingPathComponent("memory-v2/global/memory_state.sqlite")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: state)
        XCTAssertEqual(MemoryNoteStore.inferMode(home: directory, config: GrokConfig(text: "", url: config)), .v2)
    }

    func testRememberContextMatchesTheTerminalSummary() {
        let prompts = ["one", "two", "three", "four", "five", "six", String(repeating: "p", count: 250)]
        let files = ["a.swift", "b.swift", "a.swift"] + (0..<25).map { "f\($0).swift" }
        let summary = RememberContext.summary(cwd: "/repo", branch: "main", prompts: prompts, files: files)
        let lines = summary.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(8)), ["CWD: /repo", "Branch: main", "Recent prompts:", "- three", "- four", "- five", "- six", "- " + String(repeating: "p", count: 200) + "..."])
        XCTAssertEqual(lines[8], "Recent files:")
        XCTAssertEqual(lines[9], "- f24.swift")
        XCTAssertEqual(lines.count, 8 + 1 + 20)
        XCTAssertEqual(RememberContext.summary(cwd: "/repo", branch: nil, prompts: [], files: []), "CWD: /repo")
        XCTAssertEqual(RememberContext.summary(cwd: "/r", branch: nil, prompts: [], files: ["x", "y", "x"]), "CWD: /r\nRecent files:\n- x\n- y")
    }

    func testPromptTruncationEndsOnACharacterBoundary() {
        let text = String(repeating: "a", count: 199) + "界界界"
        XCTAssertEqual(RememberContext.truncatePrompt(text), String(repeating: "a", count: 199) + "...")
        XCTAssertEqual(RememberContext.truncatePrompt("short"), "short")
    }

    func testToolFilePathsComeFromReadEditAndListTools() {
        XCTAssertEqual(RememberContext.toolFilePath(["_meta": ["x.ai/tool": ["name": "read_file"]], "locations": [["path": "/r/a.swift"]]]), "/r/a.swift")
        XCTAssertEqual(RememberContext.toolFilePath(["_meta": ["x.ai/tool": ["name": "list_dir"]], "rawInput": ["target_directory": "/r/src"]]), "/r/src")
        XCTAssertNil(RememberContext.toolFilePath(["_meta": ["x.ai/tool": ["name": "bash"]], "locations": [["path": "/r"]]]))
        XCTAssertEqual(RememberContext.toolFilePath(["kind": "edit", "rawInput": ["file_path": "/r/b.swift"]]), "/r/b.swift")
        XCTAssertNil(RememberContext.toolFilePath(["kind": "execute", "rawInput": ["path": "/r"]]))
    }

    // MARK: Memory panel data

    func testMemoryListingGroupsLabelsAndDeletability() {
        let listing = MemoryListing([
            "files": [
                ["path": "/m/memory-v2/global/MEMORY.md", "source": "global", "size_bytes": 10, "generated": true],
                ["path": "/m/memory-v2/global/topics/style.md", "source": "global", "size_bytes": 20],
                ["path": "/m/memory-v2/ws/observations/_inbox/s__t000038-000040__n001.md", "source": "workspace", "size_bytes": 5],
                ["path": "/m/memory/ws/sessions/2026-01-01-a.md", "source": "session", "size_bytes": 5],
                ["path": "/m/memory/ws/sessions/2026-01-02-b.md", "source": "session", "size_bytes": 300_000],
                ["path": "/m/memory/MEMORY.md", "source": "global", "size_bytes": 5, "title": "  Curated  "],
            ],
            "enabled": true, "capture_enabled": false, "dream_enabled": true,
        ])
        XCTAssertEqual(listing.sections().map(\.title), ["Global", "Workspace", "Sessions"])
        XCTAssertEqual(listing.sections().last?.files.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["2026-01-02-b.md", "2026-01-01-a.md"], "Newest session log first")
        let files = listing.files
        XCTAssertFalse(files[0].isDeletable, "Generated index")
        XCTAssertTrue(files[1].isDeletable)
        XCTAssertEqual(files[2].label, "observation, turns 38\u{2013}40 (#2)")
        XCTAssertTrue(files[2].isDeletable)
        XCTAssertTrue(files[3].isDeletable)
        XCTAssertFalse(files[4].isDeletable, "Over the 256 KiB forget limit")
        XCTAssertFalse(files[5].isDeletable, "Legacy MEMORY.md is user content, not a topic or observation")
        XCTAssertEqual(files[5].label, "Curated")
        XCTAssertEqual(files[3].scopeLabel, "session logs")
        XCTAssertEqual(files[1].scopeLabel, "global memory")
        XCTAssertEqual(MemoryFileItem.observationLabel("s__t000007-000007__n000.md"), "observation, turn 7 (#1)")
        XCTAssertEqual(listing.sections(matching: "style").flatMap(\.files).count, 1)
        XCTAssertEqual(listing.sections(matching: "session").flatMap(\.files).count, 2, "The scope name matches")
        XCTAssertEqual(listing.sections(matching: "deploy", contents: ["/m/memory/MEMORY.md": "how to deploy"]).flatMap(\.files).map(\.label), ["Curated"])
    }

    @MainActor
    func testMemoryKeyboardNavigationAndSessionModePrecedence() {
        // Paths point into a temporary GROK_HOME so previews never read the real ~/.grok.
        let saved = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", directory.path, 1)
        defer { if let saved { setenv("GROK_HOME", saved, 1) } else { unsetenv("GROK_HOME") } }
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let memory = MemoryPanelModel(store: store)
        let id = UUID()
        let home = directory.path
        memory.apply(MemoryListing(files: [
            MemoryFileItem(path: home + "/memory/MEMORY.md", source: "global", sizeBytes: 1),
            MemoryFileItem(path: home + "/memory/ws/MEMORY.md", source: "workspace", sizeBytes: 1),
            MemoryFileItem(path: home + "/memory/ws/sessions/a.md", source: "session", sizeBytes: 1),
        ]), conversationID: id)
        XCTAssertEqual(memory.selection, home + "/memory/MEMORY.md")
        memory.moveSelection(by: 1, filter: "")
        XCTAssertEqual(memory.selection, home + "/memory/ws/MEMORY.md")
        memory.moveSelection(by: 5, filter: "")
        XCTAssertEqual(memory.selection, home + "/memory/ws/sessions/a.md")
        memory.moveSelection(by: -1, filter: "workspace")
        XCTAssertEqual(memory.selection, home + "/memory/ws/MEMORY.md")
        XCTAssertEqual(memory.mode(for: id), .legacy, "Learned from where the listed files live")
        memory.recordSessionMode("v2", conversationID: id)
        memory.apply(MemoryListing(files: [MemoryFileItem(path: home + "/memory/MEMORY.md", source: "global", sizeBytes: 1)]), conversationID: id)
        XCTAssertEqual(memory.mode(for: id), .v2, "The session's own mode wins over inference")
    }

    func testMemoryToggleAvailabilityFollowsDisabledReason() {
        XCTAssertTrue(MemoryListing(["enabled": false, "disabled_reason": "session_toggle"]).canEnable)
        XCTAssertTrue(MemoryListing(["enabled": false, "disabled_reason": "config_opt_out"]).canEnable)
        XCTAssertTrue(MemoryListing(["enabled": false]).canEnable)
        for reason in ["process_disabled", "rollout_restricted", "not_configured", "something_new"] {
            XCTAssertFalse(MemoryListing(["enabled": false, "disabled_reason": reason]).canEnable, reason)
            XCTAssertFalse(MemoryDisabledExplanation.text(reason).detail.isEmpty)
        }
        XCTAssertEqual(MemoryDisabledExplanation.text("process_disabled").title, "Memory is off for this process.")
        XCTAssertEqual(MemoryDisabledExplanation.emptyState(captureEnabled: false, dreamEnabled: false), ["/remember <note> saves something specific right now."])
    }

    func testMaintenanceSummariesUseTheShellWording() {
        XCTAssertEqual(MemoryMaintenanceSummary.flush(["flushed": true, "disposition": "flushed", "through_turn": 3]).text, "Memory flushed through turn 3.")
        XCTAssertEqual(MemoryMaintenanceSummary.flush(["flushed": true, "disposition": "flushed"]).text, "Memory flushed.")
        XCTAssertEqual(MemoryMaintenanceSummary.flush(["flushed": false, "disposition": "disabled"]).text, "Memory is turned off for this session.")
        XCTAssertEqual(MemoryMaintenanceSummary.dream(["disposition": "completed", "observation_count": 1, "topics_affected": 2]).text, "Dream merged 1 observation into 2 topics.")
        XCTAssertEqual(MemoryMaintenanceSummary.dream(["disposition": "no_work", "observation_count": 0, "topics_affected": 0]).text, "Nothing to consolidate.")
        XCTAssertEqual(MemoryMaintenanceSummary.dream(["disposition": "busy"]).text, "Dream is already running; try again when it finishes.")
        XCTAssertFalse(MemoryMaintenanceSummary.dream(["disposition": "busy"]).succeeded)
    }

    func testPreviewReadHashesExactlyTheShownBytes() throws {
        let note = directory.appendingPathComponent("note.md")
        try Data("## Käse\n".utf8).write(to: note)
        XCTAssertEqual(MemoryNoteRead.read(note.path), .text("## Käse\n", hash: GrokBlake3.hex(Data("## Käse\n".utf8))))
        XCTAssertEqual(MemoryNoteRead.read(note.path, limit: 4), .tooLarge)
        try Data([0xFF, 0xFE]).write(to: note)
        XCTAssertEqual(MemoryNoteRead.read(note.path), .unreadable)
        XCTAssertEqual(MemoryNoteRead.read(directory.appendingPathComponent("missing.md").path), .unreadable)
    }

    // MARK: Personas

    func testPersonaCreateWritesTheTerminalTemplate() throws {
        let cwd = directory.appendingPathComponent("repo")
        let url = try PersonaStore.create(name: "Security Reviewer!", description: " Finds risky code ", instructions: "Check auth.\n\nThen \"inputs\" and C:\\paths.", scope: .project, cwd: cwd, home: directory)
        XCTAssertEqual(url.path, cwd.appendingPathComponent(".grok/personas/Security-Reviewer-.toml").path)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("description = \"Finds risky code\"\ninstructions = \"\"\"\n"), text)
        let fields = try XCTUnwrap(PersonaStore.read(url))
        XCTAssertEqual(fields.name, "Security-Reviewer-")
        XCTAssertEqual(fields.description, "Finds risky code")
        XCTAssertEqual(fields.instructions, "Check auth.\n\nThen \"inputs\" and C:\\paths.")
        XCTAssertThrowsError(try PersonaStore.create(name: "Security Reviewer!", description: "", instructions: "", scope: .project, cwd: cwd, home: directory)) {
            XCTAssertEqual($0.localizedDescription, "Persona 'Security-Reviewer-' already exists")
        }
        XCTAssertThrowsError(try PersonaStore.create(name: "  ", description: "", instructions: "", scope: .user, cwd: cwd, home: directory)) {
            XCTAssertEqual($0.localizedDescription, "Name is required")
        }
        XCTAssertThrowsError(try PersonaStore.create(name: "!!!", description: "", instructions: "", scope: .user, cwd: cwd, home: directory)) {
            XCTAssertEqual($0.localizedDescription, "Name must contain at least one alphanumeric character")
        }
        let user = try PersonaStore.create(name: "writer", description: "", instructions: "", scope: .user, cwd: cwd, home: directory)
        XCTAssertEqual(user.path, directory.appendingPathComponent("personas/writer.toml").path)
        XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), "")
    }

    func testPersonaEditsKeepOtherContentAndRemoveEmptyFields() throws {
        let url = directory.appendingPathComponent("personas/reviewer.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Reviewer persona
        description = "Reviews code" # short
        model = 'grok-code'
        instructions = '''
        Look for bugs.
        Be kind.'''

        [[inputs]]
        name = "diff"
        io_type = "file"
        """.write(to: url, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(PersonaStore.read(url))
        XCTAssertEqual(original.name, "reviewer")
        XCTAssertEqual(original.model, "grok-code")
        XCTAssertEqual(original.description, "Reviews code")
        XCTAssertEqual(original.instructions, "Look for bugs.\nBe kind.")
        XCTAssertTrue(original.hasInputs)
        XCTAssertFalse(original.hasOutputs)
        var edited = original
        edited.model = ""
        edited.reasoningEffort = "high"
        edited.instructions = "Look for bugs.\nBe \"kind\"."
        try PersonaStore.update(url, from: original, to: edited)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Reviewer persona\ndescription = \"Reviews code\" # short\n"), text)
        XCTAssertFalse(text.contains("model ="))
        XCTAssertTrue(text.contains("[[inputs]]\nname = \"diff\""))
        let reread = try XCTUnwrap(PersonaStore.read(url))
        XCTAssertEqual(reread.reasoningEffort, "high")
        XCTAssertEqual(reread.instructions, "Look for bugs.\nBe \"kind\".")
        XCTAssertEqual(reread.model, "")
        XCTAssertTrue(reread.hasInputs)
        let insertion = try XCTUnwrap(text.range(of: "reasoning_effort = \"high\""))
        XCTAssertLessThan(insertion.lowerBound, try XCTUnwrap(text.range(of: "[[inputs]]")).lowerBound, "New keys stay at the top level")
    }

    func testPersonaDeletionIsLimitedToUserAndProjectFiles() throws {
        let user = try PersonaStore.create(name: "mine", description: "d", instructions: "", scope: .user, cwd: directory, home: directory)
        let bundled = directory.appendingPathComponent("bundled/personas/theirs.toml")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "description = \"x\"".write(to: bundled, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PersonaStore.delete(bundled.path, home: directory)) { XCTAssertEqual($0.localizedDescription, "Cannot delete bundled personas") }
        let stray = directory.appendingPathComponent("stray.toml")
        try "x = 1".write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PersonaStore.delete(stray.path, home: directory)) { XCTAssertEqual($0.localizedDescription, "Persona file is not in a known personas directory") }
        XCTAssertTrue(PersonaStore.isDeletable(user.path, home: directory))
        try PersonaStore.delete(user.path, home: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.path))
        let project = try PersonaStore.create(name: "team", description: "", instructions: "", scope: .project, cwd: directory.appendingPathComponent("repo"), home: directory)
        XCTAssertTrue(PersonaStore.isDeletable(project.path, home: directory))
    }

    func testTOMLStringDecoding() {
        XCTAssertEqual(PersonaTOML.decode(#""a\tb\u00e9""#), "a\tb\u{e9}")
        XCTAssertEqual(PersonaTOML.decode("'raw\\n'"), "raw\\n")
        XCTAssertEqual(PersonaTOML.decode("\"\"\"\nline one \\\n   continued\"\"\""), "line one continued")
        XCTAssertEqual(PersonaTOML.decode("\"x\" # comment"), "x")
        XCTAssertNil(PersonaTOML.decode("42"))
        XCTAssertEqual(PersonaTOML.encode("one\ntwo"), "\"\"\"\none\ntwo\"\"\"")
        XCTAssertEqual(PersonaTOML.decode(PersonaTOML.encode("ends with quote \"\n\"")), "ends with quote \"\n\"")
    }

    // MARK: Agent definitions

    func testAgentDiscoveryFollowsHarnessPriority() throws {
        let home = directory.appendingPathComponent("home"), grokHome = directory.appendingPathComponent("grok")
        let repo = directory.appendingPathComponent("repo"), nested = repo.appendingPathComponent("app/sub")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        func agent(_ folder: URL, _ file: String, _ name: String, _ description: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \"\(description)\"\ntools: [read]\n---\nPrompt body".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try agent(nested.appendingPathComponent(".grok/agents"), "near.md", "release-captain", "Nearest project definition")
        try agent(repo.appendingPathComponent(".claude/agents"), "far.md", "release-captain", "Shadowed by the nearer directory")
        try agent(repo.appendingPathComponent(".grok/agents"), "explore.md", "explore", "Project explore shadows the built-in")
        try agent(grokHome.appendingPathComponent("agents"), "plan.md", "plan", "User plan must not shadow the built-in")
        try agent(grokHome.appendingPathComponent("agents"), "grok-build.md", "grok-build", "User override of the main agent")
        try agent(home.appendingPathComponent(".claude/agents"), "writer.md", "writer", "Claude-compatible agent")
        try agent(grokHome.appendingPathComponent("bundled/agents"), "bundled.md", "bundled-helper", "Bundled")
        try "no front matter".write(to: grokHome.appendingPathComponent("agents/broken.md"), atomically: true, encoding: .utf8)
        let entries = AgentCatalog.entries(cwd: nested, home: home, grokHome: grokHome, bundledNames: ["bundled-helper", "catalog-only"], pluginAgents: [("tools", "reviewer")])
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byName["release-captain"]?.description, "Nearest project definition")
        XCTAssertEqual(byName["release-captain"]?.scope, .project)
        XCTAssertEqual(byName["explore"]?.scope, .project)
        XCTAssertEqual(byName["plan"]?.scope, .builtIn)
        XCTAssertEqual(byName["grok-build"]?.scope, .user)
        XCTAssertEqual(byName["writer"]?.scope, .user)
        XCTAssertEqual(byName["bundled-helper"]?.scope, .bundled)
        XCTAssertEqual(byName["bundled-helper"]?.id, "bundled:bundled-helper")
        XCTAssertEqual(byName["catalog-only"]?.id, "bundled:catalog-only")
        XCTAssertEqual(byName["tools:reviewer"]?.pluginName, "tools")
        XCTAssertEqual(entries.filter { $0.name == "release-captain" }.count, 1)
        XCTAssertEqual(Array(entries.prefix(5)).map(\.name), ["grok-build", "general-purpose", "explore", "plan", "browser-use"])
    }

    func testFrontMatterParsing() {
        XCTAssertEqual(AgentCatalog.frontMatter("---\nname: a\ndescription: >\n  folded\n  text\n---\nbody")?.description, "folded text")
        XCTAssertEqual(AgentCatalog.frontMatter("\n---\nname: 'it''s'\n---")?.name, "it's")
        XCTAssertNil(AgentCatalog.frontMatter("name: a"))
        XCTAssertNil(AgentCatalog.frontMatter("---\nname: a\n"))
    }

    func testDefaultAgentAndTogglesAreWrittenToConfig() throws {
        let config = directory.appendingPathComponent("config.toml")
        try "# mine\n[ui]\ntheme = \"grokday\"\n".write(to: config, atomically: true, encoding: .utf8)
        try AgentConfigWriter.setDefault("release-captain", url: config)
        try AgentConfigWriter.setEnabled("explore", enabled: false, url: config)
        try AgentConfigWriter.setEnabled("tools:reviewer", enabled: true, url: config)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("[agent]\nname = \"release-captain\""), text)
        XCTAssertTrue(text.contains("[subagents.toggle]\nexplore = false\n\"tools:reviewer\" = true"), text)
        XCTAssertTrue(text.hasPrefix("# mine\n[ui]\ntheme = \"grokday\"\n"))
        let snapshot = AgentConfigSnapshot.load(url: config)
        XCTAssertEqual(snapshot.configuredDefault, "release-captain")
        XCTAssertEqual(snapshot.toggles, ["explore": false, "tools:reviewer": true])
        XCTAssertFalse(snapshot.isEnabled("explore"))
        XCTAssertTrue(snapshot.isEnabled("plan"))
        try AgentConfigWriter.setDefault(nil, url: config)
        XCTAssertNil(AgentConfigSnapshot.load(url: config).configuredDefault)
        try "[subagents]\ntoggle = { explore = true }\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentConfigWriter.setEnabled("plan", enabled: false, url: config))
    }

    func testResolvedDefaultAgentMatchesHarnessFallbacks() {
        XCTAssertEqual(AgentConfigWriter.resolvedDefault(configured: nil, available: [], environment: [:]), "grok-build-plan")
        XCTAssertEqual(AgentConfigWriter.resolvedDefault(configured: "release-captain", available: ["release-captain"], environment: [:]), "release-captain")
        XCTAssertEqual(AgentConfigWriter.resolvedDefault(configured: "missing", available: [], environment: [:]), "grok-build-plan")
        XCTAssertEqual(AgentConfigWriter.resolvedDefault(configured: nil, available: [], environment: ["GROK_AGENT": "browser_use"]), "browser-use")
        XCTAssertEqual(AgentConfigWriter.resolvedDefault(configured: "codex", available: [], environment: [:]), "codex")
    }

    // MARK: Wire payloads

    func testActionPayloadShapes() throws {
        func json(_ value: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(json(PluginsWireAction.uninstall(pluginID: "user/1/a", confirmed: false).wire), #"{"confirmed":false,"plugin_id":"user\/1\/a","type":"uninstall"}"#)
        XCTAssertEqual(PluginsWireAction.uninstall(pluginID: "x", confirmed: false).confirmed, .uninstall(pluginID: "x", confirmed: true))
        XCTAssertNil(PluginsWireAction.reload.confirmed)
        XCTAssertEqual(json(PluginsWireAction.update(pluginID: nil).wire), #"{"type":"update"}"#)
        XCTAssertEqual(json(PluginsWireAction.update(pluginID: "p").wire), #"{"plugin_id":"p","type":"update"}"#)
        XCTAssertEqual(json(PluginsWireAction.install(source: "owner/repo").wire), #"{"source":"owner\/repo","type":"install"}"#)
        XCTAssertEqual(json(HooksWireAction.toggleSource(hookNames: ["a", "b"], disable: true).wire), #"{"disable":true,"hook_names":["a","b"],"type":"toggle_source"}"#)
        XCTAssertEqual(json(HooksWireAction.disable(hookName: "h").wire), #"{"hook_name":"h","type":"disable"}"#)
        XCTAssertEqual(json(HooksWireAction.add(path: "/p").wire), #"{"path":"\/p","type":"add"}"#)
        XCTAssertEqual(json(MarketplaceWireAction.install(source: "s", plugin: "p").wire), #"{"plugin_relative_path":"p","source_url_or_path":"s","type":"install"}"#)
        XCTAssertEqual(json(MarketplaceWireAction.refresh(source: nil).wire), #"{"type":"refresh"}"#)
        XCTAssertEqual(json(MarketplaceWireAction.addSource(url: "o/r").wire), #"{"type":"add_source","url":"o\/r"}"#)
        XCTAssertEqual(json(MarketplaceWireAction.removeSource(source: "s").wire), #"{"source_url_or_path":"s","type":"remove_source"}"#)
        XCTAssertEqual(MarketplaceWireAction.update(source: "s", plugin: "p").pendingLabel, "Updating...")
    }

    func testActionOutcomeKeepsConfirmationRequests() throws {
        let confirm = try ExtensionActionOutcome.parse(["result": ["status": "confirmation_required", "message": "Sure?", "requiresReload": false, "requiresRestart": false], "error": NSNull()])
        XCTAssertTrue(confirm.needsConfirmation)
        XCTAssertEqual(confirm.message, "Sure?")
        let done = try ExtensionActionOutcome.parse(["status": "success", "message": "ok", "requiresReload": true, "requiresRestart": false])
        XCTAssertTrue(done.succeeded && done.requiresReload)
        XCTAssertThrowsError(try ExtensionActionOutcome.parse(["result": NSNull(), "error": ["message": "boom"]])) { XCTAssertEqual($0.localizedDescription, "boom") }
    }

    func testMCPAddAcceptsURLOrCommandInOneField() {
        XCTAssertEqual(MCPAddRequest.parse(urlOrCommand: "https://mcp.linear.app/mcp", name: ""), MCPAddRequest(name: "linear", url: "https://mcp.linear.app/mcp"))
        XCTAssertEqual(MCPAddRequest.parse(urlOrCommand: "https://example.com/mcp", name: "")?.name, "example")
        XCTAssertEqual(MCPAddRequest.parse(urlOrCommand: "http://www.mcp.io", name: "")?.name, "io")
        XCTAssertEqual(MCPAddRequest.parse(urlOrCommand: "  npx -y @acme/server --root /tmp ", name: " acme "), MCPAddRequest(name: "acme", command: "npx", arguments: ["-y", "@acme/server", "--root", "/tmp"]))
        XCTAssertEqual(MCPAddRequest.parse(urlOrCommand: "uvx files", name: "")?.name, "uvx")
        XCTAssertNil(MCPAddRequest.parse(urlOrCommand: "   ", name: "x"))
        let configuration = MCPAddRequest(name: "a", command: "run", arguments: ["x"]).configuration
        XCTAssertEqual(configuration["command"] as? String, "run")
        XCTAssertEqual(configuration["args"] as? [String], ["x"])
        XCTAssertEqual(configuration["server_name"] as? String, "a")
    }

    func testPanelDataHelpers() {
        let discovery = SkillsDiscovery.parse([
            "paths": ["/custom"], "ignore": ["/old"], "totalSkills": 3,
            "message": "Skill discovery sources:\n  \u{2022} /repo/.grok/skills  (1 skill)\n  \u{2022} ~/.grok/skills  (12 skills)\n\nCustom paths:\n  \u{2022} /custom  (2 skills)\n",
            "skills": [["path": "/custom/a/SKILL.md"], ["path": "/custom/b/SKILL.md"], ["path": "/repo/.grok/skills/c/SKILL.md"]],
        ])
        XCTAssertEqual(discovery.automatic, [.init(path: "/repo/.grok/skills", count: 1), .init(path: "~/.grok/skills", count: 12)])
        XCTAssertEqual(discovery.custom, [.init(path: "/custom", count: 2)])
        XCTAssertEqual(discovery.ignored, ["/old"])

        let grok = URL(fileURLWithPath: "/Users/me/.grok"), home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(HookSourceLabel.describe("/Users/me/.grok/hooks", grokHome: grok, home: home).label, "Global hooks")
        XCTAssertEqual(HookSourceLabel.describe("/Users/me/.grok/installed-plugins/lint/hooks", grokHome: grok, home: home).label, "Plugin: lint")
        XCTAssertEqual(HookSourceLabel.describe("/repo/.grok/plugins/tidy/hooks", grokHome: grok, home: home).label, "Plugin: tidy")
        XCTAssertEqual(HookSourceLabel.describe("/repo/.claude/settings", grokHome: grok, home: home).label, "Claude settings")
        XCTAssertEqual(HookSourceLabel.describe("/repo/.grok/hooks", grokHome: grok, home: home).label, "Project hooks")
        XCTAssertEqual(HookSourceLabel.describe("/Users/me/work/hooks", grokHome: grok, home: home).label, "Custom: ~/work/hooks")
        XCTAssertEqual(HookSourceLabel.event("pre_tool_use"), "Pre-Tool Use")

        XCTAssertEqual(PluginGroupLabel.group(["origin": ["type": "marketplace_install", "source_name": "official"]]).label, "official")
        XCTAssertEqual(PluginGroupLabel.group(["origin": ["type": "marketplace_install"]]).label, "Direct installs")
        XCTAssertEqual(PluginGroupLabel.group(["origin": ["type": "project_claude"]]).label, "Project (Claude)")
        XCTAssertEqual(PluginGroupLabel.group(["scope": "user", "marketplaceSource": "git: acme"]).label, "Direct installs")
        XCTAssertEqual(PluginGroupLabel.badges(["version": "1.0", "skillCount": 1, "agentCount": 2, "hookCount": 0, "mcpServerCount": 1, "hookStatus": "blocked"]),
                       ["v1.0", "1 skill", "2 agents", "1 MCP server", "Hooks blocked"])

        let plugin = MarketplacePluginItem(["name": "x", "relativePath": "plugins/x", "installStatus": "update_available",
            "components": ["skills": [["name": "a"], ["name": "b"]], "mcpServers": [["name": "m"]]]], source: "src")
        XCTAssertEqual(plugin?.components, "2 skills \u{b7} 1 MCP server")
        XCTAssertEqual(plugin?.hasUpdate, true)
        XCTAssertEqual(plugin?.isInstalled, true)
        XCTAssertEqual(ExtensionFilter.disabled.matches(false), true)
        XCTAssertEqual(ExtensionFilter.enabled.matches(nil), true)
    }
}
