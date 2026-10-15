package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.auth.StoredCredentials
import dev.chenli.crok.mobile.data.ApproveResult
import dev.chenli.crok.mobile.data.CommandDoc
import dev.chenli.crok.mobile.data.CommandRef
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.RevokeOthersResult
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionListCache
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.relayCode
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.json.JsonElement

/** The session list as the screens see it: cached rows first, then live ones. */
data class SessionListState(
    val rows: List<SessionRow> = emptyList(),
    /** True once the relay answered (not just the cache). */
    val live: Boolean = false,
    val error: RelayException? = null,
)

/**
 * One signed-in account (Telegram's AccountInstance / iOS TelegramEngine): owns the relay connection and exposes typed
 * facades. Screens get everything through it; signing out closes it and everything it started.
 */
class CrokEngine(
    val account: StoredCredentials,
    val isDemo: Boolean,
    private val transport: RelayTransport,
    network: StateFlow<Boolean>,
    private val cache: SessionListCache?,
    dispatcher: CoroutineContext = Dispatchers.Main.immediate,
    val clock: () -> Long = System::currentTimeMillis,
) {
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    private val authReady = MutableStateFlow(false)
    private val synced = MutableStateFlow(false)
    private val _revoked = MutableSharedFlow<Unit>(replay = 1)

    /** Emits once when the relay says this device was signed out (`REVOKED`). */
    val revoked: SharedFlow<Unit> = _revoked.asSharedFlow()

    /** The raw state; screens show it through [delayedForDisplay]. */
    val connection: StateFlow<ConnectionState> =
        combine(network, transport.connected, authReady, synced) { net, connected, auth, fresh ->
            connectionStateOf(net, connected, auth && fresh)
        }.stateIn(scope, SharingStarted.Eagerly, ConnectionState.Connecting)

    val sessions = Sessions()
    val events = Events()
    val commands = Commands()
    val devices = Devices()
    val accounts = Accounts()

    fun start() {
        scope.launch { authenticateLoop() }
        scope.launch {
            // Every reconnect makes the list stale until the relay answers again ("Updating…").
            transport.connected.collect { connected -> if (!connected) synced.value = false }
        }
        sessions.start()
    }

    private suspend fun authenticateLoop() {
        var attempt = 0
        while (true) {
            val result = transport.authenticate()
            if (result.isSuccess) {
                authReady.value = true
                return
            }
            if (result.exceptionOrNull()?.relayCode == RelayErrorCode.REVOKED) {
                _revoked.tryEmit(Unit)
                return
            }
            attempt++
            delay((2_000L * attempt).coerceAtMost(30_000L))
        }
    }

    fun close() {
        scope.cancel()
        transport.close()
    }

    internal fun report(error: Throwable?) {
        if (error?.relayCode == RelayErrorCode.REVOKED) _revoked.tryEmit(Unit)
    }

    /** A realtime query, decoded; waits for sign-in so it never runs unauthenticated. */
    internal fun <T> live(name: String, args: Map<String, Any?>, strategy: DeserializationStrategy<T>): Flow<Result<T>> =
        flow {
            authReady.first { it }
            emitAll(transport.subscribe(name, args))
        }.map { result ->
            result.mapCatching { RelayJson.decodeFromJsonElement(strategy, it) }
        }.onEach { report(it.exceptionOrNull()) }.flowOn(Dispatchers.Default)

    /** A mutation, decoded. Throws RelayException / RelayNetworkException. */
    internal suspend fun <T> call(name: String, args: Map<String, Any?>, strategy: DeserializationStrategy<T>): T {
        try {
            authReady.first { it }
            val value: JsonElement = transport.mutation(name, args)
            return RelayJson.decodeFromJsonElement(strategy, value)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            report(e)
            throw e
        }
    }

    internal suspend fun callUnit(name: String, args: Map<String, Any?>) {
        call(name, args, IgnoreValue)
    }

    // ---- Facades ----

    inner class Sessions {
        private val _active = MutableStateFlow(SessionListState())

        /** The live list (not archived), cached on disk for an instant start. */
        val active: StateFlow<SessionListState> = _active.asStateFlow()

        @OptIn(FlowPreview::class)
        internal fun start() {
            scope.launch {
                cache?.load(account.deviceId)?.let { cached ->
                    if (!_active.value.live) _active.value = SessionListState(rows = cached, live = false)
                }
                live("sessions:list", emptyMap(), ListSerializer(SessionRow.serializer())).collect { result ->
                    result.onSuccess { rows ->
                        _active.value = SessionListState(rows = rows, live = true)
                        synced.value = true
                    }.onFailure { error ->
                        _active.value = _active.value.copy(error = error as? RelayException)
                    }
                }
            }
            val diskCache = cache ?: return
            scope.launch {
                _active.debounce(1_000).collect { state ->
                    if (state.live) diskCache.save(account.deviceId, state.rows)
                }
            }
        }

        fun archived(): Flow<Result<List<SessionRow>>> =
            live("sessions:list", mapOf("archived" to true), ListSerializer(SessionRow.serializer()))

        /** `sessions:get`; null once the session is gone from the relay. */
        fun get(sessionDocId: String): Flow<Result<SessionDetail?>> =
            live("sessions:get", mapOf("sessionDocId" to sessionDocId), SessionDetail.serializer().nullable).map { result ->
                if (result.exceptionOrNull()?.relayCode == RelayErrorCode.NOT_FOUND) Result.success(null) else result
            }

        suspend fun markRead(sessionDocId: String) = callUnit("sessions:markRead", mapOf("sessionDocId" to sessionDocId))

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

        fun get(commandId: String): Flow<Result<CommandDoc?>> =
            live("commands:get", mapOf("commandId" to commandId), CommandDoc.serializer().nullable)

        fun forSession(sessionDocId: String): Flow<Result<List<PromptCommand>>> =
            live("commands:forSession", mapOf("sessionDocId" to sessionDocId), ListSerializer(PromptCommand.serializer()))

        suspend fun retry(commandId: String) = callUnit("commands:retry", mapOf("commandId" to commandId))

        suspend fun discard(commandId: String) = callUnit("commands:discard", mapOf("commandId" to commandId))
    }

    inner class Devices {
        fun list(): Flow<Result<List<Device>>> = live("devices:list", emptyMap(), ListSerializer(Device.serializer()))

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
}

/** Decodes any value and drops it (mutations that return null). */
private object IgnoreValue : DeserializationStrategy<Unit> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder) {
        JsonElement.serializer().deserialize(decoder)
    }
}
