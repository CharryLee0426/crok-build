package dev.chenli.crok.mobile.screenshots

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import dev.chenli.crok.mobile.auth.PendingSignIn
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.SessionInfoResult
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.SessionListState
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.logic.OptimisticPrompt
import dev.chenli.crok.mobile.logic.SessionFilter
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.SessionCommands
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.logic.BotCard
import dev.chenli.crok.mobile.logic.BotCardKind
import dev.chenli.crok.mobile.logic.BotCardProblem
import dev.chenli.crok.mobile.ui.HomeScaffold
import dev.chenli.crok.mobile.ui.common.GlassLevel
import dev.chenli.crok.mobile.ui.common.LocalGlassLevel
import dev.chenli.crok.mobile.ui.session.NewSessionTarget
import dev.chenli.crok.mobile.ui.session.InfoRefresh
import dev.chenli.crok.mobile.ui.session.SessionActions
import dev.chenli.crok.mobile.ui.session.SessionContent
import dev.chenli.crok.mobile.ui.session.SessionInfoActions
import dev.chenli.crok.mobile.ui.session.SessionInfoContent
import dev.chenli.crok.mobile.ui.session.SessionUiState
import dev.chenli.crok.mobile.ui.sessions.SessionsActions
import dev.chenli.crok.mobile.ui.sessions.SessionsContent
import dev.chenli.crok.mobile.ui.sessions.SessionsUiState
import dev.chenli.crok.mobile.ui.settings.DevicesActions
import dev.chenli.crok.mobile.ui.settings.DevicesContent
import dev.chenli.crok.mobile.ui.settings.DevicesUiState
import dev.chenli.crok.mobile.ui.settings.LinkActions
import dev.chenli.crok.mobile.ui.settings.LinkComputerContent
import dev.chenli.crok.mobile.ui.settings.LinkStep
import dev.chenli.crok.mobile.ui.settings.SettingsActions
import dev.chenli.crok.mobile.ui.settings.SettingsContent
import dev.chenli.crok.mobile.ui.settings.SettingsUiState
import dev.chenli.crok.mobile.ui.signin.WaitingScreen
import dev.chenli.crok.mobile.ui.signin.WaitingUiState
import dev.chenli.crok.mobile.ui.signin.WelcomeScreen
import dev.chenli.crok.mobile.ui.signin.WelcomeUiState
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.TimeZone
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Pictures of the main screens, rendered on the JVM (Robolectric native graphics) from the demo data. They are written
 * only when recording: `./gradlew :app:recordRoborazziDebug` → app/build/outputs/roborazzi/.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = RobolectricDeviceQualifiers.Pixel7)
class ScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val zone: ZoneId = ZoneOffset.UTC
    private val now = LocalDateTime.of(2026, 10, 15, 15, 42).toInstant(ZoneOffset.UTC).toEpochMilli()

    @Before
    fun fixedZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    private fun shoot(name: String, dark: Boolean = false, glass: GlassLevel = GlassLevel.Liquid, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CrokTheme(dark = dark) {
                CompositionLocalProvider(LocalGlassLevel provides glass) {
                    Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) { content() }
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    /** The demo list as `sessions:groups` sends it: projects on two online computers and an offline one. */
    private fun sessionsState(
        connection: ConnectionState = ConnectionState.Connected,
        filter: SessionFilter = SessionFilter.All,
        query: String = "",
        collapsed: Set<String> = emptySet(),
        reordering: Boolean = false,
        reorderProject: String? = null,
    ): SessionsUiState {
        val groups = DemoData.groups(DemoData.state(now))
        return SessionsUiState.build(
            SessionListState(groups, live = true), null, filter, query, connection, now, collapsed,
            reordering = reordering, reorderProject = reorderProject,
        )
    }

    private fun runningSession(): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.RUNNING_SESSION }
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(DemoData.runningEvents(now).sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = DemoData.state(now).commands.map { it.prompt() },
            optimistic = listOf(OptimisticPrompt("local-1", "Then run the whole crok-remote suite", now - 20_000)),
            connection = ConnectionState.Connected,
            zone = zone,
        )
    }

    /** The session waiting on a permission request; [answering]: this phone's answer is on its way. */
    private fun waitingSession(answering: Boolean = false): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.WAITING_SESSION }
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(DemoData.waitingEvents(now).sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = zone,
            answering = if (answering) DemoData.WAITING_REQUEST else null,
        )
    }

    /** A session listed from its computer's disk, opened before its history arrived. */
    private fun listedSession(id: String): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == id }
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(emptyList(), loaded = true, historyComplete = true),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = zone,
        )
    }

    @Test
    fun welcome() = shoot("01-welcome") {
        WelcomeScreen(WelcomeUiState(error = null, busy = false, demoAllowed = true), {}, {})
    }

    @Test
    fun waitingForApproval() = shoot("02-waiting") {
        WaitingScreen(
            WaitingUiState(
                PendingSignIn(
                    serverUrl = "https://happy-otter-123.convex.cloud",
                    deviceCode = "crd_demo",
                    userCode = "BCDF-GHJK",
                    verificationUrlComplete = "https://crok.example.com/link?code=BCDF-GHJK",
                    expiresAt = now + 9 * 60_000 + 41_000,
                    deviceName = "Pixel 9",
                ),
                offline = false,
            ),
            onOpenAgain = {},
            onCancel = {},
            now = { now },
        )
    }

    @Test
    fun sessionsLight() = shoot("03-sessions-light") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    fun sessionsDarkUpdating() = shoot("04-sessions-dark", dark = true) {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(ConnectionState.Updating), SessionsActions()) }
    }

    @Test
    fun sessionsEmpty() = shoot("05-sessions-empty") {
        HomeScaffold(tab = 0, onTab = {}) {
            SessionsContent(SessionsUiState.build(SessionListState(emptyList(), live = true), null, SessionFilter.All, "", ConnectionState.Connected, now), SessionsActions())
        }
    }

    @Test
    fun runningSessionLight() = shoot("06-session-running") {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun runningSessionDarkWithDraft() = shoot("07-session-running-dark", dark = true) {
        SessionContent(runningSession(), draft = "Also check the Linux runner", now = now, actions = SessionActions())
    }

    @Test
    fun sessionInfo() = shoot("08-session-info") {
        val detail = DemoData.sessions(now).first { it.id == DemoData.RUNNING_SESSION }.detail
        Box(Modifier.fillMaxSize().background(CrokTheme.colors.grouped)) {
            SessionInfoContent(
                detail = detail,
                refresh = InfoRefresh.Done(SessionInfoResult(model = "grok-code-fast-1", inputTokens = 184_800, outputTokens = 10_140, cachedTokens = 150_200, costUsd = 0.43, contextUsed = 64_210, contextWindow = 256_000)),
                now = now,
                actions = SessionInfoActions(),
            )
        }
    }

    @Test
    fun settings() = shoot("09-settings") {
        HomeScaffold(tab = 1, onTab = {}) {
            SettingsContent(
                SettingsUiState(
                    name = "Chen Li",
                    email = "chen@example.com",
                    imageUrl = null,
                    deviceName = "Pixel 9",
                    deviceCount = 5,
                    server = "https://happy-otter-123.convex.cloud",
                ),
                ThemeMode.System,
                SettingsActions(onLanguage = {}),
            )
        }
    }

    @Test
    fun devices() = shoot("10-devices") {
        DevicesContent(DevicesUiState(DemoData.devices(now)), now, DevicesActions())
    }

    @Test
    fun linkComputerConfirm() = shoot("11-link-confirm") {
        LinkComputerContent(
            code = "BCDF-GHJK",
            step = LinkStep.Confirm(PendingLogin("BCDF-GHJK", "computer", "Mac mini", "macOS 26.1", "crok 1.0.45", now - 30_000, now + 540_000)),
            now = now,
            actions = LinkActions(),
        )
    }

    @Test
    fun linkComputerEnter() = shoot("12-link-enter", dark = true) {
        LinkComputerContent(code = "BCDF-G", step = LinkStep.Enter(), now = now, actions = LinkActions())
    }

    // The same screens in other languages, to catch translations that do not fit.

    @Test
    @Config(qualifiers = "+ja")
    fun sessionsJapanese() = shoot("13-sessions-ja") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    @Config(qualifiers = "+zh-rCN")
    fun runningSessionChinese() = shoot("14-session-zh") {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+de")
    fun settingsGerman() = shoot("15-settings-de") {
        HomeScaffold(tab = 1, onTab = {}) {
            SettingsContent(
                SettingsUiState(
                    name = "Chen Li",
                    email = "chen@example.com",
                    imageUrl = null,
                    deviceName = "Pixel 9",
                    deviceCount = 5,
                    server = "https://happy-otter-123.convex.cloud",
                ),
                ThemeMode.Dark,
                SettingsActions(onLanguage = {}),
            )
        }
    }

    @Test
    @Config(qualifiers = "+fr")
    fun devicesFrench() = shoot("16-devices-fr", dark = true) {
        DevicesContent(DevicesUiState(DemoData.devices(now)), now, DevicesActions())
    }

    @Test
    @Config(qualifiers = "+es")
    fun waitingSpanish() = shoot("17-waiting-es") {
        WaitingScreen(
            WaitingUiState(
                PendingSignIn("https://r", "crd", "BCDF-GHJK", "https://crok.example.com/link?code=BCDF-GHJK", now + 300_000, deviceName = "Pixel 9"),
                offline = true,
            ),
            onOpenAgain = {},
            onCancel = {},
            now = { now },
        )
    }

    // Projects, Reorder mode and sessions listed from a computer's disk.

    /** The whole grouped list at once, on a tall screen. */
    @Test
    @Config(qualifiers = "+h1700dp")
    fun sessionsGroupedTall() = shoot("18-sessions-grouped") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(collapsed = setOf(DemoData.LINUX_INGEST)), SessionsActions()) }
    }

    @Test
    fun sessionsComputerTab() = shoot("19-sessions-computer-tab", dark = true) {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(filter = SessionFilter.Computer(DemoData.STUDIO_ID)), SessionsActions()) }
    }

    @Test
    fun sessionsReorderMode() = shoot("20-sessions-reorder") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(reordering = true), SessionsActions()) }
    }

    @Test
    fun sessionsReorderOneProject() = shoot("20b-sessions-reorder-project") {
        HomeScaffold(tab = 0, onTab = {}) {
            SessionsContent(sessionsState(reordering = true, reorderProject = DemoData.MACBOOK_CROK_SITE), SessionsActions())
        }
    }

    @Test
    fun sessionsSearch() = shoot("21-sessions-search") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(query = "release"), SessionsActions()) }
    }

    @Test
    fun listedSessionLoading() = shoot("22-session-history-loading") {
        SessionContent(listedSession(DemoData.CATALOG_SESSION), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun listedSessionOffline() = shoot("23-session-history-offline", dark = true) {
        SessionContent(listedSession(DemoData.OFFLINE_SESSION), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+de")
    fun sessionsReorderGerman() = shoot("24-sessions-reorder-de", dark = true) {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(reordering = true), SessionsActions()) }
    }

    // A permission request any device can answer.

    @Test
    fun permissionRequest() = shoot("25-session-permission") {
        SessionContent(waitingSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+fr")
    fun permissionRequestAnsweringFrench() = shoot("26-session-permission-answering-fr", dark = true) {
        SessionContent(waitingSession(answering = true), draft = "", now = now, actions = SessionActions())
    }

    // New sessions from the phone (relay/DESIGN.md §5, "New sessions").

    private val crokSite = NewSessionTarget(DemoData.MACBOOK_ID, "/Users/chen/code/crok-site", "MacBook Pro", "crok-site")

    private fun newSessionState(): SessionUiState = SessionUiState.build(
        row = null,
        detail = null,
        gone = false,
        transcript = TranscriptState(loaded = true, historyComplete = true),
        prompts = emptyList(),
        optimistic = emptyList(),
        connection = ConnectionState.Connected,
        zone = zone,
        newSession = crokSite,
    )

    /** Right after the first prompt: the session exists on the relay and its computer is opening it. */
    private fun startingSessionState(): SessionUiState {
        val detail = SessionDetail(
            id = "demo-new-1", sessionId = "pending:client-new", title = "Fix the footer links", cwd = crokSite.path,
            status = SessionStatus.RUNNING, online = false, deviceId = DemoData.MACBOOK_ID, deviceName = "MacBook Pro",
            deviceOnline = true, createdAt = now, lastActivityAt = now, projectKey = DemoData.MACBOOK_CROK_SITE,
            projectPath = crokSite.path, projectName = "crok-site", starting = true, models = DemoData.macbookModels,
            model = "grok-code-fast-1", effort = "medium",
        )
        val create = PromptCommand(
            "cmd-new", "client-new", "Fix the footer links: two of them point at the old docs domain.", CommandStatus.PENDING, null,
            "Pixel 9", DemoData.PHONE_ID, mine = true, createdAt = now - 2_000, updatedAt = now - 2_000, type = CommandType.CREATE,
        )
        return SessionUiState.build(
            row = null, detail = detail, gone = false, transcript = TranscriptState(loaded = true, historyComplete = true),
            prompts = listOf(create), optimistic = emptyList(), connection = ConnectionState.Connected, zone = zone,
        )
    }

    @Test
    fun newSessionScreen() = shoot("27-new-session") {
        SessionContent(newSessionState(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun newSessionScreenDark() = shoot("28-new-session-dark", dark = true) {
        SessionContent(newSessionState(), draft = "Fix the footer links", now = now, actions = SessionActions())
    }

    @Test
    fun startingSession() = shoot("29-session-starting") {
        SessionContent(startingSessionState(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun projectPicker() = shoot("30-new-session-picker") {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(), SessionsActions(), pickerInitiallyOpen = true) }
    }

    @Test
    fun projectPickerDark() = shoot("31-new-session-picker-dark", dark = true) {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(), SessionsActions(), pickerInitiallyOpen = true) }
    }

    @Test
    fun startingRowInTheList() = shoot("32-sessions-starting-row") {
        val groups = DemoData.groups(DemoData.state(now)).map { group ->
            if (group.key != DemoData.MACBOOK_CROK_SITE) {
                group
            } else {
                val starting = group.sessions.first().copy(
                    id = "demo-new-1", title = "Fix the footer links", starting = true, online = false, status = SessionStatus.RUNNING,
                    unread = 0, pinned = false, preview = null, lastActivityAt = now,
                )
                group.copy(sessions = listOf(starting) + group.sessions)
            }
        }
        HomeScaffold(tab = 0, onTab = {}) {
            SessionsContent(SessionsUiState.build(SessionListState(groups, live = true), null, SessionFilter.All, "", ConnectionState.Connected, now), SessionsActions())
        }
    }

    // Commands in the composer (relay/DESIGN.md §5): the Menu button, the command list, bot cards.

    private fun commandSession(cards: List<BotCard> = emptyList(), sessionId: String = DemoData.RUNNING_SESSION, models: Boolean = true): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == sessionId }
        val detail = session.detail.copy(models = if (models) DemoData.modelsFor(session.detail.deviceId) else null)
        return SessionUiState.build(
            row = session.row(),
            detail = detail,
            gone = false,
            transcript = TranscriptState(
                if (sessionId == DemoData.RUNNING_SESSION) DemoData.runningEvents(now).sortedByDescending { it.seq } else emptyList(),
                loaded = true,
                historyComplete = true,
            ),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = zone,
            commands = SessionCommands(DemoData.slashCommands, "session"),
            cards = cards,
        )
    }

    @Test
    fun commandMenu() = shoot("33-composer-menu") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), menuInitiallyOpen = true)
    }

    @Test
    fun commandMenuDark() = shoot("34-composer-menu-dark", dark = true) {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), menuInitiallyOpen = true)
    }

    @Test
    fun commandListFiltered() = shoot("35-composer-slash-filter") {
        SessionContent(commandSession(), draft = "/re", now = now, actions = SessionActions())
    }

    @Test
    fun modelCard() = shoot("36-bot-card-model") {
        SessionContent(commandSession(listOf(BotCard("card-1", BotCardKind.Model, now - 5_000))), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun thinkCardApplyingAndModelDoneDark() = shoot("37-bot-cards-dark", dark = true) {
        val cards = listOf(
            BotCard("card-1", BotCardKind.Model, now - 60_000, done = "Grok Code Fast"),
            BotCard("card-2", BotCardKind.Think, now - 5_000, applying = "high"),
        )
        SessionContent(commandSession(cards), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun cardsWithoutChoices() = shoot("38-bot-card-no-models") {
        // The Studio's crok is too old to offer models; a typo on top.
        val cards = listOf(
            BotCard("card-1", BotCardKind.Model, now - 60_000),
            BotCard("card-2", BotCardKind.Think, now - 5_000, problem = BotCardProblem.NoMatch("maximum")),
        )
        SessionContent(commandSession(cards, sessionId = "demo-s3", models = false), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+ja")
    fun commandMenuJapanese() = shoot("39-composer-menu-ja") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), menuInitiallyOpen = true)
    }

    @Test
    @Config(qualifiers = "+de")
    fun modelCardGerman() = shoot("40-bot-card-model-de", dark = true) {
        SessionContent(commandSession(listOf(BotCard("card-1", BotCardKind.Think, now - 5_000))), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+fr")
    fun newSessionFrench() = shoot("41-new-session-fr") {
        SessionContent(newSessionState(), draft = "", now = now, actions = SessionActions())
    }

    // Liquid Glass where the device has no backdrop shaders (Android 11 and older): a frosted surface.

    @Test
    fun frostedFallback() = shoot("42-sessions-frosted-fallback", glass = GlassLevel.Tinted) {
        HomeScaffold(tab = 0, onTab = {}) { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    fun frostedFallbackSessionDark() = shoot("43-session-frosted-fallback-dark", dark = true, glass = GlassLevel.Tinted) {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }
}
