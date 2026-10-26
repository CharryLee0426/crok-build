package dev.chenli.crok.mobile.ui.o11y

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.O11yChart
import dev.chenli.crok.mobile.data.O11ySeries
import dev.chenli.crok.mobile.logic.O11yChartGeometry
import dev.chenli.crok.mobile.logic.O11yFormat
import dev.chenli.crok.mobile.ui.theme.CrokColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The o11y categorical palette (mobile/DESIGN.md "o11y" › chart): slots 1–8, light and dark; slot 0 is "Other". */
object O11yPalette {
    private val light = listOf(0xFF2A78D6, 0xFFEB6834, 0xFF1BAF7A, 0xFFEDA100, 0xFFE87BA4, 0xFF008300, 0xFF6250D6, 0xFFE34948)
    private val dark = listOf(0xFF3987E5, 0xFFD95926, 0xFF199E70, 0xFFC98500, 0xFFD55181, 0xFF008300, 0xFF9085E9, 0xFFE66767)

    fun color(slot: Int, colors: CrokColors): Color {
        if (slot < 1) return colors.textSecondary.copy(alpha = 0.6f)
        val list = if (colors.isDark) dark else light
        return Color(list[(slot - 1) % list.size])
    }

    val warn = Color(0xFFF09A37)

    fun tone(tone: O11yFormat.Tone, colors: CrokColors): Color = when (tone) {
        O11yFormat.Tone.GOOD -> colors.success
        O11yFormat.Tone.BAD -> colors.danger
        O11yFormat.Tone.NEUTRAL -> colors.textSecondary
    }
}

/** Chart and list times: "14:00" for steps under a day, "Oct 24" for daily ones (O11yTime on iOS). */
object O11yTimes {
    private fun pattern(skeleton: String, locale: Locale) = SimpleDateFormat(DateFormat.getBestDateTimePattern(locale, skeleton), locale)

    fun axis(ms: Double, step: Double, locale: Locale): String =
        if (step >= 86_400_000) pattern("MMMd", locale).format(Date(ms.toLong())) else pattern("HHmm", locale).format(Date(ms.toLong()))

    /** A list row's time: "14:02" today, "Oct 24" before. */
    fun row(ms: Double, now: Long, locale: Locale): String {
        val a = Calendar.getInstance().apply { timeInMillis = ms.toLong() }
        val b = Calendar.getInstance().apply { timeInMillis = now }
        val today = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
        return if (today) pattern("HHmm", locale).format(Date(ms.toLong())) else pattern("MMMd", locale).format(Date(ms.toLong()))
    }
}

/** A chart block: the plot, then the legend for two or more series (a tap hides or shows one), then "and N more". */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun O11yChartCard(chart: O11yChart, title: String, height: Dp, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    var hidden by remember(chart) { mutableStateOf(emptySet<String>()) }
    Column(modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        O11yChartPlot(chart, hidden, title, Modifier.fillMaxWidth().height(height))
        if (chart.series.size >= 2) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                chart.series.forEach { series ->
                    val isHidden = series.name in hidden
                    LegendChip(series, chart, isHidden, colors) {
                        hidden = when {
                            isHidden -> hidden - series.name
                            hidden.size < chart.series.size - 1 -> hidden + series.name
                            else -> hidden
                        }
                    }
                }
            }
        }
        if (chart.more > 0) {
            Text(pluralStringResource(R.plurals.o11y_more, chart.more, chart.more), fontSize = 13.sp, color = colors.textSecondary)
        }
    }
}

@Composable
private fun LegendChip(series: O11ySeries, chart: O11yChart, hidden: Boolean, colors: CrokColors, onClick: () -> Unit) {
    val color = O11yPalette.color(series.slot, colors)
    val locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT
    val total = series.total?.let { O11yFormat.value(it, chart.unit, locale) }
    Row(
        Modifier
            .clip(CircleShape)
            .background(colors.textPrimary.copy(alpha = if (colors.isDark) 0.10f else 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp)
            .semantics { contentDescription = listOfNotNull(series.name, total).joinToString(", ") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .then(if (hidden) Modifier.border(1.5.dp, color, CircleShape) else Modifier.background(color)),
        )
        val alpha = if (hidden) 0.5f else 1f
        Text(series.name, fontSize = 12.sp, color = colors.textPrimary.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (total != null) Text(total, fontSize = 12.sp, color = colors.textSecondary.copy(alpha = alpha), maxLines = 1)
    }
}

/** The plot, drawn on a canvas with the same marks as the iOS app's O11yChartPlot. */
@Composable
fun O11yChartPlot(chart: O11yChart, hidden: Set<String>, title: String, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val geometry = remember(chart, hidden) { O11yChartGeometry(chart, hidden) }
    if (geometry.isEmpty) {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.o11y_no_data), fontSize = 13.sp, color = colors.textSecondary)
        }
        return
    }
    val locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT
    val density = LocalDensity.current
    val measurer = rememberTextMeasurer()
    val times = geometry.times
    val ticks = remember(geometry) { O11yChartGeometry.ticks(geometry.maxValue()) }
    val labels = remember(ticks, chart.unit, locale) { O11yFormat.axis(ticks, chart.unit, locale) }
    var selected by remember(chart) { mutableStateOf<Int?>(null) }
    val summary = geometry.visible.joinToString(", ") { s ->
        "${s.name} ${O11yFormat.value(s.total ?: s.points.lastOrNull { it.value != null }?.value, chart.unit, locale)}"
    }
    BoxWithConstraints(modifier.semantics { contentDescription = "$title: $summary" }) {
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        val plot = Rect(0f, with(density) { 16.dp.toPx() }, widthPx, max(heightPx - with(density) { 18.dp.toPx() }, 1f))
        val scales = Scales(chart, times, plot, ticks.last())
        Canvas(
            Modifier
                .fillMaxSize()
                .testTag("o11y-plot")
                .pointerInput(times, widthPx) {
                    // A tap shows the nearest point's values (another tap hides them); holding 0.25 s then dragging
                    // moves along the plot and letting go hides them. A finger that moves first belongs to the page:
                    // nothing here consumes it, so the page scrolls (mobile/DESIGN.md "o11y" › chart).
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val early = withTimeoutOrNull(HOLD_MS) {
                            var outcome = MOVED
                            while (true) {
                                val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                                if (change == null) break
                                if (!change.pressed) {
                                    outcome = TAPPED
                                    break
                                }
                                if (change.isConsumed || (change.position - down.position).getDistance() > viewConfiguration.touchSlop) break
                            }
                            outcome
                        }
                        when (early) {
                            TAPPED -> {
                                val index = scales.nearest(down.position.x)
                                selected = if (selected == index) null else index
                            }
                            MOVED -> Unit
                            else -> {
                                selected = scales.nearest(down.position.x)
                                while (true) {
                                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                                    if (!change.pressed) break
                                    change.consume()
                                    selected = scales.nearest(change.position.x)
                                }
                                selected = null
                            }
                        }
                    }
                },
        ) {
            val grid = colors.textPrimary.copy(alpha = if (colors.isDark) 0.14f else 0.10f)
            val labelStyle = TextStyle(fontSize = 11.sp, color = colors.textSecondary)
            ticks.forEachIndexed { i, tick ->
                val y = scales.y(tick)
                drawLine(grid, Offset(plot.left, y), Offset(plot.right, y), strokeWidth = 1f)
                val layout = measurer.measure(labels[i], labelStyle)
                drawText(layout, topLeft = Offset(plot.left, y - 2.dp.toPx() - layout.size.height))
            }
            drawXLabels(this, measurer, labelStyle, chart, times, scales, plot, locale)
            if (chart.style == O11yChart.Style.BARS) drawBars(geometry, times, scales, plot, colors) else drawLines(geometry, scales, plot, colors)
            drawDashed(geometry, scales, colors)
            selected?.takeIf { it in times.indices }?.let { index ->
                val x = scales.x(index)
                drawLine(colors.textSecondary.copy(alpha = 0.7f), Offset(x, plot.top), Offset(x, plot.bottom), strokeWidth = 1.dp.toPx())
                if (chart.style == O11yChart.Style.LINE) {
                    geometry.visible.forEach { series ->
                        val value = series.valueAt(times[index]) ?: return@forEach
                        val center = Offset(x, scales.y(value))
                        drawCircle(colors.card, radius = 6.dp.toPx(), center = center)
                        drawCircle(if (series.dashed) colors.textSecondary else O11yPalette.color(series.slot, colors), radius = 4.dp.toPx(), center = center)
                    }
                }
            }
        }
        selected?.takeIf { it in times.indices }?.let { index ->
            Callout(chart, geometry, times[index], scales.x(index), widthPx, locale)
        }
    }
}

private const val HOLD_MS = 250L
private const val TAPPED = 1
private const val MOVED = 2

/** Bars sit in equal slots; lines are placed by time. */
private class Scales(val chart: O11yChart, val times: List<Double>, val plot: Rect, val top: Double) {
    fun x(index: Int): Float {
        if (chart.style == O11yChart.Style.BARS) {
            val slot = plot.width / max(1, times.size)
            return plot.left + slot * (index + 0.5f)
        }
        val first = times.firstOrNull() ?: return plot.center.x
        val last = times.last()
        if (last <= first) return plot.center.x
        return plot.left + plot.width * ((times[index] - first) / (last - first)).toFloat()
    }

    fun y(value: Double): Float = plot.bottom - plot.height * (max(0.0, value) / max(top, Double.MIN_VALUE)).toFloat()

    fun nearest(x: Float): Int? {
        if (times.isEmpty()) return null
        return times.indices.minByOrNull { abs(x(it) - x) }
    }
}

private fun drawXLabels(
    scope: DrawScope,
    measurer: androidx.compose.ui.text.TextMeasurer,
    style: TextStyle,
    chart: O11yChart,
    times: List<Double>,
    scales: Scales,
    plot: Rect,
    locale: Locale,
) = with(scope) {
    if (times.isEmpty()) return@with
    val count = min(times.size, if (plot.width < 360.dp.toPx()) 3 else 4)
    val used = HashSet<Int>()
    for (i in 0 until count) {
        val index = if (count == 1) 0 else (i.toDouble() * (times.size - 1) / (count - 1)).roundToInt()
        if (!used.add(index)) continue
        val layout = measurer.measure(O11yTimes.axis(times[index], chart.step, locale), style)
        val x = when (i) {
            0 -> plot.left
            count - 1 -> plot.right - layout.size.width
            else -> scales.x(index) - layout.size.width / 2f
        }
        drawText(layout, topLeft = Offset(x, plot.bottom + 4.dp.toPx()))
    }
}

private fun DrawScope.drawLines(geometry: O11yChartGeometry, scales: Scales, plot: Rect, colors: CrokColors) {
    val solid = geometry.visible.filter { !it.dashed }
    val index = scales.times.withIndex().associate { (i, t) -> t to i }
    for (series in solid) {
        val color = O11yPalette.color(series.slot, colors)
        val line = Path()
        var area = Path()
        var started = false
        var firstX = 0f
        var lastX = 0f
        fun closeArea() {
            if (!started || solid.size != 1) return
            area.lineTo(lastX, plot.bottom)
            area.lineTo(firstX, plot.bottom)
            area.close()
            drawPath(area, color.copy(alpha = 0.10f))
        }
        for (point in series.points) {
            val i = index[point.time] ?: continue
            val x = scales.x(i)
            val value = point.value
            if (value == null) {
                closeArea()
                started = false
                continue
            }
            val y = scales.y(value)
            if (started) {
                line.lineTo(x, y)
                area.lineTo(x, y)
            } else {
                line.moveTo(x, y)
                area = Path().apply { moveTo(x, y) }
                firstX = x
                started = true
            }
            lastX = x
        }
        closeArea()
        drawPath(line, color, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

private fun DrawScope.drawBars(geometry: O11yChartGeometry, times: List<Double>, scales: Scales, plot: Rect, colors: CrokColors) {
    val solid = geometry.visible.filter { !it.dashed }
    val slotWidth = plot.width / max(1, times.size)
    val width = min(24.dp.toPx(), max(1f, slotWidth - 2.dp.toPx()))
    val thin = width <= 3.dp.toPx()
    val gapPx = 2.dp.toPx()
    times.forEachIndexed { i, time ->
        val center = scales.x(i)
        if (scales.chart.stacked || solid.size == 1) {
            // From the baseline up, each segment 2 dp short of the next; only the stack's top is rounded.
            val values = solid.mapNotNull { s -> (s.valueAt(time) ?: 0.0).takeIf { it > 0 }?.let { s to it } }
            var base = 0.0
            values.forEachIndexed { n, (series, value) ->
                val y0 = scales.y(base)
                val y1 = scales.y(base + value)
                base += value
                val isTop = n == values.size - 1
                val gap = if (isTop || thin || y0 - y1 <= 3.dp.toPx()) 0f else gapPx
                val rect = Rect(center - width / 2, y1 + gap, center + width / 2, y1 + gap + max(0.5f, y0 - y1 - gap))
                val radius = if (isTop && !thin) min(4.dp.toPx(), min(rect.height, width / 2)) else 0f
                drawTopRounded(rect, radius, O11yPalette.color(series.slot, colors))
            }
        } else {
            // Side by side within the slot.
            val each = max(1f, width / solid.size)
            solid.forEachIndexed { n, series ->
                val value = series.valueAt(time)?.takeIf { it > 0 } ?: return@forEachIndexed
                val y = scales.y(value)
                val left = center - width / 2 + each * n
                val rect = Rect(left, y, left + max(1f, each - 1f), plot.bottom)
                val radius = if (thin) 0f else min(4.dp.toPx(), min(rect.height, each / 2))
                drawTopRounded(rect, radius, O11yPalette.color(series.slot, colors))
            }
        }
    }
}

private fun DrawScope.drawTopRounded(rect: Rect, radius: Float, color: Color) {
    if (radius <= 0f) {
        drawRect(color, topLeft = rect.topLeft, size = Size(rect.width, rect.height))
        return
    }
    val path = Path().apply {
        addRoundRect(
            RoundRect(
                rect,
                topLeft = CornerRadius(radius),
                topRight = CornerRadius(radius),
                bottomRight = CornerRadius.Zero,
                bottomLeft = CornerRadius.Zero,
            ),
        )
    }
    drawPath(path, color)
}

/** Comparison series ("7 days earlier"): a dashed line in the secondary colour, over everything. */
private fun DrawScope.drawDashed(geometry: O11yChartGeometry, scales: Scales, colors: CrokColors) {
    val index = scales.times.withIndex().associate { (i, t) -> t to i }
    for (series in geometry.visible.filter { it.dashed }) {
        val path = Path()
        var started = false
        for (point in series.points) {
            val i = index[point.time]
            val value = point.value
            if (i == null || value == null) {
                started = false
                continue
            }
            val x = scales.x(i)
            val y = scales.y(value)
            if (started) path.lineTo(x, y) else path.moveTo(x, y)
            started = true
        }
        drawPath(
            path,
            colors.textSecondary,
            style = Stroke(
                width = 2.dp.toPx(),
                cap = StrokeCap.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 6.dp.toPx())),
            ),
        )
    }
}

/** The values at the touched time, largest first, in a card that follows the finger and stays on the plot. */
@Composable
private fun Callout(chart: O11yChart, geometry: O11yChartGeometry, time: Double, x: Float, width: Float, locale: Locale) {
    val colors = CrokTheme.colors
    val rows = geometry.visible.mapNotNull { s -> s.valueAt(time)?.let { s to it } }.sortedByDescending { it.second }.take(8)
    var cardWidth by remember { mutableIntStateOf(0) }
    val left = min(max(0f, x - cardWidth / 2f), max(0f, width - cardWidth)).roundToInt()
    Column(
        Modifier
            .testTag("o11y-callout")
            .offset { IntOffset(left, 0) }
            .widthIn(max = 230.dp)
            .shadow(4.dp, RoundedCornerShape(8.dp))
            .clip(RoundedCornerShape(8.dp))
            .background(colors.sheet)
            .padding(8.dp)
            .onSizeChanged { cardWidth = it.width },
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        val stamp = O11yTimes.axis(time, chart.step, locale) +
            if (chart.step >= 86_400_000) "" else " · " + O11yTimes.axis(time, 86_400_000.0, locale)
        Text(stamp, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
        rows.forEach { (series, value) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(if (series.dashed) colors.textSecondary else O11yPalette.color(series.slot, colors)),
                )
                Spacer(Modifier.size(5.dp))
                Text(series.name, fontSize = 12.sp, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Spacer(Modifier.size(8.dp))
                Text(O11yFormat.value(value, chart.unit, locale), fontSize = 12.sp, color = colors.textPrimary, maxLines = 1)
            }
        }
    }
}
