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

    func testOnlyOpenRouterAndCodexAccountsAreOffered() throws {
        XCTAssertEqual(AccountProvider.allCases, [.openrouter, .codex])
        // xAI sign-ins and keys are not supported, so a saved xAI session or XAI_API_KEY is ignored.
        try write(["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": ["key": "secret-xai-token", "email": "alice@example.invalid",
                   "user_id": "user-1", "auth_mode": "oidc", "create_time": "2026-01-01T00:00:00Z"]], to: "auth.json")
        let statuses = AccountStatusReader(home: directory, environment: ["XAI_API_KEY": "secret-xai-key"], now: { self.now }).read()
        XCTAssertEqual(Set(statuses.keys), [.openrouter, .codex])
        XCTAssertTrue(statuses.values.allSatisfy { $0.state == .signedOut })
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
        let statuses = reader.read()
        XCTAssertTrue(statuses.values.allSatisfy { $0.state == .unreadable && !$0.isConnected })
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
        for provider in AccountProvider.allCases {
            store.login(provider: provider.rawValue)
            let deadline = Date().addingTimeInterval(8)
            while store.loginRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(store.loginRunning)
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["login openrouter", "login openai-codex"])
        XCTAssertFalse(lines.contains { $0.contains("--oauth") })
    }
}
