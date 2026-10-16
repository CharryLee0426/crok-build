package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
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

    private val recentOrder = listOf(DemoData.MACBOOK_CROK_BUILD, DemoData.MACBOOK_CROK_SITE, DemoData.STUDIO_CROK_BUILD, DemoData.LINUX_INGEST)

    private fun SessionListState.keys() = groups.map { it.key }

    private fun SessionListState.ids(projectKey: String) = groups.first { it.key == projectKey }.sessions.map { it.id }

    /** What the relay itself lists now (not the engine's optimistic view). */
    private suspend fun relayKeys(): List<String> =
        RelayJson.decodeFromJsonElement(ListSerializer(SessionGroup.serializer()), transport.subscribe("sessions:groups", emptyMap()).first().getOrThrow())
            .map { it.key }

    @Test
    fun listsProjectsInOrderAndArchivedSeparately() = await {
        val state = engine.sessions.active.first { it.live }
        // Projects by recent activity (none placed yet); two computers' projects with the same folder stay apart.
        assertEquals(recentOrder, state.keys())
        assertEquals(DemoData.RUNNING_SESSION, state.rows.first().id)
        // Pinned first within a project.
        assertEquals(listOf(DemoData.WAITING_SESSION, "demo-s12"), state.ids(DemoData.MACBOOK_CROK_SITE))
        assertTrue(state.rows.none { it.archived })
        val catalog = state.rows.first { it.id == DemoData.CATALOG_SESSION }
        assertEquals(HistoryState.NONE, catalog.historyState)
        assertTrue(!catalog.online && catalog.deviceOnline)
        val archived = engine.sessions.archived().first().getOrThrow()
        assertEquals(listOf("demo-s6"), archived.map { it.id })
        assertEquals(ConnectionState.Connected, engine.connection.first { it == ConnectionState.Connected })
    }

    @Test
    fun reordersProjectsAndSessionsAndTheRelayAgrees() = await {
        engine.sessions.active.first { it.live }
        val moved = listOf(DemoData.STUDIO_CROK_BUILD, DemoData.MACBOOK_CROK_BUILD, DemoData.MACBOOK_CROK_SITE, DemoData.LINUX_INGEST)
        engine.sessions.reorderProjects(moved)
        assertEquals(moved, engine.sessions.active.value.keys())
        assertEquals(moved, relayKeys())

        // One computer's projects: the others keep their places.
        engine.sessions.reorderProjects(listOf(DemoData.MACBOOK_CROK_SITE, DemoData.MACBOOK_CROK_BUILD))
        val subset = listOf(DemoData.STUDIO_CROK_BUILD, DemoData.MACBOOK_CROK_SITE, DemoData.MACBOOK_CROK_BUILD, DemoData.LINUX_INGEST)
        assertEquals(subset, engine.sessions.active.value.keys())
        assertEquals(subset, engine.sessions.active.first { it.keys() == subset && relayKeys() == subset }.keys())

        // Sessions: a pinned one stays first whatever is asked.
        engine.sessions.reorderSessions(DemoData.MACBOOK_CROK_SITE, listOf("demo-s12", DemoData.WAITING_SESSION))
        assertEquals(listOf(DemoData.WAITING_SESSION, "demo-s12"), engine.sessions.active.value.ids(DemoData.MACBOOK_CROK_SITE))
        val build = listOf("demo-s9", DemoData.RUNNING_SESSION, "demo-s7", DemoData.CATALOG_SESSION, "demo-s10", "demo-s11")
        engine.sessions.reorderSessions(DemoData.MACBOOK_CROK_BUILD, build)
        assertEquals(build, engine.sessions.active.first { it.ids(DemoData.MACBOOK_CROK_BUILD) == build }.ids(DemoData.MACBOOK_CROK_BUILD))

        // Back to recent activity, both levels.
        engine.sessions.sortSessionsByRecent(DemoData.MACBOOK_CROK_BUILD)
        assertEquals(DemoData.RUNNING_SESSION, engine.sessions.active.value.ids(DemoData.MACBOOK_CROK_BUILD).first())
        engine.sessions.sortProjectsByRecent()
        assertEquals(recentOrder, engine.sessions.active.first { it.keys() == recentOrder }.keys())
        assertEquals(recentOrder, relayKeys())
    }

    @Test
    fun openingAListedSessionFetchesItsHistoryWhileTheComputerIsOnline() = await {
        engine.sessions.active.first { it.live }
        engine.sessions.watch(DemoData.CATALOG_SESSION)
        val detail = engine.sessions.get(DemoData.CATALOG_SESSION).first { it.getOrNull()?.historyState == HistoryState.READY }.getOrThrow()!!
        assertEquals("MacBook Pro", detail.deviceName)
        val pager = TranscriptPager(engine, DemoData.CATALOG_SESSION, scope)
        pager.start()
        assertEquals(3, pager.state.first { it.loaded && it.events.isNotEmpty() }.events.size)
        pager.close()

        // The Linux box is offline: nothing to fetch it from.
        engine.sessions.watch(DemoData.OFFLINE_SESSION)
        assertEquals(HistoryState.NONE, engine.sessions.get(DemoData.OFFLINE_SESSION).first().getOrThrow()?.historyState)
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

/** A reorder shows at once and is taken back when the relay refuses it. */
class OptimisticReorderTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val demo = DemoTransport(scope, animate = false)
    private val gate = CompletableDeferred<Unit>()

    /** The demo relay, except that reorders wait for [gate] and then fail. */
    private val transport = object : RelayTransport by demo {
        override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
            if (name.startsWith("sessions:reorder")) {
                gate.await()
                throw RelayException(RelayErrorCode.INVALID, "No such project.")
            }
            return demo.mutation(name, args)
        }
    }

    private val engine = CrokEngine(DemoData.credentials, true, transport, MutableStateFlow(true), null, Dispatchers.Default).also { it.start() }

    @After
    fun tearDown() {
        engine.close()
        scope.cancel()
    }

    @Test
    fun aRefusedReorderIsTakenBack() = runBlocking {
        withTimeout(10_000) {
            val before = engine.sessions.active.first { it.live }.groups.map { it.key }
            val wanted = before.reversed()
            val call = async { runCatching { engine.sessions.reorderProjects(wanted) } }
            // Shown before the relay answers.
            assertEquals(wanted, engine.sessions.active.first { it.groups.map { g -> g.key } == wanted }.groups.map { it.key })
            gate.complete(Unit)
            val failure = call.await().exceptionOrNull()
            assertEquals(RelayErrorCode.INVALID, (failure as RelayException).code)
            assertEquals(before, engine.sessions.active.value.groups.map { it.key })
        }
    }
}
