import XCTest

@testable import Crok

/// The model and thinking-level pickers (mobile/DESIGN.md "Model and thinking level"): the list, its provider sections
/// and search, and what the pills say.
@MainActor
final class ModelSetupTests: XCTestCase {
    private let models: [ModelChoice] = [
        ModelChoice(
            id: "deepseek/deepseek-flash", name: "DeepSeek Flash", description: "The computer's default",
            efforts: [EffortChoice(id: "think", name: "Thinking", value: "high")], defaultEffort: "think"),
        ModelChoice(id: "grok-4", name: "Grok 4", description: "xAI's most capable model"),
        ModelChoice(id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", description: "Anthropic, with your key"),
        ModelChoice(id: "openrouter/openai/gpt-5", name: "OpenAI: GPT-5", description: "Through OpenRouter"),
        ModelChoice(id: "deepseek/deepseek-chat", name: "DeepSeek V3.2"),
        ModelChoice(id: "openrouter/qwen/qwen3-coder", name: "Qwen: Qwen3 Coder", description: "Open coding model"),
        ModelChoice(id: "grok-4", name: "Grok 4 (again)"),
    ]

    func testSectionsByProviderInTheOrderTheyFirstAppear() {
        let sections = ModelCatalog.sections(models, computerName: "MacBook Pro")
        XCTAssertEqual(sections.map(\.id), ["deepseek", "", "anthropic", "openrouter"])
        XCTAssertEqual(sections.map(\.title), ["deepseek", "MacBook Pro", "anthropic", "openrouter"], "ids without a provider: the computer")
        XCTAssertEqual(sections[0].models.map(\.id), ["deepseek/deepseek-flash", "deepseek/deepseek-chat"], "the list's order within one")
        XCTAssertEqual(sections[1].models.map(\.name), ["Grok 4"], "a repeated id shows once")
        XCTAssertEqual(ModelCatalog.provider(of: "openrouter/openai/gpt-5"), "openrouter", "up to the first slash")
        XCTAssertNil(ModelCatalog.provider(of: "grok-4"))
        XCTAssertNil(ModelCatalog.provider(of: "/odd"))
    }

    func testSearchMatchesNameIdOrDescriptionAndHidesEmptySections() {
        func search(_ query: String) -> [String: [String]] {
            Dictionary(
                uniqueKeysWithValues: ModelCatalog.sections(models, computerName: "Mac", query: query).map { ($0.id, $0.models.map(\.id)) })
        }
        XCTAssertEqual(search("QWEN"), ["openrouter": ["openrouter/qwen/qwen3-coder"]], "case-insensitive, by name")
        XCTAssertEqual(search("openrouter").keys.sorted(), ["openrouter"], "a provider, through the id")
        XCTAssertEqual(search("openrouter")["openrouter"]?.count, 2)
        XCTAssertEqual(search("your key"), ["anthropic": ["anthropic/claude-sonnet-5-5"]], "by description")
        XCTAssertEqual(search("flash"), ["deepseek": ["deepseek/deepseek-flash"]], "by id or name")
        XCTAssertEqual(search("  "), search(""), "blank: everything")
        XCTAssertEqual(search(""), ["deepseek": ["deepseek/deepseek-flash", "deepseek/deepseek-chat"], "": ["grok-4"],
                                    "anthropic": ["anthropic/claude-sonnet-5-5"],
                                    "openrouter": ["openrouter/openai/gpt-5", "openrouter/qwen/qwen3-coder"]])
        XCTAssertTrue(search("nothing like it").isEmpty, "No Results")
        // Sections keep the list's provider order even when the first model of a provider does not match.
        let ids = ModelCatalog.sections(models, computerName: "Mac", query: "deepseek v3").map(\.id)
        XCTAssertEqual(ids, ["deepseek"])
        let order = ModelCatalog.sections(models, computerName: "Mac", query: "o").map(\.id)
        XCTAssertEqual(order, ["deepseek", "", "anthropic", "openrouter"].filter(order.contains))
    }

    func testTheListComesFromDevicesModelsWithTheSessionsCopyOnlyWhenThatFails() {
        let short = Array(models.prefix(2))
        XCTAssertEqual(ModelList.resolve(listed: .some(models), listFailed: false, fallback: short, fallbackLoaded: true), .models(models))
        XCTAssertEqual(
            ModelList.resolve(listed: .some(nil), listFailed: false, fallback: short, fallbackLoaded: true), .unavailable,
            "null: offline or an older crok there, whatever the session's copy says")
        XCTAssertEqual(ModelList.resolve(listed: .some([]), listFailed: false, fallback: nil, fallbackLoaded: true), .unavailable)
        XCTAssertEqual(ModelList.resolve(listed: nil, listFailed: false, fallback: short, fallbackLoaded: true), .loading)
        XCTAssertEqual(
            ModelList.resolve(listed: nil, listFailed: true, fallback: short, fallbackLoaded: true), .models(short),
            "an older relay without devices:models")
        XCTAssertEqual(ModelList.resolve(listed: nil, listFailed: true, fallback: nil, fallbackLoaded: true), .unavailable)
        XCTAssertEqual(ModelList.resolve(listed: nil, listFailed: true, fallback: nil, fallbackLoaded: false), .loading)
    }

    func testAnOpenSessionsPills() throws {
        let list = ModelList.models(DemoWorld.macModels)
        let row = try XCTUnwrap(
            ModelSetup.session(list: list, model: "claude-sonnet-4-5", effort: "xhigh", computerOnline: true, starting: false))
        XCTAssertEqual(row.model.label, "Claude Sonnet 4.5", "the model's name")
        XCTAssertEqual(row.thinking?.label, "Max", "the level whose value is the session's effort")
        XCTAssertEqual(row.levelId, "thinking-max", "what setConfig takes")
        XCTAssertFalse(row.model.busy || row.model.dimmed || row.model.isDefault)

        let noLevels = try XCTUnwrap(
            ModelSetup.session(list: list, model: "grok-4-fast", effort: nil, computerOnline: true, starting: false))
        XCTAssertNil(noLevels.thinking, "a model without levels has no thinking pill")

        let unknown = try XCTUnwrap(
            ModelSetup.session(list: list, model: "gone-model", effort: "high", computerOnline: true, starting: false))
        XCTAssertEqual(unknown.model.label, "gone-model", "else the id")
        XCTAssertNil(unknown.thinking)

        let unnamedLevel = try XCTUnwrap(
            ModelSetup.session(list: list, model: "grok-4", effort: "medium", computerOnline: true, starting: false))
        XCTAssertEqual(unnamedLevel.thinking?.label, "Medium", "a level the model's list lacks: its canonical name")
        XCTAssertNil(unnamedLevel.levelId)

        let noEffort = try XCTUnwrap(
            ModelSetup.session(list: list, model: "grok-4", effort: nil, computerOnline: true, starting: false))
        XCTAssertEqual(noEffort.thinking?.label, "Default")
        XCTAssertEqual(noEffort.thinking?.isDefault, true)

        XCTAssertNil(ModelSetup.session(list: list, model: "grok-4", effort: nil, computerOnline: false, starting: false), "offline")
        XCTAssertNil(ModelSetup.session(list: list, model: "grok-4", effort: nil, computerOnline: true, starting: true), "starting")
        XCTAssertNil(ModelSetup.session(list: .loading, model: "grok-4", effort: nil, computerOnline: true, starting: false))

        // An older crok there: the session's model, dimmed; no row without a model name either.
        let older = try XCTUnwrap(
            ModelSetup.session(list: .unavailable, model: "grok-4", effort: "high", computerOnline: true, starting: false))
        XCTAssertEqual(older.model.label, "grok-4")
        XCTAssertTrue(older.model.dimmed)
        XCTAssertNil(older.thinking)
        XCTAssertNil(ModelSetup.session(list: .unavailable, model: nil, effort: nil, computerOnline: true, starting: false))
        XCTAssertNil(ModelSetup.session(list: .unavailable, model: "", effort: nil, computerOnline: true, starting: false))
    }

    func testAChangeOnItsWay() throws {
        let list = ModelList.models(DemoWorld.macModels)
        let sending = try XCTUnwrap(
            ModelSetup.session(
                list: list, model: "grok-code-fast-1", effort: "high", modelChange: ConfigChange(value: "claude-sonnet-4-5"),
                computerOnline: true, starting: false))
        XCTAssertEqual(sending.model.label, "Claude Sonnet 4.5", "the new value at once")
        XCTAssertTrue(sending.model.busy, "with a spinner")
        XCTAssertFalse(sending.acceptsModelTaps)
        XCTAssertEqual(sending.thinking?.label, "High", "the session's level, on the new model")
        XCTAssertEqual(sending.thinking?.enabled, false, "levels wait for the model")
        XCTAssertFalse(sending.acceptsLevelTaps)

        let applied = try XCTUnwrap(
            ModelSetup.session(
                list: list, model: "grok-code-fast-1", effort: "high",
                modelChange: ConfigChange(value: "grok-4", done: true), computerOnline: true, starting: false))
        XCTAssertEqual(applied.model.label, "Grok 4")
        XCTAssertFalse(applied.model.busy, "done: no spinner while the session catches up")
        XCTAssertTrue(applied.acceptsLevelTaps)

        let level = try XCTUnwrap(
            ModelSetup.session(
                list: list, model: "claude-sonnet-4-5", effort: "medium", effortChange: ConfigChange(value: "thinking-high"),
                computerOnline: true, starting: false))
        XCTAssertEqual(level.thinking?.label, "High")
        XCTAssertEqual(level.thinking?.busy, true)
        XCTAssertTrue(level.acceptsModelTaps, "the model pill stays usable")

        // A model whose levels do not include the session's: the computer takes the model's default.
        let defaulted = try XCTUnwrap(
            ModelSetup.session(
                list: list, model: "grok-4", effort: "low", modelChange: ConfigChange(value: "claude-sonnet-4-5"),
                computerOnline: true, starting: false))
        XCTAssertEqual(defaulted.thinking?.label, "Low", "Low exists there by value")
        let defaultedHigh = try XCTUnwrap(
            ModelSetup.session(
                list: list, model: "grok-code-fast-1", effort: "medium", modelChange: ConfigChange(value: "grok-4"),
                computerOnline: true, starting: false))
        XCTAssertEqual(defaultedHigh.thinking?.label, "High", "Grok 4 has no Medium: its default")
    }

    func testANewSessionsPills() throws {
        let list = ModelList.models(DemoWorld.macModels)
        let fresh = try XCTUnwrap(ModelSetup.newSession(list: list, model: nil, effort: nil, computerOnline: true))
        XCTAssertEqual(fresh.model.label, "Default")
        XCTAssertTrue(fresh.model.isDefault)
        XCTAssertNil(fresh.thinking, "Default hides the thinking pill")

        let picked = try XCTUnwrap(ModelSetup.newSession(list: list, model: "claude-sonnet-4-5", effort: nil, computerOnline: true))
        XCTAssertEqual(picked.model.label, "Claude Sonnet 4.5")
        XCTAssertEqual(picked.thinking?.label, "Default", "until a level is picked")
        XCTAssertEqual(picked.levelModel?.id, "claude-sonnet-4-5")

        let level = try XCTUnwrap(
            ModelSetup.newSession(list: list, model: "claude-sonnet-4-5", effort: "thinking-max", computerOnline: true))
        XCTAssertEqual(level.thinking?.label, "Max")
        XCTAssertEqual(level.levelId, "thinking-max")

        XCTAssertNil(try XCTUnwrap(ModelSetup.newSession(list: list, model: "grok-4-fast", effort: nil, computerOnline: true)).thinking)
        XCTAssertNil(ModelSetup.newSession(list: list, model: nil, effort: nil, computerOnline: false), "offline")
        XCTAssertNil(ModelSetup.newSession(list: .unavailable, model: nil, effort: nil, computerOnline: true), "no list, no row")
        XCTAssertNil(ModelSetup.newSession(list: .loading, model: nil, effort: nil, computerOnline: true))

        let args = ModelSetup.createArguments(list: list, model: "claude-sonnet-4-5", effort: "thinking-max")
        XCTAssertEqual(args.model, "claude-sonnet-4-5")
        XCTAssertEqual(args.effort, "thinking-max")
        let defaults = ModelSetup.createArguments(list: list, model: nil, effort: nil)
        XCTAssertNil(defaults.model)
        XCTAssertNil(defaults.effort)
        let gone = ModelSetup.createArguments(list: list, model: "no-longer-offered", effort: "high")
        XCTAssertNil(gone.model, "a pick the computer no longer offers is left out")
        XCTAssertNil(ModelSetup.createArguments(list: list, model: "grok-4", effort: "thinking-max").effort, "not one of its levels")
    }

    func testLevelNames() {
        XCTAssertEqual(ModelLabels.levelName("xhigh"), "Extra high")
        XCTAssertEqual(ModelLabels.levelName("turbo"), "turbo")
        XCTAssertEqual(ModelLabels.levelName("xhigh", model: DemoWorld.macModels[3]), "Max", "the model's own name for it")
        XCTAssertNil(ModelLabels.levelName(nil, model: nil))
        XCTAssertEqual(ModelLabels.modelName("grok-4", in: DemoWorld.macModels), "Grok 4")
        XCTAssertEqual(ModelLabels.modelName("other", in: nil), "other")
        XCTAssertEqual(ConfigFailure(option: .model, message: "x").title, "Couldn't change the model")
        XCTAssertEqual(ConfigFailure(option: .reasoningEffort, message: "x").title, "Couldn't change the thinking level")
    }
}

/// The pills and Choose a Model against the demo relay: the list from `devices:models`, `commands:setConfig` until done
/// or failed, new sessions started on a model and level, and an older relay without `devices:models`.
@MainActor
final class ModelPickerFlowTests: XCTestCase {
    private func makeEngine(backend: (DemoWorld) -> any RelayBackend = { DemoRelay(world: $0) }) -> (CrokEngine, DemoWorld) {
        let world = DemoWorld()
        let credentials = StoredCredentials(
            serverURL: "https://demo", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.models.\(UUID().uuidString)")!)
        let engine = CrokEngine(backend: backend(world), credentials: credentials, isDemo: true, drafts: drafts, cache: nil)
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

    func testThePillsChangeTheModelAndLevelOnTheComputer() async throws {
        let (engine, world) = makeEngine()
        let session = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        session.appear()
        await until("the pills") { session.setupRow != nil }
        XCTAssertEqual(session.models?.count, DemoWorld.macModels.count + DemoWorld.providerModels.count, "devices:models")
        XCTAssertEqual(session.setupRow?.model.label, "Grok Code Fast 1")
        XCTAssertEqual(session.setupRow?.thinking?.label, "High")

        session.tapModelPill()
        XCTAssertTrue(session.showsModelPicker)
        session.showsModelPicker = false

        session.chooseModel("claude-sonnet-4-5")
        XCTAssertEqual(session.setupRow?.model.label, "Claude Sonnet 4.5", "shown at once")
        XCTAssertEqual(session.setupRow?.model.busy, true, "spinning")
        session.chooseModel("grok-4")
        XCTAssertEqual(session.modelChange?.value, "claude-sonnet-4-5", "taps wait for the change on its way")
        await until("applied") { session.setupRow?.model.busy == false }
        XCTAssertEqual(world.sessions.first(where: { $0.detail.id == "s-relay" })?.detail.model, "claude-sonnet-4-5")
        await until("the session shows it") { session.detail.value?.model == "claude-sonnet-4-5" && session.modelChange == nil }
        XCTAssertEqual(session.setupRow?.model.label, "Claude Sonnet 4.5")
        XCTAssertEqual(session.setupRow?.thinking?.label, "High", "high exists on Claude by value")
        XCTAssertEqual(session.setupRow?.levelId, "thinking-high")

        session.chooseLevel("thinking-max")
        XCTAssertEqual(session.setupRow?.thinking?.label, "Max")
        XCTAssertEqual(session.setupRow?.thinking?.busy, true)
        await until("the level") { session.detail.value?.effort == "xhigh" && session.effortChange == nil }
        XCTAssertEqual(session.setupRow?.thinking?.label, "Max")
        XCTAssertNil(session.configFailure)

        // A model without levels: the thinking pill leaves.
        session.chooseModel("grok-4-fast")
        await until("Grok 4 Fast") { session.detail.value?.model == "grok-4-fast" && session.modelChange == nil }
        XCTAssertNil(session.setupRow?.thinking)
        session.tearDown()
        await engine.shutdown()
    }

    func testAFailedChangeGoesBackAndSaysWhy() async throws {
        let (engine, world) = makeEngine()
        let session = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        session.appear()
        await until("the pills") { session.setupRow != nil }

        // The computer refuses (the command fails).
        world.configFailure = "The model is not available with your plan."
        session.chooseModel("grok-4")
        XCTAssertEqual(session.setupRow?.model.label, "Grok 4")
        await until("the failure") { session.configFailure != nil }
        XCTAssertEqual(session.configFailure?.title, "Couldn't change the model")
        XCTAssertEqual(session.configFailure?.message, "The model is not available with your plan.")
        XCTAssertNil(session.modelChange)
        XCTAssertEqual(session.setupRow?.model.label, "Grok Code Fast 1", "back to the old value")

        session.configFailure = nil
        session.chooseLevel("low")
        await until("the level's failure") { session.configFailure != nil }
        XCTAssertEqual(session.configFailure?.title, "Couldn't change the thinking level")
        XCTAssertEqual(session.setupRow?.thinking?.label, "High")

        // The relay refuses (INVALID): the same alert, with its message.
        world.configFailure = nil
        session.configFailure = nil
        world.modelsByDevice["mbp"] = DemoWorld.macModels.filter { $0.id != "grok-4" }
        session.chooseModel("grok-4")
        await until("the refusal") { session.configFailure != nil }
        XCTAssertEqual(session.configFailure?.message, "That model is not available on this computer.")
        XCTAssertEqual(session.setupRow?.model.label, "Grok Code Fast 1")
        session.tearDown()
        await engine.shutdown()
    }

    func testAComputerWithAnOlderCrokShowsTheModelDimmed() async throws {
        let (engine, world) = makeEngine()
        world.modelsByDevice["mbp"] = nil
        let session = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        session.appear()
        await until("the dimmed pill") { session.setupRow?.model.dimmed == true }
        XCTAssertEqual(session.setupRow?.model.label, "grok-code-fast-1")
        XCTAssertNil(session.setupRow?.thinking)
        session.tapModelPill()
        XCTAssertTrue(session.showsNotOffered, "a tap says why")
        XCTAssertFalse(session.showsModelPicker)
        session.tearDown()
        await engine.shutdown()
    }

    func testANewSessionStartsOnThePickedModelAndLevel() async throws {
        let (engine, world) = makeEngine()
        await until("the list") { !engine.groups.isEmpty }
        let screen = NewSessionModel(
            target: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/website"),
            engine: engine, draft: "Add a sitemap")
        screen.start()
        await until("the pills") { screen.setupRow != nil }
        XCTAssertEqual(screen.setupRow?.model.label, "Default")
        XCTAssertNil(screen.setupRow?.thinking)

        screen.chooseModel("claude-sonnet-4-5")
        XCTAssertEqual(screen.setupRow?.thinking?.label, "Default")
        screen.chooseLevel("thinking-max")
        XCTAssertEqual(screen.setupRow?.thinking?.label, "Max")
        screen.chooseModel("grok-4")
        XCTAssertEqual(screen.setupRow?.thinking?.label, "Default", "another model: the level goes back to Default")
        screen.chooseLevel("low")

        var created: DocID?
        screen.onCreated = { created = $0 }
        await screen.send()
        let id = try XCTUnwrap(created)
        let detail = try XCTUnwrap(world.sessions.first(where: { $0.detail.id == id })?.detail)
        XCTAssertEqual(detail.model, "grok-4", "sessions:create got the model")
        XCTAssertEqual(detail.effort, "low", "and the level (the row holds the level)")
        await until("a crok there opened it") { world.rows(archived: false).first(where: { $0.id == id })?.isStarting == false }
        XCTAssertEqual(world.sessions.first(where: { $0.detail.id == id })?.detail.model, "grok-4", "kept when opened")
        screen.stop()

        // Default leaves both out: the computer's own choice.
        let plain = NewSessionModel(
            target: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/website"),
            engine: engine, draft: "Add a robots.txt")
        plain.start()
        await until("the pills") { plain.setupRow != nil }
        var plainId: DocID?
        plain.onCreated = { plainId = $0 }
        await plain.send()
        let plainDetail = try XCTUnwrap(world.sessions.first(where: { $0.detail.id == plainId })?.detail)
        XCTAssertNil(plainDetail.model, "nothing until a crok there opens it with its default")
        plain.stop()
        await engine.shutdown()
    }

    func testTheDemoRelayChecksANewSessionsChoice() throws {
        let world = DemoWorld()
        let target = (deviceId: "mbp", path: "/Users/charlie/src/website")
        XCTAssertThrowsError(
            try world.createSession(deviceId: target.deviceId, path: target.path, text: "x", model: "nope", clientId: "a")
        ) { XCTAssertEqual(($0 as? RelayError)?.code, .invalid) }
        XCTAssertThrowsError(
            try world.createSession(
                deviceId: target.deviceId, path: target.path, text: "x", model: "grok-4-fast", effort: "high", clientId: "b")
        ) { XCTAssertEqual(($0 as? RelayError)?.code, .invalid, "Grok 4 Fast has no levels") }
        let made = try world.createSession(
            deviceId: target.deviceId, path: target.path, text: "x", model: "claude-sonnet-4-5", effort: "medium", clientId: "c")
        XCTAssertEqual(world.detailForTests(made.sessionDocId)?.effort, "medium", "a level by its value works too")
        XCTAssertEqual(world.deviceModels("mbp")?.first?.id, "grok-code-fast-1")
        XCTAssertNil(world.deviceModels("studio"), "offline")
    }

    func testAnOlderRelayWithoutDevicesModelsFallsBackToTheSessionsCopy() async throws {
        let (engine, world) = makeEngine { OlderRelay(world: $0) }
        let session = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        session.appear()
        await until("the session's copy") { session.models != nil }
        XCTAssertNotNil(session.modelQuery?.error, "devices:models failed")
        XCTAssertEqual(session.models?.map(\.id), world.detailForTests("s-relay")?.models?.map(\.id))
        XCTAssertEqual(session.setupRow?.model.label, "Grok Code Fast 1")
        session.draft = "/model"
        session.send()
        guard case .choices(let choices) = session.choices(for: session.botCards[0]) else { return XCTFail("the bot card's list") }
        XCTAssertEqual(choices.first(where: \.isCurrent)?.id, "grok-code-fast-1")
        session.tearDown()

        // A new session has no copy to fall back to: no pills, and it starts on the computer's default.
        let screen = NewSessionModel(
            target: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/website"),
            engine: engine)
        screen.start()
        await until("the failure") { screen.modelQuery.error != nil }
        XCTAssertEqual(screen.modelList, .unavailable)
        XCTAssertNil(screen.setupRow)
        screen.stop()
        await engine.shutdown()
    }
}

/// A relay from before `devices:models`: that query fails, everything else is the demo's.
private final class OlderRelay: RelayBackend, DevicesAPI, @unchecked Sendable {
    let demo: DemoRelay

    @MainActor
    init(world: DemoWorld) {
        demo = DemoRelay(world: world)
    }

    var sessions: any SessionsAPI { demo }
    var commands: any CommandsAPI { demo }
    var devices: any DevicesAPI { self }
    var account: any AccountAPI { demo }
    func connectionSignals() -> AsyncStream<ConnectionSignal> { demo.connectionSignals() }
    func start() async {}
    func shutdown() async {}

    func list() -> RelayStream<[DeviceRow]> { demo.list() }
    func models(_ deviceId: DocID) -> RelayStream<[ModelChoice]?> {
        AsyncThrowingStream { $0.finish(throwing: RelayError(.server, "Could not find public function for 'devices:models'")) }
    }
    func rename(_ deviceId: DocID, name: String) async throws { try await demo.rename(deviceId, name: name) }
    func revoke(_ deviceId: DocID) async throws { try await demo.revoke(deviceId) }
    func revokeOthers() async throws -> Int { try await demo.revokeOthers() }
}
