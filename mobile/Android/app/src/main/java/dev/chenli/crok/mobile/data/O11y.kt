package dev.chenli.crok.mobile.data

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

// The o11y tab's pages (mobile/DESIGN.md "o11y", relay/DESIGN.md §3 "o11y"): the relay builds them from its owner's
// Grafana stack and sends finished blocks; the app only draws them. Text arrives in the page's language, numbers raw
// with a unit (logic/O11yFormat). Decoded by hand from the JSON, so a block kind this build does not know is skipped
// (`Unknown`) rather than failing the page.

enum class O11yUnit {
    USD, COUNT, TOKENS, RATIO, SECONDS, MS, BYTES, PER_MIN, TPS;

    companion object {
        fun of(raw: String?): O11yUnit = when (raw) {
            "usd" -> USD
            "tokens" -> TOKENS
            "ratio" -> RATIO
            "seconds" -> SECONDS
            "ms" -> MS
            "bytes" -> BYTES
            "perMin" -> PER_MIN
            "tps" -> TPS
            else -> COUNT
        }
    }
}

/** Which way a number moving is good: colours its change. */
enum class O11yBetter {
    UP, DOWN, NONE;

    companion object {
        fun of(raw: String?): O11yBetter? = when (raw) {
            "up" -> UP
            "down" -> DOWN
            "none" -> NONE
            else -> null
        }
    }
}

data class O11yValue(val v: Double, val unit: O11yUnit)

/** A detail chip: text, or a value with an optional suffix ("12.3K in"). */
sealed interface O11yChip {
    data class Text(val text: String) : O11yChip
    data class Value(val v: Double, val unit: O11yUnit, val suffix: String? = null) : O11yChip
}

data class O11yStat(
    val label: String,
    val value: Double?,
    val unit: O11yUnit,
    val change: Double? = null,
    val better: O11yBetter? = null,
)

data class O11yPoint(val time: Double, val value: Double?)

data class O11ySeries(
    val name: String,
    /** 1–8: the categorical palette; 0: "Other" (and comparison lines). */
    val slot: Int,
    val total: Double?,
    val dashed: Boolean,
    val points: List<O11yPoint>,
) {
    fun valueAt(time: Double): Double? = points.firstOrNull { it.time == time }?.value
}

data class O11yChart(
    val style: Style,
    val stacked: Boolean,
    val unit: O11yUnit,
    /** The step between points, in ms. */
    val step: Double,
    val series: List<O11ySeries>,
    val more: Int,
) {
    enum class Style { LINE, BARS }
}

data class O11yRankRow(
    val label: String,
    val value: Double,
    val slot: Int? = null,
    val detail: List<O11yChip> = emptyList(),
    val change: Double? = null,
    val better: O11yBetter? = null,
)

data class O11yRanking(val unit: O11yUnit, val rows: List<O11yRankRow>, val more: Int, val empty: String)

enum class O11yStatus { OK, WARN, BAD, INFO }

data class O11yListRow(
    val title: String,
    val detail: List<O11yChip> = emptyList(),
    val value: O11yValue? = null,
    val time: Double? = null,
    val status: O11yStatus? = null,
    val page: String? = null,
)

data class O11yLinkRow(
    val page: String,
    val title: String,
    val subtitle: String?,
    val icon: String,
    val color: String,
    val value: O11yValue?,
)

sealed interface O11yBlock {
    data class Stats(val items: List<O11yStat>) : O11yBlock
    data class Chart(val chart: O11yChart) : O11yBlock
    data class Ranking(val ranking: O11yRanking) : O11yBlock
    data class Rows(val rows: List<O11yListRow>, val empty: String) : O11yBlock
    data class Links(val rows: List<O11yLinkRow>) : O11yBlock
    data class Note(val text: String) : O11yBlock
    data class Error(val message: String) : O11yBlock

    /** A kind this build does not know (a newer relay): drawn as nothing. */
    data object Unknown : O11yBlock

    /** Wide layouts give stats and charts the whole width and pair the rest (mobile/DESIGN.md "Layout"). */
    val spansWidth: Boolean get() = this is Stats || this is Chart
}

data class O11ySection(val title: String?, val footer: String?, val block: O11yBlock, val index: Int)

data class O11yPage(
    val id: String,
    val title: String,
    val subtitle: String?,
    val range: String,
    val ranges: List<String>,
    val url: String?,
    val builtAt: Double,
    val sections: List<O11ySection>,
)

/** What `o11y:page` answers: the cached page (however old) or why there is none for this account. */
data class O11yPageState(
    val state: State,
    val page: O11yPage? = null,
    val builtAt: Double? = null,
    val refreshing: Boolean = false,
    val error: String? = null,
) {
    enum class State { OK, FORBIDDEN, UNCONFIGURED }
}

data class O11yRefreshResult(val status: String, val builtAt: Double?, val error: String?)

/** The pages as the relay sends them, read from JSON. */
object O11yDecode {
    private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
    private fun JsonElement?.arr(): List<JsonElement> = (this as? JsonArray).orEmpty()
    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
    private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

    fun chips(element: JsonElement?): List<O11yChip> = element.arr().mapNotNull { raw ->
        val chip = raw.obj() ?: return@mapNotNull null
        chip.str("t")?.let { O11yChip.Text(it) }
            ?: chip.num("v")?.let { O11yChip.Value(it, O11yUnit.of(chip.str("u")), chip.str("s")) }
    }

    private fun value(element: JsonElement?): O11yValue? {
        val v = element.obj() ?: return null
        return O11yValue(v.num("v") ?: return null, O11yUnit.of(v.str("u")))
    }

    private fun point(element: JsonElement): O11yPoint? {
        val pair = element as? JsonArray ?: return null
        val time = (pair.getOrNull(0) as? JsonPrimitive)?.doubleOrNull ?: return null
        val value = (pair.getOrNull(1) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull
        return O11yPoint(time, value)
    }

    fun block(element: JsonElement?): O11yBlock {
        val b = element.obj() ?: return O11yBlock.Unknown
        return when (b.str("kind")) {
            "stats" -> O11yBlock.Stats(
                b["items"].arr().mapNotNull { it.obj() }.map { s ->
                    O11yStat(s.str("label").orEmpty(), s.num("value"), O11yUnit.of(s.str("unit")), s.num("change"), O11yBetter.of(s.str("better")))
                },
            )
            "chart" -> O11yBlock.Chart(
                O11yChart(
                    style = if (b.str("style") == "bars") O11yChart.Style.BARS else O11yChart.Style.LINE,
                    stacked = b.bool("stacked") ?: false,
                    unit = O11yUnit.of(b.str("unit")),
                    step = b.num("step") ?: 60_000.0,
                    series = b["series"].arr().mapNotNull { it.obj() }.map { s ->
                        O11ySeries(
                            name = s.str("name").orEmpty(),
                            slot = (s.num("slot") ?: 0.0).toInt(),
                            total = s.num("total"),
                            dashed = s.bool("dashed") ?: false,
                            points = s["points"].arr().mapNotNull(::point),
                        )
                    },
                    more = (b.num("more") ?: 0.0).toInt(),
                ),
            )
            "ranking" -> O11yBlock.Ranking(
                O11yRanking(
                    unit = O11yUnit.of(b.str("unit")),
                    rows = b["rows"].arr().mapNotNull { it.obj() }.map { r ->
                        O11yRankRow(
                            label = r.str("label").orEmpty(),
                            value = r.num("value") ?: 0.0,
                            slot = r.num("slot")?.toInt(),
                            detail = chips(r["detail"]),
                            change = r.num("change"),
                            better = O11yBetter.of(r.str("better")),
                        )
                    },
                    more = (b.num("more") ?: 0.0).toInt(),
                    empty = b.str("empty").orEmpty(),
                ),
            )
            "list" -> O11yBlock.Rows(
                b["rows"].arr().mapNotNull { it.obj() }.map { r ->
                    O11yListRow(
                        title = r.str("title").orEmpty(),
                        detail = chips(r["detail"]),
                        value = value(r["value"]),
                        time = r.num("time"),
                        status = when (r.str("status")) {
                            "ok" -> O11yStatus.OK
                            "warn" -> O11yStatus.WARN
                            "bad" -> O11yStatus.BAD
                            "info" -> O11yStatus.INFO
                            else -> null
                        },
                        page = r.str("page"),
                    )
                },
                b.str("empty").orEmpty(),
            )
            "links" -> O11yBlock.Links(
                b["rows"].arr().mapNotNull { it.obj() }.map { r ->
                    O11yLinkRow(
                        page = r.str("page").orEmpty(),
                        title = r.str("title").orEmpty(),
                        subtitle = r.str("subtitle"),
                        icon = r.str("icon").orEmpty(),
                        color = r.str("color").orEmpty(),
                        value = value(r["value"]),
                    )
                },
            )
            "note" -> O11yBlock.Note(b.str("text").orEmpty())
            "error" -> O11yBlock.Error(b.str("message").orEmpty())
            else -> O11yBlock.Unknown
        }
    }

    fun page(element: JsonElement?): O11yPage? {
        val p = element.obj() ?: return null
        return O11yPage(
            id = p.str("id").orEmpty(),
            title = p.str("title").orEmpty(),
            subtitle = p.str("subtitle"),
            range = p.str("range").orEmpty(),
            ranges = p["ranges"].arr().mapNotNull { (it as? JsonPrimitive)?.content },
            url = p.str("url"),
            builtAt = p.num("builtAt") ?: 0.0,
            sections = p["sections"].arr().mapNotNull { it.obj() }.mapIndexed { index, s ->
                O11ySection(s.str("title"), s.str("footer"), block(s["block"]), index)
            },
        )
    }

    fun state(element: JsonElement?): O11yPageState {
        val s = element.obj() ?: return O11yPageState(O11yPageState.State.UNCONFIGURED)
        val state = when (s.str("state")) {
            "ok" -> O11yPageState.State.OK
            "forbidden" -> O11yPageState.State.FORBIDDEN
            else -> O11yPageState.State.UNCONFIGURED
        }
        return O11yPageState(state, page(s["page"]), s.num("builtAt"), s.bool("refreshing") ?: false, s.str("error"))
    }

    fun refresh(element: JsonElement?): O11yRefreshResult {
        val r = element.obj()
        return O11yRefreshResult(r?.str("status") ?: "failed", r?.num("builtAt"), r?.str("error"))
    }

    /** For CrokEngine.live: the page state through this decoder. */
    val StateStrategy: DeserializationStrategy<O11yPageState> = object : DeserializationStrategy<O11yPageState> {
        override val descriptor = JsonElement.serializer().descriptor
        override fun deserialize(decoder: Decoder): O11yPageState = state(JsonElement.serializer().deserialize(decoder))
    }

    val RefreshStrategy: DeserializationStrategy<O11yRefreshResult> = object : DeserializationStrategy<O11yRefreshResult> {
        override val descriptor = JsonElement.serializer().descriptor
        override fun deserialize(decoder: Decoder): O11yRefreshResult = refresh(JsonElement.serializer().deserialize(decoder))
    }
}
