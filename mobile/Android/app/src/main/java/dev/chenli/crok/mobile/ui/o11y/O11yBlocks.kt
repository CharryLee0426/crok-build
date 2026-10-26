package dev.chenli.crok.mobile.ui.o11y

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.AltRoute
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.O11yBlock
import dev.chenli.crok.mobile.data.O11yLinkRow
import dev.chenli.crok.mobile.data.O11yListRow
import dev.chenli.crok.mobile.data.O11yRanking
import dev.chenli.crok.mobile.data.O11yRankRow
import dev.chenli.crok.mobile.data.O11ySection
import dev.chenli.crok.mobile.data.O11yStat
import dev.chenli.crok.mobile.data.O11yStatus
import dev.chenli.crok.mobile.data.O11yUnit
import dev.chenli.crok.mobile.logic.O11yFormat
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.SectionRow
import dev.chenli.crok.mobile.ui.common.SettingsIcon
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.util.Locale
import kotlin.math.abs

/** A page section as a grouped-list card: the header above it, the block inside, the footer under it. */
@Composable
fun O11ySectionView(
    section: O11ySection,
    wide: Boolean,
    chartHeight: Dp,
    now: Long,
    onOpen: (String) -> Unit,
    onCopy: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = CrokTheme.colors
    Column(modifier.fillMaxWidth().testTag("o11y-section-${section.index}")) {
        section.title?.takeIf { it.isNotEmpty() }?.let { title ->
            Text(
                title,
                style = MaterialTheme.typography.labelLarge,
                color = colors.accent,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp).semantics { heading() },
            )
        }
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.card),
        ) {
            O11yBlockView(section.block, section.title.orEmpty(), wide, chartHeight, now, onOpen, onCopy)
        }
        section.footer?.takeIf { it.isNotEmpty() }?.let { footer ->
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
            )
        }
    }
}

@Composable
private fun O11yBlockView(
    block: O11yBlock,
    title: String,
    wide: Boolean,
    chartHeight: Dp,
    now: Long,
    onOpen: (String) -> Unit,
    onCopy: (String) -> Unit,
) {
    val colors = CrokTheme.colors
    when (block) {
        is O11yBlock.Stats -> O11yStatsGrid(block.items, if (wide) 4 else 2)
        is O11yBlock.Chart -> O11yChartCard(block.chart, title, chartHeight)
        is O11yBlock.Ranking -> O11yRankingView(block.ranking)
        is O11yBlock.Rows -> O11yListView(block.rows, block.empty, now, onOpen, onCopy)
        is O11yBlock.Links -> O11yLinksView(block.rows, onOpen)
        is O11yBlock.Note -> Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Outlined.Info, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
            Text(block.text, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
        }
        is O11yBlock.Error -> Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.Error, contentDescription = null, tint = colors.danger, modifier = Modifier.size(20.dp))
            Column {
                Text(stringResource(R.string.o11y_panel_failed), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                Text(block.message, fontSize = 13.sp, color = colors.textSecondary, maxLines = 4, overflow = TextOverflow.Ellipsis)
            }
        }
        O11yBlock.Unknown -> Unit
    }
}

@Composable
private fun locale(): Locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT

// ---- Stats ----

/** Telegram's overview grid: 2 tiles a row upright, 4 on its side, hairlines between them. */
@Composable
fun O11yStatsGrid(items: List<O11yStat>, columns: Int) {
    val colors = CrokTheme.colors
    val rows = items.chunked(columns)
    Column {
        rows.forEachIndexed { r, row ->
            if (r > 0) HorizontalDivider(color = colors.divider)
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                for (c in 0 until columns) {
                    if (c > 0) VerticalDivider(color = colors.divider)
                    val stat = row.getOrNull(c)
                    if (stat != null) O11yStatTile(stat, Modifier.weight(1f)) else Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun O11yStatTile(stat: O11yStat, modifier: Modifier) {
    val colors = CrokTheme.colors
    val locale = locale()
    val value = O11yFormat.value(stat.value, stat.unit, locale)
    val change = O11yFormat.change(stat.change, locale)
    val spoken = stat.change?.takeIf { it != 0.0 && it.isFinite() }?.let { c ->
        val percent = O11yFormat.value(abs(c), O11yUnit.RATIO, locale)
        stringResource(if (c > 0) R.string.o11y_spoken_up else R.string.o11y_spoken_down, value, percent)
    } ?: value
    Column(
        modifier
            .fillMaxHeight()
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) { contentDescription = "${stat.label}, $spoken" },
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(value, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 1, softWrap = false, modifier = Modifier.alignByBaseline())
            if (change != null) {
                Text(
                    change,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = O11yPalette.tone(O11yFormat.tone(stat.change, stat.better), colors),
                    maxLines = 1,
                    modifier = Modifier.alignByBaseline(),
                )
            }
        }
        // German compounds ("Claude-Cache-Trefferquote") break at syllables, not mid-letter.
        Text(
            stat.label,
            fontSize = 13.sp,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(hyphens = Hyphens.Auto, lineBreak = LineBreak.Paragraph),
        )
    }
}

// ---- Rankings ----

/** Ranked rows, each with a thin bar as long as its share of the largest (a ratio's of 1). */
@Composable
fun O11yRankingView(ranking: O11yRanking) {
    val colors = CrokTheme.colors
    if (ranking.rows.isEmpty()) {
        O11yEmptyBlock(ranking.empty)
        return
    }
    val largest = ranking.rows.maxOf { it.value }
    Column {
        ranking.rows.forEachIndexed { index, row ->
            if (index > 0) HorizontalDivider(Modifier.padding(start = 12.dp), color = colors.divider)
            val fraction = if (ranking.unit == O11yUnit.RATIO) row.value.coerceIn(0.0, 1.0) else if (largest > 0) (row.value.coerceAtLeast(0.0) / largest) else 0.0
            O11yRankRowView(row, ranking.unit, fraction.toFloat())
        }
        if (ranking.more > 0) {
            HorizontalDivider(Modifier.padding(start = 12.dp), color = colors.divider)
            Text(pluralStringResource(R.plurals.o11y_more, ranking.more, ranking.more), fontSize = 13.sp, color = colors.textSecondary, modifier = Modifier.padding(12.dp))
        }
    }
}

@Composable
private fun O11yRankRowView(row: O11yRankRow, unit: O11yUnit, fraction: Float) {
    val colors = CrokTheme.colors
    val locale = locale()
    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .padding(horizontal = 12.dp, vertical = 9.dp)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // The value and its change sit on the label's line (its first baseline), the details under the label.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f).alignBy(FirstBaseline)) {
                Text(row.label, fontSize = 16.sp, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                if (row.detail.isNotEmpty()) {
                    Text(O11yFormat.chips(row.detail, locale), fontSize = 12.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            O11yFormat.change(row.change, locale)?.let { change ->
                Text(
                    change,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = O11yPalette.tone(O11yFormat.tone(row.change, row.better), colors),
                    modifier = Modifier.alignBy(FirstBaseline),
                )
            }
            Text(
                O11yFormat.value(row.value, unit, locale),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                modifier = Modifier.alignBy(FirstBaseline),
            )
        }
        Box(Modifier.fillMaxWidth().height(4.dp)) {
            if (fraction > 0f) {
                Box(
                    Modifier
                        .fillMaxWidth(fraction.coerceIn(0.012f, 1f))
                        .height(4.dp)
                        .clip(CircleShape)
                        .background(O11yPalette.color(row.slot ?: 1, colors)),
                )
            }
        }
    }
}

// ---- Lists ----

@Composable
fun O11yListView(rows: List<O11yListRow>, empty: String, now: Long, onOpen: (String) -> Unit, onCopy: (String) -> Unit) {
    val colors = CrokTheme.colors
    if (rows.isEmpty()) {
        O11yEmptyBlock(empty)
        return
    }
    Column {
        rows.forEachIndexed { index, row ->
            if (index > 0) HorizontalDivider(Modifier.padding(start = if (row.status == null) 12.dp else 40.dp), color = colors.divider)
            O11yListRowView(row, now, onOpen, onCopy)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun O11yListRowView(row: O11yListRow, now: Long, onOpen: (String) -> Unit, onCopy: (String) -> Unit) {
    val colors = CrokTheme.colors
    val locale = locale()
    val detail = O11yFormat.chips(row.detail, locale)
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = { row.page?.let(onOpen) },
                    onLongClick = { menu = true },
                )
                .heightIn(min = 44.dp)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            row.status?.let { StatusGlyph(it) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(row.title, fontSize = 16.sp, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (detail.isNotEmpty()) Text(detail, fontSize = 13.sp, color = colors.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                row.value?.let { Text(O11yFormat.value(it.v, it.unit, locale), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 1) }
                row.time?.let { Text(O11yTimes.row(it, now, locale), fontSize = 12.sp, color = colors.textSecondary, maxLines = 1) }
            }
            if (row.page != null) {
                Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(20.dp).align(Alignment.CenterVertically))
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.action_copy)) },
                leadingIcon = { Icon(CrokIcons.Copy, contentDescription = null) },
                onClick = {
                    menu = false
                    onCopy(listOf(row.title, detail).filter { it.isNotEmpty() }.joinToString("\n"))
                },
            )
        }
    }
}

@Composable
private fun StatusGlyph(status: O11yStatus) {
    val colors = CrokTheme.colors
    val (icon, tint, label) = when (status) {
        O11yStatus.OK -> Triple(Icons.Filled.CheckCircle, colors.success, stringResource(R.string.o11y_status_ok))
        O11yStatus.BAD -> Triple(Icons.Filled.Cancel, colors.danger, stringResource(R.string.tool_failed))
        O11yStatus.WARN -> Triple(Icons.Filled.Warning, O11yPalette.warn, stringResource(R.string.o11y_status_warning))
        O11yStatus.INFO -> Triple(Icons.Outlined.Info, colors.textSecondary, null)
    }
    Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.padding(top = 1.dp).size(18.dp))
}

// ---- Links ----

/** Profile-style rows to other pages (the home page's Dashboards, Evaluation, Agent Observability). */
@Composable
fun O11yLinksView(rows: List<O11yLinkRow>, onOpen: (String) -> Unit) {
    val colors = CrokTheme.colors
    val locale = locale()
    Column {
        rows.forEachIndexed { index, row ->
            SectionRow(
                row.title,
                subtitle = row.subtitle?.takeIf { it.isNotEmpty() },
                leading = { SettingsIcon(O11yIcons.icon(row.icon), O11yIcons.color(row.color, colors.accent)) },
                divider = index < rows.size - 1,
                onClick = { onOpen(row.page) },
                modifier = Modifier.testTag("o11y-link-${row.page}"),
            ) {
                row.value?.let { Text(O11yFormat.value(it.v, it.unit, locale), color = colors.textSecondary, fontSize = 15.sp, maxLines = 1) }
                Icon(CrokIcons.ChevronRight, contentDescription = null, tint = colors.textTertiary)
            }
        }
    }
}

/** The links' glyphs (mobile/DESIGN.md "o11y" › Icons). */
object O11yIcons {
    fun icon(name: String): ImageVector = when (name) {
        "overview" -> Icons.Filled.Dashboard
        "claude" -> Icons.Filled.AutoAwesome
        "openrouter" -> Icons.AutoMirrored.Filled.AltRoute
        "crok" -> Icons.Filled.Memory
        "harness" -> Icons.Filled.Build
        "history" -> Icons.Filled.CalendarMonth
        "explorer" -> Icons.Filled.Search
        "evaluators" -> Icons.Filled.Verified
        "guards" -> Icons.Filled.Shield
        "experiments" -> Icons.Filled.Science
        "agents" -> Icons.Filled.Groups
        "conversations" -> Icons.Filled.Forum
        "slos" -> Icons.Filled.TrackChanges
        "alerts" -> Icons.Filled.NotificationsActive
        else -> Icons.Filled.BarChart
    }

    fun color(hex: String, fallback: Color): Color {
        val digits = hex.removePrefix("#")
        val value = digits.takeIf { it.length == 6 }?.toLongOrNull(16) ?: return fallback
        return Color(0xFF000000 or value)
    }
}

@Composable
fun O11yEmptyBlock(text: String) {
    Text(
        text,
        fontSize = 13.sp,
        color = CrokTheme.colors.textSecondary,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(vertical = 18.dp, horizontal = 12.dp),
    )
}
