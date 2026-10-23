package dev.chenli.crok.mobile.ui.session

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.ConfigId
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.PendingInteraction
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.chenli.crok.mobile.data.SessionCommands
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.data.SlashCommand
import dev.chenli.crok.mobile.data.relayCode
import dev.chenli.crok.mobile.data.string
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.TranscriptPager
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.BotCard
import dev.chenli.crok.mobile.logic.BotCardKind
import dev.chenli.crok.mobile.logic.BotCardProblem
import dev.chenli.crok.mobile.logic.ChoiceMatch
import dev.chenli.crok.mobile.logic.CommandEntry
import dev.chenli.crok.mobile.logic.ComposerCommands
import dev.chenli.crok.mobile.logic.LocalCommand
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** The header's subtitle (connection trouble overrides it). [Offline]: the session's computer is offline. */
enum class SessionPhase { Working, Waiting, Idle, Offline, Error }

/**
 * Where a new session will start (relay/DESIGN.md §5, "New sessions"): a folder on a computer. The new-session screen is
 * shaped like a session and becomes that session once the first prompt created it.
 */
data class NewSessionTarget(
    val deviceId: String,
    val path: String,
    val deviceName: String,
    val projectName: String,
)

/** The session's model and thinking-level choices, for `/model`, `/think` and their bot cards. */
data class ModelState(
    /** Null: nothing to choose from (the computer is offline, or its crok too old to say). */
    val models: List<ModelChoice>? = null,
    val current: ModelChoice? = null,
    /** The session's model as the relay names it (when [current] is not among [models]). */
    val modelName: String? = null,
    /** The session's canonical thinking level. */
    val effort: String? = null,
) {
    val hasThinking: Boolean get() = current?.efforts?.isNotEmpty() == true
}

data class SessionUiState(
    /** The session's relay id (its topic glyph's colour); null on the new-session screen. */
    val sessionDocId: String? = null,
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
    /** The new-session screen, before its first prompt made the session (then null). */
    val newSession: NewSessionTarget? = null,
    /** Made by `sessions:create` and not open on its computer yet. */
    val starting: Boolean = false,
    /** The command list's rows: the phone's commands that apply, then the session's own. */
    val localCommands: List<CommandEntry> = emptyList(),
    val sessionCommands: List<SlashCommand> = emptyList(),
    val models: ModelState = ModelState(),
) {
    /** Prompts go wherever the computer is online: one for a session nobody runs opens it there. */
    val canSend: Boolean get() = (newSession != null || phase != SessionPhase.Offline) && !gone
    val running: Boolean get() = phase == SessionPhase.Working

    /** The Menu button: only in a session (a new one has no commands yet). */
    val hasMenu: Boolean get() = newSession == null

    /** Nothing to show yet because the transcript is still on the computer: it loads while that is online. */
    val historyOnComputer: Boolean get() = loaded && items.isEmpty() && HistoryState.onComputerOnly(historyState)

    companion object {
        /**
         * [online]: a crok runs the session; [deviceOnline]: its computer is online (it opens the session for a prompt);
         * [starting]: made from a device and not open there yet — it works on its first prompt, or failed to open.
         */
        fun phaseOf(status: String, online: Boolean, deviceOnline: Boolean, starting: Boolean = false): SessionPhase = when {
            !online && !deviceOnline -> SessionPhase.Offline
            !online && starting && status == SessionStatus.RUNNING -> SessionPhase.Working
            !online && status == SessionStatus.ERROR -> SessionPhase.Error
            !online -> SessionPhase.Idle
            status == SessionStatus.RUNNING -> SessionPhase.Working
            status == SessionStatus.WAITING -> SessionPhase.Waiting
            status == SessionStatus.ERROR -> SessionPhase.Error
            else -> SessionPhase.Idle
        }

        /** The phone's commands as list rows (descriptions come from the screen's strings). */
        fun localEntries(running: Boolean, hasThinking: Boolean): List<CommandEntry> =
            ComposerCommands.local(running, hasThinking).map { CommandEntry(it.command, it) }

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
            newSession: NewSessionTarget? = null,
            commands: SessionCommands? = null,
            cards: List<BotCard> = emptyList(),
        ): SessionUiState {
            val status = detail?.status ?: row?.status ?: SessionStatus.IDLE
            val online = detail?.online ?: row?.online ?: false
            val deviceOnline = detail?.deviceOnline ?: row?.deviceOnline ?: (newSession != null)
            val starting = detail?.starting ?: row?.starting ?: false
            val phase = phaseOf(status, online, deviceOnline, starting)
            val plan = detail?.plan.orEmpty()
            // Only a crok that runs the session can take an answer: a stale request of a closed one is not shown.
            val pending = detail?.pending?.takeIf { detail.online }
            val models = ModelState(
                models = detail?.models,
                current = detail?.currentModel,
                modelName = detail?.model,
                effort = detail?.effort,
            )
            return SessionUiState(
                sessionDocId = detail?.id ?: row?.id,
                title = detail?.title ?: row?.title.orEmpty(),
                deviceName = detail?.deviceName ?: row?.deviceName ?: newSession?.deviceName.orEmpty(),
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
                    cards = cards,
                ),
                loaded = transcript.loaded,
                historyComplete = transcript.historyComplete,
                loadingMore = transcript.loadingMore,
                error = transcript.error?.message,
                gone = gone,
                pending = pending,
                answering = pending != null && pending.id == answering,
                newSession = newSession,
                starting = starting,
                localCommands = localEntries(phase == SessionPhase.Working, models.hasThinking),
                sessionCommands = commands?.commands.orEmpty(),
                models = models,
            )
        }
    }
}

sealed interface SessionEvent {
    data class StopFailed(val message: String) : SessionEvent
    data class AnswerFailed(val message: String) : SessionEvent

    /** `/info`: show the info sheet. */
    data object ShowInfo : SessionEvent

    /** `/new [prompt]`: a new session in this session's project, started with [prompt] at once when there is one. */
    data class NewSession(val target: NewSessionTarget, val prompt: String?) : SessionEvent

    /** `/new` could not tell where (the session's project is unknown). */
    data object NewSessionUnavailable : SessionEvent
}

/**
 * One session's screen — or, with [newSession], the new-session screen, which turns into the session once its first
 * prompt has created it (`sessions:create`), in the same navigation entry.
 */
@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class SessionViewModel(
    private val engine: CrokEngine,
    initialSessionDocId: String?,
    private val drafts: DraftStore,
    private val zone: ZoneId = ZoneId.systemDefault(),
    private val newSession: NewSessionTarget? = null,
    /** `/new <prompt>` from another session: sent as this new session's first prompt at once. */
    firstPrompt: String? = null,
    /**
     * The new-session screen's saved state: the session it created, so a screen restored after the app was killed shows
     * that session again instead of an empty new one.
     */
    private val saved: SavedStateHandle? = null,
    /** The first prompt's client id, stable across a restore so a resend finds the same session (the relay dedupes). */
    firstPromptClientId: String? = null,
) : ViewModel() {
    private val restoredSessionDocId: String? = saved?.get<String>(CREATED_KEY)
    private val docId = MutableStateFlow(initialSessionDocId ?: restoredSessionDocId)

    /** The session shown; null on the new-session screen until its first prompt made it. */
    val sessionDocId: String? get() = docId.value

    private val pager = MutableStateFlow(docId.value?.let(::startPager))
    private val optimistic = MutableStateFlow<List<OptimisticPrompt>>(emptyList())
    private val cards = MutableStateFlow<List<BotCard>>(emptyList())
    private val visible = MutableStateFlow(false)
    private val _events = Channel<SessionEvent>(Channel.BUFFERED)
    val events: Flow<SessionEvent> = _events.receiveAsFlow()

    private val draftKey: String get() = docId.value ?: newSession?.let { "new:${it.deviceId}:${it.path}" } ?: ""


    /** The composer's text; saved per session so it survives the app being killed (Telegram's saveDraft). */
    var draft by mutableStateOf(drafts.load(draftKey))
        private set

    private val detail = docId.flatMapLatest { id -> if (id == null) flowOf(null) else engine.sessions.get(id) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val prompts: StateFlow<List<PromptCommand>> = docId
        .flatMapLatest { id -> if (id == null) flowOf(emptyList()) else engine.commands.forSession(id).mapNotNull { it.getOrNull() } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val commands: StateFlow<SessionCommands?> = docId
        .flatMapLatest { id -> if (id == null) flowOf(null) else engine.sessions.commands(id).map { it.getOrNull() } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val row = combine(engine.sessions.active, docId) { list, id -> id?.let { list.rows.firstOrNull { it.id == id } } }

    /** The pending request this phone answered, until the computer takes the answer (the request leaves the session). */
    private val answering = MutableStateFlow<String?>(null)

    private val transcript: Flow<TranscriptState> = pager.flatMapLatest { current ->
        current?.state ?: flowOf(TranscriptState(loaded = true, historyComplete = true))
    }

    private data class Header(val row: SessionRow?, val detail: Result<SessionDetail?>?, val answering: String?, val id: String?)

    private data class Local(val optimistic: List<OptimisticPrompt>, val cards: List<BotCard>, val commands: SessionCommands?)

    private val header = combine(row, detail, answering, docId) { r, d, a, id -> Header(r, d, a, id) }

    private val local = combine(optimistic, cards, commands) { o, c, s -> Local(o, c, s) }

    val state: StateFlow<SessionUiState> = combine(
        header,
        transcript,
        prompts,
        local,
        engine.connection.delayedForDisplay(),
    ) { h, transcript, commandList, mine, connection ->
        val detailResult = h.detail
        val gone = h.id != null && detailResult != null && detailResult.isSuccess && detailResult.getOrNull() == null
        SessionUiState.build(
            h.row, detailResult?.getOrNull(), gone, transcript, commandList, mine.optimistic, connection, zone,
            answering = h.answering,
            newSession = if (h.id == null) newSession else null,
            commands = mine.commands,
            cards = mine.cards,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SessionUiState(newSession = newSession, loaded = newSession != null))

    init {
        // "I'm watching": on open and every 60 s while the screen is visible, so the computer streams finely. It also
        // asks for a listed session's history, so it goes again at once when the computer comes back online.
        val deviceOnline = detail.map { it?.getOrNull()?.deviceOnline == true }.distinctUntilChanged()
        viewModelScope.launch {
            combine(visible, deviceOnline, docId) { shown, _, id -> if (shown) id else null }.collectLatest { id ->
                while (id != null) {
                    runCatching { engine.sessions.watch(id) }
                    delay(WATCH_INTERVAL_MS)
                }
            }
        }
        // Read on open, and whenever a new reply arrives while the screen is visible.
        viewModelScope.launch {
            combine(visible, detail.map { it?.getOrNull()?.unread ?: 0 }) { shown, unread -> shown && unread > 0 }
                .distinctUntilChanged()
                .filter { it }
                .collect { docId.value?.let { id -> runCatching { engine.sessions.markRead(id) } } }
        }
        // "Answering…" ends once the request is gone from the session (the computer took an answer, maybe another's).
        viewModelScope.launch {
            detail.map { it?.getOrNull()?.pending?.id }.distinctUntilChanged().collect { pendingId ->
                answering.update { if (it != null && it != pendingId) null else it }
            }
        }
        firstPrompt?.trim()?.takeIf { it.isNotEmpty() && newSession != null && docId.value == null }?.let { text ->
            val clientId = firstPromptClientId ?: UUID.randomUUID().toString()
            val prompt = OptimisticPrompt(clientId = clientId, text = text, createdAt = engine.clock())
            optimistic.update { it + prompt }
            submit(prompt)
        }
    }

    private fun startPager(sessionDocId: String): TranscriptPager = engine.events.pager(sessionDocId, viewModelScope).also { it.start() }

    fun setVisible(value: Boolean) {
        visible.value = value
    }

    fun updateDraft(text: String) {
        draft = text
        drafts.save(draftKey, text)
    }

    fun loadMore() = pager.value?.loadMore() ?: Unit

    fun reload() = pager.value?.reload() ?: Unit

    /**
     * Sends the draft: the phone's own commands run here (`/new`, `/model`, `/think`, `/stop`, `/info`); anything else —
     * the session's commands (`/compact`) and unknown ones alike — goes to the computer as a prompt, an optimistic bubble
     * at once (clock), then the relay's ticks. On the new-session screen it creates the session.
     */
    fun send() {
        val text = draft.trim()
        if (text.isEmpty()) return
        val command = if (docId.value != null) ComposerCommands.parse(text) else null
        if (command?.local != null && runLocal(command.local, command.argument)) {
            updateDraft("")
            return
        }
        val prompt = OptimisticPrompt(clientId = UUID.randomUUID().toString(), text = text, createdAt = engine.clock())
        optimistic.update { it + prompt }
        updateDraft("")
        submit(prompt)
    }

    /**
     * A row of the command list: one that takes arguments fills the field with `/name ` for the rest; the others run at
     * once.
     */
    fun pickCommand(entry: CommandEntry) {
        if (entry.takesArguments) {
            updateDraft("/${entry.name} ")
            return
        }
        updateDraft("/${entry.name}")
        send()
    }

    /** Runs one of the phone's commands; false when it does not apply here (then the text goes as a prompt). */
    private fun runLocal(command: LocalCommand, argument: String?): Boolean {
        when (command) {
            LocalCommand.New -> {
                val target = projectTarget()
                if (target == null) _events.trySend(SessionEvent.NewSessionUnavailable) else _events.trySend(SessionEvent.NewSession(target, argument))
            }
            LocalCommand.Model -> modelCommand(argument)
            LocalCommand.Think -> thinkCommand(argument)
            LocalCommand.Stop -> stop()
            LocalCommand.Info -> _events.trySend(SessionEvent.ShowInfo)
        }
        return true
    }

    /** This session's project, for `/new`. */
    private fun projectTarget(): NewSessionTarget? {
        val d = detail.value?.getOrNull()
        val r = engine.sessions.active.value.rows.firstOrNull { it.id == docId.value }
        val deviceId = d?.deviceId ?: r?.deviceId ?: return null
        val path = (d?.projectPath ?: r?.projectPath).orEmpty().ifBlank { d?.cwd ?: r?.cwd.orEmpty() }
        if (path.isBlank() || deviceId.isBlank()) return null
        val name = (d?.projectName ?: r?.projectName).orEmpty().ifBlank { path.trimEnd('/').substringAfterLast('/') }
        return NewSessionTarget(deviceId, path, d?.deviceName ?: r?.deviceName.orEmpty(), name)
    }

    private fun currentModels(): ModelState = state.value.models.takeIf { it.models != null } ?: detail.value?.getOrNull()?.let {
        ModelState(it.models, it.currentModel, it.model, it.effort)
    } ?: ModelState()

    /** `/model [name]`: a card with the choices, or with a name, the change at once. */
    private fun modelCommand(argument: String?) {
        val card = BotCard(id = UUID.randomUUID().toString(), kind = BotCardKind.Model, createdAt = engine.clock())
        cards.update { it + card }
        val models = currentModels().models ?: return
        if (argument == null) return
        when (val match = ComposerCommands.matchModel(argument, models)) {
            is ChoiceMatch.One -> applyConfig(card.id, match.choice.id)
            ChoiceMatch.Ambiguous -> updateCard(card.id) { it.copy(problem = BotCardProblem.Ambiguous(argument)) }
            ChoiceMatch.None -> updateCard(card.id) { it.copy(problem = BotCardProblem.NoMatch(argument)) }
        }
    }

    /** `/think [level]`: like `/model`, for the current model's thinking levels. */
    private fun thinkCommand(argument: String?) {
        val card = BotCard(id = UUID.randomUUID().toString(), kind = BotCardKind.Think, createdAt = engine.clock())
        cards.update { it + card }
        val efforts = currentModels().current?.efforts?.takeIf { it.isNotEmpty() } ?: return
        if (argument == null) return
        when (val match = ComposerCommands.matchEffort(argument, efforts)) {
            is ChoiceMatch.One -> applyConfig(card.id, match.choice.id)
            ChoiceMatch.Ambiguous -> updateCard(card.id) { it.copy(problem = BotCardProblem.Ambiguous(argument)) }
            ChoiceMatch.None -> updateCard(card.id) { it.copy(problem = BotCardProblem.NoMatch(argument)) }
        }
    }

    /**
     * A tap on a bot card's button (or a matched argument): `commands:setConfig`, the button spinning until the command
     * is done, then the card says what is set now and its keyboard folds away; a failure shows in the card.
     */
    fun applyConfig(cardId: String, value: String) {
        val id = docId.value ?: return
        val card = cards.value.firstOrNull { it.id == cardId } ?: return
        if (card.applying != null || card.done != null) return
        val configId = if (card.kind == BotCardKind.Model) ConfigId.MODEL else ConfigId.EFFORT
        updateCard(cardId) { it.copy(applying = value, problem = null) }
        viewModelScope.launch {
            try {
                val commandId = engine.commands.setConfig(id, configId, value)
                val done = engine.commands.get(commandId).mapNotNull { it.getOrNull() }
                    .first { it.status == CommandStatus.DONE || it.status == CommandStatus.FAILED }
                if (done.status == CommandStatus.FAILED) {
                    updateCard(cardId) { it.copy(applying = null, problem = BotCardProblem.Failed(done.error ?: "")) }
                } else {
                    val result = done.result as? JsonObject
                    updateCard(cardId) { it.copy(applying = null, done = labelFor(card.kind, value, result)) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                updateCard(cardId) { it.copy(applying = null, problem = BotCardProblem.Failed(describe(e))) }
            }
        }
    }

    /** "Grok 4", "High": the applied choice by name, from the command's result when it has one. */
    private fun labelFor(kind: BotCardKind, value: String, result: JsonObject?): String {
        val models = currentModels().models.orEmpty()
        return when (kind) {
            BotCardKind.Model -> {
                val id = result?.string("model") ?: value
                models.firstOrNull { it.id == id }?.label ?: id
            }
            BotCardKind.Think -> {
                val modelId = result?.string("model")
                val model = models.firstOrNull { it.id == modelId } ?: currentModels().current
                val level = result?.string("effort")
                val effort = model?.efforts?.firstOrNull { it.id == value }
                    ?: model?.efforts?.firstOrNull { it.level == level }
                effort?.label ?: level ?: value
            }
        }
    }

    private fun updateCard(cardId: String, change: (BotCard) -> BotCard) {
        cards.update { list -> list.map { if (it.id == cardId) change(it) else it } }
    }

    private fun submit(prompt: OptimisticPrompt) {
        viewModelScope.launch {
            try {
                val existing = docId.value
                if (existing == null && newSession != null) {
                    // The first prompt makes the session; the screen turns into it.
                    val created = engine.sessions.create(newSession.deviceId, newSession.path, prompt.text, prompt.clientId)
                    replace(prompt.clientId) { it.copy(commandId = created.commandId, localError = null) }
                    drafts.save(draftKey, "")
                    saved?.set(CREATED_KEY, created.sessionDocId)
                    pager.value = startPager(created.sessionDocId)
                    docId.value = created.sessionDocId
                } else if (existing != null) {
                    val commandId = engine.commands.sendPrompt(existing, prompt.text, prompt.clientId)
                    replace(prompt.clientId) { it.copy(commandId = commandId, localError = null) }
                }
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
                if (local != null && (local.commandId == null || docId.value == null)) {
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
        val id = docId.value ?: return
        viewModelScope.launch {
            try {
                engine.commands.stop(id)
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
        val id = docId.value ?: return
        if (answering.value == interactionId) return
        answering.value = interactionId
        viewModelScope.launch {
            try {
                engine.commands.answer(id, interactionId, optionId)
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

    /** The relay's own words where it has them (e.g. "update crok there"). */
    private fun describe(e: Exception): String = when (e) {
        is RelayException -> if (e.code == RelayErrorCode.UNKNOWN) e.message.orEmpty() else e.message ?: e.code.name
        is RelayNetworkException -> e.message ?: "Network error"
        else -> e.message ?: e.javaClass.simpleName
    }

    override fun onCleared() {
        pager.value?.close()
    }

    companion object {
        const val WATCH_INTERVAL_MS = 60_000L
        private const val CREATED_KEY = "createdSessionDocId"
    }
}
