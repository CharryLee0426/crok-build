import Foundation
import Observation

/// One page of the transcript subscription. The newest page (`cursor == nil`) is live and grows as events arrive;
/// once an older page is loaded below it, its end is pinned (`endCursor`) so pages stay contiguous (the same scheme
/// Convex's own paginated queries use).
@MainActor
final class TranscriptPage {
    let cursor: String?
    private(set) var endCursor: String?
    private(set) var query: LiveQuery<EventsPage>
    private let make: @MainActor (String?, String?) -> LiveQuery<EventsPage>

    init(cursor: String?, make: @escaping @MainActor (String?, String?) -> LiveQuery<EventsPage>) {
        self.cursor = cursor
        self.make = make
        self.query = make(cursor, nil)
    }

    /// Fixes where this page ends and resubscribes; keeps showing the old value until the new one arrives.
    func pin(to endCursor: String) {
        guard self.endCursor == nil else { return }
        self.endCursor = endCursor
        let previous = query
        query = make(cursor, endCursor)
        if let value = previous.value { query.override(value) }
        query.start()
        previous.stop()
    }
}

/// The session screen's state: header, plan, transcript (paged, bottom-anchored), prompt ticks, streaming reveal,
/// composer draft, and the `watch` / `markRead` bookkeeping.
@MainActor
@Observable
final class SessionViewModel {
    let sessionDocId: DocID
    let engine: CrokEngine
    let detail: LiveQuery<SessionDetail>
    let commands: LiveQuery<[PromptCommand]>

    private(set) var items: [TranscriptItem] = []
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    private(set) var initialLoaded = false
    /// New transcript items that arrived while the person was scrolled up (the scroll-to-bottom button's counter).
    private(set) var newWhileAway = 0
    /// Assistant events whose text is being revealed gradually.
    private(set) var revealing: Set<DocID> = []
    var actionError: RelayError?
    /// The pending request this phone just answered, until the computer takes the answer (the request's id changes).
    private(set) var answeringRequestId: String?
    var isAtBottom = true {
        didSet { if isAtBottom { newWhileAway = 0 } }
    }
    /// Bumped whenever the transcript's content grows (new items, or a revealing reply getting longer), so the view
    /// can keep the bottom in sight.
    private(set) var contentTick = 0
    var draft: String {
        didSet { scheduleDraftSave() }
    }

    @ObservationIgnored private(set) var pages: [TranscriptPage] = []
    @ObservationIgnored private var events: [DocID: TranscriptEvent] = [:]
    @ObservationIgnored private var pacers: [DocID: TextRevealPacer] = [:]
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    /// When the bottom of the transcript was last on screen; `.distantPast` once the person scrolls up.
    @ObservationIgnored private var bottomSeenAt = Date()
    @ObservationIgnored private var revealTicker: Task<Void, Never>?

    /// Events per page; `-CrokPageSize 8` makes paging easy to try with the demo data.
    static var pageSize: Int {
        let override = UserDefaults.standard.integer(forKey: "CrokPageSize")
        return override > 0 ? override : 50
    }

    init(sessionDocId: DocID, engine: CrokEngine) {
        self.sessionDocId = sessionDocId
        self.engine = engine
        let sessions = engine.sessions
        let commandsAPI = engine.commands
        detail = LiveQuery(engine: engine) { sessions.get(sessionDocId) }
        commands = LiveQuery(engine: engine) { commandsAPI.forSession(sessionDocId) }
        draft = engine.drafts.draft(for: sessionDocId)
    }

    // MARK: Lifecycle

    func appear() {
        guard !isVisible else { return }
        isVisible = true
        if pages.isEmpty {
            detail.onValue = { [weak self] value in self?.detailChanged(value) }
            commands.onValue = { [weak self] _ in self?.rebuild() }
            detail.start()
            commands.start()
            let first = makePage(cursor: nil)
            pages = [first]
            first.query.start()
        }
        let sessions = engine.sessions
        let id = sessionDocId
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.engine.perform { try await sessions.watch(id) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        scheduleMarkRead(force: true)
    }

    func disappear() {
        isVisible = false
        watchTask?.cancel()
        watchTask = nil
        saveDraftNow()
    }

    /// Called when the screen is gone for good.
    func tearDown() {
        disappear()
        revealTicker?.cancel()
        detail.stop()
        commands.stop()
        for page in pages { page.query.stop() }
    }

    private func makePage(cursor: String?) -> TranscriptPage {
        let sessions = engine.sessions
        let id = sessionDocId
        let size = Self.pageSize
        let page = TranscriptPage(cursor: cursor) { [weak self] cursor, endCursor in
            let query = LiveQuery<EventsPage>(engine: self?.engine) {
                sessions.events(id, cursor: cursor, endCursor: endCursor, numItems: size)
            }
            query.onValue = { [weak self] _ in self?.pagesChanged() }
            return query
        }
        return page
    }

    // MARK: Paging

    /// Loads the next older page (scrolled to the top of the transcript).
    func loadOlder() {
        guard hasOlder, !isLoadingOlder, let last = pages.last, let value = last.query.value else { return }
        isLoadingOlder = true
        last.pin(to: value.continueCursor)
        let older = makePage(cursor: value.continueCursor)
        pages.append(older)
        older.query.start()
    }

    private func pagesChanged() {
        let previous = events
        let wasLoadingOlder = isLoadingOlder
        var merged: [DocID: TranscriptEvent] = [:]
        for page in pages {
            for event in page.query.value?.page ?? [] { merged[event.id] = event }
        }
        events = merged
        if let last = pages.last, let value = last.query.value {
            hasOlder = !value.isDone
            isLoadingOlder = false
        }
        let firstLoad = !initialLoaded && pages.first?.query.value != nil
        if initialLoaded {
            trackChanges(from: previous, to: merged, olderPageLoad: wasLoadingOlder)
        }
        if firstLoad { initialLoaded = true }
        engine.pruneLocalPrompts(in: sessionDocId, deliveredCommandIds: Set(merged.values.compactMap(\.commandId)))
        rebuild()
    }

    /// New items while scrolled up bump the counter; growing assistant text gets a reveal pacer.
    private func trackChanges(
        from previous: [DocID: TranscriptEvent], to current: [DocID: TranscriptEvent], olderPageLoad: Bool
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        let newIds = current.keys.filter { previous[$0] == nil }
        if !isAtBottom && !olderPageLoad {
            let newest = previous.values.map(\.seq).max() ?? 0
            newWhileAway += newIds.filter { (current[$0]?.seq ?? 0) > newest }.count
        }
        let latestAssistant = current.values.filter { $0.kind == .assistant }.max(by: { $0.seq < $1.seq })?.id
        for event in current.values where event.kind == .assistant {
            let oldLength = previous[event.id]?.text.count
            let newLength = event.text.count
            if let oldLength, newLength > oldLength {
                var pacer = pacers[event.id] ?? TextRevealPacer(shown: oldLength, length: oldLength)
                pacer.receive(length: newLength, at: now)
                pacers[event.id] = pacer
                revealing.insert(event.id)
                startRevealTicker()
            } else if oldLength == nil, !olderPageLoad, event.id == latestAssistant, newLength > 0 {
                var pacer = TextRevealPacer(shown: 0, length: 0)
                pacer.receive(length: newLength, at: now)
                pacers[event.id] = pacer
                revealing.insert(event.id)
                startRevealTicker()
            }
        }
        // A reply is complete once something newer follows it.
        for id in pacers.keys where id != latestAssistant {
            finishReveal(id, at: now)
        }
        if detail.value?.isRunning == false { finishAllReveals() }
    }

    // MARK: Following the bottom

    /// The bottom sentinel appeared or disappeared.
    func bottomVisibility(_ visible: Bool) {
        isAtBottom = visible
        if visible || bottomSeenAt != .distantPast { bottomSeenAt = Date() }
    }

    /// The person dragged the transcript down (to read older items): stop following the bottom.
    func userScrolledUp() {
        bottomSeenAt = .distantPast
    }

    /// Follow the bottom: it is on screen, or it was until content pushed it off a moment ago.
    var shouldFollowBottom: Bool {
        isAtBottom || Date().timeIntervalSince(bottomSeenAt) < 1.0
    }

    private func startRevealTicker() {
        guard revealTicker == nil else { return }
        revealTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.revealing.isEmpty else { break }
                self.contentTick &+= 1
                try? await Task.sleep(for: .milliseconds(120))
            }
            self?.revealTicker = nil
        }
    }

    // MARK: Reveal

    /// The part of an assistant reply to show at `time`.
    func revealedText(_ id: DocID, full: String, at time: Date) -> String {
        guard var pacer = pacers[id] else { return full }
        if full.count != pacer.length { pacer.receive(length: full.count, at: time.timeIntervalSinceReferenceDate) }
        let count = pacer.advance(to: time.timeIntervalSinceReferenceDate)
        pacers[id] = pacer
        return count >= full.count ? full : String(full.prefix(count))
    }

    private func finishReveal(_ id: DocID, at time: Double) {
        guard var pacer = pacers[id], !pacer.isFinishing else { return }
        pacer.finish(at: time)
        pacers[id] = pacer
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(TextRevealPacer.finishWindow + 0.1))
            self?.pacers[id] = nil
            self?.revealing.remove(id)
        }
    }

    private func finishAllReveals() {
        let now = Date().timeIntervalSinceReferenceDate
        for id in pacers.keys { finishReveal(id, at: now) }
    }

    // MARK: Session

    private func detailChanged(_ value: SessionDetail) {
        if !value.isRunning { finishAllReveals() }
        if value.unreadCount > 0 { scheduleMarkRead(force: false) }
        if let answering = answeringRequestId, value.pending?.id != answering { answeringRequestId = nil }
    }

    private func scheduleMarkRead(force: Bool) {
        guard isVisible else { return }
        guard force || (detail.value?.unreadCount ?? 0) > 0 else { return }
        markReadTask?.cancel()
        let sessions = engine.sessions
        let id = sessionDocId
        markReadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(force ? 300 : 800))
            guard !Task.isCancelled, let self, self.isVisible else { return }
            _ = await self.engine.perform { try await sessions.markRead(id) }
        }
    }

    /// Rebuilds the transcript items from events, prompt commands and this phone's optimistic prompts.
    func rebuild() {
        let built = TranscriptBuilder.build(
            events: Array(events.values), commands: commands.value ?? [],
            local: engine.localPrompts[sessionDocId] ?? [], hasOlder: hasOlder)
        guard built != items else { return }
        items = built
        contentTick &+= 1
    }

    var title: String {
        detail.value?.title ?? engine.sessionRow(sessionDocId)?.title ?? ""
    }

    var computerName: String {
        detail.value?.deviceName ?? engine.sessionRow(sessionDocId)?.deviceName ?? ""
    }

    /// A crok process runs the session now.
    var isOnline: Bool {
        detail.value?.online ?? engine.sessionRow(sessionDocId)?.online ?? false
    }

    var isRunning: Bool {
        detail.value?.isRunning ?? engine.sessionRow(sessionDocId)?.isRunning ?? false
    }

    var status: SessionStatus {
        detail.value?.status ?? engine.sessionRow(sessionDocId)?.status ?? .idle
    }

    /// What the header says: offline only while the computer is.
    var presence: SessionPresence {
        SessionPresence(online: isOnline, deviceOnline: isComputerOnline, status: status)
    }

    var plan: [PlanEntry] { detail.value?.plan ?? [] }

    var isRemoved: Bool { detail.error?.code == .notFound }

    /// Whether the session's computer is connected (another crok there can fetch a listed session's history).
    var isComputerOnline: Bool {
        detail.value?.deviceOnline ?? engine.sessionRow(sessionDocId)?.deviceOnline ?? false
    }

    /// The composer takes prompts whenever the computer is online, whether or not a crok runs the session: one there
    /// opens it when the prompt arrives (`commands:sendPrompt` is `OFFLINE` only for an offline computer).
    var canSendPrompts: Bool { !isRemoved && isComputerOnline }

    /// The permission request the card above the composer shows: one the running session waits on.
    var pendingRequest: PendingInteraction? {
        guard let detail = detail.value, detail.online else { return nil }
        return detail.pending
    }

    /// This phone answered the request shown and the computer has not taken the answer yet.
    var isAnsweringRequest: Bool {
        answeringRequestId != nil && answeringRequestId == pendingRequest?.id
    }

    var historyState: HistoryState? {
        detail.value?.historyState ?? engine.sessionRow(sessionDocId)?.historyState
    }

    /// A session listed from the computer's disk whose transcript has not reached the relay: the screen says it is
    /// loading from the computer (`watch` asked for it), or that the computer is offline.
    var awaitsHistory: Bool {
        !isRemoved && items.isEmpty && (historyState?.isOnComputerOnly ?? false)
    }

    // MARK: Actions

    func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, canSendPrompts else { return }
        engine.sendPrompt(text, to: sessionDocId)
        bottomSeenAt = Date()
        draft = ""
        saveDraftNow()
        rebuild()
    }

    func stop() async {
        actionError = await engine.stopTurn(sessionDocId)
    }

    /// Answers the pending request with one of its options. The buttons stay disabled until the computer takes an
    /// answer; `EXPIRED` (another device or the computer answered first) is not worth an alert, the card just goes.
    func answer(_ option: PendingOption, to request: PendingInteraction) async {
        guard answeringRequestId == nil else { return }
        answeringRequestId = request.id
        guard let error = await engine.answer(sessionDocId, interactionId: request.id, optionId: option.optionId) else {
            return
        }
        if answeringRequestId == request.id { answeringRequestId = nil }
        if error.code != .expired { actionError = error }
    }

    func retry(_ message: UserMessage) async {
        actionError = await engine.retryPrompt(message, in: sessionDocId)
        rebuild()
    }

    func discard(_ message: UserMessage) async {
        actionError = await engine.discardPrompt(message, in: sessionDocId)
        rebuild()
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        draftTask?.cancel()
        engine.drafts.setDraft(draft, for: sessionDocId)
    }
}
