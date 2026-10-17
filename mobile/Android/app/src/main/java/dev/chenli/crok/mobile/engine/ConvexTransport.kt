package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.auth.DeviceAuthProvider
import dev.chenli.crok.mobile.auth.TokenManager
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.convex.android.ConvexClientWithAuth
import dev.convex.android.ConvexError
import dev.convex.android.InternalError
import dev.convex.android.MobileConvexClient
import dev.convex.android.ServerError
import dev.convex.android.WebSocketState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement

/**
 * One relay connection over the official Convex Android client (Rust core over WebSocket). Auth goes through its own
 * [DeviceAuthProvider]: the client asks it for a fresh device JWT on every reconnect, and the [TokenManager] pushes new
 * tokens before the old ones run out.
 *
 * [close] really closes it: the client's native core (its socket, its reconnect loop, its runtime) is destroyed, which
 * the Convex client itself never does — its native callbacks keep it reachable, so it would never be collected.
 */
class ConvexTransport(
    deploymentUrl: String,
    private val tokens: TokenManager,
) : RelayTransport {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val provider = DeviceAuthProvider(tokens)

    @Volatile private var native: MobileConvexClient? = null

    private val client = ConvexClientWithAuth(deploymentUrl, provider, scope) { url, clientId, subscriber ->
        MobileConvexClient(url, clientId, subscriber).also { native = it }
    }

    override val connected: StateFlow<Boolean> = client.webSocketStateFlow
        .map { it == WebSocketState.CONNECTED }
        .stateIn(scope, SharingStarted.Eagerly, false)

    override suspend fun authenticate(): Result<Unit> =
        client.loginFromCache().map { }.recoverCatching { throw mapError(it) }

    /**
     * The current token goes to the socket at once when it is still good (a quick proof that the socket lives: the relay
     * answers it with a transition), then a fresh one from the relay follows it.
     */
    override suspend fun refreshAuth(): Result<Unit> {
        tokens.currentToken()?.let(provider::push)
        val fresh = tokens.refresh()
        fresh.onSuccess(provider::push)
        return fresh.map { }.recoverCatching { throw mapError(it) }
    }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
        client.subscribe<JsonElement>(name, args)
            // Every update is the whole result: keep the newest instead of dropping updates when the reader lags (the
            // client's callback channel drops what does not fit).
            .conflate()
            .map { result -> result.fold({ Result.success(it) }, { Result.failure(mapError(it)) }) }

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement = try {
        client.mutation<JsonElement>(name, args)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        throw mapError(e)
    }

    override fun close() {
        provider.close()
        val nativeClient = native
        scope.launch {
            // The subscriptions were cancelled just now; their cancel messages must reach the native runtime before it
            // goes, so wait a little before destroying it.
            delay(CLOSE_DELAY_MS)
            withContext(NonCancellable) { runCatching { nativeClient?.destroy() } }
            scope.cancel()
        }
    }

    private fun mapError(error: Throwable): Throwable = when (error) {
        is RelayException, is RelayNetworkException -> error
        is ConvexError -> RelayException.fromDataString(error.data, error.message ?: "Error")
        is ServerError -> RelayException(RelayErrorCode.UNKNOWN, RelayException.cleanServerMessage(error.message ?: "Server error"), error)
        is InternalError -> RelayException(RelayErrorCode.UNKNOWN, error.message ?: "Client error", error)
        else -> error
    }

    private companion object {
        const val CLOSE_DELAY_MS = 3_000L
    }
}
