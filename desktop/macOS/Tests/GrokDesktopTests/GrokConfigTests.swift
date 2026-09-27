import XCTest
@testable import GrokDesktop

final class GrokConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func edited(_ text: String, _ change: (inout GrokConfig) throws -> Void) throws -> String {
        var config = GrokConfig(text: text)
        try change(&config)
        return config.text
    }

    func testReplacesOnlyTheValueAndKeepsCommentsAndOtherTables() throws {
        let original = "# Crok settings\n[ui]\ntheme = \"groknight\" # mine\nvim_mode = true\n\n[models]\ndefault = \"grok-4\"\n"
        let result = try edited(original) { try $0.set("theme", to: .string("grokday"), in: "ui") }
        XCTAssertEqual(result, "# Crok settings\n[ui]\ntheme = \"grokday\" # mine\nvim_mode = true\n\n[models]\ndefault = \"grok-4\"\n")
    }

    func testAddsKeysAfterTheTablesLastStatementAndNewTablesAtTheEnd() throws {
        let original = "[ui]\n  theme = \"auto\"\n\n# models follow\n[models]\ndefault = \"x\""
        var result = try edited(original) { try $0.set("show_timestamps", to: .bool(false), in: "ui") }
        XCTAssertEqual(result, "[ui]\n  theme = \"auto\"\n  show_timestamps = false\n\n# models follow\n[models]\ndefault = \"x\"")
        result = try edited(result) { try $0.set("default_reasoning_effort", to: .string("high"), in: "models") }
        XCTAssertTrue(result.hasSuffix("[models]\ndefault = \"x\"\ndefault_reasoning_effort = \"high\"\n"), result)
        result = try edited(result) { try $0.set("explore", to: .bool(false), in: "subagents.toggle") }
        XCTAssertTrue(result.hasSuffix("\n\n[subagents.toggle]\nexplore = false\n"), result)
        XCTAssertEqual(GrokConfig(text: result).bool("explore", in: "subagents.toggle"), false)
    }

    func testMultilineStringsAreNotMistakenForTablesOrKeys() throws {
        let original = "[agent]\nprompt = \"\"\"\n[rules]\nname = \"not a key\"\n\"\"\"\n\n[ui]\nnote = '''\ntheme = \"keep me\"\n'''\ntheme = \"auto\"\n"
        let result = try edited(original) {
            try $0.set("name", to: .string("reviewer"), in: "agent")
            try $0.set("theme", to: .string("grokday"), in: "ui")
        }
        XCTAssertTrue(result.contains("[rules]\nname = \"not a key\"\n\"\"\"\nname = \"reviewer\"\n"), result)
        XCTAssertTrue(result.contains("theme = \"keep me\"\n'''\ntheme = \"grokday\"\n"), result)
        let config = GrokConfig(text: result)
        XCTAssertEqual(config.string("name", in: "agent"), "reviewer")
        XCTAssertEqual(config.string("theme", in: "ui"), "grokday")
        XCTAssertNil(config.string("name", in: "rules"))
    }

    func testCRLFFilesStayCRLFAndAreReadCorrectly() throws {
        let original = "[ui]\r\ntheme = \"auto\"\r\n"
        XCTAssertEqual(GrokConfig(text: original).string("theme", in: "ui"), "auto")
        let result = try edited(original) {
            try $0.set("theme", to: .string("tokyonight"), in: "ui")
            try $0.set("vim_mode", to: .bool(true), in: "ui")
        }
        XCTAssertEqual(result, "[ui]\r\ntheme = \"tokyonight\"\r\nvim_mode = true\r\n")
    }

    func testByteOrderMarkIsKept() throws {
        let result = try edited("\u{FEFF}[ui]\ntheme = \"auto\"\n") { try $0.set("theme", to: .string("grokday"), in: "ui") }
        XCTAssertEqual(result, "\u{FEFF}[ui]\ntheme = \"grokday\"\n")
    }

    func testDottedInlineAndInvalidLayoutsAreRefusedUnchanged() {
        for text in ["ui.theme = \"auto\"\n", "ui = { theme = \"auto\" }\n", "[[ui]]\ntheme = \"auto\"\n", "[ui\ntheme = \"auto\"\n"] {
            var config = GrokConfig(text: text)
            XCTAssertThrowsError(try config.set("theme", to: .string("grokday"), in: "ui"), text)
            XCTAssertEqual(config.text, text)
        }
    }

    func testRemoveDeletesOnlyThatStatement() throws {
        let result = try edited("[agent]\nname = \"a\" # default\nkeep = 1\n") { try $0.remove("name", in: "agent") }
        XCTAssertEqual(result, "[agent]\nkeep = 1\n")
    }

    func testUnreadableFileIsNeverReplaced() throws {
        let url = directory.appendingPathComponent("config.toml")
        var bytes = Data("api_key = \"secret\"\n# caf".utf8); bytes.append(0xE9); bytes.append(contentsOf: Array("\n".utf8))
        try bytes.write(to: url)
        XCTAssertThrowsError(try GrokConfig.update(url: url) { try $0.set("theme", to: .string("light"), in: "ui") })
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var lenient = GrokConfig(url: url)
        XCTAssertThrowsError(try lenient.set("theme", to: .string("light"), in: "ui"), "A lenient read of an unreadable file cannot be edited")
        XCTAssertThrowsError(try lenient.save(), "…or saved")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSymlinkedConfigIsWrittenThroughAndKeepsItsPermissions() throws {
        let target = directory.appendingPathComponent("dotfiles-config.toml")
        try Data("[ui]\ntheme = \"auto\"\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try GrokConfig.update(url: link) { try $0.set("theme", to: .string("grokday"), in: "ui") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(GrokConfig(url: target).string("theme", in: "ui"), "grokday")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNewFilesArePrivateAndConcurrentUpdatesAreAllKept() throws {
        let url = directory.appendingPathComponent("grok-home/config.toml")
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            try? GrokConfig.update(url: url) { try $0.set("key\(index)", to: .int(index), in: "stress") }
        }
        let config = GrokConfig(url: url)
        for index in 0..<24 { XCTAssertEqual(config.int("key\(index)", in: "stress"), index) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
