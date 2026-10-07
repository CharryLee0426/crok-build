import Foundation
import Darwin

enum ACPClientError: LocalizedError {
    case notRunning
    case timedOut(String)
    case disconnected(String)
    case invalidMessage(String)
    case remote(code: Int, message: String, data: Any?)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The Crok harness is not running."
        case .timedOut(let method): return "Crok did not respond to \(method) in time."
        case .disconnected(let reason), .invalidMessage(let reason): return reason
        case .remote(let code, let message, let data):
            // The harness answers most failures with the bare "Internal error" and puts the cause in `data`.
            let generic = code == -32603 && message.caseInsensitiveCompare("Internal error") == .orderedSame
            guard let detail = Self.detail(in: data), detail != message else {
                return generic ? "\(message). The cause is in the log: Help > Reveal Log File, or run `crok logs --errors`." : message
            }
            return generic ? detail : "\(message): \(detail)"
        }
    }

    /// The readable part of an error's `data`: the text itself, or the message an object carries.
    static func detail(in data: Any?) -> String? {
        if let text = data as? String { return text.isEmpty ? nil : text }
        guard let object = data as? [String: Any] else { return nil }
        return ["message", "error", "detail", "details"].lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }
}

/// A newline-delimited JSON-RPC connection to `crok agent stdio`.
/// All callbacks and request completions are delivered on the main actor; pipe I/O is not.
@MainActor
final class ACPClient {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((Any, String, [String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>?
        let method: String
        let session: String?
        let harness: Int32
        let started = Date()
    }

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let writer = DispatchQueue(label: "dev.chenli.crok.desktop.acp.stdin", qos: .userInitiated)
        var stdoutFinished = false
        var stderrFinished = false
        var exitStatus: Int32?
        var stderrTail = Data()
        /// The end of the last stderr chunk when it stopped mid-line.
        var stderrLine = ""

        func closeInput() {
            writer.async { [input] in try? input.fileHandleForWriting.close() }
        }

        func terminate() {
            closeInput()
            guard process.isRunning else { return }
            process.terminate()
            // A stuck harness must not leave pipe workers or an orphan child behind.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private var connection: Connection?
    private var nextID = 0
    private var pending: [String: PendingRequest] = [:]
    nonisolated private static let maximumFrameBytes = 16 * 1024 * 1024
    nonisolated private static let maximumStderrBytes = 16 * 1024

    var isRunning: Bool { connection?.process.isRunning == true }

    deinit { connection?.terminate() }

    func start(executable: String, cwd: String, arguments: [String] = ["agent", "stdio"]) throws {
        stop()
        let newConnection = Connection()
        let process = newConnection.process
        process.executableURL = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
        process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.cargo/bin", NSHomeDirectory() + "/.local/bin"]
        environment["PATH"] = (inheritedPath.split(separator: ":").map(String.init) + extraPaths)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        // The harness ships with the app. A leader it starts must not replace itself with another release.
        environment["CROK_DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardInput = newConnection.input
        process.standardOutput = newConnection.output
        process.standardError = newConnection.errors
        let connectionID = newConnection.id
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection?.id == connectionID else { return }
                self.connection?.exitStatus = process.terminationStatus
                self.finishIfDrained(connectionID)
            }
        }
        connection = newConnection
        do {
            // Turn a closed child stdin into a write error instead of terminating the app.
            guard Darwin.fcntl(newConnection.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try process.run()
        } catch {
            DesktopLog.error("harness.start_failed", ["executable": executable, "cwd": cwd, "arguments": arguments, "error": DesktopLog.describe(error)])
            connection = nil
            newConnection.closeInput()
            try? newConnection.output.fileHandleForReading.close()
            try? newConnection.errors.fileHandleForReading.close()
            throw error
        }
        // The harness stamps its own entries with this pid, which is what ties the two sides together.
        DesktopLog.info("harness.start", ["harness_pid": process.processIdentifier, "executable": executable, "cwd": cwd, "arguments": arguments])
        readStdout(newConnection)
        readStderr(newConnection)
    }

    /// Use `timeout: nil` for long-running `session/prompt` requests.
    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval? = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let connection, connection.process.isRunning else { throw ACPClientError.notRunning }
        nextID += 1
        let id = nextID
        let key = String(id)
        let connectionID = connection.id
        let bytes = try encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask: Task<Void, Never>? = timeout.map { seconds in
                    Task { [weak self] in
                        do {
                            let nanoseconds = UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000)
                            try await Task.sleep(nanoseconds: nanoseconds)
                            self?.complete(key, connectionID: connectionID, result: .failure(ACPClientError.timedOut(method)))
                        } catch { /* The response or cancellation already completed this request. */ }
                    }
                }
                pending[key] = PendingRequest(continuation: continuation, timeout: timeoutTask, method: method,
                                              session: params["sessionId"] as? String, harness: connection.process.processIdentifier)
                write(bytes, to: connection)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.complete(key, connectionID: connectionID, result: .failure(CancellationError()))
            }
        }
    }

    func notify(_ method: String, params: [String: Any] = [:]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func respond(id: Any, result: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(id: Any, code: Int, message: String) throws {
        try send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func stop() {
        let previous = connection
        connection = nil
        if let previous { DesktopLog.debug("harness.stop", ["harness_pid": previous.process.processIdentifier, "pending": pending.count]) }
        failPending(ACPClientError.disconnected("The Crok connection was closed."))
        previous?.terminate()
    }

    private func encode(_ message: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw ACPClientError.invalidMessage("The ACP message could not be encoded as JSON.")
        }
        var bytes = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        return bytes
    }

    private func send(_ message: [String: Any]) throws {
        guard let connection, connection.process.isRunning else { throw ACPClientError.notRunning }
        write(try encode(message), to: connection)
    }

    private func write(_ bytes: Data, to connection: Connection) {
        connection.writer.async { [weak self, connection] in
            do {
                try connection.input.fileHandleForWriting.write(contentsOf: bytes)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.disconnect(connection.id, reason: "Could not write to the Crok harness: \(error.localizedDescription)")
                }
            }
        }
    }

    private func readStdout(_ connection: Connection) {
        DispatchQueue(label: "dev.chenli.crok.desktop.acp.stdout", qos: .userInitiated).async { [weak self, connection] in
            let handle = connection.output.fileHandleForReading
            defer { try? handle.close() }
            var buffer = Data()
            // Reading outpaces the main thread when the harness sends a backlog (a long task's
            // history, a burst of rounds). Queued without limit, the main queue then drains
            // every batch in one pass and the window stops answering for seconds. A few batches
            // in flight keep it answering between them, and a full pipe slows the harness.
            let inFlight = DispatchSemaphore(value: 4)
            do {
                while let chunk = try Self.readChunk(from: handle, limit: 64 * 1024) {
                    buffer.append(chunk)
                    // Deliver everything decoded from one read together: streaming sends many
                    // small frames, and each main-queue hop has a cost. A frame that fails to
                    // decode still leaves the earlier ones to be delivered before the disconnect.
                    var messages: [[String: Any]] = []
                    var bytes = 0
                    defer {
                        if !messages.isEmpty {
                            inFlight.wait()
                            DispatchQueue.main.async { [weak self, messages, bytes] in
                                defer { inFlight.signal() }
                                ACPTraffic.record(messages: messages.count, bytes: bytes)
                                for message in messages { self?.receive(message, connectionID: connection.id) }
                            }
                        }
                    }
                    var lineStart = buffer.startIndex
                    while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                        let line = Data(buffer[lineStart..<newline])
                        lineStart = buffer.index(after: newline)
                        if line.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { continue }
                        messages.append(try Self.decode(line))
                        bytes += line.count + 1
                    }
                    buffer.removeSubrange(..<lineStart)
                    guard buffer.count <= Self.maximumFrameBytes else {
                        throw ACPClientError.invalidMessage("The Crok harness sent an ACP message larger than 16 MB.")
                    }
                }
                if !buffer.isEmpty {
                    let message = try Self.decode(buffer)
                    DispatchQueue.main.async { [weak self] in self?.receive(message, connectionID: connection.id) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection?.id == connection.id else { return }
                    connection.stdoutFinished = true
                    self.finishIfDrained(connection.id)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.disconnect(connection.id, reason: error.localizedDescription) }
            }
        }
    }

    nonisolated private static func decode(_ line: Data) throws -> [String: Any] {
        guard line.count <= maximumFrameBytes else {
            throw ACPClientError.invalidMessage("The Crok harness sent an ACP message larger than 16 MB.")
        }
        do {
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0" else {
                throw ACPClientError.invalidMessage("The Crok harness sent an invalid JSON-RPC message.")
            }
            return message
        } catch let error as ACPClientError { throw error }
        catch { throw ACPClientError.invalidMessage("The Crok harness sent malformed JSON on its ACP output.") }
    }

    nonisolated private static func readChunk(from handle: FileHandle, limit: Int) throws -> Data? {
        // Foundation's read(upToCount:) can wait to fill the requested length on macOS.
        // A direct pipe read returns as soon as bytes arrive, which is essential for ACP streaming.
        var bytes = [UInt8](repeating: 0, count: limit)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readStderr(_ connection: Connection) {
        DispatchQueue(label: "dev.chenli.crok.desktop.acp.stderr", qos: .utility).async { [weak self, connection] in
            let handle = connection.errors.fileHandleForReading
            defer { try? handle.close() }
            do {
                while let chunk = try Self.readChunk(from: handle, limit: 8 * 1024) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.connection?.id == connection.id else { return }
                        connection.stderrTail.append(chunk)
                        if connection.stderrTail.count > Self.maximumStderrBytes {
                            connection.stderrTail = Data(connection.stderrTail.suffix(Self.maximumStderrBytes))
                        }
                        self.logStderr(String(decoding: chunk, as: UTF8.self), from: connection)
                        self.onLog?(String(decoding: chunk, as: UTF8.self))
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.connection?.id == connection.id else { return }
                    self?.onLog?("Could not read Crok stderr: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection?.id == connection.id else { return }
                connection.stderrFinished = true
                self.finishIfDrained(connection.id)
            }
        }
    }

    private func receive(_ message: [String: Any], connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"], !(id is NSNull) {
                if let onRequest { onRequest(id, method, params) }
                else { try? respondError(id: id, code: -32601, message: "Unsupported client method: \(method)") }
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = message["id"] else { return }
        let key = String(describing: id)
        if let error = message["error"] as? [String: Any] {
            complete(key, connectionID: connectionID, result: .failure(ACPClientError.remote(
                code: (error["code"] as? NSNumber)?.intValue ?? -32603,
                message: error["message"] as? String ?? "The Crok harness returned an error.", data: error["data"]
            )))
        } else if let result = message["result"] as? [String: Any] {
            complete(key, connectionID: connectionID, result: .success(result))
        } else if message["result"] is NSNull {
            complete(key, connectionID: connectionID, result: .success([:]))
        } else {
            complete(key, connectionID: connectionID, result: .failure(ACPClientError.invalidMessage("The Crok harness returned an invalid ACP result.")))
        }
    }

    private func complete(_ key: String, connectionID: UUID, result: Result<[String: Any], Error>) {
        guard connection?.id == connectionID, let request = pending.removeValue(forKey: key) else { return }
        request.timeout?.cancel()
        Self.log(request, id: key, result: result)
        request.continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let requests = pending
        pending.removeAll()
        for (key, request) in requests {
            request.timeout?.cancel()
            Self.log(request, id: key, result: .failure(error))
            request.continuation.resume(throwing: error)
        }
    }

    /// Every request leaves one entry: what was asked, of which harness, how long it took and how it ended.
    /// Parameters and results are left out; they carry the conversation.
    private static func log(_ request: PendingRequest, id: String, result: Result<[String: Any], Error>) {
        var context: [String: Any?] = [
            "method": request.method, "id": id, "harness_pid": request.harness,
            "duration_ms": Int(Date().timeIntervalSince(request.started) * 1000)
        ]
        switch result {
        case .success:
            DesktopLog.debug("acp.request", session: request.session, context)
        case .failure(let error):
            context.merge(DesktopLog.context(for: error)) { _, new in new }
            let level: DesktopLog.Level
            switch error {
            case is CancellationError: level = .debug; context["kind"] = "cancelled"
            case ACPClientError.remote(let code, _, _): level = code == -32603 ? .error : .warn; context["kind"] = "remote"
            case ACPClientError.timedOut: level = .error; context["kind"] = "timeout"
            // The disconnect has an entry of its own, with the reason.
            default: level = .warn; context["kind"] = "disconnected"
            }
            DesktopLog.shared.log(level, "acp.request_failed", session: request.session, context)
        }
    }

    /// Whole stderr lines, as the harness printed them: its error-level diagnostics, and anything said on the way
    /// down (a panic, a missing library) that never reaches its own log.
    private func logStderr(_ text: String, from connection: Connection) {
        var lines = (connection.stderrLine + text).components(separatedBy: "\n")
        connection.stderrLine = lines.removeLast()
        for line in lines.map({ DesktopLog.plain($0).trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            DesktopLog.warn("harness.stderr", ["harness_pid": connection.process.processIdentifier, "line": DesktopLog.bounded(line, to: 2000)])
        }
    }

    private func finishIfDrained(_ connectionID: UUID) {
        guard let connection, connection.id == connectionID,
              connection.stdoutFinished, connection.stderrFinished, let status = connection.exitStatus else { return }
        let stderr = String(decoding: connection.stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = stderr.isEmpty ? "" : "\n\(stderr)"
        disconnect(connectionID, reason: "The Crok harness exited with status \(status).\(suffix)")
    }

    private func disconnect(_ connectionID: UUID, reason: String) {
        guard let previous = connection, previous.id == connectionID else { return }
        connection = nil
        let unfinished = DesktopLog.plain(previous.stderrLine).trimmingCharacters(in: .whitespaces)
        DesktopLog.error("harness.disconnected", [
            "harness_pid": previous.process.processIdentifier, "reason": DesktopLog.plain(reason), "exit_status": previous.exitStatus.map { Int($0) },
            "pending": pending.values.map(\.method).sorted(), "stderr": unfinished.isEmpty ? nil : unfinished
        ])
        failPending(ACPClientError.disconnected(reason))
        previous.terminate()
        onDisconnect?(reason)
    }
}
