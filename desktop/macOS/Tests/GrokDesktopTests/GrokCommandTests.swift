import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The `grok` command: the bundled launcher, the `/usr/local/bin` link, and its Settings switch.
/// Links go into temporary folders; nothing here touches `/usr/local/bin`.
@MainActor
final class GrokCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        // Folders made read-only for the password tests must be writable again to be removed.
        if let entries = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in entries { chmod(root.appendingPathComponent(path).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Launcher

    func testLauncherRunsTheBundledTUIThroughTheLinkWithSelfUpdatesOff() throws {
        let app = try makeApp()
        let link = root.appendingPathComponent("usr/local/bin/grok")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.appendingPathComponent(GrokCommand.launcherPath))

        let result = try run(link, ["--version", "two words"])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, "arg:--version\narg:two words\nautoupdater:1\n")
    }

    func testLauncherFollowsRelativeLinkChains() throws {
        let app = try makeApp()
        for folder in ["bin", "alias"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias/grok").path,
                                                   withDestinationPath: "../\(app.lastPathComponent)/\(GrokCommand.launcherPath)")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/grok").path, withDestinationPath: "../alias/grok")

        let result = try run(root.appendingPathComponent("bin/grok"), ["-p", "hello"])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, "arg:-p\narg:hello\nautoupdater:1\n")
    }

    func testLauncherLeavesUpdatesToTheApp() throws {
        let app = try makeApp()
        let result = try run(app.appendingPathComponent(GrokCommand.launcherPath), ["update", "--check"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.output, "", "the TUI must not run its own updater")
        XCTAssertTrue(result.errors.contains("updates with it"), result.errors)
    }

    func testLauncherExplainsAMissingTUI() throws {
        let app = try makeApp()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/crok"))
        let result = try run(app.appendingPathComponent(GrokCommand.launcherPath), [])
        XCTAssertEqual(result.status, 127)
        XCTAssertTrue(result.errors.contains("Reinstall Crok Desktop"), result.errors)
    }

    // MARK: Status

    func testStatusRecognisesEachKindOfLink() throws {
        let app = try makeApp()
        let launcher = try XCTUnwrap(GrokCommand.launcher(in: app))
        let link = root.appendingPathComponent("grok")
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .notInstalled)

        try relink(link, to: launcher.path)
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .installed)
        try relink(link, to: "\(app.lastPathComponent)/\(GrokCommand.launcherPath)")
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .installed, "a relative link to this app")

        let other = try makeApp(in: root.appendingPathComponent("Other", isDirectory: true))
        try relink(link, to: other.appendingPathComponent(GrokCommand.launcherPath).path)
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .otherCopy(app: other.path))

        let gone = root.appendingPathComponent("Gone.app")
        try relink(link, to: gone.appendingPathComponent(GrokCommand.launcherPath).path)
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .broken(app: gone.path))

        try relink(link, to: "/bin/echo")
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .taken(by: "/bin/echo", replaceable: true))

        try FileManager.default.removeItem(at: link)
        try Data("#!/bin/sh\n".utf8).write(to: link)
        XCTAssertEqual(GrokCommand.status(link: link, launcher: launcher), .taken(by: link.path, replaceable: false))
        XCTAssertFalse(GrokCommand.status(link: link, launcher: launcher).isOn)
    }

    func testOnlyAPackagedCopyOutsideADiskImageProvidesTheCommand() throws {
        XCTAssertNil(GrokCommand.launcher(in: root))
        XCTAssertEqual(GrokCommand.unavailableReason(bundle: root, launcher: nil), "Available in the packaged app.")
        let app = try makeApp()
        XCTAssertNil(GrokCommand.unavailableReason(bundle: app, launcher: GrokCommand.launcher(in: app)))
        let translocated = URL(fileURLWithPath: "/private/var/folders/zz/AppTranslocation/1F2E/d/Crok Desktop.app")
        let reason = GrokCommand.unavailableReason(bundle: translocated, launcher: translocated.appendingPathComponent(GrokCommand.launcherPath))
        XCTAssertTrue(reason?.contains("Applications folder") == true)
    }

    func testOtherInstallationsLeaveOutThisAppsCommand() throws {
        let app = try makeApp()
        let launcher = try XCTUnwrap(GrokCommand.launcher(in: app))
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in ["other/bin", ".local/bin"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let managed = home.appendingPathComponent(".local/bin/crok")
        try Data("#!/bin/sh\n".utf8).write(to: managed)
        chmod(managed.path, 0o755)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("other/bin/crok"), withDestinationURL: launcher)

        let others = GrokCommand.otherInstallations(home: home, excluding: [launcher])
        XCTAssertTrue(others.contains(managed.path))
        XCTAssertFalse(others.contains(home.appendingPathComponent("other/bin/crok").path))
    }

    // MARK: Switch

    func testWorkspaceTestBuildCannotChangeTheGlobalCommand() async throws {
        let app = try makeApp(testBuild: true)
        let link = root.appendingPathComponent("grok")
        let launcher = try XCTUnwrap(GrokCommand.launcher(in: app))
        try relink(link, to: launcher.path)
        let model = GrokCommandModel(link: link, bundle: app, home: root, privileged: { _, _ in XCTFail("a test build cannot request this") })

        XCTAssertTrue(model.isWorkspaceTestBuild)
        XCTAssertFalse(model.canToggle)
        XCTAssertEqual(model.status, .installed)
        XCTAssertEqual(model.unavailableReason, "This workspace test build stays out of the global Terminal command path.")

        await model.enable()
        await model.disable()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), launcher.path)
    }

    func testTurningTheCommandOnAndOffLinksAndUnlinks() async throws {
        let app = try makeApp()
        let link = root.appendingPathComponent("bin/grok")
        let model = GrokCommandModel(link: link, bundle: app, home: root, privileged: { _, _ in XCTFail("the folder is writable") })
        XCTAssertEqual(model.status, .notInstalled)
        XCTAssertTrue(model.canToggle)

        await model.enable()
        XCTAssertEqual(model.status, .installed)
        XCTAssertNil(model.error)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), app.appendingPathComponent(GrokCommand.launcherPath).path)
        XCTAssertEqual(try run(link, ["--help"]).output, "arg:--help\nautoupdater:1\n")

        await model.disable()
        XCTAssertEqual(model.status, .notInstalled)
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: link.path))
    }

    func testAnotherProgramsLinkIsReplacedOnlyWhenConfirmed() async throws {
        let app = try makeApp()
        let link = root.appendingPathComponent("grok")
        try relink(link, to: "/bin/echo")
        let model = GrokCommandModel(link: link, bundle: app, home: root, privileged: { _, _ in XCTFail("the folder is writable") })
        XCTAssertTrue(model.canToggle)

        await model.enable()
        XCTAssertEqual(model.status, .taken(by: "/bin/echo", replaceable: true), "replacing needs the user's confirmation")
        await model.enable(replacing: true)
        XCTAssertEqual(model.status, .installed)
    }

    func testAnInstalledProgramIsNeverReplaced() async throws {
        let app = try makeApp()
        let link = root.appendingPathComponent("grok")
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: link)
        let model = GrokCommandModel(link: link, bundle: app, home: root, privileged: { _, _ in XCTFail("nothing should be replaced") })
        XCTAssertFalse(model.canToggle)

        await model.enable(replacing: true)
        XCTAssertEqual(model.status, .taken(by: link.path, replaceable: false))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "#!/bin/sh\necho mine\n")
    }

    func testALinkToAMovedAppIsRepaired() async throws {
        let app = try makeApp()
        let link = root.appendingPathComponent("grok")
        let gone = root.appendingPathComponent("Gone.app")
        try relink(link, to: gone.appendingPathComponent(GrokCommand.launcherPath).path)
        let model = GrokCommandModel(link: link, bundle: app, home: root, privileged: { _, _ in XCTFail("the folder is writable") })
        XCTAssertEqual(model.status, .broken(app: gone.path))
        XCTAssertTrue(model.status.isOn)

        await model.enable()
        XCTAssertEqual(model.status, .installed)
    }

    func testAProtectedFolderAsksForAnAdministratorPassword() async throws {
        let app = try makeApp()
        let folder = root.appendingPathComponent("protected bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o555)
        let link = folder.appendingPathComponent("grok")
        let requests = PrivilegedRequests()
        let model = GrokCommandModel(link: link, bundle: app, home: root) { command, prompt in
            await requests.append(command, prompt)
            throw CancellationError()
        }

        await model.enable()
        let launcher = app.appendingPathComponent(GrokCommand.launcherPath).path
        let install = await requests.all.first
        XCTAssertEqual(install?.command, "/bin/mkdir -p '\(folder.path)' && /bin/ln -sfh '\(launcher)' '\(link.path)'")
        XCTAssertEqual(install?.prompt, "Crok Desktop wants to install the crok command in \(folder.path).")
        XCTAssertNil(model.error, "cancelling the password prompt is not an error")
        XCTAssertEqual(model.status, .notInstalled)
        XCTAssertFalse(model.isWorking)
    }

    func testRemovingFromAProtectedFolderOnlyRemovesALink() async throws {
        let app = try makeApp()
        let folder = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("grok")
        try relink(link, to: app.appendingPathComponent(GrokCommand.launcherPath).path)
        chmod(folder.path, 0o555)
        let requests = PrivilegedRequests()
        let model = GrokCommandModel(link: link, bundle: app, home: root) { command, prompt in
            await requests.append(command, prompt)
            throw DesktopError.message("Not allowed")
        }
        XCTAssertEqual(model.status, .installed)

        await model.disable()
        let removal = await requests.all.first
        XCTAssertEqual(removal?.command, "if [ -L '\(link.path)' ]; then /bin/rm -f '\(link.path)'; fi")
        XCTAssertEqual(model.error, "Not allowed")
        XCTAssertEqual(model.status, .installed)
    }

    func testCommandsSurviveShellAndAppleScriptQuoting() throws {
        let path = #"/Volumes/Grok's "Test" \ Apps/Crok Desktop.app"#
        XCTAssertEqual(try output("/bin/sh", ["-c", "printf %s \(GrokCommand.shellQuoted(path))"]), path)
        // The same round trip osascript makes before `do shell script` runs the command.
        let command = "/bin/ln -sfh \(GrokCommand.shellQuoted(path)) '/usr/local/bin/grok'"
        XCTAssertEqual(try output("/usr/bin/osascript", ["-e", "return \(GrokCommand.appleScriptString(command))"]), command + "\n")

        XCTAssertEqual(GrokCommand.administratorFailure("0:95: execution error: ln: /usr/local/bin/grok: Operation not permitted (1)\n"),
                       "ln: /usr/local/bin/grok: Operation not permitted")
        XCTAssertEqual(GrokCommand.administratorFailure(""), "The administrator command did not finish.")
    }

    func testOpeningTheAppClearsTheDownloadQuarantineFromItsCommand() throws {
        let app = try makeApp()
        let paths = [GrokCommand.launcherPath, "Contents/Resources/crok"].map { app.appendingPathComponent($0).path }
        let value = "0081;66f30000;Safari;"
        for path in paths { XCTAssertEqual(setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW), 0) }

        GrokCommand.clearQuarantine(bundle: app)
        for path in paths { XCTAssertEqual(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1, path) }
    }

    // MARK: Terminal panel

    func testTheTerminalPanelFindsTheBundledCommandAfterTheUsersOwn() {
        let directory = "/Applications/Crok Desktop.app/Contents/Resources/bin"
        let path = { (environment: [String]) in environment.first { $0.hasPrefix("PATH=") } }
        XCTAssertEqual(path(TerminalSessions.environment(shell: "/bin/zsh", commandDirectory: directory))?.hasSuffix(":" + directory), true)
        let inherited = ProcessInfo.processInfo.environment["PATH"].map { "PATH=" + $0 }
        XCTAssertEqual(path(TerminalSessions.environment(shell: "/bin/zsh", commandDirectory: nil)), inherited)
        let listed = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").first.map(String.init)
        XCTAssertEqual(path(TerminalSessions.environment(shell: "/bin/zsh", commandDirectory: listed)), inherited, "not added twice")
    }

    // MARK: Helpers

    /// A packaged app holding the real launcher and a TUI stand-in that reports how it was run.
    private func makeApp(in folder: URL? = nil, testBuild: Bool = false) throws -> URL {
        let app = (folder ?? root).appendingPathComponent("Crok Desktop.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: [GrokCommand.testBuildInfoKey: testBuild], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let harness = resources.appendingPathComponent("crok")
        let launcher = app.appendingPathComponent(GrokCommand.launcherPath)
        try Data("#!/bin/sh\nfor a in \"$@\"; do echo \"arg:$a\"; done\necho \"autoupdater:${CROK_DISABLE_AUTOUPDATER:-unset}\"\n".utf8).write(to: harness)
        try FileManager.default.copyItem(at: Self.launcherSource, to: launcher)
        for url in [harness, launcher] { chmod(url.path, 0o755) }
        return app
    }

    private static var launcherSource: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/crok-command.sh")
    }

    private func relink(_ link: URL, to destination: String) throws {
        if (try? FileManager.default.attributesOfItem(atPath: link.path)) != nil { try FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CROK_DISABLE_AUTOUPDATER")
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func output(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try run(URL(fileURLWithPath: executable), arguments)
        XCTAssertEqual(result.status, 0, result.errors)
        return result.output
    }
}

private actor PrivilegedRequests {
    struct Request: Sendable { let command: String; let prompt: String }
    private(set) var all: [Request] = []
    func append(_ command: String, _ prompt: String) { all.append(Request(command: command, prompt: prompt)) }
}

/// Writes PNGs of the `grok` command's Settings section when GROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class GrokCommandSnapshotTests: XCTestCase {
    func testRenderCommandLineSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-command-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Crok Desktop.app", isDirectory: true)
        let launcher = app.appendingPathComponent(GrokCommand.launcherPath)
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: launcher)
        chmod(launcher.path, 0o755)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok/bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: home.appendingPathComponent(".grok/bin/grok"))
        chmod(home.appendingPathComponent(".grok/bin/grok").path, 0o755)

        let states: [(String, String?)] = [("off", nil), ("on", launcher.path), ("taken", "/opt/tools/grok"), ("broken", "/Volumes/Old/Crok Desktop.app/\(GrokCommand.launcherPath)")]
        for (name, destination) in states {
            let link = root.appendingPathComponent("bin-\(name)/grok")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let destination { try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination) }
            let model = GrokCommandModel(link: link, bundle: app, home: home, privileged: { _, _ in })
            let view = CommandLineSettingsSection(command: model).padding(20).frame(width: 640).foregroundStyle(Theme.ink)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try SnapshotRenderer.write(view, size: CGSize(width: 640, height: 190), appearance: appearance,
                                           to: URL(fileURLWithPath: path).appendingPathComponent("settings-grok-command-\(name)-\(suffix).png"))
            }
        }
    }
}
