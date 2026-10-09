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
        XCTAssertEqual(L10n.t("new_task", "New Task"), "新任务")
        XCTAssertEqual(L10n.t("good_morning", "Good morning"), "早上好")
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
