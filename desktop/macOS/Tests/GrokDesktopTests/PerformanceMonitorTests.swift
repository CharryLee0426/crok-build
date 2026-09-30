import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import GrokDesktop

@MainActor
final class PerformanceMonitorTests: XCTestCase {
    // MARK: Availability

    func testOnlyWorkspaceTestBuildsCarryTheMonitorAndItStartsOn() {
        // The test runner is not a packaged test build, like a release app.
        XCTAssertFalse(PerformanceMonitorSettings.isAvailable)
        XCTAssertTrue(PerformanceMonitorSettings.enabledByDefault)
    }

    /// The overlay samples only in a test build with the setting on (the default), and stops when hidden.
    func testOverlaySamplesOnlyWhenAvailableAndTurnedOn() async throws {
        let suite = "GrokDesktopPerformanceMonitor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = PerformanceMonitor.shared

        func samples(available: Bool) async throws -> Int {
            let before = monitor.history.cpu.count
            let (window, host) = Self.host(PerformanceMonitorOverlay(available: available).defaultAppStorage(defaults))
            for _ in 0..<14 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            window.contentView = nil
            try await Task.sleep(nanoseconds: 100_000_000)
            return monitor.history.cpu.count - before
        }

        let releaseSamples = try await samples(available: false)
        XCTAssertEqual(releaseSamples, 0, "release builds never sample")
        let defaultSamples = try await samples(available: true)
        XCTAssertGreaterThanOrEqual(defaultSamples, 1, "on by default in a test build")

        let afterRemoval = monitor.history.cpu.count
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(monitor.history.cpu.count, afterRemoval, "sampling stops with the panel")

        defaults.set(false, forKey: PerformanceMonitorSettings.enabledKey)
        let disabledSamples = try await samples(available: true)
        XCTAssertEqual(disabledSamples, 0, "Settings turns it off")
    }

    /// The panel's only AppKit view is its display link probe, sized to the panel, so nothing native
    /// covers the rest of the window.
    func testOnlyThePanelCoversTheWindow() async throws {
        let suite = "GrokDesktopPerformanceMonitor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (window, host) = Self.host(PerformanceMonitorOverlay(available: true).defaultAppStorage(defaults))
        defer { window.contentView = nil }
        try await Self.settle(host)

        let probes = Self.subviews(of: host).compactMap { $0 as? PerformanceFrameProbeView }
        XCTAssertEqual(probes.count, 1)
        let frame = try XCTUnwrap(probes.first).convert(try XCTUnwrap(probes.first).bounds, to: nil)
        XCTAssertEqual(frame.width, PerformanceHUD.width, accuracy: 1)
        XCTAssertLessThan(frame.width * frame.height, host.bounds.width * host.bounds.height / 3)
        XCTAssertEqual(frame.maxX, host.bounds.width - 12, accuracy: 1, "starts at the top-trailing corner")
    }

    private static func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 800, height: 600)))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        return (window, host)
    }

    private static func settle(_ host: NSView) async throws {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews(of: $0) }
    }

    // MARK: Frames

    func testFrameWindowCountsRateDroppedFramesAndTheWorstGap() throws {
        var window = FrameWindow()
        let refresh = 1.0 / 120
        var time = 100.0
        for _ in 0..<60 {
            window.record(timestamp: time, target: time + refresh)
            time += refresh
        }
        // One frame took four refreshes: three were dropped.
        time += refresh * 3
        window.record(timestamp: time, target: time + refresh)

        let summary = try XCTUnwrap(window.drain())
        XCTAssertEqual(summary.refreshRate ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(summary.worst, refresh * 4 * 1000, accuracy: 0.01)
        XCTAssertEqual(summary.dropped, 3)
        XCTAssertEqual(summary.fps, 60 / (63 * refresh), accuracy: 0.01)
        XCTAssertNil(window.drain(), "each interval starts empty")
    }

    func testFrameWindowLeavesOutResumeGaps() throws {
        var window = FrameWindow()
        window.record(timestamp: 10, target: 10.016)
        window.record(timestamp: 10.016, target: 10.032)
        window.record(timestamp: 14, target: 14.016)
        window.record(timestamp: 14.016, target: 14.032)

        let summary = try XCTUnwrap(window.drain())
        XCTAssertEqual(summary.worst, 16, accuracy: 0.01)
        XCTAssertEqual(summary.dropped, 0)
    }

    func testFrameSummaryWithoutARefreshRateCountsNoDrops() throws {
        let summary = try XCTUnwrap(FrameSummary(intervals: [16, 40], refreshInterval: nil))
        XCTAssertEqual(summary.dropped, 0)
        XCTAssertNil(summary.refreshRate)
        XCTAssertNil(FrameSummary(intervals: [], refreshInterval: 16))
    }

    // MARK: Processes

    func testCPUPercentIsAShareOfOneCore() {
        XCTAssertEqual(cpuPercent(from: 1, to: 1.25, elapsed: 0.5), 50, accuracy: 0.001)
        XCTAssertEqual(cpuPercent(from: 1, to: 2.5, elapsed: 0.5), 300, accuracy: 0.001)
        XCTAssertEqual(cpuPercent(from: 2, to: 1, elapsed: 0.5), 0)
        XCTAssertEqual(cpuPercent(from: 1, to: 2, elapsed: 0), 0)
    }

    func testProcessProbeReadsThisProcessInSeconds() throws {
        let pid = getpid()
        let before = try XCTUnwrap(ProcessProbe.usage(of: pid))
        let rusageBefore = Self.selfCPUSeconds()
        var x = 0.0
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline { for i in 0..<10_000 { x += sin(Double(i)) } }
        XCTAssertFalse(x.isNaN)
        let after = try XCTUnwrap(ProcessProbe.usage(of: pid))
        let rusageAfter = Self.selfCPUSeconds()

        // Mach ticks converted to seconds agree with getrusage's microseconds.
        let probed = after.cpuSeconds - before.cpuSeconds
        let expected = rusageAfter - rusageBefore
        XCTAssertGreaterThan(expected, 0.2)
        XCTAssertEqual(probed, expected, accuracy: expected * 0.2)
        XCTAssertGreaterThan(after.footprint, 1_048_576)
        XCTAssertGreaterThan(ProcessProbe.threadCount(of: pid) ?? 0, 0)
    }

    func testProcessSamplerCountsChildProcesses() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }

        XCTAssertTrue(ProcessProbe.children(of: getpid()).contains(child.processIdentifier))
        var sampler = ProcessSampler()
        sampler.prime()
        let sample = sampler.sample(elapsed: 0.5)
        XCTAssertGreaterThanOrEqual(sample.children.count, 1)
        XCTAssertGreaterThan(sample.children.footprint, 0)
        XCTAssertNotNil(sample.cpu)
        XCTAssertNotNil(sample.footprint)
    }

    // MARK: Main thread

    func testWatchdogMeasuresABlockedMainThread() async throws {
        let watchdog = MainThreadWatchdog()
        watchdog.start(every: .milliseconds(20))
        defer { watchdog.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = watchdog.drain()
        Thread.sleep(forTimeInterval: 0.3)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(watchdog.drain(), 250)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(watchdog.drain(), 250, "a drained watchdog starts over")
    }

    func testMonitorTicksOnlyWhileStarted() async throws {
        let monitor = PerformanceMonitor()
        monitor.tick()
        XCTAssertNil(monitor.history.latest)

        monitor.start()
        let start = CACurrentMediaTime()
        for frame in 0..<30 { monitor.recordFrame(timestamp: start + Double(frame) / 60, target: start + Double(frame + 1) / 60) }
        ACPTraffic.record(messages: 20, bytes: 4096)
        try await Task.sleep(nanoseconds: 50_000_000)
        monitor.tick(now: start + 0.5)
        monitor.stop()

        let latest = try XCTUnwrap(monitor.history.latest)
        XCTAssertEqual(latest.frames?.fps ?? 0, 60, accuracy: 0.5)
        XCTAssertNotNil(latest.cpu)
        XCTAssertNotNil(latest.footprint)
        XCTAssertGreaterThan(latest.acpMessagesPerSecond, 0)
        monitor.tick(now: start + 1)
        XCTAssertEqual(monitor.history.fps.count, 1, "a stopped monitor does not sample")
    }

    // MARK: ACP traffic

    func testACPClientCountsDecodedMessagesAndBytes() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3.") }
        _ = ACPTraffic.drain()
        let lines = (0..<5).map { #"{"jsonrpc":"2.0","method":"session/update","params":{"n":\#($0)}}"# }
        let client = ACPClient()
        try client.start(executable: "/usr/bin/python3", cwd: NSTemporaryDirectory(), arguments: ["-u", "-c", """
import sys
sys.stdout.write(\(String(reflecting: lines.joined(separator: "\n") + "\n")))
sys.stdout.flush()
sys.stdin.read()
"""])
        defer { client.stop() }
        var received = 0
        client.onNotification = { _, _ in received += 1 }
        let deadline = Date().addingTimeInterval(5)
        while received < 5 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }

        let traffic = ACPTraffic.drain()
        XCTAssertEqual(traffic.messages, 5)
        XCTAssertEqual(traffic.bytes, lines.reduce(0) { $0 + $1.utf8.count + 1 })
    }

    // MARK: History and rows

    func testHistoryKeepsOneMinuteWithGapsForMissingMeasurements() {
        var history = PerformanceHistory()
        for index in 0..<(PerformanceHistory.capacity + 10) {
            history.append(PerformanceReading(frames: index == 0 ? nil : FrameSummary(fps: 60, worst: 17, dropped: 1, refreshRate: 60),
                                              mainThreadLag: Double(index), cpu: 10, footprint: UInt64(100 + index) * 1_048_576))
        }
        XCTAssertEqual(history.fps.count, PerformanceHistory.capacity)
        XCTAssertEqual(history.mainThreadLag.first, 10, "the oldest readings roll off")
        XCTAssertEqual(PerformanceHistory.total(history.dropped), Double(PerformanceHistory.capacity))
        XCTAssertEqual(PerformanceHistory.change(history.memory) ?? 0, Double(PerformanceHistory.capacity - 1) * 1_048_576)

        var gaps = PerformanceHistory()
        gaps.append(PerformanceReading(frames: nil))
        XCTAssertTrue(gaps.fps[0].isNaN)
        XCTAssertNil(PerformanceHistory.peak(gaps.fps))
        XCTAssertNil(PerformanceHistory.change(gaps.memory))
    }

    func testRowsShowCurrentValuesStatusAndOneMinuteContext() throws {
        var history = PerformanceHistory()
        history.append(PerformanceReading(frames: FrameSummary(fps: 120, worst: 9, dropped: 0, refreshRate: 120),
                                          mainThreadLag: 320, cpu: 42, footprint: 240 * 1_048_576, threads: 31,
                                          children: .init(count: 2, cpu: 3.14, footprint: 120 * 1_048_576),
                                          acpMessagesPerSecond: 42, acpBytesPerSecond: 18 * 1024))
        history.append(PerformanceReading(frames: FrameSummary(fps: 118, worst: 42, dropped: 4, refreshRate: 120),
                                          mainThreadLag: 2.14, cpu: 14, footprint: 252 * 1_048_576, threads: 32,
                                          children: .init(count: 2, cpu: 3.14, footprint: 120 * 1_048_576),
                                          acpMessagesPerSecond: 40, acpBytesPerSecond: 18 * 1024))
        let rows = PerformanceMetric.rows(for: history)
        XCTAssertEqual(rows.map(\.title), ["Frame rate", "Main thread", "CPU", "Memory", "Child processes", "ACP stream"])

        let frames = rows[0]
        XCTAssertEqual([frames.value, frames.unit, frames.detail], ["118", "fps", "worst 42 ms · 4 dropped"])
        XCTAssertEqual(frames.status, .init(label: "Hitching", level: .warning))
        XCTAssertEqual(frames.range, 0...120)

        let main = rows[1]
        XCTAssertEqual([main.value, main.unit, main.detail], ["2.1", "ms", "longest 320 ms"])
        XCTAssertEqual(main.status, .init(label: "Responsive", level: .good))

        XCTAssertEqual([rows[2].value, rows[2].unit, rows[2].detail], ["14", "%", "32 threads · peak 42%"])
        XCTAssertEqual([rows[3].value, rows[3].unit, rows[3].detail], ["252", "MB", "+12 MB · peak 252 MB"])
        XCTAssertFalse(rows[3].fillsArea)
        XCTAssertEqual([rows[4].value, rows[4].detail], ["3.1", "2 processes · 120 MB"])
        XCTAssertEqual([rows[5].value, rows[5].unit, rows[5].detail], ["40", "msg/s", "18 KB/s · peak 42/s"])
        XCTAssertEqual(PerformanceMetric.headerDetail(for: history), "last 1 min · 120 Hz")

        let summary = PerformanceMetric.summary(for: history)
        XCTAssertEqual(summary.text, "118 fps · 2.1 ms · 14% · 252 MB")
        XCTAssertEqual(summary.level, .warning)
    }

    func testEmptyHistoryShowsPlaceholders() {
        let rows = PerformanceMetric.rows(for: PerformanceHistory())
        XCTAssertEqual(rows.map(\.value), ["–", "–", "–", "–", "0", "0"])
        XCTAssertNil(rows[0].status)
        XCTAssertEqual(rows[4].detail, "none running")
        XCTAssertEqual(PerformanceMetric.summary(for: PerformanceHistory()).level, .idle)
        XCTAssertEqual(PerformanceMetric.headerDetail(for: PerformanceHistory()), "last 1 min")
    }

    func testStatusThresholds() {
        func frames(_ fps: Double, worst: Double = 9, dropped: Int = 0) -> FrameSummary {
            FrameSummary(fps: fps, worst: worst, dropped: dropped, refreshRate: 120)
        }
        XCTAssertEqual(PerformanceMetric.frameStatus(frames(119), refreshRate: 120).level, .good)
        XCTAssertEqual(PerformanceMetric.frameStatus(frames(119, dropped: 3), refreshRate: 120).level, .warning)
        XCTAssertEqual(PerformanceMetric.frameStatus(frames(100), refreshRate: 120).level, .warning)
        XCTAssertEqual(PerformanceMetric.frameStatus(frames(50), refreshRate: 120).level, .critical)
        XCTAssertEqual(PerformanceMetric.frameStatus(frames(110, worst: 120), refreshRate: 120).level, .critical)
        XCTAssertEqual(PerformanceMetric.frameStatus(nil, refreshRate: 120), .init(label: "Not drawing", level: .idle))
        XCTAssertEqual(PerformanceMetric.lagStatus(49).level, .good)
        XCTAssertEqual(PerformanceMetric.lagStatus(50).level, .warning)
        XCTAssertEqual(PerformanceMetric.lagStatus(250), .init(label: "Hang", level: .critical))
    }

    func testFormatting() {
        XCTAssertEqual(PerformanceFormat.number(0), "0")
        XCTAssertEqual(PerformanceFormat.number(3.14), "3.1")
        XCTAssertEqual(PerformanceFormat.number(14.2), "14")
        XCTAssertEqual(PerformanceFormat.number(1234), "1.2k")
        XCTAssertEqual(PerformanceFormat.number(23_456), "23k")
        XCTAssertEqual(PerformanceFormat.milliseconds(0.42), "0.4 ms")
        XCTAssertEqual(PerformanceFormat.milliseconds(180), "180 ms")
        XCTAssertEqual(PerformanceFormat.milliseconds(1830), "1.8 s")
        XCTAssertEqual(PerformanceFormat.bytes(820 * 1024), "820 KB")
        XCTAssertEqual(PerformanceFormat.bytes(3.5 * 1_048_576), "3.5 MB")
        XCTAssertEqual(PerformanceFormat.bytes(245 * 1_048_576), "245 MB")
        XCTAssertEqual(PerformanceFormat.bytes(1.5 * 1_073_741_824), "1.50 GB")
        XCTAssertEqual(PerformanceFormat.signedBytes(12 * 1_048_576), "+12 MB")
        XCTAssertEqual(PerformanceFormat.signedBytes(-3.4 * 1_048_576), "\u{2212}3.4 MB")
    }

    // MARK: Layout

    func testPanelStaysInsideTheWindow() {
        let panel = CGSize(width: 264, height: 340), window = CGSize(width: 1000, height: 700)
        XCTAssertEqual(PerformanceMonitorLayout.clamp(CGSize(width: -100, height: 50), panel: panel, container: window), CGSize(width: -100, height: 50))
        XCTAssertEqual(PerformanceMonitorLayout.clamp(CGSize(width: 40, height: -20), panel: panel, container: window), .zero)
        XCTAssertEqual(PerformanceMonitorLayout.clamp(CGSize(width: -5000, height: 5000), panel: panel, container: window), CGSize(width: -736, height: 360))
        XCTAssertEqual(PerformanceMonitorLayout.clamp(CGSize(width: -50, height: 50), panel: panel, container: CGSize(width: 200, height: 200)), .zero)
    }

    func testSparklineBreaksAtGapsAndEndsAtTheRightEdge() throws {
        let size = CGSize(width: 126, height: 30)
        let runs = PerformanceSparkline.runs(values: [0, 10, .nan, 5, 20], range: 0...20, capacity: 5, size: size)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 2)
        let newest = try XCTUnwrap(runs.last?.last)
        XCTAssertEqual(newest.x, size.width - 3, accuracy: 0.001)
        XCTAssertEqual(newest.y, 1.5, accuracy: 0.001, "the top of the range")
        XCTAssertEqual(runs[0][0].y, size.height - 1.5, accuracy: 0.001, "the bottom of the range")

        let partial = PerformanceSparkline.runs(values: [1], range: 0...2, capacity: 120, size: size)
        XCTAssertEqual(partial.first?.first?.x ?? 0, size.width - 3, accuracy: 0.001, "a short history grows from the right")
        XCTAssertTrue(PerformanceSparkline.runs(values: [1], range: 0...2, capacity: 1, size: size).isEmpty)
    }

    // MARK: Snapshots

    /// PNGs of the panel over light and dark windows, written when CROK_DESKTOP_SNAPSHOT_DIR is set.
    func testSnapshotsForVisualReview() throws {
        guard let directory = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let history = Self.sampleHistory()
        for dark in [false, true] {
            let scene = ZStack(alignment: .topTrailing) {
                Self.backdrop(dark: dark)
                VStack(alignment: .trailing, spacing: 12) {
                    PerformanceHUD(history: history, collapsed: .constant(false))
                    PerformanceHUD(history: history, collapsed: .constant(true))
                }
                .padding(16)
            }
            try Self.render(scene.frame(width: 640, height: 520), dark: dark, to: output.appendingPathComponent("performance-monitor-\(dark ? "dark" : "light").png"))
            try Self.render(DeveloperSettingsSection().padding(20).frame(width: 640).background(Theme.canvas).foregroundStyle(Theme.ink),
                            dark: dark, to: output.appendingPathComponent("performance-settings-\(dark ? "dark" : "light").png"))
        }
    }

    private static func sampleHistory() -> PerformanceHistory {
        var history = PerformanceHistory()
        for index in 0..<PerformanceHistory.capacity {
            let t = Double(index)
            let busy = (70..<84).contains(index)
            let hitch = index == 76 || index == 101
            let frames = index < 6 ? nil : FrameSummary(fps: hitch ? 88 : busy ? 104 + 6 * sin(t) : 119 + sin(t),
                                                         worst: hitch ? 64 : busy ? 25 : 9, dropped: hitch ? 7 : busy ? 2 : 0, refreshRate: 120)
            history.append(PerformanceReading(
                frames: frames,
                mainThreadLag: hitch ? (index == 76 ? 320 : 84) : busy ? 18 + 8 * sin(t) : 1.2 + abs(sin(t)),
                cpu: busy ? 60 + 25 * sin(t / 2) : 6 + 3 * abs(sin(t / 3)),
                footprint: UInt64((238 + t * 0.12 + (busy ? 6 : 0)) * 1_048_576),
                threads: 31,
                children: .init(count: 2, cpu: busy ? 38 + 10 * sin(t) : 2.4, footprint: 132 * 1_048_576),
                acpMessagesPerSecond: busy ? 240 + 90 * sin(t / 2) : index > 90 ? 36 + 8 * sin(t) : 0,
                acpBytesPerSecond: busy ? 96_000 : index > 90 ? 14_000 : 0
            ))
        }
        return history
    }

    /// A stand-in for the conversation behind the panel.
    private static func backdrop(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<9) { index in
                Text(index % 3 == 0 ? "Render the pricing tables with borders and a total row, then make the header row sticky while the rows scroll beneath it."
                     : "I added borders to every table cell and a bold total row. The table now reads well in both light and dark mode, and the header stays pinned.")
                    .font(.system(size: 14))
                    .foregroundStyle(dark ? Color.white.opacity(0.88) : Color.black.opacity(0.85))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.12) : Color(white: 0.97))
    }

    private static func render<V: View>(_ view: V, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }

    private static func selfCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
