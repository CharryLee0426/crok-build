package dev.chenli.crok.mobile.ui.session

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.PendingInteraction
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.data.relayCode
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.OptimisticPrompt
import dev.chenli.crok.mobile.logic.PlanSummary
import dev.chenli.crok.mobile.logic.Transcript
import dev.chenli.crok.mobile.logic.TranscriptItem
import java.time.ZoneId
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The header's subtitle (connection trouble overrides it). [Offline]: the session's computer is offline. */
enum class SessionPhase { Working, Waiting, Idle, Offline, Error }

data class SessionUiState(
    val title: String = "",
    val deviceName: String = "",
    /** The computer is online (a crok runs there), whether or not it runs this session. */
    val deviceOnline: Boolean = false,
    /** `none` / `requested`: the transcript is still only on the computer (a session listed from its disk). */
    val historyState: String? = null,
    val phase: SessionPhase = SessionPhase.Idle,
    val connection: ConnectionState = ConnectionState.Connected,
    val plan: List<PlanEntry> = emptyList(),
    val planSummary: PlanSummary? = null,
    val items: List<TranscriptItem> = emptyList(),
    val loaded: Boolean = false,
    val historyComplete: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    /** The relay no longer has this session. */
    val gone: Boolean = false,
    /** A permission request the session waits on while a crok runs it: a card with its choices above the composer. */
    val pending: PendingInteraction? = null,
    /** This phone answered [pending] and waits for the computer to take the answer. */
    val answering: Boolean = false,
) {
    /** Prompts go wherever the computer is online: one for a session nobody runs opens it there. */
    val canSend: Boolean get() = phase != SessionPhase.Offline && !gone
    val running: Boolean get() = phase == SessionPhase.Working

    /** Nothing to show yet because the transcript is still on the computer: it loads while that is online. */
    val historyOnComputer: Boolean get() = loaded && items.isEmpty() && HistoryState.onComputerOnly(historyState)

    companion object {
        /** [online]: a crok runs the session; [deviceOnline]: its computer is online (it opens the session for a prompt). */
        fun phaseOf(status: String, online: Boolean, deviceOnline: Boolean): SessionPhase = when {
            !online && !deviceOnline -> SessionPhase.Offline
            !online -> SessionPhase.Idle
            status == SessionStatus.RUNNING -> SessionPhase.Working
            status == SessionStatus.WAITING -> SessionPhase.Waiting
            status == SessionStatus.ERROR -> SessionPhase.Error
            else -> SessionPhase.Idle
        }

        /** Pure: the screen for these inputs (shared by the view model and the screenshot tests). */
        fun build(
            row: SessionRow?,
            detail: SessionDetail?,
            gone: Boolean,
            transcript: TranscriptState,
            prompts: List<PromptCommand>,
            optimistic: List<OptimisticPrompt>,
            connection: ConnectionState,
            zone: ZoneId,
            answering: String? = null,
        ): SessionUiState {
            val status = detail?.status ?: row?.status ?: SessionStatus.IDLE
            val online = detail?.online ?: row?.online ?: false
            val deviceOnline = detail?.deviceOnline ?: row?.deviceOnline ?: false
            val phase = phaseOf(status, online, deviceOnline)
            val plan = detail?.plan.orEmpty()
            // Only a crok that runs the session can take an answer: a stale request of a closed one is not shown.
            val pending = detail?.pending?.takeIf { detail.online }
            return SessionUiState(
                title = detail?.title ?: row?.title.orEmpty(),
                deviceName = detail?.deviceName ?: row?.deviceName.orEmpty(),
                deviceOnline = deviceOnline,
                historyState = if (detail != null) detail.historyState else row?.historyState,
                phase = phase,
                connection = connection,
                plan = plan,
                planSummary = PlanSummary.of(plan),
                items = Transcript.build(
                    events = transcript.events,
                    prompts = prompts,
                    optimistic = optimistic,
                    sessionRunning = phase == SessionPhase.Working,
                    historyComplete = transcript.historyComplete,
                    zone = zone,
                ),
                loaded = transcript.loaded,
                historyComplete = transcript.historyComplete,
                loadingMore = transcript.loadingMore,
                error = transcript.error?.message,
                gone = gone,
                pending = pending,
                answering = pending != null && pending.id == answering,
            )
        }
    }
}

sealed interface SessionEvent {
    data class StopFailed(val message: String) : SessionEvent
    data class AnswerFailed(val message: String) : SessionEvent
}

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class SessionViewModel(
    private val engine: CrokEngine,
    val sessionDocId: String,
    private val drafts: DraftStore,
    private val zone: ZoneId = ZoneId.systemDefault(),
) : ViewModel() {
    private val pager = engine.events.pager(sessionDocId, viewModelScope).also { it.start() }
    private val optimistic = MutableStateFlow<List<OptimisticPrompt>>(emptyList())
    private val visible = MutableStateFlow(false)
    private val _events = Channel<SessionEvent>(Channel.BUFFERED)
    val events: Flow<SessionEvent> = _events.receiveAsFlow()

    /** The composer's text; saved per session so it survives the app being killed (Telegram's saveDraft). */
    var draft by mutableStateOf(drafts.load(sessionDocId))
        private set

    private val detail = engine.sessions.get(sessionDocId)
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val prompts: StateFlow<List<PromptCommand>> = engine.commands.forSession(sessionDocId)
        .mapNotNull { it.getOrNull() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val row = engine.sessions.active.map { list -> list.rows.firstOrNull { it.id == sessionDocId } }

    /** The pending request this phone answered, until the computer takes the answer (the request leaves the session). */
    private val answering = MutableStateFlow<String?>(null)

    private val header = combine(row, detail, answering) { r, d, a -> Triple(r, d, a) }

    val state: StateFlow<SessionUiState> = combine(
        header,
        pager.state,
        prompts,
        optimistic,
        engine.connection.delayedForDisplay(),
    ) { (r, d, a), transcript, commands, mine, connection ->
        val detailResult = d
        val gone = detailResult != null && detailResult.isSuccess && detailResult.getOrNull() == null
        SessionUiState.build(r, detailResult?.getOrNull(), gone, transcript, commands, mine, connection, zone, answering = a)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SessionUiState())

    init {
        // "I'm watching": on open and every 60 s while the screen is visible, so the computer streams finely. It also
        // asks for a listed session's history, so it goes again at once when the computer comes back online.
        val deviceOnline = detail.map { it?.getOrNull()?.deviceOnline == true }.distinctUntilChanged()
        viewModelScope.launch {
            combine(visible, deviceOnline) { shown, _ -> shown }.collectLatest { shown ->
                while (shown) {
                    runCatching { engine.sessions.watch(sessionDocId) }
                    delay(WATCH_INTERVAL_MS)
                }
            }
        }
        // Read on open, and whenever a new reply arrives while the screen is visible.
        viewModelScope.launch {
            combine(visible, detail.map { it?.getOrNull()?.unread ?: 0 }) { shown, unread -> shown && unread > 0 }
                .distinctUntilChanged()
                .filter { it }
                .collect { runCatching { engine.sessions.markRead(sessionDocId) } }
        }
        // "Answering…" ends once the request is gone from the session (the computer took an answer, maybe another's).
        viewModelScope.launch {
            detail.map { it?.getOrNull()?.pending?.id }.distinctUntilChanged().collect { pendingId ->
                answering.update { if (it != null && it != pendingId) null else it }
            }
        }
    }

    fun setVisible(value: Boolean) {
        visible.value = value
    }

    fun updateDraft(text: String) {
        draft = text
        drafts.save(sessionDocId, text)
    }

    fun loadMore() = pager.loadMore()

    fun reload() = pager.reload()

    /** Sends the draft: an optimistic bubble at once (clock), then the relay's ticks. */
    fun send() {
        val text = draft.trim()
        if (text.isEmpty()) return
        val prompt = OptimisticPrompt(clientId = UUID.randomUUID().toString(), text = text, createdAt = engine.clock())
        optimistic.update { it + prompt }
        updateDraft("")
        submit(prompt)
    }

    private fun submit(prompt: OptimisticPrompt) {
        viewModelScope.launch {
            try {
                val commandId = engine.commands.sendPrompt(sessionDocId, prompt.text, prompt.clientId)
                replace(prompt.clientId) { it.copy(commandId = commandId, localError = null) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                replace(prompt.clientId) { it.copy(localError = describe(e)) }
            }
        }
    }

    /** Retry a failed prompt: the relay's `retry` for a failed command, a resend (same client id) for a failed send. */
    fun retry(item: TranscriptItem.User) {
        val local = optimistic.value.firstOrNull { it.clientId == item.clientId }
        val commandId = item.commandId
        viewModelScope.launch {
            try {
                if (local != null && local.commandId == null) {
                    replace(local.clientId) { it.copy(localError = null) }
                    submit(local.copy(localError = null))
                } else if (commandId != null) {
                    local?.let { replace(it.clientId) { p -> p.copy(localError = null) } }
                    engine.commands.retry(commandId)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                local?.let { replace(it.clientId) { p -> p.copy(localError = describe(e)) } }
            }
        }
    }

    /** Delete a failed prompt (Telegram's "Delete" on a failed message). */
    fun discard(item: TranscriptItem.User) {
        optimistic.update { list -> list.filterNot { it.clientId == item.clientId } }
        val commandId = item.commandId ?: return
        viewModelScope.launch { runCatching { engine.commands.discard(commandId) } }
    }

    fun stop() {
        viewModelScope.launch {
            try {
                engine.commands.stop(sessionDocId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _events.trySend(SessionEvent.StopFailed(describe(e)))
            }
        }
    }

    /**
     * Answers the pending permission request with one of its options, as if clicked on the computer. The card's buttons
     * stay disabled until the request leaves the session. `EXPIRED` (someone answered first) is not worth a message.
     */
    fun answer(interactionId: String, optionId: String) {
        if (answering.value == interactionId) return
        answering.value = interactionId
        viewModelScope.launch {
            try {
                engine.commands.answer(sessionDocId, interactionId, optionId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                answering.update { if (it == interactionId) null else it }
                if (e.relayCode != RelayErrorCode.EXPIRED) _events.trySend(SessionEvent.AnswerFailed(describe(e)))
            }
        }
    }

    private fun replace(clientId: String, change: (OptimisticPrompt) -> OptimisticPrompt) {
        optimistic.update { list -> list.map { if (it.clientId == clientId) change(it) else it } }
    }

    private fun describe(e: Exception): String = when (e) {
        is RelayException -> if (e.code == RelayErrorCode.UNKNOWN) e.message.orEmpty() else e.message ?: e.code.name
        is RelayNetworkException -> e.message ?: "Network error"
        else -> e.message ?: e.javaClass.simpleName
    }

    override fun onCleared() {
        pager.close()
    }

    companion object {
        const val WATCH_INTERVAL_MS = 60_000L
    }
}
