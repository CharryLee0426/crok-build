package dev.chenli.crok.mobile.data

import android.net.Uri
import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.UploadState
import java.io.File
import java.time.LocalDateTime
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The composer's strip: prepare, upload, limits, failures and retries (relay/DESIGN.md §5 "The attachment strip"). */
@RunWith(RobolectricTestRunner::class)
class AttachmentDraftsTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val dir = File(System.getProperty("java.io.tmpdir"), "drafts-test-${System.nanoTime()}").apply { mkdirs() }
    private val uploads = CopyOnWriteArrayList<Pair<String, String>>()
    private val kept = CopyOnWriteArrayList<String>()

    @After
    fun tearDown() {
        scope.cancel()
        dir.deleteRecursively()
    }

    private fun prepared(name: String, image: Boolean): PrepOutcome.Prepared {
        val file = File(dir, name).apply { writeText("bytes of $name") }
        val thumb = if (image) File(dir, "$name.thumb").apply { writeText("thumb") } else null
        return PrepOutcome.Prepared(
            if (image) AttachmentKind.Image else AttachmentKind.File, name, if (image) "image/jpeg" else "application/pdf",
            file.length(), if (image) 2048 else null, if (image) 1536 else null, file, thumb,
        )
    }

    private fun store(prepare: suspend (AttachmentPick, Int, LocalDateTime) -> PrepOutcome) =
        AttachmentDrafts(scope, prepare, keep = { id, _ -> kept += id }, clock = { LocalDateTime.of(2026, 10, 27, 12, 0) })

    private val uploader = AttachmentUploader { file, mime, progress ->
        progress(0.5f)
        uploads += file.name to mime
        "storage-${file.name}"
    }

    private fun pick(name: String, photos: Boolean = false) = AttachmentPick(Uri.parse("content://test/$name"), photos)

    private fun AttachmentDrafts.await(key: String, predicate: (List<dev.chenli.crok.mobile.logic.DraftAttachment>) -> Boolean) =
        runBlocking { withTimeout(5_000) { draft(key).first(predicate) } }

    @Test
    fun anAttachmentIsPreparedAndUploadedWithItsThumbnail() {
        val drafts = store { pick, _, _ -> prepared(pick.uri.lastPathSegment!!, image = pick.fromPhotos) }
        drafts.add("s1", listOf(pick("a.jpg", photos = true), pick("spec.pdf")), uploader)
        val ready = drafts.await("s1") { list -> list.size == 2 && list.all { it.ready } }
        assertEquals(listOf("a.jpg", "spec.pdf"), ready.map { it.name })
        assertEquals("storage-a.jpg", ready[0].storageId)
        assertEquals("storage-a.jpg.thumb", ready[0].thumbId)
        assertNull(ready[1].thumbId)
        assertTrue(uploads.contains("a.jpg.thumb" to "image/jpeg"))
        // What was uploaded is in the phone's cache under its storage id, so the sent bubble needs no download.
        assertTrue(kept.containsAll(listOf("storage-a.jpg", "storage-a.jpg.thumb", "storage-spec.pdf")))
        val outgoing = drafts.take("s1")
        assertEquals(listOf("storage-a.jpg", "storage-spec.pdf"), outgoing.map { it.storageId })
        assertTrue(drafts.current("s1").isEmpty())
    }

    @Test
    fun draftsAreKeptApart() {
        val drafts = store { pick, _, _ -> prepared(pick.uri.lastPathSegment!!, image = false) }
        drafts.add("s1", listOf(pick("one.pdf")), uploader)
        drafts.add("s2", listOf(pick("two.pdf")), uploader)
        drafts.await("s1") { it.singleOrNull()?.ready == true }
        assertEquals("two.pdf", drafts.await("s2") { it.singleOrNull()?.ready == true }.single().name)
    }

    @Test
    fun moreThanTenAreNotAddedAndSaySo() {
        val drafts = store { pick, _, _ -> prepared(pick.uri.lastPathSegment!!, image = false) }
        val notice = scope.async(start = CoroutineStart.UNDISPATCHED) { drafts.notices.first() }
        drafts.add("s1", (1..12).map { pick("$it.pdf") }, uploader)
        assertEquals("s1" to AttachNotice.TooMany, runBlocking { withTimeout(5_000) { notice.await() } })
        assertEquals(10, drafts.await("s1") { list -> list.size == 10 && list.all { it.ready } }.size)
    }

    @Test
    fun aFileOverTheLimitIsDroppedWithANotice() {
        val drafts = store { pick, _, _ -> if (pick.uri.lastPathSegment == "huge.zip") PrepOutcome.TooBig else prepared("ok.pdf", image = false) }
        val notice = scope.async(start = CoroutineStart.UNDISPATCHED) { drafts.notices.first() }
        drafts.add("s1", listOf(pick("huge.zip"), pick("ok.pdf")), uploader)
        assertEquals(AttachNotice.TooBig, runBlocking { withTimeout(5_000) { notice.await() } }.second)
        assertEquals("ok.pdf", drafts.await("s1") { it.size == 1 && it.single().ready }.single().name)
    }

    @Test
    fun aFailedUploadRetriesOnTap() {
        val drafts = store { pick, _, _ -> prepared(pick.uri.lastPathSegment!!, image = false) }
        var fail = true
        val flaky = AttachmentUploader { file, mime, progress -> if (fail) error("offline") else uploader.upload(file, mime, progress) }
        drafts.add("s1", listOf(pick("spec.pdf")), flaky)
        val failed = drafts.await("s1") { it.singleOrNull()?.state is UploadState.Failed }.single()
        assertEquals("offline", (failed.state as UploadState.Failed).message)
        assertTrue(drafts.take("s1").isEmpty())
        fail = false
        drafts.retry("s1", failed.id, flaky)
        assertEquals("storage-spec.pdf", drafts.await("s1") { it.singleOrNull()?.ready == true }.single().storageId)
    }

    @Test
    fun anImageWhoseThumbnailFailsGoesWithoutOne() {
        val drafts = store { _, _, _ -> prepared("a.jpg", image = true) }
        val noThumbs = AttachmentUploader { file, mime, progress ->
            if (file.name.endsWith(".thumb")) error("no") else uploader.upload(file, mime, progress)
        }
        drafts.add("s1", listOf(pick("a.jpg", photos = true)), noThumbs)
        val ready = drafts.await("s1") { it.singleOrNull()?.ready == true }.single()
        assertNull(ready.thumbId)
    }

    @Test
    fun removingOneStopsItsUpload() {
        val gate = CompletableDeferred<Unit>()
        val drafts = store { _, _, _ -> prepared("slow.pdf", image = false) }
        val slow = AttachmentUploader { file, mime, progress ->
            gate.await()
            uploader.upload(file, mime, progress)
        }
        drafts.add("s1", listOf(pick("slow.pdf")), slow)
        val item = drafts.await("s1") { it.singleOrNull()?.state is UploadState.Uploading }.single()
        drafts.remove("s1", item.id)
        gate.complete(Unit)
        Thread.sleep(200)
        assertTrue(drafts.current("s1").isEmpty())
        assertTrue(uploads.toString(), uploads.isEmpty())
    }
}
