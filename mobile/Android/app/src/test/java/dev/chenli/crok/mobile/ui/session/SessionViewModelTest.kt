package dev.chenli.crok.mobile.ui.session

import androidx.lifecycle.SavedStateHandle
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoTransport
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.logic.BotCardKind
import dev.chenli.crok.mobile.logic.BotCardProblem
import dev.chenli.crok.mobile.logic.Tick
import dev.chenli.crok.mobile.logic.TranscriptItem
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The session screen's view model against the demo relay: new sessions and the composer's commands. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionViewModelTest {
    private val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val transport = DemoTransport(scope, animate = false)
    private val engine = CrokEngine(DemoData.credentials, true, transport, kotlinx.coroutines.flow.MutableStateFlow(true), null, Dispatchers.Default)
    private val drafts = DraftStore(MemoryKeyValueStore())
    private val target = NewSessionTarget(DemoData.MACBOOK_ID, "/Users/chen/code/crok-site", "MacBook Pro", "crok-site")

    @Before
    fun setUp() {
        Dispatchers.setMain(main)
        engine.start()
    }

    @After
    fun tearDown() {
        engine.close()
        scope.cancel()
        Dispatchers.resetMain()
        main.close()
    }

    /** Runs [block] on the view models' main thread, waiting at most 10 s. */
    private fun <T> onMain(block: suspend CoroutineScope.() -> T): T = runBlocking { withTimeout(10_000) { withContext(main, block) } }

    private fun SessionViewModel.collectState(): SessionViewModel = also { vm -> scope.launch(main) { vm.state.collect { } } }

    @Test
    fun theNewSessionScreenTurnsIntoTheSessionItCreates() = onMain {
        val vm = SessionViewModel(engine, null, drafts, newSession = target).collectState()
        val empty = vm.state.first { it.newSession != null }
        assertTrue(empty.items.isEmpty())
        assertTrue(empty.canSend)
        assertTrue(!empty.hasMenu)

        vm.updateDraft("Fix the footer links")
        vm.send()
        // The prompt shows at once, then the screen is the new session (same view model, same screen).
        val created = vm.state.first { it.newSession == null && it.title == "Fix the footer links" }
        assertTrue(vm.sessionDocId != null)
        assertTrue(created.starting)
        val bubble = created.items.filterIsInstance<TranscriptItem.User>().single()
        assertEquals("Fix the footer links", bubble.text)
        assertEquals(Tick.Clock, bubble.tick)
        assertEquals("", vm.draft)
        val command = engine.commands.forSession(vm.sessionDocId!!).first().getOrThrow().single()
        assertEquals(CommandType.CREATE, command.type)
    }

    @Test
    fun slashNewWithAPromptStartsTheSessionAtOnce() = onMain {
        val vm = SessionViewModel(engine, null, drafts, newSession = target, firstPrompt = "Release the site").collectState()
        vm.state.first { it.newSession == null && it.title == "Release the site" }
        assertTrue(vm.sessionDocId != null)
    }

    @Test
    fun aRestoredNewSessionScreenShowsTheSessionItMade() = onMain {
        val saved = SavedStateHandle()
        val first = SessionViewModel(engine, null, drafts, newSession = target, saved = saved).collectState()
        first.updateDraft("Ship it")
        first.send()
        first.state.first { it.newSession == null }
        // The app was killed and the screen restored: the same session, not an empty new one.
        val again = SessionViewModel(engine, null, drafts, newSession = target, saved = saved).collectState()
        assertEquals(first.sessionDocId, again.sessionDocId)
        assertNull(again.state.first { it.title == "Ship it" }.newSession)
        // `/new <prompt>` restored before it got an answer resends with the same client id: still one session.
        val a = SessionViewModel(engine, null, drafts, newSession = target, firstPrompt = "Once", firstPromptClientId = "client-once").collectState()
        a.state.first { it.newSession == null }
        val b = SessionViewModel(engine, null, drafts, newSession = target, firstPrompt = "Once", firstPromptClientId = "client-once").collectState()
        b.state.first { it.newSession == null }
        assertEquals(a.sessionDocId, b.sessionDocId)
    }

    @Test
    fun aComputerWithAnOlderCrokSaysSo() = onMain {
        val studio = NewSessionTarget(DemoData.STUDIO_ID, "/Users/chen/code/crok-build", "Studio", "crok-build")
        val vm = SessionViewModel(engine, null, drafts, newSession = studio).collectState()
        vm.updateDraft("hello")
        vm.send()
        val failed = vm.state.first { state -> state.items.filterIsInstance<TranscriptItem.User>().any { it.tick == Tick.Failed } }
        val bubble = failed.items.filterIsInstance<TranscriptItem.User>().single()
        // The relay's own words reach the person.
        assertTrue(bubble.error!!.contains("update crok"))
        assertNull(vm.sessionDocId)
    }

    @Test
    fun modelWithAnArgumentAppliesItAndAnswersWithADoneCard() = onMain {
        val vm = SessionViewModel(engine, DemoData.RUNNING_SESSION, drafts).collectState()
        vm.state.first { it.models.models != null }
        vm.updateDraft("/model grok 4")
        vm.send()
        val done = vm.state.first { state -> state.items.filterIsInstance<TranscriptItem.Bot>().any { it.card.done != null } }
        val card = done.items.filterIsInstance<TranscriptItem.Bot>().single().card
        assertEquals(BotCardKind.Model, card.kind)
        assertEquals("Grok 4", card.done)
        assertEquals("grok-4", vm.state.first { it.models.current?.id == "grok-4" }.models.current?.id)
        // Handled on the phone: nothing went to the computer as a prompt.
        assertTrue(engine.commands.forSession(DemoData.RUNNING_SESSION).first().getOrThrow().none { it.text.startsWith("/model") })
    }

    @Test
    fun thinkWithoutAnArgumentOffersTheLevelsAndATapAppliesOne() = onMain {
        val vm = SessionViewModel(engine, DemoData.RUNNING_SESSION, drafts).collectState()
        vm.state.first { it.models.hasThinking }
        vm.updateDraft("/think")
        vm.send()
        val offered = vm.state.first { state -> state.items.any { it is TranscriptItem.Bot } }
        val card = offered.items.filterIsInstance<TranscriptItem.Bot>().single().card
        assertEquals(BotCardKind.Think, card.kind)
        assertNull(card.done)
        vm.applyConfig(card.id, "high")
        val done = vm.state.first { state -> state.items.filterIsInstance<TranscriptItem.Bot>().any { it.card.done != null } }
        assertEquals("High", done.items.filterIsInstance<TranscriptItem.Bot>().single().card.done)
        assertEquals("high", vm.state.first { it.models.effort == "high" }.models.effort)
    }

    @Test
    fun anAmbiguousOrUnknownArgumentShowsInTheCard() = onMain {
        val vm = SessionViewModel(engine, DemoData.RUNNING_SESSION, drafts).collectState()
        vm.state.first { it.models.models != null }
        vm.updateDraft("/model grok")
        vm.send()
        val card = vm.state.first { state -> state.items.any { it is TranscriptItem.Bot } }.items.filterIsInstance<TranscriptItem.Bot>().single().card
        assertEquals(BotCardProblem.Ambiguous("grok"), card.problem)
    }

    @Test
    fun theSessionsOwnCommandsAndUnknownOnesGoAsPrompts() = onMain {
        val vm = SessionViewModel(engine, DemoData.RUNNING_SESSION, drafts).collectState()
        vm.state.first { it.sessionCommands.isNotEmpty() }
        vm.pickCommand(vm.state.value.sessionCommands.first { it.name == "compact" }.let { dev.chenli.crok.mobile.logic.CommandEntry(it.name, null, it.description) })
        vm.updateDraft("/frobnicate now")
        vm.send()
        val prompts = engine.commands.forSession(DemoData.RUNNING_SESSION).first { result -> result.getOrNull()?.count { it.text.startsWith("/") } == 2 }.getOrThrow()
        assertEquals(setOf("/compact", "/frobnicate now"), prompts.filter { it.text.startsWith("/") }.map { it.text }.toSet())
    }

    @Test
    fun pickingACommandWithArgumentsFillsTheField() = onMain {
        val vm = SessionViewModel(engine, DemoData.RUNNING_SESSION, drafts).collectState()
        val model = vm.state.first { it.localCommands.isNotEmpty() }.localCommands.first { it.name == "model" }
        vm.pickCommand(model)
        assertEquals("/model ", vm.draft)
    }
}
