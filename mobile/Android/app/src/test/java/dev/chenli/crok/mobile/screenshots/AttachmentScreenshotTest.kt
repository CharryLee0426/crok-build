package dev.chenli.crok.mobile.screenshots

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.test.core.app.ApplicationProvider
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import dev.chenli.crok.mobile.data.Attachment
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.DraftAttachment
import dev.chenli.crok.mobile.logic.UploadState
import dev.chenli.crok.mobile.logic.shown
import dev.chenli.crok.mobile.ui.common.GlassLevel
import dev.chenli.crok.mobile.ui.common.LocalGlassLevel
import dev.chenli.crok.mobile.ui.session.AttachLaunchers
import dev.chenli.crok.mobile.ui.session.SessionActions
import dev.chenli.crok.mobile.ui.session.SessionContent
import dev.chenli.crok.mobile.ui.session.SessionUiState
import dev.chenli.crok.mobile.ui.session.ViewerContent
import dev.chenli.crok.mobile.ui.session.ViewerRequest
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.LocalSessionAppearance
import dev.chenli.crok.mobile.ui.theme.SessionAppearance
import java.io.File
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
 * Photos and files in prompts (relay/DESIGN.md §5): media bubbles, the composer's strip, the viewer, files only on the
 * computer. Written when recording: `./gradlew :app:recordRoborazziDebug` → app/build/outputs/roborazzi/.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = RobolectricDeviceQualifiers.Pixel7)
class AttachmentScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val zone = ZoneOffset.UTC
    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Before
    fun fixedZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    private fun shoot(name: String, dark: Boolean = false, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CrokTheme(dark = dark) {
                CompositionLocalProvider(LocalGlassLevel provides GlassLevel.Liquid, LocalSessionAppearance provides SessionAppearance()) {
                    Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) { content() }
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    private val actions = SessionActions(attach = AttachLaunchers(photos = {}, camera = {}, files = {}))

    private fun session(
        events: List<RelayEvent> = DemoData.attachmentEvents(now),
        attachments: List<DraftAttachment> = emptyList(),
    ): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.ATTACHMENTS_SESSION }
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(events.sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = DemoData.state(now).commands.filter { it.sessionDocId == DemoData.ATTACHMENTS_SESSION }.map { it.prompt() },
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = zone,
            deviceModels = Result.success(DemoData.modelsFor(session.detail.deviceId)),
            attachments = attachments,
            canAttach = true,
        )
    }

    /** A picture written to the cache, standing in for one the phone prepared. */
    private fun localPicture(name: String, top: Int, bottom: Int): String {
        val bitmap = Bitmap.createBitmap(480, 360, Bitmap.Config.ARGB_8888)
        val paint = Paint().apply { shader = LinearGradient(0f, 0f, 480f, 360f, top, bottom, Shader.TileMode.CLAMP) }
        Canvas(bitmap).drawRect(0f, 0f, 480f, 360f, paint)
        val file = File(context.cacheDir, name)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }
        return file.path
    }

    private fun strip(): List<DraftAttachment> = listOf(
        DraftAttachment("a1", AttachmentKind.Image, "photo-20261015-154001.jpg", "image/jpeg", 812_000, 2048, 1536,
            thumbFile = localPicture("strip-1.jpg", 0xFF3390EC.toInt(), 0xFF7B5CFF.toInt()), storageId = "s1", state = UploadState.Ready),
        DraftAttachment("a2", AttachmentKind.Image, "photo-20261015-154001-2.jpg", "image/jpeg", 640_000, 2048, 1536,
            thumbFile = localPicture("strip-2.jpg", 0xFF20B486.toInt(), 0xFFF6B800.toInt()), state = UploadState.Uploading(0.4f)),
        DraftAttachment("a3", AttachmentKind.File, "onboarding-spec.pdf", "application/pdf", 1_258_291, storageId = "s3", state = UploadState.Ready),
        DraftAttachment("a4", AttachmentKind.File, "build-log-2026-10-15.txt", "text/plain", 48_000, state = UploadState.Failed("offline")),
        DraftAttachment("a5", AttachmentKind.Image, "", state = UploadState.Preparing),
    )

    @Test
    fun mediaBubblesLight() = shoot("40-attachments-session") {
        SessionContent(session(), draft = "", now = now, actions = actions)
    }

    @Test
    fun twoPhotosAndAFile() = shoot("40b-attachments-grid") {
        SessionContent(session(events = DemoData.attachmentEvents(now).take(1)), draft = "", now = now, actions = actions)
    }

    @Test
    fun mediaBubblesDark() = shoot("41-attachments-session-dark", dark = true) {
        SessionContent(session(), draft = "", now = now, actions = actions)
    }

    @Test
    fun theStripAboveTheComposer() = shoot("42-attachment-strip") {
        SessionContent(session(attachments = strip()), draft = "Match these, please", now = now, actions = actions)
    }

    @Test
    fun theStripDark() = shoot("43-attachment-strip-dark", dark = true) {
        SessionContent(session(attachments = strip().take(3)), draft = "", now = now, actions = actions)
    }

    @Test
    fun theViewer() = shoot("44-image-viewer", dark = true) {
        val images = DemoData.attachmentEvents(now).first().attachments.filter { it.isImage }
            .mapIndexed { index, attachment -> attachment.shown(index) }
        ViewerContent(ViewerRequest(images, 1), onDismiss = {})
    }

    @Test
    fun filesThatCannotBeOpened() = shoot("45-attachments-unavailable") {
        val at = now - 30 * 60_000
        val events = listOf(
            RelayEvent(
                "u1", 1, "k1", EventKind.USER, "Compare these with the screenshot I took here", at = at, origin = "local",
                attachments = listOf(
                    Attachment(name = "Screenshot 2026-10-15 at 15.10.png", mimeType = "image/png", kind = "image"),
                    Attachment(name = "notes.md", mimeType = "text/markdown", size = 1_200, kind = "file"),
                ),
            ),
            RelayEvent(
                "u2", 2, "k2", EventKind.USER, "", at = at + 60_000, origin = "remote", commandId = "demo-cmd-x", fromLabel = DemoData.PHONE_NAME,
                attachments = listOf(Attachment(storageId = "gone-1", name = "photo-20260910-101500.jpg", mimeType = "image/jpeg", size = 900_000, kind = "image")),
            ),
            RelayEvent("a3", 3, "k3", EventKind.ASSISTANT, "The screenshot is on the MacBook, so I read it from there.", at = at + 90_000),
        )
        SessionContent(session(events = events), draft = "", now = now, actions = actions)
    }

    @Test
    @Config(qualifiers = "zh-rCN")
    fun mediaBubblesChinese() = shoot("46-attachments-zh") {
        SessionContent(session(attachments = strip().take(2)), draft = "", now = now, actions = actions)
    }
}
