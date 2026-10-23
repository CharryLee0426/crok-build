package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.ConfigId
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionInfoResult
import dev.chenli.crok.mobile.data.SessionStatus
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
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
    fun markAllAsReadClearsEveryUnreadSessionOfTheComputer() = await {
        val state = engine.sessions.active.first { it.live }
        val macbook = state.groups.filter { it.deviceId == DemoData.MACBOOK_ID }
        val unread = dev.chenli.crok.mobile.logic.Computers.unreadSessionIds(macbook)
        assertTrue(unread.size >= 2)
        engine.sessions.markRead(unread)
        // Shown read at once, and the relay agrees.
        val after = engine.sessions.active.first { list -> list.rows.filter { it.id in unread }.all { it.unread == 0 } }
        assertTrue(after.rows.filter { it.deviceId == DemoData.MACBOOK_ID }.all { it.unread == 0 })
        // The other computers keep theirs.
        assertTrue(after.rows.any { it.deviceId == DemoData.STUDIO_ID && it.unread > 0 })
        val relay = RelayJson.decodeFromJsonElement(
            ListSerializer(SessionGroup.serializer()),
            transport.subscribe("sessions:groups", emptyMap()).first().getOrThrow(),
        )
        assertTrue(relay.flatMap { it.sessions }.filter { it.id in unread }.all { it.unread == 0 })
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

    private suspend fun expectError(code: RelayErrorCode, block: suspend () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (e: RelayException) {
            assertEquals(code, e.code)
        }
    }

    @Test
    fun sendsPromptsIdempotentlyAndReportsOffline() = await {
        val id = engine.commands.sendPrompt(DemoData.WAITING_SESSION, "Yes, build it", "client-x")
        assertEquals(id, engine.commands.sendPrompt(DemoData.WAITING_SESSION, "Yes, build it", "client-x"))
        val prompts = engine.commands.forSession(DemoData.WAITING_SESSION).first().getOrThrow()
        assertEquals(CommandStatus.PENDING, prompts.first { it.clientId == "client-x" }.status)
        // Only an offline computer refuses a prompt.
        expectError(RelayErrorCode.OFFLINE) { engine.commands.sendPrompt(DemoData.OFFLINE_SESSION, "hello?", "client-y") }
    }

    @Test
    fun aSessionNobodyRunsTakesPromptsWhileItsComputerIsOnline() = await {
        // Listed from the MacBook's disk, not running: the prompt waits for a crok there to open the session.
        val listed = engine.sessions.get(DemoData.CATALOG_SESSION).first().getOrThrow()!!
        assertTrue(!listed.online && listed.deviceOnline)
        val id = engine.commands.sendPrompt(DemoData.CATALOG_SESSION, "What changed since?", "client-z")
        val prompt = engine.commands.forSession(DemoData.CATALOG_SESSION).first().getOrThrow().single()
        assertEquals(id, prompt.id)
        assertEquals(CommandStatus.PENDING, prompt.status)

        // Stop settles at once and drops the prompt nobody picked up.
        val stopId = engine.commands.stop(DemoData.CATALOG_SESSION)
        assertEquals(CommandStatus.DONE, engine.commands.get(stopId).first().getOrThrow()?.status)
        val dropped = engine.commands.forSession(DemoData.CATALOG_SESSION).first { result ->
            result.getOrNull()?.singleOrNull()?.status == CommandStatus.FAILED
        }.getOrThrow().single()
        assertEquals("Stopped before it ran.", dropped.error)
        // Its computer is online, so the prompt can go again.
        engine.commands.retry(id)
        assertEquals(CommandStatus.PENDING, engine.commands.forSession(DemoData.CATALOG_SESSION).first().getOrThrow().single().status)

        // Stop on the offline computer's session settles too; a prompt there is OFFLINE.
        engine.commands.stop(DemoData.OFFLINE_SESSION)
        expectError(RelayErrorCode.OFFLINE) { engine.commands.sendPrompt(DemoData.OFFLINE_SESSION, "hi", "client-w") }
    }

    @Test
    fun infoForASessionNobodyRunsIsTheStoredNumbersAtOnce() = await {
        for (sessionDocId in listOf(DemoData.CATALOG_SESSION, DemoData.OFFLINE_SESSION)) {
            val command = engine.commands.get(engine.commands.requestInfo(sessionDocId)).first().getOrThrow()!!
            assertEquals(CommandStatus.DONE, command.status)
            val result = SessionInfoResult.from(command.result)!!
            assertTrue(result.stored)
            assertEquals(engine.sessions.get(sessionDocId).first().getOrThrow()!!.sessionId, result.sessionId)
        }
        // A running session asks its computer: fresh numbers, not stored ones.
        val fresh = engine.commands.get(engine.commands.requestInfo(DemoData.RUNNING_SESSION))
            .first { it.getOrNull()?.status == CommandStatus.DONE }.getOrThrow()!!
        val result = SessionInfoResult.from(fresh.result)!!
        assertTrue(!result.stored)
        assertEquals(184_800L, result.inputTokens)
    }

    @Test
    fun answersAPendingRequestOnce() = await {
        val waiting = engine.sessions.get(DemoData.WAITING_SESSION).first().getOrThrow()!!
        val pending = waiting.pending!!
        assertEquals(DemoData.WAITING_REQUEST, pending.id)
        assertEquals(SessionStatus.WAITING, waiting.status)
        assertEquals(listOf("allow", "allow-always", "reject"), pending.options.map { it.optionId })

        expectError(RelayErrorCode.INVALID) { engine.commands.answer(DemoData.WAITING_SESSION, pending.id, "maybe") }
        expectError(RelayErrorCode.EXPIRED) { engine.commands.answer(DemoData.WAITING_SESSION, "an-older-request", "allow") }
        // Nothing waits in a session nobody runs.
        expectError(RelayErrorCode.EXPIRED) { engine.commands.answer(DemoData.CATALOG_SESSION, pending.id, "allow") }

        val commandId = engine.commands.answer(DemoData.WAITING_SESSION, pending.id, "allow")
        // The computer takes it: the request leaves the session and the turn goes on.
        val answered = engine.sessions.get(DemoData.WAITING_SESSION).first { it.getOrNull()?.pending == null }.getOrThrow()!!
        assertEquals(SessionStatus.RUNNING, answered.status)
        assertEquals(CommandStatus.DONE, engine.commands.get(commandId).first().getOrThrow()?.status)
        // A second answer (another device, a double tap) is too late.
        expectError(RelayErrorCode.EXPIRED) { engine.commands.answer(DemoData.WAITING_SESSION, pending.id, "reject") }
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
    fun createsASessionThatIsListedAtOnceAsStarting() = await {
        engine.sessions.active.first { it.live }
        val path = "/Users/chen/code/crok-site"
        val created = engine.sessions.create(DemoData.MACBOOK_ID, path, "Fix the footer links\nand the header", "client-new")
        // The same client id gives the same session back (a retried send).
        assertEquals(created, engine.sessions.create(DemoData.MACBOOK_ID, path, "Fix the footer links\nand the header", "client-new"))
        val row = engine.sessions.active.first { state -> state.rows.any { it.id == created.sessionDocId } }.rows.first { it.id == created.sessionDocId }
        assertTrue(row.starting)
        assertEquals("Fix the footer links", row.title)
        assertEquals(DemoData.MACBOOK_CROK_SITE, row.projectKey)
        val detail = engine.sessions.get(created.sessionDocId).first().getOrThrow()!!
        assertTrue(detail.starting)
        assertEquals(SessionStatus.RUNNING, detail.status)
        // Its first prompt is listed with the session's prompts, for the sender's ticks.
        val create = engine.commands.forSession(created.sessionDocId).first().getOrThrow().single()
        assertEquals(CommandType.CREATE, create.type)
        assertEquals(created.commandId, create.id)
        assertTrue(create.isMine)

        // Offline computers and computers with an older crok cannot; a relative folder is refused.
        expectError(RelayErrorCode.OFFLINE) { engine.sessions.create(DemoData.LINUX_ID, "/home/chen", null, "client-l") }
        expectError(RelayErrorCode.OFFLINE) { engine.sessions.create(DemoData.STUDIO_ID, "/Users/chen/code/crok-build", null, "client-s") }
        expectError(RelayErrorCode.INVALID) { engine.sessions.create(DemoData.MACBOOK_ID, "code/crok", null, "client-r") }
    }

    @Test
    fun changesTheModelAndThinkingLevelOnTheComputer() = await {
        val detail = engine.sessions.get(DemoData.RUNNING_SESSION).first().getOrThrow()!!
        assertEquals(DemoData.macbookModels.map { it.id }, detail.models?.map { it.id })
        assertEquals("grok-code-fast-1", detail.currentModel?.id)

        val modelCommand = engine.commands.setConfig(DemoData.RUNNING_SESSION, ConfigId.MODEL, "grok-4")
        val done = engine.commands.get(modelCommand).first { it.getOrNull()?.status == CommandStatus.DONE }.getOrThrow()!!
        assertEquals("grok-4", (done.result as JsonObject)["model"]?.jsonPrimitive?.content)
        // The thinking level carries over when the new model has it.
        assertEquals("medium", engine.sessions.get(DemoData.RUNNING_SESSION).first { it.getOrNull()?.model == "grok-4" }.getOrThrow()!!.effort)

        engine.commands.setConfig(DemoData.RUNNING_SESSION, ConfigId.EFFORT, "xhigh")
        assertEquals("xhigh", engine.sessions.get(DemoData.RUNNING_SESSION).first { it.getOrNull()?.effort == "xhigh" }.getOrThrow()!!.effort)
        expectError(RelayErrorCode.INVALID) { engine.commands.setConfig(DemoData.RUNNING_SESSION, ConfigId.MODEL, "gpt-9") }

        // The Studio's crok is older: online, but no models to choose from, and no config changes.
        val studio = engine.sessions.get("demo-s3").first().getOrThrow()!!
        assertTrue(studio.deviceOnline)
        assertEquals(null, studio.models)
        expectError(RelayErrorCode.OFFLINE) { engine.commands.setConfig("demo-s3", ConfigId.MODEL, "grok-4") }
    }

    @Test
    fun listsEachComputersModelsBeforeAnySessionExists() = await {
        assertEquals(DemoData.macbookModels, engine.devices.models(DemoData.MACBOOK_ID).first().getOrThrow())
        // An older crok publishes none; an offline computer has none; a phone is not a computer.
        assertEquals(null, engine.devices.models(DemoData.STUDIO_ID).first().getOrThrow())
        assertEquals(null, engine.devices.models(DemoData.LINUX_ID).first().getOrThrow())
        assertEquals(RelayErrorCode.NOT_FOUND, (engine.devices.models(DemoData.PHONE_ID).first().exceptionOrNull() as RelayException).code)
    }

    @Test
    fun createsASessionOnThePickedModelAndThinkingLevel() = await {
        val path = "/Users/chen/code/crok-site"
        val picked = engine.sessions.create(DemoData.MACBOOK_ID, path, "Plan it", "client-picked", model = "grok-4", effort = "xhigh")
        val detail = engine.sessions.get(picked.sessionDocId).first().getOrThrow()!!
        assertEquals("grok-4", detail.model)
        // The session holds the level the option stands for.
        assertEquals("xhigh", detail.effort)
        // Without a pick: the computer's default model and its default level.
        val default = engine.sessions.create(DemoData.MACBOOK_ID, path, null, "client-default")
        val plain = engine.sessions.get(default.sessionDocId).first().getOrThrow()!!
        assertEquals(DemoData.macbookModels.first().id, plain.model)
        assertEquals("medium", plain.effort)
        // Checked against the computer's list.
        expectError(RelayErrorCode.INVALID) { engine.sessions.create(DemoData.MACBOOK_ID, path, null, "client-bad", model = "gpt-9") }
        expectError(RelayErrorCode.INVALID) { engine.sessions.create(DemoData.MACBOOK_ID, path, null, "client-bad2", model = "claude-sonnet-4-5", effort = "high") }
    }

    @Test
    fun listsTheSessionsSlashCommands() = await {
        val running = engine.sessions.commands(DemoData.RUNNING_SESSION).first().getOrThrow()
        assertEquals("session", running.source)
        assertEquals(DemoData.slashCommands.map { it.name }, running.commands.map { it.name })
        assertEquals("computer", engine.sessions.commands(DemoData.CATALOG_SESSION).first().getOrThrow().source)
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
