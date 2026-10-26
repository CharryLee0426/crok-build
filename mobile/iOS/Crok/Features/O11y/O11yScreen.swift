import SwiftUI

/// A page on the o11y tab's stack.
struct O11yRoute: Hashable {
    let page: String
}

/// The o11y tab (mobile/DESIGN.md "o11y", dev builds): the page `home`, and the pages its rows open.
struct O11yTab: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            O11yScreen(pageId: "home")
                .navigationDestination(for: O11yRoute.self) { route in
                    O11yScreen(pageId: route.page)
                }
        }
    }
}

/// One page: its cached copy at once, a newer one asked for when it is stale (mobile/DESIGN.md "Loading and refresh").
@MainActor
@Observable
final class O11yPageModel {
    let pageId: String
    /// The range picked on this phone; nil until one is (the relay then uses the page's default).
    private(set) var range: String?
    private(set) var query: LiveQuery<O11yPageState>
    private(set) var asking = false

    @ObservationIgnored private let engine: CrokEngine
    @ObservationIgnored private let lang: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastAsk: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    static func rangeKey(_ pageId: String) -> String { "crok.o11y.range.\(pageId)" }

    init(engine: CrokEngine, pageId: String, lang: String = O11yLanguage.current, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init)
    {
        self.engine = engine
        self.pageId = pageId
        self.lang = lang
        self.defaults = defaults
        self.now = now
        let range = defaults.string(forKey: Self.rangeKey(pageId))
        self.range = range
        query = Self.makeQuery(engine: engine, pageId: pageId, range: range, lang: lang)
    }

    private static func makeQuery(engine: CrokEngine, pageId: String, range: String?, lang: String) -> LiveQuery<O11yPageState> {
        let api = engine.backend.o11y
        return LiveQuery(engine: engine) { api.page(pageId, range: range, lang: lang) }
    }

    var state: O11yPageState? { query.value }
    var page: O11yPage? { query.value?.page }
    /// The relay is building a newer page (or this phone asked for one).
    var refreshing: Bool { asking || (query.value?.refreshing ?? false) }

    func appear() {
        query.onValue = { [weak self] _ in self?.askIfStale() }
        query.start()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: O11yRefreshPolicy.checkEvery)
                self?.askIfStale()
            }
        }
        askIfStale()
    }

    func disappear() {
        ticker?.cancel()
        ticker = nil
        query.stop()
    }

    func select(range: String) {
        guard range != (page?.range ?? self.range) else { return }
        self.range = range
        defaults.set(range, forKey: Self.rangeKey(pageId))
        query.stop()
        query = Self.makeQuery(engine: engine, pageId: pageId, range: range, lang: lang)
        query.onValue = { [weak self] _ in self?.askIfStale() }
        query.start()
        lastAsk = nil
    }

    /// Asks for a newer page when the one held is missing or older than 90 s, at most every 15 s.
    func askIfStale() {
        guard let state = query.value, O11yRefreshPolicy.isStale(state, now: now()), !state.refreshing, !asking else { return }
        if let lastAsk, now().timeIntervalSince(lastAsk) < O11yRefreshPolicy.minimumGap { return }
        Task { await ask(force: false) }
    }

    /// Pull to refresh: ends when the relay has answered.
    func pullToRefresh() async {
        await ask(force: true)
    }

    private func ask(force: Bool) async {
        guard query.value?.state == .ok || query.value == nil else { return }
        asking = true
        lastAsk = now()
        defer { asking = false }
        _ = try? await engine.backend.o11y.refresh(pageId, range: range, lang: lang, force: force)
    }
}

/// How sections sit on a wide screen: stats and charts across, the rest two by two (mobile/DESIGN.md "Layout").
enum O11yLayout {
    enum Row: Identifiable {
        case single(O11ySection)
        case pair(O11ySection, O11ySection)

        var id: Int {
            switch self {
            case .single(let s): s.index
            case .pair(let a, _): a.index
            }
        }
    }

    static let wideWidth: CGFloat = 600

    static func rows(_ sections: [O11ySection], wide: Bool) -> [Row] {
        guard wide else { return sections.map(Row.single) }
        var rows: [Row] = []
        var i = 0
        while i < sections.count {
            let section = sections[i]
            if !section.block.spansWidth, i + 1 < sections.count, !sections[i + 1].block.spansWidth {
                rows.append(.pair(section, sections[i + 1]))
                i += 2
            } else {
                rows.append(.single(section))
                i += 1
            }
        }
        return rows
    }
}

struct O11yScreen: View {
    let pageId: String
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @State private var model: O11yPageModel?

    var body: some View {
        Group {
            if let model {
                O11yScreenContent(model: model)
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(model?.page?.title ?? (pageId == "home" ? "o11y" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleView
            }
            if let link = model?.page?.url.flatMap(URL.init(string:)) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openURL(link)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel(Text("Open in Grafana"))
                    .accessibilityIdentifier("openInGrafana")
                }
            }
        }
        .onAppear {
            if model == nil { model = O11yPageModel(engine: engine, pageId: pageId) }
            model?.appear()
        }
        .onDisappear { model?.disappear() }
    }

    private var titleView: some View {
        let page = model?.page
        let title = page?.title ?? (pageId == "home" ? "o11y" : "")
        return ConnectionTitleView(
            title: title, connection: engine.connection,
            subtitle: page.map { page in AnyView(O11ySubtitle(page: page, refreshing: model?.refreshing ?? false)) })
            .accessibilityIdentifier("o11yTitle")
    }
}

/// "LLM Observability · Updated 2 min ago", with a small spinner while a newer page is on its way.
struct O11ySubtitle: View {
    let page: O11yPage
    let refreshing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Text(Self.text(page: page, now: context.date))
                    .lineLimit(1)
                if refreshing {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    static func text(page: O11yPage, now: Date) -> String {
        let updated = String(localized: "Updated \(RelativeTime.ago(Date(timeIntervalSince1970: page.builtAt / 1000), now: now))")
        guard let subtitle = page.subtitle, !subtitle.isEmpty else { return updated }
        return "\(subtitle) · \(updated)"
    }
}

struct O11yScreenContent: View {
    let model: O11yPageModel

    var body: some View {
        if let page = model.page {
            O11yPageView(page: page, model: model)
        } else if let state = model.state, state.state != .ok {
            O11yEmptyState(state: state.state)
        } else if model.state == nil, let error = model.query.error {
            if error.message.contains("Could not find") {
                O11yEmptyState(
                    title: String(localized: "o11y is not set up"), message: String(localized: "This relay doesn't serve o11y yet."))
            } else {
                O11yEmptyState(title: String(localized: "Couldn't update"), message: error.message)
            }
        } else if let error = model.state?.error, !model.refreshing {
            O11yEmptyState(title: String(localized: "Couldn't update"), message: error)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading o11y…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("o11yLoading")
        }
    }
}

struct O11yEmptyState: View {
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(state: O11yPageState.State) {
        if state == .forbidden {
            title = String(localized: "o11y is not available")
            message = String(localized: "This account can't see the relay's Grafana stack. Ask whoever runs the relay to add it.")
        } else {
            title = String(localized: "o11y is not set up")
            message = String(localized: "The relay has no Grafana token yet. Run relay/scripts/o11y-setup.sh on the relay owner's computer.")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("o11yEmptyState")
    }
}

/// The page itself: the range control, a banner when the last update failed, then the sections.
struct O11yPageView: View {
    let page: O11yPage
    let model: O11yPageModel

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= O11yLayout.wideWidth
            let chartHeight: CGFloat = proxy.size.height < 450 ? 180 : 200
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if page.ranges.count > 1 {
                        rangePicker
                    }
                    if let error = model.state?.error {
                        errorBanner(error)
                    }
                    ForEach(O11yLayout.rows(page.sections, wide: wide)) { row in
                        switch row {
                        case .single(let section):
                            O11ySectionView(section: section, wide: wide, chartHeight: chartHeight)
                        case .pair(let a, let b):
                            HStack(alignment: .top, spacing: 16) {
                                O11ySectionView(section: a, wide: wide, chartHeight: chartHeight)
                                O11ySectionView(section: b, wide: wide, chartHeight: chartHeight)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .refreshable { await model.pullToRefresh() }
            .accessibilityIdentifier("o11yPage-\(page.id)")
        }
    }

    private var rangePicker: some View {
        Picker(
            "Range",
            selection: Binding(get: { page.range }, set: { model.select(range: $0) })
        ) {
            ForEach(page.ranges, id: \.self) { range in
                Text(O11yRanges.label(range)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("o11yRange")
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(O11yPalette.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't update")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("o11yErrorBanner")
    }
}

/// "1h" → "1h" / "1小时" / "1 Std.", "7d" → "7d" / "7天" / "7 T." (mobile/DESIGN.md Words).
enum O11yRanges {
    static func label(_ range: String) -> String {
        guard let unit = range.last, let n = Int(range.dropLast()) else { return range }
        switch unit {
        case "h": return String(localized: "\(n)h", comment: "o11y range: hours")
        case "d": return String(localized: "\(n)d", comment: "o11y range: days")
        default: return range
        }
    }
}
