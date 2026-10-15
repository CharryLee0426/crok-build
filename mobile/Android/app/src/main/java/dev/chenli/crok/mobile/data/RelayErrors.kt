package dev.chenli.crok.mobile.data

import java.io.IOException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** The relay's error codes (relay/DESIGN.md §3). [UNKNOWN] covers server errors without a code. */
enum class RelayErrorCode {
    UNAUTHENTICATED,
    REVOKED,
    FORBIDDEN,
    NOT_FOUND,
    OFFLINE,
    INVALID,
    EXPIRED,
    NOT_CONFIGURED,
    UNKNOWN;

    companion object {
        fun parse(raw: String?): RelayErrorCode = entries.firstOrNull { it.name == raw } ?: UNKNOWN
    }
}

/** A function call the relay answered with an error: a `ConvexError<{code, message}>` or a server error. */
class RelayException(
    val code: RelayErrorCode,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    companion object {
        /** From the HTTP API's `errorData` (an object) or the WebSocket client's `ConvexError.data` (a JSON string). */
        fun fromErrorData(data: JsonElement?, fallbackMessage: String): RelayException {
            val obj = when (data) {
                is JsonObject -> data
                is JsonPrimitive -> if (data.isString) parseObject(data.content) else null
                else -> null
            }
            val code = RelayErrorCode.parse(obj?.string("code"))
            val message = obj?.string("message")?.takeIf { it.isNotBlank() } ?: cleanServerMessage(fallbackMessage)
            return RelayException(code, message)
        }

        fun fromDataString(data: String?, fallbackMessage: String): RelayException =
            fromErrorData(data?.let { parseObject(it) ?: JsonPrimitive(it) }, fallbackMessage)

        private fun parseObject(text: String): JsonObject? =
            runCatching { RelayJson.parseToJsonElement(text) as? JsonObject }.getOrNull()

        /** Convex prefixes server errors with a request id: `[Request ID: abc] Server Error`. */
        internal fun cleanServerMessage(message: String): String =
            message.replace(Regex("^\\[Request ID: [^]]*]\\s*"), "").replace(Regex("^Uncaught (ConvexError|Error):\\s*"), "").trim()
    }
}

/** The relay could not be reached (no network, DNS, timeout, TLS). Callers retry; nothing is known to have happened. */
class RelayNetworkException(message: String, cause: Throwable? = null) : IOException(message, cause)

val Throwable.relayCode: RelayErrorCode?
    get() = (this as? RelayException)?.code
