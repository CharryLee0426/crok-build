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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
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
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.logic.Forum
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.ForumAvatar
import dev.chenli.crok.mobile.ui.common.GlassMenuOverlay
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.GlassShapes
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.ReplaceTabBar
import dev.chenli.crok.mobile.ui.common.TopicIcon
import dev.chenli.crok.mobile.ui.common.WorkingDots
import dev.chenli.crok.mobile.ui.common.connectionText
import dev.chenli.crok.mobile.ui.common.glass
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.session.NewSessionTarget
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.launch

/** What the Sessions tab can ask its host to do. */
data class SessionsActions(
    val onOpenProject: (SessionGroup) -> Unit = {},
    val onOpenArchived: () -> Unit = {},
    /** A search result. */
    val onOpen: (SessionRow) -> Unit = {},
    val onQuery: (String) -> Unit = {},
    val onEditing: (Boolean) -> Unit = {},
    val onSwiping: (Boolean) -> Unit = {},
    val onDragging: (Boolean) -> Unit = {},
    val onMoveProject: (projectKey: String, delta: Int) -> Unit = { _, _ -> },
    val onReorderProjects: (keys: List<String>) -> Unit = {},
    val onSortProjectsByRecent: () -> Unit = {},
    val onSortSessionsByRecent: (projectKey: String) -> Unit = {},
    val onMarkProjectRead: (projectKey: String) -> Unit = {},
    val onMarkAllRead: () -> Unit = {},
    /** A project's New session, or a pick in the compose button's picker. */
    val onNewSession: (SessionGroup) -> Unit = {},
    val onLinkComputer: () -> Unit = {},
    val onSelectComputer: (deviceId: String) -> Unit = {},
    /** Search results' own swipes and menu. */
    val topics: TopicActions = TopicActions(),
)

@Composable
fun SessionsScreen(
    viewModel: SessionsViewModel,
    onOpenProject: (SessionGroup) -> Unit,
    onOpenArchived: () -> Unit,
    onOpen: (SessionRow) -> Unit,
    onNewSession: (NewSessionTarget) -> Unit,
    onLinkComputer: () -> Unit,
    onSelectComputer: (String) -> Unit,
    onMarkProjectRead: (String) -> Unit,
    onMarkAllRead: () -> Unit,
) {
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
            onOpenProject = onOpenProject,
            onOpenArchived = onOpenArchived,
            onOpen = onOpen,
            onQuery = viewModel::setQuery,
            onEditing = viewModel::setEditing,
            onSwiping = viewModel::setSwiping,
            onDragging = viewModel::setDragging,
            onMoveProject = viewModel::moveProject,
            onReorderProjects = viewModel::reorderProjects,
            onSortProjectsByRecent = viewModel::sortProjectsByRecent,
            onSortSessionsByRecent = viewModel::sortSessionsByRecent,
            onMarkProjectRead = onMarkProjectRead,
            onMarkAllRead = onMarkAllRead,
            onNewSession = { group -> onNewSession(group.newSessionTarget()) },
            onLinkComputer = onLinkComputer,
            onSelectComputer = onSelectComputer,
            topics = TopicActions(
                onOpen = onOpen,
                onTogglePin = viewModel::togglePin,
                onToggleArchive = viewModel::toggleArchive,
                onStop = viewModel::stop,
                onMarkRead = viewModel::markRead,
                onSwiping = viewModel::setSwiping,
            ),
        ),
    )
}

/** Where a session started from a project's "+" runs: that folder on that computer. */
fun SessionGroup.newSessionTarget() = NewSessionTarget(
    deviceId = deviceId,
    path = path,
    deviceName = deviceName,
    projectName = name.ifBlank { SessionList.folderName(path) },
)

@Composable
fun SessionsContent(
    state: SessionsUiState,
    actions: SessionsActions,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    pickerInitiallyOpen: Boolean = false,
    switcherInitiallyOpen: Boolean = false,
) {
    val colors = CrokTheme.colors
    var searching by rememberSaveable { mutableStateOf(state.query.isNotEmpty()) }
    var picking by rememberSaveable { mutableStateOf(pickerInitiallyOpen) }
    var switching by remember { mutableStateOf(switcherInitiallyOpen) }

    ReplaceTabBar(active = state.editing) { EditToolbar(state, actions) }

    GlassScaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            when {
                searching -> SearchBar(
                    query = state.query,
                    onQuery = actions.onQuery,
                    onClose = {
                        searching = false
                        actions.onQuery("")
                    },
                )
                else -> ComputerTopBar(
                    state = state,
                    onTitle = { if (state.computers.isNotEmpty()) switching = !switching },
                    onSearch = {
                        actions.onEditing(false)
                        searching = true
                    },
                    onCompose = { picking = true },
                    actions = actions,
                )
            }
        },
        floating = { padding ->
            if (switching) {
                GlassMenuOverlay(
                    onDismiss = { switching = false },
                    alignment = Alignment.TopCenter,
                    padding = PaddingValues(top = padding.calculateTopPadding() + 4.dp, start = 16.dp, end = 16.dp),
                ) {
                    ComputerSwitcherItems(
                        state.computers,
                        state.computer?.deviceId,
                        onSelect = actions.onSelectComputer,
                        onLinkComputer = actions.onLinkComputer,
                        dismiss = { switching = false },
                    )
                }
            }
        },
    ) { padding ->
        val inner = Modifier.fillMaxSize().padding(padding)
        val listPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 8.dp)
        when {
            state.loading -> Box(inner, contentAlignment = Alignment.Center) { CircularProgressIndicator(color = colors.accent) }
            state.computer == null -> Box(inner) { NoComputers(actions.onLinkComputer) }
            state.searching -> SearchResults(state, actions, listPadding)
            state.editing -> ProjectReorderList(
                projects = state.projects,
                onReorder = actions.onReorderProjects,
                onMove = actions.onMoveProject,
                onDragging = actions.onDragging,
                contentPadding = listPadding,
            )
            state.projects.isEmpty() && state.archived.isEmpty() -> Box(inner) { NoSessions(state, onCompose = { picking = true }) }
            else -> ProjectList(state, actions, listPadding)
        }
    }
    if (picking) {
        ProjectPicker(
            projects = state.projects.filter { it.path.isNotBlank() }.sortedByDescending { it.lastActivityAt },
            computerName = state.computer?.name.orEmpty(),
            online = state.computer?.online == true,
            onPick = { group ->
                picking = false
                actions.onNewSession(group)
            },
            onDismiss = { picking = false },
        )
    }
}

/**
 * The top bar: Edit (Done while editing) on the left, the computer's name with a chevron (the switcher) and its status
 * in the middle, search and compose on the right.
 */
@Composable
private fun ComputerTopBar(state: SessionsUiState, onTitle: () -> Unit, onSearch: () -> Unit, onCompose: () -> Unit, actions: SessionsActions) {
    val colors = CrokTheme.colors
    TopAppBar(
        navigationIcon = {
            if (state.editing) {
                TextButton(onClick = { actions.onEditing(false) }, modifier = Modifier.testTag("edit-done")) {
                    Text(stringResource(R.string.action_done), color = colors.accent, fontWeight = FontWeight.SemiBold)
                }
            } else {
                TextButton(onClick = { actions.onEditing(true) }, enabled = state.canEdit, modifier = Modifier.testTag("edit")) {
                    Text(stringResource(R.string.action_edit), color = if (state.canEdit) colors.accent else colors.textTertiary)
                }
            }
        },
        title = {
            Column(
                Modifier
                    .clip(GlassShapes.rounded(12.dp))
                    .clickable(enabled = state.computers.isNotEmpty(), role = Role.Button, onClick = onTitle)
                    .padding(horizontal = 6.dp, vertical = 2.dp)
                    .testTag("computer-title"),
            ) {
                val computer = state.computer
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        computer?.name ?: stringResource(R.string.sessions_title),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (state.computers.isNotEmpty()) {
                        Icon(CrokIcons.ExpandMore, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(20.dp))
                    }
                }
                when {
                    state.connection != ConnectionState.Connected -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                        Spacer(Modifier.width(6.dp))
                        Text(connectionText(state.connection), fontSize = 13.sp, color = colors.textSecondary, maxLines = 1)
                    }
                    computer != null -> Text(
                        computerStatus(computer, if (state.now > 0) state.now else System.currentTimeMillis()),
                        fontSize = 13.sp,
                        color = if (computer.online) colors.accent else colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        },
        actions = {
            if (!state.editing) {
                IconButton(onClick = onSearch) {
                    Icon(CrokIcons.Search, contentDescription = stringResource(R.string.sessions_search))
                }
                // Telegram's compose button: a new session, after picking which of this computer's projects.
                IconButton(onClick = onCompose, enabled = state.canCompose, modifier = Modifier.testTag("compose")) {
                    Icon(
                        CrokIcons.Edit,
                        contentDescription = stringResource(R.string.cd_compose),
                        tint = if (state.canCompose) colors.accent else colors.textTertiary,
                    )
                }
            }
        },
        colors = glassBarColors(),
    )
}

/** Edit mode's bottom toolbar, in the tab bar's place: Read All and Sort by recent activity (Telegram's edit toolbar). */
@Composable
private fun EditToolbar(state: SessionsUiState, actions: SessionsActions) {
    val colors = CrokTheme.colors
    Row(
        Modifier
            .widthIn(min = 300.dp)
            .glass(GlassShapes.capsule)
            .padding(horizontal = 6.dp, vertical = 4.dp)
            .testTag("edit-toolbar"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        TextButton(onClick = actions.onMarkAllRead, enabled = state.unread > 0) {
            Text(stringResource(R.string.action_read_all), color = if (state.unread > 0) colors.accent else colors.textTertiary, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.width(12.dp))
        TextButton(onClick = actions.onSortProjectsByRecent) {
            Text(stringResource(R.string.sessions_sort_recent), color = colors.accent, fontWeight = FontWeight.Medium)
        }
    }
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
        colors = glassBarColors(),
    )
}

/** The computer's list: Archived Sessions first (when there are any), then one forum row per project. */
@Composable
private fun ProjectList(state: SessionsUiState, actions: SessionsActions, contentPadding: PaddingValues) {
    LazyColumn(Modifier.fillMaxSize().testTag("sessions-list"), contentPadding = contentPadding) {
        if (state.archived.isNotEmpty()) {
            item(key = "archived", contentType = "archived") {
                ArchivedRow(state.archived, onClick = actions.onOpenArchived, modifier = Modifier.animateItem())
            }
        }
        items(state.projects, key = { "p:${it.key}" }, contentType = { "project" }) { group ->
            val index = state.projects.indexOf(group)
            SwipeableForumRow(
                group = group,
                now = state.now,
                canMoveUp = index > 0,
                canMoveDown = index < state.projects.lastIndex,
                actions = actions,
                modifier = Modifier.animateItem(),
            )
        }
    }
}

@Composable
private fun SearchResults(state: SessionsUiState, actions: SessionsActions, contentPadding: PaddingValues) {
    val colors = CrokTheme.colors
    if (state.results.isEmpty()) {
        Box(Modifier.fillMaxSize().padding(contentPadding).padding(32.dp), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.sessions_no_results), color = colors.textSecondary)
        }
        return
    }
    LazyColumn(Modifier.fillMaxSize().testTag("search-results"), contentPadding = contentPadding) {
        items(state.results, key = { it.id }, contentType = { "topic" }) { row ->
            SwipeableTopicRow(row, state.now, actions.topics, projectLine = true, modifier = Modifier.animateItem())
        }
    }
}

/** Telegram's Archived Chats row: a grey archive avatar, "Archived Sessions" and the archived titles. */
@Composable
private fun ArchivedRow(rows: List<SessionRow>, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    Column(modifier.fillMaxWidth().background(colors.screen).clickable(onClick = onClick).testTag("archived-row")) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 76.dp).padding(start = 12.dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(54.dp).clip(CircleShape).background(colors.badgeMuted),
                contentAlignment = Alignment.Center,
            ) {
                Icon(CrokIcons.Archive, contentDescription = null, tint = Color.White, modifier = Modifier.size(28.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.sessions_archived_title),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                Text(
                    rows.joinToString(", ") { it.title.ifBlank { SessionList.folderName(it.cwd) } },
                    fontSize = 14.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        HorizontalDivider(Modifier.padding(start = 78.dp), color = colors.divider, thickness = 0.5.dp)
    }
}

@Composable
private fun SwipeableForumRow(
    group: SessionGroup,
    now: Long,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    actions: SessionsActions,
    modifier: Modifier = Modifier,
) {
    val colors = CrokTheme.colors
    val unread = Forum.unread(group)
    val scope = rememberCoroutineScope()
    val dismiss = rememberSwipeToDismissBoxState(positionalThreshold = { distance -> distance * 0.3f })
    LaunchedEffect(dismiss) {
        snapshotFlow { dismiss.dismissDirection != SwipeToDismissBoxValue.Settled }.collect(actions.onSwiping)
    }
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier,
        backgroundContent = {
            val visual = if (dismiss.dismissDirection == SwipeToDismissBoxValue.StartToEnd) {
                SwipeVisual(colors.swipePin, CrokIcons.DoneAll, stringResource(R.string.action_read), Alignment.CenterStart)
            } else {
                SwipeVisual(Color.Transparent, null, "", Alignment.Center)
            }
            SwipeBackground(visual)
        },
        // Leading swipe: Read (only while something is unread); no trailing swipe on a project.
        enableDismissFromStartToEnd = unread > 0,
        enableDismissFromEndToStart = false,
        onDismiss = { direction ->
            if (direction == SwipeToDismissBoxValue.StartToEnd) actions.onMarkProjectRead(group.key)
            scope.launch { dismiss.reset() }
        },
    ) {
        ForumRow(group, now, canMoveUp, canMoveDown, actions)
    }
}

/**
 * A project as a group with topics (Telegram's forum row): the rounded-square avatar; the name and time; its three most
 * recent sessions' titles; "working…", "Needs approval" or the latest preview; the unread total.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ForumRow(group: SessionGroup, now: Long, canMoveUp: Boolean, canMoveDown: Boolean, actions: SessionsActions) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    var menu by remember { mutableStateOf(false) }
    val name = group.name.ifBlank { SessionList.folderName(group.path) }
    val dimmed = !group.deviceOnline
    val unread = Forum.unread(group)
    val effectiveNow = if (now > 0) now else System.currentTimeMillis()
    val time = formatter.listTime(RelativeTime.listTime(group.lastActivityAt, effectiveNow, formatter.zone))
    val recent = Forum.recent(group).take(Forum.TOPIC_LIMIT)
    val latest = recent.firstOrNull()

    Box(Modifier.background(colors.screen)) {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = { actions.onOpenProject(group) }, onLongClick = { menu = true })
                .testTag("project-${group.key}"),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 84.dp).padding(start = 12.dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ForumAvatar(name, 54.dp, dimmed = dimmed)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            name,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (dimmed) colors.textSecondary else colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(time, fontSize = 13.sp, color = if (unread > 0 && !dimmed) colors.accent else colors.textTertiary)
                    }
                    TopicStrip(recent)
                    Spacer(Modifier.height(1.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) {
                            when (Forum.activity(group)) {
                                Forum.Activity.Working -> WorkingDots(stringResource(R.string.sessions_working), colors.accent)
                                Forum.Activity.Waiting -> NeedsApprovalChip()
                                Forum.Activity.Idle -> if (latest != null) LatestPreview(latest, dimmed) else {
                                    Text(stringResource(R.string.sessions_no_messages), fontSize = 14.sp, color = colors.textTertiary, maxLines = 1)
                                }
                            }
                        }
                        if (unread > 0) {
                            Spacer(Modifier.width(8.dp))
                            UnreadBadge(unread, muted = dimmed)
                        }
                    }
                }
            }
            HorizontalDivider(Modifier.padding(start = 78.dp), color = colors.divider, thickness = 0.5.dp)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (group.deviceOnline && group.path.isNotBlank()) {
                MenuItem(stringResource(R.string.sessions_new_session), CrokIcons.Add) {
                    menu = false
                    actions.onNewSession(group)
                }
            }
            if (unread > 0) {
                MenuItem(stringResource(R.string.action_mark_read), CrokIcons.DoneAll) {
                    menu = false
                    actions.onMarkProjectRead(group.key)
                }
            }
            if (canMoveUp) {
                MenuItem(stringResource(R.string.action_move_up), CrokIcons.ArrowUp) {
                    menu = false
                    actions.onMoveProject(group.key, -1)
                }
            }
            if (canMoveDown) {
                MenuItem(stringResource(R.string.action_move_down), CrokIcons.ArrowDown) {
                    menu = false
                    actions.onMoveProject(group.key, 1)
                }
            }
            MenuItem(stringResource(R.string.sessions_sort_recent), CrokIcons.Clock) {
                menu = false
                actions.onSortSessionsByRecent(group.key)
            }
        }
    }
}

/**
 * The forum row's second line, as iOS draws it: one line holding the three most recent topics, each after its glyph,
 * the newest in the primary colour, three spaces between them, cut once at the end (so the first title shows in full
 * when it fits and the later ones give way).
 */
@Composable
private fun TopicStrip(recent: List<SessionRow>) {
    val colors = CrokTheme.colors
    val glyph = with(LocalDensity.current) { 14.dp.toSp() }
    val titles = recent.map { it.title.ifBlank { SessionList.folderName(it.cwd) } }
    val text = buildAnnotatedString {
        recent.forEachIndexed { index, row ->
            if (index > 0) append("   ")
            appendInlineContent("topic-${row.id}", "·")
            append(" ")
            withStyle(
                SpanStyle(
                    color = if (index == 0) colors.textPrimary else colors.textSecondary,
                    fontWeight = if (index == 0) FontWeight.Medium else FontWeight.Normal,
                ),
            ) { append(titles[index]) }
        }
    }
    val icons = recent.mapIndexed { index, row ->
        "topic-${row.id}" to InlineTextContent(Placeholder(glyph, glyph, PlaceholderVerticalAlign.TextCenter)) {
            TopicIcon(titles[index], row.id, 14.dp)
        }
    }.toMap()
    Text(
        text,
        inlineContent = icons,
        fontSize = 14.sp,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(top = 1.dp).testTag("topic-strip"),
    )
}

/** The latest session's preview on the forum row ("You: " before a prompt of the person's). */
@Composable
private fun LatestPreview(row: SessionRow, dimmed: Boolean) {
    val colors = CrokTheme.colors
    if (row.preview.isNullOrBlank()) {
        TopicPreview(row, dimmed)
        return
    }
    val preview = row.preview.lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty()
    val you = stringResource(R.string.sessions_you)
    val text = buildAnnotatedString {
        if (row.previewKind == EventKind.USER) {
            withStyle(SpanStyle(color = if (dimmed) colors.textSecondary else colors.textPrimary)) { append(you) }
        }
        append(preview)
    }
    Text(text, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun NoComputers(onLinkComputer: () -> Unit) {
    val colors = CrokTheme.colors
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        IconBadge(CrokIcons.Laptop, colors.accent, size = 88.dp)
        Spacer(Modifier.height(20.dp))
        Text(stringResource(R.string.sessions_no_computers), style = MaterialTheme.typography.titleLarge, color = colors.textPrimary)
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

@Composable
private fun NoSessions(state: SessionsUiState, onCompose: () -> Unit) {
    val colors = CrokTheme.colors
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        IconBadge(CrokIcons.ChatOutline, colors.accent, size = 88.dp)
        Spacer(Modifier.height(20.dp))
        Text(
            stringResource(R.string.sessions_empty_computer, state.computer?.name.orEmpty()),
            style = MaterialTheme.typography.titleLarge,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        if (state.computer?.online == true && state.canCompose) {
            Spacer(Modifier.height(20.dp))
            Button(
                onClick = onCompose,
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            ) { Text(stringResource(R.string.sessions_new_session)) }
        }
    }
}

/**
 * The compose button's question (Telegram's new chat): which of this computer's projects, recent first. The picked one
 * opens the new-session screen.
 */
@Composable
private fun ProjectPicker(
    projects: List<SessionGroup>,
    computerName: String,
    online: Boolean,
    onPick: (SessionGroup) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = CrokTheme.colors
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.sheet) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp).testTag("project-picker")) {
            Text(
                stringResource(R.string.picker_title),
                style = MaterialTheme.typography.titleMedium,
                color = colors.textPrimary,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 2.dp),
            )
            Text(computerName, color = colors.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp))
            if (!online || projects.isEmpty()) {
                Text(
                    stringResource(R.string.picker_empty),
                    color = colors.textSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
                )
            }
            LazyColumn(Modifier.heightIn(max = 520.dp).alpha(if (online) 1f else 0.5f)) {
                items(projects, key = { "p:${it.key}" }) { group ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable(enabled = online) { onPick(group) }
                            .heightIn(min = 56.dp)
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val name = group.name.ifBlank { SessionList.folderName(group.path) }
                        ForumAvatar(name, 40.dp)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(name, color = colors.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(SessionList.prettyPath(group.path), color = colors.textTertiary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(CrokIcons.Add, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}
