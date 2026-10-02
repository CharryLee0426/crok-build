import AppKit
import Darwin
import QuartzCore

/// The performance monitor: a see-through panel over the main window with live frame, main-thread,
/// CPU, memory, child-process and ACP numbers. Only workspace test builds carry it; there it is on
/// until Settings › Developer turns it off.
enum PerformanceMonitorSettings {
    static let enabledKey = "performanceMonitor"
    static let collapsedKey = "performanceMonitorCollapsed"
    static let offsetXKey = "performanceMonitorOffsetX"
    static let offsetYKey = "performanceMonitorOffsetY"
    static let enabledByDefault = true

    /// `make build-test-desktop` marks its bundle; release and unpackaged builds never show the monitor.
    static let isAvailable = GrokCommand.isWorkspaceTestBuild(in: Bundle.main.bundleURL)
}

// MARK: - Measurements

/// Display refreshes during one sampling interval. The gap before each refresh is how long the
/// main thread took to come back for the next frame.
struct FrameWindow {
    /// A longer gap means the window stopped drawing (another Space, minimized) or the app hung.
    /// The main-thread row reports hangs, so frame numbers leave these gaps out.
    static let resumeGap: Double = 1000

    private(set) var intervals: [Double] = []
    private(set) var refreshInterval: Double?
    private var last: CFTimeInterval?

    /// A display link callback: the frame's timestamp and when the next frame is due.
    mutating func record(timestamp: CFTimeInterval, target: CFTimeInterval) {
        if target > timestamp { refreshInterval = (target - timestamp) * 1000 }
        defer { last = timestamp }
        guard let last, timestamp > last else { return }
        let gap = (timestamp - last) * 1000
        if gap < Self.resumeGap { intervals.append(gap) }
    }

    /// The interval's frames, leaving the window ready for the next interval.
    mutating func drain() -> FrameSummary? {
        defer { intervals.removeAll(keepingCapacity: true) }
        return FrameSummary(intervals: intervals, refreshInterval: refreshInterval)
    }
}

struct FrameSummary: Equatable {
    var fps: Double
    /// The longest gap between frames, in milliseconds.
    var worst: Double
    /// Refreshes the main thread missed.
    var dropped: Int
    var refreshRate: Double?

    init(fps: Double, worst: Double, dropped: Int, refreshRate: Double?) {
        self.fps = fps; self.worst = worst; self.dropped = dropped; self.refreshRate = refreshRate
    }

    /// Frame gaps in milliseconds. A gap of about two refreshes is one dropped frame.
    init?(intervals: [Double], refreshInterval: Double?) {
        guard !intervals.isEmpty else { return nil }
        let total = intervals.reduce(0, +)
        fps = total > 0 ? Double(intervals.count) * 1000 / total : 0
        worst = intervals.max() ?? 0
        if let refreshInterval, refreshInterval > 0 {
            dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / refreshInterval).rounded()) - 1) }
            refreshRate = 1000 / refreshInterval
        } else {
            dropped = 0
            refreshRate = nil
        }
    }
}

/// Measures how long work queued on the main thread waits to start, from a background timer. It
/// sees hangs even when the window is hidden and the display link has stopped.
final class MainThreadWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.chenli.crok.desktop.performance-watchdog", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var longest: Double = 0

    func start(every interval: DispatchTimeInterval = .milliseconds(50)) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        lock.withLock { self.timer = timer; waiting = false; longest = 0 }
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    /// The longest wait, in milliseconds, since the last call.
    func drain() -> Double {
        lock.withLock {
            defer { longest = 0 }
            return longest
        }
    }

    private func ping() {
        // One ping at a time: while the main thread is blocked, the waiting ping measures the whole block.
        let send = lock.withLock { () -> Bool in
            guard timer != nil, !waiting else { return false }
            waiting = true
            return true
        }
        guard send else { return }
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let wait = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            guard let self else { return }
            lock.withLock {
                self.waiting = false
                self.longest = max(self.longest, wait)
            }
        }
    }
}

/// CPU time and memory of this app and the processes it started (task harnesses, terminals).
enum ProcessProbe {
    struct Usage: Equatable {
        var cpuSeconds: Double
        /// Physical footprint, the number Activity Monitor shows as Memory.
        var footprint: UInt64
    }

    /// `proc_pid_rusage` reports CPU time in Mach ticks, which are not nanoseconds on Apple silicon.
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()

    static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return Usage(cpuSeconds: ticks * nanosecondsPerTick / 1_000_000_000, footprint: info.ri_phys_footprint)
    }

    static func threadCount(of pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 512)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }
}

/// The share of one core used between two readings, as Activity Monitor counts it (over 100% when
/// several cores work).
func cpuPercent(from previous: Double, to current: Double, elapsed: Double) -> Double {
    guard elapsed > 0 else { return 0 }
    return max(0, current - previous) / elapsed * 100
}

/// Reads CPU and memory for the app and its direct children, remembering CPU time between readings.
struct ProcessSampler {
    struct Children: Equatable {
        var count = 0
        var cpu: Double = 0
        var footprint: UInt64 = 0
    }

    let pid: pid_t
    private var lastCPU: Double?
    private var lastChildCPU: [pid_t: Double] = [:]

    init(pid: pid_t = getpid()) { self.pid = pid }

    /// Starts counting from now, so the first interval does not include earlier CPU time.
    mutating func prime() {
        lastCPU = ProcessProbe.usage(of: pid)?.cpuSeconds
        lastChildCPU = [:]
        for child in ProcessProbe.children(of: pid) {
            if let usage = ProcessProbe.usage(of: child) { lastChildCPU[child] = usage.cpuSeconds }
        }
    }

    mutating func sample(elapsed: Double) -> (cpu: Double?, footprint: UInt64?, threads: Int?, children: Children) {
        var cpu: Double?
        var footprint: UInt64?
        if let usage = ProcessProbe.usage(of: pid) {
            if let lastCPU { cpu = cpuPercent(from: lastCPU, to: usage.cpuSeconds, elapsed: elapsed) }
            lastCPU = usage.cpuSeconds
            footprint = usage.footprint
        }
        var children = Children()
        var seen: [pid_t: Double] = [:]
        for child in ProcessProbe.children(of: pid) {
            guard let usage = ProcessProbe.usage(of: child) else { continue }
            children.count += 1
            children.footprint += usage.footprint
            // A child that appeared since the last reading counts from its next interval.
            if let previous = lastChildCPU[child] { children.cpu += cpuPercent(from: previous, to: usage.cpuSeconds, elapsed: elapsed) }
            seen[child] = usage.cpuSeconds
        }
        lastChildCPU = seen
        return (cpu, footprint, ProcessProbe.threadCount(of: pid), children)
    }
}

/// ACP traffic since the monitor last looked, counted where the app decodes the harnesses' output.
@MainActor
enum ACPTraffic {
    private static var messages = 0
    private static var bytes = 0

    static func record(messages: Int, bytes: Int) {
        self.messages += messages
        self.bytes += bytes
    }

    static func drain() -> (messages: Int, bytes: Int) {
        defer { messages = 0; bytes = 0 }
        return (messages, bytes)
    }
}

// MARK: - History

/// One sampling interval's measurements.
struct PerformanceReading: Equatable {
    var frames: FrameSummary?
    /// The longest wait for the main thread, in milliseconds.
    var mainThreadLag: Double = 0
    var cpu: Double?
    var footprint: UInt64?
    var threads: Int?
    var children = ProcessSampler.Children()
    var acpMessagesPerSecond: Double = 0
    var acpBytesPerSecond: Double = 0
}

/// The last minute of readings, as the panel draws them. Series hold one value per interval, oldest
/// first; `nan` marks an interval without that measurement.
struct PerformanceHistory: Equatable {
    static let interval: TimeInterval = 0.5
    static let capacity = 120

    private(set) var latest: PerformanceReading?
    private(set) var refreshRate: Double?
    private(set) var fps: [Double] = []
    private(set) var frameWorst: [Double] = []
    private(set) var dropped: [Double] = []
    private(set) var mainThreadLag: [Double] = []
    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var childCPU: [Double] = []
    private(set) var acpMessages: [Double] = []

    mutating func append(_ reading: PerformanceReading) {
        latest = reading
        if let rate = reading.frames?.refreshRate { refreshRate = rate }
        Self.push(reading.frames?.fps ?? .nan, to: &fps)
        Self.push(reading.frames?.worst ?? .nan, to: &frameWorst)
        Self.push(Double(reading.frames?.dropped ?? 0), to: &dropped)
        Self.push(reading.mainThreadLag, to: &mainThreadLag)
        Self.push(reading.cpu ?? .nan, to: &cpu)
        Self.push(reading.footprint.map { Double($0) } ?? .nan, to: &memory)
        Self.push(reading.children.cpu, to: &childCPU)
        Self.push(reading.acpMessagesPerSecond, to: &acpMessages)
    }

    private static func push(_ value: Double, to series: inout [Double]) {
        series.append(value)
        if series.count > capacity { series.removeFirst(series.count - capacity) }
    }

    /// The largest measured value in a series, ignoring gaps.
    static func peak(_ series: [Double]) -> Double? { series.filter { !$0.isNaN }.max() }

    static func total(_ series: [Double]) -> Double { series.filter { !$0.isNaN }.reduce(0, +) }

    /// The change from the oldest to the newest measured value.
    static func change(_ series: [Double]) -> Double? {
        let measured = series.filter { !$0.isNaN }
        guard let first = measured.first, let last = measured.last, measured.count > 1 else { return nil }
        return last - first
    }
}

// MARK: - Monitor

/// Samples while the panel is on screen. Only the panel observes it, so its updates redraw nothing else.
@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published private(set) var history = PerformanceHistory()

    private var frames = FrameWindow()
    private var sampler = ProcessSampler()
    private let watchdog = MainThreadWatchdog()
    private var lastTick: CFTimeInterval?
    private var users = 0

    init() {}

    /// A preview or test with fixed readings.
    init(history: PerformanceHistory) { self.history = history }

    func start() {
        users += 1
        guard users == 1 else { return }
        frames = FrameWindow()
        sampler.prime()
        _ = ACPTraffic.drain()
        watchdog.start()
        lastTick = CACurrentMediaTime()
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        watchdog.stop()
        lastTick = nil
    }

    func recordFrame(timestamp: CFTimeInterval, target: CFTimeInterval) {
        frames.record(timestamp: timestamp, target: target)
    }

    /// Reads everything measured since the previous tick.
    func tick(now: CFTimeInterval = CACurrentMediaTime()) {
        guard users > 0, let lastTick else { return }
        let elapsed = now - lastTick
        guard elapsed > 0 else { return }
        self.lastTick = now
        let process = sampler.sample(elapsed: elapsed)
        let traffic = ACPTraffic.drain()
        history.append(PerformanceReading(
            frames: frames.drain(),
            mainThreadLag: watchdog.drain(),
            cpu: process.cpu,
            footprint: process.footprint,
            threads: process.threads,
            children: process.children,
            acpMessagesPerSecond: Double(traffic.messages) / elapsed,
            acpBytesPerSecond: Double(traffic.bytes) / elapsed
        ))
    }
}
