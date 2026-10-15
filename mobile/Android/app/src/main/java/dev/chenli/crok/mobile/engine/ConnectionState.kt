package dev.chenli.crok.mobile.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.core.content.getSystemService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
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

/** Whether the phone has a usable default network, from ConnectivityManager. */
class NetworkMonitor(context: Context, scope: CoroutineScope) {
    private val manager: ConnectivityManager? = context.getSystemService()

    val available: StateFlow<Boolean> = callbackFlow {
        val cm = manager
        if (cm == null) {
            trySend(true)
            awaitClose { }
            return@callbackFlow
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                trySend(true)
            }

            override fun onLost(network: Network) {
                trySend(hasInternet(cm))
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                trySend(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
            }
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
