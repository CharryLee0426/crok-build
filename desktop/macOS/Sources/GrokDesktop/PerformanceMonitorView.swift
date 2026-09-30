import AppKit
import QuartzCore
import SwiftUI

/// Shows the performance monitor over the main window in test builds while Settings has it on.
struct PerformanceMonitorOverlay: View {
    var available = PerformanceMonitorSettings.isAvailable
    @AppStorage(PerformanceMonitorSettings.enabledKey) private var enabled = PerformanceMonitorSettings.enabledByDefault

    var body: some View {
        if available && enabled { PerformanceMonitorPanel(monitor: .shared) }
    }
}

/// The panel where the user left it, sampling while it is on screen.
private struct PerformanceMonitorPanel: View {
    @ObservedObject var monitor: PerformanceMonitor
    @AppStorage(PerformanceMonitorSettings.collapsedKey) private var collapsed = false
    @AppStorage(PerformanceMonitorSettings.offsetXKey) private var savedX = 0.0
    @AppStorage(PerformanceMonitorSettings.offsetYKey) private var savedY = 0.0
    @GestureState private var drag = CGSize.zero
    @State private var panelSize = CGSize.zero

    var body: some View {
        GeometryReader { container in
            PerformanceHUD(history: monitor.history, collapsed: $collapsed)
                .background(GeometryReader { panel in Color.clear.preference(key: PanelSizeKey.self, value: panel.size) })
                .background(PerformanceFrameProbe(monitor: monitor))
                .offset(offset(adding: drag, in: container.size))
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        let settled = offset(adding: value.translation, in: container.size)
                        savedX = settled.width
                        savedY = settled.height
                    })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(12)
        .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
        .task {
            monitor.start()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(PerformanceHistory.interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                monitor.tick()
            }
            monitor.stop()
        }
    }

    private func offset(adding translation: CGSize, in container: CGSize) -> CGSize {
        PerformanceMonitorLayout.clamp(CGSize(width: savedX + translation.width, height: savedY + translation.height),
                                       panel: panelSize, container: container)
    }

    private struct PanelSizeKey: PreferenceKey {
        static let defaultValue = CGSize.zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }
}

enum PerformanceMonitorLayout {
    /// Keeps the panel inside the window. Offsets run left and down from the top-trailing corner.
    static func clamp(_ offset: CGSize, panel: CGSize, container: CGSize) -> CGSize {
        let left = max(0, container.width - panel.width)
        let down = max(0, container.height - panel.height)
        return CGSize(width: min(0, max(-left, offset.width)), height: min(down, max(0, offset.height)))
    }
}

/// Feeds display refreshes to the monitor while the panel is in a window.
private struct PerformanceFrameProbe: NSViewRepresentable {
    let monitor: PerformanceMonitor

    func makeNSView(context: Context) -> PerformanceFrameProbeView {
        let view = PerformanceFrameProbeView()
        view.monitor = monitor
        return view
    }

    func updateNSView(_ view: PerformanceFrameProbeView, context: Context) { view.monitor = monitor }

    static func dismantleNSView(_ view: PerformanceFrameProbeView, coordinator: ()) { view.stop() }
}

final class PerformanceFrameProbeView: NSView {
    weak var monitor: PerformanceMonitor?
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        monitor?.recordFrame(timestamp: link.timestamp, target: link.targetTimestamp)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Panel

/// The panel's colours: white ink on see-through black, the same over light and dark windows.
enum PerformanceHUDPalette {
    static let background = Color.black.opacity(0.72)
    static let border = Color.white.opacity(0.14)
    static let rule = Color.white.opacity(0.1)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.78)
    static let tertiary = Color.white.opacity(0.62)
    static let trend = Color(red: 0x7C / 255, green: 0xB8 / 255, blue: 1)
    static let good = Color(red: 0x3F / 255, green: 0xD0 / 255, blue: 0x7A / 255)
    static let warning = Color(red: 0xFA / 255, green: 0xB2 / 255, blue: 0x19 / 255)
    static let critical = Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255)
    static let idle = Color.white.opacity(0.45)
}

struct PerformanceHUD: View {
    let history: PerformanceHistory
    @Binding var collapsed: Bool

    static let width: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsed { collapsedHeader } else { header }
            if !collapsed {
                ForEach(PerformanceMetric.rows(for: history)) { metric in
                    Rectangle().fill(PerformanceHUDPalette.rule).frame(height: 0.5)
                    PerformanceMetricRow(metric: metric)
                }
            }
        }
        .frame(width: Self.width)
        .foregroundStyle(PerformanceHUDPalette.primary)
        .background(PerformanceHUDPalette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PerformanceHUDPalette.border, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Performance monitor")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(PerformanceHUDPalette.trend)
                .accessibilityHidden(true)
            Text("Performance").font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 6)
            Text(PerformanceMetric.headerDetail(for: history))
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(PerformanceHUDPalette.tertiary)
            foldButton
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
    }

    private var collapsedHeader: some View {
        let summary = PerformanceMetric.summary(for: history)
        return HStack(spacing: 7) {
            PerformanceStatusDot(level: summary.level)
            Text(summary.text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
            Spacer(minLength: 4)
            foldButton
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
    }

    private var foldButton: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PerformanceHUDPalette.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show performance details" : "Fold to one line")
        .accessibilityLabel(collapsed ? "Expand performance monitor" : "Collapse performance monitor")
    }
}

private struct PerformanceMetricRow: View {
    let metric: PerformanceMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(PerformanceHUDPalette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(metric.value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        Text(metric.unit).font(.system(size: 11, weight: .medium)).foregroundStyle(PerformanceHUDPalette.tertiary)
                    }
                    .lineLimit(1)
                }
                .frame(width: 96, alignment: .leading)
                PerformanceSparkline(values: metric.series, range: metric.range, fillsArea: metric.fillsArea)
                    .frame(height: 26)
            }
            HStack(spacing: 5) {
                if let status = metric.status {
                    PerformanceStatusDot(level: status.level)
                    Text(status.label).foregroundStyle(PerformanceHUDPalette.primary)
                        .padding(.trailing, 3)
                }
                Text(metric.detail).foregroundStyle(PerformanceHUDPalette.secondary).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(metric.help)
        .accessibilityElement(children: .combine)
    }
}

private struct PerformanceStatusDot: View {
    let level: PerformanceMetric.Level

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
    }

    private var color: Color {
        switch level {
        case .good: return PerformanceHUDPalette.good
        case .warning: return PerformanceHUDPalette.warning
        case .critical: return PerformanceHUDPalette.critical
        case .idle: return PerformanceHUDPalette.idle
        }
    }
}

/// The last minute of one metric, newest at the right edge. Gaps (`nan`) break the line.
struct PerformanceSparkline: View {
    let values: [Double]
    let range: ClosedRange<Double>
    var fillsArea = true
    var capacity = PerformanceHistory.capacity

    var body: some View {
        Canvas { context, size in
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(PerformanceHUDPalette.rule), lineWidth: 1)

            let runs = Self.runs(values: values, range: range, capacity: capacity, size: size)
            let trend = PerformanceHUDPalette.trend
            for run in runs {
                var line = Path()
                line.addLines(run)
                if fillsArea, let first = run.first, let last = run.last, run.count > 1 {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [trend.opacity(0.32), trend.opacity(0.02)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(line, with: .color(trend), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if values.last.map({ !$0.isNaN }) == true, let current = runs.last?.last {
                context.fill(Path(ellipseIn: CGRect(x: current.x - 2.5, y: current.y - 2.5, width: 5, height: 5)), with: .color(trend))
            }
        }
        .accessibilityHidden(true)
    }

    /// Points for each unbroken run of values. The newest value sits at the right edge, inset so the
    /// current-value dot is not clipped.
    static func runs(values: [Double], range: ClosedRange<Double>, capacity: Int, size: CGSize) -> [[CGPoint]] {
        guard capacity > 1, size.width > 6, size.height > 3 else { return [] }
        let inset: CGFloat = 3
        let step = (size.width - inset * 2) / CGFloat(capacity - 1)
        let first = capacity - min(values.count, capacity)
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in values.suffix(capacity).enumerated() {
            guard !value.isNaN else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
            current.append(CGPoint(x: inset + CGFloat(first + index) * step,
                                   y: size.height - 1.5 - CGFloat(fraction) * (size.height - 3)))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

// MARK: - Rows

/// One row of the panel: a current value, a one-minute sparkline, and context below it.
struct PerformanceMetric: Identifiable, Equatable {
    enum Level: Equatable { case good, warning, critical, idle }

    struct Status: Equatable {
        var label: String
        var level: Level
    }

    var title: String
    var value: String
    var unit: String
    var status: Status?
    var detail: String
    var series: [Double]
    var range: ClosedRange<Double>
    var fillsArea = true
    var help: String

    var id: String { title }

    /// A main-thread wait this long is a hang, as Xcode and Instruments count them.
    static let hangThreshold: Double = 250
    static let lagThreshold: Double = 50

    static func rows(for history: PerformanceHistory) -> [PerformanceMetric] {
        let latest = history.latest
        return [frameRate(history), mainThread(history), cpu(history), memory(history),
                children(latest?.children ?? .init(), series: history.childCPU),
                acp(latest, series: history.acpMessages)]
    }

    static func headerDetail(for history: PerformanceHistory) -> String {
        guard let rate = history.refreshRate else { return "last 1 min" }
        return String(format: "last 1 min · %.0f Hz", rate)
    }

    /// The folded panel's single line, marked with the worse of the frame and main-thread states.
    static func summary(for history: PerformanceHistory) -> (text: String, level: Level) {
        guard let latest = history.latest else { return ("Measuring…", .idle) }
        let fps = latest.frames.map { String(format: "%.0f fps", $0.fps) } ?? "– fps"
        let lag = PerformanceFormat.milliseconds(latest.mainThreadLag)
        let cpu = latest.cpu.map { PerformanceFormat.percent($0) } ?? "–%"
        let memory = latest.footprint.map { PerformanceFormat.bytes(Double($0)) } ?? "– MB"
        let levels = [frameStatus(latest.frames, refreshRate: history.refreshRate).level, lagStatus(latest.mainThreadLag).level]
        let level: Level = levels.contains(.critical) ? .critical : levels.contains(.warning) ? .warning : levels.allSatisfy { $0 == .idle } ? .idle : .good
        return ("\(fps) · \(lag) · \(cpu) · \(memory)", level)
    }

    static func frameStatus(_ frames: FrameSummary?, refreshRate: Double?) -> Status {
        guard let frames else { return Status(label: "Not drawing", level: .idle) }
        let rate = frames.refreshRate ?? refreshRate ?? 60
        let ratio = frames.fps / rate
        if ratio < 0.5 || frames.worst >= 100 { return Status(label: "Janky", level: .critical) }
        if ratio < 0.9 || frames.dropped > 2 { return Status(label: "Hitching", level: .warning) }
        return Status(label: "Smooth", level: .good)
    }

    static func lagStatus(_ lag: Double) -> Status {
        if lag >= hangThreshold { return Status(label: "Hang", level: .critical) }
        if lag >= lagThreshold { return Status(label: "Laggy", level: .warning) }
        return Status(label: "Responsive", level: .good)
    }

    private static func frameRate(_ history: PerformanceHistory) -> PerformanceMetric {
        let frames = history.latest?.frames
        let worst = PerformanceHistory.peak(history.frameWorst)
        let dropped = Int(PerformanceHistory.total(history.dropped))
        let detail = worst.map { "worst \(PerformanceFormat.milliseconds($0)) · \(dropped) dropped" } ?? "no frames yet"
        return PerformanceMetric(
            title: "Frame rate", value: frames.map { String(format: "%.0f", $0.fps) } ?? "–", unit: "fps",
            status: history.latest == nil ? nil : frameStatus(frames, refreshRate: history.refreshRate),
            detail: detail, series: history.fps, range: 0...(history.refreshRate ?? 60), fillsArea: false,
            help: "Display refreshes the main thread kept up with. A dropped frame is a refresh it missed; worst is the longest gap between frames in the last minute."
        )
    }

    private static func mainThread(_ history: PerformanceHistory) -> PerformanceMetric {
        let lag = history.latest?.mainThreadLag
        let (value, unit) = lag.map { PerformanceFormat.millisecondParts($0) } ?? ("–", "ms")
        let longest = PerformanceHistory.peak(history.mainThreadLag)
        return PerformanceMetric(
            title: "Main thread", value: value, unit: unit, status: lag.map(lagStatus),
            detail: longest.map { "longest \(PerformanceFormat.milliseconds($0))" } ?? "waiting for a sample",
            series: history.mainThreadLag, range: 0...max(longest ?? 0, lagThreshold),
            help: "How long work waited to start on the main thread. 50 ms is noticeable; 250 ms or more is a hang."
        )
    }

    private static func cpu(_ history: PerformanceHistory) -> PerformanceMetric {
        let latest = history.latest
        let peak = PerformanceHistory.peak(history.cpu)
        var detail: [String] = []
        if let threads = latest?.threads { detail.append("\(threads) threads") }
        if let peak { detail.append("peak \(PerformanceFormat.percent(peak))") }
        return PerformanceMetric(
            title: "CPU", value: latest?.cpu.map { PerformanceFormat.number($0) } ?? "–", unit: "%", status: nil,
            detail: detail.isEmpty ? "waiting for a sample" : detail.joined(separator: " · "),
            series: history.cpu, range: 0...max(peak ?? 0, 100),
            help: "This app's CPU use as a share of one core, as Activity Monitor shows it. Several busy cores go past 100%."
        )
    }

    private static func memory(_ history: PerformanceHistory) -> PerformanceMetric {
        let footprint = history.latest?.footprint.map { Double($0) }
        let (value, unit) = footprint.map { PerformanceFormat.byteParts($0) } ?? ("–", "MB")
        let measured = history.memory.filter { !$0.isNaN }
        var detail: [String] = []
        if let change = PerformanceHistory.change(history.memory) { detail.append(PerformanceFormat.signedBytes(change)) }
        if let peak = measured.max() { detail.append("peak \(PerformanceFormat.bytes(peak))") }
        let low = measured.min() ?? 0, high = measured.max() ?? 1
        let padding = max((high - low) * 0.15, 1_048_576)
        return PerformanceMetric(
            title: "Memory", value: value, unit: unit, status: nil,
            detail: detail.isEmpty ? "waiting for a sample" : detail.joined(separator: " · "),
            series: history.memory, range: max(0, low - padding)...(high + padding), fillsArea: false,
            help: "This app's physical footprint, the Memory column in Activity Monitor, and how much it changed in the last minute."
        )
    }

    private static func children(_ children: ProcessSampler.Children, series: [Double]) -> PerformanceMetric {
        let peak = PerformanceHistory.peak(series)
        let detail = children.count == 0 ? "none running"
            : "\(children.count) \(children.count == 1 ? "process" : "processes") · \(PerformanceFormat.bytes(Double(children.footprint)))"
        return PerformanceMetric(
            title: "Child processes", value: PerformanceFormat.number(children.cpu), unit: "% CPU", status: nil,
            detail: detail, series: series, range: 0...max(peak ?? 0, 100),
            help: "Processes this app started, mostly one crok agent per open task, plus terminals: their combined CPU and memory."
        )
    }

    private static func acp(_ latest: PerformanceReading?, series: [Double]) -> PerformanceMetric {
        let peak = PerformanceHistory.peak(series)
        var detail = "\(PerformanceFormat.bytes(latest?.acpBytesPerSecond ?? 0))/s"
        if let peak, peak > 0 { detail += " · peak \(PerformanceFormat.number(peak))/s" }
        return PerformanceMetric(
            title: "ACP stream", value: PerformanceFormat.number(latest?.acpMessagesPerSecond ?? 0), unit: "msg/s", status: nil,
            detail: detail, series: series, range: 0...max(peak ?? 0, 10),
            help: "Messages from the crok harnesses that reached the main thread, per second. Streaming replies and task history arrive here."
        )
    }
}

enum PerformanceFormat {
    /// "0.4", "3.1", "14", "1.2k"
    static func number(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if value >= 1000 { return String(format: "%.1fk", value / 1000) }
        if value >= 10 || value == 0 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double) -> String { number(value) + "%" }

    static func millisecondParts(_ value: Double) -> (String, String) {
        if value >= 1000 { return (String(format: "%.1f", value / 1000), "s") }
        return (value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value), "ms")
    }

    static func milliseconds(_ value: Double) -> String {
        let (number, unit) = millisecondParts(value)
        return "\(number) \(unit)"
    }

    static func byteParts(_ value: Double) -> (String, String) {
        let magnitude = abs(value)
        if magnitude >= 1_073_741_824 { return (String(format: "%.2f", value / 1_073_741_824), "GB") }
        if magnitude >= 1_048_576 {
            let megabytes = value / 1_048_576
            return (abs(megabytes) >= 10 ? String(format: "%.0f", megabytes) : String(format: "%.1f", megabytes), "MB")
        }
        return (String(format: "%.0f", value / 1024), "KB")
    }

    static func bytes(_ value: Double) -> String {
        let (number, unit) = byteParts(value)
        return "\(number) \(unit)"
    }

    /// "+12 MB", "−3.4 MB"
    static func signedBytes(_ value: Double) -> String {
        let text = bytes(abs(value))
        return (value < 0 ? "\u{2212}" : "+") + text
    }
}

// MARK: - Settings

/// Test-build tools in Settings. Release builds do not show this section.
struct DeveloperSettingsSection: View {
    @AppStorage(PerformanceMonitorSettings.enabledKey) private var monitor = PerformanceMonitorSettings.enabledByDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Developer", systemImage: "hammer").font(.system(size: 15, weight: .semibold))
                Spacer()
                ExtensionBadge(text: "Test build", tone: .warning)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 17)).foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Performance monitor").font(.system(size: 14, weight: .semibold))
                    Text("A see-through panel over the window with live frame rate, main-thread lag, CPU, memory, child processes, and ACP traffic. Drag it anywhere; its chevron folds it to one line.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Performance monitor", isOn: $monitor).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .settingsCard()
    }
}
