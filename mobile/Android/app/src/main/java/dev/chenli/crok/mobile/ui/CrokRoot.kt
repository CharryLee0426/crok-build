package dev.chenli.crok.mobile.ui

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import dev.chenli.crok.mobile.AppViewModel
import dev.chenli.crok.mobile.BuildConfig
import dev.chenli.crok.mobile.CrokApplication
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.auth.AuthState
import dev.chenli.crok.mobile.data.PhotoImport
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.ui.common.AccountAvatar
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.GlassMenuRow
import dev.chenli.crok.mobile.ui.common.GlassTab
import dev.chenli.crok.mobile.ui.common.GlassTabScaffold
import dev.chenli.crok.mobile.ui.session.NewSessionTarget
import dev.chenli.crok.mobile.ui.session.SessionInfoSheet
import dev.chenli.crok.mobile.ui.session.SessionInfoViewModel
import dev.chenli.crok.mobile.ui.session.SessionScreen
import dev.chenli.crok.mobile.ui.session.SessionViewModel
import dev.chenli.crok.mobile.ui.sessions.ArchivedScreen
import dev.chenli.crok.mobile.ui.sessions.ArchivedViewModel
import dev.chenli.crok.mobile.ui.sessions.ComputerSwitcherItems
import dev.chenli.crok.mobile.ui.sessions.ProjectScreen
import dev.chenli.crok.mobile.ui.sessions.ProjectViewModel
import dev.chenli.crok.mobile.ui.sessions.SessionsScreen
import dev.chenli.crok.mobile.ui.sessions.SessionsViewModel
import dev.chenli.crok.mobile.ui.settings.AppearanceActions
import dev.chenli.crok.mobile.ui.settings.AppearanceScreen
import dev.chenli.crok.mobile.ui.settings.AppearanceUiState
import dev.chenli.crok.mobile.ui.settings.DevicesActions
import dev.chenli.crok.mobile.ui.settings.DevicesScreen
import dev.chenli.crok.mobile.ui.settings.DevicesViewModel
import dev.chenli.crok.mobile.ui.settings.LinkComputerScreen
import dev.chenli.crok.mobile.ui.settings.LinkComputerViewModel
import dev.chenli.crok.mobile.ui.settings.ProfileActions
import dev.chenli.crok.mobile.ui.settings.ProfileScreen
import dev.chenli.crok.mobile.ui.settings.ProfileUiState
import dev.chenli.crok.mobile.ui.signin.WaitingScreen
import dev.chenli.crok.mobile.ui.signin.WaitingUiState
import dev.chenli.crok.mobile.ui.signin.WelcomeScreen
import dev.chenli.crok.mobile.ui.signin.WelcomeUiState
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.LocalSessionAppearance
import dev.chenli.crok.mobile.ui.theme.SessionAppearance
import dev.chenli.crok.mobile.ui.theme.SessionThemes
import dev.chenli.crok.mobile.ui.theme.isDarkFor
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

@Serializable
data object HomeRoute

@Serializable
data class SessionRoute(val id: String)

/** The new-session screen for a folder on a computer; [prompt] (from `/new <prompt>`) is sent at once. */
@Serializable
data class NewSessionRoute(
    val deviceId: String,
    val path: String,
    val deviceName: String,
    val projectName: String,
    val prompt: String? = null,
) {
    val target: NewSessionTarget get() = NewSessionTarget(deviceId, path, deviceName, projectName)

    companion object {
        fun of(target: NewSessionTarget, prompt: String? = null) =
            NewSessionRoute(target.deviceId, target.path, target.deviceName, target.projectName, prompt)
    }
}

@Serializable
data object DevicesRoute

@Serializable
data class LinkRoute(val code: String? = null)

/** Profile › Appearance. */
@Serializable
data object AppearanceRoute

/**
 * The whole app. Signing in is compulsory: while signed out only the sign-in flow exists; the signed-in navigation
 * graph (and every screen's view model) lives only while there is an engine.
 */
@Composable
fun CrokRoot(appViewModel: AppViewModel, browserMissing: StateFlow<String?>) {
    val settings by appViewModel.settings.collectAsStateWithLifecycle()
    val auth by appViewModel.authState.collectAsStateWithLifecycle()
    val engine by appViewModel.engine.collectAsStateWithLifecycle()
    val missing by browserMissing.collectAsStateWithLifecycle()
    val theme = settings?.theme ?: ThemeMode.System
    val dark = isDarkFor(theme)
    val graph = (LocalContext.current.applicationContext as CrokApplication).graph
    // The Photo theme's picture, read again whenever a new one is chosen.
    val photoStamp = settings?.photoStamp ?: 0L
    val photo by produceState<ImageBitmap?>(initialValue = null, photoStamp) {
        value = withContext(Dispatchers.IO) { PhotoImport.load(graph.sessionBackgroundFile)?.asImageBitmap() }
    }
    val appearance = SessionAppearance(
        themeId = settings?.sessionTheme ?: SessionThemes.NONE,
        blur = settings?.sessionThemeBlur ?: false,
        photo = photo,
    )

    CrokTheme(dark = dark) {
        SystemBars(dark)
        CompositionLocalProvider(LocalSessionAppearance provides appearance) {
            Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) {
                when (val state = auth) {
                    AuthState.Restoring -> Unit
                    is AuthState.SignedOut -> WelcomeScreen(
                        state = WelcomeUiState(
                            error = state.error,
                            busy = state.busy,
                            demoAllowed = BuildConfig.DEMO_ALLOWED,
                        ),
                        onContinue = appViewModel::startSignIn,
                        onDemo = appViewModel::enterDemo,
                    )
                    is AuthState.Waiting -> WaitingScreen(
                        state = WaitingUiState(state.pending, state.offline, browserMissing = missing),
                        onOpenAgain = appViewModel::openAgain,
                        onCancel = appViewModel::cancelSignIn,
                    )
                    is AuthState.SignedIn -> engine?.let { current ->
                        SignedInApp(current, AppearanceUiState(theme, appearance), appViewModel)
                    }
                }
            }
        }
    }
}

/** Status and navigation bar icons follow the app's theme, not only the system's. */
@Composable
private fun SystemBars(dark: Boolean) {
    val activity = LocalActivity.current as? ComponentActivity ?: return
    DisposableEffect(dark) {
        activity.enableEdgeToEdge(
            statusBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
            else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
            else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        onDispose { }
    }
}

@Composable
private fun SignedInApp(engine: CrokEngine, appearance: AppearanceUiState, appViewModel: AppViewModel) {
    val nav = rememberNavController()
    val graph = (LocalContext.current.applicationContext as CrokApplication).graph
    // Keyed by the account so a different sign-in never reuses another account's screens.
    androidx.compose.runtime.key(engine) {
        NavHost(navController = nav, startDestination = HomeRoute) {
            composable<HomeRoute> {
                HomeTabs(
                    engine = engine,
                    appViewModel = appViewModel,
                    onOpenSession = { nav.navigate(SessionRoute(it)) },
                    onNewSession = { nav.navigate(NewSessionRoute.of(it)) },
                    onDevices = { nav.navigate(DevicesRoute) },
                    onLink = { nav.navigate(LinkRoute()) },
                    onAppearance = { nav.navigate(AppearanceRoute) },
                )
            }
            composable<SessionRoute> { entry ->
                val route = entry.toRoute<SessionRoute>()
                val viewModel = viewModel(key = "session-${route.id}") { SessionViewModel(engine, route.id, graph.drafts) }
                SessionScreen(
                    viewModel = viewModel,
                    onBack = { nav.popBackStack() },
                    onNewSession = { target, prompt -> nav.navigate(NewSessionRoute.of(target, prompt)) },
                    infoSheet = { id, dismiss -> InfoSheet(engine, id, dismiss) { nav.popBackStack() } },
                )
            }
            composable<NewSessionRoute> { entry ->
                val route = entry.toRoute<NewSessionRoute>()
                // One per navigation entry: it turns into the session it creates, in place.
                val viewModel = viewModel(key = "new-${entry.id}") {
                    SessionViewModel(
                        engine, null, graph.drafts,
                        newSession = route.target,
                        firstPrompt = route.prompt,
                        saved = createSavedStateHandle(),
                        // The entry's id survives the app being killed: a restored screen resends the same create.
                        firstPromptClientId = UUID.nameUUIDFromBytes(entry.id.toByteArray()).toString(),
                    )
                }
                SessionScreen(
                    viewModel = viewModel,
                    onBack = { nav.popBackStack() },
                    onNewSession = { target, prompt -> nav.navigate(NewSessionRoute.of(target, prompt)) },
                    infoSheet = { id, dismiss -> InfoSheet(engine, id, dismiss) { nav.popBackStack() } },
                )
            }
            composable<DevicesRoute> {
                val viewModel = viewModel { DevicesViewModel(engine) }
                DevicesScreen(
                    viewModel,
                    DevicesActions(onBack = { nav.popBackStack() }, onSignOutThisPhone = appViewModel::signOut),
                )
            }
            composable<LinkRoute> { entry ->
                val route = entry.toRoute<LinkRoute>()
                val viewModel = viewModel { LinkComputerViewModel(engine, route.code) }
                LinkComputerScreen(viewModel, onBack = { nav.popBackStack() })
            }
            composable<AppearanceRoute> {
                AppearanceScreen(
                    state = appearance,
                    actions = AppearanceActions(
                        onBack = { nav.popBackStack() },
                        onMode = appViewModel::setTheme,
                        onTheme = appViewModel::setSessionTheme,
                        onBlur = appViewModel::setSessionThemeBlur,
                    ),
                    onPhoto = appViewModel::importPhoto,
                )
            }
        }
    }
}

/** A screen of the Sessions tab's own stack: the computer's projects, then a project or the archived sessions. */
sealed interface SessionsPage {
    data object Projects : SessionsPage
    data class Project(val key: String) : SessionsPage
    data class Archived(val deviceId: String, val computerName: String) : SessionsPage

    companion object {
        /** The stack as strings for `rememberSaveable` (the root is implied). */
        fun save(stack: List<SessionsPage>): List<String> = stack.mapNotNull { page ->
            when (page) {
                Projects -> null
                is Project -> "p\u0000${page.key}"
                is Archived -> "a\u0000${page.deviceId}\u0000${page.computerName}"
            }
        }

        fun restore(saved: List<String>): List<SessionsPage> = saved.mapNotNull { raw ->
            val parts = raw.split('\u0000')
            when (parts.firstOrNull()) {
                "p" -> parts.getOrNull(1)?.let { Project(it) }
                "a" -> parts.getOrNull(1)?.let { Archived(it, parts.getOrNull(2).orEmpty()) }
                else -> null
            }
        }
    }
}

@Composable
private fun HomeTabs(
    engine: CrokEngine,
    appViewModel: AppViewModel,
    onOpenSession: (String) -> Unit,
    onNewSession: (NewSessionTarget) -> Unit,
    onDevices: () -> Unit,
    onLink: () -> Unit,
    onAppearance: () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val graph = (LocalContext.current.applicationContext as CrokApplication).graph
    val home = viewModel { HomeViewModel(engine, graph.computerSelection) }
    val computers by home.computers.collectAsStateWithLifecycle()
    val account by home.account.collectAsStateWithLifecycle()
    val devices by home.devices.collectAsStateWithLifecycle()
    var savedStack by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val stack = SessionsPage.restore(savedStack)
    fun push(page: SessionsPage) {
        savedStack = SessionsPage.save(stack + page)
    }
    fun pop() {
        savedStack = SessionsPage.save(stack.dropLast(1))
    }
    LaunchedEffect(home) {
        home.events.collect { event ->
            // Another computer: its list starts at the root (Telegram's account switch).
            if (event is HomeEvent.ComputerChanged) savedStack = emptyList()
        }
    }
    BackHandler(enabled = tab == 0 && stack.isNotEmpty()) { pop() }

    HomeScaffold(
        tab = tab,
        onTab = { selected ->
            // Tapping Sessions again goes back to its root, as tab bars do.
            if (selected == 0 && tab == 0) savedStack = emptyList()
            tab = selected
        },
        ui = HomeTabsUi(account, computers),
        actions = HomeTabActions(
            onMarkAllRead = home::markAllRead,
            onSelectComputer = home::select,
            onLinkComputer = onLink,
        ),
    ) {
        if (tab == 0) {
            val page = stack.lastOrNull() ?: SessionsPage.Projects
            AnimatedContent(
                targetState = stack.size to page,
                transitionSpec = {
                    val forward = targetState.first > initialState.first
                    val enter = slideInHorizontally { width -> if (forward) width else -width / 4 } + fadeIn()
                    val exit = slideOutHorizontally { width -> if (forward) -width / 4 else width } + fadeOut()
                    enter togetherWith exit
                },
                contentKey = { it.second },
                label = "sessions-stack",
            ) { (_, shown) ->
                when (shown) {
                    SessionsPage.Projects -> {
                        val viewModel = viewModel { SessionsViewModel(engine, home.computers) }
                        SessionsScreen(
                            viewModel,
                            onOpenProject = { push(SessionsPage.Project(it.key)) },
                            onOpenArchived = {
                                computers.selected?.let { push(SessionsPage.Archived(it.deviceId, it.name)) }
                            },
                            onOpen = { onOpenSession(it.id) },
                            onNewSession = onNewSession,
                            onLinkComputer = onLink,
                            onSelectComputer = home::select,
                            onMarkProjectRead = home::markProjectRead,
                            onMarkAllRead = home::markAllRead,
                        )
                    }
                    is SessionsPage.Project -> {
                        val viewModel = viewModel(key = "project-${shown.key}") { ProjectViewModel(engine, shown.key) }
                        ProjectScreen(
                            viewModel,
                            onBack = ::pop,
                            onOpen = { onOpenSession(it.id) },
                            onNewSession = onNewSession,
                            onMarkAllRead = { home.markProjectRead(shown.key) },
                        )
                    }
                    is SessionsPage.Archived -> {
                        val viewModel = viewModel(key = "archived-${shown.deviceId}") {
                            ArchivedViewModel(engine, shown.deviceId, shown.computerName)
                        }
                        ArchivedScreen(viewModel, onBack = ::pop, onOpen = { onOpenSession(it.id) })
                    }
                }
            }
        } else {
            ProfileScreen(
                ProfileUiState(
                    account = account,
                    computers = computers.computers,
                    selectedId = computers.selectedId,
                    deviceCount = devices?.size?.takeIf { it > 0 },
                    demo = engine.isDemo,
                ),
                ProfileActions(
                    onSelectComputer = home::select,
                    onLinkComputer = onLink,
                    onDevices = onDevices,
                    onAppearance = onAppearance,
                    onSignOut = appViewModel::signOut,
                ),
            )
        }
    }
}

@Composable
private fun InfoSheet(engine: CrokEngine, sessionDocId: String, onDismiss: () -> Unit, onRemoved: () -> Unit) {
    val info = viewModel(key = "info-$sessionDocId") { SessionInfoViewModel(engine, sessionDocId) }
    SessionInfoSheet(info, onDismiss = onDismiss, onRemoved = onRemoved)
}

/** What the tab bar shows: the account picture and the badges, and what its menus list. */
data class HomeTabsUi(val account: AccountInfo, val computers: ComputerState)

data class HomeTabActions(
    val onMarkAllRead: () -> Unit = {},
    val onSelectComputer: (String) -> Unit = {},
    val onLinkComputer: () -> Unit = {},
)

/**
 * The two tabs, Sessions and Profile, under a floating Liquid Glass tab bar (mobile/DESIGN.md "Tabs"). Sessions shows
 * the selected computer's unread count, and a long press offers Mark All as Read; Profile shows the account picture
 * (ringed while selected) and the other computers' unread count, and a long press opens the computer switcher.
 */
@Composable
fun HomeScaffold(
    tab: Int,
    onTab: (Int) -> Unit,
    ui: HomeTabsUi,
    actions: HomeTabActions = HomeTabActions(),
    initialMenu: Int? = null,
    content: @Composable () -> Unit,
) {
    val colors = CrokTheme.colors
    val computers = ui.computers
    GlassTabScaffold(
        tabs = listOf(
            GlassTab(
                stringResource(R.string.tab_sessions),
                CrokIcons.ChatOutline,
                CrokIcons.Chat,
                badge = computers.unreadHere,
                tag = "tab-sessions",
                menu = { dismiss ->
                    GlassMenuRow(
                        title = stringResource(R.string.action_mark_all_read),
                        enabled = computers.unreadHere > 0,
                        leading = { Icon(CrokIcons.DoneAll, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp)) },
                        modifier = Modifier.testTag("mark-all-read"),
                        onClick = {
                            dismiss()
                            actions.onMarkAllRead()
                        },
                    )
                },
            ),
            GlassTab(
                stringResource(R.string.tab_profile),
                badge = computers.unreadElsewhere,
                tag = "tab-profile",
                customIcon = { selected -> ProfileTabIcon(ui.account, selected) },
                menu = { dismiss ->
                    ComputerSwitcherItems(
                        computers.computers,
                        computers.selectedId,
                        onSelect = actions.onSelectComputer,
                        onLinkComputer = actions.onLinkComputer,
                        dismiss = dismiss,
                    )
                },
            ),
        ),
        selected = tab,
        onSelect = onTab,
        initialMenu = initialMenu,
        content = content,
    )
}

/** The Profile tab's icon: the account picture, with a 2 dp accent ring while the tab is selected. */
@Composable
private fun ProfileTabIcon(account: AccountInfo, selected: Boolean) {
    val colors = CrokTheme.colors
    Box(
        Modifier
            .size(26.dp)
            .then(if (selected) Modifier.border(2.dp, colors.accent, CircleShape) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        AccountAvatar(account.name, account.imageUrl, if (selected) 20.dp else 26.dp)
    }
}
