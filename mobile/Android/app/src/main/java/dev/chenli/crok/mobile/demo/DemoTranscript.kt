package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.TranscriptChunk

/** What `sessions:transcript` answers at most: items, and characters of text in all. */
private const val MAX_ITEMS = 200
private const val MAX_TEXT = 400_000

/** A tool call without a title is named by the start of its detail, at most this long. */
private const val TOOL_TITLE_MAX = 200

/**
 * `sessions:transcript` as the relay answers it (relay/convex/sessions.ts): the newest [limit] items with
 * `afterSeq < seq <= throughSeq`, newest first, at most about 400 000 characters of text; thoughts and tool calls without
 * their text (a tool without a title named by its detail's first line); `more` when the range holds older ones.
 */
internal fun transcriptChunk(events: List<RelayEvent>, afterSeq: Long? = null, throughSeq: Long? = null, limit: Int): TranscriptChunk {
    val count = limit.coerceIn(1, MAX_ITEMS)
    val inRange = events
        .filter { (afterSeq == null || it.seq > afterSeq) && (throughSeq == null || it.seq <= throughSeq) }
        .sortedByDescending { it.seq }
    val picked = ArrayList<RelayEvent>()
    var text = 0
    for (event in inRange.take(count)) {
        val slim = slimEvent(event)
        if (picked.isNotEmpty() && text + slim.text.length > MAX_TEXT) break
        text += slim.text.length
        picked += slim
    }
    return TranscriptChunk(picked, more = inRange.size > picked.size)
}

private fun slimEvent(event: RelayEvent): RelayEvent = when (event.kind) {
    EventKind.THOUGHT -> event.copy(text = "")
    EventKind.TOOL -> event.copy(
        text = "",
        title = event.title?.takeIf { it.isNotEmpty() }
            ?: event.text.trim().lineSequence().firstOrNull()?.take(TOOL_TITLE_MAX)?.ifEmpty { null },
    )
    else -> event
}
