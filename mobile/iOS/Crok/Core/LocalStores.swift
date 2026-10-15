import Foundation

/// Per-session composer drafts that survive the app being killed (Telegram keeps them in the chat interface state).
struct DraftStore: @unchecked Sendable {
    var defaults: UserDefaults = .standard
    private static let key = "crok.drafts"

    func draft(for sessionDocId: DocID) -> String {
        (defaults.dictionary(forKey: Self.key) as? [String: String])?[sessionDocId] ?? ""
    }

    func setDraft(_ text: String, for sessionDocId: DocID) {
        var all = (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard all[sessionDocId] != nil else { return }
            all[sessionDocId] = nil
        } else {
            all[sessionDocId] = text
        }
        defaults.set(all, forKey: Self.key)
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The last session list, kept in Caches so the app opens on it at once while it reconnects.
struct SessionListCache: Sendable {
    var directory: URL

    static var standard: SessionListCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SessionListCache(directory: caches.appendingPathComponent("crok", isDirectory: true))
    }

    private struct Snapshot: Codable {
        var version = 1
        var deviceId: String
        var savedAt: Double
        var sessions: [SessionRow]
        var computers: [DeviceRow]
    }

    private var file: URL { directory.appendingPathComponent("sessions.json") }

    func load(deviceId: String) -> (sessions: [SessionRow], computers: [DeviceRow])? {
        guard let data = try? Data(contentsOf: file),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
            snapshot.version == 1, snapshot.deviceId == deviceId
        else { return nil }
        return (snapshot.sessions, snapshot.computers)
    }

    func save(deviceId: String, sessions: [SessionRow], computers: [DeviceRow]) {
        let snapshot = Snapshot(deviceId: deviceId, savedAt: Date().milliseconds, sessions: sessions, computers: computers)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
