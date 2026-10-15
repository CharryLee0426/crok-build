import Foundation

/// The status mark on the phone's own prompts (Telegram's clock → ✓ → ✓✓ → red "!").
enum DeliveryTick: Equatable, Sendable {
    /// Not picked up by the computer yet (or not even at the relay yet).
    case sending
    /// The computer accepted it: it is in the transcript or queued behind the running turn.
    case delivered
    /// Its turn finished.
    case done
    /// `error` says why: offline, busy, rejected.
    case failed

    init(_ status: CommandStatus) {
        switch status {
        case .pending, .unknown: self = .sending
        case .delivered: self = .delivered
        case .done: self = .done
        case .failed: self = .failed
        }
    }
}

/// A prompt shown from the moment Send is tapped, before the relay has answered (Telegram's optimistic send, keyed by
/// a client id so a resend is the same command).
struct LocalPrompt: Equatable, Sendable, Identifiable {
    var clientId: String
    var text: String
    var createdAt: Double
    /// Set once `commands:sendPrompt` answered.
    var commandId: DocID?
    /// Set when `commands:sendPrompt` failed; the bubble shows a red "!" with Retry / Delete.
    var failure: String?

    var id: String { clientId }
}

enum ToolStatus: Equatable, Sendable {
    case pending, inProgress, completed, failed, other

    init(_ raw: String?) {
        switch raw {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .other
        }
    }

    var isActive: Bool { self == .pending || self == .inProgress }
}

struct UserMessage: Equatable, Sendable {
    var text: String
    var isRemote: Bool
    var fromLabel: String?
    var tick: DeliveryTick?
    var error: String?
    var commandId: DocID?
    var clientId: String?
    /// Not in the transcript yet (optimistic, queued, or failed before it reached the computer).
    var isPending: Bool
}

struct ToolCall: Equatable, Sendable {
    var title: String
    var toolKind: String
    var status: ToolStatus
    var detail: String
}

enum NoticeStyle: Equatable, Sendable { case system, stopped, error }

struct TranscriptItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case day
        case user(UserMessage)
        case assistant(text: String)
        case thought(text: String)
        case tool(ToolCall)
        case notice(text: String, style: NoticeStyle)
    }

    /// Position inside a run of items by one author, for spacing and bubble corners (Telegram merges neighbours the
    /// same way: same author, close in time).
    enum Position: Equatable, Sendable {
        case single, first, middle, last
        var startsGroup: Bool { self == .single || self == .first }
        var endsGroup: Bool { self == .single || self == .last }
    }

    var id: String
    var kind: Kind
    var date: Date
    var position: Position = .single
    /// The event's `seq`, for transcript items backed by an event.
    var seq: Double?

    var eventID: DocID? { seq == nil ? nil : id }
}

enum TranscriptBuilder {
    /// Items of one author closer together than this are drawn as one group.
    static let groupWindow: TimeInterval = 10 * 60

    private enum Author: Equatable { case user, agent, other }

    /// Builds what the transcript shows from the loaded events (any order), the session's recent prompts
    /// (`commands:forSession`) and the prompts this phone is sending right now.
    ///
    /// - Parameter hasOlder: older events exist that are not loaded; a delivered prompt older than the oldest loaded
    ///   event is then assumed to be in those older pages rather than shown as queued.
    static func build(
        events: [TranscriptEvent], commands: [PromptCommand], local: [LocalPrompt], hasOlder: Bool,
        calendar: Calendar = .current
    ) -> [TranscriptItem] {
        var seen = Set<DocID>()
        let sorted = events.sorted { $0.seq < $1.seq }.filter { seen.insert($0.id).inserted }
        let commandsById = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let eventCommandIds = Set(sorted.compactMap(\.commandId))

        var items: [TranscriptItem] = []
        for event in sorted {
            if let item = item(for: event, command: event.commandId.flatMap { commandsById[$0] }) {
                items.append(item)
            }
        }

        // Prompts not in the transcript yet: queued at the relay, queued on the computer, or failed.
        let oldestLoaded = sorted.first?.at ?? 0
        var pending: [TranscriptItem] = []
        var clientIdsFromCommands = Set<String>()
        var commandIdsShown = Set<DocID>()
        for command in commands where command.isMine {
            if let clientId = command.clientId { clientIdsFromCommands.insert(clientId) }
            guard !eventCommandIds.contains(command.id) else { continue }
            switch command.status {
            case .done, .unknown:
                continue
            case .delivered where hasOlder && command.createdAt < oldestLoaded:
                continue
            default:
                break
            }
            commandIdsShown.insert(command.id)
            let message = UserMessage(
                text: command.text, isRemote: true, fromLabel: command.fromLabel, tick: DeliveryTick(command.status),
                error: command.status == .failed ? command.error : nil, commandId: command.id,
                clientId: command.clientId, isPending: true)
            pending.append(
                TranscriptItem(
                    id: "pending-\(command.clientId ?? command.id)", kind: .user(message),
                    date: Date(milliseconds: command.createdAt)))
        }
        for prompt in local {
            if clientIdsFromCommands.contains(prompt.clientId) { continue }
            if let commandId = prompt.commandId,
                eventCommandIds.contains(commandId) || commandIdsShown.contains(commandId) || commandsById[commandId] != nil
            {
                continue
            }
            let message = UserMessage(
                text: prompt.text, isRemote: true, fromLabel: nil,
                tick: prompt.failure == nil ? .sending : .failed, error: prompt.failure,
                commandId: prompt.commandId, clientId: prompt.clientId, isPending: true)
            pending.append(
                TranscriptItem(
                    id: "pending-\(prompt.clientId)", kind: .user(message), date: Date(milliseconds: prompt.createdAt)))
        }
        pending.sort { $0.date < $1.date }
        // A failed prompt stays where it was sent in time (Telegram keeps failed messages in place); prompts still on
        // their way go after everything the computer has written.
        for item in pending {
            guard case .user(let message) = item.kind, message.tick == .failed else {
                items.append(item)
                continue
            }
            let index = items.lastIndex(where: { !$0.id.hasPrefix("pending-") && $0.date <= item.date }).map { $0 + 1 } ?? 0
            items.insert(item, at: min(index, items.count))
        }
        // Queued prompts stay last even when a failed one was inserted after them above.
        let queued = items.filter { item in
            if case .user(let message) = item.kind { return message.isPending && message.tick != .failed }
            return false
        }
        items.removeAll { item in queued.contains(where: { $0.id == item.id }) }
        items.append(contentsOf: queued)

        return arrange(items, calendar: calendar)
    }

    /// The transcript item for one event, or nil for a pure turn marker.
    static func item(for event: TranscriptEvent, command: PromptCommand?) -> TranscriptItem? {
        let date = event.date
        switch event.kind {
        case .user:
            // Ticks only on this device's own prompts (Telegram marks outgoing messages only).
            let own = command?.isMine == true ? command : nil
            let message = UserMessage(
                text: event.text, isRemote: event.isRemote, fromLabel: event.fromLabel ?? command?.fromLabel,
                tick: own.map { DeliveryTick($0.status) }, error: own?.status == .failed ? own?.error : nil,
                commandId: event.commandId, clientId: own?.clientId, isPending: false)
            return TranscriptItem(id: event.id, kind: .user(message), date: date, seq: event.seq)
        case .assistant:
            return TranscriptItem(id: event.id, kind: .assistant(text: event.text), date: date, seq: event.seq)
        case .thought:
            return TranscriptItem(id: event.id, kind: .thought(text: event.text), date: date, seq: event.seq)
        case .tool:
            let call = ToolCall(
                title: event.title ?? event.text, toolKind: event.toolKind ?? "other", status: ToolStatus(event.status),
                detail: event.text)
            return TranscriptItem(id: event.id, kind: .tool(call), date: date, seq: event.seq)
        case .system, .unknown:
            guard let notice = systemNotice(text: event.text, status: event.status) else { return nil }
            return TranscriptItem(id: event.id, kind: .notice(text: notice.text, style: notice.style), date: date, seq: event.seq)
        case .error:
            let text = event.text.isEmpty ? String(localized: "Something went wrong.") : event.text
            return TranscriptItem(id: event.id, kind: .notice(text: text, style: .error), date: date, seq: event.seq)
        }
    }

    /// What a system event says, from its stop reason. A plain end of turn is only a marker and shows nothing.
    static func systemNotice(text: String, status: String?) -> (text: String, style: NoticeStyle)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case "cancelled":
            return (String(localized: "Stopped"), .stopped)
        case "max_tokens":
            return (trimmed.isEmpty ? String(localized: "Stopped: the reply reached its length limit") : trimmed, .system)
        case "refusal":
            return (trimmed.isEmpty ? String(localized: "The model declined to continue") : trimmed, .system)
        case "end_turn", nil:
            return trimmed.isEmpty ? nil : (trimmed, .system)
        default:
            return trimmed.isEmpty ? nil : (trimmed, .system)
        }
    }

    private static func author(of item: TranscriptItem) -> Author {
        switch item.kind {
        case .user: .user
        case .assistant, .thought, .tool: .agent
        case .notice, .day: .other
        }
    }

    /// Inserts day headers and sets each item's group position.
    static func arrange(_ items: [TranscriptItem], calendar: Calendar = .current) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        out.reserveCapacity(items.count + 4)
        var lastDay: Date?
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if lastDay != day {
                out.append(TranscriptItem(id: "day-\(Int(day.timeIntervalSince1970))", kind: .day, date: day))
                lastDay = day
            }
            out.append(item)
        }
        // Group positions: a run is consecutive items of one author, each within the window of the previous one.
        var index = 0
        while index < out.count {
            let runAuthor = author(of: out[index])
            guard runAuthor != .other else {
                out[index].position = .single
                index += 1
                continue
            }
            var end = index
            while end + 1 < out.count, author(of: out[end + 1]) == runAuthor,
                out[end + 1].date.timeIntervalSince(out[end].date) <= groupWindow
            {
                end += 1
            }
            if end == index {
                out[index].position = .single
            } else {
                out[index].position = .first
                for middle in (index + 1)..<end { out[middle].position = .middle }
                out[end].position = .last
            }
            index = end + 1
        }
        return out
    }
}
