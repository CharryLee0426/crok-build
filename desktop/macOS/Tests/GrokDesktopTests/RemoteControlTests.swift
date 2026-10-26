import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Remote control: what `crok remote … --json` prints, the link file, Settings › Remote control's
/// model against the offline fixture's `remote` command, prompts a phone sends into a task, and the
/// helper harnesses that must not run a bridge.
@MainActor
final class RemoteControlTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-remote-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func eventually(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mock-grok.py")

    /// The offline fixture, runnable from `directory`: with `main` replaced when given.
    private func fixtureExecutable(main: String? = nil) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        var source = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
            .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        if let main { source = source.components(separatedBy: "if __name__ == \"__main__\":")[0] + main }
        let executable = directory.appendingPathComponent("fixture-crok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func writeLink(_ object: [String: Any], home: URL) throws {
        let file = RemoteLink.file(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    private static let linkJSON: [String: Any] = [
        "server": "https://quiet-otter-123.convex.cloud", "deviceId": "dev_1", "refreshToken": "crr_SECRET_never_shown",
        "deviceName": "Charlie's MacBook Pro", "linkedAt": 1_760_500_000_000,
        "account": ["name": "Charlie Lee", "email": "charlie@example.com", "imageUrl": "https://img.example.com/c.png"],
    ]

    // MARK: What crok prints

    func testTheLoginLinesParse() throws {
        let code = #"{"event":"code","userCode":"BCDF-GHJK","verificationUrl":"https://crok.example/link","verificationUrlComplete":"https://crok.example/link?code=BCDF-GHJK","expiresAt":1760500600000,"server":"https://x.convex.cloud","deviceName":"Mac"}"#
        guard case .code(let parsed)? = RemoteCLIEvent.parse(code) else { return XCTFail("no code") }
        XCTAssertEqual(parsed.userCode, "BCDF-GHJK")
        XCTAssertEqual(parsed.page, URL(string: "https://crok.example/link?code=BCDF-GHJK"))
        XCTAssertEqual(parsed.verificationURL, URL(string: "https://crok.example/link"))
        XCTAssertEqual(parsed.expiresAt, Date(timeIntervalSince1970: 1_760_500_600))
        XCTAssertEqual(parsed.server, "https://x.convex.cloud")
        XCTAssertEqual(parsed.deviceName, "Mac")

        // A relay without a web address: the code is approved from a phone.
        guard case .code(let bare)? = RemoteCLIEvent.parse(#"{"event":"code","userCode":"BCDF-GHJK","verificationUrl":null,"verificationUrlComplete":null,"expiresAt":1,"server":"s","deviceName":"d"}"#)
        else { return XCTFail("no code") }
        XCTAssertNil(bare.page)
        // Only a web page is opened.
        guard case .code(let local)? = RemoteCLIEvent.parse(#"{"event":"code","userCode":"X","verificationUrlComplete":"file:///etc/passwd"}"#)
        else { return XCTFail("no code") }
        XCTAssertNil(local.page)

        XCTAssertEqual(RemoteCLIEvent.parse(#"{"event":"signed_in","account":{"name":"Ada","email":"ada@example.com","imageUrl":null},"deviceName":"Mac","deviceId":"d1","server":"s"}"#),
                       .signedIn(account: RemoteAccount(name: "Ada", email: "ada@example.com"), deviceName: "Mac", deviceID: "d1", server: "s"))
        XCTAssertEqual(RemoteCLIEvent.parse(#"{"event":"signed_out","wasSignedIn":true,"unlinked":false}"#), .signedOut(wasSignedIn: true, unlinked: false))
        XCTAssertEqual(RemoteCLIEvent.parse(#"{"event":"signed_out","wasSignedIn":false}"#), .signedOut(wasSignedIn: false, unlinked: false))
        XCTAssertEqual(RemoteCLIEvent.parse(#"{"event":"status","signedIn":true,"revoked":false,"reachable":false,"enabled":true}"#),
                       .status(signedIn: true, revoked: false, reachable: false, enabled: true))
        XCTAssertEqual(RemoteCLIEvent.parse(#"{"event":"error","message":"No relay is configured."}"#), .error("No relay is configured."))
        XCTAssertNil(RemoteCLIEvent.parse("Waiting for approval…"))
        XCTAssertNil(RemoteCLIEvent.parse(#"{"event":"code"}"#), "a code event without a code")
        XCTAssertNil(RemoteCLIEvent.parse(#"{"event":"later"}"#))
    }

    func testTheLinkFileIsReadWithoutItsToken() throws {
        let home = directory.appendingPathComponent("home")
        XCTAssertNil(RemoteLink.read(RemoteLink.file(home: home)), "no file: signed out")
        try writeLink(Self.linkJSON, home: home)
        let link = try XCTUnwrap(RemoteLink.read(RemoteLink.file(home: home)))
        XCTAssertEqual(link.server, "https://quiet-otter-123.convex.cloud")
        XCTAssertEqual(link.deviceID, "dev_1")
        XCTAssertEqual(link.deviceName, "Charlie's MacBook Pro")
        XCTAssertEqual(link.account.title, "Charlie Lee")
        XCTAssertEqual(link.account.subtitle, "charlie@example.com")
        XCTAssertEqual(link.account.imageURL, URL(string: "https://img.example.com/c.png"))
        XCTAssertEqual(link.linkedAt, Date(timeIntervalSince1970: 1_760_500_000))
        // The token is never kept, so nothing that prints the link can show it.
        for text in [String(describing: link), String(reflecting: link), String(describing: Mirror(reflecting: link).children.map(\.value))] {
            XCTAssertFalse(text.contains("crr_SECRET"), text)
        }

        // An account with only an email is named by it; a local picture is not shown.
        var other = Self.linkJSON
        other["account"] = ["email": "solo@example.com", "imageUrl": "file:///Users/me/secret.png"]
        try writeLink(other, home: home)
        let solo = try XCTUnwrap(RemoteLink.read(RemoteLink.file(home: home)))
        XCTAssertEqual(solo.account.title, "solo@example.com")
        XCTAssertNil(solo.account.subtitle)
        XCTAssertNil(solo.account.imageURL)

        // A file that is not a link reads as signed out.
        try Data("{not json".utf8).write(to: RemoteLink.file(home: home))
        XCTAssertNil(RemoteLink.read(RemoteLink.file(home: home)))
        try JSONSerialization.data(withJSONObject: ["server": "", "deviceId": "d"]).write(to: RemoteLink.file(home: home))
        XCTAssertNil(RemoteLink.read(RemoteLink.file(home: home)))
    }

    /// A test build's crok signs in to the dev relay and keeps that sign-in in `credentials-dev.json`;
    /// build-app.sh writes the name into the app, so Settings reads the file its crok writes.
    func testTheLinkFileIsTheOneTheBundledCrokUses() throws {
        func bundle(_ name: Any?) throws -> Bundle {
            let url = directory.appendingPathComponent("App-\(UUID().uuidString).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "dev.chenli.crok.desktop.tests.\(UUID().uuidString)"]
            if let name { info[RemoteLink.credentialsFileInfoKey] = name }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: url))
        }
        let home = directory.appendingPathComponent("home")
        XCTAssertEqual(RemoteLink.file(home: home, bundle: try bundle(nil)).lastPathComponent, "credentials.json")
        XCTAssertEqual(RemoteLink.file(home: home, bundle: try bundle("credentials.json")).lastPathComponent, "credentials.json")
        let dev = RemoteLink.file(home: home, bundle: try bundle("credentials-dev.json"))
        XCTAssertEqual(dev, home.appendingPathComponent("remote/credentials-dev.json"))
        for odd: Any in ["../config.toml", "credentials/../../x.json", "", 7] {
            XCTAssertEqual(RemoteLink.fileName(bundle: try bundle(odd)), "credentials.json", "\(odd)")
        }
        // The test runner's own bundle says nothing, so the tests read credentials.json.
        XCTAssertEqual(RemoteLink.file(home: home).lastPathComponent, "credentials.json")
    }

    func testTheBridgeStatusParsesAndTheBestLinkWins() {
        let status = RemoteBridgeStatus(params: ["state": "connected", "account": "Ada (ada@example.com)", "device": "Mac", "server": "https://x"])
        XCTAssertEqual(status, RemoteBridgeStatus(state: .connected, account: "Ada (ada@example.com)", device: "Mac", server: "https://x"))
        XCTAssertEqual(RemoteBridgeStatus(params: ["state": "off", "account": NSNull()])?.account, nil)
        XCTAssertNil(RemoteBridgeStatus(params: ["state": "sleeping"]))
        let off = RemoteBridgeStatus(state: .off), connecting = RemoteBridgeStatus(state: .connecting), connected = RemoteBridgeStatus(state: .connected)
        XCTAssertNil(RemoteBridgeStatus.combined([]))
        XCTAssertEqual(RemoteBridgeStatus.combined([off, connecting])?.state, .connecting)
        XCTAssertEqual(RemoteBridgeStatus.combined([off, connected, connecting])?.state, .connected)
    }

    // MARK: Settings › Remote control

    private final class Opened { var urls: [URL] = [] }

    private func model(environment: [String: String] = [:]) throws -> (RemoteControlModel, URL, Opened) {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = try fixtureExecutable()
        let model = RemoteControlModel(runner: .crok(environment: ["CROK_HOME": home.path].merging(environment) { $1 }) { executable.path }, home: home)
        let opened = Opened()
        model.openURL = { opened.urls.append($0) }
        return (model, home, opened)
    }

    func testTheModelReadsTheLinkAndTheSwitchAndFollowsTheTerminal() throws {
        let (model, home, _) = try model()
        XCTAssertNil(model.link)
        XCTAssertTrue(model.enabled, "on until config.toml turns it off")

        // Signed in from the terminal: seen at the next check.
        try writeLink(Self.linkJSON, home: home)
        try Data("[remote]\nurl = \"https://quiet-otter-123.convex.cloud\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        model.refreshIfChanged()
        XCTAssertEqual(model.link?.deviceName, "Charlie's MacBook Pro")

        // The switch writes `[remote] enabled` and keeps the rest of the table.
        XCTAssertNil(model.setEnabled(false))
        XCTAssertFalse(model.enabled)
        let config = GrokConfig(url: home.appendingPathComponent("config.toml"))
        XCTAssertEqual(config.bool("enabled", in: "remote"), false)
        XCTAssertEqual(config.string("url", in: "remote"), "https://quiet-otter-123.convex.cloud")
        XCTAssertEqual(model.command("on"), "✓ Sharing tasks with your phone: on")
        XCTAssertTrue(model.enabled)
        XCTAssertNil(model.command(""), "no argument: Settings opens instead")

        // Signed out from the terminal.
        try FileManager.default.removeItem(at: RemoteLink.file(home: home))
        model.refreshIfChanged()
        XCTAssertNil(model.link)
    }

    func testSigningInShowsTheCodeOpensThePageAndEndsSignedIn() async throws {
        let (model, home, opened) = try model()
        model.signIn()
        XCTAssertEqual(model.phase, .starting)
        try await eventually { if case .waiting = model.phase { return true } else { return false } }
        guard case .waiting(let code) = model.phase else { return XCTFail("no code shown") }
        XCTAssertEqual(code.userCode, "BCDF-GHJK")
        XCTAssertEqual(code.server, "http://127.0.0.1:3210", "crok picked the relay itself")
        XCTAssertEqual(opened.urls, [URL(string: "http://127.0.0.1:9/link?code=BCDF-GHJK")!], "the page with the code opens at once")
        model.openSignInPage()
        XCTAssertEqual(opened.urls.count, 2)

        // Approved on the web.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("remote/approve"))
        try await eventually { model.phase == .idle }
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.link?.account.name, "Fixture Tester")
        XCTAssertEqual(model.link?.deviceName, "Fixture Mac")
        XCTAssertEqual(model.link?.server, "http://127.0.0.1:3210")

        model.signOut()
        XCTAssertEqual(model.phase, .signingOut)
        try await eventually { model.phase == .idle }
        XCTAssertNil(model.link)
        XCTAssertNil(model.failure)
        XCTAssertNil(model.notice)
    }

    func testACancelledSignInIsNotAFailure() async throws {
        let (model, _, _) = try model()
        model.signIn()
        try await eventually { if case .waiting = model.phase { return true } else { return false } }
        model.cancelSignIn()
        try await eventually { model.phase == .idle }
        XCTAssertNil(model.failure)
        XCTAssertNil(model.link)
    }

    func testAFailedSignInSaysWhyInCroksWords() async throws {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        var arguments: [String] = []
        let runner = RemoteCLIRunner(
            executable: { "/bin/false" },
            stream: { args, onLine, onExit in
                arguments = args
                DispatchQueue.main.async {
                    onLine(#"{"event":"error","message":"The relay could not be reached."}"#)
                    onExit(1, "")
                }
                return {}
            },
            run: { _ in GrokCLI.Output(status: 1, stdout: Data(), stderr: "Error: relay unreachable\n") })
        let model = RemoteControlModel(runner: runner, home: home)
        model.signIn()
        XCTAssertEqual(arguments, ["remote", "login", "--json", "--no-browser"], "no --server: crok picks the relay")
        try await eventually { model.phase == .idle }
        XCTAssertEqual(model.failure, "The relay could not be reached.")
    }

    func testASignOutTheRelayDidNotHearSaysWhatToDo() async throws {
        let (model, home, _) = try model(environment: ["CROK_FIXTURE_REMOTE_OFFLINE": "1"])
        try writeLink(Self.linkJSON, home: home)
        model.refresh()
        model.signOut()
        try await eventually { model.phase == .idle }
        XCTAssertNil(model.link)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.notice, .notUnlinked)
    }

    /// Against a real relay, with a real crok: CROK_DESKTOP_REMOTE_E2E_BINARY names the crok, CROK_DESKTOP_REMOTE_E2E_RELAY
    /// the relay, and CROK_DESKTOP_REMOTE_E2E_DIR a folder where the test writes the code (`code.txt`) for someone to
    /// approve within 2 minutes. The page the app would open is recorded, not opened.
    func testRealCrokSignsInAndOutAgainstARelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["CROK_DESKTOP_REMOTE_E2E_BINARY"], let relay = environment["CROK_DESKTOP_REMOTE_E2E_RELAY"],
              let folder = environment["CROK_DESKTOP_REMOTE_E2E_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_REMOTE_E2E_BINARY, _RELAY and _DIR") }
        let home = directory.appendingPathComponent("e2e-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The app never names a relay; this test points crok's own choice at the one under test.
        let model = RemoteControlModel(runner: .crok(environment: ["CROK_HOME": home.path, "CROK_REMOTE_URL": relay]) { binary }, home: home)
        let opened = Opened()
        model.openURL = { opened.urls.append($0) }
        // A sign-in cancelled while it waits ends at once and says nothing.
        model.signIn()
        try await eventually(timeout: 60) { if case .waiting = model.phase { return true } else { return model.failure != nil } }
        model.cancelSignIn()
        try await eventually(timeout: 5) { model.phase == .idle }
        XCTAssertNil(model.failure)
        XCTAssertNil(model.link)
        opened.urls = []

        model.signIn()
        try await eventually(timeout: 60) { if case .waiting = model.phase { return true } else { return model.failure != nil } }
        XCTAssertNil(model.failure)
        guard case .waiting(let code) = model.phase else { return XCTFail("no code: \(model.failure ?? "")") }
        print("e2e code: \(code.userCode) page: \(code.page?.absoluteString ?? "none") server: \(code.server) device: \(code.deviceName)")
        XCTAssertEqual(opened.urls, code.page.map { [$0] } ?? [])
        try Data(code.userCode.utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("code.txt"))
        try await eventually(timeout: 120) { model.phase == .idle }
        XCTAssertNil(model.failure)
        let link = try XCTUnwrap(model.link, "signed in")
        print("e2e signed in: \(link.account.title ?? "?") <\(link.account.subtitle ?? "")> device \(link.deviceName) id \(link.deviceID) relay \(link.server)")
        XCTAssertEqual(link.server, relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertNil(GrokConfig(url: home.appendingPathComponent("config.toml")).string("url", in: "remote"),
                     "the relay is not written into config.toml")
        let raw = try String(contentsOf: RemoteLink.file(home: home), encoding: .utf8)
        XCTAssertTrue(raw.contains("refreshToken"), "the file has the token; the app never reads it")
        XCTAssertFalse(String(describing: link).contains("crr_"))

        model.checkStatus(force: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await eventually(timeout: 20) { model.phase == .idle }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTAssertNil(model.notice, "the relay knows this Mac")
        XCTAssertNotNil(model.link)

        model.signOut()
        try await eventually(timeout: 30) { model.phase == .idle }
        XCTAssertNil(model.failure)
        XCTAssertNil(model.notice, "the relay heard the sign-out")
        XCTAssertNil(model.link)
    }

    func testRemoteCommandOpensSettingsAtItsSectionOrSwitchesSharing() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown(); try? FileManager.default.removeItem(at: RemoteControlModel.defaultHome) }
        XCTAssertTrue(store.handleDesktopCommand("remote", arguments: ""))
        XCTAssertTrue(store.showSettings)
        XCTAssertEqual(store.settingsFocus, .remoteControl)
        XCTAssertEqual(store.remoteControl.home, RemoteControlModel.defaultHome, "tests never touch ~/.crok")
        XCTAssertTrue(store.handleDesktopCommand("remote", arguments: "off"))
        XCTAssertEqual(store.banner, "✓ Sharing tasks with your phone: off")
        XCTAssertEqual(GrokConfig(url: store.remoteControl.configURL).bool("enabled", in: "remote"), false)
        XCTAssertEqual(DesktopCommands.catalog.first { $0.name == "remote" }?.argumentHint, "[on|off]")
        XCTAssertEqual(DesktopCommands.turnPolicy("remote", arguments: ""), .runNow)
    }

    // MARK: Tasks

    /// The fixture harness, which records each process it starts (and whether it may run a
    /// bridge) and every client message, and reports a connected bridge like a signed-in crok.
    @MainActor
    private final class HarnessFixture {
        let directory: URL
        let store: AppStore

        init(directory: URL, executable: URL) {
            self.directory = directory
            store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
            let project = Project(path: directory.path)
            store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        }

        private func lines(_ name: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }

        /// `CROK_REMOTE_BRIDGE` as each harness process saw it ("" when unset).
        var bridges: [String] { lines("processes.jsonl").map { $0["bridge"] as? String ?? "" } }
        var methods: [String] { lines("requests.jsonl").compactMap { $0["method"] as? String } }
    }

    private func harness() throws -> HarnessFixture {
        let main = #"""
LOG = os.path.join(os.path.dirname(__file__), "requests.jsonl")
with open(os.path.join(os.path.dirname(__file__), "processes.jsonl"), "a") as handle:
    handle.write(json.dumps({"pid": os.getpid(), "bridge": os.environ.get("CROK_REMOTE_BRIDGE")}) + "\n")
os.environ.setdefault("CROK_FIXTURE_REMOTE_STATUS", "connected")
class LoggingHarness(MockHarness):
    def handle(self, message):
        with open(LOG, "a") as handle:
            handle.write(json.dumps(message) + "\n")
        super().handle(message)
LoggingHarness().run()
"""#
        return HarnessFixture(directory: directory, executable: try fixtureExecutable(main: main))
    }

    func testHelperHarnessesRunWithoutABridgeAndTasksWithOne() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        await store.prepareSessionOptions()
        XCTAssertEqual(fixture.bridges, ["0"], "the model catalog's harness")
        XCTAssertNil(store.remoteLink, "a helper reports no link")
        store.syncHistory()
        try await eventually { !store.syncing }
        await store.refreshCommands()
        XCTAssertEqual(fixture.bridges.filter { $0 == "0" }.count, fixture.bridges.count, "every helper: \(fixture.bridges)")

        store.draft = "Hello"
        store.send()
        try await eventually { !store.run.isRunning && store.conversation?.messages.contains { $0.kind == .assistant } == true }
        XCTAssertEqual(fixture.bridges.last, "", "a task's harness may run a bridge")
        XCTAssertEqual(store.remoteLink?.state, .connected, "the task's bridge says it is linked")
        XCTAssertEqual(store.remoteLink?.device, "Fixture Mac")

        // The harness goes, and its link with it.
        let id = try XCTUnwrap(store.state.selectedConversationID)
        store.discardConnection(id)
        XCTAssertNil(store.remoteLink)
    }

    func testAPromptFromAPhoneShowsInTheTranscriptAndItsTurnEnds() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        store.draft = "Look around fixture:remote"
        store.send()
        try await eventually(timeout: 10) { store.conversation?.messages.contains { $0.remoteFrom != nil } == true && !store.run.isRunning
            && store.conversation?.messages.last?.text.contains("remote") == true }
        let messages = try XCTUnwrap(store.conversation?.messages)
        let prompt = try XCTUnwrap(messages.firstIndex { $0.remoteFrom != nil })
        XCTAssertEqual(messages[prompt].kind, .user)
        XCTAssertEqual(messages[prompt].text, "What changed on the fixture? (sent from a phone)")
        XCTAssertEqual(messages[prompt].remoteFrom, "Fixture iPhone")
        XCTAssertEqual(messages.filter { $0.kind == .user }.count, 2, "the typed prompt and the phone's, each once")
        XCTAssertEqual(messages.last?.kind, .assistant)
        XCTAssertGreaterThan(messages.count - 1, prompt, "the reply follows the phone's prompt")
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertTrue(store.remoteTurns.isEmpty)
        XCTAssertEqual(TranscriptUserRow.remoteCaption("Fixture iPhone"), "from Fixture iPhone")
        XCTAssertEqual(TranscriptUserRow.remoteCaption(""), "from your phone or the web")
        // The relay calls a browser "Web".
        XCTAssertEqual(TranscriptUserRow.remoteCaption("Web"), "from the web")
        XCTAssertEqual(TranscriptUserRow.remoteSymbol("Web"), "globe")
        XCTAssertEqual(TranscriptUserRow.remoteSymbol("Fixture iPhone"), "iphone")

        // The task takes a typed prompt again.
        store.draft = "And now me"
        store.send()
        try await eventually { !store.run.isRunning && store.conversation?.messages.filter { $0.kind == .user }.count == 3 }
        XCTAssertEqual(fixture.methods.filter { $0 == "session/prompt" }.count, 2, "the phone's prompt was the bridge's to send")
    }

    func testStopEndsATurnAPhoneStarted() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        store.draft = "Wait for it fixture:remote-wait"
        store.send()
        try await eventually(timeout: 10) { store.conversation?.messages.contains { $0.remoteFrom != nil } == true }
        let id = try XCTUnwrap(store.state.selectedConversationID)
        XCTAssertTrue(store.run.isRunning, "the task works while the phone's prompt runs")
        XCTAssertEqual(store.run.phase, "Working")
        XCTAssertEqual(store.remoteTurns[id]?.hasPrefix("remote-"), true)
        XCTAssertEqual(store.transcriptRevision(of: id) > 0, true)

        store.cancel()
        try await eventually(timeout: 2.5) { !store.run.isRunning }
        XCTAssertEqual(store.run.phase, "Stopped")
        XCTAssertTrue(fixture.methods.contains("session/cancel"))
        XCTAssertNotNil(store.clients[id], "the turn was stopped, not the harness")
        XCTAssertTrue(store.remoteTurns.isEmpty)
    }

    func testOnlyTheRemoteTurnsOwnEndFinishesIt() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Task", sessionID: "s1")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        store.startRemoteTurn(["sessionId": "s1", "promptId": "remote-c1", "text": "Hi", "from": "Pixel 9"], id: task.id)
        XCTAssertEqual(store.runs[task.id]?.isRunning, true)
        XCTAssertEqual(store.task(task.id)?.messages.last?.remoteFrom, "Pixel 9")
        // Another turn's end, and a replayed one, leave it running.
        XCTAssertFalse(store.receiveRemote("x.ai/session/update", params: ["sessionId": "s1", "update": ["sessionUpdate": "turn_completed", "prompt_id": "p-local", "stop_reason": "end_turn"]], id: task.id))
        store.replaying.insert(task.id)
        _ = store.receiveRemote("x.ai/session/update", params: ["sessionId": "s1", "update": ["sessionUpdate": "turn_completed", "prompt_id": "remote-c1", "stop_reason": "end_turn"]], id: task.id)
        store.replaying.remove(task.id)
        XCTAssertEqual(store.runs[task.id]?.isRunning, true)
        // Its own end, on the legacy rail.
        _ = store.receiveRemote("x.ai/session/prompt_complete", params: ["sessionId": "s1", "promptId": "remote-c1", "stopReason": "end_turn"], id: task.id)
        XCTAssertEqual(store.runs[task.id]?.isRunning, false)
        XCTAssertEqual(store.runs[task.id]?.phase, "Ready")
        // A status arrives on its own: the store keeps it per task.
        XCTAssertTrue(store.receiveRemote("x.ai/remote/status", params: ["state": "connecting"], id: task.id))
        XCTAssertEqual(store.remoteLink?.state, .connecting)
    }

    // MARK: Other computers

    private let otherComputers: [String: Any] = [
        "signedIn": true,
        "computers": [[
            "deviceId": "d2", "deviceName": "Office PC", "online": true,
            "projects": [[
                "key": "d2:/w/api", "name": "api", "path": "/w/api",
                "sessions": [
                    ["sessionId": "relay:k1", "title": "Fix the login redirect", "cwd": "/w/api", "status": "running", "running": true,
                     "lastActivityAt": 1_792_000_000_000.0, "model": "grok-code-fast-1", "gitBranch": "fix/login-redirect",
                     "usage": ["inputTokens": 1_200, "outputTokens": 300, "cachedTokens": 800, "outputTokensPerSecond": 42.5]],
                    ["sessionId": "not-a-relay-id", "title": "Ignored"],
                ],
            ]],
        ]],
    ]

    func testOtherComputersParseAndOpenAsTasksTheyRun() throws {
        let computers = RemoteComputer.list(otherComputers)
        XCTAssertEqual(computers.count, 1)
        let computer = try XCTUnwrap(computers.first)
        XCTAssertEqual(computer.name, "Office PC")
        XCTAssertEqual(computer.sessions.map(\.sessionID), ["relay:k1"], "only relay ids are sessions of another computer")
        let entry = try XCTUnwrap(computer.sessions.first)
        XCTAssertTrue(entry.isWorking)
        XCTAssertEqual(entry.lastActivityAt.timeIntervalSince1970, 1_792_000_000, accuracy: 1)
        XCTAssertEqual(entry.gitBranch, "fix/login-redirect")
        XCTAssertEqual(entry.usage?.inputTokens, 1_200)
        XCTAssertEqual(entry.usage?.tokensPerSecond, 42.5)

        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let local = Project(path: directory.path)
        store.state = DesktopState(projects: [local], selectedProjectID: local.id)
        store.noteRemoteComputers(otherComputers)
        XCTAssertEqual(store.remoteComputers, computers)
        store.openRemoteSession(entry, on: computer)
        let task = try XCTUnwrap(store.conversation)
        XCTAssertEqual(task.sessionID, "relay:k1")
        XCTAssertEqual(task.remote, RemoteTaskInfo(computer: "Office PC", deviceID: "d2", cwd: "/w/api"))
        XCTAssertEqual(task.projectID, RemoteSessions.projectID)
        XCTAssertEqual(store.project?.id, RemoteSessions.projectID, "its harness runs in the app's own folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.remoteProject.path))
        XCTAssertEqual(store.workspace.branch, "fix/login-redirect", "its computer's branch, not a local one")
        XCTAssertTrue(store.workspace.isRemote)
        XCTAssertEqual(store.features.tokens.meters[task.id]?.readout(turnRunning: false),
                       TokenReadout(inputTokens: 1_200, outputTokens: 300, cachedTokens: 800,
                                    cacheHitRate: 800.0 / 1_200.0, rate: .average(42.5)))
        XCTAssertEqual(store.state.projects, [local], "the projects list stays as it was")
        // Opening it again selects the same task.
        store.newTask()
        store.openRemoteSession(entry, on: computer)
        XCTAssertEqual(store.state.conversations.count, 1)
        XCTAssertEqual(store.conversation?.id, task.id)
    }

    /// A session a phone (or the web, or another computer) started on this Mac is a task here at once, in its
    /// project (added when the app has none for that folder); it shows as working while the phone's turn runs
    /// there, is unread when that turn ends, and a task the person removed does not come back.
    func testASessionStartedOnThisMacFromAPhoneBecomesATaskInItsProject() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let local = Project(path: directory.path)
        store.state = DesktopState(projects: [local], selectedProjectID: local.id)
        let other = directory.appendingPathComponent("api").path
        func payload(_ sessions: [[String: Any]]) -> [String: Any] {
            ["signedIn": true, "computers": [], "here": ["deviceId": "me", "sessions": sessions]]
        }
        func row(_ id: String, _ title: String, project: String, status: String) -> [String: Any] {
            ["sessionId": id, "relayId": "relay:\(id)", "title": title, "cwd": project, "projectPath": project, "status": status,
             "running": true, "lastActivityAt": 1_792_000_000_000.0, "startedFrom": ["kind": "phone", "name": "iPhone", "at": 1.0]]
        }
        store.noteRemoteComputers(payload([row("s1", "Fix the login redirect", project: directory.path, status: "running"),
                                           row("s2", "Add the health check", project: other, status: "idle")]))
        let first = try XCTUnwrap(store.state.conversations.first { $0.sessionID == "s1" })
        XCTAssertEqual(first.projectID, local.id, "the project the app already has")
        XCTAssertEqual(first.title, "Fix the login redirect")
        XCTAssertNil(first.remote, "this Mac's own session, not another computer's")
        let second = try XCTUnwrap(store.state.conversations.first { $0.sessionID == "s2" })
        XCTAssertEqual(store.projectRecord(second.projectID)?.path, other, "a folder the app did not have is added")
        XCTAssertEqual(store.state.projects.count, 2)
        XCTAssertTrue(store.unreadConversationIDs.isSuperset(of: [first.id, second.id]))
        XCTAssertTrue(store.isWorkingElsewhere(first))
        XCTAssertFalse(store.isWorkingElsewhere(second))

        store.unreadConversationIDs = []
        // The phone's turn ends, and crok named the session: the task follows until it is opened here.
        store.noteRemoteComputers(payload([row("s1", "Login redirect fixed", project: directory.path, status: "idle"),
                                           row("s2", "Add the health check", project: other, status: "idle")]))
        XCTAssertFalse(store.isWorkingElsewhere(first))
        XCTAssertTrue(store.unreadConversationIDs.contains(first.id))
        XCTAssertEqual(store.state.conversations.first { $0.id == first.id }?.title, "Login redirect fixed")
        XCTAssertEqual(store.state.conversations.filter { $0.sessionID == "s1" }.count, 1, "listed again, not added again")

        store.state.deletedSessionIDs.insert("s3")
        store.noteRemoteComputers(payload([row("s3", "Removed here", project: directory.path, status: "idle")]))
        XCTAssertNil(store.state.conversations.first { $0.sessionID == "s3" })
        // A project the person removed does not come back with the session another device started there.
        store.removeProject(second.projectID)
        store.noteRemoteComputers(payload([row("s2", "Add the health check", project: other, status: "idle")]))
        XCTAssertNil(store.state.conversations.first { $0.sessionID == "s2" })
        XCTAssertEqual(store.state.projects, [local])
        // An older crok's list has no `here`: nothing changes.
        store.noteRemoteComputers(["signedIn": true, "computers": []])
        XCTAssertEqual(store.state.conversations.map(\.sessionID), ["s1"])
    }

    func testAnApprovalAnsweredOnAnotherDeviceLeavesTheTask() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Task", sessionID: "s1")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        let allow = PermissionOption(id: "allow", name: "Allow", kind: "allow_once")
        store.runs[task.id, default: RunState()].approvals = [
            Approval(requestID: 7, title: "Run ls", detail: "ls", options: [allow], toolCallID: "call_1"),
            Approval(requestID: 8, title: "Edit a file", detail: "a.txt", options: [allow], toolCallID: "call_2"),
        ]
        XCTAssertTrue(store.receiveRemote("x.ai/remote/permission_resolved", params: ["sessionId": "s1", "toolCallId": "call_1"], id: task.id))
        XCTAssertEqual(store.runs[task.id]?.approvals.map(\.toolCallID), ["call_2"])
        XCTAssertEqual(store.banner, L10n.t("remote_answered_elsewhere", "Answered on another device."))
    }

    // MARK: New tasks on other computers

    private let newTaskComputers: [String: Any] = [
        "signedIn": true,
        "computers": [
            ["deviceId": "d2", "deviceName": "Office PC", "online": true,
             "projects": [
                ["key": "d2:/w/api", "name": "api", "path": "/w/api", "sessions": []],
                ["key": "d2:w/relative", "name": "relative", "path": "w/relative", "sessions": []],
             ]],
            ["deviceId": "fixture-offline", "deviceName": "Fixture PC", "online": true,
             "projects": [["key": "fo:/w/site", "name": "site", "path": "/w/site", "sessions": []]]],
            ["deviceId": "d3", "deviceName": "Studio", "online": false,
             "projects": [["key": "d3:/w/app", "name": "app", "path": "/w/app", "sessions": []]]],
        ],
    ]

    /// This Mac's own models, which a task of another computer must neither list nor replace.
    private let localModels = [ModelOption(id: "fixture-grok-build", name: "Grok Build (fixture)"), ModelOption(id: "other-gpt", name: "This Mac's GPT")]

    /// The fixture's background "remote host", as the app keeps one while signed in, and the other computers it lists.
    private func remoteHost(for store: AppStore, executable: URL) async throws -> ACPClient {
        let host = ACPClient()
        try FileManager.default.createDirectory(atPath: store.remoteProject.path, withIntermediateDirectories: true)
        try host.start(executable: executable.path, cwd: store.remoteProject.path)
        let initial = try await store.initialize(host)
        try await store.authenticate(host, initial: initial)
        store.remoteHost = host
        store.remoteHostReady = true
        store.noteRemoteComputers(newTaskComputers)
        return host
    }

    private func useLocalModels(_ store: AppStore) {
        store.state.modelCatalog = localModels
        store.state.selectedModelID = "fixture-grok-build"
        store.catalogRun.models = localModels
        store.catalogRun.modelID = "fixture-grok-build"
    }

    func testANewTaskOnAnotherComputerStartsThereAndPicksThatComputersModels() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        useLocalModels(store)
        let localProject = try XCTUnwrap(store.project)
        _ = try await remoteHost(for: store, executable: directory.appendingPathComponent("fixture-crok"))
        let computer = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d2" })

        store.draft = "A draft of this Mac's"
        store.newRemoteTask(on: computer, in: computer.projects[0])
        let target = RemoteNewTask(deviceID: "d2", computer: "Office PC", path: "/w/api")
        XCTAssertNil(store.conversation)
        XCTAssertEqual(store.project?.id, RemoteSessions.projectID)
        XCTAssertEqual(store.remoteStartTarget, target)
        XCTAssertEqual(store.draftLocation, .remoteNewTask(target))
        XCTAssertEqual(store.draft, "", "each new task has its own draft")
        XCTAssertFalse(store.run.models.contains { $0.id == "fixture-grok-build" }, "this Mac's models are not that computer's")
        try await eventually { store.run.models.map(\.id) == ["other-claude", "other-gpt", "other-plain"] }
        XCTAssertEqual(store.run.modelID, "", "that computer's own choice until one is picked")
        XCTAssertNil(store.ensureConversation(title: "Panel"), "a panel does not start a session of this Mac's for it")

        store.draft = "Add a health check"
        store.send()
        let task = try XCTUnwrap(store.conversation)
        XCTAssertEqual(task.remote, RemoteTaskInfo(computer: "Office PC", deviceID: "d2", cwd: "/w/api"))
        XCTAssertEqual(task.projectID, RemoteSessions.projectID)
        XCTAssertEqual(task.title, "Add a health check")
        XCTAssertEqual(task.messages.map(\.text), ["Add a health check"], "the prompt shows at once")
        XCTAssertNil(task.modelID, "not this Mac's default")
        XCTAssertTrue(store.run.isRunning)
        XCTAssertEqual(store.draft, "")

        try await eventually(timeout: 10) { store.conversation?.messages.contains { $0.kind == .assistant } == true && !store.run.isRunning }
        let messages = try XCTUnwrap(store.conversation?.messages)
        XCTAssertEqual(messages.filter { $0.kind == .user }.map(\.text), ["Add a health check"], "once, though the viewer announced it")
        XCTAssertNil(messages.first?.remoteFrom, "typed here: no caption")
        XCTAssertEqual(messages.last?.kind, .assistant)
        XCTAssertEqual(store.conversation?.sessionID?.hasPrefix("relay:fixture-new-"), true)
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertTrue(store.remoteTurns.isEmpty)
        XCTAssertTrue(store.remoteFirstPrompts.isEmpty)
        let methods = fixture.methods
        XCTAssertEqual(methods.filter { $0 == "_x.ai/remote/new_session" }.count, 1)
        XCTAssertTrue(methods.contains("session/load"))
        XCTAssertFalse(methods.contains("session/new"), "no session of this Mac's own")
        XCTAssertFalse(methods.contains("session/prompt"), "the computer runs the first prompt itself")
        XCTAssertFalse(methods.contains("session/set_config_option"), "the session keeps the model it has there")

        // That computer's models, kept apart from this Mac's.
        XCTAssertEqual(store.run.models.map(\.id), ["other-claude", "other-gpt", "other-plain"])
        XCTAssertEqual(store.run.modelID, "other-claude")
        XCTAssertEqual(store.run.reasoningOptions.map(\.id), ["low", "medium", "high", "max"])
        XCTAssertEqual(store.run.reasoningID, "medium")
        XCTAssertEqual(store.modelOption("other-gpt")?.name, "GPT-5 (Office PC)", "named from that computer's list")
        XCTAssertEqual(store.state.remoteModelCatalogs["d2"]?.map(\.id), ["other-claude", "other-gpt", "other-plain"])
        XCTAssertEqual(store.state.modelCatalog, localModels)
        XCTAssertEqual(store.catalogRun.models, localModels)

        // Changed on another device: the pickers follow.
        store.draft = "Switch it fixture:model-elsewhere"
        store.send()
        try await eventually { store.run.modelID == "other-gpt" && !store.run.isRunning }
        XCTAssertEqual(store.run.reasoningID, "high")
        XCTAssertEqual(store.run.reasoningOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(store.conversation?.modelID, "other-gpt")

        // Picked here: that computer applies it.
        let plain = try XCTUnwrap(store.run.models.first { $0.id == "other-plain" })
        store.setModel(plain)
        try await eventually { store.run.modelID == "other-plain" && !store.run.isConfiguring && !store.run.isRunning }
        XCTAssertTrue(store.run.reasoningOptions.isEmpty, "that model has no thinking level there")
        let claude = try XCTUnwrap(store.run.models.first { $0.id == "other-claude" })
        store.setModel(claude)
        try await eventually { store.run.modelID == "other-claude" && !store.run.isConfiguring && !store.run.isRunning }
        let most = try XCTUnwrap(store.run.reasoningOptions.first { $0.id == "max" })
        store.setReasoning(most)
        try await eventually { store.run.reasoningID == "max" && !store.run.isConfiguring && !store.run.isRunning }
        XCTAssertNil(store.banner)
        XCTAssertEqual(store.conversation?.modelID, "other-claude")
        XCTAssertEqual(store.conversation?.reasoningID, "max")
        XCTAssertEqual(fixture.methods.filter { $0 == "session/set_config_option" }.count, 3)
        // This Mac's catalog and defaults are as they were.
        XCTAssertEqual(store.state.selectedModelID, "fixture-grok-build")
        XCTAssertEqual(store.state.modelCatalog, localModels)
        XCTAssertEqual(store.catalogRun.models, localModels)
        XCTAssertEqual(store.catalogRun.modelID, "fixture-grok-build")

        // ⌘N beside it starts another task on that computer, in the same folder.
        store.newTask()
        XCTAssertEqual(store.remoteStartTarget, target)
        XCTAssertEqual(store.run.models.map(\.id), ["other-claude", "other-gpt", "other-plain"], "that computer's list")
        XCTAssertEqual(store.run.modelID, "")
        // Back in a project of this Mac's, its own models.
        store.selectProject(localProject.id)
        XCTAssertNil(store.remoteStartTarget)
        XCTAssertEqual(store.run.models, localModels)
        XCTAssertEqual(store.modelOption("other-gpt")?.name, "This Mac's GPT")
    }

    func testANewTaskOnAnotherComputerStartsWithTheModelAndThinkingLevelPickedThere() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        useLocalModels(store)
        _ = try await remoteHost(for: store, executable: directory.appendingPathComponent("fixture-crok"))
        let computer = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d2" })
        store.newRemoteTask(on: computer, in: computer.projects[0])
        // Before any session there exists, that computer's own list (`x.ai/remote/models`).
        try await eventually { store.run.models.map(\.id) == ["other-claude", "other-gpt", "other-plain"] }
        XCTAssertTrue(fixture.methods.contains("_x.ai/remote/models"))
        XCTAssertEqual(store.run.modelID, "")
        XCTAssertTrue(store.run.reasoningOptions.isEmpty, "no thinking level to pick before a model is")

        let gpt = try XCTUnwrap(store.run.models.first { $0.id == "other-gpt" })
        store.setModel(gpt)
        XCTAssertEqual(store.run.modelID, "other-gpt")
        XCTAssertEqual(store.run.reasoningOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(store.run.reasoningID, "", "that model's own default until one is picked")
        let high = try XCTUnwrap(store.run.reasoningOptions.first { $0.id == "high" })
        store.setReasoning(high)
        XCTAssertEqual(store.run.reasoningID, "high")
        XCTAssertEqual(store.state.selectedModelID, "fixture-grok-build", "this Mac's default is untouched")
        XCTAssertEqual(store.catalogRun.modelID, "fixture-grok-build")

        store.draft = "Start on GPT"
        store.send()
        XCTAssertEqual(store.remoteStartModelID, "", "the pick went with the prompt")
        try await eventually(timeout: 10) { store.conversation?.messages.contains { $0.kind == .assistant } == true && !store.run.isRunning }
        XCTAssertEqual(store.run.modelID, "other-gpt", "that computer opened the session on the picked model")
        XCTAssertEqual(store.run.reasoningID, "high")
        XCTAssertFalse(fixture.methods.contains("session/set_config_option"), "chosen when the session started, not after")
    }

    func testAComputerThatStartedTheTaskFirstShowsThePromptOnceAndFinishesFromTheList() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        _ = try await remoteHost(for: store, executable: directory.appendingPathComponent("fixture-crok"))
        let computer = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d2" })
        store.newRemoteTask(on: computer, in: computer.projects[0])
        store.draft = "Quick one fixture:quick"
        store.send()
        try await eventually(timeout: 10) { store.conversation?.messages.contains { $0.kind == .assistant } == true && store.operations.isEmpty }
        let id = try XCTUnwrap(store.state.selectedConversationID)
        XCTAssertEqual(store.conversation?.messages.filter { $0.kind == .user }.count, 1, "the history had it already")
        XCTAssertNil(store.remoteFirstPrompts[id])
        // Nothing announced the turn: it runs until the list shows the session at rest.
        XCTAssertTrue(store.run.isRunning)
        XCTAssertEqual(store.remoteTurns[id], RemoteSessions.startingTurn)
        let session = try XCTUnwrap(store.conversation?.sessionID)
        func list(_ status: String, preview: String?) -> [String: Any] {
            var entry: [String: Any] = ["sessionId": session, "title": "Quick one", "cwd": "/w/api", "status": status, "lastActivityAt": 1_792_000_000_000.0]
            entry["preview"] = preview
            return ["computers": [["deviceId": "d2", "deviceName": "Office PC", "online": true,
                                   "projects": [["key": "d2:/w/api", "name": "api", "path": "/w/api", "sessions": [entry]]]]]]
        }
        store.noteRemoteComputers(list("idle", preview: nil))
        XCTAssertTrue(store.run.isRunning, "idle before any reply: the computer has only just taken it")
        store.noteRemoteComputers(list("running", preview: nil))
        XCTAssertTrue(store.run.isRunning)
        store.noteRemoteComputers(list("idle", preview: "Started on the other computer"))
        XCTAssertFalse(store.run.isRunning)
        XCTAssertEqual(store.run.phase, "Ready")
        XCTAssertTrue(store.remoteTurns.isEmpty)
    }

    func testANewTaskThatCannotStartSaysWhyAndCanBeSentAgain() async throws {
        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.auto) }
        _ = try await remoteHost(for: store, executable: directory.appendingPathComponent("fixture-crok"))

        // The relay finds the computer offline though the list said otherwise.
        let stale = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "fixture-offline" })
        store.newRemoteTask(on: stale, in: stale.projects[0])
        store.draft = "Deploy the site"
        store.send()
        try await eventually { store.run.phase == "Needs attention" && !store.run.isRunning }
        let offline = "Fixture PC is offline: start crok or Crok Desktop there."
        XCTAssertEqual(store.banner, offline)
        XCTAssertEqual(store.conversation?.messages.last?.text, offline)
        XCTAssertNil(store.conversation?.sessionID, "no session started")
        XCTAssertEqual(store.remoteStartTarget, RemoteNewTask(deviceID: "fixture-offline", computer: "Fixture PC", path: "/w/site"))
        XCTAssertTrue(store.remoteTurns.isEmpty)
        // Sent again from the task, it asks the relay again.
        store.draft = "Deploy the site, please"
        store.send()
        try await eventually { fixture.methods.filter { $0 == "_x.ai/remote/new_session" }.count == 2 && !store.run.isRunning }
        XCTAssertEqual(store.state.conversations.count, 1, "the same task")
        XCTAssertFalse(fixture.methods.contains("session/new"))

        // A folder that is not a full path: the relay's reason.
        let office = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d2" })
        store.newRemoteTask(on: office, in: office.projects[1])
        store.draft = "Look around"
        store.send()
        try await eventually { store.run.phase == "Needs attention" && !store.run.isRunning }
        XCTAssertEqual(store.banner, "Could not start the task on Office PC: Choose a folder on the computer (a full path).")
        XCTAssertEqual(store.state.conversations.count, 2)
    }

    func testANewTaskWaitsForAComputerThatIsOnlineAndForTheRemoteHost() throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.auto) }
        let local = Project(path: directory.path)
        store.state = DesktopState(projects: [local], selectedProjectID: local.id)
        store.noteRemoteComputers(newTaskComputers)
        let studio = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d3" })
        store.newRemoteTask(on: studio, in: studio.projects[0])
        XCTAssertEqual(store.banner, "Studio is offline: start crok or Crok Desktop there.")
        XCTAssertEqual(store.state.selectedProjectID, local.id, "nothing opened for an offline computer")
        XCTAssertNil(store.remoteNewTask)

        // Without the remote host nothing can start; the draft stays.
        let office = try XCTUnwrap(store.remoteComputers.first { $0.deviceID == "d2" })
        store.newRemoteTask(on: office, in: office.projects[0])
        store.draft = "Hello there"
        store.send()
        XCTAssertEqual(store.banner, L10n.t("remote_new_task_no_host", "Remote control is not connected on this Mac. Check Settings › Remote control, then send again."))
        XCTAssertTrue(store.state.conversations.isEmpty)
        XCTAssertEqual(store.draft, "Hello there")
        // The computer goes offline while the new task is open.
        var payload = newTaskComputers
        var computers = try XCTUnwrap(payload["computers"] as? [[String: Any]])
        computers[0]["online"] = false
        payload["computers"] = computers
        store.noteRemoteComputers(payload)
        store.banner = nil
        store.send()
        XCTAssertEqual(store.banner, "Office PC is offline: start crok or Crok Desktop there.")
        XCTAssertTrue(store.state.conversations.isEmpty)
        XCTAssertEqual(store.draft, "Hello there")

        // A launch never comes back to a new task of another computer: its folder is not kept.
        store.flush()
        let relaunched = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { relaunched.shutdown() }
        XCTAssertEqual(relaunched.state.selectedProjectID, local.id)
    }

    func testAnotherComputersModelsStayApartFromThisMacsCatalog() async throws {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let local = Project(path: directory.path)
        var remoteTask = Conversation(projectID: RemoteSessions.projectID, title: "Fix the login redirect", sessionID: "relay:k1", modelID: "other-gpt", reasoningID: "high")
        remoteTask.remote = RemoteTaskInfo(computer: "Office PC", deviceID: "d2", cwd: "/w/api")
        let localTask = Conversation(projectID: local.id, title: "Mine", sessionID: "s1")
        store.state = DesktopState(projects: [local], conversations: [remoteTask, localTask], selectedProjectID: RemoteSessions.projectID,
                                   selectedConversationID: remoteTask.id)
        useLocalModels(store)

        // Before its session loads it lists nothing of this Mac's, and names its model from that computer's last list.
        XCTAssertTrue(store.run.models.isEmpty)
        XCTAssertNil(store.modelOption("other-gpt"), "this Mac's model of the same id does not name it")
        let remoteModels: [String: Any] = ["currentModelId": "other-gpt", "availableModels": [
            ["modelId": "other-claude", "name": "Claude Opus (Office PC)", "_meta": ["supportsReasoningEffort": true, "reasoningEfforts": ["low", "max"], "reasoningEffort": "low"]],
            ["modelId": "other-gpt", "name": "GPT-5 (Office PC)", "_meta": ["supportsReasoningEffort": true, "reasoningEfforts": ["low", "high"], "reasoningEffort": "high"]],
        ]]
        store.applyModels(remoteModels, id: remoteTask.id)
        XCTAssertEqual(store.runs[remoteTask.id]?.models.map(\.id), ["other-claude", "other-gpt"])
        XCTAssertEqual(store.state.modelCatalog, localModels, "this Mac's catalog is not replaced")
        XCTAssertEqual(store.catalogRun.models, localModels)
        XCTAssertEqual(store.state.remoteModelCatalogs["d2"]?.map(\.id), ["other-claude", "other-gpt"])
        store.runs.removeValue(forKey: remoteTask.id)
        XCTAssertEqual(store.run.models.map(\.id), ["other-claude", "other-gpt"], "that computer's last list")
        XCTAssertEqual(store.run.modelID, "other-gpt")
        XCTAssertEqual(store.run.reasoningOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(store.modelOption("other-gpt")?.name, "GPT-5 (Office PC)")
        store.applyModels(remoteModels, id: remoteTask.id)

        // Changed on another device, in either shape of the notification.
        XCTAssertTrue(store.receiveRemote("x.ai/session_notification", params: ["sessionId": "relay:k1", "update": [
            "sessionUpdate": "model_changed", "model_id": "other-claude", "reasoning_effort": "max"]], id: remoteTask.id))
        XCTAssertEqual(store.runs[remoteTask.id]?.modelID, "other-claude")
        XCTAssertEqual(store.runs[remoteTask.id]?.reasoningID, "max")
        XCTAssertEqual(store.runs[remoteTask.id]?.reasoningOptions.map(\.id), ["low", "max"])
        XCTAssertTrue(store.receiveRemote("x.ai/session_notification", params: ["params": ["sessionId": "relay:k1", "update": [
            "sessionUpdate": "model_changed", "model_id": "other-gpt"]]], id: remoteTask.id))
        XCTAssertEqual(store.runs[remoteTask.id]?.modelID, "other-gpt")
        XCTAssertEqual(store.runs[remoteTask.id]?.reasoningID, "high", "the model's own level when none is named")
        XCTAssertEqual(store.state.selectedModelID, "fixture-grok-build")
        // A task of this Mac's takes its model changes through its configuration, as before.
        XCTAssertFalse(store.receiveRemote("x.ai/session_notification", params: ["sessionId": "s1", "update": [
            "sessionUpdate": "model_changed", "model_id": "other-claude"]], id: localTask.id))
        XCTAssertNil(store.runs[localTask.id])

        // A task of another computer that has not started there never opens a session here.
        var unstarted = Conversation(projectID: RemoteSessions.projectID, title: "Not yet")
        unstarted.remote = RemoteTaskInfo(computer: "Office PC", deviceID: "d2", cwd: "/w/api")
        store.state.conversations.append(unstarted)
        store.selectConversation(unstarted)
        XCTAssertEqual(store.remoteStartTarget, RemoteNewTask(deviceID: "d2", computer: "Office PC", path: "/w/api"))
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.auto) }
        let operation = store.beginOperation(unstarted.id, phase: "Connecting")
        do {
            _ = try await store.connect(id: unstarted.id, project: store.remoteProject, operationID: operation)
            XCTFail("connected a task that has no session there")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This task has not started on Office PC yet. Send a prompt to start it.")
        }
        XCTAssertNil(store.clients[unstarted.id])
    }

    func testRemoteGitReadsComeFromThatComputer() async throws {
        let executable = try fixtureExecutable()
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: executable.path)
        defer { store.shutdown() }
        let local = Project(path: directory.path)
        var task = Conversation(projectID: RemoteSessions.projectID, title: "Fix the login redirect", sessionID: "relay:k1")
        task.remote = RemoteTaskInfo(computer: "Office PC", deviceID: "d2", cwd: "/w/api")
        store.state = DesktopState(projects: [local], conversations: [task], selectedProjectID: RemoteSessions.projectID,
                                   selectedConversationID: task.id)
        try FileManager.default.createDirectory(atPath: store.remoteProject.path, withIntermediateDirectories: true)

        let branches = await store.remoteBranches(conversationID: task.id)
        XCTAssertNil(branches.error)
        // Connecting read the session's info too: the footer's branch and figures are there before a turn runs.
        XCTAssertEqual(store.workspace.branch, "fix/login-redirect")
        XCTAssertEqual(store.features.tokens.meters[task.id]?.readout(turnRunning: false),
                       TokenReadout(inputTokens: 1_200, outputTokens: 300, cachedTokens: 800,
                                    cacheHitRate: 800.0 / 1_200.0, rate: .average(42.5)))
        XCTAssertEqual(branches.current?.name, "fix/login-redirect")
        XCTAssertEqual(branches.local.map(\.name), ["fix/login-redirect", "main"])
        XCTAssertEqual(branches.remote.map(\.name), ["origin/feature"])

        let loaded: GitGraph
        switch await store.remoteGraph(conversationID: task.id, scope: .all, limit: 100) {
        case .loaded(let graph): loaded = graph
        default: return XCTFail("the fixture's repository did not load")
        }
        XCTAssertEqual(loaded.root, "/w/api")
        XCTAssertEqual(loaded.currentBranch, "fix/login-redirect")
        XCTAssertEqual(loaded.commits.map(\.subject), ["Uncommitted changes · 1 file", "Fix the login redirect", "First commit"])
        XCTAssertEqual(loaded.commits[1].refs.map(\.kind), [.head])

        let commit = loaded.commits[1]
        guard case .success(let files) = await store.remoteCommitFiles(conversationID: task.id, commit: commit) else {
            return XCTFail("the fixture's files did not load")
        }
        XCTAssertEqual(files.map(\.path), ["src/login.swift"])
        XCTAssertEqual(files.first?.additions, 4)
        let diff = await store.remoteCommitDiff(conversationID: task.id, commit: commit, file: "src/login.swift")
        XCTAssertTrue(diff.contains("+target"), diff)
        let changes = await store.remoteWorkspaceChanges(conversationID: task.id)
        XCTAssertEqual(changes.map(\.path), ["src/login.swift"])
        XCTAssertEqual(changes.first?.additions, 4)
        let workspaceDiff = await store.remoteWorkspaceDiff(conversationID: task.id, file: "src/login.swift")
        XCTAssertEqual(workspaceDiff, "Working tree changes\n\n+target\n-old")
        let signature = await store.remoteRefsSignature(conversationID: task.id)
        XCTAssertEqual(signature, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/fix/login-redirect")

        // A branch switch reports the branch its computer checked out, and the footer follows it.
        let main = try XCTUnwrap(branches.local.first { $0.name == "main" })
        let failure = await store.remoteSwitchBranch(conversationID: task.id, to: main)
        XCTAssertNil(failure)
        XCTAssertEqual(store.workspace.branch, "main")
        XCTAssertTrue(store.workspace.isRemote)
    }

    // MARK: Languages

    func testRemoteControlReadsInEveryLanguage() {
        let english = L10n.englishRemote
        XCTAssertFalse(english.isEmpty)
        // Words that are the same in a language: German keeps "Relay", "online" and "offline".
        let same: Set<String> = ["de:remote_relay", "de:remote_computer_online", "de:remote_computer_offline"]
        for code in L10n.languageCodes where code != "en" {
            for (key, text) in english {
                let translated = L10n.text(key, in: code)
                XCTAssertNotNil(translated, "\(code) lacks \(key)")
                if !same.contains("\(code):\(key)") { XCTAssertNotEqual(translated, text, "\(code) still shows English for \(key)") }
            }
        }
        L10n.setLanguage(.zhHans)
        defer { L10n.setLanguage(.auto) }
        XCTAssertEqual(TranscriptUserRow.remoteCaption("Charlie's iPhone"), "来自 Charlie's iPhone")
        XCTAssertEqual(RemoteControlModel.Notice.revoked.text, "这台 Mac 已被另一台设备退出登录。")
    }

    // MARK: Pictures

    /// PNGs of the card in its states and of a phone's prompt in the transcript, written when
    /// CROK_DESKTOP_SNAPSHOT_DIR is set (CROK_DESKTOP_SNAPSHOT_LANGUAGE picks the language).
    func testSnapshotRemoteControlCardAndCaption() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let output = URL(fileURLWithPath: path)
        let language = AppLanguage.parse(ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_LANGUAGE"] ?? "en")
        L10n.setLanguage(language)
        defer { L10n.setLanguage(.auto) }
        let suffix = language == .auto ? "en" : language.configValue
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let home = directory.appendingPathComponent("snapshot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("[remote]\nurl = \"https://quiet-otter-123.convex.cloud\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        let code = #"{"event":"code","userCode":"BCDF-GHJK","verificationUrl":"https://crok.example/link","verificationUrlComplete":"https://crok.example/link?code=BCDF-GHJK","expiresAt":1760500600000,"server":"https://quiet-otter-123.convex.cloud","deviceName":"Mac"}"#
        // Shows the code at once; stopping it ends it, as a terminated crok does.
        let runner = RemoteCLIRunner(executable: { "/bin/false" }, stream: { _, onLine, onExit in onLine(code); return { onExit(15, "") } },
                                     run: { _ in GrokCLI.Output(status: 0, stdout: Data(), stderr: "") })
        let model = RemoteControlModel(runner: runner, home: home)
        model.openURL = { _ in }

        func write(_ name: String, height: CGFloat) throws {
            let card = RemoteControlSettingsSection(model: model).padding(24).frame(width: 660).foregroundStyle(Theme.ink).desktopEnvironment(store)
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try SnapshotRenderer.write(card, size: CGSize(width: 660, height: height), appearance: appearance,
                                           to: output.appendingPathComponent("remote-\(name)-\(suffix)-\(look).png"))
            }
        }
        try write("signed-out", height: 330)
        model.signIn()
        try write("waiting", height: 480)
        model.cancelSignIn()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.failure)
        var link = Self.linkJSON
        link["account"] = ["name": "Charlie Lee", "email": "charlie@example.com"]
        try writeLink(link, home: home)
        model.refresh()
        store.noteRemoteStatus(RemoteBridgeStatus(state: .connected), from: UUID())
        try write("signed-in", height: 420)

        // A phone's prompt in the transcript, as the AppKit row draws it.
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 10))
            host.appearance = NSAppearance(named: appearance)
            let message = Message(kind: .user, text: "Run the tests again and tell me what failed.", createdAt: Date(), remoteFrom: "Charlie's iPhone")
            let row = TranscriptRowView.make(TranscriptRowModel(message: message), list: nil, in: host, width: 600)
            let height = row.height(forWidth: 600)
            host.frame = NSRect(x: 0, y: 0, width: 640, height: height + 40)
            row.frame = NSRect(x: 20, y: 20, width: 600, height: height)
            row.arrange()
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let background = NSView(frame: host.frame)
            background.wantsLayer = true
            background.layer?.backgroundColor = Theme.palette.canvasNS.cgColor
            background.addSubview(host)
            window.contentView = background
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("remote-prompt-row-\(suffix)-\(look).png"))
        }
    }

    /// PNGs of the sidebar's other computers with their folders, and of a new task on one of them, written when
    /// CROK_DESKTOP_SNAPSHOT_DIR is set (CROK_DESKTOP_SNAPSHOT_LANGUAGE picks the language).
    func testSnapshotOtherComputersAndANewTaskThere() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let output = URL(fileURLWithPath: path)
        let language = AppLanguage.parse(ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_LANGUAGE"] ?? "en")
        L10n.setLanguage(language)
        defer { L10n.setLanguage(.auto) }
        let suffix = language == .auto ? "en" : language.configValue
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let local = Project(path: directory.appendingPathComponent("crok-build").path)
        store.state = DesktopState(projects: [local], conversations: [Conversation(projectID: local.id, title: "Tidy the release notes")],
                                   selectedProjectID: local.id)
        let now = Date().timeIntervalSince1970 * 1000
        func session(_ id: String, _ title: String, minutesAgo: Double, status: String = "idle") -> [String: Any] {
            ["sessionId": "relay:\(id)", "title": title, "cwd": "/w", "status": status, "lastActivityAt": now - minutesAgo * 60_000]
        }
        store.noteRemoteComputers(["computers": [
            ["deviceId": "d2", "deviceName": "Office PC", "online": true, "projects": [
                ["key": "d2:/w/api", "name": "api", "path": "/Users/charlie/w/api", "sessions": [
                    session("k1", "Fix the login redirect", minutesAgo: 1, status: "running"),
                    session("k2", "Add a health check", minutesAgo: 50),
                    session("k3", "Bump the SDK", minutesAgo: 600),
                    session("k4", "Rename the env vars", minutesAgo: 3000),
                ]],
                ["key": "d2:/w/web", "name": "web", "path": "/Users/charlie/w/web", "sessions": [session("k5", "Dark mode for the docs", minutesAgo: 90)]],
            ]],
            ["deviceId": "d3", "deviceName": "Studio", "online": false, "projects": [
                ["key": "d3:/w/app", "name": "app", "path": "/Users/charlie/w/app", "sessions": [session("k6", "Profile the importer", minutesAgo: 9000)]],
            ]],
        ]])
        let office = try XCTUnwrap(store.remoteComputers.first)
        store.newRemoteTask(on: office, in: office.projects[1])
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(SidebarView().desktopEnvironment(store).frame(width: 280, height: 760), size: CGSize(width: 280, height: 760),
                                       appearance: appearance, to: output.appendingPathComponent("remote-sidebar-\(suffix)-\(look).png"))
            try SnapshotRenderer.write(ConversationView().desktopEnvironment(store).frame(width: 760, height: 620), size: CGSize(width: 760, height: 620),
                                       appearance: appearance, to: output.appendingPathComponent("remote-new-task-\(suffix)-\(look).png"))
        }
    }

    /// The main window for real, kept under the desktop where nobody sees it (see `TranscriptWindowTests`): a new
    /// task on another computer, the same task once that computer has run its first prompt, and after its model
    /// was changed on another device. Runs with CROK_DESKTOP_WINDOW_SHOTS=<folder>, which receives the pictures.
    func testWindowShotsOfANewTaskOnAnotherComputer() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_WINDOW_SHOTS"] else {
            throw XCTSkip("Set CROK_DESKTOP_WINDOW_SHOTS=<folder> to draw the main window for real, under the desktop")
        }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { throw XCTSkip("This macOS cannot picture a window by its number") }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.auto) }
        func spin(until predicate: () -> Bool = { false }, timeout: TimeInterval) {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end && !predicate() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        let fixture = try harness()
        let store = fixture.store
        defer { store.shutdown() }
        useLocalModels(store)
        let host = ACPClient()
        try FileManager.default.createDirectory(atPath: store.remoteProject.path, withIntermediateDirectories: true)
        try host.start(executable: directory.appendingPathComponent("fixture-crok").path, cwd: store.remoteProject.path)
        Task { @MainActor in
            let initial = try await store.initialize(host)
            try await store.authenticate(host, initial: initial)
            store.remoteHost = host
            store.remoteHostReady = true
        }
        spin(until: { store.remoteHostReady }, timeout: 10)
        XCTAssertTrue(store.remoteHostReady)
        let now = Date().timeIntervalSince1970 * 1000
        store.noteRemoteComputers(["computers": [
            ["deviceId": "d2", "deviceName": "Office PC", "online": true, "projects": [
                ["key": "d2:/w/api", "name": "api", "path": "/w/api", "sessions": [
                    ["sessionId": "relay:k1", "title": "Fix the login redirect", "cwd": "/w/api", "status": "idle", "lastActivityAt": now - 3_600_000],
                ]],
                ["key": "d2:/w/web", "name": "web", "path": "/w/web", "sessions": []],
            ]],
            ["deviceId": "d3", "deviceName": "Studio", "online": false, "projects": [
                ["key": "d3:/w/app", "name": "app", "path": "/w/app", "sessions": []],
            ]],
        ]])

        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1_240, height: 780), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFrontRegardless()
        func picture(_ name: String) throws {
            spin(timeout: 0.8)
            let image = try XCTUnwrap(capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue(), "the window server pictured the window")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }

        let office = try XCTUnwrap(store.remoteComputers.first)
        store.newRemoteTask(on: office, in: office.projects[0])
        try picture("remote-window-1-new-task")
        store.draft = "Add a health check to the API"
        store.send()
        spin(until: { store.conversation?.messages.contains { $0.kind == .assistant } == true && !store.run.isRunning }, timeout: 10)
        XCTAssertEqual(store.run.modelID, "other-claude")
        XCTAssertEqual(store.conversation?.messages.filter { $0.kind == .user }.count, 1)
        try picture("remote-window-2-started")
        store.draft = "Switch models fixture:model-elsewhere"
        store.send()
        spin(until: { store.run.modelID == "other-gpt" && !store.run.isRunning }, timeout: 10)
        XCTAssertEqual(store.run.reasoningID, "high")
        try picture("remote-window-3-changed-elsewhere")
    }
}
