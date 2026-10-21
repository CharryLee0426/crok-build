package dev.chenli.crok.mobile.ui.session

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The transcript's bottom when the newest reply is taller than the screen (the Markdown showcase on a phone-sized
 * window): the session opens on the reply's end, a short scroll up inside that reply brings the scroll-to-bottom
 * button, and the button brings the end back.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w411dp-h891dp-normal-long-notround-any-420dpi-keyshidden-nonav")
class TranscriptBottomTest {
    @get:Rule
    val compose = createComposeRule()

    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()
    private lateinit var listState: LazyListState

    @Before
    fun fixedZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        MathImages.warmUp(ApplicationProvider.getApplicationContext())
    }

    private var state by mutableStateOf<SessionUiState?>(null)

    /** The showcase session, plus `extra` newer events. */
    private fun showcase(extra: List<RelayEvent> = emptyList()): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.SHOWCASE_SESSION }
        val events = DemoData.showcaseEvents(now) + extra
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(events.sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = ZoneOffset.UTC,
        )
    }

    private fun prompt(seq: Long, text: String) =
        RelayEvent("${DemoData.SHOWCASE_SESSION}-e$seq", seq, "k$seq", EventKind.USER, text, null, null, null, "local", null, null, now)

    private fun open() {
        state = showcase()
        compose.setContent {
            listState = rememberLazyListState()
            CrokTheme(dark = false) {
                state?.let { SessionContent(it, draft = "", now = now, actions = SessionActions(), listState = listState) }
            }
        }
        compose.waitForIdle()
    }

    private val buttonLabel: String
        get() = ApplicationProvider.getApplicationContext<android.content.Context>().getString(R.string.transcript_scroll_bottom)

    private fun assertAtEnd(context: String) {
        compose.runOnIdle {
            assertEquals("$context: the newest item is the one at the bottom", 0, listState.firstVisibleItemIndex)
            assertEquals("$context: its end is at the bottom", 0, listState.firstVisibleItemScrollOffset)
        }
    }

    private fun scrollTowardOlder(pixels: Float) {
        // reverseLayout: a positive delta moves toward the end of the list, the older items.
        compose.runOnIdle { runBlocking { listState.scrollBy(pixels) } }
        compose.waitForIdle()
    }

    @Test
    fun opensOnTheEndOfALongNewestReply() {
        open()
        compose.runOnIdle {
            val newest = listState.layoutInfo.visibleItemsInfo.first()
            assertEquals(0, newest.index)
            assertTrue("the showcase reply is taller than the window", newest.size > listState.layoutInfo.viewportSize.height)
        }
        assertAtEnd("opened")
        compose.onNodeWithContentDescription(buttonLabel).assertDoesNotExist()
    }

    @Test
    fun buttonShowsInsideALongNewestReplyAndReturnsToItsEnd() {
        open()
        // A short scroll up: still inside the newest reply, but its end is off screen.
        scrollTowardOlder(400f)
        compose.runOnIdle { assertEquals("still inside the newest reply", 0, listState.firstVisibleItemIndex) }
        compose.onNodeWithContentDescription(buttonLabel).assertIsDisplayed().performClick()
        compose.waitForIdle()
        assertAtEnd("after the button")
        compose.onNodeWithContentDescription(buttonLabel).assertDoesNotExist()

        // At the top (the prompt above the reply), screens away from its end, then the button again.
        compose.runOnIdle { runBlocking { listState.scrollToItem(listState.layoutInfo.totalItemsCount - 1) } }
        compose.waitForIdle()
        compose.runOnIdle {
            val info = listState.layoutInfo
            assertTrue(
                "far from the end: ${listState.firstVisibleItemIndex}/${listState.firstVisibleItemScrollOffset} of ${info.viewportSize.height}, " +
                    info.visibleItemsInfo.joinToString { "${it.index}:${it.size}" },
                listState.firstVisibleItemScrollOffset > 2 * info.viewportSize.height,
            )
        }
        compose.onNodeWithContentDescription(buttonLabel).assertIsDisplayed().performClick()
        compose.waitForIdle()
        assertAtEnd("after the button from far up")
    }

    @Test
    fun newItemsAreFollowedFromTheEndOfALongReply() {
        open()
        state = showcase(listOf(prompt(4, "Thanks!")))
        compose.waitForIdle()
        state = showcase(listOf(prompt(4, "Thanks!"), prompt(5, "And one more thing.")))
        compose.waitForIdle()
        assertAtEnd("followed")
        compose.runOnIdle { assertEquals("e:${DemoData.SHOWCASE_SESSION}-e5", listState.layoutInfo.visibleItemsInfo.first().key) }
        compose.onNodeWithContentDescription(buttonLabel).assertDoesNotExist()
    }

    @Test
    fun newItemsWhileReadingInsideALongReplyAreCounted() {
        open()
        scrollTowardOlder(400f)
        val reading = compose.runOnIdle { listState.layoutInfo.visibleItemsInfo.first().key to listState.firstVisibleItemScrollOffset }
        state = showcase(listOf(prompt(4, "Thanks!")))
        compose.waitForIdle()
        compose.runOnIdle {
            val after = listState.layoutInfo.visibleItemsInfo.first().key to listState.firstVisibleItemScrollOffset
            assertEquals("the reader stays where they read", reading, after)
        }
        compose.onNodeWithContentDescription(buttonLabel).assertIsDisplayed()
    }
}
