package dev.chenli.crok.mobile.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import dev.chenli.crok.mobile.logic.AttachmentKind
import java.io.File
import java.time.LocalDateTime
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Preparing picks for upload (relay/DESIGN.md §5 "Preparing an upload"), on Robolectric's native graphics. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class AttachmentPrepTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val preparer = AttachmentPreparer(context)
    private val at = LocalDateTime.of(2026, 10, 27, 14, 30, 5)
    private val source = File(context.cacheDir, "picks").apply { mkdirs() }

    private fun picture(name: String, width: Int, height: Int, format: Bitmap.CompressFormat, alpha: Boolean = false): Uri {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(if (alpha) Color.TRANSPARENT else Color.rgb(51, 144, 236))
        if (alpha) bitmap.setPixel(0, 0, Color.RED)
        val file = File(source, name)
        file.outputStream().use { bitmap.compress(format, 90, it) }
        return Uri.fromFile(file)
    }

    private fun prepare(uri: Uri, fromPhotos: Boolean, index: Int = 0) = runBlocking { preparer.prepare(AttachmentPick(uri, fromPhotos), index, at) }

    @Test
    fun aLargePhotoIsScaledToJpegWithAThumbnailAndATimeName() {
        val outcome = prepare(picture("IMG_1.jpg", 4000, 3000, Bitmap.CompressFormat.JPEG), fromPhotos = true, index = 1) as PrepOutcome.Prepared
        assertEquals(AttachmentKind.Image, outcome.kind)
        assertEquals("photo-20261027-143005-2.jpg", outcome.name)
        assertEquals("image/jpeg", outcome.mimeType)
        assertEquals(2048, outcome.width)
        assertEquals(1536, outcome.height)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(outcome.file.path, bounds)
        assertEquals(2048, bounds.outWidth)
        BitmapFactory.decodeFile(outcome.thumbFile!!.path, bounds)
        assertEquals(480, bounds.outWidth)
        assertEquals("image/jpeg", bounds.outMimeType)
        assertEquals(outcome.file.length(), outcome.size)
    }

    @Test
    fun aPngFromFilesStaysPngAndKeepsItsName() {
        val outcome = prepare(picture("diagram.png", 300, 200, Bitmap.CompressFormat.PNG, alpha = true), fromPhotos = false) as PrepOutcome.Prepared
        assertEquals("diagram.png", outcome.name)
        assertEquals("image/png", outcome.mimeType)
        assertEquals(300, outcome.width)
        // The thumbnail draws transparency on white.
        val thumb = BitmapFactory.decodeFile(outcome.thumbFile!!.path)
        val corner = thumb.getPixel(thumb.width - 1, thumb.height - 1)
        assertTrue(Color.red(corner) > 240 && Color.green(corner) > 240 && Color.blue(corner) > 240)
    }

    @Test
    fun anyOtherFileGoesAsItIs() {
        val file = File(source, "notes.md").apply { writeText("# Notes\n") }
        val outcome = prepare(Uri.fromFile(file), fromPhotos = false) as PrepOutcome.Prepared
        assertEquals(AttachmentKind.File, outcome.kind)
        assertEquals("notes.md", outcome.name)
        assertEquals("text/markdown", outcome.mimeType)
        assertEquals("# Notes\n", outcome.file.readText())
        assertEquals(null, outcome.thumbFile)
    }

    @Test
    fun aFileOverTwentyMegabytesIsRefused() {
        val file = File(source, "huge.bin")
        file.outputStream().use { out -> val chunk = ByteArray(1024 * 1024); repeat(21) { out.write(chunk) } }
        assertTrue(prepare(Uri.fromFile(file), fromPhotos = false) is PrepOutcome.TooBig)
    }
}
