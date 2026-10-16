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

/// Sessions nobody runs and permission requests, as the demo relay implements relay/convex/commands.ts: a prompt
/// reaches any session of an online computer, Stop and info settle at once for a session nobody runs, and the first
/// answer to a pending request wins.
@MainActor
final class RemoteCommandsTests: XCTestCase {
    private func makeEngine(_ world: DemoWorld) -> CrokEngine {
        let credentials = StoredCredentials(
            serverURL: "https://demo", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.remote.\(UUID().uuidString)")!)
        return CrokEngine(backend: DemoRelay(world: world), credentials: credentials, isDemo: true, drafts: drafts, cache: nil)
    }

    /// Waits until `condition` holds, checking every 20 ms; returns whether it did.
    private func eventually(_ timeout: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func relayCode(_ work: () async throws -> Void) async -> RelayError.Code? {
        do {
            try await work()
            return nil
        } catch {
            return error.relayCode
        }
    }

    func testAPromptOpensASessionNobodyRunsOnAnOnlineComputer() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let notes = try world.index(of: "s-notes")
        XCTAssertFalse(world.sessions[notes].detail.online)
        let commandId = try await relay.sendPrompt("s-notes", text: "Add the German notes", clientId: "c-1")
        XCTAssertEqual(world.sessions[notes].commands.first?.status, .pending)
        let opened = try await eventually { world.sessions[notes].detail.online }
        XCTAssertTrue(opened, "a crok on the MacBook opened it")
        XCTAssertEqual(world.sessions[notes].detail.status, .running)
        XCTAssertEqual(world.sessions[notes].events.last(where: { $0.kind == .user })?.commandId, commandId)
        _ = try await relay.stop("s-notes")

        // A session only on the computer's disk comes with its history, the prompt after it.
        let pricing = try world.index(of: "s-pricing")
        _ = try await relay.sendPrompt("s-pricing", text: "Now the footer", clientId: "c-2")
        let loaded = try await eventually { world.sessions[pricing].detail.online }
        XCTAssertTrue(loaded)
        XCTAssertEqual(world.sessions[pricing].detail.historyState, .ready)
        XCTAssertEqual(world.sessions[pricing].events.first?.id, "e-pricing-1")
        XCTAssertEqual(world.sessions[pricing].events.last(where: { $0.kind == .user })?.text, "Now the footer")
        _ = try await relay.stop("s-pricing")
    }

    func testAPromptToAnOfflineComputerIsRefused() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let code = await relayCode { _ = try await relay.sendPrompt("s-bench", text: "Run it again", clientId: "c-3") }
        XCTAssertEqual(code, .offline, "Studio is offline")
        XCTAssertTrue(world.sessions[try world.index(of: "s-bench")].commands.isEmpty)
    }

    func testStopAndInfoSettleAtOnceForASessionNobodyRuns() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let notes = try world.index(of: "s-notes")
        // Stop before any computer picked the prompt up: it is dropped, and nothing opens the session.
        _ = try await relay.sendPrompt("s-notes", text: "Queued", clientId: "c-4")
        _ = try await relay.stop("s-notes")
        XCTAssertEqual(world.sessions[notes].commands.first?.status, .failed)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(world.sessions[notes].detail.online)
        XCTAssertFalse(world.sessions[notes].events.contains(where: { $0.text == "Queued" }))

        // Info: what the computer last sent, at once, for a session nobody runs (even on an offline computer).
        for id in ["s-notes", "s-bench"] {
            let infoId = try await relay.requestInfo(id)
            XCTAssertEqual(world.infoCommands[infoId]?.status, .done, id)
            XCTAssertEqual(world.infoCommands[infoId]?.result?.stored, true, id)
            XCTAssertEqual(world.infoCommands[infoId]?.result?.model, world.sessions[try world.index(of: id)].detail.model)
        }
        let running = try await relay.requestInfo("s-flaky")
        XCTAssertEqual(world.infoCommands[running]?.status, .pending, "a running session asks its computer")
    }

    func testTheFirstAnswerToAPermissionRequestWinsAndTheTurnGoesOn() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let deps = try world.index(of: "s-deps")
        let pending = try XCTUnwrap(world.sessions[deps].detail.pending)
        XCTAssertEqual(world.sessions[deps].detail.status, .waiting)

        let unknown = await relayCode { _ = try await relay.answer("s-deps", interactionId: pending.id, optionId: "nope") }
        XCTAssertEqual(unknown, .invalid)
        let other = await relayCode { _ = try await relay.answer("s-deps", interactionId: "call_9#1", optionId: "allow-once") }
        XCTAssertEqual(other, .expired, "not the request the session waits on")

        _ = try await relay.answer("s-deps", interactionId: pending.id, optionId: "allow-once")
        let second = await relayCode {
            _ = try await relay.answer("s-deps", interactionId: pending.id, optionId: "reject-once")
        }
        XCTAssertEqual(second, .expired, "another device answered first")
        let taken = try await eventually { world.sessions[deps].detail.pending == nil }
        XCTAssertTrue(taken, "the computer took the answer")
        XCTAssertEqual(world.sessions[deps].detail.status, .running)
        let finished = try await eventually { world.sessions[deps].detail.status == .idle }
        XCTAssertTrue(finished)
        XCTAssertEqual(world.sessions[deps].events.first(where: { $0.id == "e-deps-4" })?.status, "completed")
        XCTAssertEqual(world.sessions[deps].events.last?.status, "end_turn")
    }

    func testDenyingAPermissionRequestEndsTheTurn() async throws {
        let world = DemoWorld()
        let relay = DemoRelay(world: world)
        let deps = try world.index(of: "s-deps")
        let pending = try XCTUnwrap(world.sessions[deps].detail.pending)
        _ = try await relay.answer("s-deps", interactionId: pending.id, optionId: "reject-once")
        let taken = try await eventually { world.sessions[deps].detail.pending == nil }
        XCTAssertTrue(taken)
        XCTAssertEqual(world.sessions[deps].detail.status, .idle)
        XCTAssertEqual(world.sessions[deps].events.first(where: { $0.id == "e-deps-4" })?.status, "failed")
        XCTAssertEqual(world.sessions[deps].events.last(where: { $0.kind == .assistant })?.text, DemoWorld.deniedReply)
    }

    /// The composer's rule: it takes prompts whenever the computer is online; only an offline computer blocks it.
    func testTheComposerTakesPromptsWheneverTheComputerIsOnline() async throws {
        let engine = makeEngine(DemoWorld())
        engine.start()
        let notRunning = SessionViewModel(sessionDocId: "s-notes", engine: engine)
        let offlineComputer = SessionViewModel(sessionDocId: "s-bench", engine: engine)
        notRunning.appear()
        offlineComputer.appear()
        let loaded = try await eventually { notRunning.detail.value != nil && offlineComputer.detail.value != nil }
        XCTAssertTrue(loaded)

        XCTAssertFalse(notRunning.isOnline)
        XCTAssertTrue(notRunning.canSendPrompts, "nobody runs it, but the MacBook is online")
        XCTAssertEqual(notRunning.presence, .idle)
        XCTAssertFalse(offlineComputer.canSendPrompts)
        XCTAssertEqual(offlineComputer.presence, .offline)

        offlineComputer.draft = "Run it again"
        offlineComputer.send()
        XCTAssertNil(engine.localPrompts["s-bench"], "nothing is sent while Studio is offline")
        XCTAssertEqual(offlineComputer.draft, "Run it again")

        // Sending to the session nobody runs: the optimistic bubble at once, then a crok opens it and the turn runs.
        notRunning.draft = "Add the German notes"
        notRunning.send()
        XCTAssertEqual(engine.localPrompts["s-notes"]?.map(\.text), ["Add the German notes"])
        let running = try await eventually { notRunning.isRunning }
        XCTAssertTrue(running)
        XCTAssertEqual(notRunning.presence, .running)
        await notRunning.stop()

        notRunning.tearDown()
        offlineComputer.tearDown()
        await engine.shutdown()
    }

    func testAnsweringFromTheSessionScreen() async throws {
        let world = DemoWorld()
        let engine = makeEngine(world)
        engine.start()
        let model = SessionViewModel(sessionDocId: "s-deps", engine: engine)
        model.appear()
        let shown = try await eventually { model.pendingRequest != nil }
        XCTAssertTrue(shown)
        let request = try XCTUnwrap(model.pendingRequest)
        XCTAssertEqual(request.options.filter(\.isAllow).map(\.optionId), ["allow-once", "allow-always"])

        // A refused answer is shown; the buttons come back.
        await model.answer(PendingOption(optionId: "nope", name: "Nope", kind: "allow_once"), to: request)
        XCTAssertEqual(model.actionError?.code, .invalid)
        XCTAssertFalse(model.isAnsweringRequest)
        model.actionError = nil

        // The answer: buttons disabled until the computer takes it, then the card goes.
        await model.answer(request.options[0], to: request)
        XCTAssertNil(model.actionError)
        XCTAssertTrue(model.isAnsweringRequest, "the computer has not taken it yet")
        let taken = try await eventually { model.pendingRequest == nil }
        XCTAssertTrue(taken)
        XCTAssertFalse(model.isAnsweringRequest)
        XCTAssertNil(model.answeringRequestId)

        // Answering the old request again (another device was faster, say) is quiet.
        await model.answer(request.options[2], to: request)
        XCTAssertNil(model.actionError, "EXPIRED needs no alert")
        XCTAssertNil(model.answeringRequestId)

        model.tearDown()
        await engine.shutdown()
    }
}
