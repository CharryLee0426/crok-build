import Combine
import Foundation

/// Shares one ConvexMobile subscription between everyone watching the same query with the same arguments, and
/// replays its latest value to whoever joins later.
///
/// Why: ConvexMobile 0.8.1's `subscribe` forwards results through a `PassthroughSubject` that its returned publisher
/// only subscribes to once an async `Future` resolves. When the Rust client already holds that query's result (a second
/// screen watching the same session, or reopening a screen right after closing it), the first value is sent before
/// anyone listens and is lost, and the new subscriber waits until the data next changes. With one subscription per
/// query that never happens, and a value already seen is handed out at once.
///
/// When the app replaces a stuck Convex client (`ConnectionKeeper`), `restartAll` subscribes every query again on the
/// new one; observers stay attached and keep the value they have until the new subscription answers.
final class QueryHub: @unchecked Sendable {
    typealias Start = @Sendable (_ deliver: @escaping @Sendable (Any) -> Void, _ fail: @escaping @Sendable (RelayError) -> Void)
        -> AnyCancellable

    /// An entry that has produced nothing for this long is presumed stuck and replaced for the next observer.
    static let stuckAfter: TimeInterval = 5
    /// How long a subscription nobody watches is kept, so a screen reopened at once reuses it.
    static let grace: TimeInterval = 3

    /// Mutated only under `lock`.
    private final class Entry: @unchecked Sendable {
        let start: Start
        var cancellable: AnyCancellable?
        var latest: Any?
        var observers: [UUID: Observer] = [:]
        var createdAt = Date()
        /// Bumped on every (re)start; deliveries from an older run are dropped.
        var run = 0
        /// Removed from the hub: a start still in flight cancels what it made.
        var ended = false

        init(start: @escaping Start) {
            self.start = start
        }
    }

    private struct Observer {
        let value: @Sendable (Any) -> Void
        let failure: @Sendable (RelayError) -> Void
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    var count: Int { lock.withLock { entries.count } }

    /// Adds an observer for `key`, starting the subscription with `start` when there is none to share.
    func attach(
        key: String, id: UUID, onValue: @escaping @Sendable (Any) -> Void, onError: @escaping @Sendable (RelayError) -> Void,
        start: @escaping Start
    ) {
        let observer = Observer(value: onValue, failure: onError)
        var replay: Any?
        var fresh: Entry?
        var stale: AnyCancellable?
        lock.withLock {
            if let entry = entries[key], entry.latest != nil || Date().timeIntervalSince(entry.createdAt) < Self.stuckAfter {
                entry.observers[id] = observer
                replay = entry.latest
            } else {
                let entry = Entry(start: start)
                if let stuck = entries[key] {
                    entry.observers = stuck.observers
                    stuck.ended = true
                    stale = stuck.cancellable
                }
                entry.observers[id] = observer
                entries[key] = entry
                fresh = entry
            }
        }
        stale?.cancel()
        if let replay { onValue(replay) }
        if let fresh { launch(fresh, key: key) }
    }

    /// Removes an observer; the subscription ends `grace` seconds after its last observer left.
    func detach(key: String, id: UUID) {
        let entry: Entry? = lock.withLock {
            guard let entry = entries[key] else { return nil }
            entry.observers[id] = nil
            return entry.observers.isEmpty ? entry : nil
        }
        guard let entry else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.grace) { [weak self] in
            guard let self else { return }
            let cancellable: AnyCancellable? = self.lock.withLock {
                guard self.entries[key] === entry, entry.observers.isEmpty else { return nil }
                self.entries[key] = nil
                entry.ended = true
                return entry.cancellable
            }
            cancellable?.cancel()
        }
    }

    /// Subscribes every query again (on a new client); observers and latest values stay.
    func restartAll() {
        let all = lock.withLock { Array(entries) }
        for (key, entry) in all { launch(entry, key: key) }
    }

    /// Ends every subscription (sign-out).
    func removeAll() {
        let all = lock.withLock { () -> [Entry] in
            let values = Array(entries.values)
            entries.removeAll()
            for entry in values { entry.ended = true }
            return values
        }
        for entry in all { entry.cancellable?.cancel() }
    }

    /// (Re)starts an entry's subscription; whatever the previous run made is cancelled.
    private func launch(_ entry: Entry, key: String) {
        let (run, previous): (Int, AnyCancellable?) = lock.withLock {
            entry.run += 1
            entry.createdAt = Date()
            let previous = entry.cancellable
            entry.cancellable = nil
            return (entry.run, previous)
        }
        previous?.cancel()
        let cancellable = entry.start(
            { [weak self, weak entry] value in
                guard let self, let entry else { return }
                let observers: [Observer] = self.lock.withLock {
                    guard entry.run == run, !entry.ended else { return [] }
                    entry.latest = value
                    return Array(entry.observers.values)
                }
                for observer in observers { observer.value(value) }
            },
            { [weak self, weak entry] error in
                guard let self, let entry else { return }
                let observers: [Observer] = self.lock.withLock {
                    guard entry.run == run, !entry.ended else { return [] }
                    if self.entries[key] === entry { self.entries[key] = nil }
                    entry.ended = true
                    return Array(entry.observers.values)
                }
                for observer in observers { observer.failure(error) }
            })
        let unwanted: AnyCancellable? = lock.withLock {
            guard entry.run == run, !entry.ended else { return cancellable }
            entry.cancellable = cancellable
            return nil
        }
        unwanted?.cancel()
    }

    /// A stable key for a query and its arguments.
    static func key(_ name: String, _ args: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(args)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return name + json
    }
}
