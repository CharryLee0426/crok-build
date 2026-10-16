import XCTest

@testable import Crok

/// The grouped list's order rules (relay/DESIGN.md §2 "Projects and order"), search, and the engine's optimistic moves.
final class ProjectOrderTests: XCTestCase {
    static func row(
        _ id: String, project: String = "/src/app", device: String = "mac", pinned: Bool = false, at: Double = 0,
        cwd: String? = nil, title: String? = nil
    ) -> SessionRow {
        SessionRow(
            id: id, sessionId: id, title: title ?? "Session \(id)", cwd: cwd ?? project, model: nil, status: .idle,
            online: false, app: .tui, deviceId: device, deviceName: device == "mac" ? "MacBook Pro" : "Studio",
            deviceOnline: true, preview: nil, previewKind: nil, lastActivityAt: at, pinned: pinned, archived: false,
            unread: 0, plan: nil, projectKey: "\(device):\(project)", projectPath: project,
            projectName: PathText.lastComponent(project), historyState: nil)
    }

    static func group(_ path: String, device: String = "mac", at: Double = 0, placed: Bool = false, _ rows: [SessionRow])
        -> ProjectGroup
    {
        ProjectGroup(
            key: "\(device):\(path)", deviceId: device, deviceName: device == "mac" ? "MacBook Pro" : "Studio",
            deviceOnline: true, path: path, name: PathText.lastComponent(path), placed: placed, lastActivityAt: at,
            sessions: rows)
    }

    func testReorderWithinMatchesTheRelay() {
        // The wanted items take the places they held; the others stay put.
        XCTAssertEqual(ProjectOrder.reorderWithin(["a", "b", "c", "d"], ["d", "b"]), ["a", "d", "c", "b"])
        XCTAssertEqual(ProjectOrder.reorderWithin(["a", "b", "c"], ["c", "b", "a"]), ["c", "b", "a"])
        // Unknown items are ignored; a repeated one leaves the list as it was.
        XCTAssertEqual(ProjectOrder.reorderWithin(["a", "b", "c"], ["x", "c", "a"]), ["c", "b", "a"])
        XCTAssertEqual(ProjectOrder.reorderWithin(["a", "b", "c"], ["a", "a"]), ["a", "b", "c"])
        XCTAssertEqual(ProjectOrder.reorderWithin([String](), ["a"]), [])
    }

    func testMovingProjectsOfOneComputerKeepsTheOthersInPlace() {
        let groups = [
            Self.group("/m1", [Self.row("1", project: "/m1")]),
            Self.group("/s1", device: "studio", [Self.row("2", project: "/s1", device: "studio")]),
            Self.group("/m2", [Self.row("3", project: "/m2")]),
        ]
        let moved = ProjectOrder.apply(.projects(["mac:/m2", "mac:/m1"]), to: groups)
        XCTAssertEqual(moved.map(\.key), ["mac:/m2", "studio:/s1", "mac:/m1"])
        XCTAssertTrue(moved.allSatisfy(\.placed), "reordering places every project")
        XCTAssertEqual(ProjectOrder.apply(.projects(["mac:/m2", "mac:/m1"]), to: moved), moved, "applying twice is a no-op")
    }

    func testMovingSessionsKeepsPinnedOnesFirst() {
        let rows = [
            Self.row("p", pinned: true), Self.row("a"), Self.row("b"), Self.row("c"),
        ]
        let groups = [Self.group("/src/app", rows)]
        // Dragging "c" above the pinned one: it lands first among the unpinned.
        let moved = ProjectOrder.apply(.sessions(projectKey: "mac:/src/app", ids: ["c", "p", "a", "b"]), to: groups)
        XCTAssertEqual(moved[0].sessions.map(\.id), ["p", "c", "a", "b"])
        // Another project is untouched.
        let other = ProjectOrder.apply(.sessions(projectKey: "mac:/elsewhere", ids: ["c", "p"]), to: groups)
        XCTAssertEqual(other, groups)
    }

    func testSortingByActivityClearsHandPlacement() {
        let groups = [
            Self.group("/old", at: 1, placed: true, [Self.row("o1", project: "/old", at: 1)]),
            Self.group("/new", at: 9, placed: true, [
                Self.row("n1", project: "/new", at: 2), Self.row("n2", project: "/new", pinned: true, at: 1),
                Self.row("n3", project: "/new", at: 9),
            ]),
        ]
        let projects = ProjectOrder.apply(.projectsByActivity, to: groups)
        XCTAssertEqual(projects.map(\.key), ["mac:/new", "mac:/old"])
        XCTAssertFalse(projects.contains(where: \.placed))
        let sessions = ProjectOrder.apply(.sessionsByActivity(projectKey: "mac:/new"), to: groups)
        XCTAssertEqual(sessions[1].sessions.map(\.id), ["n2", "n3", "n1"], "pinned first, then newest first")
        XCTAssertEqual(sessions[0], groups[0])
    }

    func testOnMoveOffsetsAreSwiftUIs() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(ProjectOrder.moved(items, fromOffsets: [1], toOffset: 3), ["a", "c", "b", "d"])
        XCTAssertEqual(ProjectOrder.moved(items, fromOffsets: [3], toOffset: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(ProjectOrder.moved(items, fromOffsets: [0], toOffset: 4), ["b", "c", "d", "a"])
        XCTAssertEqual(ProjectOrder.moved(items, fromOffsets: [0, 2], toOffset: 4), ["b", "d", "a", "c"])
        XCTAssertEqual(ProjectOrder.moved(items, fromOffsets: [2], toOffset: 2), items)
    }

    func testMoveUpAndDown() {
        XCTAssertEqual(ProjectOrder.keys(["a", "b", "c"], moving: "b", by: -1), ["b", "a", "c"])
        XCTAssertEqual(ProjectOrder.keys(["a", "b", "c"], moving: "b", by: 1), ["a", "c", "b"])
        XCTAssertNil(ProjectOrder.keys(["a", "b", "c"], moving: "a", by: -1))
        XCTAssertNil(ProjectOrder.keys(["a", "b", "c"], moving: "c", by: 1))
        XCTAssertNil(ProjectOrder.keys(["a"], moving: "x", by: 1))

        let rows = [Self.row("p", pinned: true), Self.row("a"), Self.row("b")]
        XCTAssertEqual(ProjectOrder.sessionIDs(rows, moving: "b", by: -1), ["p", "b", "a"])
        XCTAssertNil(ProjectOrder.sessionIDs(rows, moving: "a", by: -1), "an unpinned session can't pass a pinned one")
        XCTAssertNil(ProjectOrder.sessionIDs(rows, moving: "p", by: 1))
        XCTAssertNil(ProjectOrder.sessionIDs(rows, moving: "b", by: 1))
    }

    func testPinningAndArchivingUpdateTheGroups() {
        let groups = [
            Self.group("/one", [Self.row("a", project: "/one"), Self.row("b", project: "/one")]),
            Self.group("/two", [Self.row("c", project: "/two")]),
        ]
        let pinned = ProjectOrder.settingPinned("b", true, in: groups)
        XCTAssertEqual(pinned[0].sessions.map(\.id), ["b", "a"])
        XCTAssertTrue(pinned[0].sessions[0].pinned)
        let archived = ProjectOrder.removing("c", from: groups)
        XCTAssertEqual(archived.map(\.key), ["mac:/one"], "a project without sessions leaves the list")
        XCTAssertEqual(ProjectOrder.removing("nope", from: groups), groups)
    }

    func testSearchKeepsMatchingRowsAndHidesEmptySections() {
        let groups = [
            Self.group("/src/web", [
                Self.row("a", project: "/src/web", title: "Fix the pricing page"),
                Self.row("b", project: "/src/web", title: "Add a changelog"),
            ]),
            Self.group("/src/lexer", device: "studio", [Self.row("c", project: "/src/lexer", device: "studio", title: "Port it")]),
        ]
        XCTAssertEqual(SessionSearch.filter(groups, query: "  "), groups)
        let pricing = SessionSearch.filter(groups, query: "PRICING")
        XCTAssertEqual(pricing.map(\.key), ["mac:/src/web"])
        XCTAssertEqual(pricing[0].sessions.map(\.id), ["a"])
        // A project's or computer's name matches all of its sessions.
        XCTAssertEqual(SessionSearch.filter(groups, query: "lexer").flatMap(\.sessions).map(\.id), ["c"])
        XCTAssertEqual(SessionSearch.filter(groups, query: "studio").flatMap(\.sessions).map(\.id), ["c"])
        XCTAssertTrue(SessionSearch.filter(groups, query: "zzz").isEmpty)
    }

    func testRowsNameTheirFolderOnlyWhenItIsNotTheProject() {
        XCTAssertNil(Self.row("a", project: "/src/crok-build").folderIfNotProject)
        XCTAssertEqual(
            Self.row("b", project: "/src/crok-build", cwd: "/src/crok-build/relay").folderIfNotProject, "relay")
        var legacy = Self.row("c", cwd: "/src/tool")
        legacy.projectName = nil
        XCTAssertEqual(legacy.projectDisplayName, "tool", "a relay without projects: the folder names the row")
    }

    func testCollapsedProjectsAreRemembered() {
        let defaults = UserDefaults(suiteName: "crok.collapsed.\(UUID().uuidString)")!
        let store = CollapsedProjectsStore(defaults: defaults)
        XCTAssertEqual(store.load(), [])
        store.save(["mac:/a", "studio:/b"])
        XCTAssertEqual(CollapsedProjectsStore(defaults: defaults).load(), ["mac:/a", "studio:/b"])
        store.removeAll()
        XCTAssertEqual(store.load(), [])
    }
}

/// A demo relay whose reorder calls fail, to see an optimistic move undone.
private final class FailingReorderRelay: RelayBackend, SessionsAPI, @unchecked Sendable {
    let demo: DemoRelay

    @MainActor
    init(world: DemoWorld) {
        demo = DemoRelay(world: world)
    }

    var sessions: any SessionsAPI { self }
    var commands: any CommandsAPI { demo }
    var devices: any DevicesAPI { demo }
    var account: any AccountAPI { demo }
    func connectionSignals() -> AsyncStream<ConnectionSignal> { demo.connectionSignals() }
    func start() async {}
    func shutdown() async {}

    func groups() -> RelayStream<[ProjectGroup]> { demo.groups() }
    func list(archived: Bool) -> RelayStream<[SessionRow]> { demo.list(archived: archived) }
    func get(_ sessionDocId: DocID) -> RelayStream<SessionDetail> { demo.get(sessionDocId) }
    func events(_ sessionDocId: DocID, cursor: String?, endCursor: String?, numItems: Int) -> RelayStream<EventsPage> {
        demo.events(sessionDocId, cursor: cursor, endCursor: endCursor, numItems: numItems)
    }
    func markRead(_ sessionDocId: DocID) async throws { try await demo.markRead(sessionDocId) }
    func watch(_ sessionDocId: DocID) async throws { try await demo.watch(sessionDocId) }
    func setPinned(_ sessionDocId: DocID, _ pinned: Bool) async throws { try await demo.setPinned(sessionDocId, pinned) }
    func setArchived(_ sessionDocId: DocID, _ archived: Bool) async throws { try await demo.setArchived(sessionDocId, archived) }
    func remove(_ sessionDocId: DocID) async throws { try await demo.remove(sessionDocId) }

    func reorderProjects(_ keys: [String]) async throws {
        try await Task.sleep(for: .milliseconds(100))
        throw RelayError(.server, "No.")
    }

    func reorderSessions(projectKey: String, _ sessionDocIds: [DocID]) async throws {
        throw RelayError(.server, "No.")
    }

    func resetOrder(projectKey: String?) async throws {
        throw RelayError(.server, "No.")
    }
}

@MainActor
final class EngineReorderTests: XCTestCase {
    private func credentials() -> StoredCredentials {
        StoredCredentials(
            serverURL: "https://demo", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
    }

    private func drafts() -> DraftStore {
        DraftStore(defaults: UserDefaults(suiteName: "crok.engine.\(UUID().uuidString)")!)
    }

    private func waitForGroups(_ engine: CrokEngine) async throws {
        for _ in 0..<100 where engine.groupList.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(engine.groupList.value)
    }

    func testTheDemoListIsGroupedByProject() async throws {
        let world = DemoWorld()
        let engine = CrokEngine(backend: DemoRelay(world: world), credentials: credentials(), isDemo: true, drafts: drafts(), cache: nil)
        engine.start()
        try await waitForGroups(engine)
        let groups = engine.groups
        XCTAssertEqual(groups.first?.name, "crok-build", "the most recently active project leads")
        XCTAssertEqual(groups.first?.sessions.first?.title, "Fix the flaky upload test", "pinned first")
        XCTAssertGreaterThan(groups.first?.sessions.count ?? 0, ProjectOrder.previewLimit, "enough for Show N more")
        XCTAssertEqual(Set(groups.map(\.deviceId)), ["mbp", "studio"])
        let listed = groups.flatMap(\.sessions).filter { $0.historyState == .notFetched && !$0.deviceOnline }
        XCTAssertFalse(listed.isEmpty, "a session only on an offline computer's disk")
        XCTAssertFalse(groups.flatMap(\.sessions).contains(where: \.archived))
        await engine.shutdown()
    }

    func testAMoveShowsAtOnceAndTheRelayKeepsIt() async throws {
        let world = DemoWorld()
        let engine = CrokEngine(backend: DemoRelay(world: world), credentials: credentials(), isDemo: true, drafts: drafts(), cache: nil)
        engine.start()
        try await waitForGroups(engine)
        let keys = engine.groups.map(\.key)
        let wanted = Array(keys.reversed())
        let move = Task { await engine.reorder(.projects(wanted)) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.groups.map(\.key), wanted, "shown before the relay answers")
        XCTAssertEqual(engine.pendingReorders.count, 1)
        let error = await move.value
        XCTAssertNil(error)
        XCTAssertTrue(engine.pendingReorders.isEmpty)
        XCTAssertEqual(engine.groups.map(\.key), wanted)
        XCTAssertEqual(world.groups().map(\.key), wanted, "the relay has the new order")

        // Sessions within a project, then back to recent activity.
        let project = try XCTUnwrap(engine.groups.first(where: { $0.name == "crok-build" }))
        let unpinned = project.sessions.filter { !$0.pinned }.map(\.id)
        let reordered = project.sessions.filter(\.pinned).map(\.id) + unpinned.reversed()
        let sessionsError = await engine.reorder(.sessions(projectKey: project.key, ids: reordered))
        XCTAssertNil(sessionsError)
        XCTAssertEqual(world.groups().first(where: { $0.key == project.key })?.sessions.map(\.id), reordered)
        let resetError = await engine.reorder(.sessionsByActivity(projectKey: project.key))
        XCTAssertNil(resetError)
        XCTAssertEqual(world.groups().first(where: { $0.key == project.key })?.sessions.map(\.id), project.sessions.map(\.id))
        let projectsError = await engine.reorder(.projectsByActivity)
        XCTAssertNil(projectsError)
        XCTAssertEqual(world.groups().map(\.key), keys)
        await engine.shutdown()
    }

    func testAFailedMoveGoesBack() async throws {
        let world = DemoWorld()
        let engine = CrokEngine(
            backend: FailingReorderRelay(world: world), credentials: credentials(), isDemo: true, drafts: drafts(), cache: nil)
        engine.start()
        try await waitForGroups(engine)
        let keys = engine.groups.map(\.key)
        let move = Task { await engine.reorder(.projects(Array(keys.reversed()))) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.groups.map(\.key), Array(keys.reversed()))
        let error = await move.value
        XCTAssertEqual(error?.message, "No.")
        XCTAssertEqual(engine.groups.map(\.key), keys, "the relay's order is back")
        await engine.shutdown()
    }

    func testCollapsingAProjectIsRememberedForTheAccount() async throws {
        let store = drafts()
        let engine = CrokEngine(backend: DemoRelay(), credentials: credentials(), isDemo: true, drafts: store, cache: nil)
        engine.toggleCollapsed("mbp:/Users/charlie/src/website")
        XCTAssertTrue(engine.isCollapsed("mbp:/Users/charlie/src/website"))
        let again = CrokEngine(backend: DemoRelay(), credentials: credentials(), isDemo: true, drafts: store, cache: nil)
        XCTAssertTrue(again.isCollapsed("mbp:/Users/charlie/src/website"))
        again.toggleCollapsed("mbp:/Users/charlie/src/website")
        XCTAssertFalse(CrokEngine(backend: DemoRelay(), credentials: credentials(), isDemo: true, drafts: store, cache: nil)
            .isCollapsed("mbp:/Users/charlie/src/website"))
    }

    func testOpeningAListedSessionFetchesItsHistoryWhileTheComputerIsOnline() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let online = try XCTUnwrap(world.sessions.firstIndex(where: { $0.detail.id == "s-pricing" }))
        let offline = try XCTUnwrap(world.sessions.firstIndex(where: { $0.detail.id == "s-lexer" }))
        XCTAssertEqual(world.sessions[online].detail.historyState, .notFetched)
        XCTAssertTrue(world.sessions[online].events.isEmpty)

        try await relay.watch("s-lexer")
        XCTAssertEqual(world.sessions[offline].detail.historyState, .notFetched, "nothing happens while Studio is offline")

        try await relay.watch("s-pricing")
        XCTAssertEqual(world.sessions[online].detail.historyState, .requested)
        for _ in 0..<250 where world.sessions[online].detail.historyState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(world.sessions[online].detail.historyState, .ready)
        XCTAssertFalse(world.sessions[online].events.isEmpty)
    }
}
