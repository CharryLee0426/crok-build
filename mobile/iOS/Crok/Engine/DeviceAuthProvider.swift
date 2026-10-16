import Foundation
@preconcurrency import ConvexMobile

/// ConvexMobile's `AuthProvider` for a linked device: the identity token is the device's one-hour access JWT, minted by
/// `deviceAuth:refresh` from the refresh token in the Keychain. It is called over the HTTP API, never over the
/// WebSocket client whose auth callback this is.
///
/// - `login` uses the token `deviceAuth:poll` just handed out when it is still fresh, otherwise refreshes.
/// - `loginFromCache` (ConvexMobile calls it when the server wants a new token, e.g. after a reconnect) always
///   refreshes.
/// - A timer refreshes five minutes before expiry and pushes the new token through `onIdToken`.
/// - `REVOKED` from the relay calls `onRevoked`: the app signs out locally.
final class DeviceAuthProvider: AuthProvider, @unchecked Sendable {
    typealias T = DeviceAccessToken

    /// Refresh this long before the access token runs out.
    static let refreshLead: TimeInterval = 5 * 60
    /// After a failed timed refresh (no network), try again this soon.
    static let retryDelay: TimeInterval = 30

    private let service: LiveDeviceAuthService
    private let refreshToken: String
    private let onRevoked: @Sendable () -> Void
    private let onRefreshed: @Sendable () -> Void

    private let lock = NSLock()
    private var initialToken: DeviceAccessToken?
    private var timer: Task<Void, Never>?

    init(
        service: LiveDeviceAuthService, refreshToken: String, initialToken: DeviceAccessToken?,
        onRevoked: @escaping @Sendable () -> Void, onRefreshed: @escaping @Sendable () -> Void = {}
    ) {
        self.service = service
        self.refreshToken = refreshToken
        self.initialToken = initialToken
        self.onRevoked = onRevoked
        self.onRefreshed = onRefreshed
    }

    deinit { timer?.cancel() }

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> DeviceAccessToken {
        if let token = takeInitialToken(), Self.secondsLeft(token) > Self.refreshLead * 2 {
            schedule(after: token, onIdToken: onIdToken)
            return token
        }
        return try await loginFromCache(onIdToken: onIdToken)
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> DeviceAccessToken {
        let token = try await refresh()
        schedule(after: token, onIdToken: onIdToken)
        return token
    }

    func logout() async throws {
        cancelTimer()
    }

    func extractIdToken(from authResult: DeviceAccessToken) -> String {
        authResult.accessToken
    }

    func cancelTimer() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    // MARK: - Private

    private func takeInitialToken() -> DeviceAccessToken? {
        lock.lock()
        defer { lock.unlock() }
        let token = initialToken
        initialToken = nil
        return token
    }

    private func refresh() async throws -> DeviceAccessToken {
        do {
            let token = try await service.refresh(refreshToken: refreshToken)
            onRefreshed()
            return token
        } catch let error as RelayError where error.isRevoked {
            cancelTimer()
            onRevoked()
            throw error
        }
    }

    static func secondsLeft(_ token: DeviceAccessToken, now: Date = Date()) -> TimeInterval {
        (token.accessTokenExpiresAt - now.milliseconds) / 1000
    }

    private func schedule(after token: DeviceAccessToken, onIdToken: @Sendable @escaping (String?) -> Void) {
        let task = Task { [weak self] in
            var wait = max(Self.retryDelay, Self.secondsLeft(token) - Self.refreshLead)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                do {
                    let fresh = try await self.refresh()
                    onIdToken(fresh.accessToken)
                    wait = max(Self.retryDelay, Self.secondsLeft(fresh) - Self.refreshLead)
                } catch let error as RelayError where error.isRevoked {
                    onIdToken(nil)
                    return
                } catch {
                    wait = Self.retryDelay
                }
            }
        }
        lock.lock()
        timer?.cancel()
        timer = task
        lock.unlock()
    }
}
