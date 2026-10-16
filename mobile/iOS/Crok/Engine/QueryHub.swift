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
final class QueryHub: @unchecked Sendable {
    typealias Start = (_ deliver: @escaping @Sendable (Any) -> Void, _ fail: @escaping @Sendable (RelayError) -> Void)
        -> AnyCancellable

    /// An entry that has produced nothing for this long is presumed stuck and replaced for the next observer.
    static let stuckAfter: TimeInterval = 5
    /// How long a subscription nobody watches is kept, so a screen reopened at once reuses it.
    static let grace: TimeInterval = 3

    /// Mutated only under `lock`.
    private final class Entry: @unchecked Sendable {
        var cancellable: AnyCancellable?
        var latest: Any?
        var observers: [UUID: Observer] = [:]
        let createdAt = Date()
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
        start: Start
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
                let entry = Entry()
                if let stuck = entries[key] {
                    entry.observers = stuck.observers
                    stale = stuck.cancellable
                }
                entry.observers[id] = observer
                entries[key] = entry
                fresh = entry
            }
        }
        stale?.cancel()
        if let replay { onValue(replay) }
        guard let entry = fresh else { return }
        let cancellable = start(
            { [weak self, weak entry] value in
                guard let self, let entry else { return }
                let observers = self.lock.withLock { () -> [Observer] in
                    entry.latest = value
                    return Array(entry.observers.values)
                }
                for observer in observers { observer.value(value) }
            },
            { [weak self, weak entry] error in
                guard let self, let entry else { return }
                let observers = self.lock.withLock { () -> [Observer] in
                    if self.entries[key] === entry { self.entries[key] = nil }
                    return Array(entry.observers.values)
                }
                for observer in observers { observer.failure(error) }
            })
        lock.withLock { entry.cancellable = cancellable }
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
                return entry.cancellable
            }
            cancellable?.cancel()
        }
    }

    /// Ends every subscription (sign-out).
    func removeAll() {
        let all = lock.withLock { () -> [Entry] in
            let values = Array(entries.values)
            entries.removeAll()
            return values
        }
        for entry in all { entry.cancellable?.cancel() }
    }

    /// A stable key for a query and its arguments.
    static func key(_ name: String, _ args: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(args)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return name + json
    }
}
