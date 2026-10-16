package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow

/** The chat list's folders as tabs (Telegram's FilterTabsView): All, one per computer, Archived. */
sealed interface SessionFilter {
    data object All : SessionFilter
    data class Computer(val deviceId: String) : SessionFilter
    data object Archived : SessionFilter
}

data class ComputerTab(val deviceId: String, val name: String, val online: Boolean)

/**
 * One project in the list: its sessions (already narrowed by a search) and how much of it shows. A section shows its
 * first [SessionList.PAGE] sessions until "Show N more"; while searching it shows every match and ignores collapsing.
 */
data class SessionSection(
    val group: SessionGroup,
    val rows: List<SessionRow>,
    val collapsed: Boolean = false,
    val expanded: Boolean = false,
    val searching: Boolean = false,
) {
    val key: String get() = group.key

    /** Sessions in the project at all (the header's count; while searching, the matches). */
    val count: Int get() = rows.size

    val isCollapsed: Boolean get() = collapsed && !searching

    val visibleRows: List<SessionRow>
        get() = when {
            searching -> rows
            collapsed -> emptyList()
            expanded || rows.size <= SessionList.PAGE -> rows
            else -> rows.take(SessionList.PAGE)
        }

    /** "Show N more": the sessions past the first page. */
    val hiddenCount: Int get() = if (searching || collapsed || expanded) 0 else (rows.size - SessionList.PAGE).coerceAtLeast(0)

    /** "Show less": the section was opened past its first page. */
    val canShowLess: Boolean get() = !searching && !collapsed && expanded && rows.size > SessionList.PAGE
}

object SessionList {
    /** Sessions a section shows before "Show N more". */
    const val PAGE = 5

    /** One tab per computer that has sessions, by name; shown only when there are two or more. */
    fun computerTabs(groups: List<SessionGroup>): List<ComputerTab> =
        groups.groupBy { it.deviceId }
            .map { (deviceId, projects) ->
                ComputerTab(deviceId, projects.first().deviceName, projects.any { it.deviceOnline })
            }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })

    /**
     * The sections for a tab: All shows every project, a computer tab only that computer's. A search keeps the matching
     * sessions in each section and drops sections left empty.
     */
    fun sections(
        groups: List<SessionGroup>,
        filter: SessionFilter,
        query: String,
        collapsed: Set<String> = emptySet(),
        expanded: Set<String> = emptySet(),
    ): List<SessionSection> {
        val byTab = when (filter) {
            is SessionFilter.Computer -> groups.filter { it.deviceId == filter.deviceId }
            else -> groups
        }
        val needle = query.trim()
        if (needle.isEmpty()) {
            return byTab.map { SessionSection(it, it.sessions, collapsed = it.key in collapsed, expanded = it.key in expanded) }
        }
        return byTab.mapNotNull { group ->
            val rows = group.sessions.filter { matches(it, needle) || group.name.contains(needle, ignoreCase = true) }
            if (rows.isEmpty()) null else SessionSection(group, rows, searching = true)
        }
    }

    /** The Archived tab: a flat list (and any other flat list), narrowed by a search. */
    fun filter(rows: List<SessionRow>, filter: SessionFilter, query: String): List<SessionRow> {
        val byTab = when (filter) {
            is SessionFilter.Computer -> rows.filter { it.deviceId == filter.deviceId }
            else -> rows
        }
        val needle = query.trim()
        if (needle.isEmpty()) return byTab
        return byTab.filter { matches(it, needle) }
    }

    private fun matches(row: SessionRow, needle: String): Boolean =
        row.title.contains(needle, ignoreCase = true) ||
            row.cwd.contains(needle, ignoreCase = true) ||
            row.deviceName.contains(needle, ignoreCase = true) ||
            row.projectName.contains(needle, ignoreCase = true) ||
            (row.preview?.contains(needle, ignoreCase = true) ?: false)

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

    /** The order of a sectioned list: project keys, and each project's session ids. */
    data class Order(val projects: List<String> = emptyList(), val sessions: Map<String, List<String>> = emptyMap())

    fun orderOf(sections: List<SessionSection>): Order =
        Order(sections.map { it.key }, sections.associate { section -> section.key to section.rows.map { it.id } })

    /** [freezeOrder] for sections: neither projects nor the sessions inside them move while frozen. */
    fun freezeSections(previous: Order, sections: List<SessionSection>): List<SessionSection> =
        freeze(previous.projects, sections) { it.key }.map { section ->
            val order = previous.sessions[section.key] ?: return@map section
            section.copy(rows = freezeOrder(order, section.rows))
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
     * What a grouped row's second line shows: its own folder, only when that is not the project's name (the section
     * header already names the project and the computer). Null hides the line.
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
