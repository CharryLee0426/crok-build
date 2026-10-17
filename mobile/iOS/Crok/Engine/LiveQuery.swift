import Foundation
import Observation

/// Something the engine can tell to try again at once (the connection came back).
@MainActor
protocol RetryableQuery: AnyObject {
    func retryNow()
}

/// Holds the latest value of a relay query for SwiftUI. A ConvexMobile subscription ends at its first error, so this
/// subscribes again with backoff (cut short when the engine reconnects); `REVOKED` signs the device out instead, and
/// `UNAUTHENTICATED` asks the engine for a fresh token and client. A subscription whose first value does not arrive
/// within `stallTimeout` is recreated (see QueryHub for how one can lose its first value). The value stays on screen
/// through errors and reconnects.
@MainActor
@Observable
final class LiveQuery<Value: Sendable>: RetryableQuery {
    private(set) var value: Value?
    private(set) var error: RelayError?
    /// True until the first value (or error) arrives.
    private(set) var isLoading = true

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backoff: Task<Void, Never>?
    @ObservationIgnored private let make: @MainActor () -> RelayStream<Value>
    @ObservationIgnored private weak var engine: CrokEngine?
    @ObservationIgnored var onValue: (@MainActor (Value) -> Void)?
    /// The last value the relay sent (or the cached one), under any local override.
    @ObservationIgnored private var lastReceived: Value?

    static var stallTimeout: Duration { .seconds(8) }

    init(engine: CrokEngine?, initial: Value? = nil, make: @escaping @MainActor () -> RelayStream<Value>) {
        self.engine = engine
        self.value = initial
        self.lastReceived = initial
        self.make = make
    }

    var isRunning: Bool { task != nil }

    func setEngine(_ engine: CrokEngine) {
        self.engine = engine
    }

    func start() {
        guard task == nil else { return }
        engine?.register(self)
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        backoff?.cancel()
        backoff = nil
    }

    /// Ends a backoff wait now (the engine reconnected).
    func retryNow() {
        backoff?.cancel()
    }

    /// Replaces the value locally (an optimistic update); the next relay result overwrites it.
    func override(_ value: Value) {
        self.value = value
    }

    /// Drops a local override (the change it showed failed): back to what the relay last sent.
    func revertOverride() {
        if let lastReceived { value = lastReceived }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            var received = false
            do {
                for try await next in StallGuard.wrap(make(), timeout: Self.stallTimeout) {
                    received = true
                    attempt = 0
                    lastReceived = next
                    value = next
                    error = nil
                    isLoading = false
                    onValue?(next)
                }
                attempt += 1
            } catch is StallGuard.Stalled {
                // Nothing arrived: subscribe again at once.
                try? await Task.sleep(for: .milliseconds(200))
                continue
            } catch {
                let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
                if relayError.isRevoked {
                    engine?.handleRevoked()
                    return
                }
                if relayError.code == .unauthenticated { engine?.handleUnauthenticated() }
                self.error = relayError
                isLoading = false
                attempt = received ? 1 : attempt + 1
            }
            if Task.isCancelled { return }
            let delay = Backoff.delay(attempt: attempt)
            let wait = Task { _ = try? await Task.sleep(for: delay) }
            backoff = wait
            await wait.value
            backoff = nil
        }
    }
}

/// Ends a stream with `Stalled` when its first element does not arrive in time.
enum StallGuard {
    struct Stalled: Error {}

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    static func wrap<T: Sendable>(_ source: RelayStream<T>, timeout: Duration) -> RelayStream<T> {
        AsyncThrowingStream { continuation in
            let received = Flag()
            let forward = Task {
                do {
                    for try await element in source {
                        received.set()
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !received.isSet else { return }
                continuation.finish(throwing: Stalled())
                forward.cancel()
            }
            continuation.onTermination = { _ in
                forward.cancel()
                watchdog.cancel()
            }
        }
    }
}
