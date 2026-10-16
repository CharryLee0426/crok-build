package dev.chenli.crok.mobile.logic

import kotlin.math.max
import kotlin.math.min

/**
 * Smooths streamed assistant text (iOS Telegram's TextRevealController idea): the relay delivers text in chunks about
 * every 0.75 s; instead of jumping, the screen reveals each chunk over roughly the time until the next one is expected.
 * When the turn ends the rest is revealed within [FINISH_MS].
 *
 * Pure and clock-driven: the composable calls [onText] when the text grows and [advance] every frame.
 */
class RevealPacer(initialLength: Int, now: Long) {
    private var shown: Double = initialLength.toDouble()
    private var target: Int = initialLength
    private var lastChunkAt: Long = now
    private var lastAdvanceAt: Long = now
    private var intervalMs: Double = DEFAULT_INTERVAL_MS
    private var ratePerMs: Double = 0.0
    private var finishDeadline: Long? = null

    val revealed: Int get() = min(target, shown.toInt())
    val caughtUp: Boolean get() = shown >= target

    /** The full text is now [length] characters long. */
    fun onText(length: Int, now: Long) {
        if (length < revealed) {
            // Replaced, not appended: show it as is.
            shown = length.toDouble()
            target = length
            ratePerMs = 0.0
            return
        }
        if (length == target) return
        val gap = now - lastChunkAt
        if (gap in MIN_GAP_MS..MAX_GAP_MS) intervalMs = intervalMs * 0.6 + gap * 0.4
        lastChunkAt = now
        target = length
        ratePerMs = max(ratePerMs, (target - shown) / intervalMs.coerceIn(MIN_INTERVAL_MS, MAX_INTERVAL_MS))
    }

    /** Moves the reveal forward to [now]; returns how many characters to show. */
    fun advance(now: Long, streaming: Boolean): Int {
        val dt = (now - lastAdvanceAt).coerceIn(0, 250)
        lastAdvanceAt = now
        if (shown >= target) {
            ratePerMs = 0.0
            return target
        }
        if (!streaming) {
            val deadline = finishDeadline ?: (now + FINISH_MS).also { finishDeadline = it }
            val left = deadline - now
            if (left <= 0) {
                shown = target.toDouble()
                return target
            }
            ratePerMs = max(ratePerMs, (target - shown) / left)
        } else {
            finishDeadline = null
            // Never fall more than two intervals behind, whatever the chunk rate was.
            val backlog = target - shown
            ratePerMs = max(ratePerMs, backlog / (2 * intervalMs))
        }
        shown = min(target.toDouble(), shown + max(ratePerMs * dt, if (dt > 0) 1.0 else 0.0))
        return revealed
    }

    companion object {
        const val FINISH_MS = 300L
        const val DEFAULT_INTERVAL_MS = 750.0
        const val MIN_INTERVAL_MS = 120.0
        const val MAX_INTERVAL_MS = 1500.0
        const val MIN_GAP_MS = 30L
        const val MAX_GAP_MS = 5000L
    }
}
