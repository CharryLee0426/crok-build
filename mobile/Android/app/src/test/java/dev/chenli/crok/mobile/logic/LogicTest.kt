package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.SessionRow
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UserCodeTest {
    @Test
    fun normalizesAnySpellingOfACode() {
        assertEquals("BCDF-GHJK", UserCode.normalize("bcdf ghjk"))
        assertEquals("BCDF-GHJK", UserCode.normalize("BCDFGHJK"))
        assertEquals("BCDF-GHJK", UserCode.normalize(" bcdf-ghjk "))
        assertNull(UserCode.normalize("BCDF-GHJ"))
        assertNull(UserCode.normalize("BCDF-GHJKL"))
    }

    @Test
    fun formatsWhileTyping() {
        assertEquals("BCD", UserCode.formatTyping("bcd"))
        assertEquals("BCDF", UserCode.formatTyping("bcdf"))
        assertEquals("BCDF-G", UserCode.formatTyping("bcdfg"))
        assertEquals("BCDF-GHJK", UserCode.formatTyping("bcdf-ghjk-xyz"))
        assertEquals("BCDF-GH", UserCode.formatTyping("bc1df gh"))
    }

    @Test
    fun readsScannedCodes() {
        assertEquals("BCDF-GHJK", UserCode.fromScan("https://crok.example.com/link?code=BCDF-GHJK"))
        assertEquals("BCDF-GHJK", UserCode.fromScan("https://crok.example.com/link?app=1&code=bcdf%20ghjk"))
        assertEquals("BCDF-GHJK", UserCode.fromScan("BCDF-GHJK"))
        assertNull(UserCode.fromScan("https://example.com/other"))
        assertNull(UserCode.fromScan("https://example.com/link?code=nope"))
        assertNull(UserCode.fromScan("hello world"))
    }
}

class PlanSummaryTest {
    @Test
    fun countsDoneAndPicksTheCurrentItem() {
        val plan = listOf(
            PlanEntry("Reproduce", "completed"),
            PlanEntry("Fix", "completed"),
            PlanEntry("Test 20 times", "in_progress"),
            PlanEntry("Commit", "pending"),
        )
        val summary = PlanSummary.of(plan)!!
        assertEquals(2, summary.done)
        assertEquals(4, summary.total)
        assertEquals("Test 20 times", summary.current)
    }

    @Test
    fun fallsBackToNextPendingThenLast() {
        assertEquals("B", PlanSummary.of(listOf(PlanEntry("A", "completed"), PlanEntry("B", "pending")))!!.current)
        val finished = PlanSummary.of(listOf(PlanEntry("A", "completed"), PlanEntry("B\nmore", "completed")))!!
        assertEquals("B", finished.current)
        assertTrue(finished.finished)
        assertNull(PlanSummary.of(emptyList()))
    }
}

class RelativeTimeTest {
    private val zone = ZoneOffset.UTC
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int) = LocalDateTime.of(y, mo, d, h, mi).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val now = at(2026, 10, 15, 12, 0)

    @Test
    fun listTimes() {
        assertEquals(ListTime.Today(LocalTime.of(9, 30)), RelativeTime.listTime(at(2026, 10, 15, 9, 30), now, zone))
        assertEquals(ListTime.ThisWeek(LocalDate.of(2026, 10, 12)), RelativeTime.listTime(at(2026, 10, 12, 23, 0), now, zone))
        assertEquals(ListTime.ThisYear(LocalDate.of(2026, 3, 1)), RelativeTime.listTime(at(2026, 3, 1, 8, 0), now, zone))
        assertEquals(ListTime.Older(LocalDate.of(2025, 12, 31)), RelativeTime.listTime(at(2025, 12, 31, 8, 0), now, zone))
    }

    @Test
    fun agoPicksTheCoarsestNaturalUnit() {
        assertEquals(Ago.JustNow, RelativeTime.ago(now - 20_000, now, zone))
        assertEquals(Ago.Minutes(5), RelativeTime.ago(now - 5 * 60_000, now, zone))
        assertEquals(Ago.Hours(3), RelativeTime.ago(now - 3 * 3_600_000, now, zone))
        assertEquals(Ago.Yesterday(LocalTime.of(20, 0)), RelativeTime.ago(at(2026, 10, 14, 20, 0), now, zone))
        assertEquals(Ago.Days(3), RelativeTime.ago(at(2026, 10, 12, 20, 0), now, zone))
        assertEquals(Ago.OnDate(LocalDate.of(2026, 9, 1)), RelativeTime.ago(at(2026, 9, 1, 20, 0), now, zone))
        // Clock skew (a time slightly in the future) reads as just now.
        assertEquals(Ago.JustNow, RelativeTime.ago(now + 5_000, now, zone))
    }

    @Test
    fun dayLabelsAndCountdown() {
        assertEquals(DayLabel.Today, RelativeTime.dayLabel(LocalDate.of(2026, 10, 15), now, zone))
        assertEquals(DayLabel.Yesterday, RelativeTime.dayLabel(LocalDate.of(2026, 10, 14), now, zone))
        assertEquals(DayLabel.ThisYear(LocalDate.of(2026, 1, 2)), RelativeTime.dayLabel(LocalDate.of(2026, 1, 2), now, zone))
        assertEquals(DayLabel.Older(LocalDate.of(2024, 1, 2)), RelativeTime.dayLabel(LocalDate.of(2024, 1, 2), now, zone))
        assertEquals("9:41", RelativeTime.countdown(9 * 60_000 + 41_000))
        assertEquals("0:01", RelativeTime.countdown(400))
        assertEquals("0:00", RelativeTime.countdown(-5))
    }
}

class SessionListTest {
    private fun row(id: String, device: String = "d1", name: String = "MacBook", title: String = id, online: Boolean = true) =
        SessionRow(id = id, title = title, cwd = "/Users/me/code/$id", deviceId = device, deviceName = name, deviceOnline = online, online = online)

    @Test
    fun freezingKeepsTheOrderButTakesNewContent() {
        val previous = listOf("a", "b", "c")
        val fresh = listOf(row("c", title = "C2"), row("a"), row("d"))
        val frozen = SessionList.freezeOrder(previous, fresh)
        assertEquals(listOf("a", "c", "d"), frozen.map { it.id })
        assertEquals("C2", frozen[1].title)
    }

    @Test
    fun tabsAndFilters() {
        val rows = listOf(row("a", "d1", "MacBook"), row("b", "d2", "Studio", online = false), row("c", "d1", "MacBook"))
        val tabs = SessionList.computerTabs(rows)
        assertEquals(listOf("MacBook", "Studio"), tabs.map { it.name })
        assertEquals(listOf(true, false), tabs.map { it.online })
        assertEquals(listOf("a", "c"), SessionList.filter(rows, SessionFilter.Computer("d1"), "").map { it.id })
        assertEquals(listOf("b"), SessionList.filter(rows, SessionFilter.All, "studio").map { it.id })
        assertEquals(listOf("c"), SessionList.filter(rows, SessionFilter.All, "code/c").map { it.id })
    }

    @Test
    fun foldersAndPaths() {
        assertEquals("crok-build", SessionList.folderName("/Users/me/code/crok-build/"))
        assertEquals("proj", SessionList.folderName("C:\\work\\proj"))
        assertEquals("/", SessionList.folderName("/"))
        assertEquals("~/code/crok", SessionList.prettyPath("/Users/me/code/crok"))
        assertEquals("~/svc", SessionList.prettyPath("/home/me/svc"))
        assertEquals("/opt/x", SessionList.prettyPath("/opt/x"))
    }

    @Test
    fun avatarInitialsAndColours() {
        assertEquals("CB", Avatars.initials("crok-build"))
        assertEquals("R", Avatars.initials("relay"))
        assertEquals("MP", Avatars.initials("myProject"))
        assertEquals("项", Avatars.initials("项目"))
        assertEquals(Avatars.colorIndex("crok-build", 7), Avatars.colorIndex("crok-build", 7))
        assertTrue(Avatars.colorIndex("x", 7) in 0 until 7)
    }
}

class RevealPacerTest {
    @Test
    fun revealsEachChunkOverAboutOneInterval() {
        var now = 0L
        val pacer = RevealPacer(0, now)
        // Chunks of 60 characters every 750 ms.
        var length = 0
        repeat(4) {
            length += 60
            pacer.onText(length, now)
            val start = pacer.revealed
            now += 16
            pacer.advance(now, streaming = true)
            assertTrue("reveals gradually, not all at once", pacer.revealed in (start + 1) until length)
            while (now % 750 != 0L) {
                now += 2
                pacer.advance(now, streaming = true)
            }
        }
        // It keeps up: never more than a chunk behind.
        assertTrue(length - pacer.revealed <= 60)
    }

    @Test
    fun finishesWithinThreeHundredMillisecondsWhenTheTurnEnds() {
        val pacer = RevealPacer(0, 0)
        pacer.onText(5_000, 0)
        var now = 0L
        while (!pacer.caughtUp) {
            now += 16
            pacer.advance(now, streaming = false)
            assertTrue("took too long: $now ms", now <= 320)
        }
        assertEquals(5_000, pacer.revealed)
    }

    @Test
    fun replacedTextShowsAtOnce() {
        val pacer = RevealPacer(100, 0)
        pacer.onText(40, 10)
        assertEquals(40, pacer.revealed)
        assertTrue(pacer.caughtUp)
    }
}
