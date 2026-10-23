package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.background
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
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.ForumAvatar
import dev.chenli.crok.mobile.ui.common.TopicIcon
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

private fun <T> List<T>.moved(from: Int, to: Int): List<T> = toMutableList().apply { add(to, removeAt(from)) }

/**
 * The Sessions tab in Edit mode (mobile/DESIGN.md): every project of the computer with a drag handle. A drop sends the
 * new order once; the engine shows it at once.
 */
@Composable
internal fun ProjectReorderList(
    projects: List<SessionGroup>,
    onReorder: (keys: List<String>) -> Unit,
    onMove: (projectKey: String, delta: Int) -> Unit,
    onDragging: (Boolean) -> Unit,
    contentPadding: PaddingValues,
) {
    val byKey = remember(projects) { projects.associateBy { ReorderDragState.headerKey(it.key) } }
    ReorderColumn(
        keys = remember(projects) { projects.map { ReorderDragState.headerKey(it.key) } },
        canMove = { _, _ -> true },
        onDrop = { order -> onReorder(order.map { it.removePrefix("h:") }) },
        hint = stringResource(R.string.sessions_reorder_hint_projects),
        onDragging = onDragging,
        contentPadding = contentPadding,
    ) { key, dragging, handle ->
        val group = byKey[key]
        if (group != null) {
            val index = projects.indexOf(group)
            val name = group.name.ifBlank { SessionList.folderName(group.path) }
            ReorderLine(
                dragging = dragging,
                leading = { ForumAvatar(name, 44.dp, dimmed = !group.deviceOnline) },
                title = name,
                detail = pluralStringResource(R.plurals.sessions_count, group.sessions.size, group.sessions.size),
                handle = handle,
                onMoveUp = if (index > 0) ({ onMove(group.key, -1) }) else null,
                onMoveDown = if (index < projects.lastIndex) ({ onMove(group.key, 1) }) else null,
            )
        }
    }
}

/** A project's Reorder mode: its sessions with drag handles, pinned ones among the pinned. */
@Composable
internal fun TopicReorderList(
    rows: List<SessionRow>,
    now: Long,
    onReorder: (sessionDocIds: List<String>) -> Unit,
    onMove: (SessionRow, delta: Int) -> Unit,
    onDragging: (Boolean) -> Unit,
    contentPadding: PaddingValues,
) {
    val formatter = rememberFormatter()
    val byKey = remember(rows) { rows.associateBy { ReorderDragState.rowKey(it.id) } }
    ReorderColumn(
        keys = remember(rows) { rows.map { ReorderDragState.rowKey(it.id) } },
        canMove = { from, to ->
            val a = byKey[from]
            val b = byKey[to]
            a != null && b != null && SessionOrder.canSwap(a, b)
        },
        onDrop = { order -> onReorder(order.map { it.removePrefix("r:") }) },
        hint = stringResource(R.string.sessions_reorder_hint_sessions),
        onDragging = onDragging,
        contentPadding = contentPadding,
    ) { key, dragging, handle ->
        val row = byKey[key]
        if (row != null) {
            val moves = RowMoves.of(rows, row)
            val title = row.title.ifBlank { SessionList.folderName(row.cwd) }
            val effectiveNow = if (now > 0) now else System.currentTimeMillis()
            ReorderLine(
                dragging = dragging,
                leading = { TopicIcon(title, row.id, 36.dp, dimmed = !row.reachable) },
                title = title,
                detail = formatter.listTime(RelativeTime.listTime(row.lastActivityAt, effectiveNow, formatter.zone)),
                pinned = row.pinned,
                handle = handle,
                onMoveUp = if (moves.up) ({ onMove(row, -1) }) else null,
                onMoveDown = if (moves.down) ({ onMove(row, 1) }) else null,
            )
        }
    }
}

/**
 * A column of [keys] whose items move by their handles: the working order follows the finger, [onDrop] gets it once
 * the finger lets go (if it changed), and it is dropped again when the list itself changes.
 */
@Composable
private fun ReorderColumn(
    keys: List<String>,
    canMove: (from: String, to: String) -> Boolean,
    onDrop: (List<String>) -> Unit,
    onDragging: (Boolean) -> Unit,
    hint: String,
    contentPadding: PaddingValues,
    item: @Composable (key: String, dragging: Boolean, handle: DragHandle) -> Unit,
) {
    val listState = rememberLazyListState()
    var order by remember { mutableStateOf<List<String>?>(null) }
    val shown = order ?: keys
    // The handles' gesture code outlives compositions: it reads the newest of these, never a captured copy.
    val latestShown by rememberUpdatedState(shown)
    val latestKeys by rememberUpdatedState(keys)
    val latestDrop by rememberUpdatedState(onDrop)
    val latestDragging by rememberUpdatedState(onDragging)
    val latestCanMove by rememberUpdatedState(canMove)
    val drag = remember(listState) {
        ReorderDragState(
            list = listState,
            canMove = { from, to -> latestCanMove(from, to) },
            onMove = { from, to ->
                val current = latestShown
                val i = current.indexOf(from)
                val j = current.indexOf(to)
                if (i >= 0 && j >= 0) order = current.moved(i, j)
            },
        )
    }

    fun startDrag(key: String) {
        if (drag.draggingKey != null) return
        // The list holds still (no re-sorting from the relay) while a finger moves something in it.
        latestDragging(true)
        if (!drag.start(key)) latestDragging(false)
    }

    fun endDrag() {
        if (drag.draggingKey == null) return
        drag.end()
        order?.let { if (it != latestKeys) latestDrop(it) else order = null }
        latestDragging(false)
    }

    // The working order is dropped once the list itself shows the change (or anything else changed it).
    LaunchedEffect(keys) { if (drag.draggingKey == null) order = null }
    LaunchedEffect(drag) {
        for (diff in drag.scrollRequests) {
            listState.scrollBy(diff)
            drag.drag(0f)
        }
    }
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().testTag("reorder-list"),
        contentPadding = PaddingValues(top = contentPadding.calculateTopPadding(), bottom = contentPadding.calculateBottomPadding() + 16.dp),
    ) {
        item(key = "hint", contentType = "hint") {
            Text(
                hint,
                fontSize = 13.sp,
                color = CrokTheme.colors.textSecondary,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
        items(shown, key = { it }, contentType = { "item" }) { key ->
            DraggableItem(drag, key) { dragging -> item(key, dragging, DragHandle(key, drag, ::startDrag, ::endDrag)) }
        }
    }
}

/** A drag handle's item ([key], also its test tag) and what its gesture drives. */
internal class DragHandle(
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
            // Its own node for TalkBack (with Move up / Move down).
            .semantics(mergeDescendants = true) { contentDescription = label }
            .moveActions(up, down, onMoveUp, onMoveDown),
        contentAlignment = Alignment.Center,
    ) {
        Icon(CrokIcons.DragHandle, contentDescription = null, tint = CrokTheme.colors.textTertiary)
    }
}

/** One line of a reorder list: avatar, title and a detail, a pin, the handle. */
@Composable
private fun ReorderLine(
    dragging: Boolean,
    leading: @Composable () -> Unit,
    title: String,
    detail: String,
    handle: DragHandle,
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
    pinned: Boolean = false,
) {
    val colors = CrokTheme.colors
    Column(Modifier.fillMaxWidth().background(if (dragging) colors.card else colors.screen)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(start = 14.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            leading()
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(detail, fontSize = 13.sp, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (pinned) {
                Icon(
                    CrokIcons.Pin,
                    contentDescription = stringResource(R.string.cd_pinned),
                    tint = colors.textTertiary,
                    modifier = Modifier.size(18.dp).rotate(45f),
                )
            }
            Handle(handle, onMoveUp, onMoveDown)
        }
        HorizontalDivider(Modifier.padding(start = 70.dp), color = colors.divider, thickness = 0.5.dp)
    }
}

