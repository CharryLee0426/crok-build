package dev.chenli.crok.mobile.data

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

/** The four sign-in calls that need no signed-in caller (`deviceAuth:start/poll/refresh/logout`). */
interface DeviceAuthApi {
    suspend fun start(kind: String, name: String, platform: String, client: String): StartResult
    suspend fun poll(deviceCode: String): PollResult
    suspend fun refresh(refreshToken: String): RefreshResult
    suspend fun logout(refreshToken: String)
}

/** Builds the sign-in API for a server URL. */
fun interface DeviceAuthApiFactory {
    fun create(serverUrl: String): DeviceAuthApi
}

class HttpDeviceAuthApi(private val http: ConvexHttpApi) : DeviceAuthApi {
    override suspend fun start(kind: String, name: String, platform: String, client: String): StartResult =
        decode(
            http.mutation(
                "deviceAuth:start",
                jsonArgs("kind" to kind, "name" to name, "platform" to platform, "client" to client),
            ),
        )

    override suspend fun poll(deviceCode: String): PollResult =
        decode(http.mutation("deviceAuth:poll", jsonArgs("deviceCode" to deviceCode)))

    override suspend fun refresh(refreshToken: String): RefreshResult =
        decode(http.mutation("deviceAuth:refresh", jsonArgs("refreshToken" to refreshToken)))

    override suspend fun logout(refreshToken: String) {
        http.mutation("deviceAuth:logout", jsonArgs("refreshToken" to refreshToken))
    }

    private inline fun <reified T> decode(value: JsonElement): T = try {
        RelayJson.decodeFromJsonElement<T>(value)
    } catch (e: IllegalArgumentException) {
        throw RelayException(RelayErrorCode.UNKNOWN, "Unexpected answer from the server", e)
    }

    companion object {
        val Factory = DeviceAuthApiFactory { url -> HttpDeviceAuthApi(ConvexHttpApi(url)) }
    }
}
