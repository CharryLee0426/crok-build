package dev.chenli.crok.mobile.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer

enum class ThemeMode { System, Light, Dark }

/** Per-app settings that are not secret. The relay is built in (`BuildConfig.RELAY_URL`), so it is not one of them. */
data class AppSettings(
    val theme: ThemeMode = ThemeMode.System,
    /** Profile › Appearance › Session Theme (mobile/DESIGN.md "Session themes"): a theme id, `none` by default. */
    val sessionTheme: String = "none",
    /** Blur the Photo theme's picture. */
    val sessionThemeBlur: Boolean = false,
    /** Changes whenever a new photo is chosen, so screens load it again. */
    val photoStamp: Long = 0,
)

private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "crok_settings")

class SettingsStore(private val context: Context) {
    private val themeKey = stringPreferencesKey("theme")
    private val sessionThemeKey = stringPreferencesKey("crok.sessionTheme")
    private val blurKey = booleanPreferencesKey("crok.sessionThemeBlur")
    private val photoStampKey = longPreferencesKey("crok.sessionThemePhoto")

    val settings: Flow<AppSettings> = context.settingsDataStore.data.map { prefs ->
        AppSettings(
            theme = prefs[themeKey]?.let { raw -> ThemeMode.entries.firstOrNull { it.name == raw } } ?: ThemeMode.System,
            sessionTheme = prefs[sessionThemeKey] ?: "none",
            sessionThemeBlur = prefs[blurKey] ?: false,
            photoStamp = prefs[photoStampKey] ?: 0,
        )
    }

    suspend fun setTheme(mode: ThemeMode) {
        context.settingsDataStore.edit { it[themeKey] = mode.name }
    }

    suspend fun setSessionTheme(id: String) {
        context.settingsDataStore.edit { it[sessionThemeKey] = id }
    }

    suspend fun setSessionThemeBlur(blur: Boolean) {
        context.settingsDataStore.edit { it[blurKey] = blur }
    }

    /** A new photo was stored: select the Photo theme and make screens load it again. */
    suspend fun photoChosen(stamp: Long) {
        context.settingsDataStore.edit {
            it[photoStampKey] = stamp
            it[sessionThemeKey] = "photo"
        }
    }
}

/**
 * The computer the Sessions tab shows (`crok.selectedComputer`), remembered on this phone; the list falls back to the
 * most recently active computer when it is unset or gone (`Computers.selected`).
 */
class ComputerSelectionStore(private val kv: KeyValueStore) {
    private val _selected = MutableStateFlow(kv.get(KEY))

    val selected: StateFlow<String?> = _selected.asStateFlow()

    fun select(deviceId: String) {
        if (_selected.value == deviceId) return
        _selected.value = deviceId
        kv.put(KEY, deviceId)
    }

    fun clear() {
        kv.put(KEY, null)
        _selected.value = null
    }

    private companion object {
        const val KEY = "crok.selectedComputer"
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
    private val serializer = ListSerializer(SessionGroup.serializer())

    private fun file(deviceId: String) = File(dir, "groups-${deviceId.filter { it.isLetterOrDigit() }}.json")

    suspend fun load(deviceId: String): List<SessionGroup>? = withContext(Dispatchers.IO) {
        val file = file(deviceId)
        if (!file.exists()) return@withContext null
        runCatching { RelayJson.decodeFromString(serializer, file.readText()) }.getOrNull()
    }

    suspend fun save(deviceId: String, groups: List<SessionGroup>) = withContext(Dispatchers.IO) {
        runCatching {
            dir.mkdirs()
            val target = file(deviceId)
            val temp = File(dir, target.name + ".tmp")
            temp.writeText(RelayJson.encodeToString(serializer, groups))
            temp.renameTo(target)
        }
        Unit
    }

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }
}
