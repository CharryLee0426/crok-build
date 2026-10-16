import XCTest

@testable import Crok

/// A scripted device-auth service.
final class FakeAuthService: DeviceAuthService, @unchecked Sendable {
    private let lock = NSLock()
    private var polls: [DeviceAuthPoll]
    private(set) var startCalls = 0
    private(set) var logoutTokens: [String] = []
    var startError: RelayError?
    var expiresIn: Double = 600_000

    init(polls: [DeviceAuthPoll] = []) {
        self.polls = polls
    }

    func start(kind: DeviceKind, name: String, platform: String, client: String) async throws -> DeviceAuthStart {
        lock.withLock { startCalls += 1 }
        if let startError { throw startError }
        return DeviceAuthStart(
            deviceCode: "crd_secret", userCode: "BCDF-GHJK", verificationUrl: "http://web/link",
            verificationUrlComplete: "http://web/link?code=BCDF-GHJK", expiresAt: Date().milliseconds + expiresIn,
            interval: 3600)
    }

    func poll(deviceCode: String) async throws -> DeviceAuthPoll {
        lock.withLock { polls.isEmpty ? .pending : polls.removeFirst() }
    }

    func logout(refreshToken: String) async throws {
        lock.withLock { logoutTokens.append(refreshToken) }
    }
}

@MainActor
final class TestEnvironment: AppEnvironment {
    let isDemo = true
    let store = AuthStore(secure: MemorySecureStore())
    let drafts: DraftStore
    let sessionCache: SessionListCache? = nil
    var relayURL = "http://relay.test"
    let opensBrowserAutomatically = true
    let auth: FakeAuthService
    /// The relay each sign-in call went to.
    private(set) var authServers: [String] = []

    init(auth: FakeAuthService) {
        self.auth = auth
        let defaults = UserDefaults(suiteName: "crok.tests.\(UUID().uuidString)")!
        drafts = DraftStore(defaults: defaults)
    }

    func authService(serverURL: String) -> any DeviceAuthService {
        authServers.append(serverURL)
        return auth
    }

    func makeBackend(serverURL: String, credentials: StoredCredentials, initialToken: DeviceAccessToken?,
                     onRevoked: @escaping @Sendable () -> Void) -> any RelayBackend
    {
        DemoRelay()
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "crok.appmodel.\(UUID().uuidString)")
    }

    func makeModel(_ environment: TestEnvironment, now: @escaping () -> Date = Date.init) -> AppModel {
        AppModel(environment: environment, defaults: defaults, now: now, defaultDeviceName: "Test iPhone", platform: "iOS 26.0", client: "Crok iOS test")
    }

    static let approval = DeviceApproval(
        deviceId: "dev1", refreshToken: "crr_refresh", accessToken: "a.b.c",
        accessTokenExpiresAt: Date().milliseconds + 3_600_000, user: AccountUser(name: "Ada", email: "ada@example.com", imageUrl: nil))

    func testStartsAtWelcomeWithNothingStored() {
        let model = makeModel(TestEnvironment(auth: FakeAuthService()))
        model.restore()
        XCTAssertEqual(model.phase, .welcome)
    }

    func testStartingPersistsThePendingSignInAndARelaunchResumesWaiting() async {
        let environment = TestEnvironment(auth: FakeAuthService())
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertEqual(model.pending?.userCode, "BCDF-GHJK")
        XCTAssertEqual(environment.store.pending?.deviceCode, "crd_secret")
        XCTAssertEqual(environment.store.pending?.deviceName, "Test iPhone")
        XCTAssertEqual(model.browserRequest?.url.absoluteString, "http://web/link?code=BCDF-GHJK&app=1")
        let first = model.browserRequest?.id
        model.openBrowserAgain()
        XCTAssertNotEqual(model.browserRequest?.id, first, "Open again is a new request for the same link")

        // The app is killed and launched again.
        let relaunched = makeModel(environment)
        relaunched.restore()
        XCTAssertEqual(relaunched.phase, .waiting)
        XCTAssertEqual(relaunched.pending, model.pending)
        XCTAssertNil(relaunched.browserRequest, "a resumed sign-in does not reopen the browser by itself")
        model.cancelSignIn()
    }

    func testApprovalStoresCredentialsAndSignsIn() async {
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.pending, .approved(Self.approval)]))
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        let keepPolling = await model.pollOnce()
        XCTAssertTrue(keepPolling)
        XCTAssertEqual(model.phase, .waiting)
        let stillPolling = await model.pollOnce()
        XCTAssertFalse(stillPolling)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNotNil(model.engine)
        XCTAssertEqual(environment.store.credentials?.refreshToken, "crr_refresh")
        XCTAssertEqual(environment.store.credentials?.deviceId, "dev1")
        XCTAssertEqual(environment.store.credentials?.user.name, "Ada")
        XCTAssertNil(environment.store.pending, "the device code is gone once used")

        let relaunched = makeModel(environment)
        relaunched.restore()
        XCTAssertEqual(relaunched.phase, .signedIn)
        await relaunched.signOutLocally(notice: nil)
        await model.engine?.shutdown()
    }

    func testDeniedGoesBackToWelcomeWithANotice() async {
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.denied]))
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        await model.pollOnce()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertNotNil(model.notice)
        XCTAssertNil(environment.store.pending)
        XCTAssertNil(environment.store.credentials)
    }

    func testExpiredCodeFromTheRelayEndsTheSignIn() async {
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.expired]))
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        await model.pollOnce()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertNil(environment.store.pending)
    }

    func testAPendingSignInThatExpiredWhileTheAppWasKilled() async {
        let environment = TestEnvironment(auth: FakeAuthService())
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        model.cancelSignIn()
        XCTAssertNil(environment.store.pending, "Cancel forgets the pending sign-in")

        await model.startSignIn()
        let later = makeModel(environment, now: { Date().addingTimeInterval(11 * 60) })
        later.restore()
        XCTAssertEqual(later.phase, .welcome)
        XCTAssertNotNil(later.notice)
        XCTAssertNil(environment.store.pending)
        model.cancelSignIn()
    }

    func testAStartErrorStaysOnWelcome() async {
        let auth = FakeAuthService()
        auth.startError = RelayError(.network, "Can't reach the relay.")
        let model = makeModel(TestEnvironment(auth: auth))
        model.restore()
        await model.startSignIn()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertEqual(model.notice, "Can't reach the relay.")
    }

    /// Nobody types a server: sign-in goes to the relay built into the app, and an address typed into an earlier build
    /// is forgotten.
    func testSignInUsesTheBuiltInRelayWithoutAServerField() async {
        defaults.set("https://typed-by-hand.convex.cloud", forKey: AppModel.legacyServerKey)
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.approved(Self.approval)]))
        let model = makeModel(environment)
        XCTAssertNil(defaults.string(forKey: AppModel.legacyServerKey), "the old Server field's value is dropped")
        model.restore()
        XCTAssertEqual(model.serverURL, "http://relay.test")
        await model.startSignIn()
        XCTAssertEqual(environment.auth.startCalls, 1)
        XCTAssertEqual(model.pending?.serverURL, "http://relay.test")
        await model.pollOnce()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(environment.store.credentials?.serverURL, "http://relay.test")
        XCTAssertEqual(Set(environment.authServers), ["http://relay.test"])
        await model.signOutLocally(notice: nil)
    }

    func testABuildWithoutARelayCannotStartASignIn() async {
        let environment = TestEnvironment(auth: FakeAuthService())
        environment.relayURL = ""
        let model = makeModel(environment)
        model.restore()
        XCTAssertNil(model.serverURL)
        await model.startSignIn()
        XCTAssertEqual(environment.auth.startCalls, 0)
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertNotNil(model.notice)
    }

    /// The built-in relay comes from Config/Shared.xcconfig through the Info.plist (with the `$()` trick for `//`).
    func testTheAppHasARelayBuiltIn() {
        let url = AppInfo.bundledRelayURL
        XCTAssertNotNil(ServerURL.normalize(url), url)
        XCTAssertTrue(url.hasPrefix("https://") || url.hasPrefix("http://"), url)
        XCTAssertFalse(url.contains("$("), url)
    }

    /// A developer points a build at another relay with `-CrokServer` or `CROK_RELAY_URL`; nothing in the app's UI.
    func testADeveloperOverrideOfTheRelay() {
        let suite = "crok.launch.\(UUID().uuidString)"
        let launchDefaults = UserDefaults(suiteName: suite)!
        XCTAssertNil(LaunchOptions.current(launchDefaults, environment: [:]).server)
        XCTAssertEqual(
            LaunchOptions.current(launchDefaults, environment: ["CROK_RELAY_URL": " http://127.0.0.1:3210 "]).server,
            "http://127.0.0.1:3210")
        launchDefaults.set("http://192.168.1.20:3210", forKey: "CrokServer")
        XCTAssertEqual(
            LaunchOptions.current(launchDefaults, environment: ["CROK_RELAY_URL": "http://127.0.0.1:3210"]).server,
            "http://192.168.1.20:3210", "the launch argument wins")
        launchDefaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(LiveEnvironment(relayOverride: "http://127.0.0.1:3210/").relayURL, "http://127.0.0.1:3210")
        XCTAssertEqual(LiveEnvironment(relayOverride: nil).relayURL, AppInfo.bundledRelayURL)
        XCTAssertEqual(LiveEnvironment(relayOverride: "not a url").relayURL, AppInfo.bundledRelayURL)
    }

    func testSignOutUnlinksAndWipesEverything() async {
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.approved(Self.approval)]))
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        await model.pollOnce()
        environment.drafts.setDraft("half a prompt", for: "s1")
        await model.signOut()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertNil(model.engine)
        XCTAssertNil(environment.store.credentials)
        XCTAssertEqual(environment.auth.logoutTokens, ["crr_refresh"])
        XCTAssertEqual(environment.drafts.draft(for: "s1"), "", "drafts belong to the account")
    }

    func testRevokedElsewhereSignsOutLocally() async throws {
        let environment = TestEnvironment(auth: FakeAuthService(polls: [.approved(Self.approval)]))
        let model = makeModel(environment)
        model.restore()
        await model.startSignIn()
        await model.pollOnce()
        let engine = try XCTUnwrap(model.engine)
        engine.handleRevoked()
        for _ in 0..<50 where model.phase != .welcome { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertNil(environment.store.credentials)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(environment.auth.logoutTokens.isEmpty, "a revoked device has nothing to unlink")
    }
}

final class LocalStoreTests: XCTestCase {
    func testDraftsArePerSessionAndEmptyOnesAreDropped() {
        let defaults = UserDefaults(suiteName: "crok.drafts.\(UUID().uuidString)")!
        let drafts = DraftStore(defaults: defaults)
        drafts.setDraft("one", for: "a")
        drafts.setDraft("two", for: "b")
        XCTAssertEqual(drafts.draft(for: "a"), "one")
        drafts.setDraft("   ", for: "a")
        XCTAssertEqual(drafts.draft(for: "a"), "")
        XCTAssertEqual(drafts.draft(for: "b"), "two")
    }

    func testSessionListCacheRoundTripsForTheSameDeviceOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SessionListCache(directory: directory)
        let row = SessionRow(
            id: "s1", sessionId: "x", title: "T", cwd: "/a/b", model: nil, status: .idle, online: true, app: .tui,
            deviceId: "d", deviceName: "Mac", deviceOnline: true, preview: nil, previewKind: nil, lastActivityAt: 1,
            pinned: false, archived: false, unread: 0, plan: nil, projectKey: "d:/a", projectPath: "/a", projectName: "a",
            historyState: .notFetched)
        let group = ProjectGroup(
            key: "d:/a", deviceId: "d", deviceName: "Mac", deviceOnline: true, path: "/a", name: "a", placed: true,
            lastActivityAt: 1, sessions: [row])
        cache.save(deviceId: "phone1", groups: [group], computers: [])
        XCTAssertEqual(cache.load(deviceId: "phone1")?.groups, [group])
        XCTAssertNil(cache.load(deviceId: "phone2"), "another account's cache is never shown")
        cache.clear()
        XCTAssertNil(cache.load(deviceId: "phone1"))
    }

    func testAFlatListCacheFromAnEarlierBuildIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"deviceId":"phone1","savedAt":1,"sessions":[],"computers":[]}"#.utf8)
            .write(to: directory.appendingPathComponent("sessions.json"))
        XCTAssertNil(SessionListCache(directory: directory).load(deviceId: "phone1"))
    }

    func testAuthStoreKeepsBothRecordsAndWipes() {
        let store = AuthStore(secure: MemorySecureStore())
        store.pending = PendingSignIn(
            serverURL: "s", deviceName: "n", deviceCode: "c", userCode: "BCDF-GHJK", verificationURL: nil, expiresAt: 1,
            interval: 2)
        store.credentials = StoredCredentials(
            serverURL: "s", deviceId: "d", refreshToken: "r", user: AccountUser(), deviceName: "n", signedInAt: 0)
        XCTAssertEqual(store.pending?.userCode, "BCDF-GHJK")
        XCTAssertEqual(store.credentials?.refreshToken, "r")
        store.wipe()
        XCTAssertNil(store.pending)
        XCTAssertNil(store.credentials)
    }
}
