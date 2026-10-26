package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.O11yBetter
import dev.chenli.crok.mobile.data.O11yChart
import dev.chenli.crok.mobile.data.O11yChip
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.data.O11ySection
import dev.chenli.crok.mobile.data.O11ySeries
import dev.chenli.crok.mobile.data.O11yUnit
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow

/**
 * The o11y number rules (mobile/DESIGN.md "Numbers"), the same as the iOS app's O11yFormat: the locale's decimal
 * separator, K / M / B in every language.
 */
object O11yFormat {
    private const val MINUS = "−"

    fun value(v: Double?, unit: O11yUnit, locale: Locale = Locale.getDefault()): String {
        if (v == null || !v.isFinite()) return "—"
        return when (unit) {
            O11yUnit.USD -> {
                if (v == 0.0) return "$0"
                val sign = if (v < 0) MINUS else ""
                val a = abs(v)
                when {
                    a < 0.01 -> sign + "$" + trimmed(a, 4, locale)
                    a < 1000 -> sign + "$" + fixed(a, 2, locale)
                    else -> sign + "$" + compact(a, locale)
                }
            }
            O11yUnit.COUNT, O11yUnit.TOKENS -> count(v, locale)
            O11yUnit.RATIO -> when (v) {
                0.0 -> "0%"
                1.0 -> "100%"
                else -> trimmed(v * 100, 1, locale) + "%"
            }
            O11yUnit.SECONDS -> seconds(v, locale)
            O11yUnit.MS -> seconds(v / 1000, locale)
            O11yUnit.BYTES -> bytes(v, locale)
            O11yUnit.PER_MIN -> count(v, locale) + "/min"
            O11yUnit.TPS -> count(v, locale) + " tok/s"
        }
    }

    /** "+12%", "−8%", "+0.4%"; null for no change to show. */
    fun change(c: Double?, locale: Locale = Locale.getDefault()): String? {
        if (c == null || !c.isFinite()) return null
        val pct = c * 100
        if (pct == 0.0) return "0%"
        val size = abs(pct)
        val text = if (size < 1) trimmed(size, 1, locale) else fixed(size, 0, locale)
        return (if (pct > 0) "+" else MINUS) + text + "%"
    }

    enum class Tone { GOOD, BAD, NEUTRAL }

    /** Whether a change is good news: green, red, or neither. */
    fun tone(change: Double?, better: O11yBetter?): Tone {
        if (change == null || change == 0.0 || better == null || better == O11yBetter.NONE) return Tone.NEUTRAL
        return if ((change > 0) == (better == O11yBetter.UP)) Tone.GOOD else Tone.BAD
    }

    /** A detail chip's text. */
    fun chip(chip: O11yChip, locale: Locale = Locale.getDefault()): String = when (chip) {
        is O11yChip.Text -> chip.text
        is O11yChip.Value -> chip.suffix?.let { "${value(chip.v, chip.unit, locale)} $it" } ?: value(chip.v, chip.unit, locale)
    }

    /** Chips joined by " · "; a value chip ("310 ms", "12.3K in") never breaks across lines. */
    fun chips(chips: List<O11yChip>, locale: Locale = Locale.getDefault()): String = chips.joinToString(" · ") {
        if (it is O11yChip.Value) chip(it, locale).replace(' ', ' ') else chip(it, locale)
    }

    /**
     * A chart's y-axis labels: every tick in the unit the top one needs, no trailing zeros ("$15", "$7.5"; "75 s",
     * "50 s"; "1.5K", "500").
     */
    fun axis(ticks: List<Double>, unit: O11yUnit, locale: Locale = Locale.getDefault()): List<String> {
        val top = ticks.maxOfOrNull { abs(it) } ?: 0.0
        return when (unit) {
            O11yUnit.USD -> ticks.map { v ->
                when {
                    v == 0.0 -> "$0"
                    top < 0.01 -> "$" + trimmed(v, 4, locale)
                    top < 1000 -> "$" + trimmed(v, 2, locale)
                    else -> "$" + compact(v, locale)
                }
            }
            O11yUnit.COUNT, O11yUnit.TOKENS -> ticks.map { count(it, locale) }
            O11yUnit.PER_MIN -> ticks.map { count(it, locale) + "/min" }
            O11yUnit.TPS -> ticks.map { count(it, locale) + " tok/s" }
            O11yUnit.RATIO -> ticks.map { trimmed(it * 100, 1, locale) + "%" }
            O11yUnit.SECONDS, O11yUnit.MS -> {
                val seconds = if (unit == O11yUnit.MS) ticks.map { it / 1000 } else ticks
                val most = if (unit == O11yUnit.MS) top / 1000 else top
                val (divisor, suffix) = when {
                    most < 1 -> 0.001 to " ms"
                    most < 120 -> 1.0 to " s"
                    most < 7200 -> 60.0 to " min"
                    else -> 3600.0 to " h"
                }
                seconds.map { trimmed(it / divisor, 1, locale) + suffix }
            }
            O11yUnit.BYTES -> {
                val (divisor, suffix) = when {
                    top < 1024 -> 1.0 to " B"
                    top < 1_048_576 -> 1024.0 to " KB"
                    top < 1_073_741_824 -> 1_048_576.0 to " MB"
                    else -> 1_073_741_824.0 to " GB"
                }
                ticks.map { trimmed(it / divisor, 1, locale) + suffix }
            }
        }
    }

    // ---- Pieces ----

    fun count(v: Double, locale: Locale): String {
        val sign = if (v < 0) MINUS else ""
        val a = abs(v)
        if (a < 1000) {
            if (abs(a - roundHalfUp(a)) < 1e-9) return sign + fixed(a, 0, locale)
            val text = trimmed(a, 1, locale)
            return sign + if (text == fixed(1000.0, 0, locale)) "1K" else text
        }
        return sign + compact(a, locale)
    }

    /** 1.2K, 340K, 1.2M, 3.4B: one decimal under 100 of the unit, none above. */
    fun compact(a: Double, locale: Locale): String {
        val units = listOf(1e9 to "B", 1e6 to "M", 1e3 to "K")
        var index = units.indexOfFirst { a >= it.first }.takeIf { it >= 0 } ?: (units.size - 1)
        while (true) {
            val (size, suffix) = units[index]
            val mantissa = a / size
            val decimals = if (mantissa < 99.95) 1 else 0
            val factor = 10.0.pow(decimals)
            val rounded = roundHalfUp(mantissa * factor) / factor
            if (rounded >= 1000 && index > 0) {
                index -= 1
                continue
            }
            return trimmed(rounded, decimals, locale) + suffix
        }
    }

    fun seconds(s: Double, locale: Locale): String {
        val a = abs(s)
        return when {
            a < 1 -> fixed(a * 1000, 0, locale) + " ms"
            a < 60 -> fixed(a, 1, locale) + " s"
            a < 3600 -> fixed(a / 60, 1, locale) + " min"
            else -> fixed(a / 3600, 1, locale) + " h"
        }
    }

    fun bytes(b: Double, locale: Locale): String {
        val a = abs(b)
        return when {
            a < 1024 -> fixed(a, 0, locale) + " B"
            a < 1024 * 1024 -> fixed(a / 1024, 1, locale) + " KB"
            a < 1024.0 * 1024 * 1024 -> fixed(a / 1024 / 1024, 1, locale) + " MB"
            else -> fixed(a / 1024 / 1024 / 1024, 1, locale) + " GB"
        }
    }

    /** Swift's `rounded()` for the positive numbers it is used on: halves away from zero. */
    private fun roundHalfUp(x: Double): Double = floor(x + 0.5)

    /** Exactly [decimals] decimals, no grouping. */
    fun fixed(v: Double, decimals: Int, locale: Locale): String = format(v, decimals, decimals, locale)

    /** Up to [decimals] decimals, trailing zeros dropped. */
    fun trimmed(v: Double, decimals: Int, locale: Locale): String = format(v, 0, decimals, locale)

    private fun format(v: Double, min: Int, max: Int, locale: Locale): String {
        val format = NumberFormat.getNumberInstance(locale)
        format.isGroupingUsed = false
        format.minimumFractionDigits = min
        format.maximumFractionDigits = max
        return format.format(v)
    }
}

/** mobile/DESIGN.md "Loading and refresh": a page older than 90 s is stale; a visible screen checks every 60 s. */
object O11yRefreshPolicy {
    const val STALE_AFTER_MS = 90_000L
    const val CHECK_EVERY_MS = 60_000L

    /** The phone does not ask again sooner than this after its own last ask (the relay dedupes too). */
    const val MINIMUM_GAP_MS = 15_000L

    fun isStale(state: O11yPageState?, nowMs: Long): Boolean {
        if (state == null || state.state != O11yPageState.State.OK) return false
        val builtAt = state.builtAt ?: state.page?.builtAt ?: return true
        return nowMs - builtAt > STALE_AFTER_MS
    }
}

/** The relay's language codes, from the app's own UI language. */
object O11yLanguage {
    fun code(localization: String?): String {
        val id = (localization ?: "en").lowercase(Locale.ROOT)
        return listOf("zh", "ja", "es", "fr", "de").firstOrNull { id.startsWith(it) } ?: "en"
    }
}

/** How sections sit on a wide screen: stats and charts across, the rest two by two (mobile/DESIGN.md "Layout"). */
object O11yLayout {
    sealed interface Row {
        val id: Int

        data class Single(val section: O11ySection) : Row {
            override val id get() = section.index
        }

        data class Pair(val first: O11ySection, val second: O11ySection) : Row {
            override val id get() = first.index
        }
    }

    const val WIDE_DP = 600

    fun rows(sections: List<O11ySection>, wide: Boolean): List<Row> {
        if (!wide) return sections.map { Row.Single(it) }
        val rows = ArrayList<Row>()
        var i = 0
        while (i < sections.size) {
            val section = sections[i]
            val next = sections.getOrNull(i + 1)
            if (!section.block.spansWidth && next != null && !next.block.spansWidth) {
                rows += Row.Pair(section, next)
                i += 2
            } else {
                rows += Row.Single(section)
                i += 1
            }
        }
        return rows
    }
}

/** What a chart draws: its points on one time axis, the y scale from 0 to round values (O11yChartGeometry on iOS). */
class O11yChartGeometry(val chart: O11yChart, val hidden: Set<String>) {
    /** Every time any series has, in order: the x axis. */
    val times: List<Double> = chart.series.flatMap { s -> s.points.map { it.time } }.distinct().sorted()

    val visible: List<O11ySeries> = chart.series.filter { it.name !in hidden }

    val isEmpty: Boolean = chart.series.none { s -> s.points.any { it.value != null } }

    /** The largest value drawn: a stack's total for stacked bars. */
    fun maxValue(times: List<Double> = this.times): Double {
        var top = visible.flatMap { s -> s.points.mapNotNull { it.value } }.maxOrNull() ?: 0.0
        if (chart.style == O11yChart.Style.BARS && chart.stacked) {
            val solid = visible.filter { !it.dashed }
            for (t in times) top = max(top, solid.sumOf { max(0.0, it.valueAt(t) ?: 0.0) })
        }
        return top
    }

    companion object {
        /** Three steps of a round size (1, 2, 2.5, 5 × 10ⁿ) from 0, the top one at or above [max]. */
        fun ticks(max: Double): List<Double> {
            if (max <= 0 || !max.isFinite()) return (0..3).map { it / 3.0 }
            val raw = max / 3
            val magnitude = 10.0.pow(floor(log10(raw)))
            val step = listOf(1.0, 2.0, 2.5, 5.0, 10.0).map { it * magnitude }.firstOrNull { it >= raw } ?: raw
            return (0..3).map { it * step }
        }
    }
}
