package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.demo.transcriptChunk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transcript window over `sessions:transcript` (relay/DESIGN.md §3 "Loading long transcripts"), against a relay
 * that answers like the real one: opening on the newest items, the live end, splitting it, older parts, and starting
 * over after a burst or a replaced transcript. The same cases as the iOS app's TranscriptWindowTests.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TranscriptWindowTest {
    /** The session's items on the relay; every subscription answers again when they change, as Convex does. */
    private val relay = MutableStateFlow<List<RelayEvent>>(emptyList())

    /** Every range asked for, in order. */
    private val asked = ArrayList<TranscriptRange>()

    private fun add(count: Int, text: String = "reply", kind: String = EventKind.ASSISTANT) {
        val start = (relay.value.maxOfOrNull { it.seq } ?: 0) + 1
        relay.value = relay.value + (start until start + count).map { seq -> RelayEvent("e$seq", seq, "k$seq", kind, text, at = seq * 1000) }
    }

    /** Where the window's queries run: on the test's clock, as foreground work (`advanceUntilIdle` runs it). */
    private lateinit var windowScope: CoroutineScope

    private fun windowTest(body: suspend TestScope.() -> Unit) = runTest {
        windowScope = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
        try {
            body()
        } finally {
            windowScope.cancel()
        }
    }

    private fun TestScope.window(): TranscriptWindow {
        val window = TranscriptWindow(
            source = { range ->
                asked += range
                relay.map { Result.success(transcriptChunk(it, range.afterSeq, range.throughSeq, range.limit)) }
            },
            scope = windowScope,
        )
        window.start()
        advanceUntilIdle()
        return window
    }

    private val TranscriptWindow.seqs: List<Long> get() = state.value.events.map { it.seq }.sorted()

    @Test
    fun opensOnTheNewestAndKeepsALiveEndFromThere() = windowTest {
        add(100)
        val window = window()
        assertEquals(TranscriptRange(limit = 40), asked.first())
        assertEquals((61L..100L).toList(), window.seqs)
        assertTrue(window.state.value.loaded)
        assertFalse(window.state.value.historyComplete)
        // The opening query is gone; the live end runs from the oldest item shown.
        assertEquals(listOf(TranscriptRange(afterSeq = 60, limit = 200)), window.ranges)

        add(3)
        advanceUntilIdle()
        assertEquals(103L, window.seqs.last())
        assertEquals("nothing slides out of the window", 43, window.seqs.size)
    }

    @Test
    fun theLiveEndSplitsWhenItHoldsTooManyItems() = windowTest {
        add(40)
        val window = window()
        add(45) // 85 in the live end: more than 80
        advanceUntilIdle()
        assertEquals(
            "the newest 40 stay live; the rest is a fixed part",
            listOf(TranscriptRange(afterSeq = 45, limit = 200), TranscriptRange(afterSeq = 0, throughSeq = 45, limit = 200)),
            window.ranges,
        )
        assertEquals("every item still shows", (1L..85L).toList(), window.seqs)
    }

    @Test
    fun theLiveEndSplitsWhenItHoldsTooMuchText() = windowTest {
        val long = "x".repeat(30_000)
        add(4, text = long)
        val window = window()
        add(4, text = long) // 240 000 characters in 8 items
        advanceUntilIdle()
        assertEquals("half the text stays live", listOf(TranscriptRange(afterSeq = 4, limit = 200), TranscriptRange(afterSeq = 0, throughSeq = 4, limit = 200)), window.ranges)
        assertEquals((1L..8L).toList(), window.seqs)
    }

    @Test
    fun olderPartsLoadUntilTheBeginning() = windowTest {
        add(130)
        val window = window()
        window.loadMore()
        assertTrue(window.state.value.loadingMore)
        advanceUntilIdle()
        assertEquals(TranscriptRange(throughSeq = 90, limit = 60), asked.last())
        assertEquals((31L..130L).toList(), window.seqs)
        assertFalse(window.state.value.historyComplete)
        window.loadMore()
        advanceUntilIdle()
        assertTrue("the beginning of the session", window.state.value.historyComplete)
        assertEquals((1L..130L).toList(), window.seqs)
        val asks = asked.size
        window.loadMore()
        advanceUntilIdle()
        assertEquals("nothing older to ask for", asks, asked.size)
    }

    @Test
    fun aLoadMoreDuringTheHandOverHappensOnceItSettles() = windowTest {
        add(100)
        val window = TranscriptWindow(
            source = { range ->
                val answers = relay.map { Result.success(transcriptChunk(it, range.afterSeq, range.throughSeq, range.limit)) }
                // The live end answers late, as over a slow network.
                if (range.afterSeq != null && range.throughSeq == null) flow { delay(500); emitAll(answers) } else answers
            },
            scope = windowScope,
        )
        window.start()
        testScheduler.runCurrent()
        assertTrue("only the opening has answered", window.state.value.loaded)
        window.loadMore()
        assertFalse("nothing older yet: the live end is on its way", window.state.value.loadingMore)
        advanceUntilIdle()
        assertEquals((1L..100L).toList(), window.seqs)
        assertTrue(window.state.value.historyComplete)
    }

    @Test
    fun aBurstLargerThanTheLiveEndStartsOver() = windowTest {
        add(10)
        val window = window()
        add(250) // the phone slept through a busy turn
        advanceUntilIdle()
        assertEquals(1, window.restarts)
        assertEquals("the newest again", (221L..260L).toList(), window.seqs)
        assertFalse(window.state.value.historyComplete)
        assertEquals(listOf(TranscriptRange(afterSeq = 220, limit = 200)), window.ranges)
    }

    @Test
    fun aReplacedTranscriptStartsOver() = windowTest {
        add(100)
        val window = window()
        window.loadMore()
        advanceUntilIdle()
        assertEquals((1L..100L).toList(), window.seqs)
        // The computer resyncs: every item goes, new ones follow from the next seq.
        relay.value = (101L..120L).map { seq -> RelayEvent("r$seq", seq, "k$seq", EventKind.ASSISTANT, "again", at = 0) }
        advanceUntilIdle()
        assertTrue(window.restarts >= 1)
        assertEquals((101L..120L).toList(), window.seqs)
        assertTrue(window.state.value.historyComplete)
    }

    @Test
    fun anEmptySessionWaitsForItsFirstItems() = windowTest {
        val window = window()
        assertTrue(window.state.value.loaded)
        assertTrue(window.state.value.events.isEmpty())
        assertTrue(window.state.value.historyComplete)
        add(2)
        advanceUntilIdle()
        assertEquals(listOf(1L, 2L), window.seqs)
        assertEquals(listOf(TranscriptRange(afterSeq = 0, limit = 200)), window.ranges)
    }

    @Test
    fun theRelayLeavesOutThoughtAndToolText() {
        val events = listOf(
            RelayEvent("e1", 1, "k1", EventKind.THOUGHT, "secret reasoning", at = 1),
            RelayEvent("e2", 2, "k2", EventKind.TOOL, "$ cargo test\nok", at = 2),
            RelayEvent("e3", 3, "k3", EventKind.TOOL, "out", title = "Read a.rs", at = 3),
            RelayEvent("e4", 4, "k4", EventKind.ASSISTANT, "Done.", at = 4),
        )
        val chunk = transcriptChunk(events, limit = 10)
        assertEquals(listOf(4L, 3L, 2L, 1L), chunk.events.map { it.seq })
        assertEquals(listOf("Done.", "", "", ""), chunk.events.map { it.text })
        assertEquals(listOf(null, "Read a.rs", "$ cargo test", null), chunk.events.map { it.title })
        assertFalse(chunk.more)
        assertTrue(transcriptChunk(events, limit = 2).more)
    }
}
