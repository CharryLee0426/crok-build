import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

@MainActor
final class SidebarReorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-reorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var stateFile: URL { directory.appendingPathComponent("state.json") }

    /// Three projects; the first has four tasks, newest first A, B, C, D, and two of them are pinned.
    private func makeStore() -> (AppStore, [Project], [Conversation]) {
        let store = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        let projects = [Project(path: "/tmp/alpha"), Project(path: "/tmp/beta"), Project(path: "/tmp/gamma")]
        let now = Date()
        let tasks = ["A", "B", "C", "D"].enumerated().map { index, title in
            Conversation(projectID: projects[0].id, title: title, updatedAt: now.addingTimeInterval(Double(-60 * index)), isPinned: index % 2 == 1)
        }
        store.state.projects = projects
        store.state.conversations = tasks
        return (store, projects, tasks)
    }

    private func titles(_ store: AppStore, _ list: SidebarTaskList) -> [String] { store.tasks(in: list).map(\.title) }

    // MARK: Store

    func testProjectsMoveToTheDroppedSlotAndStayThereAfterRelaunch() {
        let (store, projects, _) = makeStore()
        store.moveProject(projects[2].id, to: 0)
        XCTAssertEqual(store.state.projects.map(\.name), ["gamma", "alpha", "beta"])
        store.moveProject(projects[2].id, to: 99)
        XCTAssertEqual(store.state.projects.map(\.name), ["alpha", "beta", "gamma"], "a slot past the end is the last one")
        store.moveProject(projects[0].id, to: 1)
        XCTAssertEqual(store.state.projects.map(\.name), ["beta", "alpha", "gamma"])
        store.flush()
        let reopened = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(reopened.state.projects.map(\.name), ["beta", "alpha", "gamma"])
    }

    func testDraggingATaskGivesItsFolderTheUsersOrder() {
        let (store, projects, tasks) = makeStore()
        let folder = SidebarTaskList.project(projects[0].id)
        XCTAssertFalse(store.hasManualOrder(folder))
        store.moveTask(tasks[3].id, to: 0, in: folder)
        XCTAssertEqual(titles(store, folder), ["D", "A", "B", "C"])
        XCTAssertTrue(store.hasManualOrder(folder))
        // New activity no longer reorders the folder.
        store.state.conversations[1].updatedAt = Date().addingTimeInterval(60)
        XCTAssertEqual(titles(store, folder), ["D", "A", "B", "C"])
        // Recents keeps following activity.
        XCTAssertEqual(store.recentConversations.map(\.title).first, "B")
    }

    func testNewTasksLeadAFolderInTheUsersOrder() {
        let (store, projects, tasks) = makeStore()
        let folder = SidebarTaskList.project(projects[0].id)
        store.moveTask(tasks[0].id, to: 3, in: folder)
        XCTAssertEqual(titles(store, folder), ["B", "C", "D", "A"])
        store.state.conversations.append(Conversation(projectID: projects[0].id, title: "New"))
        XCTAssertEqual(titles(store, folder), ["New", "B", "C", "D", "A"])
        // Placing the new task makes it part of the order.
        store.moveTask(store.state.conversations[4].id, to: 2, in: folder)
        XCTAssertEqual(titles(store, folder), ["B", "C", "New", "D", "A"])
    }

    func testDeletedAndArchivedTasksLeaveTheOrder() {
        let (store, projects, tasks) = makeStore()
        let folder = SidebarTaskList.project(projects[0].id)
        store.moveTask(tasks[3].id, to: 0, in: folder)
        store.deleteConversation(tasks[1].id)
        store.archive(tasks[2].id)
        XCTAssertEqual(titles(store, folder), ["D", "A"])
        store.archive(tasks[2].id)
        XCTAssertEqual(titles(store, folder), ["D", "A", "C"], "a restored task keeps its place")
    }

    func testPinnedTasksReorderApartFromTheirFolder() {
        let (store, projects, tasks) = makeStore()
        XCTAssertEqual(titles(store, .pinned), ["B", "D"])
        store.moveTask(tasks[3].id, to: 0, in: .pinned)
        XCTAssertEqual(titles(store, .pinned), ["D", "B"])
        XCTAssertEqual(titles(store, .project(projects[0].id)), ["A", "B", "C", "D"], "the folder is untouched")
        store.flush()
        let reopened = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(titles(reopened, .pinned), ["D", "B"])
    }

    func testSortByRecentActivityDropsTheUsersOrder() {
        let (store, projects, tasks) = makeStore()
        let folder = SidebarTaskList.project(projects[0].id)
        store.moveTask(tasks[3].id, to: 0, in: folder)
        store.moveTask(tasks[3].id, to: 0, in: .pinned)
        store.sortByRecentActivity(folder)
        XCTAssertFalse(store.hasManualOrder(folder))
        XCTAssertEqual(titles(store, folder), ["A", "B", "C", "D"])
        XCTAssertEqual(titles(store, .pinned), ["D", "B"], "each list resets on its own")
        store.sortByRecentActivity(.pinned)
        XCTAssertEqual(titles(store, .pinned), ["B", "D"])
    }

    func testMovingToTheSameSlotDoesNotStartAnOrder() {
        let (store, projects, tasks) = makeStore()
        let folder = SidebarTaskList.project(projects[0].id)
        store.moveTask(tasks[1].id, to: 1, in: folder)
        XCTAssertFalse(store.hasManualOrder(folder))
    }

    func testStateWithoutOrdersStillLoads() throws {
        let legacy = #"{"projects":[{"id":"8F0F4B0E-4C2B-4E0B-9A45-2B7A7F2B1C11","path":"/tmp/alpha"}],"conversations":[],"deletedSessionIDs":[]}"#
        try Data(legacy.utf8).write(to: stateFile)
        let store = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        XCTAssertEqual(store.state.projects.count, 1)
        XCTAssertTrue(store.state.taskOrder.isEmpty)
        XCTAssertTrue(store.state.pinnedOrder.isEmpty)
    }

    // MARK: Drag arithmetic

    /// Five 30-point rows with 1 point between them.
    private let rows = (0..<5).map { CGRect(x: 0, y: CGFloat($0) * 31, width: 200, height: 30) }

    func testTargetSlotFollowsThePointerPastEachRowsMiddle() {
        let gap: CGFloat = 31
        XCTAssertEqual(ReorderLayout.target(pointerY: 15, origin: 0, gap: gap, frames: rows), 0)
        // Dragging row 0 down: row 1 is measured as if row 0 had left (middle at 15).
        XCTAssertEqual(ReorderLayout.target(pointerY: 16, origin: 0, gap: gap, frames: rows), 1)
        XCTAssertEqual(ReorderLayout.target(pointerY: 200, origin: 0, gap: gap, frames: rows), 4)
        // Dragging row 4 up past rows 3 and 2.
        XCTAssertEqual(ReorderLayout.target(pointerY: 60, origin: 4, gap: gap, frames: rows), 2)
        XCTAssertEqual(ReorderLayout.target(pointerY: -40, origin: 4, gap: gap, frames: rows), 0)
    }

    func testRowsBetweenTheOriginAndTargetMakeWay() {
        let down = ReorderDrag(id: UUID(), origin: 1, target: 3, gap: 31)
        XCTAssertEqual((0..<5).map { ReorderLayout.offset(of: $0, drag: down, translation: 70) }, [0, 70, -31, -31, 0])
        let up = ReorderDrag(id: UUID(), origin: 3, target: 1, gap: 31)
        XCTAssertEqual((0..<5).map { ReorderLayout.offset(of: $0, drag: up, translation: -60) }, [0, 31, 31, -60, 0])
        XCTAssertEqual((0..<5).map { ReorderLayout.offset(of: $0, drag: nil, translation: 0) }, [0, 0, 0, 0, 0])
    }

    func testATallFolderSwapsHalfwayLikeARow() {
        // A folder of 150 points (header and tasks) between two headers.
        let frames = [CGRect(x: 0, y: 0, width: 200, height: 30), CGRect(x: 0, y: 31, width: 200, height: 150), CGRect(x: 0, y: 182, width: 200, height: 30)]
        // Dragging the last header up: it passes the folder once the pointer is above its middle.
        XCTAssertEqual(ReorderLayout.target(pointerY: 120, origin: 2, gap: 31, frames: frames), 2)
        XCTAssertEqual(ReorderLayout.target(pointerY: 100, origin: 2, gap: 31, frames: frames), 1)
    }

    /// Renders a list mid-drag when CROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
    func testRenderDragSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        struct Row: Identifiable { let id = UUID(); let title: String }
        let items = ["Render tables and math", "Fix invoice rounding", "Pinned design notes", "Review webhook retries", "Oldest app task"].map(Row.init)
        for (name, appearance) in [("reorder-drag-light", NSAppearance.Name.aqua), ("reorder-drag-dark", .darkAqua)] {
            let view = ReorderableStack(items: items, onMove: { _, _ in },
                                        preview: (ReorderDrag(id: items[1].id, origin: 1, target: 3, gap: 31), 52)) { item, handle in
                HStack { Text(item.title).font(.system(size: 13)); Spacer(); Text("2h").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    .padding(.horizontal, 8).frame(height: 30).modifier(handle)
            }.padding(10).frame(width: 280, height: 200, alignment: .top).background { SidebarMaterial() }
            try SnapshotRenderer.write(view, size: CGSize(width: 280, height: 200), appearance: appearance,
                                       to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
    }
}
