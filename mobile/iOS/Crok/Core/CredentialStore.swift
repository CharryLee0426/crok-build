import Foundation
import Security

/// Where secrets live: the Keychain in the app, memory in tests and demo mode.
protocol SecureStore: Sendable {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

/// Generic-password items under one service, readable after the first unlock and never synced or backed up to
/// another device (the refresh token belongs to this phone only).
struct KeychainStore: SecureStore {
    var service = "dev.chenli.crok.mobile"

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func data(for key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func set(_ data: Data?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let data else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

final class MemorySecureStore: SecureStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    init() {}

    func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    func set(_ data: Data?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        items[key] = data
    }
}

/// A signed-in device: what survives an app restart.
struct StoredCredentials: Codable, Equatable, Sendable {
    var serverURL: String
    var deviceId: String
    var refreshToken: String
    var user: AccountUser
    var deviceName: String
    var signedInAt: Double
}

/// A sign-in waiting for approval, persisted so a killed app resumes waiting (Telegram keeps its authorization
/// state the same way). The device code is a secret, so this lives in the Keychain too.
struct PendingSignIn: Codable, Equatable, Sendable {
    var serverURL: String
    var deviceName: String
    var deviceCode: String
    var userCode: String
    var verificationURL: String?
    var expiresAt: Double
    var interval: Double

    func isExpired(now: Date) -> Bool { now.milliseconds >= expiresAt }

    /// The browser link for a phone: the web page ends on `crok://signed-in` when it sees `app=1`.
    var browserURL: URL? {
        guard let verificationURL, var components = URLComponents(string: verificationURL) else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "app" }) { items.append(URLQueryItem(name: "app", value: "1")) }
        components.queryItems = items
        return components.url
    }
}

/// The two Keychain records the sign-in state machine reads and writes.
struct AuthStore: Sendable {
    let secure: any SecureStore

    private static let credentialsKey = "credentials"
    private static let pendingKey = "pending-sign-in"

    var credentials: StoredCredentials? {
        get { read(Self.credentialsKey) }
        nonmutating set { write(newValue, Self.credentialsKey) }
    }

    var pending: PendingSignIn? {
        get { read(Self.pendingKey) }
        nonmutating set { write(newValue, Self.pendingKey) }
    }

    func wipe() {
        secure.set(nil, for: Self.credentialsKey)
        secure.set(nil, for: Self.pendingKey)
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = secure.data(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T?, _ key: String) {
        secure.set(value.flatMap { try? JSONEncoder().encode($0) }, for: key)
    }
}
