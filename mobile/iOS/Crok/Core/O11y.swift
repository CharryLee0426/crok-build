import Foundation

// The o11y tab's pages (mobile/DESIGN.md "o11y", relay/DESIGN.md §3 "o11y"): the relay builds them from its owner's
// Grafana stack and sends finished blocks; the app only draws them. Text arrives in the page's language, numbers raw
// with a unit (`O11yFormat`).

enum O11yUnit: String, Sendable, Equatable, Decodable {
    case usd, count, tokens, ratio, seconds, ms, bytes, perMin, tps

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = O11yUnit(rawValue: raw) ?? .count
    }
}

/// Which way a number moving is good: colours its change.
enum O11yBetter: String, Sendable, Equatable, Decodable {
    case up, down, none

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = O11yBetter(rawValue: raw) ?? .none
    }
}

struct O11yValue: Sendable, Equatable, Decodable {
    var v: Double
    var u: O11yUnit
}

/// A detail chip: text, or a value with an optional suffix ("12.3K in").
enum O11yChip: Sendable, Equatable, Decodable {
    case text(String)
    case value(Double, O11yUnit, suffix: String?)

    private enum Keys: String, CodingKey { case t, v, u, s }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let text = try c.decodeIfPresent(String.self, forKey: .t) {
            self = .text(text)
        } else {
            self = .value(
                try c.decode(Double.self, forKey: .v), try c.decodeIfPresent(O11yUnit.self, forKey: .u) ?? .count,
                suffix: try c.decodeIfPresent(String.self, forKey: .s))
        }
    }
}

struct O11yStat: Sendable, Equatable, Decodable {
    var label: String
    var value: Double?
    var unit: O11yUnit
    var change: Double?
    var better: O11yBetter?
}

struct O11ySeries: Sendable, Equatable, Decodable, Identifiable {
    var name: String
    /// 1–8: the categorical palette; 0: "Other" (and comparison lines).
    var slot: Int
    var total: Double?
    var dashed: Bool?
    var points: [O11yPoint]

    var id: String { name }
}

struct O11yPoint: Sendable, Equatable, Decodable {
    var time: Double
    var value: Double?

    init(time: Double, value: Double?) {
        self.time = time
        self.value = value
    }

    /// `[ms, value|null]`.
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        time = try c.decode(Double.self)
        value = try c.decodeIfPresent(Double.self)
    }
}

struct O11yRankRow: Sendable, Equatable, Decodable {
    var label: String
    var value: Double
    var slot: Int?
    var detail: [O11yChip]?
    var change: Double?
    var better: O11yBetter?
}

enum O11yStatus: String, Sendable, Equatable, Decodable {
    case ok, warn, bad, info
}

struct O11yListRow: Sendable, Equatable, Decodable {
    var title: String
    var detail: [O11yChip]?
    var value: O11yValue?
    var time: Double?
    var status: O11yStatus?
    var page: String?
}

struct O11yLinkRow: Sendable, Equatable, Decodable {
    var page: String
    var title: String
    var subtitle: String?
    var icon: String
    var color: String
    var value: O11yValue?
}

enum O11yBlock: Sendable, Equatable, Decodable {
    case stats([O11yStat])
    case chart(O11yChart)
    case ranking(O11yRanking)
    case list(rows: [O11yListRow], empty: String)
    case links([O11yLinkRow])
    case note(String)
    case error(String)
    /// A kind this build does not know (a newer relay): drawn as nothing.
    case unknown

    struct O11yChart: Sendable, Equatable {
        var style: Style
        var stacked: Bool
        var unit: O11yUnit
        /// The step between points, in ms.
        var step: Double
        var series: [O11ySeries]
        var more: Int

        enum Style: String, Sendable { case line, bars }
    }

    struct O11yRanking: Sendable, Equatable {
        var unit: O11yUnit
        var rows: [O11yRankRow]
        var more: Int
        var empty: String
    }

    private enum Keys: String, CodingKey {
        case kind, items, style, stacked, unit, step, series, more, rows, empty, text, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "stats":
            self = .stats(try c.decode([O11yStat].self, forKey: .items))
        case "chart":
            self = .chart(
                O11yChart(
                    style: O11yChart.Style(rawValue: try c.decode(String.self, forKey: .style)) ?? .line,
                    stacked: try c.decodeIfPresent(Bool.self, forKey: .stacked) ?? false,
                    unit: try c.decode(O11yUnit.self, forKey: .unit),
                    step: try c.decodeIfPresent(Double.self, forKey: .step) ?? 60_000,
                    series: try c.decode([O11ySeries].self, forKey: .series),
                    more: Int(try c.decodeIfPresent(Double.self, forKey: .more) ?? 0)))
        case "ranking":
            self = .ranking(
                O11yRanking(
                    unit: try c.decode(O11yUnit.self, forKey: .unit),
                    rows: try c.decode([O11yRankRow].self, forKey: .rows),
                    more: Int(try c.decodeIfPresent(Double.self, forKey: .more) ?? 0),
                    empty: try c.decodeIfPresent(String.self, forKey: .empty) ?? ""))
        case "list":
            self = .list(
                rows: try c.decode([O11yListRow].self, forKey: .rows),
                empty: try c.decodeIfPresent(String.self, forKey: .empty) ?? "")
        case "links":
            self = .links(try c.decode([O11yLinkRow].self, forKey: .rows))
        case "note":
            self = .note(try c.decode(String.self, forKey: .text))
        case "error":
            self = .error(try c.decode(String.self, forKey: .message))
        default:
            self = .unknown
        }
    }

    /// Wide layouts give stats and charts the whole width and pair the rest (mobile/DESIGN.md "Layout").
    var spansWidth: Bool {
        switch self {
        case .stats, .chart: true
        default: false
        }
    }
}

struct O11ySection: Sendable, Equatable, Decodable, Identifiable {
    var title: String?
    var footer: String?
    var block: O11yBlock
    /// Its place on the page (set when the page is decoded), so two sections of the same title stay apart.
    var index = 0

    var id: Int { index }

    private enum Keys: String, CodingKey { case title, footer, block }

    init(title: String?, footer: String?, block: O11yBlock, index: Int = 0) {
        self.title = title
        self.footer = footer
        self.block = block
        self.index = index
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        footer = try c.decodeIfPresent(String.self, forKey: .footer)
        block = try c.decode(O11yBlock.self, forKey: .block)
    }
}

struct O11yPage: Sendable, Equatable, Decodable {
    var id: String
    var title: String
    var subtitle: String?
    var range: String
    var ranges: [String]
    var url: String?
    var builtAt: Double
    var sections: [O11ySection]

    private enum Keys: String, CodingKey { case id, title, subtitle, range, ranges, url, builtAt, sections }

    init(id: String, title: String, subtitle: String?, range: String, ranges: [String], url: String?, builtAt: Double,
         sections: [O11ySection])
    {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.range = range
        self.ranges = ranges
        self.url = url
        self.builtAt = builtAt
        self.sections = sections.enumerated().map { index, section in
            var s = section
            s.index = index
            return s
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
            range: try c.decode(String.self, forKey: .range),
            ranges: try c.decodeIfPresent([String].self, forKey: .ranges) ?? [],
            url: try c.decodeIfPresent(String.self, forKey: .url),
            builtAt: try c.decode(Double.self, forKey: .builtAt),
            sections: try c.decode([O11ySection].self, forKey: .sections))
    }
}

/// What `o11y:page` answers: the cached page (however old) or why there is none for this account.
struct O11yPageState: Sendable, Equatable, Decodable {
    enum State: String, Sendable, Decodable {
        case ok, forbidden, unconfigured
    }

    var state: State
    var page: O11yPage?
    var builtAt: Double?
    var refreshing: Bool
    var error: String?

    private enum Keys: String, CodingKey { case state, page, builtAt, refreshing, error }

    init(state: State, page: O11yPage? = nil, builtAt: Double? = nil, refreshing: Bool = false, error: String? = nil) {
        self.state = state
        self.page = page
        self.builtAt = builtAt
        self.refreshing = refreshing
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = State(rawValue: (try? c.decode(String.self, forKey: .state)) ?? "") ?? .unconfigured
        page = try c.decodeIfPresent(O11yPage.self, forKey: .page)
        builtAt = try c.decodeIfPresent(Double.self, forKey: .builtAt)
        refreshing = try c.decodeIfPresent(Bool.self, forKey: .refreshing) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct O11yRefreshResult: Sendable, Equatable, Decodable {
    var status: String
    var builtAt: Double?
    var error: String?
}

// MARK: - When to ask for a new page

/// mobile/DESIGN.md "Loading and refresh": a page older than 90 s is stale; a visible screen checks every 60 s.
enum O11yRefreshPolicy {
    static let staleAfter: TimeInterval = 90
    static let checkEvery: Duration = .seconds(60)
    /// The phone does not ask again sooner than this after its own last ask (the relay dedupes too).
    static let minimumGap: TimeInterval = 15

    static func isStale(_ state: O11yPageState?, now: Date) -> Bool {
        guard let state, state.state == .ok else { return false }
        guard let builtAt = state.builtAt ?? state.page?.builtAt else { return true }
        return now.timeIntervalSince1970 - builtAt / 1000 > staleAfter
    }
}

/// The relay's language codes, from the app's own UI language.
enum O11yLanguage {
    static func code(for localization: String?) -> String {
        let id = (localization ?? "en").lowercased()
        for code in ["zh", "ja", "es", "fr", "de"] where id.hasPrefix(code) {
            return code
        }
        return "en"
    }

    static var current: String { code(for: Bundle.main.preferredLocalizations.first) }
}

// MARK: - Numbers

/// The o11y number rules (mobile/DESIGN.md "Numbers"), the same in both apps: the locale's decimal separator, K / M / B
/// in every language.
enum O11yFormat {
    static func value(_ v: Double?, _ unit: O11yUnit, locale: Locale = .current) -> String {
        guard let v, v.isFinite else { return "—" }
        switch unit {
        case .usd:
            if v == 0 { return "$0" }
            let sign = v < 0 ? "\u{2212}" : ""
            let a = abs(v)
            if a < 0.01 { return sign + "$" + trimmed(a, decimals: 4, locale: locale) }
            if a < 1000 { return sign + "$" + fixed(a, decimals: 2, locale: locale) }
            return sign + "$" + compact(a, locale: locale, decimalsUnder100: true)
        case .count, .tokens:
            return count(v, locale: locale)
        case .ratio:
            if v == 0 { return "0%" }
            if v == 1 { return "100%" }
            return trimmed(v * 100, decimals: 1, locale: locale) + "%"
        case .seconds:
            return seconds(v, locale: locale)
        case .ms:
            return seconds(v / 1000, locale: locale)
        case .bytes:
            return bytes(v, locale: locale)
        case .perMin:
            return count(v, locale: locale) + "/min"
        case .tps:
            return count(v, locale: locale) + " tok/s"
        }
    }

    /// A chart's y-axis labels: every tick in the unit the top one needs, no trailing zeros ("$15", "$7.5";
    /// "75 s", "50 s"; "1.5K", "500").
    static func axis(_ ticks: [Double], _ unit: O11yUnit, locale: Locale = .current) -> [String] {
        let top = ticks.map(abs).max() ?? 0
        switch unit {
        case .usd:
            return ticks.map { v in
                if v == 0 { return "$0" }
                if top < 0.01 { return "$" + trimmed(v, decimals: 4, locale: locale) }
                if top < 1000 { return "$" + trimmed(v, decimals: 2, locale: locale) }
                return "$" + compact(v, locale: locale, decimalsUnder100: true)
            }
        case .count, .tokens:
            return ticks.map { count($0, locale: locale) }
        case .perMin:
            return ticks.map { count($0, locale: locale) + "/min" }
        case .tps:
            return ticks.map { count($0, locale: locale) + " tok/s" }
        case .ratio:
            return ticks.map { trimmed($0 * 100, decimals: 1, locale: locale) + "%" }
        case .seconds, .ms:
            let seconds = unit == .ms ? ticks.map { $0 / 1000 } : ticks
            let max = unit == .ms ? top / 1000 : top
            let (divisor, suffix): (Double, String) =
                max < 1 ? (0.001, " ms") : max < 120 ? (1, " s") : max < 7200 ? (60, " min") : (3600, " h")
            return seconds.map { trimmed($0 / divisor, decimals: 1, locale: locale) + suffix }
        case .bytes:
            let (divisor, suffix): (Double, String) =
                top < 1024 ? (1, " B") : top < 1_048_576 ? (1024, " KB") : top < 1_073_741_824 ? (1_048_576, " MB") : (1_073_741_824, " GB")
            return ticks.map { trimmed($0 / divisor, decimals: 1, locale: locale) + suffix }
        }
    }

    /// "+12%", "−8%", "+0.4%"; nil for no change to show.
    static func change(_ c: Double?, locale: Locale = .current) -> String? {
        guard let c, c.isFinite else { return nil }
        let pct = c * 100
        if pct == 0 { return "0%" }
        let size = abs(pct)
        let text = size < 1 ? trimmed(size, decimals: 1, locale: locale) : fixed(size, decimals: 0, locale: locale)
        return (pct > 0 ? "+" : "\u{2212}") + text + "%"
    }

    /// Whether a change is good news: green, red, or neither.
    static func tone(_ change: Double?, better: O11yBetter?) -> Tone {
        guard let change, change != 0, let better, better != .none else { return .neutral }
        return (change > 0) == (better == .up) ? .good : .bad
    }

    enum Tone { case good, bad, neutral }

    /// A detail chip's text.
    static func chip(_ chip: O11yChip, locale: Locale = .current) -> String {
        switch chip {
        case .text(let text): text
        case .value(let v, let unit, let suffix):
            suffix.map { "\(value(v, unit, locale: locale)) \($0)" } ?? value(v, unit, locale: locale)
        }
    }

    // MARK: Pieces

    static func count(_ v: Double, locale: Locale) -> String {
        let sign = v < 0 ? "\u{2212}" : ""
        let a = abs(v)
        if a < 1000 {
            let whole = abs(a - a.rounded()) < 1e-9
            if whole { return sign + fixed(a, decimals: 0, locale: locale) }
            let text = trimmed(a, decimals: 1, locale: locale)
            return sign + (text == fixed(1000, decimals: 0, locale: locale) ? "1K" : text)
        }
        return sign + compact(a, locale: locale, decimalsUnder100: true)
    }

    /// 1.2K, 340K, 1.2M, 3.4B: one decimal under 100 of the unit, none above.
    static func compact(_ a: Double, locale: Locale, decimalsUnder100: Bool) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        var index = units.firstIndex { a >= $0.0 } ?? units.count - 1
        while true {
            let (size, suffix) = units[index]
            let mantissa = a / size
            let decimals = decimalsUnder100 && mantissa < 99.95 ? 1 : 0
            let rounded = (mantissa * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
            if rounded >= 1000, index > 0 {
                index -= 1
                continue
            }
            return trimmed(rounded, decimals: decimals, locale: locale) + suffix
        }
    }

    static func seconds(_ s: Double, locale: Locale) -> String {
        let a = abs(s)
        if a < 1 { return fixed(a * 1000, decimals: 0, locale: locale) + " ms" }
        if a < 60 { return fixed(a, decimals: 1, locale: locale) + " s" }
        if a < 3600 { return fixed(a / 60, decimals: 1, locale: locale) + " min" }
        return fixed(a / 3600, decimals: 1, locale: locale) + " h"
    }

    static func bytes(_ b: Double, locale: Locale) -> String {
        let a = abs(b)
        if a < 1024 { return fixed(a, decimals: 0, locale: locale) + " B" }
        if a < 1024 * 1024 { return fixed(a / 1024, decimals: 1, locale: locale) + " KB" }
        if a < 1024 * 1024 * 1024 { return fixed(a / 1024 / 1024, decimals: 1, locale: locale) + " MB" }
        return fixed(a / 1024 / 1024 / 1024, decimals: 1, locale: locale) + " GB"
    }

    /// Exactly `decimals` decimals, no grouping.
    static func fixed(_ v: Double, decimals: Int, locale: Locale) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never).locale(locale))
    }

    /// Up to `decimals` decimals, trailing zeros dropped.
    static func trimmed(_ v: Double, decimals: Int, locale: Locale) -> String {
        v.formatted(.number.precision(.fractionLength(0...decimals)).grouping(.never).locale(locale))
    }
}

// MARK: - Times

enum O11yTime {
    /// Chart axis and callout times: "14:00" for steps under a day, "Oct 24" for daily ones.
    static func axis(_ ms: Double, step: Double, locale: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return step >= 86_400_000 ? date.formatted(day.locale(locale)) : hhmm(date, locale: locale)
    }

    /// A list row's time: "14:02" today, "Oct 24" before.
    static func row(_ ms: Double, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return calendar.isDate(date, inSameDayAs: now) ? hhmm(date, locale: locale) : date.formatted(day.locale(locale))
    }

    private static let day = Date.FormatStyle().month(.abbreviated).day()

    static func hhmm(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter.string(from: date)
    }
}

// MARK: - Demo

extension O11yPage {
    /// Every word on the page through `translate` (the demo applies the relay's table this way).
    func mapText(_ translate: (String) -> String) -> O11yPage {
        func chips(_ list: [O11yChip]?) -> [O11yChip]? {
            list?.map { chip in
                if case .text(let text) = chip { return .text(translate(text)) }
                return chip
            }
        }
        var page = self
        page.title = translate(title)
        page.subtitle = subtitle.map(translate)
        page.sections = sections.map { section in
            var s = section
            s.title = section.title.map(translate)
            s.footer = section.footer.map(translate)
            switch section.block {
            case .stats(let items):
                s.block = .stats(items.map { var i = $0; i.label = translate($0.label); return i })
            case .chart(var chart):
                chart.series = chart.series.map { var x = $0; x.name = translate($0.name); return x }
                s.block = .chart(chart)
            case .ranking(var ranking):
                ranking.rows = ranking.rows.map { var r = $0; r.label = translate($0.label); r.detail = chips($0.detail); return r }
                ranking.empty = translate(ranking.empty)
                s.block = .ranking(ranking)
            case .list(let rows, let empty):
                s.block = .list(
                    rows: rows.map { var r = $0; r.title = translate($0.title); r.detail = chips($0.detail); return r },
                    empty: translate(empty))
            case .links(let rows):
                s.block = .links(rows.map { var r = $0; r.title = translate($0.title); r.subtitle = $0.subtitle.map(translate); return r })
            case .note(let text):
                s.block = .note(translate(text))
            case .error, .unknown:
                break
            }
            return s
        }
        return page
    }

    /// Every time on the page moved by `delta` ms (the demo's fixture was built days ago; its data looks current).
    func shifted(by delta: Double) -> O11yPage {
        var page = self
        page.sections = sections.map { section in
            var s = section
            switch section.block {
            case .chart(var chart):
                chart.series = chart.series.map { series in
                    var x = series
                    x.points = series.points.map { O11yPoint(time: $0.time + delta, value: $0.value) }
                    return x
                }
                s.block = .chart(chart)
            case .list(let rows, let empty):
                s.block = .list(rows: rows.map { var r = $0; r.time = $0.time.map { $0 + delta }; return r }, empty: empty)
            default:
                break
            }
            return s
        }
        return page
    }
}
