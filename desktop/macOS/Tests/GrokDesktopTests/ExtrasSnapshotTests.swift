import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Renders the theme, guides, tutorial, palette, and shortcuts views to PNGs for visual review
/// when GROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class ExtrasSnapshotTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-extras-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Theme.apply(.auto)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore(project: Bool = true) -> AppStore {
        let defaults = UserDefaults(suiteName: "GrokDesktopExtrasSnapshots.\(UUID().uuidString)")!
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: "/nonexistent/grok")
        store.features.extras.themePreferences = GrokThemePreferences(defaults: defaults, configURL: directory.appendingPathComponent("config.toml"))
        store.features.extras.tutorialDefaults = defaults
        guard project else { store.state = DesktopState(); return store }
        let app = Project(path: "/tmp/grok-desktop")
        let now = Date()
        let task = Conversation(projectID: app.id, title: "Theme the desktop app", messages: [
            Message(kind: .user, text: "Match the terminal's themes in the desktop app, and keep the default look for everyone else.", createdAt: now),
            Message(kind: .thought, text: "Read the pager palettes first, then map their roles onto the desktop colours.", createdAt: now),
            Message(kind: .tool, text: "Read crates/codegen/xai-grok-pager-render/src/theme/groknight.rs", status: "completed", createdAt: now),
            Message(kind: .assistant, text: "Done. **Crok Night** now uses the terminal's `#141414` background with the `#bb9af7` accent, and `auto` keeps today's look.\n\n- `/theme` cycles themes\n- `/theme tokyo` applies one by alias\n- Settings shows every theme as a swatch", createdAt: now),
        ], updatedAt: now)
        store.state.projects = [app, Project(path: "/tmp/billing-api")]
        store.state.selectedProjectID = app.id
        store.state.conversations = [task, Conversation(projectID: app.id, title: "Render tables and math", updatedAt: now.addingTimeInterval(-3_600))]
        store.state.selectedConversationID = task.id
        return store
    }

    private func write<V: View>(_ view: V, _ name: String, size: CGSize, dark: Bool) throws {
        try SnapshotRenderer.write(view, size: size, appearance: dark ? .darkAqua : .aqua, to: output.appendingPathComponent(name + ".png"))
    }

    /// Like `SnapshotRenderer.write`, but lets the window settle and clears the banner the
    /// missing harness raises before capturing.
    private func writeSettled<V: View>(_ view: V, store: AppStore, _ name: String, size: CGSize, dark: Bool) throws {
        let host = NSHostingView(rootView: view.background(Theme.canvas))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        store.banner = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    /// The whole window, and (because the split view's floating sidebar is not captured offscreen)
    /// the sidebar beside the conversation.
    func testMainWindowInEachTheme() throws {
        let cases: [(GrokTheme, Bool)] = [(.auto, false), (.auto, true), (.groknight, true), (.grokday, false), (.tokyonight, true), (.rosepineMoon, true), (.oscuraMidnight, true)]
        for (theme, dark) in cases {
            Theme.apply(theme)
            let suffix = "\(theme.rawValue)-\(dark ? "dark" : "light")"
            let store = makeStore()
            try writeSettled(ContentView().desktopEnvironment(store).frame(width: 1100, height: 720), store: store, "main-" + suffix,
                             size: CGSize(width: 1100, height: 720), dark: dark)
            let chrome = HStack(spacing: 0) {
                SidebarView().frame(width: 264)
                Divider()
                ConversationView().frame(maxWidth: .infinity).background(Theme.canvas)
            }.foregroundStyle(Theme.ink).frame(width: 1100, height: 720)
            try writeSettled(chrome.desktopEnvironment(store), store: store, "chrome-" + suffix, size: CGSize(width: 1100, height: 720), dark: dark)
        }
    }

    func testThemeSheet() throws {
        for (theme, dark) in [(GrokTheme.auto, false), (.groknight, true)] {
            Theme.apply(theme)
            let store = makeStore()
            store.features.extras.setTheme(theme)
            try write(ThemeSheet().desktopEnvironment(store).frame(width: 620), "theme-sheet-\(dark ? "dark" : "light")", size: CGSize(width: 620, height: 640), dark: dark)
        }
    }

    func testSettingsAppearanceSection() throws {
        for (theme, dark) in [(GrokTheme.grokday, false), (.tokyonight, true)] {
            Theme.apply(theme)
            let store = makeStore()
            store.features.extras.setTheme(theme)
            let view = AppearanceSettingsSection().settingsCard().padding(24).frame(width: 660).background(Theme.canvas).desktopEnvironment(store)
            try write(view, "settings-appearance-\(dark ? "dark" : "light")", size: CGSize(width: 660, height: 330), dark: dark)
        }
    }

    func testPaletteAndShortcuts() throws {
        for dark in [false, true] {
            let store = makeStore(project: false)
            try write(CommandPalette().desktopEnvironment(store), "palette-\(dark ? "dark" : "light")", size: CGSize(width: 660, height: 560), dark: dark)
            try write(CommandPalette(query: "mo").desktopEnvironment(store), "palette-search-\(dark ? "dark" : "light")", size: CGSize(width: 660, height: 560), dark: dark)
            try write(KeyboardShortcutsSheet().desktopEnvironment(store), "shortcuts-\(dark ? "dark" : "light")", size: CGSize(width: 760, height: 620), dark: dark)
        }
    }

    func testDocsWindow() throws {
        let guides = directory.appendingPathComponent("home/docs/user-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: guides, withIntermediateDirectories: true)
        for entry in GuideLibrary.catalog {
            let text = "# \(entry.title)\n\n\(entry.summary). Crok Build reads `config.toml` from `~/.crok`, and this\nparagraph is wrapped at seventy-five columns the way the real guides are, so\nthe reader has to join the lines.\n\n## Overview\n\nSee [Configuration](05-configuration.md#telemetry) for every key.\n\n```toml\n[ui]\ntheme = \"groknight\"\n```\n\n## Tips\n\n- Run `/theme` to preview themes.\n- Use truecolor terminals for the best colours.\n"
            try text.write(to: guides.appendingPathComponent(entry.fileName), atomically: true, encoding: .utf8)
        }
        for dark in [false, true] {
            let store = makeStore(project: false)
            store.features.extras.guideRequest = .init(fileName: "06-theming.md")
            try write(DocsWindow(directory: guides).desktopEnvironment(store), "docs-\(dark ? "dark" : "light")", size: CGSize(width: 980, height: 680), dark: dark)
        }
        let searching = makeStore(project: false)
        try write(DocsWindow(directory: guides, query: "truecolor").desktopEnvironment(searching), "docs-search-dark", size: CGSize(width: 980, height: 680), dark: true)
        let store = makeStore(project: false)
        try write(DocsWindow(directory: directory.appendingPathComponent("missing")).desktopEnvironment(store), "docs-missing-light",
                  size: CGSize(width: 900, height: 560), dark: false)
    }

    func testTutorialWindow() throws {
        for dark in [false, true] {
            let store = makeStore(project: false)
            store.features.extras.markTutorialTopicExplored("01-coming-from-another-tool")
            try write(TutorialWindow().desktopEnvironment(store), "tutorial-welcome-\(dark ? "dark" : "light")", size: CGSize(width: 820, height: 620), dark: dark)
            try write(TutorialWindow(initialTopic: 1).desktopEnvironment(store), "tutorial-topic-\(dark ? "dark" : "light")", size: CGSize(width: 820, height: 620), dark: dark)
        }
    }
}
