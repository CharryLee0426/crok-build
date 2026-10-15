import XCTest

@testable import Crok

/// The String Catalog compiles into one table per language; every language must carry every key.
final class LocalizationTests: XCTestCase {
    static let languages = ["zh-Hans", "ja", "es", "fr", "de"]

    private func table(_ language: String, _ name: String = "Localizable") throws -> [String: Any] {
        let bundle = Bundle(for: AppModel.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: language),
            "\(language).lproj/\(name).strings is missing")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    }

    func testEveryLanguageHasTheSameKeys() throws {
        let reference = Set(try table("zh-Hans").keys)
        XCTAssertGreaterThan(reference.count, 180)
        for language in Self.languages {
            let keys = Set(try table(language).keys)
            XCTAssertEqual(keys.symmetricDifference(reference), [], "\(language) differs from zh-Hans")
        }
    }

    func testDesktopWordingIsReused() throws {
        let expected: [String: [String: String]] = [
            "Settings": ["zh-Hans": "设置", "ja": "設定", "es": "Ajustes", "fr": "Réglages", "de": "Einstellungen"],
            "Stop": ["zh-Hans": "停止", "ja": "停止", "es": "Detener", "fr": "Arrêter", "de": "Stopp"],
            "Sign Out": ["zh-Hans": "退出登录", "ja": "サインアウト", "es": "Cerrar sesión", "fr": "Se déconnecter", "de": "Abmelden"],
        ]
        for (key, byLanguage) in expected {
            for (language, value) in byLanguage {
                XCTAssertEqual(try table(language)[key] as? String, value, "\(key) in \(language)")
            }
        }
    }

    func testCameraUsageIsLocalized() throws {
        for language in Self.languages {
            let info = try table(language, "InfoPlist")
            XCTAssertNotNil(info["NSCameraUsageDescription"], language)
        }
    }
}
