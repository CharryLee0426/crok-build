import Foundation
import UIKit

/// The app's identity as the relay sees it, and the build-time relay URL.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// `Crok iOS 1.0 (1)`: the `client` a device registers with.
    static var clientName: String { "Crok iOS \(version) (\(build))" }

    /// The `Convex-Client` header: Convex accepts only `{client_name}-{semver}` and answers 400 otherwise.
    static var convexClientHeader: String { convexClientHeader(version: version) }

    static func convexClientHeader(version: String) -> String {
        var parts = version.split(separator: ".").map { String($0.filter(\.isNumber)) }.filter { !$0.isEmpty }
        while parts.count < 3 { parts.append("0") }
        return "crok-ios-" + parts.prefix(3).joined(separator: ".")
    }

    /// The relay deployment baked in at build time: `CrokRelayURL` in the Info.plist, from `CROK_RELAY_URL` in
    /// Config/Debug.xcconfig (dev relay) or Config/Release.xcconfig (production relay), or `CROK_RELAY_URL=…` on the
    /// xcodebuild command line.
    static var bundledRelayURL: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CrokRelayURL") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `iOS 26.0` / `iPadOS 26.0`.
    @MainActor static var platform: String {
        let device = UIDevice.current
        let name = device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        return "\(name) \(device.systemVersion)"
    }

    /// The name this phone is shown under on the Devices screen. iOS only reveals the user-assigned name with a
    /// special entitlement, so this is often just "iPhone"; the welcome screen's Advanced sheet lets the person change it.
    @MainActor static var defaultDeviceName: String { UIDevice.current.name }
}

/// Relay URL rules for the built-in address and a developer's override.
enum ServerURL {
    /// Trims, adds `https://` when no scheme was typed, and drops a trailing slash. Nil when it is not a URL.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return text
    }
}
