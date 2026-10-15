package dev.chenli.crok.mobile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.chenli.crok.mobile.auth.AuthController
import dev.chenli.crok.mobile.auth.AuthEffect
import dev.chenli.crok.mobile.auth.AuthState
import dev.chenli.crok.mobile.auth.DeviceAuthProvider
import dev.chenli.crok.mobile.auth.TokenManager
import dev.chenli.crok.mobile.data.AppSettings
import dev.chenli.crok.mobile.data.ConvexHttpApi
import dev.chenli.crok.mobile.data.HttpDeviceAuthApi
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.ThemeMode
import dev.chenli.crok.mobile.demo.DemoData
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

/**
 * The app's root: the sign-in state machine and, while signed in, the account's [CrokEngine] (created on sign-in,
 * closed on sign-out — Telegram's AccountInstance lifecycle).
 */
class AppViewModel(private val graph: AppGraph) : ViewModel() {
    private val auth = AuthController(graph.authStore, graph.apiFactory, viewModelScope)

    val authState: StateFlow<AuthState> = auth.state
    val effects: Flow<AuthEffect> = auth.effects

    val settings: StateFlow<AppSettings?> = graph.settingsStore.settings.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _engine = MutableStateFlow<CrokEngine?>(null)
    val engine: StateFlow<CrokEngine?> = _engine.asStateFlow()
    private var tokenScope: CoroutineScope? = null

    val defaultRelayUrl: String get() = graph.defaultRelayUrl

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
            CrokEngine(credentials, isDemo = true, transport = DemoTransport(scope), network = MutableStateFlow(true), cache = null)
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
            val transport = ConvexTransport(credentials.serverUrl, DeviceAuthProvider(tokens), graph.context)
            tokens.start()
            CrokEngine(credentials, isDemo = false, transport = transport, network = graph.network.available, cache = graph.sessionCache)
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

    fun startSignIn(serverInput: String) {
        viewModelScope.launch {
            val normalized = ConvexHttpApi.normalizeServerUrl(serverInput)
            graph.settingsStore.setServer(if (normalized == null || normalized == graph.defaultRelayUrl) null else normalized)
        }
        auth.startSignIn(serverInput, graph.deviceInfo())
    }

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

    override fun onCleared() {
        closeEngine()
    }

    companion object {
        fun factory(graph: AppGraph): ViewModelProvider.Factory = viewModelFactory {
            initializer { AppViewModel(graph) }
        }
    }
}
