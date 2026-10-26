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
import dev.chenli.crok.mobile.engine.TranscriptState
import dev.chenli.crok.mobile.logic.OptimisticPrompt
import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.SessionCommands
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionStatus
import dev.chenli.crok.mobile.logic.BotCard
import dev.chenli.crok.mobile.logic.BotCardKind
import dev.chenli.crok.mobile.logic.BotCardProblem
import dev.chenli.crok.mobile.ui.AccountInfo
import dev.chenli.crok.mobile.ui.ComputerState
import dev.chenli.crok.mobile.ui.HomeScaffold
import dev.chenli.crok.mobile.ui.HomeTabsUi
import dev.chenli.crok.mobile.ui.common.GlassLevel
import dev.chenli.crok.mobile.ui.common.LocalGlassLevel
import dev.chenli.crok.mobile.logic.SetupChange
import dev.chenli.crok.mobile.logic.SetupChoice
import dev.chenli.crok.mobile.ui.session.InfoSetup
import dev.chenli.crok.mobile.ui.session.NewSessionTarget
import dev.chenli.crok.mobile.ui.session.InfoRefresh
import dev.chenli.crok.mobile.ui.session.SetupPickers
import dev.chenli.crok.mobile.ui.session.SessionActions
import dev.chenli.crok.mobile.ui.session.SessionContent
import dev.chenli.crok.mobile.ui.session.SessionInfoActions
import dev.chenli.crok.mobile.ui.session.SessionInfoContent
import dev.chenli.crok.mobile.ui.session.SessionUiState
import dev.chenli.crok.mobile.ui.sessions.ArchivedContent
import dev.chenli.crok.mobile.ui.sessions.ArchivedUiState
import dev.chenli.crok.mobile.ui.sessions.ProjectActions
import dev.chenli.crok.mobile.ui.sessions.ProjectContent
import dev.chenli.crok.mobile.ui.sessions.ProjectUiState
import dev.chenli.crok.mobile.ui.sessions.SessionsActions
import dev.chenli.crok.mobile.ui.sessions.SessionsContent
import dev.chenli.crok.mobile.ui.sessions.SessionsUiState
import dev.chenli.crok.mobile.ui.sessions.TopicActions
import dev.chenli.crok.mobile.ui.settings.AppearanceActions
import dev.chenli.crok.mobile.ui.settings.AppearanceContent
import dev.chenli.crok.mobile.ui.settings.AppearanceUiState
import dev.chenli.crok.mobile.ui.settings.DevicesActions
import dev.chenli.crok.mobile.ui.settings.DevicesContent
import dev.chenli.crok.mobile.ui.settings.DevicesUiState
import dev.chenli.crok.mobile.ui.settings.LinkActions
import dev.chenli.crok.mobile.ui.settings.LinkComputerContent
import dev.chenli.crok.mobile.ui.settings.LinkStep
import dev.chenli.crok.mobile.ui.settings.ProfileActions
import dev.chenli.crok.mobile.ui.settings.ProfileContent
import dev.chenli.crok.mobile.ui.settings.ProfileUiState
import dev.chenli.crok.mobile.ui.theme.LocalSessionAppearance
import dev.chenli.crok.mobile.ui.theme.SessionAppearance
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

    private fun shoot(
        name: String,
        dark: Boolean = false,
        glass: GlassLevel = GlassLevel.Liquid,
        appearance: SessionAppearance = SessionAppearance(),
        content: @Composable () -> Unit,
    ) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CrokTheme(dark = dark) {
                CompositionLocalProvider(LocalGlassLevel provides glass, LocalSessionAppearance provides appearance) {
                    Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) { content() }
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    private val demo get() = DemoData.state(now)
    private val account = AccountInfo("Chen Li", "chen@example.com", null)

    /** The person's computers as the relay lists them, with [selected] (default: the most recently active, MacBook Pro). */
    private fun computers(selected: String? = null, groups: List<dev.chenli.crok.mobile.data.SessionGroup> = DemoData.groups(demo)) =
        ComputerState.build(groups, listed = true, devices = demo.devices, remembered = selected)

    /** The Sessions tab on the demo data: the selected computer's projects. */
    private fun sessionsState(
        connection: ConnectionState = ConnectionState.Connected,
        selected: String? = null,
        query: String = "",
        editing: Boolean = false,
        groups: List<dev.chenli.crok.mobile.data.SessionGroup> = DemoData.groups(demo),
    ): SessionsUiState {
        val archived = DemoData.sessions(now).filter { it.detail.archived }.map { it.row() }
        return SessionsUiState.build(computers(selected, groups), archived, query, connection, now, editing)
    }

    /** The home screen's tabs around [content], for the selected computer. */
    @Composable
    private fun Home(tab: Int = 0, selected: String? = null, menu: Int? = null, content: @Composable () -> Unit) {
        HomeScaffold(tab = tab, onTab = {}, ui = HomeTabsUi(account, computers(selected)), initialMenu = menu, content = content)
    }

    private fun projectState(key: String, reordering: Boolean = false) =
        ProjectUiState.build(DemoData.groups(demo), live = true, key, "", reordering, ConnectionState.Connected, now)

    private fun profileState(selected: String? = null) = ProfileUiState(
        account = account,
        computers = computers(selected).computers,
        selectedId = computers(selected).selectedId,
        deviceCount = 5,
        version = "1.0 (1)",
    )

    /** What `devices:models` answers for [deviceId] (the demo computers' lists). */
    private fun deviceModels(deviceId: String) = Result.success(DemoData.modelsFor(deviceId))

    private fun runningSession(changing: SetupChange = SetupChange()): SessionUiState {
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
            deviceModels = deviceModels(session.detail.deviceId),
            changing = changing,
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
            deviceModels = deviceModels(session.detail.deviceId),
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
            deviceModels = deviceModels(session.detail.deviceId),
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
        Home { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    fun sessionsDarkUpdating() = shoot("04-sessions-dark", dark = true) {
        Home { SessionsContent(sessionsState(ConnectionState.Updating), SessionsActions()) }
    }

    @Test
    fun sessionsNoComputers() = shoot("05-sessions-empty") {
        val empty = ComputerState.build(emptyList(), listed = true, devices = emptyList(), remembered = null)
        HomeScaffold(tab = 0, onTab = {}, ui = HomeTabsUi(account, empty)) {
            SessionsContent(SessionsUiState.build(empty, emptyList(), "", ConnectionState.Connected, now), SessionsActions())
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
    fun profile() = shoot("09-profile") {
        Home(tab = 1) { ProfileContent(profileState(), ProfileActions(onLanguage = {})) }
    }

    @Test
    @Config(qualifiers = "+h1100dp")
    fun profileDarkTall() = shoot("09b-profile-dark", dark = true) {
        Home(tab = 1, selected = DemoData.STUDIO_ID) { ProfileContent(profileState(DemoData.STUDIO_ID), ProfileActions(onLanguage = {})) }
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
        Home { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    @Config(qualifiers = "+zh-rCN")
    fun runningSessionChinese() = shoot("14-session-zh") {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+de")
    fun profileGerman() = shoot("15-profile-de") {
        Home(tab = 1) { ProfileContent(profileState(), ProfileActions(onLanguage = {})) }
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

    // Computers as accounts, projects as groups, sessions as topics (mobile/DESIGN.md).

    /** A project's topics, on a tall screen so every session shows. */
    @Test
    @Config(qualifiers = "+h1100dp")
    fun projectScreen() = shoot("18-project") {
        Home { ProjectContent(projectState(DemoData.MACBOOK_CROK_BUILD), ProjectActions()) }
    }

    /** Studio: the Archived Sessions row, then its project (dark). */
    @Test
    fun sessionsOtherComputer() = shoot("19-sessions-studio", dark = true) {
        Home(selected = DemoData.STUDIO_ID) { SessionsContent(sessionsState(selected = DemoData.STUDIO_ID), SessionsActions()) }
    }

    @Test
    fun sessionsEditMode() = shoot("20-sessions-edit") {
        Home { SessionsContent(sessionsState(editing = true), SessionsActions()) }
    }

    @Test
    fun projectReorderMode() = shoot("20b-project-reorder") {
        Home { ProjectContent(projectState(DemoData.MACBOOK_CROK_BUILD, reordering = true), ProjectActions()) }
    }

    @Test
    fun sessionsSearch() = shoot("21-sessions-search") {
        Home { SessionsContent(sessionsState(query = "release"), SessionsActions()) }
    }

    @Test
    fun archived() = shoot("21b-archived") {
        val rows = DemoData.sessions(now).filter { it.detail.archived }.map { it.row() }
        Home(selected = DemoData.STUDIO_ID) { ArchivedContent(ArchivedUiState("Studio", rows, now), onBack = {}, actions = TopicActions()) }
    }

    /** Long press on Sessions: Mark All as Read. */
    @Test
    fun sessionsTabMenu() = shoot("44-tab-menu-mark-all-read") {
        Home(menu = 0) { SessionsContent(sessionsState(), SessionsActions()) }
    }

    /** Long press on Profile: the computer switcher (dark). */
    @Test
    fun profileTabSwitcher() = shoot("45-tab-menu-switcher-dark", dark = true) {
        Home(menu = 1) { SessionsContent(sessionsState(), SessionsActions()) }
    }

    /** The switcher from the Sessions title. */
    @Test
    fun titleSwitcher() = shoot("46-title-switcher") {
        Home { SessionsContent(sessionsState(), SessionsActions(), switcherInitiallyOpen = true) }
    }

    /** A computer without sessions (Linux box is offline). */
    @Test
    fun computerWithoutSessions() = shoot("47-sessions-no-sessions") {
        val groups = DemoData.groups(demo).filter { it.deviceId != DemoData.LINUX_ID }
        HomeScaffold(tab = 0, onTab = {}, ui = HomeTabsUi(account, computers(DemoData.LINUX_ID, groups))) {
            SessionsContent(sessionsState(selected = DemoData.LINUX_ID, groups = groups), SessionsActions())
        }
    }

    // Profile › Appearance and the session themes.

    private val home = SessionAppearance(themeId = "home")
    private val snowman = SessionAppearance(themeId = "snowman")

    @Test
    @Config(qualifiers = "+h1000dp")
    fun appearanceLight() = shoot("48-appearance-home") {
        AppearanceContent(AppearanceUiState(ThemeMode.System, home), AppearanceActions())
    }

    @Test
    @Config(qualifiers = "+h1000dp")
    fun appearanceDark() = shoot("49-appearance-snowman-dark", dark = true) {
        AppearanceContent(AppearanceUiState(ThemeMode.Dark, snowman), AppearanceActions())
    }

    @Test
    fun themedSessionLight() = shoot("50-session-theme-classic", appearance = SessionAppearance(themeId = "classic")) {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun themedSessionDark() = shoot("51-session-theme-classic-dark", dark = true, appearance = SessionAppearance(themeId = "classic")) {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun themedSessionPurpleDark() = shoot("52-session-theme-purple-dark", dark = true, appearance = SessionAppearance(themeId = "purple")) {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun themedSessionGame() = shoot("53-session-theme-game", appearance = SessionAppearance(themeId = "game")) {
        SessionContent(waitingSession(), draft = "", now = now, actions = SessionActions())
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
    fun sessionsEditGerman() = shoot("24-sessions-edit-de", dark = true) {
        Home { SessionsContent(sessionsState(editing = true), SessionsActions()) }
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

    private fun newSessionState(choice: SetupChoice = SetupChoice()): SessionUiState = SessionUiState.build(
        row = null,
        detail = null,
        gone = false,
        transcript = TranscriptState(loaded = true, historyComplete = true),
        prompts = emptyList(),
        optimistic = emptyList(),
        connection = ConnectionState.Connected,
        zone = zone,
        newSession = crokSite,
        deviceModels = deviceModels(crokSite.deviceId),
        choice = choice,
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
        Home { SessionsContent(sessionsState(), SessionsActions(), pickerInitiallyOpen = true) }
    }

    @Test
    fun projectPickerDark() = shoot("31-new-session-picker-dark", dark = true) {
        Home { SessionsContent(sessionsState(), SessionsActions(), pickerInitiallyOpen = true) }
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
        HomeScaffold(tab = 0, onTab = {}, ui = HomeTabsUi(account, computers(groups = groups))) {
            ProjectContent(ProjectUiState.build(groups, live = true, DemoData.MACBOOK_CROK_SITE, "", false, ConnectionState.Connected, now), ProjectActions())
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
            // The computer's list as devices:models answers it: none from the Studio's older crok.
            deviceModels = Result.success(if (models) DemoData.modelsFor(session.detail.deviceId) else null),
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
        Home { SessionsContent(sessionsState(), SessionsActions()) }
    }

    @Test
    fun frostedFallbackSessionDark() = shoot("43-session-frosted-fallback-dark", dark = true, glass = GlassLevel.Tinted) {
        SessionContent(runningSession(), draft = "", now = now, actions = SessionActions())
    }

    // Model and thinking level (mobile/DESIGN.md): the setup row, Choose a Model, the thinking menu.

    private val grokXhigh = SetupChoice("grok-4", "xhigh")

    @Test
    fun newSessionSetupPicked() = shoot("54-new-session-setup-picked") {
        SessionContent(newSessionState(grokXhigh), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun newSessionSetupPickedDark() = shoot("55-new-session-setup-picked-dark", dark = true) {
        SessionContent(newSessionState(grokXhigh), draft = "Plan the 1.6 release", now = now, actions = SessionActions())
    }

    @Test
    fun sessionSetupRow() = shoot("56-session-setup-row") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun sessionSetupRowDarkWithDraft() = shoot("57-session-setup-row-dark", dark = true) {
        SessionContent(commandSession(), draft = "Also check the Linux runner", now = now, actions = SessionActions())
    }

    @Test
    fun modelSheet() = shoot("58-model-sheet") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(modelSheet = true))
    }

    @Test
    fun modelSheetSearchDark() = shoot("59-model-sheet-search-dark", dark = true) {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(modelSheet = true, query = "deep"))
    }

    @Test
    fun modelSheetNewSession() = shoot("60-model-sheet-new-session") {
        SessionContent(newSessionState(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(modelSheet = true))
    }

    @Test
    fun modelSheetNoResults() = shoot("61-model-sheet-no-results") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(modelSheet = true, query = "gpt"))
    }

    @Test
    fun thinkingMenu() = shoot("62-thinking-menu") {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(thinkingMenu = true))
    }

    @Test
    fun thinkingMenuNewSessionDark() = shoot("63-thinking-menu-new-session-dark", dark = true) {
        SessionContent(newSessionState(SetupChoice("grok-4")), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(thinkingMenu = true))
    }

    @Test
    fun sessionSetupThemed() = shoot("64-session-setup-theme-classic", appearance = SessionAppearance(themeId = "classic")) {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun sessionSetupThemedDark() = shoot("65-session-setup-theme-purple-dark", dark = true, appearance = SessionAppearance(themeId = "purple")) {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(thinkingMenu = true))
    }

    /** A model change on its way: the new name with a spinner; both pills wait. */
    @Test
    fun sessionSetupChanging() = shoot("66-session-setup-changing") {
        SessionContent(runningSession(SetupChange(model = "openrouter/moonshotai/kimi-k2")), draft = "", now = now, actions = SessionActions())
    }

    /** The Studio's older crok offers no list: the session's model, dimmed. */
    @Test
    fun sessionSetupOlderCrok() = shoot("67-session-setup-older-crok", dark = true) {
        SessionContent(commandSession(sessionId = "demo-s3", models = false), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+ja")
    fun newSessionSetupJapanese() = shoot("68-new-session-setup-ja") {
        SessionContent(newSessionState(SetupChoice("grok-4")), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+de")
    fun modelSheetGermanNewSession() = shoot("69-model-sheet-new-session-de", dark = true) {
        SessionContent(newSessionState(grokXhigh), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(modelSheet = true))
    }

    @Test
    @Config(qualifiers = "+fr")
    fun thinkingMenuFrench() = shoot("70-thinking-menu-fr") {
        SessionContent(newSessionState(grokXhigh), draft = "", now = now, actions = SessionActions(), pickers = SetupPickers(thinkingMenu = true))
    }

    /** Session info: Model and Thinking level by name, with chevrons while the computer offers choices. */
    @Test
    fun sessionInfoSetupRows() = shoot("71-session-info-setup") {
        val detail = DemoData.sessions(now).first { it.id == DemoData.RUNNING_SESSION }.detail
        Box(Modifier.fillMaxSize().background(CrokTheme.colors.grouped)) {
            SessionInfoContent(
                detail = detail,
                refresh = InfoRefresh.Idle,
                now = now,
                actions = SessionInfoActions(),
                setup = InfoSetup(DemoData.macbookModels, onModel = {}, onThinking = {}),
            )
        }
    }

    @Test
    fun sessionSetupFrosted() = shoot("72-session-setup-frosted-fallback", glass = GlassLevel.Tinted) {
        SessionContent(commandSession(), draft = "", now = now, actions = SessionActions())
    }

    // Thinking and tool calls by their status only (mobile/DESIGN.md "Thinking and tool calls").

    /**
     * A turn that ended (a thought, a done, a failed and a stopped call, then Stop) and the one running now: a call
     * running and the newest item a thought, so "Thinking…" shows.
     */
    private fun activitySession(): SessionUiState {
        val session = DemoData.sessions(now).first { it.id == DemoData.RUNNING_SESSION }
        val s = session.id
        fun event(seq: Long, kind: String, at: Long, text: String = "", title: String? = null, status: String? = null) =
            dev.chenli.crok.mobile.data.RelayEvent("$s-a$seq", seq, "a$seq", kind, text, title, if (kind == "tool") "execute" else null, status, "local", null, null, at)
        val start = now - 12 * 60_000
        val events = listOf(
            event(1, "user", start, "Why does relay_reconnect flake on CI?"),
            event(2, "thought", start + 10_000),
            event(3, "tool", start + 20_000, title = "Read `crates/codegen/crok-remote/src/socket.rs`", status = "completed").copy(toolKind = "read"),
            event(4, "tool", start + 30_000, title = "Run `cargo test -p crok-remote relay_reconnect`", status = "completed"),
            event(5, "tool", start + 40_000, title = "Run `cargo clippy -p crok-remote -- -D warnings`", status = "failed"),
            event(6, "tool", start + 50_000, title = "Run `cargo bench -p crok-remote`", status = "in_progress"),
            event(7, "system", start + 60_000, status = "cancelled"),
            event(8, "user", now - 3 * 60_000, "Skip the bench, run the test 20 times"),
            event(9, "tool", now - 2 * 60_000, title = "Run `cargo test -p crok-remote relay_reconnect -- --test-threads 1`", status = "in_progress"),
            event(10, "thought", now - 60_000),
        )
        return SessionUiState.build(
            row = session.row(),
            detail = session.detail,
            gone = false,
            transcript = TranscriptState(events.sortedByDescending { it.seq }, loaded = true, historyComplete = true),
            prompts = emptyList(),
            optimistic = emptyList(),
            connection = ConnectionState.Connected,
            zone = zone,
            deviceModels = deviceModels(session.detail.deviceId),
        )
    }

    @Test
    fun activityLight() = shoot("80-activity-light") {
        SessionContent(activitySession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun activityDark() = shoot("81-activity-dark", dark = true) {
        SessionContent(activitySession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun activityOnAWallpaper() = shoot("82-activity-theme-home", appearance = SessionAppearance(themeId = "home")) {
        SessionContent(activitySession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    fun activityOnAWallpaperDark() = shoot("83-activity-theme-snowman-dark", dark = true, appearance = SessionAppearance(themeId = "snowman")) {
        SessionContent(activitySession(), draft = "", now = now, actions = SessionActions())
    }

    @Test
    @Config(qualifiers = "+zh-rCN")
    fun activityChinese() = shoot("84-activity-zh") {
        SessionContent(activitySession(), draft = "", now = now, actions = SessionActions())
    }
}
