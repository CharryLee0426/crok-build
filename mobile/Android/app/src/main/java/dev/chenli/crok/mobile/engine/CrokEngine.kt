package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.auth.StoredCredentials
import dev.chenli.crok.mobile.data.ApproveResult
import dev.chenli.crok.mobile.data.CommandDoc
import dev.chenli.crok.mobile.data.CommandRef
import dev.chenli.crok.mobile.data.ConfigId
import dev.chenli.crok.mobile.data.CreateResult
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.RevokeOthersResult
import dev.chenli.crok.mobile.data.SessionCommands
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionListCache
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.relayCode
import dev.chenli.crok.mobile.logic.OrderChange
import dev.chenli.crok.mobile.logic.SessionOrder
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.json.JsonElement

/**
 * The session list as the screens see it: projects with their sessions (`sessions:groups`), cached ones first, then
 * live ones, with reorders not yet confirmed by the relay already applied.
 */
data class SessionListState(
    val groups: List<SessionGroup> = emptyList(),
    /** True once the relay answered (not just the cache). */
    val live: Boolean = false,
    val error: RelayException? = null,
) {
    /** Every session of the list, in list order. */
    val rows: List<SessionRow> by lazy { groups.flatMap { it.sessions } }
}

/**
 * One signed-in account (Telegram's AccountInstance / iOS TelegramEngine): owns the relay connection and exposes typed
 * facades. Screens get everything through it; signing out closes it and everything it started.
 *
 * [connect] makes a relay transport; the engine makes a new one whenever the current one stops answering (relay/
 * DESIGN.md §5, "Staying connected", in [RelayConnection]), told by [foreground] (the app came back to the front),
 * [network] and [networkChanges] (the network came back or changed).
 */
class CrokEngine(
    val account: StoredCredentials,
    val isDemo: Boolean,
    connect: () -> RelayTransport,
    network: StateFlow<Boolean>,
    private val cache: SessionListCache?,
    dispatcher: CoroutineContext = Dispatchers.Main.immediate,
    val clock: () -> Long = System::currentTimeMillis,
    networkChanges: Flow<Unit> = emptyFlow(),
    foreground: StateFlow<Boolean> = MutableStateFlow(true),
    timing: ConnectionTiming = ConnectionTiming(),
    /** Where relay results are decoded (off the main thread). */
    private val decodeDispatcher: CoroutineContext = Dispatchers.Default,
) {
    /** One transport for good (demo mode, tests): a replacement gets the same one back. */
    constructor(
        account: StoredCredentials,
        isDemo: Boolean,
        transport: RelayTransport,
        network: StateFlow<Boolean>,
        cache: SessionListCache?,
        dispatcher: CoroutineContext = Dispatchers.Main.immediate,
        clock: () -> Long = System::currentTimeMillis,
    ) : this(account, isDemo, { transport }, network, cache, dispatcher, clock)

    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    private val _revoked = MutableSharedFlow<Unit>(replay = 1)

    /** Emits once when the relay says this device was signed out (`REVOKED`). */
    val revoked: SharedFlow<Unit> = _revoked.asSharedFlow()

    internal val relay = RelayConnection(
        connect = connect,
        scope = scope,
        network = network,
        networkChanges = networkChanges,
        foreground = foreground,
        clock = clock,
        timing = timing,
        onRevoked = { _revoked.tryEmit(Unit) },
    )

    /** The raw state; screens show it through [delayedForDisplay]. */
    val connection: StateFlow<ConnectionState> = relay.state

    val sessions = Sessions()
    val events = Events()
    val commands = Commands()
    val devices = Devices()
    val accounts = Accounts()

    fun start() {
        relay.start()
        sessions.start()
    }

    fun close() {
        scope.cancel()
        relay.close()
    }

    /** A realtime query, decoded; waits for sign-in so it never runs unauthenticated, and survives a new transport. */
    internal fun <T> live(name: String, args: Map<String, Any?>, strategy: DeserializationStrategy<T>): Flow<Result<T>> =
        relay.subscribe(name, args).map { result ->
            result.mapCatching { RelayJson.decodeFromJsonElement(strategy, it) }
        }.flowOn(decodeDispatcher)

    /** A mutation, decoded. Throws RelayException / RelayNetworkException. */
    internal suspend fun <T> call(name: String, args: Map<String, Any?>, strategy: DeserializationStrategy<T>): T {
        val value: JsonElement = relay.call { transport -> transport.mutation(name, args) }
        return RelayJson.decodeFromJsonElement(strategy, value)
    }

    internal suspend fun callUnit(name: String, args: Map<String, Any?>) {
        call(name, args, IgnoreValue)
    }

    // ---- Facades ----

    inner class Sessions {
        /** A reorder sent to the relay: shown at once, kept until the relay's list has caught up with it. */
        private inner class PendingChange(val change: OrderChange) {
            var settled = false
        }

        private val lock = Any()
        private var base = SessionListState()
        private val pending = ArrayList<PendingChange>()

        /** Sessions marked read here that the relay's list may still count as unread: shown read meanwhile. */
        private val markedRead = HashSet<String>()
        private val _active = MutableStateFlow(SessionListState())

        /** The live list (not archived), grouped by project and cached on disk for an instant start. */
        val active: StateFlow<SessionListState> = _active.asStateFlow()

        private fun publishLocked() {
            val ordered = if (pending.isEmpty()) base.groups else SessionOrder.applyAll(base.groups, pending.map { it.change })
            val groups = if (markedRead.isEmpty()) {
                ordered
            } else {
                ordered.map { group ->
                    if (group.sessions.none { it.id in markedRead && it.unread > 0 }) {
                        group
                    } else {
                        group.copy(sessions = group.sessions.map { if (it.id in markedRead) it.copy(unread = 0) else it })
                    }
                }
            }
            _active.value = if (groups === base.groups) base else base.copy(groups = groups)
        }

        /** Drops the read marks the relay's list already shows (those sessions have no unread there any more). */
        private fun dropReadLocked() {
            if (markedRead.isEmpty() || !base.live) return
            val stillUnread = base.groups.flatMapTo(HashSet()) { group -> group.sessions.filter { it.unread > 0 }.map { it.id } }
            markedRead.retainAll(stillUnread)
        }

        /**
         * Drops the confirmed reorders the relay's list already shows: the longest run of confirmed ones, from the
         * oldest, whose combined effect leaves the list as it is (so a later change that undid an earlier one counts).
         */
        private fun dropReflectedLocked() {
            if (!base.live) return
            val confirmed = pending.takeWhile { it.settled }
            for (count in confirmed.size downTo 1) {
                val changes = confirmed.take(count).map { it.change }
                if (SessionOrder.sameOrder(SessionOrder.applyAll(base.groups, changes), base.groups)) {
                    repeat(count) { pending.removeAt(0) }
                    return
                }
            }
        }

        @OptIn(FlowPreview::class)
        internal fun start() {
            scope.launch {
                cache?.load(account.deviceId)?.let { cached ->
                    synchronized(lock) {
                        if (!base.live) {
                            base = SessionListState(groups = cached, live = false)
                            publishLocked()
                        }
                    }
                }
                live("sessions:groups", emptyMap(), ListSerializer(SessionGroup.serializer())).collect { result ->
                    result.onSuccess { groups ->
                        synchronized(lock) {
                            base = SessionListState(groups = groups, live = true)
                            dropReflectedLocked()
                            dropReadLocked()
                            publishLocked()
                        }
                    }.onFailure { error ->
                        synchronized(lock) {
                            base = base.copy(error = error as? RelayException)
                            publishLocked()
                        }
                    }
                }
            }
            val diskCache = cache ?: return
            scope.launch {
                _active.debounce(1_000).collect { state ->
                    if (state.live) diskCache.save(account.deviceId, state.groups)
                }
            }
        }

        /**
         * Applies [change] to the list at once (optimistic), then sends it. A failure takes it back and rethrows; on
         * success it stays until the relay's list shows it (Convex answers a mutation after its subscriptions have the
         * result, so usually at once), or for [SETTLE_TIMEOUT_MS] at most, should another device reorder meanwhile.
         */
        private suspend fun reorder(change: OrderChange, send: suspend () -> Unit) {
            val entry = PendingChange(change)
            synchronized(lock) {
                pending += entry
                publishLocked()
            }
            try {
                send()
            } catch (e: Throwable) {
                synchronized(lock) {
                    pending.remove(entry)
                    publishLocked()
                }
                throw e
            }
            synchronized(lock) {
                entry.settled = true
                dropReflectedLocked()
                publishLocked()
            }
            scope.launch {
                delay(SETTLE_TIMEOUT_MS)
                synchronized(lock) {
                    if (pending.remove(entry)) publishLocked()
                }
            }
        }

        /** `sessions:reorderProjects`: [keys] are the projects of the current tab (all, or one computer's) in their new order. */
        suspend fun reorderProjects(keys: List<String>) =
            reorder(OrderChange.Projects(keys)) { callUnit("sessions:reorderProjects", mapOf("keys" to keys)) }

        /** `sessions:reorderSessions`: some of one project's sessions in their new order (pinned ones still lead). */
        suspend fun reorderSessions(projectKey: String, sessionDocIds: List<String>) =
            reorder(OrderChange.Sessions(projectKey, sessionDocIds)) {
                callUnit("sessions:reorderSessions", mapOf("projectKey" to projectKey, "sessionDocIds" to sessionDocIds))
            }

        /** "Sort projects by recent activity" (`sessions:resetOrder({})`): every project, on every computer. */
        suspend fun sortProjectsByRecent() {
            val keys = SessionOrder.projectsByRecent(_active.value.groups)
            reorder(OrderChange.Projects(keys)) { callUnit("sessions:resetOrder", emptyMap()) }
        }

        /** "Sort by recent activity" on one project (`sessions:resetOrder({projectKey})`). */
        suspend fun sortSessionsByRecent(projectKey: String) {
            val group = _active.value.groups.firstOrNull { it.key == projectKey } ?: return
            val ids = SessionOrder.sessionsByRecent(group.sessions)
            reorder(OrderChange.Sessions(projectKey, ids)) { callUnit("sessions:resetOrder", mapOf("projectKey" to projectKey)) }
        }

        fun archived(): Flow<Result<List<SessionRow>>> =
            live("sessions:list", mapOf("archived" to true), ListSerializer(SessionRow.serializer()))

        /** `sessions:get`; null once the session is gone from the relay. */
        fun get(sessionDocId: String): Flow<Result<SessionDetail?>> =
            live("sessions:get", mapOf("sessionDocId" to sessionDocId), SessionDetail.serializer().nullable).map { result ->
                if (result.exceptionOrNull()?.relayCode == RelayErrorCode.NOT_FOUND) Result.success(null) else result
            }

        /**
         * `sessions:create`: a new session in [path] on computer [deviceId], started with [text] when there is one, on
         * [model] (an id from `devices:models`) and thinking level [effort] (an effort's id) when picked — the
         * computer's own choice otherwise. The row exists at once (`starting`); the same [clientId] gives the same
         * session back.
         */
        suspend fun create(
            deviceId: String,
            path: String,
            text: String?,
            clientId: String,
            model: String? = null,
            effort: String? = null,
        ): CreateResult {
            val args = buildMap<String, Any?> {
                put("deviceId", deviceId)
                put("path", path)
                // Optional on the relay: leave them out rather than send null.
                if (!text.isNullOrBlank()) put("text", text)
                if (!model.isNullOrBlank()) put("model", model)
                if (!effort.isNullOrBlank()) put("effort", effort)
                put("clientId", clientId)
            }
            return call("sessions:create", args, CreateResult.serializer())
        }

        /** `sessions:commands`: the session's slash commands (crok's own, skills, workflows), without the `/`. */
        fun commands(sessionDocId: String): Flow<Result<SessionCommands>> =
            live("sessions:commands", mapOf("sessionDocId" to sessionDocId), SessionCommands.serializer())

        suspend fun markRead(sessionDocId: String) = callUnit("sessions:markRead", mapOf("sessionDocId" to sessionDocId))

        /**
         * Mark All as Read (and a project's Read): `sessions:markRead` for each of [sessionDocIds], all shown read at
         * once. Those that fail show their unread count again; the first failure is rethrown. A read mark the relay
         * never confirms (a new reply came meanwhile) goes after [SETTLE_TIMEOUT_MS].
         */
        suspend fun markRead(sessionDocIds: Collection<String>) {
            val ids = sessionDocIds.toSet()
            if (ids.isEmpty()) return
            synchronized(lock) {
                markedRead += ids
                publishLocked()
            }
            val failures = coroutineScope {
                ids.map { id ->
                    async {
                        try {
                            markRead(id)
                            id to null
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            id to e
                        }
                    }
                }.awaitAll()
            }.filter { it.second != null }
            synchronized(lock) {
                failures.forEach { markedRead -= it.first }
                dropReadLocked()
                publishLocked()
            }
            scope.launch {
                delay(SETTLE_TIMEOUT_MS)
                synchronized(lock) {
                    if (markedRead.removeAll(ids)) publishLocked()
                }
            }
            failures.firstOrNull()?.second?.let { throw it }
        }

        suspend fun watch(sessionDocId: String) = callUnit("sessions:watch", mapOf("sessionDocId" to sessionDocId))

        suspend fun setPinned(sessionDocId: String, pinned: Boolean) =
            callUnit("sessions:setPinned", mapOf("sessionDocId" to sessionDocId, "pinned" to pinned))

        suspend fun setArchived(sessionDocId: String, archived: Boolean) =
            callUnit("sessions:setArchived", mapOf("sessionDocId" to sessionDocId, "archived" to archived))

        suspend fun remove(sessionDocId: String) = callUnit("sessions:remove", mapOf("sessionDocId" to sessionDocId))
    }

    inner class Events {
        /** A bottom-anchored, paginated transcript (50 events per page, newest first). */
        fun pager(sessionDocId: String, scope: CoroutineScope): TranscriptPager =
            TranscriptPager(this@CrokEngine, sessionDocId, scope)
    }

    inner class Commands {
        suspend fun sendPrompt(sessionDocId: String, text: String, clientId: String): String =
            call(
                "commands:sendPrompt",
                mapOf("sessionDocId" to sessionDocId, "text" to text, "clientId" to clientId),
                CommandRef.serializer(),
            ).commandId

        suspend fun stop(sessionDocId: String): String =
            call("commands:stop", mapOf("sessionDocId" to sessionDocId), CommandRef.serializer()).commandId

        suspend fun requestInfo(sessionDocId: String): String =
            call("commands:requestInfo", mapOf("sessionDocId" to sessionDocId), CommandRef.serializer()).commandId

        /** Answers the session's pending permission request; `EXPIRED` once that request is no longer pending. */
        suspend fun answer(sessionDocId: String, interactionId: String, optionId: String): String =
            call(
                "commands:answer",
                mapOf("sessionDocId" to sessionDocId, "interactionId" to interactionId, "optionId" to optionId),
                CommandRef.serializer(),
            ).commandId

        /**
         * `commands:setConfig`: the session's model ([ConfigId.MODEL]) or thinking level ([ConfigId.EFFORT], an effort's
         * id), as if picked on its computer. The command's result is `{model, effort}` once done.
         */
        suspend fun setConfig(sessionDocId: String, configId: String, value: String): String =
            call(
                "commands:setConfig",
                mapOf("sessionDocId" to sessionDocId, "configId" to configId, "value" to value),
                CommandRef.serializer(),
            ).commandId

        fun get(commandId: String): Flow<Result<CommandDoc?>> =
            live("commands:get", mapOf("commandId" to commandId), CommandDoc.serializer().nullable)

        fun forSession(sessionDocId: String): Flow<Result<List<PromptCommand>>> =
            live("commands:forSession", mapOf("sessionDocId" to sessionDocId), ListSerializer(PromptCommand.serializer()))

        suspend fun retry(commandId: String) = callUnit("commands:retry", mapOf("commandId" to commandId))

        suspend fun discard(commandId: String) = callUnit("commands:discard", mapOf("commandId" to commandId))
    }

    inner class Devices {
        fun list(): Flow<Result<List<Device>>> = live("devices:list", emptyMap(), ListSerializer(Device.serializer()))

        /**
         * `devices:models`: what computer [deviceId] can run, in picker order (its default model, its own providers',
         * then OpenRouter's), for new and open sessions alike; null while it is offline or before its crok published a
         * list. A subscription of its own that changes only with the list. It fails on a relay from before it; the
         * session's own copy (`sessions:get` → `models`) is the fallback then.
         */
        fun models(deviceId: String): Flow<Result<List<ModelChoice>?>> =
            live("devices:models", mapOf("deviceId" to deviceId), ListSerializer(ModelChoice.serializer()).nullable)

        suspend fun revoke(deviceId: String) = callUnit("devices:revoke", mapOf("deviceId" to deviceId))

        suspend fun revokeOthers(): Int =
            call("devices:revokeOthers", emptyMap(), RevokeOthersResult.serializer()).count

        suspend fun rename(deviceId: String, name: String) =
            callUnit("devices:rename", mapOf("deviceId" to deviceId, "name" to name))
    }

    inner class Accounts {
        fun me(): Flow<Result<Me?>> = live("users:me", emptyMap(), Me.serializer().nullable)

        /** Looks up another device's sign-in before approving it (Telegram's QR login confirmation). */
        suspend fun pendingLogin(userCode: String): PendingLogin? =
            live("deviceAuth:pendingLogin", mapOf("userCode" to userCode), PendingLogin.serializer().nullable)
                .first()
                .getOrThrow()

        suspend fun approve(userCode: String): ApproveResult =
            call("deviceAuth:approve", mapOf("userCode" to userCode), ApproveResult.serializer())

        suspend fun deny(userCode: String) = callUnit("deviceAuth:deny", mapOf("userCode" to userCode))
    }

    companion object {
        /** A confirmed reorder the list does not show yet is dropped after this long (someone else reordered). */
        const val SETTLE_TIMEOUT_MS = 5_000L
    }
}

/** Decodes any value and drops it (mutations that return null). */
private object IgnoreValue : DeserializationStrategy<Unit> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder) {
        JsonElement.serializer().deserialize(decoder)
    }
}
