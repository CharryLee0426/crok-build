package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

/** Telegram's message status: clock (not picked up), one check (delivered), two checks (turn done), red "!" (failed). */
enum class Tick { Clock, Sent, Done, Failed }

fun tickFor(status: String?): Tick = when (status) {
    CommandStatus.DELIVERED -> Tick.Sent
    CommandStatus.DONE -> Tick.Done
    CommandStatus.FAILED -> Tick.Failed
    else -> Tick.Clock
}

/** A prompt this phone sent, shown at once (keyed by its client id) until the transcript holds it. */
data class OptimisticPrompt(
    val clientId: String,
    val text: String,
    val createdAt: Long,
    /** From `commands:sendPrompt`, once it answered. */
    val commandId: String? = null,
    /** Set when the send itself failed (offline, rejected) before any command existed. */
    val localError: String? = null,
)

/** Whether a row continues the author's previous row (no gap, flatter corner) and is continued by the next. */
data class Grouping(val withOlder: Boolean = false, val withNewer: Boolean = false)

enum class NoticeKind { Stopped, MaxTokens, Refusal, Error, Info }

sealed interface TranscriptItem {
    val key: String

    data class Day(val date: LocalDate) : TranscriptItem {
        override val key: String get() = "d:$date"
    }

    data class User(
        override val key: String,
        val text: String,
        val at: Long,
        val remote: Boolean,
        val fromLabel: String?,
        val tick: Tick?,
        val error: String?,
        val commandId: String?,
        val clientId: String?,
        /** Not yet in the transcript (optimistic, or queued behind a running turn). */
        val pending: Boolean,
        val grouping: Grouping = Grouping(),
    ) : TranscriptItem

    data class Assistant(
        override val key: String,
        val text: String,
        val at: Long,
        val streaming: Boolean,
        val grouping: Grouping = Grouping(),
    ) : TranscriptItem

    data class Thought(
        override val key: String,
        val text: String,
        val at: Long,
        val grouping: Grouping = Grouping(),
    ) : TranscriptItem

    data class Tool(
        override val key: String,
        val title: String,
        val toolKind: String?,
        val status: String?,
        val text: String,
        val at: Long,
        val grouping: Grouping = Grouping(),
    ) : TranscriptItem

    data class Notice(
        override val key: String,
        val kind: NoticeKind,
        val text: String,
        val at: Long,
    ) : TranscriptItem

    /** The phone's own answer to `/model` or `/think` (not on the relay). */
    data class Bot(
        override val key: String,
        val card: BotCard,
        val at: Long,
    ) : TranscriptItem
}

object Transcript {
    /** Consecutive rows of one author merge when they are this close (Telegram's grouping window). */
    const val GROUP_WINDOW_MS = 10 * 60 * 1000L

    private enum class Author { User, Agent, None }

    private fun authorOf(item: TranscriptItem): Author = when (item) {
        is TranscriptItem.User -> Author.User
        is TranscriptItem.Assistant, is TranscriptItem.Thought, is TranscriptItem.Tool -> Author.Agent
        else -> Author.None
    }

    private fun atOf(item: TranscriptItem): Long = when (item) {
        is TranscriptItem.User -> item.at
        is TranscriptItem.Assistant -> item.at
        is TranscriptItem.Thought -> item.at
        is TranscriptItem.Tool -> item.at
        is TranscriptItem.Notice -> item.at
        is TranscriptItem.Bot -> item.at
        is TranscriptItem.Day -> 0
    }

    /**
     * Builds what the transcript shows, **newest first** (for a reversed LazyColumn): the loaded events, then this
     * phone's prompts that the transcript does not hold yet, with day headers and grouping.
     *
     * @param events any order, possibly with duplicates across pages
     * @param prompts `commands:forSession` — prompts from phones and the web, for ticks and failures
     * @param historyComplete true when the oldest page is loaded (`isDone`)
     * @param cards the phone's bot cards (`/model`, `/think`), placed by when they were made
     */
    fun build(
        events: List<RelayEvent>,
        prompts: List<PromptCommand>,
        optimistic: List<OptimisticPrompt>,
        sessionRunning: Boolean,
        historyComplete: Boolean,
        zone: ZoneId,
        cards: List<BotCard> = emptyList(),
    ): List<TranscriptItem> {
        val ordered = events.distinctBy { it.id }.sortedBy { it.seq }
        val commandsById = prompts.associateBy { it.id }
        val commandsByClient = prompts.filter { it.clientId != null }.associateBy { it.clientId!! }
        val inTranscript = ordered.mapNotNullTo(HashSet()) { it.commandId }
        val oldestLoadedAt = ordered.firstOrNull()?.at

        val lastUserSeq = ordered.lastOrNull { it.kind == EventKind.USER }?.seq ?: Long.MIN_VALUE
        val streamingId = if (sessionRunning) {
            ordered.lastOrNull { it.kind == EventKind.ASSISTANT }?.takeIf { it.seq > lastUserSeq }?.id
        } else {
            null
        }

        val rows = ArrayList<TranscriptItem>(ordered.size + optimistic.size + cards.size)
        // Bot cards go among the events by time: a card made before the computer's next reply stays above it.
        val botRows = cards.sortedBy { it.createdAt }.map { TranscriptItem.Bot("b:${it.id}", it, it.createdAt) }
        var nextCard = 0
        for (event in ordered) {
            val row = rowFor(event, commandsById, streamingId) ?: continue
            while (nextCard < botRows.size && botRows[nextCard].at < atOf(row)) rows += botRows[nextCard++]
            rows += row
        }
        while (nextCard < botRows.size) rows += botRows[nextCard++]

        // Prompts on their way: this phone's optimistic bubbles, and sent prompts the transcript does not hold yet.
        val pending = ArrayList<Pair<Long, TranscriptItem>>()
        val optimisticClients = HashSet<String>()
        for (prompt in optimistic) {
            optimisticClients += prompt.clientId
            val command = prompt.commandId?.let(commandsById::get) ?: commandsByClient[prompt.clientId]
            val commandId = prompt.commandId ?: command?.id
            if (commandId != null && commandId in inTranscript) continue
            val tick = if (prompt.localError != null) Tick.Failed else tickFor(command?.status)
            pending += prompt.createdAt to TranscriptItem.User(
                key = "c:${prompt.clientId}",
                text = prompt.text,
                at = prompt.createdAt,
                remote = true,
                fromLabel = null,
                tick = tick,
                error = prompt.localError ?: command?.error,
                commandId = commandId,
                clientId = prompt.clientId,
                pending = true,
            )
        }
        for (command in prompts) {
            // Other phones' and the web's prompts appear when the computer runs them; only ours wait here with ticks.
            if (!command.isMine) continue
            if (command.clientId != null && command.clientId in optimisticClients) continue
            if (command.id in inTranscript) continue
            if (command.status == CommandStatus.DONE) continue
            // A prompt older than the loaded window belongs to history that is not shown yet.
            if (!historyComplete && oldestLoadedAt != null && command.createdAt < oldestLoadedAt) continue
            pending += command.createdAt to TranscriptItem.User(
                key = "c:${command.clientId ?: command.id}",
                text = command.text,
                at = command.createdAt,
                remote = true,
                fromLabel = command.fromLabel.ifBlank { null },
                tick = tickFor(command.status),
                error = command.error,
                commandId = command.id,
                clientId = command.clientId,
                pending = true,
            )
        }
        pending.sortBy { it.first }
        pending.mapTo(rows) { it.second }

        return withDaysAndGrouping(rows, zone).asReversed().distinctBy { it.key }
    }

    private fun rowFor(
        event: RelayEvent,
        commandsById: Map<String, PromptCommand>,
        streamingId: String?,
    ): TranscriptItem? {
        val key = "e:${event.id}"
        return when (event.kind) {
            EventKind.USER -> {
                val remote = event.origin == "remote"
                val command = event.commandId?.let(commandsById::get)
                // Status ticks belong to the sender: only prompts this device sent get them.
                val mine = remote && command != null && command.isMine
                TranscriptItem.User(
                    key = key,
                    text = event.text,
                    at = event.at,
                    remote = remote,
                    fromLabel = (event.fromLabel ?: command?.fromLabel)?.ifBlank { null },
                    tick = if (mine) tickFor(command.status) else null,
                    error = if (mine) command.error else null,
                    commandId = event.commandId,
                    clientId = command?.clientId,
                    pending = false,
                )
            }
            EventKind.ASSISTANT -> {
                if (event.text.isBlank() && event.id != streamingId) return null
                TranscriptItem.Assistant(key, event.text, event.at, streaming = event.id == streamingId)
            }
            EventKind.THOUGHT -> if (event.text.isBlank()) null else TranscriptItem.Thought(key, event.text, event.at)
            EventKind.TOOL -> TranscriptItem.Tool(
                key = key,
                title = event.title?.takeIf { it.isNotBlank() } ?: event.text.lineSequence().firstOrNull().orEmpty(),
                toolKind = event.toolKind,
                status = event.status,
                text = event.text,
                at = event.at,
            )
            EventKind.ERROR -> TranscriptItem.Notice(key, NoticeKind.Error, event.text, event.at)
            else -> when (event.status) {
                "end_turn", "end", "completed" -> null
                "cancelled" -> TranscriptItem.Notice(key, NoticeKind.Stopped, event.text, event.at)
                "max_tokens", "max_turn_requests" -> TranscriptItem.Notice(key, NoticeKind.MaxTokens, event.text, event.at)
                "refusal" -> TranscriptItem.Notice(key, NoticeKind.Refusal, event.text, event.at)
                else -> if (event.text.isBlank()) null else TranscriptItem.Notice(key, NoticeKind.Info, event.text, event.at)
            }
        }
    }

    /** Adds day headers and grouping flags to rows in chronological order. */
    private fun withDaysAndGrouping(rows: List<TranscriptItem>, zone: ZoneId): List<TranscriptItem> {
        val out = ArrayList<TranscriptItem>(rows.size + 4)
        var lastDay: LocalDate? = null
        for ((index, row) in rows.withIndex()) {
            val at = atOf(row)
            val day = Instant.ofEpochMilli(at).atZone(zone).toLocalDate()
            if (day != lastDay) {
                out += TranscriptItem.Day(day)
                lastDay = day
            }
            val older = rows.getOrNull(index - 1)
            val newer = rows.getOrNull(index + 1)
            val grouping = Grouping(
                withOlder = older != null && sameGroup(older, row, zone),
                withNewer = newer != null && sameGroup(row, newer, zone),
            )
            out += when (row) {
                is TranscriptItem.User -> row.copy(grouping = grouping)
                is TranscriptItem.Assistant -> row.copy(grouping = grouping)
                is TranscriptItem.Thought -> row.copy(grouping = grouping)
                is TranscriptItem.Tool -> row.copy(grouping = grouping)
                else -> row
            }
        }
        return out
    }

    private fun sameGroup(a: TranscriptItem, b: TranscriptItem, zone: ZoneId): Boolean {
        val author = authorOf(a)
        if (author == Author.None || author != authorOf(b)) return false
        val atA = atOf(a)
        val atB = atOf(b)
        if (abs(atB - atA) > GROUP_WINDOW_MS) return false
        val dayA = Instant.ofEpochMilli(atA).atZone(zone).toLocalDate()
        val dayB = Instant.ofEpochMilli(atB).atZone(zone).toLocalDate()
        return dayA == dayB
    }
}
