package dev.chenli.crok.mobile.data

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One HTTP POST; swapped for a fake in tests. */
fun interface HttpPoster {
    /** Returns the status code and body, or throws [IOException] when the server cannot be reached. */
    fun post(url: String, body: String, headers: Map<String, String>): HttpReply
}

data class HttpReply(val code: Int, val body: String)

object UrlConnectionPoster : HttpPoster {
    override fun post(url: String, body: String, headers: Map<String, String>): HttpReply {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 20_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            return HttpReply(code, text)
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * Convex's HTTP API (`POST <deployment>/api/mutation` / `/api/query`). The sign-in calls go through it, never through the
 * WebSocket client, so refreshing a token never re-enters that client from its own auth callback.
 */
class ConvexHttpApi(
    baseUrl: String,
    private val poster: HttpPoster = UrlConnectionPoster,
) {
    val baseUrl: String = normalizeServerUrl(baseUrl) ?: throw IllegalArgumentException("Not a server URL: $baseUrl")

    suspend fun mutation(path: String, args: JsonObject, bearer: String? = null): JsonElement =
        call("mutation", path, args, bearer)

    suspend fun query(path: String, args: JsonObject, bearer: String? = null): JsonElement =
        call("query", path, args, bearer)

    private suspend fun call(kind: String, path: String, args: JsonObject, bearer: String?): JsonElement =
        withContext(Dispatchers.IO) {
            val body = buildJsonObject {
                put("path", path)
                put("args", args)
                put("format", "json")
            }.toString()
            val headers = if (bearer != null) mapOf("Authorization" to "Bearer $bearer") else emptyMap()
            val reply = try {
                poster.post("$baseUrl/api/$kind", body, headers)
            } catch (e: IOException) {
                throw RelayNetworkException(e.message ?: "Network error", e)
            }
            decodeReply(reply)
        }

    companion object {
        /**
         * Turns a reply into the function's value: `{"status":"success","value":…}`, or a [RelayException] for
         * `{"status":"error","errorMessage":…,"errorData":{code,message}}` and anything unexpected.
         */
        fun decodeReply(reply: HttpReply): JsonElement {
            val parsed = runCatching { RelayJson.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
            if (parsed != null) {
                when (parsed.string("status")) {
                    "success" -> return parsed["value"] ?: JsonNull
                    "error" -> throw RelayException.fromErrorData(
                        parsed["errorData"],
                        parsed.string("errorMessage") ?: "Server error",
                    )
                }
            }
            if (reply.code in 500..599 || reply.code == 0) {
                throw RelayNetworkException("The server answered ${reply.code}")
            }
            val snippet = reply.body.take(200).ifBlank { "HTTP ${reply.code}" }
            throw RelayException(RelayErrorCode.UNKNOWN, snippet)
        }

        /**
         * Accepts what a person types in the Server field: adds https:// when no scheme is given, trims slashes and
         * whitespace. Null when it can't be a URL.
         */
        fun normalizeServerUrl(input: String): String? {
            val raw = input.trim()
            if (raw.isEmpty()) return null
            val text = (if (raw.contains("://")) raw else "https://$raw").trimEnd('/')
            val url = runCatching { URL(text) }.getOrNull() ?: return null
            if (url.protocol != "https" && url.protocol != "http") return null
            if (url.host.isNullOrBlank() || url.host.contains(' ')) return null
            return text
        }
    }
}

internal fun jsonArgs(vararg pairs: Pair<String, Any?>): JsonObject = buildJsonObject {
    for ((key, value) in pairs) {
        when (value) {
            null -> put(key, JsonNull)
            is String -> put(key, value)
            is Boolean -> put(key, value)
            // Convex wants float64 numbers: never send Kotlin integers.
            is Number -> put(key, JsonPrimitive(value.toDouble()))
            is JsonElement -> put(key, value)
            else -> error("Unsupported argument type for $key")
        }
    }
}
