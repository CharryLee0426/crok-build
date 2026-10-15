package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionStateTest {
    @Test
    fun mapsTheInputs() {
        assertEquals(ConnectionState.WaitingForNetwork, connectionStateOf(network = false, connected = true, synced = true))
        assertEquals(ConnectionState.Connecting, connectionStateOf(network = true, connected = false, synced = true))
        assertEquals(ConnectionState.Updating, connectionStateOf(network = true, connected = true, synced = false))
        assertEquals(ConnectionState.Connected, connectionStateOf(network = true, connected = true, synced = true))
    }

    @Test
    fun troubleShowsOnlyAfterThreeHundredMilliseconds() = runTest {
        val source = MutableStateFlow(ConnectionState.Connected)
        val shown = mutableListOf<ConnectionState>()
        val job = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            source.delayedForDisplay().collect { shown += it }
        }
        source.value = ConnectionState.Connecting
        advanceTimeBy(200)
        // A blip shorter than 0.3 s never shows.
        source.value = ConnectionState.Connected
        advanceTimeBy(1_000)
        assertEquals(listOf(ConnectionState.Connected, ConnectionState.Connected), shown)
        source.value = ConnectionState.WaitingForNetwork
        advanceTimeBy(301)
        assertEquals(ConnectionState.WaitingForNetwork, shown.last())
        job.cancel()
    }
}

/** The engine's facades against the in-memory relay: decoding, pagination and commands end to end. */
class EngineOverDemoTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val transport = DemoTransport(scope, animate = false)
    private val engine = CrokEngine(
        account = DemoData.credentials,
        isDemo = true,
        transport = transport,
        network = MutableStateFlow(true),
        cache = null,
        dispatcher = Dispatchers.Default,
    ).also { it.start() }

    @After
    fun tearDown() {
        engine.close()
        scope.cancel()
    }

    private fun <T> await(block: suspend () -> T): T = runBlocking { withTimeout(10_000) { block() } }

    @Test
    fun listsSessionsPinnedFirstAndArchivedSeparately() = await {
        val state = engine.sessions.active.first { it.live }
        assertEquals(DemoData.WAITING_SESSION, state.rows.first().id)
        assertTrue(state.rows.none { it.archived })
        val archived = engine.sessions.archived().first().getOrThrow()
        assertEquals(listOf("demo-s6"), archived.map { it.id })
        assertEquals(ConnectionState.Connected, engine.connection.first { it == ConnectionState.Connected })
    }

    @Test
    fun pagesTheTranscriptNewestFirst() = await {
        val pager = TranscriptPager(engine, DemoData.RUNNING_SESSION, scope, pageSize = 4)
        pager.start()
        val first = pager.state.first { it.loaded }
        assertEquals(listOf(10L, 9L, 8L, 7L), first.events.map { it.seq })
        assertTrue(!first.historyComplete)
        pager.loadMore()
        val second = pager.state.first { it.events.size == 8 }
        assertEquals((10L downTo 3L).toList(), second.events.map { it.seq })
        pager.loadMore()
        val all = pager.state.first { it.historyComplete }
        assertEquals((10L downTo 1L).toList(), all.events.map { it.seq })
        pager.close()
    }

    @Test
    fun sendsPromptsIdempotentlyAndReportsOffline() = await {
        val id = engine.commands.sendPrompt(DemoData.WAITING_SESSION, "Yes, build it", "client-x")
        assertEquals(id, engine.commands.sendPrompt(DemoData.WAITING_SESSION, "Yes, build it", "client-x"))
        val prompts = engine.commands.forSession(DemoData.WAITING_SESSION).first().getOrThrow()
        assertEquals(CommandStatus.PENDING, prompts.first { it.clientId == "client-x" }.status)
        try {
            engine.commands.sendPrompt("demo-s5", "hello?", "client-y")
            fail("expected OFFLINE")
        } catch (e: RelayException) {
            assertEquals(RelayErrorCode.OFFLINE, e.code)
        }
    }

    @Test
    fun pinsArchivesAndReadsDevices() = await {
        engine.sessions.setArchived(DemoData.WAITING_SESSION, true)
        val active = engine.sessions.active.first { state -> state.live && state.rows.none { it.id == DemoData.WAITING_SESSION } }
        assertTrue(active.rows.isNotEmpty())
        val devices = engine.devices.list().first().getOrThrow()
        assertTrue(devices.first().isCurrent)
        assertEquals(4, engine.devices.revokeOthers())
        val me = engine.accounts.me().first().getOrThrow()
        assertEquals("Chen Li", me?.name)
        val pending = engine.accounts.pendingLogin("bcdf ghjk")
        assertEquals("BCDF-GHJK", pending?.userCode)
    }

    @Test
    fun signingThisPhoneOutElsewhereRevokesIt() = await {
        engine.devices.revoke(DemoData.PHONE_ID)
        // The live session list now fails with REVOKED, and the engine reports it once.
        engine.revoked.first()
    }
}
