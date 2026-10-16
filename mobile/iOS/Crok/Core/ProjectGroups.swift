import Foundation

/// A change to the order of the session list (relay/DESIGN.md §2 "Projects and order"). The engine applies it at once
/// and keeps applying it over whatever the relay sends until the relay has it, so a move never jumps back.
enum ListReorder: Equatable, Sendable {
    /// Some project keys (the ones a tab shows) in their new order: `sessions:reorderProjects`.
    case projects([String])
    /// Some of one project's sessions in their new order: `sessions:reorderSessions`.
    case sessions(projectKey: String, ids: [DocID])
    /// The projects back to most recently active first: `sessions:resetOrder({})`.
    case projectsByActivity
    /// One project's sessions back to most recently active first: `sessions:resetOrder({projectKey})`.
    case sessionsByActivity(projectKey: String)
}

/// The list's order rules as pure functions over `sessions:groups` values, mirroring the relay
/// (`relay/convex/lib/projects.ts`), so an optimistic move shows what the relay will send.
enum ProjectOrder {
    /// A section shows this many sessions before "Show N more".
    static let previewLimit = 5

    /// Puts `wanted` (some of `current`, in their new order) into the places those items hold in `current`, so moving
    /// one computer's projects leaves the others where they are. Returns `current` when `wanted` repeats an item.
    static func reorderWithin<T: Hashable>(_ current: [T], _ wanted: [T]) -> [T] {
        let wantedSet = Set(wanted)
        let slots = current.indices.filter { wantedSet.contains(current[$0]) }
        let currentSet = Set(current)
        let known = wanted.filter { currentSet.contains($0) }
        guard known.count == slots.count else { return current }
        var next = current
        for (slot, item) in zip(slots, known) { next[slot] = item }
        return next
    }

    /// Pinned sessions lead their project; the rest keep their order.
    static func pinnedFirst(_ rows: [SessionRow]) -> [SessionRow] {
        rows.filter(\.pinned) + rows.filter { !$0.pinned }
    }

    /// Pinned first, then most recently active first: a project's order before anyone placed its sessions.
    static func byActivity(_ rows: [SessionRow]) -> [SessionRow] {
        pinnedFirst(rows.sorted { a, b in
            a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id < b.id
        })
    }

    /// The list after `change`, the way the relay will order it.
    static func apply(_ change: ListReorder, to groups: [ProjectGroup]) -> [ProjectGroup] {
        switch change {
        case .projects(let keys):
            let order = reorderWithin(groups.map(\.key), keys)
            var byKey: [String: ProjectGroup] = [:]
            for group in groups where byKey[group.key] == nil { byKey[group.key] = group }
            // Reordering places every project (a newcomer then appears on top until it is moved).
            return order.compactMap { key in
                byKey[key].map { group in
                    var placed = group
                    placed.placed = true
                    return placed
                }
            }
        case .sessions(let projectKey, let ids):
            return groups.map { group in
                guard group.key == projectKey else { return group }
                var byId: [DocID: SessionRow] = [:]
                for row in group.sessions where byId[row.id] == nil { byId[row.id] = row }
                let order = reorderWithin(group.sessions.map(\.id), ids)
                var moved = group
                moved.sessions = pinnedFirst(order.compactMap { byId[$0] })
                return moved
            }
        case .projectsByActivity:
            return groups
                .sorted { a, b in a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.key < b.key }
                .map { group in
                    var unplaced = group
                    unplaced.placed = false
                    return unplaced
                }
        case .sessionsByActivity(let projectKey):
            return groups.map { group in
                guard group.key == projectKey else { return group }
                var sorted = group
                sorted.sessions = byActivity(group.sessions)
                return sorted
            }
        }
    }

    /// A session pinned or unpinned: its project re-sorts so pinned sessions lead.
    static func settingPinned(_ id: DocID, _ pinned: Bool, in groups: [ProjectGroup]) -> [ProjectGroup] {
        groups.map { group in
            guard group.sessions.contains(where: { $0.id == id }) else { return group }
            var changed = group
            changed.sessions = pinnedFirst(group.sessions.map { row in
                guard row.id == id else { return row }
                var row = row
                row.pinned = pinned
                return row
            })
            return changed
        }
    }

    /// A session archived: it leaves the list, and its project too when it was the last one.
    static func removing(_ id: DocID, from groups: [ProjectGroup]) -> [ProjectGroup] {
        guard groups.contains(where: { $0.sessions.contains(where: { $0.id == id }) }) else { return groups }
        return groups.compactMap { group in
            var kept = group
            kept.sessions.removeAll { $0.id == id }
            return kept.sessions.isEmpty ? nil : kept
        }
    }

    /// `items` after a drag: the ones at `source` moved to `destination` (an index into `items` before the move, as
    /// SwiftUI's `onMove` reports it).
    static func moved<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let valid = IndexSet(source.filter { items.indices.contains($0) })
        let moving = valid.map { items[$0] }
        var rest = items.indices.filter { !valid.contains($0) }.map { items[$0] }
        let insertAt = destination - valid.count(in: 0..<max(0, min(destination, items.count)))
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return rest
    }

    /// Project keys after moving `key` one place up (`-1`) or down (`+1`); nil at either end.
    static func keys(_ keys: [String], moving key: String, by offset: Int) -> [String]? {
        guard let index = keys.firstIndex(of: key), keys.indices.contains(index + offset) else { return nil }
        var next = keys
        next.swapAt(index, index + offset)
        return next
    }

    /// Session ids after moving `id` one place up or down; nil at either end, and where a pinned and an unpinned
    /// session meet (pinned sessions always lead).
    static func sessionIDs(_ rows: [SessionRow], moving id: DocID, by offset: Int) -> [DocID]? {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset),
            rows[index + offset].pinned == rows[index].pinned
        else { return nil }
        var ids = rows.map(\.id)
        ids.swapAt(index, index + offset)
        return ids
    }
}

/// The search field over the grouped list: sections keep only matching sessions, and empty sections go.
enum SessionSearch {
    static func matches(_ row: SessionRow, _ needle: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return [row.title, row.folderName, row.projectDisplayName, row.deviceName, row.preview ?? "", row.model ?? ""]
            .contains { $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func filter(_ groups: [ProjectGroup], query: String) -> [ProjectGroup] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        return groups.compactMap { group in
            var matching = group
            matching.sessions = group.sessions.filter { matches($0, query) }
            return matching.sessions.isEmpty ? nil : matching
        }
    }
}
