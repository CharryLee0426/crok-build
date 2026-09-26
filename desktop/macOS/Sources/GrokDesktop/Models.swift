import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Project: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Conversation: Identifiable, Codable, Sendable {
    var id = UUID()
    var projectID: UUID
    var title: String = "New task"
    var sessionID: String?
    var messages: [Message] = []
    var updatedAt = Date()
    var isArchived = false
    var isPinned = false
    var modelID: String?
    var reasoningID: String?
    /// Side questions (`/btw`) asked about this task, with their answers.
    var sideChat: [SideChatMessage]?
}

struct Message: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case user, assistant, thought, tool, system }
    var id = UUID()
    var kind: Kind
    var text: String
    var toolID: String?
    var status: String?
    var detail: String?
    /// When the message began streaming or was sent; unknown for replayed history.
    var createdAt: Date?
    /// Images, files, and folders sent with a prompt.
    var attachments: [MessageAttachment]?
}

/// What a sent prompt carried, as the transcript shows it: images keep a small preview.
struct MessageAttachment: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case image, file, folder }
    var id = UUID()
    var kind: Kind
    var name: String
    var path: String?
    /// A downscaled JPEG or PNG of an image.
    var thumbnail: Data?
}

/// One entry of a task's side chat.
struct SideChatMessage: Identifiable, Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case question, answer, failure }
    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
}

struct ModelOption: Identifiable, Equatable {
    var id: String
    var name: String
    var reasoningOptions: [ModelOption] = []
    var defaultReasoningID = ""
}

enum SessionOptions {
    static func models(_ state: [String: Any]) -> [ModelOption] {
        (state["availableModels"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["modelId"] as? String else { return nil }
            let meta = value["_meta"] as? [String: Any] ?? [:]
            var model = ModelOption(id: id, name: value["name"] as? String ?? id)
            guard meta["supportsReasoningEffort"] as? Bool == true else { return model }
            let valid = Set(["none", "minimal", "low", "medium", "high", "xhigh", "max"])
            let efforts = (meta["reasoningEfforts"] as? [Any] ?? []).compactMap { entry -> (ModelOption, String, Bool)? in
                let item = entry as? [String: Any] ?? ["value": entry]
                guard let canonical = item["value"] as? String, valid.contains(canonical) else { return nil }
                let id = item["id"] as? String ?? canonical
                return (ModelOption(id: id, name: item["label"] as? String ?? label(canonical)), canonical, item["default"] as? Bool ?? false)
            }
            model.reasoningOptions = efforts.isEmpty
                ? ["minimal", "low", "medium", "high", "xhigh"].map { ModelOption(id: $0, name: label($0)) }
                : efforts.map { $0.0 }
            let current = meta["reasoningEffort"] as? String ?? ""
            model.defaultReasoningID = efforts.first(where: { $0.1 == current })?.0.id
                ?? model.reasoningOptions.first(where: { $0.id == current })?.id
                ?? (valid.contains(current) ? current : nil)
                ?? efforts.first(where: { $0.2 })?.0.id ?? model.reasoningOptions.first?.id ?? ""
            return model
        }
    }

    static func choices(_ option: [String: Any]) -> [ModelOption] {
        (option["options"] as? [[String: Any]] ?? []).flatMap { item -> [ModelOption] in
            if item["options"] != nil { return choices(item) }
            guard let id = item["value"] as? String else { return [] }
            return [ModelOption(id: id, name: item["name"] as? String ?? id)]
        }
    }

    private static func label(_ value: String) -> String { value == "xhigh" ? "Extra high" : value.capitalized }
}

struct PermissionOption: Identifiable {
    var id: String
    var name: String
    var kind: String
}

struct Approval: Identifiable {
    var id = UUID()
    var requestID: Any
    var title: String
    var detail: String
    var options: [PermissionOption]
}

struct PlanEntry: Identifiable {
    var id: Int
    var content: String
    var status: String
}

struct AgentQuestion: Identifiable {
    var id: String { question }
    var question: String
    var options: [String]
    var multiSelect: Bool
}

struct QuestionRequest: Identifiable {
    var id = UUID()
    var requestID: Any
    var questions: [AgentQuestion]

    func response(answers: [String: [String]], notes: [String: String] = [:]) -> [String: Any] {
        var wireAnswers: [String: [String]] = [:]
        var annotations: [String: [String: String]] = [:]
        for question in questions {
            let supplied = answers[question.question] ?? []
            let selected = question.options.filter { supplied.contains($0) }
            let custom = supplied.filter { !question.options.contains($0) }
            let note = ([notes[question.question] ?? ""] + custom).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
            wireAnswers[question.question] = selected.isEmpty && !note.isEmpty ? ["Other"] : selected
            if !note.isEmpty { annotations[question.question] = ["notes": note] }
        }
        return ["outcome": "accepted", "answers": wireAnswers, "annotations": annotations]
    }
}

struct RunState {
    var isRunning = false
    var isConfiguring = false
    var phase = "Ready"
    var approvals: [Approval] = []
    var models: [ModelOption] = []
    var modes: [ModelOption] = []
    var modelID = ""
    var modeID = ""
    var reasoningOptions: [ModelOption] = []
    var reasoningID = ""
    var plan: [PlanEntry] = []
    var questions: [QuestionRequest] = []
    var commands: [SlashCommand] = []
    var commandsLoaded = false
    var availableTools: [String]?
    var goal: GoalState?
    var subagents: [SubagentState] = []
}

struct DesktopState: Codable, Sendable {
    var projects: [Project] = []
    var conversations: [Conversation] = []
    var selectedProjectID: UUID?
    var selectedConversationID: UUID?
    var selectedModelID: String?
    var selectedReasoningID: String?
    var deletedSessionIDs: Set<String> = []
    /// Project folders the user folded in the sidebar. Folders are expanded by default.
    var collapsedProjectIDs: Set<UUID> = []
}

extension DesktopState {
    private enum CodingKeys: String, CodingKey {
        case projects, conversations, selectedProjectID, selectedConversationID
        case selectedModelID, selectedReasoningID, deletedSessionIDs, collapsedProjectIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
        conversations = try values.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        selectedProjectID = try values.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        selectedConversationID = try values.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
        selectedModelID = try values.decodeIfPresent(String.self, forKey: .selectedModelID)
        selectedReasoningID = try values.decodeIfPresent(String.self, forKey: .selectedReasoningID)
        deletedSessionIDs = try values.decodeIfPresent(Set<String>.self, forKey: .deletedSessionIDs) ?? []
        collapsedProjectIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .collapsedProjectIDs) ?? []
    }
}

enum DesktopVersion {
    /// Packaging writes `desktop/macOS/VERSION` into Info.plist; unpackaged development runs have none.
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
}

enum DesktopPaths {
    static var stateFile: URL {
        if let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_STATE_FILE"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "GrokDesktopStateFile") as? String, path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crok Desktop", isDirectory: true).appendingPathComponent("state.json")
    }

    static func findHarness(in project: String? = nil) -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("crok").path { candidates.append(bundled) }
        for base in [project, ProcessInfo.processInfo.environment["CROK_BUILD_ROOT"], fm.currentDirectoryPath].compactMap({ $0 }) {
            candidates += ["\(base)/target/release/xai-grok-pager", "\(base)/target/debug/xai-grok-pager"]
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/crok", "/usr/local/bin/crok"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/crok" }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }) ?? ""
    }
}

enum TranscriptReducer {
    static func text(from block: [String: Any]) -> String {
        if let text = block["text"] as? String { return text }
        if let resource = block["resource"] as? [String: Any] {
            return resource["text"] as? String ?? resource["uri"] as? String ?? ""
        }
        if block["type"] as? String == "image" { return "[Image]" }
        return ""
    }

    /// An image or resource link in a prompt, as the transcript shows it.
    static func attachment(from block: [String: Any]) -> MessageAttachment? {
        switch block["type"] as? String {
        case "image":
            let thumbnail = (block["data"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.flatMap { data -> Data? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = PromptAttachmentsModel.downscaled(source, maxSide: PromptAttachmentsModel.thumbnailSide) else { return nil }
                return PromptAttachmentsModel.encode(image, as: .jpeg, quality: 0.72)
            }
            return MessageAttachment(kind: .image, name: "Image", thumbnail: thumbnail)
        case "resource_link":
            guard let uri = block["uri"] as? String else { return nil }
            let url = URL(string: uri)
            let path = url?.isFileURL == true ? url?.path : nil
            let isFolder = (block["_meta"] as? [String: Any])?["x.ai/kind"] as? String == "directory"
            return MessageAttachment(kind: isFolder ? .folder : .file, name: block["name"] as? String ?? url?.lastPathComponent ?? uri, path: path ?? uri)
        default:
            return nil
        }
    }

    static func apply(_ update: [String: Any], to messages: inout [Message], date: Date? = nil) {
        let kind = update["sessionUpdate"] as? String ?? ""
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk":
            let role: Message.Kind = kind == "agent_message_chunk" ? .assistant : kind == "agent_thought_chunk" ? .thought : .user
            let block = update["content"] as? [String: Any] ?? [:]
            if role == .user, let attachment = attachment(from: block) {
                if messages.last?.kind == .user { messages[messages.count - 1].attachments = (messages[messages.count - 1].attachments ?? []) + [attachment] }
                else { messages.append(Message(kind: .user, text: "", createdAt: date, attachments: [attachment])) }
                return
            }
            let content = text(from: block)
            guard !content.isEmpty else { return }
            if messages.last?.kind == role { messages[messages.count - 1].text += content }
            else { messages.append(Message(kind: role, text: content, createdAt: date)) }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            let contents = update["content"] as? [[String: Any]] ?? []
            let detail = contents.compactMap { item -> String? in
                if item["type"] as? String == "diff" {
                    return "\(item["path"] as? String ?? "File")\n\(item["newText"] as? String ?? "")"
                }
                if let content = item["content"] as? [String: Any] { return text(from: content) }
                return nil
            }.joined(separator: "\n")
            if let index = messages.firstIndex(where: { $0.toolID == id }) {
                if let title = update["title"] as? String { messages[index].text = title }
                if let status = update["status"] as? String { messages[index].status = status }
                if !detail.isEmpty { messages[index].detail = detail }
            } else {
                messages.append(Message(kind: .tool, text: update["title"] as? String ?? "Tool call", toolID: id,
                                        status: update["status"] as? String ?? "pending", detail: detail, createdAt: date))
            }
        default: break
        }
    }
}
