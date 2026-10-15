package dev.chenli.crok.mobile.auth

import android.util.Base64
import dev.chenli.crok.mobile.data.KeyValueStore
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.RelayUser
import dev.chenli.crok.mobile.data.SecretBox
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable

/** What a signed-in phone keeps: everything needed to get a new access token after the app restarts. */
@Serializable
data class StoredCredentials(
    val serverUrl: String,
    val deviceId: String,
    val refreshToken: String,
    val accessToken: String? = null,
    val accessTokenExpiresAt: Long = 0,
    val user: RelayUser = RelayUser(),
    val deviceName: String = "",
)

/**
 * A sign-in waiting for approval, persisted so a killed app resumes waiting (Telegram's LoginActivity keeps its page
 * and parameters the same way). [deviceCode] is a secret, so this is stored encrypted too.
 */
@Serializable
data class PendingSignIn(
    val serverUrl: String,
    val deviceCode: String,
    val userCode: String,
    val verificationUrlComplete: String? = null,
    val expiresAt: Long,
    val intervalSeconds: Int = 2,
    val deviceName: String = "",
    val startedAt: Long = 0,
) {
    /** The approval page in the browser; `app=1` makes it end on `crok://signed-in` so the browser sheet closes. */
    val browserUrl: String?
        get() = verificationUrlComplete?.let { url -> if ("?" in url) "$url&app=1" else "$url?app=1" }
}

/** Encodes bytes for a string store; Android's Base64 in the app, java.util's in JVM tests. */
interface BytesCodec {
    fun encode(bytes: ByteArray): String
    fun decode(text: String): ByteArray = throw UnsupportedOperationException()

    companion object {
        val Android = object : BytesCodec {
            override fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
            override fun decode(text: String): ByteArray = Base64.decode(text, Base64.NO_WRAP)
        }
        val Jvm = object : BytesCodec {
            override fun encode(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)
            override fun decode(text: String): ByteArray = java.util.Base64.getDecoder().decode(text)
        }
    }
}

/** The encrypted store for credentials and the pending sign-in. Anything that fails to decrypt reads as absent. */
class AuthStore(
    private val kv: KeyValueStore,
    private val box: SecretBox,
    private val codec: BytesCodec = BytesCodec.Android,
) {
    fun loadCredentials(): StoredCredentials? = read(KEY_CREDENTIALS, StoredCredentials.serializer())

    fun saveCredentials(credentials: StoredCredentials?) = write(KEY_CREDENTIALS, StoredCredentials.serializer(), credentials)

    fun loadPending(): PendingSignIn? = read(KEY_PENDING, PendingSignIn.serializer())

    fun savePending(pending: PendingSignIn?) = write(KEY_PENDING, PendingSignIn.serializer(), pending)

    fun clear() {
        kv.put(KEY_CREDENTIALS, null)
        kv.put(KEY_PENDING, null)
    }

    private fun <T> read(key: String, serializer: KSerializer<T>): T? {
        val stored = kv.get(key) ?: return null
        return try {
            val plain = box.open(codec.decode(stored))
            RelayJson.decodeFromString(serializer, plain.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            // A lost Keystore key or a format change: forget it rather than crash on every start.
            kv.put(key, null)
            null
        }
    }

    private fun <T> write(key: String, serializer: KSerializer<T>, value: T?) {
        if (value == null) {
            kv.put(key, null)
            return
        }
        val plain = RelayJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8)
        kv.put(key, codec.encode(box.seal(plain)))
    }

    private companion object {
        const val KEY_CREDENTIALS = "credentials.v1"
        const val KEY_PENDING = "pending-sign-in.v1"
    }
}
