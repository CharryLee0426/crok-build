package dev.chenli.crok.mobile.auth

import dev.chenli.crok.mobile.data.ConvexHttpApi
import dev.chenli.crok.mobile.data.DeviceAuthApiFactory
import dev.chenli.crok.mobile.data.PollResult
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.chenli.crok.mobile.data.RelayUser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** How this phone introduces itself to the relay (`deviceAuth:start`). */
data class DeviceInfo(val name: String, val platform: String, val client: String)

/** Why the phone is (back) on the Welcome screen. */
sealed interface SignInError {
    data object NoServer : SignInError
    data object BadServer : SignInError
    data object Network : SignInError
    data object Denied : SignInError
    data object Expired : SignInError
    data object Revoked : SignInError
    data object NotConfigured : SignInError
    data class Other(val message: String) : SignInError
}

/**
 * The sign-in state machine: welcome → waiting for approval → signed in (Telegram's LoginActivity pages, iOS's
 * AuthorizationSequenceController). Every step that must survive the app being killed is persisted in [AuthStore].
 */
sealed interface AuthState {
    data object Restoring : AuthState
    data class SignedOut(val error: SignInError? = null, val busy: Boolean = false) : AuthState
    data class Waiting(val pending: PendingSignIn, val offline: Boolean = false) : AuthState
    data class SignedIn(val credentials: StoredCredentials, val demo: Boolean = false) : AuthState
}

sealed interface AuthEffect {
    /** Show the approval page in an Auth Tab / Custom Tab. */
    data class OpenBrowser(val url: String) : AuthEffect
}

class AuthController(
    private val store: AuthStore,
    private val apiFactory: DeviceAuthApiFactory,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val _state = MutableStateFlow<AuthState>(AuthState.Restoring)
    val state: StateFlow<AuthState> = _state.asStateFlow()

    // A channel, not a SharedFlow: a request to open the browser waits for the activity to collect it.
    private val _effects = Channel<AuthEffect>(Channel.BUFFERED)
    val effects: Flow<AuthEffect> = _effects.receiveAsFlow()

    private var pollJob: Job? = null
    private val pollNudge = Channel<Unit>(Channel.CONFLATED)

    /** Reads what was persisted: signed in, still waiting for approval (resumes polling), or signed out. */
    fun restore() {
        store.loadCredentials()?.let {
            _state.value = AuthState.SignedIn(it)
            return
        }
        val pending = store.loadPending()
        when {
            pending == null -> _state.value = AuthState.SignedOut()
            clock() >= pending.expiresAt -> {
                store.savePending(null)
                _state.value = AuthState.SignedOut(SignInError.Expired)
            }
            else -> {
                _state.value = AuthState.Waiting(pending)
                startPolling(pending)
            }
        }
    }

    /** `deviceAuth:start`, then the browser, then polling. */
    fun startSignIn(serverInput: String, device: DeviceInfo) {
        val current = _state.value
        if (current is AuthState.SignedOut && current.busy) return
        if (current is AuthState.SignedIn || current is AuthState.Waiting) return
        if (serverInput.isBlank()) {
            _state.value = AuthState.SignedOut(SignInError.NoServer)
            return
        }
        val serverUrl = ConvexHttpApi.normalizeServerUrl(serverInput)
        if (serverUrl == null) {
            _state.value = AuthState.SignedOut(SignInError.BadServer)
            return
        }
        _state.value = AuthState.SignedOut(busy = true)
        scope.launch {
            try {
                val started = apiFactory.create(serverUrl).start("phone", device.name, device.platform, device.client)
                val now = clock()
                val pending = PendingSignIn(
                    serverUrl = serverUrl,
                    deviceCode = started.deviceCode,
                    userCode = started.userCode,
                    verificationUrlComplete = started.verificationUrlComplete,
                    expiresAt = if (started.expiresAt > now) started.expiresAt else now + DEFAULT_LOGIN_TTL_MS,
                    intervalSeconds = started.interval.coerceIn(1, 30),
                    deviceName = device.name,
                    startedAt = now,
                )
                store.savePending(pending)
                _state.value = AuthState.Waiting(pending)
                pending.browserUrl?.let { _effects.trySend(AuthEffect.OpenBrowser(it)) }
                startPolling(pending)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = AuthState.SignedOut(errorFor(e))
            }
        }
    }

    /** "Open again": the browser sheet was closed before approving. */
    fun openAgain() {
        val waiting = _state.value as? AuthState.Waiting ?: return
        waiting.pending.browserUrl?.let { _effects.trySend(AuthEffect.OpenBrowser(it)) }
        pollNow()
    }

    /** Polls at once, e.g. when the browser sheet closes or `crok://signed-in` arrives. */
    fun pollNow() {
        pollNudge.trySend(Unit)
    }

    fun cancel() {
        pollJob?.cancel()
        pollJob = null
        store.savePending(null)
        _state.value = AuthState.SignedOut()
    }

    private fun startPolling(pending: PendingSignIn) {
        pollJob?.cancel()
        pollJob = scope.launch {
            val api = apiFactory.create(pending.serverUrl)
            val interval = pending.intervalSeconds * 1000L
            var wait = 0L
            while (isActive) {
                if (wait > 0) withTimeoutOrNull(wait) { pollNudge.receive() }
                wait = interval
                if (clock() >= pending.expiresAt) {
                    finish(AuthState.SignedOut(SignInError.Expired))
                    return@launch
                }
                val result = try {
                    api.poll(pending.deviceCode)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: RelayNetworkException) {
                    _state.value = AuthState.Waiting(pending, offline = true)
                    wait = (interval * 2).coerceAtMost(MAX_OFFLINE_WAIT_MS)
                    continue
                } catch (e: Exception) {
                    finish(AuthState.SignedOut(errorFor(e)))
                    return@launch
                }
                when (result.status) {
                    PollResult.PENDING -> _state.value = AuthState.Waiting(pending, offline = false)
                    PollResult.APPROVED -> {
                        complete(pending, result)
                        return@launch
                    }
                    PollResult.DENIED -> {
                        finish(AuthState.SignedOut(SignInError.Denied))
                        return@launch
                    }
                    else -> {
                        finish(AuthState.SignedOut(SignInError.Expired))
                        return@launch
                    }
                }
            }
        }
    }

    private fun complete(pending: PendingSignIn, result: PollResult) {
        val deviceId = result.deviceId
        val refreshToken = result.refreshToken
        if (deviceId == null || refreshToken == null) {
            finish(AuthState.SignedOut(SignInError.Other("The server approved the sign-in without a token.")))
            return
        }
        val credentials = StoredCredentials(
            serverUrl = pending.serverUrl,
            deviceId = deviceId,
            refreshToken = refreshToken,
            accessToken = result.accessToken,
            accessTokenExpiresAt = result.accessTokenExpiresAt,
            user = result.user ?: RelayUser(),
            deviceName = pending.deviceName,
        )
        // The refresh token is handed out exactly once: store it before anything else can fail.
        store.saveCredentials(credentials)
        store.savePending(null)
        _state.value = AuthState.SignedIn(credentials)
    }

    private fun finish(state: AuthState.SignedOut) {
        store.savePending(null)
        _state.value = state
    }

    /** Keeps the newest access token so a restart can reuse it while it is valid. */
    fun saveTokens(accessToken: String, expiresAt: Long) {
        val signedIn = _state.value as? AuthState.SignedIn ?: return
        if (signedIn.demo) return
        val stored = store.loadCredentials() ?: return
        if (stored.deviceId != signedIn.credentials.deviceId) return
        store.saveCredentials(stored.copy(accessToken = accessToken, accessTokenExpiresAt = expiresAt))
    }

    /** Keeps the account's name, email and picture current (from `users:me`). */
    fun saveUser(user: RelayUser) {
        val signedIn = _state.value as? AuthState.SignedIn ?: return
        if (signedIn.demo || signedIn.credentials.user == user) return
        val stored = store.loadCredentials() ?: return
        val updated = stored.copy(user = user)
        store.saveCredentials(updated)
        _state.value = signedIn.copy(credentials = signedIn.credentials.copy(user = user))
    }

    /** "Sign out": unlinks the device on the relay (best effort) and forgets everything local. */
    fun signOut() {
        val signedIn = _state.value as? AuthState.SignedIn
        pollJob?.cancel()
        if (signedIn?.demo != true) store.clear()
        _state.value = AuthState.SignedOut()
        if (signedIn != null && !signedIn.demo) {
            val credentials = signedIn.credentials
            scope.launch {
                withTimeoutOrNull(LOGOUT_TIMEOUT_MS) {
                    runCatching { apiFactory.create(credentials.serverUrl).logout(credentials.refreshToken) }
                }
            }
        }
    }

    /** The relay said this device was signed out elsewhere (`REVOKED`). */
    fun onRevoked() {
        val signedIn = _state.value as? AuthState.SignedIn ?: return
        if (!signedIn.demo) store.clear()
        _state.value = AuthState.SignedOut(SignInError.Revoked)
    }

    /** Debug builds: a signed-in state backed by demo data, never persisted. Only from the Welcome screen. */
    fun enterDemo(credentials: StoredCredentials) {
        if (_state.value !is AuthState.SignedOut) return
        _state.value = AuthState.SignedIn(credentials, demo = true)
    }

    private fun errorFor(e: Exception): SignInError = when (e) {
        is RelayNetworkException -> SignInError.Network
        is RelayException -> when (e.code) {
            RelayErrorCode.EXPIRED -> SignInError.Expired
            RelayErrorCode.REVOKED -> SignInError.Revoked
            RelayErrorCode.NOT_CONFIGURED -> SignInError.NotConfigured
            else -> SignInError.Other(e.message ?: e.code.name)
        }
        is IllegalArgumentException -> SignInError.BadServer
        else -> SignInError.Other(e.message ?: e.javaClass.simpleName)
    }

    companion object {
        const val DEFAULT_LOGIN_TTL_MS = 10 * 60 * 1000L
        const val MAX_OFFLINE_WAIT_MS = 15_000L
        const val LOGOUT_TIMEOUT_MS = 5_000L
    }
}
