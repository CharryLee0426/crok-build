import Foundation

/// Launch arguments (`-Name value`, read through UserDefaults' argument domain).
///
/// - `-CrokDemo YES`: in-memory demo relay with sample data, signed in.
/// - `-CrokDemoSignIn YES`: with `-CrokDemo`, start signed out to show the sign-in screens.
/// - `-CrokDemoApproveAfter 3`: with `-CrokDemoSignIn`, the demo approves the code after that many seconds.
/// - `-CrokAppearance light|dark`: force the appearance (screenshots).
/// - `-CrokResetState YES`: forget the Keychain credentials, drafts and caches at launch (tests).
/// - `-CrokNoBrowser YES`: do not open the browser sheet by itself when a sign-in starts (tests).
struct LaunchOptions {
    var demo: Bool
    var demoSignIn: Bool
    var demoApproveAfter: Double?
    var appearance: String?
    var resetState: Bool
    var noBrowser: Bool

    static func current(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        LaunchOptions(
            demo: defaults.bool(forKey: "CrokDemo"),
            demoSignIn: defaults.bool(forKey: "CrokDemoSignIn"),
            demoApproveAfter: defaults.object(forKey: "CrokDemoApproveAfter") == nil
                ? nil : defaults.double(forKey: "CrokDemoApproveAfter"),
            appearance: defaults.string(forKey: "CrokAppearance"),
            resetState: defaults.bool(forKey: "CrokResetState"),
            noBrowser: defaults.bool(forKey: "CrokNoBrowser"))
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
    /// The relay URL built into the app (empty when none).
    var bundledServerURL: String { get }
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
    var bundledServerURL: String { AppInfo.bundledRelayURL }
    let opensBrowserAutomatically: Bool

    init(opensBrowserAutomatically: Bool = true) {
        self.opensBrowserAutomatically = opensBrowserAutomatically
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
    let bundledServerURL = "https://demo.crok.example"
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
                serverURL: bundledServerURL, deviceId: "demo-phone", refreshToken: "crr_demo",
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
