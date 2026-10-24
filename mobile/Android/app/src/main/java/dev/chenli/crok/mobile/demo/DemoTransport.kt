package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.data.ApproveResult
import dev.chenli.crok.mobile.data.CommandDoc
import dev.chenli.crok.mobile.data.CommandRef
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.ConfigId
import dev.chenli.crok.mobile.data.CreateResult
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.SessionCommands
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.PendingOption
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.RevokeOthersResult
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.data.TranscriptChunk
import dev.chenli.crok.mobile.engine.RelayTransport
import dev.chenli.crok.mobile.logic.SessionOrder
import dev.chenli.crok.mobile.logic.UserCode
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * An in-memory relay answering the same function names as the real one, for demo mode and screenshots. With
 * [animate], prompts and answers are picked up, streamed and finished like a real computer would (a prompt for a
 * session nobody runs opens it on its computer first); without, commands stay where the relay leaves them, except
 * that an answer is taken at once.
 */
class DemoTransport(
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val animate: Boolean = true,
) : RelayTransport {
    private val state = MutableStateFlow(DemoData.state(clock()))
    private val turns = HashMap<String, Job>()

    /** Per session: the rest of a turn after its permission request was answered. */
    private val answers = HashMap<String, Job>()

    /** Requests the computer already took an answer for: later answers to them change nothing. */
    private val answered = HashSet<String>()

    /** Bumped by [refreshAuth]: like Convex after a new token, every subscription answers again. */
    private val identity = MutableStateFlow(0)

    override val connected: StateFlow<Boolean> = MutableStateFlow(true)

    override suspend fun authenticate(): Result<Unit> = Result.success(Unit)

    override suspend fun refreshAuth(): Result<Unit> {
        identity.update { it + 1 }
        return Result.success(Unit)
    }

    init {
        if (animate) finishStreamingReply()
    }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
        combine(state, identity) { current, version -> version to runCatching { answer(current, name, args) } }
            .distinctUntilChanged()
            .map { it.second }

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
        delay(if (animate) 150 else 0)
        if (state.value.revoked) throw RelayException(RelayErrorCode.REVOKED, "This device was signed out.")
        return mutate(name, args)
    }

    override fun close() {
        turns.values.forEach { it.cancel() }
        answers.values.forEach { it.cancel() }
    }

    // ---- Queries ----

    private fun answer(s: DemoState, name: String, args: Map<String, Any?>): JsonElement {
        if (s.revoked) throw RelayException(RelayErrorCode.REVOKED, "This device was signed out.")
        return when (name) {
            "users:me" -> RelayJson.encodeToJsonElement(Me.serializer(), s.me)
            "devices:list" -> RelayJson.encodeToJsonElement(ListSerializer(Device.serializer()), s.devices)
            "devices:models" -> {
                // As on the relay: the computer's list while it is online; null when it is offline or its crok publishes none.
                val device = s.devices.firstOrNull { it.id == args["deviceId"] && it.isComputer }
                    ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such computer.")
                val models = if (device.online) DemoData.modelsFor(device.id) else null
                RelayJson.encodeToJsonElement(ListSerializer(ModelChoice.serializer()).nullable, models)
            }
            "sessions:list" -> {
                val archived = args["archived"] == true
                val rows = s.sessions.filter { it.detail.archived == archived }
                    .sortedWith(compareByDescending<DemoSession> { it.detail.pinned }.thenByDescending { it.detail.lastActivityAt })
                    .map { it.row() }
                RelayJson.encodeToJsonElement(ListSerializer(dev.chenli.crok.mobile.data.SessionRow.serializer()), rows)
            }
            "sessions:groups" -> RelayJson.encodeToJsonElement(ListSerializer(SessionGroup.serializer()), DemoData.groups(s))
            "sessions:get" -> {
                val session = s.sessions.firstOrNull { it.id == args["sessionDocId"] }
                    ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such session.")
                val models = if (session.detail.deviceOnline) DemoData.modelsFor(session.detail.deviceId) else null
                RelayJson.encodeToJsonElement(SessionDetail.serializer(), session.detail.copy(unread = session.unread, models = models))
            }
            "sessions:commands" -> {
                val session = s.sessions.firstOrNull { it.id == args["sessionDocId"] }
                    ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such session.")
                // A session crok runs has its own list; one nobody runs gets its computer's last one; a fresh one none.
                val commands = when {
                    session.detail.starting -> SessionCommands()
                    session.detail.online -> SessionCommands(DemoData.slashCommands, "session")
                    else -> SessionCommands(DemoData.slashCommands, "computer")
                }
                RelayJson.encodeToJsonElement(SessionCommands.serializer(), commands)
            }
            "sessions:transcript" -> RelayJson.encodeToJsonElement(TranscriptChunk.serializer(), transcript(s, args))
            "commands:forSession" -> RelayJson.encodeToJsonElement(
                ListSerializer(dev.chenli.crok.mobile.data.PromptCommand.serializer()),
                s.commands.filter { it.sessionDocId == args["sessionDocId"] && (it.type == CommandType.PROMPT || it.type == CommandType.CREATE) }
                    .sortedByDescending { it.createdAt }
                    .map { it.prompt() },
            )
            "commands:get" -> {
                val command = s.commands.firstOrNull { it.id == args["commandId"] }
                RelayJson.encodeToJsonElement(
                    CommandDoc.serializer().nullable,
                    command?.let { CommandDoc(it.id, it.type, it.status, it.error, it.result, it.createdAt, it.updatedAt) },
                )
            }
            "deviceAuth:pendingLogin" -> {
                val code = UserCode.normalize(args["userCode"] as? String ?: "")
                RelayJson.encodeToJsonElement(
                    PendingLogin.serializer().nullable,
                    code?.let {
                        PendingLogin(it, "computer", "Mac mini", "macOS 26.1", "crok 1.0.45", clock() - 30_000, clock() + 9 * 60_000, "pending")
                    },
                )
            }
            else -> throw RelayException(RelayErrorCode.UNKNOWN, "The demo relay does not know $name")
        }
    }

    /** `sessions:transcript` as the relay answers it (see [transcriptChunk]). */
    private fun transcript(s: DemoState, args: Map<String, Any?>): TranscriptChunk {
        val sessionId = args["sessionDocId"] as? String
        if (s.sessions.none { it.id == sessionId }) throw RelayException(RelayErrorCode.NOT_FOUND, "No such session.")
        return transcriptChunk(
            s.events[sessionId].orEmpty(),
            afterSeq = (args["afterSeq"] as? Number)?.toLong(),
            throughSeq = (args["throughSeq"] as? Number)?.toLong(),
            limit = (args["limit"] as? Number)?.toInt() ?: 40,
        )
    }

    // ---- Mutations ----

    private fun mutate(name: String, args: Map<String, Any?>): JsonElement {
        val sessionDocId = args["sessionDocId"] as? String
        when (name) {
            "sessions:markRead" -> updateSession(sessionDocId) { it.copy(unread = 0) }
            "sessions:watch" -> requestHistory(session(sessionDocId))
            "sessions:reorderProjects" -> {
                val keys = strings(args["keys"])
                state.update { s ->
                    val order = SessionOrder.reorderWithin(DemoData.groups(s).map { it.key }, keys)
                    s.copy(projectPositions = order.withIndex().associate { (index, key) -> key to index })
                }
            }
            "sessions:reorderSessions" -> {
                val projectKey = args["projectKey"] as? String
                val wanted = strings(args["sessionDocIds"])
                state.update { s ->
                    val group = DemoData.groups(s).firstOrNull { it.key == projectKey }
                        ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such project.")
                    val positions = SessionOrder.reorderWithin(group.sessions.map { it.id }, wanted)
                        .withIndex().associate { (index, id) -> id to index }
                    s.copy(sessions = s.sessions.map { session -> positions[session.id]?.let { session.copy(position = it) } ?: session })
                }
            }
            "sessions:resetOrder" -> {
                val projectKey = args["projectKey"] as? String
                state.update { s ->
                    if (projectKey == null) {
                        s.copy(projectPositions = emptyMap())
                    } else {
                        s.copy(sessions = s.sessions.map { if (it.projectKey == projectKey) it.copy(position = null) else it })
                    }
                }
            }
            "sessions:setPinned" -> updateSession(sessionDocId) { it.copy(detail = it.detail.copy(pinned = args["pinned"] == true)) }
            "sessions:setArchived" -> updateSession(sessionDocId) {
                val archived = args["archived"] == true
                it.copy(detail = it.detail.copy(archived = archived, pinned = if (archived) false else it.detail.pinned))
            }
            "sessions:remove" -> {
                val session = session(sessionDocId)
                if (session.detail.online) throw RelayException(RelayErrorCode.INVALID, "Close the session on the computer first, or archive it.")
                state.update { s -> s.copy(sessions = s.sessions.filterNot { it.id == sessionDocId }) }
            }
            "commands:sendPrompt" -> return sendPrompt(sessionDocId, args["text"] as? String ?: "", args["clientId"] as? String)
            "sessions:create" -> return create(
                args["deviceId"] as? String,
                args["path"] as? String,
                args["text"] as? String,
                args["clientId"] as? String,
                args["model"] as? String,
                args["effort"] as? String,
            )
            "commands:setConfig" -> return setConfig(sessionDocId, args["configId"] as? String, args["value"] as? String)
            "commands:stop" -> {
                val session = session(sessionDocId)
                val id = newCommand(session.id, "cancel", status = CommandStatus.DONE)
                if (session.detail.online) stopTurn(session.id) else dropWaitingPrompts(session.id)
                return ref(id)
            }
            "commands:requestInfo" -> {
                val session = session(sessionDocId)
                // Nobody runs it: the relay answers at once with what its computer last sent.
                if (!session.detail.online) return ref(newCommand(session.id, "info", status = CommandStatus.DONE, result = storedInfo(session)))
                val id = newCommand(session.id, "info")
                scope.launch {
                    delay(if (animate) 900 else 0)
                    val usage = session.detail.usage
                    val result = buildJsonObject {
                        session.detail.model?.let { put("model", it) }
                        session.detail.effort?.let { put("effort", it) }
                        put("cwd", session.detail.cwd)
                        session.detail.gitBranch?.let { put("gitBranch", it) }
                        put("title", session.detail.title)
                        put("createdAt", session.detail.createdAt.toDouble())
                        put(
                            "usage",
                            buildJsonObject {
                                put("inputTokens", (usage?.inputTokens ?: 0L).toDouble() + 2_400)
                                put("outputTokens", (usage?.outputTokens ?: 0L).toDouble() + 310)
                                put("cachedTokens", (usage?.cachedTokens ?: 0L).toDouble())
                                put("reasoningTokens", (usage?.reasoningTokens ?: 0L).toDouble())
                                put("costUsd", (usage?.costUsd ?: 0.0) + 0.01)
                            },
                        )
                        put(
                            "context",
                            buildJsonObject {
                                put("used", ((usage?.contextTokens ?: 0L) + 2_710).toDouble())
                                put("window", (usage?.contextWindow ?: 256_000L).toDouble())
                            },
                        )
                        put("messages", 14.0)
                        put("sessionId", session.detail.sessionId)
                    }
                    updateCommand(id) { it.copy(status = CommandStatus.DONE, result = result, updatedAt = clock()) }
                }
                return ref(id)
            }
            "commands:retry" -> {
                val id = args["commandId"] as? String
                val command = state.value.commands.firstOrNull { it.id == id }
                    ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such prompt.")
                requireReachable(command.sessionDocId)
                updateCommand(command.id) { it.copy(status = CommandStatus.PENDING, error = null, updatedAt = clock()) }
                runPrompt(command.sessionDocId, command.id, command.text)
            }
            "commands:answer" -> return answer(sessionDocId, args["interactionId"] as? String, args["optionId"] as? String)
            "commands:discard" -> {
                val id = args["commandId"] as? String
                state.update { s -> s.copy(commands = s.commands.filterNot { it.id == id && it.status == CommandStatus.FAILED }) }
            }
            "devices:revoke" -> {
                val id = args["deviceId"] as? String
                state.update { s ->
                    s.copy(
                        devices = s.devices.filterNot { it.id == id },
                        revoked = s.revoked || id == DemoData.PHONE_ID,
                        sessions = s.sessions.map { session ->
                            if (session.detail.deviceId == id) {
                                session.copy(detail = session.detail.copy(online = false, deviceOnline = false, status = SessionStatus.IDLE, pending = null))
                            } else {
                                session
                            }
                        },
                    )
                }
            }
            "devices:revokeOthers" -> {
                val others = state.value.devices.count { !it.isCurrent }
                state.update { s -> s.copy(devices = s.devices.filter { it.isCurrent }) }
                return RelayJson.encodeToJsonElement(RevokeOthersResult.serializer(), RevokeOthersResult(others))
            }
            "devices:rename" -> {
                val id = args["deviceId"] as? String
                val newName = (args["name"] as? String).orEmpty().trim()
                state.update { s -> s.copy(devices = s.devices.map { if (it.id == id) it.copy(name = newName) else it }) }
            }
            "deviceAuth:approve" -> {
                val code = UserCode.normalize(args["userCode"] as? String ?: "")
                    ?: throw RelayException(RelayErrorCode.NOT_FOUND, "That code is not valid. Check it and try again.")
                val device = Device("demo-${code.lowercase()}", "computer", "Mac mini", "macOS 26.1", "crok 1.0.45", clock(), clock(), false, false, 0)
                state.update { s -> s.copy(devices = s.devices + device) }
                return RelayJson.encodeToJsonElement(ApproveResult.serializer(), ApproveResult(device.id, device.kind, device.name))
            }
            "deviceAuth:deny" -> Unit
            else -> throw RelayException(RelayErrorCode.UNKNOWN, "The demo relay does not know $name")
        }
        return JsonNull
    }

    private fun ref(id: String) = RelayJson.encodeToJsonElement(CommandRef.serializer(), CommandRef(id))

    private fun strings(value: Any?): List<String> = (value as? List<*>).orEmpty().filterIsInstance<String>()

    /**
     * `sessions:watch` on a session listed from disk: while its computer is online, "the computer" reads the transcript
     * and pushes it (`historyState` none → requested → ready); while it is offline nothing happens.
     */
    private fun requestHistory(session: DemoSession) {
        val detail = session.detail
        if (detail.online || !HistoryState.onComputerOnly(detail.historyState) || !detail.deviceOnline) return
        if (detail.historyState == HistoryState.REQUESTED) return
        updateSession(session.id) { it.copy(detail = it.detail.copy(historyState = HistoryState.REQUESTED)) }
        val deliver = {
            state.update { s ->
                val current = s.sessions.firstOrNull { it.id == session.id } ?: return@update s
                // A prompt opened it on the computer meanwhile, with its history.
                if (current.detail.historyState != HistoryState.REQUESTED) return@update s
                val events = DemoData.historyFromDisk(current)
                s.copy(
                    events = s.events + (session.id to events),
                    sessions = s.sessions.map {
                        if (it.id == session.id) it.copy(detail = it.detail.copy(historyState = HistoryState.READY, eventSeq = events.size.toLong())) else it
                    },
                )
            }
        }
        if (animate) {
            scope.launch {
                delay(1_800)
                deliver()
            }
        } else {
            deliver()
        }
    }

    private fun session(id: String?): DemoSession =
        state.value.sessions.firstOrNull { it.id == id } ?: throw RelayException(RelayErrorCode.NOT_FOUND, "No such session.")

    /** As on the relay: a session nobody runs still takes prompts while its computer is online (a crok there opens it). */
    private fun requireReachable(id: String?): DemoSession {
        val session = session(id)
        if (!session.detail.reachable) {
            throw RelayException(RelayErrorCode.OFFLINE, "${session.detail.deviceName} is offline: start crok or Crok Desktop there.")
        }
        return session
    }

    /** Stop for a session nobody runs: the prompts no computer picked up yet are dropped. */
    private fun dropWaitingPrompts(sessionDocId: String) {
        turns.remove(sessionDocId)?.cancel()
        state.value.commands.filter { it.sessionDocId == sessionDocId && it.type == "prompt" && it.status == CommandStatus.PENDING }.forEach { command ->
            updateCommand(command.id) { it.copy(status = CommandStatus.FAILED, error = "Stopped before it ran.", updatedAt = clock()) }
        }
    }

    /** The relay's answer to an info request for a session nobody runs: what its computer last reported. */
    private fun storedInfo(session: DemoSession): JsonElement {
        val detail = session.detail
        val usage = detail.usage
        return buildJsonObject {
            put("sessionId", detail.sessionId)
            put("title", detail.title)
            detail.model?.let { put("model", it) }
            detail.effort?.let { put("effort", it) }
            put("cwd", detail.cwd)
            detail.gitBranch?.let { put("gitBranch", it) }
            put("createdAt", detail.createdAt.toDouble())
            put(
                "usage",
                buildJsonObject {
                    usage?.inputTokens?.let { put("inputTokens", it.toDouble()) }
                    usage?.outputTokens?.let { put("outputTokens", it.toDouble()) }
                    usage?.cachedTokens?.let { put("cachedTokens", it.toDouble()) }
                    usage?.reasoningTokens?.let { put("reasoningTokens", it.toDouble()) }
                    usage?.costUsd?.let { put("costUsd", it) }
                },
            )
            put(
                "context",
                buildJsonObject {
                    usage?.contextTokens?.let { put("used", it.toDouble()) }
                    usage?.contextWindow?.let { put("window", it.toDouble()) }
                },
            )
            put("stored", true)
        }
    }

    private fun updateSession(id: String?, change: (DemoSession) -> DemoSession) {
        state.update { s -> s.copy(sessions = s.sessions.map { if (it.id == id) change(it) else it }) }
    }

    private fun updateCommand(id: String, change: (DemoCommand) -> DemoCommand) {
        state.update { s -> s.copy(commands = s.commands.map { if (it.id == id) change(it) else it }) }
    }

    private fun newCommand(
        sessionDocId: String,
        type: String,
        text: String = "",
        clientId: String? = null,
        status: String = CommandStatus.PENDING,
        result: JsonElement? = null,
    ): String {
        val id = "demo-cmd-${UUID.randomUUID()}"
        val command = DemoCommand(id, sessionDocId, type, text, clientId, status, createdAt = clock(), result = result)
        state.update { s -> s.copy(commands = s.commands + command) }
        return id
    }

    private fun sendPrompt(sessionDocId: String?, text: String, clientId: String?): JsonElement {
        state.value.commands.firstOrNull { clientId != null && it.clientId == clientId }?.let { return ref(it.id) }
        requireReachable(sessionDocId)
        val trimmed = text.trim()
        if (trimmed.isEmpty()) throw RelayException(RelayErrorCode.INVALID, "The prompt is empty.")
        val id = newCommand(sessionDocId!!, "prompt", trimmed, clientId)
        runPrompt(sessionDocId, id, trimmed)
        return ref(id)
    }

    /**
     * `sessions:create`: the session is listed at once (`starting`, its title from the prompt), on the [model] and
     * thinking level [effort] picked from `devices:models` (else the computer's default), with a `create` command;
     * "the computer" opens it a moment later and runs the prompt like any other.
     */
    private fun create(deviceId: String?, path: String?, text: String?, clientId: String?, model: String?, effort: String?): JsonElement {
        val s = state.value
        s.commands.firstOrNull { clientId != null && it.clientId == clientId && it.type == CommandType.CREATE }?.let {
            return RelayJson.encodeToJsonElement(CreateResult.serializer(), CreateResult(it.sessionDocId, it.id))
        }
        val device = s.devices.firstOrNull { it.id == deviceId && it.isComputer }
            ?: throw RelayException(RelayErrorCode.FORBIDDEN, "That is not one of your computers.")
        if (path.isNullOrBlank() || !path.startsWith("/")) throw RelayException(RelayErrorCode.INVALID, "The folder must be an absolute path.")
        if (!device.online) throw RelayException(RelayErrorCode.OFFLINE, "${device.name} is offline: start crok or Crok Desktop there.")
        if (!DemoData.canCreate(device.id)) {
            throw RelayException(RelayErrorCode.OFFLINE, "${device.name} runs an older crok that cannot start sessions from other devices: update crok there.")
        }
        val prompt = text?.trim()?.takeIf { it.isNotEmpty() }
        // Checked against the computer's list, as the relay does; `effort` is an option id or the level it stands for.
        val models = DemoData.modelsFor(device.id)
        val chosen = model?.takeIf { it.isNotBlank() }?.let { wanted ->
            models?.firstOrNull { it.id == wanted } ?: throw RelayException(RelayErrorCode.INVALID, "No such model: $wanted")
        } ?: models?.firstOrNull()
        val level = effort?.takeIf { it.isNotBlank() }?.let { wanted ->
            chosen?.efforts?.firstOrNull { it.id == wanted || it.level == wanted }?.level
                ?: throw RelayException(RelayErrorCode.INVALID, "No such thinking level: $wanted")
        } ?: chosen?.efforts?.firstOrNull { it.id == chosen.defaultEffort }?.level
        val id = "demo-new-${UUID.randomUUID().toString().take(8)}"
        val now = clock()
        val project = s.sessions.firstOrNull { it.detail.deviceId == device.id && it.detail.projectPath == path }?.detail
        val session = DemoSession(
            SessionDetail(
                id = id,
                sessionId = "pending:$clientId",
                title = prompt?.lineSequence()?.firstOrNull()?.take(80) ?: "New session",
                cwd = path,
                model = chosen?.id,
                effort = level,
                status = if (prompt != null) SessionStatus.RUNNING else SessionStatus.IDLE,
                online = false,
                app = "desktop",
                deviceId = device.id,
                deviceName = device.name,
                devicePlatform = device.platform,
                deviceOnline = true,
                createdAt = now,
                lastActivityAt = now,
                projectKey = "${device.id}:$path",
                projectPath = path,
                projectName = project?.projectName ?: path.trimEnd('/').substringAfterLast('/'),
                historyState = HistoryState.READY,
                starting = true,
            ),
            preview = null,
            previewKind = null,
            unread = 0,
        )
        val commandId = "demo-cmd-${UUID.randomUUID()}"
        state.update { st ->
            st.copy(
                sessions = st.sessions + session,
                commands = st.commands + DemoCommand(commandId, id, CommandType.CREATE, prompt.orEmpty(), clientId, createdAt = now),
            )
        }
        val open = suspend {
            updateSession(id) {
                it.copy(detail = it.detail.copy(starting = false, online = true, sessionId = "0199e2e0-0000-7000-8000-${id.takeLast(8).padStart(12, '0')}"))
            }
            if (prompt == null) {
                updateCommand(commandId) { it.copy(status = CommandStatus.DONE, updatedAt = clock()) }
            }
        }
        if (animate) {
            scope.launch {
                delay(1_200)
                open()
                if (prompt != null) runPrompt(id, commandId, prompt)
            }
        }
        return RelayJson.encodeToJsonElement(CreateResult.serializer(), CreateResult(id, commandId))
    }

    /** `commands:setConfig`: checked against the computer's models, applied by "the computer" a moment later. */
    private fun setConfig(sessionDocId: String?, configId: String?, value: String?): JsonElement {
        val session = requireReachable(sessionDocId)
        val models = DemoData.modelsFor(session.detail.deviceId)
            ?: throw RelayException(RelayErrorCode.OFFLINE, "${session.detail.deviceName} runs an older crok that cannot change models from other devices: update crok there.")
        val detail = session.detail
        val (model, effort) = when (configId) {
            ConfigId.MODEL -> {
                val choice = models.firstOrNull { it.id == value } ?: throw RelayException(RelayErrorCode.INVALID, "No such model: $value")
                val keep = choice.efforts.firstOrNull { it.level == detail.effort }
                choice.id to (keep ?: choice.efforts.firstOrNull { it.id == choice.defaultEffort })?.level
            }
            ConfigId.EFFORT -> {
                val current = models.firstOrNull { it.id == detail.model } ?: throw RelayException(RelayErrorCode.INVALID, "This model has no thinking levels.")
                val choice = current.efforts.firstOrNull { it.id == value } ?: throw RelayException(RelayErrorCode.INVALID, "No such thinking level: $value")
                current.id to choice.level
            }
            else -> throw RelayException(RelayErrorCode.INVALID, "Unknown setting: $configId")
        }
        val id = newCommand(session.id, CommandType.CONFIG, text = value.orEmpty())
        val apply = {
            updateSession(session.id) { it.copy(detail = it.detail.copy(model = model, effort = effort, online = true)) }
            val result = buildJsonObject {
                put("model", model)
                effort?.let { put("effort", it) }
            }
            updateCommand(id) { it.copy(status = CommandStatus.DONE, result = result, updatedAt = clock()) }
        }
        if (animate) {
            scope.launch {
                delay(800)
                apply()
            }
        } else {
            apply()
        }
        return ref(id)
    }

    private fun appendEvent(sessionDocId: String, event: (seq: Long) -> RelayEvent): RelayEvent {
        var created: RelayEvent? = null
        state.update { s ->
            val list = s.events[sessionDocId].orEmpty()
            val next = event((list.maxOfOrNull { it.seq } ?: 0) + 1)
            created = next
            s.copy(events = s.events + (sessionDocId to list + next))
        }
        return created!!
    }

    private fun replaceEvent(sessionDocId: String, eventId: String, change: (RelayEvent) -> RelayEvent) {
        state.update { s ->
            val list = s.events[sessionDocId].orEmpty().map { if (it.id == eventId) change(it) else it }
            s.copy(events = s.events + (sessionDocId to list))
        }
    }

    /**
     * What a computer does with a prompt: open the session if nobody runs it, accept the prompt, show it, run a tool,
     * stream a reply, finish the turn. One sent while the session waits on a permission request runs after that.
     */
    private fun runPrompt(sessionDocId: String, commandId: String, text: String) {
        if (!animate) return
        turns[sessionDocId]?.cancel()
        turns[sessionDocId] = scope.launch {
            delay(700)
            state.first { s -> s.sessions.firstOrNull { it.id == sessionDocId }?.detail?.pending == null }
            answers[sessionDocId]?.join()
            adopt(sessionDocId)
            updateCommand(commandId) { it.copy(status = CommandStatus.DELIVERED, updatedAt = clock()) }
            appendEvent(sessionDocId) { seq ->
                RelayEvent(
                    "$sessionDocId-e$seq", seq, "k$seq", EventKind.USER, text,
                    origin = "remote", commandId = commandId, fromLabel = DemoData.PHONE_NAME, at = clock(),
                )
            }
            updateSession(sessionDocId) {
                it.copy(
                    detail = it.detail.copy(status = SessionStatus.RUNNING, lastActivityAt = clock()),
                    preview = text,
                    previewKind = EventKind.USER,
                )
            }
            delay(600)
            // It thinks first: the phone shows "Thinking…" while that is the newest item.
            appendEvent(sessionDocId) { seq ->
                RelayEvent("$sessionDocId-e$seq", seq, "k$seq", EventKind.THOUGHT, "Read the README before answering.", at = clock())
            }
            delay(1_200)
            val tool = appendEvent(sessionDocId) { seq ->
                RelayEvent(
                    "$sessionDocId-e$seq", seq, "k$seq", EventKind.TOOL, "README.md",
                    title = "Read README.md", toolKind = "read", status = "in_progress", at = clock(),
                )
            }
            delay(900)
            replaceEvent(sessionDocId, tool.id) { it.copy(status = "completed") }
            stream(sessionDocId, DEMO_REPLY)
            finishTurn(sessionDocId, commandId)
        }
    }

    /**
     * A crok on the computer takes a prompt for a session nobody runs: it opens the session (with its history from disk
     * when the relay has none yet) and runs it from then on.
     */
    private fun adopt(sessionDocId: String) {
        state.update { s ->
            val current = s.sessions.firstOrNull { it.id == sessionDocId } ?: return@update s
            if (current.detail.online) return@update s
            val history = if (s.events[sessionDocId].isNullOrEmpty()) DemoData.historyFromDisk(current) else null
            s.copy(
                events = if (history != null) s.events + (sessionDocId to history) else s.events,
                sessions = s.sessions.map {
                    if (it.id != sessionDocId) {
                        it
                    } else {
                        it.copy(
                            detail = it.detail.copy(
                                online = true,
                                archived = false,
                                historyState = if (history != null) HistoryState.READY else it.detail.historyState,
                                eventSeq = history?.size?.toLong() ?: it.detail.eventSeq,
                            ),
                        )
                    }
                },
            )
        }
    }

    /** `commands:answer`: only for the request the session waits on now; the first answer from any device wins. */
    private fun answer(sessionDocId: String?, interactionId: String?, optionId: String?): JsonElement {
        val session = session(sessionDocId)
        val pending = session.detail.pending
        if (!session.detail.online || pending == null || pending.id != interactionId) {
            throw RelayException(RelayErrorCode.EXPIRED, "That request was already answered.")
        }
        val option = pending.options.firstOrNull { it.optionId == optionId } ?: throw RelayException(RelayErrorCode.INVALID, "No such choice.")
        val id = newCommand(session.id, "answer", text = option.optionId)
        if (answered.add(pending.id)) takeAnswer(session.id, id, option) else updateCommand(id) { it.copy(status = CommandStatus.DONE, updatedAt = clock()) }
        return ref(id)
    }

    /**
     * The computer takes an answer: the request leaves the session and the turn goes on (the tool runs, or is skipped
     * when the answer refused it), then finishes.
     */
    private fun takeAnswer(sessionDocId: String, commandId: String, option: PendingOption) {
        val take = {
            updateCommand(commandId) { it.copy(status = CommandStatus.DONE, updatedAt = clock()) }
            updateSession(sessionDocId) { it.copy(detail = it.detail.copy(pending = null, status = SessionStatus.RUNNING, lastActivityAt = clock())) }
        }
        if (!animate) {
            take()
            return
        }
        answers[sessionDocId] = scope.launch {
            delay(600)
            take()
            val tool = state.value.events[sessionDocId].orEmpty().lastOrNull { it.kind == EventKind.TOOL && it.status == "pending" }
            if (option.allows) {
                tool?.let { replaceEvent(sessionDocId, it.id) { event -> event.copy(status = "in_progress") } }
                delay(1_500)
                tool?.let { replaceEvent(sessionDocId, it.id) { event -> event.copy(status = "completed", text = BUILD_OUTPUT) } }
                stream(sessionDocId, BUILD_REPLY)
            } else {
                tool?.let { replaceEvent(sessionDocId, it.id) { event -> event.copy(status = "failed") } }
                stream(sessionDocId, SKIPPED_REPLY)
            }
            finishTurn(sessionDocId, null)
        }
    }

    private suspend fun stream(sessionDocId: String, reply: String, existing: RelayEvent? = null) {
        val words = reply.split(" ")
        // Continue an existing reply from the words it already shares with the new one.
        val existingWords = existing?.text?.split(" ").orEmpty()
        var shown = words.indices.takeWhile { it < existingWords.size && words[it] == existingWords[it] }.count()
        val event = existing ?: appendEvent(sessionDocId) { seq ->
            RelayEvent("$sessionDocId-e$seq", seq, "k$seq", EventKind.ASSISTANT, "", at = clock())
        }
        while (shown < words.size) {
            delay(700)
            shown = (shown + 6).coerceAtMost(words.size)
            val text = words.take(shown).joinToString(" ")
            replaceEvent(sessionDocId, event.id) { it.copy(text = text) }
            updateSession(sessionDocId) {
                it.copy(preview = text.take(120), previewKind = EventKind.ASSISTANT, detail = it.detail.copy(lastActivityAt = clock()))
            }
        }
    }

    private fun finishTurn(sessionDocId: String, commandId: String?) {
        commandId?.let { updateCommand(it) { c -> c.copy(status = CommandStatus.DONE, updatedAt = clock()) } }
        appendEvent(sessionDocId) { seq ->
            RelayEvent("$sessionDocId-e$seq", seq, "k$seq", EventKind.SYSTEM, "", status = "end_turn", at = clock())
        }
        updateSession(sessionDocId) {
            it.copy(detail = it.detail.copy(status = SessionStatus.IDLE, lastActivityAt = clock()), unread = it.unread + 1)
        }
    }

    /** Stops the running turn, or the one waiting on a permission request (the request goes with it). */
    private fun stopTurn(sessionDocId: String) {
        turns.remove(sessionDocId)?.cancel()
        answers.remove(sessionDocId)?.cancel()
        val session = state.value.sessions.firstOrNull { it.id == sessionDocId } ?: return
        if (session.detail.status != SessionStatus.RUNNING && session.detail.status != SessionStatus.WAITING) return
        appendEvent(sessionDocId) { seq ->
            RelayEvent("$sessionDocId-e$seq", seq, "k$seq", EventKind.SYSTEM, "", status = "cancelled", at = clock())
        }
        state.value.commands.filter { it.sessionDocId == sessionDocId && it.status == CommandStatus.DELIVERED }.forEach { command ->
            updateCommand(command.id) { it.copy(status = CommandStatus.DONE, updatedAt = clock()) }
        }
        updateSession(sessionDocId) { it.copy(detail = it.detail.copy(status = SessionStatus.IDLE, pending = null, lastActivityAt = clock())) }
    }

    /** The demo's running session finishes its reply a few seconds after the app opens. */
    private fun finishStreamingReply() {
        val sessionDocId = DemoData.RUNNING_SESSION
        turns[sessionDocId] = scope.launch {
            delay(2_500)
            val events = state.value.events[sessionDocId].orEmpty()
            events.lastOrNull { it.kind == EventKind.TOOL }?.let { tool ->
                replaceEvent(sessionDocId, tool.id) { it.copy(status = "completed", text = "running 20 iterations…\n20/20 passed") }
            }
            val reply = events.lastOrNull { it.kind == EventKind.ASSISTANT } ?: return@launch
            stream(sessionDocId, DemoData.STREAMING_TEXT.removeSuffix(" Waiting for the last eight runs…") + FINISH_TEXT, reply)
            updateSession(sessionDocId) { it.copy(detail = it.detail.copy(plan = DemoData.runningPlan.mapIndexed { i, p -> if (i <= 3) p.copy(status = "completed") else if (i == 4) p.copy(status = "in_progress") else p })) }
            finishTurn(sessionDocId, "demo-cmd-1")
        }
    }

    private companion object {
        const val DEMO_REPLY = "This is the demo relay, so nothing ran on a real computer. In a linked session, crok would " +
            "now work on **your prompt** exactly as if you had typed it at the computer, and stream its reply here."
        const val FINISH_TEXT = " All **20 of 20** runs passed. I'll run the whole `crok-remote` suite next."
        const val BUILD_OUTPUT = "$ npm run build\n✓ 214 modules transformed\n✓ built in 2.41s"
        const val BUILD_REPLY = "The build passes and the settings page now follows the system's **dark mode**. Want me to " +
            "add a manual override next to it?"
        const val SKIPPED_REPLY = "OK, I won't run the build. The theme change is in `src/styles/settings.css` whenever " +
            "you want to check it yourself."
    }
}
