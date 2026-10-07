import XCTest
@testable import GrokDesktop

/// An offline harness for the extension panels: the shared mock plus the memory, marketplace,
/// plugins, hooks, skills-config, workflows, and session-info methods, all recorded to disk.
/// CROK_HOME and HOME point into the fixture directory for the fixture's lifetime.
@MainActor
final class ExtensionHarnessFixture {
    let directory: URL
    let grokHome: URL
    let userHome: URL
    let project: URL
    let defaultsName = "GrokDesktopExtensions.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: AppStore
    private let savedEnvironment: [String: String?]

    init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-extension-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        grokHome = directory.appendingPathComponent("grok-home", isDirectory: true)
        userHome = directory.appendingPathComponent("home", isDirectory: true)
        project = directory.appendingPathComponent("project", isDirectory: true)
        for folder in [grokHome, userHome, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        savedEnvironment = ["CROK_HOME": ProcessInfo.processInfo.environment["CROK_HOME"], "HOME": ProcessInfo.processInfo.environment["HOME"]]
        setenv("CROK_HOME", grokHome.path, 1)
        setenv("HOME", userHome.path, 1)
        defaults = UserDefaults(suiteName: defaultsName)!
        try Self.writeMemoryFiles(root: directory.appendingPathComponent("memory-store"))

        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).components(separatedBy: "if __name__ == \"__main__\":")[0]
            .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let executable = directory.appendingPathComponent("fixture-grok")
        try (source + Self.extensionHarness).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: executable.path)
        let item = Project(path: project.path)
        store.state = DesktopState(projects: [item], selectedProjectID: item.id)
    }

    var memoryRoot: URL { directory.appendingPathComponent("memory-store") }

    var requests: [[String: Any]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
        return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    func params(for method: String) -> [[String: Any]] {
        requests.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }

    var prompts: [[String: Any]] { params(for: "session/prompt") }

    func cleanup() {
        store.shutdown()
        defaults.removePersistentDomain(forName: defaultsName)
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    static func writeMemoryFiles(root: URL) throws {
        let files: [(String, String)] = [
            ("memory-v2/global/MEMORY.md", "# Global memory index\n\n- [Coding style](topics/coding-style.md)\n"),
            ("memory-v2/global/topics/coding-style.md", "## Coding style\n\n- Prefer `rg` over `grep` for searching.\n- Keep functions short and name them after what they return.\n- Swift: no force unwraps on external data.\n"),
            ("memory-v2/global/observations/_inbox/remember-a1B2c3.md", "## Release notes go in CHANGELOG.md\n\nEvery user-visible change gets a line under **Unreleased**."),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/topics/build-and-test.md", "## Build and test\n\nRun `swift build` and `swift test` from `desktop/macOS`.\n\n| Step | Command |\n|---|---|\n| Build | `swift build` |\n| Test | `swift test` |\n"),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/observations/_inbox/s1__t000038-000040__n001.md", "## Snapshot tests\n\nRender with SnapshotRenderer and check light and dark."),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/observations/_inbox/changed.md", "## Stale\n\nThis note changes before it is deleted."),
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let extensionHarness = #"""
import time

class ExtensionHarness(MockHarness):
    def __init__(self):
        super().__init__()
        self.base = os.path.dirname(os.path.abspath(__file__))
        self.memory_root = os.path.join(self.base, "memory-store")
        self.memory_on = True
        self.memory_reason = None
        self.trusted = False
        self.skill_paths = ["/fixture/custom-skills"]
        self.disabled_hooks = {"project/.grok/hooks:post_tool_use[0].hooks[0]"}
        self.plugin_state = {"user/1a2b3c4d/code-review": True, "project/5e6f7a8b/team-lint": True, "user/9c0d1e2f/legacy-helper": False}
        self.installed = {"plugins/code-review": "installed", "plugins/release-notes": "update_available", "plugins/pdf-tools": "not_installed"}
        self.sources = [("grok-official", "git", "https://github.com/xai-org/grok-plugins"), ("team-tools", "local", "/Users/team/marketplace")]

    def log(self, message):
        with open(os.path.join(self.base, "requests.jsonl"), "a") as log:
            log.write(json.dumps(message) + "\n")

    def memory_files(self):
        entries = [
            ("memory-v2/global/MEMORY.md", "global", True, None, 3600),
            ("memory-v2/global/topics/coding-style.md", "global", False, None, 86400 * 3),
            ("memory-v2/global/observations/_inbox/remember-a1B2c3.md", "global", False, "Release notes go in CHANGELOG.md", 7200),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/topics/build-and-test.md", "workspace", False, None, 1800),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/observations/_inbox/s1__t000038-000040__n001.md", "workspace", False, None, 300),
            ("memory-v2/workspaces/grok-desktop-1a2b3c4d/observations/_inbox/changed.md", "workspace", False, "Stale note", 30),
        ]
        files = []
        now = int(time.time())
        for rel, source, generated, title, age in entries:
            path = os.path.join(self.memory_root, rel)
            if not os.path.exists(path):
                continue
            item = {"path": path, "source": source, "size_bytes": os.path.getsize(path), "modified_epoch_secs": now - age}
            if generated:
                item["generated"] = True
            if title:
                item["title"] = title
            files.append(item)
        return files

    def listing(self):
        value = {"files": self.memory_files() if self.memory_on else [], "enabled": self.memory_on, "capture_enabled": True, "dream_enabled": True}
        if self.memory_reason:
            value["disabled_reason"] = self.memory_reason
        return value

    def outcome(self, status, message, reload=False):
        return {"result": {"status": status, "message": message, "requiresReload": reload, "requiresRestart": False}, "error": None}

    def marketplace(self):
        catalog = {
            "grok-official": [
                {"name": "code-review", "version": "1.4.0", "description": "Review pull requests with structured, line-level feedback.", "category": "Quality", "author": "xAI",
                 "relativePath": "plugins/code-review", "skillCount": 2, "hasHooks": True, "hasAgents": True, "hasMcp": False,
                 "components": {"skills": [{"name": "review"}, {"name": "triage"}], "agents": [{"name": "reviewer"}], "hooks": [{"name": "PreToolUse"}]}},
                {"name": "release-notes", "version": "2.1.0", "description": "Draft release notes from merged changes.", "category": "Writing",
                 "relativePath": "plugins/release-notes", "skillCount": 1, "hasHooks": False, "hasAgents": False, "hasMcp": False},
                {"name": "pdf-tools", "version": "0.9.2", "description": "Read, split, and fill PDF forms.", "author": "Community",
                 "relativePath": "plugins/pdf-tools", "skillCount": 3, "hasHooks": False, "hasAgents": False, "hasMcp": True},
            ],
            "team-tools": [],
        }
        sources = []
        for name, kind, url in self.sources:
            plugins = []
            for plugin in catalog.get(name, []):
                status = self.installed.get(plugin["relativePath"], "not_installed")
                entry = dict(plugin, installStatus=status)
                if status != "not_installed":
                    entry["installedVersion"] = "2.0.3" if status == "update_available" else plugin["version"]
                plugins.append(entry)
            source = {"sourceName": name, "sourceKind": kind, "sourceUrlOrPath": url, "plugins": plugins, "error": None}
            if name == "team-tools":
                source["error"] = "marketplace.json not found in /Users/team/marketplace"
            sources.append(source)
        return sources

    def plugins(self):
        return [
            {"name": "code-review", "id": "user/1a2b3c4d/code-review", "root": "/fixture/grok-home/installed-plugins/code-review", "scope": "user", "trusted": True,
             "enabled": self.plugin_state["user/1a2b3c4d/code-review"], "version": "1.4.0", "description": "Review pull requests with structured, line-level feedback.",
             "skillCount": 2, "skillNames": ["review", "triage"], "agentCount": 1, "agentNames": ["reviewer"], "hookStatus": "active", "hookCount": 1,
             "mcpServerCount": 0, "mcpStatus": "none", "marketplaceSource": "grok-official", "origin": {"type": "marketplace_install", "source_name": "grok-official"}},
            {"name": "team-lint", "id": "project/5e6f7a8b/team-lint", "root": "/fixture/project/.grok/plugins/team-lint", "scope": "project", "trusted": True,
             "enabled": self.plugin_state["project/5e6f7a8b/team-lint"], "version": "0.3.0", "description": "Lint rules shared by the team.",
             "skillCount": 1, "agentCount": 0, "hookStatus": "blocked", "hookCount": 2, "mcpServerCount": 1, "mcpStatus": "active", "origin": {"type": "project_grok"}},
            {"name": "legacy-helper", "id": "user/9c0d1e2f/legacy-helper", "root": "/fixture/home/.grok/plugins/legacy-helper", "scope": "user", "trusted": True,
             "enabled": self.plugin_state["user/9c0d1e2f/legacy-helper"], "description": "Helpers from an older setup.", "skillCount": 0, "agentCount": 0,
             "hookStatus": "none", "hookCount": 0, "mcpServerCount": 0, "mcpStatus": "none", "origin": {"type": "user_grok"},
             "conflict": "Shadows another plugin named legacy-helper in ~/.claude/plugins."},
        ]

    def hooks(self):
        home = os.environ.get("CROK_HOME", "")
        rows = [
            {"name": "global/safety:pre_tool_use[0].hooks[0]", "event": "pre_tool_use", "handlerType": "command", "matcher": "Bash", "command": home + "/hooks/safety/check-command.sh", "url": None, "timeoutMs": 5000, "sourceDir": home + "/hooks", "removable": False, "pinned": False},
            {"name": "global/safety:session_start[0].hooks[0]", "event": "session_start", "handlerType": "http", "matcher": None, "command": None, "url": "https://hooks.example.com/session", "timeoutMs": 2000, "sourceDir": home + "/hooks", "removable": False, "pinned": True},
            {"name": "project/.grok/hooks:post_tool_use[0].hooks[0]", "event": "post_tool_use", "handlerType": "command", "matcher": "Edit|Write", "command": "swift-format --in-place $FILE", "url": None, "timeoutMs": 10000, "sourceDir": self.base + "/project/.grok/hooks", "removable": False, "pinned": False},
            {"name": "custom/notify:stop[0].hooks[0]", "event": "stop", "handlerType": "command", "matcher": None, "command": "osascript -e 'display notification \"Done\"'", "url": None, "timeoutMs": 3000, "sourceDir": home + "/extra-hooks/notify", "removable": True, "pinned": False},
        ]
        for row in rows:
            row["disabled"] = row["name"] in self.disabled_hooks
        return rows

    def handle(self, message):
        self.log(message)
        method = message.get("method")
        rid = message.get("id")
        params = message.get("params", {})
        if method == "_x.ai/memory/list":
            if params.get("sessionId") not in self.sessions:
                self.error(rid, -32602, "Invalid params")
                return
            self.result(rid, self.listing())
        elif method == "_x.ai/memory/toggle":
            self.memory_on = bool(params.get("enabled"))
            self.memory_reason = None if self.memory_on else "session_toggle"
            response = {"message": "Memory enabled for this session." if self.memory_on else "Memory disabled for this session.", "enabled": self.memory_on, "listing": self.listing()}
            if self.memory_reason:
                response["disabled_reason"] = self.memory_reason
            self.result(rid, response)
        elif method == "_x.ai/memory/forget":
            path = params.get("path", "")
            if params.get("sessionId") not in self.sessions or not params.get("expectedContentHash"):
                self.error(rid, -32602, "Invalid params")
            elif path.endswith("changed.md"):
                self.result(rid, {"outcome": "rejected", "reason": "changed", "message": "This note changed since you opened it."})
            elif os.path.exists(path):
                os.remove(path)
                self.result(rid, {"outcome": "forgotten", "was_already_forgotten": False})
            else:
                self.result(rid, {"outcome": "rejected", "reason": "not_deletable", "message": "This file can't be deleted."})
        elif method == "_x.ai/memory/flush":
            if params.get("session_id") not in self.sessions:
                self.error(rid, -32602, "Invalid params")
                return
            self.result(rid, {"flushed": True, "disposition": "flushed", "through_turn": 3})
        elif method == "_x.ai/memory/dream":
            if params.get("session_id") not in self.sessions:
                self.error(rid, -32602, "Invalid params")
                return
            self.result(rid, {"disposition": "completed", "observation_count": 4, "topics_affected": 2})
        elif method == "_x.ai/memory/rewrite":
            if params.get("sessionId") not in self.sessions or "rawText" not in params or "contextSummary" not in params:
                self.error(rid, -32602, "Invalid params")
                return
            self.result(rid, {"rewritten": "## Enhanced note\n\n" + params["rawText"]})
        elif method == "_x.ai/session/info":
            self.result(rid, {"result": {"sessionId": params.get("sessionId"), "cwd": os.getcwd(), "agentName": "grok-build", "turns": 1, "turnIndex": 0, "context": {}}, "error": None})
        elif method == "_x.ai/marketplace/list":
            self.result(rid, {"result": {"sources": self.marketplace()}, "error": None})
        elif method == "_x.ai/marketplace/action":
            action = params.get("action", {})
            kind = action.get("type")
            if params.get("sessionId") not in self.sessions:
                self.error(rid, -32602, "Invalid params")
            elif kind in ("install", "update", "uninstall"):
                path = action.get("plugin_relative_path")
                if not action.get("source_url_or_path") or not path:
                    self.result(rid, self.outcome("validation_error", "Source and plugin path are required."))
                    return
                if kind == "uninstall" and path == "plugins/code-review" and not action.get("confirmed"):
                    self.result(rid, self.outcome("confirmation_required", "code-review provides hooks used by this project. Uninstall anyway?"))
                    return
                self.installed[path] = "not_installed" if kind == "uninstall" else "installed"
                verb = {"install": "Installed", "update": "Updated", "uninstall": "Uninstalled"}[kind]
                self.result(rid, self.outcome("success", verb + " " + path, reload=kind == "install"))
            elif kind == "add_source":
                self.sources.append(("added", "git", action.get("url", "")))
                self.result(rid, self.outcome("success", "Added marketplace source " + action.get("url", "")))
            elif kind == "remove_source":
                self.sources = [s for s in self.sources if s[2] != action.get("source_url_or_path")]
                self.result(rid, self.outcome("success", "Removed marketplace source"))
            elif kind == "refresh":
                self.result(rid, self.outcome("success", "Refreshed 2 source(s)."))
            else:
                self.result(rid, self.outcome("unsupported", "Unknown action"))
        elif method == "_x.ai/plugins/notify-updates":
            self.result(rid, {"result": {"ok": True}, "error": None})
        elif method == "_x.ai/plugins/list":
            self.result(rid, {"result": {"plugins": self.plugins()}, "error": None})
        elif method == "_x.ai/plugins/action":
            action = params.get("action", {})
            kind = action.get("type")
            if kind == "uninstall" and not action.get("confirmed"):
                self.result(rid, self.outcome("confirmation_required", 'Repo "code-review" contains 2 plugin(s): code-review, triage. Uninstalling will remove all of them.'))
            elif kind == "uninstall":
                self.result(rid, self.outcome("success", 'Uninstalled repo "code-review" (2 plugin(s): code-review, triage)', reload=True))
            elif kind in ("enable", "disable"):
                self.plugin_state[action["plugin_id"]] = kind == "enable"
                self.result(rid, self.outcome("success", ("Enabled " if kind == "enable" else "Disabled ") + action["plugin_id"]))
            elif kind == "update":
                self.result(rid, self.outcome("success", "code-review: already up to date"))
            elif kind == "install":
                self.result(rid, self.outcome("success", "Installed 1 plugin(s) from " + action.get("source", ""), reload=True))
            else:
                self.result(rid, self.outcome("success", "Reloaded plugins."))
        elif method == "_x.ai/hooks/list":
            self.result(rid, {"result": {"hooks": self.hooks(), "projectTrusted": self.trusted, "loadErrors": ["/fixture/project/.grok/hooks/broken.json: expected value at line 1 column 1"]}, "error": None})
        elif method == "_x.ai/hooks/action":
            action = params.get("action", {})
            kind = action.get("type")
            if kind == "trust":
                self.trusted = True
            elif kind == "toggle_source":
                for name in action.get("hook_names", []):
                    if action.get("disable"):
                        self.disabled_hooks.add(name)
                    else:
                        self.disabled_hooks.discard(name)
            self.result(rid, self.outcome("success", "Hooks updated."))
        elif method == "_x.ai/skills/config":
            message = "Skill discovery sources:\n  • " + os.getcwd() + "/.grok/skills  (1 skill)\n  • ~/.grok/skills  (3 skills)\n\nCustom paths:\n  • /fixture/custom-skills  (0 skills)\n\nTotal skills loaded: 2"
            self.result(rid, {"result": {"paths": self.skill_paths, "ignore": ["/fixture/old-skills"], "totalSkills": len(self.skills()), "message": message, "skills": self.skills()}, "error": None})
        elif method == "_x.ai/skills/remove":
            self.skill_paths = [p for p in self.skill_paths if p != params.get("path")]
            self.result(rid, {"result": {"path": params.get("path"), "skills": self.skills(), "message": "Removed path " + params.get("path", "") + ". 2 skills remaining."}, "error": None})
        elif method == "_x.ai/skills/reset":
            self.skill_paths = []
            self.result(rid, {"result": {"skills": self.skills(), "message": "Custom skills config reset"}, "error": None})
        elif method == "_x.ai/workflows/list":
            self.result(rid, {"result": {"workflows": [
                {"name": "fix-ci", "description": "Fix failing CI on the current PR", "when_to_use": "A pull request has red checks and you want Crok to diagnose and fix them.", "source": "project", "path": os.getcwd() + "/.grok/workflows/fix-ci.md"},
                {"name": "ship-release", "description": "Cut a release branch, bump versions, and draft notes", "source": "user", "path": "/fixture/home/.grok/workflows/ship-release.md"},
            ]}, "error": None})
        else:
            super().handle(message)

ExtensionHarness().run()
"""#
}
