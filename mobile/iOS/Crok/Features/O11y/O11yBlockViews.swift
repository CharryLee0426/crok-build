import SwiftUI
import UIKit

/// A page section as a grouped-list card: the header above it, the block inside, the footer under it.
struct O11ySectionView: View {
    let section: O11ySection
    let wide: Bool
    let chartHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = section.title, !title.isEmpty {
                Text(title)
                    .font(.footnote)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            O11yBlockView(block: section.block, title: section.title ?? "", wide: wide, chartHeight: chartHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer = section.footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        // A container, so the identifier names the section and its rows keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("o11ySection-\(section.index)")
    }
}

struct O11yBlockView: View {
    let block: O11yBlock
    let title: String
    let wide: Bool
    let chartHeight: CGFloat

    var body: some View {
        switch block {
        case .stats(let items):
            O11yStatsGrid(items: items, columns: wide ? 4 : 2)
        case .chart(let chart):
            O11yChartCard(chart: chart, title: title, height: chartHeight)
        case .ranking(let ranking):
            O11yRankingView(ranking: ranking)
        case .list(let rows, let empty):
            O11yListView(rows: rows, empty: empty)
        case .links(let rows):
            O11yLinksView(rows: rows)
        case .note(let text):
            Label {
                Text(text)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(12)
        case .error(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(O11yPalette.bad)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't read this panel")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            .padding(12)
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - Stats

/// Telegram's overview grid: 2 tiles a row upright, 4 on its side, hairlines between them.
struct O11yStatsGrid: View {
    let items: [O11yStat]
    let columns: Int

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 { Divider() }
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { c in
                        if c > 0 { Divider() }
                        if c < rows[r].count {
                            O11yStatTile(stat: rows[r][c])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct O11yStatTile: View {
    let stat: O11yStat

    var body: some View {
        let change = O11yFormat.change(stat.change)
        let tone = O11yFormat.tone(stat.change, better: stat.better)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(O11yFormat.value(stat.value, stat.unit))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let change {
                    Text(change)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(O11yPalette.tone(tone))
                        .lineLimit(1)
                }
            }
            Text(stat.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stat.label))
        .accessibilityValue(Text(O11yStatTile.spoken(stat)))
    }

    static func spoken(_ stat: O11yStat) -> String {
        let value = O11yFormat.value(stat.value, stat.unit)
        guard let change = stat.change, change != 0, change.isFinite else { return value }
        let percent = O11yFormat.value(abs(change), .ratio)
        return change > 0 ? String(localized: "\(value), up \(percent)") : String(localized: "\(value), down \(percent)")
    }
}

// MARK: - Rankings

/// Ranked rows, each with a thin bar as long as its share of the largest (a ratio's of 1).
struct O11yRankingView: View {
    let ranking: O11yBlock.O11yRanking

    var body: some View {
        if ranking.rows.isEmpty {
            O11yEmptyBlock(text: ranking.empty)
        } else {
            let largest = ranking.rows.map(\.value).max() ?? 0
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ranking.rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    rankRow(row, fraction: fraction(row.value, largest: largest))
                }
                if ranking.more > 0 {
                    Divider().padding(.leading, 12)
                    Text("and \(ranking.more) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
    }

    private func fraction(_ value: Double, largest: Double) -> CGFloat {
        if ranking.unit == .ratio { return CGFloat(min(1, max(0, value))) }
        return largest > 0 ? CGFloat(max(0, value) / largest) : 0
    }

    private func rankRow(_ row: O11yRankRow, fraction: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail.map { O11yFormat.chip($0) }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let change = O11yFormat.change(row.change) {
                    Text(change)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(O11yPalette.tone(O11yFormat.tone(row.change, better: row.better)))
                }
                Text(O11yFormat.value(row.value, ranking.unit))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(O11yPalette.color(slot: row.slot ?? 1))
                    .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * fraction), height: 4)
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lists

struct O11yListView: View {
    let rows: [O11yListRow]
    let empty: String

    var body: some View {
        if rows.isEmpty {
            O11yEmptyBlock(text: empty)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, row.status == nil ? 12 : 40) }
                    if let page = row.page {
                        NavigationLink(value: O11yRoute(page: page)) { O11yListRowView(row: row, chevron: true) }
                            .buttonStyle(.plain)
                    } else {
                        O11yListRowView(row: row, chevron: false)
                    }
                }
            }
        }
    }
}

struct O11yListRowView: View {
    let row: O11yListRow
    let chevron: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let status = row.status {
                statusGlyph(status)
                    .font(.system(size: 18))
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let value = row.value {
                    Text(O11yFormat.value(value.v, value.u))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let time = row.time {
                    Text(O11yTime.row(time, now: Date()))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                let detail = (row.detail ?? []).isEmpty ? [] : [detailText]
                UIPasteboard.general.string = ([row.title] + detail).joined(separator: "\n")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        (row.detail ?? []).map { O11yFormat.chip($0) }.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusGlyph(_ status: O11yStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(O11yPalette.good)
                .accessibilityLabel(Text("OK"))
        case .bad:
            Image(systemName: "xmark.circle.fill").foregroundStyle(O11yPalette.bad)
                .accessibilityLabel(Text("Failed"))
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(O11yPalette.warn)
                .accessibilityLabel(Text("Warning"))
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Links

/// Profile-style rows to other pages (the home page's Dashboards, Evaluation, Agent Observability).
struct O11yLinksView: View {
    let rows: [O11yLinkRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 55) }
                NavigationLink(value: O11yRoute(page: row.page)) {
                    HStack(spacing: 14) {
                        Image(systemName: O11yIcons.symbol(row.icon))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 29, height: 29)
                            .background(O11yIcons.color(row.color), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let value = row.value {
                            Text(O11yFormat.value(value.v, value.u))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("o11yLink-\(row.page)")
            }
        }
    }
}

/// The links' glyphs (mobile/DESIGN.md "o11y" › Icons).
enum O11yIcons {
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "overview": "square.grid.2x2"
        case "claude": "sparkle"
        case "openrouter": "arrow.triangle.branch"
        case "crok": "cpu"
        case "harness": "hammer"
        case "history": "calendar"
        case "explorer": "magnifyingglass"
        case "evaluators": "checkmark.seal"
        case "guards": "shield.lefthalf.filled"
        case "experiments": "flask"
        case "agents": "person.2"
        case "conversations": "bubble.left.and.text.bubble.right"
        case "slos": "target"
        case "alerts": "bell"
        default: "chart.bar"
        }
    }

    static func color(_ hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return Theme.accent }
        return Color(uiColor: UIColor(hex: value))
    }
}

struct O11yEmptyBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
    }
}
