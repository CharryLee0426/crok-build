package dev.chenli.crok.mobile.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.CollapsedProjectsStore
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.SessionListState
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.ComputerTab
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.logic.SessionSection
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class SessionsUiState(
    val connection: ConnectionState = ConnectionState.Connecting,
    val tabs: List<ComputerTab> = emptyList(),
    val filter: SessionFilter = SessionFilter.All,
    /** All and computer tabs: one section per project, in the relay's order. */
    val sections: List<SessionSection> = emptyList(),
    /** The Archived tab: a flat list. */
    val rows: List<SessionRow> = emptyList(),
    /** Nothing to show yet: no cache and the relay has not answered. */
    val loading: Boolean = true,
    /** Sessions on the active list at all (before the tab and search narrow it). */
    val totalActive: Int = 0,
    val query: String = "",
    val now: Long = 0,
    /** Reorder mode: drag handles on projects, or on the sessions of [reorderProject]. */
    val reordering: Boolean = false,
    /** In Reorder mode, the project opened to move its sessions (null: the projects themselves move). */
    val reorderProject: String? = null,
    /** The compose button's picker: online computers' projects. */
    val newSessionProjects: List<SessionList.ComputerProjects> = emptyList(),
) {
    /** The tab shows projects (not the flat Archived list). */
    val grouped: Boolean get() = filter != SessionFilter.Archived

    val searching: Boolean get() = query.isNotBlank()

    val isEmpty: Boolean get() = if (grouped) sections.isEmpty() else rows.isEmpty()

    /** Projects and sessions can be moved: a project tab with something in it, and no search narrowing it. */
    val canReorder: Boolean get() = grouped && !searching && sections.isNotEmpty()

    /** Section headers name the computer only on All (a computer tab already does). */
    val showComputer: Boolean get() = filter == SessionFilter.All

    companion object {
        /** Pure: what the list shows for the inputs (shared by the view model and the screenshot tests). */
        fun build(
            active: SessionListState,
            archived: List<SessionRow>?,
            filter: SessionFilter,
            query: String,
            connection: ConnectionState,
            now: Long,
            collapsed: Set<String> = emptySet(),
            expanded: Set<String> = emptySet(),
            reordering: Boolean = false,
            reorderProject: String? = null,
        ): SessionsUiState {
            val tabs = SessionList.computerTabs(active.groups)
            // A computer tab whose computer has no sessions left falls back to All.
            val effectiveFilter = if (filter is SessionFilter.Computer && tabs.none { it.deviceId == filter.deviceId }) SessionFilter.All else filter
            val archivedTab = effectiveFilter == SessionFilter.Archived
            val state = SessionsUiState(
                connection = connection,
                tabs = if (tabs.size >= 2) tabs else emptyList(),
                filter = effectiveFilter,
                sections = if (archivedTab) emptyList() else SessionList.sections(active.groups, effectiveFilter, query, collapsed, expanded),
                rows = if (archivedTab) SessionList.filter(archived.orEmpty(), effectiveFilter, query) else emptyList(),
                loading = if (archivedTab) archived == null else !active.live && active.groups.isEmpty(),
                totalActive = active.rows.size,
                query = query,
                now = now,
                newSessionProjects = SessionList.newSessionProjects(active.groups),
            )
            val reorder = reordering && state.canReorder
            return state.copy(
                reordering = reorder,
                reorderProject = reorderProject?.takeIf { key -> reorder && state.sections.any { it.key == key } },
            )
        }
    }
}

sealed interface SessionsEvent {
    data class Archived(val sessionDocId: String) : SessionsEvent
    data class Failed(val message: String) : SessionsEvent
}

@OptIn(ExperimentalCoroutinesApi::class)
class SessionsViewModel(
    private val engine: CrokEngine,
    private val collapsedStore: CollapsedProjectsStore? = null,
) : ViewModel() {
    private val filter = MutableStateFlow<SessionFilter>(SessionFilter.All)
    private val query = MutableStateFlow("")
    private val swiping = MutableStateFlow(false)
    private val dragging = MutableStateFlow(false)
    private val expanded = MutableStateFlow(emptySet<String>())
    private val reordering = MutableStateFlow(false)
    private val reorderProject = MutableStateFlow<String?>(null)
    private val localCollapsed = MutableStateFlow(emptySet<String>())
    private val collapsed: StateFlow<Set<String>> = collapsedStore?.keys ?: localCollapsed
    private var lastOrder = SessionList.Order()
    private var lastRowOrder: List<String> = emptyList()

    private val _events = Channel<SessionsEvent>(Channel.BUFFERED)
    val events: Flow<SessionsEvent> = _events.receiveAsFlow()

    private val archived: Flow<List<SessionRow>?> = filter.flatMapLatest { current ->
        if (current == SessionFilter.Archived) engine.sessions.archived().map { it.getOrNull() } else flowOf(null)
    }

    /** Relative times in the rows move on without new data. */
    private val ticker: Flow<Long> = flow {
        while (true) {
            emit(engine.clock())
            delay(30_000)
        }
    }

    private data class Inputs(
        val filter: SessionFilter,
        val query: String,
        val frozen: Boolean,
        val collapsed: Set<String>,
        val expanded: Set<String>,
        val reordering: Boolean,
        val reorderProject: String?,
    )

    private data class View(val collapsed: Set<String>, val expanded: Set<String>, val reordering: Boolean, val reorderProject: String?)

    private val view = combine(collapsed, expanded, reordering, reorderProject, ::View)

    private val inputs = combine(filter, query, swiping, dragging, view) { f, q, s, d, v ->
        Inputs(f, q, s || d, v.collapsed, v.expanded, v.reordering, v.reorderProject)
    }

    val state: StateFlow<SessionsUiState> = combine(
        engine.sessions.active,
        archived,
        inputs,
        engine.connection.delayedForDisplay(),
        ticker,
    ) { active, archivedRows, input, connection, now ->
        val built = SessionsUiState.build(
            active, archivedRows, input.filter, input.query, connection, now, input.collapsed, input.expanded, input.reordering,
            input.reorderProject,
        )
        // Telegram freezes the list while a row is swiped, so it never re-sorts under the finger; so does a drag.
        val sections = if (input.frozen) SessionList.freezeSections(lastOrder, built.sections) else built.sections
        val rows = if (input.frozen) SessionList.freezeOrder(lastRowOrder, built.rows) else built.rows
        lastOrder = SessionList.orderOf(sections)
        lastRowOrder = rows.map { it.id }
        built.copy(sections = sections, rows = rows)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SessionsUiState())

    fun setFilter(value: SessionFilter) {
        filter.value = value
        if (value == SessionFilter.Archived) reordering.value = false
    }

    fun setQuery(value: String) {
        query.value = value
        if (value.isNotBlank()) reordering.value = false
    }

    fun setSwiping(value: Boolean) {
        swiping.value = value
    }

    fun setDragging(value: Boolean) {
        dragging.value = value
    }

    fun setReordering(value: Boolean) {
        reordering.value = value
        reorderProject.value = null
    }

    /** In Reorder mode: open a project to move its sessions, or close it (null) to move projects again. */
    fun setReorderProject(projectKey: String?) {
        reorderProject.value = projectKey
    }

    /** The chevron on a project's header; remembered on this phone. */
    fun toggleCollapsed(projectKey: String) {
        if (collapsedStore != null) collapsedStore.toggle(projectKey) else localCollapsed.value = localCollapsed.value.toggled(projectKey)
    }

    /** "Show N more" / "Show less". */
    fun toggleExpanded(projectKey: String) {
        expanded.value = expanded.value.toggled(projectKey)
    }

    private fun Set<String>.toggled(key: String): Set<String> = if (key in this) this - key else this + key

    fun togglePin(row: SessionRow) = act { engine.sessions.setPinned(row.id, !row.pinned) }

    fun toggleArchive(row: SessionRow) = act {
        engine.sessions.setArchived(row.id, !row.archived)
        if (!row.archived) _events.trySend(SessionsEvent.Archived(row.id))
    }

    fun unarchive(sessionDocId: String) = act { engine.sessions.setArchived(sessionDocId, false) }

    fun stop(row: SessionRow) = act { engine.commands.stop(row.id) }

    /** Move up / Move down on a project: among the projects of the current tab. */
    fun moveProject(projectKey: String, delta: Int) {
        val current = state.value
        if (!current.canReorder) return
        val keys = SessionOrder.move(current.sections.map { it.key }, projectKey, delta) ?: return
        reorderProjects(keys)
    }

    /** Move up / Move down on a session: within its project, pinned ones among the pinned. */
    fun moveSession(row: SessionRow, delta: Int) {
        if (state.value.searching) return
        val group = engine.sessions.active.value.groups.firstOrNull { g -> g.sessions.any { it.id == row.id } } ?: return
        val ids = SessionOrder.moveSession(group.sessions, row.id, delta) ?: return
        reorderSessions(group.key, ids)
    }

    /** A drag in Reorder mode ended: the projects of the current tab in their new order. */
    fun reorderProjects(keys: List<String>) = act { engine.sessions.reorderProjects(keys) }

    fun reorderSessions(projectKey: String, sessionDocIds: List<String>) = act { engine.sessions.reorderSessions(projectKey, sessionDocIds) }

    fun sortProjectsByRecent() = act { engine.sessions.sortProjectsByRecent() }

    fun sortSessionsByRecent(projectKey: String) = act { engine.sessions.sortSessionsByRecent(projectKey) }

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
