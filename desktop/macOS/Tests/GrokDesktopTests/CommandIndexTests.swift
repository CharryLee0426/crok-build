import XCTest
@testable import GrokDesktop

/// The command index ranks the composer menu and the palette without lowercasing the catalog
/// on every keystroke, and the store keeps it until the catalog changes.
@MainActor
final class CommandIndexTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("crok-command-index-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func skills(_ count: Int) -> [SlashCommand] {
        (0..<count).map { i in
            SlashCommand(name: "plugin\(i % 40):skill-\(String(format: "%04d", i))", description: "Skill number \(i) does a thing",
                         source: "plugin\(i % 40)", skillPath: "/plugins/\(i % 40)/skill-\(i)/SKILL.md")
        }
    }

    func testTiersOrderExactPrefixSubstringDescriptionThenSubsequence() {
        let commands = [
            SlashCommand(name: "subsequence", description: "s then k then i", aliases: ["z-s-k-i"]),
            SlashCommand(name: "described", description: "about skills"),
            SlashCommand(name: "my-ski-tool", description: "substring"),
            SlashCommand(name: "skills", description: "prefix, listed after the alias hit"),
            SlashCommand(name: "exact", description: "alias is the query", aliases: ["ski"]),
            SlashCommand(name: "skip", description: "prefix"),
            SlashCommand(name: "unrelated", description: "nothing"),
        ]
        let index = CommandIndex(commands)
        XCTAssertEqual(index.matches(query: " /SKI ").map(\.name), ["exact", "skills", "skip", "my-ski-tool", "described", "subsequence"])
        XCTAssertEqual(index.matches(query: "").map(\.name), commands.map(\.name), "an empty query lists the catalog in order")
        XCTAssertEqual(index.matches(query: "/").map(\.name), commands.map(\.name))
        XCTAssertEqual(DesktopCommands.matches(commands, query: "ski").map(\.name), index.matches(query: "ski").map(\.name))
    }

    func testTheStoreReusesTheIndexUntilTheCatalogChanges() async throws {
        let store = AppStore(stateFile: home.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: home.path)
        store.state.projects = [project]
        store.state.selectedProjectID = project.id
        store.commandCatalogProjectID = project.id
        store.catalogRun.commands = skills(500)
        store.catalogRun.commandsLoaded = true

        let first = store.commandIndex
        XCTAssertEqual(first.commands.filter(\.isSkill).count, 500)
        XCTAssertTrue(first.commands.contains { $0.name == "help" }, "desktop commands come first")
        XCTAssertEqual(store.commandIndex.commands.map(\.id), first.commands.map(\.id))
        XCTAssertNotNil(store.commandIndexCache)

        store.catalogRun.commands = skills(501)
        XCTAssertEqual(store.commandIndex.commands.filter(\.isSkill).count, 501, "a changed catalog rebuilds the index")

        // A harness command sharing a desktop name only lends its argument hint, and only when the
        // desktop command has none.
        store.catalogRun.commands = [SlashCommand(name: "usage", description: "harness", argumentHint: "<period>"),
                                     SlashCommand(name: "model", description: "harness", argumentHint: "<id>"),
                                     SlashCommand(name: "fresh", description: "new")]
        let merged = store.commandIndex.commands
        XCTAssertEqual(merged.filter { $0.name == "usage" }.count, 1)
        XCTAssertEqual(merged.first { $0.name == "usage" }?.argumentHint, "<period>")
        XCTAssertEqual(merged.first { $0.name == "usage" }?.source, "Desktop")
        XCTAssertEqual(merged.first { $0.name == "model" }?.argumentHint, DesktopCommands.catalog.first { $0.name == "model" }?.argumentHint)
        XCTAssertEqual(merged.last?.name, "fresh")
    }

    func testTypingInTheComposerDoesNotPublishTheStore() {
        let store = AppStore(stateFile: home.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        var storePublishes = 0, draftPublishes = 0
        let storeSink = store.objectWillChange.sink { storePublishes += 1 }
        let draftSink = store.composerDraft.objectWillChange.sink { draftPublishes += 1 }
        defer { storeSink.cancel(); draftSink.cancel() }
        store.draft = "/sk"
        store.draft = "/ski"
        store.draft = "/ski"
        store.search = "bug"
        XCTAssertEqual(store.draft, "/ski")
        XCTAssertEqual(store.search, "bug")
        XCTAssertEqual(draftPublishes, 2, "each change publishes the draft once; a repeat is skipped")
        XCTAssertEqual(storePublishes, 0, "the sidebar and transcript do not redraw per keystroke")
    }

    func testRankingThousandsOfCommandsStaysQuick() {
        let index = CommandIndex(DesktopCommands.catalog + skills(3000))
        measure {
            for query in ["s", "sk", "skill-1", "plugin7:skill-07", "thing"] {
                XCTAssertFalse(index.matches(query: query).isEmpty)
            }
        }
    }
}
