package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.data.ApproveResult
import dev.chenli.crok.mobile.data.CommandDoc
import dev.chenli.crok.mobile.data.CommandRef
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.EventPage
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.RevokeOthersResult
import dev.chenli.crok.mobile.data.SessionStatus
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
import kotlinx.coroutines.flow.distinctUntilChanged
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
 * [animate], prompts are picked up, streamed and finished like a real computer would.
 */
class DemoTransport(
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val animate: Boolean = true,
) : RelayTransport {
    private val state = MutableStateFlow(DemoData.state(clock()))
    private val turns = HashMap<String, Job>()

    override val connected: StateFlow<Boolean> = MutableStateFlow(true)

    override suspend fun authenticate(): Result<Unit> = Result.success(Unit)

    init {
        if (animate) finishStreamingReply()
    }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
        state.map { current -> runCatching { answer(current, name, args) } }.distinctUntilChanged()

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
        delay(if (animate) 150 else 0)
        if (state.value.revoked) throw RelayException(RelayErrorCode.REVOKED, "This device was signed out.")
        return mutate(name, args)
    }

    override fun close() {
        turns.values.forEach { it.cancel() }
    }

    // ---- Queries ----

    private fun answer(s: DemoState, name: String, args: Map<String, Any?>): JsonElement {
        if (s.revoked) throw RelayException(RelayErrorCode.REVOKED, "This device was signed out.")
        return when (name) {
            "users:me" -> RelayJson.encodeToJsonElement(Me.serializer(), s.me)
            "devices:list" -> RelayJson.encodeToJsonElement(ListSerializer(Device.serializer()), s.devices)
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
                RelayJson.encodeToJsonElement(SessionDetail.serializer(), session.detail.copy(unread = session.unread))
            }
            "sessions:events" -> RelayJson.encodeToJsonElement(EventPage.serializer(), page(s, args))
            "commands:forSession" -> RelayJson.encodeToJsonElement(
                ListSerializer(dev.chenli.crok.mobile.data.PromptCommand.serializer()),
                s.commands.filter { it.sessionDocId == args["sessionDocId"] && it.type == "prompt" }
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

    /** Convex-style pagination over the session's events, newest first; cursors are `seq:<n>`. */
    private fun page(s: DemoState, args: Map<String, Any?>): EventPage {
        val sessionId = args["sessionDocId"] as? String
        @Suppress("UNCHECKED_CAST")
        val options = args["paginationOpts"] as? Map<String, Any?> ?: emptyMap()
        val numItems = (options["numItems"] as? Number)?.toInt() ?: 50
        val cursor = (options["cursor"] as? String)?.removePrefix("seq:")?.toLongOrNull()
        val end = (options["endCursor"] as? String)?.removePrefix("seq:")?.toLongOrNull()
        val all = s.events[sessionId].orEmpty().sortedByDescending { it.seq }
        val after = if (cursor != null) all.filter { it.seq < cursor } else all
        val items = if (end != null) after.filter { it.seq >= end } else after.take(numItems)
        val continueCursor = when {
            end != null -> "seq:$end"
            items.isNotEmpty() -> "seq:${items.last().seq}"
            else -> "seq:${cursor ?: 0}"
        }
        return EventPage(items, isDone = items.size == after.size, continueCursor = continueCursor)
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
            "commands:stop" -> {
                requireOnline(sessionDocId)
                val id = newCommand(sessionDocId!!, "cancel", status = CommandStatus.DONE)
                stopTurn(sessionDocId)
                return ref(id)
            }
            "commands:requestInfo" -> {
                val session = requireOnline(sessionDocId)
                val id = newCommand(sessionDocId!!, "info")
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
                requireOnline(command.sessionDocId)
                updateCommand(command.id) { it.copy(status = CommandStatus.PENDING, error = null, updatedAt = clock()) }
                runPrompt(command.sessionDocId, command.id, command.text)
            }
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
                                session.copy(detail = session.detail.copy(online = false, deviceOnline = false, status = SessionStatus.IDLE))
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

    private fun requireOnline(id: String?): DemoSession {
        val session = session(id)
        if (!session.detail.online) throw RelayException(RelayErrorCode.OFFLINE, "This session is not running on its computer right now.")
        return session
    }

    private fun updateSession(id: String?, change: (DemoSession) -> DemoSession) {
        state.update { s -> s.copy(sessions = s.sessions.map { if (it.id == id) change(it) else it }) }
    }

    private fun updateCommand(id: String, change: (DemoCommand) -> DemoCommand) {
        state.update { s -> s.copy(commands = s.commands.map { if (it.id == id) change(it) else it }) }
    }

    private fun newCommand(sessionDocId: String, type: String, text: String = "", clientId: String? = null, status: String = CommandStatus.PENDING): String {
        val id = "demo-cmd-${UUID.randomUUID()}"
        val command = DemoCommand(id, sessionDocId, type, text, clientId, status, createdAt = clock())
        state.update { s -> s.copy(commands = s.commands + command) }
        return id
    }

    private fun sendPrompt(sessionDocId: String?, text: String, clientId: String?): JsonElement {
        state.value.commands.firstOrNull { clientId != null && it.clientId == clientId }?.let { return ref(it.id) }
        requireOnline(sessionDocId)
        val trimmed = text.trim()
        if (trimmed.isEmpty()) throw RelayException(RelayErrorCode.INVALID, "The prompt is empty.")
        val id = newCommand(sessionDocId!!, "prompt", trimmed, clientId)
        runPrompt(sessionDocId, id, trimmed)
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

    /** What a computer does with a prompt: accept it, show it, run a tool, stream a reply, finish the turn. */
    private fun runPrompt(sessionDocId: String, commandId: String, text: String) {
        if (!animate) return
        turns[sessionDocId]?.cancel()
        turns[sessionDocId] = scope.launch {
            delay(700)
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

    private fun stopTurn(sessionDocId: String) {
        turns.remove(sessionDocId)?.cancel()
        val session = state.value.sessions.firstOrNull { it.id == sessionDocId } ?: return
        if (session.detail.status != SessionStatus.RUNNING) return
        appendEvent(sessionDocId) { seq ->
            RelayEvent("$sessionDocId-e$seq", seq, "k$seq", EventKind.SYSTEM, "", status = "cancelled", at = clock())
        }
        state.value.commands.filter { it.sessionDocId == sessionDocId && it.status == CommandStatus.DELIVERED }.forEach { command ->
            updateCommand(command.id) { it.copy(status = CommandStatus.DONE, updatedAt = clock()) }
        }
        updateSession(sessionDocId) { it.copy(detail = it.detail.copy(status = SessionStatus.IDLE, lastActivityAt = clock())) }
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
    }
}
