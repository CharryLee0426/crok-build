package dev.chenli.crok.mobile.auth

import android.content.Context
import dev.chenli.crok.mobile.data.DeviceAuthApi
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.convex.android.AuthProvider
import java.util.concurrent.CopyOnWriteArraySet
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Keeps a valid device access JWT. Refreshes it over the HTTP API (`deviceAuth:refresh`) five minutes before it runs
 * out and whenever a Convex client reconnects ([token] with `force`), and hands every new one from the background
 * refresh to its listeners (each Convex client's `onIdToken`). A `REVOKED` answer calls [onRevoked]: the phone signs
 * out.
 */
class TokenManager(
    private val api: DeviceAuthApi,
    initial: StoredCredentials,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val onTokens: (accessToken: String, expiresAt: Long) -> Unit = { _, _ -> },
    private val onRevoked: () -> Unit = {},
) {
    private val refreshToken = initial.refreshToken
    private val mutex = Mutex()

    @Volatile private var accessToken: String? = initial.accessToken

    @Volatile private var expiresAt: Long = initial.accessTokenExpiresAt

    /** When this process last fetched a token; null until the first refresh. */
    @Volatile private var fetchedAt: Long? = null

    @Volatile private var revoked = false

    /** Every live Convex client's token callback; a replaced client takes its own out again. */
    private val listeners = CopyOnWriteArraySet<(String?) -> Unit>()

    private var job: Job? = null

    fun addListener(listener: (String?) -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: (String?) -> Unit) {
        listeners -= listener
    }

    /**
     * A valid access token. With [force] (a reconnect, or the server refused the token) it is refreshed unless one was
     * fetched in the last 30 s; without, only when it runs out within five minutes.
     *
     * A refresh that fails for any reason but `REVOKED` (no network yet, right after the phone wakes up or changes
     * networks) still answers with the current token while that has not expired: the Convex client caches whatever this
     * returns and reconnects with it, and a missing token would leave it connected without a user — every query then
     * fails with `UNAUTHENTICATED` and nothing reconnects it.
     */
    suspend fun token(force: Boolean): Result<String> = mutex.withLock {
        val now = clock()
        val current = accessToken
        val valid = current != null && expiresAt - now > REFRESH_AHEAD_MS
        val recent = fetchedAt?.let { now - it < RECENT_MS } ?: false
        if (current != null && valid && (!force || recent)) return@withLock Result.success(current)
        val refreshed = refreshLocked()
        if (refreshed.isFailure && !revoked && current != null && expiresAt - clock() > USABLE_MARGIN_MS) {
            return@withLock Result.success(current)
        }
        refreshed
    }

    /** Refreshes now (unless one was fetched in the last 30 s); unlike [token], a failure is reported as one. */
    suspend fun refresh(): Result<String> = mutex.withLock {
        val current = accessToken
        val recent = fetchedAt?.let { clock() - it < RECENT_MS } ?: false
        if (current != null && recent && expiresAt - clock() > USABLE_MARGIN_MS) return@withLock Result.success(current)
        refreshLocked()
    }

    /** The current token while it is still good for at least [USABLE_MARGIN_MS], without asking the relay. */
    fun currentToken(): String? = accessToken?.takeIf { expiresAt - clock() > USABLE_MARGIN_MS && !revoked }

    private suspend fun refreshLocked(): Result<String> {
        if (revoked) return Result.failure(RelayException(RelayErrorCode.REVOKED, "This device was signed out."))
        return try {
            val fresh = api.refresh(refreshToken)
            accessToken = fresh.accessToken
            expiresAt = fresh.accessTokenExpiresAt
            fetchedAt = clock()
            onTokens(fresh.accessToken, fresh.accessTokenExpiresAt)
            Result.success(fresh.accessToken)
        } catch (e: CancellationException) {
            throw e
        } catch (e: RelayException) {
            if (e.code == RelayErrorCode.REVOKED) {
                revoked = true
                listeners.forEach { it(null) }
                onRevoked()
            }
            Result.failure(e)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /** Starts the background refresh: wakes up at most once a minute and refreshes five minutes ahead of expiry. */
    fun start() {
        if (job != null) return
        job = scope.launch {
            var failures = 0
            while (isActive && !revoked) {
                val until = expiresAt - REFRESH_AHEAD_MS - clock()
                if (until > 0 && accessToken != null) {
                    // At most a minute at a time: the clock is wall time, and a sleeping phone's delay() stands still.
                    delay(until.coerceAtMost(MAX_SLEEP_MS))
                    continue
                }
                val result = mutex.withLock { refreshLocked() }
                if (result.isSuccess) {
                    failures = 0
                    val token = result.getOrThrow()
                    listeners.forEach { it(token) }
                } else {
                    if (revoked) return@launch
                    failures++
                    delay((RETRY_BASE_MS * failures).coerceAtMost(MAX_SLEEP_MS))
                }
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        listeners.clear()
    }

    val currentExpiry: Long get() = expiresAt

    companion object {
        const val REFRESH_AHEAD_MS = 5 * 60 * 1000L
        const val RECENT_MS = 30_000L
        const val MAX_SLEEP_MS = 60_000L
        const val RETRY_BASE_MS = 5_000L

        /** A token this close to its expiry is not handed out any more: it could run out on the way. */
        const val USABLE_MARGIN_MS = 30_000L
    }
}

/** What `ConvexClientWithAuth` keeps after signing in: the current device JWT. */
data class DeviceToken(val accessToken: String)

/**
 * One Convex client's [AuthProvider] for a linked device. There is no interactive login here — the device flow ran
 * before the engine existed — so [login] and [loginFromCache] both mean "get a fresh access token". Each client gets its
 * own provider: [close] (when the engine replaces the client) unhooks it from [tokens], so a retired client never takes
 * a token meant for its successor.
 */
class DeviceAuthProvider(private val tokens: TokenManager) : AuthProvider<DeviceToken> {
    @Volatile private var onIdToken: ((String?) -> Unit)? = null

    @Volatile private var closed = false

    private val forward: (String?) -> Unit = { token -> if (!closed) onIdToken?.invoke(token) }

    override suspend fun login(context: Context, onIdToken: (String?) -> Unit): Result<DeviceToken> =
        loginFromCache(onIdToken)

    override suspend fun loginFromCache(onIdToken: (String?) -> Unit): Result<DeviceToken> {
        if (!closed) {
            this.onIdToken = onIdToken
            tokens.addListener(forward)
        }
        return tokens.token(force = true).map { DeviceToken(it) }
    }

    /** Hands [token] to this provider's client, which authenticates its socket again with it. */
    fun push(token: String) {
        forward(token)
    }

    override suspend fun logout(context: Context): Result<Void?> {
        close()
        return Result.success(null)
    }

    fun close() {
        closed = true
        tokens.removeListener(forward)
        onIdToken = null
    }

    override fun extractIdToken(authResult: DeviceToken): String = authResult.accessToken
}
