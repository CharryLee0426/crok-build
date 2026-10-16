package dev.chenli.crok.mobile.engine

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonElement

/**
 * How the engine reaches the relay: realtime queries and mutations by function name. [ConvexTransport] is the Convex
 * Android client; the demo uses an in-memory relay with the same function names, so every screen runs the same
 * decoding and state code in both.
 *
 * Arguments are plain maps of String / Boolean / Double / null / Map / List. Numbers must be Doubles: Convex reads
 * Kotlin Ints and Longs as int64, and the relay's arguments are float64.
 */
interface RelayTransport {
    /** True while the WebSocket is connected. */
    val connected: StateFlow<Boolean>

    /** Signs the transport in (or refreshes its token). Fails with REVOKED when the device was signed out. */
    suspend fun authenticate(): Result<Unit>

    fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>>

    suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement

    fun close()
}
