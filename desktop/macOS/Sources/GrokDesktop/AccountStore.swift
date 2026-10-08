import Foundation
import Combine

/// Model providers Crok Desktop can sign in to. xAI accounts are not supported;
/// Grok models are available through OpenRouter.
enum AccountProvider: String, CaseIterable, Identifiable {
    case openrouter
    case codex = "openai-codex"
    case deepseek
    case glm
    case anthropic

    var id: String { rawValue }
    var name: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .codex: return "OpenAI Codex"
        case .deepseek: return "DeepSeek"
        case .glm: return "GLM Coding Plan"
        case .anthropic: return "Anthropic"
        }
    }

    /// The places this provider takes a pasted API key. Empty for a provider that signs in with the browser.
    /// GLM has two: z.ai and bigmodel.cn keep separate accounts, and a key from one is refused by the other.
    var keySources: [AccountKeySource] {
        switch self {
        case .openrouter, .codex: return []
        case .deepseek:
            return [AccountKeySource(id: "deepseek", title: "DeepSeek", site: "platform.deepseek.com",
                                     keyPage: "https://platform.deepseek.com/api_keys", environmentKeys: ["DEEPSEEK_API_KEY"])]
        case .glm:
            return [AccountKeySource(id: "glm", title: "International", site: "z.ai",
                                     keyPage: "https://z.ai/manage-apikey/apikey-list", environmentKeys: ["ZAI_API_KEY"]),
                    AccountKeySource(id: "glm-cn", title: "China mainland", site: "bigmodel.cn",
                                     keyPage: "https://bigmodel.cn/coding-plan/personal/overview", environmentKeys: ["ZHIPU_API_KEY"])]
        case .anthropic:
            return [AccountKeySource(id: "anthropic", title: "Anthropic", site: "platform.claude.com",
                                     keyPage: "https://platform.claude.com/settings/keys", environmentKeys: ["ANTHROPIC_API_KEY"])]
        }
    }

    var signsInWithKey: Bool { !keySources.isEmpty }

    /// What the row says before anything is connected.
    var signedOutDetail: String {
        switch self {
        case .openrouter, .codex: return "Sign in with your browser"
        case .deepseek: return "Add an API key from platform.deepseek.com"
        case .glm: return "Add the API key from your z.ai or bigmodel.cn subscription"
        // The Claude API, billed per token. A Claude subscription is a different product and has no key.
        case .anthropic: return "Add a Claude API key from platform.claude.com"
        }
    }
}

/// One site that issues keys for a provider. `id` is the name the CLI knows it by:
/// `crok login <id> --with-api-key` saves the key to `provider-auth/<id>.json`.
struct AccountKeySource: Identifiable, Equatable {
    let id: String
    let title: String
    let site: String
    let keyPage: String
    let environmentKeys: [String]
}

/// Presentation-only metadata. Credential values never leave the reader.
struct AccountStatus: Equatable {
    enum State: Equatable { case signedOut, connected, expired, unreadable }
    var state: State = .signedOut
    var identity: String?
    var detail: String = "Sign in with your browser"
    /// The CLI name of the saved credential (`crok logout <name>` removes it). Nil when the
    /// credential comes from the environment, which Crok Desktop cannot change.
    var savedAs: String?
    var isConnected: Bool { state == .connected }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [AccountProvider: AccountStatus] = [:]
    private let reader: AccountStatusReader

    init(reader: AccountStatusReader = AccountStatusReader()) {
        self.reader = reader
        refresh()
    }

    func status(for provider: AccountProvider) -> AccountStatus { accounts[provider] ?? AccountStatus(detail: provider.signedOutDetail) }

    func refresh() { accounts = reader.read() }

    /// Recheck the shared CLI credentials at the action boundary as they may have
    /// changed since this view last rendered (for example, a CLI browser sign-in).
    @discardableResult
    func signIn(provider: AccountProvider, loginRunning: Bool, perform: (String) -> Void) -> Bool {
        refresh()
        guard !loginRunning, !status(for: provider).isConnected else { return false }
        perform(provider.rawValue)
        return true
    }

    /// The same recheck for a pasted key. `source` is one of the provider's `keySources`.
    @discardableResult
    func addKey(_ key: String, provider: AccountProvider, source: AccountKeySource, loginRunning: Bool, perform: (String, String) -> Void) -> Bool {
        refresh()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loginRunning, !key.isEmpty, provider.keySources.contains(source), !status(for: provider).isConnected else { return false }
        perform(source.id, key)
        return true
    }
}

struct AccountStatusReader {
    private let home: URL
    private let environment: [String: String]
    private let now: () -> Date

    init(home: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.home = home ?? environment["CROK_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".crok", isDirectory: true)
        self.now = now
    }

    func read() -> [AccountProvider: AccountStatus] {
        Dictionary(uniqueKeysWithValues: AccountProvider.allCases.map { ($0, readProvider($0)) })
    }

    private func readProvider(_ provider: AccountProvider) -> AccountStatus {
        switch provider {
        case .openrouter:
            if validSecret(environment["OPENROUTER_API_KEY"]) {
                return AccountStatus(state: .connected, detail: "API key from environment · account name unavailable")
            }
            switch readCredential(named: provider.rawValue) {
            case .missing: return AccountStatus(detail: provider.signedOutDetail)
            case .invalid: return unreadable()
            case .found: return AccountStatus(state: .connected, detail: "API key connected · account name unavailable", savedAs: provider.rawValue)
            }
        case .codex:
            switch readCredential(named: provider.rawValue) {
            case .missing: return AccountStatus(detail: provider.signedOutDetail)
            case .invalid: return unreadable()
            case .found(let credential):
                // Mirror the harness's required Codex OAuth fields. A refresh token
                // means an expired access token can be renewed without signing in again.
                guard validSecret(credential.refresh_token), let accountID = displayText(credential.account_id),
                      let expiry = credential.expires_at, expiry.isFinite, expiry > 0 else { return unreadable() }
                let identity = profileEmail(from: credential.access_token) ?? "Account \(accountID)"
                return AccountStatus(state: .connected, identity: identity,
                                     detail: expiry <= now().timeIntervalSince1970 ? "Signed in · session renews automatically" : "Signed in",
                                     savedAs: provider.rawValue)
            }
        case .deepseek, .glm, .anthropic:
            return readKeyProvider(provider)
        }
    }

    /// The first of the provider's key sources that has a usable key: its environment variable, then its saved key.
    /// The harness reads them in the same order.
    private func readKeyProvider(_ provider: AccountProvider) -> AccountStatus {
        let sources = provider.keySources
        var damaged = false
        for source in sources {
            // A provider with one site needs no site name; GLM says which of its two is connected.
            let site = sources.count > 1 ? " · \(source.site)" : ""
            if let name = source.environmentKeys.first(where: { validSecret(environment[$0]) }) {
                return AccountStatus(state: .connected, detail: "API key from \(name)\(site)")
            }
            switch readCredential(named: source.id) {
            case .missing: continue
            case .invalid: damaged = true
            case .found: return AccountStatus(state: .connected, detail: "API key connected\(site)", savedAs: source.id)
            }
        }
        return damaged ? AccountStatus(state: .unreadable, detail: "Saved API key is unreadable · add it again") : AccountStatus(detail: provider.signedOutDetail)
    }

    private enum SavedCredential {
        case missing, invalid
        case found(ProviderCredential)
    }

    /// `provider-auth/<name>.json`, accepted only when it names the same provider and holds a token.
    private func readCredential(named name: String) -> SavedCredential {
        let url = home.appendingPathComponent("provider-auth/\(name).json")
        do {
            guard let data = try readData(url) else { return .missing }
            let credential = try JSONDecoder().decode(ProviderCredential.self, from: data)
            guard credential.provider == name, validSecret(credential.access_token) else { return .invalid }
            return .found(credential)
        } catch { return .invalid }
    }

    private func unreadable() -> AccountStatus {
        AccountStatus(state: .unreadable, detail: "Saved sign-in is incomplete · sign in to reconnect")
    }

    private func readData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private func validSecret(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func displayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 320, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    /// Decode only a display email. JWT claims are not used to establish trust or
    /// select credentials; the harness performs actual authentication.
    private func profileEmail(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let profile = object["https://api.openai.com/profile"] as? [String: Any]
        return displayText(profile?["email"] as? String) ?? displayText(object["email"] as? String)
    }

    private struct ProviderCredential: Decodable {
        var provider: String
        var access_token: String
        var refresh_token: String?
        var expires_at: Double?
        var account_id: String?
    }
}
