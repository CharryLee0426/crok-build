package dev.chenli.crok.mobile.ui.session

import android.net.Uri
import dev.chenli.crok.mobile.data.AttachmentDrafts
import dev.chenli.crok.mobile.data.AttachmentPick
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.data.PrepOutcome
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoTransport
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.RelayTransport
import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.TranscriptItem
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import androidx.lifecycle.viewModelScope
import kotlinx.serialization.json.JsonElement
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Photos and files from the composer to the relay (relay/DESIGN.md §5 "Sending"), against the demo relay. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class SessionAttachmentsTest {
    private val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val demo = DemoTransport(scope, animate = false)
    private val calls = CopyOnWriteArrayList<Pair<String, Map<String, Any?>>>()
    private val transport = object : RelayTransport by demo {
        override suspend fun mutation(name: String, args: Map<String, Any?>): JsonElement {
            calls += name to args
            return demo.mutation(name, args)
        }
    }
    private val engine = CrokEngine(DemoData.credentials, true, transport, MutableStateFlow(true), null, Dispatchers.Default)
    private val drafts = DraftStore(MemoryKeyValueStore())
    private val dir = File(System.getProperty("java.io.tmpdir"), "session-attachments-${System.nanoTime()}").apply { mkdirs() }

    /** Prepares a pick as the phone would: a photo (from Photos) or a PDF, written to a temporary file. */
    private val attachments = AttachmentDrafts(scope, { pick: AttachmentPick, _: Int, _: java.time.LocalDateTime ->
        val name = pick.uri.lastPathSegment!!
        val file = File(dir, name).apply { writeText("bytes of $name") }
        PrepOutcome.Prepared(
            if (pick.fromPhotos) AttachmentKind.Image else AttachmentKind.File, name,
            if (pick.fromPhotos) "image/jpeg" else "application/pdf", file.length(),
            if (pick.fromPhotos) 2048 else null, if (pick.fromPhotos) 1536 else null, file, null,
        )
    })

    @Before
    fun setUp() {
        Dispatchers.setMain(main)
        engine.start()
    }

    @After
    fun tearDown() {
        // The view models' own coroutines stop here, before the main dispatcher goes back.
        runBlocking(main) { models.forEach { it.viewModelScope.cancel() } }
        engine.close()
        scope.cancel()
        Dispatchers.resetMain()
        main.close()
        dir.deleteRecursively()
    }

    private fun <T> onMain(block: suspend CoroutineScope.() -> T): T = runBlocking { withTimeout(10_000) { withContext(main, block) } }

    private val models = CopyOnWriteArrayList<SessionViewModel>()

    private fun SessionViewModel.collectState(): SessionViewModel = also { vm ->
        models += vm
        scope.launch(main) { vm.state.collect { } }
    }

    private fun pick(name: String, photo: Boolean) = AttachmentPick(Uri.parse("content://test/$name"), photo)

    /** The latest `commands:sendPrompt`'s arguments, once [count] have gone out. */
    private suspend fun sent(count: Int = 1): Map<String, Any?> {
        while (calls.count { it.first == "commands:sendPrompt" } < count) kotlinx.coroutines.delay(20)
        return calls.last { it.first == "commands:sendPrompt" }.second
    }

    @Test
    fun photosAndFilesGoWithThePromptOnceUploaded() = onMain {
        val vm = SessionViewModel(engine, DemoData.SHOWCASE_SESSION, drafts, attachments = attachments).collectState()
        vm.attach(listOf(pick("a.jpg", photo = true), pick("spec.pdf", photo = false)))
        val uploading = vm.state.first { it.attachments.size == 2 }
        assertTrue(uploading.canAttach)
        // Send waits for the uploads.
        vm.updateDraft("What do you see?")
        if (!uploading.attachments.all { it.ready }) {
            assertFalse(uploading.canSubmit(vm.draft))
            vm.send()
            assertTrue(calls.none { it.first == "commands:sendPrompt" })
        }
        val ready = vm.state.first { state -> state.attachments.size == 2 && state.attachments.all { it.ready } }
        assertTrue(ready.canSubmit(vm.draft))
        vm.send()
        val args = sent()
        assertEquals("What do you see?", args["text"])
        @Suppress("UNCHECKED_CAST")
        val sentAttachments = args["attachments"] as List<Map<String, Any?>>
        assertEquals(listOf("a.jpg", "spec.pdf"), sentAttachments.map { it["name"] })
        assertTrue(sentAttachments.all { (it["storageId"] as String).startsWith("demo-blob-") })
        assertEquals(2048.0, sentAttachments[0]["width"])
        assertFalse(sentAttachments[1].containsKey("width"))
        // The strip is empty; the bubble shows them at once, from the phone's own copies.
        val after = vm.state.first { state -> state.attachments.isEmpty() && state.items.any { it is TranscriptItem.User && it.attachments.size == 2 } }
        val bubble = after.items.filterIsInstance<TranscriptItem.User>().first { it.attachments.size == 2 }
        assertTrue(bubble.attachments[0].full!!.url.startsWith("file:"))
    }

    @Test
    fun aPhotoAloneIsAPromptAndSlashTextGoesAsIs() = onMain {
        val vm = SessionViewModel(engine, DemoData.SHOWCASE_SESSION, drafts, attachments = attachments).collectState()
        vm.attach(listOf(pick("b.jpg", photo = true)))
        vm.state.first { state -> state.attachments.singleOrNull()?.ready == true }
        vm.send()
        assertEquals("", sent(1)["text"])
        vm.attach(listOf(pick("c.jpg", photo = true)))
        vm.state.first { state -> state.attachments.singleOrNull()?.ready == true }
        // With an attachment, `/model` is not the phone's command: it goes to the computer as it is.
        vm.updateDraft("/model")
        vm.send()
        assertEquals("/model", sent(2)["text"])
        assertEquals(1, (sent(2)["attachments"] as List<*>).size)
    }

    @Test
    fun aPlainPromptSendsNoAttachmentsKey() = onMain {
        val vm = SessionViewModel(engine, DemoData.SHOWCASE_SESSION, drafts, attachments = attachments).collectState()
        vm.updateDraft("Just text")
        vm.send()
        vm.state.first { state -> state.items.any { it is TranscriptItem.User && it.text == "Just text" } }
        assertFalse(sent().containsKey("attachments"))
    }

    @Test
    fun aNewSessionStartsWithItsAttachments() = onMain {
        val target = NewSessionTarget(DemoData.MACBOOK_ID, "/Users/chen/code/crok-site", "MacBook Pro", "crok-site")
        val vm = SessionViewModel(engine, null, drafts, newSession = target, attachments = attachments).collectState()
        vm.attach(listOf(pick("mockup.jpg", photo = true)))
        vm.state.first { state -> state.attachments.singleOrNull()?.ready == true }
        vm.send()
        vm.state.first { it.newSession == null }
        while (calls.none { it.first == "sessions:create" }) kotlinx.coroutines.delay(20)
        val create = calls.last { it.first == "sessions:create" }.second
        assertEquals(1, (create["attachments"] as List<*>).size)
        assertFalse(create.containsKey("text"))
    }
}
