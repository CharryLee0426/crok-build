import Foundation
import Observation

/// The sign-in state machine (Telegram's AuthorizationSequenceController idea): welcome → waiting for approval →
/// signed in. Every step is persisted, so a killed app comes back to the same place, still polling.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case welcome
        case waiting
        case signedIn
    }

    private(set) var phase: Phase = .welcome
    private(set) var pending: PendingSignIn?
    private(set) var engine: CrokEngine?
    private(set) var credentials: StoredCredentials?
    /// Shown on the welcome screen: why the last sign-in ended (denied, expired, signed out elsewhere, an error).
    var notice: String?
    private(set) var isStarting = false
    /// Shown on the waiting screen while polls fail (no network); polling continues.
    private(set) var pollProblem: String?
    /// A request to show the browser sheet. Each has its own id, so "Open again" for the same link is a new request.
    struct BrowserRequest: Equatable, Sendable {
        let id = UUID()
        let url: URL
    }

    /// Set when a sign-in starts and by "Open again"; the waiting screen opens each request once.
    private(set) var browserRequest: BrowserRequest?

    /// The name this phone signs in under ("Advanced" on the welcome screen).
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Self.deviceNameKey) }
    }

    let environment: any AppEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// A device code works once, so two polls must never be in flight together.
    @ObservationIgnored private var pollInFlight = false
    @ObservationIgnored private let platform: String
    @ObservationIgnored private let client: String

    /// Where earlier builds kept a relay address typed on the welcome screen; forgotten now that the relay is built in.
    static let legacyServerKey = "crok.server"
    private static let deviceNameKey = "crok.deviceName"

    init(environment: any AppEnvironment, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         defaultDeviceName: String, platform: String, client: String = AppInfo.clientName)
    {
        self.environment = environment
        self.defaults = defaults
        self.now = now
        self.platform = platform
        self.client = client
        defaults.removeObject(forKey: Self.legacyServerKey)
        deviceName = defaults.string(forKey: Self.deviceNameKey) ?? defaultDeviceName
    }

    // MARK: Server

    /// The relay new sign-ins use. It is built into the app (`CROK_RELAY_URL` in Config/Shared.xcconfig); developers
    /// point a build elsewhere with `-CrokServer` or `CROK_RELAY_URL` at launch. A signed-in phone keeps the relay it
    /// signed in to (`StoredCredentials.serverURL`).
    var serverURL: String? {
        ServerURL.normalize(environment.relayURL)
    }

    // MARK: Restore

    /// Picks up where the app left off: signed in, waiting for an approval, or at the welcome screen.
    func restore() {
        let store = environment.store
        if let saved = store.credentials {
            enterSignedIn(saved, initialToken: nil)
            return
        }
        if let waiting = store.pending {
            if waiting.isExpired(now: now()) {
                store.pending = nil
                notice = String(localized: "The sign-in code expired. Start again.")
                phase = .welcome
            } else {
                pending = waiting
                phase = .waiting
                startPolling()
            }
            return
        }
        phase = .welcome
    }

    // MARK: Sign-in

    func startSignIn() async {
        guard !isStarting else { return }
        guard let server = serverURL else {
            // Only a build made with an empty CROK_RELAY_URL gets here.
            notice = String(localized: "Something went wrong.")
            return
        }
        notice = nil
        isStarting = true
        defer { isStarting = false }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let started = try await environment.authService(serverURL: server).start(
                kind: .phone, name: name.isEmpty ? "iPhone" : name, platform: platform, client: client)
            let waiting = PendingSignIn(
                serverURL: server, deviceName: name, deviceCode: started.deviceCode, userCode: started.userCode,
                verificationURL: started.verificationUrlComplete, expiresAt: started.expiresAt,
                interval: max(1, started.interval))
            environment.store.pending = waiting
            pending = waiting
            pollProblem = nil
            phase = .waiting
            if environment.opensBrowserAutomatically { browserRequest = waiting.browserURL.map { BrowserRequest(url: $0) } }
            startPolling()
        } catch {
            notice = (error as? RelayError)?.message ?? error.localizedDescription
        }
    }

    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        environment.store.pending = nil
        pending = nil
        pollProblem = nil
        browserRequest = nil
        phase = .welcome
    }

    func openBrowserAgain() {
        browserRequest = pending?.browserURL.map { BrowserRequest(url: $0) }
    }

    private func startPolling() {
        pollTask?.cancel()
        guard let interval = pending?.interval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if await !self.pollOnce() { return }
            }
        }
    }

    /// One poll. Returns false once the sign-in is over (approved, denied, expired or cancelled).
    @discardableResult
    func pollOnce() async -> Bool {
        guard let waiting = pending, phase == .waiting else { return false }
        guard !pollInFlight else { return true }
        pollInFlight = true
        defer { pollInFlight = false }
        if waiting.isExpired(now: now()) {
            finishWaiting(notice: String(localized: "The sign-in code expired. Start again."))
            return false
        }
        do {
            let result = try await environment.authService(serverURL: waiting.serverURL).poll(deviceCode: waiting.deviceCode)
            guard pending == waiting else { return false }
            pollProblem = nil
            switch result {
            case .pending:
                return true
            case .denied:
                finishWaiting(notice: String(localized: "The sign-in was denied."))
                return false
            case .expired:
                finishWaiting(notice: String(localized: "The sign-in code expired. Start again."))
                return false
            case .approved(let approval):
                let saved = StoredCredentials(
                    serverURL: waiting.serverURL, deviceId: approval.deviceId, refreshToken: approval.refreshToken,
                    user: approval.user, deviceName: waiting.deviceName, signedInAt: now().milliseconds)
                environment.store.credentials = saved
                environment.store.pending = nil
                pending = nil
                browserRequest = nil
                enterSignedIn(
                    saved,
                    initialToken: DeviceAccessToken(
                        deviceId: approval.deviceId, accessToken: approval.accessToken,
                        accessTokenExpiresAt: approval.accessTokenExpiresAt))
                return false
            }
        } catch {
            pollProblem = (error as? RelayError)?.message ?? error.localizedDescription
            return true
        }
    }

    private func finishWaiting(notice: String) {
        pollTask?.cancel()
        pollTask = nil
        environment.store.pending = nil
        pending = nil
        browserRequest = nil
        self.notice = notice
        phase = .welcome
    }

    // MARK: Signed in

    private func enterSignedIn(_ saved: StoredCredentials, initialToken: DeviceAccessToken?) {
        credentials = saved
        let backend = environment.makeBackend(
            serverURL: saved.serverURL, credentials: saved, initialToken: initialToken,
            onRevoked: { [weak self] in
                Task { @MainActor in self?.engine?.handleRevoked() }
            })
        let engine = CrokEngine(
            backend: backend, credentials: saved, isDemo: environment.isDemo, drafts: environment.drafts,
            cache: environment.sessionCache)
        engine.onRevoked = { [weak self] in
            Task { await self?.signOutLocally(notice: String(localized: "This device was signed out from another device.")) }
        }
        self.engine = engine
        phase = .signedIn
        engine.start()
    }

    /// Sign out from Settings: unlink this device on the relay, then forget everything local.
    func signOut() async {
        if let saved = credentials {
            let service = environment.authService(serverURL: saved.serverURL)
            // Best effort: a phone with no network still signs out locally; the relay copy can be revoked elsewhere.
            _ = try? await withTimeout(seconds: 5) { try await service.logout(refreshToken: saved.refreshToken) }
        }
        await signOutLocally(notice: nil)
    }

    /// Forgets the account on this phone (also the answer to `REVOKED`).
    func signOutLocally(notice: String?) async {
        guard phase == .signedIn || credentials != nil else { return }
        let engine = self.engine
        self.engine = nil
        credentials = nil
        environment.store.wipe()
        environment.drafts.removeAll()
        CollapsedProjectsStore(defaults: environment.drafts.defaults).removeAll()
        environment.sessionCache?.clear()
        self.notice = notice
        phase = .welcome
        await engine?.shutdown()
    }
}

/// Runs `work`, giving up after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RelayError(.network, String(localized: "Can't reach the relay. Check your connection."))
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
