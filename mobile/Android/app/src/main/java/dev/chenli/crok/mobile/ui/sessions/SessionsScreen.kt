package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.logic.SessionSection
import dev.chenli.crok.mobile.ui.common.ConnectionTitle
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.InitialsAvatar
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.launch

/** What the session list can ask its host to do. */
data class SessionsActions(
    val onOpen: (SessionRow) -> Unit = {},
    val onFilter: (SessionFilter) -> Unit = {},
    val onQuery: (String) -> Unit = {},
    val onSwiping: (Boolean) -> Unit = {},
    val onTogglePin: (SessionRow) -> Unit = {},
    val onToggleArchive: (SessionRow) -> Unit = {},
    val onStop: (SessionRow) -> Unit = {},
    val onLinkComputer: () -> Unit = {},
    val onToggleCollapsed: (projectKey: String) -> Unit = {},
    val onToggleExpanded: (projectKey: String) -> Unit = {},
    val onReordering: (Boolean) -> Unit = {},
    /** Reorder mode: open a project to move its sessions (null closes it). */
    val onReorderProject: (projectKey: String?) -> Unit = {},
    val onDragging: (Boolean) -> Unit = {},
    val onMoveProject: (projectKey: String, delta: Int) -> Unit = { _, _ -> },
    val onMoveSession: (SessionRow, delta: Int) -> Unit = { _, _ -> },
    val onReorderProjects: (keys: List<String>) -> Unit = {},
    val onReorderSessions: (projectKey: String, sessionDocIds: List<String>) -> Unit = { _, _ -> },
    val onSortProjectsByRecent: () -> Unit = {},
    val onSortSessionsByRecent: (projectKey: String) -> Unit = {},
)

@Composable
fun SessionsScreen(viewModel: SessionsViewModel, onOpen: (SessionRow) -> Unit, onLinkComputer: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is SessionsEvent.Archived -> {
                    val result = snackbar.showSnackbar(
                        resources.getString(R.string.sessions_archived_snackbar),
                        actionLabel = resources.getString(R.string.action_undo),
                        withDismissAction = false,
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.unarchive(event.sessionDocId)
                }
                is SessionsEvent.Failed -> snackbar.showSnackbar(resources.getString(R.string.sessions_action_failed, event.message))
            }
        }
    }
    SessionsContent(
        state = state,
        snackbar = snackbar,
        actions = SessionsActions(
            onOpen = onOpen,
            onFilter = viewModel::setFilter,
            onQuery = viewModel::setQuery,
            onSwiping = viewModel::setSwiping,
            onTogglePin = viewModel::togglePin,
            onToggleArchive = viewModel::toggleArchive,
            onStop = viewModel::stop,
            onLinkComputer = onLinkComputer,
            onToggleCollapsed = viewModel::toggleCollapsed,
            onToggleExpanded = viewModel::toggleExpanded,
            onReordering = viewModel::setReordering,
            onReorderProject = viewModel::setReorderProject,
            onDragging = viewModel::setDragging,
            onMoveProject = viewModel::moveProject,
            onMoveSession = viewModel::moveSession,
            onReorderProjects = viewModel::reorderProjects,
            onReorderSessions = viewModel::reorderSessions,
            onSortProjectsByRecent = viewModel::sortProjectsByRecent,
            onSortSessionsByRecent = viewModel::sortSessionsByRecent,
        ),
    )
}

@Composable
fun SessionsContent(
    state: SessionsUiState,
    actions: SessionsActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
) {
    val colors = CrokTheme.colors
    var searching by rememberSaveable { mutableStateOf(state.query.isNotEmpty()) }
    val swipingRows = remember { mutableStateOf(emptySet<String>()) }
    val onSwiping: (String, Boolean) -> Unit = { id, active ->
        val next = if (active) swipingRows.value + id else swipingRows.value - id
        if (next != swipingRows.value) {
            swipingRows.value = next
            actions.onSwiping(next.isNotEmpty())
        }
    }

    Scaffold(
        containerColor = colors.screen,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column(Modifier.background(colors.bar)) {
                when {
                    state.reordering -> ReorderTopBar(actions)
                    searching -> SearchBar(
                        query = state.query,
                        onQuery = actions.onQuery,
                        onClose = {
                            searching = false
                            actions.onQuery("")
                        },
                    )
                    else -> ListTopBar(
                        state = state,
                        onSearch = {
                            actions.onReordering(false)
                            searching = true
                        },
                        actions = actions,
                    )
                }
                FilterTabs(state, actions.onFilter)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.loading -> CircularProgressIndicator(Modifier.align(Alignment.Center), color = colors.accent)
                state.isEmpty -> EmptyState(state, actions.onLinkComputer)
                state.reordering -> ReorderList(state, actions)
                state.grouped -> GroupedList(state, actions, onSwiping)
                else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 8.dp)) {
                    items(state.rows, key = { it.id }, contentType = { "session" }) { row ->
                        SwipeableSessionRow(
                            row = row,
                            now = state.now,
                            actions = actions,
                            onSwiping = { onSwiping(row.id, it) },
                            modifier = Modifier.animateItem(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ListTopBar(state: SessionsUiState, onSearch: () -> Unit, actions: SessionsActions) {
    var menu by remember { mutableStateOf(false) }
    TopAppBar(
        title = { ConnectionTitle(state.connection, stringResource(R.string.sessions_title)) },
        actions = {
            IconButton(onClick = onSearch) {
                Icon(CrokIcons.Search, contentDescription = stringResource(R.string.sessions_search))
            }
            if (state.canReorder) {
                IconButton(onClick = { actions.onReordering(true) }, modifier = Modifier.testTag("reorder")) {
                    Icon(CrokIcons.Reorder, contentDescription = stringResource(R.string.sessions_reorder))
                }
                Box {
                    IconButton(onClick = { menu = true }) {
                        Icon(CrokIcons.MoreVert, contentDescription = stringResource(R.string.cd_more_options))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.sessions_sort_projects_recent)) },
                            leadingIcon = { Icon(CrokIcons.Clock, contentDescription = null) },
                            onClick = {
                                menu = false
                                actions.onSortProjectsByRecent()
                            },
                        )
                    }
                }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = CrokTheme.colors.bar),
    )
}

@Composable
private fun ReorderTopBar(actions: SessionsActions) {
    val colors = CrokTheme.colors
    var menu by remember { mutableStateOf(false) }
    TopAppBar(
        navigationIcon = {
            IconButton(onClick = { actions.onReordering(false) }) {
                Icon(CrokIcons.Close, contentDescription = stringResource(R.string.action_done))
            }
        },
        title = { Text(stringResource(R.string.sessions_reorder), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        actions = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(CrokIcons.MoreVert, contentDescription = stringResource(R.string.cd_more_options))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_sort_projects_recent)) },
                        leadingIcon = { Icon(CrokIcons.Clock, contentDescription = null) },
                        onClick = {
                            menu = false
                            actions.onSortProjectsByRecent()
                        },
                    )
                }
            }
            TextButton(onClick = { actions.onReordering(false) }, modifier = Modifier.testTag("reorder-done")) {
                Text(stringResource(R.string.action_done), color = colors.accent, fontWeight = FontWeight.SemiBold)
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.bar),
    )
}

@Composable
private fun SearchBar(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    TopAppBar(
        navigationIcon = {
            IconButton(onClick = onClose) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
        },
        title = {
            TextField(
                value = query,
                onValueChange = onQuery,
                placeholder = { Text(stringResource(R.string.sessions_search_hint)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
        },
        actions = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) { Icon(CrokIcons.Close, contentDescription = stringResource(R.string.cd_clear)) }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = CrokTheme.colors.bar),
    )
}

/** All · one tab per computer · Archived (Telegram's folder tabs). */
@Composable
private fun FilterTabs(state: SessionsUiState, onFilter: (SessionFilter) -> Unit) {
    val colors = CrokTheme.colors
    val filters = buildList {
        add(SessionFilter.All to stringResource(R.string.filter_all))
        state.tabs.forEach { add(SessionFilter.Computer(it.deviceId) to it.name) }
        // Reorder mode moves projects, which the flat Archived tab has none of.
        if (!state.reordering) add(SessionFilter.Archived to stringResource(R.string.filter_archived))
    }
    val selected = filters.indexOfFirst { it.first == state.filter }.coerceAtLeast(0)
    PrimaryScrollableTabRow(
        selectedTabIndex = selected,
        containerColor = colors.bar,
        contentColor = colors.accent,
        edgePadding = 8.dp,
        minTabWidth = 64.dp,
        divider = { HorizontalDivider(color = colors.divider) },
    ) {
        filters.forEachIndexed { index, (filter, label) ->
            Tab(
                selected = index == selected,
                onClick = { onFilter(filter) },
                selectedContentColor = colors.accent,
                unselectedContentColor = colors.textSecondary,
                text = { Text(label, maxLines = 1, fontWeight = if (index == selected) FontWeight.SemiBold else FontWeight.Normal) },
            )
        }
    }
}

@Composable
private fun EmptyState(state: SessionsUiState, onLinkComputer: () -> Unit) {
    val colors = CrokTheme.colors
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            state.query.isNotBlank() -> Text(stringResource(R.string.sessions_no_results), color = colors.textSecondary)
            state.filter == SessionFilter.Archived -> {
                IconBadge(CrokIcons.Archive, colors.textSecondary, size = 72.dp)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.sessions_archived_empty), color = colors.textSecondary, textAlign = TextAlign.Center)
            }
            else -> {
                IconBadge(CrokIcons.Laptop, colors.accent, size = 88.dp)
                Spacer(Modifier.height(20.dp))
                Text(
                    stringResource(R.string.sessions_empty_title),
                    style = MaterialTheme.typography.titleLarge,
                    color = colors.textPrimary,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.sessions_empty_body),
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.widthIn(max = 360.dp),
                )
                Spacer(Modifier.height(20.dp))
                Button(
                    onClick = onLinkComputer,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
                ) {
                    Icon(CrokIcons.QrCode, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.sessions_link_computer))
                }
            }
        }
    }
}

/** The main list: one section per project (header, its first sessions, "Show N more"). */
@Composable
private fun GroupedList(state: SessionsUiState, actions: SessionsActions, onSwiping: (String, Boolean) -> Unit) {
    LazyColumn(Modifier.fillMaxSize().testTag("sessions-list"), contentPadding = PaddingValues(bottom = 8.dp)) {
        state.sections.forEachIndexed { index, section ->
            item(key = "h:${section.key}", contentType = "header") {
                ProjectHeader(
                    section = section,
                    showComputer = state.showComputer,
                    canMoveUp = state.canReorder && index > 0,
                    canMoveDown = state.canReorder && index < state.sections.lastIndex,
                    canSort = !state.searching,
                    actions = actions,
                    modifier = Modifier.animateItem(),
                )
            }
            items(section.visibleRows, key = { "r:${it.id}" }, contentType = { "session" }) { row ->
                SwipeableSessionRow(
                    row = row,
                    now = state.now,
                    actions = actions,
                    projectName = section.group.name.ifBlank { SessionList.projectName(row) },
                    moves = if (state.searching) RowMoves.None else RowMoves.of(section.rows, row),
                    onSwiping = { onSwiping(row.id, it) },
                    modifier = Modifier.animateItem(),
                )
            }
            if (section.hiddenCount > 0 || section.canShowLess) {
                item(key = "m:${section.key}", contentType = "more") {
                    ShowMoreRow(section, onClick = { actions.onToggleExpanded(section.key) }, modifier = Modifier.animateItem())
                }
            }
        }
    }
}

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
 * A project's header: folder icon, name, on All the computer (muted, with its online dot), the session count and a
 * chevron. Tap collapses; a long press opens Move up / Move down / Sort by recent activity.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectHeader(
    section: SessionSection,
    showComputer: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    canSort: Boolean,
    actions: SessionsActions,
    modifier: Modifier = Modifier,
) {
    val colors = CrokTheme.colors
    var menu by remember { mutableStateOf(false) }
    val hasMenu = canMoveUp || canMoveDown || canSort
    val collapsed = section.isCollapsed
    val toggleLabel = stringResource(if (collapsed) R.string.action_expand else R.string.action_collapse)
    Box(modifier.fillMaxWidth().background(colors.grouped)) {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    enabled = !section.searching,
                    onClickLabel = toggleLabel,
                    onClick = { actions.onToggleCollapsed(section.key) },
                    onLongClick = if (hasMenu) ({ menu = true }) else null,
                )
                .heightIn(min = 48.dp)
                .padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = 8.dp),
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
            if (!section.searching) {
                Spacer(Modifier.width(4.dp))
                Icon(
                    if (collapsed) CrokIcons.ChevronRight else CrokIcons.ExpandMore,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (canMoveUp) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_move_up)) },
                    leadingIcon = { Icon(CrokIcons.ArrowUp, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onMoveProject(section.key, -1)
                    },
                )
            }
            if (canMoveDown) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_move_down)) },
                    leadingIcon = { Icon(CrokIcons.ArrowDown, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onMoveProject(section.key, 1)
                    },
                )
            }
            if (canSort) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sessions_sort_recent)) },
                    leadingIcon = { Icon(CrokIcons.Clock, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onSortSessionsByRecent(section.key)
                    },
                )
            }
        }
    }
}

/** Folder icon, project name and (on All) "computer ●". Shared by the list and Reorder mode. */
@Composable
internal fun ProjectTitle(section: SessionSection, showComputer: Boolean, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val group = section.group
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(CrokIcons.Folder, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            group.name.ifBlank { SessionList.folderName(group.path) },
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (showComputer) {
            Spacer(Modifier.width(10.dp))
            val onlineLabel = stringResource(R.string.cd_online)
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(if (group.deviceOnline) colors.online else colors.badgeMuted)
                    .then(if (group.deviceOnline) Modifier.semantics { contentDescription = onlineLabel } else Modifier),
            )
            Spacer(Modifier.width(5.dp))
            Text(
                group.deviceName,
                fontSize = 13.sp,
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
    }
}

@Composable
private fun ShowMoreRow(section: SessionSection, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    Column(modifier.fillMaxWidth().background(colors.screen)) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 44.dp).padding(start = 78.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (section.hiddenCount > 0) {
                    pluralStringResource(R.plurals.sessions_show_more, section.hiddenCount, section.hiddenCount)
                } else {
                    stringResource(R.string.sessions_show_less)
                },
                color = colors.accent,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.width(4.dp))
            Icon(
                if (section.hiddenCount > 0) CrokIcons.ExpandMore else CrokIcons.ExpandLess,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )
        }
        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)
    }
}

@Composable
private fun SwipeableSessionRow(
    row: SessionRow,
    now: Long,
    actions: SessionsActions,
    onSwiping: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    projectName: String? = null,
    moves: RowMoves = RowMoves.None,
) {
    val colors = CrokTheme.colors
    val scope = rememberCoroutineScope()
    val dismiss = rememberSwipeToDismissBoxState(positionalThreshold = { distance -> distance * 0.3f })
    LaunchedEffect(dismiss) {
        snapshotFlow { dismiss.dismissDirection != SwipeToDismissBoxValue.Settled }.collect(onSwiping)
    }
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier,
        backgroundContent = {
            val direction = dismiss.dismissDirection
            val (background, icon, label, alignment) = when (direction) {
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
            Box(Modifier.fillMaxSize().background(background).padding(horizontal = 24.dp), contentAlignment = alignment) {
                if (icon != null) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(icon, contentDescription = null, tint = Color.White)
                        Text(label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }
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
        SessionRowItem(row, now, actions, projectName = projectName, moves = moves)
    }
}

private data class SwipeVisual(
    val background: Color,
    val icon: ImageVector?,
    val label: String,
    val alignment: Alignment,
)

/**
 * Telegram's DialogCell, for a session: avatar, title and time, a second line, preview or state, badge. Under a
 * project header ([projectName] set) the second line is the session's own folder, and only when that differs from the
 * project's name; in a flat list it is "computer · folder".
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionRowItem(
    row: SessionRow,
    now: Long,
    actions: SessionsActions,
    modifier: Modifier = Modifier,
    projectName: String? = null,
    moves: RowMoves = RowMoves.None,
) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var menu by remember { mutableStateOf(false) }
    val folder = SessionList.folderName(row.cwd)
    val dimmed = !row.online
    val effectiveNow = if (now > 0) now else System.currentTimeMillis()
    val time = formatter.listTime(RelativeTime.listTime(row.lastActivityAt, effectiveNow, formatter.zone))
    val secondLine = if (projectName != null) SessionList.folderLine(row, projectName) else "${row.deviceName} · $folder"

    Box(modifier.background(colors.screen)) {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = { actions.onOpen(row) }, onLongClick = { menu = true }),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 80.dp).padding(start = 12.dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                InitialsAvatar(folder, key = folder, size = 54.dp, dimmed = dimmed, online = row.online)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            row.title.ifBlank { folder },
                            style = MaterialTheme.typography.titleMedium,
                            fontSize = 16.sp,
                            color = if (dimmed) colors.textSecondary else colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(time, fontSize = 13.sp, color = if (row.unread > 0 && !dimmed) colors.accent else colors.textTertiary)
                    }
                    if (secondLine != null) {
                        Text(
                            secondLine,
                            fontSize = 13.sp,
                            color = colors.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) {
                            when {
                                row.isWaiting -> NeedsApprovalChip()
                                row.isRunning -> WorkingDots(stringResource(R.string.sessions_working), colors.accent)
                                else -> Preview(row, dimmed)
                            }
                        }
                        if (row.unread > 0) {
                            Spacer(Modifier.width(8.dp))
                            UnreadBadge(row.unread, muted = dimmed)
                        } else if (row.pinned) {
                            Spacer(Modifier.width(8.dp))
                            val pinned = stringResource(R.string.cd_pinned)
                            Icon(
                                CrokIcons.Pin,
                                contentDescription = pinned,
                                tint = colors.textTertiary,
                                modifier = Modifier.size(18.dp).rotate(45f),
                            )
                        }
                    }
                }
            }
            HorizontalDivider(Modifier.padding(start = 78.dp), color = colors.divider, thickness = 0.5.dp)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
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
            if (!row.archived) {
                DropdownMenuItem(
                    text = { Text(stringResource(if (row.pinned) R.string.action_unpin else R.string.action_pin)) },
                    leadingIcon = { Icon(CrokIcons.Pin, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onTogglePin(row)
                    },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(if (row.archived) R.string.action_unarchive else R.string.action_archive)) },
                leadingIcon = { Icon(if (row.archived) CrokIcons.Unarchive else CrokIcons.Archive, contentDescription = null) },
                onClick = {
                    menu = false
                    actions.onToggleArchive(row)
                },
            )
            if (moves.up) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_move_up)) },
                    leadingIcon = { Icon(CrokIcons.ArrowUp, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onMoveSession(row, -1)
                    },
                )
            }
            if (moves.down) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_move_down)) },
                    leadingIcon = { Icon(CrokIcons.ArrowDown, contentDescription = null) },
                    onClick = {
                        menu = false
                        actions.onMoveSession(row, 1)
                    },
                )
            }
        }
    }
}

@Composable
private fun Preview(row: SessionRow, dimmed: Boolean) {
    val colors = CrokTheme.colors
    val preview = row.preview?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
    val you = stringResource(R.string.sessions_you)
    val text = buildAnnotatedString {
        if (row.previewKind == EventKind.USER && preview.isNotEmpty()) {
            withStyle(SpanStyle(color = if (dimmed) colors.textSecondary else colors.textPrimary)) { append(you) }
        }
        append(preview)
    }
    Text(
        text,
        fontSize = 14.sp,
        color = colors.textSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun NeedsApprovalChip() {
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
