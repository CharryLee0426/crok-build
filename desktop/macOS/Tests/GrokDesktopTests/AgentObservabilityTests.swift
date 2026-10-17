import XCTest
@testable import GrokDesktop

/// Settings › Agent Observability: the switch in config.toml (shared with the terminal) and the
/// destination read from agento11y.env.
@MainActor
final class AgentObservabilityTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("crok-observability-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        L10n.setLanguage(.en)
    }

    override func tearDownWithError() throws {
        L10n.setLanguage(.auto)
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testTheSwitchIsSavedWhereTheTerminalReadsIt() throws {
        try write("config.toml", "[ui]\nui_language = \"en\"\n")
        let model = AgentObservabilitySettings(home: home)
        XCTAssertFalse(model.isOn, "off until turned on")
        XCTAssertEqual(model.destination, .notSetUp)

        let banner = model.set(true)
        XCTAssertTrue(model.isOn)
        XCTAssertEqual(GrokConfig(url: model.configURL).bool("agent_observability", in: "features"), true)
        XCTAssertEqual(GrokConfig(url: model.configURL).string("ui_language", in: "ui"), "en", "other settings stay")
        XCTAssertTrue(banner.hasPrefix("✓ Agent Observability: on · nothing is sent until "), banner)

        try write("agento11y.env", "AGENTO11Y_ENDPOINT=https://agento11y-prod-us-west-0.grafana.net\nAGENTO11Y_AUTH_TOKEN=glc_secret\n")
        model.refresh()
        XCTAssertEqual(model.destination, .host("agento11y-prod-us-west-0.grafana.net"))
        let reporting = model.set(true)
        XCTAssertEqual(reporting, "✓ Agent Observability: on · reporting to agento11y-prod-us-west-0.grafana.net")
        XCTAssertFalse(reporting.contains("glc_"))

        XCTAssertEqual(model.set(false), "✓ Agent Observability: off")
        XCTAssertEqual(GrokConfig(url: model.configURL).bool("agent_observability", in: "features"), false)

        L10n.setLanguage(.zhHans)
        XCTAssertEqual(model.set(true), "✓ Agent Observability：开启 · 上报到 agento11y-prod-us-west-0.grafana.net")
    }

    /// The terminal's `/settings` writes the key; the watcher hands the new file to the model.
    func testTheSwitchFollowsTheTerminal() throws {
        let model = AgentObservabilitySettings(home: home)
        try write("config.toml", "[features]\nagent_observability = true\n")
        model.apply(GrokConfig(url: model.configURL))
        XCTAssertTrue(model.isOn)
        try write("config.toml", "[features]\nphone_use = false\n")
        model.apply(GrokConfig(url: model.configURL))
        XCTAssertFalse(model.isOn, "no key is off")
    }

    func testTheDestinationIsReadAsCrokReadsTheFile() {
        let read = { AgentObservabilitySettings.destination(settingsFile: $0, environment: [:]) }
        XCTAssertEqual(read(nil), .notSetUp)
        XCTAssertEqual(read("# nothing yet\n"), .notSetUp)
        XCTAssertEqual(read("export AGENTO11Y_ENDPOINT=\"https://a.example/api\"\n"), .host("a.example"))
        XCTAssertEqual(read("AGENTO11Y_ENDPOINT='http://user:glc_x@localhost:8080'\n"), .host("localhost:8080"))
        XCTAssertEqual(read("AGENTO11Y_ENDPOINT=https://a.example # the stack\nAGENTO11Y_ENABLED=False\n"), .disabledInFile(host: "a.example"))
        XCTAssertEqual(read("AGENTO11Y_ENDPOINT=\n"), .notSetUp)

        // Without a file the inherited environment counts; with one, the file is the whole configuration.
        let environment = ["AGENTO11Y_ENDPOINT": "https://from-env.example"]
        XCTAssertEqual(AgentObservabilitySettings.destination(settingsFile: nil, environment: environment), .host("from-env.example"))
        XCTAssertEqual(AgentObservabilitySettings.destination(settingsFile: "", environment: environment), .notSetUp)
    }
}
