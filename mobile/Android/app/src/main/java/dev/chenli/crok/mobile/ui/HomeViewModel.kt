package dev.chenli.crok.mobile.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.ComputerSelectionStore
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.logic.ComputerAccount
import dev.chenli.crok.mobile.logic.Computers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** The person's computers (their "accounts") and which one the Sessions tab shows. */
data class ComputerState(
    val computers: List<ComputerAccount> = emptyList(),
    val selected: ComputerAccount? = null,
    /** The selected computer's projects, in the relay's order. */
    val projects: List<SessionGroup> = emptyList(),
    /** The session list has an answer (cache or relay). */
    val listed: Boolean = false,
    /** `devices:list` answered. */
    val devicesLoaded: Boolean = false,
) {
    val selectedId: String? get() = selected?.deviceId

    /** The Sessions tab's badge. */
    val unreadHere: Int get() = selected?.unread ?: 0

    /** The Profile tab's badge: unread on the other computers. */
    val unreadElsewhere: Int get() = Computers.unreadElsewhere(computers, selectedId)

    companion object {
        fun build(groups: List<SessionGroup>, listed: Boolean, devices: List<Device>?, remembered: String?): ComputerState {
            val computers = Computers.list(devices, groups)
            val selected = Computers.selected(computers, remembered)
            return ComputerState(
                computers = computers,
                selected = selected,
                projects = Computers.projects(groups, selected?.deviceId),
                listed = listed,
                devicesLoaded = devices != null,
            )
        }
    }
}

/**
 * Remembers the default computer the first time both the relay's session list (not the cache) and `devices:list` have
 * answered, and again only when the remembered one is gone (signed out): until then the selection would follow "most
 * recently active" on every new value. A silent pin, not a switch (no [HomeEvent.ComputerChanged]).
 */
internal fun settleSelectedComputer(
    selection: ComputerSelectionStore,
    computers: List<ComputerAccount>,
    live: Boolean,
    devicesLoaded: Boolean,
) {
    if (!live || !devicesLoaded) return
    val remembered = selection.selected.value
    if (remembered != null && computers.any { it.deviceId == remembered }) return
    Computers.selected(computers, null)?.let { selection.select(it.deviceId) }
}

/** The signed-in account as the Profile tab and header show it. */
data class AccountInfo(val name: String, val email: String?, val imageUrl: String?)

sealed interface HomeEvent {
    /** Another computer was picked: the Sessions tab goes back to its root. */
    data object ComputerChanged : HomeEvent
    data class Failed(val message: String) : HomeEvent
}

/** The home screen's shared state: computers, the selection, the account, Mark All as Read. */
class HomeViewModel(private val engine: CrokEngine, private val selection: ComputerSelectionStore) : ViewModel() {
    /** `devices:list`, shared by the switcher, Profile and its Devices count. */
    val devices: StateFlow<List<Device>?> = engine.devices.list()
        .map { it.getOrNull() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val computers: StateFlow<ComputerState> = combine(engine.sessions.active, devices, selection.selected) { list, devices, remembered ->
        ComputerState.build(list.groups, list.live || list.groups.isNotEmpty(), devices, remembered)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ComputerState())

    val account: StateFlow<AccountInfo> = engine.accounts.me().map { result ->
        val me = result.getOrNull()
        val user = engine.account.user
        AccountInfo(
            name = me?.name ?: user.name ?: me?.email ?: user.email ?: "",
            email = me?.email ?: user.email,
            imageUrl = me?.imageUrl ?: user.imageUrl,
        )
    }.stateIn(
        viewModelScope,
        SharingStarted.Eagerly,
        engine.account.user.let { AccountInfo(it.name ?: it.email ?: "", it.email, it.imageUrl) },
    )

    private val _events = Channel<HomeEvent>(Channel.BUFFERED)
    val events: Flow<HomeEvent> = _events.receiveAsFlow()

    init {
        // Pin the default computer once the relay has answered, so the tab never jumps to whichever computer's
        // sessions become the most recently active later (iOS: CrokEngine.settleSelectedComputer).
        viewModelScope.launch {
            combine(engine.sessions.active, devices) { list, devices -> list to devices }.collect { (list, devices) ->
                settleSelectedComputer(selection, Computers.list(devices, list.groups), live = list.live, devicesLoaded = devices != null)
            }
        }
    }

    /** Picks the computer the Sessions tab shows (the switcher, Profile's list). */
    fun select(deviceId: String) {
        val changed = computers.value.selectedId != deviceId
        selection.select(deviceId)
        if (changed) _events.trySend(HomeEvent.ComputerChanged)
    }

    /** Long press on Sessions › Mark All as Read: every unread session of the selected computer. */
    fun markAllRead() = markRead(Computers.unreadSessionIds(computers.value.projects))

    /** A project's Read, or the project screen's Mark All as Read. */
    fun markProjectRead(projectKey: String) =
        markRead(Computers.unreadSessionIds(engine.sessions.active.value.groups.filter { it.key == projectKey }))

    private fun markRead(ids: Set<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch {
            try {
                engine.sessions.markRead(ids)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _events.trySend(HomeEvent.Failed(e.message ?: e.javaClass.simpleName))
            }
        }
    }
}
