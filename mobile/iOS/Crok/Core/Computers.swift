import Foundation

/// A linked computer as the phone shows it: an account under the person's relay account, the way Telegram lists
/// several accounts under one app (mobile/DESIGN.md). The Sessions tab shows only the selected one.
struct ComputerAccount: Identifiable, Hashable, Sendable {
    var id: DocID
    var name: String
    var online: Bool
    /// From `devices:list`; nil for a computer known only from the session list.
    var lastSeenAt: Double?
    var createdAt: Double?
    /// Unread replies over its sessions in the main list.
    var unread: Int
    /// Its most recent session activity; 0 without sessions.
    var lastActivityAt: Double

    var lastSeen: Date? { lastSeenAt.map { Date(milliseconds: $0) } }
}

/// The computers in the switcher and the Profile list, and which one the Sessions tab shows.
enum ComputerList {
    /// Every computer in link order (`devices:list` by `createdAt`), then the ones only the session list knows (a
    /// computer signed out since, or a device list still on its way), most recently active first.
    static func make(devices: [DeviceRow], groups: [ProjectGroup]) -> [ComputerAccount] {
        var unread: [DocID: Int] = [:]
        var activity: [DocID: Double] = [:]
        var known: [DocID: ProjectGroup] = [:]
        for group in groups {
            unread[group.deviceId, default: 0] += group.unreadCount
            activity[group.deviceId] = max(activity[group.deviceId] ?? 0, group.lastActivityAt)
            if known[group.deviceId] == nil { known[group.deviceId] = group }
        }
        let linked = devices
            .filter { $0.kind == .computer }
            .sorted { a, b in a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id }
        var seen = Set<DocID>()
        var computers: [ComputerAccount] = []
        for device in linked where seen.insert(device.id).inserted {
            computers.append(
                ComputerAccount(
                    id: device.id, name: device.name, online: device.online, lastSeenAt: device.lastSeenAt,
                    createdAt: device.createdAt, unread: unread[device.id] ?? 0, lastActivityAt: activity[device.id] ?? 0))
        }
        let others = known.values
            .filter { !seen.contains($0.deviceId) }
            .sorted { a, b in
                let x = activity[a.deviceId] ?? 0, y = activity[b.deviceId] ?? 0
                return x != y ? x > y : a.deviceId < b.deviceId
            }
        for group in others {
            computers.append(
                ComputerAccount(
                    id: group.deviceId, name: group.deviceName, online: group.deviceOnline, lastSeenAt: nil, createdAt: nil,
                    unread: unread[group.deviceId] ?? 0, lastActivityAt: activity[group.deviceId] ?? 0))
        }
        return computers
    }

    /// The computer to show: the remembered one while it is still linked, else the one whose sessions were active
    /// last, else the first.
    static func resolve(remembered: DocID?, in computers: [ComputerAccount]) -> DocID? {
        if let remembered, computers.contains(where: { $0.id == remembered }) { return remembered }
        let active = computers.filter { $0.lastActivityAt > 0 }
        if let latest = active.max(by: { $0.lastActivityAt < $1.lastActivityAt }) { return latest.id }
        return computers.first?.id
    }
}

/// What a project's row on the Sessions tab shows (Telegram's forum row): its newest topics, and what is going on in
/// it.
struct ForumSummary: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        /// A turn runs in one of its sessions.
        case running
        /// One of its sessions waits on a question or a permission.
        case waiting
        case none
    }

    /// Up to three sessions, most recently active first.
    var topics: [SessionRow]
    /// The most recently active session, whose preview the row shows.
    var latest: SessionRow?
    var activity: Activity
    var unread: Int

    static let topicLimit = 3

    static func make(_ group: ProjectGroup) -> ForumSummary {
        let recent = group.sessions.sorted { a, b in
            a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id < b.id
        }
        let activity: Activity =
            if group.sessions.contains(where: { $0.online && $0.status == .running }) {
                .running
            } else if group.sessions.contains(where: { $0.online && $0.status == .waiting }) {
                .waiting
            } else {
                .none
            }
        return ForumSummary(
            topics: Array(recent.prefix(topicLimit)), latest: recent.first, activity: activity, unread: group.unreadCount)
    }
}

/// Telegram's topic glyph for a session: a speech bubble in one of six colours with the title's first letter.
enum TopicIcon {
    /// Telegram's topic colours: blue, yellow, violet, green, rose, red.
    static let colors: [UInt32] = [0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F]

    static func colorIndex(for sessionDocId: DocID) -> Int {
        ProjectAvatar.colorIndex(for: sessionDocId, paletteSize: colors.count)
    }

    /// The first letter or digit of the title, uppercased; `·` when there is none.
    static func letter(for title: String) -> String {
        guard let first = title.first(where: { $0.isLetter || $0.isNumber }) else { return "·" }
        return String(first).uppercased()
    }
}

/// The unread sessions "Mark All as Read" (and a project's "Mark as Read") clears.
enum ReadAll {
    static func unreadIDs(in groups: [ProjectGroup]) -> [DocID] {
        groups.flatMap { group in group.sessions.filter { $0.unreadCount > 0 }.map(\.id) }
    }
}

extension ProjectOrder {
    /// The list with `ids` read, shown before the relay confirms it.
    static func markingRead(_ ids: Set<DocID>, in groups: [ProjectGroup]) -> [ProjectGroup] {
        guard !ids.isEmpty else { return groups }
        return groups.map { group in
            guard group.sessions.contains(where: { ids.contains($0.id) }) else { return group }
            var changed = group
            changed.sessions = group.sessions.map { row in
                guard ids.contains(row.id) else { return row }
                var row = row
                row.unread = 0
                return row
            }
            return changed
        }
    }
}

/// The computer the Sessions tab shows, remembered on this phone.
struct SelectedComputerStore: @unchecked Sendable {
    var defaults: UserDefaults = .standard
    private static let key = "crok.selectedComputer"

    func load() -> DocID? { defaults.string(forKey: Self.key) }

    func save(_ id: DocID?) {
        if let id { defaults.set(id, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }
}
