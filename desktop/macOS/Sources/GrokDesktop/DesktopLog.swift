import Darwin
import Foundation

/// Crok Desktop's entries in the unified log, `$CROK_HOME/logs/unified.jsonl`.
///
/// The harness and the terminal UI append to the same file, one JSON object per line, so a request the app sent, the
/// error the harness answered with and what the harness logged while failing read as one timeline (`crok logs`).
/// The app writes the file itself rather than through the harness: the entries that matter most are about a harness
/// that would not start, stopped answering or exited.
///
/// Entries are encoded where they are logged and appended on a background queue, so logging never waits on the disk.
final class DesktopLog: @unchecked Sendable {
    enum Level: String { case error, warn, info, debug }

    static let shared = DesktopLog(file: defaultFile)

    /// The harness's writers trim the file to its newer half at this size; so does this one.
    static let maximumBytes = 5 * 1024 * 1024
    /// Longest text kept for one value. An error that quotes a response body is cut here.
    static let maximumValueLength = 8 * 1024

    let file: URL
    private let maximumBytes: Int
    private let version: String
    private let queue = DispatchQueue(label: "dev.chenli.crok.desktop.log", qos: .utility)

    init(file: URL, version: String = DesktopVersion.current, maximumBytes: Int = DesktopLog.maximumBytes) {
        self.file = file
        self.version = version
        self.maximumBytes = maximumBytes
    }

    /// Tests get a file of their own: a test run must not write into the log the developer is reading.
    static var defaultFile: URL {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("crok-desktop-log-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("unified.jsonl")
        }
        return GrokPaths.home.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("unified.jsonl")
    }

    static func error(_ message: String, session: String? = nil, _ context: [String: Any?] = [:]) { shared.log(.error, message, session: session, context) }
    static func warn(_ message: String, session: String? = nil, _ context: [String: Any?] = [:]) { shared.log(.warn, message, session: session, context) }
    static func info(_ message: String, session: String? = nil, _ context: [String: Any?] = [:]) { shared.log(.info, message, session: session, context) }
    static func debug(_ message: String, session: String? = nil, _ context: [String: Any?] = [:]) { shared.log(.debug, message, session: session, context) }

    /// `message` names the event (`acp.request_failed`); what varies goes in `context`.
    func log(_ level: Level, _ message: String, session: String? = nil, _ context: [String: Any?] = [:], date: Date = Date()) {
        let line = Self.line(level: level, message: message, session: session, context: context, date: date, version: version)
        queue.async { [self] in append(line) }
    }

    /// Returns once everything logged so far is in the file.
    func flush() { queue.sync {} }

    // MARK: Encoding

    /// One entry, in the field order the harness writes: `ts`, `src`, `pid`, `ver`, `lvl`, `sid`, `msg`, `ctx`.
    static func line(level: Level, message: String, session: String?, context: [String: Any?], date: Date, version: String,
                     pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Data {
        var text = "{\"ts\":\(quoted(timestamp(date))),\"src\":\"grok-desktop\",\"pid\":\(pid),\"ver\":\(quoted(version)),\"lvl\":\"\(level.rawValue)\""
        if let session, !session.isEmpty { text += ",\"sid\":\(quoted(session))" }
        text += ",\"msg\":\(quoted(message))"
        let fields = context.compactMapValues { $0.map(json) }
        if !fields.isEmpty, JSONSerialization.isValidJSONObject(fields),
           let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) {
            text += ",\"ctx\":" + String(decoding: data, as: UTF8.self)
        }
        text += "}\n"
        return Data(text.utf8)
    }

    /// RFC 3339 in UTC with milliseconds, as the harness stamps its entries.
    static func timestamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        let milliseconds = Int((date.timeIntervalSince1970 - Double(seconds)) * 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                      parts.tm_hour, parts.tm_min, parts.tm_sec, min(999, max(0, milliseconds)))
    }

    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A value JSON can hold: long text cut, anything that is not JSON described as text.
    static func json(_ value: Any) -> Any {
        switch value {
        case let text as String: return bounded(text)
        case let number as NSNumber: return number
        case is NSNull: return value
        case let list as [Any]: return list.map(json)
        case let object as [String: Any]: return object.mapValues(json)
        case let url as URL: return bounded(url.isFileURL ? url.path : url.absoluteString)
        case let error as Error: return bounded(describe(error))
        default: return bounded(String(describing: value))
        }
    }

    static func bounded(_ text: String, to limit: Int = maximumValueLength) -> String {
        text.utf8.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// What an error says to a developer: its type and case as well as its message, which for a harness error is
    /// often just "Internal error".
    static func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        let reflected = String(reflecting: error)
        return reflected.contains(message) ? reflected : "\(message) [\(reflected)]"
    }

    /// The context fields for a failure: the text shown to the user, the error as a developer needs it, and for a
    /// harness error its code and `data`.
    static func context(for error: Error) -> [String: Any?] {
        var fields: [String: Any?] = ["shown": error.localizedDescription, "error": describe(error)]
        if case ACPClientError.remote(let code, let message, let data) = error {
            fields["error"] = message
            fields["code"] = code
            fields["data"] = data
        }
        return fields
    }

    /// Harness stderr arrives coloured for a terminal.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    // MARK: Writing

    private func append(_ line: Data) {
        var descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        if descriptor == -1, errno == ENOENT {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard descriptor != -1 else { return }
        defer { close(descriptor) }
        // One write per entry: with O_APPEND the entry lands whole, after whatever another process just wrote.
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { return }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_size >= off_t(maximumBytes) { trim() }
    }

    /// Keeps the newer half, from the first whole entry. In place, as the harness does it: every other writer holds
    /// this file open for appending, so replacing it would leave them writing to a file nobody reads.
    private func trim() {
        let descriptor = open(file.path, O_RDWR | O_CLOEXEC)
        guard descriptor != -1 else { return }
        defer { close(descriptor) }
        // Held by another writer: it is trimming, and there is nothing left for this one to do.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let half = data.startIndex + data.count / 2
        guard let newline = data[half...].firstIndex(of: 0x0A) else { return }
        let tail = data[data.index(after: newline)...]
        let written = tail.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == tail.count else { return }
        ftruncate(descriptor, off_t(tail.count))
    }
}
