package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.auth.StoredCredentials
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.MeDevice
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.PlanProgress
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.data.SessionUsage

/** A session in the demo relay: its detail plus the list-only fields. */
data class DemoSession(
    val detail: SessionDetail,
    val preview: String?,
    val previewKind: String?,
    val unread: Int,
) {
    val id: String get() = detail.id

    fun row(): SessionRow = SessionRow(
        id = detail.id,
        sessionId = detail.sessionId,
        title = detail.title,
        cwd = detail.cwd,
        model = detail.model,
        status = detail.status,
        online = detail.online,
        app = detail.app,
        deviceId = detail.deviceId,
        deviceName = detail.deviceName,
        deviceOnline = detail.deviceOnline,
        preview = preview,
        previewKind = previewKind,
        lastActivityAt = detail.lastActivityAt,
        pinned = detail.pinned,
        archived = detail.archived,
        unread = unread,
        plan = if (detail.plan.isEmpty()) null else PlanProgress(detail.plan.count { it.status == "completed" }, detail.plan.size),
    )
}

/** A command in the demo relay. */
data class DemoCommand(
    val id: String,
    val sessionDocId: String,
    val type: String,
    val text: String = "",
    val clientId: String? = null,
    val status: String = CommandStatus.PENDING,
    val error: String? = null,
    val fromLabel: String = DemoData.PHONE_NAME,
    val fromDeviceId: String? = DemoData.PHONE_ID,
    val createdAt: Long,
    val updatedAt: Long = createdAt,
    val result: kotlinx.serialization.json.JsonElement? = null,
) {
    fun prompt(): PromptCommand =
        PromptCommand(id, clientId, text, status, error, fromLabel, fromDeviceId, mine = fromDeviceId == DemoData.PHONE_ID, createdAt = createdAt, updatedAt = updatedAt)
}

data class DemoState(
    val me: Me,
    val devices: List<Device>,
    val sessions: List<DemoSession>,
    val events: Map<String, List<RelayEvent>>,
    val commands: List<DemoCommand>,
    val revoked: Boolean = false,
)

/**
 * The demo account: three computers, a phone, and sessions in every state the screens draw (running with a plan,
 * waiting for approval, idle, offline, archived). Used by demo mode (`crokDemo=true`) and by the screenshot tests.
 */
object DemoData {
    const val PHONE_ID = "demo-phone"
    const val PHONE_NAME = "Pixel 9"
    const val MACBOOK_ID = "demo-macbook"
    const val STUDIO_ID = "demo-studio"
    const val LINUX_ID = "demo-linux"
    const val RUNNING_SESSION = "demo-s1"
    const val WAITING_SESSION = "demo-s2"

    private const val MIN = 60_000L
    private const val HOUR = 60 * MIN
    private const val DAY = 24 * HOUR

    val credentials = StoredCredentials(
        serverUrl = "https://demo.crok.invalid",
        deviceId = PHONE_ID,
        refreshToken = "demo",
        user = RelayUser(name = "Chen Li", email = "chen@example.com"),
        deviceName = PHONE_NAME,
    )

    fun state(now: Long): DemoState = DemoState(
        me = Me(
            userId = "demo-user",
            name = "Chen Li",
            email = "chen@example.com",
            device = MeDevice(PHONE_ID, "phone", PHONE_NAME, "Android 16", "Crok Android 1.0 (1)"),
        ),
        devices = devices(now),
        sessions = sessions(now),
        events = mapOf(RUNNING_SESSION to runningEvents(now), WAITING_SESSION to waitingEvents(now)),
        commands = listOf(
            DemoCommand(
                id = "demo-cmd-1",
                sessionDocId = RUNNING_SESSION,
                type = "prompt",
                text = "Run it 20 times to be sure",
                clientId = "demo-client-1",
                status = CommandStatus.DELIVERED,
                createdAt = now - 6 * MIN,
            ),
        ),
    )

    fun devices(now: Long): List<Device> = listOf(
        Device(PHONE_ID, "phone", PHONE_NAME, "Android 16", "Crok Android 1.0 (1)", now - 20 * DAY, now - MIN, true, true, 0),
        Device(MACBOOK_ID, "computer", "MacBook Pro", "macOS 26.1", "Crok Desktop 1.5.0", now - 40 * DAY, now - 2 * MIN, true, false, 2),
        Device(STUDIO_ID, "computer", "Studio", "macOS 26.0", "crok 1.0.45", now - 60 * DAY, now - 3 * MIN, true, false, 2),
        Device("demo-iphone", "phone", "iPhone", "iOS 26.0", "Crok iOS 1.0 (1)", now - 18 * DAY, now - 2 * HOUR, false, false, 0),
        Device(LINUX_ID, "computer", "Linux box", "Ubuntu 24.04", "crok 1.0.44", now - 90 * DAY, now - 3 * DAY, false, false, 0),
    )

    val runningPlan = listOf(
        PlanEntry("Reproduce the flake locally", "completed"),
        PlanEntry("Find the race in the reconnect test", "completed"),
        PlanEntry("Replace the fixed sleep with wait_connected", "completed"),
        PlanEntry("Run the test 20 times", "in_progress"),
        PlanEntry("Run the whole crok-remote suite", "pending"),
        PlanEntry("Write the commit message", "pending"),
        PlanEntry("Open a pull request", "pending"),
    )

    fun sessions(now: Long): List<DemoSession> = listOf(
        DemoSession(
            SessionDetail(
                id = RUNNING_SESSION,
                sessionId = "0199e2e0-7a1c-7b4e-9f00-5c1d2e3f4a5b",
                title = "Fix the flaky relay reconnect test",
                cwd = "/Users/chen/code/crok-build",
                model = "grok-code-fast-1",
                effort = "medium",
                gitBranch = "fix/relay-reconnect-flake",
                status = SessionStatus.RUNNING,
                online = true,
                app = "desktop",
                deviceId = MACBOOK_ID,
                deviceName = "MacBook Pro",
                devicePlatform = "macOS 26.1",
                deviceOnline = true,
                createdAt = now - DAY - 3 * HOUR,
                lastActivityAt = now - MIN,
                plan = runningPlan,
                usage = SessionUsage(182_400, 9_830, 150_200, 2_100, 0.42, 61_500, 256_000),
                eventSeq = 10,
            ),
            preview = "So far 12 of 20 runs passed, none failed.",
            previewKind = EventKind.ASSISTANT,
            unread = 2,
        ),
        DemoSession(
            SessionDetail(
                id = WAITING_SESSION,
                sessionId = "0199e2e0-11aa-7c00-8d00-000000000002",
                title = "Add dark mode to the settings page",
                cwd = "/Users/chen/code/crok-site",
                model = "claude-sonnet-4-5",
                effort = "high",
                gitBranch = "dark-settings",
                status = SessionStatus.WAITING,
                online = true,
                app = "tui",
                deviceId = MACBOOK_ID,
                deviceName = "MacBook Pro",
                devicePlatform = "macOS 26.1",
                deviceOnline = true,
                createdAt = now - 2 * HOUR,
                lastActivityAt = now - 4 * MIN,
                pinned = true,
                usage = SessionUsage(40_100, 3_200, 31_000, null, 0.18, 22_000, 200_000),
                eventSeq = 3,
            ),
            preview = "Run npm run build to check the new theme?",
            previewKind = EventKind.ASSISTANT,
            unread = 1,
        ),
        DemoSession(
            SessionDetail(
                id = "demo-s3",
                sessionId = "0199e2e0-11aa-7c00-8d00-000000000003",
                title = "Refactor relay pagination",
                cwd = "/Users/chen/code/crok-build/relay",
                model = "grok-code-fast-1",
                status = SessionStatus.IDLE,
                online = true,
                app = "tui",
                deviceId = STUDIO_ID,
                deviceName = "Studio",
                devicePlatform = "macOS 26.0",
                deviceOnline = true,
                createdAt = now - 5 * HOUR,
                lastActivityAt = now - 35 * MIN,
            ),
            preview = "ship it",
            previewKind = EventKind.USER,
            unread = 0,
        ),
        DemoSession(
            SessionDetail(
                id = "demo-s4",
                sessionId = "0199e2e0-11aa-7c00-8d00-000000000004",
                title = "Write the 1.5 release notes",
                cwd = "/Users/chen/code/crok-build",
                model = "grok-4",
                status = SessionStatus.IDLE,
                online = true,
                app = "desktop",
                deviceId = STUDIO_ID,
                deviceName = "Studio",
                devicePlatform = "macOS 26.0",
                deviceOnline = true,
                createdAt = now - DAY - 6 * HOUR,
                lastActivityAt = now - DAY - 2 * HOUR,
            ),
            preview = "The notes are in dist/v1.5.0/notes, in six languages.",
            previewKind = EventKind.ASSISTANT,
            unread = 1,
        ),
        DemoSession(
            SessionDetail(
                id = "demo-s5",
                sessionId = "0199e2e0-11aa-7c00-8d00-000000000005",
                title = "Investigate the memory spike in ingest",
                cwd = "/home/chen/services/ingest",
                model = "grok-code-fast-1",
                status = SessionStatus.IDLE,
                online = false,
                app = "tui",
                deviceId = LINUX_ID,
                deviceName = "Linux box",
                devicePlatform = "Ubuntu 24.04",
                deviceOnline = false,
                createdAt = now - 4 * DAY,
                lastActivityAt = now - 3 * DAY,
            ),
            preview = "The leak is in the batch buffer: it never shrinks after a burst.",
            previewKind = EventKind.ASSISTANT,
            unread = 0,
        ),
        DemoSession(
            SessionDetail(
                id = "demo-s6",
                sessionId = "0199e2e0-11aa-7c00-8d00-000000000006",
                title = "Try Kotlin 2.4",
                cwd = "/Users/chen/code/scratch",
                status = SessionStatus.IDLE,
                online = false,
                app = "tui",
                deviceId = STUDIO_ID,
                deviceName = "Studio",
                devicePlatform = "macOS 26.0",
                deviceOnline = true,
                createdAt = now - 13 * DAY,
                lastActivityAt = now - 12 * DAY,
                archived = true,
            ),
            preview = "Everything compiles; two deprecation warnings left.",
            previewKind = EventKind.ASSISTANT,
            unread = 0,
        ),
    )

    private fun event(
        session: String,
        seq: Long,
        kind: String,
        text: String,
        at: Long,
        title: String? = null,
        toolKind: String? = null,
        status: String? = null,
        origin: String? = null,
        commandId: String? = null,
        fromLabel: String? = null,
    ) = RelayEvent("$session-e$seq", seq, "k$seq", kind, text, title, toolKind, status, origin, commandId, fromLabel, at)

    const val STREAMING_TEXT = "So far **12 of 20** runs passed and none failed. The slowest reconnect took `612 ms`, " +
        "well inside the new 5 s wait. Waiting for the last eight runs…"

    fun runningEvents(now: Long): List<RelayEvent> {
        val s = RUNNING_SESSION
        val yesterday = now - DAY - 2 * HOUR
        return listOf(
            event(s, 1, EventKind.USER, "The `relay_reconnect` test fails about one run in ten on CI. Can you find out why?", yesterday, origin = "local"),
            event(
                s, 2, EventKind.THOUGHT,
                "The test sleeps for a fixed time before asserting that the client reconnected. On a loaded CI machine the " +
                    "backoff can take longer than that sleep.",
                yesterday + 20_000,
            ),
            event(
                s, 3, EventKind.TOOL,
                "$ cargo test -p crok-remote relay_reconnect\ntest relay_reconnect ... FAILED\nassertion failed: client.is_connected()",
                yesterday + 45_000, title = "Run cargo test -p crok-remote relay_reconnect", toolKind = "execute", status = "completed",
            ),
            event(
                s, 4, EventKind.TOOL, "crates/codegen/crok-remote/src/socket.rs",
                yesterday + 60_000, title = "Read socket.rs", toolKind = "read", status = "completed",
            ),
            event(
                s, 5, EventKind.ASSISTANT,
                "Found it. The test sleeps **500 ms** and then asserts, but the reconnect backoff starts at `250 ms` and " +
                    "doubles, so a second attempt lands at *750 ms*.\n\nI'll make the test wait for the connection instead:\n\n" +
                    "```rust\nclient.wait_connected(Duration::from_secs(5)).await?;\n```\n\n- no fixed sleep\n- fails fast with a clear message",
                yesterday + 90_000,
            ),
            event(
                s, 6, EventKind.TOOL,
                "- tokio::time::sleep(Duration::from_millis(500)).await;\n+ client.wait_connected(Duration::from_secs(5)).await?;",
                yesterday + 110_000, title = "Edit crates/codegen/crok-remote/src/socket.rs", toolKind = "edit", status = "completed",
            ),
            event(s, 7, EventKind.SYSTEM, "", yesterday + 115_000, status = "end_turn"),
            event(s, 8, EventKind.USER, "Run it 20 times to be sure", now - 6 * MIN, origin = "remote", commandId = "demo-cmd-1", fromLabel = PHONE_NAME),
            event(
                s, 9, EventKind.TOOL, "running 20 iterations…\n12/20 passed",
                now - 5 * MIN, title = "Run cargo test -p crok-remote relay_reconnect (20×)", toolKind = "execute", status = "in_progress",
            ),
            event(s, 10, EventKind.ASSISTANT, STREAMING_TEXT, now - MIN),
        )
    }

    fun waitingEvents(now: Long): List<RelayEvent> {
        val s = WAITING_SESSION
        return listOf(
            event(s, 1, EventKind.USER, "Add a dark mode to the settings page, following the system setting.", now - 20 * MIN, origin = "local"),
            event(
                s, 2, EventKind.TOOL, "src/styles/settings.css", now - 15 * MIN,
                title = "Edit src/styles/settings.css", toolKind = "edit", status = "completed",
            ),
            event(s, 3, EventKind.ASSISTANT, "The theme follows `prefers-color-scheme` now. Run `npm run build` to check the new theme?", now - 4 * MIN),
        )
    }
}
