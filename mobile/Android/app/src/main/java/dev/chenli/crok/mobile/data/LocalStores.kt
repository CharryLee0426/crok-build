package dev.chenli.crok.mobile.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer

enum class ThemeMode { System, Light, Dark }

/** Per-app settings that are not secret: appearance and the Server override from the Welcome screen. */
data class AppSettings(
    val theme: ThemeMode = ThemeMode.System,
    val serverOverride: String? = null,
)

private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "crok_settings")

class SettingsStore(private val context: Context) {
    private val themeKey = stringPreferencesKey("theme")
    private val serverKey = stringPreferencesKey("server")

    val settings: Flow<AppSettings> = context.settingsDataStore.data.map { prefs ->
        AppSettings(
            theme = prefs[themeKey]?.let { raw -> ThemeMode.entries.firstOrNull { it.name == raw } } ?: ThemeMode.System,
            serverOverride = prefs[serverKey]?.takeIf { it.isNotBlank() },
        )
    }

    suspend fun setTheme(mode: ThemeMode) {
        context.settingsDataStore.edit { it[themeKey] = mode.name }
    }

    suspend fun setServer(url: String?) {
        context.settingsDataStore.edit { prefs ->
            if (url.isNullOrBlank()) prefs.remove(serverKey) else prefs[serverKey] = url
        }
    }
}

/** The composer's unsent text per session (Telegram's `saveDraft`): survives the app being killed. */
class DraftStore(private val kv: KeyValueStore) {
    fun load(sessionDocId: String): String = kv.get(sessionDocId).orEmpty()

    fun save(sessionDocId: String, text: String) = kv.put(sessionDocId, text.ifEmpty { null })

    fun clear() = kv.clear()
}

/** The last session list, so the app opens instantly on the cached list while it reconnects. One file per account. */
class SessionListCache(private val dir: File) {
    private val serializer = ListSerializer(SessionRow.serializer())

    private fun file(deviceId: String) = File(dir, "sessions-${deviceId.filter { it.isLetterOrDigit() }}.json")

    suspend fun load(deviceId: String): List<SessionRow>? = withContext(Dispatchers.IO) {
        val file = file(deviceId)
        if (!file.exists()) return@withContext null
        runCatching { RelayJson.decodeFromString(serializer, file.readText()) }.getOrNull()
    }

    suspend fun save(deviceId: String, rows: List<SessionRow>) = withContext(Dispatchers.IO) {
        runCatching {
            dir.mkdirs()
            val target = file(deviceId)
            val temp = File(dir, target.name + ".tmp")
            temp.writeText(RelayJson.encodeToString(serializer, rows))
            temp.renameTo(target)
        }
        Unit
    }

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }
}
