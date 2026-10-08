import XCTest
import SwiftUI
@testable import GrokDesktop

/// A task streams on for hundreds of messages, with rows of very different heights, while its
/// window is drawn and while it is away (on another Space, behind a full-screen app). Crok
/// Desktop 1.2.0, whose rows were a SwiftUI lazy stack, went blank under the Following button
/// after a few hundred messages and stayed blank for the rest of the turn. It must keep showing
/// its newest messages.
///
/// The window here is never on screen: "shown" is a layout and a draw 30 times a second, as the
/// display cycle of a visible window runs them, and "away" is none. Takes about a minute, so it
/// runs with CROK_DESKTOP_UI_TESTS=1, against the offline fixture's `fixture:mixed` turn, or
/// against a recorded session named by CROK_TRANSCRIPT_REPLAY (a trace export or updates.jsonl).
/// CROK_TRANSCRIPT_AWAY_CYCLES and CROK_TRANSCRIPT_AWAY_SECONDS set the cycles; with
/// CROK_TRANSCRIPT_SHOTS a folder receives each cycle's picture, and with CROK_TRANSCRIPT_DIAGNOSE
/// the rows around every large jump of the content's height are printed.
@MainActor
final class TranscriptVisibilityTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var host: NSHostingView<AnyView>!
    private var window: NSWindow!

    private var replay: String? { ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_REPLAY"] }
    /// Messages enough that most of them are far out of sight.
    private static let longTask = 240

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_UI_TESTS"] != nil || replay != nil else {
            throw XCTSkip("Set CROK_DESKTOP_UI_TESTS=1 to stream a long task through the transcript (about a minute)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-visibility-\(UUID().uuidString)", isDirectory: true)
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
        for key in ["CROK_FIXTURE_REPLAY", "CROK_FIXTURE_REPLAY_SPEED", "CROK_FIXTURE_REPLAY_FAST_TURNS", "CROK_FIXTURE_REPLAY_MAX_GAP", "CROK_FIXTURE_CHUNK_SECONDS"] {
            unsetenv(key)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Frames drawn while following a transcript that showed none of its rows, and the longest run of them.
    private var blankFrames = 0, blankRun = 0, longestBlankRun = 0, frames = 0
    /// How long each frame's layout and draw took, in milliseconds.
    private var frameTimes: [Double] = []

    /// Display cycles for `seconds`: a layout and a draw every frame.
    private func shown(_ seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            frameTimes.append(Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000)
            frames += 1
            // No row reported on screen, and nothing drawn: a row far taller than the window can show without being reported.
            if store.features.transcript.isFollowingOutput, !(store.conversation?.messages ?? []).isEmpty,
               store.features.transcript.viewport.topMessageIndex == nil, (try? inkedFraction()).map({ $0 < 0.02 }) ?? true {
                blankFrames += 1
                blankRun += 1
                longestBlankRun = max(longestBlankRun, blankRun)
            } else {
                blankRun = 0
            }
            diagnose()
            try await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private var lastContentHeight: CGFloat?
    private var lastRows: [Message] = []

    /// With CROK_TRANSCRIPT_DIAGNOSE set: the rows around a frame whose content height jumps.
    private func diagnose() {
        guard ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_DIAGNOSE"] != nil else { return }
        let messages = store.conversation?.messages ?? []
        let height = store.features.transcript.lastScrollSample?.contentHeight
        defer { lastContentHeight = height; lastRows = messages }
        guard let height, let previous = lastContentHeight, abs(height - previous) > 3_000 else { return }
        func describe(_ message: Message) -> String {
            "\(message.kind) text \(message.text.utf8.count)B detail \(message.detail?.utf8.count ?? 0)B status \(message.status ?? "-") \(message.text.prefix(50).debugDescription)"
        }
        let old = Set(lastRows.map(\.id))
        print("TRANSCRIPT-DIAGNOSE content height \(Int(previous)) → \(Int(height)); messages \(lastRows.count) → \(messages.count)")
        for message in messages where !old.contains(message.id) { print("TRANSCRIPT-DIAGNOSE   new: \(describe(message))") }
        for (a, b) in zip(lastRows, messages) where a.id == b.id && (a.text != b.text || a.detail != b.detail || a.status != b.status) {
            print("TRANSCRIPT-DIAGNOSE   changed: \(describe(a)) → \(describe(b))")
        }
    }

    /// User and system CPU time of this process.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// No display cycles: the run loop still delivers the harness's updates.
    private func away(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// How much of the transcript's area is drawn in something other than the background.
    private func inkedFraction() throws -> Double {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // The transcript: below the title area, above the plan and composer, left of the Following button.
        let region = CGRect(x: 60, y: 40, width: 620, height: 380)
        let background = bitmap.colorAt(x: 4, y: bitmap.pixelsHigh / 2)
        var inked = 0, total = 0
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        for y in stride(from: Int(region.minY * scale), to: Int(region.maxY * scale), by: 3) {
            for x in stride(from: Int(region.minX * scale), to: Int(region.maxX * scale), by: 3) {
                total += 1
                guard let color = bitmap.colorAt(x: x, y: y), let background else { continue }
                let difference = abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > 0.08 { inked += 1 }
            }
        }
        return Double(inked) / Double(max(1, total))
    }

    private struct Look: CustomStringConvertible {
        var messages: Int
        var topVisible: Int?
        var inked: Double
        var scroll: TranscriptScrollSample?
        var description: String {
            let geometry = scroll.map { "offset \(Int($0.offsetY)) of content \(Int($0.contentHeight)), viewport \(Int($0.viewportHeight))" } ?? "no geometry"
            return "messages \(messages), top visible row \(topVisible.map(String.init) ?? "none"), inked \(String(format: "%.3f", inked)), \(geometry)"
        }
    }

    private func look(_ name: String) throws -> Look {
        let result = Look(messages: store.conversation?.messages.count ?? 0, topVisible: store.features.transcript.viewport.topMessageIndex,
                          inked: try inkedFraction(), scroll: store.features.transcript.lastScrollSample)
        if let folder = ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_SHOTS"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return result
    }

    private func start(prompt: String) async throws {
        // The conversation view asks the harness for its models first; a prompt waits for that.
        let configured = Date().addingTimeInterval(20)
        try await shown(0.3)
        while store.run.isConfiguring && Date() < configured { try await shown(0.1) }
        store.draft = prompt
        store.send()
        let deadline = Date().addingTimeInterval(20)
        while !(store.run.isRunning && (store.conversation?.messages.count ?? 0) > Self.longTask) && Date() < deadline {
            try await shown(0.1)
        }
        XCTAssertGreaterThan(store.conversation?.messages.count ?? 0, Self.longTask,
                             "the task is a long one (phase \(store.run.phase), banner \(store.banner ?? "none"))")
    }

    func testALongStreamingTaskKeepsShowingItsNewestMessages() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Row visibility is reported on macOS 15 and later") }
        if let replay {
            setenv("CROK_FIXTURE_REPLAY", replay, 1)
            setenv("CROK_FIXTURE_REPLAY_SPEED", ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_REPLAY_SPEED"] ?? "4", 1)
            setenv("CROK_FIXTURE_REPLAY_FAST_TURNS", "10", 1)
            setenv("CROK_FIXTURE_REPLAY_MAX_GAP", "5", 1)
            try await start(prompt: "fixture:replay")
        } else {
            // 125 rounds at once (375 messages of varied heights), then rounds at a model's pace for longer than the test.
            setenv("CROK_FIXTURE_CHUNK_SECONDS", "0.01", 1)
            try await start(prompt: "fixture:mixed:125:2000")
        }
        try await shown(2)
        frameTimes.removeAll()
        let cpuStart = Self.cpuSeconds(), messagesStart = store.conversation?.messages.count ?? 0
        defer {
            let ordered = frameTimes.sorted()
            func percentile(_ p: Double) -> Double { ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))] }
            print(String(format: "PERF transcript streaming: %d messages, %d frames, frame p50 %.1f p95 %.1f p99 %.1f max %.1f ms, over 16 ms %d, CPU %.1f s, blank frames %d, longest blank %d",
                         (store.conversation?.messages.count ?? 0) - messagesStart, ordered.count, percentile(50), percentile(95), percentile(99), ordered.last ?? 0,
                         ordered.filter { $0 > 16 }.count, Self.cpuSeconds() - cpuStart, blankFrames, longestBlankRun))
        }
        let before = try look("before")
        XCTAssertNotNil(before.topVisible, "rows are on screen while streaming: \(before)")
        XCTAssertGreaterThan(before.inked, 0.02, "the transcript draws its rows: \(before)")

        let cycles = Int(ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_AWAY_CYCLES"] ?? "12") ?? 12
        let awaySeconds = Double(ProcessInfo.processInfo.environment["CROK_TRANSCRIPT_AWAY_SECONDS"] ?? "1") ?? 1
        // Half a second of frames: a longer blank is one the reader sees.
        let noticeable = 15
        for cycle in 1...cycles {
            let left = store.conversation?.messages.count ?? 0
            try await away(awaySeconds)
            try await shown(1.5)
            let after = try look("cycle\(cycle)")
            print("TRANSCRIPT-VISIBILITY cycle \(cycle): away \(awaySeconds)s, \(after.messages - left) messages arrived; \(after); "
                  + "blank frames \(blankFrames) of \(frames), longest \(longestBlankRun)")
            // A recording can end before the cycles do.
            guard store.run.isRunning else { print("TRANSCRIPT-VISIBILITY the turn ended at cycle \(cycle)"); break }
            try await shown(1)
        }
        try await shown(1)
        XCTAssertLessThanOrEqual(longestBlankRun, noticeable, "the transcript never stays blank: \(blankFrames) blank frames of \(frames)")
        XCTAssertNotNil(try look("end").topVisible, "the newest rows are on screen at the end")
    }
}
