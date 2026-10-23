package dev.chenli.crok.mobile

import android.app.Application
import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.ProcessLifecycleOwner
import dev.chenli.crok.mobile.auth.AuthStore
import dev.chenli.crok.mobile.auth.DeviceInfo
import dev.chenli.crok.mobile.data.ComputerSelectionStore
import dev.chenli.crok.mobile.data.DeviceAuthApiFactory
import dev.chenli.crok.mobile.data.DraftStore
import dev.chenli.crok.mobile.data.HttpDeviceAuthApi
import dev.chenli.crok.mobile.data.KeystoreSecretBox
import dev.chenli.crok.mobile.data.PrefsKeyValueStore
import dev.chenli.crok.mobile.data.SessionListCache
import dev.chenli.crok.mobile.data.SettingsStore
import dev.chenli.crok.mobile.engine.AppForeground
import dev.chenli.crok.mobile.engine.NetworkMonitor
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class CrokApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }

    override fun onCreate() {
        super.onCreate()
        graph.foreground.observe(ProcessLifecycleOwner.get().lifecycle)
    }
}

/** The app's long-lived objects; screens reach the per-account ones through the CrokEngine instead. */
class AppGraph(val context: Context) {
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val authStore = AuthStore(PrefsKeyValueStore(context, "crok_secure"), KeystoreSecretBox())
    val settingsStore = SettingsStore(context)
    val drafts = DraftStore(PrefsKeyValueStore(context, "crok_drafts"))
    val sessionCache = SessionListCache(File(context.filesDir, "session-cache"))
    val computerSelection = ComputerSelectionStore(PrefsKeyValueStore(context, "crok_selection"))

    /** The Photo session theme's picture (Profile › Appearance › Choose a Photo), downscaled; kept across sign-ins. */
    val sessionBackgroundFile = File(context.filesDir, "session-background.jpg")
    val network by lazy { NetworkMonitor(context, appScope) }

    /** Whether the app is in front: coming back to it checks the relay connection. */
    val foreground = AppForeground()
    val apiFactory: DeviceAuthApiFactory = HttpDeviceAuthApi.Factory

    /**
     * The relay this build signs in to (`RELAY_URL` in app/build.gradle.kts): the development relay in debug builds, the
     * production one in release builds; `-PcrokRelayEnv` / `-PcrokRelayUrl` pick another.
     */
    val relayUrl: String = BuildConfig.RELAY_URL

    /** How this phone shows up in the Devices list and on the approval page. */
    fun deviceInfo(): DeviceInfo {
        val name = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: modelName()
        return DeviceInfo(
            name = name,
            platform = "Android ${Build.VERSION.RELEASE}",
            client = "Crok Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
        )
    }

    private fun modelName(): String {
        val model = Build.MODEL.orEmpty()
        val maker = Build.MANUFACTURER.orEmpty()
        return when {
            model.isBlank() -> "Android phone"
            model.startsWith(maker, ignoreCase = true) -> model
            else -> "${maker.replaceFirstChar { it.titlecase() }} $model"
        }
    }

    /** Forgets everything that belongs to the signed-out account. */
    fun clearAccountData() {
        drafts.clear()
        sessionCache.clear()
        computerSelection.clear()
    }
}
