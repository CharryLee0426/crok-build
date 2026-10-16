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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer

enum class ThemeMode { System, Light, Dark }

/** Per-app settings that are not secret. The relay is built in (`BuildConfig.RELAY_URL`), so it is not one of them. */
data class AppSettings(
    val theme: ThemeMode = ThemeMode.System,
)

private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "crok_settings")

class SettingsStore(private val context: Context) {
    private val themeKey = stringPreferencesKey("theme")

    val settings: Flow<AppSettings> = context.settingsDataStore.data.map { prefs ->
        AppSettings(
            theme = prefs[themeKey]?.let { raw -> ThemeMode.entries.firstOrNull { it.name == raw } } ?: ThemeMode.System,
        )
    }

    suspend fun setTheme(mode: ThemeMode) {
        context.settingsDataStore.edit { it[themeKey] = mode.name }
    }
}

/** The composer's unsent text per session (Telegram's `saveDraft`): survives the app being killed. */
class DraftStore(private val kv: KeyValueStore) {
    fun load(sessionDocId: String): String = kv.get(sessionDocId).orEmpty()

    fun save(sessionDocId: String, text: String) = kv.put(sessionDocId, text.ifEmpty { null })

    fun clear() = kv.clear()
}

/**
 * The projects collapsed in the session list, by project key, remembered on this phone (the order itself lives on the
 * relay and is shared; what is folded away is per device).
 */
class CollapsedProjectsStore(private val kv: KeyValueStore) {
    private val serializer = ListSerializer(String.serializer())
    private val _keys = MutableStateFlow(read())

    val keys: StateFlow<Set<String>> = _keys.asStateFlow()

    private fun read(): Set<String> =
        kv.get(KEY)?.let { raw -> runCatching { RelayJson.decodeFromString(serializer, raw).toSet() }.getOrNull() }.orEmpty()

    fun toggle(projectKey: String) = set(projectKey, projectKey !in _keys.value)

    fun set(projectKey: String, collapsed: Boolean) {
        val next = if (collapsed) _keys.value + projectKey else _keys.value - projectKey
        if (next == _keys.value) return
        _keys.value = next
        kv.put(KEY, if (next.isEmpty()) null else RelayJson.encodeToString(serializer, next.sorted()))
    }

    fun clear() {
        kv.clear()
        _keys.value = emptySet()
    }

    private companion object {
        const val KEY = "collapsed"
    }
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
