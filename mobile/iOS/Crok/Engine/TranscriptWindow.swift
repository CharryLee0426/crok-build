import Foundation

/// The loaded part of a session's transcript as a window of live parts over `sessions:transcript` (relay/DESIGN.md §3,
/// "Loading long transcripts"): it opens on the newest items, keeps a live end that grows as items arrive and splits
/// before it gets long, and loads older parts on demand. The relay re-sends a part whenever an item in it changes, so a
/// streamed reply costs only the live end, however long the session is.
@MainActor
final class TranscriptWindow {
    /// Items the window opens on.
    static var openLimit: Int { pageSizeOverride ?? 40 }
    /// Items one older part asks for.
    static var olderLimit: Int { pageSizeOverride ?? 60 }
    /// What one live or fixed part holds at most (the relay's own limit).
    static let partLimit = 200
    /// The live end splits beyond this many items (keeping `openLimit`), or beyond `splitText` characters of text.
    static var splitCount: Int { 2 * openLimit }
    static let splitText = 200_000

    /// `-CrokPageSize 8` makes the parts small, to try paging and splitting with the demo data.
    private static var pageSizeOverride: Int? {
        let value = UserDefaults.standard.integer(forKey: "CrokPageSize")
        return value > 0 ? value : nil
    }

    @MainActor
    final class Part {
        enum Role {
            /// The newest items, until the first answer fixes where the live end starts (or, while the session is
            /// empty, the live end itself).
            case opening
            /// Everything from a seq on, growing as items arrive.
            case live
            /// A range split off the live end.
            case fixed
            /// A range below everything loaded, asked for on reaching the top.
            case older
        }

        let range: TranscriptRange
        let role: Role
        let query: LiveQuery<TranscriptChunk>
        /// It has answered with items before (an empty answer then means the transcript was replaced).
        var hadEvents = false

        init(range: TranscriptRange, role: Role, query: LiveQuery<TranscriptChunk>) {
            self.range = range
            self.role = role
            self.query = query
        }

        var chunk: TranscriptChunk? { query.value }
    }

    private weak var engine: CrokEngine?
    private let make: @MainActor (TranscriptRange) -> RelayStream<TranscriptChunk>
    /// Newest first: the live end (or the opening part), parts split off it, then older parts.
    private(set) var parts: [Part] = []
    /// Parts still shown until all of `replacing` have answered (a split, the opening's hand-over, a restart).
    private(set) var retiring: [Part] = []
    private var replacing: [Part] = []
    /// Items exist below the oldest loaded part.
    private(set) var hasOlder = false
    /// The first answer has arrived.
    private(set) var loaded = false
    /// Times the window started over (tests).
    private(set) var restarts = 0
    /// `loadOlder` was asked while it could not start; it starts once the parts settle.
    private var wantsOlder = false
    /// Called after any part answered.
    var onChange: (@MainActor () -> Void)?

    init(engine: CrokEngine?, make: @escaping @MainActor (TranscriptRange) -> RelayStream<TranscriptChunk>) {
        self.engine = engine
        self.make = make
    }

    func start() {
        guard parts.isEmpty else { return }
        let opening = makePart(TranscriptRange(limit: Self.openLimit), .opening)
        parts = [opening]
        opening.query.start()
    }

    func stop() {
        for part in parts + retiring { part.query.stop() }
        parts = []
        retiring = []
        replacing = []
    }

    /// An older part is on its way.
    var isLoadingOlder: Bool {
        guard let last = parts.last else { return false }
        return last.role == .older && last.chunk == nil
    }

    /// Every item shown, by id: the retiring parts' first, so the parts replacing them win.
    var events: [DocID: TranscriptEvent] {
        var merged: [DocID: TranscriptEvent] = [:]
        for part in retiring + parts.reversed() {
            for event in part.chunk?.events ?? [] { merged[event.id] = event }
        }
        return merged
    }

    /// Asks for the next older part (the transcript's top came into view). Asked while parts are being replaced, it
    /// happens once they have answered.
    func loadOlder() {
        guard hasOlder, !isLoadingOlder else { return }
        guard replacing.isEmpty, let oldest = parts.last?.chunk?.events.map(\.seq).min() else {
            wantsOlder = true
            return
        }
        wantsOlder = false
        let older = makePart(TranscriptRange(throughSeq: oldest - 1, limit: Self.olderLimit), .older)
        parts.append(older)
        older.query.start()
    }

    private func makePart(_ range: TranscriptRange, _ role: Part.Role) -> Part {
        let make = self.make
        let query = LiveQuery<TranscriptChunk>(engine: engine) { make(range) }
        let part = Part(range: range, role: role, query: query)
        query.onValue = { [weak self, weak part] _ in
            guard let self, let part else { return }
            self.answered(part)
        }
        return part
    }

    private func answered(_ part: Part) {
        defer {
            if wantsOlder { loadOlder() }
            onChange?()
        }
        guard parts.contains(where: { $0 === part }), let chunk = part.chunk else { return }
        let hadEvents = part.hadEvents
        if !chunk.events.isEmpty { part.hadEvents = true }
        loaded = true
        settleReplacement()
        switch part.role {
        case .opening:
            hasOlder = chunk.more
            guard let lowest = chunk.events.map(\.seq).min() else { return }
            // The live end starts at the oldest item shown; the opening part shows until it answers.
            let live = makePart(TranscriptRange(afterSeq: lowest - 1, limit: Self.partLimit), .live)
            replace([part], with: [live])
        case .live:
            if chunk.more {
                // More arrived than it holds (the phone slept through a busy turn): start again from the newest.
                restart()
                return
            }
            splitIfLong(part)
        case .fixed, .older:
            if hadEvents && chunk.events.isEmpty {
                // The computer replaced the transcript (a resync): its old items are gone.
                restart()
                return
            }
            if part === parts.last { hasOlder = chunk.more }
        }
    }

    /// Once every part of a replacement has answered, the parts it replaces go.
    private func settleReplacement() {
        guard !replacing.isEmpty, replacing.allSatisfy({ $0.chunk != nil }) else { return }
        for part in retiring { part.query.stop() }
        retiring = []
        replacing = []
    }

    /// Swaps `old` (adjacent parts) for `new` in place; `old` keeps showing until all of `new` have answered.
    private func replace(_ old: [Part], with new: [Part]) {
        guard let index = parts.firstIndex(where: { $0 === old.first }) else { return }
        parts.replaceSubrange(index..<(index + old.count), with: new)
        retiring += old
        replacing += new
        for part in new { part.query.start() }
    }

    /// The live end holds too much to re-send on every change: the newest part of it stays live, the rest becomes a
    /// fixed part.
    private func splitIfLong(_ live: Part) {
        guard replacing.isEmpty, let events = live.chunk?.events.sorted(by: { $0.seq > $1.seq }), events.count >= 2
        else { return }
        let text = events.reduce(0) { $0 + $1.text.utf16.count }
        var keep: Int
        if events.count > Self.splitCount {
            keep = Self.openLimit
        } else if text > Self.splitText {
            // Half the text stays live.
            keep = 0
            var kept = 0
            while keep < events.count - 1, kept < text / 2 {
                kept += events[keep].text.utf16.count
                keep += 1
            }
        } else {
            return
        }
        keep = min(max(keep, 1), events.count - 1)
        let start = events[keep - 1].seq
        let newLive = makePart(TranscriptRange(afterSeq: start - 1, limit: Self.partLimit), .live)
        let fixed = makePart(
            TranscriptRange(afterSeq: live.range.afterSeq, throughSeq: start - 1, limit: Self.partLimit), .fixed)
        replace([live], with: [newLive, fixed])
    }

    /// Starts again from the newest items; everything loaded shows until they arrive.
    private func restart() {
        restarts += 1
        let opening = makePart(TranscriptRange(limit: Self.openLimit), .opening)
        retiring += parts
        replacing = [opening]
        parts = [opening]
        opening.query.start()
    }
}
