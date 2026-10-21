import AppKit
import Darwin
import Foundation

// Remote control (relay/DESIGN.md): a phone or the web follows and steers this Mac's tasks through
// a relay. Every `crok agent stdio` a task runs is a bridge while this Mac is signed in; Crok
// Desktop signs in and out with the bundled `crok remote …`, shows prompts a phone sent, and keeps
// the bridge's link state. Signing in here is separate from the model providers under Accounts.

/// The person this Mac is linked to.
struct RemoteAccount: Equatable, Sendable {
    var name: String?
    var email: String?
    var imageURL: URL?

    init(name: String? = nil, email: String? = nil, imageURL: URL? = nil) {
        self.name = name
        self.email = email
        self.imageURL = imageURL
    }

    /// `{"name", "email", "imageUrl"}`, as `credentials.json` and `crok remote … --json` write it.
    init(json: Any?) {
        let object = json as? [String: Any]
        name = Self.text(object?["name"])
        email = Self.text(object?["email"])
        // Only a web picture: a `file:` address must not make the card read local files.
        imageURL = Self.webURL(object?["imageUrl"])
    }

    /// What the card names the account by: the name, else the email.
    var title: String? { name ?? email }
    /// The email under the name, when the name is the title.
    var subtitle: String? { name == nil ? nil : email }

    /// A non-empty string, trimmed.
    static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// An http or https address with a host.
    static func webURL(_ value: Any?) -> URL? {
        guard let url = text(value).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// This Mac's link to the relay, from `$CROK_HOME/remote/credentials.json` (`credentials-dev.json` when the
/// bundled crok is a test build for the dev relay). The file also holds the long-lived refresh token; it is
/// never decoded, so nothing here can show or log it.
struct RemoteLink: Equatable, Sendable {
    var server: String
    var deviceID: String
    var deviceName: String
    var account: RemoteAccount
    var linkedAt: Date?

    static let credentialsFileInfoKey = "CrokRemoteCredentialsFile"

    static func file(home: URL, bundle: Bundle = .main) -> URL {
        home.appendingPathComponent("remote", isDirectory: true).appendingPathComponent(fileName(bundle: bundle))
    }

    /// The sign-in file of the relay the bundled crok signs in to, which build-app.sh asks it for
    /// (`crok version --json`); `credentials.json` when the bundle does not say or says something odd.
    static func fileName(bundle: Bundle = .main) -> String {
        guard let name = (bundle.object(forInfoDictionaryKey: credentialsFileInfoKey) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("credentials"), name.hasSuffix(".json"), !name.contains("/") else { return "credentials.json" }
        return name
    }

    /// The link the file describes; nil when there is none (signed out) or it cannot be read.
    static func read(_ url: URL) -> RemoteLink? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> RemoteLink? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let server = stored.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !stored.deviceId.isEmpty else { return nil }
        let account = RemoteAccount(name: RemoteAccount.text(stored.account?.name), email: RemoteAccount.text(stored.account?.email),
                                    imageURL: RemoteAccount.webURL(stored.account?.imageUrl))
        return RemoteLink(server: server, deviceID: stored.deviceId, deviceName: stored.deviceName ?? "", account: account,
                          linkedAt: stored.linkedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// The fields the app reads. `refreshToken` is not among them, so the decoder skips it.
    private struct Stored: Decodable {
        struct Account: Decodable {
            var name: String?
            var email: String?
            var imageUrl: String?
        }
        var server: String
        var deviceId: String
        var deviceName: String?
        var account: Account?
        var linkedAt: Double?
    }
}

/// One line of `crok remote login | logout | status --json`.
enum RemoteCLIEvent: Equatable {
    /// The code to approve, and where.
    struct Code: Equatable {
        var userCode: String
        var verificationURL: URL?
        /// The sign-in page with the code filled in.
        var verificationURLComplete: URL?
        var expiresAt: Date?
        var server: String
        var deviceName: String

        /// The page the browser opens: the one with the code in it when there is one.
        var page: URL? { verificationURLComplete ?? verificationURL }
    }

    case code(Code)
    case signedIn(account: RemoteAccount, deviceName: String, deviceID: String, server: String)
    case signedOut(wasSignedIn: Bool, unlinked: Bool)
    case status(signedIn: Bool, revoked: Bool, reachable: Bool, enabled: Bool)
    case error(String)

    static func parse(_ line: String) -> RemoteCLIEvent? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        func text(_ key: String) -> String { object[key] as? String ?? "" }
        func flag(_ key: String) -> Bool { object[key] as? Bool ?? false }
        func web(_ key: String) -> URL? { RemoteAccount.webURL(object[key]) }
        switch event {
        case "code":
            guard let code = RemoteAccount.text(object["userCode"]) else { return nil }
            let expires = (object["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return .code(Code(userCode: code, verificationURL: web("verificationUrl"), verificationURLComplete: web("verificationUrlComplete"),
                              expiresAt: expires, server: text("server"), deviceName: text("deviceName")))
        case "signed_in":
            return .signedIn(account: RemoteAccount(json: object["account"]), deviceName: text("deviceName"), deviceID: text("deviceId"), server: text("server"))
        case "signed_out":
            return .signedOut(wasSignedIn: flag("wasSignedIn"), unlinked: flag("unlinked"))
        case "status":
            return .status(signedIn: flag("signedIn"), revoked: flag("revoked"), reachable: object["reachable"] as? Bool ?? true,
                           enabled: object["enabled"] as? Bool ?? true)
        case "error":
            return .error(RemoteAccount.text(object["message"]) ?? L10n.t("accounts_sign_in_unfinished", "Sign-in did not finish."))
        default:
            return nil
        }
    }
}

/// The bridge's link state, from `x.ai/remote/status`.
struct RemoteBridgeStatus: Equatable, Sendable {
    enum State: String, Sendable { case off, connecting, connected }
    var state: State
    var account: String?
    var device: String?
    var server: String?

    init(state: State, account: String? = nil, device: String? = nil, server: String? = nil) {
        self.state = state
        self.account = account
        self.device = device
        self.server = server
    }

    init?(params: [String: Any]) {
        guard let state = (params["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        self.init(state: state, account: RemoteAccount.text(params["account"]), device: RemoteAccount.text(params["device"]),
                  server: RemoteAccount.text(params["server"]))
    }

    /// Every task's harness runs a bridge of its own; this Mac is as linked as the best of them.
    static func combined<S: Sequence>(_ statuses: S) -> RemoteBridgeStatus? where S.Element == RemoteBridgeStatus {
        let rank: [State: Int] = [.off: 0, .connecting: 1, .connected: 2]
        return statuses.max { rank[$0.state, default: 0] < rank[$1.state, default: 0] }
    }
}

/// Runs the bundled `crok remote …`. Tests replace it.
struct RemoteCLIRunner {
    /// The `crok` executable; empty when there is none.
    var executable: @MainActor () -> String
    /// Starts `crok` with the arguments; stdout's lines arrive on the main thread as they are printed,
    /// then the exit status and stderr. Returns an action that stops it.
    var stream: @MainActor (_ arguments: [String], _ onLine: @escaping @MainActor (String) -> Void,
                            _ onExit: @escaping @MainActor (Int32, String) -> Void) throws -> () -> Void
    /// Runs `crok` with the arguments to the end.
    var run: @MainActor (_ arguments: [String]) async throws -> GrokCLI.Output

    /// `crok` is the fork's updater; grok's own stays off, as everywhere the app runs crok.
    static let environment = ["CROK_DISABLE_AUTOUPDATER": "1"]

    /// `environment` is added to the app's own (tests give crok a `CROK_HOME` of their own).
    static func crok(environment extra: [String: String] = [:], _ executable: @escaping @MainActor () -> String) -> RemoteCLIRunner {
        let variables = environment.merging(extra) { $1 }
        return RemoteCLIRunner(
            executable: executable,
            stream: { arguments, onLine, onExit in
                try streamProcess(executable(), arguments: arguments, environment: variables, onLine: onLine, onExit: onExit)
            },
            run: { arguments in
                try await GrokCLI.run(executable(), arguments: arguments, environment: variables, timeout: 45)
            })
    }

    /// One reader thread delivers every line before the exit, so the last event is never lost to a
    /// process that ended while its output was still in the pipe.
    @MainActor
    static func streamProcess(_ executable: String, arguments: [String], environment variables: [String: String],
                              onLine: @escaping @MainActor (String) -> Void,
                              onExit: @escaping @MainActor (Int32, String) -> Void) throws -> () -> Void {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw DesktopError.message(L10n.t("accounts_runtime_missing", "The bundled Crok runtime is missing. Reinstall Crok Desktop."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment.merging(variables) { $1 }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async {
            var stderr = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stderr = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let handle = output.fileHandleForReading
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
                }
            }
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
            try? handle.close()
            group.wait()
            process.waitUntilExit()
            let status = process.terminationStatus
            let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status, text) } }
        }
        return { if process.isRunning { process.terminate() } }
    }
}

/// Settings › Remote control: whether this Mac is linked, signing in and out, and the switch that
/// shares its tasks. It reads `credentials.json` and `[remote]` itself, so a sign-in or sign-out made
/// in the terminal shows here within a couple of seconds.
@MainActor
final class RemoteControlModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// `crok remote login` is starting and has not shown a code yet.
        case starting
        /// The code is shown; `crok remote login` waits for it to be approved.
        case waiting(RemoteCLIEvent.Code)
        case signingOut
    }

    /// Said under the card after something that did not fail but needs saying.
    enum Notice: Equatable {
        /// Signed out here, but the relay did not hear it.
        case notUnlinked
        /// Another device signed this Mac out.
        case revoked
        case unreachable

        var text: String {
            switch self {
            case .notUnlinked:
                return L10n.t("remote_notice_not_unlinked", "Signed out on this Mac, but the relay could not be reached. Remove this Mac under Devices on your phone or the web.")
            case .revoked: return L10n.t("remote_notice_revoked", "This Mac was signed out from another device.")
            case .unreachable: return L10n.t("remote_notice_unreachable", "The relay could not be reached right now.")
            }
        }
    }

    @Published private(set) var link: RemoteLink?
    /// `[remote] enabled`; on unless config.toml turns it off.
    @Published private(set) var enabled = true
    @Published private(set) var phase: Phase = .idle
    /// Why the last sign-in or sign-out did not finish.
    @Published var failure: String?
    @Published var notice: Notice?

    let home: URL
    let configURL: URL
    var credentialsURL: URL { RemoteLink.file(home: home) }
    /// Opens the sign-in page. Tests replace it.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    private let runner: RemoteCLIRunner
    private var stopLogin: (() -> Void)?
    /// The sign-in in progress; output from an earlier one is dropped.
    private var loginRun = UUID()
    private var loginError: String?
    private var loginCancelled = false
    private var lastStamps: [ConfigFileWatcher.Stamp] = []
    private var checkingStatus = false
    private var statusCheckedAt: Date?

    /// Tests read and write a home of their own, never the user's `~/.crok`.
    nonisolated static var defaultHome: URL {
        NSClassFromString("XCTestCase") == nil ? GrokPaths.home
            : FileManager.default.temporaryDirectory.appendingPathComponent("crok-remote-home-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// What `crok remote` runs with: the app's own `CROK_HOME`, or in tests the same home of their own.
    nonisolated static var defaultEnvironment: [String: String] {
        NSClassFromString("XCTestCase") == nil ? [:] : ["CROK_HOME": defaultHome.path]
    }

    init(runner: RemoteCLIRunner, home: URL = RemoteControlModel.defaultHome, configURL: URL? = nil) {
        self.runner = runner
        self.home = home
        self.configURL = configURL ?? home.appendingPathComponent("config.toml")
        refresh()
    }

    var isSignedIn: Bool { link != nil }
    var isBusy: Bool { phase != .idle }

    /// Reads the link and `[remote]` again.
    func refresh() {
        lastStamps = [ConfigFileWatcher.Stamp.of(credentialsURL), ConfigFileWatcher.Stamp.of(configURL)]
        let link = RemoteLink.read(credentialsURL)
        if self.link != link { self.link = link }
        let config = GrokConfig(url: configURL)
        let enabled = config.bool("enabled", in: "remote") ?? true
        if self.enabled != enabled { self.enabled = enabled }
    }

    /// Reads again only when either file changed; two `stat`s otherwise. Settings calls it every couple of seconds.
    func refreshIfChanged() {
        guard [ConfigFileWatcher.Stamp.of(credentialsURL), ConfigFileWatcher.Stamp.of(configURL)] != lastStamps else { return }
        refresh()
    }

    // MARK: Signing in

    /// `crok remote login --json --no-browser`: shows the code, opens the page with it, and waits for
    /// the approval. The relay is the one built into crok; nobody types an address.
    func signIn() {
        guard phase == .idle, link == nil else { return }
        failure = nil
        notice = nil
        let arguments = ["remote", "login", "--json", "--no-browser"]
        let run = UUID()
        loginRun = run
        loginError = nil
        loginCancelled = false
        phase = .starting
        do {
            stopLogin = try runner.stream(arguments, { [weak self] line in self?.loginLine(line, run: run) },
                                          { [weak self] status, errors in self?.loginExited(status: status, errors: errors, run: run) })
            DesktopLog.info("remote.login_start")
        } catch {
            phase = .idle
            failure = error.localizedDescription
        }
    }

    /// Stops waiting for the approval; the code expires on its own.
    func cancelSignIn() {
        guard case .waiting = phase else {
            if phase == .starting { loginCancelled = true; stopLogin?() }
            return
        }
        loginCancelled = true
        stopLogin?()
    }

    /// Opens the sign-in page again.
    func openSignInPage() {
        guard case .waiting(let code) = phase, let page = code.page else { return }
        openURL(page)
    }

    func copyCode() {
        guard case .waiting(let code) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
    }

    func loginLine(_ line: String, run: UUID) {
        guard loginRun == run, let event = RemoteCLIEvent.parse(line) else { return }
        switch event {
        case .code(let code):
            phase = .waiting(code)
            if let page = code.page { openURL(page) }
        case .signedIn:
            refresh()
        case .error(let message):
            loginError = message
        case .signedOut, .status:
            break
        }
    }

    func loginExited(status: Int32, errors: String, run: UUID) {
        guard loginRun == run else { return }
        stopLogin = nil
        phase = .idle
        refresh()
        DesktopLog.info("remote.login_end", ["status": Int(status), "cancelled": loginCancelled, "signed_in": link != nil])
        guard status != 0, !loginCancelled, link == nil else { return }
        failure = loginError ?? Self.lastLine(errors) ?? L10n.t("accounts_sign_in_unfinished", "Sign-in did not finish.")
    }

    // MARK: Signing out

    /// `crok remote logout --json`: forgets the link here and unlinks this Mac on the relay.
    func signOut() {
        guard phase == .idle, link != nil else { return }
        failure = nil
        notice = nil
        phase = .signingOut
        Task { [weak self] in
            guard let self else { return }
            defer { self.phase = .idle; self.refresh() }
            do {
                let output = try await self.runner.run(["remote", "logout", "--json"])
                let events = output.text.split(separator: "\n").compactMap { RemoteCLIEvent.parse(String($0)) }
                if let message = events.lazy.compactMap({ if case .error(let message) = $0 { return message } else { return nil } }).first {
                    self.failure = message
                } else if let done = events.first(where: { if case .signedOut = $0 { return true } else { return false } }) {
                    if case .signedOut(let was, let unlinked) = done, was, !unlinked { self.notice = .notUnlinked }
                } else if output.status != 0 {
                    self.failure = Self.lastLine(output.stderr) ?? L10n.t("remote_sign_out_failed", "Could not sign out.")
                }
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    // MARK: The link

    /// `crok remote status --json`, at most once a minute while Settings is open: it asks the relay
    /// whether this Mac is still linked, and crok forgets a link another device revoked.
    func checkStatus(force: Bool = false) {
        guard link != nil, phase == .idle, !checkingStatus else { return }
        if !force, let last = statusCheckedAt, Date().timeIntervalSince(last) < 60 { return }
        checkingStatus = true
        statusCheckedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { self.checkingStatus = false; self.refresh() }
            guard let output = try? await self.runner.run(["remote", "status", "--json"]) else { return }
            for event in output.text.split(separator: "\n").compactMap({ RemoteCLIEvent.parse(String($0)) }) {
                guard case .status(_, let revoked, let reachable, _) = event else { continue }
                if revoked { self.notice = .revoked } else if !reachable { self.notice = .unreachable } else if self.notice == .unreachable { self.notice = nil }
            }
        }
    }

    /// `[remote] enabled`: whether this Mac shares its tasks while it is signed in. Returns why it
    /// could not be saved, or nil.
    @discardableResult
    func setEnabled(_ on: Bool) -> String? {
        do {
            try GrokConfig.update(url: configURL) { try $0.set("enabled", to: .bool(on), in: "remote") }
        } catch {
            refresh()
            return L10n.t("remote_save_failed", "Could not save [remote].enabled: {error}", ["error": error.localizedDescription])
        }
        refresh()
        return nil
    }

    /// `/remote on|off`, as in the terminal; the banner it shows.
    func command(_ arguments: String) -> String? {
        refresh()
        let on: Bool
        switch arguments.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on", "true", "yes", "enable", "enabled": on = true
        case "off", "false", "no", "disable", "disabled": on = false
        default: return nil
        }
        if let failure = setEnabled(on) { return failure }
        return L10n.t("remote_banner_sharing", "✓ Sharing tasks with your phone: {state}", ["state": L10n.onOff(on)])
    }

    /// Ends a sign-in that is still waiting, as the app quits.
    func shutdown() {
        loginCancelled = true
        stopLogin?()
        stopLogin = nil
    }

    /// What a command printed last, which is where it says why it failed.
    static func lastLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        guard var line, !line.isEmpty else { return nil }
        if line.hasPrefix("Error: ") { line = String(line.dropFirst(7)) }
        return line
    }
}

// MARK: - Tasks

extension AppStore {
    /// The remote-control notifications a task's harness sends: the bridge's link state, a prompt a
    /// phone or the web is about to run in this task, and the end of that prompt's turn. Returns
    /// whether the notification is used up; a turn's end is left for the token meter and the rest.
    func receiveRemote(_ method: String, params: [String: Any], id: UUID) -> Bool {
        switch method {
        case "x.ai/remote/status":
            noteRemoteStatus(RemoteBridgeStatus(params: params), from: id)
            return true
        case "x.ai/remote/prompt":
            startRemoteTurn(params, id: id)
            return true
        case "x.ai/remote/permission_resolved":
            dropAnsweredApproval(params, id: id)
            return true
        case "x.ai/session/prompt_complete":
            // The fire-and-forget end of every turn the harness ran through `prompt`.
            finishRemoteTurn(promptID: params["promptId"] as? String, stopReason: params["stopReason"] as? String, id: id)
            return false
        case "x.ai/session_notification":
            // Another computer's model, changed on any device.
            if let update = (params["params"] as? [String: Any] ?? params)["update"] as? [String: Any], applyRemoteModelChange(update, id: id) { return true }
            if let nested = params["params"] as? [String: Any] { _ = receiveRemote("x.ai/session/update", params: nested, id: id) }
            return false
        case "x.ai/session/update", "session/update":
            if let update = params["update"] as? [String: Any], applyRemoteModelChange(update, id: id) { return true }
            // The durable end of a turn, which a reload also replays: only a live one ends a turn.
            guard let update = params["update"] as? [String: Any], update["sessionUpdate"] as? String == "turn_completed",
                  !replaying.contains(id), !importing.contains(id) else { return false }
            finishRemoteTurn(promptID: update["prompt_id"] as? String, stopReason: update["stop_reason"] as? String, id: id)
            return false
        default:
            return false
        }
    }

    /// A prompt from a phone or the web runs in this task now. The harness does not echo it, so it
    /// goes in the transcript here, as a typed prompt does when it is sent, and the task shows as
    /// working until the turn ends.
    func startRemoteTurn(_ params: [String: Any], id: UUID) {
        guard let promptID = RemoteAccount.text(params["promptId"]), task(id) != nil else { return }
        let text = params["text"] as? String ?? ""
        // `fromKind` says a browser sent it; the transcript names that sender "Web" (see `remoteCaption`).
        let from = RemoteAccount.text(params["fromKind"]) == "web" ? "Web" : (RemoteAccount.text(params["from"]) ?? "")
        DesktopLog.info("remote.prompt", session: task(id)?.sessionID, ["prompt_id": promptID, "from": from, "task": id.uuidString])
        // A new task's own first prompt, which the task shows already: its turn starts without a second copy.
        if let first = remoteFirstPrompts[id], RemoteSessions.samePrompt(first, text) {
            remoteFirstPrompts.removeValue(forKey: id)
        } else {
            append(Message(kind: .user, text: text, createdAt: Date(), remoteFrom: from), to: id)
        }
        remoteTurns[id] = promptID
        cancellationRequested.remove(id)
        runs[id, default: RunState()].isRunning = true
        runs[id]?.phase = "Working"
    }

    /// The turn a remote prompt started ended: the task is ready again, unless something the app
    /// started itself is still at work in it, which ends the running state when it is done.
    func finishRemoteTurn(promptID: String?, stopReason: String?, id: UUID) {
        // A new task's first turn ends with whichever turn ends first: the viewer did not name it.
        guard let running = remoteTurns[id], promptID == nil || promptID == running || running == RemoteSessions.startingTurn else { return }
        remoteTurns.removeValue(forKey: id)
        flushTranscript(id)
        let stopped = stopReason == "cancelled" || cancellationRequested.contains(id)
        if let index = state.conversations.firstIndex(where: { $0.id == id }) { state.conversations[index].updatedAt = Date() }
        guard operationIDs[id] == nil else { save(); return }
        cancellationFallbacks.removeValue(forKey: id)?.cancel()
        cancellationRequested.remove(id)
        runs[id]?.isRunning = false
        runs[id]?.phase = stopped ? "Stopped" : "Ready"
        runs[id]?.approvals = []; runs[id]?.questions = []
        if state.selectedConversationID != id { unreadConversationIDs.insert(id) }
        save()
        features.composer.turnDidFinish(conversationID: id, stopped: stopped)
        Task { await refreshWorkspace() }
    }

    /// A task's harness is gone: its remote turn, if any, and its bridge go with it.
    func forgetRemote(_ id: UUID) {
        noteRemoteStatus(nil, from: id)
        guard remoteTurns.removeValue(forKey: id) != nil, operationIDs[id] == nil else { return }
        runs[id]?.isRunning = false
        if runs[id]?.phase == "Working" { runs[id]?.phase = "Disconnected" }
    }

    func noteRemoteStatus(_ status: RemoteBridgeStatus?, from id: UUID) {
        if let status { remoteStatuses[id] = status } else { remoteStatuses.removeValue(forKey: id) }
        let combined = RemoteBridgeStatus.combined(remoteStatuses.values)
        if remoteLink != combined { remoteLink = combined }
    }

    /// `/remote`: Settings › Remote control, or `on` / `off` to share this Mac's tasks or stop.
    func remoteCommand(_ arguments: String) {
        if let banner = remoteControl.command(arguments) {
            self.banner = banner
        } else {
            settingsFocus = .remoteControl
            showSettings = true
        }
    }
}
