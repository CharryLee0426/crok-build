package dev.chenli.crok.mobile.screenshots

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.TranscriptState
import androidx.test.core.app.ApplicationProvider
import dev.chenli.crok.mobile.ui.session.MarkdownText
import dev.chenli.crok.mobile.ui.session.MathImages
import dev.chenli.crok.mobile.ui.session.SessionActions
import dev.chenli.crok.mobile.ui.session.SessionContent
import dev.chenli.crok.mobile.ui.session.SessionUiState
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.TimeZone
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The shared Markdown showcase (relay/scripts/markdown-showcase.md) in a session, on a phone-wide window tall enough
 * for the whole reply: `./gradlew :app:recordRoborazziDebug --tests '*MarkdownScreenshotTest*'`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w411dp-h4600dp-normal-long-notround-any-420dpi-keyshidden-nonav")
class MarkdownScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()

    @Before
    fun fixedZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        // The app starts JLatexMath in the background; here it is ready before the first frame.
        MathImages.warmUp(ApplicationProvider.getApplicationContext())
    }

    private fun shoot(name: String, dark: Boolean, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CrokTheme(dark = dark) {
                Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) { content() }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    private fun showcaseSession(): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.SHOWCASE_SESSION }
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(DemoData.showcaseEvents(now).sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = ZoneOffset.UTC,
        )
    }

    @Test
    fun showcaseLight() = shoot("30-markdown-light", dark = false) {
        SessionContent(showcaseSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun showcaseDark() = shoot("31-markdown-dark", dark = true) {
        SessionContent(showcaseSession(), draft = "", now = now, actions = SessionActions())
    }

    /** Replies cut off mid-stream: inside a fence, and after an opening `$$` and a half-written table. */
    @Test
    fun halfStreamed() = shoot("32-markdown-streaming", dark = false) {
        val fence = "Here is the fix, **step by step**:\n\n1. Wait for the socket\n2. Then assert\n\n" +
            "```rust\nclient.wait_connected(Duration::from_secs(5)).await?;\nlet n = clients.len("
        val math = "The sum is \$\\sum_k k\$ and **the bound** is\n\$\$\n\\sum_{k=1}^{n} k = \\frac{n(n+1)}{\n\n| a | b |\n|---|"
        // An inline formula wider than 60 % of the screen is lifted out as a display block that scrolls.
        val wide = "So \$p(x) = a_0 + a_1 x + a_2 x^2 + a_3 x^3 + a_4 x^4 + a_5 x^5 + a_6 x^6 + a_7 x^7 + a_8 x^8\$ for every *x*."
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            for (text in listOf(fence, math, wide)) {
                Box(Modifier.fillMaxWidth(0.92f).clip(RoundedCornerShape(18.dp)).background(CrokTheme.colors.bubbleIn).padding(12.dp)) {
                    MarkdownText(text)
                }
            }
        }
    }
}
