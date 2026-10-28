package dev.chenli.crok.mobile.data

import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.AttachmentRules
import dev.chenli.crok.mobile.logic.DraftAttachment
import dev.chenli.crok.mobile.logic.OutgoingAttachment
import dev.chenli.crok.mobile.logic.UploadState
import java.io.File
import java.time.LocalDateTime
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Uploads one prepared file to the relay (`files:uploadUrl`, then `POST`); the answer is its storage id. */
fun interface AttachmentUploader {
    suspend fun upload(file: File, mimeType: String, onProgress: (Float) -> Unit): String
}

/** Why the composer did not take everything picked. */
enum class AttachNotice { TooMany, TooBig }

/**
 * The composer's photos and files per draft (a session, or a new-session screen), for as long as the app runs
 * (relay/DESIGN.md §5 "The attachment strip"): each one is prepared and uploaded as soon as it was attached, on
 * [scope], so leaving the session keeps the strip and its uploads going. [keep] copies what was uploaded into the
 * phone's file cache under its storage id.
 */
class AttachmentDrafts(
    private val scope: CoroutineScope,
    private val prepare: suspend (AttachmentPick, Int, LocalDateTime) -> PrepOutcome,
    private val keep: (String, File) -> Unit = { _, _ -> },
    private val clock: () -> LocalDateTime = LocalDateTime::now,
) {
    private val drafts = MutableStateFlow<Map<String, List<DraftAttachment>>>(emptyMap())
    private val jobs = ConcurrentHashMap<String, Job>()

    /** Each attachment's pick, for a retry of one that could not be prepared. */
    private val picks = ConcurrentHashMap<String, Triple<AttachmentPick, Int, LocalDateTime>>()
    private val _notices = MutableSharedFlow<Pair<String, AttachNotice>>(extraBufferCapacity = 8)

    /** By draft key: picks that were not added. */
    val notices: SharedFlow<Pair<String, AttachNotice>> = _notices.asSharedFlow()

    fun draft(key: String): Flow<List<DraftAttachment>> = drafts.map { it[key].orEmpty() }.distinctUntilChanged()

    fun current(key: String): List<DraftAttachment> = drafts.value[key].orEmpty()

    /** Adds [picked] (as many as fit next to what is there) and starts preparing and uploading each. */
    fun add(key: String, picked: List<AttachmentPick>, uploader: AttachmentUploader) {
        if (picked.isEmpty()) return
        val room = AttachmentRules.room(current(key).size, picked.size)
        if (room < picked.size) _notices.tryEmit(key to AttachNotice.TooMany)
        val at = clock()
        picked.take(room).forEachIndexed { index, pick ->
            val id = UUID.randomUUID().toString()
            val kind = if (pick.fromPhotos) AttachmentKind.Image else AttachmentKind.File
            change(key) { it + DraftAttachment(id = id, kind = kind, name = "") }
            picks[id] = Triple(pick, index, at)
            start(key, id) { prepareAndUpload(key, id, uploader) }
        }
    }

    fun remove(key: String, id: String) {
        jobs.remove(id)?.cancel()
        picks.remove(id)
        change(key) { list -> list.filterNot { it.id == id } }
    }

    /** A failed one again: its upload, or its preparation when that failed. */
    fun retry(key: String, id: String, uploader: AttachmentUploader) {
        val item = current(key).firstOrNull { it.id == id } ?: return
        if (item.state !is UploadState.Failed) return
        if (item.file == null) {
            set(key, id) { it.copy(state = UploadState.Preparing) }
            start(key, id) { prepareAndUpload(key, id, uploader) }
        } else {
            set(key, id) { it.copy(state = UploadState.Uploading(0f)) }
            start(key, id) { upload(key, id, uploader) }
        }
    }

    /** What goes with the prompt now (every attachment uploaded); the strip is empty afterwards. */
    fun take(key: String): List<OutgoingAttachment> {
        val list = current(key)
        if (list.isEmpty() || list.any { !it.ready }) return emptyList()
        change(key) { emptyList() }
        list.forEach { picks.remove(it.id) }
        return list.mapNotNull { it.outgoing() }
    }

    /** Signing out: everything goes. */
    fun clear() {
        jobs.values.forEach { it.cancel() }
        jobs.clear()
        picks.clear()
        drafts.value = emptyMap()
    }

    private fun start(key: String, id: String, block: suspend () -> Unit) {
        jobs.remove(id)?.cancel()
        jobs[id] = scope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                set(key, id) { it.copy(state = UploadState.Failed(e.message)) }
            } finally {
                jobs.remove(id)
            }
        }
    }

    private suspend fun prepareAndUpload(key: String, id: String, uploader: AttachmentUploader) {
        val (pick, index, at) = picks[id] ?: return
        when (val outcome = prepare(pick, index, at)) {
            PrepOutcome.TooBig -> {
                picks.remove(id)
                change(key) { list -> list.filterNot { it.id == id } }
                _notices.tryEmit(key to AttachNotice.TooBig)
            }
            is PrepOutcome.Failed -> set(key, id) { it.copy(state = UploadState.Failed(outcome.message)) }
            is PrepOutcome.Prepared -> {
                set(key, id) {
                    it.copy(
                        kind = outcome.kind,
                        name = outcome.name,
                        mimeType = outcome.mimeType,
                        size = outcome.size,
                        width = outcome.width,
                        height = outcome.height,
                        file = outcome.file.path,
                        thumbFile = outcome.thumbFile?.path,
                        state = UploadState.Uploading(0f),
                    )
                }
                upload(key, id, uploader)
            }
        }
    }

    private suspend fun upload(key: String, id: String, uploader: AttachmentUploader) {
        val item = current(key).firstOrNull { it.id == id } ?: return
        val file = File(item.file ?: return)
        // The file is most of the bytes; its thumbnail goes after it, and the image goes without one if that fails.
        val storageId = uploader.upload(file, item.mimeType) { progress ->
            set(key, id) { it.copy(state = UploadState.Uploading(progress * 0.95f)) }
        }
        keep(storageId, file)
        val thumbId = item.thumbFile?.let { path ->
            try {
                uploader.upload(File(path), "image/jpeg") {}.also { keep(it, File(path)) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
        }
        set(key, id) { it.copy(storageId = storageId, thumbId = thumbId, state = UploadState.Ready) }
    }

    private fun change(key: String, transform: (List<DraftAttachment>) -> List<DraftAttachment>) {
        drafts.update { all ->
            val next = transform(all[key].orEmpty())
            if (next.isEmpty()) all - key else all + (key to next)
        }
    }

    private fun set(key: String, id: String, transform: (DraftAttachment) -> DraftAttachment) {
        change(key) { list -> list.map { if (it.id == id) transform(it) else it } }
    }
}
