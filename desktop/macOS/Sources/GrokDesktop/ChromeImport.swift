import CommonCrypto
import Foundation
import Security

// Reading a Google Chrome profile on this Mac: its cookies, browsing history, and bookmarks.
// Nothing here touches the browser; BrowserImport.swift applies what is read. Chrome keeps its
// databases locked while it runs, so each is copied to a private folder and read there.

/// One Chrome profile ("Person") on this Mac.
struct ChromeProfile: Identifiable, Equatable {
    var directory: URL
    /// The name Chrome shows in its profile menu.
    var name: String
    /// The signed-in Google account, when the profile has one.
    var account: String?

    var id: String { directory.lastPathComponent }
}

struct ChromeHistoryEntry: Equatable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisit: Date
}

struct ChromeBookmark: Equatable {
    var title: String
    var url: String
    /// The folders above it, joined with " / ": "Bookmarks Bar / Work".
    var folder: String
}

struct ChromeCookie: Equatable {
    enum SameSite: Equatable { case unspecified, none, lax, strict }

    var name: String
    var value: String
    /// The host, with a leading dot when the cookie covers subdomains.
    var domain: String
    var path: String
    /// Nil for a session cookie.
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSite: SameSite

    /// The cookie as the web view's store takes it.
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path]
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
        switch sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .none, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }
}

enum ChromeImportError: LocalizedError, Equatable {
    case notInstalled
    case missing(String)
    case unreadable(String)
    case keychainDenied
    case keychainUnavailable(String)
    /// The person at the Mac dismissed macOS's request to confirm who they are.
    case authenticationCancelled
    case notAuthenticated(String)

    var errorDescription: String? {
        switch self {
        case .authenticationCancelled: return "The import was cancelled."
        case .notAuthenticated(let detail): return "macOS could not confirm it's you, so nothing was read from Chrome: \(detail)"
        case .notInstalled: return "Google Chrome has no profiles on this Mac."
        case .missing(let what): return "This Chrome profile has no \(what)."
        case .unreadable(let detail): return detail
        case .keychainDenied: return "Chrome's cookies are encrypted with a key in your keychain. Allow access to “Chrome Safe Storage” to import them."
        case .keychainUnavailable(let detail): return "Could not read Chrome's encryption key from the keychain: \(detail)"
        }
    }
}

/// Chrome's times count microseconds from 1601.
enum ChromeTime {
    static let epochOffset: Double = 11_644_473_600

    static func date(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - epochOffset)
    }

    static func microseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + epochOffset) * 1_000_000) }
}

enum ChromeData {
    /// Where Chrome keeps its profiles.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// The profiles Chrome lists in `Local State`, the one used last first. Folders that hold a
    /// profile Chrome does not list (a copied one) are added by name.
    static func profiles(in root: URL = defaultRoot) -> [ChromeProfile] {
        let fileManager = FileManager.default
        var named: [String: (name: String, account: String?)] = [:]
        var lastUsed: String?
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = state["profile"] as? [String: Any] {
            lastUsed = profile["last_used"] as? String
            for (directory, value) in profile["info_cache"] as? [String: Any] ?? [:] {
                guard let info = value as? [String: Any] else { continue }
                let account = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                named[directory] = ((info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory, account)
            }
        }
        let folders = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var profiles: [ChromeProfile] = []
        for folder in folders.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let isProfile = folder == "Default" || folder.hasPrefix("Profile ") || named[folder] != nil
            guard isProfile, fileManager.fileExists(atPath: directory.appendingPathComponent("Preferences").path)
                    || fileManager.fileExists(atPath: directory.appendingPathComponent("Cookies").path)
                    || fileManager.fileExists(atPath: directory.appendingPathComponent("History").path) else { continue }
            let info = named[folder]
            profiles.append(ChromeProfile(directory: directory, name: info?.name ?? folder, account: info?.account))
        }
        if let lastUsed, let index = profiles.firstIndex(where: { $0.id == lastUsed }), index > 0 {
            profiles.insert(profiles.remove(at: index), at: 0)
        }
        return profiles
    }

    // MARK: History

    /// The profile's most recently visited pages, newest first.
    static func history(in profile: URL, limit: Int = 20_000) throws -> [ChromeHistoryEntry] {
        let source = profile.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        return try withCopy(of: source) { database in
            var entries: [ChromeHistoryEntry] = []
            // Chrome's own pages (chrome://, extensions) are filtered here, so the limit counts web pages.
            try database.query("""
                SELECT url, title, visit_count, last_visit_time FROM urls
                WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%') ORDER BY last_visit_time DESC LIMIT ?
                """, [.integer(Int64(limit))]) { row in
                let url = row.text(0)
                guard isWebAddress(url), let visited = ChromeTime.date(row.integer(3)) else { return }
                entries.append(ChromeHistoryEntry(url: url, title: row.text(1), visitCount: max(1, Int(row.integer(2))), lastVisit: visited))
            }
            return entries
        }
    }

    // MARK: Bookmarks

    /// The profile's bookmarks in Chrome's order: the bookmarks bar, then other and mobile bookmarks.
    static func bookmarks(in profile: URL) throws -> [ChromeBookmark] {
        let source = profile.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        guard let data = try? Data(contentsOf: source), let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = document["roots"] as? [String: Any] else {
            throw ChromeImportError.unreadable("Could not read Chrome's Bookmarks file.")
        }
        var bookmarks: [ChromeBookmark] = []
        func walk(_ node: [String: Any], folder: String) {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                guard let url = node["url"] as? String, isWebAddress(url) else { return }
                bookmarks.append(ChromeBookmark(title: name, url: url, folder: folder))
            } else {
                let path = folder.isEmpty ? name : name.isEmpty ? folder : folder + " / " + name
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, folder: path) }
            }
        }
        for root in ["bookmark_bar", "other", "synced"] {
            if let node = roots[root] as? [String: Any] { walk(node, folder: "") }
        }
        return bookmarks
    }

    // MARK: Cookies

    struct CookieResult: Equatable {
        var cookies: [ChromeCookie] = []
        /// Cookies the key did not decrypt.
        var undecryptable = 0
        /// Cookies left out: expired, or partitioned to one embedding site, which the web view cannot keep.
        var skipped = 0
    }

    static func cookieDatabase(in profile: URL) -> URL? {
        // Newer versions keep network state in a subfolder.
        for path in ["Cookies", "Network/Cookies"] {
            let file = profile.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// The profile's unexpired cookies, decrypted with `cipher`.
    static func cookies(in profile: URL, cipher: ChromeCookieCipher, now: Date = Date()) throws -> CookieResult {
        guard let source = cookieDatabase(in: profile) else { return CookieResult() }
        return try withCopy(of: source) { database in
            var result = CookieResult()
            let partitioned = database.hasColumn("top_frame_site_key", in: "cookies")
            let sameSite = database.hasColumn("samesite", in: "cookies")
            let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires, "
                + (sameSite ? "samesite" : "-1") + ", " + (partitioned ? "top_frame_site_key" : "''") + " FROM cookies"
            try database.query(sql) { row in
                let host = row.text(0)
                guard !row.text(1).isEmpty, !host.isEmpty else { result.skipped += 1; return }
                guard row.text(10).isEmpty else { result.skipped += 1; return }
                let expires = row.integer(8) != 0 ? ChromeTime.date(row.integer(5)) : nil
                if let expires, expires <= now { result.skipped += 1; return }
                let encrypted = row.blob(3)
                let value: String
                if encrypted.isEmpty {
                    value = row.text(2)
                } else if let decrypted = cipher.decrypt(encrypted, host: host) {
                    value = decrypted
                } else {
                    result.undecryptable += 1
                    return
                }
                let policy: ChromeCookie.SameSite
                switch row.integer(9) {
                case 0: policy = .none
                case 1: policy = .lax
                case 2: policy = .strict
                default: policy = .unspecified
                }
                result.cookies.append(ChromeCookie(name: row.text(1), value: value, domain: host, path: row.text(4), expires: expires,
                                                   isSecure: row.integer(6) != 0, isHTTPOnly: row.integer(7) != 0, sameSite: policy))
            }
            return result
        }
    }

    // MARK: Reading

    static func isWebAddress(_ url: String) -> Bool { url.hasPrefix("http://") || url.hasPrefix("https://") }

    /// Copies a Chrome database, with its journal or write-ahead log, into a private folder that is
    /// removed afterwards, and reads the copy. Chrome holds an exclusive lock on the original.
    static func withCopy<T>(of source: URL, _ body: (SQLiteDatabase) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("crok-chrome-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: copy)
        } catch {
            throw ChromeImportError.unreadable("Could not read Chrome's \(source.lastPathComponent) file: \(error.localizedDescription)")
        }
        for suffix in ["-journal", "-wal"] {
            let extra = URL(fileURLWithPath: source.path + suffix)
            if fileManager.fileExists(atPath: extra.path) { try? fileManager.copyItem(at: extra, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        do {
            // Read-write, so SQLite can replay a journal the copy caught mid-write.
            let database = try SQLiteDatabase(url: copy)
            return try body(database)
        } catch let error as ChromeImportError {
            throw error
        } catch {
            throw ChromeImportError.unreadable("Could not read Chrome's \(source.lastPathComponent) database: \(error.localizedDescription)")
        }
    }
}

/// Decrypts the cookie values Chrome for Mac stores: AES-128-CBC under a key derived from the
/// "Chrome Safe Storage" password in the login keychain.
struct ChromeCookieCipher {
    static let salt = Array("saltysalt".utf8)
    static let iterations: UInt32 = 1003
    static let keyLength = 16
    /// Sixteen spaces.
    static let initializationVector = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    /// Marks a value encrypted with the keychain key.
    static let versionPrefix = Array("v10".utf8)

    let key: [UInt8]

    init(password: String) {
        var derived = [UInt8](repeating: 0, count: Self.keyLength)
        let bytes = Array(password.utf8)
        bytes.withUnsafeBufferPointer { passwordPointer in
            passwordPointer.withMemoryRebound(to: CChar.self) { characters in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), characters.baseAddress, bytes.count, Self.salt, Self.salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), Self.iterations, &derived, Self.keyLength)
            }
        }
        key = derived
    }

    /// The cookie's value, or nil when the key is wrong or the value is in a format this does not know.
    func decrypt(_ encrypted: Data, host: String) -> String? {
        guard encrypted.count > Self.versionPrefix.count, encrypted.prefix(Self.versionPrefix.count).elementsEqual(Self.versionPrefix) else { return nil }
        let payload = [UInt8](encrypted.dropFirst(Self.versionPrefix.count))
        guard !payload.isEmpty, payload.count % kCCBlockSizeAES128 == 0 else { return nil }
        var plain = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), key, key.count,
                             Self.initializationVector, payload, payload.count, &plain, plain.count, &length)
        guard status == kCCSuccess else { return nil }
        var value = plain.prefix(length)
        // Since Chrome 130 the value follows a SHA-256 of the cookie's host, which ties it to its row.
        let digest = Self.sha256(Array(host.utf8))
        if value.count >= digest.count, value.prefix(digest.count).elementsEqual(digest) { value = value.dropFirst(digest.count) }
        return String(bytes: value, encoding: .utf8)
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest
    }
}

/// Chrome's cookie encryption password, which macOS releases only after asking the user.
enum ChromeSafeStorage {
    static let service = "Chrome Safe Storage"
    static let account = "Chrome"

    /// Asks the keychain for the password. macOS shows its own prompt naming this app and
    /// "Chrome Safe Storage"; the user can allow it once, always, or deny it.
    static func password() throws -> String {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw ChromeImportError.keychainUnavailable("the stored key is empty")
            }
            return password
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ChromeImportError.keychainDenied
        case errSecItemNotFound:
            throw ChromeImportError.keychainUnavailable("Chrome has not stored one yet. Open Chrome once and try again.")
        default:
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw ChromeImportError.keychainUnavailable(detail)
        }
    }
}
