package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.TopicIcon
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.launch

/** What a topic row can ask for (the project screen, Archived, the Sessions tab's search). */
data class TopicActions(
    val onOpen: (SessionRow) -> Unit = {},
    val onTogglePin: (SessionRow) -> Unit = {},
    val onToggleArchive: (SessionRow) -> Unit = {},
    val onStop: (SessionRow) -> Unit = {},
    val onMarkRead: (SessionRow) -> Unit = {},
    val onMove: (SessionRow, delta: Int) -> Unit = { _, _ -> },
    /** A row's swipe started or ended: the list holds still meanwhile (Telegram's frozen list). */
    val onSwiping: (Boolean) -> Unit = {},
)

/** Which ways a session can move by hand in its project (Move up / Move down). */
data class RowMoves(val up: Boolean, val down: Boolean) {
    companion object {
        val None = RowMoves(up = false, down = false)

        fun of(projectRows: List<SessionRow>, row: SessionRow) = RowMoves(
            up = SessionOrder.moveSession(projectRows, row.id, -1) != null,
            down = SessionOrder.moveSession(projectRows, row.id, 1) != null,
        )
    }
}

/**
 * A session row as a topic of its project's group (mobile/DESIGN.md "Project screen"): the topic glyph, title and
 * time, the folder when it is not the project's and "offline" while the computer is (or, with [projectLine], the
 * project's name), the preview in up to two lines, and the unread count or a pin. Swipes: Pin / Unpin from the start,
 * Archive (Unarchive) from the end; a long press opens the rest.
 */
@Composable
fun SwipeableTopicRow(
    row: SessionRow,
    now: Long,
    actions: TopicActions,
    modifier: Modifier = Modifier,
    projectName: String? = null,
    projectLine: Boolean = false,
    moves: RowMoves = RowMoves.None,
) {
    val colors = CrokTheme.colors
    val scope = rememberCoroutineScope()
    val dismiss = rememberSwipeToDismissBoxState(positionalThreshold = { distance -> distance * 0.3f })
    LaunchedEffect(dismiss) {
        snapshotFlow { dismiss.dismissDirection != SwipeToDismissBoxValue.Settled }.collect(actions.onSwiping)
    }
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier,
        backgroundContent = {
            val visual = when (dismiss.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> SwipeVisual(
                    colors.swipePin,
                    CrokIcons.Pin,
                    stringResource(if (row.pinned) R.string.action_unpin else R.string.action_pin),
                    Alignment.CenterStart,
                )
                SwipeToDismissBoxValue.EndToStart -> SwipeVisual(
                    colors.swipeArchive,
                    if (row.archived) CrokIcons.Unarchive else CrokIcons.Archive,
                    stringResource(if (row.archived) R.string.action_unarchive else R.string.action_archive),
                    Alignment.CenterEnd,
                )
                SwipeToDismissBoxValue.Settled -> SwipeVisual(Color.Transparent, null, "", Alignment.Center)
            }
            SwipeBackground(visual)
        },
        enableDismissFromStartToEnd = !row.archived,
        onDismiss = { direction ->
            when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> actions.onTogglePin(row)
                SwipeToDismissBoxValue.EndToStart -> actions.onToggleArchive(row)
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch { dismiss.reset() }
        },
    ) {
        TopicRow(row, now, actions, projectName = projectName, projectLine = projectLine, moves = moves)
    }
}

internal data class SwipeVisual(
    val background: Color,
    val icon: ImageVector?,
    val label: String,
    val alignment: Alignment,
)

@Composable
internal fun SwipeBackground(visual: SwipeVisual) {
    Box(Modifier.fillMaxSize().background(visual.background).padding(horizontal = 24.dp), contentAlignment = visual.alignment) {
        if (visual.icon != null) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(visual.icon, contentDescription = null, tint = Color.White)
                Text(visual.label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

/** [SwipeableTopicRow]'s content, also used without swipes. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TopicRow(
    row: SessionRow,
    now: Long,
    actions: TopicActions,
    modifier: Modifier = Modifier,
    projectName: String? = null,
    projectLine: Boolean = false,
    moves: RowMoves = RowMoves.None,
) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var menu by remember { mutableStateOf(false) }
    // Dimmed only when its computer is offline: a session nobody runs opens there when it gets a prompt.
    val dimmed = !row.reachable
    val effectiveNow = if (now > 0) now else System.currentTimeMillis()
    val time = formatter.listTime(RelativeTime.listTime(row.lastActivityAt, effectiveNow, formatter.zone))
    val title = row.title.ifBlank { SessionList.folderName(row.cwd) }
    val project = projectName ?: SessionList.projectName(row)
    val offline = stringResource(R.string.computer_offline)
    val secondLine = if (projectLine) {
        listOfNotNull(project, offline.takeIf { dimmed }).joinToString(" · ")
    } else {
        listOfNotNull(SessionList.folderLine(row, project), offline.takeIf { dimmed }).joinToString(" · ").ifEmpty { null }
    }

    Box(modifier.background(colors.screen)) {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = { actions.onOpen(row) }, onLongClick = { menu = true })
                .testTag("topic-${row.id}"),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(start = 14.dp, end = 16.dp, top = 9.dp, bottom = 9.dp),
                verticalAlignment = Alignment.Top,
            ) {
                TopicIcon(title, row.id, 40.dp, dimmed = dimmed, modifier = Modifier.padding(top = 2.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            title,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (dimmed) colors.textSecondary else colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(time, fontSize = 13.sp, color = if (row.unread > 0 && !dimmed) colors.accent else colors.textTertiary)
                    }
                    if (secondLine != null) {
                        Text(secondLine, fontSize = 13.sp, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.height(1.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { TopicPreview(row, dimmed, maxLines = 2) }
                        if (row.unread > 0) {
                            Spacer(Modifier.width(8.dp))
                            UnreadBadge(row.unread, muted = dimmed)
                        } else if (row.pinned) {
                            Spacer(Modifier.width(8.dp))
                            Icon(
                                CrokIcons.Pin,
                                contentDescription = stringResource(R.string.cd_pinned),
                                tint = colors.textTertiary,
                                modifier = Modifier.size(18.dp).rotate(45f),
                            )
                        }
                    }
                }
            }
            HorizontalDivider(Modifier.padding(start = 66.dp), color = colors.divider, thickness = 0.5.dp)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!row.archived) {
                MenuItem(stringResource(if (row.pinned) R.string.action_unpin else R.string.action_pin), CrokIcons.Pin) {
                    menu = false
                    actions.onTogglePin(row)
                }
            }
            if (row.isRunning) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_stop), color = colors.danger) },
                    leadingIcon = { Icon(CrokIcons.Stop, contentDescription = null, tint = colors.danger) },
                    onClick = {
                        menu = false
                        actions.onStop(row)
                    },
                )
            }
            if (row.unread > 0) {
                MenuItem(stringResource(R.string.action_mark_read), CrokIcons.DoneAll) {
                    menu = false
                    actions.onMarkRead(row)
                }
            }
            MenuItem(
                stringResource(if (row.archived) R.string.action_unarchive else R.string.action_archive),
                if (row.archived) CrokIcons.Unarchive else CrokIcons.Archive,
            ) {
                menu = false
                actions.onToggleArchive(row)
            }
            if (moves.up) {
                MenuItem(stringResource(R.string.action_move_up), CrokIcons.ArrowUp) {
                    menu = false
                    actions.onMove(row, -1)
                }
            }
            if (moves.down) {
                MenuItem(stringResource(R.string.action_move_down), CrokIcons.ArrowDown) {
                    menu = false
                    actions.onMove(row, 1)
                }
            }
        }
    }
}

@Composable
internal fun MenuItem(text: String, icon: ImageVector, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(text) }, leadingIcon = { Icon(icon, contentDescription = null) }, onClick = onClick)
}

/** A session's state line: "Starting…", "working…", "Needs approval", the preview, or where its history is. */
@Composable
fun TopicPreview(row: SessionRow, dimmed: Boolean, maxLines: Int = 1) {
    val colors = CrokTheme.colors
    when {
        row.starting && row.deviceOnline -> Text(stringResource(R.string.session_starting), fontSize = 14.sp, color = colors.accent, maxLines = 1)
        row.isWaiting -> NeedsApprovalChip()
        row.isRunning -> WorkingDots(stringResource(R.string.sessions_working), colors.accent)
        !row.preview.isNullOrBlank() -> Preview(row, dimmed, maxLines)
        HistoryState.onComputerOnly(row.historyState) -> Text(
            stringResource(R.string.sessions_history_on, row.deviceName),
            fontSize = 14.sp,
            color = colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        else -> Text(stringResource(R.string.sessions_no_messages), fontSize = 14.sp, color = colors.textTertiary, maxLines = 1)
    }
}

/** The preview text, "You: " before a prompt of the person's. */
@Composable
fun Preview(row: SessionRow, dimmed: Boolean, maxLines: Int = 1) {
    val colors = CrokTheme.colors
    val preview = row.preview.orEmpty().lines().filter { it.isNotBlank() }.joinToString(" ") { it.trim() }
    val you = stringResource(R.string.sessions_you)
    val text = buildAnnotatedString {
        if (row.previewKind == EventKind.USER && preview.isNotEmpty()) {
            withStyle(SpanStyle(color = if (dimmed) colors.textSecondary else colors.textPrimary)) { append(you) }
        }
        append(preview)
    }
    Text(text, fontSize = 14.sp, lineHeight = 19.sp, color = colors.textSecondary, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

@Composable
fun NeedsApprovalChip() {
    val colors = CrokTheme.colors
    Row(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(colors.warningContainer)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(CrokIcons.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(4.dp))
        Text(stringResource(R.string.sessions_needs_approval), color = colors.warning, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun UnreadBadge(count: Int, muted: Boolean) {
    val colors = CrokTheme.colors
    val description = pluralStringResource(R.plurals.sessions_unread, count, count)
    Box(
        Modifier
            .heightIn(min = 22.dp)
            .widthIn(min = 22.dp)
            .clip(CircleShape)
            .background(if (muted) colors.badgeMuted else colors.accent)
            .padding(horizontal = 6.dp)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (count > 99) "99+" else count.toString(),
            color = if (muted) Color.White else colors.onAccent,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}
