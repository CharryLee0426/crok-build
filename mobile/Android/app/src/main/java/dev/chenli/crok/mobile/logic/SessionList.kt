package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.SessionRow

/** Session list helpers shared by the Sessions tab, a project's screen and Archived. */
object SessionList {
    /**
     * While a row is being swiped the list must not re-sort under the finger (Telegram's `setDialogsListFrozen`):
     * keep the previous order, take each row's new content, drop rows that went away and add new ones at the end.
     */
    fun freezeOrder(previousOrder: List<String>, rows: List<SessionRow>): List<SessionRow> = freeze(previousOrder, rows) { it.id }

    fun <T> freeze(previousOrder: List<String>, items: List<T>, id: (T) -> String): List<T> {
        val byId = items.associateBy(id)
        val kept = previousOrder.mapNotNull(byId::get)
        val keptIds = kept.mapTo(HashSet(), id)
        return kept + items.filter { id(it) !in keptIds }
    }

    /** The folder a session runs in: the last path component of its cwd. */
    fun folderName(cwd: String): String {
        val trimmed = cwd.trimEnd('/', '\\')
        if (trimmed.isEmpty()) return cwd
        val name = trimmed.substringAfterLast('/').substringAfterLast('\\')
        return name.ifEmpty { trimmed }
    }

    /** The project a row belongs to, by name; older relays send no project, then it is the session's folder. */
    fun projectName(row: SessionRow): String = row.projectName.ifBlank { folderName(row.projectPath.ifBlank { row.cwd }) }

    /**
     * What a topic row's second line shows: its own folder, only when that is not the project's name (the project's
     * screen already names the project). Null hides the line.
     */
    fun folderLine(row: SessionRow, projectName: String): String? {
        val folder = folderName(row.cwd)
        return folder.takeIf { it.isNotBlank() && it != projectName }
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
