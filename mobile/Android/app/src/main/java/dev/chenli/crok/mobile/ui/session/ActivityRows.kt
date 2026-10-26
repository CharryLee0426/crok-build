package dev.chenli.crok.mobile.ui.session

import android.animation.ValueAnimator
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.ToolState
import dev.chenli.crok.mobile.logic.TranscriptItem
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokColors
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.Mono

// Thinking and tool calls, after Crok Desktop's reasoning and tool rows but by their status only (mobile/DESIGN.md
// "Thinking and tool calls"): nothing expands, the relay does not even send their text.

/** Crok Desktop's thinking colours (ThinkingPalette), the same in light and dark. */
private val ThinkingColors = listOf(0xFF598CFF, 0xFF9E6BFF, 0xFFFA66B8, 0xFFFF9E52, 0xFFFA66B8, 0xFF9E6BFF, 0xFF598CFF)
    .map { Color(it) }

/** The running tool card's rim (Desktop's ExecutingPalette). */
private val RunningRimColors = listOf(0xFF3366FF, 0xFF1A9EFF, 0xFF47DBFA, 0xFF1A9EFF, 0xFF3366FF).map { Color(it) }

/** Executing blue: the running tool's spinner and status word. */
private fun CrokColors.executing(): Color = if (isDark) Color(0xFF5FA8FF) else Color(0xFF2868E8)

/** Animations run unless the system turned them off (Developer options › animator duration scale 0, battery saver). */
@Composable
private fun rememberMotion(): Boolean = remember { ValueAnimator.areAnimatorsEnabled() }

/** 0 → 1 over [millis], again and again ([reverse]: back and forth); null when animations are off. */
@Composable
private fun rememberPhase(motion: Boolean, millis: Int, reverse: Boolean = false, label: String): State<Float>? {
    if (!motion) return null
    val transition = rememberInfiniteTransition(label = label)
    return transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(millis, easing = if (reverse) FastOutSlowInEasing else LinearEasing),
            if (reverse) RepeatMode.Reverse else RepeatMode.Restart,
        ),
        label = label,
    )
}

/** The thinking colours as a mirrored band [period] px wide, slid by [shift] px. */
private fun thinkingBrush(shift: Float, period: Float, colors: List<Color> = ThinkingColors): Brush =
    Brush.horizontalGradient(colors, startX = shift, endX = shift + period, tileMode = TileMode.Mirror)

@Composable
fun ThoughtRow(item: TranscriptItem.Thought) {
    val colors = CrokTheme.colors
    val shape = RoundedCornerShape(12.dp)
    val label = stringResource(if (item.active) R.string.thinking_active else R.string.thought_title)
    Box(
        Modifier
            .fillMaxWidth()
            .padding(top = if (item.grouping.withOlder) 2.dp else 10.dp)
            .padding(start = 10.dp, end = 28.dp),
    ) {
        Column(
            Modifier
                .width(IntrinsicSize.Max)
                .clip(shape)
                .background(colors.card)
                .border(0.5.dp, colors.divider, shape)
                .semantics(mergeDescendants = true) { contentDescription = label }
                .testTag(if (item.active) "thinking-active" else "thought"),
        ) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (item.active) {
                    ThinkingLabel(label)
                } else {
                    Icon(CrokIcons.Sparkle, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(label, color = colors.textSecondary, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                }
            }
            if (item.active) ThinkingBar(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 6.dp))
        }
    }
}

/** "Thinking…" and its sparkle in the thinking colours, sliding sideways; the sparkle turns. */
@Composable
private fun ThinkingLabel(label: String) {
    val motion = rememberMotion()
    val sweep = rememberPhase(motion, 2_400, label = "thinking-sweep")
    val turn = rememberPhase(motion, 2_800, label = "thinking-turn")
    val period = with(LocalDensity.current) { 120.dp.toPx() }
    Icon(
        CrokIcons.Sparkle,
        contentDescription = null,
        tint = Color.White,
        modifier = Modifier
            .size(13.dp)
            .graphicsLayer {
                rotationZ = (turn?.value ?: 0f) * 360f
                compositingStrategy = CompositingStrategy.Offscreen
            }
            .drawWithContent {
                drawContent()
                drawRect(thinkingBrush((sweep?.value ?: 0f) * 2 * period, period), blendMode = BlendMode.SrcIn)
            },
    )
    Spacer(Modifier.width(8.dp))
    Text(
        label,
        maxLines = 1,
        style = TextStyle(
            brush = thinkingBrush((sweep?.value ?: 0f) * 2 * period - 30f, period),
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
        ),
    )
}

/** Desktop's thinking bar: a faint track and a coloured segment sliding end to end and back. */
@Composable
private fun ThinkingBar(modifier: Modifier) {
    val colors = CrokTheme.colors
    val motion = rememberMotion()
    val slide = rememberPhase(motion, 1_250, reverse = true, label = "thinking-bar")
    Canvas(modifier.height(2.dp)) {
        val radius = CornerRadius(size.height / 2)
        drawRoundRect(colors.textSecondary.copy(alpha = 0.14f), cornerRadius = radius)
        val width = if (slide == null) size.width else (size.width * 0.36f).coerceIn(minOf(36.dp.toPx(), size.width), minOf(260.dp.toPx(), size.width))
        val x = (slide?.value ?: 0f) * (size.width - width)
        drawRoundRect(
            thinkingBrush(x, width * 2.2f),
            topLeft = Offset(x, 0f),
            size = Size(width, size.height),
            cornerRadius = radius,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ToolCard(item: TranscriptItem.Tool, actions: TranscriptActions) {
    val colors = CrokTheme.colors
    val shape = RoundedCornerShape(12.dp)
    val tint = when (item.state) {
        ToolState.Running -> colors.executing()
        ToolState.Completed -> colors.success
        ToolState.Failed -> colors.danger
        ToolState.Stopped, ToolState.Other -> colors.textSecondary
    }
    val status = when (item.state) {
        ToolState.Running -> stringResource(R.string.tool_state_running)
        ToolState.Completed -> stringResource(R.string.tool_state_done)
        ToolState.Failed -> stringResource(R.string.tool_state_failed)
        ToolState.Stopped -> stringResource(R.string.tool_state_stopped)
        ToolState.Other -> null
    }
    val edge = when (item.state) {
        ToolState.Completed -> Modifier.background(tint.copy(alpha = 0.10f)).border(1.dp, tint.copy(alpha = 0.35f), shape)
        ToolState.Failed -> Modifier.background(tint.copy(alpha = 0.10f)).border(1.dp, tint.copy(alpha = 0.40f), shape)
        ToolState.Running -> Modifier.runningRim(shape)
        ToolState.Stopped, ToolState.Other -> Modifier.border(0.5.dp, colors.divider, shape)
    }
    Box(
        Modifier
            .fillMaxWidth()
            .padding(top = if (item.grouping.withOlder) 2.dp else 10.dp)
            .padding(start = 10.dp, end = 28.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clip(shape)
                .background(colors.card)
                .then(edge)
                .combinedClickable(onClick = {}, onLongClick = { actions.onCopy(item.title) })
                .semantics(mergeDescendants = true) {}
                .testTag("tool-${item.state.name.lowercase()}")
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                when (item.state) {
                    ToolState.Running -> ToolSpinner(tint)
                    ToolState.Completed -> Icon(CrokIcons.CheckCircle, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
                    ToolState.Failed -> Icon(CrokIcons.Cancel, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
                    ToolState.Stopped, ToolState.Other ->
                        Icon(toolIcon(item.toolKind), contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
                }
            }
            Spacer(Modifier.width(10.dp))
            Text(
                toolTitle(item.title, colors),
                color = colors.textPrimary,
                fontSize = 15.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (status != null) {
                Spacer(Modifier.width(8.dp))
                Text(status, color = tint, fontSize = 12.sp, maxLines = 1)
            }
        }
    }
}

/** A running call's rim: a thin band of blues sliding along it (still when animations are off). */
@Composable
private fun Modifier.runningRim(shape: RoundedCornerShape): Modifier {
    val motion = rememberMotion()
    val sweep = rememberPhase(motion, 3_400, reverse = true, label = "tool-rim")
    val period = with(LocalDensity.current) { 220.dp.toPx() }
    return border(1.dp, thinkingBrush((sweep?.value ?: 0f) * 2 * period, period, RunningRimColors), shape)
}

/** Desktop's spinner: a faint ring with a 68 % arc turning once every 0.9 s. */
@Composable
private fun ToolSpinner(tint: Color) {
    val motion = rememberMotion()
    val turn = rememberPhase(motion, 900, label = "tool-spinner")
    Canvas(Modifier.size(13.dp).graphicsLayer { rotationZ = (turn?.value ?: 0f) * 360f }) {
        val stroke = 1.8.dp.toPx()
        val inset = stroke / 2
        val arcSize = Size(size.width - stroke, size.height - stroke)
        drawArc(tint.copy(alpha = 0.2f), 0f, 360f, useCenter = false, topLeft = Offset(inset, inset), size = arcSize, style = Stroke(stroke))
        drawArc(tint, -90f, 0.68f * 360f, useCenter = false, topLeft = Offset(inset, inset), size = arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}

/** A call's title with its `code` spans in the monospaced font on the code fill, as Desktop draws `` Execute `ls` ``. */
private fun toolTitle(title: String, colors: CrokColors): AnnotatedString = buildAnnotatedString {
    val parts = title.split('`')
    // An odd number of parts means the backticks pair up; otherwise they are shown as typed.
    if (parts.size < 3 || parts.size % 2 == 0) {
        append(title)
        return@buildAnnotatedString
    }
    for ((index, part) in parts.withIndex()) {
        if (index % 2 == 0) {
            append(part)
        } else {
            withStyle(SpanStyle(fontFamily = Mono, fontSize = 13.sp, background = colors.inlineCode)) { append(" $part ") }
        }
    }
}
