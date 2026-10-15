package dev.chenli.crok.mobile.data

import java.io.IOException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ConvexHttpApiTest {
    @Test
    fun decodesSuccess() {
        val value = ConvexHttpApi.decodeReply(HttpReply(200, """{"status":"success","value":{"a":1},"logLines":[]}"""))
        assertEquals(JsonPrimitive(1), value.jsonObject["a"])
    }

    @Test
    fun decodesConvexErrors() {
        val reply = HttpReply(
            400,
            """{"status":"error","errorMessage":"[Request ID: 1] Uncaught ConvexError: x","errorData":{"code":"REVOKED","message":"This device was signed out."}}""",
        )
        try {
            ConvexHttpApi.decodeReply(reply)
            fail("expected an error")
        } catch (e: RelayException) {
            assertEquals(RelayErrorCode.REVOKED, e.code)
            assertEquals("This device was signed out.", e.message)
        }
    }

    @Test
    fun decodesServerErrorsWithoutData() {
        try {
            ConvexHttpApi.decodeReply(HttpReply(500, """{"status":"error","errorMessage":"[Request ID: abc] Server Error"}"""))
            fail("expected an error")
        } catch (e: RelayException) {
            assertEquals(RelayErrorCode.UNKNOWN, e.code)
            assertEquals("Server Error", e.message)
        }
    }

    @Test
    fun treatsGatewayErrorsAsNetworkTrouble() {
        try {
            ConvexHttpApi.decodeReply(HttpReply(502, "<html>Bad gateway</html>"))
            fail("expected an error")
        } catch (e: RelayNetworkException) {
            assertTrue(e.message!!.contains("502"))
        }
        try {
            ConvexHttpApi.decodeReply(HttpReply(404, "Not found"))
            fail("expected an error")
        } catch (e: RelayException) {
            assertEquals(RelayErrorCode.UNKNOWN, e.code)
        }
    }

    @Test
    fun normalizesServerUrls() {
        assertEquals("https://happy-cat-123.convex.cloud", ConvexHttpApi.normalizeServerUrl(" happy-cat-123.convex.cloud/ "))
        assertEquals("http://10.0.2.2:3210", ConvexHttpApi.normalizeServerUrl("http://10.0.2.2:3210"))
        assertNull(ConvexHttpApi.normalizeServerUrl(""))
        assertNull(ConvexHttpApi.normalizeServerUrl("ftp://x.dev"))
        assertNull(ConvexHttpApi.normalizeServerUrl("https://"))
    }

    @Test
    fun postsTheFunctionPathArgsAndFloatNumbers() = runTest {
        var url = ""
        var body = ""
        var headers = emptyMap<String, String>()
        val api = ConvexHttpApi("https://x.convex.cloud/") { u, b, h ->
            url = u
            body = b
            headers = h
            HttpReply(200, """{"status":"success","value":null}""")
        }
        api.query("sessions:events", jsonArgs("sessionDocId" to "s1", "n" to 50), bearer = "jwt")
        assertEquals("https://x.convex.cloud/api/query", url)
        val sent = RelayJson.parseToJsonElement(body).jsonObject
        assertEquals("sessions:events", sent["path"]!!.jsonPrimitive.content)
        assertEquals("json", sent["format"]!!.jsonPrimitive.content)
        // Integers go out as float64: 50.0, never Convex's int64.
        assertEquals("50.0", (sent["args"] as JsonObject)["n"]!!.jsonPrimitive.content)
        assertEquals("Bearer jwt", headers["Authorization"])
    }

    @Test
    fun wrapsConnectionFailures() = runTest {
        val api = ConvexHttpApi("https://x.convex.cloud") { _, _, _ -> throw IOException("unreachable") }
        try {
            api.mutation("deviceAuth:poll", jsonArgs("deviceCode" to "d"))
            fail("expected an error")
        } catch (e: RelayNetworkException) {
            assertEquals("unreachable", e.message)
        }
    }

    @Test
    fun parsesWebSocketErrorData() {
        val e = RelayException.fromDataString("""{"code":"OFFLINE","message":"Not running"}""", "Uncaught ConvexError")
        assertEquals(RelayErrorCode.OFFLINE, e.code)
        assertEquals("Not running", e.message)
        assertEquals(RelayErrorCode.UNKNOWN, RelayException.fromDataString("\"just text\"", "fallback").code)
    }
}

class WireModelsTest {
    @Test
    fun readsFloatNumbersIntoIntegers() {
        val rows = RelayJson.decodeFromString(
            ListSerializer(SessionRow.serializer()),
            """[{"_id":"s1","_creationTime":1.7605e12,"title":"T","cwd":"/x","status":"running","online":true,"app":"tui",
               "deviceId":"d1","deviceName":"Mac","deviceOnline":true,"preview":null,"previewKind":null,
               "lastActivityAt":1760500000123.0,"pinned":false,"archived":false,"unread":2.0,"plan":{"done":3,"total":7},
               "somethingNew":"ignored"}]""",
        )
        val row = rows.single()
        assertEquals(1760500000123L, row.lastActivityAt)
        assertEquals(2, row.unread)
        assertEquals(PlanProgress(3, 7), row.plan)
        assertTrue(row.isRunning)
    }

    @Test
    fun writesIntegersAsFloats() {
        val json = RelayJson.encodeToString(PlanProgress.serializer(), PlanProgress(1, 2))
        assertEquals("""{"done":1.0,"total":2.0}""", json)
    }

    @Test
    fun readsInfoResultsInBothShapes() {
        val nested = SessionInfoResult.from(
            RelayJson.parseToJsonElement(
                """{"model":"grok","usage":{"inputTokens":1200,"costUsd":0.01},"context":{"used":5000,"window":256000},"sessionId":"x"}""",
            ),
        )!!
        assertEquals("grok", nested.model)
        assertEquals(1200L, nested.inputTokens)
        assertEquals(0.01, nested.costUsd!!, 1e-9)
        assertEquals(256000L, nested.contextWindow)
        val flat = SessionInfoResult.from(RelayJson.parseToJsonElement("""{"model":"grok-code","inputTokens":1200,"costUsd":0.01}"""))!!
        assertEquals(1200L, flat.inputTokens)
        assertNull(SessionInfoResult.from(JsonPrimitive("x")))
    }

    @Test
    fun readsPollAnswers() {
        val pending = RelayJson.decodeFromString(PollResult.serializer(), """{"status":"pending"}""")
        assertEquals(PollResult.PENDING, pending.status)
        val approved = RelayJson.decodeFromString(
            PollResult.serializer(),
            """{"status":"approved","deviceId":"d","refreshToken":"crr_x","accessToken":"a.b.c","accessTokenExpiresAt":1760503600000,
               "user":{"name":"Chen","email":null,"imageUrl":null}}""",
        )
        assertEquals("crr_x", approved.refreshToken)
        assertEquals(1760503600000L, approved.accessTokenExpiresAt)
        assertEquals("Chen", approved.user?.name)
        assertNull(approved.user?.email)
    }
}
