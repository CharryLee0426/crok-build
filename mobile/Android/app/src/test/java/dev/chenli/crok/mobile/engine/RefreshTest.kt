package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.ListRefreshResult
import dev.chenli.crok.mobile.data.ListRefreshState
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.ui.sessions.SessionsEvent
import dev.chenli.crok.mobile.ui.sessions.refreshSessions
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A relay for Refresh: `sessions:refresh` answers [answer] (or fails with [failure]), `sessions:refreshState` streams
 * [pending], and `sessions:groups` answers an empty list again after each token refresh (as a live Convex socket does).
 */
private class RefreshTransport : RelayTransport {
    override val connected = MutableStateFlow(true)
    private val identity = MutableStateFlow(0)
    var answer = ListRefreshResult(asked = 2, offline = 1, at = 1_760_500_000_123)
    var failure: RelayException? = null
    val pending = MutableStateFlow(listOf("d1"))
    var refreshCalls = 0
    var authRefreshes = 0
    val stateArgs = mutableListOf<Map<String, Any?>>()

    override suspend fun authenticate(): Result<Unit> = Result.success(Unit)

    override suspend fun refreshAuth(): Result<Unit> {
        authRefreshes++
        identity.value++
        return Result.success(Unit)
    }

    override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> = when (name) {
        "sessions:groups" -> identity.map { Result.success(JsonArray(emptyList())) }
        "sessions:refreshState" -> {
            stateArgs += args
            pending.map { Result.success(RelayJson.encodeToJsonElement(ListRefreshState.serializer(), ListRefreshState(it))) }
        }
        else -> flow { awaitCancellation() }
    }

    override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
        assertEquals("sessions:refresh", name)
        refreshCalls++
        failure?.let { throw it }
        return RelayJson.encodeToJsonElement(ListRefreshResult.serializer(), answer)
    }

    override suspend fun action(name: String, args: Map<String, Any?>): JsonElement = mutation(name, args)

    override fun close() = Unit
}

@OptIn(ExperimentalCoroutinesApi::class)
class RefreshTest {
    private val transport = RefreshTransport()

    private fun TestScope.engine(): CrokEngine {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return CrokEngine(
            account = DemoData.credentials,
            isDemo = false,
            connect = { transport },
            network = MutableStateFlow(true),
            cache = null,
            dispatcher = dispatcher,
            clock = { testScheduler.currentTime },
            decodeDispatcher = dispatcher,
        ).also {
            it.start()
            runCurrent()
        }
    }

    @Test
    fun waitsUntilEveryComputerHasListedItsSessions() = runTest {
        val engine = engine()
        val outcome = async { engine.sessions.refresh() }
        runCurrent()
        assertTrue(engine.sessions.isRefreshing.value)
        assertEquals(1, transport.refreshCalls)
        // It follows that refresh: `since` is the relay's `at`, as a float64.
        assertEquals(listOf(mapOf<String, Any?>("since" to 1_760_500_000_123.0)), transport.stateArgs)
        advanceTimeBy(5_000)
        assertFalse(outcome.isCompleted)
        transport.pending.value = emptyList()
        runCurrent()
        assertEquals(RefreshOutcome(asked = 2, offline = 1), outcome.await())
        assertFalse(engine.sessions.isRefreshing.value)
        // A live connection is not checked.
        assertEquals(0, transport.authRefreshes)
        engine.close()
    }

    @Test
    fun stopsWaitingAfterFifteenSeconds() = runTest {
        val engine = engine()
        val outcome = async { engine.sessions.refresh() }
        advanceTimeBy(CrokEngine.REFRESH_WAIT_MS - 100)
        assertTrue(engine.sessions.isRefreshing.value)
        advanceTimeBy(200)
        // A computer whose crok predates Refresh did not answer: the list stays as it is.
        assertEquals(RefreshOutcome(asked = 2, offline = 1, pending = listOf("d1")), outcome.await())
        assertFalse(engine.sessions.isRefreshing.value)
        engine.close()
    }

    @Test
    fun noComputerOnlineEndsAtOnceButShowsTheSpinnerAWhile() = runTest {
        transport.answer = ListRefreshResult(asked = 0, offline = 2, at = 1_000)
        val engine = engine()
        val started = testScheduler.currentTime
        val outcome = engine.sessions.refresh()
        assertTrue(outcome.noneOnline)
        assertEquals(CrokEngine.REFRESH_MIN_MS, testScheduler.currentTime - started)
        // Nothing to wait for.
        assertTrue(transport.stateArgs.isEmpty())
        assertFalse(engine.sessions.isRefreshing.value)
        engine.close()
    }

    @Test
    fun aSecondRefreshJoinsTheRunningOne() = runTest {
        val engine = engine()
        val first = async { engine.sessions.refresh() }
        runCurrent()
        val second = async { engine.sessions.refresh() }
        runCurrent()
        transport.pending.value = emptyList()
        runCurrent()
        assertEquals(first.await(), second.await())
        assertEquals(1, transport.refreshCalls)
        // Once it is over, the next one asks again.
        transport.pending.value = listOf("d1")
        val third = async { engine.sessions.refresh() }
        runCurrent()
        assertEquals(2, transport.refreshCalls)
        transport.pending.value = emptyList()
        runCurrent()
        third.await()
        engine.close()
    }

    @Test
    fun aConnectionThatIsNotLiveIsCheckedAtOnce() = runTest {
        val engine = engine()
        assertEquals(ConnectionState.Connected, engine.connection.value)
        // The socket reconnected and nothing fresh came yet: "Updating…".
        transport.connected.value = false
        runCurrent()
        transport.connected.value = true
        runCurrent()
        assertEquals(ConnectionState.Updating, engine.connection.value)
        val outcome = async { engine.sessions.refresh() }
        runCurrent()
        // The token goes out again at once, rather than after the 20 s watchdog, and the live socket answers.
        assertEquals(1, transport.authRefreshes)
        assertEquals(ConnectionState.Connected, engine.connection.value)
        transport.pending.value = emptyList()
        runCurrent()
        outcome.await()
        engine.close()
    }

    @Test
    fun aFailureEndsTheSpinnerAndReachesTheScreen() = runTest {
        transport.failure = RelayException(RelayErrorCode.UNKNOWN, "Server Error")
        val engine = engine()
        try {
            engine.sessions.refresh()
            fail("expected an error")
        } catch (e: RelayException) {
            assertEquals("Server Error", e.message)
        }
        assertFalse(engine.sessions.isRefreshing.value)
        // The screens' shared path turns it into a snackbar event.
        val events = Channel<SessionsEvent>(Channel.BUFFERED)
        backgroundScope.refreshSessions(engine, events)
        runCurrent()
        assertEquals(SessionsEvent.RefreshFailed("Server Error"), events.tryReceive().getOrNull())
        engine.close()
    }

    @Test
    fun theScreensShowTheNoticeOnlyWhenNoComputerIsOnline() = runTest {
        val engine = engine()
        val events = Channel<SessionsEvent>(Channel.BUFFERED)
        transport.pending.value = emptyList()
        backgroundScope.refreshSessions(engine, events)
        advanceTimeBy(1_000)
        assertNull(events.tryReceive().getOrNull())
        transport.answer = ListRefreshResult(asked = 0, offline = 1, at = 2_000)
        backgroundScope.refreshSessions(engine, events)
        advanceTimeBy(1_000)
        assertEquals(SessionsEvent.NoneOnline, events.tryReceive().getOrNull())
        engine.close()
    }
}
