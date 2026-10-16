package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    /** Sessions in one project of [device] at /Users/me/code/[project]. */
    private fun group(project: String, vararg sessions: SessionRow, device: String = "d1", name: String = "MacBook", online: Boolean = true): SessionGroup {
        val key = "$device:/Users/me/code/$project"
        return SessionGroup(
            key = key,
            deviceId = device,
            deviceName = name,
            deviceOnline = online,
            path = "/Users/me/code/$project",
            name = project,
            sessions = sessions.map { it.copy(projectKey = key, projectPath = "/Users/me/code/$project", projectName = project) },
        )
    }

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
        val groups = listOf(
            group("crok", row("a"), row("c")),
            group("svc", row("b", "d2", "Studio", online = false), device = "d2", name = "Studio", online = false),
        )
        val tabs = SessionList.computerTabs(groups)
        assertEquals(listOf("MacBook", "Studio"), tabs.map { it.name })
        assertEquals(listOf(true, false), tabs.map { it.online })
        // The flat Archived list filters the same way.
        val rows = groups.flatMap { it.sessions }
        assertEquals(listOf("a", "c"), SessionList.filter(rows, SessionFilter.Computer("d1"), "").map { it.id })
        assertEquals(listOf("b"), SessionList.filter(rows, SessionFilter.All, "studio").map { it.id })
        assertEquals(listOf("c"), SessionList.filter(rows, SessionFilter.All, "code/c").map { it.id })
    }

    @Test
    fun aComputerTabShowsOnlyItsProjects() {
        val groups = listOf(group("crok", row("a")), group("svc", row("b", "d2", "Studio"), device = "d2", name = "Studio"), group("site", row("c")))
        assertEquals(listOf("d1:/Users/me/code/crok", "d1:/Users/me/code/site"), SessionList.sections(groups, SessionFilter.Computer("d1"), "").map { it.key })
        assertEquals(3, SessionList.sections(groups, SessionFilter.All, "").size)
    }

    @Test
    fun aSectionShowsFiveSessionsThenMore() {
        val big = group("crok", *(1..7).map { row("s$it") }.toTypedArray())
        val section = SessionList.sections(listOf(big), SessionFilter.All, "").single()
        assertEquals(7, section.count)
        assertEquals(listOf("s1", "s2", "s3", "s4", "s5"), section.visibleRows.map { it.id })
        assertEquals(2, section.hiddenCount)
        assertFalse(section.canShowLess)

        val expanded = SessionList.sections(listOf(big), SessionFilter.All, "", expanded = setOf(big.key)).single()
        assertEquals(7, expanded.visibleRows.size)
        assertEquals(0, expanded.hiddenCount)
        assertTrue(expanded.canShowLess)

        val collapsed = SessionList.sections(listOf(big), SessionFilter.All, "", collapsed = setOf(big.key)).single()
        assertTrue(collapsed.isCollapsed)
        assertEquals(emptyList<SessionRow>(), collapsed.visibleRows)
        assertEquals(0, collapsed.hiddenCount)
        assertEquals(7, collapsed.count)
    }

    @Test
    fun searchKeepsMatchingSessionsAndHidesEmptySections() {
        val groups = listOf(
            group("crok", row("a", title = "Fix the relay"), row("b", title = "Write notes"), row("c", title = "relay paging")),
            group("site", row("d", title = "Dark mode")),
        )
        val found = SessionList.sections(groups, SessionFilter.All, " relay ", collapsed = setOf(groups[0].key))
        assertEquals(1, found.size)
        // Matches show even in a collapsed section, all of them, without "Show more".
        assertEquals(listOf("a", "c"), found.single().visibleRows.map { it.id })
        assertFalse(found.single().isCollapsed)
        assertEquals(2, found.single().count)
        // A project's name matches all its sessions.
        assertEquals(listOf("d"), SessionList.sections(groups, SessionFilter.All, "site").single().rows.map { it.id })
        assertTrue(SessionList.sections(groups, SessionFilter.All, "nothing like it").isEmpty())
    }

    @Test
    fun theSecondLineShowsTheFolderOnlyWhenItIsNotTheProject() {
        val inProject = row("x").copy(cwd = "/Users/me/code/crok-build")
        val inSubfolder = row("y").copy(cwd = "/Users/me/code/crok-build/relay")
        assertNull(SessionList.folderLine(inProject, "crok-build"))
        assertEquals("relay", SessionList.folderLine(inSubfolder, "crok-build"))
        assertEquals("crok-build", SessionList.projectName(inProject))
        assertEquals("p", SessionList.projectName(inProject.copy(projectName = "p")))
    }

    @Test
    fun freezingSectionsHoldsBothLevels() {
        val before = listOf(group("crok", row("a"), row("b")), group("site", row("c")))
        val order = SessionList.orderOf(SessionList.sections(before, SessionFilter.All, ""))
        val after = listOf(group("site", row("c")), group("crok", row("b"), row("a", title = "A2"), row("n")))
        val frozen = SessionList.freezeSections(order, SessionList.sections(after, SessionFilter.All, ""))
        assertEquals(listOf("d1:/Users/me/code/crok", "d1:/Users/me/code/site"), frozen.map { it.key })
        assertEquals(listOf("a", "b", "n"), frozen.first().rows.map { it.id })
        assertEquals("A2", frozen.first().rows.first().title)
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

class SessionOrderTest {
    private fun row(id: String, at: Long, pinned: Boolean = false) = SessionRow(id = id, lastActivityAt = at, pinned = pinned)

    private fun group(key: String, at: Long, vararg sessions: SessionRow) =
        SessionGroup(key = key, deviceId = key.substringBefore(':'), lastActivityAt = at, sessions = sessions.toList())

    private val groups = listOf(
        group("mac:/a", 50, row("a1", 50), row("a2", 40)),
        group("box:/x", 45, row("x1", 45)),
        group("mac:/b", 30, row("b1", 30, pinned = true), row("b2", 20), row("b3", 10)),
        group("mac:/c", 60, row("c1", 60)),
    )

    private fun keys(list: List<SessionGroup>) = list.map { it.key }

    @Test
    fun reorderWithinLeavesTheOtherItemsInPlace() {
        // One computer's projects reordered: the other computer's project keeps its slot (the relay's reorderWithin).
        assertEquals(listOf("c", "x", "a", "b"), SessionOrder.reorderWithin(listOf("a", "x", "b", "c"), listOf("c", "a", "b")))
        assertEquals(listOf("b", "a"), SessionOrder.reorderWithin(listOf("a", "b"), listOf("b", "a")))
        // Unknown items make it a no-op rather than lose anything.
        assertEquals(listOf("a", "b"), SessionOrder.reorderWithin(listOf("a", "b"), listOf("b", "a", "a")))
        assertEquals(listOf("a", "b"), SessionOrder.reorderWithin(listOf("a", "b"), listOf("zz", "b")))
    }

    @Test
    fun appliesProjectAndSessionMovesLikeTheRelay() {
        val projects = SessionOrder.apply(groups, OrderChange.Projects(listOf("mac:/c", "mac:/b", "mac:/a")))
        assertEquals(listOf("mac:/c", "box:/x", "mac:/b", "mac:/a"), keys(projects))

        // Pinned sessions lead whatever order is asked for.
        val sessions = SessionOrder.apply(groups, OrderChange.Sessions("mac:/b", listOf("b3", "b2", "b1")))
        assertEquals(listOf("b1", "b3", "b2"), sessions[2].sessions.map { it.id })
        assertEquals(groups[0], sessions[0])

        val both = SessionOrder.applyAll(groups, listOf(OrderChange.Projects(listOf("mac:/b", "mac:/a")), OrderChange.Sessions("mac:/a", listOf("a2", "a1"))))
        assertEquals(listOf("mac:/b", "box:/x", "mac:/a", "mac:/c"), keys(both))
        assertEquals(listOf("a2", "a1"), both[2].sessions.map { it.id })
        assertTrue(SessionOrder.sameOrder(both, SessionOrder.apply(both, OrderChange.Sessions("mac:/a", listOf("a2", "a1")))))
        assertFalse(SessionOrder.sameOrder(both, groups))
    }

    @Test
    fun movesUpAndDownWithinTheirPartOfTheProject() {
        val b = groups[2].sessions
        assertEquals(listOf("b1", "b3", "b2"), SessionOrder.moveSession(b, "b3", -1))
        assertEquals(listOf("b1", "b3", "b2"), SessionOrder.moveSession(b, "b2", 1))
        // b2 is the first unpinned session: it cannot go above the pinned one, nor b3 below the end.
        assertNull(SessionOrder.moveSession(b, "b2", -1))
        assertNull(SessionOrder.moveSession(b, "b3", 1))
        assertNull(SessionOrder.moveSession(b, "b1", -1))
        assertNull(SessionOrder.moveSession(b, "b1", 1))
        assertEquals(listOf("b", "a", "c"), SessionOrder.move(listOf("a", "b", "c"), "b", -1))
        assertNull(SessionOrder.move(listOf("a", "b", "c"), "a", -1))
        assertTrue(SessionOrder.canSwap(b[1], b[2]))
        assertFalse(SessionOrder.canSwap(b[0], b[1]))
    }

    @Test
    fun sortByRecentActivity() {
        assertEquals(listOf("mac:/c", "mac:/a", "box:/x", "mac:/b"), SessionOrder.projectsByRecent(groups))
        val shuffled = listOf(row("old", 1), row("pinnedOld", 2, pinned = true), row("new", 9))
        assertEquals(listOf("pinnedOld", "new", "old"), SessionOrder.sessionsByRecent(shuffled))
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
