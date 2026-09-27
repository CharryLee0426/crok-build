import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

@MainActor
final class SidebarTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeStore() -> (AppStore, Project, Project) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let app = Project(path: "/tmp/grok-desktop"), api = Project(path: "/tmp/billing-api")
        let now = Date()
        store.state.projects = [app, api]
        store.state.selectedProjectID = app.id
        store.state.conversations = [
            Conversation(projectID: app.id, title: "Oldest app task", updatedAt: now.addingTimeInterval(-9 * 86_400)),
            Conversation(projectID: api.id, title: "Fix invoice rounding", updatedAt: now.addingTimeInterval(-3_600)),
            Conversation(projectID: app.id, title: "Render tables and math", updatedAt: now.addingTimeInterval(-120)),
            Conversation(projectID: app.id, title: "Pinned design notes", updatedAt: now.addingTimeInterval(-2 * 86_400), isPinned: true),
            Conversation(projectID: api.id, title: "Archived migration", updatedAt: now, isArchived: true),
            Conversation(projectID: api.id, title: "Review webhook retries", updatedAt: now.addingTimeInterval(-40 * 86_400)),
        ]
        return (store, app, api)
    }

    func testProjectFoldersListTheirTasksNewestFirstIgnoringPins() {
        let (store, app, api) = makeStore()
        XCTAssertEqual(store.conversations(inProject: app.id).map(\.title), ["Render tables and math", "Pinned design notes", "Oldest app task"])
        XCTAssertEqual(store.conversations(inProject: api.id).map(\.title), ["Fix invoice rounding", "Review webhook retries"])
    }

    func testRecentsCoverEveryProjectNewestFirstAndStartFolded() {
        let (store, _, _) = makeStore()
        XCTAssertFalse(store.recentsExpanded)
        XCTAssertEqual(store.recentConversations.map(\.title), [
            "Render tables and math", "Fix invoice rounding", "Pinned design notes", "Oldest app task", "Review webhook retries"
        ])
        XCTAssertEqual(store.pinnedConversations.map(\.title), ["Pinned design notes"])
        XCTAssertEqual(store.archivedConversations.map(\.title), ["Archived migration"])
    }

    func testSearchSpansProjectsAndFollowsArchiveToggle() {
        let (store, _, _) = makeStore()
        store.search = "i"
        XCTAssertTrue(store.searchResults.allSatisfy { !$0.isArchived })
        XCTAssertTrue(store.searchResults.contains { $0.title == "Fix invoice rounding" })
        store.showArchived = true
        XCTAssertEqual(store.searchResults.map(\.title), ["Archived migration"])
    }

    func testFolderFoldingPersistsAcrossLaunches() throws {
        let (store, app, _) = makeStore()
        XCTAssertTrue(store.isProjectExpanded(app.id))
        store.toggleProjectExpanded(app.id)
        XCTAssertFalse(store.isProjectExpanded(app.id))
        store.flush()
        let reopened = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        XCTAssertFalse(reopened.isProjectExpanded(app.id))
        XCTAssertFalse(reopened.recentsExpanded, "Recents starts folded on every launch")
    }

    func testSelectingATaskClearsItsUnreadMark() {
        let (store, _, _) = makeStore()
        let task = store.state.conversations[1]
        store.unreadConversationIDs = [task.id]
        store.selectConversation(task)
        XCTAssertTrue(store.unreadConversationIDs.isEmpty)
    }

    func testRelativeTimesAreCompact() {
        let now = Date()
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-3 * 3_600), now: now), "3h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-2 * 86_400), now: now), "2d")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-15 * 86_400), now: now), "2w")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-70 * 86_400), now: now), "2mo")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-800 * 86_400), now: now), "2y")
    }

    /// Writes PNGs of the sidebar when GROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
    func testRenderSidebarSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let (store, _, _) = makeStore()
        store.state.selectedConversationID = store.state.conversations[2].id
        store.unreadConversationIDs = [store.state.conversations[1].id]
        for (name, expanded, appearance) in [("sidebar-folded-light", false, NSAppearance.Name.aqua), ("sidebar-recents-dark", true, .darkAqua)] {
            store.recentsExpanded = expanded
            try SnapshotRenderer.write(SidebarView().environmentObject(store).frame(width: 280, height: 760),
                                       size: CGSize(width: 280, height: 760), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
    }
}

/// Renders a SwiftUI view offscreen (xctest windows never become key, but drawing works).
@MainActor
enum SnapshotRenderer {
    static func write<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.background(Theme.canvas))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
