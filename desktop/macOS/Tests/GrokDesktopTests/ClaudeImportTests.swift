import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// `/import-claude` against temporary home, `CROK_HOME`, and project directories; nothing here reads
/// or writes the real `~/.claude` or `~/.crok`.
final class ClaudeImportTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var grokHome: URL { root.appendingPathComponent("grok-home", isDirectory: true) }
    private var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
    private var cwd: URL { repo.appendingPathComponent("sub", isDirectory: true) }

    override func setUpWithError() throws {
        // Resolve /var → /private/var so paths compare the way the scanner sees them.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-claude-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        for directory in [home, grokHome, cwd, repo.appendingPathComponent(".git")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var environment: ClaudeImportEnvironment {
        ClaudeImportEnvironment(home: home, grokHome: grokHome, cwd: cwd, now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Claude settings in every place the terminal looks.
    private func writeFixture() throws {
        try write("""
        { "permissions": { "allow": ["mcp__github"] } }
        """, home.appendingPathComponent(".claude/settings.local.json"))
        try write("""
        {
          "permissions": {
            "allow": ["Bash(npm test)", "Read(src/**)", "EnterWorktree", 42],
            "deny": ["Bash(rm:*)"],
            "ask": ["WebFetch(domain:example.com)"]
          },
          "env": { "RUST_LOG": "debug", "RETRIES": 3, "FLAG": true, "NESTED": {} },
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [
                { "type": "command", "command": "echo pre", "timeout": 7 },
                { "type": "http", "url": "https://example.com/hook" }
              ] }
            ],
            "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "say done" } ] } ]
          }
        }
        """, home.appendingPathComponent(".claude/settings.json"))
        try write("""
        {
          "mcpServers": {
            "github": { "type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": { "GITHUB_TOKEN": "ghp_x" } },
            "broken": { "enabled": true },
            "linear": { "command": "user-level-loses" }
          },
          "projects": {
            "\(cwd.path)": { "mcpServers": { "linear": { "type": "http", "url": "https://mcp.linear.app/mcp" } } }
          }
        }
        """, home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/rules"), withIntermediateDirectories: true)
        try write("""
        { "permissions": { "allow": ["Edit"] }, "env": { "PROJECT_ONLY": "1" } }
        """, repo.appendingPathComponent(".claude/settings.json"))
        try write("""
        { "permissions": { "deny": ["Read(./.env)"] } }
        """, cwd.appendingPathComponent(".claude/settings.local.json"))
        try write("""
        { "mcpServers": { "docs": { "command": "farther" } } }
        """, repo.appendingPathComponent(".mcp.json"))
        try write("""
        { "mcpServers": { "docs": { "command": "nearer" }, "sentry": { "url": "https://sentry.dev/mcp", "headers": { "Authorization": "Bearer s" } } } }
        """, cwd.appendingPathComponent(".mcp.json"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
    }

    // MARK: Scanning

    func testScanFindsEverySourceKindInTheTerminalsOrder() throws {
        try writeFixture()
        let plan = ClaudeImportScanner.scan(environment)
        XCTAssertEqual(plan.projectRoot.path, repo.path)
        XCTAssertEqual(plan.projectConfigPath, repo.path + "/.grok/config.toml")
        XCTAssertEqual(plan.global.map(\.label), [
            "allow Mcp(github__*)",
            "allow Bash(npm test)",
            "allow Read(src/**)",
            "deny  Bash(rm)",
            "ask   WebFetch(example.com)",
            "RUST_LOG = \"debug\"",
            "RETRIES = \"3\"",
            "FLAG = \"true\"",
            "PreToolUse  matcher=Bash → echo pre timeout=7s",
            "Stop  matcher=* → say done",
            "linear",
            "github",
            "skill dir: \(home.path)/.claude/skills",
            "rule dir: \(home.path)/.claude/rules",
        ])
        XCTAssertEqual(plan.project.map(\.label), [
            "deny  Read(./.env)",
            "allow Edit(*)",
            "PROJECT_ONLY = \"1\"",
            "docs",
            "sentry",
            "skill dir: \(repo.path)/.claude/skills",
        ])
        guard case .mcpServer(_, let linear) = plan.global[10], case .mcpServer(_, let github) = plan.global[11],
              case .mcpServer(_, let docs) = plan.project[3], case .mcpServer(_, let sentry) = plan.project[4] else { return XCTFail("servers") }
        XCTAssertEqual(linear.lines, ["url = \"https://mcp.linear.app/mcp\"", "type = \"http\"", "enabled = true"], "this project's entry wins over the user-level one")
        XCTAssertEqual(github.lines, ["command = \"npx\"", "args = [\"-y\", \"@modelcontextprotocol/server-github\"]", "env = { GITHUB_TOKEN = \"ghp_x\" }", "enabled = true"])
        XCTAssertEqual(docs.lines, ["command = \"nearer\"", "args = []", "enabled = true"], "the nearer .mcp.json wins")
        XCTAssertEqual(sentry.lines, ["url = \"https://sentry.dev/mcp\"", "headers = { Authorization = \"Bearer s\" }", "enabled = true"])
        XCTAssertEqual(github.summary, "npx -y @modelcontextprotocol/server-github")
    }

    func testHomeThatIsARepositoryIsNotAProjectRoot() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try write(#"{ "permissions": { "allow": ["Bash"] } }"#, home.appendingPathComponent(".claude/settings.json"))
        let project = home.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var environment = self.environment
        environment.cwd = project
        XCTAssertEqual(ClaudeImportScanner.settingsPaths(environment).map(\.path), [
            project.path + "/.claude/settings.local.json", project.path + "/.claude/settings.json",
            home.path + "/.claude/settings.local.json", home.path + "/.claude/settings.json",
        ], "the walk stops at the working directory instead of reaching the home repository")
        let plan = ClaudeImportScanner.scan(environment)
        XCTAssertEqual(plan.global.map(\.label), ["allow Bash(*)"], "~/.claude stays global")
        XCTAssertTrue(plan.project.isEmpty)
    }

    func testNothingToImport() {
        XCTAssertTrue(ClaudeImportScanner.scan(environment).isEmpty)
    }

    func testSymlinkedSettingsAreReadAndFIFOsAreNot() throws {
        let dotfiles = root.appendingPathComponent("dotfiles/claude-settings.json")
        try write(#"{ "env": { "FROM_LINK": "1" } }"#, dotfiles)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude/settings.json"), withDestinationURL: dotfiles)
        XCTAssertEqual(mkfifo(cwd.appendingPathComponent(".mcp.json").path, 0o600), 0)
        XCTAssertEqual(ClaudeImportScanner.scan(environment).global.map(\.label), ["FROM_LINK = \"1\""])
        XCTAssertNoThrow(try ClaudeImportState.markImported(environment), "hashing skips the FIFO instead of blocking")
    }

    func testPermissionRulesParseAndFormatLikeTheTerminal() {
        func rule(_ text: String, _ action: ClaudeRuleAction = .allow) -> ClaudePermissionRule? { ClaudePermissionRule(text, action: action) }
        XCTAssertEqual(rule("Bash(npm run build)")?.configString, "Bash(npm run build)")
        XCTAssertEqual(rule("  Bash( sed:* ) ")?.configString, "Bash(sed)")
        XCTAssertEqual(rule("Bash")?.configString, "Bash")
        XCTAssertEqual(rule("Bash(*)")?.configString, "Bash")
        XCTAssertEqual(rule("Bash()")?.configString, "Bash")
        XCTAssertEqual(rule("Write(src/*.rs)")?.configString, "Edit(src/*.rs)")
        XCTAssertEqual(rule("Glob")?.configString, "Grep")
        XCTAssertEqual(rule("WebFetch(domain:example.com)")?.configString, "WebFetch(domain:example.com)")
        XCTAssertEqual(rule("Read(a\\(b\\))")?.configString, "Read(a(b))")
        XCTAssertEqual(rule("SendAgentMessage")?.configString, "AgentMessage")
        XCTAssertEqual(rule("mcp__*")?.configString, "MCPTool")
        XCTAssertEqual(rule("mcp__linear__create_issue")?.configString, "MCPTool(linear__create_issue)")
        XCTAssertEqual(rule("mcp__linear")?.configString, "MCPTool(linear__*)")
        XCTAssertEqual(rule("*")?.configString, "*")
        XCTAssertEqual(rule("")?.configString, "*")
        XCTAssertEqual(rule("src/**")?.configString, "src/**")
        XCTAssertNil(rule("Unknown(x)"))
        XCTAssertNil(rule("NotebookEdit"))
        XCTAssertNil(rule("NotebookRead(x)"))
        XCTAssertNil(rule("Bash(unclosed"))
        XCTAssertEqual(ClaudeImportItem.permission(rule("src/**", .ask)!).label, "ask   Any(src/**)")
        XCTAssertEqual(ClaudeImportItem.envVar(key: "Q", value: "a\"b\\c\nd\u{1}").label, #"Q = "a\"b\\c\nd\u{1}""#)
        XCTAssertEqual(ClaudeImportItem.path(kind: .rule, path: "/r").label, "rule dir: /r")
    }

    func testMCPEntriesTheTerminalWouldRejectAreSkipped() throws {
        func convert(_ json: String) throws -> [String]? { ClaudeMCPConverter.convert(try ClaudeJSON.parse(json))?.lines }
        XCTAssertNil(try convert(#"{ "enabled": false }"#), "no transport")
        XCTAssertNil(try convert(#"{ "command": "x", "args": ["a", 1] }"#), "non-string args")
        XCTAssertNil(try convert(#"{ "command": "x", "env": { "A": 1 } }"#), "non-string env")
        XCTAssertNil(try convert(#"{ "command": "x", "enabled": "yes" }"#))
        XCTAssertNil(try convert(#"{ "url": "u", "startup_timeout_sec": 1.5 }"#))
        XCTAssertEqual(try convert(#"{ "command": 5, "url": "https://x" }"#), ["url = \"https://x\"", "enabled = true"], "falls back to HTTP like serde's untagged enum")
        XCTAssertEqual(try convert(#"{ "urlTemplate": "https://t", "type": "sse", "enabled": false, "tool_timeout_sec": 30, "tool_timeouts": { "search": 5 }, "oauth": { "clientId": "c", "scopes": ["a"], "callbackPort": 8765 } }"#), [
            "url = \"https://t\"", "type = \"sse\"", "enabled = false",
            "oauth = { clientId = \"c\", scopes = [\"a\"], callbackPort = 8765 }", "tool_timeout_sec = 30", "tool_timeouts = { search = 5 }",
        ])
        XCTAssertEqual(try convert(#"{ "command": "run", "cwd": null, "setup": { "fields": [ { "id": "site", "label": "Site", "type": "select", "options": [ { "label": "US", "value": "us" } ] } ], "values": { "url": { "from": "site", "map": { "us": "https://us" } } } } }"#), [
            "command = \"run\"", "args = []", "enabled = true",
            "setup = { fields = [{ id = \"site\", label = \"Site\", type = \"select\", required = false, options = [{ label = \"US\", value = \"us\" }] }], variables = { url = { from = \"site\", map = { us = \"https://us\" } } } }",
        ])
        let lines = try XCTUnwrap(try convert(#"{ "command": "x", "env": { "weird key": "v\"q" } }"#))
        XCTAssertEqual(lines[2], #"env = { "weird key" = "v\"q" }"#)
        XCTAssertNoThrow(try ClaudeTOMLDocument("[mcp_servers.x]\n" + lines.joined(separator: "\n") + "\n"), "the generated TOML parses")
    }

    // MARK: Applying

    private func item(_ text: String, _ action: ClaudeRuleAction = .allow) throws -> ClaudeImportItem { .permission(try XCTUnwrap(ClaudePermissionRule(text, action: action))) }

    func testApplyMergesAdditivelyAndPreservesEverythingElse() throws {
        let configURL = grokHome.appendingPathComponent("config.toml")
        let original = """
        # Crok settings
        [ui]
        theme = "dark" # keep me

        [permission]
        allow = [
            "Bash(npm test)",  # already here
        ]
        deny = ["Read(.env)"]

        [env]
        RUST_LOG = "info"

        [mcp_servers.github]
        command = "gh-mcp"

        [model]
        default = "grok-4"

        """
        try write(original, configURL)
        let server = try XCTUnwrap(ClaudeMCPConverter.convert(try ClaudeJSON.parse(#"{ "type": "http", "url": "https://mcp.linear.app/mcp" }"#)))
        let github = try XCTUnwrap(ClaudeMCPConverter.convert(try ClaudeJSON.parse(#"{ "command": "npx" }"#)))
        let plan = ClaudeImportPlan(global: [
            try item("Bash(npm test)"), try item("Read(src/**)"), try item("WebFetch(domain:example.com)", .ask), try item("Bash(rm:*)", .deny),
            .envVar(key: "RUST_LOG", value: "debug"), .envVar(key: "RETRIES", value: "3"),
            .mcpServer(name: "github", server: github), .mcpServer(name: "linear", server: server),
            .path(kind: .skill, path: "/Users/you/.claude/skills"),
            .hook(event: "Stop", matcher: nil, command: "say done", timeout: nil),
        ], projectRoot: repo)
        let result = try ClaudeImporter.apply(plan, environment: environment)
        XCTAssertEqual(try read(configURL), """
        # Crok settings
        [ui]
        theme = "dark" # keep me

        [permission]
        allow = [
            "Bash(npm test)",  # already here
            "Read(src/**)",
        ]
        deny = ["Read(.env)", "Bash(rm)"]
        ask = ["WebFetch(domain:example.com)"]

        [env]
        RUST_LOG = "info"
        RETRIES = "3"

        [mcp_servers.github]
        command = "gh-mcp"

        [model]
        default = "grok-4"

        [paths]
        extra_skill_dirs = ["/Users/you/.claude/skills"]

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"
        type = "http"
        enabled = true

        """)
        let hooksURL = grokHome.appendingPathComponent("hooks/imported-from-claude.json")
        XCTAssertEqual(result, ClaudeImportResult(globalCount: 7, projectCount: 0, modifiedFiles: [configURL.path, hooksURL.path]))
        XCTAssertNoThrow(try ClaudeTOMLDocument(try read(configURL)))

        // A second import adds nothing and leaves the config byte-for-byte alone.
        let before = try read(configURL)
        let again = try ClaudeImporter.apply(plan, environment: environment)
        XCTAssertEqual(again.total, 0)
        XCTAssertEqual(again.modifiedFiles, [])
        XCTAssertEqual(try read(configURL), before)
    }

    func testProjectItemsGoToTheRepositoryAndNewFilesArePrivate() throws {
        let plan = ClaudeImportPlan(global: [.envVar(key: "TOKEN", value: "secret")],
                                    project: [try item("Edit"), .hook(event: "PreToolUse", matcher: "Bash", command: "lint", timeout: 3)],
                                    projectRoot: repo)
        let result = try ClaudeImporter.apply(plan, environment: environment)
        let global = grokHome.appendingPathComponent("config.toml"), project = repo.appendingPathComponent(".grok/config.toml")
        XCTAssertEqual(result.globalCount, 1)
        XCTAssertEqual(result.projectCount, 2)
        XCTAssertEqual(result.modifiedFiles, [global.path, project.path, repo.appendingPathComponent(".grok/hooks/imported-from-claude.json").path])
        XCTAssertEqual(try read(global), "[env]\nTOKEN = \"secret\"\n")
        XCTAssertEqual(try read(project), "[permission]\nallow = [\"Edit\"]\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: global.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "imported env vars can be secrets")
    }

    func testRefusesInvalidOrUneditableConfigWithoutWritingAnything() throws {
        let configURL = grokHome.appendingPathComponent("config.toml")
        let plan = ClaudeImportPlan(global: [try item("Bash")], project: [try item("Edit")], projectRoot: repo)
        for invalid in ["[ui\ntheme = 1\n", "a = 1\na = 2\n", "[permission]\nallow = [\"x\",\n"] {
            try write(invalid, configURL)
            XCTAssertThrowsError(try ClaudeImporter.apply(plan, environment: environment)) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("refusing to import: existing config at \(configURL.path) is not valid TOML ("), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.hasSuffix("Fix the file (or move it aside) and retry."))
            }
            XCTAssertEqual(try read(configURL), invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".grok").path), "no file is written when any is refused")
        }
        for layout in ["permission = { allow = [] }\n", "permission.allow = []\n"] {
            try write(layout, configURL)
            XCTAssertThrowsError(try ClaudeImporter.apply(plan, environment: environment), layout) { error in
                XCTAssertEqual(error.localizedDescription, "refusing to import: \(configURL.path) cannot be edited safely ([permission] is written as dotted keys or an inline table). Edit it by hand, or run /import-claude in the terminal.")
            }
            XCTAssertEqual(try read(configURL), layout)
        }
        // Wrong types fail with the terminal's own messages.
        for (layout, message) in [("[permission]\nallow = \"Bash\"\n", "permission.allow is not an array"), ("[[permission]]\n", "[permission] is not a table"), ("permission = 1\n", "[permission] is not a table")] {
            try write(layout, configURL)
            XCTAssertThrowsError(try ClaudeImporter.apply(plan, environment: environment), layout) { XCTAssertEqual($0.localizedDescription, message) }
            XCTAssertEqual(try read(configURL), layout)
        }
        // A bad project config stops the import before the global config is written.
        try FileManager.default.removeItem(at: configURL)
        try write("[oops", repo.appendingPathComponent(".grok/config.toml"))
        XCTAssertThrowsError(try ClaudeImporter.apply(plan, environment: environment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        // An `env` that is not a table is skipped rather than fatal, as in the terminal.
        try write("env = \"x\"\n", configURL)
        let skipped = try ClaudeImporter.apply(ClaudeImportPlan(global: [.envVar(key: "A", value: "b")], projectRoot: repo), environment: environment)
        XCTAssertEqual(skipped.total, 0)
        XCTAssertEqual(try read(configURL), "env = \"x\"\n")
    }

    func testHooksFileFormatDedupAndTimeoutRefresh() throws {
        let hooksURL = grokHome.appendingPathComponent("hooks/imported-from-claude.json")
        let plan = ClaudeImportPlan(global: [
            .hook(event: "PreToolUse", matcher: "Bash", command: "echo pre", timeout: 7),
            .hook(event: "Stop", matcher: nil, command: "say done", timeout: nil),
        ], projectRoot: repo)
        XCTAssertEqual(try ClaudeImporter.apply(plan, environment: environment).globalCount, 2)
        XCTAssertEqual(try read(hooksURL), """
        {
          "hooks": {
            "PreToolUse": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo pre",
                    "timeout": 7
                  }
                ],
                "matcher": "Bash"
              }
            ],
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  }
                ]
              }
            ]
          }
        }
        """)
        // Same (event, matcher, command): the timeout is refreshed in place and nothing is added.
        let refreshed = ClaudeImportPlan(global: [
            .hook(event: "PreToolUse", matcher: "Bash", command: "echo pre", timeout: nil),
            .hook(event: "PreToolUse", matcher: "Edit", command: "echo pre", timeout: 2),
        ], projectRoot: repo)
        let result = try ClaudeImporter.apply(refreshed, environment: environment)
        XCTAssertEqual(result.globalCount, 1)
        let json = try ClaudeJSON.parse(try read(hooksURL))
        let groups = try XCTUnwrap(json["hooks"]?["PreToolUse"]?.arrayValue)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNil(groups[0]["hooks"]?.arrayValue?.first?["timeout"], "the missing timeout is removed")
        XCTAssertEqual(groups[1]["matcher"], .string("Edit"))
        XCTAssertEqual(groups[1]["hooks"]?.arrayValue?.first?["timeout"], .number("2"))

        // A malformed file is replaced, as the terminal does.
        try write("{ not json", hooksURL)
        XCTAssertEqual(try ClaudeImporter.apply(plan, environment: environment).globalCount, 2)
        XCTAssertNotNil(try ClaudeJSON.parse(try read(hooksURL))["hooks"]?["Stop"])
        try write("[1]", hooksURL)
        XCTAssertThrowsError(try ClaudeImporter.apply(plan, environment: environment))
    }

    func testMarkerIsWrittenAdditively() throws {
        let configURL = grokHome.appendingPathComponent("config.toml")
        try ClaudeImporter.markImported(environment)
        XCTAssertEqual(try read(configURL), "[claude_compat]\nimported = true\n")
        try write("# mine\n[claude_compat]\nimported = false # was off\n\n[ui]\ntheme = \"light\"", configURL)
        try ClaudeImporter.markImported(environment)
        XCTAssertEqual(try read(configURL), "# mine\n[claude_compat]\nimported = true # was off\n\n[ui]\ntheme = \"light\"")
        try write("[ui]\ntheme = \"light\"", configURL)
        try ClaudeImporter.markImported(environment)
        try ClaudeImporter.markImported(environment)
        XCTAssertEqual(try read(configURL), "[ui]\ntheme = \"light\"\n\n[claude_compat]\nimported = true\n")
        try write("[claude_compat\n", configURL)
        XCTAssertThrowsError(try ClaudeImporter.markImported(environment))
        XCTAssertEqual(try read(configURL), "[claude_compat\n")
    }

    func testStateFileRecordsHashesLikeTheTerminal() throws {
        try write("A", home.appendingPathComponent(".claude/settings.json"))
        try write("B", home.appendingPathComponent(".claude.json"))
        try write("C", cwd.appendingPathComponent(".mcp.json"))
        try write(#"{"version":1,"global":null,"projects":{"/elsewhere":{"last_hash":"sha256:0","last_checked":"x"}},"extra":true}"#, grokHome.appendingPathComponent("claude_import_state.json"))
        try ClaudeImportState.markImported(environment)

        func digest(_ parts: [(String, String)]) -> String {
            var hasher = SHA256()
            for (path, contents) in parts { hasher.update(data: Data((path + "\0" + contents + "\0").utf8)) }
            return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        // Rust orders paths by component, so `~/.claude/settings.json` sorts before `~/.claude.json`.
        let global = digest([(home.path + "/.claude/settings.json", "A"), (home.path + "/.claude.json", "B")])
        let project = digest([(cwd.path + "/.mcp.json", "C")])
        let timestamp = "2026-09-21T14:13:20.000000+00:00"
        XCTAssertEqual(try read(grokHome.appendingPathComponent("claude_import_state.json")), """
        {
          "version": 1,
          "global": {
            "last_hash": "\(global)",
            "last_checked": "\(timestamp)"
          },
          "projects": {
            "/elsewhere": {
              "last_hash": "sha256:0",
              "last_checked": "x"
            },
            "\(cwd.path)": {
              "last_hash": "\(project)",
              "last_checked": "\(timestamp)"
            }
          }
        }
        """)
        XCTAssertEqual(ClaudeImportState.hash([]), "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testImportSelectionReportsLikeTheTerminal() async throws {
        try writeFixture()
        let plan = ClaudeImportScanner.scan(environment)
        let selected = Set([1, 5, plan.global.count])
        let summary = await ClaudeImportFlow.importSelection(plan, selected: selected, environment: environment)
        XCTAssertEqual(summary, """
        Imported 3 of \(plan.totalItems) setting(s).
        Updated: \(grokHome.path)/config.toml
        Updated: \(repo.path)/.grok/config.toml
        """)
        XCTAssertTrue(try read(grokHome.appendingPathComponent("config.toml")).contains("[claude_compat]\nimported = true"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: grokHome.appendingPathComponent("claude_import_state.json").path))

        let none = await ClaudeImportFlow.importSelection(plan, selected: [], environment: environment)
        XCTAssertEqual(none, "No items selected.")

        try write("[broken", grokHome.appendingPathComponent("config.toml"))
        let failed = await ClaudeImportFlow.importSelection(plan, selected: selected, environment: environment)
        XCTAssertTrue(failed.hasPrefix("Failed to import Claude settings: refusing to import: existing config at"), failed)
    }

    // MARK: TOML

    func testTOMLParserAcceptsValidDocuments() throws {
        let valid = #"""
        # comment
        title = "TOML \"Example\" \u00e9 \U0001F600"
        literal = 'C:\Users\x'
        multi = """
        Roses are red \
           Violets are blue"""
        lit_multi = '''
        raw \n text'''
        quotes = """"five" quotes""""
        int = +1_000
        hex = 0xDEAD_beef
        oct = 0o755
        bin = 0b1101
        float = -3.14e+10
        special = [inf, -inf, nan]
        date = 1979-05-27T07:32:00-08:00
        spaced = 1979-05-27 07:32:00Z
        local_date = 1979-05-27
        time = 07:32:00.999
        bool = true
        "quoted key" = 1
        'literal key' = 2
        dotted.deep.key = 3
        dotted.deep.other = 4
        points = [ { x = 1, y = 2 }, { x = 3, "y" = 4 } ]
        nested = [ [1, 2], ["a", 'b'], ] # trailing comma
        inline = { a.b = 1, a.c = 2 }
        multiline_inline = {
          esc = "\e\x41", # TOML 1.1, which Crok's parser reads
          short_time = 07:32,
        }

        [a.b.c]
        x = 1
        [a]
        y = 2
        [[fruits]]
        name = "apple"
        [fruits.physical]
        color = "red"
        [[fruits]]
        name = "banana"
        [ spaced_out . "header" ]
        k = 'v'
        """#
        let document = try ClaudeTOMLDocument(valid)
        guard case .tableArray(let fruits)? = document.root.entries["fruits"] else { return XCTFail("fruits") }
        XCTAssertEqual(fruits.count, 2)
        guard case .value(.string(let multi), _)? = document.root.entries["multi"] else { return XCTFail("multi") }
        XCTAssertEqual(multi, "Roses are red Violets are blue")
        guard case .value(.string(let quotes), _)? = document.root.entries["quotes"] else { return XCTFail("quotes") }
        XCTAssertEqual(quotes, "\"five\" quotes\"")
        guard case .value(.string(let title), _)? = document.root.entries["title"] else { return XCTFail("title") }
        XCTAssertEqual(title, "TOML \"Example\" é 😀")
        XCTAssertNoThrow(try ClaudeTOMLDocument("\u{FEFF}a = 1\r\n[b]\r\nc = 2\r\n"))
        XCTAssertNoThrow(try ClaudeTOMLDocument(""))
    }

    func testTOMLParserRejectsInvalidDocuments() {
        let invalid = [
            "a = 1\na = 2", "[a]\n[a]", "a.b = 1\n[a]", "a = {}\n[a.b]", "a = { b = 1 }\na.c = 2", "[a]\nb.c = 1\n[a.b]",
            "a = \"unterminated", "a = \"bad \\q escape\"", "a = \"line\nbreak\"", "a = ", "a = 1 2", "a = [1, 2", "a = [,]",
            "[a", "[[a]\n", "= 1", "a = 1\n[[a]]", "[x]\n[[x]]", "a = 01", "a = 1__0", "a = 1.", "a = .5",
            "a = tru", "key\n= 1", "a = 1979-05-27T25", "a = \"\u{01}\"", "a = '''open", "[a.b]\n[a]\n[a]",
        ]
        for text in invalid {
            XCTAssertThrowsError(try ClaudeTOMLDocument(text), text) { error in
                guard case ClaudeTOMLError.syntax = error else { return XCTFail("\(text): \(error)") }
            }
        }
    }

    func testTOMLEditorKeepsEachArrayStyle() throws {
        func merged(_ text: String, _ values: [String] = ["n1", "n2"], key: String = "allow") throws -> String {
            var editor = try ClaudeTOMLEditor(text: text)
            _ = try editor.mergeStrings(values, into: key, of: "permission")
            XCTAssertNoThrow(try ClaudeTOMLDocument(editor.text), editor.text)
            return editor.text
        }
        XCTAssertEqual(try merged("[permission]\nallow = []\n"), "[permission]\nallow = [\"n1\", \"n2\"]\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\"a\",]\n"), "[permission]\nallow = [\"a\", \"n1\", \"n2\",]\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\n]\n"), "[permission]\nallow = [\n    \"n1\",\n    \"n2\",\n]\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\n  \"a\", # first\n  \"b\"\n]\n"), "[permission]\nallow = [\n  \"a\", # first\n  \"b\",\n  \"n1\",\n  \"n2\"\n]\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\n  \"a\" # only\n]\n"), "[permission]\nallow = [\n  \"a\", # only\n  \"n1\",\n  \"n2\"\n]\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\n  \"a\"]\n"), "[permission]\nallow = [\n  \"a\", \"n1\", \"n2\"]\n")
        XCTAssertEqual(try merged("[permission]\r\nallow = [\r\n    \"a\",\r\n]\r\n"), "[permission]\r\nallow = [\r\n    \"a\",\r\n    \"n1\",\r\n    \"n2\",\r\n]\r\n")
        XCTAssertEqual(try merged("[permission]\nallow = [\"n1\", 3]\n", ["n1", "n1"]), "[permission]\nallow = [\"n1\", 3]\n", "nothing new")
        XCTAssertEqual(try merged("[permission]\n  deny = [\"x\"]\n\n# next\n[ui]\n"), "[permission]\n  deny = [\"x\"]\n  allow = [\n      \"n1\",\n      \"n2\",\n  ]\n\n# next\n[ui]\n")
        XCTAssertEqual(try merged("[permission]"), "[permission]\nallow = [\n    \"n1\",\n    \"n2\",\n]\n")
        XCTAssertEqual(try merged("x = 1", ["only"]), "x = 1\n\n[permission]\nallow = [\"only\"]\n")
        XCTAssertEqual(try merged("[permission.rules]\nk = 1\n", ["only"]), "[permission.rules]\nk = 1\n\n[permission]\nallow = [\"only\"]\n", "a super-table may follow its sub-tables")
        XCTAssertEqual(try merged("\u{FEFF}[permission]\nallow = [\"a\"]\n", ["b"]), "\u{FEFF}[permission]\nallow = [\"a\", \"b\"]\n")
    }

    // MARK: Sheet model

    private func samplePlan() throws -> ClaudeImportPlan {
        let github = try XCTUnwrap(ClaudeMCPConverter.convert(try ClaudeJSON.parse(#"{ "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }"#)))
        let linear = try XCTUnwrap(ClaudeMCPConverter.convert(try ClaudeJSON.parse(#"{ "type": "http", "url": "https://mcp.linear.app/mcp" }"#)))
        return ClaudeImportPlan(global: [
            .mcpServer(name: "github", server: github),
            try item("Bash(npm run test:*)"),
            try item("Read(~/.ssh/**)", .deny),
            .envVar(key: "ANTHROPIC_LOG", value: "info"),
            try item("WebFetch(domain:docs.rs)", .ask),
            .mcpServer(name: "linear", server: linear),
            .hook(event: "PostToolUse", matcher: "Edit|Write", command: "prettier --write \"$CLAUDE_FILE_PATHS\"", timeout: 30),
            .path(kind: .skill, path: "/Users/you/.claude/skills"),
            .path(kind: .rule, path: "/Users/you/.claude/rules"),
        ], project: [
            try item("Bash(cargo test *)"),
            .envVar(key: "RUST_BACKTRACE", value: "1"),
            .hook(event: "Stop", matcher: nil, command: "./scripts/notify.sh", timeout: nil),
            .path(kind: .skill, path: "/Users/you/code/billing-api/.claude/skills"),
        ], projectRoot: URL(fileURLWithPath: "/Users/you/code/billing-api"))
    }

    @MainActor
    func testSheetModelGroupsTogglesAndFolds() throws {
        let model = ClaudeImportModel(plan: try samplePlan(), environment: environment)
        XCTAssertEqual(model.selectedCount, 13)
        XCTAssertEqual(model.rows.filter(\.isHeader).map(model.label), [
            "Global  ~/.crok/config.toml", "Permissions (3)", "Env vars (1)", "MCP servers (2)", "Hooks (1)", "Paths (2)",
            "Project  /Users/you/code/billing-api/.grok/config.toml", "Permissions (1)", "Env vars (1)", "Hooks (1)", "Paths (1)",
        ])
        XCTAssertEqual(model.focus, .item(1), "focus starts on the first item")
        XCTAssertEqual(model.indices(.group(.global, .mcpServer)), [0, 5], "grouping keeps each item's own index")

        // Deselecting the MCP group must drop exactly those servers (the terminal's grouping regression).
        model.toggle(.group(.global, .mcpServer))
        XCTAssertEqual(model.check(.group(.global, .mcpServer)), .off)
        XCTAssertEqual(model.check(.scope(.global)), .mixed)
        let filtered = try XCTUnwrap(model.plan).filtered(model.selected)
        XCTAssertFalse(filtered.global.contains { $0.kind == .mcpServer })
        XCTAssertEqual(filtered.global.count, 7)
        XCTAssertEqual(filtered.project.count, 4)
        model.toggle(.scope(.global))
        XCTAssertEqual(model.check(.scope(.global)), .on, "a partly selected header selects everything")
        model.toggle(.scope(.global))
        XCTAssertEqual(model.check(.scope(.global)), .off)
        XCTAssertEqual(model.check(.scope(.project)), .on, "the other scope is untouched")
        model.toggle(.item(9))
        XCTAssertEqual(model.check(.group(.project, .permission)), .off)
        model.selectAll()
        XCTAssertEqual(model.selectedCount, 13)
        model.selectNone()
        XCTAssertEqual(model.selectedCount, 0)

        // ← folds an open header, then jumps to the parent; → unfolds.
        model.focus = .item(3)
        model.foldOrParent()
        XCTAssertEqual(model.focus, .group(.global, .envVar))
        model.foldOrParent()
        XCTAssertTrue(model.isCollapsed(.group(.global, .envVar)))
        XCTAssertFalse(model.rows.contains(.item(3)))
        model.foldOrParent()
        XCTAssertEqual(model.focus, .scope(.global))
        model.foldOrParent()
        XCTAssertEqual(model.rows.first, .scope(.global))
        XCTAssertEqual(model.rows[1], .scope(.project), "a folded scope hides its groups")
        model.unfold()
        XCTAssertTrue(model.rows.contains(.group(.global, .envVar)))
        model.moveFocus(1)
        XCTAssertEqual(model.focus, .group(.global, .permission))
        model.focusEdge(last: true)
        XCTAssertEqual(model.focus, .item(12))
    }

    /// Writes the sheet in light and dark when CROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
    @MainActor
    func testRenderImportClaudeSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let store = AppStore(stateFile: root.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        for (name, appearance, fold) in [("import-claude-light", NSAppearance.Name.aqua, false), ("import-claude-dark", .darkAqua, true)] {
            let model = ClaudeImportModel(plan: try samplePlan(), environment: environment)
            model.toggle(.item(2))
            model.toggle(.group(.global, .path))
            model.toggle(.item(12))
            if fold { model.setCollapsed(.group(.global, .permission), true) }
            model.focus = .item(3)
            try SnapshotRenderer.write(ImportClaudeSheet(model: model).environmentObject(store), size: CGSize(width: 760, height: 620),
                                       appearance: appearance, to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
    }
}
