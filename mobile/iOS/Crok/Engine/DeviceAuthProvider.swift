import Foundation
@preconcurrency import ConvexMobile

/// The device's access tokens, shared by every Convex client the account makes (one is replaced when the connection is
/// stuck): one `deviceAuth:refresh` at a time, a token refreshed moments ago is reused, and `REVOKED` signs out.
final class DeviceTokenSource: @unchecked Sendable {
    typealias Fetch = @Sendable (_ refreshToken: String) async throws -> DeviceAccessToken

    /// The longest a refresh may take before it counts as failed (a stuck request must not stall a reconnect).
    static let refreshTimeout: Double = 10

    private let refreshToken: String
    private let fetch: Fetch
    private let onRevoked: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var latest: DeviceAccessToken?
    private var latestAt: Date?
    private var inFlight: Task<DeviceAccessToken, Error>?
    private var revoked = false

    init(
        refreshToken: String, initialToken: DeviceAccessToken?, fetch: @escaping Fetch,
        onRevoked: @escaping @Sendable () -> Void, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.refreshToken = refreshToken
        self.fetch = fetch
        self.onRevoked = onRevoked
        self.now = now
        latest = initialToken
        latestAt = initialToken == nil ? nil : now()
    }

    /// The newest token while it has at least `seconds` left.
    func current(minimumSecondsLeft seconds: TimeInterval) -> DeviceAccessToken? {
        lock.withLock {
            guard let latest, DeviceAuthProvider.secondsLeft(latest, now: now()) > seconds else { return nil }
            return latest
        }
    }

    /// A token refreshed at most `maxAge` seconds ago (and not about to expire), fetching one if needed. Concurrent
    /// callers share one request.
    func fresh(maxAge: TimeInterval) async throws -> DeviceAccessToken {
        enum Source {
            case cached(DeviceAccessToken)
            case request(Task<DeviceAccessToken, Error>)
        }
        let source: Source = try lock.withLock {
            if revoked { throw RelayError(.revoked, String(localized: "This device was signed out from another device.")) }
            if let latest, let latestAt, now().timeIntervalSince(latestAt) <= maxAge,
                DeviceAuthProvider.secondsLeft(latest, now: now()) > DeviceAuthProvider.refreshLead
            {
                return .cached(latest)
            }
            if let inFlight { return .request(inFlight) }
            let fetch = self.fetch
            let refreshToken = self.refreshToken
            let task = Task {
                try await withTimeout(seconds: Self.refreshTimeout) { try await fetch(refreshToken) }
            }
            inFlight = task
            return .request(task)
        }
        let task: Task<DeviceAccessToken, Error>
        switch source {
        case .cached(let token): return token
        case .request(let request): task = request
        }
        do {
            let token = try await task.value
            lock.withLock {
                if inFlight == task { inFlight = nil }
                if latestAt == nil || latest?.accessTokenExpiresAt ?? 0 <= token.accessTokenExpiresAt {
                    latest = token
                    latestAt = now()
                }
            }
            return token
        } catch {
            let relayError = (error as? RelayError) ?? RelayError.network(error)
            let firstRevocation: Bool = lock.withLock {
                if inFlight == task { inFlight = nil }
                guard relayError.isRevoked, !revoked else { return false }
                revoked = true
                return true
            }
            if firstRevocation { onRevoked() }
            throw relayError
        }
    }
}

/// ConvexMobile's `AuthProvider` for a linked device: the identity token is the device's one-hour access JWT, minted by
/// `deviceAuth:refresh` from the refresh token in the Keychain (`DeviceTokenSource`, over the HTTP API, never over the
/// WebSocket client whose auth callback this is). One provider per Convex client.
///
/// - `login` uses a token with ten minutes or more left (the one `deviceAuth:poll` just handed out, or one refreshed a
///   moment ago), otherwise refreshes.
/// - `loginFromCache` (ConvexMobile calls it on every reconnect, from inside the client's worker) reuses a token
///   refreshed in the last 30 s; when a refresh fails it returns a token that is still valid rather than letting
///   ConvexMobile fall back to its cached one, which may have expired.
/// - A timer refreshes five minutes before expiry and pushes the new token through `onIdToken`; so does `pushFresh`
///   (the app's "is the socket alive?" probe: a live socket answers a new token with fresh query results).
final class DeviceAuthProvider: AuthProvider, @unchecked Sendable {
    typealias T = DeviceAccessToken

    /// Refresh this long before the access token runs out.
    static let refreshLead: TimeInterval = 5 * 60
    /// After a failed timed refresh (no network), try again this soon.
    static let retryDelay: TimeInterval = 30
    /// A reconnect reuses a token refreshed this recently.
    static let reconnectReuse: TimeInterval = 30

    private let tokens: DeviceTokenSource
    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    private var onIdToken: (@Sendable (String?) -> Void)?

    init(tokens: DeviceTokenSource) {
        self.tokens = tokens
    }

    deinit { timer?.cancel() }

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> DeviceAccessToken {
        if let token = tokens.current(minimumSecondsLeft: Self.refreshLead * 2) {
            remember(onIdToken)
            schedule(after: token)
            return token
        }
        return try await loginFromCache(onIdToken: onIdToken)
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> DeviceAccessToken {
        remember(onIdToken)
        do {
            let token = try await tokens.fresh(maxAge: Self.reconnectReuse)
            schedule(after: token)
            return token
        } catch let error as RelayError where error.isRevoked {
            cancelTimer()
            throw error
        } catch {
            if let stillValid = tokens.current(minimumSecondsLeft: 60) { return stillValid }
            throw error
        }
    }

    func logout() async throws {
        cancelTimer()
    }

    func extractIdToken(from authResult: DeviceAccessToken) -> String {
        authResult.accessToken
    }

    /// Refreshes the token now and hands it to the client (which authenticates again over its socket).
    func pushFresh() async throws {
        let token = try await tokens.fresh(maxAge: 5)
        let handler = lock.withLock { onIdToken }
        handler?(token.accessToken)
        schedule(after: token)
    }

    func cancelTimer() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            onIdToken = nil
        }
    }

    // MARK: - Private

    private func remember(_ handler: @Sendable @escaping (String?) -> Void) {
        lock.withLock { onIdToken = handler }
    }

    static func secondsLeft(_ token: DeviceAccessToken, now: Date = Date()) -> TimeInterval {
        (token.accessTokenExpiresAt - now.milliseconds) / 1000
    }

    private func schedule(after token: DeviceAccessToken) {
        let tokens = self.tokens
        let task = Task { [weak self] in
            var wait = max(Self.retryDelay, Self.secondsLeft(token) - Self.refreshLead)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                do {
                    let fresh = try await tokens.fresh(maxAge: 0)
                    self.lock.withLock { self.onIdToken }?(fresh.accessToken)
                    wait = max(Self.retryDelay, Self.secondsLeft(fresh) - Self.refreshLead)
                } catch let error as RelayError where error.isRevoked {
                    self.lock.withLock { self.onIdToken }?(nil)
                    return
                } catch {
                    wait = Self.retryDelay
                }
            }
        }
        lock.withLock {
            timer?.cancel()
            timer = task
        }
    }
}
