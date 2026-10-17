package dev.chenli.crok.mobile.engine

import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.relayCode
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement

/** How long the connection waits before it acts (relay/DESIGN.md §5, "Staying connected"); tests shorten nothing. */
data class ConnectionTiming(
    /** Not synced for this long while the network is up (and the app is in front): refresh, then maybe replace. */
    val staleAfterMs: Long = 20_000,
    /** After a token refresh, how long the socket has to answer before the client is replaced. */
    val syncTimeoutMs: Long = 10_000,
    /** A mutation still running on a replaced client gets this long before it is sent again on the new one. */
    val mutationGraceMs: Long = 10_000,
    /** Replacing again and again (the relay unreachable behind a captive portal, say) backs off up to this. */
    val maxBackoffMs: Long = 120_000,
)

/** Why the connection is being checked. */
enum class RecoveryReason { Foreground, Network, Stale, Unauthenticated }

/**
 * One relay transport and what the engine knows about it: signed in yet, replaced yet, mutations still running on it.
 */
internal class Link(val transport: RelayTransport, val number: Int) {
    val authReady = MutableStateFlow(false)
    val retired = MutableStateFlow(false)
    val inFlight = AtomicInteger(0)
    val authNudge = Channel<Unit>(Channel.CONFLATED)
    var authJob: Job? = null

    /** A recovery asked this link to prove it is alive: a subscription's first (maybe cached) result proves nothing. */
    @Volatile var probing = false
}

/**
 * The engine's connection to the relay: the current transport, its sign-in, whether fresh data has arrived since it
 * last (re)connected, and the recovery that keeps it alive without the person killing the app (relay/DESIGN.md §5,
 * "Staying connected"):
 *
 * - on returning to the foreground, on the network coming back or changing, and when nothing has synced for
 *   [ConnectionTiming.staleAfterMs] while the network is up, it refreshes the token on the current socket; if no fresh
 *   result arrives within [ConnectionTiming.syncTimeoutMs], it replaces the transport;
 * - `UNAUTHENTICATED` from any query or mutation refreshes the token and replaces the transport at once;
 * - `REVOKED` anywhere calls [onRevoked] (the phone signs out) and stops all of it.
 *
 * Live queries ([subscribe]) and mutations ([call]) always run on the current transport and move to a new one by
 * themselves; a screen keeps what it shows meanwhile.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class RelayConnection(
    private val connect: () -> RelayTransport,
    private val scope: CoroutineScope,
    private val network: StateFlow<Boolean>,
    private val networkChanges: Flow<Unit> = emptyFlow(),
    private val foreground: StateFlow<Boolean> = MutableStateFlow(true),
    private val clock: () -> Long,
    private val timing: ConnectionTiming = ConnectionTiming(),
    private val onRevoked: () -> Unit,
) {
    private val _link = MutableStateFlow(Link(connect(), 1))

    /** The transport everything runs on now. */
    val link: StateFlow<Link> = _link.asStateFlow()

    /** Fresh data arrived since the transport last (re)connected or was asked to prove itself. */
    private val synced = MutableStateFlow(false)

    private val socketConnected: Flow<Boolean> = _link.flatMapLatest { it.transport.connected }

    private val authenticated: Flow<Boolean> = _link.flatMapLatest { it.authReady }

    /** The raw state; screens show it through [delayedForDisplay]. */
    val state: StateFlow<ConnectionState> =
        combine(network, socketConnected, authenticated, synced) { net, connected, auth, fresh ->
            connectionStateOf(net, connected, auth && fresh)
        }.stateIn(scope, SharingStarted.Eagerly, ConnectionState.Connecting)

    private var recovery: Job? = null
    private var recoveryReason: RecoveryReason? = null
    private val recoveryLock = Any()
    private val retiredLinks = LinkedHashSet<Link>()

    /** Replacements in a row without a sync in between; the waits grow with it. */
    private var failedReplacements = 0
    private var lastReplacedAt = Long.MIN_VALUE

    @Volatile private var revoked = false

    /** How many transports this connection has made (the first one included). */
    val transportsMade: Int get() = _link.value.number

    fun start() {
        startLink(_link.value)
        scope.launch {
            // Every reconnect makes what is shown stale until the relay answers again ("Updating…").
            socketConnected.collect { connected -> if (!connected) synced.value = false }
        }
        scope.launch {
            synced.collect { fresh -> if (fresh) failedReplacements = 0 }
        }
        scope.launch {
            var wasInFront = foreground.value
            foreground.collect { inFront ->
                if (inFront && !wasInFront) recover(RecoveryReason.Foreground)
                wasInFront = inFront
            }
        }
        scope.launch {
            var wasUp = network.value
            network.collect { up ->
                if (up && !wasUp) recover(RecoveryReason.Network)
                wasUp = up
            }
        }
        scope.launch {
            networkChanges.collect { if (network.value) recover(RecoveryReason.Network) }
        }
        scope.launch { watchdog() }
    }

    /** Nothing synced for a while although the network is up and the app is in front: check the socket. */
    private suspend fun watchdog() {
        combine(synced, network, foreground) { fresh, up, inFront -> !fresh && up && inFront }
            .distinctUntilChanged()
            .collectLatest { stale ->
                if (!stale) return@collectLatest
                var round = 0
                while (true) {
                    delay(backoff(timing.staleAfterMs, round++))
                    recover(RecoveryReason.Stale)?.join()
                }
            }
    }

    private fun backoff(base: Long, round: Int): Long =
        (base shl round.coerceAtMost(6)).coerceAtMost(timing.maxBackoffMs).coerceAtLeast(base)

    /**
     * Starts a check of the connection unless one runs (an `UNAUTHENTICATED` one replaces a milder one). Returns the
     * running check, or null when none applies (signed out, no network, in the background).
     */
    fun recover(reason: RecoveryReason): Job? {
        if (revoked) return null
        if (reason != RecoveryReason.Unauthenticated) {
            if (!network.value) return null
            if (reason != RecoveryReason.Foreground && !foreground.value) return null
        }
        synchronized(recoveryLock) {
            val running = recovery
            if (running != null && running.isActive) {
                if (reason != RecoveryReason.Unauthenticated || recoveryReason == RecoveryReason.Unauthenticated) return running
                running.cancel()
            }
            val job = scope.launch { runRecovery(reason) }
            recovery = job
            recoveryReason = reason
            return job
        }
    }

    private suspend fun runRecovery(reason: RecoveryReason) {
        val link = _link.value
        if (reason == RecoveryReason.Unauthenticated) {
            synced.value = false
            waitBeforeReplacing()
            // A fresh token first, so the new client starts with it (both go through the same token manager).
            val refreshed = withTimeoutOrNull(timing.syncTimeoutMs) {
                runCatching { link.transport.refreshAuth() }.getOrElse { Result.failure(it) }
            }
            if (refreshed?.exceptionOrNull()?.relayCode == RelayErrorCode.REVOKED) return revoke()
            replace(link)
            return
        }
        if (!link.authReady.value) {
            // Still signing in (it failed while the network was down): try again now rather than after its backoff.
            link.authNudge.trySend(Unit)
            val signedIn = withTimeoutOrNull(timing.syncTimeoutMs) { link.authReady.first { it } } != null
            if (!signedIn && _link.value === link) {
                waitBeforeReplacing()
                replace(link)
            }
            return
        }
        synced.value = false
        link.probing = true
        try {
            val refresh = scope.async { runCatching { link.transport.refreshAuth() }.getOrElse { Result.failure(it) } }
            val alive = withTimeoutOrNull(timing.syncTimeoutMs) { synced.first { it } } != null
            if (refresh.isCompleted && refresh.await().exceptionOrNull()?.relayCode == RelayErrorCode.REVOKED) return revoke()
            if (!alive && _link.value === link) {
                waitBeforeReplacing()
                replace(link)
            }
        } finally {
            link.probing = false
        }
    }

    /** After a replacement that did not help, the next waits a while (10 s, 20 s, … up to the maximum). */
    private suspend fun waitBeforeReplacing() {
        if (failedReplacements == 0) return
        val gap = backoff(timing.syncTimeoutMs, failedReplacements - 1)
        val wait = lastReplacedAt + gap - clock()
        if (wait > 0) delay(wait)
    }

    /** A new transport takes over; the old one closes once nothing runs on it any more. */
    private fun replace(old: Link) {
        if (revoked || _link.value !== old) return
        val fresh = Link(connect(), old.number + 1)
        synced.value = false
        failedReplacements++
        lastReplacedAt = clock()
        _link.value = fresh
        startLink(fresh)
        retire(old)
    }

    private fun retire(link: Link) {
        link.retired.value = true
        link.authJob?.cancel()
        synchronized(retiredLinks) { retiredLinks += link }
        scope.launch {
            // Mutations on it either finish or move to the new transport within the grace period.
            withTimeoutOrNull(timing.mutationGraceMs + 1_000) {
                while (link.inFlight.get() > 0) delay(100)
            }
            val stillOpen = synchronized(retiredLinks) { retiredLinks.remove(link) }
            if (stillOpen) link.transport.close()
        }
    }

    private fun startLink(link: Link) {
        link.authJob = scope.launch {
            var attempt = 0
            while (true) {
                val result = link.transport.authenticate()
                if (result.isSuccess) {
                    link.authReady.value = true
                    return@launch
                }
                if (result.exceptionOrNull()?.relayCode == RelayErrorCode.REVOKED) return@launch revoke()
                attempt++
                withTimeoutOrNull((2_000L * attempt).coerceAtMost(30_000L)) { link.authNudge.receive() }
            }
        }
    }

    private fun revoke() {
        if (revoked) return
        revoked = true
        onRevoked()
    }

    /** Looks at a query or mutation error: `REVOKED` signs out, `UNAUTHENTICATED` replaces the transport. */
    fun report(link: Link?, error: Throwable?) {
        when (error?.relayCode) {
            RelayErrorCode.REVOKED -> revoke()
            RelayErrorCode.UNAUTHENTICATED -> if (link == null || link === _link.value) recover(RecoveryReason.Unauthenticated)
            else -> Unit
        }
    }

    /**
     * A realtime query on whichever transport is current; it waits for that one's sign-in so it never runs
     * unauthenticated, and starts again on the next transport by itself.
     */
    fun subscribe(name: String, args: Map<String, Any?>): Flow<Result<JsonElement>> =
        _link.flatMapLatest { link ->
            flow {
                link.authReady.first { it }
                var first = true
                var restarts = 0
                while (true) {
                    link.transport.subscribe(name, args)
                        .catch { error -> emit(Result.failure(error)) }
                        .collect { result ->
                            note(link, result, first)
                            first = false
                            emit(result)
                        }
                    // A subscription never ends by itself; if the client gave up on it, ask again.
                    delay((1_000L shl restarts.coerceAtMost(5)).coerceAtMost(30_000L))
                    restarts++
                }
            }
        }

    private fun note(link: Link, result: Result<JsonElement>, first: Boolean) {
        if (link !== _link.value) return
        if (result.isSuccess) {
            if (!(first && link.probing)) synced.value = true
        } else {
            report(link, result.exceptionOrNull())
        }
    }

    /** A signed-in transport, waiting for one if needed (also across a replacement). */
    private suspend fun readyLink(): Link =
        _link.flatMapLatest { link -> link.authReady.filter { it }.map { link } }.first()

    /**
     * Runs a mutation on the current transport. Should that transport be replaced while it runs, it gets
     * [ConnectionTiming.mutationGraceMs] to finish there and is then sent again on the new one (every mutation the app
     * makes is safe to repeat: prompts and new sessions carry a client id, the rest set a state).
     */
    suspend fun <T> call(block: suspend (RelayTransport) -> T): T {
        while (true) {
            val link = readyLink()
            link.inFlight.incrementAndGet()
            try {
                val outcome: Attempt<T> = try {
                    coroutineScope {
                        val attempt = async { block(link.transport) }
                        val abandon = async {
                            link.retired.first { it }
                            delay(timing.mutationGraceMs)
                        }
                        select {
                            attempt.onAwait { value ->
                                abandon.cancel()
                                Attempt.Done(value)
                            }
                            abandon.onAwait {
                                attempt.cancel()
                                Attempt.Moved
                            }
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    report(link, e)
                    throw e
                }
                if (outcome is Attempt.Done) return outcome.value
            } finally {
                link.inFlight.decrementAndGet()
            }
        }
    }

    private sealed interface Attempt<out T> {
        data class Done<T>(val value: T) : Attempt<T>
        data object Moved : Attempt<Nothing>
    }

    fun close() {
        synchronized(recoveryLock) { recovery?.cancel() }
        val retired = synchronized(retiredLinks) { retiredLinks.toList().also { retiredLinks.clear() } }
        retired.forEach { it.transport.close() }
        _link.value.transport.close()
    }
}
