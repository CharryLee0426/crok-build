import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Renders the extension panels and the remember sheet, loaded from the offline harness, when
/// GROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class ExtensionSnapshotTests: XCTestCase {
    private func output() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["GROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set GROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        return URL(fileURLWithPath: path)
    }

    /// Hosts the view, lets its tasks finish, then draws it in light and dark.
    private func render<V: View>(_ name: String, _ view: V, size: CGSize, store: AppStore, settle: @escaping () -> Bool = { true }) async throws {
        let directory = try output()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.desktopEnvironment(store).background(Theme.canvas))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            // A first draw makes the view appear, which starts its `.task` before we wait on it.
            host.layoutSubtreeIfNeeded()
            if let warmup = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: warmup) }
            let deadline = Date().addingTimeInterval(6)
            try await Task.sleep(nanoseconds: 300_000_000)
            while (!settle() || store.featureLoading) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 350_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            window.contentView = nil
        }
    }

    private func browser(_ panel: FeaturePanel, fixture: ExtensionHarnessFixture, height: CGFloat = 760, width: CGFloat = 720,
                         showAddMCP: Bool = false, creatingPersona: Bool = false, expandSkillSources: Bool = false, settle: @escaping () -> Bool = { true }) async throws {
        fixture.store.featurePanel = panel
        await fixture.store.refreshFeatures(panel)
        try await render("panel-\(panel.rawValue)\(showAddMCP || creatingPersona || expandSkillSources ? "-form" : "")",
                         FeatureBrowser(panel: panel, showAddMCP: showAddMCP, creatingPersona: creatingPersona, expandSkillSources: expandSkillSources),
                         size: CGSize(width: width, height: height), store: fixture.store, settle: settle)
    }

    func testRenderMemoryPanel() async throws {
        _ = try output()
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let memory = fixture.store.features.extensions.memory
        fixture.store.featurePanel = .memory
        await memory.load()
        if let topic = memory.listing?.files.first(where: { $0.path.hasSuffix("build-and-test.md") }) { memory.select(topic.path) }
        try await render("panel-memory", FeatureBrowser(panel: .memory), size: CGSize(width: 940, height: 780), store: fixture.store) {
            memory.preview != nil && !memory.loading
        }
        memory.toggle()
        let deadline = Date().addingTimeInterval(5)
        while memory.listing?.enabled != false && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try await render("panel-memory-off", FeatureBrowser(panel: .memory), size: CGSize(width: 940, height: 780), store: fixture.store) { !memory.loading }
    }

    func testRenderRememberSheet() async throws {
        _ = try output()
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        fixture.store.draft = "Inspect the offline fixture"
        fixture.store.send()
        let deadline = Date().addingTimeInterval(8)
        while (fixture.store.run.isRunning || fixture.prompts.isEmpty) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await render("sheet-remember", RememberSheet(initialText: "Release notes go in CHANGELOG.md under Unreleased, one line per user-visible change."),
                         size: CGSize(width: 640, height: 520), store: fixture.store) { !fixture.params(for: "_x.ai/memory/rewrite").isEmpty }
        try await render("sheet-remember-empty", RememberSheet(initialText: ""), size: CGSize(width: 640, height: 520), store: fixture.store)
    }

    func testRenderMarketplaceAndPlugins() async throws {
        _ = try output()
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        try await browser(.marketplace, fixture: fixture, height: 900)
        try await browser(.plugins, fixture: fixture, height: 900)
    }

    func testRenderHooksSkillsWorkflowsAndMCPs() async throws {
        _ = try output()
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        try await browser(.hooks, fixture: fixture, height: 900)
        try await browser(.skills, fixture: fixture, height: 900, expandSkillSources: true)
        try await browser(.workflows, fixture: fixture)
        try await browser(.mcps, fixture: fixture, height: 900, showAddMCP: true)
    }

    func testRenderAgentsAndPersonas() async throws {
        _ = try output()
        let fixture = try ExtensionHarnessFixture()
        defer { fixture.cleanup() }
        let agents = fixture.project.appendingPathComponent(".grok/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "---\nname: release-captain\ndescription: Cuts release branches, bumps versions, and drafts release notes.\n---\nYou ship releases.".write(to: agents.appendingPathComponent("release-captain.md"), atomically: true, encoding: .utf8)
        try AgentConfigWriter.setDefault("release-captain", url: fixture.grokHome.appendingPathComponent("config.toml"))
        try AgentConfigWriter.setEnabled("browser-use", enabled: false, url: fixture.grokHome.appendingPathComponent("config.toml"))
        try PersonaStore.create(name: "security-reviewer", description: "Reviews changes for injection, auth, and secrets handling.", instructions: "Check auth.\n\nFlag secrets.", scope: .project, cwd: fixture.project)
        fixture.store.draft = "Inspect the offline fixture"
        fixture.store.send()
        let deadline = Date().addingTimeInterval(8)
        while (fixture.store.run.isRunning || fixture.prompts.isEmpty) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await browser(.agentDefinitions, fixture: fixture, height: 900)
        try await browser(.personas, fixture: fixture, height: 760)
        try await browser(.personas, fixture: fixture, height: 900, creatingPersona: true)
        let editable = try XCTUnwrap(fixture.store.featureRows.first { $0.payload["editable"] as? Bool == true })
        try await render("panel-personas-edit", ScrollView {
            PersonasPanelView(rows: fixture.store.featureRows, disabled: false, creating: .constant(false), editing: editable.id).padding(24)
        }.frame(width: 720, height: 820).background(Theme.surface), size: CGSize(width: 720, height: 820), store: fixture.store)
    }
}
