import XCTest
import SwiftUI
@testable import GrokDesktop

/// A recorded session replayed through the main window as it was sent: its first turn, a relaunch
/// that loads it back from the harness, the rest of its prompts one by one, and then the window
/// resized. For a session that ended or hung the app, on the Mac where it did.
///
/// Runs only with CROK_TRACE_HTML naming a `/trace` export. The window is never on screen, and a
/// frame is a layout and a draw, so it needs no display. A main thread that stops for six seconds
/// is sampled (to CROK_TRACE_SAMPLE, or a file the run names) and the run ends there: a hang does
/// not fail, it never returns.
///
/// - CROK_TRACE_PIECE=1 streams each reply a character at a time, a frame apart, so every partial
///   text it can stop at is laid out and drawn; CROK_TRACE_BURST=5:0.2 streams it in a provider's
///   bursts instead, cut at different places on every run. CROK_TRACE_FAST_TURNS=N sends the
///   first N turns at once.
/// - CROK_TRACE_WINDOW=1728x1117 sizes the window, CROK_TRACE_SIDE_PANEL=files|sideChat|terminal|browser
///   opens the side panel, CROK_TRACE_TIMELINE and CROK_TRACE_TIMESTAMPS turn those on, and
///   CROK_TRACE_NO_RELAUNCH leaves the relaunch out.
/// - CROK_TRACE_SHOTS=<folder> receives a picture after each turn.
@MainActor
final class TraceSessionReplayTests: XCTestCase {
    private var directory: URL!
    private var executable: URL!
    private var store: AppStore!
    private var host: NSHostingView<AnyView>!
    private var window: NSWindow!
    private let watchdog = MainThreadWatchdog()

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var trace: String? { environment["CROK_TRACE_HTML"] }

    /// Samples the process and ends the run when the main thread has not marked a step for `limit` seconds.
    final class MainThreadWatchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var beat = 0
        private var note = ""
        private var stopped = false

        func mark(_ note: String) { lock.lock(); beat += 1; self.note = note; lock.unlock() }
        func stop() { lock.lock(); stopped = true; lock.unlock() }

        func start(limit: TimeInterval, report: URL) {
            Thread.detachNewThread { [self] in
                var last = -1
                var since = Date()
                while true {
                    Thread.sleep(forTimeInterval: 0.25)
                    lock.lock()
                    let (beat, note, stopped) = (self.beat, self.note, self.stopped)
                    lock.unlock()
                    if stopped { return }
                    if beat != last { last = beat; since = Date(); continue }
                    guard Date().timeIntervalSince(since) > limit else { continue }
                    FileHandle.standardError.write("TRACE-REPLAY HANG during: \(note)\n".data(using: .utf8)!)
                    let sample = Process()
                    sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    sample.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-file", report.path]
                    try? sample.run()
                    sample.waitUntilExit()
                    FileHandle.standardError.write("TRACE-REPLAY sample written to \(report.path)\n".data(using: .utf8)!)
                    exit(9)
                }
            }
        }
    }

    private static let fixtureSettings = ["CROK_FIXTURE_REPLAY", "CROK_FIXTURE_REPLAY_BY_TURN", "CROK_FIXTURE_REPLAY_SPEED", "CROK_FIXTURE_REPLAY_MAX_GAP", "CROK_FIXTURE_HISTORY",
                                          "CROK_FIXTURE_REPLAY_PIECE", "CROK_FIXTURE_REPLAY_BURST", "CROK_FIXTURE_CHUNK_SECONDS", "CROK_FIXTURE_REPLAY_FAST_TURNS"]

    override func setUp() async throws {
        guard let trace, FileManager.default.fileExists(atPath: trace) else { throw XCTSkip("Set CROK_TRACE_HTML to a /trace export to replay its session") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-trace-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("project"), withIntermediateDirectories: true)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        executable = directory.appendingPathComponent("fixture-grok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        setenv("CROK_FIXTURE_REPLAY", trace, 1)
        setenv("CROK_FIXTURE_REPLAY_BY_TURN", "1", 1)
        setenv("CROK_FIXTURE_REPLAY_SPEED", environment["CROK_TRACE_SPEED"] ?? "4", 1)
        setenv("CROK_FIXTURE_REPLAY_MAX_GAP", "3", 1)
        setenv("CROK_FIXTURE_REPLAY_FAST_TURNS", environment["CROK_TRACE_FAST_TURNS"] ?? "0", 1)
        if let piece = environment["CROK_TRACE_PIECE"] {
            setenv("CROK_FIXTURE_REPLAY_PIECE", piece, 1)
            // Longer than the 33 ms a batch of updates waits, so each piece is shown.
            setenv("CROK_FIXTURE_CHUNK_SECONDS", environment["CROK_TRACE_CHUNK_SECONDS"] ?? "0.04", 1)
        }
        if let burst = environment["CROK_TRACE_BURST"] { setenv("CROK_FIXTURE_REPLAY_BURST", burst, 1) }
        let report = URL(fileURLWithPath: environment["CROK_TRACE_SAMPLE"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("grok-trace-replay-hang-\(UUID().uuidString).txt").path)
        watchdog.start(limit: 6, report: report)
    }

    override func tearDown() async throws {
        watchdog.stop()
        window?.contentView = nil
        store?.shutdown()
        for key in Self.fixtureSettings { unsetenv(key) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The recording's session updates, as its harness wrote them.
    private func records() throws -> [[String: Any]] {
        let html = try String(contentsOfFile: try XCTUnwrap(trace), encoding: .utf8)
        let open = try XCTUnwrap(html.range(of: "<script type=\"application/json\" id=\"trace-data\">"))
        let close = try XCTUnwrap(html.range(of: "</script>", range: open.upperBound..<html.endIndex))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any])
        let events = (data["events"] as? [[String: Any]] ?? []).filter { $0["source"] as? String == "updates.jsonl" }
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return events.compactMap { $0["raw"] as? [String: Any] }.filter { ($0["params"] as? [String: Any])?["update"] is [String: Any] }
    }

    private func update(_ record: [String: Any]) -> [String: Any] { (record["params"] as? [String: Any])?["update"] as? [String: Any] ?? [:] }
    private func kind(_ record: [String: Any]) -> String { update(record)["sessionUpdate"] as? String ?? "" }

    /// The text of the recording's chunks of one kind; a recording keeps each reply as one chunk.
    private func texts(_ records: [[String: Any]], of kind: String) -> [String] {
        records.filter { self.kind($0) == kind }.compactMap { (update($0)["content"] as? [String: Any])?["text"] as? String }.filter { !$0.isEmpty }
    }

    private var windowSize: CGSize {
        let parts = (environment["CROK_TRACE_WINDOW"] ?? "1320x780").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1320, height: 780)
    }

    /// A launch: a store on the state file, and the main window on it.
    private func launch() {
        window?.contentView = nil
        store?.shutdown()
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
        if store.state.conversations.isEmpty {
            // A folder outside Git: the footer says so, and the Files tab reads the disk.
            let project = Project(path: directory.appendingPathComponent("project").path)
            store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        }
        if let tab = environment["CROK_TRACE_SIDE_PANEL"].flatMap(SidePanelTab.init(rawValue:)) {
            store.sidePanelTab = tab
            store.showInspector = true
        }
        if environment["CROK_TRACE_TIMELINE"] != nil { store.features.transcript.setTimeline(true) }
        if environment["CROK_TRACE_TIMESTAMPS"] != nil { store.features.transcript.setTimestamps(true) }
        host = NSHostingView(rootView: AnyView(ContentView().desktopEnvironment(store)))
        host.frame = CGRect(origin: .zero, size: windowSize)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
    }

    private var slowest: (ms: Double, note: String) = (0, "")

    /// Display cycles for `seconds`: a layout and a draw every frame.
    private func shown(_ seconds: Double, _ note: String) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            watchdog.mark(note)
            let started = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if took > slowest.ms { slowest = (took, note) }
            watchdog.mark(note + " (between frames)")
            try await Task.sleep(nanoseconds: 16_000_000)
        } while Date() < deadline
    }

    private func send(_ prompt: String, _ note: String) async throws {
        let ready = Date().addingTimeInterval(20)
        try await shown(0.3, note + ": before sending")
        while (store.run.isConfiguring || store.run.isRunning) && Date() < ready { try await shown(0.1, note + ": waiting to send") }
        store.draft = prompt
        store.send()
        let started = Date().addingTimeInterval(20)
        while !store.run.isRunning && Date() < started { try await shown(0.05, note + ": starting") }
        let deadline = Date().addingTimeInterval(600)
        while store.run.isRunning && Date() < deadline { try await shown(0.05, note + ": streaming") }
        XCTAssertFalse(store.run.isRunning, "\(note) finished (phase \(store.run.phase), banner \(store.banner ?? "none"))")
        try await shown(2, note + ": after the turn")
        print("TRACE-REPLAY \(note): \(store.conversation?.messages.count ?? 0) messages, phase \(store.run.phase), slowest frame \(String(format: "%.0f", slowest.ms)) ms during \(slowest.note)")
    }

    private func shot(_ name: String) {
        guard let folder = environment["CROK_TRACE_SHOTS"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    private func resize(to size: CGSize) async throws {
        host.frame = CGRect(origin: .zero, size: size)
        window.setContentSize(size)
        try await shown(0, "resizing to \(Int(size.width)) × \(Int(size.height))")
    }

    func testTheRecordedSessionReplaysAsItWasSent() async throws {
        let records = try records()
        let prompts = texts(records, of: "user_message_chunk")
        XCTAssertFalse(prompts.isEmpty, "the recording has a prompt")
        launch()
        try await send(prompts[0], "turn 1")
        shot("turn1")
        // A relaunch: the task is selected, and its session is loaded with the harness's history.
        if environment["CROK_TRACE_NO_RELAUNCH"] == nil, prompts.count > 1, let session = store.conversation?.sessionID {
            let first = records.firstIndex { kind($0) == "turn_completed" } ?? records.count - 1
            let file = directory.appendingPathComponent("history.json")
            try JSONSerialization.data(withJSONObject: [session: Array(records[...first])]).write(to: file)
            setenv("CROK_FIXTURE_HISTORY", file.path, 1)
            store.flush()
            launch()
            try await shown(3, "relaunch")
            shot("relaunch")
            print("TRACE-REPLAY relaunch: \(store.conversation?.messages.count ?? 0) messages, phase \(store.run.phase)")
        }
        for (index, prompt) in prompts.enumerated().dropFirst() {
            try await send(prompt, "turn \(index + 1)")
            shot("turn\(index + 1)")
        }
        try await shown(Double(environment["CROK_TRACE_WAIT"] ?? "8") ?? 8, "waiting after the last turn")
        // The window resized as a drag does it, a few points at a time: narrower, wider, shorter.
        let size = windowSize
        for width in stride(from: size.width, through: 920, by: -3) { try await resize(to: CGSize(width: width, height: size.height)) }
        for width in stride(from: 920, through: size.width + 400, by: 7) { try await resize(to: CGSize(width: width, height: size.height)) }
        for height in stride(from: size.height, through: 650, by: -5) { try await resize(to: CGSize(width: size.width, height: height)) }
        shot("end")
        XCTAssertFalse((store.conversation?.messages ?? []).isEmpty)
        print("TRACE-REPLAY done: \(store.conversation?.messages.count ?? 0) messages, slowest frame \(String(format: "%.0f", slowest.ms)) ms during \(slowest.note)")
    }

    /// The kinds of block in a document, nested ones included, that TextKit lays out as text blocks.
    private func blockKinds(_ blocks: [MarkdownBlock]) -> Set<String> {
        var kinds = Set<String>()
        for block in blocks {
            switch block {
            case .paragraph, .heading: break
            case .list(let list): for item in list.items { kinds.formUnion(blockKinds(item.content)) }
            case .quote(let inner): kinds.insert("quote"); kinds.formUnion(blockKinds(inner))
            case .callout(_, _, let inner): kinds.insert("callout"); kinds.formUnion(blockKinds(inner))
            case .footnoteDefinition(_, let inner): kinds.formUnion(blockKinds(inner))
            case .code: kinds.insert("code")
            case .math: kinds.insert("math")
            case .table: kinds.insert("table")
            case .thematicBreak: kinds.insert("rule")
            case .html: kinds.insert("html")
            }
        }
        return kinds
    }

    /// Prints, for each reply and reasoning text of the recording, the partial texts that hold a block
    /// the finished text does not: what a stream draws for a moment and then takes away. None may
    /// be left once an unsettled last line waits (see `StreamingMarkdown`).
    func testWhichPartialTextsHoldABlockTheFinishedTextDoesNot() throws {
        let records = try records()
        for (number, text) in (texts(records, of: "agent_message_chunk") + texts(records, of: "agent_thought_chunk")).enumerated() {
            let scalars = Array(text.unicodeScalars)
            let final = blockKinds(MarkdownParser.parse(text))
            var passing: [(kinds: Set<String>, at: Int)] = []
            for end in 0...scalars.count {
                watchdog.mark("parsing text \(number), prefix \(end)")
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<end])
                let prefix = String(view)
                let kinds = blockKinds(MarkdownParser.parse(prefix)).subtracting(final)
                if !kinds.isEmpty { passing.append((kinds, end)) }
                XCTAssertTrue(blockKinds(MarkdownParser.parse(StreamingMarkdown.settled(prefix))).subtracting(final).isEmpty,
                              "text \(number) shows \(kinds.sorted()) for a moment after \(end) characters")
            }
            guard !passing.isEmpty else { continue }
            let summary = Dictionary(grouping: passing, by: { $0.kinds.sorted().joined(separator: "+") }).map { "\($0.value.count) × \($0.key)" }.sorted()
            print("TRACE-REPLAY text \(number) (\(scalars.count) characters): as it stands, its partial texts pass through \(summary.joined(separator: ", "))")
        }
    }
}
