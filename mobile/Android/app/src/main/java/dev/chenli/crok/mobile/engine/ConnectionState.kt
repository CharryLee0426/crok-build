package dev.chenli.crok.mobile.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.core.content.getSystemService
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest

/**
 * What the title shows instead of "Sessions" (Telegram's connection states): no network, the socket is connecting,
 * connected but the first fresh data has not arrived yet, or all good.
 */
enum class ConnectionState { WaitingForNetwork, Connecting, Updating, Connected }

fun connectionStateOf(network: Boolean, connected: Boolean, synced: Boolean): ConnectionState = when {
    !network -> ConnectionState.WaitingForNetwork
    !connected -> ConnectionState.Connecting
    !synced -> ConnectionState.Updating
    else -> ConnectionState.Connected
}

/**
 * Shows trouble only once it has lasted [delayMs] (0.3 s in Telegram), so a brief reconnect never flickers the title;
 * "connected" shows at once.
 */
@OptIn(ExperimentalCoroutinesApi::class)
fun Flow<ConnectionState>.delayedForDisplay(delayMs: Long = 300): Flow<ConnectionState> =
    distinctUntilChanged().transformLatest { state ->
        if (state != ConnectionState.Connected) delay(delayMs)
        emit(state)
    }

/**
 * Whether the phone has a usable default network, from ConnectivityManager, and [changes]: one event each time a
 * default network appears (the network came back, or the phone moved from Wi-Fi to mobile data or back — either way the
 * WebSocket on the old one is dead, often without noticing).
 */
class NetworkMonitor(context: Context, scope: CoroutineScope) {
    private val manager: ConnectivityManager? = context.getSystemService()
    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    val available: StateFlow<Boolean> = callbackFlow {
        val cm = manager
        if (cm == null) {
            trySend(true)
            awaitClose { }
            return@callbackFlow
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            private var current: Network? = null

            override fun onAvailable(network: Network) {
                if (network != current) {
                    // The callback reports the network that is there at registration too: that one is no change.
                    if (current != null || startedWithout) _changes.tryEmit(Unit)
                    current = network
                }
                trySend(true)
            }

            override fun onLost(network: Network) {
                if (network == current) current = null
                startedWithout = true
                trySend(hasInternet(cm))
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                trySend(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
            }

            private var startedWithout = !hasInternet(cm)
        }
        trySend(hasInternet(cm))
        cm.registerDefaultNetworkCallback(callback)
        awaitClose { cm.unregisterNetworkCallback(callback) }
    }.distinctUntilChanged().stateIn(scope, SharingStarted.Eagerly, manager?.let { hasInternet(it) } ?: true)

    private fun hasInternet(cm: ConnectivityManager): Boolean {
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }
}

/**
 * Whether the app is in front (ProcessLifecycleOwner: started = some activity is visible). A phone suspends a
 * backgrounded app and its socket dies meanwhile, so coming back to the front is when the connection is checked.
 */
class AppForeground {
    private val _inFront = MutableStateFlow(false)
    val inFront: StateFlow<Boolean> = _inFront.asStateFlow()

    /** Call on the main thread, once. */
    fun observe(lifecycle: Lifecycle) {
        _inFront.value = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_START -> _inFront.value = true
                    Lifecycle.Event.ON_STOP -> _inFront.value = false
                    else -> Unit
                }
            },
        )
    }
}
