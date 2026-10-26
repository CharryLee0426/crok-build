package dev.chenli.crok.mobile.screenshots

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import dev.chenli.crok.mobile.data.O11yDecode
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoO11y
import dev.chenli.crok.mobile.ui.AccountInfo
import dev.chenli.crok.mobile.ui.ComputerState
import dev.chenli.crok.mobile.ui.HomeScaffold
import dev.chenli.crok.mobile.ui.HomeTabsUi
import dev.chenli.crok.mobile.ui.O11Y_TAB
import dev.chenli.crok.mobile.ui.common.GlassLevel
import dev.chenli.crok.mobile.ui.common.LocalGlassLevel
import dev.chenli.crok.mobile.ui.o11y.O11yActions
import dev.chenli.crok.mobile.ui.o11y.O11yContent
import dev.chenli.crok.mobile.ui.o11y.O11yUi
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The o11y tab (mobile/DESIGN.md "o11y") from the demo pages (o11y-demo.json): pictures written only when recording
 * (`./gradlew :app:recordRoborazziDebug --tests '*O11yScreenshotTest*'` → app/build/outputs/roborazzi/o11y-*.png), and
 * the chart's touches: a drag that starts on a chart scrolls the page, a tap shows the callout and another hides it.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = RobolectricDeviceQualifiers.Pixel7)
class O11yScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val now = LocalDateTime.of(2026, 10, 26, 7, 30).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val demo by lazy { DemoO11y(File("src/debug/assets/o11y-demo.json").readText(), clock = { now }) }
    private val account = AccountInfo("Chen Li", "chen@example.com", null)

    @Before
    fun fixedZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    private fun ui(page: String, lang: String = "en", forced: O11yPageState.State? = null): O11yUi {
        val source = if (forced != null) DemoO11y(File("src/debug/assets/o11y-demo.json").readText(), clock = { now }, forced = forced) else demo
        return O11yUi(state = O11yDecode.state(source.answer(mapOf("page" to page, "lang" to lang))), now = now)
    }

    private fun computers(): ComputerState {
        val state = DemoData.state(now)
        return ComputerState.build(DemoData.groups(state), listed = true, devices = state.devices, remembered = null)
    }

    private fun shoot(name: String, dark: Boolean = false, capture: Boolean = true, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CrokTheme(dark = dark) {
                CompositionLocalProvider(LocalGlassLevel provides GlassLevel.Liquid) {
                    Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) { content() }
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)
        if (capture) compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    /** The o11y tab selected in the home tab bar around [page]. */
    @Composable
    private fun Tab(page: String, ui: O11yUi, back: Boolean = page != "home") {
        HomeScaffold(tab = O11Y_TAB, onTab = {}, ui = HomeTabsUi(account, computers()), showO11y = true) {
            O11yContent(page, ui, O11yActions(onBack = if (back) ({}) else null))
        }
    }

    @Test
    fun home() = shoot("o11y-01-home") { Tab("home", ui("home")) }

    @Test
    @Config(qualifiers = "+h1500dp")
    fun homeTall() = shoot("o11y-02-home-tall") { Tab("home", ui("home")) }

    @Test
    fun overview() = shoot("o11y-03-overview") { Tab("overview", ui("overview")) }

    @Test
    @Config(qualifiers = "+h3400dp")
    fun overviewTall() = shoot("o11y-04-overview-tall") { Tab("overview", ui("overview")) }

    @Test
    @Config(qualifiers = "+h2600dp")
    fun evaluatorsTall() = shoot("o11y-05-evaluators-tall") { Tab("evaluators", ui("evaluators")) }

    @Test
    @Config(qualifiers = "+h2600dp")
    fun historyTall() = shoot("o11y-06-history-tall") { Tab("history", ui("history")) }

    @Test
    @Config(qualifiers = "+h2200dp")
    fun agentsAndListsTall() = shoot("o11y-07-explorer-tall") { Tab("explorer", ui("explorer")) }

    @Test
    @Config(qualifiers = "+land")
    fun wideHome() = shoot("o11y-08-wide-home") { Tab("home", ui("home")) }

    @Test
    @Config(qualifiers = "+land")
    fun wideOverview() = shoot("o11y-09-wide-overview") { Tab("overview", ui("overview")) }

    @Test
    @Config(qualifiers = "w914dp-h2400dp")
    fun wideOverviewTall() = shoot("o11y-10-wide-overview-tall") { Tab("overview", ui("overview")) }

    @Test
    fun darkHome() = shoot("o11y-11-dark-home", dark = true) { Tab("home", ui("home")) }

    @Test
    @Config(qualifiers = "+h3400dp")
    fun darkOverviewTall() = shoot("o11y-12-dark-overview-tall", dark = true) { Tab("overview", ui("overview")) }

    @Test
    @Config(qualifiers = "+de")
    fun germanOverview() = shoot("o11y-13-de-overview") { Tab("overview", ui("overview", "de")) }

    @Test
    @Config(qualifiers = "+zh-rCN-h1500dp")
    fun chineseHome() = shoot("o11y-14-zh-home") { Tab("home", ui("home", "zh")) }

    @Test
    fun unconfigured() = shoot("o11y-15-unconfigured") { Tab("home", ui("home", forced = O11yPageState.State.UNCONFIGURED)) }

    @Test
    @Config(qualifiers = "+h1200dp")
    fun slosAndAlerts() = shoot("o11y-16-slos") { Tab("slos", ui("slos")) }

    /** A tap on a chart shows its callout (pictured), a second tap on the same point hides it. */
    @Test
    fun tapShowsTheCallout() {
        shoot("o11y-17-callout", capture = false) { Tab("overview", ui("overview")) }
        val plot = compose.onAllNodesWithTag("o11y-plot")[0]
        plot.performTouchInput { click(centerRight.copy(x = width * 0.8f)) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onAllNodesWithTag("o11y-callout").assertCountEquals(1)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/o11y-17-callout.png")
        plot.performTouchInput { click(centerRight.copy(x = width * 0.8f)) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onAllNodesWithTag("o11y-callout").assertCountEquals(0)
    }

    /** The bug iOS had: a vertical drag that starts on a chart must still scroll the page. */
    @Test
    fun aDragStartingOnAChartScrollsThePage() {
        shoot("o11y-scroll", capture = false) { Tab("overview", ui("overview")) }
        val below = compose.onNodeWithTag("o11y-section-4")
        val before = below.getUnclippedBoundsInRoot().top
        compose.onAllNodesWithTag("o11y-plot")[0].performTouchInput { swipeUp(startY = centerY + height * 0.3f, endY = top - 400f, durationMillis = 300) }
        compose.mainClock.advanceTimeBy(2_000)
        val after = below.getUnclippedBoundsInRoot().top
        assertTrue("the page scrolled (from $before to $after)", after < before - 50.dp)
    }
}
