import Foundation

/// What the Sessions title and the session header say about the link to the relay, Telegram style: the title is
/// replaced by "Waiting for network", "Connecting…" or "Updating…" until everything is live again.
enum ConnectionStatus: Equatable, Sendable {
    case waitingForNetwork
    case connecting
    case updating
    case online

    /// - Parameters:
    ///   - networkAvailable: the system reports a usable path.
    ///   - socketConnected: the Convex WebSocket is up and authenticated.
    ///   - synced: the first results arrived since the socket (re)connected.
    static func derive(networkAvailable: Bool, socketConnected: Bool, synced: Bool) -> ConnectionStatus {
        if !networkAvailable { return .waitingForNetwork }
        if !socketConnected { return .connecting }
        if !synced { return .updating }
        return .online
    }

    var title: String? {
        switch self {
        case .waitingForNetwork: String(localized: "Waiting for network")
        case .connecting: String(localized: "Connecting…")
        case .updating: String(localized: "Updating…")
        case .online: nil
        }
    }
}

/// Shows a non-online state only once it has lasted `delay` (0.3 s, like Telegram), so a quick reconnect never flashes
/// "Connecting…"; going back online shows at once.
@MainActor
final class DelayedConnectionStatus {
    private(set) var shown: ConnectionStatus
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private let onChange: @MainActor (ConnectionStatus) -> Void

    init(initial: ConnectionStatus, delay: Duration = .milliseconds(300), onChange: @escaping @MainActor (ConnectionStatus) -> Void) {
        self.shown = initial
        self.delay = delay
        self.onChange = onChange
    }

    func update(_ status: ConnectionStatus) {
        pending?.cancel()
        pending = nil
        if status == .online {
            set(status)
            return
        }
        if shown != .online {
            // Already showing a problem: move between problem states without waiting.
            set(status)
            return
        }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.set(status)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func set(_ status: ConnectionStatus) {
        guard status != shown else { return }
        shown = status
        onChange(status)
    }
}
