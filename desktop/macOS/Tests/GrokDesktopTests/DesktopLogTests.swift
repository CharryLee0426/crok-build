import XCTest
@testable import GrokDesktop

@MainActor
final class DesktopLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entries(in file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], "not an entry: \($0)")
        }
    }

    /// The shared log's entries with this message. Other tests in the run write to the same file.
    private func sharedEntries(_ message: String, method: String) throws -> [[String: Any]] {
        DesktopLog.shared.flush()
        return try entries(in: DesktopLog.shared.file).filter {
            $0["msg"] as? String == message && ($0["ctx"] as? [String: Any])?["method"] as? String == method
        }
    }

    // MARK: Entries

    func testAnEntryIsOneLineInTheHarnessFormat() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.319)
        let line = DesktopLog.line(level: .error, message: "acp.request_failed", session: "01a0e1a1", context: [
            "method": "session/prompt", "code": -32603, "data": ["message": "disk \"full\"\nretry"], "absent": nil, "ok": false
        ], date: date, version: "1.2.3", pid: 4242)
        let text = String(decoding: line, as: UTF8.self)

        // The harness writes its fields in this order, and a reader skimming the raw file relies on it.
        XCTAssertTrue(text.hasPrefix(#"{"ts":"2026-09-21T14:13:20.319Z","src":"grok-desktop","pid":4242,"ver":"1.2.3","lvl":"error","sid":"01a0e1a1","msg":"acp.request_failed","ctx":{"#), text)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "an entry must stay on one line")

        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let context = try XCTUnwrap(entry["ctx"] as? [String: Any])
        XCTAssertEqual(context["method"] as? String, "session/prompt")
        XCTAssertEqual(context["code"] as? Int, -32603)
        XCTAssertEqual(context["ok"] as? Bool, false)
        XCTAssertEqual((context["data"] as? [String: Any])?["message"] as? String, "disk \"full\"\nretry")
        XCTAssertNil(context["absent"])
    }

    func testAnEntryWithoutSessionOrContextOmitsThem() throws {
        let line = DesktopLog.line(level: .info, message: "app.terminate", session: nil, context: [:], date: Date(), version: "1.0.0")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertNil(entry["sid"])
        XCTAssertNil(entry["ctx"])
        XCTAssertEqual(entry["lvl"] as? String, "info")
    }

    func testValuesThatAreNotJSONAreDescribedAndLongTextIsCut() throws {
        struct Opaque { let id = 7 }
        let long = String(repeating: "x", count: DesktopLog.maximumValueLength + 100)
        let line = DesktopLog.line(level: .warn, message: "probe", session: nil, context: [
            "opaque": Opaque(), "file": URL(fileURLWithPath: "/tmp/a b.txt"), "long": long,
            "error": ACPClientError.timedOut("session/load"), "nested": ["list": [Opaque()]]
        ], date: Date(), version: "1.0.0")
        let context = try XCTUnwrap((JSONSerialization.jsonObject(with: line) as? [String: Any])?["ctx"] as? [String: Any])
        XCTAssertEqual(context["opaque"] as? String, "Opaque(id: 7)")
        XCTAssertEqual(context["file"] as? String, "/tmp/a b.txt")
        XCTAssertEqual((context["long"] as? String)?.count, DesktopLog.maximumValueLength + 1)
        XCTAssertTrue((context["long"] as? String)?.hasSuffix("…") == true)
        XCTAssertTrue((context["error"] as? String)?.contains("session/load") == true)
        XCTAssertEqual(((context["nested"] as? [String: Any])?["list"] as? [String])?.first, "Opaque(id: 7)")
    }

    func testHarnessStderrLosesItsTerminalColours() {
        XCTAssertEqual(DesktopLog.plain("\u{1B}[2m2026-10-06T18:05:45Z\u{1B}[0m \u{1B}[31mERROR\u{1B}[0m save failed"), "2026-10-06T18:05:45Z ERROR save failed")
    }

    // MARK: Writing

    func testWritesCreateTheDirectoryAndAppend() throws {
        let file = directory.appendingPathComponent("logs/unified.jsonl")
        let log = DesktopLog(file: file, version: "9.9.9")
        log.log(.info, "first", session: "s-1", ["n": 1])
        log.log(.error, "second")
        log.flush()

        let written = try entries(in: file)
        XCTAssertEqual(written.map { $0["msg"] as? String }, ["first", "second"])
        XCTAssertEqual(written[0]["sid"] as? String, "s-1")
        XCTAssertEqual(written[0]["src"] as? String, "grok-desktop")
        XCTAssertEqual(written[0]["ver"] as? String, "9.9.9")
        XCTAssertEqual(written[0]["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
    }

    /// The harness appends to the same file. What it wrote must still be there, whole, around the app's entries.
    func testEntriesInterleaveWithAnotherWriters() throws {
        let file = directory.appendingPathComponent("unified.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harnessLine = #"{"ts":"2026-10-06T18:05:45.319Z","src":"shell","pid":1,"lvl":"info","msg":"agent initialized"}"# + "\n"
        try Data(harnessLine.utf8).write(to: file)

        let log = DesktopLog(file: file)
        log.log(.info, "app.launch")
        log.flush()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(harnessLine.utf8))
        try handle.close()

        XCTAssertEqual(try entries(in: file).map { $0["src"] as? String }, ["shell", "grok-desktop", "shell"])
    }

    func testAFullLogKeepsItsNewerHalfFromAWholeEntry() throws {
        let file = directory.appendingPathComponent("unified.jsonl")
        let log = DesktopLog(file: file, maximumBytes: 4096)
        for index in 0..<60 { log.log(.info, "entry", ["index": index, "padding": String(repeating: "p", count: 40)]) }
        log.flush()

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertLessThan(size, 4096 + 512, "the log must not grow past its cap")
        let kept = try entries(in: file).compactMap { ($0["ctx"] as? [String: Any])?["index"] as? Int }
        XCTAssertEqual(kept.last, 59, "the newest entry is kept")
        XCTAssertGreaterThan(try XCTUnwrap(kept.first), 0, "the oldest entries are dropped")
        XCTAssertEqual(kept, Array(try XCTUnwrap(kept.first)...59), "what is kept is a whole, ordered tail")
    }

    func testTestsWriteToTheirOwnFile() {
        XCTAssertTrue(DesktopLog.defaultFile.path.hasPrefix(FileManager.default.temporaryDirectory.path), DesktopLog.defaultFile.path)
        XCTAssertFalse(DesktopLog.shared.file.path.hasPrefix(GrokPaths.home.path))
    }

    // MARK: What the user is told

    func testAnInternalErrorIsShownWithItsCause() {
        XCTAssertEqual(ACPClientError.remote(code: -32603, message: "Internal error", data: "session store: disk I/O error").localizedDescription,
                       "session store: disk I/O error")
        XCTAssertEqual(ACPClientError.remote(code: -32603, message: "Internal error", data: ["message": "model catalog is empty"]).localizedDescription,
                       "model catalog is empty")
        // A specific message keeps its place in front of the detail.
        XCTAssertEqual(ACPClientError.remote(code: -32602, message: "Invalid params", data: "unknown session id").localizedDescription,
                       "Invalid params: unknown session id")
        XCTAssertEqual(ACPClientError.remote(code: -32000, message: "Sign in required", data: ["auth": true]).localizedDescription, "Sign in required")
    }

    func testAnInternalErrorWithoutACausePointsAtTheLog() {
        let shown = ACPClientError.remote(code: -32603, message: "Internal error", data: nil).localizedDescription
        XCTAssertTrue(shown.hasPrefix("Internal error. "), shown)
        XCTAssertTrue(shown.contains("crok logs --errors"), shown)
        let structured = ACPClientError.remote(code: -32603, message: "Internal error", data: ["xaiAcpChannelFailure": "recv_failed"]).localizedDescription
        XCTAssertTrue(structured.contains("Reveal Log File"), structured)
    }

    // MARK: The client

    private func startFixture(_ source: String) throws -> ACPClient {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The process transport fixture requires /usr/bin/python3.")
        }
        let client = ACPClient()
        try client.start(executable: "/usr/bin/python3", cwd: NSTemporaryDirectory(), arguments: ["-u", "-c", source])
        return client
    }

    func testAFailedRequestIsLoggedWithTheCauseTheHarnessGave() async throws {
        let client = try startFixture(#"""
import json, sys
request = json.loads(sys.stdin.readline())
print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32603, "message": "Internal error", "data": "session store: disk I/O error"}}), flush=True)
sys.stdin.read()
"""#)
        defer { client.stop() }
        do {
            _ = try await client.request("probe/failed_request", params: ["sessionId": "log-probe-session", "prompt": "a secret"], timeout: 5)
            XCTFail("the request must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "session store: disk I/O error")
        }

        let logged = try sharedEntries("acp.request_failed", method: "probe/failed_request")
        XCTAssertEqual(logged.count, 1)
        let entry = try XCTUnwrap(logged.first)
        XCTAssertEqual(entry["lvl"] as? String, "error")
        XCTAssertEqual(entry["sid"] as? String, "log-probe-session")
        let context = try XCTUnwrap(entry["ctx"] as? [String: Any])
        XCTAssertEqual(context["kind"] as? String, "remote")
        XCTAssertEqual(context["code"] as? Int, -32603)
        XCTAssertEqual(context["error"] as? String, "Internal error")
        XCTAssertEqual(context["data"] as? String, "session store: disk I/O error")
        XCTAssertEqual(context["shown"] as? String, "session store: disk I/O error")
        XCTAssertNotNil(context["duration_ms"] as? Int)
        XCTAssertNotNil(context["harness_pid"] as? Int)
        // What was asked is not logged, only that it was.
        XCTAssertFalse(String(describing: entry).contains("a secret"))
    }

    func testASuccessfulRequestLeavesADebugEntry() async throws {
        let client = try startFixture(#"""
import json, sys
request = json.loads(sys.stdin.readline())
print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"reply": "a secret reply"}}), flush=True)
sys.stdin.read()
"""#)
        defer { client.stop() }
        _ = try await client.request("probe/successful_request", timeout: 5)

        let entry = try XCTUnwrap(try sharedEntries("acp.request", method: "probe/successful_request").first)
        XCTAssertEqual(entry["lvl"] as? String, "debug")
        XCTAssertFalse(String(describing: entry).contains("a secret reply"))
    }

    func testAHarnessThatDiesIsLoggedWithItsLastWords() async throws {
        let client = try startFixture(#"""
import sys
sys.stdin.readline()
sys.stderr.write("\x1b[31mthread 'main' panicked\x1b[0m at probe-death-marker\nsecond line\nno newline at the end")
sys.stderr.flush()
sys.exit(101)
"""#)
        defer { client.stop() }
        do {
            _ = try await client.request("probe/dying_harness", timeout: 5)
            XCTFail("the request must fail")
        } catch {}

        DesktopLog.shared.flush()
        let all = try entries(in: DesktopLog.shared.file)
        let stderr = all.filter { $0["msg"] as? String == "harness.stderr" }.compactMap { ($0["ctx"] as? [String: Any])?["line"] as? String }
        XCTAssertTrue(stderr.contains("thread 'main' panicked at probe-death-marker"), "\(stderr)")

        let disconnect = try XCTUnwrap(all.last {
            $0["msg"] as? String == "harness.disconnected" && (($0["ctx"] as? [String: Any])?["pending"] as? [String]) == ["probe/dying_harness"]
        })
        XCTAssertEqual(disconnect["lvl"] as? String, "error")
        let context = try XCTUnwrap(disconnect["ctx"] as? [String: Any])
        XCTAssertEqual(context["exit_status"] as? Int, 101)
        XCTAssertEqual(context["stderr"] as? String, "no newline at the end")

        let failed = try XCTUnwrap(try sharedEntries("acp.request_failed", method: "probe/dying_harness").first)
        XCTAssertEqual((failed["ctx"] as? [String: Any])?["kind"] as? String, "disconnected")
    }
}
