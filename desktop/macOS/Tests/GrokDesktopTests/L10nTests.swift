import Combine
import XCTest
@testable import GrokDesktop

final class L10nTests: XCTestCase {

    override func tearDown() {
        // Restore auto so tests do not bleed into each other.
        L10n.setLanguage(.auto)
        super.tearDown()
    }

    // MARK: AppLanguage.parse

    func testParseNilReturnsAuto() {
        XCTAssertEqual(AppLanguage.parse(nil), .auto)
    }

    func testParseEmptyReturnsAuto() {
        XCTAssertEqual(AppLanguage.parse(""), .auto)
    }

    func testParseAutoStringReturnsAuto() {
        XCTAssertEqual(AppLanguage.parse("auto"), .auto)
    }

    func testParseZhVariants() {
        for raw in ["zh", "zh-Hans", "zh-CN", "zh_CN", "zh-Hant"] {
            XCTAssertEqual(AppLanguage.parse(raw), .zhHans, "Expected .zhHans for \(raw)")
        }
    }

    func testParseKnownCodes() {
        XCTAssertEqual(AppLanguage.parse("en"), .en)
        XCTAssertEqual(AppLanguage.parse("ja"), .ja)
        XCTAssertEqual(AppLanguage.parse("es"), .es)
        XCTAssertEqual(AppLanguage.parse("fr"), .fr)
        XCTAssertEqual(AppLanguage.parse("de"), .de)
    }

    func testParseUnknownCodeReturnsAuto() {
        XCTAssertEqual(AppLanguage.parse("klingon"), .auto)
    }

    // MARK: L10n.t — Chinese

    func testChineseLookup() {
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.t("settings", "Settings"), "设置")
        XCTAssertEqual(L10n.t("done", "Done"), "完成")
        XCTAssertEqual(L10n.t("cancel", "Cancel"), "取消")
        XCTAssertEqual(L10n.t("new_task", "New Task"), "新建任务")
        XCTAssertEqual(L10n.t("good_morning", "Good morning"), "早上好")
    }

    /// The strings from the sidebar, empty state, and composer that were once English in every language.
    func testChineseCoversTheSidebarWelcomeAndComposer() {
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.t("new_task_row", "New task"), "新建任务")
        XCTAssertEqual(L10n.t("search", "Search"), "搜索")
        XCTAssertEqual(L10n.t("commands_row", "Commands"), "命令")
        XCTAssertEqual(L10n.t("skills_tools", "Skills & tools"), "技能与工具")
        XCTAssertEqual(L10n.t("projects", "Projects"), "项目")
        XCTAssertEqual(L10n.t("recents", "Recents"), "最近")
        XCTAssertEqual(L10n.t("archived", "Archived"), "已归档")
        XCTAssertEqual(L10n.t("settings", "Settings"), "设置")
        XCTAssertEqual(L10n.t("starter_explore", "Explore the codebase"), "探索代码库")
        XCTAssertEqual(L10n.t("starter_build", "Build something"), "动手构建")
        XCTAssertEqual(L10n.t("starter_review", "Review changes"), "审查更改")
        XCTAssertEqual(L10n.t("placeholder_new", "Ask Crok to build, fix, or explore anything…"), "让 Crok 构建、修复或探索任何内容…")
        XCTAssertEqual(L10n.t("thinking", "Thinking"), "思考")
        XCTAssertEqual(L10n.reasoningName(id: "high", fallback: "High"), "高")
        XCTAssertEqual(L10n.reasoningName(id: "custom-level", fallback: "Harness name"), "Harness name", "unknown levels keep the harness's name")
        XCTAssertEqual(ComposerPermissionMode.alwaysApprove.title, "始终批准")
        XCTAssertEqual(ComposerFollowUpBehavior.queue.title, "排队")
        XCTAssertEqual(L10n.t("no_repository", "No repository"), "无仓库")
        XCTAssertEqual(L10n.t("show_n_more", "Show %d more", count: 3), "再显示 3 个")
    }

    /// Every language's table has every key the English one has, so no language mixes in English.
    func testEveryLanguageCoversEveryKey() {
        L10n.setLanguage(.en)
        let keys = ["new_task_row", "search", "commands_row", "skills_tools", "projects", "pinned", "recents", "archived",
                    "back_to_projects", "time_now", "time_minutes", "time_days", "good_night", "starter_explore",
                    "placeholder_new", "placeholder_queue", "thinking_level", "effort_high", "effort_xhigh",
                    "mode_always_approve", "mode_auto_detail", "toast_always_approve_on", "followup_steer", "no_repository"]
        let english = keys.map { L10n.t($0, "") }
        for language in AppLanguage.allCases where language != .auto && language != .en {
            L10n.setLanguage(language)
            for (key, en) in zip(keys, english) {
                let value = L10n.t(key, "")
                XCTAssertFalse(value.isEmpty, "\(language) lacks \(key)")
                XCTAssertNotEqual(value, en, "\(language) still shows English for \(key)")
            }
        }
    }

    // MARK: L10n.state

    func testStatePublishesOnlyWhenTheLanguageChanges() {
        L10n.setLanguage(.en)
        var seen: [AppLanguage] = []
        let subscription = L10n.state.$language.dropFirst().sink { seen.append($0) }
        defer { subscription.cancel() }
        L10n.setLanguage(.en)
        XCTAssertEqual(seen, [], "the same choice again is not a change")
        L10n.setLanguage(.ja)
        L10n.setLanguage(.auto)
        XCTAssertEqual(seen, [.ja, .auto])
        XCTAssertEqual(L10n.language, .auto)
    }

    func testLanguageIsTheChoiceNotTheResolvedCode() {
        L10n.setLanguage(.de)
        XCTAssertEqual(L10n.language, .de)
        XCTAssertEqual(L10n.resolvedCode, "de")
        XCTAssertEqual(AppLanguage.de.configValue, "de")
        XCTAssertEqual(AppLanguage.auto.configValue, "auto")
    }

    // MARK: ConfigFileWatcher

    private func temporaryConfig() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crok-l10n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("config.toml")
    }

    private func replace(_ url: URL, with text: String) throws {
        // The terminal and the desktop both replace the file atomically.
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func testTheWatcherReportsOnlyWhenTheFileChanges() throws {
        let url = try temporaryConfig()
        try replace(url, with: "[ui]\nui_language = \"en\"\n")
        let watcher = ConfigFileWatcher(url: url)
        XCTAssertNil(watcher.check(), "unchanged since the watcher started")

        try replace(url, with: "[ui]\nui_language = \"zh-Hans\"\n")
        let changed = try XCTUnwrap(watcher.check())
        XCTAssertEqual(changed.string("ui_language", in: "ui"), "zh-Hans")
        XCTAssertNil(watcher.check(), "reported once")

        try FileManager.default.removeItem(at: url)
        let gone = try XCTUnwrap(watcher.check(), "a deleted file is a change too")
        XCTAssertNil(gone.string("ui_language", in: "ui"))
    }

    func testTheWatcherStartsFromAMissingFile() throws {
        let url = try temporaryConfig()
        let watcher = ConfigFileWatcher(url: url)
        XCTAssertNil(watcher.check())
        try replace(url, with: "[ui]\nui_language = \"fr\"\n")
        XCTAssertEqual(try XCTUnwrap(watcher.check()).string("ui_language", in: "ui"), "fr")
    }

    /// The terminal writes `[ui].ui_language`; the desktop's timer sees it and the language changes.
    func testTheWatcherAppliesTheTerminalsChange() throws {
        let url = try temporaryConfig()
        try replace(url, with: "[ui]\nui_language = \"en\"\n")
        L10n.setLanguage(.en)
        let watcher = ConfigFileWatcher(url: url)
        let applied = expectation(description: "language applied")
        watcher.start { config in
            ConfigFileWatcher.apply(config)
            applied.fulfill()
        }
        defer { watcher.stop() }
        try replace(url, with: "[ui]\nui_language = \"ja\"\n")
        wait(for: [applied], timeout: ConfigFileWatcher.interval * 3)
        XCTAssertEqual(L10n.language, .ja)
        XCTAssertEqual(L10n.t("settings", "Settings"), "設定")
    }

    // MARK: L10n.t — English fallback for unknown key

    func testEnglishFallbackForUnknownKey() {
        L10n.setLanguage(.zhHans)
        let result = L10n.t("totally_unknown_key_xyz", "Fallback English")
        XCTAssertEqual(result, "Fallback English")
    }

    func testEnglishFallbackWhenSetToEnglish() {
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.t("settings", "Settings"), "Settings")
        XCTAssertEqual(L10n.t("done", "Done"), "Done")
    }

    // MARK: L10n.t — other languages

    func testJapaneseLookup() {
        L10n.setLanguage(.ja)
        XCTAssertEqual(L10n.t("settings", "Settings"), "設定")
        XCTAssertEqual(L10n.t("cancel", "Cancel"), "キャンセル")
    }

    func testSpanishLookup() {
        L10n.setLanguage(.es)
        XCTAssertEqual(L10n.t("done", "Done"), "Listo")
        XCTAssertEqual(L10n.t("cancel", "Cancel"), "Cancelar")
    }

    func testFrenchLookup() {
        L10n.setLanguage(.fr)
        XCTAssertEqual(L10n.t("settings", "Settings"), "Réglages")
        XCTAssertEqual(L10n.t("done", "Done"), "Terminé")
    }

    func testGermanLookup() {
        L10n.setLanguage(.de)
        XCTAssertEqual(L10n.t("settings", "Settings"), "Einstellungen")
        XCTAssertEqual(L10n.t("done", "Done"), "Fertig")
    }

    // MARK: L10n.configure

    func testConfigureReadsUiLanguage() {
        let config = GrokConfig(text: "[ui]\nui_language = \"zh-Hans\"\n")
        L10n.configure(fromConfig: config)
        XCTAssertEqual(L10n.t("settings", "Settings"), "设置")
    }

    func testConfigureAutoResetsOverride() {
        L10n.setLanguage(.zhHans)
        let config = GrokConfig(text: "[ui]\nui_language = \"auto\"\n")
        L10n.configure(fromConfig: config)
        // After auto, resolvedCode falls back to system locale — just verify no crash and key lookup still works.
        let result = L10n.t("totally_unknown_key_xyz", "Fallback")
        XCTAssertEqual(result, "Fallback")
    }

    // MARK: AppLanguage properties

    func testAllCasesAreIdentifiedByRawValue() {
        for lang in AppLanguage.allCases {
            XCTAssertEqual(lang.id, lang.rawValue)
        }
    }

    func testMenuTitlesAreNonEmpty() {
        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.menuTitle.isEmpty, "\(lang) has empty menuTitle")
        }
    }
}
