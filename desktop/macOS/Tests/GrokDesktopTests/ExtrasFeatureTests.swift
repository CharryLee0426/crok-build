import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Themes, guides, the tutorial, and the command palette's grouped actions.
@MainActor
final class ExtrasFeatureTests: XCTestCase {
    private var directory: URL!
    private var defaultsName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-extras-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "GrokDesktopExtras.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        Theme.apply(.auto)
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var configURL: URL { directory.appendingPathComponent("config.toml") }

    private func makeStore() -> (AppStore, ExtrasFeatureModel) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: "/usr/bin/false")
        let extras = store.features.extras
        extras.themePreferences = GrokThemePreferences(defaults: defaults, configURL: configURL)
        extras.tutorialDefaults = defaults
        return (store, extras)
    }

    // MARK: Theme names

    func testThemeNamesAndAliasesResolveIgnoringCase() {
        let expected: [String: GrokTheme] = [
            "auto": .auto, "SYSTEM": .auto,
            "groknight": .groknight, "Grok-Night": .groknight, "dark": .groknight,
            "grokday": .grokday, "grok-day": .grokday, "light": .grokday, "Day": .grokday,
            "tokyonight": .tokyonight, "tokyo-night": .tokyonight, "tokyo": .tokyonight,
            "rosepine-moon": .rosepineMoon, "rosepine": .rosepineMoon, "rose-pine": .rosepineMoon, "rose-pine-moon": .rosepineMoon,
            "oscura-midnight": .oscuraMidnight, " oscura ": .oscuraMidnight,
        ]
        for (name, theme) in expected { XCTAssertEqual(GrokTheme(name: name), theme, name) }
        XCTAssertNil(GrokTheme(name: "terminal"), "The terminal-native theme has no window equivalent")
        XCTAssertNil(GrokTheme(name: "solarized"))
        XCTAssertEqual(GrokTheme.unknownMessage("solarized"),
                       "Unknown theme: solarized. Available: auto, groknight, grokday, tokyonight, rosepine-moon, oscura-midnight")
    }

    func testBareThemeCyclesLikeTheTerminal() {
        XCTAssertEqual(GrokTheme.next(after: .groknight, systemIsDark: true), .grokday)
        XCTAssertEqual(GrokTheme.next(after: .grokday, systemIsDark: true), .tokyonight)
        XCTAssertEqual(GrokTheme.next(after: .oscuraMidnight, systemIsDark: false), .groknight)
        // Auto counts as the theme it resolves to.
        XCTAssertEqual(GrokTheme.next(after: .auto, systemIsDark: true), .grokday)
        XCTAssertEqual(GrokTheme.next(after: .auto, systemIsDark: false), .tokyonight)
    }

    func testPalettesUseThePagerColours() {
        func hex(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "?" }
            return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
        }
        XCTAssertEqual(hex(ThemePalette.grokNight.canvasNS), "#141414")
        XCTAssertEqual(hex(ThemePalette.grokNight.accentNS), "#BB9AF7")
        XCTAssertEqual(hex(ThemePalette.grokDay.canvasNS), "#EEEEEE")
        XCTAssertEqual(hex(ThemePalette.grokDay.accentNS), "#7D4BC6")
        for theme in GrokTheme.allCases { XCTAssertEqual(ThemePalette.palette(for: theme).theme, theme) }
        XCTAssertTrue(ThemePalette.auto.usesSystemMaterials)
        XCTAssertFalse(ThemePalette.tokyoNight.usesSystemMaterials)
    }

    // MARK: /theme

    func testThemeCommandAppliesPersistsAndCycles() throws {
        try "# mine\n[ui]\nshow_timestamps = false\n\n[models]\ndefault = \"grok-4\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        let (store, extras) = makeStore()
        let revision = extras.themeRevision

        store.executeCommand(name: "t", arguments: "Dark")
        XCTAssertEqual(extras.activeTheme, .groknight)
        XCTAssertEqual(Theme.palette.theme, .groknight)
        XCTAssertEqual(store.banner, "✓ Theme: Crok Night")
        XCTAssertGreaterThan(extras.themeRevision, revision)
        XCTAssertEqual(defaults.string(forKey: "theme"), "groknight")
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        extras.flushThemeWrites()
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8),
                       "# mine\n[ui]\nshow_timestamps = false\ntheme = \"groknight\"\n\n[models]\ndefault = \"grok-4\"\n")

        store.executeCommand(name: "theme", arguments: "solarized")
        XCTAssertEqual(store.banner, GrokTheme.unknownMessage("solarized"))
        XCTAssertEqual(extras.activeTheme, .groknight)

        store.executeCommand(name: "theme", arguments: "")
        XCTAssertEqual(extras.activeTheme, .grokday)
        XCTAssertEqual(store.banner, "✓ Theme: Crok Day")
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")

        store.executeCommand(name: "theme", arguments: "system")
        XCTAssertEqual(extras.activeTheme, .auto)
        XCTAssertEqual(store.banner, "✓ Theme: Auto")
        XCTAssertEqual(defaults.string(forKey: "appearance"), "system")
        extras.flushThemeWrites()
        XCTAssertEqual(GrokConfig(url: configURL).string("theme", in: "ui"), "auto")
    }

    func testPreviewDoesNotSaveAndCancelRestoresAppearance() throws {
        let (_, extras) = makeStore()
        defaults.set("dark", forKey: "appearance")   // chosen before themes existed
        extras.previewTheme(.grokday)
        XCTAssertEqual(Theme.palette.theme, .grokday)
        XCTAssertEqual(extras.previewedTheme, .grokday)
        XCTAssertEqual(extras.activeTheme, .auto)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
        extras.previewTheme(.tokyonight)
        extras.cancelThemePreview()
        XCTAssertEqual(Theme.palette.theme, .auto)
        XCTAssertNil(extras.previewedTheme)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        XCTAssertNil(defaults.string(forKey: "theme"))
        extras.flushThemeWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testUnwritableConfigStillAppliesTheTheme() throws {
        try "ui = { theme = \"groknight\" }\n".write(to: configURL, atomically: true, encoding: .utf8)
        let (store, extras) = makeStore()
        extras.setTheme(.tokyonight)
        extras.flushThemeWrites()
        let expectation = expectation(description: "banner")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(extras.activeTheme, .tokyonight)
        XCTAssertTrue(store.banner?.hasPrefix("✓ Theme: Tokyo Night · not saved to config.toml") == true, store.banner ?? "")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "ui = { theme = \"groknight\" }\n")
    }

    func testSavedThemePrefersTheTerminalsConfig() throws {
        let preferences = GrokThemePreferences(defaults: defaults, configURL: configURL)
        XCTAssertNil(preferences.savedTheme(), "Nothing chosen yet")

        defaults.set("tokyonight", forKey: "theme")
        XCTAssertEqual(preferences.savedTheme(), .tokyonight)

        try "theme = \"oscura\"\n[ui]\nvim_mode = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(preferences.savedTheme(), .oscuraMidnight, "The legacy top-level key is still read")

        try "[ui]\ntheme = \"Rose-Pine\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(preferences.savedTheme(), .rosepineMoon)

        try "[ui]\ntheme = \"terminal\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(preferences.savedTheme(), .tokyonight, "A terminal-only theme falls back to the desktop's choice")
    }

    func testRestoreAtLaunchAppliesTheSavedTheme() throws {
        let preferences = GrokThemePreferences(defaults: defaults, configURL: configURL)
        defaults.set("dark", forKey: "appearance")
        ExtrasFeatureModel.restoreSavedTheme(preferences)
        XCTAssertEqual(Theme.palette.theme, .auto)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark", "Without a saved theme the old appearance choice stays")

        try "[ui]\ntheme = \"grokday\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        ExtrasFeatureModel.restoreSavedTheme(preferences)
        XCTAssertEqual(Theme.palette.theme, .grokday)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
        XCTAssertEqual(defaults.string(forKey: "theme"), "grokday")
        let (_, extras) = makeStore()
        XCTAssertEqual(extras.activeTheme, .grokday)
    }

    func testThemeChangedInTheTerminalIsFollowed() throws {
        let (store, extras) = makeStore()
        func sync() {
            extras.syncThemeFromConfig()
            extras.flushThemeWrites()
            let drained = expectation(description: "main queue")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
        extras.setTheme(.grokday)
        sync()
        XCTAssertEqual(extras.activeTheme, .grokday, "The desktop's own write is not an outside change")

        try "[ui]\ntheme = \"tokyo\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        store.banner = nil
        sync()
        XCTAssertEqual(extras.activeTheme, .tokyonight)
        XCTAssertEqual(Theme.palette.theme, .tokyonight)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        XCTAssertNil(store.banner)

        try "[ui]\ntheme = \"terminal\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        sync()
        XCTAssertEqual(extras.activeTheme, .tokyonight, "A terminal-only theme is ignored")
    }

    // MARK: /docs

    func testDocsTargetsParseLikeTheTerminal() {
        for argument in ["", "  ", "how-to", "HowTo", "guides", "guide", "list", "TUI"] {
            XCTAssertEqual(GuideDocsTarget(arguments: argument), .browse, argument)
        }
        for argument in ["web", "Online", "browser", "site", "www"] {
            XCTAssertEqual(GuideDocsTarget(arguments: argument), .web, argument)
        }
        XCTAssertEqual(GuideDocsTarget(arguments: "getting started"), .guide("01-getting-started.md"))
        XCTAssertEqual(GuideDocsTarget(arguments: "Project Rules (AGENTS.md)"), .guide("12-project-rules.md"))
        XCTAssertEqual(GuideDocsTarget(arguments: "theming"), .guide("06-theming.md"), "A title prefix is enough")
        XCTAssertEqual(GuideDocsTarget(arguments: "Plan Mode"), .guide("19-plan-mode.md"))
        XCTAssertEqual(GuideDocsTarget(arguments: "zebra"), .unknown("zebra"))
        XCTAssertEqual(GuideDocsTarget.unknownMessage("zebra \"x\""),
                       #"Unknown docs target "zebra \"x\"". Try /docs, /docs web, or a guide title (e.g. /docs Getting Started)."#)
    }

    func testDocsCommandOpensTheRightPlace() {
        let (store, extras) = makeStore()
        var opened: [URL] = []
        extras.openURL = { opened.append($0) }

        store.executeCommand(name: "guides", arguments: "web")
        XCTAssertEqual(opened, [URL(string: "https://docs.x.ai/build/overview")!])
        XCTAssertNil(store.windowRequest)

        store.executeCommand(name: "howto", arguments: "Hooks")
        XCTAssertEqual(extras.guideRequest?.fileName, "10-hooks.md")
        XCTAssertEqual(store.windowRequest, .docs)

        store.windowRequest = nil
        store.executeCommand(name: "docs", arguments: "")
        XCTAssertNil(extras.guideRequest?.fileName)
        XCTAssertEqual(store.windowRequest, .docs)

        store.windowRequest = nil
        store.executeCommand(name: "docs", arguments: "zebra")
        XCTAssertNil(store.windowRequest)
        XCTAssertEqual(store.banner, GuideDocsTarget.unknownMessage("zebra"))
    }

    func testGuidesAreDiscoveredInTheTerminalsOrder() throws {
        let guides = directory.appendingPathComponent("home/docs/user-guide", isDirectory: true)
        XCTAssertNil(GuideLibrary.load(from: guides), "A missing folder is reported as such")
        try FileManager.default.createDirectory(at: guides, withIntermediateDirectories: true)
        try "# Theming\n\nUse truecolor.\n".write(to: guides.appendingPathComponent("06-theming.md"), atomically: true, encoding: .utf8)
        try "# Getting Started\n\nHello.\n".write(to: guides.appendingPathComponent("01-getting-started.md"), atomically: true, encoding: .utf8)
        try "# Something New\n\nFrom a newer harness.\n".write(to: guides.appendingPathComponent("30-new.md"), atomically: true, encoding: .utf8)
        try "index".write(to: guides.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "notes".write(to: guides.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GuideLibrary.directory(home: directory.appendingPathComponent("home")).standardizedFileURL, guides.standardizedFileURL)

        let loaded = try XCTUnwrap(GuideLibrary.load(from: guides))
        XCTAssertEqual(loaded.map(\.title), ["Getting Started", "Theming and Appearance", "Something New"])
        XCTAssertEqual(loaded.map(\.fileName), ["01-getting-started.md", "06-theming.md", "30-new.md"])
        XCTAssertEqual(loaded[1].summary, "Themes, color support, pager.toml customization")
    }

    func testGuideSearchCoversTitlesAndText() {
        let guides = [
            GuideDocument(fileName: "01-a.md", title: "Getting Started", summary: "First launch", content: "# Getting Started\nRun `crok` in a repo.\n"),
            GuideDocument(fileName: "02-b.md", title: "Theming", summary: "Themes", content: "# Theming\n\nEnable **truecolor** in tmux.\nTruecolor again.\n"),
            GuideDocument(fileName: "03-c.md", title: "Truecolor Notes", summary: "", content: "# Notes\n"),
        ]
        XCTAssertEqual(GuideLibrary.search("", in: guides).count, 3)
        let hits = GuideLibrary.search("TrueColor", in: guides)
        XCTAssertEqual(hits.map(\.guide.fileName), ["03-c.md", "02-b.md"], "Title matches come first")
        XCTAssertNil(hits[0].snippet)
        XCTAssertEqual(hits[1].snippet, "Enable truecolor in tmux.")
        XCTAssertEqual(hits[1].count, 2)
        XCTAssertTrue(GuideLibrary.search("nowhere", in: guides).isEmpty)
    }

    func testGuideSectionsKeepCodeTogetherAndExposeAnchors() {
        let content = "# Guide\nIntro.\n\n## Harness Compatibility\nText.\n```bash\n# not a heading\n```\n### `[ui]` settings\n#### Deep\nMore.\n"
        let sections = GuideLibrary.sections(of: content)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].anchors, ["guide"])
        XCTAssertEqual(sections[1].anchors, ["harness-compatibility"])
        XCTAssertTrue(sections[1].text.contains("# not a heading"))
        XCTAssertEqual(sections[2].anchors, ["ui-settings", "deep"])
        XCTAssertEqual(GuideLibrary.slug("Permissions & Safety: Modes"), "permissions--safety-modes")
    }

    func testReflowJoinsWrappedLinesButKeepsBlocks() {
        let source = """
        Crok Build is a conversation with an agent that can read your
        code, run commands.

        - **Rules** — `AGENTS.md` and
          `CLAUDE.md` files.
        - Second item
        > A quoted
        > note.
        Hard break\u{20}\u{20}
        next line
        | a | b |
        |---|---|
        ```bash
        echo one
        echo two
        ```
        ## Heading
        Text after.
        """
        XCTAssertEqual(GuideLibrary.reflow(source), """
        Crok Build is a conversation with an agent that can read your code, run commands.

        - **Rules** — `AGENTS.md` and `CLAUDE.md` files.
        - Second item
        > A quoted note.
        Hard break\u{20}\u{20}
        next line
        | a | b |
        |---|---|
        ```bash
        echo one
        echo two
        ```
        ## Heading
        Text after.
        """)
    }

    // MARK: /tutorial

    func testTutorialHasTheNineTopics() {
        let topics = GrokTutorial.topics
        XCTAssertEqual(topics.map(\.title), [
            "Coming from Claude, Cursor, or Codex?", "Your First Prompt", "Attach Files, Images & Paste", "Finding Your Way Around",
            "Slash Commands", "Parallel Work: Worktrees", "Plan Mode & Permissions", "Make It Yours", "Where to Go Next",
        ])
        XCTAssertEqual(Set(topics.map(\.id)).count, 9)
        for topic in topics {
            XCTAssertFalse(topic.blurb.isEmpty, topic.title)
            XCTAssertTrue(topic.content.hasPrefix("# " + topic.title), topic.title)
            XCTAssertFalse(topic.body.hasPrefix("# "), "The page body drops its title: \(topic.title)")
            XCTAssertGreaterThan(topic.body.count, 200, topic.title)
            if let guide = topic.goDeeper {
                XCTAssertEqual(GuideLibrary.entry(matching: guide)?.title, guide, "Go deeper names a real guide")
            }
        }
        XCTAssertNil(topics.last?.goDeeper)
        XCTAssertEqual(topics.filter { $0.desktopNote != nil }.count, 8)
    }

    /// In the repository, the embedded pages must match the terminal's files.
    func testTutorialTextMatchesTheTerminalPages() throws {
        let repository = ProcessInfo.processInfo.environment["CROK_BUILD_REPOSITORY"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        let pages = repository.appendingPathComponent("crates/codegen/xai-grok-pager/docs/tutorial")
        guard FileManager.default.fileExists(atPath: pages.path) else { throw XCTSkip("The pager sources are not next to this package") }
        for topic in GrokTutorial.topics {
            let source = try String(contentsOf: pages.appendingPathComponent(topic.id + ".md"), encoding: .utf8)
            XCTAssertEqual(topic.content, source.trimmingCharacters(in: .newlines), "Regenerate with scripts/gen-tutorial.py: \(topic.id)")
        }
    }

    func testTutorialProgressPersists() {
        let (store, extras) = makeStore()
        extras.markTutorialTopicExplored("02-first-prompt")
        extras.markTutorialTopicExplored("02-first-prompt")
        extras.markTutorialTopicExplored("05-slash-commands")
        XCTAssertEqual(defaults.stringArray(forKey: ExtrasFeatureModel.tutorialProgressKey), ["02-first-prompt", "05-slash-commands"])
        defaults.set(["02-first-prompt", "retired-topic"], forKey: ExtrasFeatureModel.tutorialProgressKey)
        extras.tutorialDefaults = defaults
        XCTAssertEqual(extras.exploredTutorialTopics, ["02-first-prompt"])

        store.executeCommand(name: "tour", arguments: "")
        XCTAssertEqual(store.windowRequest, .tutorial)
        store.windowRequest = nil
        extras.openGuide(title: "Plan Mode")
        XCTAssertEqual(extras.guideRequest?.fileName, "19-plan-mode.md")
        XCTAssertEqual(store.windowRequest, .docs)
    }

    // MARK: /help

    func testPaletteActionsSearchLabelsAndShortcuts() {
        XCTAssertEqual(CommandPaletteAction.matches("").count, CommandPaletteAction.catalog.count)
        XCTAssertEqual(CommandPaletteAction.matches("model").map(\.label), ["Switch Model"])
        XCTAssertEqual(CommandPaletteAction.matches("⌘").map(\.label), ["New Session", "Settings", "Keyboard Shortcuts", "Quit"])
        XCTAssertEqual(CommandPaletteAction.matches("/MCP").map(\.label), ["MCP Servers"])
        XCTAssertEqual(CommandPaletteAction.matches("session").map(\.label),
                       ["New Session", "Delete This Session", "Resume Session", "Rename Session", "Session Info"])
        XCTAssertTrue(CommandPaletteAction.matches("zzz").isEmpty)
    }

    func testPaletteActionsAreGroupedAndRunRealCommands() {
        let groups = CommandPaletteAction.catalog.map(\.group)
        XCTAssertEqual(groups, groups.sorted { CommandPaletteAction.Group.allCases.firstIndex(of: $0)! < CommandPaletteAction.Group.allCases.firstIndex(of: $1)! },
                       "Actions are listed group by group")
        for group in CommandPaletteAction.Group.allCases { XCTAssertTrue(groups.contains(group), group.rawValue) }
        XCTAssertEqual(Set(CommandPaletteAction.catalog.map(\.label)).count, CommandPaletteAction.catalog.count)
        let names = Set(DesktopCommands.catalog.map(\.name))
        for action in CommandPaletteAction.catalog {
            switch action.perform {
            case .command(let name), .prefill(let name): XCTAssertTrue(names.contains(name), "\(action.label) runs /\(name)")
            case .themePicker, .keyboardShortcuts, .editPrompt: break
            }
        }
    }

    func testPaletteThemeAndShortcutEntriesOpenSheets() {
        let (store, extras) = makeStore()
        extras.openThemePicker()
        XCTAssertEqual(store.sheet, .theme)
        extras.openKeyboardShortcuts()
        XCTAssertEqual(store.sheet, .keyboardShortcuts)
        let actions = KeyboardShortcutCatalog.groups.flatMap(\.entries).map(\.action)
        XCTAssertEqual(Set(actions).count, actions.count)
        XCTAssertEqual(KeyboardShortcutCatalog.columns.flatMap { $0 }.count, KeyboardShortcutCatalog.groups.count, "Every group has a column")
    }
}
