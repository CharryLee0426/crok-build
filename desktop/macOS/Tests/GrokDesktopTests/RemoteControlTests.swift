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

    // MARK: Languages

    func testRemoteControlReadsInEveryLanguage() {
        let english = L10n.englishRemote
        XCTAssertFalse(english.isEmpty)
        // Words that are the same in a language: German keeps "Relay".
        let same: Set<String> = ["de:remote_relay"]
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
}
