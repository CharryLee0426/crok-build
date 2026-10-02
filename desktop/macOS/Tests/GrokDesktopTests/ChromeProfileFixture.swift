import CommonCrypto
import Foundation
@testable import GrokDesktop

/// A Chrome user-data folder written the way Chrome for Mac writes one: `Local State`, and per
/// profile a `History` and a `Cookies` database (with values encrypted under a known password) and
/// a `Bookmarks` file. The browser's tests and performance tests import from it; nothing of the
/// real Chrome is read.
enum ChromeProfileFixture {
    static let password = "fixture-safe-storage-password"
    private static var ciphers: [String: ChromeCookieCipher] = [:]

    struct Size {
        var history = 40
        var cookies = 30
        var bookmarks = 12
    }

    /// Encrypts as Chrome does: "v10", then AES-128-CBC over (since Chrome 130) a SHA-256 of the host and the value.
    static func encrypt(_ value: String, host: String, password: String = password, withHostDigest: Bool = true) -> Data {
        // Deriving the key is the slow part, and a profile's cookies share one.
        let cipher = ciphers[password] ?? ChromeCookieCipher(password: password)
        ciphers[password] = cipher
        let plain = (withHostDigest ? ChromeCookieCipher.sha256(Array(host.utf8)) : []) + Array(value.utf8)
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), cipher.key, cipher.key.count,
                             ChromeCookieCipher.initializationVector, plain, plain.count, &output, output.count, &length)
        precondition(status == kCCSuccess)
        return Data(ChromeCookieCipher.versionPrefix + output.prefix(length))
    }

    static func host(_ index: Int) -> String { "site\(index % 400).example.com" }

    /// Writes `root/Local State` and the profiles. The first profile is the one Chrome used last.
    static func make(root: URL, profiles: [(folder: String, name: String, account: String?)] = [("Default", "Work", "me@example.com")],
                     size: Size = Size(), now: Date = Date()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var cache: [String: Any] = [:]
        for profile in profiles {
            cache[profile.folder] = ["name": profile.name, "user_name": profile.account ?? ""]
            try makeProfile(root.appendingPathComponent(profile.folder, isDirectory: true), size: size, now: now)
        }
        let state: [String: Any] = ["profile": ["info_cache": cache, "last_used": profiles.first?.folder ?? "Default"]]
        try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("Local State"))
    }

    static func makeProfile(_ directory: URL, size: Size, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Preferences"))
        try writeHistory(directory.appendingPathComponent("History"), count: size.history, now: now)
        try writeCookies(directory.appendingPathComponent("Cookies"), count: size.cookies, now: now)
        try writeBookmarks(directory.appendingPathComponent("Bookmarks"), count: size.bookmarks)
    }

    static func writeHistory(_ file: URL, count: Int, now: Date) throws {
        let database = try SQLiteDatabase(url: file)
        try database.execute("""
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
                typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
            """)
        try database.transaction {
            let statement = try SQLiteDatabase.Statement(database, "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)")
            for index in 0..<count {
                let visited = ChromeTime.microseconds(now.addingTimeInterval(-Double(index) * 90))
                try statement.run([.text("https://\(host(index))/docs/page-\(index)?ref=fixture"), .text("Page \(index) · \(topics[index % topics.count]) guide"),
                                   .integer(Int64(1 + index % 17)), .integer(visited), .integer(0)])
            }
            // Rows the import leaves out: a hidden page and Chrome's own pages.
            try statement.run([.text("https://hidden.example.com/"), .text("Hidden"), .integer(3), .integer(ChromeTime.microseconds(now)), .integer(1)])
            try statement.run([.text("chrome://settings/"), .text("Settings"), .integer(9), .integer(ChromeTime.microseconds(now)), .integer(0)])
        }
    }

    static let topics = ["swift", "rust", "webkit", "sqlite", "keychain", "cookies", "markdown", "terminal"]

    /// The schema of Chrome 130 and later. With `legacy`, the columns Chrome had before SameSite and partitioning.
    static func writeCookies(_ file: URL, count: Int, now: Date, password: String = password, legacy: Bool = false) throws {
        let database = try SQLiteDatabase(url: file)
        try database.execute(legacy ? """
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, path TEXT NOT NULL,
                expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL,
                has_expires INTEGER NOT NULL DEFAULT 1, is_persistent INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 1,
                encrypted_value BLOB DEFAULT '');
            """ : """
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
                value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
                is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
                priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
                last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL, has_cross_site_ancestor INTEGER NOT NULL);
            """)
        let created = ChromeTime.microseconds(now)
        let expires = ChromeTime.microseconds(now.addingTimeInterval(86_400 * 30))
        try database.transaction {
            if legacy {
                let statement = try SQLiteDatabase.Statement(database, """
                    INSERT INTO cookies (creation_utc, host_key, name, value, path, expires_utc, is_secure, is_httponly, last_access_utc, encrypted_value)
                    VALUES (?, ?, ?, '', '/', ?, 1, 0, ?, ?)
                    """)
                for index in 0..<count {
                    let host = "." + self.host(index)
                    try statement.run([.integer(created), .text(host), .text("legacy\(index)"), .integer(expires), .integer(created),
                                       .blob(encrypt("old-\(index)", host: host, password: password, withHostDigest: false))])
                }
                return
            }
            let statement = try SQLiteDatabase.Statement(database, """
                INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 2, 443, ?, 0, 0)
                """)
            func insert(host: String, partition: String = "", name: String, plain: String = "", encrypted: Data = Data(), expires: Int64, hasExpires: Bool = true,
                        secure: Bool = true, httpOnly: Bool = false, sameSite: Int64 = 1) throws {
                try statement.run([.integer(created), .text(host), .text(partition), .text(name), .text(plain), .blob(encrypted), .text("/"), .integer(expires),
                                   .integer(secure ? 1 : 0), .integer(httpOnly ? 1 : 0), .integer(created), .integer(hasExpires ? 1 : 0),
                                   .integer(hasExpires ? 1 : 0), .integer(sameSite), .integer(created)])
            }
            for index in 0..<count {
                // Domain cookies and host-only cookies, as sites set both.
                let host = (index % 3 == 0 ? "" : ".") + self.host(index)
                try insert(host: host, name: "session\(index)", encrypted: encrypt("value-\(index)-\(String(repeating: "x", count: index % 60))", host: host, password: password),
                           expires: expires, httpOnly: index % 2 == 0, sameSite: Int64(index % 3))
            }
            // Rows the import leaves out or handles specially.
            try insert(host: ".expired.example.com", name: "old", encrypted: encrypt("gone", host: ".expired.example.com", password: password),
                       expires: ChromeTime.microseconds(now.addingTimeInterval(-3_600)))
            try insert(host: ".partitioned.example.com", partition: "https://embedder.example", name: "chips",
                       encrypted: encrypt("partitioned", host: ".partitioned.example.com", password: password), expires: expires)
            try insert(host: ".plain.example.com", name: "plain", plain: "not-encrypted", expires: expires, secure: false)
            try insert(host: ".session.example.com", name: "tab", encrypted: encrypt("until-quit", host: ".session.example.com", password: password),
                       expires: 0, hasExpires: false)
            try insert(host: ".otherkey.example.com", name: "locked", encrypted: encrypt("secret", host: ".otherkey.example.com", password: "another-password"),
                       expires: expires)
        }
    }

    static func writeBookmarks(_ file: URL, count: Int) throws {
        func url(_ index: Int) -> [String: Any] { ["type": "url", "name": "Bookmark \(index)", "url": "https://\(host(index))/bookmark/\(index)"] }
        let bar = (0..<count / 2).map(url)
        let folder: [String: Any] = ["type": "folder", "name": "Reading", "children": (count / 2..<count).map(url)
            + [["type": "url", "name": "Chrome settings", "url": "chrome://settings/"]]]
        let roots: [String: Any] = [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks Bar", "children": bar + [folder]],
            "other": ["type": "folder", "name": "Other Bookmarks", "children": [["type": "url", "name": "Elsewhere", "url": "https://elsewhere.example.com/"]]],
            "synced": ["type": "folder", "name": "Mobile Bookmarks", "children": []],
        ]
        try JSONSerialization.data(withJSONObject: ["roots": roots, "version": 1]).write(to: file)
    }
}
