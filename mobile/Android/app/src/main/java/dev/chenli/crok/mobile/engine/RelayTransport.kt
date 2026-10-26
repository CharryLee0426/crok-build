package dev.chenli.crok.mobile.engine

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonElement

/**
 * One connection to the relay: realtime queries and mutations by function name. [ConvexTransport] is the Convex
 * Android client; the demo uses an in-memory relay with the same function names, so every screen runs the same
 * decoding and state code in both. The engine makes a new one whenever the old one stopped answering (relay/DESIGN.md
 * §5, "Staying connected") and closes the old one.
 *
 * Arguments are plain maps of String / Boolean / Double / null / Map / List. Numbers must be Doubles: Convex reads
 * Kotlin Ints and Longs as int64, and the relay's arguments are float64.
 */
interface RelayTransport {
    /** True while the WebSocket is connected. */
    val connected: StateFlow<Boolean>

    /** Signs the transport in (its first token). Fails with REVOKED when the device was signed out. */
    suspend fun authenticate(): Result<Unit>

    /**
     * Fetches a fresh access token and authenticates the socket again with it. A live socket answers that with a new
     * result for every subscription (Convex confirms a new identity with a transition), which is how the engine tells a
     * live socket from a dead one. Fails with REVOKED when the device was signed out.
     */
    suspend fun refreshAuth(): Result<Unit>

    fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>>

    suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement

    /** A Convex action (the o11y tab's `o11y:refresh`): it may call out of the relay, so it can take seconds. */
    suspend fun action(name: String, args: Map<String, Any?>): JsonElement

    /** Closes this connection for good. */
    fun close()
}
