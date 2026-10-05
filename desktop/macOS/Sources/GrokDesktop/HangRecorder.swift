import AppKit
import Foundation

/// When a main thread that has stopped answering is worth a report.
struct HangPolicy: Equatable {
    /// The main thread has been silent this long. Shorter stalls are the performance monitor's to show.
    var threshold: TimeInterval = 3
    /// At least this long from one report to the next, so a run of hangs does not fill the folder.
    var spacing: TimeInterval = 20
    /// Reports kept; the oldest go first.
    var kept = 20
}

/// One question to the main thread at a time: when it was asked, and whether its silence was reported.
struct HangWatch: Equatable {
    enum Step: Equatable {
        /// Ask the main thread to answer.
        case ask
        case wait
        /// The pending question has waited this long: write a report.
        case report(waited: TimeInterval)
    }

    struct Answer: Equatable {
        var waited: TimeInterval
        var wasReported: Bool
    }

    private(set) var askedAt: TimeInterval?
    private var reported = false
    private var lastReportAt: TimeInterval?

    mutating func tick(now: TimeInterval, policy: HangPolicy) -> Step {
        guard let askedAt else {
            self.askedAt = now
            reported = false
            return .ask
        }
        let waited = now - askedAt
        guard waited >= policy.threshold, !reported else { return .wait }
        // One report for a hang, however long it lasts.
        reported = true
        if let lastReportAt, now - lastReportAt < policy.spacing { return .wait }
        lastReportAt = now
        return .report(waited: waited)
    }

    /// The main thread answered the pending question.
    mutating func answered(now: TimeInterval) -> Answer? {
        guard let askedAt else { return nil }
        defer { self.askedAt = nil }
        return Answer(waited: now - askedAt, wasReported: reported && lastReportAt.map { $0 >= askedAt } == true)
    }
}

/// Writes down what the app was doing when its main thread stops answering: the window's state as
/// last noted, then the call stacks of every thread, sampled by the system's `sample` tool. A hang
/// seen once in a long session is then found in a file rather than lost with the force quit.
///
/// Only workspace test builds run it (see `PerformanceMonitorSettings.isAvailable`). It asks the
/// main thread to answer four times a second from a thread of its own, and does nothing else until
/// an answer is three seconds late.
final class HangRecorder: @unchecked Sendable {
    static let shared = HangRecorder()

    /// Where reports go: beside the app's state file.
    static var defaultDirectory: URL {
        DesktopPaths.stateFile.deletingLastPathComponent().appendingPathComponent("hang-reports", isDirectory: true)
    }

    private let lock = NSLock()
    private var watch = HangWatch()
    private var policy = HangPolicy()
    private var directory: URL?
    private var running = false
    /// What the main thread last said about the app, and when.
    private var context = ""
    private var contextAt: TimeInterval?
    /// The report of the hang in progress, for the line that says how it ended.
    private var openReport: URL?
    private var contextTimer: Timer?
    /// Replaced in tests, which have no use for a real sample of the test runner.
    var sample: @Sendable (_ pid: Int32, _ output: URL) -> Void = { pid, output in HangRecorder.runSample(pid: pid, output: output) }
    var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Starts watching. `describe` runs on the main thread once a second; what it returns goes at the top of a report.
    @MainActor
    func start(directory: URL = HangRecorder.defaultDirectory, policy: HangPolicy = HangPolicy(),
               describe: @escaping @MainActor () -> String, recovered: @escaping @MainActor (URL, TimeInterval) -> Void) {
        configure(directory: directory, policy: policy)
        let alreadyRunning = lock.withLock { () -> Bool in
            defer { running = true }
            return running
        }
        note(describe())
        contextTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.note(describe()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        contextTimer = timer
        self.recovered = recovered
        guard !alreadyRunning else { return }
        let thread = Thread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                self.tick()
                usleep(250_000)
            }
        }
        thread.name = "dev.chenli.crok.desktop.hang-recorder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Where reports go and when one is due; `start` sets these, and a test that calls `tick` itself.
    func configure(directory: URL, policy: HangPolicy = HangPolicy()) {
        lock.withLock { self.directory = directory; self.policy = policy }
    }

    @MainActor
    func stop() {
        contextTimer?.invalidate()
        contextTimer = nil
        lock.withLock { running = false; watch = HangWatch(); openReport = nil }
    }

    @MainActor private var recovered: (@MainActor (URL, TimeInterval) -> Void)?

    /// What a report says about the app. Kept from the main thread, because a hung one cannot be asked.
    func note(_ context: String) {
        let now = clock()
        lock.withLock { self.context = context; contextAt = now }
    }

    /// One look at the pending question; from the recorder's thread, or a test.
    func tick() {
        let now = clock()
        let (step, context, age, directory, policy) = lock.withLock {
            (watch.tick(now: now, policy: policy), self.context, contextAt.map { now - $0 }, self.directory, self.policy)
        }
        switch step {
        case .wait: break
        case .ask:
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.answered() } }
        case .report(let waited):
            guard let directory else { return }
            write(waited: waited, context: context, contextAge: age, to: directory, kept: policy.kept)
        }
    }

    @MainActor
    private func answered() {
        let now = clock()
        let (answer, report) = lock.withLock { () -> (HangWatch.Answer?, URL?) in
            defer { openReport = nil }
            return (watch.answered(now: now), openReport)
        }
        guard let answer, answer.wasReported, let report else { return }
        Self.append(String(format: "\nThe main thread answered again after %.1f seconds.\n", answer.waited), to: report)
        recovered?(report, answer.waited)
    }

    private func write(waited: TimeInterval, context: String, contextAge: TimeInterval?, to directory: URL, kept: Int) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "hang-" + formatter.string(from: Date())
        let report = directory.appendingPathComponent(name + ".txt")
        let stacks = directory.appendingPathComponent(name + ".sample.txt")
        let noted = contextAge.map { String(format: "What the app last noted, %.1f seconds before this was written:", $0) } ?? "The app had noted nothing yet."
        let text = """
        Crok Desktop hang report
        \(Self.buildLine)
        \(ISO8601DateFormatter().string(from: Date()))

        The main thread had not answered for \(String(format: "%.1f", waited)) seconds when this was written.
        The call stacks of every thread are in \(stacks.lastPathComponent), sampled then. Both files are needed.

        \(noted)
        \(context)

        """
        try? text.write(to: report, atomically: true, encoding: .utf8)
        lock.withLock { openReport = report }
        sample(ProcessInfo.processInfo.processIdentifier, stacks)
        Self.prune(directory, keeping: kept)
    }

    private static var buildLine: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Crok Desktop"
        return "\(name) \(DesktopVersion.current), macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// One second of every thread's stack, every ten milliseconds. Short, so that it is on disk before a
    /// force quit: about two seconds after it starts, five after the app stopped answering.
    private static func runSample(pid: Int32, output: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), "1", "10", "-file", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? "The call stacks could not be sampled: \(error.localizedDescription)\n".write(to: output, atomically: true, encoding: .utf8)
        }
    }

    private static func append(_ text: String, to file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Keeps the newest `kept` hangs; a hang is its report and its sample.
    static func prune(_ directory: URL, keeping kept: Int) {
        let fileManager = FileManager.default
        let reports = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "txt" && !$0.lastPathComponent.hasSuffix(".sample.txt") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in reports.dropFirst(max(0, kept)) {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: old.deletingPathExtension().appendingPathExtension("sample.txt"))
        }
    }
}

/// What a hang report says about the app: its main window and what its tasks were doing.
@MainActor
enum HangContext {
    static func describe(store: AppStore?) -> String {
        var lines: [String] = []
        let windows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        if let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            let frame = window.frame
            var state = [window.styleMask.contains(.fullScreen) ? "full screen" : "not full screen",
                         "\(Int(frame.width)) × \(Int(frame.height)) points",
                         window.isOnActiveSpace ? "on the active Space" : "on another Space",
                         window.occlusionState.contains(.visible) ? "visible" : "covered or off screen"]
            if window.isKeyWindow { state.append("key") }
            if let screen = window.screen { state.append("screen \(Int(screen.frame.width)) × \(Int(screen.frame.height))") }
            lines.append("Main window: " + state.joined(separator: ", "))
        } else {
            lines.append("Main window: none visible")
        }
        lines.append("App: \(NSApp.isActive ? "active" : "in the background"), \(NSApp.windows.filter(\.isVisible).count) windows visible")
        if let store {
            let running = store.runs.values.filter(\.isRunning).count
            lines.append("Tasks running: \(running)")
            lines.append("Selected task: \(store.conversation?.messages.count ?? 0) messages, \(store.run.isRunning ? "running (\(store.run.phase))" : "idle")")
            lines.append("Side panel: \(store.showInspector ? store.sidePanelTab.rawValue : "closed"); minimal mode: \(store.minimalMode ? "on" : "off")")
        }
        return lines.joined(separator: "\n")
    }
}
