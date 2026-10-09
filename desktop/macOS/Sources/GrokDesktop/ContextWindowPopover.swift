import SwiftUI

/// The composer's context ring, opened: the window as a large ring divided by what fills it, the
/// figures beside it, and where auto-compact begins. The breakdown is measured as it opens; until
/// it arrives, the ring's own figure stands in.
struct ContextWindowPopover: View {
    @ObservedObject var tokens: TokenMeterModel
    @ObservedObject var account: AccountFeatureModel
    let conversationID: UUID
    let catalogWindow: Int?
    var openDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    static let ringSize: CGFloat = 140
    static let ringWidth: CGFloat = 14

    var body: some View {
        let state = account.contextBreakdowns[conversationID] ?? ContextBreakdownState()
        let figures = ContextWindowFigures(snapshot: state.snapshot, usage: tokens.contextUsage(conversationID, catalogWindow: catalogWindow))
        let skeleton = figures.legend.isEmpty && state.isLoading
        VStack(alignment: .leading, spacing: 16) {
            header(state)
            HStack(alignment: .center, spacing: 22) {
                ring(figures, measuring: state.isLoading)
                VStack(alignment: .leading, spacing: 0) {
                    if skeleton {
                        legend(ContextWindowFigures.placeholder).redacted(reason: .placeholder)
                    } else if figures.legend.isEmpty {
                        Text("Send a message, or wait for the task to connect, to measure its context.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        legend(figures)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = state.error {
                Label(figures.snapshot == nil ? "Couldn't measure the breakdown: \(error)" : "Showing the last measurement. \(error)",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = figures.snapshot { notes(snapshot) }
            Divider()
            HStack {
                if let snapshot = figures.snapshot {
                    Text("\(UsageFormatting.groupThousands(snapshot.used)) of \(UsageFormatting.groupThousands(snapshot.total)) tokens")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button(action: openDetails) {
                    HStack(spacing: 3) {
                        Text("Usage details")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Open Usage on its Context tab · /context")
            }
        }
        .padding(18)
        .frame(width: 448)
        .onAppear {
            guard !revealed else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { revealed = true }
        }
    }

    private func header(_ state: ContextBreakdownState) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Context window").font(.system(size: 14, weight: .semibold))
            if state.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Measuring") }
            Spacer(minLength: 8)
            if let model = state.model {
                Text(model).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }

    private func ring(_ figures: ContextWindowFigures, measuring: Bool) -> some View {
        let fraction = figures.fraction
        return ZStack {
            ContextDonut(arcs: figures.arcs, size: Self.ringSize, lineWidth: Self.ringWidth, marker: figures.compactThreshold,
                         progress: revealed ? 1 : 0, dashed: figures.used == nil)
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: figures.arcs)
            VStack(spacing: 3) {
                Text(fraction.map(TokenFormat.percent) ?? (figures.used == nil ? "–" : UsageFormatting.tokensBig(figures.used ?? 0)))
                    .font(.system(size: fraction == nil ? 22 : 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(fraction.map(Self.tint) ?? Theme.ink)
                    .contentTransition(.numericText())
                Text(caption(figures, measuring: measuring))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            .frame(width: Self.ringSize - Self.ringWidth * 2 - 8)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window")
        .accessibilityValue(figures.accessibilityValue)
    }

    private func caption(_ figures: ContextWindowFigures, measuring: Bool) -> String {
        guard let used = figures.used else { return measuring ? "Measuring…" : "Not measured" }
        guard let total = figures.total else { return "tokens used" }
        return "\(UsageFormatting.tokensBig(used)) / \(UsageFormatting.tokensBig(total))"
    }

    private func legend(_ figures: ContextWindowFigures) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            ForEach(figures.legend) { part in
                GridRow {
                    HStack(spacing: 8) {
                        Group {
                            if part.hollow { RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.muted.opacity(0.7), lineWidth: 1) }
                            else { RoundedRectangle(cornerRadius: 3).fill(part.color) }
                        }
                        .frame(width: 10, height: 10)
                        Text(part.label).lineLimit(1)
                    }
                    Text(UsageFormatting.tokens(part.tokens)).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(figures.total.map { UsageFormatting.percentOfWindow(part.tokens, $0) } ?? "")
                        .monospacedDigit().foregroundStyle(Theme.muted).gridColumnAlignment(.trailing)
                }
                .font(.system(size: 12.5))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func notes(_ snapshot: UsageContextSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = snapshot.autoCompact {
                Label(line.text, systemImage: line.warning ? "exclamationmark.triangle" : "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(line.warning ? UsagePalette.warning : Theme.muted)
            }
            Text(snapshot.stats).foregroundStyle(Theme.muted)
            if snapshot.showsCompactTip {
                Label("Tip: run /compact to free up context space.", systemImage: "lightbulb").foregroundStyle(UsagePalette.warning)
            }
        }
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The composer ring's colours, from the normal ink: the warning colour from 75%, the error colour from 95%.
    private static func tint(_ fraction: Double) -> Color {
        fraction >= 0.95 ? Theme.red : fraction >= 0.75 ? ComposerPalette.warning : Theme.ink
    }
}

/// What the popover draws, from the measured breakdown when there is one and the ring's figure otherwise.
struct ContextWindowFigures {
    struct Part: Identifiable {
        var id: String { label }
        let label: String
        let tokens: UInt64
        let color: Color
        var hollow = false
    }

    var used: UInt64?
    var total: UInt64?
    var legend: [Part] = []
    var snapshot: UsageContextSnapshot?

    init(snapshot: UsageContextSnapshot?, usage: ContextUsage?) {
        if let snapshot, snapshot.total > 0 {
            self.snapshot = snapshot
            used = snapshot.used
            total = snapshot.total
            let window = snapshot.window
            legend = [Part(label: "System prompt", tokens: window.system, color: UsagePalette.system),
                      Part(label: "Messages", tokens: window.messages, color: UsagePalette.messages)]
            if window.overhead > 0 { legend.append(Part(label: "Reasoning/overhead", tokens: window.overhead, color: UsagePalette.overhead)) }
            legend.append(Part(label: "Free", tokens: window.free, color: UsagePalette.free, hollow: true))
        } else if let usage {
            let used = UInt64(max(0, usage.used))
            self.used = used
            total = usage.window.map { UInt64(max(0, $0)) }
            let tint = usage.fraction.map(ComposerContextRing.tint) ?? Theme.ink.opacity(0.7)
            legend = [Part(label: "Used", tokens: used, color: tint)]
            if let total, total > used { legend.append(Part(label: "Free", tokens: total - used, color: UsagePalette.free, hollow: true)) }
        }
    }

    private init(placeholderLegend: [Part]) { legend = placeholderLegend }

    /// Rows the shape of a breakdown, for the moment before the first one arrives.
    static let placeholder = ContextWindowFigures(placeholderLegend: [
        Part(label: "System prompt", tokens: 8_000, color: UsagePalette.system),
        Part(label: "Messages", tokens: 40_000, color: UsagePalette.messages),
        Part(label: "Free", tokens: 200_000, color: UsagePalette.free, hollow: true),
    ])

    /// Past 1 when the context has outgrown its window.
    var fraction: Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    var compactThreshold: Double? {
        snapshot.map { min(1, Double($0.autoCompactThresholdPercent) / 100) }
    }

    /// The filled parts as arcs of the whole ring, clockwise from the top, a hair apart.
    var arcs: [ContextDonut.Arc] {
        guard let total, total > 0 else { return [] }
        let drawn = legend.filter { !$0.hollow && $0.tokens > 0 }
        let gap = 0.008
        var start = 0.0
        var arcs: [ContextDonut.Arc] = []
        for (index, part) in drawn.enumerated() {
            let span = min(Double(part.tokens) / Double(total), 1 - start)
            guard span > 0 else { continue }
            let roomy = span > gap * 2
            arcs.append(ContextDonut.Arc(id: part.label, start: start + (index > 0 && roomy ? gap / 2 : 0),
                                         end: start + span - (index < drawn.count - 1 && roomy ? gap / 2 : 0), color: part.color))
            start += span
        }
        return arcs
    }

    var accessibilityValue: String {
        guard let used else { return "Not measured yet" }
        var text = total.map { "\(TokenFormat.percent(Double(used) / Double(max(1, $0)))) full, \(used.formatted()) of \($0.formatted()) tokens" }
            ?? "\(used.formatted()) tokens used"
        let parts = legend.filter { !$0.hollow && $0.label != "Used" }
        if !parts.isEmpty { text += ". " + parts.map { "\($0.label) \($0.tokens.formatted())" }.joined(separator: ", ") }
        return text
    }
}

/// A ring divided into arcs, clockwise from the top, over a faint track, with an optional mark on it.
struct ContextDonut: View {
    struct Arc: Identifiable, Equatable {
        let id: String
        let start: Double
        let end: Double
        let color: Color
    }

    let arcs: [Arc]
    var size: CGFloat
    var lineWidth: CGFloat
    /// Where along the ring, from 0 to 1, a tick is drawn across it.
    var marker: Double?
    /// How much of each arc is drawn, for the sweep as the ring appears.
    var progress: Double = 1
    var dashed = false

    var body: some View {
        ZStack {
            if dashed {
                Circle().inset(by: lineWidth / 2).stroke(Theme.muted.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            } else {
                Circle().inset(by: lineWidth / 2).stroke(Theme.muted.opacity(0.14), lineWidth: lineWidth)
            }
            ForEach(arcs) { arc in
                Circle().inset(by: lineWidth / 2)
                    .trim(from: arc.start * progress, to: arc.end * progress)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if let marker {
                Capsule().fill(Theme.ink.opacity(0.65))
                    .frame(width: 2, height: lineWidth + 7)
                    .offset(y: -(size - lineWidth) / 2)
                    .rotationEffect(.degrees(360 * marker))
                    .help("Auto-compact begins here")
            }
        }
        .frame(width: size, height: size)
    }
}
