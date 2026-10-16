import Foundation

/// Launch arguments (`-Name value`, read through UserDefaults' argument domain).
///
/// - `-CrokDemo YES`: in-memory demo relay with sample data, signed in.
/// - `-CrokDemoSignIn YES`: with `-CrokDemo`, start signed out to show the sign-in screens.
/// - `-CrokDemoApproveAfter 3`: with `-CrokDemoSignIn`, the demo approves the code after that many seconds.
/// - `-CrokAppearance light|dark`: force the appearance (screenshots).
/// - `-CrokResetState YES`: forget the Keychain credentials, drafts and caches at launch (tests).
/// - `-CrokNoBrowser YES`: do not open the browser sheet by itself when a sign-in starts (tests).
/// - `-CrokServer http://127.0.0.1:3210` (or the `CROK_RELAY_URL` environment variable): sign in to another relay than
///   the built-in one, e.g. a local `npx convex dev` (development only; there is no setting for it in the app).
struct LaunchOptions {
    var demo: Bool
    var demoSignIn: Bool
    var demoApproveAfter: Double?
    var appearance: String?
    var resetState: Bool
    var noBrowser: Bool
    /// A developer's relay for new sign-ins, from `-CrokServer` or `CROK_RELAY_URL`.
    var server: String?

    static func current(
        _ defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchOptions {
        let server = [defaults.string(forKey: "CrokServer"), environment["CROK_RELAY_URL"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return LaunchOptions(
            demo: defaults.bool(forKey: "CrokDemo"),
            demoSignIn: defaults.bool(forKey: "CrokDemoSignIn"),
            demoApproveAfter: defaults.object(forKey: "CrokDemoApproveAfter") == nil
                ? nil : defaults.double(forKey: "CrokDemoApproveAfter"),
            appearance: defaults.string(forKey: "CrokAppearance"),
            resetState: defaults.bool(forKey: "CrokResetState"),
            noBrowser: defaults.bool(forKey: "CrokNoBrowser"),
            server: server)
    }
}

/// What differs between the real app and demo mode (and unit tests): where secrets live, how sign-in talks to a
/// server, and which relay backend a signed-in account gets.
@MainActor
protocol AppEnvironment: AnyObject {
    var isDemo: Bool { get }
    var store: AuthStore { get }
    var drafts: DraftStore { get }
    var sessionCache: SessionListCache? { get }
    /// The relay new sign-ins use: the one built into the app, or a developer's override. Nobody types it.
    var relayURL: String { get }
    /// Open the browser sheet as soon as a sign-in starts.
    var opensBrowserAutomatically: Bool { get }
    func authService(serverURL: String) -> any DeviceAuthService
    func makeBackend(serverURL: String, credentials: StoredCredentials, initialToken: DeviceAccessToken?,
                     onRevoked: @escaping @Sendable () -> Void) -> any RelayBackend
}

@MainActor
final class LiveEnvironment: AppEnvironment {
    let isDemo = false
    let store = AuthStore(secure: KeychainStore())
    let drafts = DraftStore()
    let sessionCache: SessionListCache? = .standard
    let relayURL: String
    let opensBrowserAutomatically: Bool

    /// `relayOverride` (`-CrokServer`, `CROK_RELAY_URL`) wins over the built-in relay when it is a valid address.
    init(opensBrowserAutomatically: Bool = true, relayOverride: String? = nil) {
        self.opensBrowserAutomatically = opensBrowserAutomatically
        relayURL = relayOverride.flatMap(ServerURL.normalize) ?? AppInfo.bundledRelayURL
    }

    func authService(serverURL: String) -> any DeviceAuthService {
        LiveDeviceAuthService(http: ConvexHTTPClient(deploymentURL: URL(string: serverURL)!))
    }

    func makeBackend(serverURL: String, credentials: StoredCredentials, initialToken: DeviceAccessToken?,
                     onRevoked: @escaping @Sendable () -> Void) -> any RelayBackend
    {
        ConvexRelay(
            serverURL: URL(string: serverURL)!, credentials: credentials, initialToken: initialToken, onRevoked: onRevoked)
    }
}

@MainActor
final class DemoEnvironment: AppEnvironment {
    let isDemo = true
    let store = AuthStore(secure: MemorySecureStore())
    let drafts: DraftStore
    let sessionCache: SessionListCache? = nil
    let relayURL = "https://demo.crok.example"
    let opensBrowserAutomatically = false
    let approveAfter: Double?
    private let auth: DemoDeviceAuthService

    init(signedIn: Bool, approveAfter: Double?) {
        self.approveAfter = approveAfter
        auth = DemoDeviceAuthService(approveAfter: approveAfter)
        let defaults = UserDefaults(suiteName: "crok.demo") ?? .standard
        defaults.removePersistentDomain(forName: "crok.demo")
        drafts = DraftStore(defaults: defaults)
        if signedIn {
            store.credentials = StoredCredentials(
                serverURL: relayURL, deviceId: "demo-phone", refreshToken: "crr_demo",
                user: AccountUser(name: "Charlie Lee", email: "charlie@example.com", imageUrl: nil),
                deviceName: "Charlie's iPhone", signedInAt: Date().milliseconds)
        }
    }

    func authService(serverURL: String) -> any DeviceAuthService {
        auth
    }

    func makeBackend(serverURL: String, credentials: StoredCredentials, initialToken: DeviceAccessToken?,
                     onRevoked: @escaping @Sendable () -> Void) -> any RelayBackend
    {
        DemoRelay()
    }
}
