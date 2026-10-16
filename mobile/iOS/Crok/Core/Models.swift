import Foundation

// The relay's data as the Convex functions return it (relay/convex/*.ts, relay/DESIGN.md §3).
// Ids are strings; every number is a JSON float64, so numbers decode as Double and are turned into Int where shown.

typealias DocID = String

/// String enums that keep decoding when the relay adds a value this build does not know.
protocol LenientStringEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    static var unknownValue: Self { get }
}

extension LenientStringEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownValue
    }
}

enum SessionStatus: String, LenientStringEnum {
    case idle, running, waiting, error
    static let unknownValue = SessionStatus.idle
}

enum HostApp: String, LenientStringEnum {
    case tui, desktop, cli, unknown
    static let unknownValue = HostApp.unknown
}

enum EventKind: String, LenientStringEnum {
    case user, assistant, thought, tool, system, error, unknown
    static let unknownValue = EventKind.unknown
}

enum CommandStatus: String, LenientStringEnum {
    case pending, delivered, done, failed, unknown
    static let unknownValue = CommandStatus.unknown
}

enum DeviceKind: String, LenientStringEnum {
    case computer, phone, unknown
    static let unknownValue = DeviceKind.unknown
}

/// Where a session's transcript is: `notFetched` ("none") and `requested` mean it is still only on the computer's disk
/// (a session listed from the computer's catalog); `ready` (or no value) means the relay has it.
enum HistoryState: String, LenientStringEnum {
    case notFetched = "none"
    case requested, ready, unknown
    static let unknownValue = HistoryState.unknown

    /// The transcript has not reached the relay yet.
    var isOnComputerOnly: Bool { self == .notFetched || self == .requested }
}

struct PlanProgress: Codable, Hashable, Sendable {
    var done: Double
    var total: Double
}

struct PlanEntry: Codable, Hashable, Sendable {
    var content: String
    var status: String
}

struct SessionUsage: Codable, Hashable, Sendable {
    var inputTokens: Double?
    var outputTokens: Double?
    var cachedTokens: Double?
    var reasoningTokens: Double?
    var costUsd: Double?
    var contextTokens: Double?
    var contextWindow: Double?
}

/// A row of `sessions:list` and of a project in `sessions:groups`.
struct SessionRow: Codable, Identifiable, Hashable, Sendable {
    var id: DocID
    var sessionId: String
    var title: String
    var cwd: String
    var model: String?
    var status: SessionStatus
    var online: Bool
    var app: HostApp
    var deviceId: DocID
    var deviceName: String
    var deviceOnline: Bool
    var preview: String?
    var previewKind: EventKind?
    var lastActivityAt: Double
    var pinned: Bool
    var archived: Bool
    var unread: Double
    var plan: PlanProgress?
    /// The project this session is grouped under: `<deviceId>:<path>`, its folder, and that folder's name.
    var projectKey: String?
    var projectPath: String?
    var projectName: String?
    var historyState: HistoryState?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case sessionId, title, cwd, model, status, online, app, deviceId, deviceName, deviceOnline, preview,
            previewKind, lastActivityAt, pinned, archived, unread, plan, projectKey, projectPath, projectName,
            historyState
    }

    init(
        id: DocID, sessionId: String, title: String, cwd: String, model: String?, status: SessionStatus, online: Bool,
        app: HostApp, deviceId: DocID, deviceName: String, deviceOnline: Bool, preview: String?, previewKind: EventKind?,
        lastActivityAt: Double, pinned: Bool, archived: Bool, unread: Double, plan: PlanProgress?,
        projectKey: String? = nil, projectPath: String? = nil, projectName: String? = nil,
        historyState: HistoryState? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.model = model
        self.status = status
        self.online = online
        self.app = app
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceOnline = deviceOnline
        self.preview = preview
        self.previewKind = previewKind
        self.lastActivityAt = lastActivityAt
        self.pinned = pinned
        self.archived = archived
        self.unread = unread
        self.plan = plan
        self.projectKey = projectKey
        self.projectPath = projectPath
        self.projectName = projectName
        self.historyState = historyState
    }

    var unreadCount: Int { max(0, Int(unread.rounded())) }
    var lastActivity: Date { Date(milliseconds: lastActivityAt) }
    var folderName: String { PathText.lastComponent(cwd) }
    var isRunning: Bool { online && status == .running }

    /// The project's name, or the session's own folder on a relay that does not group sessions.
    var projectDisplayName: String {
        if let projectName, !projectName.isEmpty { return projectName }
        return folderName
    }

    /// The session's own folder when it is not the project's (a subfolder or a worktree); nil when the project's
    /// header already says it.
    var folderIfNotProject: String? {
        let folder = folderName
        return folder.isEmpty || folder == projectDisplayName ? nil : folder
    }
}

/// One project of `sessions:groups`: a folder on one computer and its sessions, both in the list's order.
struct ProjectGroup: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var deviceId: DocID
    var deviceName: String
    var deviceOnline: Bool
    var path: String
    var name: String
    /// Placed by hand: it keeps its place. Projects never placed come first, most recently active first.
    var placed: Bool
    var lastActivityAt: Double
    var sessions: [SessionRow]

    var id: String { key }
    var unreadCount: Int { sessions.reduce(0) { $0 + $1.unreadCount } }
}

/// `sessions:get`: everything the header and the info sheet show.
struct SessionDetail: Codable, Hashable, Sendable {
    var id: DocID
    var sessionId: String
    var title: String
    var cwd: String
    var model: String?
    var effort: String?
    var gitBranch: String?
    var status: SessionStatus
    var online: Bool
    var app: HostApp
    var deviceId: DocID
    var deviceName: String
    var devicePlatform: String
    var deviceOnline: Bool
    var createdAt: Double
    var lastActivityAt: Double
    var plan: [PlanEntry]
    var usage: SessionUsage?
    var pinned: Bool
    var archived: Bool
    var unread: Double
    var eventSeq: Double
    var projectKey: String?
    var projectPath: String?
    var projectName: String?
    var historyState: HistoryState?
    /// A permission request the session waits on, which any of the person's devices may answer (`commands:answer`).
    /// Missing from older relays.
    var pending: PendingInteraction?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case sessionId, title, cwd, model, effort, gitBranch, status, online, app, deviceId, deviceName,
            devicePlatform, deviceOnline, createdAt, lastActivityAt, plan, usage, pinned, archived, unread, eventSeq,
            projectKey, projectPath, projectName, historyState, pending
    }

    var unreadCount: Int { max(0, Int(unread.rounded())) }
    var folderName: String { PathText.lastComponent(cwd) }
    var isRunning: Bool { online && status == .running }
    var presence: SessionPresence { SessionPresence(online: online, deviceOnline: deviceOnline, status: status) }
}

/// What a session's header says about it. Only a computer that is offline makes a session offline: a session nobody
/// runs on an online computer takes prompts (a crok there opens it when one arrives), so it reads as idle.
enum SessionPresence: Equatable, Sendable {
    case offline, idle, running, waiting, error

    init(online: Bool, deviceOnline: Bool, status: SessionStatus) {
        if !deviceOnline {
            self = .offline
        } else if !online {
            self = .idle
        } else {
            switch status {
            case .running: self = .running
            case .waiting: self = .waiting
            case .error: self = .error
            case .idle: self = .idle
            }
        }
    }
}

/// One choice of a pending request: `kind` is ACP's `allow_once`, `allow_always`, `reject_once` or `reject_always`.
struct PendingOption: Codable, Identifiable, Hashable, Sendable {
    var optionId: String
    var name: String
    var kind: String

    var id: String { optionId }
    /// Allowing choices are the prominent buttons.
    var isAllow: Bool { kind.hasPrefix("allow") }
    var label: String { name.isEmpty ? optionId : name }
}

/// What a session waits for (`sessions:get` → `pending`): a permission request (run this command, edit that file).
/// `id` names this request; the first answer from any device wins, and the field goes back to null once the computer
/// took an answer. Decoded leniently, so a field this build does not expect never hides the session.
struct PendingInteraction: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var title: String
    var detail: String?
    var toolKind: String?
    var options: [PendingOption]
    var at: Double

    init(
        id: String, kind: String = "permission", title: String, detail: String? = nil, toolKind: String? = nil,
        options: [PendingOption], at: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolKind = toolKind
        self.options = options
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "permission"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        toolKind = try? c.decodeIfPresent(String.self, forKey: .toolKind)
        options = (try? c.decodeIfPresent([PendingOption].self, forKey: .options)) ?? []
        at = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? 0
    }
}

/// One transcript item (`sessions:events`).
struct TranscriptEvent: Codable, Identifiable, Hashable, Sendable {
    var id: DocID
    var seq: Double
    var key: String
    var kind: EventKind
    var text: String
    var title: String?
    var toolKind: String?
    var status: String?
    var origin: String?
    var commandId: DocID?
    /// For a remote prompt: who sent it (a device name, or "Web").
    var fromLabel: String?
    var at: Double

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case seq, key, kind, text, title, toolKind, status, origin, commandId, fromLabel, at
    }

    var date: Date { Date(milliseconds: at) }
    var isRemote: Bool { origin == "remote" }
}

/// A page of `sessions:events`, newest first.
struct EventsPage: Decodable, Sendable, Equatable {
    var page: [TranscriptEvent]
    var isDone: Bool
    var continueCursor: String
    var splitCursor: String?
    var pageStatus: String?
}

/// A prompt sent from a phone or the web (`commands:forSession`).
struct PromptCommand: Codable, Identifiable, Hashable, Sendable {
    var id: DocID
    var clientId: String?
    var text: String
    var status: CommandStatus
    var error: String?
    var fromLabel: String
    var fromDeviceId: DocID?
    /// Sent by this device. Missing from older relays, where every listed prompt counts as this device's own.
    var mine: Bool?
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case clientId, text, status, error, fromLabel, fromDeviceId, mine, createdAt, updatedAt
    }

    /// This device's own prompt: it gets status ticks and an optimistic bubble.
    var isMine: Bool { mine ?? true }
}

/// A command row (`commands:get`). Only the fields the app reads; `result` is decoded leniently.
struct CommandRecord: Decodable, Sendable, Equatable {
    var id: DocID
    var type: String
    var status: CommandStatus
    var error: String?
    var result: SessionInfoResult?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case type, status, error, result
    }

    init(id: DocID, type: String, status: CommandStatus, error: String? = nil, result: SessionInfoResult? = nil) {
        self.id = id
        self.type = type
        self.status = status
        self.error = error
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DocID.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        status = try c.decode(CommandStatus.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        result = try? c.decodeIfPresent(SessionInfoResult.self, forKey: .result)
    }
}

/// What a computer answers to `commands:requestInfo`. Fields may be missing; usage may be nested or flat. For a session
/// no crok runs the relay answers at once with what the computer last sent (`stored`).
struct SessionInfoResult: Decodable, Hashable, Sendable {
    var model: String?
    var effort: String?
    var cwd: String?
    var gitBranch: String?
    var title: String?
    var createdAt: Double?
    var usage: SessionUsage?
    var contextUsed: Double?
    var contextWindow: Double?
    var messages: Double?
    var sessionId: String?
    /// The relay's stored values, not fresh ones from the computer.
    var stored: Bool

    init(
        model: String? = nil, effort: String? = nil, cwd: String? = nil, gitBranch: String? = nil,
        title: String? = nil, createdAt: Double? = nil, usage: SessionUsage? = nil, contextUsed: Double? = nil,
        contextWindow: Double? = nil, messages: Double? = nil, sessionId: String? = nil, stored: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.createdAt = createdAt
        self.usage = usage
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
        self.messages = messages
        self.sessionId = sessionId
        self.stored = stored
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Context: Decodable {
        var used: Double?
        var window: Double?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func string(_ key: String) -> String? { try? c.decodeIfPresent(String.self, forKey: AnyKey(key)) }
        func number(_ key: String) -> Double? { try? c.decodeIfPresent(Double.self, forKey: AnyKey(key)) }
        model = string("model")
        effort = string("effort")
        cwd = string("cwd")
        gitBranch = string("gitBranch")
        title = string("title")
        sessionId = string("sessionId")
        messages = number("messages")
        stored = (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("stored"))) ?? false
        if let ms = number("createdAt") {
            createdAt = ms
        } else if let iso = string("createdAt") {
            createdAt = ISO8601DateFormatter().date(from: iso).map { $0.timeIntervalSince1970 * 1000 }
        }
        var usage = (try? c.decodeIfPresent(SessionUsage.self, forKey: AnyKey("usage"))) ?? SessionUsage()
        usage.inputTokens = usage.inputTokens ?? number("inputTokens")
        usage.outputTokens = usage.outputTokens ?? number("outputTokens")
        usage.cachedTokens = usage.cachedTokens ?? number("cachedTokens")
        usage.reasoningTokens = usage.reasoningTokens ?? number("reasoningTokens")
        usage.costUsd = usage.costUsd ?? number("costUsd")
        self.usage = usage == SessionUsage() ? nil : usage
        let context = try? c.decodeIfPresent(Context.self, forKey: AnyKey("context"))
        contextUsed = context?.used ?? usage.contextTokens
        contextWindow = context?.window ?? usage.contextWindow
    }
}

/// A row of `devices:list`.
struct DeviceRow: Codable, Identifiable, Hashable, Sendable {
    var id: DocID
    var kind: DeviceKind
    var name: String
    var platform: String
    var client: String
    var createdAt: Double
    var lastSeenAt: Double
    var online: Bool
    var isCurrent: Bool
    var liveSessionCount: Double

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case kind, name, platform, client, createdAt, lastSeenAt, online, isCurrent, liveSessionCount
    }
}

/// The person behind the account, as `deviceAuth:poll` and `users:me` describe them.
struct AccountUser: Codable, Hashable, Sendable {
    var name: String?
    var email: String?
    var imageUrl: String?
}

/// `users:me`.
struct AccountInfo: Decodable, Hashable, Sendable {
    struct Device: Decodable, Hashable, Sendable {
        var deviceId: DocID
        var kind: DeviceKind
        var name: String
        var platform: String
        var client: String
    }

    var userId: DocID
    var name: String?
    var email: String?
    var imageUrl: String?
    var device: Device?

    var user: AccountUser { AccountUser(name: name, email: email, imageUrl: imageUrl) }
}

// MARK: - Device sign-in

/// `deviceAuth:start`.
struct DeviceAuthStart: Codable, Hashable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationUrl: String?
    var verificationUrlComplete: String?
    var expiresAt: Double
    var interval: Double
}

/// `deviceAuth:poll` once approved: the refresh token is handed out exactly once.
struct DeviceApproval: Decodable, Hashable, Sendable {
    var deviceId: DocID
    var refreshToken: String
    var accessToken: String
    var accessTokenExpiresAt: Double
    var user: AccountUser
}

enum DeviceAuthPoll: Decodable, Hashable, Sendable {
    case pending
    case denied
    case expired
    case approved(DeviceApproval)

    private enum CodingKeys: String, CodingKey { case status }

    init(from decoder: Decoder) throws {
        let status = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .status)
        switch status {
        case "approved": self = .approved(try DeviceApproval(from: decoder))
        case "denied": self = .denied
        case "expired": self = .expired
        default: self = .pending
        }
    }
}

/// `deviceAuth:refresh`.
struct DeviceAccessToken: Decodable, Hashable, Sendable {
    var deviceId: DocID
    var accessToken: String
    var accessTokenExpiresAt: Double
}

/// `deviceAuth:pendingLogin`: which device asks to be linked.
struct PendingLoginInfo: Decodable, Hashable, Sendable {
    var userCode: String
    var kind: DeviceKind
    var name: String
    var platform: String
    var client: String
    var createdAt: Double
    var expiresAt: Double
    var status: String
}

/// `deviceAuth:approve`.
struct ApprovedDevice: Decodable, Hashable, Sendable {
    var deviceId: DocID
    var kind: DeviceKind
    var name: String
}

/// For mutations that return `null`.
struct Nothing: Decodable, Sendable, Equatable {
    init() {}
    init(from decoder: Decoder) throws {}
}

struct CommandRef: Decodable, Sendable, Equatable {
    var commandId: DocID
}

struct RevokeCount: Decodable, Sendable, Equatable {
    var count: Double
}

// MARK: - Helpers

extension Date {
    init(milliseconds: Double) { self.init(timeIntervalSince1970: milliseconds / 1000) }
    var milliseconds: Double { timeIntervalSince1970 * 1000 }
}

enum PathText {
    /// The folder name of a cwd (`/Users/me/src/crok-build` → `crok-build`); `~` for a bare home folder.
    static func lastComponent(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        guard !trimmed.isEmpty else { return path.isEmpty ? "" : "/" }
        let parts = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? trimmed
    }

    /// Shortens `/Users/<name>/…` to `~/…` for display.
    static func abbreviatingHome(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home" {
            let rest = parts.dropFirst(3).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/" + rest
        }
        return path
    }
}
