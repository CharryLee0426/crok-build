import Foundation

// The composer's slash commands (relay/DESIGN.md §5 "Commands in the composer", Telegram's bot menu): this device's
// own commands first, then the session's (`sessions:commands`); `/model` and `/think` answer with a bot card.

/// A command the phone handles itself.
enum DeviceCommand: String, CaseIterable, Sendable {
    case new, model, think, stop, info

    /// Takes the rest of the line (`/new [prompt]`, `/model [name]`, `/think [level]`); works without it too.
    var takesArgument: Bool {
        switch self {
        case .new, .model, .think: true
        case .stop, .info: false
        }
    }

    var hint: String? {
        switch self {
        case .new: String(localized: "[prompt]")
        case .model: String(localized: "[name]")
        case .think: String(localized: "[level]")
        case .stop, .info: nil
        }
    }

    var summary: String {
        switch self {
        case .new: String(localized: "Start a new session in this project")
        case .model: String(localized: "Change the model (on this session's computer)")
        case .think: String(localized: "Change the thinking level")
        case .stop: String(localized: "Stop the running turn")
        case .info: String(localized: "Session info")
        }
    }
}

/// One row of the command list.
struct CommandMenuItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case device(DeviceCommand)
        case session
    }

    var name: String
    var description: String
    var hint: String?
    var source: Source

    var id: String { name }

    /// Tapping fills the field with `/name ` for the rest instead of sending at once.
    var takesArgument: Bool {
        switch source {
        case .device(let command): command.takesArgument
        case .session: hint != nil
        }
    }
}

enum CommandMenu {
    /// What the session allows of the phone's own commands: `/think` only when its model has thinking levels (or the
    /// relay cannot say), `/stop` only while a turn runs.
    static func deviceCommands(isRunning: Bool, modelHasThinking: Bool?) -> [DeviceCommand] {
        DeviceCommand.allCases.filter { command in
            switch command {
            case .think: modelHasThinking != false
            case .stop: isRunning
            default: true
            }
        }
    }

    /// The device's commands, then the session's, filtered by the name typed so far (`mo` → `model`). A session
    /// command named like one of the phone's is left out: typing it runs the phone's.
    static func items(device: [DeviceCommand], session: [SlashCommand], filter: String = "") -> [CommandMenuItem] {
        let phoneNames = Set(DeviceCommand.allCases.map(\.rawValue))
        let all =
            device.map { CommandMenuItem(name: $0.rawValue, description: $0.summary, hint: $0.hint, source: .device($0)) }
            + session
            .filter { !phoneNames.contains($0.name.lowercased()) }
            .map { CommandMenuItem(name: $0.name, description: $0.description, hint: $0.hint, source: .session) }
        let prefix = filter.lowercased()
        guard !prefix.isEmpty else { return all }
        return all.filter { $0.name.lowercased().hasPrefix(prefix) }
    }

    /// While the field holds `/` and the start of a name (no space yet), the name typed so far; else nil.
    static func typedName(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }
}

/// A line that starts with `/`: the command's name and what follows it.
struct ComposerCommand: Equatable, Sendable {
    var name: String
    var argument: String

    static func parse(_ text: String) -> ComposerCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix(while: { !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return ComposerCommand(name: String(name), argument: argument)
    }

    /// The phone's own command this line names (case-insensitive), if any.
    var deviceCommand: DeviceCommand? { DeviceCommand(rawValue: name.lowercased()) }
}

/// Matching `/model grok` or `/think high` against the computer's choices: an exact id, value or name first, else a
/// unique prefix of one; case does not matter.
enum ChoiceMatch<Choice> {
    case one(Choice)
    case none
    case ambiguous([Choice])

    static func find(_ query: String, in choices: [Choice], keys: (Choice) -> [String]) -> ChoiceMatch {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return .none }
        let exact = choices.filter { keys($0).contains { $0.lowercased() == wanted } }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let prefixed = choices.filter { keys($0).contains { $0.lowercased().hasPrefix(wanted) } }
        switch prefixed.count {
        case 0: return .none
        case 1: return .one(prefixed[0])
        default: return .ambiguous(prefixed)
        }
    }
}

/// Where a new session starts: a folder on one computer (a project of the list, or the folder of an open session).
struct NewSessionTarget: Hashable, Sendable {
    var deviceId: DocID
    var deviceName: String
    var path: String

    var projectName: String { PathText.lastComponent(path) }

    init(deviceId: DocID, deviceName: String, path: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.path = path
    }

    init(group: ProjectGroup) {
        self.init(deviceId: group.deviceId, deviceName: group.deviceName, path: group.path)
    }
}

/// The projects a new session can start in: those of online computers, grouped by computer, most recent first.
enum NewSessionChoices {
    struct Computer: Identifiable, Equatable, Sendable {
        var deviceId: DocID
        var name: String
        var projects: [ProjectGroup]
        var id: DocID { deviceId }
    }

    static func computers(from groups: [ProjectGroup]) -> [Computer] {
        let online = groups.filter(\.deviceOnline)
        var byDevice: [DocID: Computer] = [:]
        for group in online {
            byDevice[group.deviceId, default: Computer(deviceId: group.deviceId, name: group.deviceName, projects: [])]
                .projects.append(group)
        }
        return byDevice.values
            .map { computer in
                var sorted = computer
                sorted.projects.sort { a, b in
                    a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.name < b.name
                }
                return sorted
            }
            .sorted { a, b in
                let la = a.projects.first?.lastActivityAt ?? 0
                let lb = b.projects.first?.lastActivityAt ?? 0
                return la != lb ? la > lb : a.name < b.name
            }
    }
}
