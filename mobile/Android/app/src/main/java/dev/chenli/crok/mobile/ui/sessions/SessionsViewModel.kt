package dev.chenli.crok.mobile.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.SessionListState
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.ComputerTab
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.logic.SessionList
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
    val rows: List<SessionRow> = emptyList(),
    /** Nothing to show yet: no cache and the relay has not answered. */
    val loading: Boolean = true,
    /** Sessions on the active list at all (before the tab and search narrow it). */
    val totalActive: Int = 0,
    val query: String = "",
    val now: Long = 0,
) {
    companion object {
        /** Pure: what the list shows for the inputs (shared by the view model and the screenshot tests). */
        fun build(
            active: SessionListState,
            archived: List<SessionRow>?,
            filter: SessionFilter,
            query: String,
            connection: ConnectionState,
            now: Long,
        ): SessionsUiState {
            val tabs = SessionList.computerTabs(active.rows)
            // A computer tab whose computer has no sessions left falls back to All.
            val effectiveFilter = if (filter is SessionFilter.Computer && tabs.none { it.deviceId == filter.deviceId }) SessionFilter.All else filter
            val source = if (effectiveFilter == SessionFilter.Archived) archived.orEmpty() else active.rows
            return SessionsUiState(
                connection = connection,
                tabs = if (tabs.size >= 2) tabs else emptyList(),
                filter = effectiveFilter,
                rows = SessionList.filter(source, effectiveFilter, query),
                loading = if (effectiveFilter == SessionFilter.Archived) archived == null else !active.live && active.rows.isEmpty(),
                totalActive = active.rows.size,
                query = query,
                now = now,
            )
        }
    }
}

sealed interface SessionsEvent {
    data class Archived(val sessionDocId: String) : SessionsEvent
    data class Failed(val message: String) : SessionsEvent
}

@OptIn(ExperimentalCoroutinesApi::class)
class SessionsViewModel(private val engine: CrokEngine) : ViewModel() {
    private val filter = MutableStateFlow<SessionFilter>(SessionFilter.All)
    private val query = MutableStateFlow("")
    private val swiping = MutableStateFlow(false)
    private var lastOrder: List<String> = emptyList()

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

    private val inputs = combine(filter, query, swiping) { f, q, s -> Triple(f, q, s) }

    val state: StateFlow<SessionsUiState> = combine(
        engine.sessions.active,
        archived,
        inputs,
        engine.connection.delayedForDisplay(),
        ticker,
    ) { active, archivedRows, (f, q, frozen), connection, now ->
        val built = SessionsUiState.build(active, archivedRows, f, q, connection, now)
        // Telegram freezes the list while a row is swiped, so it never re-sorts under the finger.
        val rows = if (frozen) SessionList.freezeOrder(lastOrder, built.rows) else built.rows
        lastOrder = rows.map { it.id }
        built.copy(rows = rows)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SessionsUiState())

    fun setFilter(value: SessionFilter) {
        filter.value = value
    }

    fun setQuery(value: String) {
        query.value = value
    }

    fun setSwiping(value: Boolean) {
        swiping.value = value
    }

    fun togglePin(row: SessionRow) = act { engine.sessions.setPinned(row.id, !row.pinned) }

    fun toggleArchive(row: SessionRow) = act {
        engine.sessions.setArchived(row.id, !row.archived)
        if (!row.archived) _events.trySend(SessionsEvent.Archived(row.id))
    }

    fun unarchive(sessionDocId: String) = act { engine.sessions.setArchived(sessionDocId, false) }

    fun stop(row: SessionRow) = act { engine.commands.stop(row.id) }

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
