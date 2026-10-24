package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.TranscriptChunk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The loaded part of a transcript, newest first. */
data class TranscriptState(
    val events: List<RelayEvent> = emptyList(),
    /** The newest items have arrived at least once. */
    val loaded: Boolean = false,
    /** The oldest item is loaded (nothing older on the relay). */
    val historyComplete: Boolean = false,
    val loadingMore: Boolean = false,
    val error: Throwable? = null,
)

/**
 * Which items a part of the transcript holds (`sessions:transcript`): those with `afterSeq < seq <= throughSeq` (either
 * bound optional), the newest [limit] of them.
 */
data class TranscriptRange(val afterSeq: Long? = null, val throughSeq: Long? = null, val limit: Int)

/**
 * The loaded part of a session's transcript as a window of live parts over `sessions:transcript` (relay/DESIGN.md §3,
 * "Loading long transcripts"; the iOS app's TranscriptWindow does the same): it opens on the newest items, keeps a live
 * end that grows as items arrive and splits before it gets long, and loads older parts on demand. The relay re-sends a
 * part whenever an item in it changes, so a streamed reply costs only the live end, however long the session is.
 */
class TranscriptWindow(
    private val source: (TranscriptRange) -> Flow<Result<TranscriptChunk>>,
    private val scope: CoroutineScope,
    /** Items the window opens on (and that stay live when the live end splits). */
    private val openLimit: Int = OPEN_LIMIT,
    /** Items one older part asks for. */
    private val olderLimit: Int = OLDER_LIMIT,
) {
    enum class Role {
        /** The newest items, until the first answer fixes where the live end starts (or, while empty, the live end). */
        Opening,

        /** Everything from a seq on, growing as items arrive. */
        Live,

        /** A range split off the live end. */
        Fixed,

        /** A range below everything loaded, asked for on reaching the top. */
        Older,
    }

    /** One live query. Compared by identity. */
    class Part(val range: TranscriptRange, val role: Role) {
        var chunk: TranscriptChunk? = null
        var error: Throwable? = null

        /** It has answered with items before (an empty answer then means the transcript was replaced). */
        var hadEvents = false
        var job: Job? = null
    }

    private val lock = Any()

    /** Newest first: the live end (or the opening part), parts split off it, then older parts. */
    private val parts = ArrayList<Part>()

    /** Parts still shown until all of [replacing] have answered (a split, the opening's hand-over, a restart). */
    private val retiring = ArrayList<Part>()
    private val replacing = ArrayList<Part>()

    /** New parts to subscribe once the current change is done. */
    private val toStart = ArrayList<Part>()
    private var hasOlder = false
    private var loaded = false

    /** [loadMore] was asked while it could not start; it starts once the parts settle. */
    private var wantsOlder = false

    /** Times the window started over (tests). */
    var restarts = 0
        private set

    private val _state = MutableStateFlow(TranscriptState())
    val state: StateFlow<TranscriptState> = _state.asStateFlow()

    /** The ranges subscribed now, newest first (tests). */
    val ranges: List<TranscriptRange> get() = synchronized(lock) { parts.map { it.range } }

    fun start() {
        synchronized(lock) {
            if (parts.isNotEmpty()) return
            parts += newPart(TranscriptRange(limit = openLimit), Role.Opening)
            startPending()
        }
    }

    /** Asks for the next older part (the top came into view); asked during a hand-over, it happens once parts settle. */
    fun loadMore() {
        synchronized(lock) {
            if (!loadOlderLocked()) return
            publish()
            startPending()
        }
    }

    /** After an error: drop everything and start again from the newest items. */
    fun reload(): Unit = synchronized(lock) {
        (parts + retiring).forEach { it.job?.cancel() }
        parts.clear()
        retiring.clear()
        replacing.clear()
        toStart.clear()
        hasOlder = false
        loaded = false
        wantsOlder = false
        _state.value = TranscriptState()
        parts += newPart(TranscriptRange(limit = openLimit), Role.Opening)
        startPending()
    }

    fun close(): Unit = synchronized(lock) {
        (parts + retiring).forEach { it.job?.cancel() }
        parts.clear()
        retiring.clear()
        replacing.clear()
        toStart.clear()
    }

    private val loadingOlder: Boolean get() = parts.lastOrNull()?.let { it.role == Role.Older && it.chunk == null } == true

    private fun loadOlderLocked(): Boolean {
        if (!hasOlder || loadingOlder) return false
        val oldest = parts.lastOrNull()?.chunk?.events?.minOfOrNull { it.seq }
        if (replacing.isNotEmpty() || oldest == null) {
            wantsOlder = true
            return false
        }
        wantsOlder = false
        parts += newPart(TranscriptRange(throughSeq = oldest - 1, limit = olderLimit), Role.Older)
        return true
    }

    private fun newPart(range: TranscriptRange, role: Role): Part = Part(range, role).also { toStart += it }

    private fun startPending() {
        while (toStart.isNotEmpty()) {
            val part = toStart.removeAt(0)
            if (part.job != null || parts.none { it === part }) continue
            part.job = scope.launch { source(part.range).collect { result -> synchronized(lock) { answered(part, result) } } }
        }
    }

    private fun answered(part: Part, result: Result<TranscriptChunk>) {
        result.onFailure { part.error = it }
        val chunk = result.getOrNull()
        if (chunk != null) {
            part.error = null
            part.chunk = chunk
        }
        if (chunk != null && parts.any { it === part }) handle(part, chunk)
        if (wantsOlder) loadOlderLocked()
        publish()
        startPending()
    }

    private fun handle(part: Part, chunk: TranscriptChunk) {
        val hadEvents = part.hadEvents
        if (chunk.events.isNotEmpty()) part.hadEvents = true
        loaded = true
        settleReplacement()
        when (part.role) {
            Role.Opening -> {
                hasOlder = chunk.more
                val lowest = chunk.events.minOfOrNull { it.seq } ?: return
                // The live end starts at the oldest item shown; the opening part shows until it answers.
                replace(listOf(part), listOf(newPart(TranscriptRange(afterSeq = lowest - 1, limit = PART_LIMIT), Role.Live)))
            }
            // More arrived than it holds (the phone slept through a busy turn): start again from the newest.
            Role.Live -> if (chunk.more) restart() else splitIfLong(part)
            Role.Fixed, Role.Older -> when {
                // The computer replaced the transcript (a resync): its old items are gone.
                hadEvents && chunk.events.isEmpty() -> restart()
                part === parts.last() -> hasOlder = chunk.more
            }
        }
    }

    /** Once every part of a replacement has answered, the parts it replaces go. */
    private fun settleReplacement() {
        if (replacing.isEmpty() || replacing.any { it.chunk == null }) return
        retiring.forEach { it.job?.cancel() }
        retiring.clear()
        replacing.clear()
    }

    /** Swaps [old] (adjacent parts) for [new] in place; [old] keeps showing until all of [new] have answered. */
    private fun replace(old: List<Part>, new: List<Part>) {
        val index = parts.indexOfFirst { it === old.first() }
        if (index < 0) return
        repeat(old.size) { parts.removeAt(index) }
        parts.addAll(index, new)
        retiring += old
        replacing += new
    }

    /**
     * The live end holds too much to re-send on every change: its newest [openLimit] items (or half its text) stay live,
     * the rest becomes a fixed part.
     */
    private fun splitIfLong(live: Part) {
        if (replacing.isNotEmpty()) return
        val events = live.chunk?.events?.sortedByDescending { it.seq } ?: return
        if (events.size < 2) return
        val text = events.sumOf { it.text.length }
        var keep = when {
            events.size > 2 * openLimit -> openLimit
            text > SPLIT_TEXT -> {
                var count = 0
                var kept = 0
                while (count < events.size - 1 && kept < text / 2) {
                    kept += events[count].text.length
                    count++
                }
                count
            }
            else -> return
        }
        keep = keep.coerceIn(1, events.size - 1)
        val start = events[keep - 1].seq
        replace(
            listOf(live),
            listOf(
                newPart(TranscriptRange(afterSeq = start - 1, limit = PART_LIMIT), Role.Live),
                newPart(TranscriptRange(afterSeq = live.range.afterSeq, throughSeq = start - 1, limit = PART_LIMIT), Role.Fixed),
            ),
        )
    }

    /** Starts again from the newest items; everything loaded shows until they arrive. */
    private fun restart() {
        restarts++
        retiring += parts
        parts.clear()
        replacing.clear()
        val opening = newPart(TranscriptRange(limit = openLimit), Role.Opening)
        parts += opening
        replacing += opening
    }

    private fun publish() {
        val merged = LinkedHashMap<String, RelayEvent>()
        // The retiring parts first, so the parts replacing them win.
        for (part in retiring + parts.asReversed()) {
            for (event in part.chunk?.events.orEmpty()) merged[event.id] = event
        }
        _state.value = TranscriptState(
            events = merged.values.sortedByDescending { it.seq },
            loaded = loaded,
            historyComplete = loaded && !hasOlder,
            loadingMore = loadingOlder,
            error = (parts + retiring).firstNotNullOfOrNull { it.error },
        )
    }

    companion object {
        const val OPEN_LIMIT = 40
        const val OLDER_LIMIT = 60

        /** What one live or fixed part holds at most (the relay's own limit). */
        const val PART_LIMIT = 200

        /** The live end splits beyond `2 × OPEN_LIMIT` items or this many characters of text. */
        const val SPLIT_TEXT = 200_000

        /** The arguments of `sessions:transcript` for [range]. */
        fun args(sessionDocId: String, range: TranscriptRange): Map<String, Any?> = buildMap {
            put("sessionDocId", sessionDocId)
            put("limit", range.limit.toDouble())
            range.afterSeq?.let { put("afterSeq", it.toDouble()) }
            range.throughSeq?.let { put("throughSeq", it.toDouble()) }
        }
    }
}
