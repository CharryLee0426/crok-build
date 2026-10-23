package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow

/**
 * A linked computer as the phone shows it: one of the person's "accounts" (mobile/DESIGN.md, Telegram's accounts under
 * one person). Its sessions are the projects of `sessions:groups` that carry its device id.
 */
data class ComputerAccount(
    val deviceId: String,
    val name: String,
    val online: Boolean,
    val lastSeenAt: Long = 0,
    val createdAt: Long = 0,
    /** Unread replies over its sessions. */
    val unread: Int = 0,
    /** Its most recent session activity (0 without sessions). */
    val lastActivityAt: Long = 0,
)

/** The computer list, the selected computer and what each one holds. */
object Computers {
    /**
     * Every computer in link order: the `devices:list` computers by `createdAt`, then computers only known from the
     * session list (a relay whose device list has not arrived, a computer signed out with sessions left).
     */
    fun list(devices: List<Device>?, groups: List<SessionGroup>): List<ComputerAccount> {
        val byDevice = groups.groupBy { it.deviceId }
        fun unread(deviceId: String) = byDevice[deviceId].orEmpty().sumOf { group -> group.sessions.sumOf { it.unread } }
        fun activity(deviceId: String) = byDevice[deviceId].orEmpty().maxOfOrNull { it.lastActivityAt } ?: 0L
        val linked = devices.orEmpty()
            .filter { it.isComputer }
            .sortedWith(compareBy<Device> { it.createdAt }.thenBy { it.id })
            .map { device ->
                ComputerAccount(
                    deviceId = device.id,
                    name = device.name.ifBlank { byDevice[device.id]?.firstOrNull()?.deviceName.orEmpty() },
                    online = device.online,
                    lastSeenAt = device.lastSeenAt,
                    createdAt = device.createdAt,
                    unread = unread(device.id),
                    lastActivityAt = activity(device.id),
                )
            }
        val known = linked.mapTo(HashSet()) { it.deviceId }
        val listedOnly = byDevice.filterKeys { it.isNotBlank() && it !in known }.map { (deviceId, projects) ->
            ComputerAccount(
                deviceId = deviceId,
                name = projects.first().deviceName,
                online = projects.any { it.deviceOnline },
                unread = unread(deviceId),
                lastActivityAt = activity(deviceId),
            )
        }
        return linked + listedOnly
    }

    /**
     * The computer the Sessions tab shows: the remembered one while it is still there, else the one with the most
     * recent session activity, else the first; null without computers.
     */
    fun selected(computers: List<ComputerAccount>, remembered: String?): ComputerAccount? {
        computers.firstOrNull { it.deviceId == remembered }?.let { return it }
        return computers.filter { it.lastActivityAt > 0 }.maxByOrNull { it.lastActivityAt } ?: computers.firstOrNull()
    }

    /** One computer's projects, in the relay's order. */
    fun projects(groups: List<SessionGroup>, deviceId: String?): List<SessionGroup> =
        if (deviceId == null) emptyList() else groups.filter { it.deviceId == deviceId }

    /** Unread replies on the other computers (the Profile tab's badge). */
    fun unreadElsewhere(computers: List<ComputerAccount>, deviceId: String?): Int =
        computers.filter { it.deviceId != deviceId }.sumOf { it.unread }

    /** The sessions Mark All as Read marks: every unread one in [groups]. */
    fun unreadSessionIds(groups: List<SessionGroup>): Set<String> =
        groups.flatMapTo(LinkedHashSet()) { group -> group.sessions.filter { it.unread > 0 }.map { it.id } }
}

/** A project as a group with topics (Telegram's forum row): what its second and third lines show. */
object Forum {
    /** Topics shown on a project's second line. */
    const val TOPIC_LIMIT = 3

    /** Its sessions most recently active first (not the hand-placed order: Telegram's row shows recent topics). */
    fun recent(group: SessionGroup): List<SessionRow> =
        group.sessions.sortedWith(compareByDescending<SessionRow> { it.lastActivityAt }.thenBy { it.id })

    /** The titles on the second line, most recent first. */
    fun topicTitles(group: SessionGroup, limit: Int = TOPIC_LIMIT): List<String> =
        recent(group).take(limit).map { it.title.ifBlank { SessionList.folderName(it.cwd) } }

    /** The session whose preview the third line shows. */
    fun latest(group: SessionGroup): SessionRow? = recent(group).firstOrNull()

    enum class Activity { Working, Waiting, Idle }

    /** "working…" while any session runs, else "Needs approval" while one waits. */
    fun activity(group: SessionGroup): Activity = when {
        group.sessions.any { it.isRunning } -> Activity.Working
        group.sessions.any { it.isWaiting } -> Activity.Waiting
        else -> Activity.Idle
    }

    fun unread(group: SessionGroup): Int = group.sessions.sumOf { it.unread }

    /** The project screen's and search's narrowing: title, folder, project, preview or model. */
    fun matches(row: SessionRow, query: String): Boolean {
        val needle = query.trim()
        if (needle.isEmpty()) return true
        return row.title.contains(needle, ignoreCase = true) ||
            row.cwd.contains(needle, ignoreCase = true) ||
            SessionList.projectName(row).contains(needle, ignoreCase = true) ||
            (row.preview?.contains(needle, ignoreCase = true) ?: false) ||
            (row.model?.contains(needle, ignoreCase = true) ?: false)
    }

    /** The Sessions tab's search over one computer: its matching sessions, in list order. */
    fun search(groups: List<SessionGroup>, query: String): List<SessionRow> {
        if (query.isBlank()) return emptyList()
        return groups.flatMap { group -> group.sessions.filter { matches(it, query) || group.name.contains(query.trim(), ignoreCase = true) } }
    }
}

/**
 * Stable colour picks shared with the iOS app: FNV-1a over the UTF-8 bytes (as iOS's `ProjectAvatar.colorIndex`), so a
 * session's topic colour is the same on both phones.
 */
object StableIndex {
    fun fnv1a(key: String, count: Int): Int {
        if (count <= 0) return 0
        var hash = 2_166_136_261u
        for (byte in key.encodeToByteArray()) {
            hash = hash xor byte.toUByte().toUInt()
            hash *= 16_777_619u
        }
        return (hash % count.toUInt()).toInt()
    }
}

/** Telegram's six topic colours (mobile/DESIGN.md "Topic icon"), as ARGB. */
object TopicColors {
    val all: List<Long> = listOf(0xFF6FB9F0, 0xFFFFD67E, 0xFFCB86DB, 0xFF8EEE98, 0xFFFF93B2, 0xFFFB6F5F)

    fun index(sessionDocId: String): Int = StableIndex.fnv1a(sessionDocId, all.size)

    /** The glyph's letter: the title's first letter or digit, uppercased; `·` when it has none. */
    fun initial(title: String): String {
        val first = title.firstOrNull { it.isLetterOrDigit() } ?: return "·"
        return first.uppercase()
    }
}

/**
 * The session theme gradient (mobile/DESIGN.md "Session themes"): four colours at fixed points of the unit square,
 * mixed with weights `max(0, 0.9 - distance)^4`, normalised.
 */
object ThemeGradient {
    val points: List<Pair<Float, Float>> = listOf(0.80f to 0.10f, 0.20f to 0.30f, 0.75f to 0.65f, 0.25f to 0.90f)

    fun weights(x: Float, y: Float): FloatArray {
        val raw = FloatArray(points.size) { i ->
            val (px, py) = points[i]
            val dx = x - px
            val dy = y - py
            val w = (0.9f - kotlin.math.sqrt(dx * dx + dy * dy)).coerceAtLeast(0f)
            w * w * w * w
        }
        val sum = raw.sum()
        if (sum <= 0f) return FloatArray(points.size) { 1f / points.size }
        for (i in raw.indices) raw[i] /= sum
        return raw
    }

    /** One pixel of the gradient from four ARGB colours. */
    fun mix(colors: List<Long>, x: Float, y: Float): Int {
        val w = weights(x, y)
        var r = 0f
        var g = 0f
        var b = 0f
        for (i in w.indices) {
            val c = colors[i]
            r += w[i] * ((c shr 16) and 0xFF)
            g += w[i] * ((c shr 8) and 0xFF)
            b += w[i] * (c and 0xFF)
        }
        return (0xFF shl 24) or (r.toInt().coerceIn(0, 255) shl 16) or (g.toInt().coerceIn(0, 255) shl 8) or b.toInt().coerceIn(0, 255)
    }
}
