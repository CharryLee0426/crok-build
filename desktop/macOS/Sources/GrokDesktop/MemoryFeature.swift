import AppKit
import Foundation

/// One file from `memory/list` (snake_case `MemoryFileInfo`).
struct MemoryFileItem: Identifiable, Equatable {
    /// Largest note `memory/forget` will hash and delete.
    static let maxForgetBytes = 256 * 1024

    let path: String
    /// `global`, `workspace`, or `session`.
    let source: String
    let sizeBytes: Int
    let modified: Date?
    /// A store-generated index (the v2 `MEMORY.md`) rather than a note.
    let generated: Bool
    let title: String?
    var id: String { path }

    init?(_ value: [String: Any]) {
        guard let path = value["path"] as? String else { return nil }
        self.path = path
        source = value["source"] as? String ?? "session"
        sizeBytes = (value["size_bytes"] as? NSNumber)?.intValue ?? 0
        modified = (value["modified_epoch_secs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        generated = value["generated"] as? Bool ?? false
        title = value["title"] as? String
    }

    init(path: String, source: String, sizeBytes: Int, modified: Date? = nil, generated: Bool = false, title: String? = nil) {
        self.path = path; self.source = source; self.sizeBytes = sizeBytes; self.modified = modified; self.generated = generated; self.title = title
    }

    /// The shell's title, else a readable v2 observation key, else the file name.
    var label: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return Self.observationLabel(name) ?? name
    }

    /// `<session>__t000038-000040__n001.md` → `observation, turns 38–40 (#2)`.
    static func observationLabel(_ fileName: String) -> String? {
        guard fileName.hasSuffix(".md") else { return nil }
        let parts = fileName.dropLast(3).components(separatedBy: "__")
        guard parts.count == 3, parts[1].hasPrefix("t"), parts[2].hasPrefix("n"), let ordinal = Int(parts[2].dropFirst()) else { return nil }
        let range = parts[1].dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let from = UInt64(range[0]), let through = UInt64(range[1]) else { return nil }
        let turns = from == through ? "turn \(from)" : "turns \(from)\u{2013}\(through)"
        return "observation, \(turns) (#\(ordinal + 1))"
    }

    /// Mirrors the store's rule: v2 topics and inbox observations, or legacy session logs.
    var isDeletable: Bool {
        guard !generated, sizeBytes <= Self.maxForgetBytes else { return false }
        switch source {
        case "session": return true
        case "workspace", "global":
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return parent.hasSuffix("/topics") || parent.hasSuffix("/observations/_inbox")
        default: return false
        }
    }

    /// How the delete confirmation names the scope.
    var scopeLabel: String { source == "session" ? "session logs" : "\(source) memory" }

    /// "812 B", "4.2 KB", "1.1 MB".
    var sizeText: String {
        if sizeBytes < 1000 { return "\(sizeBytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(sizeBytes) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// Relative age in at most three columns, like the terminal list.
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "\u{2014}" }
        let delta = max(0, Int(now.timeIntervalSince(date)))
        if delta < 60 { return "<1m" }
        if delta < 3600 { return "\(delta / 60)m" }
        if delta < 86_400 { return "\(delta / 3600)h" }
        let days = delta / 86_400
        if days < 100 { return "\(days)d" }
        if days < 365 { return "\(days / 7)w" }
        return "\(days / 365)y"
    }
}

/// `memory/list` and the `memory_files` notification (snake_case `MemoryListing`).
struct MemoryListing: Equatable {
    var files: [MemoryFileItem] = []
    var enabled = true
    var disabledReason: String?
    var captureEnabled = true
    var dreamEnabled = true

    init(files: [MemoryFileItem] = [], enabled: Bool = true, disabledReason: String? = nil, captureEnabled: Bool = true, dreamEnabled: Bool = true) {
        self.files = files; self.enabled = enabled; self.disabledReason = disabledReason
        self.captureEnabled = captureEnabled; self.dreamEnabled = dreamEnabled
    }

    init(_ value: [String: Any]) {
        files = (value["files"] as? [[String: Any]] ?? []).compactMap(MemoryFileItem.init)
        enabled = value["enabled"] as? Bool ?? true
        disabledReason = value["disabled_reason"] as? String
        captureEnabled = value["capture_enabled"] as? Bool ?? true
        dreamEnabled = value["dream_enabled"] as? Bool ?? true
    }

    /// The switch can turn memory back on only for these reasons; unknown reasons fail closed.
    var canEnable: Bool { !enabled && (disabledReason == nil || ["session_toggle", "config_opt_out"].contains(disabledReason!)) }
    var hasNotes: Bool { files.contains { !$0.generated } }

    /// Global, Workspace, then Sessions (newest session log first).
    func sections(matching filter: String = "", contents: [String: String] = [:]) -> [(title: String, files: [MemoryFileItem])] {
        let terms = filter.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches: (MemoryFileItem) -> Bool = { file in
            terms.allSatisfy { term in
                file.label.lowercased().contains(term) || file.source.lowercased().contains(term) || contents[file.path]?.contains(term) == true
            }
        }
        let scoped: (String) -> [MemoryFileItem] = { source in self.files.filter { $0.source == source && matches($0) } }
        let sessions = files.filter { !["global", "workspace"].contains($0.source) && matches($0) }.reversed()
        return [("Global", scoped("global")), ("Workspace", scoped("workspace")), ("Sessions", Array(sessions))].filter { !$0.1.isEmpty }
    }
}

/// Why memory is off, as the terminal explains it, with desktop wording for the controls.
enum MemoryDisabledExplanation {
    static func text(_ reason: String?) -> (title: String, detail: String) {
        switch reason {
        case nil, "session_toggle"?:
            return ("Memory is off for this session.", "Turn it back on with the Memory switch. While off, Crok isn't reading or saving notes; anything already remembered is kept on disk. Memory carries conventions, decisions, and project facts between sessions so you don't have to repeat yourself.")
        case "config_opt_out"?:
            return ("Memory is off ([memory] enabled = false in config.toml).", "Use the Memory switch to turn it on for this session. The switch lasts for this session only; new sessions follow config.toml. Set enabled = true there (or remove the line) to keep memory on. Anything already remembered is kept on disk.")
        case "process_disabled"?:
            return ("Memory is off for this process.", "Start a new session without --no-memory or CROK_MEMORY=0 to use it. Memory was turned off when Crok Build started, so it can't be turned on here. Anything already remembered is kept on disk.")
        case "rollout_restricted"?:
            return ("Memory is unavailable in this session.", "Start a new session to pick up your current settings. This session's memory settings were pinned when it started, and they disable memory, so it can't be turned on here.")
        case "not_configured"?:
            return ("Memory isn't configured.", "No memory storage is set up for this session, so there is nothing to browse or turn on.")
        default:
            return ("Memory is off for this session.", "This session reports a reason this version of Crok Desktop doesn't recognize, so it can't be turned on here.")
        }
    }

    /// Only advertises what the session reports as available.
    static func emptyState(captureEnabled: Bool, dreamEnabled: Bool) -> [String] {
        var lines: [String] = []
        if captureEnabled { lines.append("Keep working. Notes are saved automatically after each completed turn.") }
        lines.append("/remember <note> saves something specific right now.")
        if dreamEnabled { lines.append("/dream organizes saved notes into topics.") }
        return lines
    }
}

/// What a bounded read of a note produced.
enum MemoryNoteRead: Equatable {
    case text(String, hash: String)
    case tooLarge
    case unreadable

    static let previewLimit = 1_048_576

    /// Reads at most `limit` bytes (the file may grow between the size check and the read) and
    /// hashes exactly the bytes that will be shown, which is what `memory/forget` verifies.
    static func read(_ path: String, limit: Int = previewLimit) -> MemoryNoteRead {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else { return .unreadable }
        if data.count > limit { return .tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .text(text, hash: GrokBlake3.hex(data))
    }
}

/// `/flush` and `/dream` outcomes, worded like the shell's shared summaries.
enum MemoryMaintenanceSummary {
    static func flush(_ value: [String: Any]) -> (text: String, succeeded: Bool) {
        let disposition = value["disposition"] as? String ?? ((value["flushed"] as? Bool == true) ? "flushed" : "failed")
        let turn = (value["through_turn"] as? NSNumber)?.intValue
        switch disposition {
        case "flushed": return (turn.map { "Memory flushed through turn \($0)." } ?? "Memory flushed.", true)
        case "retry_required": return ("Memory flush did not finish; capture will retry in the background.", false)
        case "timed_out": return ("Memory flush timed out; capture continues in the background.", false)
        case "disabled": return ("Memory is turned off for this session.", false)
        case "busy": return ("Another memory flush is already running.", false)
        default: return ("Memory flush failed.", false)
        }
    }

    static func dream(_ value: [String: Any]) -> (text: String, succeeded: Bool) {
        let observations = (value["observation_count"] as? NSNumber)?.intValue ?? 0
        let topics = (value["topics_affected"] as? NSNumber)?.intValue ?? 0
        switch value["disposition"] as? String ?? "failed" {
        case "completed" where topics > 0: return ("Dream merged \(plural(observations, "observation")) into \(plural(topics, "topic")).", true)
        case "completed": return ("Dream completed.", true)
        case "no_work": return ("Nothing to consolidate.", true)
        case "busy": return ("Dream is already running; try again when it finishes.", false)
        case "recovered" where topics > 0: return ("Dream finished an interrupted earlier run, updating \(plural(topics, "topic")).", true)
        case "recovered": return ("Dream finished an interrupted earlier run.", true)
        case "retry_required": return ("Dream did not finish; it will retry automatically.", false)
        case "shadow": return ("Dream ran in shadow mode; nothing was written.", true)
        case "cancelled": return ("Dream cancelled.", false)
        case "disabled": return ("Dream is turned off for this session.", false)
        default: return ("Dream failed.", false)
        }
    }

    private static func plural(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }
}

struct MemoryStatusLine: Equatable {
    var text: String
    var isError = false
}

/// State behind the Memory panel, `/flush`, and `/dream`.
@MainActor
final class MemoryPanelModel: ObservableObject {
    weak var store: AppStore?
    @Published private(set) var listing: MemoryListing?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var selection: String?
    @Published private(set) var preview: MemoryNoteRead?
    @Published var status: MemoryStatusLine?
    /// A running maintenance or delete request, e.g. "Flushing memory…".
    @Published private(set) var busy: String?
    @Published private(set) var toggling = false
    /// Lower-cased note contents for the filter, read lazily off the main thread.
    @Published private(set) var searchContents: [String: String] = [:]
    private(set) var conversationID: UUID?
    /// The memory store each task uses, learned from where its listed files live.
    private(set) var modes: [UUID: MemoryNoteMode] = [:]
    private var sessionModes: Set<UUID> = []
    private var requestID = UUID()
    private var previewID = UUID()
    private var searchLoading = false

    init(store: AppStore) { self.store = store }

    var selectedFile: MemoryFileItem? { listing?.files.first { $0.path == selection } }

    // MARK: Loading

    func load() async {
        guard let store else { return }
        guard store.project != nil else { error = "Open a project first."; return }
        let request = UUID(); requestID = request
        loading = true; error = nil
        defer { if requestID == request { loading = false } }
        do {
            let (client, id, session) = try await store.featureSession()
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/memory/list", params: ["sessionId": session], timeout: 60))
            guard requestID == request, store.state.selectedConversationID == id else { return }
            apply(MemoryListing(result), conversationID: id)
        } catch {
            if requestID == request { self.error = "Couldn't load memory: \(ExtensionErrorText.describe(error))" }
        }
    }

    /// A pushed `memory_files` listing; only the task on screen replaces the panel's contents.
    func receive(_ listing: MemoryListing, conversationID: UUID) {
        learnMode(listing, conversationID: conversationID)
        guard self.conversationID == conversationID, store?.featurePanel == .memory else { return }
        apply(listing, conversationID: conversationID)
    }

    func apply(_ listing: MemoryListing, conversationID: UUID) {
        let changedTask = self.conversationID != conversationID
        let previous = self.listing?.files.first { $0.path == selection }
        let previousFiles = self.listing?.files
        self.conversationID = conversationID
        self.listing = listing
        learnMode(listing, conversationID: conversationID)
        if changedTask || previousFiles != listing.files { searchContents = [:] }
        if let selection, let current = listing.files.first(where: { $0.path == selection }) {
            // Re-read when the note changed on disk, so a delete verifies what is there now.
            if changedTask || previous != current || preview == nil { select(selection, clearStatus: false) }
        } else {
            select(listing.sections().first?.files.first?.path, clearStatus: false)
        }
    }

    func mode(for conversationID: UUID) -> MemoryNoteMode? { modes[conversationID] }

    /// The session's own `_meta["x.ai/memoryMode"]`, when the store passes it on; it outranks listings.
    func recordSessionMode(_ raw: String, conversationID: UUID) {
        if let mode = MemoryNoteMode(rawValue: raw) { modes[conversationID] = mode; sessionModes.insert(conversationID) }
    }

    private func learnMode(_ listing: MemoryListing, conversationID: UUID) {
        guard !sessionModes.contains(conversationID) else { return }
        if let mode = MemoryNoteStore.mode(forListedPaths: listing.files.map(\.path)) { modes[conversationID] = mode }
    }

    /// Up and down arrows in the filter field move through the visible notes.
    func moveSelection(by offset: Int, filter: String) {
        guard let listing else { return }
        let visible = listing.sections(matching: filter, contents: searchContents).flatMap(\.files)
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.path == selection } ?? (offset > 0 ? -1 : visible.count)
        let next = min(max(current + offset, 0), visible.count - 1)
        if visible[next].path != selection { select(visible[next].path) }
    }

    // MARK: Selection and preview

    func select(_ path: String?, clearStatus: Bool = true) {
        selection = path
        if clearStatus { status = nil }
        let request = UUID(); previewID = request
        guard let path else { preview = nil; return }
        preview = nil
        Task.detached(priority: .userInitiated) {
            let read = MemoryNoteRead.read(path)
            await MainActor.run { [weak self] in
                guard let self, self.previewID == request else { return }
                self.preview = read
            }
        }
    }

    /// Reads note contents once a filter is typed, capped like the terminal (256 KiB per note, 8 MiB total).
    func loadSearchContents() {
        guard !searchLoading, searchContents.isEmpty, let files = listing?.files, !files.isEmpty else { return }
        searchLoading = true
        let paths = files.map(\.path)
        Task.detached(priority: .utility) {
            var budget = 8 * 1_048_576
            var contents: [String: String] = [:]
            for path in paths where budget > 0 {
                if case .text(let text, _) = MemoryNoteRead.read(path, limit: min(262_144, budget)) {
                    budget -= text.utf8.count
                    contents[path] = text.lowercased()
                }
            }
            let loaded = contents
            await MainActor.run { [weak self] in
                self?.searchContents = loaded
                self?.searchLoading = false
            }
        }
    }

    // MARK: Actions

    func toggle() {
        guard let store, let listing, listing.enabled || listing.canEnable, !toggling else { return }
        let enabling = !listing.enabled
        toggling = true; status = nil
        Task {
            defer { toggling = false }
            do {
                let (client, id, session) = try await store.featureSession()
                let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/memory/toggle", params: ["sessionId": session, "enabled": enabling]))
                guard store.state.selectedConversationID == id else { return }
                let enabled = result["enabled"] as? Bool ?? enabling
                status = MemoryStatusLine(text: result["message"] as? String ?? "", isError: enabled != enabling)
                if let updated = result["listing"] as? [String: Any] { apply(MemoryListing(updated), conversationID: id) }
                else {
                    var copy = self.listing ?? listing
                    copy.enabled = enabled; copy.disabledReason = result["disabled_reason"] as? String
                    self.listing = copy
                    await load()
                }
            } catch {
                status = MemoryStatusLine(text: "Couldn't change memory state: \(ExtensionErrorText.describe(error))", isError: true)
            }
        }
    }

    /// Deletes the selected note, proving with the preview's BLAKE3 hash that it is what the user saw.
    func forgetSelected() {
        guard let store, let file = selectedFile, file.isDeletable, busy == nil else { return }
        guard case .text(_, let hash) = preview else {
            status = MemoryStatusLine(text: "Can't delete: this note couldn't be read for verification.", isError: true); return
        }
        busy = "Deleting \(file.label)…"; status = nil
        Task {
            defer { busy = nil }
            do {
                let (client, id, session) = try await store.featureSession()
                let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/memory/forget", params: ["sessionId": session, "path": file.path, "expectedContentHash": hash], timeout: 60))
                guard store.state.selectedConversationID == id else { return }
                applyForget(result, file: file)
            } catch {
                status = MemoryStatusLine(text: "Couldn't delete \(file.label): \(ExtensionErrorText.describe(error))", isError: true)
            }
        }
    }

    func applyForget(_ result: [String: Any], file: MemoryFileItem) {
        if result["outcome"] as? String == "forgotten" {
            if var listing {
                let sections = listing.sections().flatMap(\.files)
                let index = sections.firstIndex(of: file)
                listing.files.removeAll { $0.path == file.path }
                self.listing = listing
                let remaining = listing.sections().flatMap(\.files)
                if selection == file.path {
                    select(index.flatMap { remaining.indices.contains($0) ? remaining[$0].path : remaining.last?.path })
                }
            }
            searchContents[file.path] = nil
            status = MemoryStatusLine(text: "Deleted \(file.label).")
            return
        }
        let message = result["message"] as? String ?? "The note wasn't deleted."
        switch result["reason"] as? String {
        case "changed":
            // Show what is on disk now so a second delete verifies the current bytes.
            select(file.path)
            status = MemoryStatusLine(text: message + " The preview now shows the current note.", isError: true)
        case "memory_disabled":
            status = MemoryStatusLine(text: message, isError: true)
            Task { await load(); status = MemoryStatusLine(text: message, isError: true) }
        case "dream_running":
            status = MemoryStatusLine(text: message + " Try again when Dream finishes.", isError: true)
        default:
            status = MemoryStatusLine(text: message, isError: true)
        }
    }

    func copySelectedPath() {
        guard let file = selectedFile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
        status = MemoryStatusLine(text: "Copied \(file.path)")
    }

    func openSelected() {
        guard let file = selectedFile else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    /// `/flush`: captures completed turns into memory now.
    func flush() { runMaintenance(method: "memory/flush", working: "Flushing memory…", summary: MemoryMaintenanceSummary.flush) }

    /// `/dream`: consolidates saved observations into topics.
    func dream() { runMaintenance(method: "memory/dream", working: "Dreaming…", summary: MemoryMaintenanceSummary.dream) }

    private func runMaintenance(method: String, working: String, summary: @escaping ([String: Any]) -> (text: String, succeeded: Bool)) {
        guard let store else { return }
        let command = method == "memory/flush" ? "flush" : "dream"
        guard store.project != nil else { store.banner = "Open a project first."; return }
        guard store.state.selectedConversationID != nil else { store.banner = "Open a task to run /\(command) on its memory."; return }
        guard !store.run.isRunning, !store.run.isConfiguring else { store.banner = "Wait for the current turn to finish or stop it before running /\(command)."; return }
        guard busy == nil else { return }
        busy = working; store.banner = working
        let showsPanel = store.featurePanel == .memory
        if showsPanel { status = nil }
        Task {
            defer { busy = nil }
            do {
                let (client, id, session) = try await store.featureSession()
                // These two methods take snake_case parameters, unlike the rest of the memory family.
                let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/\(method)", params: ["session_id": session], timeout: 600))
                let outcome = summary(result)
                store.banner = outcome.text
                if store.featurePanel == .memory, store.state.selectedConversationID == id {
                    status = MemoryStatusLine(text: outcome.text, isError: !outcome.succeeded)
                    await load()
                }
            } catch {
                let text = "Couldn't \(command) memory: \(ExtensionErrorText.describe(error))"
                store.banner = text
                if store.featurePanel == .memory { status = MemoryStatusLine(text: text, isError: true) }
            }
        }
    }
}
