import XCTest
@testable import GrokDesktop

/// ACP flows of the extension panels against the offline harness: exact method names, casing, and payloads.
@MainActor
final class ExtensionIntegrationTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    private func startTask(_ fixture: ExtensionHarnessFixture) async throws {
        fixture.store.draft = "Inspect the offline fixture"
        fixture.store.send()
        try await eventually { !fixture.store.run.isRunning && !fixture.prompts.isEmpty }
    }

    // MARK: Memory

    func testMemoryPanelPreviewsAndForgetsWithBlake3OfPreviewedBytes() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, memory = store.features.extensions.memory
        store.featurePanel = .memory
        await store.refreshFeatures(.memory)
        let listing = try XCTUnwrap(memory.listing)
        XCTAssertEqual(listing.files.count, 6)
        XCTAssertEqual(listing.sections().map(\.title), ["Global", "Workspace"])
        XCTAssertEqual(fixture.params(for: "_x.ai/memory/list").last?["sessionId"] as? String, store.conversation?.sessionID)

        let style = try XCTUnwrap(listing.files.first { $0.path.hasSuffix("coding-style.md") })
        memory.select(style.path)
        try await eventually { memory.preview != nil }
        memory.forgetSelected()
        try await eventually { memory.busy == nil && memory.status != nil }
        let forget = try XCTUnwrap(fixture.params(for: "_x.ai/memory/forget").last)
        XCTAssertEqual(forget["path"] as? String, style.path)
        XCTAssertEqual(forget["sessionId"] as? String, store.conversation?.sessionID)
        XCTAssertEqual(forget["expectedContentHash"] as? String, GrokBlake3.hex(Data("## Coding style\n\n- Prefer `rg` over `grep` for searching.\n- Keep functions short and name them after what they return.\n- Swift: no force unwraps on external data.\n".utf8)))
        XCTAssertEqual(memory.status, MemoryStatusLine(text: "Deleted coding-style.md."))
        XCTAssertFalse(memory.listing?.files.contains { $0.path == style.path } ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: style.path))

        let stale = try XCTUnwrap(listing.files.first { $0.path.hasSuffix("changed.md") })
        memory.select(stale.path)
        try await eventually { memory.preview != nil }
        memory.forgetSelected()
        try await eventually { memory.busy == nil && memory.status?.isError == true }
        XCTAssertTrue(memory.status?.text.hasPrefix("This note changed since you opened it.") == true)
        XCTAssertTrue(memory.listing?.files.contains { $0.path == stale.path } == true)

        let index = try XCTUnwrap(listing.files.first { $0.generated })
        XCTAssertFalse(index.isDeletable)

        memory.toggle()
        try await eventually { !memory.toggling && memory.listing?.enabled == false }
        XCTAssertEqual(fixture.params(for: "_x.ai/memory/toggle").last?["enabled"] as? Bool, false)
        XCTAssertEqual(memory.status?.text, "Memory disabled for this session.")
        XCTAssertEqual(memory.listing?.canEnable, true)
        XCTAssertTrue(fixture.prompts.isEmpty, "Memory management never prompts the model")
    }

    func testFlushDreamAndMemoryArgumentsAreNative() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.executeCommand(name: "flush")
        XCTAssertEqual(store.banner, "Open a task to run /flush on its memory.", "No empty task is started for it")
        XCTAssertTrue(store.state.conversations.isEmpty)
        try await startTask(fixture)
        store.executeCommand(name: "flush")
        try await eventually { store.banner == "Memory flushed through turn 3." }
        let flush = try XCTUnwrap(fixture.params(for: "_x.ai/memory/flush").last)
        XCTAssertEqual(flush["session_id"] as? String, store.conversation?.sessionID)
        XCTAssertNil(flush["sessionId"], "memory/flush is snake_case")
        try await eventually { store.features.extensions.memory.busy == nil }
        store.executeCommand(name: "dream")
        try await eventually { store.banner == "Dream merged 4 observations into 2 topics." }
        XCTAssertNotNil(fixture.params(for: "_x.ai/memory/dream").last?["session_id"])
        store.executeCommand(name: "memory", arguments: "status")
        XCTAssertEqual(store.banner, "/memory takes no arguments. Open it, then use the Memory switch to turn memory on or off.")
        XCTAssertNil(store.featurePanel)
        store.executeCommand(name: "mem")
        XCTAssertEqual(store.featurePanel, .memory)
        XCTAssertEqual(fixture.prompts.count, 1, "Only the task's own prompt; memory commands never prompt the model")
    }

    func testRememberEnhanceSendsTaskContextAndSaveStaysLocal() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, extensions = store.features.extensions
        try await startTask(fixture)
        let id = try XCTUnwrap(store.state.selectedConversationID)
        _ = extensions.handle(method: "session/update", params: [:], update: [
            "sessionUpdate": "tool_call", "toolCallId": "read-1", "kind": "read", "title": "Read App.swift",
            "_meta": ["x.ai/tool": ["name": "read_file"]], "locations": [["path": "/repo/Sources/App.swift"]],
        ], conversationID: id)
        XCTAssertTrue(extensions.canEnhanceMemoryNote)
        let rewritten = try await extensions.rewriteMemoryNote("Use the staging script")
        XCTAssertEqual(rewritten, "## Enhanced note\n\nUse the staging script")
        let request = try XCTUnwrap(fixture.params(for: "_x.ai/memory/rewrite").last)
        XCTAssertEqual(request["sessionId"] as? String, store.conversation?.sessionID)
        XCTAssertEqual(request["rawText"] as? String, "Use the staging script")
        XCTAssertEqual(request["contextSummary"] as? String,
                       "CWD: \(fixture.project.path)\nRecent prompts:\n- Inspect the offline fixture\nRecent files:\n- /repo/Sources/App.swift")

        XCTAssertEqual(extensions.memoryNoteMode(home: fixture.grokHome, configURL: fixture.grokHome.appendingPathComponent("config.toml")), .legacy)
        await extensions.saveMemoryNote(rewritten, mode: .legacy, home: fixture.grokHome)
        XCTAssertEqual(store.banner, "Memory note saved")
        XCTAssertEqual(try String(contentsOf: fixture.grokHome.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8), "## Enhanced note\n\nUse the staging script")
        await extensions.saveMemoryNote("   ", mode: .legacy, home: fixture.grokHome)
        XCTAssertEqual(store.banner, "Couldn't save memory note: Please provide a memory note.")
        XCTAssertEqual(fixture.prompts.count, 1, "Remembering never prompts the model")

        store.executeCommand(name: "remember", arguments: "ship it")
        XCTAssertEqual(store.sheet, .remember(text: "ship it"))
    }

    // MARK: Marketplace and plugins

    func testMarketplaceActionsSendTaggedPayloadsAndAnnounceUpdates() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, marketplace = store.features.extensions.marketplace
        store.featurePanel = .marketplace
        await store.refreshFeatures(.marketplace)
        XCTAssertEqual(marketplace.sources.map(\.name), ["grok-official", "team-tools"])
        XCTAssertEqual(marketplace.sources[1].error, "marketplace.json not found in /Users/team/marketplace")
        let plugins = marketplace.sources[0].plugins
        XCTAssertEqual(plugins.map(\.installStatus), ["installed", "update_available", "not_installed"])
        XCTAssertEqual(plugins[0].components, "2 skills \u{b7} 1 agent \u{b7} 1 hook")

        marketplace.perform(.install(source: plugins[2].source, plugin: plugins[2].relativePath), plugin: plugins[2])
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/marketplace/action").count == 1 }
        let install = try XCTUnwrap(fixture.params(for: "_x.ai/marketplace/action").last)
        XCTAssertEqual(install["sessionId"] as? String, store.conversation?.sessionID)
        XCTAssertEqual(install["action"] as? [String: String], ["type": "install", "source_url_or_path": "https://github.com/xai-org/grok-plugins", "plugin_relative_path": "plugins/pdf-tools"])
        XCTAssertEqual((fixture.params(for: "_x.ai/plugins/action").last?["action"] as? [String: Any])?["type"] as? String, "reload", "requiresReload triggers a plugin reload")
        XCTAssertEqual(store.features.extensions.notice?.text, "Installed plugins/pdf-tools")
        XCTAssertEqual(marketplace.sources[0].plugins[2].installStatus, "installed", "The list refreshes after an action")

        let outdated = marketplace.sources[0].plugins[1]
        marketplace.perform(.update(source: outdated.source, plugin: outdated.relativePath), plugin: outdated)
        try await eventually { !store.featureLoading && !fixture.params(for: "_x.ai/plugins/notify-updates").isEmpty }
        let notify = try XCTUnwrap(fixture.params(for: "_x.ai/plugins/notify-updates").last)
        XCTAssertEqual(notify["updates"] as? [[String]], [["release-notes", "2.0.3", "2.1.0"]])

        let installed = marketplace.sources[0].plugins[0]
        marketplace.perform(.uninstall(source: installed.source, plugin: installed.relativePath), plugin: installed)
        try await eventually { !store.featureLoading && store.features.extensions.pendingConfirmation != nil }
        let confirmation = try XCTUnwrap(store.features.extensions.pendingConfirmation)
        XCTAssertEqual(confirmation.message, "code-review provides hooks used by this project. Uninstall anyway?")
        store.features.extensions.pendingConfirmation = nil
        confirmation.run()
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/marketplace/action").count == 4 }
        XCTAssertEqual((fixture.params(for: "_x.ai/marketplace/action").last?["action"] as? [String: Any])?["confirmed"] as? Bool, true)
        XCTAssertEqual(marketplace.sources[0].plugins[0].installStatus, "not_installed")

        marketplace.perform(.addSource(url: "acme/plugins"))
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/marketplace/action").count == 5 }
        XCTAssertEqual(fixture.params(for: "_x.ai/marketplace/action").last?["action"] as? [String: String], ["type": "add_source", "url": "acme/plugins"])
        marketplace.perform(.removeSource(source: "/Users/team/marketplace"))
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/marketplace/action").count == 6 }
        XCTAssertEqual(fixture.params(for: "_x.ai/marketplace/action").last?["action"] as? [String: String], ["type": "remove_source", "source_url_or_path": "/Users/team/marketplace"])
        XCTAssertFalse(marketplace.sources.contains { $0.name == "team-tools" })
        XCTAssertTrue(fixture.prompts.isEmpty)
    }

    func testPluginUninstallConfirmsThenResendsWithConfirmation() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, extensions = store.features.extensions
        store.featurePanel = .plugins
        await store.refreshFeatures(.plugins)
        XCTAssertEqual(store.featureRows.map(\.id), ["user/1a2b3c4d/code-review", "project/5e6f7a8b/team-lint", "user/9c0d1e2f/legacy-helper"])
        XCTAssertEqual(store.featureRows.map { PluginGroupLabel.group($0.payload).label }, ["grok-official", "Project", "User"])
        XCTAssertEqual(store.featureRows[2].enabled, false)

        store.runPluginsAction(.uninstall(pluginID: "user/1a2b3c4d/code-review", confirmed: false))
        try await eventually { extensions.pendingConfirmation != nil && !store.featureLoading }
        let confirmation = try XCTUnwrap(extensions.pendingConfirmation)
        XCTAssertEqual(confirmation.panel, .plugins)
        XCTAssertTrue(confirmation.message.hasSuffix("Uninstalling will remove all of them."))
        XCTAssertEqual((fixture.params(for: "_x.ai/plugins/action").last?["action"] as? [String: Any])?["confirmed"] as? Bool, false)
        extensions.pendingConfirmation = nil
        confirmation.run()
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/plugins/action").count == 3 }
        let actions = fixture.params(for: "_x.ai/plugins/action").compactMap { $0["action"] as? [String: Any] }
        XCTAssertEqual(actions[1]["confirmed"] as? Bool, true)
        XCTAssertEqual(actions[1]["plugin_id"] as? String, "user/1a2b3c4d/code-review")
        XCTAssertEqual(actions[2]["type"] as? String, "reload")
        XCTAssertEqual(extensions.notice?.text, "Uninstalled repo \"code-review\" (2 plugin(s): code-review, triage)")

        store.runPluginsAction(.update(pluginID: nil))
        try await eventually { !store.featureLoading && fixture.params(for: "_x.ai/plugins/action").count == 4 }
        XCTAssertEqual(fixture.params(for: "_x.ai/plugins/action").last?["action"] as? [String: String], ["type": "update"])
        let legacy = store.featureRows[2]
        store.toggleFeature(legacy, panel: .plugins)
        try await eventually { !store.featureLoading && store.featureRows.first { $0.id == legacy.id }?.enabled == true }
        XCTAssertEqual(fixture.params(for: "_x.ai/plugins/action").last?["action"] as? [String: String], ["type": "enable", "plugin_id": "user/9c0d1e2f/legacy-helper"])
        XCTAssertTrue(fixture.prompts.isEmpty)
    }

    // MARK: Hooks, skills, workflows, MCP

    func testHooksTrustBannerLoadErrorsAndSourceToggle() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, extensions = store.features.extensions
        store.featurePanel = .hooks
        await store.refreshFeatures(.hooks)
        XCTAssertEqual(extensions.hooksTrusted, false)
        XCTAssertEqual(extensions.hooksLoadErrors.count, 1)
        let groups = HookSourceGroup.groups(store.featureRows)
        XCTAssertEqual(groups.map(\.label), ["Global hooks", "Project hooks", "Custom: $GROK_HOME/extra-hooks/notify"])
        XCTAssertEqual(groups.map(\.removable), [false, false, true])
        XCTAssertTrue(groups[0].pinned)
        XCTAssertTrue(groups[0].anyEnabled)
        XCTAssertFalse(groups[1].anyEnabled)

        store.runHooksAction(.toggleSource(hookNames: groups[0].hooks.map(\.id), disable: groups[0].anyEnabled))
        try await eventually { !store.featureLoading && !fixture.params(for: "_x.ai/hooks/action").isEmpty }
        let toggle = try XCTUnwrap(fixture.params(for: "_x.ai/hooks/action").last?["action"] as? [String: Any])
        XCTAssertEqual(toggle["type"] as? String, "toggle_source")
        XCTAssertEqual(toggle["disable"] as? Bool, true)
        XCTAssertEqual(toggle["hook_names"] as? [String], ["global/safety:pre_tool_use[0].hooks[0]", "global/safety:session_start[0].hooks[0]"])

        store.runHooksAction(.trust)
        try await eventually { !store.featureLoading && extensions.hooksTrusted == true }
        XCTAssertEqual(fixture.params(for: "_x.ai/hooks/action").last?["action"] as? [String: String], ["type": "trust"])
        XCTAssertTrue(fixture.prompts.isEmpty)
    }

    func testSkillsDiscoverySourcesRemoveAndReset() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store, extensions = store.features.extensions
        store.featurePanel = .skills
        await store.refreshFeatures(.skills)
        let discovery = try XCTUnwrap(extensions.skillsDiscovery)
        XCTAssertEqual(discovery.automatic.map(\.count), [1, 3])
        XCTAssertEqual(discovery.custom.map(\.path), ["/fixture/custom-skills"])
        XCTAssertEqual(discovery.ignored, ["/fixture/old-skills"])
        store.removeSkillPath("/fixture/custom-skills")
        try await eventually { !store.featureLoading && !fixture.params(for: "_x.ai/skills/remove").isEmpty }
        XCTAssertEqual(fixture.params(for: "_x.ai/skills/remove").last?["path"] as? String, "/fixture/custom-skills")
        XCTAssertEqual(fixture.params(for: "_x.ai/skills/remove").last?["cwd"] as? String, fixture.project.path)
        XCTAssertEqual(extensions.notice?.text, "Removed path /fixture/custom-skills. 2 skills remaining.")
        try await eventually { extensions.skillsDiscovery?.custom.isEmpty == true }
        store.resetSkillsConfig()
        try await eventually { !store.featureLoading && !fixture.params(for: "_x.ai/skills/reset").isEmpty }
        XCTAssertEqual(fixture.params(for: "_x.ai/skills/reset").last?["cwd"] as? String, fixture.project.path)
        XCTAssertEqual(extensions.notice?.text, "Custom skills config reset")
    }

    func testWorkflowsCarryWhenToUseSourceAndPath() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.featurePanel = .workflows
        await store.refreshFeatures(.workflows)
        let fix = try XCTUnwrap(store.featureRows.first)
        XCTAssertEqual(fix.title, "fix-ci")
        XCTAssertEqual(fix.payload["when_to_use"] as? String, "A pull request has red checks and you want Grok to diagnose and fix them.")
        XCTAssertEqual(fix.payload["source"] as? String, "project")
        XCTAssertTrue((fix.payload["path"] as? String)?.hasSuffix("/project/.grok/workflows/fix-ci.md") == true)
        store.invokeFeature(fix, panel: .workflows, action: "Use")
        XCTAssertEqual(store.draft, "/workflow fix-ci ")
    }

    func testMCPOneFieldAdd() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store.featurePanel = .mcps
        await store.refreshFeatures(.mcps)
        XCTAssertTrue(store.addMCPServer(urlOrCommand: "https://mcp.linear.app/mcp", name: ""))
        try await eventually { !store.featureLoading && store.featureRows.contains { $0.id == "linear" } }
        let upsert = try XCTUnwrap(fixture.params(for: "_x.ai/mcp/upsert").last)
        XCTAssertEqual(upsert["server_name"] as? String, "linear")
        XCTAssertEqual(upsert["url"] as? String, "https://mcp.linear.app/mcp")
        XCTAssertFalse(store.addMCPServer(urlOrCommand: "  ", name: "x"))
        XCTAssertEqual(store.featureError, "Required: URL / Command")
        XCTAssertTrue(fixture.prompts.isEmpty)
    }

    // MARK: Agents and personas

    func testAgentDefinitionsBadgeActiveAgentListPluginAgentsAndWriteConfig() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let agents = fixture.project.appendingPathComponent(".grok/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "---\nname: release-captain\ndescription: Ships releases\n---\nYou ship releases.".write(to: agents.appendingPathComponent("release-captain.md"), atomically: true, encoding: .utf8)
        let store = fixture.store, extensions = store.features.extensions
        try await startTask(fixture)
        store.featurePanel = .agentDefinitions
        await store.refreshFeatures(.agentDefinitions)
        XCTAssertEqual(extensions.activeAgent, "grok-build")
        XCTAssertEqual(fixture.params(for: "_x.ai/session/info").last?["sessionId"] as? String, store.conversation?.sessionID)
        let rows = store.featureRows
        XCTAssertTrue(rows.contains { $0.id == "bundled:fixture-explorer" })
        let captain = try XCTUnwrap(rows.first { $0.title == "release-captain" })
        XCTAssertEqual(captain.payload["scope"] as? String, "Project")
        let pluginAgent = try XCTUnwrap(rows.first { $0.title == "code-review:reviewer" })
        let available = rows.filter { $0.payload["plugin"] == nil }.map(\.title)

        extensions.toggleDefaultAgent(captain, available: available)
        XCTAssertEqual(extensions.notice?.text, "New sessions will start with 'release-captain'")
        XCTAssertEqual(GrokConfig(url: fixture.grokHome.appendingPathComponent("config.toml")).string("name", in: "agent"), "release-captain")
        extensions.toggleDefaultAgent(captain, available: available)
        XCTAssertEqual(extensions.notice?.text, "Cleared: new sessions use 'grok-build-plan'")
        extensions.toggleDefaultAgent(pluginAgent, available: available)
        XCTAssertEqual(extensions.notice?.text, "Plugin agents can't be the session default — they are spawned as subagents via the Task tool.")

        let explore = try XCTUnwrap(rows.first { $0.title == "explore" })
        store.toggleFeature(explore, panel: .agentDefinitions)
        XCTAssertEqual(extensions.notice?.text, "Disabled 'explore' — applies to new sessions")
        XCTAssertEqual(store.featureRows.first { $0.title == "explore" }?.enabled, false)
        XCTAssertEqual(GrokConfig(url: fixture.grokHome.appendingPathComponent("config.toml")).bool("explore", in: "subagents.toggle"), false)

        store.invokeFeature(captain, panel: .agentDefinitions, action: "Inspect")
        try await eventually { store.featureRows.first { $0.id == captain.id }?.payload["content"] as? String == "---\nname: release-captain\ndescription: Ships releases\n---\nYou ship releases." }
        XCTAssertTrue(fixture.params(for: "_x.ai/bundle/entry/get").isEmpty, "Local definitions are read from disk")
        XCTAssertEqual(fixture.prompts.count, 1)
    }

    func testPersonasMergeBundledAndLocalFiles() async throws {
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        try PersonaStore.create(name: "security-reviewer", description: "Finds risky code", instructions: "Check auth.", scope: .project, cwd: fixture.project)
        try PersonaStore.create(name: "fixture-researcher", description: "Shadowed by the bundled persona", instructions: "", scope: .user, cwd: fixture.project)
        let store = fixture.store
        await store.refreshFeatures(.personas)
        XCTAssertEqual(store.featureRows.map(\.title), ["fixture-researcher", "security-reviewer"])
        XCTAssertEqual(store.featureRows[0].detail, "Investigate offline fixture data")
        XCTAssertEqual(store.featureRows[1].payload["editable"] as? Bool, true)
        XCTAssertEqual(store.featureRows[1].subtitle, "Project")
        XCTAssertNil(store.conversation, "Browsing personas never starts a session")
    }
}
