import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Renders the Git Graph window, the composer's branch footer, and the branch picker for a
/// fixture repository with several branches, merges, tags, and authors, when
/// CROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class GitGraphSnapshotTests: XCTestCase {
    private var directory: URL!
    private var repository: URL!
    private var store: AppStore!
    private var defaultsName = ""

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] != nil else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-git-graph-snapshots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        repository = directory.appendingPathComponent("aurora", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try makeHistory()
        defaultsName = "GrokDesktopGitGraph.\(UUID().uuidString)"
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: UserDefaults(suiteName: defaultsName)!, binaryPath: "/usr/bin/false")
        let project = Project(path: repository.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        await store.refreshWorkspace()
    }

    override func tearDown() async throws {
        store?.features.gitGraph.windowDisappeared()
        store?.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRenderGitGraphWindowFooterAndBranchPicker() async throws {
        let model = store.features.gitGraph
        try await render("git-graph", GitGraphWindow(), size: CGSize(width: 1280, height: 820)) {
            guard model.phase == .loaded else { return false }
            if let merge = model.entries.first(where: { $0.commit.subject == "Merge branch 'feature/login'" }), model.selectedID != merge.id {
                model.select(merge.id)
                return false
            }
            if model.selectedFile == nil, let file = model.files.first(where: { $0.path.hasSuffix("login.swift") }) {
                model.selectFile(file.path)
                return false
            }
            return model.selectedFile != nil && model.diffText.contains("@@")
        }
        XCTAssertEqual(model.graph?.currentBranch, "main")
        XCTAssertGreaterThanOrEqual(model.graph?.laneCount ?? 0, 3)
        XCTAssertTrue(model.entries.first?.commit.isUncommitted == true)

        model.query = "login"
        try await render("git-graph-search", GitGraphWindow(), size: CGSize(width: 1280, height: 820)) { !model.matches.isEmpty }
        XCTAssertFalse(model.matches.isEmpty)
        model.query = ""

        try await render("composer-footer", ComposerGitFooter().padding(.horizontal, 20).frame(width: 620, alignment: .leading), size: CGSize(width: 620, height: 44))
        try await render("branch-picker", BranchPickerPopover(isPresented: .constant(true)), size: CGSize(width: 420, height: 470))
    }

    /// Hosts the view, waits until `settle` holds, then draws it in light and dark.
    private func render<V: View>(_ name: String, _ view: V, size: CGSize, settle: @escaping () -> Bool = { true }) async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] ?? "")
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.desktopEnvironment(store).background(Theme.canvas))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let warmup = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: warmup) }
            let deadline = Date().addingTimeInterval(8)
            try await Task.sleep(nanoseconds: 300_000_000)
            while !settle() && Date() < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
            window.contentView = nil
        }
    }

    // MARK: Fixture

    /// Each commit lands about a day after the one before, so the dates read like real history.
    private var clock = Date(timeIntervalSinceNow: -18 * 86_400)
    private var author = ("Ada Lovelace", "ada@example.invalid")

    private func makeHistory() throws {
        try git(["init", "-b", "main"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "tag.gpgsign", "false"])
        try git(["remote", "add", "origin", "https://example.invalid/aurora.git"])
        let ada = ("Ada Lovelace", "ada@example.invalid"), grace = ("Grace Hopper", "grace@example.invalid")
        let linus = ("Linus Torvalds", "linus@example.invalid"), margaret = ("Margaret Hamilton", "margaret@example.invalid")

        author = ada
        try commit("README.md", "# Aurora\n", "Initial commit")
        try commit("Package.swift", "// swift-tools-version: 5.9\n", "Add Swift package manifest")
        try git(["switch", "-q", "-c", "feature/login"])
        author = grace
        try commit("Sources/Auth/login.swift", "struct Login {}\n", "Add login screen skeleton")
        try git(["switch", "-q", "-c", "fix/typo", "main"])
        author = linus
        try commit("README.md", "# Aurora\n\nA tiny weather app.\n", "Fix typo in README")
        try git(["switch", "-q", "main"])
        author = ada
        try commit(".github/ci.yml", "name: CI\n", "Configure CI")
        try merge("fix/typo", "Merge branch 'fix/typo'")
        try git(["switch", "-q", "feature/login"])
        author = grace
        try commit("Sources/Auth/login.swift", "struct Login {\n    var user = \"\"\n    var password = \"\"\n}\n", "Validate credentials before submit")
        try commit("Sources/Auth/session.swift", "final class Session {}\n", "Keep the session in the keychain\n\nTokens no longer live in UserDefaults.")
        try git(["update-ref", "refs/remotes/origin/feature/login", "HEAD"])
        try git(["switch", "-q", "main"])
        author = margaret
        try commit("Sources/App/forecast.swift", "struct Forecast {}\n", "Show a seven-day forecast")
        try merge("feature/login", "Merge branch 'feature/login'")
        try git(["tag", "-a", "v1.0.0", "-m", "Aurora 1.0"])
        try git(["switch", "-q", "-c", "experiment/radar"])
        author = linus
        try commit("Sources/App/radar.swift", "struct Radar {}\n", "Prototype the rain radar")
        try commit("Sources/App/radar.swift", "struct Radar { var frames = 12 }\n", "Animate radar frames")
        try git(["switch", "-q", "main"])
        author = ada
        try commit("Sources/App/forecast.swift", "struct Forecast { var days = 7 }\n", "Cache forecasts for an hour")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try git(["switch", "-q", "-c", "release/1.1"])
        author = margaret
        try commit("CHANGELOG.md", "## 1.1\n- Radar\n", "Prepare the 1.1 changelog")
        try git(["tag", "v1.1.0-rc1"])
        try git(["switch", "-q", "main"])
        author = grace
        try commit("Sources/App/settings.swift", "struct Settings {}\n", "Add a settings screen")
        try write("struct Settings { var units = \"metric\" }\n", to: "Sources/App/settings.swift")
        try write("notes\n", to: "NOTES.md")
    }

    private func commit(_ file: String, _ contents: String, _ message: String) throws {
        try write(contents, to: file)
        try git(["add", file])
        clock = clock.addingTimeInterval(86_400 + 2_600)
        try git(["commit", "-q", "-m", message])
    }

    private func merge(_ branch: String, _ message: String) throws {
        clock = clock.addingTimeInterval(3 * 3_600)
        try git(["merge", "-q", "--no-ff", branch, "-m", message])
    }

    private func write(_ value: String, to file: String) throws {
        let url = repository.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    private func git(_ arguments: [String]) throws {
        let stamp = "\(Int(clock.timeIntervalSince1970)) +0000"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = author.0; environment["GIT_AUTHOR_EMAIL"] = author.1
        environment["GIT_COMMITTER_NAME"] = author.0; environment["GIT_COMMITTER_EMAIL"] = author.1
        environment["GIT_AUTHOR_DATE"] = stamp; environment["GIT_COMMITTER_DATE"] = stamp
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }
}
