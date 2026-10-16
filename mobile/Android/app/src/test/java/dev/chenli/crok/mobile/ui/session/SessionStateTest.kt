package dev.chenli.crok.mobile.ui.session

import dev.chenli.crok.mobile.data.PendingInteraction
import dev.chenli.crok.mobile.data.PendingOption
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.TranscriptState
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The session screen's header status, composer gating and permission card, from the relay's session detail. */
class SessionStateTest {
    private val request = PendingInteraction(
        id = "tc-1",
        title = "Run npm run build",
        options = listOf(PendingOption("o1", "Allow once", "allow_once"), PendingOption("o2", "Reject", "reject_once")),
    )

    private fun state(detail: SessionDetail?, answering: String? = null, gone: Boolean = false) = SessionUiState.build(
        row = null,
        detail = detail,
        gone = gone,
        transcript = TranscriptState(loaded = true, historyComplete = true),
        prompts = emptyList(),
        optimistic = emptyList(),
        connection = ConnectionState.Connected,
        zone = ZoneOffset.UTC,
        answering = answering,
    )

    private fun detail(online: Boolean, deviceOnline: Boolean, status: String = SessionStatus.IDLE, pending: PendingInteraction? = null) =
        SessionDetail(id = "s1", deviceName = "MacBook", online = online, deviceOnline = deviceOnline, status = status, pending = pending)

    @Test
    fun theComposerIsBlockedOnlyWhileTheComputerIsOffline() {
        // Computer offline: blocked, "offline".
        val offline = state(detail(online = false, deviceOnline = false))
        assertEquals(SessionPhase.Offline, offline.phase)
        assertFalse(offline.canSend)

        // Computer online, nobody runs the session: a prompt opens it there, so it reads as idle and takes prompts.
        val notRunning = state(detail(online = false, deviceOnline = true, status = SessionStatus.RUNNING))
        assertEquals(SessionPhase.Idle, notRunning.phase)
        assertTrue(notRunning.canSend)
        assertFalse(notRunning.running)

        // Running there: Stop.
        val running = state(detail(online = true, deviceOnline = true, status = SessionStatus.RUNNING))
        assertEquals(SessionPhase.Working, running.phase)
        assertTrue(running.canSend)
        assertTrue(running.running)
        assertEquals(SessionPhase.Waiting, state(detail(online = true, deviceOnline = true, status = SessionStatus.WAITING)).phase)

        // Gone from the relay, or nothing known yet about the computer.
        assertFalse(state(null, gone = true).canSend)
        assertFalse(state(null).canSend)
    }

    @Test
    fun aPendingRequestShowsWhileACrokRunsTheSession() {
        val waiting = state(detail(online = true, deviceOnline = true, status = SessionStatus.WAITING, pending = request))
        assertEquals(request, waiting.pending)
        assertFalse(waiting.answering)

        // Answered from this phone: the buttons wait until the request leaves the session.
        assertTrue(state(detail(online = true, deviceOnline = true, status = SessionStatus.WAITING, pending = request), answering = "tc-1").answering)
        // An answer to an earlier request does not hold back a new one.
        assertFalse(state(detail(online = true, deviceOnline = true, status = SessionStatus.WAITING, pending = request), answering = "tc-0").answering)

        // A stale request of a session nobody runs is not shown.
        assertNull(state(detail(online = false, deviceOnline = true, pending = request)).pending)
        assertFalse(state(detail(online = false, deviceOnline = true, pending = request), answering = "tc-1").answering)
    }
}
