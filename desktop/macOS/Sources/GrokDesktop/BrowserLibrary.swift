import Foundation

// What the browser remembers of the pages it visited: a SQLite database in `browser/` beside the
// desktop state file, so thousands of imported pages cost nothing until the address bar asks for them.

/// Turns what was typed in the address bar into a page to load.
enum BrowserAddress {
    enum SearchEngine: String, CaseIterable, Identifiable {
        case google, duckDuckGo = "duckduckgo", bing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .google: return "Google"
            case .duckDuckGo: return "DuckDuckGo"
            case .bing: return "Bing"
            }
        }

        func url(for query: String) -> URL {
            var components: URLComponents
            switch self {
            case .google: components = URLComponents(string: "https://www.google.com/search")!
            case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
            case .bing: components = URLComponents(string: "https://www.bing.com/search")!
            }
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url!
        }
    }

    static let searchEngineKey = "browserSearchEngine"

    static func searchEngine(_ defaults: UserDefaults = .standard) -> SearchEngine {
        defaults.string(forKey: searchEngineKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    /// Schemes the browser loads itself. Anything else (mailto:, an app's scheme) goes to the system.
    static let loadableSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]

    /// An address is loaded as typed, a bare host gets a scheme (http for this Mac, https elsewhere),
    /// and anything else is searched for.
    static func resolve(_ input: String, searchEngine: SearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), !looksLikeHostWithPort(text) {
            if ["http", "https"].contains(scheme), url.host?.isEmpty == false { return url }
            if ["file", "about", "data"].contains(scheme) { return url }
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = (text as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        if !text.contains(where: \.isWhitespace), let host = hostPart(of: text) {
            let scheme = isLocal(host) ? "http" : "https"
            if isLocal(host) || looksLikeDomain(host), let url = URL(string: "\(scheme)://\(text)") { return url }
        }
        return searchEngine.url(for: text)
    }

    /// The text to show for a page: without the scheme for the common case, as browsers do.
    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.scheme == "about" { return "" }
        if url.isFileURL { return url.path }
        var text = url.absoluteString
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        if text.hasSuffix("/"), url.path == "/", url.query == nil, url.fragment == nil { text.removeLast() }
        return text
    }

    /// "localhost:3000" parses as a URL with scheme "localhost".
    private static func looksLikeHostWithPort(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let rest = text[text.index(after: colon)...]
        let port = rest.prefix { $0.isNumber }
        guard !port.isEmpty else { return false }
        let after = rest.dropFirst(port.count)
        return after.isEmpty || after.hasPrefix("/") || after.hasPrefix("?") || after.hasPrefix("#")
    }

    private static func hostPart(of text: String) -> String? {
        var host = text
        if let end = host.firstIndex(where: { "/?#".contains($0) }) { host = String(host[..<end]) }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            return String(host[...close])
        }
        if let colon = host.lastIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
            host = String(host[..<colon])
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "[::1]" || host == "0.0.0.0" || host.hasPrefix("127.")
            || host.hasSuffix(".local") || isPrivateAddress(host)
    }

    private static func isPrivateAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return false }
        // An IPv4 address, or a name whose last label could be a top-level domain.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return labels.count == 4 }
        return labels.last.map { $0.count >= 2 && $0.allSatisfy(\.isLetter) } ?? false
    }
}

struct BrowserHistoryItem: Equatable, Identifiable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisit: Date

    var id: String { url }
}

/// The browser's visited pages. Every call runs on the store's own queue, off the main thread.
actor BrowserHistoryStore {
    private let file: URL?
    private var database: SQLiteDatabase?

    /// A nil file keeps history in memory, for tests and private data stores.
    init(file: URL?) { self.file = file }

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let opened: SQLiteDatabase
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            opened = try SQLiteDatabase(url: file)
        } else {
            opened = try SQLiteDatabase.inMemory()
        }
        try opened.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS pages (url TEXT PRIMARY KEY, title TEXT NOT NULL, visit_count INTEGER NOT NULL, last_visit REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS pages_last_visit ON pages (last_visit DESC);
            """)
        database = opened
        return opened
    }

    /// One visit to a page, now.
    func record(url: String, title: String, at date: Date = Date()) {
        guard ChromeData.isWebAddress(url) else { return }
        try? open().run("""
            INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, 1, ?)
            ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = excluded.last_visit,
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
            """, [.text(url), .text(title), .real(date.timeIntervalSince1970)])
    }

    /// A page's title, once it is known.
    func setTitle(_ title: String, for url: String) {
        guard !title.isEmpty else { return }
        try? open().run("UPDATE pages SET title = ? WHERE url = ?", [.text(title), .text(url)])
    }

    /// Adds pages visited elsewhere, keeping the larger visit count and the later visit of a page already known.
    @discardableResult
    func merge(_ items: [BrowserHistoryItem]) throws -> Int {
        let database = try open()
        try database.transaction {
            let statement = try SQLiteDatabase.Statement(database, """
                INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visit_count, excluded.visit_count),
                    last_visit = MAX(last_visit, excluded.last_visit),
                    title = CASE WHEN title = '' THEN excluded.title ELSE title END
                """)
            for item in items {
                try statement.run([.text(item.url), .text(item.title), .integer(Int64(item.visitCount)), .real(item.lastVisit.timeIntervalSince1970)])
            }
        }
        return items.count
    }

    /// Pages whose address or title contains every word of `text`, the most visited and most recent first.
    func suggestions(for text: String, limit: Int = 6) -> [BrowserHistoryItem] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, let database = try? open() else { return [] }
        let clause = words.map { _ in "(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let values = words.flatMap { word -> [SQLiteDatabase.Value] in
            let pattern = "%" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            return [.text(pattern), .text(pattern)]
        }
        return read(database, "SELECT url, title, visit_count, last_visit FROM pages WHERE \(clause) ORDER BY visit_count DESC, last_visit DESC LIMIT ?",
                    values + [.integer(Int64(limit))])
    }

    func recent(limit: Int = 50) -> [BrowserHistoryItem] {
        guard let database = try? open() else { return [] }
        return read(database, "SELECT url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ?", [.integer(Int64(limit))])
    }

    func count() -> Int {
        guard let database = try? open(), case .integer(let count)? = try? database.scalar("SELECT COUNT(*) FROM pages") else { return 0 }
        return Int(count)
    }

    func clear() {
        try? open().execute("DELETE FROM pages")
    }

    private func read(_ database: SQLiteDatabase, _ sql: String, _ values: [SQLiteDatabase.Value]) -> [BrowserHistoryItem] {
        var items: [BrowserHistoryItem] = []
        try? database.query(sql, values) { row in
            items.append(BrowserHistoryItem(url: row.text(0), title: row.text(1), visitCount: Int(row.integer(2)),
                                            lastVisit: Date(timeIntervalSince1970: row.real(3))))
        }
        return items
    }
}
