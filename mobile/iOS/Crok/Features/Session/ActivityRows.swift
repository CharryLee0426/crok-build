import SwiftUI
import UIKit

// The agent's reasoning and tool calls, after Crok Desktop's rows (TranscriptRowViews.swift, ThinkingEffects.swift)
// but by their status only: the relay does not send a thought's text or a tool's output to the phones, so nothing
// expands (mobile/DESIGN.md "Thinking and tool calls"). Both draw on `Theme.card`, which reads on Crok Day and Night,
// every session theme and a photo; state tints go on top of it.

/// Reasoning: "Thinking…" with the thinking colours sweeping through it and a bar along the bottom while it is the
/// newest thing of a running turn, then a quiet "Thought".
struct ThoughtRow: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if active && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        card(time: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    card(time: nil)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            Spacer(minLength: 28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(active ? "thoughtRowActive" : "thoughtRow")
    }

    /// `time`: now, to move the effect; nil draws it still.
    private func card(time: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(time.map { ($0 / 2.8).truncatingRemainder(dividingBy: 1) * 360 } ?? 0))
            Text(active ? "Thinking…" : "Thought")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(
            active ? AnyShapeStyle(ActivityEffects.sweep(Theme.thinkingColors, time: time, period: 2.4))
                : AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, active ? 13 : 8)
        // The bar as wide as the label, under it.
        .overlay(alignment: .bottom) {
            if active {
                ThinkingBar(time: time)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// The 2 pt bar under "Thinking…": a faint track and a segment sliding end to end and back (Desktop's progress bar).
private struct ThinkingBar: View {
    let time: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let segment = time == nil ? width : min(max(width * 0.36, 36), min(260, width))
            let travel = ActivityEffects.pingPong(time, period: 2.5)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                Capsule()
                    .fill(ActivityEffects.sweep(Theme.thinkingColors, time: time, period: 3.8))
                    .frame(width: segment)
                    .offset(x: (width - segment) * travel)
            }
        }
        .frame(height: 2)
    }
}

/// A tool call: a status glyph, its title and a status word, on a card tinted by its state.
struct ToolCard: View {
    let call: ToolCall
    /// The session's turn is still going (`running` or `waiting`).
    let turnRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: ToolRowState { ToolRowState(call.status, turnRunning: turnRunning) }
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                glyph
                    .frame(width: 16, height: 16)
                Text(ToolTitle.attributed(call.title))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let word {
                    Text(word)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background {
                shape.fill(Theme.card)
                if let fill = stateFill { shape.fill(fill) }
            }
            .overlay { border }
            .contentShape(shape)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = call.title
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Spacer(minLength: 28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toolCard")
        .accessibilityValue(Text(word ?? ""))
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .running:
            ToolSpinner(tint: Theme.toolRunning)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.toolDone)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.toolFailed)
        case .stopped, .other:
            Image(systemName: ToolTitle.symbol(for: call.toolKind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var word: String? {
        switch state {
        case .running: String(localized: "running")
        case .completed: String(localized: "done")
        case .failed: String(localized: "failed")
        case .stopped: String(localized: "stopped")
        case .other: nil
        }
    }

    private var tint: Color {
        switch state {
        case .running: Theme.toolRunning
        case .completed: Theme.toolDone
        case .failed: Theme.toolFailed
        case .stopped, .other: .secondary
        }
    }

    private var stateFill: Color? {
        switch state {
        case .completed: Theme.toolDone.opacity(0.10)
        case .failed: Theme.toolFailed.opacity(0.10)
        case .running, .stopped, .other: nil
        }
    }

    @ViewBuilder private var border: some View {
        switch state {
        case .completed:
            shape.strokeBorder(Theme.toolDone.opacity(0.35), lineWidth: 1)
        case .failed:
            shape.strokeBorder(Theme.toolFailed.opacity(0.40), lineWidth: 1)
        case .running:
            if reduceMotion {
                shape.strokeBorder(ActivityEffects.sweep(Theme.runningRimColors, time: nil, period: 3.4), lineWidth: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    shape.strokeBorder(
                        ActivityEffects.sweep(
                            Theme.runningRimColors, time: context.date.timeIntervalSinceReferenceDate, period: 3.4),
                        lineWidth: 1)
                }
            }
        case .stopped, .other:
            shape.strokeBorder(Theme.hairline)
        }
    }
}

/// Desktop's spinner: a faint 13 pt ring with a 68 % arc turning once every 0.9 s.
private struct ToolSpinner: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ring(angle: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                ring(angle: (context.date.timeIntervalSinceReferenceDate / 0.9).truncatingRemainder(dividingBy: 1) * 360)
            }
        }
    }

    private func ring(angle: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle - 90))
        }
        .frame(width: 13, height: 13)
        .accessibilityLabel(Text("Running"))
    }
}

/// The moving colours: a gradient wider than what it fills (2.6×), sliding sideways and back with ease-in-out.
enum ActivityEffects {
    /// 0 → 1 → 0 over `period` seconds, eased; 0 while `time` is nil (Reduce Motion: still).
    static func pingPong(_ time: Double?, period: Double) -> Double {
        guard let time else { return 0 }
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        let linear = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return linear * linear * (3 - 2 * linear)
    }

    static func sweep(_ colors: [Color], time: Double?, period: Double) -> LinearGradient {
        let shift = 1.6 * pingPong(time, period: period)
        return LinearGradient(
            colors: colors, startPoint: UnitPoint(x: -shift, y: 0.5), endPoint: UnitPoint(x: 2.6 - shift, y: 0.5))
    }
}

/// A tool call's title as Desktop draws it: `code` spans in the monospaced font on the code fill, padded by thin
/// spaces (`` Execute `git status` ``).
enum ToolTitle {
    static func attributed(_ title: String) -> AttributedString {
        var result = AttributedString()
        let parts = title.split(separator: "`", omittingEmptySubsequences: false)
        // An odd count of backticks leaves the last one as text.
        let closed = parts.count % 2 == 1 ? parts.count : parts.count - 1
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 && index < closed {
                var code = AttributedString("\u{2009}\(part)\u{2009}")
                code.font = .system(.footnote, design: .monospaced)
                code.backgroundColor = Theme.codeBackground
                result += code
            } else {
                result += AttributedString((index % 2 == 1 ? "`" : "") + part)
            }
        }
        return result
    }

    /// The glyph of a tool's kind (ACP's `kind`).
    static func symbol(for kind: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.left.arrow.right"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}
