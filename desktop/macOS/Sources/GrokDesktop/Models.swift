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

extension Conversation {
    /// A copy without its transcript, for views that list tasks. A view keeps what it was given
    /// until it renders again, and a transcript kept that way is copied whole on every streamed
    /// update instead of grown in place.
    var listing: Conversation {
        var copy = self
        copy.messages = []
        copy.sideChat = nil
        return copy
    }
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
    /// Images, files, and folders sent with a prompt; images a tool returned or a reply carried.
    var attachments: [MessageAttachment]?
}

/// What a sent prompt carried, or an image a tool or reply showed, as the transcript shows it:
/// images keep a small preview, and the whole image in the `ImageStore`.
struct MessageAttachment: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case image, file, folder }
    /// Where a transcript image came from, when it was not sent with a prompt.
    enum Origin: String, Codable, Sendable { case tool, generated, reply }
    var id = UUID()
    var kind: Kind
    var name: String
    var path: String?
    /// A downscaled JPEG or PNG of an image.
    var thumbnail: Data?
    /// The whole image's file name in the `ImageStore`.
    var blob: String?
    var mimeType: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var origin: Origin?
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
    /// The model's context window in tokens (`_meta.totalContextTokens`), when the catalog says.
    var contextWindow: Int?
}

enum SessionOptions {
    static func models(_ state: [String: Any]) -> [ModelOption] {
        (state["availableModels"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["modelId"] as? String else { return nil }
            let meta = value["_meta"] as? [String: Any] ?? [:]
            var model = ModelOption(id: id, name: value["name"] as? String ?? id)
            model.contextWindow = (meta["totalContextTokens"] as? Int).flatMap { $0 > 0 ? $0 : nil }
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
    /// Task order the user dragged a project folder into, keyed by project ID. A folder without
    /// one lists its tasks newest first.
    var taskOrder: [String: [UUID]] = [:]
    /// Pinned tasks in the order the user dragged them into; empty lists them newest first.
    var pinnedOrder: [UUID] = []
}

extension DesktopState {
    private enum CodingKeys: String, CodingKey {
        case projects, conversations, selectedProjectID, selectedConversationID
        case selectedModelID, selectedReasoningID, deletedSessionIDs, collapsedProjectIDs
        case taskOrder, pinnedOrder
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
        taskOrder = try values.decodeIfPresent([String: [UUID]].self, forKey: .taskOrder) ?? [:]
        pinnedOrder = try values.decodeIfPresent([UUID].self, forKey: .pinnedOrder) ?? []
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
    /// Whether two transcripts show the same thing, ignoring message ids and times, which a replay
    /// assigns afresh. Lengths are compared first, so a differing transcript rarely reads its text.
    static func sameContent(_ lhs: [Message], _ rhs: [Message]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.kind == b.kind && a.status == b.status && a.toolID == b.toolID
                && a.text.utf8.count == b.text.utf8.count && (a.detail?.utf8.count ?? -1) == (b.detail?.utf8.count ?? -1)
                && a.attachments?.count == b.attachments?.count
                && a.attachments?.map(\.blob) == b.attachments?.map(\.blob)
        } && zip(lhs, rhs).allSatisfy { a, b in a.text == b.text && a.detail == b.detail }
    }

    static func text(from block: [String: Any]) -> String {
        if let text = block["text"] as? String { return text }
        if let resource = block["resource"] as? [String: Any] {
            return resource["text"] as? String ?? resource["uri"] as? String ?? ""
        }
        if block["type"] as? String == "image" { return "[Image]" }
        return ""
    }

    /// An ACP image block as a transcript image; one whose data does not decode is dropped.
    static func image(from block: [String: Any], name fallback: String = "Image", origin: MessageAttachment.Origin? = nil) -> MessageAttachment? {
        guard block["type"] as? String == "image" else { return nil }
        let url = (block["uri"] as? String).flatMap(URL.init(string:))
        let path = url?.isFileURL == true ? url?.path : nil
        let name = url.map(\.lastPathComponent).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } ?? fallback
        if let data = (block["data"] as? String).flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }), !data.isEmpty {
            return MessageAttachment.image(data: data, mimeType: block["mimeType"] as? String, name: name, path: path, origin: origin)
        }
        // No bytes: a file the viewer can still open.
        guard let path else { return nil }
        return MessageAttachment(kind: .image, name: name, path: path, mimeType: block["mimeType"] as? String, origin: origin)
    }

    /// An image a media tool saved (`rawOutput` `{"type": "ImageGen", "path": …}`), read from disk.
    static func generatedImage(from rawOutput: Any?) -> MessageAttachment? {
        guard let output = rawOutput as? [String: Any], ["ImageGen", "ImageEdit"].contains(output["type"] as? String ?? ""),
              let path = output["path"] as? String, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = (output["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return MessageAttachment(kind: .image, name: name, path: path, origin: .generated)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let thumbnail = PromptAttachmentsModel.downscaled(source, maxSide: PromptAttachmentsModel.thumbnailSide)
            .flatMap { PromptAttachmentsModel.encode($0, as: .jpeg, quality: 0.72) }
        return MessageAttachment(kind: .image, name: name, path: path, thumbnail: thumbnail,
                                 mimeType: (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType },
                                 pixelWidth: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                                 pixelHeight: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, origin: .generated)
    }

    /// An image or resource link in a prompt, as the transcript shows it.
    static func attachment(from block: [String: Any]) -> MessageAttachment? {
        switch block["type"] as? String {
        case "image":
            return image(from: block)
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

    /// How far back a `tool_call` looks for a call it repeats before adding a new one.
    static let newCallLookback = 256

    /// Applies a session update to a transcript. Returns the index of the message it changed or
    /// added, so that what shows the transcript need not look at every message to find it; nil
    /// when the update left the transcript as it was.
    @discardableResult
    static func apply(_ update: [String: Any], to messages: inout [Message], date: Date? = nil) -> Int? {
        let kind = update["sessionUpdate"] as? String ?? ""
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk":
            let role: Message.Kind = kind == "agent_message_chunk" ? .assistant : kind == "agent_thought_chunk" ? .thought : .user
            let block = update["content"] as? [String: Any] ?? [:]
            let attachment = role == .user ? attachment(from: block) : role == .assistant ? image(from: block, origin: .reply) : nil
            if let attachment {
                if messages.last?.kind == role { messages[messages.count - 1].attachments = (messages[messages.count - 1].attachments ?? []) + [attachment] }
                else { messages.append(Message(kind: role, text: "", createdAt: date, attachments: [attachment])) }
                return messages.count - 1
            }
            let content = text(from: block)
            guard !content.isEmpty else { return nil }
            if messages.last?.kind == role { messages[messages.count - 1].text += content }
            else { messages.append(Message(kind: role, text: content, createdAt: date)) }
            return messages.count - 1
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return nil }
            let contents = update["content"] as? [[String: Any]] ?? []
            let detail = contents.compactMap { item -> String? in
                if item["type"] as? String == "diff" {
                    return "\(item["path"] as? String ?? "File")\n\(item["newText"] as? String ?? "")"
                }
                // Images show as images, under the call.
                if let content = item["content"] as? [String: Any], content["type"] as? String != "image" { return text(from: content) }
                return nil
            }.joined(separator: "\n")
            // Updates are for recent calls, so the search runs from the end. A new call is looked
            // for only among recent messages: searching all of a long transcript for each new call
            // made streaming, and loading, a task quadratic in its length.
            let searched = kind == "tool_call" ? messages.indices.suffix(Self.newCallLookback) : messages.indices.suffix(from: 0)
            let images = toolImages(contents, rawOutput: update["rawOutput"])
            if let index = searched.last(where: { messages[$0].toolID == id }) {
                if let title = update["title"] as? String { messages[index].text = title }
                if let status = update["status"] as? String { messages[index].status = status }
                if !detail.isEmpty { messages[index].detail = detail }
                // An update that resends the same images keeps the ones shown, so the row does not redraw.
                if let images, images.map(\.blob) != messages[index].attachments?.map(\.blob)
                    || images.map(\.path) != messages[index].attachments?.map(\.path) {
                    messages[index].attachments = images
                }
                return index
            }
            messages.append(Message(kind: .tool, text: update["title"] as? String ?? "Tool call", toolID: id,
                                    status: update["status"] as? String ?? "pending", detail: detail, createdAt: date, attachments: images))
            return messages.count - 1
        default: return nil
        }
    }

    /// The images a tool call's update shows: image content (a read image, PDF pages, an MCP
    /// screenshot) and the file a media tool saved. Nil when the update carries none.
    static func toolImages(_ contents: [[String: Any]], rawOutput: Any?) -> [MessageAttachment]? {
        let blocks = contents.compactMap { $0["content"] as? [String: Any] }.filter { $0["type"] as? String == "image" }
        var images = blocks.enumerated().compactMap { index, block in
            image(from: block, name: blocks.count == 1 ? "Image" : "Image \(index + 1)", origin: .tool)
        }
        if let generated = generatedImage(from: rawOutput), !images.contains(where: { $0.path == generated.path }) { images.append(generated) }
        return images.isEmpty ? nil : images
    }
}
