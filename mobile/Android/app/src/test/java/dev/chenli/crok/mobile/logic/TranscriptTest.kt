package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptTest {
    private val zone: ZoneId = ZoneOffset.UTC
    private val day1 = LocalDateTime.of(2026, 10, 14, 17, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val day2 = LocalDateTime.of(2026, 10, 15, 9, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val minute = 60_000L

    private fun event(seq: Long, kind: String, at: Long, text: String = "t$seq", status: String? = null, origin: String? = null, commandId: String? = null) =
        RelayEvent("e$seq", seq, "k$seq", kind, text, status = status, origin = origin, commandId = commandId, at = at)

    private fun build(
        events: List<RelayEvent>,
        prompts: List<PromptCommand> = emptyList(),
        optimistic: List<OptimisticPrompt> = emptyList(),
        running: Boolean = false,
        complete: Boolean = true,
    ) = Transcript.build(events, prompts, optimistic, running, complete, zone)

    @Test
    fun newestFirstWithDayHeaders() {
        val items = build(
            listOf(
                event(1, EventKind.USER, day1),
                event(2, EventKind.ASSISTANT, day1 + minute),
                event(3, EventKind.USER, day2),
            ),
        )
        // Reversed list: newest at index 0, the day header sits above (after) its day's items.
        assertEquals(listOf("e:e3", "d:2026-10-15", "e:e2", "e:e1", "d:2026-10-14"), items.map { it.key })
    }

    @Test
    fun groupsSameAuthorWithinTenMinutes() {
        val items = build(
            listOf(
                event(1, EventKind.ASSISTANT, day1),
                event(2, EventKind.TOOL, day1 + 2 * minute),
                event(3, EventKind.ASSISTANT, day1 + 20 * minute),
                event(4, EventKind.USER, day1 + 21 * minute),
            ),
        ).filterNot { it is TranscriptItem.Day }.reversed()
        val first = items[0] as TranscriptItem.Assistant
        val tool = items[1] as TranscriptItem.Tool
        val late = items[2] as TranscriptItem.Assistant
        val user = items[3] as TranscriptItem.User
        assertEquals(Grouping(withOlder = false, withNewer = true), first.grouping)
        assertEquals(Grouping(withOlder = true, withNewer = false), tool.grouping)
        // 18 minutes later: a new group.
        assertEquals(Grouping(withOlder = false, withNewer = false), late.grouping)
        assertEquals(Grouping(), user.grouping)
    }

    @Test
    fun hidesTurnEndsAndNamesStops() {
        val items = build(
            listOf(
                event(1, EventKind.ASSISTANT, day1),
                event(2, EventKind.SYSTEM, day1, text = "", status = "end_turn"),
                event(3, EventKind.SYSTEM, day1, text = "", status = "cancelled"),
                event(4, EventKind.ERROR, day1, text = "boom"),
            ),
        )
        val notices = items.filterIsInstance<TranscriptItem.Notice>()
        assertEquals(listOf(NoticeKind.Error, NoticeKind.Stopped), notices.map { it.kind })
        assertTrue(items.none { it.key == "e:e2" })
    }

    @Test
    fun streamingIsTheLastReplyAfterTheLastPromptWhileRunning() {
        val events = listOf(
            event(1, EventKind.ASSISTANT, day1),
            event(2, EventKind.USER, day1),
            event(3, EventKind.ASSISTANT, day1, text = "partial"),
        )
        val running = build(events, running = true).filterIsInstance<TranscriptItem.Assistant>()
        assertEquals(listOf(true, false), running.map { it.streaming })
        val idle = build(events, running = false).filterIsInstance<TranscriptItem.Assistant>()
        assertTrue(idle.none { it.streaming })
        // A reply before the newest prompt is never the streaming one.
        val waitingForReply = build(events.take(2), running = true).filterIsInstance<TranscriptItem.Assistant>()
        assertTrue(waitingForReply.none { it.streaming })
    }

    @Test
    fun optimisticPromptShowsUntilTheTranscriptHasIt() {
        val prompt = OptimisticPrompt("client-1", "Run it", day2)
        val sending = build(listOf(event(1, EventKind.USER, day1)), optimistic = listOf(prompt))
        val bubble = sending.first() as TranscriptItem.User
        assertEquals("c:client-1", bubble.key)
        assertEquals(Tick.Clock, bubble.tick)
        assertTrue(bubble.pending)

        // The relay accepted it: one check.
        val command = PromptCommand("cmd-1", "client-1", "Run it", CommandStatus.DELIVERED, null, "Pixel 9", createdAt = day2, updatedAt = day2)
        val delivered = build(listOf(event(1, EventKind.USER, day1)), listOf(command), listOf(prompt.copy(commandId = "cmd-1")))
        assertEquals(Tick.Sent, (delivered.first() as TranscriptItem.User).tick)

        // The transcript holds the user event with that command: the optimistic bubble goes, the event keeps the tick.
        val inTranscript = build(
            listOf(event(1, EventKind.USER, day1), event(2, EventKind.USER, day2, origin = "remote", commandId = "cmd-1")),
            listOf(command.copy(status = CommandStatus.DONE)),
            listOf(prompt.copy(commandId = "cmd-1")),
        )
        assertTrue(inTranscript.none { it.key == "c:client-1" })
        val event = inTranscript.first() as TranscriptItem.User
        assertEquals("e:e2", event.key)
        assertEquals(Tick.Done, event.tick)
        assertEquals("Pixel 9", event.fromLabel)
        assertTrue(event.remote)
    }

    @Test
    fun matchesTheCommandByClientIdBeforeSendPromptAnswers() {
        val prompt = OptimisticPrompt("client-2", "hello", day2)
        val command = PromptCommand("cmd-2", "client-2", "hello", CommandStatus.PENDING, null, "Pixel 9", createdAt = day2, updatedAt = day2)
        val items = build(
            listOf(event(1, EventKind.USER, day1), event(2, EventKind.USER, day2, origin = "remote", commandId = "cmd-2")),
            listOf(command),
            listOf(prompt),
        )
        assertTrue(items.none { it.key == "c:client-2" })
    }

    @Test
    fun failedSendsShowTheErrorAndFailedCommandsSurviveRestarts() {
        val local = build(emptyList(), optimistic = listOf(OptimisticPrompt("c3", "hi", day2, localError = "offline")))
        val failed = local.first() as TranscriptItem.User
        assertEquals(Tick.Failed, failed.tick)
        assertEquals("offline", failed.error)

        // After a restart there is no optimistic state, but the relay still lists the failed prompt.
        val fromRelay = build(
            listOf(event(1, EventKind.USER, day1)),
            listOf(PromptCommand("cmd-4", "c4", "again", CommandStatus.FAILED, "busy", "Pixel 9", createdAt = day2, updatedAt = day2)),
        )
        val bubble = fromRelay.first() as TranscriptItem.User
        assertEquals(Tick.Failed, bubble.tick)
        assertEquals("busy", bubble.error)
        assertEquals("cmd-4", bubble.commandId)
    }

    @Test
    fun skipsDonePromptsAndPromptsOlderThanTheLoadedWindow() {
        val events = listOf(event(10, EventKind.USER, day2))
        val old = PromptCommand("old", "c-old", "older", CommandStatus.FAILED, "x", "Pixel 9", createdAt = day1, updatedAt = day1)
        val done = PromptCommand("done", "c-done", "done", CommandStatus.DONE, null, "Pixel 9", createdAt = day2 + minute, updatedAt = day2 + minute)
        val partial = build(events, listOf(old, done), complete = false)
        assertTrue(partial.none { it.key == "c:c-old" || it.key == "c:c-done" })
        // With the whole history loaded the old failed prompt shows (at the end, as pending).
        val full = build(events, listOf(old), complete = true)
        assertTrue(full.any { it.key == "c:c-old" })
    }

    @Test
    fun onlyThisDevicesPromptsGetTicksAndWaitingBubbles() {
        val theirs = PromptCommand(
            "cmd-web", "c-web", "from the web", CommandStatus.DELIVERED, null, "Web",
            fromDeviceId = null, mine = false, createdAt = day2, updatedAt = day2,
        )
        val queued = build(listOf(event(1, EventKind.USER, day1)), listOf(theirs))
        assertTrue(queued.none { it.key == "c:c-web" })

        val ran = build(
            listOf(event(1, EventKind.USER, day2, origin = "remote", commandId = "cmd-web").copy(fromLabel = "Web")),
            listOf(theirs.copy(status = CommandStatus.DONE)),
        )
        val user = ran.first() as TranscriptItem.User
        assertNull(user.tick)
        assertEquals("Web", user.fromLabel)
    }

    @Test
    fun keysAreUniqueEvenWithDuplicateEvents() {
        val events = listOf(event(1, EventKind.USER, day1), event(1, EventKind.USER, day1), event(2, EventKind.ASSISTANT, day1))
        val items = build(events)
        assertEquals(items.size, items.map { it.key }.toSet().size)
    }

    @Test
    fun tickMapping() {
        assertEquals(Tick.Clock, tickFor(null))
        assertEquals(Tick.Clock, tickFor(CommandStatus.PENDING))
        assertEquals(Tick.Sent, tickFor(CommandStatus.DELIVERED))
        assertEquals(Tick.Done, tickFor(CommandStatus.DONE))
        assertEquals(Tick.Failed, tickFor(CommandStatus.FAILED))
    }

    @Test
    fun localPromptsHaveNoTick() {
        val items = build(listOf(event(1, EventKind.USER, day1, origin = "local")))
        val user = items.first() as TranscriptItem.User
        assertNull(user.tick)
        assertFalse(user.remote)
    }

    private fun tool(seq: Long, status: String?, title: String = "Run `cargo test`") =
        RelayEvent("e$seq", seq, "k$seq", EventKind.TOOL, "", title = title, toolKind = "execute", status = status, at = day1 + seq)

    private fun stateOf(items: List<TranscriptItem>, seq: Long) = (items.first { it.key == "e:e$seq" } as TranscriptItem.Tool).state

    @Test
    fun thoughtsShowWithoutTheirTextAndThinkWhileNewestInARunningTurn() {
        // `sessions:transcript` sends thoughts without their text: they still show, by their status.
        val thinking = listOf(event(1, EventKind.USER, day1), event(2, EventKind.THOUGHT, day1 + 1, text = ""))
        assertTrue((build(thinking, running = true).first() as TranscriptItem.Thought).active)
        // Not running (or waiting): done.
        assertFalse((build(thinking, running = false).first() as TranscriptItem.Thought).active)
        val waiting = Transcript.build(thinking, emptyList(), emptyList(), sessionRunning = false, historyComplete = true, zone = zone, turnRunning = true)
        assertTrue("a turn waiting on a permission request still runs", (waiting.first() as TranscriptItem.Thought).active)
        // Something newer followed it: done.
        val after = build(thinking + tool(3, "in_progress"), running = true)
        assertFalse((after.first { it is TranscriptItem.Thought } as TranscriptItem.Thought).active)
    }

    @Test
    fun toolCallsShowTheirState() {
        val events = listOf(
            event(1, EventKind.USER, day1),
            tool(2, "in_progress"),
            event(3, EventKind.SYSTEM, day1 + 3, text = "", status = "cancelled"),
            event(4, EventKind.USER, day1 + 4),
            tool(5, "completed"),
            tool(6, "failed"),
            tool(7, "pending"),
            tool(8, "in_progress"),
            tool(9, "weird_status"),
        )
        val running = build(events, running = true)
        assertEquals("its turn ended after it", ToolState.Stopped, stateOf(running, 2))
        assertEquals(ToolState.Completed, stateOf(running, 5))
        assertEquals(ToolState.Failed, stateOf(running, 6))
        assertEquals(ToolState.Running, stateOf(running, 7))
        assertEquals(ToolState.Running, stateOf(running, 8))
        assertEquals(ToolState.Other, stateOf(running, 9))
        // The session stopped running: unfinished calls are stopped.
        val idle = build(events, running = false)
        assertEquals(ToolState.Stopped, stateOf(idle, 7))
        assertEquals(ToolState.Stopped, stateOf(idle, 8))
        assertEquals(ToolState.Completed, stateOf(idle, 5))
        // The title stays as sent (its `code` is drawn by the row).
        assertEquals("Run `cargo test`", (running.first { it.key == "e:e5" } as TranscriptItem.Tool).title)
    }
}
