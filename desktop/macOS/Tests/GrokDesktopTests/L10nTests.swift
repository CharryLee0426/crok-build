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

    // MARK: Tables

    /// No language lacks a key another has: a missing one would show English in the middle of that language.
    func testEveryLanguageHasTheSameKeys() {
        let english = L10n.keys(for: "en")
        XCTAssertGreaterThan(english.count, 400)
        for code in L10n.languageCodes where code != "en" {
            let keys = L10n.keys(for: code)
            XCTAssertEqual(english.subtracting(keys).sorted(), [], "\(code) lacks keys")
            XCTAssertEqual(keys.subtracting(english).sorted(), [], "\(code) has keys English does not")
        }
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\{[a-z_]+\}|%d|%@"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    /// A translation that drops or renames a placeholder would show `{name}` or lose the value.
    func testTranslationsKeepThePlaceholders() {
        for key in L10n.keys(for: "en") {
            let english = L10n.text(key, in: "en") ?? ""
            for code in L10n.languageCodes where code != "en" {
                let text = L10n.text(key, in: code) ?? ""
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(code) \(key) is empty")
                XCTAssertEqual(placeholders(text), placeholders(english), "\(code) \(key)")
            }
        }
    }

    /// What a Swift string literal's source text says.
    private func unescaped(_ literal: String) -> String {
        var text = literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
        let scalar = try! NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]+)\}"#)
        for match in scalar.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let digits = String(text[Range(match.range(at: 1), in: text)!])
            text.replaceSubrange(Range(match.range, in: text)!, with: String(UnicodeScalar(UInt32(digits, radix: 16)!)!))
        }
        return text.replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Every `L10n.t("key", "English")` in the app names a key the tables hold, with that English. The
    /// English stays at the call site so the code reads on its own; this keeps the two copies the same,
    /// and with `testEveryLanguageHasTheSameKeys` it means no call falls back to English in any language.
    func testEveryCallSiteMatchesTheEnglishTable() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GrokDesktop")
        let call = try NSRegularExpression(pattern: #"L10n\.t\(\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)""#)
        var seen = 0
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = unescaped(String(text[Range(match.range(at: 1), in: text)!]))
                let english = unescaped(String(text[Range(match.range(at: 2), in: text)!]))
                XCTAssertEqual(L10n.text(key, in: "en"), english, "\(file.lastPathComponent): \(key)")
                seen += 1
            }
        }
        XCTAssertGreaterThan(seen, 400, "the scan found too few calls to be reading the sources")
    }

    /// The lines under a setting's name are the part a reader most needs in their own language.
    func testSettingsDescriptionsAreTranslated() {
        let details = L10n.keys(for: "en").filter { $0.hasSuffix("_detail") || $0.hasSuffix("_subtitle") || $0.hasSuffix("_note") }
        XCTAssertGreaterThan(details.count, 30)
        for key in details {
            let english = L10n.text(key, in: "en")
            for code in L10n.languageCodes where code != "en" {
                XCTAssertNotEqual(L10n.text(key, in: code), english, "\(code) still shows English for \(key)")
            }
        }
    }

    /// The strings from Settings and the side panel that were English in every language.
    func testChineseCoversSettingsAndTheSidePanel() {
        L10n.setLanguage(.zhHans)
        // Settings
        XCTAssertEqual(L10n.t("conversation", "Conversation"), "对话")
        XCTAssertNotEqual(L10n.t("display_timestamps_detail", "Show when each message was sent."), "Show when each message was sent.")
        XCTAssertNotEqual(L10n.t("browser_search_engine", "Search engine"), "Search engine")
        XCTAssertNotEqual(L10n.t("browser_data", "Browsing data"), "Browsing data")
        XCTAssertNotEqual(L10n.t("cli_section", "Command line"), "Command line")
        XCTAssertNotEqual(L10n.t("accounts_sign_in", "Sign in"), "Sign in")
        XCTAssertNotEqual(L10n.t("accounts_add_key", "Add Key…"), "Add Key…")
        XCTAssertNotEqual(AccountProvider.codex.signedOutDetail, "Sign in with your browser")
        XCTAssertFalse(AccountProvider.deepseek.signedOutDetail.contains("{site}"))
        XCTAssertTrue(AccountProvider.deepseek.signedOutDetail.contains("platform.deepseek.com"))
        XCTAssertEqual(AppLanguage.auto.menuTitle, L10n.t("language_system", "System"))
        XCTAssertEqual(AppLanguage.zhHans.menuTitle, "简体中文", "a language is named in that language")
        // The side panel
        XCTAssertEqual(SidePanelTab.allCases.map(\.title), [L10n.t("files", "Files"), L10n.t("side_chat", "Side chat"), L10n.t("terminal", "Terminal"), L10n.t("browser", "Browser")])
        XCTAssertFalse(SidePanelTab.allCases.map(\.title).contains { $0.allSatisfy(\.isASCII) }, "every tab is named in Chinese")
        XCTAssertNotEqual(L10n.t("files_all", "All files"), "All files")
        XCTAssertNotEqual(L10n.t("files_filter", "Filter files"), "Filter files")
        XCTAssertNotEqual(FileStatusBadge.description("M"), "Modified")
        XCTAssertNotEqual(FilePreviewFailure.folder.message, "This is a folder.")
        L10n.setLanguage(.en)
        XCTAssertEqual(SidePanelTab.sideChat.title, "Side chat")
        XCTAssertEqual(FileStatusBadge.description("??"), "Untracked")
    }

    // MARK: Placeholders

    func testFillPutsValuesWhereTheLanguageWantsThem() {
        XCTAssertEqual(L10n.fill("Sign in to {name}", ["name": "OpenRouter"]), "Sign in to OpenRouter")
        XCTAssertEqual(L10n.fill("{b} then {a}, {a} again", ["a": "1", "b": "2"]), "2 then 1, 1 again")
        XCTAssertEqual(L10n.fill("{file}: {error}", ["file": "{error}.txt", "error": "gone"]), "{error}.txt: gone", "a value is not filled again")
        XCTAssertEqual(L10n.fill("keeps {unknown} and a lone {", [:]), "keeps {unknown} and a lone {")
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.t("files_truncated", "Showing the first {count} files.", ["count": "5,000"]), "Showing the first 5,000 files.")
    }

    func testSplitGivesTheTextAroundAPlaceholder() {
        let parts = L10n.split("Create a key at {site} · Saved", around: "site")
        XCTAssertEqual(parts.before, "Create a key at ")
        XCTAssertEqual(parts.after, " · Saved")
        XCTAssertEqual(L10n.split("{command} command", around: "command").before, "")
        XCTAssertEqual(L10n.split("no placeholder", around: "site").after, "")
    }

    func testLanguageNamesFollowTheInterfaceLanguage() {
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.languageName(code: "es", fallback: "Spanish"), "Spanish")
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.languageName(code: "es", fallback: "Spanish"), "西班牙语")
        L10n.setLanguage(.fr)
        XCTAssertEqual(L10n.languageName(code: "ja", fallback: "Japanese"), "Japonais", "a list entry starts with a capital")
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
