package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.demo.DemoData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the fake relay serves, shared by every transport a test makes (one deployment, many clients). */
private class FakeRelayServer {
    /** Bumped for a change any live socket would push. */
    val version = MutableStateFlow(0)
    val mutations = mutableListOf<Pair<Int, String>>()
}

/**
 * One fake Convex client. [alive] false is a socket that died without noticing (the phone slept, the network changed):
 * it still says connected, answers nothing and takes no mutation. [unauthenticated]: connected without a user, every
 * query fails with UNAUTHENTICATED (what a reconnect with no token used to leave behind).
 */
private class FakeTransport(val number: Int, private val server: FakeRelayServer) : RelayTransport {
    override val connected = MutableStateFlow(true)
    val alive = MutableStateFlow(true)
    var unauthenticated = false
    var revoked = false
    var authFailures = 0
    var refreshes = 0
    var closed = false
    val active = mutableListOf<String>()
    private val identity = MutableStateFlow(0)

    override suspend fun authenticate(): Result<Unit> {
        if (revoked) return Result.failure(RelayException(RelayErrorCode.REVOKED, "signed out"))
        if (authFailures > 0) {
            authFailures--
            return Result.failure(RuntimeException("no network"))
        }
        return Result.success(Unit)
    }

    override suspend fun refreshAuth(): Result<Unit> {
        refreshes++
        if (revoked) return Result.failure(RelayException(RelayErrorCode.REVOKED, "signed out"))
        identity.value++
        return Result.success(Unit)
    }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> = flow {
        active += name
        try {
            combine(server.version, identity, alive) { v, i, live -> Triple(v, i, live) }
                .filter { it.third }
                .map { (v, _, _) ->
                    when {
                        revoked -> Result.failure(RelayException(RelayErrorCode.REVOKED, "signed out"))
                        unauthenticated -> Result.failure(RelayException(RelayErrorCode.UNAUTHENTICATED, "Sign in first."))
                        name == "sessions:groups" -> Result.success(groupsJson(number))
                        else -> Result.success(JsonPrimitive("$name v$v from #$number"))
                    }
                }
                .collect { emit(it) }
        } finally {
            active -= name
        }
    }

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
        // A dead socket never answers.
        alive.first { it }
        server.mutations += number to name
        return JsonPrimitive("done on #$number")
    }

    override suspend fun action(name: String, args: Map<String, Any?>): JsonElement = mutation(name, args)

    override fun close() {
        closed = true
    }

    companion object {
        /** The demo list, with the transport's number in the first project's name to tell transports apart. */
        fun groupsJson(number: Int): JsonElement {
            val groups = DemoData.groups(DemoData.state(1_760_000_000_000)).mapIndexed { i, g -> if (i == 0) g.copy(name = "${g.name} #$number") else g }
            return RelayJson.encodeToJsonElement(ListSerializer(SessionGroup.serializer()), groups)
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class StayingConnectedTest {
    private val server = FakeRelayServer()
    private val made = mutableListOf<FakeTransport>()
    private val network = MutableStateFlow(true)
    private val networkChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
    private val foreground = MutableStateFlow(true)
    private var revokedCount = 0

    private fun TestScope.connection(scope: CoroutineScope = backgroundScope): RelayConnection =
        RelayConnection(
            connect = { FakeTransport(made.size + 1, server).also { made += it } },
            scope = scope,
            network = network,
            networkChanges = networkChanges,
            foreground = foreground,
            clock = { testScheduler.currentTime },
            onRevoked = { revokedCount++ },
        ).also { it.start() }

    /** Collects a live query the way a screen does, keeping the last value it saw. */
    private fun TestScope.watch(relay: RelayConnection, name: String = "devices:list"): MutableStateFlow<Result<JsonElement>?> {
        val seen = MutableStateFlow<Result<JsonElement>?>(null)
        backgroundScope.launch { relay.subscribe(name, emptyMap()).collect { seen.value = it } }
        return seen
    }

    private fun Result<JsonElement>?.text(): String? = (this?.getOrNull() as? JsonPrimitive)?.content

    @Test
    fun aDeadSocketIsReplacedWhenTheAppComesBack() = runTest {
        val relay = connection()
        val seen = watch(relay)
        runCurrent()
        assertEquals("devices:list v0 from #1", seen.value.text())
        assertEquals(ConnectionState.Connected, relay.state.value)

        // In the background the socket dies without noticing; the screen keeps what it had.
        foreground.value = false
        made[0].alive.value = false
        server.version.value = 1
        advanceTimeBy(60_000)
        assertEquals(1, made.size)

        foreground.value = true
        runCurrent()
        // First a token refresh on the old socket, and the title says it is updating.
        assertEquals(1, made[0].refreshes)
        assertEquals(ConnectionState.Updating, relay.state.value)
        assertEquals("devices:list v0 from #1", seen.value.text())
        advanceTimeBy(9_000)
        assertEquals(1, made.size)
        // No answer within 10 s: a new client, every live query again on it.
        advanceTimeBy(1_100)
        assertEquals(2, made.size)
        runCurrent()
        assertEquals("devices:list v1 from #2", seen.value.text())
        assertEquals(listOf("devices:list"), made[1].active)
        assertTrue(made[0].active.isEmpty())
        assertEquals(ConnectionState.Connected, relay.state.value)
        // The old one is closed once nothing runs on it.
        advanceTimeBy(20_000)
        assertTrue(made[0].closed)
        assertFalse(made[1].closed)
    }

    @Test
    fun aLiveSocketIsKeptWhenTheAppComesBack() = runTest {
        val relay = connection()
        val seen = watch(relay)
        runCurrent()
        foreground.value = false
        advanceTimeBy(5 * 60_000)
        foreground.value = true
        runCurrent()
        // The refresh made the relay answer again at once: nothing to replace.
        assertEquals(1, made[0].refreshes)
        assertEquals(ConnectionState.Connected, relay.state.value)
        advanceTimeBy(60_000)
        assertEquals(1, made.size)
        assertEquals("devices:list v0 from #1", seen.value.text())
    }

    @Test
    fun nothingSyncedForTwentySecondsReplacesTheClient() = runTest {
        // The socket connects but never answers.
        val relay = RelayConnection(
            connect = { FakeTransport(made.size + 1, server).also { made += it; if (made.size == 1) it.alive.value = false } },
            scope = backgroundScope,
            network = network,
            foreground = foreground,
            clock = { testScheduler.currentTime },
            onRevoked = { revokedCount++ },
        ).also { it.start() }
        val seen = watch(relay)
        runCurrent()
        assertEquals(ConnectionState.Updating, relay.state.value)
        advanceTimeBy(19_000)
        assertEquals(0, made[0].refreshes)
        advanceTimeBy(1_100)
        assertEquals(1, made[0].refreshes)
        advanceTimeBy(10_000)
        assertEquals(2, made.size)
        runCurrent()
        assertEquals("devices:list v0 from #2", seen.value.text())
        assertEquals(ConnectionState.Connected, relay.state.value)
    }

    @Test
    fun theWatchdogWaitsForTheNetwork() = runTest {
        network.value = false
        val relay = RelayConnection(
            connect = { FakeTransport(made.size + 1, server).also { made += it; it.alive.value = false } },
            scope = backgroundScope,
            network = network,
            foreground = foreground,
            clock = { testScheduler.currentTime },
            onRevoked = { revokedCount++ },
        ).also { it.start() }
        watch(relay)
        runCurrent()
        assertEquals(ConnectionState.WaitingForNetwork, relay.state.value)
        advanceTimeBy(120_000)
        assertEquals(1, made.size)
        assertEquals(0, made[0].refreshes)
        // The network comes back: checked at once.
        network.value = true
        runCurrent()
        assertEquals(1, made[0].refreshes)
    }

    @Test
    fun aNewNetworkChecksTheSocket() = runTest {
        val relay = connection()
        watch(relay)
        runCurrent()
        // Wi-Fi → mobile data: the availability never changed, but the socket on Wi-Fi is gone.
        made[0].alive.value = false
        networkChanges.tryEmit(Unit)
        runCurrent()
        assertEquals(1, made[0].refreshes)
        advanceTimeBy(10_100)
        assertEquals(2, made.size)
    }

    @Test
    fun unauthenticatedRefreshesTheTokenAndReplacesTheClientAtOnce() = runTest {
        val relay = connection()
        val seen = watch(relay)
        runCurrent()
        // A reconnect without a token: the socket is fine, but every query now fails.
        made[0].unauthenticated = true
        server.version.value = 1
        runCurrent()
        assertEquals(1, made[0].refreshes)
        assertEquals(2, made.size)
        runCurrent()
        assertEquals("devices:list v1 from #2", seen.value.text())
        assertEquals(ConnectionState.Connected, relay.state.value)
        assertEquals(0, revokedCount)
    }

    @Test
    fun aRelayThatKeepsRefusingBacksOff() = runTest {
        val relay = RelayConnection(
            connect = { FakeTransport(made.size + 1, server).also { made += it; it.unauthenticated = true } },
            scope = backgroundScope,
            network = network,
            foreground = foreground,
            clock = { testScheduler.currentTime },
            onRevoked = { revokedCount++ },
        ).also { it.start() }
        watch(relay)
        runCurrent()
        assertEquals(2, made.size)
        advanceTimeBy(9_000)
        assertEquals(2, made.size)
        advanceTimeBy(1_100)
        assertEquals(3, made.size)
        // Then 20 s, 40 s, …: never a tight loop.
        advanceTimeBy(15_000)
        assertEquals(3, made.size)
        advanceTimeBy(5_100)
        assertEquals(4, made.size)
    }

    @Test
    fun revokedSignsOutAndStopsReconnecting() = runTest {
        val relay = connection()
        watch(relay)
        runCurrent()
        made[0].revoked = true
        server.version.value = 1
        runCurrent()
        assertEquals(1, revokedCount)
        foreground.value = false
        runCurrent()
        foreground.value = true
        advanceTimeBy(120_000)
        assertEquals(1, made.size)
        assertEquals(1, revokedCount)
    }

    @Test
    fun aSignInThatFailedOfflineIsRetriedWhenTheNetworkReturns() = runTest {
        network.value = false
        val relay = RelayConnection(
            connect = { FakeTransport(made.size + 1, server).also { made += it; it.authFailures = 100 } },
            scope = backgroundScope,
            network = network,
            foreground = foreground,
            clock = { testScheduler.currentTime },
            onRevoked = { revokedCount++ },
        ).also { it.start() }
        val seen = watch(relay)
        advanceTimeBy(5_000)
        assertEquals(null, seen.value)
        made[0].authFailures = 0
        network.value = true
        runCurrent()
        assertEquals("devices:list v0 from #1", seen.value.text())
        assertEquals(1, made.size)
    }

    @Test
    fun aMutationOnAReplacedClientIsSentAgainOnTheNewOne() = runTest {
        val relay = connection()
        watch(relay)
        runCurrent()
        made[0].alive.value = false
        val call = async { relay.call { it.mutation("sessions:markRead", emptyMap()) } }
        runCurrent()
        foreground.value = false
        runCurrent()
        foreground.value = true
        advanceTimeBy(10_100)
        assertEquals(2, made.size)
        assertFalse(call.isCompleted)
        // It had its grace period on the old client, then goes on the new one.
        advanceTimeBy(10_100)
        assertEquals(JsonPrimitive("done on #2"), call.await())
        assertEquals(listOf(2 to "sessions:markRead"), server.mutations)
        advanceTimeBy(2_000)
        assertTrue(made[0].closed)
    }

    @Test
    fun titleStatesFollowTheSocket() = runTest {
        val relay = connection()
        watch(relay)
        assertEquals(ConnectionState.Connecting, relay.state.value)
        runCurrent()
        assertEquals(ConnectionState.Connected, relay.state.value)
        made[0].connected.value = false
        runCurrent()
        assertEquals(ConnectionState.Connecting, relay.state.value)
        made[0].connected.value = true
        runCurrent()
        // Connected again, but nothing fresh yet.
        assertEquals(ConnectionState.Updating, relay.state.value)
        server.version.value = 1
        runCurrent()
        assertEquals(ConnectionState.Connected, relay.state.value)
        network.value = false
        runCurrent()
        assertEquals(ConnectionState.WaitingForNetwork, relay.state.value)
    }
}

/** The session list stays on screen while the engine swaps a dead client for a new one. */
@OptIn(ExperimentalCoroutinesApi::class)
class EngineReconnectTest {
    @Test
    fun theListStaysWhileTheClientIsReplaced() = runTest {
        val server = FakeRelayServer()
        val made = mutableListOf<FakeTransport>()
        val foreground = MutableStateFlow(true)
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = CrokEngine(
            account = DemoData.credentials,
            isDemo = false,
            connect = { FakeTransport(made.size + 1, server).also { made += it } },
            network = MutableStateFlow(true),
            cache = null,
            dispatcher = dispatcher,
            clock = { testScheduler.currentTime },
            foreground = foreground,
            decodeDispatcher = dispatcher,
        )
        engine.start()
        runCurrent()
        val before = engine.sessions.active.value
        assertTrue(before.live)
        assertTrue(before.groups.first().name.endsWith("#1"))

        foreground.value = false
        made[0].alive.value = false
        runCurrent()
        foreground.value = true
        runCurrent()
        advanceTimeBy(5_000)
        // Still the old list (not empty, not an error) while the new client is not there yet.
        assertEquals(before.groups, engine.sessions.active.value.groups)
        advanceTimeBy(5_100)
        runCurrent()
        val after = engine.sessions.active.value
        assertTrue(after.groups.first().name.endsWith("#2"))
        assertEquals(before.groups.size, after.groups.size)
        assertEquals(ConnectionState.Connected, engine.connection.value)
        engine.close()
    }
}
