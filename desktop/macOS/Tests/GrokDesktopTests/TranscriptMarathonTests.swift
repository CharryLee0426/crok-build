import XCTest
import SwiftUI
@testable import GrokDesktop

/// A session of the size the AppKit transcript was built for, from the harness to the screen:
/// 3,000 rounds arrive at once, each with reasoning (a line, a paragraph, or pages), three
/// commands that ran together (a few lines, a screen, or hundreds of lines of output), and a
/// reply (every fifth one in every Markdown format); then rounds keep streaming at a model's
/// pace while the window is dragged to other sizes, taken to a screen's size and back as full
/// screen does, and the reader scrolls, jumps, searches, and opens blocks.
///
/// The window is never on screen: a frame is a layout and a draw 30 times a second, as the
/// display cycle of a visible window runs them. Takes a couple of minutes, so it runs with
/// CROK_DESKTOP_UI_TESTS=1, against the offline fixture's `fixture:marathon` turn.
/// CROK_MARATHON_ROUNDS sets how many rounds arrive at once (3,000), and with
/// CROK_TRANSCRIPT_SHOTS a folder receives pictures along the way.
@MainActor
final class TranscriptMarathonTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var host: NSHostingView<AnyView>!
    private var window: NSWindow!

    private var rounds: Int { Int(ProcessInfo.processInfo.environment["CROK_MARATHON_ROUNDS"] ?? "") ?? 3_000 }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_UI_TESTS"] != nil else {
            throw XCTSkip("Set CROK_DESKTOP_UI_TESTS=1 to stream a 3,000-round session through the transcript (a couple of minutes)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-marathon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let executable = directory.appendingPathComponent("fixture-grok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        host = NSHostingView(rootView: AnyView(ConversationView().desktopEnvironment(store).background(Theme.canvas)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
    }

    override func tearDown() async throws {
        window?.contentView = nil
        store?.shutdown()
        unsetenv("CROK_FIXTURE_CHUNK_SECONDS")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var tools: TranscriptToolsModel { store.features.transcript }
    private var messages: [Message] { store.conversation?.messages ?? [] }

    private var list: TranscriptListView? {
        func find(_ view: NSView) -> TranscriptListView? { (view as? TranscriptListView) ?? view.subviews.lazy.compactMap(find).first }
        return find(host)
    }

    /// How long each frame's layout and draw took, in milliseconds, and the frames that showed no row.
    private var frameTimes: [Double] = []
    private var blankFrames = 0

    /// Display cycles for `seconds`: a layout and a draw every frame. `each` runs before every frame.
    private func shown(_ seconds: Double, each: ((Int) -> Void)? = nil) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var frame = 0
        while Date() < deadline {
            let start = DispatchTime.now().uptimeNanoseconds
            each?(frame)
            frame += 1
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            frameTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if !messages.isEmpty, list?.topVisibleRow == nil { blankFrames += 1 }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func distanceFromEnd(file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let sample = try XCTUnwrap(tools.lastScrollSample, "the transcript says where it is scrolled", file: file, line: line)
        return sample.contentHeight - sample.offsetY - sample.viewportHeight
    }

    private func resize(_ size: CGSize) {
        host.frame = CGRect(origin: .zero, size: size)
        window.setContentSize(size)
    }

    private func picture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_SHOTS"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("marathon-\(name).png"))
    }

    private func summary(_ label: String, from start: Int = 0) -> String {
        let ordered = frameTimes[start...].sorted()
        func percentile(_ p: Double) -> Double { ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))] }
        return String(format: "PERF marathon %@: %d frames, frame p50 %.1f p95 %.1f p99 %.1f max %.1f ms, over 33 ms %d", label, ordered.count,
                      percentile(50), percentile(95), percentile(99), ordered.last ?? 0, ordered.filter { $0 > 33 }.count)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func testAThreeThousandRoundSessionStreamsResizesAndScrolls() async throws {
        setenv("CROK_FIXTURE_CHUNK_SECONDS", "0.01", 1)
        // The conversation view asks the harness for its models first; a prompt waits for that.
        try await shown(0.3)
        let configured = Date().addingTimeInterval(20)
        while store.run.isConfiguring && Date() < configured { try await shown(0.1) }
        store.draft = "fixture:marathon:\(rounds):100000"
        let sent = Date()
        store.send()

        // The rounds that arrive at once: five messages each, the reasoning first.
        let expected = rounds * 5
        let filled = Date().addingTimeInterval(240)
        while messages.count < expected, Date() < filled { try await shown(0.2) }
        let fill = Date().timeIntervalSince(sent)
        XCTAssertGreaterThanOrEqual(messages.count, expected, "the rounds arrived (phase \(store.run.phase), banner \(store.banner ?? "none"))")
        XCTAssertGreaterThanOrEqual(messages.filter { $0.kind == .thought }.count, rounds, "with their reasoning")
        print(String(format: "PERF marathon fill: %d messages (%d reasoning blocks, %d commands) in %.1f s; %@", messages.count,
                     messages.filter { $0.kind == .thought }.count, messages.filter { $0.kind == .tool }.count, fill, summary("while filling")))
        let list = try XCTUnwrap(self.list, "the transcript is the AppKit list")
        XCTAssertLessThan(list.realizedRowCount, 120, "a screenful of rows has views, of \(list.rowCount)")
        XCTAssertTrue(store.run.isRunning, "and the turn streams on")
        picture("filled")

        // Streaming at a model's pace, followed.
        var mark = frameTimes.count
        let cpuStart = Self.cpuSeconds(), countStart = messages.count
        try await shown(8)
        print(summary("streaming, followed", from: mark) + String(format: ", CPU %.1f s for %d messages over 8 s", Self.cpuSeconds() - cpuStart, messages.count - countStart))
        XCTAssertGreaterThan(messages.count, countStart, "messages keep arriving")
        XCTAssertLessThanOrEqual(try distanceFromEnd(), 40, "the end is in sight while streaming")
        XCTAssertTrue(tools.isFollowingOutput)
        XCTAssertEqual(tools.viewport.topMessageIndex.map { $0 > messages.count - 60 }, true, "the newest rows are on screen")
        picture("streaming")

        // Dragged to other sizes while it streams: a frame at every size.
        mark = frameTimes.count
        try await shown(4) { frame in
            let step = Double(frame % 60)
            self.resize(CGSize(width: 900 - (step < 30 ? step : 60 - step) * 11, height: 760 - Double(frame % 9) * 8))
        }
        print(summary("resizing while streaming", from: mark))
        XCTAssertLessThanOrEqual(try distanceFromEnd(), 40, "still at the end after the drag")
        // To a screen's size and back, as entering and leaving full screen does, more than once.
        mark = frameTimes.count
        for size in [CGSize(width: 1_728, height: 1_117), CGSize(width: 900, height: 760), CGSize(width: 2_560, height: 1_440), CGSize(width: 560, height: 650), CGSize(width: 1_440, height: 900), CGSize(width: 900, height: 760)] {
            try await shown(0.7) { frame in if frame == 0 { self.resize(size) } }
            XCTAssertLessThanOrEqual(try distanceFromEnd(), 40, "at \(size) the end is in sight")
            XCTAssertEqual(tools.viewport.topMessageIndex.map { $0 > messages.count - 80 }, true, "and the newest rows are, at \(size)")
            XCTAssertLessThan(list.realizedRowCount, 160)
            picture("size-\(Int(size.width))")
        }
        print(summary("full screen sizes while streaming", from: mark))
        XCTAssertTrue(tools.isFollowingOutput, "followed throughout")

        // The reader goes to the middle of the task: a message that has never been laid out.
        mark = frameTimes.count
        let middle = messages[messages.count / 2]
        tools.requestScroll(.message(middle.id))
        try await shown(0.5)
        XCTAssertFalse(tools.isFollowingOutput)
        XCTAssertEqual(tools.viewport.topMessageIndex, messages.count / 2 == 0 ? 0 : messages.firstIndex { $0.id == middle.id }, "the message asked for is first in sight")
        let offset = try XCTUnwrap(tools.lastScrollSample).offsetY
        let arrivedBefore = messages.count
        try await shown(3)
        XCTAssertGreaterThan(messages.count, arrivedBefore, "output arrived meanwhile")
        XCTAssertEqual(try XCTUnwrap(tools.lastScrollSample).offsetY, offset, accuracy: 1, "and did not move what the reader is looking at")
        // The window changes size under a reader in the middle: their message stays first.
        for size in [CGSize(width: 1_728, height: 1_117), CGSize(width: 700, height: 700), CGSize(width: 900, height: 760)] {
            resize(size)
            try await shown(0.5)
            XCTAssertEqual(tools.viewport.topMessageIndex, messages.firstIndex { $0.id == middle.id }, "at \(size) the reader's message is still first")
        }
        picture("middle")

        // Opening blocks there: reasoning and a command's output.
        let around = try XCTUnwrap(messages.firstIndex { $0.id == middle.id })
        let thought = try XCTUnwrap(messages[around...].first { $0.kind == .thought })
        let command = try XCTUnwrap(messages[around...].first { $0.kind == .tool })
        tools.setExpanded(thought.id, true)
        tools.setExpanded(command.id, true)
        try await shown(0.5)
        XCTAssertEqual(tools.viewport.topMessageIndex, around, "opening blocks keeps the reader's place")
        picture("opened")
        print(summary("in the middle", from: mark))

        // Find, across everything.
        mark = frameTimes.count
        tools.openFind("Round 18 in full")
        let found = Date().addingTimeInterval(20)
        while tools.findMatches.isEmpty, Date() < found { try await shown(0.2) }
        XCTAssertFalse(tools.findMatches.isEmpty, "find reaches a reply near the start of the task")
        try await shown(0.5)
        let match = try XCTUnwrap(tools.currentFindMessageID)
        XCTAssertEqual(tools.viewport.topMessageIndex, messages.firstIndex { $0.id == match }, "and shows it")
        picture("found")
        tools.closeFind()
        print(summary("find", from: mark))

        // Back to the end: followed again, and still streaming.
        mark = frameTimes.count
        tools.requestScroll(.bottom)
        try await shown(3)
        XCTAssertTrue(tools.isFollowingOutput)
        XCTAssertLessThanOrEqual(try distanceFromEnd(), 40)
        print(summary("followed again", from: mark))
        XCTAssertEqual(blankFrames, 0, "no frame of \(frameTimes.count) showed a transcript without rows")
        print(summary("in all") + ", \(messages.count) messages at the end, \(list.realizedRowCount) rows with views")

        // Stopping the turn leaves the transcript as it is.
        store.cancel()
        let stopped = Date().addingTimeInterval(10)
        while store.run.isRunning, Date() < stopped { try await shown(0.2) }
        XCTAssertFalse(store.run.isRunning)
        XCTAssertLessThanOrEqual(try distanceFromEnd(), 40)
        picture("stopped")
    }
}
