import AppKit
import Combine
import SwiftUI

/// A scroll the transcript should perform. The serial makes repeated requests for the same
/// target distinct, so each one scrolls.
struct TranscriptScrollRequest: Equatable {
    enum Target: Equatable {
        /// Align the top of a message with the top of the transcript.
        case message(UUID)
        /// The end of the conversation, following new output again.
        case bottom
    }
    let serial: Int
    let target: Target
}

/// How a message row is marked: the current find match, or the vim-mode cursor.
enum TranscriptRowHighlight: Equatable {
    case none, match, focus
}

/// `/jump`: the turn list and where to return if the reader backs out.
struct TranscriptJumpState: Equatable {
    var turns: [TranscriptTurn]
    var selected: Int
    /// The turn on screen when the picker opened.
    var initial: Int
    var restoreMessageID: UUID?
    var restoreFollowing: Bool
}

/// `/history`: prompts fed by `_x.ai/prompt_history`, most recent first.
struct TranscriptHistoryState: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case project, task
        var id: String { rawValue }
        var title: String { self == .project ? "All tasks" : "This task" }
    }
    var scope: Scope = .project
    var prompts: [String] = []
    var isLoading = false
    /// Shown above the list when the harness could not provide history.
    var notice: String?
}

/// The export-format Markdown shown by the transcript window (`/transcript`).
struct TranscriptDocument: Equatable {
    enum Source: Equatable { case cli, local }
    let conversationID: UUID
    let title: String
    let markdown: String
    let source: Source
}

enum TranscriptDocumentState: Equatable {
    case idle
    case loading
    case empty
    case loaded(TranscriptDocument)
}

/// The message at the top of the visible transcript, for the timeline's active tick. Kept apart
/// from the model so scrolling re-renders only the rail.
@MainActor
final class TranscriptViewportState: ObservableObject {
    @Published var topMessageIndex: Int?
}

/// Find, jump, timeline, timestamps, expand, vim keys, copy, export, transcript, history, and debug overlays.
@MainActor
final class TranscriptToolsModel: ObservableObject {
    weak var store: AppStore?

    // MARK: Display preferences

    /// `[ui].show_timestamps` (default on), mirrored in UserDefaults so launch needs no file read.
    @Published private(set) var showTimestamps: Bool
    /// `[ui].show_timeline`.
    @Published private(set) var showTimeline: Bool
    /// `[ui].vim_mode`.
    @Published private(set) var vimMode: Bool

    // MARK: Transcript state

    /// Reasoning and tool blocks that are open. The rows read this rather than keeping their own
    /// state, so `/expand` and find can open them, and lazy rows keep it when they are recycled.
    @Published private(set) var expandedMessageIDs: Set<UUID> = []
    @Published private(set) var scrollRequest: TranscriptScrollRequest?
    @Published private(set) var vimFocusID: UUID?

    @Published private(set) var findPresented = false
    @Published var findQuery = "" { didSet { if findQuery != oldValue { runFind(resetCursor: true) } } }
    @Published private(set) var findMatches: [TranscriptFindMatch] = []
    @Published private(set) var findCursor: Int?
    @Published private(set) var findInvalid = false
    /// The query the matches belong to; the count waits while a newer one is searched.
    @Published private(set) var findSearchedQuery = ""
    @Published private(set) var findFocusRequest = 0

    @Published private(set) var jump: TranscriptJumpState?
    @Published private(set) var history = TranscriptHistoryState()
    @Published private(set) var document: TranscriptDocumentState = .idle

    @Published private(set) var debugScroll = false
    @Published private(set) var debugFPS = false
    @Published private(set) var scrollLogURL: URL?
    let debugHUD = TranscriptDebugHUD()
    let viewport = TranscriptViewportState()

    /// Reported by the transcript; read on demand, so not published.
    var isFollowingOutput = true
    var topVisibleMessageID: UUID?
    var lastScrollSample: TranscriptScrollSample?
    /// The view hosting the transcript, for vim keys and clicks.
    weak var hostView: NSView? { didSet { updateKeyMonitor() } }

    // MARK: Environment (injectable for tests)

    let defaults: UserDefaults
    var configURL: URL
    var grokHomeOverride: URL?
    var environment = ProcessInfo.processInfo.environment
    var pasteboard = NSPasteboard.general
    var grokHome: URL { grokHomeOverride ?? GrokPaths.home }
    /// The latest file, clipboard, or harness work started by a command.
    private(set) var pendingWork: Task<Void, Never>?

    private enum Keys {
        static let timestamps = "showTimestamps"
        static let timeline = "showTimeline"
        static let vimMode = "transcriptVimMode"
    }

    private let configQueue = DispatchQueue(label: "dev.chenli.crok.desktop.transcript-config", qos: .utility)
    private var preferencesLoaded = false
    private var preferenceEdits = 0
    private var scrollSerial = 0
    private var findGeneration = 0
    private var findRefresh: Task<Void, Never>?
    private var historyRequest = UUID()
    private var documentRequest = UUID()
    private var keyMonitor: Any?
    private var scrollLog: TranscriptScrollLog?

    init(store: AppStore, defaults: UserDefaults = .standard, configURL: URL? = nil) {
        self.store = store
        self.defaults = defaults
        self.configURL = configURL ?? GrokPaths.configFile
        showTimestamps = defaults.object(forKey: Keys.timestamps) as? Bool ?? true
        showTimeline = defaults.bool(forKey: Keys.timeline)
        vimMode = defaults.bool(forKey: Keys.vimMode)
    }

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool { false }

    private var messages: [Message] { store?.conversation?.messages ?? [] }

    /// Emits when another task is selected; windows that show the selected task reload on it.
    private(set) lazy var selectedConversationChanges: AnyPublisher<UUID?, Never> = {
        guard let store else { return Empty().eraseToAnyPublisher() }
        return store.$state.map(\.selectedConversationID).removeDuplicates().dropFirst().eraseToAnyPublisher()
    }()

    private func flush() {
        if let id = store?.state.selectedConversationID { store?.flushTranscript(id) }
    }

    // MARK: - Preferences

    /// Adopts `[ui]` values from config.toml once, so changes made in the terminal carry over.
    func loadPreferencesIfNeeded() {
        guard !preferencesLoaded else { return }
        preferencesLoaded = true
        let url = configURL, edits = preferenceEdits
        pendingWork = Task { [weak self] in
            let values = await Task.detached(priority: .utility) { () -> (Bool?, Bool?, Bool?) in
                let config = GrokConfig(url: url)
                return (config.bool("show_timestamps", in: "ui"), config.bool("show_timeline", in: "ui"), config.bool("vim_mode", in: "ui"))
            }.value
            guard let self, self.preferenceEdits == edits else { return }
            if let value = values.0, value != self.showTimestamps { self.showTimestamps = value; self.defaults.set(value, forKey: Keys.timestamps) }
            if let value = values.1, value != self.showTimeline { self.showTimeline = value; self.defaults.set(value, forKey: Keys.timeline) }
            if let value = values.2, value != self.vimMode { self.vimMode = value; self.defaults.set(value, forKey: Keys.vimMode); self.updateKeyMonitor() }
        }
    }

    private func persist(_ key: String, _ value: Bool) {
        preferenceEdits += 1
        let url = configURL
        configQueue.async { [weak self] in
            do { try GrokConfig.update(url: url) { try $0.set(key, to: .bool(value), in: "ui") } }
            catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.store?.banner = "Could not save [ui].\(key): \(message)" }
            }
        }
    }

    /// Blocks until queued config.toml writes have landed (tests).
    func waitForConfigWrites() { configQueue.sync {} }

    /// `/timestamps`.
    func toggleTimestamps() { setTimestamps(!showTimestamps) }

    func setTimestamps(_ enabled: Bool) {
        guard enabled != showTimestamps else { return }
        showTimestamps = enabled
        defaults.set(enabled, forKey: Keys.timestamps)
        persist("show_timestamps", enabled)
        store?.banner = "✓ Timestamps: \(enabled ? "on" : "off")"
    }

    /// `/timeline`.
    func toggleTimeline() { setTimeline(!showTimeline) }

    func setTimeline(_ enabled: Bool) {
        guard enabled != showTimeline else { return }
        showTimeline = enabled
        defaults.set(enabled, forKey: Keys.timeline)
        persist("show_timeline", enabled)
        store?.banner = "✓ Timeline sidebar: \(enabled ? "on" : "off")"
    }

    /// `/vim-mode`.
    func toggleVimMode() { setVimMode(!vimMode) }

    func setVimMode(_ enabled: Bool) {
        guard enabled != vimMode else { return }
        vimMode = enabled
        if !enabled { vimFocusID = nil }
        defaults.set(enabled, forKey: Keys.vimMode)
        persist("vim_mode", enabled)
        updateKeyMonitor()
        store?.banner = "Vim mode: \(enabled ? "on" : "off")"
    }

    // MARK: - Scrolling and expansion

    func requestScroll(_ target: TranscriptScrollRequest.Target) {
        scrollSerial += 1
        scrollRequest = TranscriptScrollRequest(serial: scrollSerial, target: target)
    }

    func isExpanded(_ id: UUID) -> Bool { expandedMessageIDs.contains(id) }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { expandedMessageIDs.insert(id) } else { expandedMessageIDs.remove(id) }
    }

    /// `/expand`: opens the newest folded reasoning or tool output and scrolls to it. Each use
    /// walks further back, because the blocks it opened stay open.
    func expandNext() {
        guard let store, store.conversation != nil else { store?.banner = "No active session"; return }
        flush()
        let target = messages.last { message in
            guard !expandedMessageIDs.contains(message.id) else { return false }
            switch message.kind {
            case .thought: return !message.text.isEmpty
            case .tool: return !(message.detail ?? "").isEmpty
            default: return false
            }
        }
        guard let target else { store.banner = "Nothing left to expand"; return }
        expandedMessageIDs.insert(target.id)
        requestScroll(.message(target.id))
    }

    /// The transcript switched to another task.
    func conversationDidChange() {
        vimFocusID = nil
        topVisibleMessageID = nil
        viewport.topMessageIndex = nil
        if findPresented { runFind(resetCursor: true) }
    }

    /// The transcript's text changed; a find that is open follows it, at most a few times a second.
    func transcriptDidChange() {
        guard findPresented, !findQuery.isEmpty, findRefresh == nil else { return }
        findRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.findRefresh = nil
            self.runFind(resetCursor: false)
        }
    }

    /// Called by the transcript as rows scroll in and out of view.
    func visibleMessagesChanged(topIndex: Int?, topID: UUID?) {
        topVisibleMessageID = topID
        if viewport.topMessageIndex != topIndex { viewport.topMessageIndex = topIndex }
    }

    // MARK: - /find

    /// `/find [text]` and ⌘F: shows the find bar, prefilled from the argument.
    func openFind(_ query: String) {
        guard let store, store.conversation != nil else { store?.banner = "No conversation to search yet"; return }
        flush()
        let wasPresented = findPresented
        findPresented = true
        findFocusRequest += 1
        if !query.isEmpty, query != findQuery { findQuery = query }
        else if !wasPresented { runFind(resetCursor: true) }
    }

    func closeFind() {
        guard findPresented else { return }
        findPresented = false
        findRefresh?.cancel(); findRefresh = nil
        findGeneration += 1
        findMatches = []; findCursor = nil; findInvalid = false; findSearchedQuery = ""
        if !vimMode { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
    }

    /// Return moves to the next match (⇧Return the previous); an empty query closes the bar.
    func submitFind(backwards: Bool) {
        if findQuery.isEmpty { closeFind(); return }
        moveFind(backwards ? -1 : 1)
    }

    func moveFind(_ step: Int) {
        guard let next = TranscriptSearch.step(findCursor, by: step, count: findMatches.count) else { return }
        findCursor = next
        revealFindMatch()
    }

    /// The message holding the current match, while the find bar is open.
    var currentFindMessageID: UUID? {
        guard findPresented, let cursor = findCursor, findMatches.indices.contains(cursor) else { return nil }
        return findMatches[cursor].messageID
    }

    /// "2 of 14", "No matches", or "Invalid pattern".
    var findStatus: String? {
        guard !findQuery.isEmpty, findSearchedQuery == findQuery else { return nil }
        if findInvalid { return "Invalid pattern" }
        guard let cursor = findCursor, !findMatches.isEmpty else { return "No matches" }
        return "\(cursor + 1) of \(findMatches.count)"
    }

    private func runFind(resetCursor: Bool) {
        findGeneration += 1
        let generation = findGeneration, query = findQuery
        guard findPresented else { return }
        guard !query.isEmpty else { findMatches = []; findCursor = nil; findInvalid = false; findSearchedQuery = ""; return }
        let snapshot = messages
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                TranscriptSearch.run(query: query, documents: snapshot.map(TranscriptSearchDocument.make))
            }.value
            self?.applyFind(result, query: query, generation: generation, resetCursor: resetCursor)
        }
    }

    private func applyFind(_ result: TranscriptSearch.Result, query: String, generation: Int, resetCursor: Bool) {
        guard generation == findGeneration, findPresented else { return }
        findSearchedQuery = query
        findInvalid = result.isInvalid
        let previous = findCursor
        findMatches = result.matches
        if result.matches.isEmpty { findCursor = nil; return }
        if resetCursor || previous == nil {
            findCursor = 0
            revealFindMatch()
        } else if let previous {
            findCursor = min(previous, result.matches.count - 1)
        }
    }

    private func revealFindMatch() {
        guard let id = currentFindMessageID, let message = messages.first(where: { $0.id == id }) else { return }
        if message.kind == .thought || message.kind == .tool { expandedMessageIDs.insert(id) }
        requestScroll(.message(id))
    }

    // MARK: - /jump and the timeline

    /// `/jump`: the turn picker. Moving through it scrolls the transcript; backing out restores it.
    func openJump() {
        guard let store, store.conversation != nil else { store?.banner = "Nothing to jump to yet"; return }
        flush()
        let messages = self.messages
        let turns = TranscriptTurns.list(messages)
        guard turns.count >= 2 else { store.banner = "Nothing to jump to yet"; return }
        let top = topVisibleMessageID.flatMap { id in messages.firstIndex { $0.id == id } }
        let selected = top.flatMap { TranscriptTurns.turn(containing: $0, in: turns) } ?? turns.count - 1
        jump = TranscriptJumpState(turns: turns, selected: selected, initial: selected,
                                   restoreMessageID: topVisibleMessageID, restoreFollowing: isFollowingOutput)
        requestScroll(.message(turns[selected].messageID))
        store.sheet = .jump
    }

    func moveJump(to index: Int) {
        guard var state = jump, !state.turns.isEmpty else { return }
        let clamped = min(max(index, 0), state.turns.count - 1)
        guard clamped != state.selected else { return }
        state.selected = clamped
        jump = state
        requestScroll(.message(state.turns[clamped].messageID))
    }

    func commitJump() {
        guard let state = jump else { return }
        jump = nil
        if state.turns.indices.contains(state.selected) { requestScroll(.message(state.turns[state.selected].messageID)) }
        if store?.sheet == .jump { store?.sheet = nil }
    }

    func cancelJump() {
        guard let state = jump else { return }
        jump = nil
        if state.restoreFollowing { requestScroll(.bottom) }
        else if let id = state.restoreMessageID, messages.contains(where: { $0.id == id }) { requestScroll(.message(id)) }
        if store?.sheet == .jump { store?.sheet = nil }
    }

    /// A click on a timeline tick.
    func jumpToTurn(_ turn: TranscriptTurn) { requestScroll(.message(turn.messageID)) }

    // MARK: - Vim keys

    enum VimKey { case down, up, top, bottom, yank, escape, insert }

    /// Moves the cursor through messages and copies the focused one. Returns false when the key
    /// has no meaning here and should reach the rest of the app.
    @discardableResult
    func handleVimKey(_ key: VimKey) -> Bool {
        guard vimMode, let store, store.conversation != nil else { return false }
        let messages = self.messages
        guard !messages.isEmpty else { return false }
        let current = vimFocusID.flatMap { id in messages.firstIndex { $0.id == id } }
        let start = topVisibleMessageID.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count - 1
        switch key {
        case .down: focus(current.map { min($0 + 1, messages.count - 1) } ?? start, in: messages)
        case .up: focus(current.map { max($0 - 1, 0) } ?? start, in: messages)
        case .top: focus(0, in: messages)
        case .bottom:
            vimFocusID = messages.last?.id
            requestScroll(.bottom)
        case .yank:
            guard let index = current else { store.banner = "Move to a message with j or k, then press y to copy it."; return true }
            let message = messages[index]
            let text = message.kind == .tool ? [message.text, message.detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") : message.text
            deliver(text) { [weak self] delivery in
                guard let self else { return }
                switch delivery {
                case .clipboard: self.store?.banner = "Copied to clipboard"
                case .file(let url): self.store?.banner = "Clipboard unreachable: wrote \(TranscriptClipboard.displayPath(url, grokHome: self.grokHome))"
                case .failed: self.store?.banner = "Copy failed"
                }
            }
        case .escape:
            guard vimFocusID != nil else { return false }
            vimFocusID = nil
        case .insert:
            vimFocusID = nil
            NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
        }
        return true
    }

    private func focus(_ index: Int, in messages: [Message]) {
        guard messages.indices.contains(index) else { return }
        vimFocusID = messages[index].id
        requestScroll(.message(messages[index].id))
    }

    private func updateKeyMonitor() {
        let wanted = vimMode && hostView != nil
        if wanted, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.intercept(event) ?? false }
                return consumed ? nil : event
            }
        } else if !wanted, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Vim keys apply only while no text field has the keyboard. Clicking the conversation, or
    /// pressing esc in an empty composer, hands the keyboard to it.
    private func intercept(_ event: NSEvent) -> Bool {
        guard vimMode, let host = hostView, let window = host.window, event.window === window, window.attachedSheet == nil else { return false }
        let composerFocused = window.firstResponder is SubmitTextView
        if event.type == .leftMouseDown {
            if composerFocused, host.convert(host.bounds, to: nil).contains(event.locationInWindow) { window.makeFirstResponder(nil) }
            return false
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if composerFocused {
            // Esc while composing belongs to the input method, which cancels the composition.
            guard event.keyCode == 53, store?.draft.isEmpty == true, (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
            window.makeFirstResponder(nil)
            handleVimKey(.down)
            return true
        }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        if event.keyCode == 53 { return handleVimKey(.escape) }
        switch event.charactersIgnoringModifiers {
        case "j": return handleVimKey(.down)
        case "k": return handleVimKey(.up)
        case "g": return handleVimKey(.top)
        case "G": return handleVimKey(.bottom)
        case "y": return handleVimKey(.yank)
        case "i": return handleVimKey(.insert)
        default: return false
        }
    }

    /// How a message row is marked right now.
    func highlight(for id: UUID) -> TranscriptRowHighlight {
        if id == currentFindMessageID { return .match }
        if vimMode, id == vimFocusID { return .focus }
        return .none
    }

    // MARK: - Clipboard

    /// Writes the clipboard now and its backup file in the background, then reports where the text landed.
    private func deliver(_ text: String, completion: @escaping (TranscriptCopyDelivery) -> Void) {
        let copied = TranscriptClipboard.setClipboard(text, pasteboard: pasteboard)
        let backup = TranscriptClipboard.backupURL(environment: environment, grokHome: grokHome)
        pendingWork = Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                (try? TranscriptClipboard.writeBackup(text, to: backup)) != nil
            }.value
            completion(TranscriptClipboard.delivery(copied: copied, backup: saved ? backup : nil))
        }
    }

    // MARK: - /copy

    /// `/copy [N] [file]`.
    func copy(_ arguments: String) {
        guard let store else { return }
        let request: TranscriptCopyRequest
        do { request = try TranscriptCopyRequest.parse(arguments) } catch { store.banner = error.localizedDescription; return }
        flush()
        let text: String
        switch TranscriptCopyRequest.select(request.index, from: messages) {
        case .failure(let error): store.banner = error.localizedDescription; return
        case .success(let value): text = value
        }
        let stats = TranscriptClipboard.statsSuffix(text)
        if let path = request.path {
            let url = TranscriptClipboard.resolve(path, relativeTo: store.project?.path)
            pendingWork = Task { [weak self] in
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { try TranscriptClipboard.writeCopyFile(text, to: url); return nil } catch { return error.localizedDescription }
                }.value
                self?.store?.banner = failure.map { "Failed to write file: \($0)" } ?? "Copied to \(url.path)\(stats)"
            }
        } else {
            deliver(text) { [weak self] delivery in
                guard let self else { return }
                self.store?.banner = TranscriptClipboard.copyMessage(delivery, stats: stats, grokHome: self.grokHome)
            }
        }
    }

    // MARK: - /export and /transcript

    /// The terminal's Markdown for a task: `crok export <session>` renders it exactly; a task the
    /// harness has not saved yet (or a failing CLI) falls back to the same format built here.
    func exportMarkdown(for id: UUID) async -> (markdown: String, source: TranscriptDocument.Source) {
        guard let store, let conversation = store.task(id) else { return ("", .local) }
        let local = TranscriptMarkdownExport.render(conversation.messages)
        let binary = store.binaryPath
        if let session = conversation.sessionID, FileManager.default.isExecutableFile(atPath: binary) {
            let cwd = store.state.projects.first { $0.id == conversation.projectID }?.path
            if let output = try? await GrokCLI.run(binary, arguments: ["export", session], cwd: cwd, timeout: 60), output.status == 0 {
                var text = output.text
                if text.hasSuffix("\n") { text.removeLast() }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, .cli) }
            }
        }
        return (local, .local)
    }

    /// `/export [filename]`: to a file, or to the clipboard and its backup file.
    func export(_ arguments: String) {
        guard let store, let conversation = store.conversation else { store?.banner = "No active session to export"; return }
        flush()
        let path = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = path.isEmpty ? nil : TranscriptClipboard.resolve(path, relativeTo: store.project?.path)
        let id = conversation.id
        pendingWork = Task { [weak self] in
            guard let self else { return }
            let markdown = await self.exportMarkdown(for: id).markdown
            guard !markdown.isEmpty else { self.store?.banner = "No conversation content to export"; return }
            if let target {
                let message = await Task.detached(priority: .userInitiated) { () -> String in
                    do { try TranscriptClipboard.makeDirectories(target.deletingLastPathComponent()) }
                    catch { return "Failed to create directory: \(error.localizedDescription)" }
                    do { try TranscriptClipboard.write(markdown, to: target, ownerOnly: false) }
                    catch { return "Failed to write file: \(error.localizedDescription)" }
                    return "Conversation exported to \(target.path)"
                }.value
                self.store?.banner = message
            } else {
                let stats = TranscriptClipboard.statsSuffix(markdown)
                self.deliver(markdown) { [weak self] delivery in
                    guard let self else { return }
                    self.store?.banner = TranscriptClipboard.exportMessage(delivery, stats: stats, grokHome: self.grokHome)
                }
            }
        }
    }

    /// `/transcript`, alias `/log`.
    func openTranscriptWindow() {
        guard let store, let conversation = store.conversation,
              conversation.sessionID != nil || !TranscriptMarkdownExport.render(conversation.messages).isEmpty else {
            store?.banner = "No conversation transcript to view yet"
            return
        }
        store.open(.transcript)
        loadDocument()
    }

    /// Loads the selected task's transcript into the transcript window.
    func loadDocument() {
        let request = UUID()
        documentRequest = request
        guard let store, let conversation = store.conversation else { document = .empty; return }
        flush()
        if case .loaded(let current) = document, current.conversationID == conversation.id {} else { document = .loading }
        let id = conversation.id, title = conversation.title
        pendingWork = Task { [weak self] in
            guard let self else { return }
            let (markdown, source) = await self.exportMarkdown(for: id)
            guard self.documentRequest == request else { return }
            self.document = markdown.isEmpty ? .empty
                : .loaded(TranscriptDocument(conversationID: id, title: title, markdown: markdown, source: source))
        }
    }

    /// Copies the transcript window's Markdown like `/export` without a file name does.
    func copyDocument(_ markdown: String, completion: @escaping (String) -> Void) {
        let stats = TranscriptClipboard.statsSuffix(markdown)
        deliver(markdown) { [weak self] delivery in
            guard let self else { return }
            completion(TranscriptClipboard.exportMessage(delivery, stats: stats, grokHome: self.grokHome))
        }
    }

    // MARK: - /history

    /// `/history`: fuzzy search over the prompts sent in this project.
    func openHistory() {
        guard let store else { return }
        guard store.project != nil else { store.banner = "Open a project first."; return }
        store.sheet = .history
        loadHistory(scope: history.scope)
    }

    func loadHistory(scope: TranscriptHistoryState.Scope) {
        guard let store, let project = store.project else { return }
        let request = UUID()
        historyRequest = request
        let taskPrompts = TranscriptPromptHistory.unique((store.conversation?.messages ?? []).reversed().filter { $0.kind == .user }.map(\.text))
        let sessionID = store.conversation?.sessionID
        history = TranscriptHistoryState(scope: scope, prompts: history.scope == scope ? history.prompts : [], isLoading: true)
        if scope == .task && sessionID == nil {
            history = TranscriptHistoryState(scope: scope, prompts: taskPrompts)
            return
        }
        pendingWork = Task { [weak self] in
            guard let self else { return }
            do {
                let prompts = try await self.fetchPromptHistory(cwd: project.path, sessionID: scope == .task ? sessionID : nil)
                guard self.historyRequest == request else { return }
                self.history = TranscriptHistoryState(scope: scope, prompts: prompts)
            } catch {
                guard self.historyRequest == request else { return }
                self.history = TranscriptHistoryState(scope: scope, prompts: taskPrompts,
                                                      notice: "Prompt history is unavailable (\(error.localizedDescription)). Showing this task's prompts.")
            }
        }
    }

    /// `_x.ai/prompt_history`. A connected task's client is reused; otherwise a short-lived one is
    /// started, so reading history never creates a task.
    private func fetchPromptHistory(cwd: String, sessionID: String?) async throws -> [String] {
        guard let store else { throw CancellationError() }
        var params: [String: Any] = ["cwd": cwd]
        if let sessionID { params["filter_session_id"] = sessionID }
        if let id = store.state.selectedConversationID, let client = store.clients[id], store.loaded.contains(id) {
            return TranscriptPromptHistory.prompts(from: try await client.request("_x.ai/prompt_history", params: params))
        }
        let client = ACPClient()
        let clientID = UUID()
        store.auxiliaryClients[clientID] = client
        defer { client.stop(); store.auxiliaryClients.removeValue(forKey: clientID) }
        try client.start(executable: store.binaryPath, cwd: cwd)
        let initial = try await store.initialize(client)
        try await store.authenticate(client, initial: initial)
        let response = try await client.request("_x.ai/prompt_history", params: params)
        if let error = response["error"] as? [String: Any] { throw DesktopError.message(error["message"] as? String ?? "The runtime rejected the request.") }
        return TranscriptPromptHistory.prompts(from: response)
    }

    /// Puts a prompt in the composer and gives it the keyboard.
    func insertHistory(_ prompt: String) {
        store?.draft = prompt
        store?.sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotificationCenter.default.post(name: .grokFocusComposer, object: nil) }
    }

    // MARK: - /debug

    /// `/debug [scroll|fps|log]` and bare `/scroll-debug`.
    func debug(_ arguments: String) {
        switch arguments.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": store?.banner = TranscriptDebugFormat.status(scroll: debugScroll, fps: debugFPS, log: scrollLogURL != nil)
        case "scroll":
            debugScroll.toggle()
            debugHUD.scroll = lastScrollSample
            debugHUD.following = isFollowingOutput
            debugHUD.messageCount = messages.count
        case "fps":
            debugFPS.toggle()
            debugHUD.resetFrames()
        case "log": toggleScrollLog()
        case let other: store?.banner = "Unknown /debug option '\(other)'. Usage: /debug [scroll|fps|log]"
        }
    }

    private func toggleScrollLog() {
        if let log = scrollLog {
            log.close()
            scrollLog = nil
            scrollLogURL = nil
            store?.banner = "scroll log: off"
            return
        }
        let url = TranscriptDebugFormat.scrollLogURL(grokHome: grokHome)
        do {
            let log = try TranscriptScrollLog(url: url)
            scrollLog = log
            scrollLogURL = url
            log.record(["evt": "start", "messages": messages.count, "following": isFollowingOutput])
            store?.banner = "scroll log: recording to \(url.path)"
        } catch {
            store?.banner = "scroll log: could not open \(url.path): \(error.localizedDescription)"
        }
    }

    /// Scroll geometry from the transcript, for the scroll HUD and log.
    func recordScroll(_ sample: TranscriptScrollSample) {
        lastScrollSample = sample
        if debugScroll { debugHUD.scroll = sample }
        scrollLog?.record(["evt": "scroll", "offset_y": Double(sample.offsetY), "content_height": Double(sample.contentHeight),
                           "viewport_height": Double(sample.viewportHeight), "following": isFollowingOutput])
    }

    func recordScrollPhase(_ phase: String) {
        if debugScroll { debugHUD.phase = phase }
        scrollLog?.record(["evt": "phase", "phase": phase, "following": isFollowingOutput])
    }

    /// How often a transcript that showed none of its rows was laid out afresh (see `TranscriptPage`).
    private(set) var blankRecoveries = 0

    func recordBlankRecovery(messageCount: Int) {
        blankRecoveries += 1
        scrollLog?.record(["evt": "blank_recovery", "messages": messageCount, "following": isFollowingOutput])
    }

    func recordFollowing(_ following: Bool, messageCount: Int) {
        isFollowingOutput = following
        if debugScroll { debugHUD.following = following; debugHUD.messageCount = messageCount }
        scrollLog?.record(["evt": "follow", "following": following])
    }
}

/// Where the transcript is scrolled, as the HUD and log report it.
struct TranscriptScrollSample: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// Numbers for the debug HUDs, published a few times a second rather than every frame.
@MainActor
final class TranscriptDebugHUD: ObservableObject {
    @Published private(set) var frameLine = TranscriptDebugFormat.frameLine([])
    @Published private(set) var scrollLines: [String] = []
    var scroll: TranscriptScrollSample?
    var phase = "idle"
    var following = true
    var messageCount = 0
    private var intervals: [Double] = []
    private var lastFrame: CFTimeInterval?

    /// A display refresh; the gap since the previous one is the frame's cost to the main thread.
    func recordFrame(timestamp: CFTimeInterval) {
        defer { lastFrame = timestamp }
        guard let lastFrame, timestamp > lastFrame else { return }
        intervals.append((timestamp - lastFrame) * 1000)
        if intervals.count > 120 { intervals.removeFirst(intervals.count - 120) }
    }

    func resetFrames() {
        intervals.removeAll()
        lastFrame = nil
        frameLine = TranscriptDebugFormat.frameLine([])
    }

    func refresh() {
        let line = TranscriptDebugFormat.frameLine(intervals)
        if line != frameLine { frameLine = line }
        var lines: [String] = []
        if let scroll {
            lines.append(String(format: "offset %.0f / %.0f", scroll.offsetY, max(0, scroll.contentHeight - scroll.viewportHeight)))
            lines.append(String(format: "content %.0f  viewport %.0f", scroll.contentHeight, scroll.viewportHeight))
        } else {
            lines.append(ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
                         ? "offset -  (scroll to sample)" : "offset -  (needs macOS 15)")
        }
        lines.append("following \(following ? "yes" : "no")  ·  \(phase)")
        lines.append("messages \(messageCount)")
        if lines != scrollLines { scrollLines = lines }
    }
}

/// The `/debug log` recorder: one JSON object per line, written off the main thread.
final class TranscriptScrollLog: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.chenli.crok.desktop.scroll-log", qos: .utility)
    private let started = Date()

    init(url: URL) throws {
        self.url = url
        try TranscriptClipboard.makeDirectories(url.deletingLastPathComponent())
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw TranscriptFileError(code: errno == 0 ? EACCES : errno) }
        handle = try FileHandle(forWritingTo: url)
    }

    func record(_ fields: [String: Any]) {
        var record = fields
        record["ts_ms"] = Int(Date().timeIntervalSince(started) * 1000)
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        let handle = self.handle
        queue.async { try? handle.write(contentsOf: data) }
    }

    func close() {
        let handle = self.handle
        queue.async { try? handle.close() }
    }

    /// Blocks until queued records are written (tests).
    func waitForWrites() { queue.sync {} }
}
