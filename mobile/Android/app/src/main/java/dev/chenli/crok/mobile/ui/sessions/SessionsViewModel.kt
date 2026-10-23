package dev.chenli.crok.mobile.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.ComputerAccount
import dev.chenli.crok.mobile.logic.Forum
import dev.chenli.crok.mobile.logic.SessionList
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.ui.ComputerState
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** The Sessions tab: the selected computer's projects (mobile/DESIGN.md "Sessions tab"). */
data class SessionsUiState(
    val connection: ConnectionState = ConnectionState.Connecting,
    val computers: List<ComputerAccount> = emptyList(),
    /** The computer shown; null without computers. */
    val computer: ComputerAccount? = null,
    /** Its projects, in the relay's order. */
    val projects: List<SessionGroup> = emptyList(),
    /** Its archived sessions (the Archived Sessions row). */
    val archived: List<SessionRow> = emptyList(),
    val query: String = "",
    /** While searching: its matching sessions. */
    val results: List<SessionRow> = emptyList(),
    /** Edit mode: projects move by their handles; Read All and Sort take the tab bar's place. */
    val editing: Boolean = false,
    /** Nothing to show yet: no cache and the relay has not answered. */
    val loading: Boolean = true,
    val now: Long = 0,
) {
    val searching: Boolean get() = query.isNotBlank()

    /** Edit is offered while there are projects and no search narrows them. */
    val canEdit: Boolean get() = !searching && projects.isNotEmpty()

    /** New sessions start only on an online computer. */
    val canCompose: Boolean get() = computer?.online == true && projects.any { it.path.isNotBlank() }

    val unread: Int get() = projects.sumOf { Forum.unread(it) }

    companion object {
        /** Pure: what the tab shows for the inputs (shared by the view model and the screenshot tests). */
        fun build(
            computers: ComputerState,
            archived: List<SessionRow>?,
            query: String,
            connection: ConnectionState,
            now: Long,
            editing: Boolean = false,
        ): SessionsUiState {
            val selectedId = computers.selectedId
            val projects = computers.projects
            val searching = query.isNotBlank()
            return SessionsUiState(
                connection = connection,
                computers = computers.computers,
                computer = computers.selected,
                projects = projects,
                archived = archived.orEmpty().filter { it.deviceId == selectedId },
                query = query,
                results = if (searching) Forum.search(projects, query) else emptyList(),
                editing = editing && !searching && projects.isNotEmpty(),
                loading = computers.computers.isEmpty() && !(computers.listed && computers.devicesLoaded),
                now = now,
            )
        }
    }
}

sealed interface SessionsEvent {
    data class Archived(val sessionDocId: String) : SessionsEvent
    data class Failed(val message: String) : SessionsEvent
}

class SessionsViewModel(private val engine: CrokEngine, computers: StateFlow<ComputerState>) : ViewModel() {
    private val query = MutableStateFlow("")
    private val editing = MutableStateFlow(false)
    private val swiping = MutableStateFlow(false)
    private val dragging = MutableStateFlow(false)
    private var lastOrder: List<String> = emptyList()

    private val _events = Channel<SessionsEvent>(Channel.BUFFERED)
    val events: Flow<SessionsEvent> = _events.receiveAsFlow()

    private val archived: Flow<List<SessionRow>?> = engine.sessions.archived().map { it.getOrNull() }.onStart { emit(null) }

    /** Relative times in the rows move on without new data. */
    private val ticker: Flow<Long> = flow {
        while (true) {
            emit(engine.clock())
            delay(30_000)
        }
    }

    private data class Inputs(val query: String, val editing: Boolean, val frozen: Boolean)

    private val inputs = combine(query, editing, swiping, dragging) { q, e, s, d -> Inputs(q, e, s || d) }

    val state: StateFlow<SessionsUiState> = combine(
        computers,
        archived,
        inputs,
        engine.connection.delayedForDisplay(),
        ticker,
    ) { computerState, archivedRows, input, connection, now ->
        val built = SessionsUiState.build(computerState, archivedRows, input.query, connection, now, input.editing)
        // Telegram freezes the list while a row is swiped, so it never re-sorts under the finger; so does a drag.
        val projects = if (input.frozen) SessionList.freeze(lastOrder, built.projects) { it.key } else built.projects
        lastOrder = projects.map { it.key }
        built.copy(projects = projects)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SessionsUiState())

    fun setQuery(value: String) {
        query.value = value
        if (value.isNotBlank()) editing.value = false
    }

    fun setEditing(value: Boolean) {
        editing.value = value
    }

    fun setSwiping(value: Boolean) {
        swiping.value = value
    }

    fun setDragging(value: Boolean) {
        dragging.value = value
    }

    /** Move up / Move down on a project: among this computer's projects. */
    fun moveProject(projectKey: String, delta: Int) {
        val current = state.value
        if (current.searching) return
        val keys = SessionOrder.move(current.projects.map { it.key }, projectKey, delta) ?: return
        reorderProjects(keys)
    }

    /** A drop in Edit mode: this computer's projects in their new order (the others keep their places). */
    fun reorderProjects(keys: List<String>) = act { engine.sessions.reorderProjects(keys) }

    fun sortProjectsByRecent() = act { engine.sessions.sortProjectsByRecent() }

    fun sortSessionsByRecent(projectKey: String) = act { engine.sessions.sortSessionsByRecent(projectKey) }

    fun togglePin(row: SessionRow) = act { engine.sessions.setPinned(row.id, !row.pinned) }

    fun toggleArchive(row: SessionRow) = act {
        engine.sessions.setArchived(row.id, !row.archived)
        if (!row.archived) _events.trySend(SessionsEvent.Archived(row.id))
    }

    fun unarchive(sessionDocId: String) = act { engine.sessions.setArchived(sessionDocId, false) }

    fun stop(row: SessionRow) = act { engine.commands.stop(row.id) }

    fun markRead(row: SessionRow) = act { engine.sessions.markRead(listOf(row.id)) }

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
