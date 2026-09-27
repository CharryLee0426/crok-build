import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Taxonomy (frozen v1 wire values)

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, idea
    case missingCapability = "missing_capability"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bug: return "Bug"
        case .idea: return "Idea"
        case .missingCapability: return "Missing capability"
        }
    }
}

enum FeedbackTaskCategory: String, CaseIterable, Identifiable {
    case codeEdit = "code_edit", debug, explain, plan, shell, search, review, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .codeEdit: return "Code edit"
        case .debug: return "Debug"
        case .explain: return "Explain"
        case .plan: return "Plan"
        case .shell: return "Shell"
        case .search: return "Search"
        case .review: return "Review"
        case .other: return "Other"
        }
    }
}

enum FeedbackFailureMode: String, CaseIterable, Identifiable {
    case overeager, stoppedEarly = "stopped_early", unwantedScope = "unwanted_scope", didntAskForHelp = "didnt_ask_for_help"
    case excessiveQuestions = "excessive_questions", subagentOverspawn = "subagent_overspawn", overCorrection = "over_correction"
    case ignoredInstructions = "ignored_instructions", hallucinated, sloppyCode = "sloppy_code", destructive
    case lostContext = "lost_context", stuckInALoop = "stuck_in_a_loop", modelRegression = "model_regression"
    case disputed, wrongTone = "wrong_tone", unclearOutput = "unclear_output", other

    var id: String { rawValue }

    /// Legacy spellings older drafts may still carry.
    init?(wire: String) {
        let aliases = ["did_too_much": "overeager", "gave_up_early": "stopped_early", "ignored_direction": "ignored_instructions",
                       "wrong_or_made_up": "hallucinated", "broke_something": "destructive", "stuck_in_loop": "stuck_in_a_loop"]
        self.init(rawValue: aliases[wire] ?? wire)
    }

    var label: String {
        switch self {
        case .overeager: return "Overeager"
        case .stoppedEarly: return "Stopping early"
        case .unwantedScope: return "Unwanted scope"
        case .didntAskForHelp: return "Didn't ask for help"
        case .excessiveQuestions: return "Excessive questions"
        case .subagentOverspawn: return "Subagent overspawn"
        case .overCorrection: return "Over correction"
        case .ignoredInstructions: return "Instruction following"
        case .hallucinated: return "Overconfidence and hallucination"
        case .sloppyCode: return "Code quality"
        case .destructive: return "Destructive actions"
        case .lostContext: return "Context and memory"
        case .stuckInALoop: return "Repetition and looping"
        case .modelRegression: return "Model regression"
        case .disputed: return "Dispute or decline"
        case .wrongTone: return "Tone or preachiness"
        case .unclearOutput: return "Unclear output"
        case .other: return "Other"
        }
    }

    var meaning: String {
        switch self {
        case .overeager: return "Did more than asked, acted before being told, jumped in without enough info"
        case .stoppedEarly: return "Quit early, handed back work that could have been finished"
        case .unwantedScope: return "Not stopping"
        case .didntAskForHelp: return "Didn't ask the user for help when stuck"
        case .excessiveQuestions: return "Asked clarifying questions when there was enough to proceed"
        case .subagentOverspawn: return "Launched more subagents than the task warranted"
        case .overCorrection: return "Fixed feedback by swinging too far the other way"
        case .ignoredInstructions: return "Ignored or missed explicit instructions or constraints"
        case .hallucinated: return "Stated something confidently that was wrong or fabricated"
        case .sloppyCode: return "Buggy, sloppy, or poorly structured code"
        case .destructive: return "Did or risked something hard to reverse"
        case .lostContext: return "Lost earlier context, forgot established facts, contradicted itself"
        case .stuckInALoop: return "Repeated output or retried the same failing action"
        case .modelRegression: return "Behavior noticeably worse than a previous model version"
        case .disputed: return "Refused or argued against a reasonable request"
        case .wrongTone: return "Wrong tone — moralizing, condescending, sycophantic, verbose"
        case .unclearOutput: return "Output was hard to read or interpret"
        case .other: return "Model-behavior issue fitting none of the above"
        }
    }

    /// The failure picker's sections, in the terminal's order.
    static let groups: [(title: String, modes: [FeedbackFailureMode])] = [
        ("Doing the wrong amount of work", [.overeager, .stoppedEarly, .unwantedScope, .didntAskForHelp, .excessiveQuestions, .subagentOverspawn, .overCorrection]),
        ("Wrong outputs", [.ignoredInstructions, .hallucinated, .sloppyCode, .destructive, .lostContext, .stuckInALoop, .modelRegression]),
        ("Style", [.disputed, .wrongTone, .unclearOutput, .other]),
    ]
}

struct FeedbackTaxonomySelection: Equatable {
    var type: FeedbackKind?
    var taskCategory: FeedbackTaskCategory?
    var failureMode: FeedbackFailureMode?
}

enum FeedbackTraceChoice: CaseIterable, Identifiable {
    case sendThisSession, feedbackOnly, neverAsk
    var id: Self { self }
    var label: String {
        switch self {
        case .sendThisSession: return "Send this session's trace"
        case .feedbackOnly: return "No, just the feedback"
        case .neverAsk: return "No, and don't ask again"
        }
    }
}

// MARK: - Copy

enum FeedbackCopy {
    static let thanks = "Thanks for the feedback! The Crok Build team is on it."
    static let emptySubmit = "Add feedback text or an image before sending."
    static let draftNeedsType = "Choose a type before sending this draft."
    static let needsTask = "Open a task to send feedback: it is sent with that task's session details."
    static let enqueuedUnknown = "Feedback was enqueued, but the response did not arrive in time. The send may still complete; do not resend it yet."
    static let draftCleanupFailed = "Feedback was sent, but the stored draft could not be deleted. Delete it manually; do not resend."
    static let draftLocalOnly = "Feedback was saved locally but was not sent. The draft was kept."
    static let unknownSaved = "The remote outcome is unknown. The latest text was saved to this draft and copied to the clipboard. Close and do not resend."
    static let unknownSaveFailed = "The remote outcome is unknown. The latest text was copied to the clipboard, but it could not be saved to the draft. Close and do not resend."
    static let unknownNotSaved = "The remote outcome is unknown. The latest text was copied to the clipboard. Close and do not resend."
    static let traceDisclosure = "One archive of this session is sent with this report only. Nothing is turned on for future sessions."
    static let discardForDraft = "Discard the current Write composition and open the selected draft?"
    static let deleteDraft = "Delete this feedback draft?"
    static let deleteRecoveryCopy = "Delete the stored recovery copy? Your current edits will remain."

    /// The trace question follows the chosen type only; the text never picks it.
    static func tracePrompt(for type: FeedbackKind?) -> String {
        switch type {
        case .bug: return "Attach this session's trace to help us debug this bug?"
        case .idea: return "Attach this session's trace to give this idea context?"
        case .missingCapability: return "Attach this session's trace to show what was missing?"
        case nil: return "Attach this session's trace to your feedback?"
        }
    }
}

enum FeedbackText {
    /// The first non-blank line, trimmed and cut to 80 characters, or "Feedback draft".
    static func deriveTitle(_ text: String) -> String {
        guard let line = text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
            return "Feedback draft"
        }
        return String(line.prefix(80))
    }

    static func postText(title: String, details: String) -> String {
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(details.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - Attachments

struct FeedbackAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let fileName: String?

    static func == (lhs: FeedbackAttachment, rhs: FeedbackAttachment) -> Bool { lhs.id == rhs.id }

    /// `{data, mimeType, fileName}` with standard base64.
    var wire: [String: Any] {
        var value: [String: Any] = ["data": data.base64EncodedString(), "mimeType": mimeType]
        if let fileName { value["fileName"] = fileName }
        return value
    }

    /// PNG, JPEG, GIF, and WebP are sent as they are; anything else AppKit can read is converted to PNG.
    static func make(data: Data, fileName: String?) -> FeedbackAttachment? {
        if let mime = sniffedType(data) { return FeedbackAttachment(data: data, mimeType: mime, fileName: fileName) }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let name = fileName.map { (($0 as NSString).deletingPathExtension as NSString).appendingPathExtension("png") ?? $0 }
        return FeedbackAttachment(data: png, mimeType: "image/png", fileName: name)
    }

    static func sniffedType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

/// The harness's limits: four images, 8 MB each, 16 MB together.
enum FeedbackImageRules {
    static let maximumCount = 4
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumTotalBytes = 16 * 1024 * 1024

    static func admit(_ incoming: [FeedbackAttachment], to existing: [FeedbackAttachment]) -> (accepted: [FeedbackAttachment], notice: String?) {
        var accepted: [FeedbackAttachment] = []
        var notices: [String] = []
        var total = existing.reduce(0) { $0 + $1.data.count }
        for image in incoming {
            let name = image.fileName ?? "The image"
            if existing.count + accepted.count >= maximumCount { notices.append("Feedback takes up to \(maximumCount) images."); break }
            if image.data.count > maximumBytes { notices.append("\(name) is larger than 8 MB."); continue }
            if total + image.data.count > maximumTotalBytes { notices.append("Images can add up to at most 16 MB."); continue }
            total += image.data.count
            accepted.append(image)
        }
        return (accepted, notices.isEmpty ? nil : notices.joined(separator: " "))
    }
}

// MARK: - Harness requests

struct FeedbackLoadedDraft: Equatable {
    let id: String
    let title: String
    let area: String?
}

struct FeedbackComposition {
    var text: String
    var images: [FeedbackAttachment] = []
    var taxonomy = FeedbackTaxonomySelection()
    var draft: FeedbackLoadedDraft?
    var traceChoice: FeedbackTraceChoice?
}

enum FeedbackSubmitResult: Equatable {
    case sent
    /// Nothing was sent; the form stays open to try again.
    case failed(String)
    /// The report may have gone out, so the form stays open with this message and must not send again.
    case settled(String)
}

enum FeedbackOutcome: Equatable {
    case submitted, submittedCleanupFailed, localOnly, outcomeUnknown, other

    init(wire: String?) {
        switch wire {
        case nil, "submitted": self = .submitted
        case "submitted_cleanup_failed": self = .submittedCleanupFailed
        case "local_only": self = .localOnly
        case "outcome_unknown": self = .outcomeUnknown
        default: self = .other
        }
    }
}

/// The raw `_x.ai/feedback` reply (camelCase).
struct FeedbackResponse: Equatable {
    var success: Bool
    var outcome: FeedbackOutcome
    var traceUploadToken: String?

    init(success: Bool, outcome: FeedbackOutcome, traceUploadToken: String?) {
        self.success = success; self.outcome = outcome; self.traceUploadToken = traceUploadToken
    }

    init(_ response: [String: Any]) {
        let value = response["result"] as? [String: Any] ?? response
        success = value["success"] as? Bool ?? false
        outcome = FeedbackOutcome(wire: value["outcome"] as? String)
        traceUploadToken = AccountJSON.string(value["traceUploadToken"])
    }

    /// Accepted by the backend (the only replies that may carry a trace grant).
    var posted: Bool { outcome == .submitted || outcome == .submittedCleanupFailed }
}

/// Feedback bodies are snake_case; the draft form carries its fields in `edited_body` only.
enum FeedbackRequests {
    static let sendTimeout: TimeInterval = 30

    static var clientVersion: String { DesktopVersion.current }

    static func structuredFeedback(source: String, taxonomy: FeedbackTaxonomySelection) -> [String: Any] {
        var envelope: [String: Any] = ["schema_version": 1, "source": source]
        if let type = taxonomy.type { envelope["type"] = type.rawValue }
        if let task = taxonomy.taskCategory { envelope["task_category"] = task.rawValue }
        if let failure = taxonomy.failureMode { envelope["failure_mode"] = failure.rawValue }
        return ["structured_feedback": envelope]
    }

    static func write(sessionID: String, text: String, images: [FeedbackAttachment], taxonomy: FeedbackTaxonomySelection,
                      requestTraceUploadToken: Bool, clientVersion: String) -> [String: Any] {
        [
            "session_id": sessionID,
            "client_type": "desktop",
            "feedback_text": text,
            "images": images.map(\.wire),
            "feedback_categories": [String](),
            "client_version": clientVersion,
            "metadata": structuredFeedback(source: "write", taxonomy: taxonomy),
            "request_trace_upload_token": requestTraceUploadToken,
        ]
    }

    static func draft(sessionID: String, draftID: String, title: String, details: String, area: String?, type: FeedbackKind,
                      taxonomy: FeedbackTaxonomySelection, images: [FeedbackAttachment], requestTraceUploadToken: Bool,
                      clientVersion: String) -> [String: Any] {
        var body = draftFields(title: title, details: details, area: area, type: type, taxonomy: taxonomy)
        body["images"] = images.map(\.wire)
        body["client_version"] = clientVersion
        return ["session_id": sessionID, "draft_id": draftID, "request_trace_upload_token": requestTraceUploadToken, "edited_body": body]
    }

    static func update(sessionID: String, draftID: String, title: String, details: String, area: String?, type: FeedbackKind,
                       taxonomy: FeedbackTaxonomySelection) -> [String: Any] {
        var params = draftFields(title: title, details: details, area: area, type: type, taxonomy: taxonomy)
        params["session_id"] = sessionID
        params["draft_id"] = draftID
        return params
    }

    private static func draftFields(title: String, details: String, area: String?, type: FeedbackKind, taxonomy: FeedbackTaxonomySelection) -> [String: Any] {
        var fields: [String: Any] = ["title": title, "details": details, "type": type.rawValue]
        if let area, !area.trimmingCharacters(in: .whitespaces).isEmpty { fields["area"] = area }
        if let task = taxonomy.taskCategory { fields["task_category"] = task.rawValue }
        if let failure = taxonomy.failureMode { fields["failure_mode"] = failure.rawValue }
        return fields
    }
}

/// One row of `_x.ai/feedback/drafts/list` (snake_case).
struct FeedbackDraftRecord: Identifiable, Equatable {
    let id: String
    var title: String
    var details: String
    var area: String?
    var type: FeedbackKind?
    var taskCategory: FeedbackTaskCategory?
    var failureMode: FeedbackFailureMode?
    var createdAt: Date?

    init(id: String, title: String, details: String, area: String? = nil, type: FeedbackKind? = nil,
         taskCategory: FeedbackTaskCategory? = nil, failureMode: FeedbackFailureMode? = nil, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.details = details; self.area = area; self.type = type
        self.taskCategory = taskCategory; self.failureMode = failureMode; self.createdAt = createdAt
    }

    init?(_ value: [String: Any]) {
        guard let id = AccountJSON.string(value["id"]) else { return nil }
        self.id = id
        title = value["title"] as? String ?? ""
        details = value["details"] as? String ?? value["text"] as? String ?? ""
        area = AccountJSON.string(value["area"])
        type = (value["type"] as? String).flatMap(FeedbackKind.init(rawValue:))
        taskCategory = (value["task_category"] as? String).flatMap(FeedbackTaskCategory.init(rawValue:))
        failureMode = (value["failure_mode"] as? String).flatMap(FeedbackFailureMode.init(wire:))
        createdAt = AccountJSON.int(value["created_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// `Bug · Code edit · Overeager`, with the terminal's defaults for a draft saved before it was classified.
    var classification: String {
        [type?.label ?? "Unclassified", taskCategory?.label ?? "Other", failureMode?.label].compactMap { $0 }.joined(separator: " · ")
    }

    var preview: String {
        details.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? title
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || "\(title) \(details) \(classification)".localizedCaseInsensitiveContains(query)
    }
}

enum FeedbackDraftListState: Equatable {
    case idle, loading
    case loaded([FeedbackDraftRecord])
    case failed(String)
    case unavailable(String)
}

// MARK: - Local drafts for unsent reports

/// Appends a draft to a session's `feedback_drafts.json` the way the terminal does when an
/// inline report cannot be sent: under the store's lock file, written atomically, and never
/// rewriting a document it cannot read.
enum FeedbackPredraftStore {
    static let fileName = "feedback_drafts.json"
    static let lockName = ".feedback_drafts.lock"
    private static let maximumDocumentBytes = 8 * 1024 * 1024
    private static let maximumDrafts = 1_000
    private static let maximumTextBytes = 64 * 1024

    @discardableResult
    static func append(sessionDirectory: URL, title: String, details: String, now: Date = Date()) throws -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopError.message("the draft is empty")
        }
        guard title.utf8.count <= maximumTextBytes, details.utf8.count <= maximumTextBytes else { throw DesktopError.message("the draft is too large") }
        var status = stat()
        guard lstat(sessionDirectory.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            throw DesktopError.message("the session directory is missing")
        }
        let lock = open(sessionDirectory.appendingPathComponent(lockName).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw DesktopError.message("the drafts lock could not be opened") }
        defer { close(lock) }
        var locked = false
        for attempt in 1...5 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            guard errno == EWOULDBLOCK else { break }
            if attempt < 5 { usleep(10_000) }
        }
        guard locked else { throw DesktopError.message("the drafts are busy") }
        defer { flock(lock, LOCK_UN) }

        let file = sessionDirectory.appendingPathComponent(fileName)
        var document: [String: Any] = ["schema_version": 1, "drafts": [Any]()]
        if lstat(file.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size <= maximumDocumentBytes else {
                throw DesktopError.message("the drafts file is not a regular file")
            }
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  (parsed["schema_version"] as? NSNumber)?.intValue == 1, parsed["drafts"] is [Any] else {
                throw DesktopError.message("the drafts file could not be read")
            }
            document = parsed
        }
        var drafts = document["drafts"] as? [Any] ?? []
        guard drafts.count < maximumDrafts else { throw DesktopError.message("there are too many drafts") }
        let id = uuidV7(now: now)
        drafts.append(["id": id, "title": title, "details": details, "created_at": Int64(now.timeIntervalSince1970), "revision": 1] as [String: Any])
        document["drafts"] = drafts
        var bytes = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        guard bytes.count <= maximumDocumentBytes else { throw DesktopError.message("the drafts file is too large") }
        let temporary = sessionDirectory.appendingPathComponent(".feedback_drafts.tmp-\(UUID().uuidString.prefix(8))")
        let handle = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw DesktopError.message("a temporary file could not be created") }
        let written = bytes.withUnsafeBytes { buffer in write(handle, buffer.baseAddress, buffer.count) }
        let synced = fsync(handle) == 0
        close(handle)
        guard written == bytes.count, synced, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw DesktopError.message("the drafts file could not be written")
        }
        let directory = open(sessionDirectory.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
        return id
    }

    /// Time-ordered ids, as the harness's store creates them.
    static func uuidV7(now: Date) -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for index in 0..<6 { bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }
}

// MARK: - Sheet

enum FeedbackSheetTab: String, CaseIterable, Identifiable {
    case write = "Write", drafts = "Drafts"
    var id: String { rawValue }
}

/// `/feedback`: a Write tab for a new report and a Drafts tab for reports saved in this task.
struct FeedbackSheet: View {
    let initialText: String
    var loadsOnAppear = true
    @EnvironmentObject var account: AccountFeatureModel
    @State private var tab: FeedbackSheetTab
    @State private var text: String
    @State private var taxonomy: FeedbackTaxonomySelection
    @State private var images: [FeedbackAttachment]
    @State private var draft: FeedbackLoadedDraft?
    @State private var baseline = FeedbackSheetBaseline()
    @State private var traceStep: Bool
    @State private var traceChoice: FeedbackTraceChoice = .feedbackOnly
    @State private var error: String?
    @State private var sending = false
    /// Set once a draft send may have reached the backend, so it can never go out twice.
    @State private var settled = false
    @State private var dropTargeted = false
    @State private var draftQuery = ""
    @State private var pendingDraftOpen: FeedbackDraftRecord?
    @State private var pendingDraftDelete: FeedbackDraftRecord?
    @State private var busyDraftID: String?
    @FocusState private var editorFocused: Bool

    init(initialText: String, loadsOnAppear: Bool = true, tab: FeedbackSheetTab = .write, taxonomy: FeedbackTaxonomySelection = .init(),
         images: [FeedbackAttachment] = [], traceStep: Bool = false, error: String? = nil) {
        self.initialText = initialText
        self.loadsOnAppear = loadsOnAppear
        _tab = State(initialValue: tab)
        _text = State(initialValue: initialText)
        _taxonomy = State(initialValue: taxonomy)
        _images = State(initialValue: images)
        _traceStep = State(initialValue: traceStep)
        _error = State(initialValue: error)
    }

    var body: some View {
        DesktopPanel(title: "Feedback", subtitle: "Tell the Crok Build team what worked, what didn't, and what's missing.",
                     width: 660, height: 640, onClose: close) {
            VStack(spacing: 0) {
                if !traceStep {
                    Picker("Section", selection: $tab) { ForEach(FeedbackSheetTab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(width: 240)
                        .padding(.top, 18).padding(.bottom, 4)
                }
                Group {
                    if traceStep { traceContent }
                    else if tab == .write { writeContent }
                    else { draftsContent }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } footer: {
            footer
        }
        .onAppear(perform: appear)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .alert(FeedbackCopy.discardForDraft, isPresented: Binding(get: { pendingDraftOpen != nil }, set: { if !$0 { pendingDraftOpen = nil } })) {
            Button("Cancel", role: .cancel) { pendingDraftOpen = nil }
            Button("Discard and Open", role: .destructive) {
                if let row = pendingDraftOpen { open(row, confirmed: true) }
                pendingDraftOpen = nil
            }
        }
        .alert(pendingDraftDelete?.id == draft?.id ? FeedbackCopy.deleteRecoveryCopy : FeedbackCopy.deleteDraft,
               isPresented: Binding(get: { pendingDraftDelete != nil }, set: { if !$0 { pendingDraftDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDraftDelete = nil }
            Button("Delete", role: .destructive) {
                if let row = pendingDraftDelete { delete(row) }
                pendingDraftDelete = nil
            }
        }
    }

    // MARK: Write

    private var writeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let draft {
                    Label("Editing draft · \(draft.title)", systemImage: "doc.text")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                editor
                if let error { FeedbackErrorLine(text: error) }
                taxonomyPickers
                attachments
            }
            .padding(24)
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 9).padding(.vertical, 10)
                .accessibilityLabel("Feedback")
            if text.isEmpty {
                Text("Tell us what happened").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14).padding(.vertical, 10).allowsHitTesting(false)
            }
        }
        .frame(height: 170)
        .modifier(InputSurface(focused: editorFocused))
    }

    private var taxonomyPickers: some View {
        HStack(spacing: 20) {
            Picker("Type", selection: $taxonomy.type) {
                Text(draft == nil ? "None" : "Choose…").tag(FeedbackKind?.none)
                Divider()
                ForEach(FeedbackKind.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .frame(maxWidth: 200, alignment: .leading)
            Picker("Task", selection: $taxonomy.taskCategory) {
                Text("None").tag(FeedbackTaskCategory?.none)
                Divider()
                ForEach(FeedbackTaskCategory.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .frame(maxWidth: 170, alignment: .leading)
            Picker("Failure", selection: $taxonomy.failureMode) {
                Text("None").tag(FeedbackFailureMode?.none)
                ForEach(FeedbackFailureMode.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.modes) { Text($0.label).tag(Optional($0)) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .help(taxonomy.failureMode?.meaning ?? "What went wrong with the model's behavior, if anything")
        }
        .pickerStyle(.menu)
        .font(.system(size: 13))
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(images) { image in FeedbackThumbnail(attachment: image) { images.removeAll { $0.id == image.id } } }
                if images.count < FeedbackImageRules.maximumCount {
                    Button(action: chooseImages) {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .background(Theme.input.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(Image(systemName: "photo.badge.plus").font(.system(size: 18)).foregroundStyle(Theme.muted))
                            .frame(width: 64, height: 64).contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Paste Image", action: pasteImage).disabled(!Self.pasteboardHasImage) }
                    .help("Attach screenshots").accessibilityLabel("Attach screenshots")
                }
            }
            HStack(spacing: 4) {
                Text("Optional: up to 4 screenshots, 8 MB each. Drop them here, or")
                Button("paste from the clipboard", action: pasteImage).buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityHint("Attaches the image on the clipboard")
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Trace step

    private var traceContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(FeedbackCopy.tracePrompt(for: taxonomy.type)).font(.system(size: 17, weight: .semibold))
            Text(FeedbackCopy.traceDisclosure).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(FeedbackTraceChoice.allCases) { choice in
                    Button { traceChoice = choice } label: {
                        HStack(spacing: 12) {
                            Image(systemName: traceChoice == choice ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 16)).foregroundStyle(traceChoice == choice ? Theme.accent : Theme.muted)
                            Text(choice.label).font(.system(size: 14))
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(traceChoice == choice ? Theme.hover.opacity(0.7) : Theme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(traceChoice == choice ? Theme.accent.opacity(0.55) : Theme.line.opacity(0.3), lineWidth: traceChoice == choice ? 1 : 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(traceChoice == choice ? .isSelected : [])
                }
            }
            .padding(.top, 4)
            if let error { FeedbackErrorLine(text: error) }
        }
        .padding(24)
    }

    // MARK: Drafts

    private var draftsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(text: $draftQuery, placeholder: "Search drafts", onEscape: close)
                .frame(height: 36).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error, tab == .drafts { FeedbackErrorLine(text: error) }
                    switch account.feedbackDrafts {
                    case .idle, .loading: UsageStatusLine(text: "Loading drafts…", loading: true)
                    case .failed(let message): UsageStatusLine(text: message, isError: true)
                    case .unavailable(let reason): UsageEmptyState(symbol: "tray", title: "No task selected", detail: reason)
                    case .loaded(let rows):
                        let visible = rows.filter { $0.matches(draftQuery) }
                        if visible.isEmpty {
                            UsageEmptyState(symbol: rows.isEmpty ? "tray" : "magnifyingglass", title: rows.isEmpty ? "No drafts." : "No matching drafts.",
                                            detail: rows.isEmpty ? "Reports that could not be sent, and drafts Crok prepares for you, appear here." : "Try a different search.")
                        }
                        ForEach(visible) { draftRow($0) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
    }

    private func draftRow(_ row: FeedbackDraftRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.classification).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
                Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(row.preview).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                if let created = row.createdAt {
                    Text(created, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 4) {
                    if busyDraftID == row.id { ProgressView().controlSize(.small) }
                    Button("Open") { open(row, confirmed: false) }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                    IconButton(icon: "trash", help: "Delete draft", size: 28) { pendingDraftDelete = row }
                }
                .disabled(busyDraftID != nil || sending)
            }
        }
        .usageCard(padding: 16)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(row, confirmed: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(row.classification)")
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if traceStep {
            Button("Back") { traceStep = false; error = nil }.disabled(sending)
            Spacer(minLength: 0)
            if sending { ProgressView().controlSize(.small) }
            Button("Cancel", action: close)
            Button(sending ? "Sending…" : "Send", action: submit).keyboardShortcut(.defaultAction).disabled(sending)
        } else if tab == .write {
            Text("⌘↩ to send · Goes to the Crok Build team with this task's session ID.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 0)
            if sending { ProgressView().controlSize(.small) }
            Button("Cancel", action: close)
            Button(sending ? (draft == nil ? "Sending…" : "Sending draft…") : "Send", action: submit)
                .keyboardShortcut(.return, modifiers: .command).disabled(sending || settled)
        } else {
            Button("Refresh") { Task { await account.loadFeedbackDrafts() } }.disabled(account.feedbackDrafts == .loading)
            Spacer(minLength: 0)
            Button("Close", action: close).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func close() { account.store?.sheet = nil }

    private func appear() {
        baseline = FeedbackSheetBaseline(text: text, taxonomy: taxonomy, imageIDs: images.map(\.id))
        if tab == .write && !traceStep { editorFocused = true }
        guard loadsOnAppear else { return }
        let bare = initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        Task {
            await account.loadFeedbackDrafts()
            // A bare open shows saved drafts first when there are any, as in the terminal.
            if bare, text.isEmpty, case .loaded(let rows) = account.feedbackDrafts, !rows.isEmpty { tab = .drafts }
        }
    }

    private var hasUnsavedWrite: Bool {
        FeedbackSheetBaseline(text: text, taxonomy: taxonomy, imageIDs: images.map(\.id)) != baseline
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private func submit() {
        guard !sending, !settled else { return }
        error = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty { error = FeedbackCopy.emptySubmit; traceStep = false; return }
        if draft != nil && taxonomy.type == nil { error = FeedbackCopy.draftNeedsType; traceStep = false; return }
        if !traceStep && account.feedbackTraceOffered {
            traceChoice = .feedbackOnly
            traceStep = true
            return
        }
        let composition = FeedbackComposition(text: text, images: images, taxonomy: taxonomy, draft: draft, traceChoice: traceStep ? traceChoice : nil)
        sending = true
        Task {
            let result = await account.submitFeedback(composition)
            sending = false
            switch result {
            case .sent: close()
            case .failed(let message), .settled(let message):
                if case .settled = result { settled = true }
                traceStep = false
                tab = .write
                error = message
            }
        }
    }

    private func open(_ row: FeedbackDraftRecord, confirmed: Bool) {
        if !confirmed && hasUnsavedWrite { pendingDraftOpen = row; return }
        busyDraftID = row.id
        error = nil
        Task {
            defer { busyDraftID = nil }
            do {
                let loaded = try await account.loadFeedbackDraft(id: row.id)
                text = loaded.details
                taxonomy = FeedbackTaxonomySelection(type: loaded.type, taskCategory: loaded.taskCategory, failureMode: loaded.failureMode)
                images = []
                draft = FeedbackLoadedDraft(id: loaded.id, title: loaded.title, area: loaded.area)
                baseline = FeedbackSheetBaseline(text: text, taxonomy: taxonomy, imageIDs: [])
                settled = false
                traceStep = false
                tab = .write
                editorFocused = true
            } catch {
                self.error = AccountErrorText.describe(error)
                await account.loadFeedbackDrafts()
            }
        }
    }

    private func delete(_ row: FeedbackDraftRecord) {
        busyDraftID = row.id
        Task {
            defer { busyDraftID = nil }
            do {
                try await account.deleteFeedbackDraft(id: row.id)
                // The Write text stays; only the link to the deleted draft goes.
                if draft?.id == row.id { draft = nil }
                error = nil
            } catch {
                self.error = AccountErrorText.describe(error)
            }
        }
    }

    private func add(_ incoming: [FeedbackAttachment], rejected: Int = 0) {
        let (accepted, notice) = FeedbackImageRules.admit(incoming, to: images)
        images += accepted
        let unreadable = rejected > 0 ? "Dropped \(rejected) invalid image(s)." : nil
        let message = [unreadable, notice].compactMap { $0 }.joined(separator: " ")
        error = message.isEmpty ? nil : message
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose screenshots to send with your feedback."
        guard panel.runModal() == .OK else { return }
        loadFiles(panel.urls)
    }

    private func loadFiles(_ urls: [URL]) {
        // Only local files: a dropped web link must never turn into a download.
        let files = urls.filter(\.isFileURL)
        Task {
            let attachments = await Task.detached(priority: .userInitiated) { () -> [FeedbackAttachment] in
                files.compactMap { url in
                    // Anything far beyond the limit is not worth reading or converting.
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= FeedbackImageRules.maximumBytes * 4,
                          let data = try? Data(contentsOf: url) else { return nil }
                    return FeedbackAttachment.make(data: data, fileName: url.lastPathComponent)
                }
            }.value
            add(attachments, rejected: urls.count - attachments.count)
        }
    }

    private static var pasteboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
            || NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])
    }

    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                               .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
            loadFiles(urls)
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let attachment = FeedbackAttachment.make(data: data, fileName: "Pasted image.png") {
                add([attachment]); return
            }
        }
        error = "The clipboard does not contain an image."
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { loadFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        if let attachment = FeedbackAttachment.make(data: data, fileName: provider.suggestedName) { add([attachment]) }
                        else { add([], rejected: 1) }
                    }
                }
            }
        }
        return accepted
    }
}

/// What the Write tab held when it was opened or a draft was loaded, to tell whether opening
/// another draft would discard edits.
struct FeedbackSheetBaseline: Equatable {
    var text = ""
    var taxonomy = FeedbackTaxonomySelection()
    var imageIDs: [UUID] = []
}

struct FeedbackThumbnail: View {
    let attachment: FeedbackAttachment
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line.opacity(0.5), lineWidth: 0.5))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain).offset(x: 6, y: -6).opacity(hovered ? 1 : 0.85)
            .help("Remove image").accessibilityLabel("Remove \(attachment.fileName ?? "image")")
        }
        .onHover { hovered = $0 }
        .help(attachment.fileName ?? "Image")
    }
}

struct FeedbackErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(UsagePalette.error)
            Text(text).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsagePalette.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}
