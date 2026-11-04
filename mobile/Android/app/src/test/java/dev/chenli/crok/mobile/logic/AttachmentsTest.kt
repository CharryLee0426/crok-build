package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.Attachment
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayJson
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** relay/DESIGN.md §5 "Photos and files in prompts": limits, preparation, names, labels, and how items show. */
class AttachmentsTest {
    @Test
    fun imagesAreScaledToTheirLongerSide() {
        assertEquals(2048 to 1536, AttachmentRules.targetSize(4032, 3024))
        assertEquals(886 to 2048, AttachmentRules.targetSize(1170, 2704))
        assertEquals(800 to 600, AttachmentRules.targetSize(800, 600))
        assertEquals(480 to 360, AttachmentRules.targetSize(4032, 3024, AttachmentRules.THUMB_SIDE))
    }

    @Test
    fun everyImageButASmallGifIsReEncoded() {
        assertEquals(AttachmentRules.Encoding.Jpeg, AttachmentRules.encodingFor("image/jpeg", hasAlpha = false, byteCount = 1_000))
        assertEquals(AttachmentRules.Encoding.Jpeg, AttachmentRules.encodingFor("image/heic", hasAlpha = false, byteCount = 1_000))
        assertEquals(AttachmentRules.Encoding.Png, AttachmentRules.encodingFor("image/png", hasAlpha = false, byteCount = 1_000))
        assertEquals(AttachmentRules.Encoding.Png, AttachmentRules.encodingFor("image/webp", hasAlpha = true, byteCount = 1_000))
        assertEquals(AttachmentRules.Encoding.AsIs, AttachmentRules.encodingFor("image/gif", hasAlpha = true, byteCount = 9_000_000))
        // A larger GIF goes as its first frame, re-encoded.
        assertEquals(AttachmentRules.Encoding.Png, AttachmentRules.encodingFor("image/gif", hasAlpha = true, byteCount = 11_000_000))
        assertEquals("image/jpeg", AttachmentRules.mimeFor(AttachmentRules.Encoding.Jpeg, "image/heic"))
        assertEquals("image/gif", AttachmentRules.mimeFor(AttachmentRules.Encoding.AsIs, "image/gif"))
    }

    @Test
    fun photosWithoutANameAreNamedByTheTime() {
        val at = LocalDateTime.of(2026, 10, 27, 9, 5, 3)
        assertEquals("photo-20261027-090503.jpg", AttachmentRules.photoName(at, 0, "jpg"))
        assertEquals("photo-20261027-090503-2.jpg", AttachmentRules.photoName(at, 1, "jpg"))
        assertEquals("photo-20261027-090503-3.png", AttachmentRules.photoName(at, 2, "png"))
    }

    @Test
    fun aReEncodedFileKeepsItsNameWithTheNewExtension() {
        assertEquals("IMG_0042.jpg", AttachmentRules.withExtension("IMG_0042.HEIC", "jpg"))
        assertEquals("diagram.png", AttachmentRules.withExtension("diagram", "png"))
        assertEquals(".env.jpg", AttachmentRules.withExtension(".env", "jpg"))
    }

    @Test
    fun filesGoWithTheSystemsTypeElseTheirExtensions() {
        assertEquals("application/pdf", AttachmentRules.mimeFor("report.pdf", null))
        assertEquals("application/pdf", AttachmentRules.mimeFor("report.pdf", "application/octet-stream"))
        assertEquals("text/x-kotlin", AttachmentRules.mimeFor("Main.kt", "text/x-kotlin; charset=utf-8"))
        assertEquals(AttachmentRules.OCTET_STREAM, AttachmentRules.mimeFor("blob", null))
        assertTrue(AttachmentRules.isImageType("image/HEIC"))
        assertFalse(AttachmentRules.isImageType("application/pdf"))
    }

    @Test
    fun sizesAndTypesReadLikeTelegrams() {
        assertEquals("12 B", AttachmentRules.sizeLabel(12, Locale.US))
        assertEquals("1.2 MB", AttachmentRules.sizeLabel(1_258_291, Locale.US))
        assertEquals("1,2 MB", AttachmentRules.sizeLabel(1_258_291, Locale.GERMANY))
        assertEquals("340 KB", AttachmentRules.sizeLabel(348_160, Locale.US))
        assertEquals("PDF", AttachmentRules.typeLabel("report.pdf", "application/pdf"))
        assertEquals("PNG", AttachmentRules.typeLabel("screenshot", "image/png"))
        assertEquals("FILE", AttachmentRules.typeLabel("blob", AttachmentRules.OCTET_STREAM))
        assertEquals("1.2 MB · PDF", AttachmentRules.fileLine(1_258_291, "spec.pdf", "application/pdf", Locale.US))
    }

    @Test
    fun atMostTenFitInOneMessage() {
        assertEquals(3, AttachmentRules.room(attached = 0, picked = 3))
        assertEquals(2, AttachmentRules.room(attached = 8, picked = 5))
        assertEquals(0, AttachmentRules.room(attached = 10, picked = 1))
    }

    @Test
    fun outgoingArgumentsCarryDoublesAndLeaveOutWhatIsNotThere() {
        val image = OutgoingAttachment("s1", "t1", "photo.jpg", "image/jpeg", 10, AttachmentKind.Image, 2048, 1536)
        assertEquals(mapOf("storageId" to "s1", "thumbId" to "t1", "name" to "photo.jpg", "width" to 2048.0, "height" to 1536.0), image.args())
        val file = OutgoingAttachment("s2", null, "spec.pdf", "application/pdf", 10, AttachmentKind.File, null, null)
        assertEquals(mapOf("storageId" to "s2", "name" to "spec.pdf"), file.args())
    }

    @Test
    fun aRelayAttachmentShowsItsThumbnailAndOpensTheOriginal() {
        val shown = Attachment("s1", "t1", "a.png", "image/png", 99, "image", 4, 3, "https://x/s1", "https://x/t1").shown(0)
        assertEquals(FileRef("https://x/t1", "t1"), shown.preview)
        assertEquals(FileRef("https://x/s1", "s1"), shown.full)
        assertEquals(4f / 3f, shown.aspect!!, 0.001f)
        assertNull(shown.unavailable)
        // No thumbnail: the image itself is the preview.
        assertEquals(FileRef("https://x/s1", "s1"), Attachment("s1", name = "a.png", kind = "image", url = "https://x/s1").shown(0).preview)
    }

    @Test
    fun anAttachmentWithoutAUrlSaysWhy() {
        assertEquals(Unavailable.OnComputer, Attachment(name = "notes.md", kind = "file").shown(0).unavailable)
        assertEquals(Unavailable.Gone, Attachment(storageId = "s1", name = "a.png", kind = "image").shown(0).unavailable)
        assertNull(Attachment(storageId = "s1", name = "a.png", kind = "image").shown(0).preview)
    }

    @Test
    fun transcriptItemsAndPendingPromptsDecodeTheirAttachments() {
        val event = RelayJson.decodeFromString(
            RelayEvent.serializer(),
            """{"_id":"e1","seq":3.0,"key":"k","kind":"user","text":"","attachments":[{"storageId":"s1","thumbId":"t1","name":"a.png",
               "mimeType":"image/png","size":1200.0,"kind":"image","width":800.0,"height":600.0,"url":"https://x/s1","thumbUrl":null}],"at":1.0}""",
        )
        assertEquals(1, event.attachments.size)
        assertEquals(800, event.attachments[0].width)
        assertNull(event.attachments[0].thumbUrl)
        assertTrue(event.attachments[0].isImage)
        val older = RelayJson.decodeFromString(RelayEvent.serializer(), """{"_id":"e2","kind":"user","text":"hi"}""")
        assertTrue(older.attachments.isEmpty())
        val command = RelayJson.decodeFromString(
            PromptCommand.serializer(),
            """{"_id":"c1","text":"","status":"pending","fromLabel":"Pixel","attachments":[{"name":"spec.pdf","kind":"file","url":"https://x/s2","storageId":"s2"}]}""",
        )
        assertEquals("spec.pdf", command.attachments.single().name)
    }

    @Test
    fun theTranscriptShowsAttachmentsOnItemsOptimisticBubblesAndPendingPrompts() {
        val zone = ZoneOffset.UTC
        val image = Attachment("s1", null, "a.jpg", "image/jpeg", 10, "image", 4, 3, "https://x/s1")
        val events = listOf(RelayEvent("e1", 1, "k1", EventKind.USER, "", origin = "remote", at = 1_000, attachments = listOf(image)))
        val pending = PromptCommand(
            "cmd-2", "client-2", "", CommandStatus.PENDING, null, "Pixel 9", mine = true, createdAt = 5_000, updatedAt = 5_000,
            attachments = listOf(Attachment("s3", name = "spec.pdf", kind = "file", url = "https://x/s3")),
        )
        val optimistic = OptimisticPrompt(
            "client-3", "look", 6_000,
            attachments = listOf(OutgoingAttachment("s4", "t4", "photo.jpg", "image/jpeg", 10, AttachmentKind.Image, 2, 1, "/tmp/a.jpg", "/tmp/t.jpg")),
        )
        val rows = Transcript.build(events, listOf(pending), listOf(optimistic), sessionRunning = false, historyComplete = true, zone = zone)
            .filterIsInstance<TranscriptItem.User>()
        val byKey = rows.associateBy { it.key }
        assertEquals("s1", byKey.getValue("e:e1").attachments.single().full?.cacheKey)
        assertEquals("spec.pdf", byKey.getValue("c:client-2").attachments.single().name)
        val local = byKey.getValue("c:client-3").attachments.single()
        // Its own copies, under the keys the relay's URLs use once the item arrives.
        assertTrue(local.full!!.url.startsWith("file:"))
        assertEquals("s4", local.full.cacheKey)
        assertEquals("t4", local.preview?.cacheKey)
    }
}
