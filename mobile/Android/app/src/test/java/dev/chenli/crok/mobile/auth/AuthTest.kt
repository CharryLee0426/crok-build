package dev.chenli.crok.mobile.auth

import dev.chenli.crok.mobile.data.DeviceAuthApi
import dev.chenli.crok.mobile.data.DeviceAuthApiFactory
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.data.PollResult
import dev.chenli.crok.mobile.data.RefreshResult
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayNetworkException
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.SecretBox
import dev.chenli.crok.mobile.data.StartResult
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** XOR "encryption": enough to prove nothing is stored in plain text and that a wrong key reads as absent. */
private class FakeBox(private val key: Byte = 0x5A) : SecretBox {
    override fun seal(plain: ByteArray) = plain.map { (it.toInt() xor key.toInt()).toByte() }.toByteArray() + byteArrayOf(key)

    override fun open(sealed: ByteArray): ByteArray {
        require(sealed.last() == key) { "wrong key" }
        return sealed.dropLast(1).map { (it.toInt() xor key.toInt()).toByte() }.toByteArray()
    }
}

private class FakeApi : DeviceAuthApi {
    val polls = ArrayDeque<() -> PollResult>()
    var started = 0
    var loggedOut: String? = null
    var refreshes = 0
    var refreshAnswer: () -> RefreshResult = { RefreshResult("dev-1", "jwt-${++refreshes}", 0) }

    override suspend fun start(kind: String, name: String, platform: String, client: String): StartResult {
        started++
        assertEquals("phone", kind)
        return StartResult("crd_secret", "BCDF-GHJK", "https://web/link", "https://web/link?code=BCDF-GHJK", expiresAt = 600_000, interval = 2)
    }

    override suspend fun poll(deviceCode: String): PollResult {
        assertEquals("crd_secret", deviceCode)
        return polls.removeFirstOrNull()?.invoke() ?: PollResult(PollResult.PENDING)
    }

    override suspend fun refresh(refreshToken: String): RefreshResult = refreshAnswer()

    override suspend fun logout(refreshToken: String) {
        loggedOut = refreshToken
    }
}

/** The relay a test build has built in. */
private const val RELAY = "https://relay.example"

@OptIn(ExperimentalCoroutinesApi::class)
class AuthControllerTest {
    private val kv = MemoryKeyValueStore()
    private val store = AuthStore(kv, FakeBox(), BytesCodec.Jvm)
    private val api = FakeApi()
    private val factory = DeviceAuthApiFactory { api }
    private val device = DeviceInfo("Pixel 9", "Android 16", "Crok Android 1.0 (1)")

    private fun TestScope.controller() = AuthController(store, factory, backgroundScope, RELAY) { testScheduler.currentTime }

    private val approved = PollResult(
        status = PollResult.APPROVED,
        deviceId = "dev-1",
        refreshToken = "crr_refresh",
        accessToken = "jwt-0",
        accessTokenExpiresAt = 3_600_000,
        user = RelayUser("Chen", "chen@example.com", null),
    )

    @Test
    fun signsInThroughTheWholeFlow() = runTest {
        val auth = controller()
        auth.restore()
        assertEquals(AuthState.SignedOut(), auth.state.value)
        auth.startSignIn(device)
        runCurrent()
        val waiting = auth.state.value as AuthState.Waiting
        assertEquals("BCDF-GHJK", waiting.pending.userCode)
        assertEquals("https://web/link?code=BCDF-GHJK&app=1", waiting.pending.browserUrl)
        // The browser opens once.
        assertEquals(AuthEffect.OpenBrowser("https://web/link?code=BCDF-GHJK&app=1"), auth.effects.first())

        api.polls += { approved }
        advanceTimeBy(2_100)
        val signedIn = auth.state.value as AuthState.SignedIn
        assertEquals("dev-1", signedIn.credentials.deviceId)
        assertEquals("Pixel 9", signedIn.credentials.deviceName)
        // Stored encrypted, the pending sign-in forgotten.
        assertEquals("crr_refresh", store.loadCredentials()!!.refreshToken)
        assertNull(store.loadPending())
        assertFalse(kv.get("credentials.v1")!!.contains("crr_refresh"))
    }

    @Test
    fun aKilledAppResumesWaiting() = runTest {
        val firstProcess = CoroutineScope(StandardTestDispatcher(testScheduler) + Job())
        val first = AuthController(store, factory, firstProcess, RELAY) { testScheduler.currentTime }
        first.restore()
        first.startSignIn(device)
        runCurrent()
        assertTrue(first.state.value is AuthState.Waiting)
        firstProcess.cancel() // the process dies while waiting

        // A new process: same store, new controller. It resumes waiting and polls at once.
        val second = controller()
        second.restore()
        assertEquals("BCDF-GHJK", (second.state.value as AuthState.Waiting).pending.userCode)
        api.polls += { approved }
        runCurrent()
        assertTrue(second.state.value is AuthState.SignedIn)
        // And the next start finds the credentials.
        val third = controller()
        third.restore()
        assertTrue(third.state.value is AuthState.SignedIn)
    }

    @Test
    fun anExpiredPendingSignInIsDropped() = runTest {
        store.savePending(PendingSignIn(RELAY, "crd_secret", "BCDF-GHJK", null, expiresAt = 5_000))
        val auth = AuthController(store, factory, backgroundScope, RELAY) { 6_000 }
        auth.restore()
        assertEquals(AuthState.SignedOut(SignInError.Expired), auth.state.value)
        assertNull(store.loadPending())
    }

    /** A release build (production relay) installed over a debug one (development relay) must not use its sign-in. */
    @Test
    fun aSignInFromAnotherRelayIsForgotten() = runTest {
        store.saveCredentials(StoredCredentials("https://limitless-badger-727.convex.cloud", "dev-1", "crr_refresh"))
        val auth = AuthController(store, factory, backgroundScope, "https://tacit-finch-29.convex.cloud") { testScheduler.currentTime }
        auth.restore()
        assertEquals(AuthState.SignedOut(SignInError.RelayChanged), auth.state.value)
        assertNull(store.loadCredentials())
        assertNull(kv.get("credentials.v1"))
        // Nothing goes to either relay: the sign-in is only forgotten here.
        assertNull(api.loggedOut)
        // And the next start is a plain signed-out one.
        val next = AuthController(store, factory, backgroundScope, "https://tacit-finch-29.convex.cloud") { testScheduler.currentTime }
        next.restore()
        assertEquals(AuthState.SignedOut(), next.state.value)
    }

    @Test
    fun aSignInFromTheSameRelayIsKeptWhateverItsTrailingSlash() = runTest {
        store.saveCredentials(StoredCredentials("$RELAY/", "dev-1", "crr_refresh"))
        val auth = controller()
        auth.restore()
        assertEquals("dev-1", (auth.state.value as AuthState.SignedIn).credentials.deviceId)

        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val slashed = AuthController(store, factory, backgroundScope, "$RELAY/") { testScheduler.currentTime }
        slashed.restore()
        assertTrue(slashed.state.value is AuthState.SignedIn)
        assertNotNull(store.loadCredentials())
    }

    @Test
    fun aPendingSignInOnAnotherRelayIsDropped() = runTest {
        store.savePending(PendingSignIn("https://other.example", "crd_secret", "BCDF-GHJK", null, expiresAt = 600_000))
        val auth = controller()
        auth.restore()
        assertEquals(AuthState.SignedOut(SignInError.RelayChanged), auth.state.value)
        assertNull(store.loadPending())
        // It does not keep polling the other relay.
        advanceTimeBy(10_000)
        assertEquals(AuthState.SignedOut(SignInError.RelayChanged), auth.state.value)
    }

    @Test
    fun deniedAndExpiredEndTheWait() = runTest {
        val auth = controller()
        auth.restore()
        auth.startSignIn(device)
        runCurrent()
        api.polls += { PollResult(PollResult.DENIED) }
        advanceTimeBy(2_100)
        assertEquals(AuthState.SignedOut(SignInError.Denied), auth.state.value)
        assertNull(store.loadPending())

        auth.startSignIn(device)
        runCurrent()
        // Past the code's lifetime the phone stops polling by itself.
        advanceTimeBy(700_000)
        assertEquals(AuthState.SignedOut(SignInError.Expired), auth.state.value)
    }

    @Test
    fun networkTroubleKeepsWaiting() = runTest {
        val auth = controller()
        auth.restore()
        auth.startSignIn(device)
        runCurrent()
        api.polls += { throw RelayNetworkException("down") }
        advanceTimeBy(2_100)
        assertTrue((auth.state.value as AuthState.Waiting).offline)
        api.polls += { approved }
        advanceTimeBy(5_000)
        assertTrue(auth.state.value is AuthState.SignedIn)
    }

    @Test
    fun pollNowSkipsTheWait() = runTest {
        val auth = controller()
        auth.restore()
        auth.startSignIn(device)
        runCurrent()
        api.polls += { approved }
        auth.pollNow()
        runCurrent()
        assertTrue(auth.state.value is AuthState.SignedIn)
    }

    @Test
    fun signsInToTheBuiltInRelayWithoutAskingForAServer() = runTest {
        val urls = mutableListOf<String>()
        val auth = AuthController(store, { url -> urls += url; api }, backgroundScope, "https://limitless-badger-727.convex.cloud/") {
            testScheduler.currentTime
        }
        auth.restore()
        auth.startSignIn(device)
        runCurrent()
        val pending = (auth.state.value as AuthState.Waiting).pending
        // Start and poll both go to the built-in relay, and the credentials remember it.
        assertEquals("https://limitless-badger-727.convex.cloud", pending.serverUrl)
        assertEquals(listOf("https://limitless-badger-727.convex.cloud"), urls.distinct())
        api.polls += { approved }
        advanceTimeBy(2_100)
        assertEquals("https://limitless-badger-727.convex.cloud", (auth.state.value as AuthState.SignedIn).credentials.serverUrl)
        assertEquals(1, api.started)
    }

    @Test
    fun aBuildWithoutARelayCannotStart() = runTest {
        val auth = AuthController(store, factory, backgroundScope, " ") { testScheduler.currentTime }
        auth.restore()
        auth.startSignIn(device)
        assertTrue((auth.state.value as AuthState.SignedOut).error is SignInError.Other)
        assertEquals(0, api.started)
    }

    @Test
    fun cancelForgetsThePendingSignIn() = runTest {
        val auth = controller()
        auth.restore()
        auth.startSignIn(device)
        runCurrent()
        auth.cancel()
        assertEquals(AuthState.SignedOut(), auth.state.value)
        assertNull(store.loadPending())
    }

    @Test
    fun signOutUnlinksAndWipes() = runTest {
        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val auth = controller()
        auth.restore()
        assertTrue(auth.state.value is AuthState.SignedIn)
        auth.signOut()
        runCurrent()
        assertEquals(AuthState.SignedOut(), auth.state.value)
        assertNull(store.loadCredentials())
        assertEquals("crr_refresh", api.loggedOut)
    }

    @Test
    fun revokedSignsOutWithAReason() = runTest {
        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val auth = controller()
        auth.restore()
        auth.onRevoked()
        assertEquals(AuthState.SignedOut(SignInError.Revoked), auth.state.value)
        assertNull(store.loadCredentials())
    }

    @Test
    fun aLostKeyReadsAsSignedOut() = runTest {
        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val other = AuthStore(kv, FakeBox(key = 0x11), BytesCodec.Jvm)
        assertNull(other.loadCredentials())
        assertNull(kv.get("credentials.v1"))
    }

    @Test
    fun demoNeverMixesWithARealAccount() = runTest {
        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val auth = controller()
        auth.restore()
        auth.enterDemo(StoredCredentials("demo", "demo-phone", "demo"))
        assertEquals("dev-1", (auth.state.value as AuthState.SignedIn).credentials.deviceId)

        val fresh = AuthStore(MemoryKeyValueStore(), FakeBox(), BytesCodec.Jvm)
        val signedOut = AuthController(fresh, factory, backgroundScope, RELAY)
        signedOut.restore()
        signedOut.enterDemo(StoredCredentials("demo", "demo-phone", "demo"))
        assertTrue((signedOut.state.value as AuthState.SignedIn).demo)
        signedOut.signOut()
        runCurrent()
        assertEquals(AuthState.SignedOut(), signedOut.state.value)
        assertNull(api.loggedOut)
    }

    @Test
    fun savesTokensAndUser() = runTest {
        store.saveCredentials(StoredCredentials(RELAY, "dev-1", "crr_refresh"))
        val auth = controller()
        auth.restore()
        auth.saveTokens("jwt-9", 99)
        assertEquals("jwt-9", store.loadCredentials()!!.accessToken)
        auth.saveUser(RelayUser("New Name", null, null))
        assertEquals("New Name", (auth.state.value as AuthState.SignedIn).credentials.user.name)
        assertEquals("New Name", store.loadCredentials()!!.user.name)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class TokenManagerTest {
    private val credentials = StoredCredentials("https://r", "dev-1", "crr_refresh", accessToken = "jwt-0", accessTokenExpiresAt = 3_600_000)

    @Test
    fun reconnectRefreshesUnlessJustRefreshed() = runTest {
        val api = FakeApi().apply { refreshAnswer = { RefreshResult("dev-1", "jwt-${++refreshes}", testScheduler.currentTime + 3_600_000) } }
        val tokens = TokenManager(api, credentials, backgroundScope, { testScheduler.currentTime })
        assertEquals("jwt-0", tokens.token(force = false).getOrThrow())
        assertEquals("jwt-1", tokens.token(force = true).getOrThrow())
        // A second reconnect right away reuses it.
        assertEquals("jwt-1", tokens.token(force = true).getOrThrow())
        advanceTimeBy(31_000)
        assertEquals("jwt-2", tokens.token(force = true).getOrThrow())
    }

    @Test
    fun refreshesFiveMinutesBeforeExpiryAndPushesTheToken() = runTest {
        val api = FakeApi().apply { refreshAnswer = { RefreshResult("dev-1", "jwt-${++refreshes}", testScheduler.currentTime + 3_600_000) } }
        val pushed = mutableListOf<String?>()
        val saved = mutableListOf<String>()
        val tokens = TokenManager(api, credentials, backgroundScope, { testScheduler.currentTime }, onTokens = { t, _ -> saved += t })
        tokens.addListener { pushed += it }
        tokens.start()
        advanceTimeBy(3_600_000 - 5 * 60_000 - 1_000)
        assertTrue(pushed.isEmpty())
        advanceTimeBy(70_000)
        assertEquals(listOf<String?>("jwt-1"), pushed)
        assertEquals(listOf("jwt-1"), saved)
        tokens.stop()
    }

    @Test
    fun revokedClearsTheClientAndSignsOut() = runTest {
        val api = FakeApi().apply { refreshAnswer = { throw RelayException(RelayErrorCode.REVOKED, "signed out") } }
        var revoked = false
        val pushed = mutableListOf<String?>()
        val tokens = TokenManager(api, credentials, backgroundScope, { testScheduler.currentTime }, onRevoked = { revoked = true })
        tokens.addListener { pushed += it }
        val result = tokens.token(force = true)
        assertTrue(result.isFailure)
        assertTrue(revoked)
        assertEquals(listOf<String?>(null), pushed)
        assertNotNull(result.exceptionOrNull() as? RelayException)
    }

    /**
     * The bug behind "the app loses the connection and shows no sessions until it is killed": the Convex client asks for
     * a forced refresh on every reconnect and caches what it gets — a null after a failed refresh (the network not back
     * yet after the phone woke up) made it reconnect without a user, for good. A token that is still valid is kept.
     */
    @Test
    fun aFailedRefreshOnReconnectKeepsTheStillValidToken() = runTest {
        var down = true
        val api = FakeApi().apply {
            refreshAnswer = {
                if (down) throw RelayNetworkException("Unable to resolve host")
                RefreshResult("dev-1", "jwt-${++refreshes}", testScheduler.currentTime + 3_600_000)
            }
        }
        val tokens = TokenManager(api, credentials, backgroundScope, { testScheduler.currentTime })
        assertEquals("jwt-0", tokens.token(force = true).getOrThrow())
        // An explicit refresh reports the failure, so the engine knows the socket did not get a new token.
        assertTrue(tokens.refresh().isFailure)
        down = false
        assertEquals("jwt-1", tokens.token(force = true).getOrThrow())
    }

    @Test
    fun anExpiredTokenIsNotHandedOutWhenTheRefreshFails() = runTest {
        val api = FakeApi().apply { refreshAnswer = { throw RelayNetworkException("down") } }
        val tokens = TokenManager(api, credentials.copy(accessTokenExpiresAt = 10_000), backgroundScope, { testScheduler.currentTime })
        advanceTimeBy(20_000)
        assertTrue(tokens.token(force = true).isFailure)
        assertNull(tokens.currentToken())
    }

    @Test
    fun aClosedProviderNoLongerTakesTokens() = runTest {
        val api = FakeApi().apply { refreshAnswer = { RefreshResult("dev-1", "jwt-${++refreshes}", testScheduler.currentTime + 600_000) } }
        val tokens = TokenManager(api, credentials.copy(accessTokenExpiresAt = 0), backgroundScope, { testScheduler.currentTime })
        val old = DeviceAuthProvider(tokens)
        val new = DeviceAuthProvider(tokens)
        val toOld = mutableListOf<String?>()
        val toNew = mutableListOf<String?>()
        old.loginFromCache { toOld += it }
        new.loginFromCache { toNew += it }
        // The engine replaced the old client: its provider is closed and must not take the next token.
        old.close()
        tokens.start()
        advanceTimeBy(600_000)
        assertTrue(toOld.isEmpty())
        assertTrue(toNew.isNotEmpty())
        tokens.stop()
    }

    @Test
    fun networkFailuresAreNotRevocations() = runTest {
        val api = FakeApi().apply { refreshAnswer = { throw RelayNetworkException("down") } }
        var revoked = false
        val tokens = TokenManager(api, credentials.copy(accessToken = null), backgroundScope, { testScheduler.currentTime }, onRevoked = { revoked = true })
        assertTrue(tokens.token(force = true).isFailure)
        assertFalse(revoked)
    }
}
