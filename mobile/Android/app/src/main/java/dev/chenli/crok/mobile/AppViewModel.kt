package dev.chenli.crok.mobile

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.chenli.crok.mobile.auth.AuthController
import dev.chenli.crok.mobile.auth.AuthEffect
import dev.chenli.crok.mobile.auth.AuthState
import dev.chenli.crok.mobile.auth.TokenManager
import dev.chenli.crok.mobile.data.AppSettings
import dev.chenli.crok.mobile.data.ConvexHttpApi
import dev.chenli.crok.mobile.data.HttpDeviceAuthApi
import dev.chenli.crok.mobile.data.PhotoImport
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.demo.DemoO11y
import dev.chenli.crok.mobile.demo.DemoTransport
import dev.chenli.crok.mobile.engine.ConvexTransport
import dev.chenli.crok.mobile.engine.CrokEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The app's root: the sign-in state machine and, while signed in, the account's [CrokEngine] (created on sign-in,
 * closed on sign-out — Telegram's AccountInstance lifecycle).
 */
class AppViewModel(private val graph: AppGraph) : ViewModel() {
    private val auth = AuthController(graph.authStore, graph.apiFactory, viewModelScope, graph.relayUrl)

    val authState: StateFlow<AuthState> = auth.state
    val effects: Flow<AuthEffect> = auth.effects

    val settings: StateFlow<AppSettings?> = graph.settingsStore.settings.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _engine = MutableStateFlow<CrokEngine?>(null)
    val engine: StateFlow<CrokEngine?> = _engine.asStateFlow()
    private var tokenScope: CoroutineScope? = null

    init {
        auth.restore()
        viewModelScope.launch { authState.collect(::onAuthState) }
    }

    private fun onAuthState(state: AuthState) {
        if (state is AuthState.SignedIn) {
            val current = _engine.value
            if (current != null && current.account.deviceId == state.credentials.deviceId && current.isDemo == state.demo) return
            closeEngine()
            _engine.value = createEngine(state)
        } else {
            if (_engine.value != null) {
                closeEngine()
                graph.clearAccountData()
            }
        }
    }

    private fun createEngine(state: AuthState.SignedIn): CrokEngine {
        val credentials = state.credentials
        val engine = if (state.demo) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            tokenScope = scope
            val o11y = if (BuildConfig.O11Y_TAB) DemoO11y.fromAssets(graph.context) else null
            CrokEngine(credentials, isDemo = true, transport = DemoTransport(scope, o11y = o11y), network = MutableStateFlow(true), cache = null)
        } else {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            tokenScope = scope
            val tokens = TokenManager(
                api = HttpDeviceAuthApi(ConvexHttpApi(credentials.serverUrl)),
                initial = credentials,
                scope = scope,
                onTokens = { token, expiresAt -> viewModelScope.launch { auth.saveTokens(token, expiresAt) } },
                onRevoked = { viewModelScope.launch { auth.onRevoked() } },
            )
            tokens.start()
            CrokEngine(
                account = credentials,
                isDemo = false,
                // A new Convex client each time the engine replaces a dead one; all of them share the token manager.
                connect = { ConvexTransport(credentials.serverUrl, tokens) },
                network = graph.network.available,
                cache = graph.sessionCache,
                networkChanges = graph.network.changes,
                foreground = graph.foreground.inFront,
            )
        }
        engine.start()
        engine.scope.launch {
            engine.revoked.first()
            auth.onRevoked()
        }
        engine.scope.launch {
            engine.accounts.me().collect { result ->
                result.getOrNull()?.let { me -> auth.saveUser(RelayUser(me.name, me.email, me.imageUrl)) }
            }
        }
        return engine
    }

    private fun closeEngine() {
        _engine.value?.close()
        _engine.value = null
        tokenScope?.cancel()
        tokenScope = null
    }

    /** Signs in to the relay built into the app ([AppGraph.relayUrl]). */
    fun startSignIn() = auth.startSignIn(graph.deviceInfo())

    fun openAgain() = auth.openAgain()

    fun pollNow() = auth.pollNow()

    fun cancelSignIn() = auth.cancel()

    fun signOut() = auth.signOut()

    fun enterDemo() {
        if (BuildConfig.DEMO_ALLOWED) auth.enterDemo(DemoData.credentials)
    }

    fun setTheme(mode: ThemeMode) {
        viewModelScope.launch { graph.settingsStore.setTheme(mode) }
    }

    /** Profile › Appearance › Session Theme. */
    fun setSessionTheme(id: String) {
        viewModelScope.launch { graph.settingsStore.setSessionTheme(id) }
    }

    fun setSessionThemeBlur(blur: Boolean) {
        viewModelScope.launch { graph.settingsStore.setSessionThemeBlur(blur) }
    }

    /**
     * Choose a Photo: the picked picture, downscaled to [PhotoImport.MAX_SIDE] px on its longest side, becomes the Photo
     * theme's background (stored in the app's own files) and is selected.
     */
    fun importPhoto(uri: Uri) {
        viewModelScope.launch {
            val stored = withContext(Dispatchers.IO) { PhotoImport.store(graph.context, uri, graph.sessionBackgroundFile) }
            if (stored) graph.settingsStore.photoChosen(System.currentTimeMillis())
        }
    }

    override fun onCleared() {
        closeEngine()
    }

    companion object {
        fun factory(graph: AppGraph): ViewModelProvider.Factory = viewModelFactory {
            initializer { AppViewModel(graph) }
        }
    }
}
