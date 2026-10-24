import XCTest

@testable import Crok

/// The composer's commands, bot cards and new sessions (relay/DESIGN.md §5 "Commands in the composer", "New sessions").
@MainActor
final class ComposerCommandsTests: XCTestCase {
    func testThePhonesCommandsComeFirstAndFollowTheSession() {
        let session = [
            SlashCommand(name: "compact", description: "Summarize"),
            SlashCommand(name: "model", description: "crok's own picker"),
            SlashCommand(name: "review-pr", description: "Review a pull request", hint: "<number>"),
        ]
        let idle = CommandMenu.items(device: CommandMenu.deviceCommands(isRunning: false, modelHasThinking: true), session: session)
        XCTAssertEqual(idle.map(\.name), ["new", "model", "think", "info", "compact", "review-pr"], "no /stop while idle")
        XCTAssertEqual(idle.first(where: { $0.name == "model" })?.source, .device(.model), "the phone's /model wins")
        let running = CommandMenu.deviceCommands(isRunning: true, modelHasThinking: false)
        XCTAssertEqual(running, [.new, .model, .stop, .info], "/think hidden for a model without thinking levels")
        XCTAssertEqual(CommandMenu.deviceCommands(isRunning: false, modelHasThinking: nil), [.new, .model, .think, .info])
        XCTAssertEqual(CommandMenu.items(device: DeviceCommand.allCases, session: session, filter: "Mo").map(\.name), ["model"])
        XCTAssertEqual(CommandMenu.items(device: [], session: session, filter: "re").map(\.name), ["review-pr"])
    }

    func testWhichRowsFillTheFieldAndWhichSendAtOnce() {
        let items = CommandMenu.items(
            device: DeviceCommand.allCases,
            session: [SlashCommand(name: "compact", description: ""), SlashCommand(name: "review-pr", description: "", hint: "<n>")])
        let fills = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.takesArgument) })
        XCTAssertEqual(fills, ["new": true, "model": true, "think": true, "stop": false, "info": false, "compact": false, "review-pr": true])
    }

    func testTheListOpensWhileTheNameIsTyped() {
        XCTAssertEqual(CommandMenu.typedName(in: "/"), "")
        XCTAssertEqual(CommandMenu.typedName(in: "/mo"), "mo")
        XCTAssertNil(CommandMenu.typedName(in: "/model "), "arguments: the list goes")
        XCTAssertNil(CommandMenu.typedName(in: "hello /mo"))
    }

    func testParsingACommandLine() {
        XCTAssertEqual(ComposerCommand.parse("/model  grok 4 "), ComposerCommand(name: "model", argument: "grok 4"))
        XCTAssertEqual(ComposerCommand.parse("/new\nFix the build"), ComposerCommand(name: "new", argument: "Fix the build"))
        XCTAssertEqual(ComposerCommand.parse("/Think")?.deviceCommand, .think)
        XCTAssertNil(ComposerCommand.parse("/compact")?.deviceCommand, "the session's commands go to the computer")
        XCTAssertNil(ComposerCommand.parse("/"))
        XCTAssertNil(ComposerCommand.parse("no command"))
    }

    func testMatchingChoices() {
        let models = DemoWorld.macModels
        func model(_ query: String) -> String? {
            if case .one(let found) = ChoiceMatch.find(query, in: models, keys: { [$0.id, $0.name] }) { return found.id }
            return nil
        }
        XCTAssertEqual(model("grok-4"), "grok-4", "an exact id beats being a prefix of grok-4-fast")
        XCTAssertEqual(model("GROK 4 FAST"), "grok-4-fast")
        XCTAssertEqual(model("sonnet"), nil, "names match from their start")
        XCTAssertEqual(model("claude"), "claude-sonnet-4-5")
        if case .ambiguous(let several) = ChoiceMatch.find("grok", in: models, keys: { [$0.id, $0.name] }) {
            XCTAssertEqual(several.count, 3)
        } else {
            XCTFail("grok is ambiguous")
        }
        let efforts = models[3].efforts
        if case .one(let effort) = ChoiceMatch.find("xhigh", in: efforts, keys: { [$0.id, $0.level, $0.name] }) {
            XCTAssertEqual(effort.id, "thinking-max", "matched by its canonical value; setConfig gets the id")
        } else {
            XCTFail("xhigh matches Max")
        }
        if case .none = ChoiceMatch.find("ultra", in: efforts, keys: { [$0.id, $0.level, $0.name] }) {} else { XCTFail() }
    }

    func testNewSessionsStartInOnlineComputersProjectsMostRecentFirst() {
        func group(_ device: String, _ path: String, online: Bool, last: Double) -> ProjectGroup {
            ProjectGroup(
                key: "\(device):\(path)", deviceId: device, deviceName: device.uppercased(), deviceOnline: online, path: path,
                name: PathText.lastComponent(path), placed: false, lastActivityAt: last, sessions: [])
        }
        let computers = NewSessionChoices.computers(from: [
            group("mac", "/a", online: true, last: 10), group("pc", "/b", online: true, last: 30),
            group("mac", "/c", online: true, last: 20), group("off", "/d", online: false, last: 99),
        ])
        XCTAssertEqual(computers.map(\.deviceId), ["pc", "mac"])
        XCTAssertEqual(computers[1].projects.map(\.path), ["/c", "/a"])
        XCTAssertEqual(NewSessionTarget(group: computers[1].projects[0]).projectName, "c")
    }

    func testWhatABotCardOffers() throws {
        var detail = try XCTUnwrap(DemoWorld().detailForTests("s-dark"))
        let models = detail.models
        let card = BotCard(kind: .think)
        guard case .choices(let levels) = BotChoices.make(.think, models: models, detail: detail, computerName: "Mac", computerOnline: true)
        else {
            return XCTFail("Claude's thinking levels")
        }
        XCTAssertEqual(levels.map(\.id), ["thinking-low", "thinking-medium", "thinking-high", "thinking-max"])
        XCTAssertEqual(levels.first(where: \.isCurrent)?.title, "Medium", "the session's effort is the canonical value")
        XCTAssertEqual(card.state, .choosing(note: nil))
        detail.model = "grok-4-fast"
        XCTAssertEqual(
            BotChoices.make(.think, models: models, detail: detail, computerName: "Mac", computerOnline: true),
            .noThinking(model: "Grok 4 Fast"))
        XCTAssertEqual(
            BotChoices.make(.model, models: nil, detail: detail, computerName: "Mac", computerOnline: true), .notOffered("Mac"),
            "an older crok there")
        XCTAssertEqual(
            BotChoices.make(.model, models: nil, detail: detail, computerName: "Mac", computerOnline: false), .computerOffline("Mac"))
    }

    func testABotCardReadsTheComputersListNotTheSessionsShortCopy() throws {
        var detail = try XCTUnwrap(DemoWorld().detailForTests("s-relay"))
        // A computer with OpenRouter: `sessions:get` leaves a long list out (null); `devices:models` has it.
        detail.models = nil
        let long = (0..<450).map { ModelChoice(id: "openrouter/vendor/model-\($0)", name: "Model \($0)") }
        detail.model = "openrouter/vendor/model-449"
        guard case .choices(let choices) = BotChoices.make(.model, models: long, detail: detail, computerName: "Mac", computerOnline: true)
        else { return XCTFail("the computer's list") }
        XCTAssertEqual(choices.count, 450)
        XCTAssertEqual(choices.first(where: \.isCurrent)?.id, "openrouter/vendor/model-449")
        XCTAssertEqual(BotChoices.name(of: "openrouter/vendor/model-3", .model, models: long, detail: detail), "Model 3")
    }

    func testBotCardsSitWhereTheyWereAskedForBeforeQueuedPrompts() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            TranscriptEvent(id: "e1", seq: 1, key: "k1", kind: .assistant, text: "Hi", at: t.milliseconds)
        ]
        let queued = LocalPrompt(clientId: "c1", text: "later", createdAt: t.addingTimeInterval(5).milliseconds)
        let card = BotCard(id: "b1", kind: .model, createdAt: t.addingTimeInterval(10))
        let items = TranscriptBuilder.build(events: events, commands: [], local: [queued], hasOlder: false, cards: [card])
        XCTAssertEqual(items.map(\.id).filter { !$0.hasPrefix("day-") }, ["e1", "card-b1", "pending-c1"])
    }
}

/// The new fields decode defensively: an older relay without them, and odd entries, never hide a session.
final class NewFieldsDecodingTests: XCTestCase {
    func testASessionWithModelsAndThinkingLevels() throws {
        let json = #"""
            {"_id":"s1","sessionId":"pending:abc","title":"New session","cwd":"/src/app","model":null,"effort":"high",
             "gitBranch":null,"status":"idle","online":false,"app":"desktop","deviceId":"d1","deviceName":"Mac",
             "devicePlatform":"macOS","deviceOnline":true,"createdAt":1.0,"lastActivityAt":2.0,"plan":[],"usage":null,
             "pinned":false,"archived":false,"unread":0.0,"eventSeq":0.0,"starting":true,"pending":null,
             "models":[{"id":"m1","name":"Model One","efforts":[{"id":"e-hi","name":"High","value":"high"},{"name":"broken"}],
                        "defaultEffort":"e-hi"},
                       {"id":"m2","efforts":null,"extra":42}]}
            """#
        let detail = try JSONDecoder().decode(SessionDetail.self, from: Data(json.utf8))
        XCTAssertTrue(detail.isStarting)
        XCTAssertEqual(detail.models?.map(\.id), ["m1", "m2"])
        XCTAssertEqual(detail.models?[0].efforts.map(\.id), ["e-hi"], "an effort without an id is dropped")
        XCTAssertEqual(detail.models?[0].effort(matching: "high")?.name, "High")
        XCTAssertEqual(detail.models?[1].name, "m2", "the id stands in for a missing name")
        XCTAssertEqual(detail.models?[1].efforts, [])
    }

    func testAnOlderRelayWithoutTheNewFields() throws {
        let row = #"""
            {"_id":"s1","sessionId":"x","title":"T","cwd":"/a","model":"m","status":"running","online":true,"app":"tui",
             "deviceId":"d","deviceName":"Mac","deviceOnline":true,"preview":null,"previewKind":null,"lastActivityAt":1.0,
             "pinned":false,"archived":false,"unread":0.0,"plan":null}
            """#
        let decoded = try JSONDecoder().decode(SessionRow.self, from: Data(row.utf8))
        XCTAssertFalse(decoded.isStarting)
        let command = #"{"_id":"c","clientId":null,"text":"hi","status":"done","error":null,"fromLabel":"Web","createdAt":1.0,"updatedAt":2.0}"#
        XCTAssertNil(try JSONDecoder().decode(PromptCommand.self, from: Data(command.utf8)).type)
        let created = #"{"_id":"c","type":"create","clientId":"u","text":"go","status":"pending","error":null,"fromLabel":"iPhone","fromDeviceId":"p","mine":true,"createdAt":1.0,"updatedAt":2.0}"#
        XCTAssertEqual(try JSONDecoder().decode(PromptCommand.self, from: Data(created.utf8)).type, "create")
    }

    func testSlashCommandLists() throws {
        let json = #"{"commands":[{"name":"compact","description":"Summarize"},{"name":"review-pr","description":"Review","hint":"<n>"},{"description":"no name"}],"source":"computer"}"#
        let list = try JSONDecoder().decode(SlashCommandList.self, from: Data(json.utf8))
        XCTAssertEqual(list.commands.map(\.name), ["compact", "review-pr"])
        XCTAssertEqual(list.commands[1].hint, "<n>")
        XCTAssertEqual(list.source, "computer")
        XCTAssertEqual(try JSONDecoder().decode(SlashCommandList.self, from: Data("{}".utf8)).source, "none")
    }

    func testAConfigCommandsResult() throws {
        let json = #"{"_id":"c","type":"config","status":"done","result":{"model":"grok-4","effort":"high"}}"#
        let record = try JSONDecoder().decode(CommandRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.result?.model, "grok-4")
        XCTAssertEqual(record.result?.effort, "high")
    }
}

/// New sessions, `/model`, `/think` and `/new` against the demo relay.
@MainActor
final class SessionCommandsFlowTests: XCTestCase {
    private func makeEngine() -> (CrokEngine, DemoWorld) {
        let world = DemoWorld()
        let credentials = StoredCredentials(
            serverURL: "https://demo", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.flows.\(UUID().uuidString)")!)
        let engine = CrokEngine(backend: DemoRelay(world: world), credentials: credentials, isDemo: true, drafts: drafts, cache: nil)
        engine.start()
        return (engine, world)
    }

    private func until(_ what: String, timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testStartingASessionShowsThePromptAndAStartingRowThenRunsIt() async {
        let (engine, world) = makeEngine()
        let target = NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/crok-build")
        let result = await engine.startSession(in: target, text: "Add a health check\nwith tests", clientId: "client-1")
        guard case .success(let id) = result else { return XCTFail("\(result)") }
        let again = await engine.startSession(in: target, text: "Add a health check", clientId: "client-1")
        XCTAssertEqual(try? again.get(), id, "the same client id is the same session")
        XCTAssertEqual(engine.localPrompts[id]?.first?.clientId, "client-1", "shown optimistically under the create's client id")
        let row = world.rows(archived: false).first(where: { $0.id == id })
        XCTAssertEqual(row?.title, "Add a health check")
        XCTAssertEqual(row?.isStarting, true)
        XCTAssertEqual(world.sessions.first(where: { $0.detail.id == id })?.commands.first?.type, "create")
        await until("a crok there opened it", timeout: 4) {
            world.rows(archived: false).first(where: { $0.id == id })?.isStarting == false
        }
        XCTAssertTrue(world.sessions.first(where: { $0.detail.id == id })?.events.contains(where: { $0.kind == .user }) ?? false)

        let offline = await engine.startSession(
            in: NewSessionTarget(deviceId: "studio", deviceName: "Studio", path: "/x"), text: "hi", clientId: "client-2")
        XCTAssertEqual(offline.failureCode, .offline)
        let relative = await engine.startSession(
            in: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "src"), text: "hi", clientId: "client-3")
        XCTAssertEqual(relative.failureCode, .invalid)
        await engine.shutdown()
    }

    func testTheNewSessionScreenKeepsTheTextWhenRefusedAndHandsOverTheSession() async {
        let (engine, _) = makeEngine()
        await until("the list") { !engine.groups.isEmpty }
        let offline = NewSessionModel(
            target: NewSessionTarget(deviceId: "studio", deviceName: "Studio", path: "/Users/charlie/src/tokenizer"),
            engine: engine, draft: "Profile the tokenizer")
        XCTAssertFalse(offline.computerOnline)
        XCTAssertFalse(offline.canSend, "a new session needs its computer online")
        await offline.send()
        XCTAssertEqual(offline.actionError?.code, .offline, "the relay's refusal is shown")
        XCTAssertEqual(offline.draft, "Profile the tokenizer", "the text goes back to the field")
        XCTAssertNil(offline.pendingPrompt)

        let online = NewSessionModel(
            target: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/website"),
            engine: engine, draft: "Add a sitemap")
        var created: DocID?
        online.onCreated = { created = $0 }
        XCTAssertTrue(online.canSend)
        await online.send()
        XCTAssertNotNil(created)
        XCTAssertEqual(online.draft, "")
        XCTAssertEqual(engine.startedSessions[online.clientId], created)
        await engine.shutdown()
    }

    func testModelAndThinkingCardsApplyOnTheComputer() async {
        let (engine, world) = makeEngine()
        let model = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        model.appear()
        await until("the session and its computer's models") { model.detail.value != nil && model.models != nil }

        model.draft = "/model"
        model.send()
        XCTAssertEqual(model.botCards.count, 1)
        XCTAssertEqual(model.draft, "")
        guard case .choices(let choices) = model.choices(for: model.botCards[0]) else { return XCTFail("models") }
        XCTAssertEqual(choices.first(where: \.isCurrent)?.id, "grok-code-fast-1")
        model.choose(choices.first(where: { $0.id == "grok-4" })!, on: model.botCards[0])
        XCTAssertEqual(model.botCards[0].state, .applying(choiceId: "grok-4"))
        await until("applied") { model.botCards[0].isDone }
        XCTAssertEqual(model.botCards[0].state, .done(label: "Grok 4"))
        XCTAssertEqual(world.sessions.first(where: { $0.detail.id == "s-relay" })?.detail.model, "grok-4")

        model.draft = "/think LOW"
        model.send()
        await until("the level") { model.botCards.count == 2 && model.botCards[1].isDone }
        XCTAssertEqual(model.botCards[1].state, .done(label: "Low"))
        XCTAssertEqual(world.sessions.first(where: { $0.detail.id == "s-relay" })?.detail.effort, "low")

        model.draft = "/model nothing-like-it"
        model.send()
        XCTAssertEqual(model.botCards[2].state, .choosing(note: "No model matches “nothing-like-it”."))

        // A model without thinking levels: /think leaves the menu.
        model.draft = "/model grok 4 fast"
        model.send()
        await until("Grok 4 Fast") { model.detail.value?.model == "grok-4-fast" }
        XCTAssertFalse(model.availableCommands.contains(where: { $0.name == "think" }))
        XCTAssertTrue(model.availableCommands.contains(where: { $0.name == "compact" }), "the session's commands")
        model.tearDown()
        await engine.shutdown()
    }

    func testNewAndInfoAndSessionCommands() async {
        let (engine, world) = makeEngine()
        let model = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        var opened: [(NewSessionTarget, String?)] = []
        model.onNewSession = { opened.append(($0, $1)) }
        model.appear()
        await until("the session") { model.detail.value != nil }
        model.draft = "/new Write the README"
        model.send()
        XCTAssertEqual(opened.first?.0, NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/crok-build"))
        XCTAssertEqual(opened.first?.1, "Write the README")
        model.draft = "/info"
        model.send()
        XCTAssertTrue(model.showsInfo)
        model.toggleMenu()
        await until("the session's commands") { model.commandMenuItems.contains(where: { $0.name == "compact" }) }
        model.pick(model.commandMenuItems.first(where: { $0.name == "compact" })!)
        XCTAssertFalse(model.menuOpen)
        await until("sent as a prompt") {
            world.sessions.first(where: { $0.detail.id == "s-relay" })?.commands.contains(where: { $0.text == "/compact" }) ?? false
        }
        model.pick(model.availableCommands.first(where: { $0.name == "model" })!)
        XCTAssertEqual(model.draft, "/model ", "a command that takes an argument fills the field")
        model.tearDown()
        await engine.shutdown()
    }
}

private extension Result where Failure == RelayError {
    var failureCode: RelayError.Code? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}

extension DemoWorld {
    /// `sessions:get` for a demo session, as the relay would send it.
    func detailForTests(_ id: DocID) -> SessionDetail? {
        sessions.first(where: { $0.detail.id == id }).map(detail)
    }
}
