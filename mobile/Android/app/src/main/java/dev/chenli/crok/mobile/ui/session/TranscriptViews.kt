package dev.chenli.crok.mobile.ui.session

import android.os.SystemClock
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.Grouping
import dev.chenli.crok.mobile.logic.NoticeKind
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.RevealPacer
import dev.chenli.crok.mobile.logic.Tick
import dev.chenli.crok.mobile.logic.TranscriptItem
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.Pill
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme

/** What transcript rows can ask for. */
data class TranscriptActions(
    val onCopy: (String) -> Unit = {},
    val onRetry: (TranscriptItem.User) -> Unit = {},
    val onDelete: (TranscriptItem.User) -> Unit = {},
    /** A bot card's button (`cardId`, the choice's id). */
    val onApplyConfig: (String, String) -> Unit = { _, _ -> },
)

/** What a bot card shows its choices from: the session's models and its computer. */
data class BotContext(
    val models: ModelState = ModelState(),
    val deviceName: String = "",
    val deviceOnline: Boolean = false,
)

private fun outShape(grouping: Grouping) = RoundedCornerShape(
    topStart = 18.dp,
    topEnd = if (grouping.withOlder) 6.dp else 18.dp,
    bottomEnd = if (grouping.withNewer) 6.dp else 18.dp,
    bottomStart = 18.dp,
)

private fun inShape(grouping: Grouping) = RoundedCornerShape(
    topStart = if (grouping.withOlder) 6.dp else 18.dp,
    topEnd = 18.dp,
    bottomEnd = 18.dp,
    bottomStart = if (grouping.withNewer) 6.dp else 18.dp,
)

private fun Modifier.groupSpacing(grouping: Grouping) = padding(top = if (grouping.withOlder) 2.dp else 10.dp)

@Composable
fun TranscriptRow(item: TranscriptItem, now: Long, actions: TranscriptActions, bot: BotContext = BotContext()) {
    when (item) {
        is TranscriptItem.Bot -> BotCardRow(item.card, bot, actions.onApplyConfig)
        is TranscriptItem.Day -> DayHeader(item, now)
        is TranscriptItem.User -> UserBubble(item, actions)
        is TranscriptItem.Assistant -> AssistantBubble(item, actions)
        is TranscriptItem.Thought -> ThoughtRow(item)
        is TranscriptItem.Tool -> ToolCard(item)
        is TranscriptItem.Notice -> NoticeRow(item)
    }
}

@Composable
private fun DayHeader(item: TranscriptItem.Day, now: Long) {
    val formatter = rememberFormatter()
    Box(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 6.dp), contentAlignment = Alignment.Center) {
        Pill(formatter.dayLabel(RelativeTime.dayLabel(item.date, now, formatter.zone)))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun UserBubble(item: TranscriptItem.User, actions: TranscriptActions) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var menu by remember { mutableStateOf(false) }
    val failed = item.tick == Tick.Failed
    Column(
        Modifier.fillMaxWidth().groupSpacing(item.grouping).padding(end = 10.dp),
        horizontalAlignment = Alignment.End,
    ) {
        Row(Modifier.fillMaxWidth(0.86f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.End) {
            if (failed) {
                Box {
                    IconButton(onClick = { menu = true }, modifier = Modifier.size(36.dp)) {
                        Icon(CrokIcons.Error, contentDescription = stringResource(R.string.tick_failed), tint = colors.danger)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.action_retry)) },
                            onClick = {
                                menu = false
                                actions.onRetry(item)
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.action_delete), color = colors.danger) },
                            onClick = {
                                menu = false
                                actions.onDelete(item)
                            },
                        )
                    }
                }
            }
            Column(
                Modifier
                    .weight(1f, fill = false)
                    .clip(outShape(item.grouping))
                    .background(colors.bubbleOut)
                    .combinedClickable(onClick = { if (failed) menu = true }, onLongClick = { actions.onCopy(item.text) })
                    .padding(start = 12.dp, end = 10.dp, top = 8.dp, bottom = 6.dp),
                horizontalAlignment = Alignment.End,
            ) {
                Text(item.text, style = MaterialTheme.typography.bodyLarge, color = colors.onBubbleOut, modifier = Modifier.align(Alignment.Start))
                // Time and label on the bubble: muted ordinary text on light blue, translucent white on dark blue.
                val meta = if (colors.isDark) colors.onBubbleOut.copy(alpha = 0.6f) else colors.textTertiary
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (item.remote && item.fromLabel != null) {
                        Icon(CrokIcons.Phone, contentDescription = null, tint = meta, modifier = Modifier.size(12.dp))
                        Text(stringResource(R.string.message_from, item.fromLabel), fontSize = 12.sp, color = meta, maxLines = 1)
                        Spacer(Modifier.width(2.dp))
                    }
                    Text(formatter.time(item.at), fontSize = 12.sp, color = meta)
                    item.tick?.let { TickIcon(it) }
                }
            }
        }
        if (failed && item.error != null) {
            Text(
                stringResource(R.string.prompt_not_sent, item.error),
                color = colors.danger,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp, end = 4.dp),
            )
        }
    }
}

@Composable
private fun TickIcon(tick: Tick) {
    val colors = CrokTheme.colors
    // Accent ticks on the light bubble; on the dark blue one the accent would vanish, so a light blue-white.
    val check = if (colors.isDark) Color(0xFFB8D8FF) else colors.accent
    val clock = if (colors.isDark) colors.onBubbleOut.copy(alpha = 0.6f) else colors.textTertiary
    val (icon, tint, label) = when (tick) {
        Tick.Clock -> Triple(CrokIcons.Clock, clock, R.string.tick_clock)
        Tick.Sent -> Triple(CrokIcons.Check, check, R.string.tick_sent)
        Tick.Done -> Triple(CrokIcons.DoneAll, check, R.string.tick_done)
        Tick.Failed -> Triple(CrokIcons.Error, colors.danger, R.string.tick_failed)
    }
    Icon(icon, contentDescription = stringResource(label), tint = tint, modifier = Modifier.size(15.dp))
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AssistantBubble(item: TranscriptItem.Assistant, actions: TranscriptActions) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val shown = rememberRevealedLength(item.key, item.text.length, item.streaming)
    val text = if (shown >= item.text.length) item.text else item.text.take(shown)
    Box(Modifier.fillMaxWidth(0.92f).groupSpacing(item.grouping).padding(start = 10.dp)) {
        Column(
            Modifier
                .clip(inShape(item.grouping))
                .background(colors.bubbleIn)
                .border(0.5.dp, colors.divider, inShape(item.grouping))
                .combinedClickable(onClick = {}, onLongClick = { actions.onCopy(item.text) })
                .padding(start = 12.dp, end = 12.dp, top = 9.dp, bottom = 6.dp),
        ) {
            MarkdownText(text, onCopyCode = actions.onCopy)
            Row(Modifier.align(Alignment.End).padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                if (item.streaming) {
                    CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.accent)
                    Spacer(Modifier.width(6.dp))
                }
                Text(formatter.time(item.at), fontSize = 12.sp, color = colors.textTertiary)
            }
        }
    }
}

/**
 * How many characters of a streaming reply to show now (see [RevealPacer]). Text that was already there when the row
 * appeared shows at once; growth is revealed at the observed chunk pace and finishes within 0.3 s at turn end.
 */
@Composable
fun rememberRevealedLength(key: String, length: Int, streaming: Boolean): Int {
    val pacer = remember(key) { RevealPacer(length, SystemClock.uptimeMillis()) }
    var shown by remember(key) { mutableIntStateOf(length) }
    val streamingNow by rememberUpdatedState(streaming)
    LaunchedEffect(key, length) {
        pacer.onText(length, SystemClock.uptimeMillis())
        shown = pacer.revealed
        while (!pacer.caughtUp) {
            withFrameMillis { }
            shown = pacer.advance(SystemClock.uptimeMillis(), streamingNow)
        }
        shown = length
    }
    return shown
}

@Composable
private fun ThoughtRow(item: TranscriptItem.Thought) {
    val colors = CrokTheme.colors
    var expanded by rememberSaveable(item.key) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .groupSpacing(item.grouping)
            .padding(start = 10.dp, end = 28.dp)
            .animateContentSize(),
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(12.dp))
                .clickable { expanded = !expanded }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(CrokIcons.Bulb, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.thought_title), fontStyle = FontStyle.Italic, color = colors.textSecondary, fontSize = 14.sp)
            Icon(
                if (expanded) CrokIcons.ExpandLess else CrokIcons.ExpandMore,
                contentDescription = stringResource(if (expanded) R.string.cd_collapse else R.string.cd_expand),
                tint = colors.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        if (expanded) {
            Text(
                item.text,
                fontStyle = FontStyle.Italic,
                color = colors.textSecondary,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(start = 30.dp, end = 8.dp, bottom = 4.dp),
            )
        }
    }
}

fun toolIcon(kind: String?): ImageVector = when (kind) {
    "read" -> CrokIcons.Document
    "edit" -> CrokIcons.Edit
    "delete" -> CrokIcons.Delete
    "move" -> CrokIcons.Move
    "search" -> CrokIcons.Search
    "execute" -> CrokIcons.Terminal
    "think" -> CrokIcons.Bulb
    "fetch" -> CrokIcons.Globe
    else -> CrokIcons.Build
}

@Composable
private fun ToolCard(item: TranscriptItem.Tool) {
    val colors = CrokTheme.colors
    var expanded by rememberSaveable(item.key) { mutableStateOf(false) }
    val expandable = item.text.isNotBlank() && item.text.trim() != item.title.trim()
    Box(Modifier.fillMaxWidth(0.92f).groupSpacing(item.grouping).padding(start = 10.dp)) {
        Column(
            Modifier
                .clip(RoundedCornerShape(12.dp))
                .background(colors.card)
                .border(0.5.dp, colors.divider, RoundedCornerShape(12.dp))
                .then(if (expandable) Modifier.clickable { expanded = !expanded } else Modifier)
                .padding(horizontal = 10.dp, vertical = 8.dp)
                .animateContentSize(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(toolIcon(item.toolKind), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    item.title,
                    color = colors.textPrimary,
                    fontSize = 14.sp,
                    maxLines = if (expanded) 4 else 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.width(8.dp))
                ToolStatus(item.status)
            }
            if (expanded) {
                CodeBlock(item.text, Modifier.padding(top = 8.dp))
            }
        }
    }
}

@Composable
private fun ToolStatus(status: String?) {
    val colors = CrokTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        when (status) {
            "in_progress" -> {
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = colors.accent)
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.tool_running), color = colors.accent, fontSize = 12.sp)
            }
            "completed" -> {
                Icon(CrokIcons.Check, contentDescription = null, tint = colors.success, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(2.dp))
                Text(stringResource(R.string.tool_done), color = colors.success, fontSize = 12.sp)
            }
            "failed" -> {
                Icon(CrokIcons.Error, contentDescription = null, tint = colors.danger, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(2.dp))
                Text(stringResource(R.string.tool_failed), color = colors.danger, fontSize = 12.sp)
            }
            else -> Text(stringResource(R.string.tool_pending), color = colors.textTertiary, fontSize = 12.sp)
        }
    }
}

@Composable
private fun NoticeRow(item: TranscriptItem.Notice) {
    val colors = CrokTheme.colors
    val (text, fg, bg) = when (item.kind) {
        NoticeKind.Stopped -> Triple(stringResource(R.string.notice_stopped), colors.textSecondary, colors.card)
        NoticeKind.MaxTokens -> Triple(stringResource(R.string.notice_max_tokens), colors.warning, colors.warningContainer)
        NoticeKind.Refusal -> Triple(stringResource(R.string.notice_refusal), colors.warning, colors.warningContainer)
        NoticeKind.Error -> Triple(item.text.ifBlank { stringResource(R.string.tool_failed) }, colors.danger, colors.dangerContainer)
        NoticeKind.Info -> Triple(item.text, colors.textSecondary, colors.card)
    }
    Box(Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
        Pill(text, color = fg, background = bg)
    }
}
