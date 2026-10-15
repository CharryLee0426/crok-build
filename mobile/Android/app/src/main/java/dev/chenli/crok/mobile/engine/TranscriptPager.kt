package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.EventPage
import dev.chenli.crok.mobile.data.RelayEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The loaded part of a transcript, newest first. */
data class TranscriptState(
    val events: List<RelayEvent> = emptyList(),
    /** The newest page has arrived at least once. */
    val loaded: Boolean = false,
    /** The oldest event is loaded (`isDone`). */
    val historyComplete: Boolean = false,
    val loadingMore: Boolean = false,
    val error: Throwable? = null,
)

/**
 * Bottom-anchored windowed history over `sessions:events` (Telegram's ChatHistoryListNode / ChatActivity): page 0 is
 * a live query for the newest [pageSize] events; [loadMore] adds the next older page. Before adding one, the page above
 * it is pinned with `endCursor` so its lower bound stops moving as new events arrive at the top — otherwise events
 * would slip into a gap between pages (what Convex's own paginated hook does).
 */
class TranscriptPager(
    private val engine: CrokEngine,
    private val sessionDocId: String,
    private val scope: CoroutineScope,
    private val pageSize: Int = PAGE_SIZE,
) {
    private class Page(val cursor: String?) {
        var endCursor: String? = null
        var result: EventPage? = null
        var job: Job? = null
        var error: Throwable? = null
    }

    private val pages = ArrayList<Page>()
    private val _state = MutableStateFlow(TranscriptState())
    val state: StateFlow<TranscriptState> = _state.asStateFlow()

    fun start() {
        if (pages.isEmpty()) addPage(null)
    }

    /** Loads the next older page, if the newest loaded page has answered and history goes further back. */
    fun loadMore() {
        val last = pages.lastOrNull() ?: return
        val result = last.result ?: return
        if (result.isDone || result.continueCursor.isEmpty()) return
        if (last.endCursor == null) pin(last, result.continueCursor)
        addPage(result.continueCursor)
        publish()
    }

    /** After an error: drop everything and start again from the newest page. */
    fun reload() {
        pages.forEach { it.job?.cancel() }
        pages.clear()
        _state.value = TranscriptState()
        addPage(null)
    }

    fun close() {
        pages.forEach { it.job?.cancel() }
        pages.clear()
    }

    private fun args(page: Page): Map<String, Any?> {
        val options = HashMap<String, Any?>()
        options["numItems"] = pageSize.toDouble()
        options["cursor"] = page.cursor
        page.endCursor?.let { options["endCursor"] = it }
        return mapOf("sessionDocId" to sessionDocId, "paginationOpts" to options)
    }

    private fun addPage(cursor: String?) {
        val page = Page(cursor)
        pages += page
        page.job = subscribe(page, previous = null)
    }

    private fun pin(page: Page, endCursor: String) {
        page.endCursor = endCursor
        page.job = subscribe(page, previous = page.job)
    }

    /** Subscribes [page]; a [previous] subscription keeps delivering until the new one has answered. */
    private fun subscribe(page: Page, previous: Job?): Job = scope.launch {
        var replaced = previous == null
        engine.live("sessions:events", args(page), EventPage.serializer()).collect { result ->
            if (!replaced) {
                previous?.cancel()
                replaced = true
            }
            result.onSuccess {
                page.result = it
                page.error = null
            }.onFailure { page.error = it }
            publish()
        }
    }

    private fun publish() {
        val seen = HashSet<String>()
        val merged = ArrayList<RelayEvent>()
        for (page in pages) {
            for (event in page.result?.page.orEmpty()) {
                if (seen.add(event.id)) merged += event
            }
        }
        merged.sortByDescending { it.seq }
        val last = pages.lastOrNull()
        _state.value = TranscriptState(
            events = merged,
            loaded = pages.firstOrNull()?.result != null,
            historyComplete = last?.result?.isDone == true,
            loadingMore = pages.size > 1 && last?.result == null,
            error = pages.firstNotNullOfOrNull { it.error },
        )
    }

    companion object {
        const val PAGE_SIZE = 50
    }
}
