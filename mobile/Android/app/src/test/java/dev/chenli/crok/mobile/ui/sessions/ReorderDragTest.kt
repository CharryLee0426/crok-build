package dev.chenli.crok.mobile.ui.sessions

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.ui.ComputerState
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

/** The drag handles of Edit mode (projects) and of a project's Reorder mode (sessions), driven by touch on the JVM. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], qualifiers = RobolectricDeviceQualifiers.Pixel7)
class ReorderDragTest {
    @get:Rule
    val compose = createComposeRule()

    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val demo = DemoData.state(now)

    private var projects: List<String>? = null
    private var sessions: List<String>? = null
    private var dragging = mutableListOf<Boolean>()

    private fun computers() = ComputerState.build(DemoData.groups(demo), listed = true, devices = demo.devices, remembered = DemoData.MACBOOK_ID)

    /** The MacBook's projects in Edit mode. */
    private fun showProjects() {
        val state = SessionsUiState.build(computers(), emptyList(), "", ConnectionState.Connected, now, editing = true)
        compose.setContent {
            CrokTheme(dark = false) {
                SessionsContent(state, SessionsActions(onReorderProjects = { projects = it }, onDragging = { dragging += it }))
            }
        }
        compose.waitForIdle()
    }

    /** A project's sessions in Reorder mode. */
    private fun showProject(key: String) {
        val state = ProjectUiState.build(DemoData.groups(demo), live = true, key, "", reordering = true, ConnectionState.Connected, now)
        compose.setContent {
            CrokTheme(dark = false) {
                ProjectContent(state, ProjectActions(onReorder = { sessions = it }, onDragging = { dragging += it }))
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
    fun draggingAProjectUpPutsItFirst() {
        showProjects()
        // Project lines are ~64 dp: a bit more than one line up passes one.
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.MACBOOK_CROK_SITE)).drag(-dp(80f))
        assertEquals(listOf(DemoData.MACBOOK_CROK_SITE, DemoData.MACBOOK_CROK_BUILD), projects)
        assertEquals(listOf(true, false), dragging)
    }

    @Test
    fun editModeListsOnlyTheSelectedComputersProjects() {
        showProjects()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.MACBOOK_CROK_BUILD)).assertExists()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.STUDIO_CROK_BUILD)).assertDoesNotExist()
        compose.onNodeWithTag(ReorderDragState.headerKey(DemoData.LINUX_INGEST)).assertDoesNotExist()
    }

    @Test
    fun draggingASessionUpTradesPlacesWithinItsProject() {
        showProject(DemoData.MACBOOK_CROK_BUILD)
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s7")).drag(-dp(80f))
        val expected = listOf("demo-s7", DemoData.RUNNING_SESSION, DemoData.CATALOG_SESSION, "demo-s9", "demo-s10", "demo-s11")
        assertEquals(expected, sessions)
    }

    @Test
    fun anUnpinnedSessionCannotPassAPinnedOne() {
        showProject(DemoData.MACBOOK_CROK_SITE)
        // crok-site: the pinned waiting session, then demo-s12. Dragging demo-s12 above it changes nothing.
        compose.onNodeWithTag(ReorderDragState.rowKey("demo-s12")).drag(-dp(90f))
        assertNull(sessions)
    }

    @Test
    fun theTopBarsEditButtonOpensEditMode() {
        var editing: Boolean? = null
        val state = SessionsUiState.build(computers(), emptyList(), "", ConnectionState.Connected, now)
        compose.setContent {
            CrokTheme(dark = false) { SessionsContent(state, SessionsActions(onEditing = { editing = it })) }
        }
        compose.onNodeWithTag("edit").performClick()
        assertEquals(true, editing)
    }
}
