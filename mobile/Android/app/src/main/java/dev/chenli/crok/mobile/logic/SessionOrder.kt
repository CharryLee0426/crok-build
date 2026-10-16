package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow

/** A change to the list's hand-placed order, as sent to the relay (and applied locally until it answers). */
sealed interface OrderChange {
    /** `sessions:reorderProjects`: some project keys (all, or one computer's) in their new order. */
    data class Projects(val keys: List<String>) : OrderChange

    /** `sessions:reorderSessions`: some of one project's sessions in their new order. */
    data class Sessions(val projectKey: String, val sessionDocIds: List<String>) : OrderChange
}

/**
 * The ordering rules of relay/DESIGN.md §2 "Projects and order", on the phone: what a reorder does to the list before
 * the relay confirms it, and the orders the Move up / Move down and "Sort by recent activity" menus send.
 */
object SessionOrder {
    /**
     * Puts [wanted] (some of [current], in their new order) into the places those items hold in [current], so reordering
     * one computer's projects leaves the others where they are. The relay's `reorderWithin`, item for item.
     */
    fun <T> reorderWithin(current: List<T>, wanted: List<T>): List<T> {
        val wantedSet = wanted.toHashSet()
        val slots = current.indices.filter { current[it] in wantedSet }
        val currentSet = current.toHashSet()
        val known = wanted.filter { it in currentSet }
        if (known.size != slots.size) return current
        val next = current.toMutableList()
        slots.forEachIndexed { i, slot -> next[slot] = known[i] }
        return next
    }

    /** Pinned sessions lead their project whatever their place (a stable partition). */
    fun pinnedFirst(sessions: List<SessionRow>): List<SessionRow> = sessions.filter { it.pinned } + sessions.filterNot { it.pinned }

    fun apply(groups: List<SessionGroup>, change: OrderChange): List<SessionGroup> = when (change) {
        is OrderChange.Projects -> {
            val byKey = groups.associateBy { it.key }
            reorderWithin(groups.map { it.key }, change.keys).map { byKey.getValue(it) }
        }
        is OrderChange.Sessions -> groups.map { group ->
            if (group.key != change.projectKey) return@map group
            val byId = group.sessions.associateBy { it.id }
            val placed = reorderWithin(group.sessions.map { it.id }, change.sessionDocIds).map { byId.getValue(it) }
            group.copy(sessions = pinnedFirst(placed))
        }
    }

    fun applyAll(groups: List<SessionGroup>, changes: List<OrderChange>): List<SessionGroup> =
        changes.fold(groups) { acc, change -> apply(acc, change) }

    /** Both levels in the same order (contents aside). */
    fun sameOrder(a: List<SessionGroup>, b: List<SessionGroup>): Boolean =
        a.size == b.size && a.indices.all { i -> a[i].key == b[i].key && a[i].sessions.map { it.id } == b[i].sessions.map { it.id } }

    /** [items] with [item] moved by [delta] places, or null when it cannot move that way. */
    fun <T> move(items: List<T>, item: T, delta: Int): List<T>? {
        val from = items.indexOf(item)
        if (from < 0 || delta == 0) return null
        val to = from + delta
        if (to !in items.indices) return null
        return items.toMutableList().apply { add(to, removeAt(from)) }
    }

    /**
     * A project's session ids with one session moved by [delta] places among the sessions it can trade places with:
     * pinned ones among the pinned, the others among the others. Null when it cannot move.
     */
    fun moveSession(sessions: List<SessionRow>, sessionDocId: String, delta: Int): List<String>? {
        val session = sessions.firstOrNull { it.id == sessionDocId } ?: return null
        val pinned = sessions.filter { it.pinned }.map { it.id }
        val others = sessions.filterNot { it.pinned }.map { it.id }
        return if (session.pinned) {
            move(pinned, sessionDocId, delta)?.let { it + others }
        } else {
            move(others, sessionDocId, delta)?.let { pinned + it }
        }
    }

    /** Whether two sessions of one project may trade places by hand (never across the pinned / not pinned line). */
    fun canSwap(a: SessionRow, b: SessionRow): Boolean = a.pinned == b.pinned

    /** "Sort projects by recent activity": the order the relay shows once positions are cleared. */
    fun projectsByRecent(groups: List<SessionGroup>): List<String> = groups.sortedByDescending { it.lastActivityAt }.map { it.key }

    /** "Sort by recent activity" on a project: pinned first, then newest first. */
    fun sessionsByRecent(sessions: List<SessionRow>): List<String> =
        sessions.sortedWith(compareByDescending<SessionRow> { it.pinned }.thenByDescending { it.lastActivityAt }).map { it.id }
}
