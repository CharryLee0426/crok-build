import XCTest
import SwiftUI
@testable import GrokDesktop

/// What the side panel costs the conversation beside it: a task streams at a model's pace while
/// the panel is closed and while it shows each of its tabs in turn, and the main window is laid
/// out from a saved state as a launch does.
///
/// Measured offscreen like `TranscriptVisibilityTests` (a layout and a draw 30 times a second in a
/// window that is never shown), so it needs no screen and runs with CROK_DESKTOP_UI_TESTS=1; build
/// it optimized for numbers worth quoting (`swift build -c release --build-tests -Xswiftc -enable-testing`).
/// It uses only what Crok Desktop 1.2.1 already had, so the same file measures an older tree too;
/// tabs added since are picked up from `SidePanelTab.allCases`. CROK_SIDE_PANEL_SECONDS (6) is how
/// long each tab is measured per pass, CROK_SIDE_PANEL_PASSES (2) how many passes, and
/// CROK_SIDE_PANEL_TABS ("closed,files,…") which of them, to profile one.
@MainActor
final class SidePanelPerformanceTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var host: NSHostingView<AnyView>!
    private var window: NSWindow!

    /// The conversation and, when open, the side panel, as the main window lays them out.
    private struct Scene: View {
        @EnvironmentObject var store: AppStore

        var body: some View {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ConversationView().frame(maxWidth: .infinity)
                    if store.showInspector { SidePanelView(containerWidth: geometry.size.width) }
                }
            }
        }
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_UI_TESTS"] != nil else {
            throw XCTSkip("Set CROK_DESKTOP_UI_TESTS=1 to measure the side panel beside a streaming task (about a minute)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-side-panel-perf-\(UUID().uuidString)", isDirectory: true)
        // A project with enough files for the Files tab to have a tree to show.
        for folder in 0..<12 {
            let path = directory.appendingPathComponent("project/Sources/Module\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            for file in 0..<25 { try Data("// file \(file)\nlet value = \(file)\n".utf8).write(to: path.appendingPathComponent("File\(file).swift")) }
        }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let executable = directory.appendingPathComponent("fixture-grok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    override func tearDown() async throws {
        window?.contentView = nil
        store?.shutdown()
        unsetenv("CROK_FIXTURE_CHUNK_SECONDS")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore(state: DesktopState? = nil) -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString)/state.json"),
                             binaryPath: directory.appendingPathComponent("fixture-grok").path)
        let project = Project(path: directory.appendingPathComponent("project").path)
        store.state = state ?? DesktopState(projects: [project], selectedProjectID: project.id)
        return store
    }

    private func show<V: View>(_ view: V, size: CGSize) {
        host = NSHostingView(rootView: AnyView(view.desktopEnvironment(store).background(Theme.canvas)))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
    }

    /// One display cycle; returns how long its layout and draw took, in milliseconds.
    @discardableResult
    private func frame() -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Display cycles for `seconds`, 30 a second; returns each frame's time.
    @discardableResult
    private func shown(_ seconds: Double) async throws -> [Double] {
        var times: [Double] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            times.append(frame())
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        return times
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let ordered = values.sorted()
        return ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))]
    }

    private struct Sample {
        var frames: [Double] = []
        var cpu = 0.0
        var wall = 0.0
        var messages = 0
    }

    private static func report(_ name: String, _ sample: Sample) {
        print(String(format: "PERF side panel streaming [%@]: %d frames, frame p50 %.2f p95 %.2f p99 %.2f max %.1f ms, over 16 ms %d, CPU %.0f%% of a core, %.0f messages/s",
                     name, sample.frames.count, percentile(sample.frames, 50), percentile(sample.frames, 95), percentile(sample.frames, 99), sample.frames.max() ?? 0,
                     sample.frames.filter { $0 > 16 }.count, sample.wall > 0 ? sample.cpu / sample.wall * 100 : 0, sample.wall > 0 ? Double(sample.messages) / sample.wall : 0))
    }

    func testATaskStreamsAsSmoothlyBesideEveryTab() async throws {
        store = makeStore()
        show(Scene(), size: CGSize(width: 1400, height: 800))
        let seconds = Double(ProcessInfo.processInfo.environment["CROK_SIDE_PANEL_SECONDS"] ?? "6") ?? 6
        let passes = Int(ProcessInfo.processInfo.environment["CROK_SIDE_PANEL_PASSES"] ?? "2") ?? 2

        // 125 rounds at once, then rounds at a model's pace for longer than the test.
        setenv("CROK_FIXTURE_CHUNK_SECONDS", "0.01", 1)
        let configured = Date().addingTimeInterval(20)
        try await shown(0.3)
        while store.run.isConfiguring && Date() < configured { try await shown(0.1) }
        store.draft = "fixture:mixed:125:2000"
        store.send()
        let started = Date().addingTimeInterval(20)
        while !(store.run.isRunning && (store.conversation?.messages.count ?? 0) > 240) && Date() < started { try await shown(0.1) }
        XCTAssertTrue(store.run.isRunning, "the task is streaming (phase \(store.run.phase), banner \(store.banner ?? "none"))")
        try await shown(2)

        // Closed, then each tab, and back again in the other order: what arrives later in the turn is spread
        // over all of them, and none is always measured just after the terminal, whose shell is still starting.
        var samples: [String: Sample] = [:]
        let chosen = ProcessInfo.processInfo.environment["CROK_SIDE_PANEL_TABS"]?.split(separator: ",").map(String.init)
        let configurations: [(name: String, tab: SidePanelTab?)] = ([("closed", nil)] + SidePanelTab.allCases.map { ($0.rawValue, $0) })
            .filter { chosen?.contains($0.0) ?? true }
        for pass in 0..<passes {
            for configuration in pass % 2 == 0 ? configurations : configurations.reversed() {
                if let tab = configuration.tab {
                    store.sidePanelTab = tab
                    store.showInspector = true
                } else {
                    store.showInspector = false
                }
                // The switch itself, and what the tab loads as it appears, are not the steady state.
                try await shown(1)
                let cpu = Self.cpuSeconds(), wall = Date(), messages = store.conversation?.messages.count ?? 0
                let frames = try await shown(seconds)
                var sample = samples[configuration.name] ?? Sample()
                sample.frames += frames
                sample.cpu += Self.cpuSeconds() - cpu
                sample.wall += Date().timeIntervalSince(wall)
                sample.messages += (store.conversation?.messages.count ?? 0) - messages
                samples[configuration.name] = sample
                XCTAssertTrue(store.run.isRunning, "the task is still streaming beside \(configuration.name)")
            }
        }
        for configuration in configurations { Self.report(configuration.name, samples[configuration.name] ?? Sample()) }
        // An open panel narrows the conversation and is laid out with it; that may cost the frames that
        // carry a new message a little, whatever the panel shows, and no more. The 99th percentile is
        // those frames: most frames have nothing new to lay out, which makes the 95th jump about.
        guard let closed = samples["closed"].map({ Self.percentile($0.frames, 99) }) else { return }
        for configuration in configurations where configuration.tab != nil {
            let open = Self.percentile(samples[configuration.name]?.frames ?? [], 99)
            XCTAssertLessThan(open, closed * 1.5 + 3, "frames beside \(configuration.name) (p99 \(open) ms) against the panel closed (p99 \(closed) ms)")
        }
    }

    func testSwitchingTabsAndOpeningThePanel() async throws {
        let project = Project(path: directory.appendingPathComponent("project").path)
        let now = Date()
        let messages = (0..<60).map { index in
            Message(kind: index % 2 == 0 ? .user : .assistant, text: index % 2 == 0 ? "Question \(index): what does `Module\(index % 12)` do?"
                : "It declares **\(index)** values.\n\n```swift\nlet value = \(index)\n```\n\n- one\n- two", createdAt: now)
        }
        let task = Conversation(projectID: project.id, title: "Read the modules", messages: messages)
        store = makeStore(state: DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id))
        show(Scene(), size: CGSize(width: 1400, height: 800))
        try await shown(1.5)

        // Opening and closing the panel.
        var opening: [Double] = [], closing: [Double] = []
        store.sidePanelTab = .files
        for _ in 0..<8 {
            store.showInspector = true
            opening.append(frame())
            try await shown(0.4)
            store.showInspector = false
            closing.append(frame())
            try await shown(0.3)
        }
        print(String(format: "PERF side panel open: median %.1f ms, max %.1f ms; close: median %.1f ms, max %.1f ms",
                     Self.percentile(opening, 50), opening.max() ?? 0, Self.percentile(closing, 50), closing.max() ?? 0))

        // Switching to each tab from the one before it. The first visit loads the tab; later ones only show it.
        store.showInspector = true
        try await shown(0.5)
        var first: [String: Double] = [:], later: [String: [Double]] = [:]
        for round in 0..<8 {
            for tab in SidePanelTab.allCases {
                store.sidePanelTab = tab
                let time = frame()
                if round == 0 { first[tab.rawValue] = time } else { later[tab.rawValue, default: []].append(time) }
                try await shown(0.35)
            }
        }
        for tab in SidePanelTab.allCases {
            let times = later[tab.rawValue] ?? []
            print(String(format: "PERF side panel switch to [%@]: first %.1f ms, then median %.1f ms, max %.1f ms",
                         tab.rawValue, first[tab.rawValue] ?? 0, Self.percentile(times, 50), times.max() ?? 0))
            XCTAssertLessThan(Self.percentile(times, 50), 250, "switching to \(tab.rawValue) is one frame's work")
        }
    }

    func testLayingOutTheMainWindowFromASavedState() async throws {
        // 40 tasks of 200 messages each, as a state file a few weeks old holds. With CROK_LAUNCH_TABLES=1 every
        // reply ends in a small table instead of a list. Crok Desktop 1.2.1 never finishes laying that out
        // (see TableLayoutTests), so run that variant against an older tree under a watchdog.
        // CROK_LAUNCH_MESSAGES sets how long each task is (200), to see how that layout grows.
        let tables = ProcessInfo.processInfo.environment["CROK_LAUNCH_TABLES"] == "1"
        let length = Int(ProcessInfo.processInfo.environment["CROK_LAUNCH_MESSAGES"] ?? "") ?? 200
        let project = Project(path: directory.appendingPathComponent("project").path)
        let now = Date()
        let tasks = (0..<40).map { task in
            Conversation(projectID: project.id, title: "Task \(task): tidy `Module\(task % 12)`", messages: (0..<length).map { index in
                Message(kind: index % 2 == 0 ? .user : .assistant, text: index % 2 == 0 ? "Step \(index) of task \(task)."
                    : "Done with step \(index).\n\n```swift\nlet step = \(index)\n```\n\n" + (tables ? "| a | b |\n| - | - |\n| \(task) | \(index) |" : "- \(task)\n- \(index)"), createdAt: now)
            })
        }
        let stateFile = directory.appendingPathComponent("launch/state.json")
        let seed = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        seed.state = DesktopState(projects: [project], conversations: tasks, selectedProjectID: project.id, selectedConversationID: tasks[0].id)
        seed.save()
        seed.shutdown()
        let saved = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: stateFile.path) && Date() < saved { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))

        var loads: [Double] = [], layouts: [Double] = []
        for _ in 0..<6 {
            let start = DispatchTime.now().uptimeNanoseconds
            let launched = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
            _ = launched.features
            let loaded = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(launched.state.conversations.count, 40)
            store = launched
            show(ContentView(), size: CGSize(width: 1320, height: 780))
            frame()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            loads.append(Double(loaded - start) / 1_000_000)
            layouts.append(Double(laidOut - loaded) / 1_000_000)
            try await shown(0.3)
            window.contentView = nil
            launched.shutdown()
        }
        // The first pass also warms fonts and SwiftUI itself; a launch pays that once, in every version.
        print(String(format: "PERF main window from a saved state (40 tasks of %d messages%@): load state %.0f ms first, %.0f ms median; first layout and draw %.0f ms first, %.0f ms median",
                     length, tables ? ", replies ending in tables" : "", loads[0], Self.percentile(Array(loads.dropFirst()), 50), layouts[0], Self.percentile(Array(layouts.dropFirst()), 50)))
    }
}
