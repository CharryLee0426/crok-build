import SwiftUI
import UIKit

/// The o11y categorical palette (mobile/DESIGN.md "o11y" › chart): slots 1–8, light and dark; slot 0 is "Other".
enum O11yPalette {
    private static let slots: [(UInt32, UInt32)] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
        (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x6250D6, 0x9085E9), (0xE34948, 0xE66767),
    ]

    static func color(slot: Int) -> Color {
        guard slot >= 1 else { return Color.secondary.opacity(0.6) }
        let (light, dark) = slots[(slot - 1) % slots.count]
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let good = Theme.toolDone
    static let bad = Theme.toolFailed
    static let warn = Color(uiColor: UIColor(hex: 0xF09A37))

    static func tone(_ tone: O11yFormat.Tone) -> Color {
        switch tone {
        case .good: good
        case .bad: bad
        case .neutral: .secondary
        }
    }
}

/// What a chart draws: its points on one time axis, the y scale from 0 to round values, and what a touch picks.
struct O11yChartGeometry {
    let chart: O11yBlock.O11yChart
    let hidden: Set<String>

    /// Every time any series has, in order: the x axis.
    var times: [Double] {
        Array(Set(chart.series.flatMap { $0.points.map(\.time) })).sorted()
    }

    var visible: [O11ySeries] { chart.series.filter { !hidden.contains($0.name) } }

    var isEmpty: Bool { !chart.series.contains { $0.points.contains { $0.value != nil } } }

    /// The largest value drawn: a stack's total for stacked bars.
    func maxValue(times: [Double]) -> Double {
        let shown = visible
        var top = shown.flatMap { $0.points.compactMap(\.value) }.max() ?? 0
        if chart.style == .bars && chart.stacked {
            let solid = shown.filter { $0.dashed != true }
            for t in times {
                let sum = solid.reduce(0) { $0 + max(0, $1.value(at: t) ?? 0) }
                top = max(top, sum)
            }
        }
        return top
    }

    /// Three steps of a round size from 0, the top one at or above `max`.
    static func ticks(max: Double) -> [Double] {
        guard max > 0, max.isFinite else { return [0, 1, 2, 3].map { Double($0) / 3 } }
        let raw = max / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        return (0...3).map { Double($0) * step }
    }
}

extension O11ySeries {
    func value(at time: Double) -> Double? {
        points.first { $0.time == time }?.value
    }
}

/// A chart block: the plot, then the legend for two or more series (a tap hides or shows one), then "and N more".
struct O11yChartCard: View {
    let chart: O11yBlock.O11yChart
    let title: String
    let height: CGFloat
    @State private var hidden: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            O11yChartPlot(chart: chart, hidden: hidden, title: title)
                .frame(height: height)
            if chart.series.count >= 2 {
                O11yFlowLayout(spacing: 6) {
                    ForEach(chart.series) { series in
                        legendChip(series)
                    }
                }
            }
            if chart.more > 0 {
                Text("and \(chart.more) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func legendChip(_ series: O11ySeries) -> some View {
        let isHidden = hidden.contains(series.name)
        return Button {
            if isHidden {
                hidden.remove(series.name)
            } else if hidden.count < chart.series.count - 1 {
                hidden.insert(series.name)
            }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if isHidden {
                        Circle().strokeBorder(O11yPalette.color(slot: series.slot), lineWidth: 1.5)
                    } else {
                        Circle().fill(O11yPalette.color(slot: series.slot))
                    }
                }
                .frame(width: 8, height: 8)
                Text(series.name)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let total = series.total {
                    Text(O11yFormat.value(total, chart.unit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .opacity(isHidden ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(series.name))
        .accessibilityValue(Text(series.total.map { O11yFormat.value($0, chart.unit) } ?? ""))
        .accessibilityAddTraits(isHidden ? [] : .isSelected)
    }
}

/// The plot itself, drawn on a canvas (both apps draw the same marks: mobile/DESIGN.md "o11y" › chart).
struct O11yChartPlot: View {
    let chart: O11yBlock.O11yChart
    let hidden: Set<String>
    let title: String
    @State private var selected: Int?
    @State private var scrubbing = false
    @Environment(\.colorScheme) private var colorScheme

    private static let top: CGFloat = 16
    private static let bottom: CGFloat = 18

    var body: some View {
        let geometry = O11yChartGeometry(chart: chart, hidden: hidden)
        let times = geometry.times
        if geometry.isEmpty {
            Text("No data in this range")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let ticks = O11yChartGeometry.ticks(max: geometry.maxValue(times: times))
            GeometryReader { proxy in
                let plot = CGRect(
                    x: 0, y: Self.top, width: proxy.size.width, height: max(1, proxy.size.height - Self.top - Self.bottom))
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        drawGrid(&context, plot: plot, ticks: ticks)
                        drawXLabels(&context, plot: plot, times: times)
                        if chart.style == .bars {
                            drawBars(&context, plot: plot, times: times, top: ticks.last ?? 1, geometry: geometry)
                        } else {
                            drawLines(&context, plot: plot, times: times, top: ticks.last ?? 1, geometry: geometry)
                        }
                        drawDashed(&context, plot: plot, times: times, top: ticks.last ?? 1, geometry: geometry)
                        if let selected, times.indices.contains(selected) {
                            drawSelection(&context, plot: plot, times: times, index: selected, top: ticks.last ?? 1, geometry: geometry)
                        }
                    }
                    if let selected, times.indices.contains(selected) {
                        callout(index: selected, times: times, geometry: geometry)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                let x = xPosition(index: selected, times: times, plot: plot)
                                return -min(max(0, x - d.width / 2), max(0, plot.width - d.width))
                            }
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // UIKit recognizers, not SwiftUI gestures: any SwiftUI drag on the chart (even a simultaneous
                    // one) stops the page from scrolling when a swipe starts on it.
                    O11yChartTouches(
                        tap: { x in
                            let index = nearest(x: x, times: times, plot: plot)
                            selected = selected == index ? nil : index
                        },
                        scrub: { x in
                            if let x {
                                scrubbing = true
                                selected = nearest(x: x, times: times, plot: plot)
                            } else {
                                if scrubbing { selected = nil }
                                scrubbing = false
                            }
                        })
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(summary(geometry)))
        }
    }

    // MARK: Touch

    private func nearest(x: CGFloat, times: [Double], plot: CGRect) -> Int? {
        guard !times.isEmpty else { return nil }
        var best = 0
        var distance = CGFloat.infinity
        for index in times.indices {
            let d = abs(xPosition(index: index, times: times, plot: plot) - x)
            if d < distance {
                distance = d
                best = index
            }
        }
        return best
    }

    // MARK: Scales

    /// Bars sit in equal slots; lines are placed by time.
    private func xPosition(index: Int, times: [Double], plot: CGRect) -> CGFloat {
        if chart.style == .bars {
            let slot = plot.width / CGFloat(max(1, times.count))
            return plot.minX + slot * (CGFloat(index) + 0.5)
        }
        guard let first = times.first, let last = times.last, last > first else { return plot.midX }
        return plot.minX + plot.width * CGFloat((times[index] - first) / (last - first))
    }

    private func yPosition(_ value: Double, top: Double, plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(max(0, value) / max(top, .leastNonzeroMagnitude))
    }

    // MARK: Drawing

    private var gridColor: Color { Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10) }

    private func drawGrid(_ context: inout GraphicsContext, plot: CGRect, ticks: [Double]) {
        let top = ticks.last ?? 1
        let labels = O11yFormat.axis(ticks, chart.unit)
        for (tick, text) in zip(ticks, labels) {
            let y = yPosition(tick, top: top, plot: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 1 / UIScreen.main.scale)
            let label = Text(text).font(.caption2).foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: plot.minX, y: y - 2), anchor: .bottomLeading)
        }
    }

    private func drawXLabels(_ context: inout GraphicsContext, plot: CGRect, times: [Double]) {
        guard !times.isEmpty else { return }
        let count = min(times.count, plot.width < 360 ? 3 : 4)
        var used = Set<Int>()
        for i in 0..<count {
            let index = count == 1 ? 0 : Int((Double(i) * Double(times.count - 1) / Double(count - 1)).rounded())
            guard used.insert(index).inserted else { continue }
            let x = xPosition(index: index, times: times, plot: plot)
            let anchor: UnitPoint = i == 0 ? .topLeading : i == count - 1 ? .topTrailing : .top
            let label = Text(O11yTime.axis(times[index], step: chart.step)).font(.caption2).foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: i == 0 ? plot.minX : i == count - 1 ? plot.maxX : x, y: plot.maxY + 4), anchor: anchor)
        }
    }

    private func drawLines(_ context: inout GraphicsContext, plot: CGRect, times: [Double], top: Double, geometry: O11yChartGeometry) {
        let solid = geometry.visible.filter { $0.dashed != true }
        let index = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($1, $0) })
        for series in solid {
            var path = Path()
            var area = Path()
            var started = false
            var firstX: CGFloat = 0
            var lastX: CGFloat = 0
            for point in series.points {
                guard let i = index[point.time] else { continue }
                let x = xPosition(index: i, times: times, plot: plot)
                guard let value = point.value else {
                    if started, solid.count == 1 { closeArea(&area, from: firstX, to: lastX, plot: plot, into: &context, slot: series.slot) }
                    started = false
                    continue
                }
                let p = CGPoint(x: x, y: yPosition(value, top: top, plot: plot))
                if started {
                    path.addLine(to: p)
                    area.addLine(to: p)
                } else {
                    path.move(to: p)
                    area = Path()
                    area.move(to: p)
                    firstX = x
                    started = true
                }
                lastX = x
            }
            if started, solid.count == 1 { closeArea(&area, from: firstX, to: lastX, plot: plot, into: &context, slot: series.slot) }
            context.stroke(
                path, with: .color(O11yPalette.color(slot: series.slot)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// A lone series' area wash under its line.
    private func closeArea(_ area: inout Path, from: CGFloat, to: CGFloat, plot: CGRect, into context: inout GraphicsContext, slot: Int) {
        area.addLine(to: CGPoint(x: to, y: plot.maxY))
        area.addLine(to: CGPoint(x: from, y: plot.maxY))
        area.closeSubpath()
        context.fill(area, with: .color(O11yPalette.color(slot: slot).opacity(0.10)))
    }

    private func drawBars(_ context: inout GraphicsContext, plot: CGRect, times: [Double], top: Double, geometry: O11yChartGeometry) {
        let solid = geometry.visible.filter { $0.dashed != true }
        let slotWidth = plot.width / CGFloat(max(1, times.count))
        let width = min(24, max(1, slotWidth - 2))
        let thin = width <= 3
        for (i, time) in times.enumerated() {
            let center = xPosition(index: i, times: times, plot: plot)
            if chart.stacked || solid.count == 1 {
                // From the baseline up, each segment 2 pt short of the next; only the stack's top is rounded.
                let values = solid.map { (series: $0, value: max(0, $0.value(at: time) ?? 0)) }.filter { $0.value > 0 }
                var base = 0.0
                for (n, item) in values.enumerated() {
                    let y0 = yPosition(base, top: top, plot: plot)
                    let y1 = yPosition(base + item.value, top: top, plot: plot)
                    base += item.value
                    let isTop = n == values.count - 1
                    let gap: CGFloat = isTop || thin || y0 - y1 <= 3 ? 0 : 2
                    let rect = CGRect(x: center - width / 2, y: y1 + gap, width: width, height: max(0.5, y0 - y1 - gap))
                    let radius: CGFloat = isTop && !thin ? min(4, rect.height, width / 2) : 0
                    let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius).path(in: rect)
                    context.fill(shape, with: .color(O11yPalette.color(slot: item.series.slot)))
                }
            } else {
                // Side by side within the slot.
                let each = max(1, width / CGFloat(solid.count))
                for (n, series) in solid.enumerated() {
                    guard let value = series.value(at: time), value > 0 else { continue }
                    let y = yPosition(value, top: top, plot: plot)
                    let rect = CGRect(x: center - width / 2 + each * CGFloat(n), y: y, width: max(1, each - 1), height: plot.maxY - y)
                    let radius: CGFloat = thin ? 0 : min(4, rect.height, each / 2)
                    context.fill(
                        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius).path(in: rect),
                        with: .color(O11yPalette.color(slot: series.slot)))
                }
            }
        }
    }

    /// Comparison series ("7 days earlier"): a dashed line in the secondary colour, over everything.
    private func drawDashed(_ context: inout GraphicsContext, plot: CGRect, times: [Double], top: Double, geometry: O11yChartGeometry) {
        let index = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($1, $0) })
        for series in geometry.visible where series.dashed == true {
            var path = Path()
            var started = false
            for point in series.points {
                guard let i = index[point.time], let value = point.value else {
                    started = false
                    continue
                }
                let p = CGPoint(x: xPosition(index: i, times: times, plot: plot), y: yPosition(value, top: top, plot: plot))
                if started { path.addLine(to: p) } else { path.move(to: p) }
                started = true
            }
            context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 6]))
        }
    }

    private func drawSelection(
        _ context: inout GraphicsContext, plot: CGRect, times: [Double], index: Int, top: Double, geometry: O11yChartGeometry
    ) {
        let x = xPosition(index: index, times: times, plot: plot)
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(rule, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
        guard chart.style == .line else { return }
        for series in geometry.visible {
            guard let value = series.value(at: times[index]) else { continue }
            let center = CGPoint(x: x, y: yPosition(value, top: top, plot: plot))
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.stroke(dot, with: .color(Color(uiColor: .secondarySystemGroupedBackground)), lineWidth: 4)
            context.fill(dot, with: .color(series.dashed == true ? .secondary : O11yPalette.color(slot: series.slot)))
        }
    }

    private func callout(index: Int, times: [Double], geometry: O11yChartGeometry) -> some View {
        let time = times[index]
        let rows = geometry.visible
            .compactMap { series in series.value(at: time).map { (series: series, value: $0) } }
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 3) {
            Text(O11yTime.axis(time, step: chart.step) + (chart.step >= 86_400_000 ? "" : " · " + O11yTime.row(time, now: .distantFuture)))
                .font(.caption.weight(.semibold))
            ForEach(rows.prefix(8), id: \.series.name) { row in
                HStack(spacing: 5) {
                    Circle()
                        .fill(row.series.dashed == true ? Color.secondary : O11yPalette.color(slot: row.series.slot))
                        .frame(width: 7, height: 7)
                    Text(row.series.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(O11yFormat.value(row.value, chart.unit))
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }

    private func summary(_ geometry: O11yChartGeometry) -> String {
        geometry.visible.map { series in
            let value = series.total ?? series.points.compactMap(\.value).last
            return "\(series.name) \(O11yFormat.value(value, chart.unit))"
        }
        .joined(separator: ", ")
    }
}

/// A chart's touches (mobile/DESIGN.md "o11y" › chart › Touch): a tap shows the nearest point's values (another tap
/// on it hides them); holding 0.25 s then dragging moves along the plot, and letting go hides them. The page's own
/// pan wins whenever the finger moves first, so a swipe that starts on a chart scrolls the page.
struct O11yChartTouches: UIViewRepresentable {
    let tap: (CGFloat) -> Void
    /// The finger's x while scrubbing; nil when it lifts.
    let scrub: (CGFloat?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.25
        hold.cancelsTouchesInView = false
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: O11yChartTouches

        init(parent: O11yChartTouches) {
            self.parent = parent
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            parent.tap(recognizer.location(in: recognizer.view).x)
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: parent.scrub(recognizer.location(in: recognizer.view).x)
            default: parent.scrub(nil)
            }
        }
    }
}

/// Chips that wrap onto as many lines as they need.
struct O11yFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let fitted = min(size.width, width)
            if x > 0, x + fitted > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += fitted + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let fitted = min(size.width, bounds.width)
            if x > bounds.minX, x + fitted > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: fitted, height: size.height))
            x += fitted + spacing
            line = max(line, size.height)
        }
    }
}
