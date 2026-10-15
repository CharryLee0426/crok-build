package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.SessionRow

/** The chat list's folders as tabs (Telegram's FilterTabsView): All, one per computer, Archived. */
sealed interface SessionFilter {
    data object All : SessionFilter
    data class Computer(val deviceId: String) : SessionFilter
    data object Archived : SessionFilter
}

data class ComputerTab(val deviceId: String, val name: String, val online: Boolean)

object SessionList {
    /** One tab per computer that has sessions, by name; shown only when there are two or more. */
    fun computerTabs(rows: List<SessionRow>): List<ComputerTab> =
        rows.groupBy { it.deviceId }
            .map { (deviceId, sessions) ->
                ComputerTab(deviceId, sessions.first().deviceName, sessions.any { it.deviceOnline })
            }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })

    fun filter(rows: List<SessionRow>, filter: SessionFilter, query: String): List<SessionRow> {
        val byTab = when (filter) {
            is SessionFilter.Computer -> rows.filter { it.deviceId == filter.deviceId }
            else -> rows
        }
        val needle = query.trim()
        if (needle.isEmpty()) return byTab
        return byTab.filter { row ->
            row.title.contains(needle, ignoreCase = true) ||
                row.cwd.contains(needle, ignoreCase = true) ||
                row.deviceName.contains(needle, ignoreCase = true) ||
                (row.preview?.contains(needle, ignoreCase = true) ?: false)
        }
    }

    /**
     * While a row is being swiped the list must not re-sort under the finger (Telegram's `setDialogsListFrozen`):
     * keep the previous order, take each row's new content, drop rows that went away and add new ones at the end.
     */
    fun freezeOrder(previousOrder: List<String>, rows: List<SessionRow>): List<SessionRow> {
        val byId = rows.associateBy { it.id }
        val kept = previousOrder.mapNotNull(byId::get)
        val keptIds = kept.mapTo(HashSet()) { it.id }
        return kept + rows.filter { it.id !in keptIds }
    }

    /** The folder a session runs in: the last path component of its cwd. */
    fun folderName(cwd: String): String {
        val trimmed = cwd.trimEnd('/', '\\')
        if (trimmed.isEmpty()) return cwd
        val name = trimmed.substringAfterLast('/').substringAfterLast('\\')
        return name.ifEmpty { trimmed }
    }

    /** "~/code/crok-build" for display: the home directory shortened like a shell prompt. */
    fun prettyPath(cwd: String): String {
        val home = Regex("^(/Users/[^/]+|/home/[^/]+)").find(cwd)?.value ?: return cwd
        return "~" + cwd.removePrefix(home)
    }
}

/** Avatars: project initials and a stable colour per project (Telegram's peer colours, our own palette). */
object Avatars {
    /** "crok-build" → "CB", "relay" → "R", "myProject" → "MP". */
    fun initials(name: String): String {
        val words = name
            .replace(Regex("([a-z])([A-Z])"), "$1 $2")
            .split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.isNotEmpty() }
        return when {
            words.isEmpty() -> name.trim().take(1).uppercase().ifEmpty { "?" }
            words.size == 1 -> words[0].take(1).uppercase()
            else -> (words[0].take(1) + words[1].take(1)).uppercase()
        }
    }

    /** A stable index into a palette of [count] colours (String.hashCode is specified, so it is the same everywhere). */
    fun colorIndex(key: String, count: Int): Int = Math.floorMod(key.hashCode(), count)
}
