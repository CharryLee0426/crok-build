import Foundation
import Observation

/// The session screen's state: header, plan, transcript (paged, bottom-anchored), prompt ticks, streaming reveal,
/// composer draft and its slash commands (the Menu, `/model` and `/think` bot cards), the model and thinking-level pills
/// above the composer, and the `watch` / `markRead` bookkeeping.
@MainActor
@Observable
final class SessionViewModel {
    let sessionDocId: DocID
    let engine: CrokEngine
    let detail: LiveQuery<SessionDetail>
    let commands: LiveQuery<[PromptCommand]>
    /// The session's own slash commands (`sessions:commands`), after the phone's.
    let slashCommands: LiveQuery<SlashCommandList>
    /// `/model` and `/think` answers in the transcript, on this phone only.
    private(set) var botCards: [BotCard] = []
    /// The command list was opened with the Menu button (it also opens on its own for a typed `/`).
    private(set) var menuOpen = false
    /// The info sheet (the header, the ⓘ button, or `/info`).
    var showsInfo = false
    /// What the session's computer can run (`devices:models`), watched while the screen is open; made once the
    /// computer is known.
    private(set) var modelQuery: LiveQuery<[ModelChoice]?>?
    /// A model or thinking-level change from the pills or Session info: on its way, then shown until the session
    /// reports it.
    private(set) var modelChange: ConfigChange?
    private(set) var effortChange: ConfigChange?
    /// "Couldn't change the model" / "Couldn't change the thinking level".
    var configFailure: ConfigFailure?
    /// Choose a Model (the model pill).
    var showsModelPicker = false
    /// The dimmed model pill's explanation: the computer's crok publishes no list.
    var showsNotOffered = false

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
    /// The transcript follows its end (no scroll-to-bottom button). iOS 18+: `follower.follows`; iOS 17: the bottom
    /// sentinel is on screen.
    var isAtBottom = true {
        didSet { if isAtBottom { newWhileAway = 0 } }
    }
    /// Bumped whenever the transcript's content grows (new items, or a revealing reply getting longer), so the view
    /// can keep the bottom in sight.
    private(set) var contentTick = 0 {
        didSet {
            follower.contentChanged()
            blankRepairs = 0
        }
    }
    /// Bumped when the view should put the transcript's end back in sight at once (iOS 18+: something moved the end
    /// while following, or the view rests past it).
    private(set) var pinTick = 0
    var draft: String {
        didSet {
            scheduleDraftSave()
            // Typing a message (not a command) closes the menu, as in Telegram.
            if menuOpen && !draft.isEmpty && CommandMenu.typedName(in: draft) == nil { menuOpen = false }
        }
    }

    /// The loaded part of the transcript (`sessions:transcript`), made on first appearance.
    @ObservationIgnored private(set) var window: TranscriptWindow?
    @ObservationIgnored private var events: [DocID: TranscriptEvent] = [:]
    @ObservationIgnored private var pacers: [DocID: TextRevealPacer] = [:]
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    /// iOS 17: when the bottom of the transcript was last on screen; `.distantPast` once the person scrolls up.
    @ObservationIgnored private var bottomSeenAt = Date()
    /// iOS 18+: whether the transcript follows its end, from the scroll view's geometry and phase.
    @ObservationIgnored private var follower = BottomFollower()
    /// The scroll view reports its geometry (iOS 18+), so the follower decides.
    @ObservationIgnored private var tracksGeometry = false
    /// iOS 18+: what the blank-stretch check compares (`scheduleBlankCheck`).
    @ObservationIgnored private var contentOverflows = false
    @ObservationIgnored private var sentinelBottom: Double?
    @ObservationIgnored private var visibleBottom: Double?
    @ObservationIgnored private var blankCheck: Task<Void, Never>?
    /// Ends the button's or a send's scroll animation for the follower if the scroll phase never does.
    @ObservationIgnored private var followAnimation: Task<Void, Never>?
    /// Blank-stretch repairs since the content last changed or the person last scrolled.
    @ObservationIgnored private var blankRepairs = 0
    private static let maxBlankRepairs = 3
    @ObservationIgnored private var revealTicker: Task<Void, Never>?
    /// The config commands bot cards wait on, by card id.
    @ObservationIgnored private var configWatches: [String: LiveQuery<CommandRecord?>] = [:]
    /// Opens a new session in this session's project (`/new`); the screen wires it to navigation.
    @ObservationIgnored var onNewSession: ((NewSessionTarget, String?) -> Void)?

    init(sessionDocId: DocID, engine: CrokEngine) {
        self.sessionDocId = sessionDocId
        self.engine = engine
        let sessions = engine.sessions
        let commandsAPI = engine.commands
        detail = LiveQuery(engine: engine) { sessions.get(sessionDocId) }
        commands = LiveQuery(engine: engine) { commandsAPI.forSession(sessionDocId) }
        slashCommands = LiveQuery(engine: engine) { sessions.slashCommands(sessionDocId) }
        draft = engine.drafts.draft(for: sessionDocId)
    }

    // MARK: Lifecycle

    func appear() {
        guard !isVisible else { return }
        isVisible = true
        if window == nil {
            detail.onValue = { [weak self] value in self?.detailChanged(value) }
            commands.onValue = { [weak self] _ in self?.rebuild() }
            detail.start()
            commands.start()
            slashCommands.start()
            watchModels(of: engine.sessionRow(sessionDocId)?.deviceId)
            let sessions = engine.sessions
            let id = sessionDocId
            let window = TranscriptWindow(engine: engine) { range in sessions.transcript(id, range: range) }
            window.onChange = { [weak self] in self?.windowChanged() }
            self.window = window
            window.start()
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
        blankCheck?.cancel()
        followAnimation?.cancel()
        detail.stop()
        commands.stop()
        slashCommands.stop()
        modelQuery?.stop()
        for watch in configWatches.values { watch.stop() }
        configWatches.removeAll()
        window?.stop()
    }

    // MARK: Paging

    /// Loads the next older part (scrolled to the top of the transcript).
    func loadOlder() {
        guard let window, hasOlder, !isLoadingOlder else { return }
        window.loadOlder()
        isLoadingOlder = window.isLoadingOlder
    }

    private func windowChanged() {
        guard let window else { return }
        let previous = events
        let wasLoadingOlder = isLoadingOlder
        let merged = window.events
        events = merged
        hasOlder = window.hasOlder
        isLoadingOlder = window.isLoadingOlder
        let firstLoad = !initialLoaded && window.loaded
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

    /// iOS 18+: the scroll view's geometry moved (`distance`: how far the transcript's end is below the visible bottom
    /// edge, 0 when it all fits; `overflows`: the content is taller than the visible area).
    func scrollGeometryChanged(distanceFromBottom distance: Double, overflows: Bool) {
        tracksGeometry = true
        contentOverflows = overflows
        applyFollower(pin: follower.geometryChanged(distance: distance))
        scheduleBlankCheck()
    }

    /// iOS 18+: the person started or stopped moving the transcript, or a programmatic scroll started or ended.
    func scrollPhaseChanged(_ phase: BottomFollower.Phase) {
        tracksGeometry = true
        if phase == .user { blankRepairs = 0 }
        applyFollower(pin: follower.phaseChanged(phase))
        scheduleBlankCheck()
    }

    /// iOS 18+: where the last row really ends on screen (global y, the bottom sentinel plus the stack's bottom
    /// padding), or nil while the lazy stack has no sentinel.
    func sentinelMoved(to y: Double?) {
        sentinelBottom = y
        scheduleBlankCheck()
    }

    /// iOS 18+: where the visible part of the transcript ends on screen (global y): the composer's top.
    func visibleBottomMoved(to y: Double) {
        visibleBottom = y
        scheduleBlankCheck()
    }

    /// The lazy stack can come to rest with its estimated height taller than its rows: the scroll view sits at the end
    /// of the estimate, which its geometry reports as the end, with a blank stretch under the last row until a touch
    /// makes it measure again. Once nothing has moved for a moment, put the real end back at the bottom.
    private func scheduleBlankCheck() {
        blankCheck?.cancel()
        guard showsBlankStretch, blankRepairs < Self.maxBlankRepairs else { return }
        blankCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.showsBlankStretch else { return }
            self.blankRepairs += 1
            self.pinTick &+= 1
        }
    }

    /// Content taller than the screen, at rest, and the last row's end on screen well above the composer.
    private var showsBlankStretch: Bool {
        guard follower.phase == .idle, contentOverflows, let sentinelBottom, let visibleBottom else { return false }
        return visibleBottom - sentinelBottom > BottomFollower.slop
    }

    /// iOS 18+: the whole transcript fits the visible area. `defaultScrollAnchor(.bottom)` keeps such a transcript at
    /// the bottom by itself; a `scrollTo` can then only move it away (toward a row the lazy stack has not measured yet
    /// it lands under the composer, where the geometry still reads "all in sight", so nothing brings it back until a
    /// touch: the first prompt of a session "disappeared"). The view scrolls only a transcript taller than the screen.
    var contentFits: Bool { tracksGeometry && !contentOverflows }

    /// The scroll-to-bottom button or a send is taking the transcript to its end: follow it from now on. `scrolling`:
    /// the view animates to the end (not when the transcript fits).
    func followBottom(scrolling: Bool = true) {
        guard tracksGeometry else { return }
        follower.follow()
        guard scrolling else {
            applyFollower(pin: follower.animationEnded())
            return
        }
        applyFollower(pin: false)
        followAnimation?.cancel()
        followAnimation = Task { [weak self] in
            // The scroll phase may never report the animation's end.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.applyFollower(pin: self.follower.animationEnded())
            self.scheduleBlankCheck()
        }
    }

    private func applyFollower(pin: Bool) {
        if isAtBottom != follower.follows { isAtBottom = follower.follows }
        if pin { pinTick &+= 1 }
    }

    /// iOS 17: the bottom sentinel appeared or disappeared.
    func bottomVisibility(_ visible: Bool) {
        isAtBottom = visible
        if visible || bottomSeenAt != .distantPast { bottomSeenAt = Date() }
    }

    /// iOS 17: the person dragged the transcript down (to read older items): stop following the bottom.
    func userScrolledUp() {
        bottomSeenAt = .distantPast
    }

    /// Follow the bottom. iOS 18+: the follower says so. iOS 17: the sentinel is on screen, or was until content pushed
    /// it off a moment ago.
    var shouldFollowBottom: Bool {
        tracksGeometry ? follower.follows : isAtBottom || Date().timeIntervalSince(bottomSeenAt) < 1.0
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

    /// The part of an assistant reply to show at `time`. A long reply grows in steps of a hundredth of its length, so
    /// the frames between steps show a text the Markdown cache has parsed already (each new prefix is a full parse).
    func revealedText(_ id: DocID, full: String, at time: Date) -> String {
        guard var pacer = pacers[id] else { return full }
        if full.count != pacer.length { pacer.receive(length: full.count, at: time.timeIntervalSinceReferenceDate) }
        var count = pacer.advance(to: time.timeIntervalSinceReferenceDate)
        pacers[id] = pacer
        if count >= full.count { return full }
        count = Self.revealStep(count, of: full.count)
        return String(full.prefix(count))
    }

    /// Replies up to this long reveal character by character.
    static let smoothRevealLength = 2_000

    /// `count` rounded down to a step of the reveal: itself for short replies, a hundredth of the length for long ones.
    static func revealStep(_ count: Int, of length: Int) -> Int {
        guard length > smoothRevealLength else { return count }
        let step = length / 100
        return count - count % step
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
        watchModels(of: value.deviceId)
        settleConfigChanges(value)
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
            local: engine.localPrompts[sessionDocId] ?? [], hasOlder: hasOlder, cards: botCards)
        let start = events.values.filter { $0.kind == .user || ($0.kind == .system && $0.status != nil) }.map(\.seq).max()
        if start != turnStartSeq { turnStartSeq = start }
        guard built != items else { return }
        items = built
        contentTick &+= 1
    }

    /// Where the running turn began: its prompt, or the last turn's end marker. A tool call before it belongs to an
    /// ended turn and shows "stopped", not a spinner, whatever runs now.
    private(set) var turnStartSeq: Double?

    /// A tool call at `seq` is part of a turn that still runs.
    func toolRuns(at seq: Double?) -> Bool {
        guard isTurnActive else { return false }
        guard let start = turnStartSeq, let seq else { return true }
        return seq > start
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

    /// The turn is still going: running, or waiting on a permission request (a tool call in it is still running).
    var isTurnActive: Bool { isOnline && (status == .running || status == .waiting) }

    /// The thought shown as "Thinking…": the transcript's newest event while the turn runs.
    var activeThoughtID: String? {
        guard isTurnActive, let newest = items.last(where: { $0.seq != nil }), case .thought = newest.kind else {
            return nil
        }
        return newest.id
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

    /// Made by `sessions:create` and not open on its computer yet.
    var isStarting: Bool {
        detail.value?.isStarting ?? engine.sessionRow(sessionDocId)?.isStarting ?? false
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

    /// Sends the draft: a phone command (`/new`, `/model`, `/think`, `/stop`, `/info`) is handled here; anything else,
    /// the session's commands (`/compact`) and unknown ones alike, goes to the computer as a prompt.
    func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, canSendPrompts else { return }
        menuOpen = false
        if let command = ComposerCommand.parse(text), let device = command.deviceCommand {
            draft = ""
            saveDraftNow()
            run(device, argument: command.argument)
            return
        }
        engine.sendPrompt(text, to: sessionDocId)
        bottomSeenAt = Date()
        draft = ""
        saveDraftNow()
        rebuild()
    }

    /// Send is enabled: the field has text (a command, or a prompt).
    var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Commands

    /// The phone's commands this session allows: `/think` only when its model has thinking levels (or the relay
    /// cannot say), `/stop` only while a turn runs.
    private var allowedDeviceCommands: [DeviceCommand] {
        let thinking: Bool? = models == nil ? nil : !(currentModel?.efforts.isEmpty ?? true)
        return CommandMenu.deviceCommands(isRunning: isRunning, modelHasThinking: thinking)
    }

    /// The phone's commands this session allows, then the session's.
    var availableCommands: [CommandMenuItem] {
        CommandMenu.items(device: allowedDeviceCommands, session: slashCommands.value?.commands ?? [])
    }

    /// The command list above the composer: what matches a typed `/name`, else everything after Menu.
    var commandMenuItems: [CommandMenuItem] {
        guard canSendPrompts else { return [] }
        if let typed = CommandMenu.typedName(in: draft) {
            return CommandMenu.items(device: allowedDeviceCommands, session: slashCommands.value?.commands ?? [], filter: typed)
        }
        return menuOpen && draft.isEmpty ? availableCommands : []
    }

    /// The Menu pill: opens the list, or closes it (also one a typed `/` opened).
    func toggleMenu() {
        if commandMenuItems.isEmpty {
            menuOpen = true
        } else {
            menuOpen = false
            if CommandMenu.typedName(in: draft) != nil { draft = "" }
        }
    }

    /// A row of the command list: one that takes arguments fills the field for the rest; others are sent at once.
    func pick(_ item: CommandMenuItem) {
        menuOpen = false
        if item.takesArgument {
            draft = "/\(item.name) "
            return
        }
        draft = "/\(item.name)"
        send()
    }

    private func run(_ command: DeviceCommand, argument: String) {
        switch command {
        case .new:
            guard let target = newSessionTarget else { return }
            onNewSession?(target, argument.isEmpty ? nil : argument)
        case .model:
            ask(.model, argument: argument)
        case .think:
            ask(.think, argument: argument)
        case .stop:
            Task { await stop() }
        case .info:
            showsInfo = true
        }
    }

    /// Where `/new` starts a session: this session's project on its computer.
    var newSessionTarget: NewSessionTarget? {
        if let detail = detail.value {
            return NewSessionTarget(
                deviceId: detail.deviceId, deviceName: detail.deviceName, path: detail.projectPath ?? detail.cwd)
        }
        guard let row = engine.sessionRow(sessionDocId) else { return nil }
        return NewSessionTarget(deviceId: row.deviceId, deviceName: row.deviceName, path: row.projectPath ?? row.cwd)
    }

    /// What a bot card offers now.
    func choices(for card: BotCard) -> BotChoices {
        BotChoices.make(
            card.kind, models: models, detail: detail.value, computerName: computerName, computerOnline: isComputerOnline)
    }

    /// `/model` or `/think`: without an argument a card with the choices; with one, the matching choice is applied at
    /// once (the card shows it done), or the card says nothing matched.
    private func ask(_ kind: BotCard.Kind, argument: String) {
        var card = BotCard(kind: kind)
        bottomSeenAt = Date()
        if !argument.isEmpty, case .choices = choices(for: card) {
            switch match(argument, kind) {
            case .one(let id):
                botCards.append(card)
                apply(id, on: card.id)
                rebuild()
                return
            case .none:
                card.state = .choosing(note: kind == .model
                    ? String(localized: "No model matches “\(argument)”.")
                    : String(localized: "No thinking level matches “\(argument)”."))
            case .ambiguous:
                card.state = .choosing(note: String(localized: "“\(argument)” matches more than one. Pick one:"))
            }
        }
        botCards.append(card)
        rebuild()
    }

    private enum Matched { case one(String), none, ambiguous }

    private func match(_ argument: String, _ kind: BotCard.Kind) -> Matched {
        switch kind {
        case .model:
            switch ChoiceMatch.find(argument, in: models ?? [], keys: { [$0.id, $0.name] }) {
            case .one(let model): return .one(model.id)
            case .none: return .none
            case .ambiguous: return .ambiguous
            }
        case .think:
            let efforts = currentModel?.efforts ?? []
            switch ChoiceMatch.find(argument, in: efforts, keys: { [$0.id, $0.level, $0.name] }) {
            case .one(let effort): return .one(effort.id)
            case .none: return .none
            case .ambiguous: return .ambiguous
            }
        }
    }

    /// A tap on a card's button.
    func choose(_ choice: BotChoice, on card: BotCard) {
        guard !card.isApplying, !card.isDone else { return }
        apply(choice.id, on: card.id)
    }

    /// `commands:setConfig`, then the card follows the command (`commands:get`) until it is done or failed.
    private func apply(_ value: String, on cardId: String) {
        guard let index = botCards.firstIndex(where: { $0.id == cardId }) else { return }
        let kind = botCards[index].kind
        updateCard(cardId) { $0.state = .applying(choiceId: value) }
        sendConfig(kind == .model ? .model : .reasoningEffort, value, key: "card-" + cardId) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .done(let record):
                let chosen = kind == .model ? (record.result?.model ?? value) : (record.result?.effort ?? value)
                let label = BotChoices.name(of: chosen, kind, models: self.models, detail: self.detail.value)
                self.updateCard(cardId) { $0.state = .done(label: label) }
            case .failed(let message):
                self.updateCard(cardId) { $0.state = .failed(message: message) }
            }
        }
    }

    private enum ConfigOutcome {
        case done(CommandRecord)
        case failed(String)
    }

    /// `commands:setConfig`, then follows the command (`commands:get`, under `key`) until it is done or failed; a
    /// refusal from the relay (`INVALID`, `OFFLINE`) is a failure too.
    private func sendConfig(
        _ option: ConfigOption, _ value: String, key: String, _ ended: @escaping @MainActor (ConfigOutcome) -> Void
    ) {
        let commands = engine.commands
        let id = sessionDocId
        Task { [weak self] in
            do {
                let commandId = try await commands.setConfig(id, configId: option, value: value)
                self?.follow(commandId, key: key, ended)
            } catch {
                guard let self else { return }
                let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
                if relayError.isRevoked { self.engine.handleRevoked() }
                if relayError.code == .unauthenticated { self.engine.handleUnauthenticated() }
                ended(.failed(relayError.message))
            }
        }
    }

    private func follow(_ commandId: DocID, key: String, _ ended: @escaping @MainActor (ConfigOutcome) -> Void) {
        let commands = engine.commands
        let query = LiveQuery<CommandRecord?>(engine: engine) { commands.get(commandId) }
        query.onValue = { [weak self] record in
            guard let self, let record else { return }
            switch record.status {
            case .done:
                self.endWatch(key)
                ended(.done(record))
            case .failed:
                self.endWatch(key)
                ended(.failed(record.error ?? String(localized: "The computer couldn't change it.")))
            default:
                break
            }
        }
        configWatches[key]?.stop()
        configWatches[key] = query
        query.start()
    }

    private func endWatch(_ key: String) {
        configWatches[key]?.stop()
        configWatches[key] = nil
    }

    private func updateCard(_ id: String, _ change: (inout BotCard) -> Void) {
        guard let index = botCards.firstIndex(where: { $0.id == id }) else { return }
        change(&botCards[index])
        rebuild()
    }

    // MARK: Model and thinking level

    private func watchModels(of deviceId: DocID?) {
        guard modelQuery == nil, let deviceId, !deviceId.isEmpty else { return }
        let devices = engine.devices
        let query = LiveQuery<[ModelChoice]?>(engine: engine) { devices.models(deviceId) }
        modelQuery = query
        query.start()
    }

    /// The computer's list: `devices:models`, or `sessions:get`'s copy when that query fails (an older relay).
    var modelList: ModelList {
        ModelList.resolve(
            listed: modelQuery?.value, listFailed: modelQuery?.value == nil && modelQuery?.error != nil,
            fallback: detail.value?.models, fallbackLoaded: detail.value != nil)
    }

    /// The models this session's computer offers now; nil while it offers none (offline, an older crok, loading).
    var models: [ModelChoice]? { modelList.models }

    /// The model the session runs, among its computer's choices.
    var currentModel: ModelChoice? {
        guard let id = detail.value?.model else { return nil }
        return models?.first(where: { $0.id == id })
    }

    /// The pills above the input row; nil hides the row.
    var setupRow: ModelSetupRow? {
        ModelSetup.session(
            list: modelList, model: detail.value?.model ?? engine.sessionRow(sessionDocId)?.model,
            effort: detail.value?.effort, modelChange: modelChange, effortChange: effortChange,
            computerOnline: canSendPrompts, starting: isStarting)
    }

    /// The model pill: Choose a Model, or (an older crok there) why there is nothing to choose.
    func tapModelPill() {
        guard let row = setupRow, row.acceptsModelTaps else { return }
        if row.model.dimmed {
            showsNotOffered = true
        } else {
            showsModelPicker = true
        }
    }

    /// Choose a Model: `commands:setConfig({configId: "model"})`; the pill spins until the computer has applied it.
    func chooseModel(_ id: String) {
        guard let row = setupRow, row.acceptsModelTaps, !row.model.dimmed, id != row.modelId else { return }
        modelChange = ConfigChange(value: id)
        sendConfig(.model, id, key: "pill-model") { [weak self] outcome in self?.configEnded(.model, id, outcome) }
    }

    /// The thinking menu: `commands:setConfig({configId: "reasoning_effort", value: <option id>})`.
    func chooseLevel(_ id: String?) {
        guard let id, let row = setupRow, row.acceptsLevelTaps, id != row.levelId else { return }
        effortChange = ConfigChange(value: id)
        sendConfig(.reasoningEffort, id, key: "pill-effort") { [weak self] outcome in
            self?.configEnded(.reasoningEffort, id, outcome)
        }
    }

    private func configEnded(_ option: ConfigOption, _ value: String, _ outcome: ConfigOutcome) {
        switch outcome {
        case .done(let record):
            var change = ConfigChange(value: value, done: true)
            if option == .model, let applied = record.result?.model, !applied.isEmpty { change.value = applied }
            if option == .model { modelChange = change } else { effortChange = change }
            if let detail = detail.value { settleConfigChanges(detail) }
            // Shown until the session reports it, a few seconds at most (it may report something else).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if option == .model, self.modelChange == change { self.modelChange = nil }
                if option == .reasoningEffort, self.effortChange == change { self.effortChange = nil }
            }
        case .failed(let message):
            if option == .model { modelChange = nil } else { effortChange = nil }
            configFailure = ConfigFailure(option: option, message: message)
        }
    }

    /// Drops a done change once the session shows it.
    private func settleConfigChanges(_ detail: SessionDetail) {
        if let change = modelChange, change.done, detail.model == change.value { modelChange = nil }
        if let change = effortChange, change.done {
            let model = models?.first(where: { $0.id == detail.model })
            let level = model?.efforts.first(where: { $0.id == change.value })?.level ?? change.value
            if detail.effort == level || detail.effort == change.value { effortChange = nil }
        }
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
