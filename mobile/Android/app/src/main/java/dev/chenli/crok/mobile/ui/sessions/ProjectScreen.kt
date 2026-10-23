package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.Forum
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.connectionText
import dev.chenli.crok.mobile.ui.common.glassBarColors
import dev.chenli.crok.mobile.ui.session.NewSessionTarget
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** A project's screen: its sessions as the group's topics (mobile/DESIGN.md "Project screen"). */
data class ProjectUiState(
    val connection: ConnectionState = ConnectionState.Connected,
    /** The project; null once it has no sessions left (all archived, or gone). */
    val group: SessionGroup? = null,
    /** Its sessions (narrowed by a search), in the relay's order. */
    val rows: List<SessionRow> = emptyList(),
    val query: String = "",
    val reordering: Boolean = false,
    val loaded: Boolean = false,
    val now: Long = 0,
) {
    val searching: Boolean get() = query.isNotBlank()
    val canReorder: Boolean get() = !searching && (group?.sessions?.size ?: 0) > 1
    val unread: Int get() = group?.let { Forum.unread(it) } ?: 0
    val canCompose: Boolean get() = group?.deviceOnline == true && group.path.isNotBlank()

    companion object {
        fun build(groups: List<SessionGroup>, live: Boolean, projectKey: String, query: String, reordering: Boolean, connection: ConnectionState, now: Long): ProjectUiState {
            val group = groups.firstOrNull { it.key == projectKey }
            val rows = group?.sessions.orEmpty().filter { Forum.matches(it, query) }
            val state = ProjectUiState(connection, group, rows, query, false, live || groups.isNotEmpty(), now)
            return state.copy(reordering = reordering && state.canReorder)
        }
    }
}

class ProjectViewModel(private val engine: CrokEngine, private val projectKey: String) : ViewModel() {
    private val query = MutableStateFlow("")
    private val reordering = MutableStateFlow(false)
    private val frozen = MutableStateFlow(false)
    private var lastOrder: List<String> = emptyList()

    private val _events = Channel<SessionsEvent>(Channel.BUFFERED)
    val events: Flow<SessionsEvent> = _events.receiveAsFlow()

    private val ticker: Flow<Long> = flow {
        while (true) {
            emit(engine.clock())
            delay(30_000)
        }
    }

    val state: StateFlow<ProjectUiState> = combine(
        engine.sessions.active,
        combine(query, reordering, frozen) { q, r, f -> Triple(q, r, f) },
        engine.connection.delayedForDisplay(),
        ticker,
    ) { list, (q, r, f), connection, now ->
        val built = ProjectUiState.build(list.groups, list.live, projectKey, q, r, connection, now)
        val rows = if (f) SessionList.freezeOrder(lastOrder, built.rows) else built.rows
        lastOrder = rows.map { it.id }
        built.copy(rows = rows)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ProjectUiState())

    fun setQuery(value: String) {
        query.value = value
        if (value.isNotBlank()) reordering.value = false
    }

    fun setReordering(value: Boolean) {
        reordering.value = value
    }

    fun setFrozen(value: Boolean) {
        frozen.value = value
    }

    fun togglePin(row: SessionRow) = act { engine.sessions.setPinned(row.id, !row.pinned) }

    fun toggleArchive(row: SessionRow) = act {
        engine.sessions.setArchived(row.id, !row.archived)
        if (!row.archived) _events.trySend(SessionsEvent.Archived(row.id))
    }

    fun unarchive(sessionDocId: String) = act { engine.sessions.setArchived(sessionDocId, false) }

    fun stop(row: SessionRow) = act { engine.commands.stop(row.id) }

    fun markRead(row: SessionRow) = act { engine.sessions.markRead(listOf(row.id)) }

    /** Move up / Move down: within the project, pinned ones among the pinned. */
    fun move(row: SessionRow, delta: Int) {
        val group = state.value.group ?: return
        val ids = SessionOrder.moveSession(group.sessions, row.id, delta) ?: return
        reorder(ids)
    }

    fun reorder(sessionDocIds: List<String>) = act { engine.sessions.reorderSessions(projectKey, sessionDocIds) }

    fun sortByRecent() = act { engine.sessions.sortSessionsByRecent(projectKey) }

    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _events.trySend(SessionsEvent.Failed(e.message ?: e.javaClass.simpleName))
            }
        }
    }
}

data class ProjectActions(
    val onBack: () -> Unit = {},
    val onQuery: (String) -> Unit = {},
    val onReordering: (Boolean) -> Unit = {},
    val onDragging: (Boolean) -> Unit = {},
    val onReorder: (List<String>) -> Unit = {},
    val onSortByRecent: () -> Unit = {},
    val onMarkAllRead: () -> Unit = {},
    val onNewSession: () -> Unit = {},
    val topics: TopicActions = TopicActions(),
)

@Composable
fun ProjectScreen(
    viewModel: ProjectViewModel,
    onBack: () -> Unit,
    onOpen: (SessionRow) -> Unit,
    onNewSession: (NewSessionTarget) -> Unit,
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
    ProjectContent(
        state = state,
        snackbar = snackbar,
        actions = ProjectActions(
            onBack = onBack,
            onQuery = viewModel::setQuery,
            onReordering = viewModel::setReordering,
            onDragging = viewModel::setFrozen,
            onReorder = viewModel::reorder,
            onSortByRecent = viewModel::sortByRecent,
            onMarkAllRead = onMarkAllRead,
            onNewSession = { state.group?.let { onNewSession(it.newSessionTarget()) } },
            topics = TopicActions(
                onOpen = onOpen,
                onTogglePin = viewModel::togglePin,
                onToggleArchive = viewModel::toggleArchive,
                onStop = viewModel::stop,
                onMarkRead = viewModel::markRead,
                onMove = viewModel::move,
                onSwiping = viewModel::setFrozen,
            ),
        ),
    )
}

@Composable
fun ProjectContent(state: ProjectUiState, actions: ProjectActions, snackbar: SnackbarHostState = remember { SnackbarHostState() }) {
    val colors = CrokTheme.colors
    var searching by rememberSaveable { mutableStateOf(state.query.isNotEmpty()) }
    GlassScaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            if (searching) {
                ProjectSearchBar(state.query, actions.onQuery) {
                    searching = false
                    actions.onQuery("")
                }
            } else {
                ProjectTopBar(state, actions, onSearch = {
                    actions.onReordering(false)
                    searching = true
                })
            }
        },
    ) { padding ->
        val listPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 8.dp)
        when {
            !state.loaded -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }
            state.reordering -> TopicReorderList(
                rows = state.rows,
                now = state.now,
                onReorder = actions.onReorder,
                onMove = actions.topics.onMove,
                onDragging = actions.onDragging,
                contentPadding = listPadding,
            )
            state.rows.isEmpty() -> Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) {
                Text(
                    stringResource(if (state.searching) R.string.sessions_no_results else R.string.sessions_empty_title),
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
            else -> LazyColumn(Modifier.fillMaxSize().testTag("project-list"), contentPadding = listPadding) {
                val group = state.group
                items(state.rows, key = { it.id }, contentType = { "topic" }) { row ->
                    SwipeableTopicRow(
                        row = row,
                        now = state.now,
                        actions = actions.topics,
                        projectName = group?.name?.ifBlank { null },
                        moves = if (state.searching || group == null) RowMoves.None else RowMoves.of(group.sessions, row),
                        modifier = Modifier.animateItem(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ProjectTopBar(state: ProjectUiState, actions: ProjectActions, onSearch: () -> Unit) {
    val colors = CrokTheme.colors
    var menu by remember { mutableStateOf(false) }
    val group = state.group
    TopAppBar(
        navigationIcon = {
            IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
        },
        title = {
            Column {
                Text(
                    group?.name?.ifBlank { null } ?: group?.path?.let { SessionList.folderName(it) }.orEmpty(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                if (state.connection != ConnectionState.Connected) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = colors.textSecondary)
                        Spacer(Modifier.width(6.dp))
                        Text(connectionText(state.connection), fontSize = 13.sp, color = colors.textSecondary, maxLines = 1)
                    }
                } else if (group != null) {
                    Text(
                        pluralStringResource(R.plurals.project_subtitle, group.sessions.size, group.sessions.size, group.deviceName),
                        fontSize = 13.sp,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        },
        actions = {
            if (state.reordering) {
                TextButton(onClick = { actions.onReordering(false) }, modifier = Modifier.testTag("reorder-done")) {
                    Text(stringResource(R.string.action_done), color = colors.accent, fontWeight = FontWeight.SemiBold)
                }
            } else {
                IconButton(onClick = onSearch) {
                    Icon(CrokIcons.Search, contentDescription = stringResource(R.string.sessions_search))
                }
                IconButton(onClick = actions.onNewSession, enabled = state.canCompose, modifier = Modifier.testTag("compose")) {
                    Icon(
                        CrokIcons.Edit,
                        contentDescription = stringResource(R.string.sessions_new_session),
                        tint = if (state.canCompose) colors.accent else colors.textTertiary,
                    )
                }
                Box {
                    IconButton(onClick = { menu = true }, modifier = Modifier.testTag("project-menu")) {
                        Icon(CrokIcons.MoreHoriz, contentDescription = stringResource(R.string.cd_more_options))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        if (state.unread > 0) {
                            MenuItem(stringResource(R.string.action_mark_all_read), CrokIcons.DoneAll) {
                                menu = false
                                actions.onMarkAllRead()
                            }
                        }
                        if (state.canReorder) {
                            MenuItem(stringResource(R.string.sessions_reorder), CrokIcons.Reorder) {
                                menu = false
                                actions.onReordering(true)
                            }
                        }
                        MenuItem(stringResource(R.string.sessions_sort_recent), CrokIcons.Clock) {
                            menu = false
                            actions.onSortByRecent()
                        }
                    }
                }
            }
        },
        colors = glassBarColors(),
    )
}

@Composable
private fun ProjectSearchBar(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
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
                modifier = Modifier.focusRequester(focus),
            )
        },
        colors = glassBarColors(),
    )
}
