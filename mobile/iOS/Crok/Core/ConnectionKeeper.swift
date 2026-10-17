import Foundation

/// Keeps a phone's link to the relay alive (relay/DESIGN.md §5 "Staying connected"). A phone's WebSocket dies when the
/// app is suspended or the network changes, and ConvexMobile does not always recover on its own: its connect has no
/// timeout (a socket can stay "connecting" for good, and every query and mutation waits behind it), and on reconnect
/// it keeps the old access token when a refresh fails. So, on returning to the foreground, on the network coming back
/// (or switching), and whenever nothing has synced for 20 s while the network is up, the app refreshes the access
/// token and pushes it (a live socket answers with fresh query results); if nothing syncs within 10 s, it replaces the
/// Convex client. `UNAUTHENTICATED` from a query refreshes and replaces at once (at most every 15 s).
///
/// A pure state machine: the engine feeds it events with the time, runs the actions it returns, and reports when they
/// finish. "Synced" means query results arrived over the socket, not from a cache or a replay.
struct ConnectionKeeper: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Refresh the access token and hand it to the live client; then call `refreshFinished`.
        case refreshToken
        /// Replace the Convex client (queries resubscribe on the new one); then call `replaceFinished`.
        case replaceClient
    }

    /// Why a recovery started.
    enum Trigger: Equatable, Sendable { case foreground, network, stalled, unauthenticated }

    /// Not synced for this long while the network is up: start a recovery.
    static let stallAfter: TimeInterval = 20
    /// After the token push, how long the socket has to sync before the client is replaced.
    static let syncWindow: TimeInterval = 10
    /// The least time between two client replacements asked for by `UNAUTHENTICATED`.
    static let minReplaceInterval: TimeInterval = 15

    private enum Phase: Equatable, Sendable {
        case watching
        case refreshing(replaceAfter: Bool)
        case probing(until: Date)
        case replacing
    }

    private(set) var networkAvailable = true
    private(set) var synced = false
    /// Recoveries pause while the app is in the background (it is about to be suspended anyway).
    private(set) var isActive = true
    private(set) var lastTrigger: Trigger?
    private var phase: Phase = .watching
    /// Since when nothing has synced: the watchdog's start.
    private var unsyncedSince: Date
    private var lastReplacedAt: Date?
    /// `UNAUTHENTICATED` asked for a new client that could not be made yet (too soon after the last, or no network).
    private var replaceWanted = false

    init(now: Date) {
        unsyncedSince = now
    }

    var isRecovering: Bool { phase != .watching }

    // MARK: Events

    mutating func networkChanged(available: Bool, now: Date) -> [Action] {
        let cameBack = available && !networkAvailable
        networkAvailable = available
        if !available {
            markUnsynced(now)
            return []
        }
        if cameBack {
            // The watchdog measures from here, not from when the network went away.
            unsyncedSince = now
            return recover(.network, now: now)
        }
        return []
    }

    /// The network switched (Wi-Fi to cellular, another Wi-Fi): a socket on the old path is dead.
    mutating func pathChanged(now: Date) -> [Action] {
        guard networkAvailable else { return [] }
        markUnsynced(now)
        return recover(.network, now: now)
    }

    /// Only a drop matters here: after a reconnect the socket counts as synced once results arrive.
    mutating func socketChanged(connected: Bool, now: Date) -> [Action] {
        if !connected { markUnsynced(now) }
        return []
    }

    /// Query results arrived over the socket.
    mutating func synced(now: Date) -> [Action] {
        synced = true
        if case .probing = phase { phase = .watching }
        return []
    }

    mutating func becameActive(now: Date) -> [Action] {
        isActive = true
        // What the screen shows may be stale: say "Updating…" until the socket proves itself.
        markUnsynced(now)
        unsyncedSince = now
        return recover(.foreground, now: now)
    }

    mutating func enteredBackground() {
        isActive = false
    }

    mutating func unauthenticated(now: Date) -> [Action] {
        markUnsynced(now)
        replaceWanted = true
        return recover(.unauthenticated, now: now)
    }

    /// Called about once a second: the watchdog, the sync window, and a replacement that had to wait.
    mutating func tick(now: Date) -> [Action] {
        switch phase {
        case .watching:
            guard isActive, networkAvailable else { return [] }
            if replaceWanted, canReplace(now: now) { return recover(.unauthenticated, now: now) }
            if !synced, now.timeIntervalSince(unsyncedSince) >= Self.stallAfter { return recover(.stalled, now: now) }
            return []
        case .probing(let until):
            if synced {
                phase = .watching
                return []
            }
            guard now >= until else { return [] }
            phase = .replacing
            return [.replaceClient]
        case .refreshing, .replacing:
            return []
        }
    }

    // MARK: Results

    mutating func refreshFinished(now: Date) -> [Action] {
        guard case .refreshing(let replaceAfter) = phase else { return [] }
        if replaceAfter && canReplace(now: now) {
            phase = .replacing
            return [.replaceClient]
        }
        if synced {
            phase = .watching
            return []
        }
        phase = .probing(until: now.addingTimeInterval(Self.syncWindow))
        return []
    }

    mutating func replaceFinished(now: Date) -> [Action] {
        guard phase == .replacing else { return [] }
        lastReplacedAt = now
        replaceWanted = false
        phase = .watching
        // A new client has synced nothing yet; the watchdog starts over.
        synced = false
        unsyncedSince = now
        return []
    }

    // MARK: Private

    private mutating func markUnsynced(_ now: Date) {
        guard synced else { return }
        synced = false
        unsyncedSince = now
    }

    private func canReplace(now: Date) -> Bool {
        guard let lastReplacedAt else { return true }
        return now.timeIntervalSince(lastReplacedAt) >= Self.minReplaceInterval
    }

    private mutating func recover(_ trigger: Trigger, now: Date) -> [Action] {
        guard networkAvailable, isActive else { return [] }
        let replace = trigger == .unauthenticated || replaceWanted
        switch phase {
        case .watching:
            break
        case .refreshing(let replaceAfter):
            // Already refreshing: a new client is decided when it finishes.
            if replace && !replaceAfter { phase = .refreshing(replaceAfter: true) }
            return []
        case .probing:
            guard replace, canReplace(now: now) else { return [] }
            lastTrigger = trigger
            phase = .replacing
            return [.replaceClient]
        case .replacing:
            return []
        }
        lastTrigger = trigger
        phase = .refreshing(replaceAfter: replace)
        return [.refreshToken]
    }
}
