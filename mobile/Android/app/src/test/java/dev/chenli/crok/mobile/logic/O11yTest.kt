package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.O11yBetter
import dev.chenli.crok.mobile.data.O11yBlock
import dev.chenli.crok.mobile.data.O11yChart
import dev.chenli.crok.mobile.data.O11yChip
import dev.chenli.crok.mobile.data.O11yDecode
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.data.O11yPoint
import dev.chenli.crok.mobile.data.O11ySection
import dev.chenli.crok.mobile.data.O11ySeries
import dev.chenli.crok.mobile.data.O11yStatus
import dev.chenli.crok.mobile.data.O11yUnit
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.demo.DemoO11y
import java.io.File
import java.util.Locale
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The o11y tab's pages (mobile/DESIGN.md "o11y"): what the relay sends decodes, numbers read the same as in the iOS app
 * (CrokTests/O11yTests.swift, the same expected strings), wide screens pair sections, and the demo serves the fixture.
 */
class O11yTest {
    private val en = Locale.US
    private val de = Locale.GERMANY

    /** The fixture both apps bundle (relay/scripts/o11y-demo.mjs). */
    private val fixture: String by lazy { File("src/debug/assets/o11y-demo.json").readText() }

    // ---- Decoding ----

    @Test
    fun decodesAPageOfEveryBlockKind() {
        val json = """
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
        """.trimIndent()
        val state = O11yDecode.state(RelayJson.parseToJsonElement(json))
        assertEquals(O11yPageState.State.OK, state.state)
        val page = state.page!!
        assertEquals("sections keep their place as their identity", (0 until 8).toList(), page.sections.map { it.index })
        val stats = page.sections[0].block as O11yBlock.Stats
        assertNull(stats.items[1].value)
        assertEquals(O11yBetter.DOWN, stats.items[1].better)
        val chart = (page.sections[1].block as O11yBlock.Chart).chart
        assertEquals(O11yChart.Style.BARS, chart.style)
        assertTrue(chart.stacked)
        assertEquals(2, chart.more)
        assertEquals("Convex sends numbers as floats", 1, chart.series[0].slot)
        assertNull(chart.series[0].points[1].value)
        assertTrue(chart.series[1].dashed)
        val ranking = (page.sections[2].block as O11yBlock.Ranking).ranking
        assertEquals(listOf(O11yChip.Text("anthropic"), O11yChip.Value(12.0, O11yUnit.TOKENS, "in")), ranking.rows[0].detail)
        val rows = (page.sections[3].block as O11yBlock.Rows).rows
        assertEquals(O11yStatus.BAD, rows[0].status)
        assertEquals("explorer", rows[0].page)
        assertEquals("a newer relay's block kind is skipped, not an error", O11yBlock.Unknown, page.sections[7].block)
    }

    @Test
    fun decodesTheStatesWithoutAPage() {
        val forbidden = O11yDecode.state(RelayJson.parseToJsonElement("""{"state":"forbidden"}"""))
        assertEquals(O11yPageState.State.FORBIDDEN, forbidden.state)
        assertNull(forbidden.page)
        val unconfigured = O11yDecode.state(RelayJson.parseToJsonElement("""{"state":"unconfigured"}"""))
        assertEquals(O11yPageState.State.UNCONFIGURED, unconfigured.state)
    }

    @Test
    fun theBundledDemoFixtureDecodesEveryPage() {
        val pages = RelayJson.parseToJsonElement(fixture).jsonObject["pages"]!!.jsonObject
        assertEquals(
            setOf(
                "home", "overview", "claude", "openrouter", "crok", "harness", "history", "explorer", "evaluators", "guards",
                "experiments", "agents", "conversations", "slos", "alerts",
            ),
            pages.keys,
        )
        for ((id, element) in pages) {
            val page = O11yDecode.page(element)!!
            assertFalse(id, page.sections.isEmpty())
            assertFalse(id, page.sections.any { it.block == O11yBlock.Unknown })
        }
    }

    // ---- Numbers (mobile/DESIGN.md "Numbers") ----

    private fun v(value: Double?, unit: O11yUnit, locale: Locale = en) = O11yFormat.value(value, unit, locale)

    @Test
    fun dollars() {
        assertEquals("$0", v(0.0, O11yUnit.USD))
        assertEquals("$0.0042", v(0.0042, O11yUnit.USD))
        assertEquals("$0.0042", v(0.00419, O11yUnit.USD))
        assertEquals("$0.005", v(0.005, O11yUnit.USD))
        assertEquals("$1.79", v(1.789, O11yUnit.USD))
        assertEquals("$999.99", v(999.99, O11yUnit.USD))
        assertEquals("$1.2K", v(1234.0, O11yUnit.USD))
        assertEquals("the locale's decimal separator", "$1,79", v(1.789, O11yUnit.USD, de))
    }

    @Test
    fun countsAndTokens() {
        assertEquals("7", v(7.0, O11yUnit.COUNT))
        assertEquals("3.4", v(3.44, O11yUnit.COUNT))
        assertEquals("999", v(999.0, O11yUnit.COUNT))
        assertEquals("1.2K", v(1200.0, O11yUnit.COUNT))
        assertEquals("2K", v(2000.0, O11yUnit.COUNT))
        assertEquals("100K", v(99_960.0, O11yUnit.COUNT))
        assertEquals("340K", v(340_000.0, O11yUnit.TOKENS))
        assertEquals("rounding up moves to the next unit", "1M", v(999_700.0, O11yUnit.TOKENS))
        assertEquals("58.6M", v(58_590_000.0, O11yUnit.TOKENS))
        assertEquals("1.2B", v(1_200_000_000.0, O11yUnit.TOKENS))
        assertEquals("12,3K", v(12_300.0, O11yUnit.COUNT, de))
        assertEquals("12.3/min", v(12.3, O11yUnit.PER_MIN))
        assertEquals("45 tok/s", v(45.0, O11yUnit.TPS))
    }

    @Test
    fun ratiosTimesAndBytes() {
        assertEquals("0%", v(0.0, O11yUnit.RATIO))
        assertEquals("100%", v(1.0, O11yUnit.RATIO))
        assertEquals("2.9%", v(0.029, O11yUnit.RATIO))
        assertEquals("96%", v(0.96, O11yUnit.RATIO))
        assertEquals("99.4%", v(0.9944, O11yUnit.RATIO))
        assertEquals("340 ms", v(0.34, O11yUnit.SECONDS))
        assertEquals("4.3 s", v(4.33, O11yUnit.SECONDS))
        assertEquals("2.1 min", v(126.0, O11yUnit.SECONDS))
        assertEquals("1.5 h", v(5400.0, O11yUnit.SECONDS))
        assertEquals("250 ms", v(250.0, O11yUnit.MS))
        assertEquals("4.2 KB", v(4300.0, O11yUnit.BYTES))
        assertEquals("—", v(null, O11yUnit.USD))
    }

    @Test
    fun changesAndTheirColours() {
        assertEquals("+12%", O11yFormat.change(0.12, en))
        assertEquals("−8%", O11yFormat.change(-0.08, en))
        assertEquals("+0.4%", O11yFormat.change(0.004, en))
        assertEquals("+621%", O11yFormat.change(6.21, en))
        assertNull(O11yFormat.change(null, en))
        assertEquals("spend going up is bad news", O11yFormat.Tone.BAD, O11yFormat.tone(0.1, O11yBetter.DOWN))
        assertEquals(O11yFormat.Tone.GOOD, O11yFormat.tone(-0.1, O11yBetter.DOWN))
        assertEquals(O11yFormat.Tone.GOOD, O11yFormat.tone(0.1, O11yBetter.UP))
        assertEquals(O11yFormat.Tone.NEUTRAL, O11yFormat.tone(0.1, O11yBetter.NONE))
        assertEquals("12.3K in", O11yFormat.chip(O11yChip.Value(12_345.0, O11yUnit.TOKENS, "in"), en))
    }

    @Test
    fun axisLabelsShareTheTopTicksUnit() {
        assertEquals(listOf("$0", "$5", "$10", "$15"), O11yFormat.axis(listOf(0.0, 5.0, 10.0, 15.0), O11yUnit.USD, en))
        assertEquals(listOf("$0", "$2.5", "$5", "$7.5"), O11yFormat.axis(listOf(0.0, 2.5, 5.0, 7.5), O11yUnit.USD, en))
        assertEquals(listOf("0 s", "25 s", "50 s", "75 s"), O11yFormat.axis(listOf(0.0, 25.0, 50.0, 75.0), O11yUnit.SECONDS, en))
        assertEquals(listOf("0 ms", "200 ms", "400 ms", "600 ms"), O11yFormat.axis(listOf(0.0, 0.2, 0.4, 0.6), O11yUnit.SECONDS, en))
        assertEquals(listOf("0", "500", "1K", "1.5K"), O11yFormat.axis(listOf(0.0, 500.0, 1000.0, 1500.0), O11yUnit.COUNT, en))
        assertEquals(listOf("0%", "25%", "50%", "75%"), O11yFormat.axis(listOf(0.0, 0.25, 0.5, 0.75), O11yUnit.RATIO, en))
        assertEquals(listOf("0/min", "20/min", "40/min", "60/min"), O11yFormat.axis(listOf(0.0, 20.0, 40.0, 60.0), O11yUnit.PER_MIN, en))
    }

    @Test
    fun chartTicksAreRoundFromZero() {
        assertEquals(listOf(0.0, 1.0, 2.0, 3.0), O11yChartGeometry.ticks(2.75))
        assertEquals(listOf(0.0, 20.0, 40.0, 60.0), O11yChartGeometry.ticks(44.37))
        assertEquals(listOf(0.0, 0.5, 1.0, 1.5), O11yChartGeometry.ticks(0.98))
        assertEquals(listOf(0.0, 500_000.0, 1_000_000.0, 1_500_000.0), O11yChartGeometry.ticks(1_435_000.0))
        assertEquals(4, O11yChartGeometry.ticks(0.0).size)
    }

    @Test
    fun stackedBarsScaleToTheTallestStack() {
        val chart = O11yChart(
            O11yChart.Style.BARS, stacked = true, unit = O11yUnit.USD, step = 86_400_000.0,
            series = listOf(
                O11ySeries("a", 1, 5.0, false, listOf(O11yPoint(1.0, 3.0), O11yPoint(2.0, 2.0))),
                O11ySeries("b", 2, 5.0, false, listOf(O11yPoint(1.0, 4.0), O11yPoint(2.0, 1.0))),
            ),
            more = 0,
        )
        assertEquals(7.0, O11yChartGeometry(chart, emptySet()).maxValue(), 0.0)
        assertEquals("a hidden series leaves the scale", 3.0, O11yChartGeometry(chart, setOf("b")).maxValue(), 0.0)
    }

    // ---- Layout and refresh ----

    @Test
    fun wideScreensPairTheHalfSections() {
        val stats = O11ySection("s", null, O11yBlock.Stats(emptyList()), 0)
        val note = O11ySection("c", null, O11yBlock.Note("x"), 1)
        val links = O11ySection("a", null, O11yBlock.Links(emptyList()), 2)
        val list = O11ySection("b", null, O11yBlock.Rows(emptyList(), ""), 3)
        val lone = O11ySection("d", null, O11yBlock.Note("y"), 4)
        val chart = O11ySection("e", null, O11yBlock.Chart(O11yChart(O11yChart.Style.LINE, false, O11yUnit.COUNT, 60_000.0, emptyList(), 0)), 5)
        val sections = listOf(stats, note, links, list, lone, chart)
        assertEquals("upright: one column", 6, O11yLayout.rows(sections, wide = false).size)
        val wide = O11yLayout.rows(sections, wide = true)
        assertEquals(listOf(0, 1, 3, 5), wide.map { it.id })
        val first = wide[1] as O11yLayout.Row.Pair
        assertEquals(listOf(1, 2), listOf(first.first.index, first.second.index))
        val second = wide[2] as O11yLayout.Row.Pair
        assertEquals(listOf(3, 4), listOf(second.first.index, second.second.index))
        assertTrue("a chart spans the width", wide[3] is O11yLayout.Row.Single)
    }

    @Test
    fun aPageIsStaleWhenMissingOrOlderThan90Seconds() {
        val now = 1_793_000_000_000L
        assertTrue("no page yet", O11yRefreshPolicy.isStale(O11yPageState(O11yPageState.State.OK), now))
        assertFalse(O11yRefreshPolicy.isStale(O11yPageState(O11yPageState.State.OK, builtAt = (now - 60_000).toDouble()), now))
        assertTrue(O11yRefreshPolicy.isStale(O11yPageState(O11yPageState.State.OK, builtAt = (now - 120_000).toDouble()), now))
        assertFalse("nothing to ask for", O11yRefreshPolicy.isStale(O11yPageState(O11yPageState.State.FORBIDDEN), now))
        assertFalse(O11yRefreshPolicy.isStale(null, now))
    }

    @Test
    fun theRelayLanguageFollowsTheAppsOwn() {
        assertEquals("zh", O11yLanguage.code("zh-Hans"))
        assertEquals("zh", O11yLanguage.code("zh-CN"))
        assertEquals("ja", O11yLanguage.code("ja"))
        assertEquals("de", O11yLanguage.code("de-DE"))
        assertEquals("en", O11yLanguage.code("en"))
        assertEquals("en", O11yLanguage.code("pt-BR"))
        assertEquals("en", O11yLanguage.code(null))
    }

    // ---- Demo ----

    @Test
    fun theDemoTranslatesItsPagesAndMovesThemToNow() = runTest {
        var now = 1_900_000_000_000L
        val demo = DemoO11y(fixture, clock = { now }, refreshDelayMs = 0)
        val english = O11yDecode.state(demo.answer(mapOf("page" to "overview", "range" to "6h", "lang" to "en")))
        val page = english.page!!
        assertEquals("LLM Overview", page.title)
        assertEquals("a range the page offers is kept", "6h", page.range)
        assertEquals((now - 30_000).toDouble(), page.builtAt, 0.0)
        val latest = page.sections.mapNotNull { (it.block as? O11yBlock.Chart)?.chart?.series?.flatMap { s -> s.points }?.maxOfOrNull { p -> p.time } }.max()
        assertTrue("the fixture's times are moved to now", kotlin.math.abs(latest - page.builtAt) < 30 * 86_400_000.0)
        val chinese = O11yDecode.state(demo.answer(mapOf("page" to "overview", "lang" to "zh"))).page!!
        assertEquals("LLM 概览", chinese.title)
        assertEquals("each known part of a name", "输入 · claude", demo.translate("input · claude", "zh"))
        now += 5_000
        val result = O11yDecode.refresh(demo.refresh(mapOf("page" to "overview", "lang" to "zh", "force" to true)))
        assertEquals("built", result.status)
        assertEquals(now.toDouble(), O11yDecode.state(demo.answer(mapOf("page" to "overview", "lang" to "zh"))).builtAt!!, 0.0)
        val forbidden = DemoO11y(fixture, forced = O11yPageState.State.FORBIDDEN)
        assertEquals(O11yPageState.State.FORBIDDEN, O11yDecode.state(forbidden.answer(mapOf("page" to "home"))).state)
        assertNotNull(chinese.url)
    }
}
