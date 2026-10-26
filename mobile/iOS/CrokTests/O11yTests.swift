import XCTest

@testable import Crok

/// The o11y tab's pages (mobile/DESIGN.md "o11y"): what the relay sends decodes, numbers read the same in both apps,
/// wide screens pair sections, and the demo serves the fixture in every language.
final class O11yTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    // MARK: Decoding

    func testDecodesAPageOfEveryBlockKind() throws {
        let json = #"""
            {"state":"ok","builtAt":1793000000000.0,"refreshing":false,"error":null,"page":{
              "id":"overview","title":"LLM Overview","subtitle":"LLM Observability","range":"24h","ranges":["1h","6h","24h"],
              "url":"https://x.grafana.net/d/llm-overview","builtAt":1793000000000.0,"sections":[
                {"title":"At a glance","block":{"kind":"stats","items":[
                  {"label":"Spend","value":2.75,"unit":"usd"},{"label":"p95","value":null,"unit":"seconds","change":0.12,"better":"down"}]}},
                {"title":"Calls","block":{"kind":"chart","style":"bars","stacked":true,"unit":"count","step":60000.0,
                  "series":[{"name":"claude","slot":1.0,"total":12.0,"points":[[1792999940000.0,3.0],[1793000000000.0,null]]},
                            {"name":"7 days earlier","slot":0.0,"total":null,"dashed":true,"points":[]}],"more":2.0}},
                {"block":{"kind":"ranking","unit":"usd","rows":[{"label":"opus","value":0.65,"detail":[{"t":"anthropic"},{"v":12.0,"u":"tokens","s":"in"}],"change":-0.2,"better":"down"}],"empty":"Nothing"}},
                {"block":{"kind":"list","rows":[{"title":"deepseek-flash","detail":[{"t":"deepseek"}],"value":{"v":0.01,"u":"usd"},"time":1793000000000.0,"status":"bad","page":"explorer"}],"empty":"No calls"}},
                {"block":{"kind":"links","rows":[{"page":"claude","title":"Claude Platform","subtitle":"Calls","icon":"claude","color":"#F09A37","value":{"v":3.0,"u":"count"}}]}},
                {"block":{"kind":"note","text":"Hello"}},
                {"block":{"kind":"error","message":"timeout"}},
                {"block":{"kind":"sparkline3d"}}
              ]}}
            """#
        let state = try JSONDecoder().decode(O11yPageState.self, from: Data(json.utf8))
        XCTAssertEqual(state.state, .ok)
        let page = try XCTUnwrap(state.page)
        XCTAssertEqual(page.sections.map(\.index), Array(0..<8), "sections keep their place as their identity")
        guard case .stats(let stats) = page.sections[0].block else { return XCTFail("stats") }
        XCTAssertNil(stats[1].value)
        XCTAssertEqual(stats[1].better, .down)
        guard case .chart(let chart) = page.sections[1].block else { return XCTFail("chart") }
        XCTAssertEqual(chart.style, .bars)
        XCTAssertTrue(chart.stacked)
        XCTAssertEqual(chart.more, 2)
        XCTAssertEqual(chart.series[0].slot, 1, "Convex sends numbers as floats")
        XCTAssertNil(chart.series[0].points[1].value)
        XCTAssertEqual(chart.series[1].dashed, true)
        guard case .ranking(let ranking) = page.sections[2].block else { return XCTFail("ranking") }
        XCTAssertEqual(ranking.rows[0].detail, [.text("anthropic"), .value(12, .tokens, suffix: "in")])
        guard case .list(let rows, _) = page.sections[3].block else { return XCTFail("list") }
        XCTAssertEqual(rows[0].status, .bad)
        XCTAssertEqual(rows[0].page, "explorer")
        XCTAssertEqual(page.sections[7].block, .unknown, "a newer relay's block kind is skipped, not an error")
    }

    func testDecodesTheStatesWithoutAPage() throws {
        let forbidden = try JSONDecoder().decode(O11yPageState.self, from: Data(#"{"state":"forbidden"}"#.utf8))
        XCTAssertEqual(forbidden.state, .forbidden)
        XCTAssertNil(forbidden.page)
        let unconfigured = try JSONDecoder().decode(O11yPageState.self, from: Data(#"{"state":"unconfigured"}"#.utf8))
        XCTAssertEqual(unconfigured.state, .unconfigured)
    }

    func testTheBundledDemoFixtureDecodesEveryPage() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "o11y-demo", withExtension: "json"))
        let fixture = try JSONDecoder().decode(DemoO11y.Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(
            Set(fixture.pages.keys),
            ["home", "overview", "claude", "openrouter", "crok", "harness", "history", "explorer", "evaluators", "guards",
             "experiments", "agents", "conversations", "slos", "alerts"])
        for (id, page) in fixture.pages {
            XCTAssertFalse(page.sections.isEmpty, id)
            XCTAssertFalse(page.sections.contains { $0.block == .unknown }, id)
        }
        XCTAssertNotNil(fixture.strings["Spend by model"]?["zh"])
    }

    // MARK: Numbers (mobile/DESIGN.md "Numbers")

    func testDollars() {
        XCTAssertEqual(O11yFormat.value(0, .usd, locale: en), "$0")
        XCTAssertEqual(O11yFormat.value(0.0042, .usd, locale: en), "$0.0042")
        XCTAssertEqual(O11yFormat.value(0.00419, .usd, locale: en), "$0.0042")
        XCTAssertEqual(O11yFormat.value(0.005, .usd, locale: en), "$0.005")
        XCTAssertEqual(O11yFormat.value(1.789, .usd, locale: en), "$1.79")
        XCTAssertEqual(O11yFormat.value(999.99, .usd, locale: en), "$999.99")
        XCTAssertEqual(O11yFormat.value(1234, .usd, locale: en), "$1.2K")
        XCTAssertEqual(O11yFormat.value(1.789, .usd, locale: de), "$1,79", "the locale's decimal separator")
    }

    func testCountsAndTokens() {
        XCTAssertEqual(O11yFormat.value(7, .count, locale: en), "7")
        XCTAssertEqual(O11yFormat.value(3.44, .count, locale: en), "3.4")
        XCTAssertEqual(O11yFormat.value(999, .count, locale: en), "999")
        XCTAssertEqual(O11yFormat.value(1200, .count, locale: en), "1.2K")
        XCTAssertEqual(O11yFormat.value(2000, .count, locale: en), "2K")
        XCTAssertEqual(O11yFormat.value(99_960, .count, locale: en), "100K")
        XCTAssertEqual(O11yFormat.value(340_000, .tokens, locale: en), "340K")
        XCTAssertEqual(O11yFormat.value(999_700, .tokens, locale: en), "1M", "rounding up moves to the next unit")
        XCTAssertEqual(O11yFormat.value(58_590_000, .tokens, locale: en), "58.6M")
        XCTAssertEqual(O11yFormat.value(1_200_000_000, .tokens, locale: en), "1.2B")
        XCTAssertEqual(O11yFormat.value(12_300, .count, locale: de), "12,3K")
        XCTAssertEqual(O11yFormat.value(12.3, .perMin, locale: en), "12.3/min")
        XCTAssertEqual(O11yFormat.value(45, .tps, locale: en), "45 tok/s")
    }

    func testRatiosTimesAndBytes() {
        XCTAssertEqual(O11yFormat.value(0, .ratio, locale: en), "0%")
        XCTAssertEqual(O11yFormat.value(1, .ratio, locale: en), "100%")
        XCTAssertEqual(O11yFormat.value(0.029, .ratio, locale: en), "2.9%")
        XCTAssertEqual(O11yFormat.value(0.96, .ratio, locale: en), "96%")
        XCTAssertEqual(O11yFormat.value(0.9944, .ratio, locale: en), "99.4%")
        XCTAssertEqual(O11yFormat.value(0.34, .seconds, locale: en), "340 ms")
        XCTAssertEqual(O11yFormat.value(4.33, .seconds, locale: en), "4.3 s")
        XCTAssertEqual(O11yFormat.value(126, .seconds, locale: en), "2.1 min")
        XCTAssertEqual(O11yFormat.value(5400, .seconds, locale: en), "1.5 h")
        XCTAssertEqual(O11yFormat.value(250, .ms, locale: en), "250 ms")
        XCTAssertEqual(O11yFormat.value(4300, .bytes, locale: en), "4.2 KB")
        XCTAssertEqual(O11yFormat.value(nil, .usd, locale: en), "—")
    }

    func testChangesAndTheirColours() {
        XCTAssertEqual(O11yFormat.change(0.12, locale: en), "+12%")
        XCTAssertEqual(O11yFormat.change(-0.08, locale: en), "\u{2212}8%")
        XCTAssertEqual(O11yFormat.change(0.004, locale: en), "+0.4%")
        XCTAssertEqual(O11yFormat.change(6.21, locale: en), "+621%")
        XCTAssertNil(O11yFormat.change(nil, locale: en))
        XCTAssertEqual(O11yFormat.tone(0.1, better: .down), .bad, "spend going up is bad news")
        XCTAssertEqual(O11yFormat.tone(-0.1, better: .down), .good)
        XCTAssertEqual(O11yFormat.tone(0.1, better: .up), .good)
        XCTAssertEqual(O11yFormat.tone(0.1, better: O11yBetter.none), .neutral)
        XCTAssertEqual(O11yFormat.chip(.value(12_345, .tokens, suffix: "in"), locale: en), "12.3K in")
        XCTAssertEqual(
            O11yFormat.chipLine([.text("OpenRouter"), .value(12_345, .tokens, suffix: "in"), .value(4.3, .seconds, suffix: nil)], locale: en),
            "OpenRouter · 12.3K\u{00A0}in · 4.3\u{00A0}s", "a value chip never splits across lines")
    }

    func testAxisLabelsShareTheTopTicksUnit() {
        XCTAssertEqual(O11yFormat.axis([0, 5, 10, 15], .usd, locale: en), ["$0", "$5", "$10", "$15"])
        XCTAssertEqual(O11yFormat.axis([0, 2.5, 5, 7.5], .usd, locale: en), ["$0", "$2.5", "$5", "$7.5"])
        XCTAssertEqual(O11yFormat.axis([0, 25, 50, 75], .seconds, locale: en), ["0 s", "25 s", "50 s", "75 s"])
        XCTAssertEqual(O11yFormat.axis([0, 0.2, 0.4, 0.6], .seconds, locale: en), ["0 ms", "200 ms", "400 ms", "600 ms"])
        XCTAssertEqual(O11yFormat.axis([0, 500, 1000, 1500], .count, locale: en), ["0", "500", "1K", "1.5K"])
        XCTAssertEqual(O11yFormat.axis([0, 0.25, 0.5, 0.75], .ratio, locale: en), ["0%", "25%", "50%", "75%"])
        XCTAssertEqual(O11yFormat.axis([0, 20, 40, 60], .perMin, locale: en), ["0/min", "20/min", "40/min", "60/min"])
    }

    func testChartTicksAreRoundFromZero() {
        XCTAssertEqual(O11yChartGeometry.ticks(max: 2.75), [0, 1, 2, 3])
        XCTAssertEqual(O11yChartGeometry.ticks(max: 44.37), [0, 20, 40, 60])
        XCTAssertEqual(O11yChartGeometry.ticks(max: 0.98), [0, 0.5, 1, 1.5])
        XCTAssertEqual(O11yChartGeometry.ticks(max: 1435000), [0, 500_000, 1_000_000, 1_500_000])
        XCTAssertEqual(O11yChartGeometry.ticks(max: 0).count, 4)
    }

    func testStackedBarsScaleToTheTallestStack() {
        let chart = O11yBlock.O11yChart(
            style: .bars, stacked: true, unit: .usd, step: 86_400_000,
            series: [
                O11ySeries(name: "a", slot: 1, total: 5, points: [O11yPoint(time: 1, value: 3), O11yPoint(time: 2, value: 2)]),
                O11ySeries(name: "b", slot: 2, total: 5, points: [O11yPoint(time: 1, value: 4), O11yPoint(time: 2, value: 1)]),
            ], more: 0)
        let geometry = O11yChartGeometry(chart: chart, hidden: [])
        XCTAssertEqual(geometry.maxValue(times: geometry.times), 7)
        XCTAssertEqual(O11yChartGeometry(chart: chart, hidden: ["b"]).maxValue(times: [1, 2]), 3, "a hidden series leaves the scale")
    }

    // MARK: Layout and refresh

    func testWideScreensPairTheHalfSections() {
        let stats = O11ySection(title: "s", footer: nil, block: .stats([]), index: 0)
        let chart = O11ySection(title: "c", footer: nil, block: .note("x"), index: 1)
        let rankA = O11ySection(title: "a", footer: nil, block: .links([]), index: 2)
        let rankB = O11ySection(title: "b", footer: nil, block: .list(rows: [], empty: ""), index: 3)
        let lone = O11ySection(title: "d", footer: nil, block: .note("y"), index: 4)
        let bigChart = O11ySection(
            title: "e", footer: nil,
            block: .chart(.init(style: .line, stacked: false, unit: .count, step: 60_000, series: [], more: 0)), index: 5)
        let sections = [stats, chart, rankA, rankB, lone, bigChart]
        XCTAssertEqual(O11yLayout.rows(sections, wide: false).count, 6, "upright: one column")
        let wide = O11yLayout.rows(sections, wide: true)
        XCTAssertEqual(wide.map(\.id), [0, 1, 3, 5])
        guard case .pair(let first, let second) = wide[1] else { return XCTFail("note and links pair") }
        XCTAssertEqual([first.index, second.index], [1, 2])
        guard case .pair(let third, let fourth) = wide[2] else { return XCTFail("list and note pair") }
        XCTAssertEqual([third.index, fourth.index], [3, 4])
        guard case .single = wide[3] else { return XCTFail("a chart spans the width") }
    }

    func testAPageIsStaleWhenMissingOrOlderThan90Seconds() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(O11yRefreshPolicy.isStale(O11yPageState(state: .ok), now: now), "no page yet")
        XCTAssertFalse(
            O11yRefreshPolicy.isStale(O11yPageState(state: .ok, builtAt: (now.timeIntervalSince1970 - 60) * 1000), now: now))
        XCTAssertTrue(
            O11yRefreshPolicy.isStale(O11yPageState(state: .ok, builtAt: (now.timeIntervalSince1970 - 120) * 1000), now: now))
        XCTAssertFalse(O11yRefreshPolicy.isStale(O11yPageState(state: .forbidden), now: now), "nothing to ask for")
        XCTAssertFalse(O11yRefreshPolicy.isStale(nil, now: now))
    }

    func testTheRelayLanguageFollowsTheAppsOwn() {
        XCTAssertEqual(O11yLanguage.code(for: "zh-Hans"), "zh")
        XCTAssertEqual(O11yLanguage.code(for: "ja"), "ja")
        XCTAssertEqual(O11yLanguage.code(for: "de"), "de")
        XCTAssertEqual(O11yLanguage.code(for: "en"), "en")
        XCTAssertEqual(O11yLanguage.code(for: "pt-BR"), "en")
        XCTAssertEqual(O11yLanguage.code(for: nil), "en")
    }

    func testRangeLabels() {
        XCTAssertEqual(O11yRanges.label("24h"), "24h")
        XCTAssertEqual(O11yRanges.label("7d"), "7d")
        XCTAssertEqual(O11yRanges.label("odd"), "odd")
    }

    // MARK: Demo

    func testTheDemoTranslatesItsPagesAndMovesThemToNow() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let demo = DemoO11y(now: { now })
        let english = demo.state("overview", range: "6h", lang: "en")
        let page = try XCTUnwrap(english.page)
        XCTAssertEqual(page.title, "LLM Overview")
        XCTAssertEqual(page.range, "6h", "a range the page offers is kept")
        XCTAssertEqual(page.builtAt, (now.timeIntervalSince1970 - 30) * 1000)
        let latest = page.sections.compactMap { section -> Double? in
            if case .chart(let chart) = section.block { return chart.series.flatMap(\.points).map(\.time).max() }
            return nil
        }.max() ?? 0
        XCTAssertLessThan(abs(latest - page.builtAt), 30 * 86_400_000, "the fixture's times are moved to now")
        let chinese = try XCTUnwrap(demo.state("overview", range: nil, lang: "zh").page)
        XCTAssertEqual(chinese.title, "LLM 概览")
        XCTAssertEqual(demo.translate("input · claude", lang: "zh"), "输入 · claude", "each known part of a name")
        let result = try await demo.refresh("overview", range: nil, lang: "zh", force: true)
        XCTAssertEqual(result.status, "built")
        XCTAssertEqual(demo.state("overview", range: nil, lang: "zh").builtAt, now.timeIntervalSince1970 * 1000)
    }
}
