package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.auth.StoredCredentials
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.EffortChoice
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.HistoryState
import dev.chenli.crok.mobile.data.Me
import dev.chenli.crok.mobile.data.MeDevice
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.PendingInteraction
import dev.chenli.crok.mobile.data.PendingOption
import dev.chenli.crok.mobile.data.PlanEntry
import dev.chenli.crok.mobile.data.PlanProgress
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.data.SessionUsage
import dev.chenli.crok.mobile.data.SlashCommand
import dev.chenli.crok.mobile.logic.SessionList

/** A session in the demo relay: its detail plus the list-only fields and its hand-placed position. */
data class DemoSession(
    val detail: SessionDetail,
    val preview: String?,
    val previewKind: String?,
    val unread: Int,
    val position: Int? = null,
) {
    val id: String get() = detail.id
    val projectKey: String get() = detail.projectKey

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
        projectKey = detail.projectKey,
        projectPath = detail.projectPath,
        projectName = detail.projectName,
        historyState = detail.historyState,
        starting = detail.starting,
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
        PromptCommand(
            id, clientId, text, status, error, fromLabel, fromDeviceId,
            mine = fromDeviceId == DemoData.PHONE_ID, createdAt = createdAt, updatedAt = updatedAt, type = type,
        )
}

data class DemoState(
    val me: Me,
    val devices: List<Device>,
    val sessions: List<DemoSession>,
    val events: Map<String, List<RelayEvent>>,
    val commands: List<DemoCommand>,
    /** Hand-placed project positions by project key (none until someone reorders). */
    val projectPositions: Map<String, Int> = emptyMap(),
    val revoked: Boolean = false,
)

/**
 * The demo account: three computers, a phone, and sessions in every state the screens draw (running with a plan,
 * waiting on a permission request any device can answer, idle, offline, archived, listed from disk with the history
 * still on the computer), in several projects on two computers. Used by demo mode (`crokDemo=true`) and by the
 * screenshot tests.
 */
object DemoData {
    const val PHONE_ID = "demo-phone"
    const val PHONE_NAME = "Pixel 9"
    const val MACBOOK_ID = "demo-macbook"
    const val STUDIO_ID = "demo-studio"
    const val LINUX_ID = "demo-linux"
    const val RUNNING_SESSION = "demo-s1"

    /** Waits on [WAITING_REQUEST]: crok asks to run `npm run build`. */
    const val WAITING_SESSION = "demo-s2"

    /** A reply using every Markdown feature the apps render (relay/scripts/markdown-showcase.md). */
    const val SHOWCASE_SESSION = "demo-s7"
    const val WAITING_REQUEST = "demo-request-1"

    /** Listed from the MacBook's disk, never opened on the relay: opening it loads the history from the computer. */
    const val CATALOG_SESSION = "demo-s8"

    /** On the Linux box, which is offline: its history cannot load until crok runs there. */
    const val OFFLINE_SESSION = "demo-s5"

    const val MACBOOK_CROK_BUILD = "$MACBOOK_ID:/Users/chen/code/crok-build"
    const val MACBOOK_CROK_SITE = "$MACBOOK_ID:/Users/chen/code/crok-site"
    const val STUDIO_CROK_BUILD = "$STUDIO_ID:/Users/chen/code/crok-build"
    const val LINUX_INGEST = "$LINUX_ID:/home/chen/services/ingest"

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
        events = mapOf(
            RUNNING_SESSION to runningEvents(now),
            WAITING_SESSION to waitingEvents(now),
            SHOWCASE_SESSION to showcaseEvents(now),
        ),
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
        Device(MACBOOK_ID, "computer", "MacBook Pro", "macOS 26.1", "Crok Desktop 1.5.0", now - 40 * DAY, now - 2 * MIN, true, false, 3),
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

    private data class Computer(val id: String, val name: String, val platform: String, val online: Boolean)

    private val macbook = Computer(MACBOOK_ID, "MacBook Pro", "macOS 26.1", true)
    private val studio = Computer(STUDIO_ID, "Studio", "macOS 26.0", true)
    private val linux = Computer(LINUX_ID, "Linux box", "Ubuntu 24.04", false)

    private fun session(
        id: String,
        title: String,
        computer: Computer,
        project: String,
        cwd: String = project,
        lastActivityAt: Long,
        createdAt: Long = lastActivityAt - 2 * HOUR,
        online: Boolean = computer.online,
        status: String = SessionStatus.IDLE,
        app: String = "tui",
        model: String? = "grok-code-fast-1",
        effort: String? = null,
        gitBranch: String? = null,
        plan: List<PlanEntry> = emptyList(),
        usage: SessionUsage? = null,
        pinned: Boolean = false,
        archived: Boolean = false,
        historyState: String? = null,
        eventSeq: Long = 0,
        pending: PendingInteraction? = null,
        preview: String?,
        previewKind: String? = EventKind.ASSISTANT,
        unread: Int = 0,
    ) = DemoSession(
        SessionDetail(
            id = id,
            sessionId = "0199e2e0-11aa-7c00-8d00-" + id.filter { it.isDigit() }.padStart(12, '0'),
            title = title,
            cwd = cwd,
            model = model,
            effort = effort,
            gitBranch = gitBranch,
            status = status,
            online = online,
            app = app,
            deviceId = computer.id,
            deviceName = computer.name,
            devicePlatform = computer.platform,
            deviceOnline = computer.online,
            createdAt = createdAt,
            lastActivityAt = lastActivityAt,
            plan = plan,
            usage = usage,
            pinned = pinned,
            archived = archived,
            eventSeq = eventSeq,
            projectKey = "${computer.id}:$project",
            projectPath = project,
            projectName = SessionList.folderName(project),
            historyState = historyState,
            pending = pending,
        ),
        preview = preview,
        previewKind = previewKind,
        unread = unread,
    )

    fun sessions(now: Long): List<DemoSession> {
        val crokBuild = "/Users/chen/code/crok-build"
        val crokSite = "/Users/chen/code/crok-site"
        return listOf(
            session(
                RUNNING_SESSION, "Fix the flaky relay reconnect test", macbook, crokBuild,
                lastActivityAt = now - MIN, createdAt = now - DAY - 3 * HOUR,
                status = SessionStatus.RUNNING, app = "desktop", effort = "medium", gitBranch = "fix/relay-reconnect-flake",
                plan = runningPlan, usage = SessionUsage(182_400, 9_830, 150_200, 2_100, 0.42, 61_500, 256_000), eventSeq = 12,
                preview = "So far 12 of 20 runs passed, none failed.", unread = 2,
            ).let { it.copy(detail = it.detail.copy(sessionId = "0199e2e0-7a1c-7b4e-9f00-5c1d2e3f4a5b")) },
            session(
                WAITING_SESSION, "Add dark mode to the settings page", macbook, crokSite,
                lastActivityAt = now - 4 * MIN, status = SessionStatus.WAITING, model = "claude-sonnet-4-5", effort = "high",
                gitBranch = "dark-settings", usage = SessionUsage(40_100, 3_200, 31_000, null, 0.18, 22_000, 200_000),
                pinned = true, eventSeq = 4, pending = buildRequest(now), preview = "Run npm run build to check the new theme?", unread = 1,
            ),
            session(
                SHOWCASE_SESSION, "Render every Markdown feature", macbook, crokBuild,
                cwd = "$crokBuild/.claude/worktrees/mobile-markdown", lastActivityAt = now - 25 * MIN, gitBranch = "mobile-markdown",
                eventSeq = 3, preview = "Markdown showcase: text, code, tables and math.", unread = 1,
            ),
            session(
                CATALOG_SESSION, "Plan the 1.6 release", macbook, crokBuild,
                lastActivityAt = now - 2 * DAY - 3 * HOUR, online = false, model = "grok-4", historyState = HistoryState.NONE,
                preview = "Three milestones: remote control, projects, then notifications.",
            ),
            session(
                "demo-s9", "Why is cargo test slow on CI?", macbook, crokBuild,
                lastActivityAt = now - 3 * DAY - 5 * HOUR, online = false, historyState = HistoryState.NONE,
                preview = "Most of the time goes to linking; sccache would help.",
            ),
            session(
                "demo-s10", "Bump Kotlin to 2.4.21", macbook, crokBuild,
                cwd = "$crokBuild/mobile/Android", lastActivityAt = now - 5 * DAY, online = false, historyState = HistoryState.NONE,
                preview = "Done. Compose 1.12 waits for compileSdk 37.",
            ),
            session(
                "demo-s11", "Translate the release notes", macbook, crokBuild,
                lastActivityAt = now - 8 * DAY, online = false, historyState = HistoryState.NONE,
                preview = "All five languages are in dist/v1.4.1/notes.", previewKind = EventKind.ASSISTANT,
            ),
            session(
                "demo-s12", "Fix the broken docs links", macbook, crokSite,
                lastActivityAt = now - 9 * DAY, online = false, historyState = HistoryState.NONE,
                preview = "check the links again", previewKind = EventKind.USER,
            ),
            session(
                "demo-s3", "Refactor relay pagination", studio, crokBuild,
                cwd = "$crokBuild/relay", lastActivityAt = now - 35 * MIN, createdAt = now - 5 * HOUR,
                preview = "ship it", previewKind = EventKind.USER,
            ),
            session(
                "demo-s4", "Write the 1.5 release notes", studio, crokBuild,
                lastActivityAt = now - DAY - 2 * HOUR, createdAt = now - DAY - 6 * HOUR, app = "desktop", model = "grok-4",
                preview = "The notes are in dist/v1.5.0/notes, in six languages.", unread = 1,
            ),
            session(
                OFFLINE_SESSION, "Investigate the memory spike in ingest", linux, "/home/chen/services/ingest",
                lastActivityAt = now - 3 * DAY, createdAt = now - 4 * DAY, historyState = HistoryState.NONE,
                preview = "The leak is in the batch buffer: it never shrinks after a burst.",
            ),
            session(
                "demo-s6", "Try Kotlin 2.4", studio, "/Users/chen/code/scratch",
                lastActivityAt = now - 12 * DAY, createdAt = now - 13 * DAY, online = false, model = null, archived = true,
                preview = "Everything compiles; two deprecation warnings left.",
            ),
        )
    }

    /** The list as the relay's `sessions:groups` builds it (relay/convex/lib/projects.ts `buildGroups`). */
    fun groups(state: DemoState): List<SessionGroup> {
        val byKey = LinkedHashMap<String, MutableList<DemoSession>>()
        state.sessions.filter { !it.detail.archived }
            .sortedByDescending { it.detail.lastActivityAt }
            .forEach { byKey.getOrPut(it.projectKey) { mutableListOf() } += it }
        val sessionOrder = compareByDescending<DemoSession> { it.detail.pinned }
            .then(byPlace({ it.position }, { it.detail.lastActivityAt }))
        val groups = byKey.map { (key, sessions) ->
            val first = sessions.first().detail
            SessionGroup(
                key = key,
                deviceId = first.deviceId,
                deviceName = first.deviceName,
                deviceOnline = first.deviceOnline,
                path = first.projectPath,
                name = first.projectName,
                placed = state.projectPositions[key] != null,
                lastActivityAt = sessions.maxOf { it.detail.lastActivityAt },
                sessions = sessions.sortedWith(sessionOrder).map { it.row() },
            )
        }
        return groups.sortedWith(byPlace({ state.projectPositions[it.key] }, { it.lastActivityAt }))
    }

    /** Never placed first, most recent first; then placed ones by position. */
    private fun <T> byPlace(position: (T) -> Int?, activity: (T) -> Long): Comparator<T> = Comparator { a, b ->
        val pa = position(a)
        val pb = position(b)
        when {
            (pa == null) != (pb == null) -> if (pa == null) -1 else 1
            pa != null && pb != null && pa != pb -> pa.compareTo(pb)
            else -> activity(b).compareTo(activity(a))
        }
    }

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
                s, 5, EventKind.TOOL, "error: unused variable: `backoff`",
                yesterday + 75_000, title = "Run `cargo clippy -p crok-remote -- -D warnings`", toolKind = "execute", status = "failed",
            ),
            event(
                s, 6, EventKind.ASSISTANT,
                "Found it. The test sleeps **500 ms** and then asserts, but the reconnect backoff starts at `250 ms` and " +
                    "doubles, so a second attempt lands at *750 ms*.\n\nI'll make the test wait for the connection instead:\n\n" +
                    "```rust\nclient.wait_connected(Duration::from_secs(5)).await?;\n```\n\n- no fixed sleep\n- fails fast with a clear message",
                yesterday + 90_000,
            ),
            event(
                s, 7, EventKind.TOOL,
                "- tokio::time::sleep(Duration::from_millis(500)).await;\n+ client.wait_connected(Duration::from_secs(5)).await?;",
                yesterday + 110_000, title = "Edit crates/codegen/crok-remote/src/socket.rs", toolKind = "edit", status = "completed",
            ),
            // Stopped with its turn: still `in_progress`, but the turn ended after it.
            event(
                s, 8, EventKind.TOOL, "",
                yesterday + 112_000, title = "Run `cargo bench -p crok-remote`", toolKind = "execute", status = "in_progress",
            ),
            event(s, 9, EventKind.SYSTEM, "", yesterday + 115_000, status = "cancelled"),
            event(s, 10, EventKind.USER, "Run it 20 times to be sure", now - 6 * MIN, origin = "remote", commandId = "demo-cmd-1", fromLabel = PHONE_NAME),
            event(
                s, 11, EventKind.TOOL, "running 20 iterations…\n12/20 passed",
                now - 5 * MIN, title = "Run cargo test -p crok-remote relay_reconnect (20×)", toolKind = "execute", status = "in_progress",
            ),
            event(s, 12, EventKind.ASSISTANT, STREAMING_TEXT, now - MIN),
        )
    }

    /**
     * The shared Markdown showcase, verbatim: a copy of relay/scripts/markdown-showcase.md kept in the app's Java
     * resources (DemoDataTest checks the two are identical).
     */
    val markdownShowcase: String by lazy {
        DemoData::class.java.getResourceAsStream("/demo/markdown-showcase.md")!!.use { it.readBytes().decodeToString() }
    }

    fun showcaseEvents(now: Long): List<RelayEvent> {
        val s = SHOWCASE_SESSION
        val at = now - 25 * MIN
        return listOf(
            event(s, 1, EventKind.USER, "Show me every Markdown feature the phone can render.", at - 2 * MIN, origin = "local"),
            event(s, 2, EventKind.ASSISTANT, markdownShowcase, at),
            event(s, 3, EventKind.SYSTEM, "", at + 1_000, status = "end_turn"),
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
            event(s, 3, EventKind.ASSISTANT, "The theme follows `prefers-color-scheme` now. I'll build the site to check it.", now - 4 * MIN),
            event(
                s, 4, EventKind.TOOL, "$ npm run build", now - 4 * MIN + 2_000,
                title = "Run npm run build", toolKind = "execute", status = "pending",
            ),
        )
    }

    /** What [WAITING_SESSION] waits on: permission to run its pending tool call. */
    fun buildRequest(now: Long) = PendingInteraction(
        id = WAITING_REQUEST,
        title = "Run npm run build",
        detail = "npm run build\n# in /Users/chen/code/crok-site",
        toolKind = "execute",
        options = listOf(
            PendingOption("allow", "Allow", "allow_once"),
            PendingOption("allow-always", "Always allow", "allow_always"),
            PendingOption("reject", "Reject", "reject_once"),
        ),
        at = now - 4 * MIN + 2_000,
    )

    /**
     * What the MacBook's crok can run (`devices:models`, and `sessions:get` → `models`), in picker order: its default
     * and its own models (ids without a provider prefix), its DeepSeek key's, then OpenRouter's — some with thinking
     * levels, some without. The Studio runs an older crok that publishes none (and cannot start sessions for other
     * devices); the Linux box is offline.
     */
    val macbookModels: List<ModelChoice> = listOf(
        ModelChoice(
            id = "grok-code-fast-1",
            name = "Grok Code Fast",
            description = "Quick edits and tool calls",
            efforts = listOf(
                EffortChoice("low", "Low", value = "low"),
                EffortChoice("medium", "Medium", value = "medium"),
                EffortChoice("high", "High", value = "high"),
            ),
            defaultEffort = "medium",
        ),
        ModelChoice(
            id = "grok-4",
            name = "Grok 4",
            description = "Hard problems, long plans",
            efforts = listOf(
                EffortChoice("low", "Low", value = "low"),
                EffortChoice("medium", "Medium", value = "medium"),
                EffortChoice("high", "High", value = "high"),
                EffortChoice("xhigh", "Extra high", value = "xhigh"),
            ),
            defaultEffort = "high",
        ),
        ModelChoice(id = "claude-sonnet-4-5", name = "Claude Sonnet 4.5", description = "Through your Anthropic key"),
        ModelChoice(id = "deepseek/deepseek-chat", name = "DeepSeek V3.2", description = "DeepSeek's general model"),
        ModelChoice(
            id = "deepseek/deepseek-reasoner",
            name = "DeepSeek V3.2 Reasoner",
            description = "Thinks before it answers",
            efforts = listOf(EffortChoice("low", "Low", value = "low"), EffortChoice("high", "High", value = "high")),
            defaultEffort = "high",
        ),
        ModelChoice(
            id = "openrouter/google/gemini-2.5-pro",
            name = "Gemini 2.5 Pro",
            description = "Google's model, through OpenRouter",
            efforts = listOf(
                EffortChoice("low", "Low", value = "low"),
                EffortChoice("medium", "Medium", value = "medium"),
                EffortChoice("high", "High", value = "high"),
            ),
            defaultEffort = "medium",
        ),
        ModelChoice(id = "openrouter/moonshotai/kimi-k2", name = "Kimi K2", description = "Moonshot's agentic coding model, through OpenRouter"),
        ModelChoice(id = "openrouter/qwen/qwen3-coder", name = "Qwen3 Coder", description = "Alibaba's coding model, through OpenRouter"),
    )

    /** Models by computer: only computers whose crok publishes them. */
    fun modelsFor(deviceId: String): List<ModelChoice>? = if (deviceId == MACBOOK_ID) macbookModels else null

    /** Computers that can open sessions for other devices (`sessions:create`, `commands:setConfig`). */
    fun canCreate(deviceId: String): Boolean = deviceId == MACBOOK_ID

    /** The slash commands crok advertises for a session (`sessions:commands`). */
    val slashCommands: List<SlashCommand> = listOf(
        SlashCommand("compact", "Summarize the conversation to free up context"),
        SlashCommand("context", "Show what fills the context window"),
        SlashCommand("memory", "Edit the memory files crok reads"),
        SlashCommand("review-pr", "Review a pull request", hint = "<number>"),
        SlashCommand("release-notes", "Write release notes in six languages", hint = "<version>"),
    )

    /** What a computer pushes for a listed session someone opened: the last turn, read from its disk. */
    fun historyFromDisk(session: DemoSession): List<RelayEvent> {
        val s = session.id
        val at = session.detail.lastActivityAt
        return listOf(
            event(s, 1, EventKind.USER, session.detail.title, at - 4 * MIN, origin = "local"),
            event(s, 2, EventKind.ASSISTANT, session.preview ?: "Done.", at),
            event(s, 3, EventKind.SYSTEM, "", at + 1_000, status = "end_turn"),
        )
    }
}
