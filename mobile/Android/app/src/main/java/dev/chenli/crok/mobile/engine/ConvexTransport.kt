package dev.chenli.crok.mobile.engine

import android.content.Context
import dev.chenli.crok.mobile.auth.DeviceAuthProvider
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.convex.android.ConvexClientWithAuth
import dev.convex.android.ConvexError
import dev.convex.android.InternalError
import dev.convex.android.ServerError
import dev.convex.android.WebSocketState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

/**
 * The relay over the official Convex Android client (Rust core over WebSocket). Auth goes through
 * [DeviceAuthProvider]: the client asks it for a fresh device JWT on every reconnect, and the provider pushes new
 * tokens before the old ones run out.
 */
class ConvexTransport(
    deploymentUrl: String,
    provider: DeviceAuthProvider,
    private val appContext: Context,
) : RelayTransport {
    private val scope = CoroutineScope(SupervisorJob())
    private val client = ConvexClientWithAuth(deploymentUrl, provider, scope)

    override val connected: StateFlow<Boolean> = client.webSocketStateFlow
        .map { it == WebSocketState.CONNECTED }
        .stateIn(scope, SharingStarted.Eagerly, false)

    override suspend fun authenticate(): Result<Unit> =
        client.loginFromCache().map { }.recoverCatching { throw mapError(it) }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
        client.subscribe<JsonElement>(name, args).map { result ->
            result.fold({ Result.success(it) }, { Result.failure(mapError(it)) })
        }

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement = try {
        client.mutation<JsonElement>(name, args)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        throw mapError(e)
    }

    override fun close() {
        scope.launch {
            runCatching { client.logout(appContext) }
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
}
