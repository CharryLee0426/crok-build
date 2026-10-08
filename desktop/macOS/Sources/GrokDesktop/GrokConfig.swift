import Foundation

/// Locations the terminal client shares with the desktop.
enum GrokPaths {
    /// `$CROK_HOME`, or `~/.crok`.
    static var home: URL {
        if let value = ProcessInfo.processInfo.environment["CROK_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".crok", isDirectory: true)
    }
    static var configFile: URL { home.appendingPathComponent("config.toml") }

    /// The harness's directory for one session, or nil when it has not been recorded yet.
    /// Long project paths use a hashed directory with a `.cwd` sidecar; those are found by
    /// reading the sidecars rather than reimplementing the hash.
    static func sessionDirectory(cwd: String, sessionID: String, home: URL = GrokPaths.home) -> URL? {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let manager = FileManager.default
        if let encoded = cwd.addingPercentEncoding(withAllowedCharacters: allowed), encoded.utf8.count <= 255 {
            let direct = sessions.appendingPathComponent(encoded, isDirectory: true).appendingPathComponent(sessionID, isDirectory: true)
            if manager.fileExists(atPath: direct.path) { return direct }
        }
        for directory in (try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(".cwd")),
                  String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == cwd else { continue }
            let candidate = directory.appendingPathComponent(sessionID, isDirectory: true)
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// A TOML value the desktop writes into `config.toml`.
enum GrokConfigValue: Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])

    var toml: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value): return GrokConfig.quote(value)
        case .strings(let values): return "[" + values.map(GrokConfig.quote).joined(separator: ", ") + "]"
        }
    }
}

enum GrokConfigError: LocalizedError {
    case unsupportedLayout(String)
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLayout(let detail): return "Crok Desktop could not safely edit config.toml: \(detail). Edit the file by hand or use the terminal."
        case .unreadable(let detail): return "Crok Desktop left config.toml unchanged: \(detail)."
        }
    }
}

/// Reads and edits `~/.crok/config.toml` the way the terminal does: one key at a time, keeping
/// every other line, comment, and table exactly as written. Edits locate tables and keys with a
/// full TOML parser (multi-line strings, CRLF, and BOMs included), replace only the bytes of the
/// value they change, and re-parse the result. A file that cannot be read or parsed, or whose
/// table is written as dotted keys or an inline table, is refused rather than rewritten.
struct GrokConfig {
    private(set) var text: String
    let url: URL
    /// Why the file could not be read; saving is refused so an unreadable file is never replaced.
    private let loadError: Error?

    /// Reads leniently, for display: an unreadable file reads as empty but cannot be saved.
    init(url: URL = GrokPaths.configFile) {
        self.url = url
        do { text = try Self.read(url) ?? ""; loadError = nil }
        catch { text = ""; loadError = error }
    }

    init(text: String, url: URL = GrokPaths.configFile) {
        self.text = text
        self.url = url
        loadError = nil
    }

    /// The file's text, nil when it does not exist; anything else unreadable throws.
    static func read(_ url: URL) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GrokConfigError.unreadable("\(url.path) is not valid UTF-8")
        }
        return text
    }

    private var document: ClaudeTOMLDocument? { text.isEmpty ? try? ClaudeTOMLDocument("") : try? ClaudeTOMLDocument(text) }

    // MARK: Reading

    /// The table at a dotted path, following headers, implicit tables, dotted keys, and inline tables.
    private static func table(_ path: String, in document: ClaudeTOMLDocument) -> ClaudeTOMLTable? {
        var table = document.root
        for component in path.split(separator: ".").map(String.init) {
            switch table.entries[component] {
            case .table(let child)?: table = child
            case .value(.inlineTable(let child), _)?: table = child
            default: return nil
            }
        }
        return table
    }

    /// The raw TOML text of a value, e.g. `true` or `"auto"`.
    func rawValue(_ key: String, in table: String) -> String? {
        guard let document, let found = Self.table(table, in: document),
              case .value(_, let index?)? = found.entries[key] else { return nil }
        let statement = document.keyValues[index]
        return String(decoding: document.bytes[statement.valueRange], as: UTF8.self)
    }

    func bool(_ key: String, in table: String) -> Bool? {
        guard let document, let found = Self.table(table, in: document), case .value(.boolean(let value), _)? = found.entries[key] else { return nil }
        return value
    }

    func string(_ key: String, in table: String) -> String? {
        guard let document, let found = Self.table(table, in: document), case .value(.string(let value), _)? = found.entries[key] else { return nil }
        return value
    }

    func int(_ key: String, in table: String) -> Int? { rawValue(key, in: table).flatMap { Int($0.replacingOccurrences(of: "_", with: "")) } }

    // MARK: Writing

    /// Sets `key` in `[table]`, adding the table at the end when it does not exist.
    mutating func set(_ key: String, to value: GrokConfigValue, in table: String) throws {
        let document = try editableDocument()
        var bytes = document.bytes
        let newline = Array(lineEnding.utf8)
        let entry = Array("\(Self.bareKey(key)) = \(value.toml)".utf8)
        switch try Self.locate(table, in: document) {
        case .header(let header, let found):
            switch found.entries[key] {
            case .value(_, let index?)?:
                bytes.replaceSubrange(document.keyValues[index].valueRange, with: Array(value.toml.utf8))
            case nil:
                // After the table's last statement, lined up with it.
                var insertion = document.sectionEnd(ofHeader: header)
                var line = Array(document.indentation(ofHeader: header).utf8) + entry + newline
                if insertion > 0, bytes[insertion - 1] != UInt8(ascii: "\n") { line = newline + line }
                if insertion > bytes.count { insertion = bytes.count }
                bytes.insert(contentsOf: line, at: insertion)
            default:
                throw GrokConfigError.unsupportedLayout("\(table).\(key) is not a plain value")
            }
        case .absent:
            // Also right when the table exists only implicitly (as the parent of `[table.child]`).
            while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") || last == 0x20 || last == 0x09 { bytes.removeLast() }
            if !bytes.isEmpty { bytes += newline + newline }
            bytes += Array("[\(Self.tablePath(table))]".utf8) + newline + entry + newline
        }
        try commit(bytes, verifying: key, in: table, expected: value.toml)
    }

    /// Removes `key` from `[table]` when present.
    mutating func remove(_ key: String, in table: String) throws {
        let document = try editableDocument()
        guard case .header(_, let found) = try Self.locate(table, in: document) else { return }
        guard case .value(_, let index?)? = found.entries[key] else { return }
        var bytes = document.bytes
        let statement = document.keyValues[index]
        bytes.removeSubrange(statement.lineStart..<statement.lineEnd)
        try commit(bytes, verifying: key, in: table, expected: nil)
    }

    private enum Location { case header(Int, ClaudeTOMLTable), absent }

    /// Where `[table]` is defined. Tables written as dotted keys, inline tables, or arrays of
    /// tables are refused: adding a `[table]` header next to them would make the file invalid.
    private static func locate(_ path: String, in document: ClaudeTOMLDocument) throws -> Location {
        var table = document.root
        for component in path.split(separator: ".").map(String.init) {
            switch table.entries[component] {
            case .table(let child)?:
                guard child.origin == .header || child.origin == .implicit else {
                    throw GrokConfigError.unsupportedLayout("[\(path)] is written as dotted keys")
                }
                table = child
            case nil: return .absent
            default: throw GrokConfigError.unsupportedLayout("[\(path)] is written as an inline table or array")
            }
        }
        guard let header = table.headerIndex, table.origin == .header else { return .absent }
        return .header(header, table)
    }

    private func editableDocument() throws -> ClaudeTOMLDocument {
        if let loadError { throw GrokConfigError.unreadable(loadError.localizedDescription) }
        do { return try ClaudeTOMLDocument(text) }
        catch { throw GrokConfigError.unreadable("\(url.lastPathComponent) is not valid TOML (\(error)); fix it before changing settings") }
    }

    /// Accepts an edit only if the result parses and reads back the intended value.
    private mutating func commit(_ bytes: [UInt8], verifying key: String, in table: String, expected: String?) throws {
        let bom = text.utf8.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" : ""
        let candidate = GrokConfig(text: bom + String(decoding: bytes, as: UTF8.self), url: url)
        guard (try? ClaudeTOMLDocument(candidate.text)) != nil, candidate.rawValue(key, in: table) == expected else {
            throw GrokConfigError.unsupportedLayout("the edited file did not read back \(table).\(key) as expected")
        }
        text = candidate.text
    }

    private var lineEnding: String { text.contains("\r\n") ? "\r\n" : "\n" }

    private static func tablePath(_ path: String) -> String { path.split(separator: ".").map { bareKey(String($0)) }.joined(separator: ".") }

    /// Writes atomically. A symlinked config is written through to its target, and the file
    /// keeps its permissions (new files are private to the user).
    func save() throws {
        if let loadError { throw GrokConfigError.unreadable(loadError.localizedDescription) }
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        try Data(text.utf8).write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: existing ?? NSNumber(value: 0o600)], ofItemAtPath: target.path)
    }

    /// Serialises every read-modify-write of Crok's configuration in this process, as the
    /// terminal does, so two quick changes cannot drop each other.
    private static let writeLock = NSRecursiveLock()

    static func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try body()
    }

    /// Reads, edits, and saves in one step. An unreadable or invalid file is left untouched.
    static func update(url: URL = GrokPaths.configFile, _ change: (inout GrokConfig) throws -> Void) throws {
        try withWriteLock {
            var config = GrokConfig(text: try read(url) ?? "", url: url)
            try change(&config)
            try config.save()
        }
    }

    // MARK: Line helpers (for callers that scan the text themselves)

    /// The table name of a `[table]` header line, normalising spaces around dots.
    static func headerName(_ line: String) -> String? {
        let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        return inner.split(separator: ".", omittingEmptySubsequences: false)
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ".")
    }


    static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), let equals = keySeparator(trimmed) else { return nil }
        let key = unquote(String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces))
        let value = stripComment(String(trimmed[trimmed.index(after: equals)...])).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// The `=` that ends a key, skipping any inside a quoted key.
    private static func keySeparator(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote { if character == open { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "=" { return index }
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(value[..<index]) }
        }
        return value
    }

    static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { escaped += String(format: "\\u%04X", scalar.value) }
                else { escaped.unicodeScalars.append(scalar) }
            }
        }
        return "\"" + escaped + "\""
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()) }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var iterator = value.dropFirst().dropLast().makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else { result.append(character); continue }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default: result.append(next)
            }
        }
        return result
    }

    private static func bareKey(_ key: String) -> String {
        let bare = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !key.isEmpty && key.unicodeScalars.allSatisfy(bare.contains) ? key : quote(key)
    }
}

/// Runs the bundled `crok` executable for commands that have no ACP method.
enum GrokCLI {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func run(_ executable: String, arguments: [String], cwd: String? = nil, environment: [String: String] = [:],
                    timeout: TimeInterval = 120) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw DesktopError.message("The bundled Crok runtime is missing. Reinstall Crok Desktop.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
                var env = ProcessInfo.processInfo.environment
                env.merge(environment) { $1 }
                process.environment = env
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Read both pipes concurrently so a full stderr buffer cannot stall stdout.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: outputData, stderr: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }
}
