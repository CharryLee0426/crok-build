package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.logic.SessionSection
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.InitialsAvatar
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.channels.Channel

/**
 * Dragging one item of a LazyColumn by its handle (the Compose drag-and-drop sample's approach): the dragged item is
 * drawn under the finger, and when its middle passes over an item it may trade places with, [onMove] swaps the two in
 * the data at once, so the dragged item's real place follows the finger and it never scrolls out of composition. Near
 * the list's edges it asks for scrolling through [scrollRequests].
 */
class ReorderDragState(
    private val list: LazyListState,
    private val canMove: (from: String, to: String) -> Boolean,
    private val onMove: (from: String, to: String) -> Unit,
) {
    var draggingKey by mutableStateOf<String?>(null)
        private set

    private var delta by mutableFloatStateOf(0f)
    private var initialOffset by mutableIntStateOf(0)

    /** The layout in which the last swap was asked for: no new swap until the list has been laid out again. */
    private var layoutAtMove: LazyListLayoutInfo? = null

    internal val scrollRequests = Channel<Float>(Channel.CONFLATED)

    private val draggingInfo: LazyListItemInfo?
        get() = draggingKey?.let { key -> list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key } }

    /** How far the dragged item is drawn from the place the list gives it. */
    val offset: Float
        get() = draggingInfo?.let { initialOffset + delta - it.offset } ?: 0f

    fun start(key: String): Boolean {
        val info = list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key } ?: return false
        draggingKey = key
        initialOffset = info.offset
        delta = 0f
        layoutAtMove = null
        return true
    }

    fun drag(dy: Float) {
        if (draggingKey == null) return
        delta += dy
        val layout = list.layoutInfo
        if (layoutAtMove != null && layout === layoutAtMove) return
        layoutAtMove = null
        val dragged = draggingInfo ?: return
        val top = initialOffset + delta
        val bottom = top + dragged.size
        val middle = ((top + bottom) / 2f).toInt()
        val target = layout.visibleItemsInfo.firstOrNull { item ->
            val key = item.key as? String ?: return@firstOrNull false
            key != dragged.key && middle in item.offset..(item.offset + item.size) && canMove(dragged.key as String, key)
        }
        if (target != null) {
            // Keep the list where it is when the first visible item moves (it would otherwise follow that item).
            if (dragged.index == list.firstVisibleItemIndex || target.index == list.firstVisibleItemIndex) {
                list.requestScrollToItem(list.firstVisibleItemIndex, list.firstVisibleItemScrollOffset)
            }
            layoutAtMove = layout
            onMove(dragged.key as String, target.key as String)
        } else {
            val overscroll = when {
                delta > 0 -> (bottom - layout.viewportEndOffset).coerceAtLeast(0f)
                delta < 0 -> (top - layout.viewportStartOffset).coerceAtMost(0f)
                else -> 0f
            }
            if (overscroll != 0f) scrollRequests.trySend(overscroll)
        }
    }

    fun end() {
        draggingKey = null
        delta = 0f
        initialOffset = 0
        layoutAtMove = null
    }

    companion object {
        fun headerKey(projectKey: String) = "h:$projectKey"

        fun rowKey(sessionDocId: String) = "r:$sessionDocId"
    }
}

/** The sections with a drag's working order applied: projects in [projectOrder], one project's sessions in [sessionOrder]. */
internal fun arrangeSections(
    sections: List<SessionSection>,
    projectOrder: List<String>?,
    sessionOrder: Pair<String, List<String>>?,
): List<SessionSection> {
    val ordered = if (projectOrder != null) SessionList.freeze(projectOrder, sections) { it.key } else sections
    if (sessionOrder == null) return ordered
    return ordered.map { section ->
        if (section.key == sessionOrder.first) section.copy(rows = SessionList.freezeOrder(sessionOrder.second, section.rows)) else section
    }
}

private fun <T> List<T>.moved(from: Int, to: Int): List<T> = toMutableList().apply { add(to, removeAt(from)) }

/**
 * Reorder mode, in two levels on one screen so that nothing changes size under a drag: every project shows as its
 * header with a drag handle (projects move among the tab's projects); tapping one opens it, and then its sessions have
 * the handles instead (they move within the project, pinned ones among the pinned). A drop sends the new order once;
 * the engine shows it at once.
 */
@Composable
internal fun ReorderList(state: SessionsUiState, actions: SessionsActions) {
    val listState = rememberLazyListState()
    var projectOrder by remember { mutableStateOf<List<String>?>(null) }
    var sessionOrder by remember { mutableStateOf<Pair<String, List<String>>?>(null) }
    val sections = remember(state.sections, projectOrder, sessionOrder) { arrangeSections(state.sections, projectOrder, sessionOrder) }
    val open = state.reorderProject
    // The handles' gesture code outlives compositions: it reads the newest of these, never a captured copy.
    val latestSections by rememberUpdatedState(sections)
    val latestState by rememberUpdatedState(state)
    val latestActions by rememberUpdatedState(actions)

    fun sectionOfRow(id: String): SessionSection? = latestSections.firstOrNull { section -> section.rows.any { it.id == id } }

    val drag = remember(listState) {
        ReorderDragState(
            list = listState,
            canMove = { from, to ->
                when {
                    from.startsWith("h:") && to.startsWith("h:") -> true
                    from.startsWith("r:") && to.startsWith("r:") -> {
                        val a = from.removePrefix("r:")
                        val b = to.removePrefix("r:")
                        val section = sectionOfRow(a)
                        val rowA = section?.rows?.firstOrNull { it.id == a }
                        val rowB = section?.rows?.firstOrNull { it.id == b }
                        rowA != null && rowB != null && SessionOrder.canSwap(rowA, rowB)
                    }
                    else -> false
                }
            },
            onMove = { from, to ->
                if (from.startsWith("h:")) {
                    val keys = latestSections.map { it.key }
                    val i = keys.indexOf(from.removePrefix("h:"))
                    val j = keys.indexOf(to.removePrefix("h:"))
                    if (i >= 0 && j >= 0) projectOrder = keys.moved(i, j)
                } else {
                    val a = from.removePrefix("r:")
                    val section = sectionOfRow(a)
                    if (section != null) {
                        val ids = section.rows.map { it.id }
                        val i = ids.indexOf(a)
                        val j = ids.indexOf(to.removePrefix("r:"))
                        if (i >= 0 && j >= 0) sessionOrder = section.key to ids.moved(i, j)
                    }
                }
            },
        )
    }

    fun startDrag(key: String) {
        if (drag.draggingKey != null) return
        // The list holds still (no re-sorting from the relay) while a finger moves something in it.
        latestActions.onDragging(true)
        if (!drag.start(key)) latestActions.onDragging(false)
    }

    fun endDrag() {
        if (drag.draggingKey == null) return
        drag.end()
        val original = SessionList.orderOf(latestState.sections)
        projectOrder?.let { order ->
            if (order != original.projects) latestActions.onReorderProjects(order) else projectOrder = null
        }
        sessionOrder?.let { (projectKey, ids) ->
            if (ids != original.sessions[projectKey]) latestActions.onReorderSessions(projectKey, ids) else sessionOrder = null
        }
        latestActions.onDragging(false)
    }

    // The working order is dropped once the list itself shows the change (or anything else changed it).
    val stateOrder = remember(state.sections) { SessionList.orderOf(state.sections) }
    LaunchedEffect(stateOrder) {
        if (drag.draggingKey == null) {
            projectOrder = null
            sessionOrder = null
        }
    }
    LaunchedEffect(drag) {
        for (diff in drag.scrollRequests) {
            listState.scrollBy(diff)
            drag.drag(0f)
        }
    }

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize().testTag("reorder-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
        item(key = "hint", contentType = "hint") { ReorderHint() }
        sections.forEachIndexed { index, section ->
            val headerKey = ReorderDragState.headerKey(section.key)
            val isOpen = section.key == open
            item(key = headerKey, contentType = "header") {
                DraggableItem(drag, headerKey) { dragging ->
                    ReorderHeader(
                        section = section,
                        showComputer = state.showComputer,
                        open = isOpen,
                        dragging = dragging,
                        // Projects move while none is open; an open one shows its sessions' handles instead.
                        handle = if (open == null) DragHandle(headerKey, drag, ::startDrag, ::endDrag) else null,
                        onToggle = { actions.onReorderProject(if (isOpen) null else section.key) },
                        onMoveUp = if (index > 0) ({ actions.onMoveProject(section.key, -1) }) else null,
                        onMoveDown = if (index < sections.lastIndex) ({ actions.onMoveProject(section.key, 1) }) else null,
                    )
                }
            }
            if (isOpen) {
                items(section.rows, key = { ReorderDragState.rowKey(it.id) }, contentType = { "session" }) { row ->
                    val rowKey = ReorderDragState.rowKey(row.id)
                    val moves = RowMoves.of(section.rows, row)
                    DraggableItem(drag, rowKey) { dragging ->
                        ReorderRow(
                            row = row,
                            projectName = section.group.name,
                            now = state.now,
                            dragging = dragging,
                            handle = DragHandle(rowKey, drag, ::startDrag, ::endDrag),
                            onMoveUp = if (moves.up) ({ actions.onMoveSession(row, -1) }) else null,
                            onMoveDown = if (moves.down) ({ actions.onMoveSession(row, 1) }) else null,
                        )
                    }
                }
            }
        }
    }
}

/** A drag handle's item ([key], also its test tag) and what its gesture drives. */
private class DragHandle(
    val key: String,
    val drag: ReorderDragState,
    val onStart: (String) -> Unit,
    val onEnd: () -> Unit,
)

private fun Modifier.dragGesture(handle: DragHandle): Modifier =
    pointerInput(handle.key, handle.drag) {
        detectVerticalDragGestures(
            onDragStart = { handle.onStart(handle.key) },
            onDragEnd = handle.onEnd,
            onDragCancel = handle.onEnd,
            onVerticalDrag = { change, amount ->
                change.consume()
                handle.drag.drag(amount)
            },
        )
    }

@Composable
private fun LazyItemScope.DraggableItem(drag: ReorderDragState, key: String, content: @Composable (dragging: Boolean) -> Unit) {
    val dragging = drag.draggingKey == key
    val modifier = if (dragging) {
        Modifier
            .zIndex(1f)
            .graphicsLayer {
                translationY = drag.offset
                shadowElevation = 8.dp.toPx()
            }
    } else {
        Modifier.animateItem()
    }
    Box(modifier) { content(dragging) }
}

@Composable
private fun ReorderHint() {
    Text(
        stringResource(R.string.sessions_reorder_hint),
        fontSize = 13.sp,
        color = CrokTheme.colors.textSecondary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/** Move up / Move down for TalkBack on a drag handle (a drag is hard without sight). */
private fun Modifier.moveActions(up: String, down: String, onMoveUp: (() -> Unit)?, onMoveDown: (() -> Unit)?): Modifier =
    semantics {
        customActions = listOfNotNull(
            onMoveUp?.let { move -> CustomAccessibilityAction(up) { move(); true } },
            onMoveDown?.let { move -> CustomAccessibilityAction(down) { move(); true } },
        )
    }

@Composable
private fun Handle(handle: DragHandle, onMoveUp: (() -> Unit)?, onMoveDown: (() -> Unit)?) {
    val label = stringResource(R.string.cd_drag_to_reorder)
    val up = stringResource(R.string.action_move_up)
    val down = stringResource(R.string.action_move_down)
    Box(
        Modifier
            .size(48.dp)
            .testTag(handle.key)
            .dragGesture(handle)
            // Its own node for TalkBack (with Move up / Move down), not part of the header's click.
            .semantics(mergeDescendants = true) { contentDescription = label }
            .moveActions(up, down, onMoveUp, onMoveDown),
        contentAlignment = Alignment.Center,
    ) {
        Icon(CrokIcons.DragHandle, contentDescription = null, tint = CrokTheme.colors.textTertiary)
    }
}

@Composable
private fun ReorderHeader(
    section: SessionSection,
    showComputer: Boolean,
    open: Boolean,
    dragging: Boolean,
    handle: DragHandle?,
    onToggle: () -> Unit,
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
) {
    val colors = CrokTheme.colors
    val toggleLabel = stringResource(if (open) R.string.action_collapse else R.string.action_expand)
    Column(Modifier.fillMaxWidth().background(if (dragging) colors.card else colors.grouped)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClickLabel = toggleLabel, onClick = onToggle)
                .heightIn(min = 52.dp)
                .padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProjectTitle(section, showComputer, Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            val countLabel = pluralStringResource(R.plurals.sessions_count, section.count, section.count)
            Text(
                section.count.toString(),
                fontSize = 13.sp,
                color = colors.textTertiary,
                modifier = Modifier.semantics { contentDescription = countLabel },
            )
            Spacer(Modifier.width(4.dp))
            Icon(
                if (open) CrokIcons.ExpandMore else CrokIcons.ChevronRight,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(20.dp),
            )
            if (handle != null) {
                Handle(handle, onMoveUp, onMoveDown)
            } else {
                Spacer(Modifier.width(12.dp))
            }
        }
        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
    }
}

@Composable
private fun ReorderRow(
    row: SessionRow,
    projectName: String,
    now: Long,
    dragging: Boolean,
    handle: DragHandle,
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val folder = SessionList.folderName(row.cwd)
    val effectiveNow = if (now > 0) now else System.currentTimeMillis()
    val time = formatter.listTime(RelativeTime.listTime(row.lastActivityAt, effectiveNow, formatter.zone))
    val detail = listOfNotNull(SessionList.folderLine(row, projectName), time).joinToString(" · ")
    Column(Modifier.fillMaxWidth().background(if (dragging) colors.card else colors.screen)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            InitialsAvatar(folder, key = folder, size = 40.dp, dimmed = !row.online, online = row.online)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    row.title.ifBlank { folder },
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (row.online) colors.textPrimary else colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(detail, fontSize = 13.sp, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (row.pinned) {
                Icon(
                    CrokIcons.Pin,
                    contentDescription = stringResource(R.string.cd_pinned),
                    tint = colors.textTertiary,
                    modifier = Modifier.size(18.dp).rotate(45f),
                )
            }
            Handle(handle, onMoveUp, onMoveDown)
        }
        HorizontalDivider(Modifier.padding(start = 68.dp), color = colors.divider, thickness = 0.5.dp)
    }
}
