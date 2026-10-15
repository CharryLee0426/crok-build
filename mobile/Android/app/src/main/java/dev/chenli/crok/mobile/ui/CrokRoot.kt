package dev.chenli.crok.mobile.ui

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.LocalActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.ui.session.SessionInfoSheet
import dev.chenli.crok.mobile.ui.session.SessionInfoViewModel
import dev.chenli.crok.mobile.ui.session.SessionScreen
import dev.chenli.crok.mobile.ui.session.SessionViewModel
import dev.chenli.crok.mobile.ui.sessions.SessionsScreen
import dev.chenli.crok.mobile.ui.sessions.SessionsViewModel
import dev.chenli.crok.mobile.ui.settings.DevicesActions
import dev.chenli.crok.mobile.ui.settings.DevicesScreen
import dev.chenli.crok.mobile.ui.settings.DevicesViewModel
import dev.chenli.crok.mobile.ui.settings.LinkComputerScreen
import dev.chenli.crok.mobile.ui.settings.LinkComputerViewModel
import dev.chenli.crok.mobile.ui.settings.SettingsActions
import dev.chenli.crok.mobile.ui.settings.SettingsScreen
import dev.chenli.crok.mobile.ui.settings.SettingsViewModel
import dev.chenli.crok.mobile.ui.signin.WaitingScreen
import dev.chenli.crok.mobile.ui.signin.WaitingUiState
import dev.chenli.crok.mobile.ui.signin.WelcomeScreen
import dev.chenli.crok.mobile.ui.signin.WelcomeUiState
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.isDarkFor
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
data object HomeRoute

@Serializable
data class SessionRoute(val id: String)

@Serializable
data object DevicesRoute

@Serializable
data class LinkRoute(val code: String? = null)

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

    CrokTheme(dark = dark) {
        SystemBars(dark)
        Box(Modifier.fillMaxSize().background(CrokTheme.colors.screen)) {
            when (val state = auth) {
                AuthState.Restoring -> Unit
                is AuthState.SignedOut -> WelcomeScreen(
                    state = WelcomeUiState(
                        defaultServer = appViewModel.defaultRelayUrl,
                        savedServer = settings?.serverOverride,
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
                    SignedInApp(current, theme, appViewModel)
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
private fun SignedInApp(engine: CrokEngine, theme: ThemeMode, appViewModel: AppViewModel) {
    val nav = rememberNavController()
    val graph = (LocalContext.current.applicationContext as CrokApplication).graph
    // Keyed by the account so a different sign-in never reuses another account's screens.
    androidx.compose.runtime.key(engine) {
        NavHost(navController = nav, startDestination = HomeRoute) {
            composable<HomeRoute> {
                HomeTabs(
                    engine = engine,
                    theme = theme,
                    appViewModel = appViewModel,
                    onOpenSession = { nav.navigate(SessionRoute(it)) },
                    onDevices = { nav.navigate(DevicesRoute) },
                    onLink = { nav.navigate(LinkRoute()) },
                )
            }
            composable<SessionRoute> { entry ->
                val route = entry.toRoute<SessionRoute>()
                val viewModel = viewModel(key = "session-${route.id}") { SessionViewModel(engine, route.id, graph.drafts) }
                SessionScreen(
                    viewModel = viewModel,
                    onBack = { nav.popBackStack() },
                    infoSheet = { dismiss ->
                        val info = viewModel(key = "info-${route.id}") { SessionInfoViewModel(engine, route.id) }
                        SessionInfoSheet(info, onDismiss = dismiss, onRemoved = { nav.popBackStack() })
                    },
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
        }
    }
}

@Composable
private fun HomeTabs(
    engine: CrokEngine,
    theme: ThemeMode,
    appViewModel: AppViewModel,
    onOpenSession: (String) -> Unit,
    onDevices: () -> Unit,
    onLink: () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    HomeScaffold(tab, onTab = { tab = it }) {
        if (tab == 0) {
            val viewModel = viewModel { SessionsViewModel(engine) }
            SessionsScreen(viewModel, onOpen = { onOpenSession(it.id) }, onLinkComputer = onLink)
        } else {
            val viewModel = viewModel { SettingsViewModel(engine) }
            SettingsScreen(
                viewModel,
                theme,
                SettingsActions(
                    onDevices = onDevices,
                    onLinkComputer = onLink,
                    onTheme = appViewModel::setTheme,
                    onSignOut = appViewModel::signOut,
                ),
            )
        }
    }
}

/** The two tabs, Sessions and Settings, with the bottom navigation bar. */
@Composable
fun HomeScaffold(tab: Int, onTab: (Int) -> Unit, content: @Composable () -> Unit) {
    val colors = CrokTheme.colors
    Scaffold(
        containerColor = colors.screen,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            NavigationBar(containerColor = colors.bar) {
                val itemColors = NavigationBarItemDefaults.colors(
                    selectedIconColor = colors.accent,
                    selectedTextColor = colors.accent,
                    indicatorColor = colors.bubbleOut,
                    unselectedIconColor = colors.textSecondary,
                    unselectedTextColor = colors.textSecondary,
                )
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { onTab(0) },
                    icon = { Icon(if (tab == 0) CrokIcons.Chat else CrokIcons.ChatOutline, contentDescription = null) },
                    label = { Text(stringResource(R.string.tab_sessions)) },
                    colors = itemColors,
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { onTab(1) },
                    icon = { Icon(CrokIcons.Settings, contentDescription = null) },
                    label = { Text(stringResource(R.string.tab_settings)) },
                    colors = itemColors,
                )
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) { content() }
    }
}
