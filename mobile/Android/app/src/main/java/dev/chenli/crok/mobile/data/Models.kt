package dev.chenli.crok.mobile.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// The relay's API shapes (relay/DESIGN.md §3, relay/convex/*.ts). Every number is a float64 on the wire: WireLong /
// WireInt read it into Kotlin integers. Every field that the relay may leave out has a default.

// ---- Sign-in (deviceAuth) ----

@Serializable
data class StartResult(
    val deviceCode: String,
    val userCode: String,
    val verificationUrl: String? = null,
    val verificationUrlComplete: String? = null,
    val expiresAt: WireLong = 0,
    val interval: WireInt = 2,
)

@Serializable
data class RelayUser(
    val name: String? = null,
    val email: String? = null,
    val imageUrl: String? = null,
)

@Serializable
data class PollResult(
    val status: String,
    val deviceId: String? = null,
    val refreshToken: String? = null,
    val accessToken: String? = null,
    val accessTokenExpiresAt: WireLong = 0,
    val user: RelayUser? = null,
) {
    companion object {
        const val PENDING = "pending"
        const val APPROVED = "approved"
        const val DENIED = "denied"
        const val EXPIRED = "expired"
    }
}

@Serializable
data class RefreshResult(
    val deviceId: String,
    val accessToken: String,
    val accessTokenExpiresAt: WireLong,
)

/** What `deviceAuth:pendingLogin` shows before this phone approves another device. */
@Serializable
data class PendingLogin(
    val userCode: String,
    val kind: String = "computer",
    val name: String = "",
    val platform: String = "",
    val client: String = "",
    val createdAt: WireLong = 0,
    val expiresAt: WireLong = 0,
    val status: String = "pending",
)

@Serializable
data class ApproveResult(val deviceId: String, val kind: String = "computer", val name: String = "")

// ---- Account and devices ----

@Serializable
data class MeDevice(
    val deviceId: String,
    val kind: String = "phone",
    val name: String = "",
    val platform: String = "",
    val client: String = "",
)

@Serializable
data class Me(
    val userId: String,
    val name: String? = null,
    val email: String? = null,
    val imageUrl: String? = null,
    val device: MeDevice? = null,
)

@Serializable
data class Device(
    @SerialName("_id") val id: String,
    val kind: String = "computer",
    val name: String = "",
    val platform: String = "",
    val client: String = "",
    val createdAt: WireLong = 0,
    val lastSeenAt: WireLong = 0,
    val online: Boolean = false,
    val isCurrent: Boolean = false,
    val liveSessionCount: WireInt = 0,
) {
    val isComputer: Boolean get() = kind == "computer"
}

@Serializable
data class RevokeOthersResult(val count: WireInt = 0)

// ---- Sessions ----

@Serializable
data class PlanProgress(val done: WireInt = 0, val total: WireInt = 0)

@Serializable
data class PlanEntry(val content: String = "", val status: String = "pending")

@Serializable
data class SessionUsage(
    val inputTokens: WireLong? = null,
    val outputTokens: WireLong? = null,
    val cachedTokens: WireLong? = null,
    val reasoningTokens: WireLong? = null,
    val costUsd: Double? = null,
    val contextTokens: WireLong? = null,
    val contextWindow: WireLong? = null,
)

object SessionStatus {
    const val IDLE = "idle"
    const val RUNNING = "running"
    const val WAITING = "waiting"
    const val ERROR = "error"
}

/**
 * Where a session's transcript is (`historyState`): `none` / `requested` — still only on its computer (listed from disk,
 * fetched when someone opens it while the computer is online); `ready` or null — on the relay.
 */
object HistoryState {
    const val NONE = "none"
    const val REQUESTED = "requested"
    const val READY = "ready"

    fun onComputerOnly(state: String?): Boolean = state == NONE || state == REQUESTED
}

/** A row of the session list (the sessions of `sessions:groups`, and `sessions:list`). */
@Serializable
data class SessionRow(
    @SerialName("_id") val id: String,
    val sessionId: String = "",
    val title: String = "",
    val cwd: String = "",
    val model: String? = null,
    val status: String = SessionStatus.IDLE,
    val online: Boolean = false,
    val app: String = "tui",
    val deviceId: String = "",
    val deviceName: String = "",
    val deviceOnline: Boolean = false,
    val preview: String? = null,
    val previewKind: String? = null,
    val lastActivityAt: WireLong = 0,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val unread: WireInt = 0,
    val plan: PlanProgress? = null,
    /** `<deviceId>:<path>`: the project this session is listed under. */
    val projectKey: String = "",
    val projectPath: String = "",
    val projectName: String = "",
    val historyState: String? = null,
) {
    val isRunning: Boolean get() = online && status == SessionStatus.RUNNING
    val isWaiting: Boolean get() = online && status == SessionStatus.WAITING

    /** Takes prompts: a crok runs it, or its computer is online and opens it when one arrives. */
    val reachable: Boolean get() = online || deviceOnline
}

/**
 * One project of the main list (`sessions:groups`): a folder on one computer and its sessions, both levels in the order
 * the person put them in (pinned sessions lead their project).
 */
@Serializable
data class SessionGroup(
    val key: String,
    val deviceId: String = "",
    val deviceName: String = "",
    val deviceOnline: Boolean = false,
    val path: String = "",
    val name: String = "",
    /** Placed by hand; otherwise it sorts by recent activity, ahead of the placed ones. */
    val placed: Boolean = false,
    val lastActivityAt: WireLong = 0,
    val sessions: List<SessionRow> = emptyList(),
)

/** One choice of a pending request; [kind] is ACP's `allow_once`, `allow_always`, `reject_once` or `reject_always`. */
@Serializable
data class PendingOption(
    val optionId: String = "",
    val name: String = "",
    val kind: String = "",
) {
    val allows: Boolean get() = kind.startsWith("allow")
}

/**
 * A permission request the session waits on (run this command, edit that file). Any of the person's devices may answer
 * it with one of [options] (`commands:answer`); the first answer wins, and the session's `pending` goes back to null
 * once the computer took one.
 */
@Serializable
data class PendingInteraction(
    val id: String,
    val kind: String = "permission",
    val title: String = "",
    val detail: String? = null,
    val toolKind: String? = null,
    val options: List<PendingOption> = emptyList(),
    val at: WireLong = 0,
)

/** `sessions:get`: everything the session header and the info sheet show. */
@Serializable
data class SessionDetail(
    @SerialName("_id") val id: String,
    val sessionId: String = "",
    val title: String = "",
    val cwd: String = "",
    val model: String? = null,
    val effort: String? = null,
    val gitBranch: String? = null,
    val status: String = SessionStatus.IDLE,
    val online: Boolean = false,
    val app: String = "tui",
    val deviceId: String = "",
    val deviceName: String = "",
    val devicePlatform: String = "",
    val deviceOnline: Boolean = false,
    val createdAt: WireLong = 0,
    val lastActivityAt: WireLong = 0,
    val plan: List<PlanEntry> = emptyList(),
    val usage: SessionUsage? = null,
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val unread: WireInt = 0,
    val eventSeq: WireLong = 0,
    val projectKey: String = "",
    val projectPath: String = "",
    val projectName: String = "",
    val historyState: String? = null,
    /** A permission request the session waits on, or null. */
    val pending: PendingInteraction? = null,
) {
    val isRunning: Boolean get() = online && status == SessionStatus.RUNNING

    /** Takes prompts: a crok runs it, or its computer is online and opens it when one arrives. */
    val reachable: Boolean get() = online || deviceOnline
}

object EventKind {
    const val USER = "user"
    const val ASSISTANT = "assistant"
    const val THOUGHT = "thought"
    const val TOOL = "tool"
    const val SYSTEM = "system"
    const val ERROR = "error"
}

/** One transcript item (`sessions:events`). Streaming text updates the same row: same `key`, same `_id`. */
@Serializable
data class RelayEvent(
    @SerialName("_id") val id: String,
    val seq: WireLong = 0,
    val key: String = "",
    val kind: String = EventKind.SYSTEM,
    val text: String = "",
    val title: String? = null,
    val toolKind: String? = null,
    val status: String? = null,
    val origin: String? = null,
    val commandId: String? = null,
    /** For a remote prompt: who sent it (a device name, or "Web"). */
    val fromLabel: String? = null,
    val at: WireLong = 0,
)

@Serializable
data class EventPage(
    val page: List<RelayEvent> = emptyList(),
    val isDone: Boolean = true,
    val continueCursor: String = "",
)

// ---- Commands ----

object CommandStatus {
    const val PENDING = "pending"
    const val DELIVERED = "delivered"
    const val DONE = "done"
    const val FAILED = "failed"
}

@Serializable
data class CommandRef(val commandId: String)

/** A prompt sent from a phone or the web (`commands:forSession`), for the sender's status ticks. */
@Serializable
data class PromptCommand(
    @SerialName("_id") val id: String,
    val clientId: String? = null,
    val text: String = "",
    val status: String = CommandStatus.PENDING,
    val error: String? = null,
    val fromLabel: String = "",
    val fromDeviceId: String? = null,
    /** Sent by this device. Older relays leave it out: then every listed prompt counts as ours. */
    val mine: Boolean? = null,
    val createdAt: WireLong = 0,
    val updatedAt: WireLong = 0,
) {
    val isMine: Boolean get() = mine ?: true
}

/** The full command row (`commands:get`); an info request's answer is in [result]. */
@Serializable
data class CommandDoc(
    @SerialName("_id") val id: String,
    val type: String = "prompt",
    val status: String = CommandStatus.PENDING,
    val error: String? = null,
    val result: JsonElement? = null,
    val createdAt: WireLong = 0,
    val updatedAt: WireLong = 0,
)

/**
 * Fresh numbers from the computer (`commands:requestInfo` → `commands:get(...).result`). Every field may be missing;
 * [from] reads both the documented nested shape and flat fields. [stored]: no crok runs the session, so the relay
 * answered at once with the numbers its computer last sent.
 */
data class SessionInfoResult(
    val model: String? = null,
    val effort: String? = null,
    val cwd: String? = null,
    val gitBranch: String? = null,
    val title: String? = null,
    val createdAt: Long? = null,
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    val cachedTokens: Long? = null,
    val reasoningTokens: Long? = null,
    val costUsd: Double? = null,
    val contextUsed: Long? = null,
    val contextWindow: Long? = null,
    val messages: Long? = null,
    val sessionId: String? = null,
    val stored: Boolean = false,
) {
    companion object {
        fun from(result: JsonElement?): SessionInfoResult? {
            val root = result as? JsonObject ?: return null
            val usage = root["usage"] as? JsonObject
            val context = root["context"] as? JsonObject
            fun usageNumber(key: String) = usage?.number(key) ?: root.number(key)
            return SessionInfoResult(
                model = root.string("model"),
                effort = root.string("effort"),
                cwd = root.string("cwd"),
                gitBranch = root.string("gitBranch"),
                title = root.string("title"),
                createdAt = root.number("createdAt")?.toLong(),
                inputTokens = usageNumber("inputTokens")?.toLong(),
                outputTokens = usageNumber("outputTokens")?.toLong(),
                cachedTokens = usageNumber("cachedTokens")?.toLong(),
                reasoningTokens = usageNumber("reasoningTokens")?.toLong(),
                costUsd = usageNumber("costUsd"),
                contextUsed = (context?.number("used") ?: root.number("contextTokens"))?.toLong(),
                contextWindow = (context?.number("window") ?: root.number("contextWindow"))?.toLong(),
                messages = root.number("messages")?.toLong(),
                sessionId = root.string("sessionId"),
                stored = root.boolean("stored") == true,
            )
        }
    }
}
