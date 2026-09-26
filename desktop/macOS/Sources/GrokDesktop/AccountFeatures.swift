import AppKit
import SwiftUI

/// Usage, context, session info, feedback, release notes, and announcements.
@MainActor
final class AccountFeatureModel: ObservableObject {
    weak var store: AppStore?

    /// The usage sheet's tab. `/usage`, `/context`, and `/session-info` switch it in place when the sheet is open.
    @Published var usageTab: UsageTab = .usage
    @Published private(set) var usage = UsageSheetState()
    @Published private(set) var releaseNotes = ReleaseNotesState()
    @Published private(set) var announcements: [GrokAnnouncement] = []
    @Published private(set) var hiddenAnnouncementKeys: Set<String> = []
    @Published private(set) var feedbackDrafts: FeedbackDraftListState = .idle

    /// Opens links in the browser. Tests replace it so nothing leaves the process.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// `$GROK_HOME`, read when needed. Tests point it at a temporary directory.
    var grokHome: () -> URL = { GrokPaths.home }
    /// Downloads release notes. Tests replace it so no request reaches the network.
    var downloadText: (URL, TimeInterval) async -> String? = ReleaseNotesLoader.download

    private var usageRequestID: UUID?
    private var releaseNotesRequestID: UUID?
    private var draftsRequestID: UUID?
    private var announcementsGeneration: UInt64 = 0
    private var announcementExpiry: Task<Void, Never>?
    private let announcementWrites = DispatchQueue(label: "ai.grok.desktop.announcements", qos: .utility)
    /// "No, and don't ask again" applies to the rest of this run even before config.toml is read again.
    private var feedbackTraceLatched = false
    private var showResolvedModel = false

    init(store: AppStore) { self.store = store }

    // MARK: Notifications

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool {
        handleGlobal(method: method, params: params)
    }

    /// Notifications that do not depend on a task (for example `x.ai/announcements/update`).
    func handleGlobal(method: String, params: [String: Any]) -> Bool {
        switch method {
        case "x.ai/announcements/update":
            applyAnnouncementsUpdate(params)
            return true
        case "x.ai/settings/update":
            // Other features read the same push; only note what the session-info model row needs.
            let settings = params["settings"] as? [String: Any] ?? params
            if let value = settings["show_resolved_model"] as? Bool { showResolvedModel = value }
            return false
        default:
            return false
        }
    }

    // MARK: Command entry points

    /// `/usage`, alias `/cost`: the current session's token and cost totals.
    func usage(_ arguments: String) {
        let argument = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard argument.isEmpty else { store?.banner = "Unknown argument: \(argument). Use /usage"; return }
        presentUsage(.usage)
    }
    /// `/context`. The shell's own `/context` prompt does nothing, so it is never forwarded.
    func openContext() { presentUsage(.context) }
    /// `/session-info`, aliases `/status` and `/info`.
    func openSessionInfo() { presentUsage(.session) }
    /// `/feedback [text]`: text is sent at once, as in the terminal; bare opens the form.
    func feedback(_ arguments: String) {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { store?.sheet = .feedback(text: "") } else { sendInlineFeedback(text) }
    }
    /// `/release-notes`, alias `/changelog`.
    func openReleaseNotes() {
        store?.open(.releaseNotes)
        if !releaseNotes.isLoading { loadReleaseNotes() }
    }
    /// `/announcements hide|show`.
    func announcements(_ arguments: String) {
        switch arguments.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" {
        case "hide": hideCurrentAnnouncement()
        case "show": showAllAnnouncements()
        default: store?.banner = "Usage: /announcements hide | show"
        }
    }

    private func presentUsage(_ tab: UsageTab) {
        guard let store else { return }
        usageTab = tab
        // An open sheet only changes tabs, as the terminal's modal does; reopening would refetch.
        if case .usage = store.sheet { return }
        store.sheet = .usage(tab)
    }

    /// The selected task's session, when there is a task. Nothing is created without one.
    private func selectedSession() async throws -> (ACPClient, UUID, String)? {
        guard let store, store.state.selectedConversationID != nil else { return nil }
        return try await store.featureSession()
    }

    // MARK: Usage sheet

    /// Loads all three tabs. Results from an earlier load are dropped.
    func refreshUsage() {
        guard let store else { return }
        let requestID = UUID()
        usageRequestID = requestID
        let conversation = store.conversation
        var state = UsageSheetState()
        if conversation != nil {
            state.context = .loading; state.sessionInfo = .loading; state.sessionUsage = .loading
        } else {
            state.context = .unavailable("No active session.")
            state.sessionInfo = .unavailable("No active session.")
            state.sessionUsage = .unavailable("No active session.")
        }
        usage = state
        Task { await loadUsage(requestID: requestID, title: conversation?.title) }
    }

    private func loadUsage(requestID: UUID, title: String?) async {
        let session: (ACPClient, UUID, String)?
        do { session = try await selectedSession() } catch {
            guard usageRequestID == requestID else { return }
            let message = AccountErrorText.describe(error)
            usage.context = .failed(message); usage.sessionInfo = .failed(message); usage.sessionUsage = .failed(message)
            return
        }
        guard usageRequestID == requestID, case let (client, _, sessionID)? = session else { return }
        async let info: Void = loadSessionInfo(requestID: requestID, client: client, sessionID: sessionID, title: title)
        async let totals: Void = loadSessionUsage(requestID: requestID, client: client, sessionID: sessionID)
        _ = await (info, totals)
    }

    private func loadSessionInfo(requestID: UUID, client: ACPClient, sessionID: String, title: String?) async {
        do {
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/session/info", params: ["sessionId": sessionID]))
            guard usageRequestID == requestID, let store else { return }
            let info = UsageSessionInfo(result)
            usage.context = .loaded(info.context)
            usage.contextModel = info.model ?? "unknown"
            usage.sessionInfo = .loaded(UsageFormatting.sessionInfoRows(
                info, title: title, shellVersion: store.harnessMeta.agentVersion,
                auth: .providerCredentials, showResolvedModel: showResolvedModel))
        } catch {
            guard usageRequestID == requestID else { return }
            let message = AccountErrorText.describe(error)
            usage.context = .failed(message); usage.sessionInfo = .failed(message)
        }
    }

    private func loadSessionUsage(requestID: UUID, client: ACPClient, sessionID: String) async {
        do {
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/session/usage", params: ["sessionId": sessionID]))
            guard usageRequestID == requestID else { return }
            guard let totals = result["usage"] as? [String: Any] else { throw DesktopError.message("The harness did not return session usage.") }
            usage.sessionUsage = .loaded(UsageSessionSummary(totals))
        } catch {
            guard usageRequestID == requestID else { return }
            usage.sessionUsage = .failed(AccountErrorText.describe(error))
        }
    }

    // MARK: Feedback

    /// Whether to ask about attaching the session trace, following the terminal's gates:
    /// offered by the harness, coding data opted in, not Zero Data Retention, not on a team,
    /// and not declined with "don't ask again".
    var feedbackTraceOffered: Bool {
        guard let store, store.harnessMeta.feedbackTraceOffer, !feedbackTraceLatched else { return false }
        let optOut = store.harnessMeta.codingDataRetentionOptOut ?? true
        let config = GrokConfig(url: grokHome().appendingPathComponent("config.toml"))
        return !optOut && !store.harnessMeta.isZDR && store.harnessMeta.teamName == nil
            && config.bool("feedback_trace_card", in: "features") != false
    }

    /// `/feedback <text>`: thanks at once, send in the background, and keep the text as a draft if it fails.
    func sendInlineFeedback(_ text: String) {
        guard let store else { return }
        // Feedback is sent with a session's details; don't start an empty task for it.
        guard store.state.selectedConversationID != nil else { store.banner = FeedbackCopy.needsTask; return }
        store.banner = FeedbackCopy.thanks
        let projectPath = store.project?.path
        Task {
            var sessionID: String?
            do {
                let (client, _, session) = try await store.featureSession()
                sessionID = session
                let params = FeedbackRequests.write(sessionID: session, text: text, images: [], taxonomy: FeedbackTaxonomySelection(),
                                                    requestTraceUploadToken: false, clientVersion: FeedbackRequests.clientVersion)
                let response = FeedbackResponse(try await client.request("_x.ai/feedback", params: params, timeout: FeedbackRequests.sendTimeout))
                if response.outcome == .outcomeUnknown { store.banner = FeedbackCopy.enqueuedUnknown }
            } catch ACPClientError.timedOut {
                store.banner = FeedbackCopy.enqueuedUnknown
            } catch {
                let failure = "Couldn't send feedback: \(AccountErrorText.describe(error))"
                store.banner = await keepUnsentFeedback(text: text, failure: failure, projectPath: projectPath, sessionID: sessionID)
            }
        }
    }

    /// Saves unsent inline feedback as a draft beside the session, as the terminal does.
    private func keepUnsentFeedback(text: String, failure: String, projectPath: String?, sessionID: String?) async -> String {
        let home = grokHome()
        // Harness messages often end in a period; the notice adds its own.
        let failure = failure.hasSuffix(".") ? String(failure.dropLast()) : failure
        guard let projectPath, let sessionID else { return "\(failure). Not sent: \(text)" }
        return await Task.detached(priority: .utility) { () -> String in
            guard let directory = GrokPaths.sessionDirectory(cwd: projectPath, sessionID: sessionID, home: home) else {
                return "\(failure). Not sent: \(text)"
            }
            do {
                try FeedbackPredraftStore.append(sessionDirectory: directory, title: FeedbackText.deriveTitle(text), details: text)
                return "\(failure). Saved to Drafts; open `/feedback` to retry."
            } catch {
                return "\(failure). Could not save it as a draft (\(error.localizedDescription)). Not sent: \(text)"
            }
        }.value
    }

    /// Sends the feedback form. The sheet stays open on failure so nothing typed is lost.
    func submitFeedback(_ composition: FeedbackComposition) async -> FeedbackSubmitResult {
        guard let store else { return .failed("Grok Desktop is closing.") }
        guard store.state.selectedConversationID != nil else { return .failed(FeedbackCopy.needsTask) }
        let text = composition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composition.images.isEmpty else { return .failed(FeedbackCopy.emptySubmit) }
        if composition.draft != nil, composition.taxonomy.type == nil { return .failed(FeedbackCopy.draftNeedsType) }
        if composition.traceChoice == .neverAsk { persistFeedbackTraceDecline() }
        let wantsTrace = composition.traceChoice == .sendThisSession
        let client: ACPClient, session: String
        do { (client, _, session) = try await store.featureSession() } catch {
            return .failed("Couldn't send feedback: \(AccountErrorText.describe(error))")
        }
        let params: [String: Any]
        if let draft = composition.draft, let type = composition.taxonomy.type {
            params = FeedbackRequests.draft(sessionID: session, draftID: draft.id, title: draft.title, details: text, area: draft.area,
                                            type: type, taxonomy: composition.taxonomy, images: composition.images,
                                            requestTraceUploadToken: wantsTrace, clientVersion: FeedbackRequests.clientVersion)
        } else {
            params = FeedbackRequests.write(sessionID: session, text: text, images: composition.images, taxonomy: composition.taxonomy,
                                            requestTraceUploadToken: wantsTrace, clientVersion: FeedbackRequests.clientVersion)
        }
        let response: FeedbackResponse
        do {
            response = FeedbackResponse(try await client.request("_x.ai/feedback", params: params, timeout: FeedbackRequests.sendTimeout))
        } catch ACPClientError.timedOut {
            response = FeedbackResponse(success: false, outcome: .outcomeUnknown, traceUploadToken: nil)
        } catch {
            let failure = "Couldn't send feedback: \(AccountErrorText.describe(error))"
            return .failed(composition.draft == nil ? failure : "\(failure). The draft was kept.")
        }
        if wantsTrace, response.posted, let token = response.traceUploadToken { uploadFeedbackTrace(client: client, sessionID: session, token: token) }
        guard let draft = composition.draft else {
            if response.outcome == .outcomeUnknown { store.banner = FeedbackCopy.enqueuedUnknown } else { store.banner = FeedbackCopy.thanks }
            return .sent
        }
        switch response.outcome {
        case .submitted:
            store.banner = FeedbackCopy.thanks
            return .sent
        case .submittedCleanupFailed:
            return .settled(FeedbackCopy.draftCleanupFailed)
        case .localOnly:
            return .failed(FeedbackCopy.draftLocalOnly)
        case .outcomeUnknown, .other:
            // Never resend: copy the latest text and save it back to the draft instead.
            let copy = FeedbackText.postText(title: draft.title, details: text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
            guard let type = composition.taxonomy.type else { return .settled(FeedbackCopy.unknownNotSaved) }
            let update = FeedbackRequests.update(sessionID: session, draftID: draft.id, title: draft.title, details: text, area: draft.area,
                                                 type: type, taxonomy: composition.taxonomy)
            let saved = (try? await client.request("_x.ai/feedback/drafts/update", params: update, timeout: 15))?["updated"] as? Bool == true
            return .settled(saved ? FeedbackCopy.unknownSaved : FeedbackCopy.unknownSaveFailed)
        }
    }

    private func uploadFeedbackTrace(client: ACPClient, sessionID: String, token: String) {
        Task { [weak self] in
            do {
                _ = try ExtensionResponse.unwrap(try await client.request("_x.ai/feedback/upload-trace", params: [
                    "sessionId": sessionID, "intent": "send_this_session", "traceUploadToken": token,
                ], timeout: 150))
            } catch {
                self?.store?.banner = "Couldn't upload a session trace; your feedback was still sent. \(AccountErrorText.describe(error))"
            }
        }
    }

    /// "No, and don't ask again": `[features] feedback_trace_card = false`, shared with the terminal.
    private func persistFeedbackTraceDecline() {
        feedbackTraceLatched = true
        let url = grokHome().appendingPathComponent("config.toml")
        Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try GrokConfig.update(url: url) { try $0.set("feedback_trace_card", to: .bool(false), in: "features") }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let failure { self?.store?.banner = "✗ Could not save feedback_trace_card: \(failure)" }
        }
    }

    /// Loads the selected task's saved feedback drafts.
    func loadFeedbackDrafts() async {
        guard let store else { return }
        guard store.state.selectedConversationID != nil else {
            feedbackDrafts = .unavailable("Feedback drafts are saved with a task. Select a task to see its drafts.")
            return
        }
        let requestID = UUID()
        draftsRequestID = requestID
        feedbackDrafts = .loading
        do {
            let (client, _, session) = try await store.featureSession()
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/feedback/drafts/list", params: ["session_id": session], timeout: 15))
            guard draftsRequestID == requestID else { return }
            feedbackDrafts = .loaded((result["drafts"] as? [[String: Any]] ?? []).compactMap(FeedbackDraftRecord.init))
        } catch {
            guard draftsRequestID == requestID else { return }
            feedbackDrafts = .failed(AccountErrorText.describe(error))
        }
    }

    func loadFeedbackDraft(id: String) async throws -> FeedbackDraftRecord {
        guard let store else { throw CancellationError() }
        let (client, _, session) = try await store.featureSession()
        let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/feedback/drafts/get", params: ["session_id": session, "draft_id": id], timeout: 15))
        guard let draft = (result["draft"] as? [String: Any]).flatMap(FeedbackDraftRecord.init) else {
            throw DesktopError.message("The harness did not return the feedback draft.")
        }
        return draft
    }

    func deleteFeedbackDraft(id: String) async throws {
        guard let store else { throw CancellationError() }
        let (client, _, session) = try await store.featureSession()
        let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/feedback/drafts/delete", params: ["session_id": session, "draft_id": id], timeout: 15))
        guard result["deleted"] as? Bool == true else { throw DesktopError.message("The draft was already deleted.") }
        if case .loaded(let rows) = feedbackDrafts { feedbackDrafts = .loaded(rows.filter { $0.id != id }) }
    }

    // MARK: Release notes

    func loadReleaseNotes() {
        guard let store else { return }
        let requestID = UUID()
        releaseNotesRequestID = requestID
        releaseNotes.isLoading = true
        releaseNotes.message = nil
        let knownVersion = store.harnessMeta.agentVersion
        let binary = store.binaryPath
        let home = grokHome()
        let download = downloadText
        Task {
            var version = knownVersion
            if version == nil { version = await ReleaseNotesLoader.cliVersion(binary: binary) }
            let loaded = await ReleaseNotesLoader.load(version: version, home: home, download: download)
            guard releaseNotesRequestID == requestID else { return }
            releaseNotes = ReleaseNotesState(version: version, markdown: loaded?.markdown, source: loaded?.source, isLoading: false,
                                             message: loaded == nil ? "No release notes available (offline)." : nil)
        }
    }

    // MARK: Announcements

    /// The banner's announcement: the first live critical one, else the first promo, skipping hidden ones.
    var currentAnnouncement: GrokAnnouncement? {
        AnnouncementRules.current(announcements, hidden: hiddenAnnouncementKeys, now: Date())
    }

    /// Whether `/announcements` has anything to act on. Hidden ones count, so `show` stays reachable.
    var hasSessionAnnouncements: Bool { !AnnouncementRules.sessionHideKeys(announcements, now: Date()).isEmpty }

    func applyAnnouncementsUpdate(_ params: [String: Any], now: Date = Date()) {
        let generation = (params["gen"] as? NSNumber)?.uint64Value ?? 0
        guard generation > announcementsGeneration else { return }
        announcementsGeneration = generation
        let list = (params["announcements"] as? [[String: Any]] ?? []).map(GrokAnnouncement.init).filter { !$0.isExpired(at: now) }
        announcements = list
        var hidden = readHiddenAnnouncements()
        if AnnouncementRules.prune(&hidden, active: list) { persistHiddenAnnouncements(hidden) }
        hiddenAnnouncementKeys = hidden
        scheduleAnnouncementExpiry()
    }

    /// Takes an announcement down when it expires, as the terminal's per-frame check does.
    private func scheduleAnnouncementExpiry() {
        announcementExpiry?.cancel()
        guard let next = announcements.compactMap(\.expiresAt).filter({ $0 > Date() }).min() else { return }
        announcementExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, next.timeIntervalSinceNow) * 1_000_000_000) + 50_000_000)
            guard !Task.isCancelled, let self else { return }
            self.announcements = self.announcements.filter { !$0.isExpired(at: Date()) }
            self.scheduleAnnouncementExpiry()
        }
    }

    /// Hides the shown announcement when the server allows it. The terminal's hides are read first.
    func hideCurrentAnnouncement() {
        var hidden = readHiddenAnnouncements()
        guard let shown = AnnouncementRules.current(announcements, hidden: hidden, now: Date()), shown.isDismissible else {
            hiddenAnnouncementKeys = hidden
            return
        }
        hidden.insert(shown.hideKey)
        hiddenAnnouncementKeys = hidden
        persistHiddenAnnouncements(hidden)
    }

    /// Shows every current announcement again.
    func showAllAnnouncements() {
        let keys = Set(AnnouncementRules.sessionHideKeys(announcements, now: Date()))
        var hidden = readHiddenAnnouncements()
        let changed = !hidden.isDisjoint(with: keys)
        hidden.subtract(keys)
        hiddenAnnouncementKeys = hidden
        if changed { persistHiddenAnnouncements(hidden) }
    }

    func openAnnouncementAction(_ announcement: GrokAnnouncement) {
        guard let url = announcement.action?.url else { return }
        openURL(url)
    }

    /// The hidden set the terminal and Grok Desktop share, after this app's own queued writes.
    private func readHiddenAnnouncements() -> Set<String> {
        announcementWrites.sync {}
        return AnnouncementHiddenFile.read(home: grokHome())
    }

    private func persistHiddenAnnouncements(_ keys: Set<String>) {
        let home = grokHome()
        announcementWrites.async {
            do { try AnnouncementHiddenFile.write(keys, home: home) }
            catch { NSLog("Grok Desktop could not save hidden announcements: \(error.localizedDescription)") }
        }
    }

    /// Waits for queued writes to `announcements.json`; used by tests.
    func flushAnnouncementWrites() { announcementWrites.sync {} }
}

#if DEBUG
extension AccountFeatureModel {
    /// Puts panels into a given state without a harness, for snapshot tests.
    func showPreviewState(usage: UsageSheetState? = nil, releaseNotes: ReleaseNotesState? = nil,
                          drafts: FeedbackDraftListState? = nil, announcements: [GrokAnnouncement]? = nil) {
        if let usage { self.usage = usage }
        if let releaseNotes { self.releaseNotes = releaseNotes }
        if let drafts { feedbackDrafts = drafts }
        if let announcements { self.announcements = announcements; hiddenAnnouncementKeys = [] }
    }
}
#endif

/// The Session info tab's "Auth method" row.
struct AccountAuthDescription: Equatable {
    var method: String
    var note: String?

    /// Grok Desktop signs in only with OpenRouter or OpenAI Codex credentials.
    static let providerCredentials = AccountAuthDescription(method: "Provider credentials", note: nil)
}

/// Error text for notices. Harness errors carry their detail in JSON-RPC `data`.
enum AccountErrorText {
    static func describe(_ error: Error) -> String {
        if case ACPClientError.remote(_, let message, let data) = error {
            if let text = data as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            if let object = data as? [String: Any], let text = object["message"] as? String ?? object["error"] as? String, !text.isEmpty { return text }
            return message
        }
        return error.localizedDescription
    }
}
