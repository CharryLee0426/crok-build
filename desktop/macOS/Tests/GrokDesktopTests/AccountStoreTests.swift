import Foundation
import XCTest
@testable import GrokDesktop

final class AccountStoreTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("provider-auth"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func write(_ object: Any, to path: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(path))
    }

    private var reader: AccountStatusReader { AccountStatusReader(home: directory, environment: [:], now: { self.now }) }

    func testOnlyProviderAccountsAreOffered() throws {
        XCTAssertEqual(AccountProvider.allCases, [.openrouter, .codex, .deepseek, .glm])
        // xAI sign-ins and keys are not supported, so a saved xAI session or XAI_API_KEY is ignored.
        try write(["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": ["key": "secret-xai-token", "email": "alice@example.invalid",
                   "user_id": "user-1", "auth_mode": "oidc", "create_time": "2026-01-01T00:00:00Z"]], to: "auth.json")
        let statuses = AccountStatusReader(home: directory, environment: ["XAI_API_KEY": "secret-xai-key"], now: { self.now }).read()
        XCTAssertEqual(Set(statuses.keys), Set(AccountProvider.allCases))
        XCTAssertTrue(statuses.values.allSatisfy { $0.state == .signedOut && $0.savedAs == nil })
        XCTAssertFalse(String(describing: statuses).contains("secret"))
    }

    func testReadsCodexJWTProfileWithoutExposingTokens() throws {
        let claims = ["https://api.openai.com/profile": ["email": "bob@example.invalid"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let bearer = "header.\(payload).secret-signature"
        try write(["provider": "openai-codex", "access_token": bearer, "refresh_token": "secret-refresh", "account_id": "account-1", "expires_at": now.timeIntervalSince1970 + 3600], to: "provider-auth/openai-codex.json")
        let statuses = reader.read()
        XCTAssertEqual(statuses[.codex]?.identity, "bob@example.invalid")
        XCTAssertTrue(statuses[.codex]!.isConnected)
        let presentation = String(describing: statuses)
        XCTAssertFalse(presentation.contains("secret-refresh"))
        XCTAssertFalse(presentation.contains(bearer))
    }

    func testCodexFallsBackToAccountIDAndKeepsRefreshableSessionConnected() throws {
        try write(["provider": "openai-codex", "access_token": "opaque-secret", "refresh_token": "refresh-secret", "account_id": "account-42", "expires_at": now.timeIntervalSince1970 - 3600], to: "provider-auth/openai-codex.json")
        let status = reader.read()[.codex]!
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.identity, "Account account-42")
        XCTAssertEqual(status.detail, "Signed in · session renews automatically")
    }

    func testMalformedAndWrongProviderCredentialsNeverBecomeConnected() throws {
        try write(["provider": "openai-codex", "access_token": "secret-other-provider"], to: "provider-auth/openrouter.json")
        try write(["provider": "openai-codex", "access_token": "secret-incomplete", "account_id": "account-42"], to: "provider-auth/openai-codex.json")
        // A key saved for one GLM site under the other's name, and a DeepSeek file with no key in it.
        try write(["provider": "glm", "access_token": "secret-wrong-site"], to: "provider-auth/glm-cn.json")
        try write(["provider": "deepseek", "access_token": "  "], to: "provider-auth/deepseek.json")
        let statuses = reader.read()
        XCTAssertTrue(statuses.values.allSatisfy { $0.state == .unreadable && !$0.isConnected })
        XCTAssertFalse(String(describing: statuses).contains("secret"))
    }

    func testKeyProvidersAreConnectedBySavedOrEnvironmentKeysWithoutShowingThem() throws {
        XCTAssertEqual(AccountProvider.deepseek.keySources.map(\.id), ["deepseek"])
        // One row covers both GLM sites; each saves under the name the CLI gives it.
        XCTAssertEqual(AccountProvider.glm.keySources.map(\.id), ["glm", "glm-cn"])
        XCTAssertTrue(AccountProvider.openrouter.keySources.isEmpty && AccountProvider.codex.keySources.isEmpty)
        XCTAssertFalse(reader.read()[.deepseek]!.isConnected)
        XCTAssertEqual(reader.read()[.glm]?.detail, "Add the API key from your z.ai or bigmodel.cn subscription")

        try write(["provider": "deepseek", "access_token": "sk-secret-deepseek", "issued_at": 1], to: "provider-auth/deepseek.json")
        try write(["provider": "glm-cn", "access_token": "secret.bigmodel"], to: "provider-auth/glm-cn.json")
        var statuses = reader.read()
        XCTAssertEqual(statuses[.deepseek], AccountStatus(state: .connected, detail: "API key connected", savedAs: "deepseek"))
        // The row says which site the key belongs to, and which saved sign-in a removal would delete.
        XCTAssertEqual(statuses[.glm], AccountStatus(state: .connected, detail: "API key connected · bigmodel.cn", savedAs: "glm-cn"))
        XCTAssertFalse(String(describing: statuses).contains("secret"))

        // The harness reads the environment first, so the row describes that key and offers no removal.
        statuses = AccountStatusReader(home: directory, environment: ["DEEPSEEK_API_KEY": "sk-secret-env", "ZAI_API_KEY": "secret.zai"]).read()
        XCTAssertEqual(statuses[.deepseek], AccountStatus(state: .connected, detail: "API key from DEEPSEEK_API_KEY"))
        XCTAssertEqual(statuses[.glm], AccountStatus(state: .connected, detail: "API key from ZAI_API_KEY · z.ai"))
        XCTAssertFalse(String(describing: statuses).contains("secret"))
    }

    func testOpenRouterEnvironmentKeyTakesPrecedenceWithoutDisplayingKey() throws {
        try write(["provider": "invalid", "access_token": "bad-secret"], to: "provider-auth/openrouter.json")
        let statuses = AccountStatusReader(home: directory, environment: ["OPENROUTER_API_KEY": "environment-secret"]).read()
        XCTAssertTrue(statuses[.openrouter]!.isConnected)
        XCTAssertNil(statuses[.openrouter]?.identity)
        XCTAssertEqual(statuses[.openrouter]?.detail, "API key from environment · account name unavailable")
        XCTAssertFalse(String(describing: statuses).contains("environment-secret"))
    }

    @MainActor
    func testSignInGuardRefreshesSharedCredentialsBeforeStartingAndAfterRemoval() throws {
        let store = AccountStore(reader: reader)
        var calls: [String] = []
        XCTAssertFalse(store.status(for: .openrouter).isConnected)
        // A browser sign-in in another process finishes after the settings view opens.
        try write(["provider": "openrouter", "access_token": "new-secret"], to: "provider-auth/openrouter.json")
        XCTAssertFalse(store.signIn(provider: .openrouter, loginRunning: false) { calls.append($0) })
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(store.status(for: .openrouter).isConnected)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("provider-auth/openrouter.json"))
        XCTAssertFalse(store.signIn(provider: .openrouter, loginRunning: true) { calls.append($0) })
        XCTAssertTrue(store.signIn(provider: .openrouter, loginRunning: false) { calls.append($0) })
        XCTAssertEqual(calls, ["openrouter"])
        XCTAssertFalse(store.status(for: .openrouter).isConnected)
    }

    @MainActor
    func testAddingAKeyNamesTheChosenSiteAndRechecksSavedKeysFirst() throws {
        let store = AccountStore(reader: reader)
        var calls: [[String]] = []
        let record: (String, String) -> Void = { calls.append([$0, $1]) }
        let china = try XCTUnwrap(AccountProvider.glm.keySources.last)
        let deepseek = try XCTUnwrap(AccountProvider.deepseek.keySources.first)
        // Nothing to save, a sign-in already running, or a site that is not this provider's.
        XCTAssertFalse(store.addKey("  \n", provider: .glm, source: china, loginRunning: false, perform: record))
        XCTAssertFalse(store.addKey("key", provider: .glm, source: china, loginRunning: true, perform: record))
        XCTAssertFalse(store.addKey("key", provider: .glm, source: deepseek, loginRunning: false, perform: record))
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(store.addKey("  pasted.key\n", provider: .glm, source: china, loginRunning: false, perform: record))
        XCTAssertEqual(calls, [["glm-cn", "pasted.key"]])
        // The terminal saved a key while the form was open: there is nothing left to add.
        try write(["provider": "deepseek", "access_token": "sk-from-terminal"], to: "provider-auth/deepseek.json")
        XCTAssertFalse(store.addKey("sk-pasted", provider: .deepseek, source: deepseek, loginRunning: false, perform: record))
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(store.status(for: .deepseek).isConnected)
    }

    @MainActor
    func testLoginNamesTheProviderAndNeverUsesXAIOAuth() async throws {
        let log = directory.appendingPathComponent("login-arguments.txt")
        let script = directory.appendingPathComponent("fake-grok")
        // Only sign-in runs are recorded; a model refresh after sign-in may start the runtime too.
        try "#!/bin/sh\n[ \"$1\" = login ] && printf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let defaultsName = "GrokDesktopLogin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: script.path)
        defer { store.shutdown() }
        for provider in AccountProvider.allCases where !provider.signsInWithKey {
            store.login(provider: provider.rawValue)
            let deadline = Date().addingTimeInterval(8)
            while store.loginRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(store.loginRunning)
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["login openrouter", "login openai-codex"])
        XCTAssertFalse(lines.contains { $0.contains("--oauth") })
    }

    /// A stand-in CLI that records its arguments and what arrives on standard input, then exits with `status`.
    @MainActor
    private func storeWithFakeCLI(exit status: Int, saying message: String = "") throws -> (AppStore, arguments: URL, input: URL, cleanUp: () -> Void) {
        let arguments = directory.appendingPathComponent("arguments.txt"), input = directory.appendingPathComponent("input.txt")
        let script = directory.appendingPathComponent("fake-crok")
        let body = "#!/bin/sh\ncase \"$1\" in login|logout) printf '%s\\n' \"$*\" >> '\(arguments.path)';; *) exit 0;; esac\n"
            + "[ \"$1\" = login ] && cat > '\(input.path)'\n"
            + (message.isEmpty ? "" : "echo '\(message)' >&2\n") + "exit \(status)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let defaultsName = "GrokDesktopLogin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: script.path)
        return (store, arguments, input, { store.shutdown(); defaults.removePersistentDomain(forName: defaultsName) })
    }

    @MainActor
    private func waitForLogin(_ store: AppStore) async throws {
        let deadline = Date().addingTimeInterval(8)
        while store.loginRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.loginRunning)
    }

    @MainActor
    func testAPastedKeyReachesTheCLIOnStandardInputAndNeverAsAnArgument() async throws {
        let (store, arguments, input, cleanUp) = try storeWithFakeCLI(exit: 0)
        defer { cleanUp() }
        store.login(provider: "glm-cn", apiKey: "secret.pasted-key")
        XCTAssertTrue(store.loginUsesKey)
        try await waitForLogin(store)
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "login glm-cn --with-api-key\n")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "secret.pasted-key\n")
        XCTAssertNil(store.loginFailure)
        XCTAssertFalse(store.loginLog.contains("secret.pasted-key"))
    }

    @MainActor
    func testARefusedKeyShowsTheCLIsReasonAndRemovalRunsLogout() async throws {
        let (store, arguments, _, cleanUp) = try storeWithFakeCLI(exit: 1, saying: "Error: z.ai did not accept this API key. Nothing was saved.")
        // (The CLI prints an error as `Error: <reason>`.)
        defer { cleanUp() }
        store.login(provider: "glm", apiKey: "wrong.key")
        try await waitForLogin(store)
        // The reason is the last thing the CLI writes, and can arrive just after its exit is seen.
        let reason = "z.ai did not accept this API key. Nothing was saved."
        let arrived = Date().addingTimeInterval(8)
        while store.loginFailure != reason && Date() < arrived { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.loginFailure, reason)
        XCTAssertEqual(AppStore.loginFailureText("Checking the API key…\n\n"), "Checking the API key…")
        XCTAssertEqual(AppStore.loginFailureText(""), "Sign-in did not finish.")

        let changes = store.accountsChanged
        store.logout(provider: "deepseek")
        let deadline = Date().addingTimeInterval(8)
        while store.accountsChanged == changes && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.accountsChanged, changes + 1)
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").last, "logout deepseek")
    }
}
