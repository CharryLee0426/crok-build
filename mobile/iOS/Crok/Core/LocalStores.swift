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

/// The projects collapsed in the session list, remembered on this phone by project key.
struct CollapsedProjectsStore: @unchecked Sendable {
    var defaults: UserDefaults = .standard
    private static let key = "crok.collapsedProjects"

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func save(_ keys: Set<String>) {
        if keys.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(keys.sorted(), forKey: Self.key)
        }
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

    /// Version 2 holds the grouped list (`sessions:groups`); a version 1 file (a flat list) is ignored.
    private struct Snapshot: Codable {
        var version = 2
        var deviceId: String
        var savedAt: Double
        var groups: [ProjectGroup]
        var computers: [DeviceRow]
    }

    private var file: URL { directory.appendingPathComponent("sessions.json") }

    func load(deviceId: String) -> (groups: [ProjectGroup], computers: [DeviceRow])? {
        guard let data = try? Data(contentsOf: file),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
            snapshot.version == 2, snapshot.deviceId == deviceId
        else { return nil }
        return (snapshot.groups, snapshot.computers)
    }

    func save(deviceId: String, groups: [ProjectGroup], computers: [DeviceRow]) {
        let snapshot = Snapshot(deviceId: deviceId, savedAt: Date().milliseconds, groups: groups, computers: computers)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
