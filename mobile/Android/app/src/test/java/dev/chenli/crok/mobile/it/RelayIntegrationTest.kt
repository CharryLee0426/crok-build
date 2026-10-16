package dev.chenli.crok.mobile.it

import dev.chenli.crok.mobile.auth.AuthController
import dev.chenli.crok.mobile.auth.AuthState
import dev.chenli.crok.mobile.auth.AuthStore
import dev.chenli.crok.mobile.auth.BytesCodec
import dev.chenli.crok.mobile.auth.DeviceInfo
import dev.chenli.crok.mobile.auth.TokenManager
import dev.chenli.crok.mobile.data.ApproveResult
import dev.chenli.crok.mobile.data.CommandDoc
import dev.chenli.crok.mobile.data.CommandRef
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.ConvexHttpApi
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.EventPage
import dev.chenli.crok.mobile.data.HttpDeviceAuthApi
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.PollResult
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.SecretBox
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionInfoResult
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.OptimisticPrompt
import dev.chenli.crok.mobile.logic.Tick
import dev.chenli.crok.mobile.logic.Transcript
import dev.chenli.crok.mobile.logic.TranscriptItem
import dev.chenli.crok.mobile.logic.UserCode
import java.io.File
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * The phone's sign-in and viewer API against a running relay (by default the local `npx convex dev` at
 * http://127.0.0.1:3210). Runs only with CROK_RELAY_IT=1:
 *
 *     CROK_RELAY_IT=1 ./gradlew :app:testDebugUnitTest --tests '*RelayIntegrationTest*'
 *
 * A person approving a sign-in on the web is stood in for by `npx convex run deviceAuth:approve --identity …` in
 * relay/ (CROK_NPX points at npx when it is not on the PATH). A second device, a "computer", mirrors a session through
 * the bridge functions so the phone has real rows to decode. Everything it links is signed out again at the end.
 */
class RelayIntegrationTest {
    private val relayUrl = System.getProperty("crok.relayUrl") ?: "http://127.0.0.1:3210"
    private val relayDir = File(System.getProperty("crok.relayDir") ?: "../../relay")
    private val identity =
        """{"subject":"android-tester","issuer":"https://placeholder.clerk.accounts.dev","name":"Android Tester","email":"android@example.com"}"""

    private val http by lazy { ConvexHttpApi(relayUrl) }
    private val auth by lazy { HttpDeviceAuthApi(http) }

    @Before
    fun onlyWhenAsked() {
        assumeTrue("set CROK_RELAY_IT=1 to run against a relay", System.getenv("CROK_RELAY_IT") == "1")
    }

    /** What the web's approval page does, as the Clerk test identity. */
    private fun approveAsPerson(userCode: String) {
        val npx = System.getenv("CROK_NPX")?.takeIf { it.isNotBlank() } ?: "npx"
        val process = ProcessBuilder(npx, "convex", "run", "deviceAuth:approve", """{"userCode":"$userCode"}""", "--identity", identity)
            .directory(relayDir)
            .redirectErrorStream(true)
            .apply {
                val bin = File(npx).parentFile
                if (bin != null) environment()["PATH"] = bin.path + File.pathSeparator + (environment()["PATH"] ?: "")
            }
            .start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue("npx convex run timed out", process.waitFor(90, TimeUnit.SECONDS))
        assertEquals("approve failed: $output", 0, process.exitValue())
    }

    private fun <T> decode(strategy: DeserializationStrategy<T>, value: JsonElement): T = RelayJson.decodeFromJsonElement(strategy, value)

    private fun args(build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): JsonObject = buildJsonObject(build)

    @Test
    fun phoneSignsInAndReadsARealSession() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            // 1. The phone signs in through the app's own state machine.
            val passThrough = object : SecretBox {
                override fun seal(plain: ByteArray) = plain
                override fun open(sealed: ByteArray) = sealed
            }
            val store = AuthStore(MemoryKeyValueStore(), passThrough, BytesCodec.Jvm)
            // The relay under test stands in for the app's built-in one (BuildConfig.RELAY_URL).
            val controller = AuthController(store, { url -> HttpDeviceAuthApi(ConvexHttpApi(url)) }, scope, relayUrl)
            controller.restore()
            controller.startSignIn(DeviceInfo("IT Pixel", "Android 16", "Crok Android IT"))
            val waiting = withTimeout(20_000) { controller.state.first { it is AuthState.Waiting || it is AuthState.SignedOut && it.error != null } }
            assertTrue("start failed: $waiting", waiting is AuthState.Waiting)
            val pending = (waiting as AuthState.Waiting).pending
            assertEquals(pending.userCode, UserCode.normalize(pending.userCode))
            println("phone user code ${pending.userCode}, link ${pending.browserUrl}")
            approveAsPerson(pending.userCode)
            val signedIn = withTimeout(30_000) { controller.state.first { it is AuthState.SignedIn } } as AuthState.SignedIn
            val phone = signedIn.credentials
            assertTrue(phone.refreshToken.startsWith("crr_"))
            assertEquals("Android Tester", phone.user.name)
            assertEquals(phone.refreshToken, store.loadCredentials()?.refreshToken)

            // 2. Tokens come from deviceAuth:refresh over the HTTP API.
            val tokens = TokenManager(auth, phone, scope)
            val jwt = tokens.token(force = true).getOrThrow()
            assertEquals(3, jwt.split('.').size)

            val me = decode(Me.serializer().nullable, http.query("users:me", args { }, jwt))
            assertEquals("IT Pixel", me?.device?.name)
            assertEquals("phone", me?.device?.kind)

            // 3. A computer on the same account mirrors a session through the bridge.
            val computerStart = auth.start("computer", "IT MacBook", "macOS 26", "crok IT")
            approveAsPerson(computerStart.userCode)
            val computer = auth.poll(computerStart.deviceCode)
            assertEquals(PollResult.APPROVED, computer.status)
            val cjwt = computer.accessToken!!
            val hostId = http.mutation(
                "bridge:connect",
                args {
                    put("instanceId", "android-it-${UUID.randomUUID()}")
                    put("app", "desktop")
                    put("appVersion", "crok IT")
                },
                cjwt,
            ).jsonObject["hostId"]!!.jsonPrimitive.content
            val sessionId = "android-it-${System.currentTimeMillis()}"
            val now = System.currentTimeMillis().toDouble()
            val sessionDocId = http.mutation(
                "bridge:upsertSession",
                args {
                    put("hostId", hostId)
                    put("sessionId", sessionId)
                    putJsonObject("fields") {
                        put("title", "Android integration test")
                        put("cwd", "/Users/it/code/crok-build")
                        put("model", "grok-code-fast-1")
                        put("status", "running")
                        putJsonArray("plan") {
                            addJsonObject { put("content", "Sign in"); put("status", "completed") }
                            addJsonObject { put("content", "Read the session"); put("status", "in_progress") }
                        }
                        putJsonObject("usage") {
                            put("inputTokens", 1200.0)
                            put("outputTokens", 300.0)
                            put("costUsd", 0.02)
                            put("contextTokens", 5000.0)
                            put("contextWindow", 256000.0)
                        }
                    }
                },
                cjwt,
            ).jsonObject["sessionDocId"]!!.jsonPrimitive.content
            http.mutation(
                "bridge:pushEvents",
                args {
                    put("hostId", hostId)
                    put("sessionDocId", sessionDocId)
                    putJsonArray("events") {
                        addJsonObject { put("key", "u1"); put("kind", "user"); put("text", "Why does the test flake?"); put("origin", "local"); put("at", now) }
                        addJsonObject { put("key", "t1"); put("kind", "thought"); put("text", "Timing."); put("at", now + 1) }
                        addJsonObject {
                            put("key", "x1"); put("kind", "tool"); put("text", "$ cargo test"); put("title", "Run cargo test")
                            put("toolKind", "execute"); put("status", "completed"); put("at", now + 2)
                        }
                        addJsonObject { put("key", "a1"); put("kind", "assistant"); put("text", "Looking at **the test** now."); put("at", now + 3) }
                    }
                },
                cjwt,
            )

            // 4. The phone reads it all through the app's models.
            val rows = decode(ListSerializer(SessionRow.serializer()), http.query("sessions:list", args { }, jwt))
            val row = rows.first { it.sessionId == sessionId }
            assertEquals("IT MacBook", row.deviceName)
            assertTrue(row.isRunning)
            assertEquals(1, row.plan?.done)
            assertEquals(2, row.plan?.total)
            assertTrue(row.lastActivityAt > 0)

            // The main list: the same session under its project (its cwd until the computer says otherwise).
            val groups = decode(ListSerializer(SessionGroup.serializer()), http.query("sessions:groups", args { }, jwt))
            val group = groups.first { g -> g.sessions.any { it.sessionId == sessionId } }
            assertEquals("IT MacBook", group.deviceName)
            assertEquals("/Users/it/code/crok-build", group.path)
            assertEquals("crok-build", group.name)
            assertEquals(group.key, group.sessions.first { it.sessionId == sessionId }.projectKey)
            // Reordering a project's sessions and resetting the order both answer null.
            http.mutation(
                "sessions:reorderSessions",
                args {
                    put("projectKey", group.key)
                    putJsonArray("sessionDocIds") { group.sessions.forEach { add(JsonPrimitive(it.id)) } }
                },
                jwt,
            )
            http.mutation("sessions:resetOrder", args { put("projectKey", group.key) }, jwt)

            val detail = decode(SessionDetail.serializer(), http.query("sessions:get", args { put("sessionDocId", sessionDocId) }, jwt))
            assertEquals(1200L, detail.usage?.inputTokens)
            assertEquals(256000L, detail.usage?.contextWindow)
            assertEquals(2, detail.plan.size)
            assertEquals("desktop", detail.app)

            // Paging: newest first, two at a time, and a pinned page keeps its lower bound.
            fun page(cursor: String?, end: String? = null) = decode(
                EventPage.serializer(),
                runBlocking {
                    http.query(
                        "sessions:events",
                        args {
                            put("sessionDocId", sessionDocId)
                            putJsonObject("paginationOpts") {
                                put("numItems", 2.0)
                                if (cursor == null) put("cursor", JsonNull) else put("cursor", cursor)
                                if (end != null) put("endCursor", end)
                            }
                        },
                        jwt,
                    )
                },
            )
            val first = page(null)
            assertEquals(listOf("a1", "x1"), first.page.map { it.key })
            val second = page(first.continueCursor)
            assertEquals(listOf("t1", "u1"), second.page.map { it.key })
            val pinned = page(null, first.continueCursor)
            assertEquals(listOf("a1", "x1"), pinned.page.map { it.key })

            // 5. A prompt: idempotent by client id, "mine" for this phone, then delivered and in the transcript.
            val clientId = UUID.randomUUID().toString()
            val sendArgs = args {
                put("sessionDocId", sessionDocId)
                put("text", "Run it 20 times")
                put("clientId", clientId)
            }
            val commandId = decode(CommandRef.serializer(), http.mutation("commands:sendPrompt", sendArgs, jwt)).commandId
            assertEquals(commandId, decode(CommandRef.serializer(), http.mutation("commands:sendPrompt", sendArgs, jwt)).commandId)
            var prompts = decode(ListSerializer(PromptCommand.serializer()), http.query("commands:forSession", args { put("sessionDocId", sessionDocId) }, jwt))
            val mine = prompts.first { it.id == commandId }
            assertEquals(clientId, mine.clientId)
            assertEquals(CommandStatus.PENDING, mine.status)
            assertTrue(mine.isMine)

            assertEquals(
                true,
                http.mutation("bridge:claimCommand", args { put("hostId", hostId); put("commandId", commandId) }, cjwt).jsonPrimitive.content.toBoolean(),
            )
            http.mutation(
                "bridge:pushEvents",
                args {
                    put("hostId", hostId)
                    put("sessionDocId", sessionDocId)
                    putJsonArray("events") {
                        addJsonObject {
                            put("key", "u2"); put("kind", "user"); put("text", "Run it 20 times"); put("origin", "remote")
                            put("commandId", commandId); put("fromLabel", "IT Pixel"); put("at", now + 10)
                        }
                    }
                },
                cjwt,
            )
            prompts = decode(ListSerializer(PromptCommand.serializer()), http.query("commands:forSession", args { put("sessionDocId", sessionDocId) }, jwt))
            val events = page(null).page + page(page(null).continueCursor).page + page(page(page(null).continueCursor).continueCursor).page
            val items = Transcript.build(
                events = events,
                prompts = prompts,
                optimistic = listOf(OptimisticPrompt(clientId, "Run it 20 times", now.toLong(), commandId)),
                sessionRunning = true,
                historyComplete = true,
                zone = ZoneId.systemDefault(),
            )
            val newest = items.first() as TranscriptItem.User
            assertEquals("the optimistic bubble gives way to the transcript's event", "Run it 20 times", newest.text)
            assertTrue(newest.key.startsWith("e:"))
            assertEquals("IT Pixel", newest.fromLabel)
            assertEquals(Tick.Sent, newest.tick)

            // 6. Fresh info from the computer.
            val infoId = decode(CommandRef.serializer(), http.mutation("commands:requestInfo", args { put("sessionDocId", sessionDocId) }, jwt)).commandId
            http.mutation("bridge:claimCommand", args { put("hostId", hostId); put("commandId", infoId) }, cjwt)
            http.mutation(
                "bridge:completeCommand",
                args {
                    put("hostId", hostId)
                    put("commandId", infoId)
                    put("status", "done")
                    putJsonObject("result") {
                        put("model", "grok-code-fast-1")
                        putJsonObject("usage") { put("inputTokens", 1500.0); put("costUsd", 0.03) }
                        putJsonObject("context") { put("used", 6000.0); put("window", 256000.0) }
                    }
                },
                cjwt,
            )
            val info = decode(CommandDoc.serializer().nullable, http.query("commands:get", args { put("commandId", infoId) }, jwt))
            assertEquals(CommandStatus.DONE, info?.status)
            val result = SessionInfoResult.from(info?.result)
            assertEquals(1500L, result?.inputTokens)
            assertEquals(6000L, result?.contextUsed)

            // 7. Devices, and approving another computer from the phone (Telegram's QR login).
            val devices = decode(ListSerializer(Device.serializer()), http.query("devices:list", args { }, jwt))
            assertTrue(devices.first().isCurrent)
            assertTrue(devices.any { it.name == "IT MacBook" && it.isComputer })
            val second2 = auth.start("computer", "IT Studio", "macOS 26", "crok IT")
            val lookup = decode(
                PendingLogin.serializer().nullable,
                http.query("deviceAuth:pendingLogin", args { put("userCode", second2.userCode.lowercase().replace("-", " ")) }, jwt),
            )
            assertEquals("IT Studio", lookup?.name)
            assertEquals("pending", lookup?.status)
            val approved = decode(ApproveResult.serializer(), http.mutation("deviceAuth:approve", args { put("userCode", second2.userCode) }, jwt))
            assertEquals("IT Studio", approved.name)
            val studio = auth.poll(second2.deviceCode)
            assertEquals(PollResult.APPROVED, studio.status)

            // 8. Sign-outs: the phone signs both computers out; then itself.
            http.mutation("devices:revoke", args { put("deviceId", computer.deviceId!!) }, jwt)
            http.mutation("devices:revoke", args { put("deviceId", studio.deviceId!!) }, jwt)
            try {
                auth.refresh(computer.refreshToken!!)
                fail("a revoked computer must not refresh")
            } catch (e: RelayException) {
                assertEquals(RelayErrorCode.REVOKED, e.code)
            }
            controller.signOut()
            val revoked = withTimeout(10_000) {
                var code: RelayErrorCode? = null
                while (code == null) {
                    code = runCatching { auth.refresh(phone.refreshToken) }.exceptionOrNull()?.let { (it as? RelayException)?.code }
                    if (code == null) kotlinx.coroutines.delay(200)
                }
                code
            }
            assertEquals(RelayErrorCode.REVOKED, revoked)
            assertNotNull(store)
            println("relay integration: all checks passed against $relayUrl")
        } finally {
            scope.cancel()
        }
    }
}
