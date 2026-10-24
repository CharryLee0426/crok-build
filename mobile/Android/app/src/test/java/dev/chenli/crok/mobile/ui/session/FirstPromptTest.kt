package dev.chenli.crok.mobile.ui.session

import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.SemanticsNodeInteractionsProvider
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ApplicationProvider
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoTransport
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.RelayTransport
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.JsonElement
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A short transcript's first prompt stays in sight (mobile/DESIGN.md "Session screen"): the new-session screen turning
 * into the session it created, and a prompt sent in a session shorter than the screen. The real view model against the
 * demo relay, which picks the prompt up, thinks, runs a tool and replies like a computer; the prompt's bubble is sampled
 * all along and must sit between the top of the screen and the composer every time.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w411dp-h891dp-normal-long-notround-any-420dpi-keyshidden-nonav")
class FirstPromptTest {
    @get:Rule
    val compose = createComposeRule()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val demo = DemoTransport(scope)

    /** The demo relay, with the transcript answering late, as over a slow network. */
    private val transport = object : RelayTransport by demo {
        override fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
            if (name == "sessions:transcript" || name == "sessions:events") {
                flow {
                    delay(600)
                    emitAll(demo.subscribe(name, args))
                }
            } else {
                demo.subscribe(name, args)
            }
    }
    private val engine = CrokEngine(DemoData.credentials, true, transport, MutableStateFlow(true), null, Dispatchers.Default)
    private val drafts = DraftStore(MemoryKeyValueStore())

    @After
    fun tearDown() {
        engine.close()
        scope.cancel()
    }

    private fun show(vm: SessionViewModel) {
        engine.start()
        compose.setContent {
            CrokTheme(dark = false) {
                val state by vm.state.collectAsState()
                SessionContent(
                    state,
                    draft = vm.draft,
                    now = System.currentTimeMillis(),
                    actions = SessionActions(onDraft = vm::updateDraft, onSend = vm::send, onLoadMore = vm::loadMore),
                )
            }
        }
        compose.waitForIdle()
    }

    private fun send(text: String) {
        compose.onNodeWithTag("composer-field").performTextInput(text)
        compose.waitForIdle()
        val label = ApplicationProvider.getApplicationContext<android.content.Context>().getString(R.string.composer_send)
        compose.onNodeWithContentDescription(label).performClick()
    }

    /** The bubble with [text] in the transcript's list (a new session's title in the top bar is its prompt too). */
    private fun SemanticsNodeInteractionsProvider.bubble(text: String): Rect? =
        onAllNodes(hasText(text) and !hasSetTextAction() and hasAnyAncestor(hasScrollAction()), useUnmergedTree = true).fetchSemanticsNodes()
            .map { it.boundsInRoot }
            .maxByOrNull { it.top }

    /** Samples for [millis]: from its first appearance, every sample must find the bubble on screen above the composer. */
    private fun assertStaysInSight(text: String, millis: Long) {
        val misses = ArrayList<String>()
        var seen = 0
        val end = System.currentTimeMillis() + millis
        while (System.currentTimeMillis() < end) {
            Thread.sleep(100)
            compose.waitForIdle()
            val bubble = compose.bubble(text)
            if (bubble == null) {
                // Once shown it stays: the list is never swapped for a spinner while the session's transcript loads.
                if (seen > 0) misses += "gone after $seen samples"
                continue
            }
            val composerTop = compose.onNodeWithTag("composer-field").fetchSemanticsNode().boundsInRoot.top
            seen++
            val sample = "bubble ${bubble.top}–${bubble.bottom}, composer at $composerTop"
            println("[first-prompt $text] $sample")
            if (bubble.top < 0f || bubble.bottom > composerTop) misses += sample
        }
        assertTrue("the prompt showed", seen > 0)
        assertTrue("the prompt went out of sight: ${misses.joinToString("; ")}", misses.isEmpty())
    }

    @Test
    fun aNewSessionsFirstPromptStaysInSight() {
        val target = NewSessionTarget(DemoData.MACBOOK_ID, "/Users/chen/code/crok-site", "MacBook Pro", "crok-site")
        val vm = SessionViewModel(engine, null, drafts, newSession = target)
        show(vm)
        compose.onNodeWithTag("new-session-note").assertExists()
        send("Add a health check endpoint")
        // Created, opened on the computer, picked up: then it thinks, runs a tool and replies.
        assertStaysInSight("Add a health check endpoint", 3_500)
        assertTrue("the screen became the session", vm.sessionDocId != null)
    }

    @Test
    fun aPromptInAShortSessionStaysInSight() {
        val vm = SessionViewModel(engine, DemoData.CATALOG_SESSION, drafts)
        vm.setVisible(true) // opening it fetches its last turn from the computer
        show(vm)
        compose.waitUntil(10_000) { compose.bubble("Done.") != null || vm.state.value.items.size >= 3 }
        send("Add a test for it")
        assertStaysInSight("Add a test for it", 2_500)
    }
}
