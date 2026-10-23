package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SessionStatus
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

    private fun device(id: String, name: String, createdAt: Long, online: Boolean = true, kind: String = "computer") =
        Device(id = id, kind = kind, name = name, createdAt = createdAt, lastSeenAt = createdAt, online = online)

    @Test
    fun computersComeInLinkOrderWithTheirUnreadCounts() {
        val groups = listOf(
            group("crok", row("a").copy(unread = 2, lastActivityAt = 50), row("c").copy(unread = 1)),
            group("svc", row("b", "d2", "Studio").copy(lastActivityAt = 90), device = "d2", name = "Studio"),
            // A computer the device list does not know (yet): listed after the linked ones, by its sessions' name.
            group("old", row("z", "d9", "Old Mac").copy(unread = 4), device = "d9", name = "Old Mac", online = false),
        )
        val devices = listOf(
            device("phone", "Pixel", 1, kind = "phone"),
            device("d2", "Studio", 10, online = false),
            device("d1", "MacBook", 20),
        )
        val computers = Computers.list(devices, groups)
        assertEquals(listOf("d2", "d1", "d9"), computers.map { it.deviceId })
        assertEquals(listOf("Studio", "MacBook", "Old Mac"), computers.map { it.name })
        assertEquals(listOf(false, true, false), computers.map { it.online })
        assertEquals(listOf(0, 3, 4), computers.map { it.unread })
        // The Profile tab's badge: the others' unread.
        assertEquals(4, Computers.unreadElsewhere(computers, "d1"))
        assertEquals(7, Computers.unreadElsewhere(computers, "d2"))
    }

    @Test
    fun theSelectionIsTheRememberedComputerElseTheMostRecentlyActive() {
        val computers = listOf(
            ComputerAccount("d1", "MacBook", online = true, lastActivityAt = 50),
            ComputerAccount("d2", "Studio", online = true, lastActivityAt = 90),
            ComputerAccount("d3", "Linux", online = false),
        )
        assertEquals("d1", Computers.selected(computers, "d1")?.deviceId)
        assertEquals("d2", Computers.selected(computers, null)?.deviceId)
        // A remembered computer that is gone (signed out) falls back too.
        assertEquals("d2", Computers.selected(computers, "gone")?.deviceId)
        // Without any activity: the first.
        assertEquals("d3", Computers.selected(listOf(computers[2]), null)?.deviceId)
        assertNull(Computers.selected(emptyList(), "d1"))
    }

    @Test
    fun theSessionsTabKeepsOnlyTheSelectedComputersProjects() {
        val groups = listOf(group("crok", row("a")), group("svc", row("b", "d2", "Studio"), device = "d2", name = "Studio"), group("site", row("c")))
        assertEquals(listOf("d1:/Users/me/code/crok", "d1:/Users/me/code/site"), Computers.projects(groups, "d1").map { it.key })
        assertTrue(Computers.projects(groups, null).isEmpty())
    }

    @Test
    fun markAllAsReadTakesEveryUnreadSessionOfTheComputer() {
        val groups = listOf(
            group("crok", row("a").copy(unread = 2), row("b")),
            group("site", row("c").copy(unread = 1)),
        )
        assertEquals(setOf("a", "c"), Computers.unreadSessionIds(groups))
        assertTrue(Computers.unreadSessionIds(listOf(group("quiet", row("q")))).isEmpty())
    }

    @Test
    fun aForumRowShowsItsThreeMostRecentTopics() {
        val project = group(
            "crok",
            // Hand-placed order: pinned first; the row still lists the most recent topics.
            row("p", title = "Pinned plan").copy(pinned = true, lastActivityAt = 10),
            row("x", title = "").copy(cwd = "/Users/me/code/crok/relay", lastActivityAt = 40),
            row("y", title = "Fix the pager").copy(lastActivityAt = 90),
            row("w", title = "Write notes").copy(lastActivityAt = 30),
        )
        assertEquals(listOf("Fix the pager", "relay", "Write notes"), Forum.topicTitles(project))
        assertEquals("y", Forum.latest(project)?.id)
        assertEquals(Forum.Activity.Idle, Forum.activity(project))
        val busy = project.copy(sessions = project.sessions + row("r").copy(status = SessionStatus.RUNNING))
        assertEquals(Forum.Activity.Working, Forum.activity(busy))
        val asking = project.copy(sessions = project.sessions + row("q").copy(status = SessionStatus.WAITING))
        assertEquals(Forum.Activity.Waiting, Forum.activity(asking))
    }

    @Test
    fun searchFindsTheComputersSessionsByTitleFolderPreviewOrModel() {
        val groups = listOf(
            group("crok", row("a", title = "Fix the relay"), row("b", title = "Write notes").copy(model = "grok-4"), row("c", title = "Paging").copy(preview = "the relay pages now")),
            group("site", row("d", title = "Dark mode")),
        )
        assertEquals(listOf("a", "c"), Forum.search(groups, " relay ").map { it.id })
        assertEquals(listOf("b"), Forum.search(groups, "GROK").map { it.id })
        // A project's name matches all its sessions.
        assertEquals(listOf("d"), Forum.search(groups, "site").map { it.id })
        assertTrue(Forum.search(groups, "nothing like it").isEmpty())
        assertTrue(Forum.search(groups, "  ").isEmpty())
    }

    @Test
    fun topicColoursMatchTheIosApp() {
        // FNV-1a over UTF-8, as iOS's ProjectAvatar.colorIndex: the same session gets the same colour on both phones.
        assertEquals(StableIndex.fnv1a("", 6), (2_166_136_261L % 6).toInt())
        val a = 2_166_136_261L xor 'a'.code.toLong()
        assertEquals(((a * 16_777_619L) and 0xFFFFFFFFL) % 6, StableIndex.fnv1a("a", 6).toLong())
        assertEquals(StableIndex.fnv1a("demo-s1", 6), TopicColors.index("demo-s1"))
        assertEquals(6, TopicColors.all.size)
        assertEquals("F", TopicColors.initial("fix the pager"))
        assertEquals("2", TopicColors.initial("  2nd try"))
        assertEquals("·", TopicColors.initial("…"))
    }

    @Test
    fun theGradientMixesFourColoursByDistance() {
        // Each colour dominates at its own point; the weights always add up to one.
        ThemeGradient.points.forEachIndexed { index, (x, y) ->
            val w = ThemeGradient.weights(x, y)
            assertEquals(1f, w.sum(), 1e-4f)
            assertEquals(index, w.indices.maxBy { w[it] })
        }
        val colors = listOf(0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF)
        // At the first point the pixel is mostly red.
        val pixel = ThemeGradient.mix(colors, 0.80f, 0.10f)
        assertTrue((pixel shr 16 and 0xFF) > 200)
        assertEquals(0xFF, pixel ushr 24)
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
    fun freezingProjectsHoldsTheirOrder() {
        val before = listOf(group("crok", row("a")), group("site", row("c")))
        val after = listOf(group("site", row("c")), group("new", row("n")), group("crok", row("a", title = "A2")))
        val frozen = SessionList.freeze(before.map { it.key }, after) { it.key }
        assertEquals(listOf("d1:/Users/me/code/crok", "d1:/Users/me/code/site", "d1:/Users/me/code/new"), frozen.map { it.key })
        assertEquals("A2", frozen.first().sessions.single().title)
    }

    @Test
    fun photosAreDownscaledToTheirLongestSide() {
        assertEquals(2048 to 1536, dev.chenli.crok.mobile.data.PhotoImport.targetSize(4032, 3024))
        assertEquals(1152 to 2048, dev.chenli.crok.mobile.data.PhotoImport.targetSize(2268, 4032))
        assertEquals(800 to 600, dev.chenli.crok.mobile.data.PhotoImport.targetSize(800, 600))
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
