package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.SessionListState
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.time.LocalDateTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Reorder mode's drag handles, driven by touch on the JVM: what a drop sends. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], qualifiers = RobolectricDeviceQualifiers.Pixel7)
class ReorderDragTest {
    @get:Rule
    val compose = createComposeRule()

    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()

    private var projects: List<String>? = null
    private var sessions: Pair<String, List<String>>? = null
    private var opened = mutableListOf<String?>()
    private var dragging = mutableListOf<Boolean>()

    /** Reorder mode on the demo list; with [open], that project is open to move its sessions. */
    private fun show(open: String? = null) {
        val state = SessionsUiState.build(
            SessionListState(DemoData.groups(DemoData.state(now)), live = true),
            null,
            SessionFilter.All,
            "",
            ConnectionState.Connected,
            now,
            reordering = true,
            reorderProject = open,
        )
        compose.setContent {
            CrokTheme(dark = false) {
                SessionsContent(
                    state,
                    SessionsActions(
                        onReorderProjects = { projects = it },
                        onReorderSessions = { key, ids -> sessions = key to ids },
                        onReorderProject = { opened += it },
                        onDragging = { dragging += it },
                    ),
                )
            }
        }
        compose.waitForIdle()
    }

    /** Presses the handle, moves it [dy] px in small steps (a frame between each), lets go. */
    private fun SemanticsNodeInteraction.drag(dy: Float, steps: Int = 12) {
        performTouchInput { down(center) }
        compose.waitForIdle()
        repeat(steps) {
            performTouchInput { moveBy(Offset(0f, dy / steps)) }
            compose.waitForIdle()
        }
        performTouchInput { up() }
        compose.waitForIdle()
    }

    private fun dp(value: Float) = value * compose.density.density

    @Test
    fun draggingAProjectDownPutsItAfterTheNextOne() {
        show()
        // Projects show as ~52 dp headers: a bit more than one header down passes one.
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.MACBOOK_CROK_SITE)).drag(dp(64f))
        assertEquals(
            listOf(DemoData.MACBOOK_CROK_BUILD, DemoData.STUDIO_CROK_BUILD, DemoData.MACBOOK_CROK_SITE, DemoData.LINUX_INGEST),
            projects,
        )
        assertNull(sessions)
        assertEquals(listOf(true, false), dragging)
    }

    @Test
    fun draggingAProjectFarUpPutsItFirst() {
        show()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.LINUX_INGEST)).drag(-dp(200f), steps = 20)
        assertEquals(
            listOf(DemoData.LINUX_INGEST, DemoData.MACBOOK_CROK_BUILD, DemoData.MACBOOK_CROK_SITE, DemoData.STUDIO_CROK_BUILD),
            projects,
        )
    }

    @Test
    fun tappingAProjectOpensIt() {
        show()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.MACBOOK_CROK_SITE)).assertExists()
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s7")).assertDoesNotExist()
        compose.onNodeWithText("crok-site").performClick()
        assertEquals(listOf<String?>(DemoData.MACBOOK_CROK_SITE), opened)
    }

    @Test
    fun anOpenProjectShowsEverySessionWithAHandle() {
        // Every session (no "Show more"), and no project handles while one is open.
        show(open = DemoData.MACBOOK_CROK_BUILD)
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s11")).assertExists()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.MACBOOK_CROK_SITE)).assertDoesNotExist()
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s12")).assertDoesNotExist()
    }

    @Test
    fun draggingASessionUpTradesPlacesWithinItsProject() {
        show(open = DemoData.MACBOOK_CROK_BUILD)
        // Rows are ~64 dp: about one row up passes the session above.
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s7")).drag(-dp(80f))
        val expected = listOf("demo-s7", DemoData.RUNNING_SESSION, DemoData.CATALOG_SESSION, "demo-s9", "demo-s10", "demo-s11")
        assertEquals(DemoData.MACBOOK_CROK_BUILD to expected, sessions)
        assertNull(projects)
    }

    @Test
    fun anUnpinnedSessionCannotPassAPinnedOne() {
        show(open = DemoData.MACBOOK_CROK_SITE)
        // crok-site: the pinned waiting session, then demo-s12. Dragging demo-s12 above it changes nothing.
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s12")).drag(-dp(90f))
        assertNull(sessions)
        assertNull(projects)
    }

    @Test
    fun theToolbarOpensReorderMode() {
        var reordering: Boolean? = null
        val state = SessionsUiState.build(
            SessionListState(DemoData.groups(DemoData.state(now)), live = true), null, SessionFilter.All, "", ConnectionState.Connected, now,
        )
        compose.setContent {
            CrokTheme(dark = false) { SessionsContent(state, SessionsActions(onReordering = { reordering = it })) }
        }
        compose.onNodeWithTag("reorder").performClick()
        assertEquals(true, reordering)
    }
}
