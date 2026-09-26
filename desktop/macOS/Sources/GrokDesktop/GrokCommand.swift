import AppKit
import Darwin
import SwiftUI

/// What `/usr/local/bin/crok` is, from this copy of the app's point of view.
enum GrokCommandStatus: Equatable {
    case notInstalled
    /// Links to this app's launcher.
    case installed
    /// Links to the launcher in another copy of Grok Desktop.
    case otherCopy(app: String)
    /// Links to a Grok Desktop launcher that no longer exists: that app was moved or deleted.
    case broken(app: String)
    /// Another program is installed as `crok`. Only a symlink is replaced, and only when the user agrees.
    case taken(by: String, replaceable: Bool)

    /// The command is Grok Desktop's, so turning it off removes the link.
    var isOn: Bool {
        switch self {
        case .installed, .otherCopy, .broken: return true
        case .notInstalled, .taken: return false
        }
    }
}

/// The `crok` command: a symlink at `/usr/local/bin/crok`, on every Mac's default PATH, to the launcher
/// bundled as `Contents/Resources/bin/crok`, which runs the app's copy of the Grok Build TUI.
enum GrokCommand {
    static let defaultLink = URL(fileURLWithPath: "/usr/local/bin/crok")
    static let launcherPath = "Contents/Resources/bin/crok"
    static let testBuildInfoKey = "GrokDesktopTestBuild"
    private static let harnessPath = "Contents/Resources/crok"

    /// Runs a shell command as root, after macOS asks for an administrator password with `prompt`.
    typealias PrivilegedRunner = @Sendable (_ command: String, _ prompt: String) async throws -> Void

    /// The app's launcher, when the app is packaged.
    static func launcher(in bundle: URL = Bundle.main.bundleURL) -> URL? {
        let url = bundle.appendingPathComponent(launcherPath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The folder holding the launcher, which the terminal panel adds to PATH.
    static var bundledCommandDirectory: String? { launcher()?.deletingLastPathComponent().path }

    static func isWorkspaceTestBuild(in bundle: URL) -> Bool {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any]
        else { return false }
        return plist[testBuildInfoKey] as? Bool == true
    }

    static func status(link: URL, launcher: URL?) -> GrokCommandStatus {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: link.path) else { return .notInstalled }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return .taken(by: link.path, replaceable: false)
        }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        if let launcher, target.resolvingSymlinksInPath().path == launcher.resolvingSymlinksInPath().path { return .installed }
        guard target.path.hasSuffix(".app/" + launcherPath) else { return .taken(by: target.path, replaceable: true) }
        let app = String(target.path.dropLast(launcherPath.count + 1))
        return fileManager.isExecutableFile(atPath: target.path) ? .otherCopy(app: app) : .broken(app: app)
    }

    /// Why this copy of the app cannot provide the command, if it cannot. A link into a disk image or a
    /// translocated copy would stop working once that copy goes away.
    static func unavailableReason(bundle: URL, launcher: URL?, workspaceTestBuild: Bool? = nil) -> String? {
        if workspaceTestBuild ?? isWorkspaceTestBuild(in: bundle) {
            return "This workspace test build stays out of the global Terminal command path."
        }
        guard launcher != nil else { return "Available in the packaged app." }
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if readOnly || bundle.path.contains("/AppTranslocation/") {
            return "Move Crok Desktop to your Applications folder and open it from there to turn this on."
        }
        return nil
    }

    /// Other `crok` commands a terminal may find first, depending on PATH order.
    static func otherInstallations(home: URL, excluding excluded: [URL]) -> [String] {
        let excludedPaths = Set(excluded.map { $0.resolvingSymlinksInPath().path })
        return [home.appendingPathComponent(".local/bin/crok").path, "/opt/homebrew/bin/crok"]
            .filter { path in
                FileManager.default.isExecutableFile(atPath: path)
                    && !excludedPaths.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
    }

    /// Points `link` at `launcher`, asking for an administrator password only when its folder is not writable.
    static func install(launcher: URL, link: URL, privileged: PrivilegedRunner) async throws {
        do {
            try linkDirectly(launcher: launcher, link: link)
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            let directory = link.deletingLastPathComponent().path
            try await privileged("/bin/mkdir -p \(shellQuoted(directory)) && /bin/ln -sfh \(shellQuoted(launcher.path)) \(shellQuoted(link.path))",
                                 "Crok Desktop wants to install the crok command in \(directory).")
        }
    }

    /// Removes the link, which must be Grok Desktop's.
    static func uninstall(link: URL, privileged: PrivilegedRunner) async throws {
        guard unlink(link.path) != 0 else { return }
        let code = errno
        if code == ENOENT { return }
        guard code == EACCES || code == EPERM else { throw posixError(code) }
        try await privileged("if [ -L \(shellQuoted(link.path)) ]; then /bin/rm -f \(shellQuoted(link.path)); fi",
                             "Crok Desktop wants to remove the crok command from \(link.deletingLastPathComponent().path).")
    }

    /// Clears the download quarantine from the launcher and the TUI it runs. Opening the app approved it;
    /// a terminal runs the command outside the app, where Gatekeeper would judge it as a separate download.
    static func clearQuarantine(bundle: URL = Bundle.main.bundleURL) {
        for path in [launcherPath, harnessPath] {
            removexattr(bundle.appendingPathComponent(path).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static let runAsAdministrator: PrivilegedRunner = { command, prompt in
        let script = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let (status, errors) = try await osascript(script)
        guard status != 0 else { return }
        if errors.contains("(-128)") { throw CancellationError() }
        throw DesktopError.message(administratorFailure(errors))
    }

    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// osascript reports `0:95: execution error: <message> (<code>)`; the message is what the user needs.
    static func administratorFailure(_ errors: String) -> String {
        var message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: #"^\d+:\d+: execution error: "#, options: .regularExpression) { message.removeSubrange(range) }
        if let range = message.range(of: #"\s*\(-?\d+\)$"#, options: .regularExpression) { message.removeSubrange(range) }
        return message.isEmpty ? "The administrator command did not finish." : message
    }

    /// Replaces `link` atomically, so a working command is never briefly missing.
    private static func linkDirectly(launcher: URL, link: URL) throws {
        let directory = link.deletingLastPathComponent().path
        if access(directory, F_OK) != 0, mkdir(directory, 0o755) != 0 { throw posixError(errno) }
        let temporary = directory + "/.grok-\(UUID().uuidString)"
        guard symlink(launcher.path, temporary) == 0 else { throw posixError(errno) }
        guard rename(temporary, link.path) == 0 else {
            let code = errno
            unlink(temporary)
            throw posixError(code)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

    private static func osascript(_ script: String) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// The `grok` command's switch in Settings.
@MainActor
final class GrokCommandModel: ObservableObject {
    @Published private(set) var status: GrokCommandStatus = .notInstalled
    @Published private(set) var otherInstallations: [String] = []
    @Published private(set) var isWorking = false
    @Published var error: String?
    let link: URL
    let launcher: URL?
    let unavailableReason: String?
    let isWorkspaceTestBuild: Bool
    private let home: URL
    private let privileged: GrokCommand.PrivilegedRunner

    init(link: URL = GrokCommand.defaultLink, bundle: URL = Bundle.main.bundleURL,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         privileged: @escaping GrokCommand.PrivilegedRunner = GrokCommand.runAsAdministrator) {
        self.link = link
        self.home = home
        self.privileged = privileged
        launcher = GrokCommand.launcher(in: bundle)
        let workspaceTestBuild = GrokCommand.isWorkspaceTestBuild(in: bundle)
        isWorkspaceTestBuild = workspaceTestBuild
        unavailableReason = GrokCommand.unavailableReason(bundle: bundle, launcher: launcher, workspaceTestBuild: workspaceTestBuild)
        refresh()
    }

    var canToggle: Bool {
        guard !isWorking, !isWorkspaceTestBuild else { return false }
        if status.isOn { return true }
        if case .taken(_, false) = status { return false }
        return unavailableReason == nil
    }

    func refresh() {
        status = GrokCommand.status(link: link, launcher: launcher)
        otherInstallations = GrokCommand.otherInstallations(home: home, excluding: [link] + (launcher.map { [$0] } ?? []))
    }

    /// Links the command to this app. Another program's symlink is replaced only with `replacing`.
    func enable(replacing: Bool = false) async {
        refresh()
        guard let launcher, unavailableReason == nil, !isWorking, !isWorkspaceTestBuild else { return }
        switch status {
        case .installed: return
        case .taken(_, let replaceable) where !replaceable || !replacing: return
        default: break
        }
        await perform { try await GrokCommand.install(launcher: launcher, link: self.link, privileged: self.privileged) }
    }

    func disable() async {
        refresh()
        guard status.isOn, !isWorking, !isWorkspaceTestBuild else { return }
        await perform { try await GrokCommand.uninstall(link: self.link, privileged: self.privileged) }
    }

    private func perform(_ change: () async throws -> Void) async {
        isWorking = true
        error = nil
        do { try await change() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
        isWorking = false
        refresh()
    }
}

/// Settings for the `grok` command, which runs the Grok Build TUI bundled with the app from any terminal.
struct CommandLineSettingsSection: View {
    @StateObject private var command: GrokCommandModel
    @State private var confirmingReplace = false

    init(command: GrokCommandModel? = nil) {
        _command = StateObject(wrappedValue: command ?? GrokCommandModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Command line", systemImage: "terminal").font(.system(size: 15, weight: .semibold))
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    (Text("crok").font(.system(size: 14, weight: .semibold, design: .monospaced))
                        + Text(" command in Terminal").font(.system(size: 14, weight: .medium)))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if command.status.isOn, !command.otherInstallations.isEmpty {
                        Text("Also installed: \(command.otherInstallations.map(Self.abbreviated).joined(separator: ", ")). Terminals run whichever comes first in PATH.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = command.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(ComposerPalette.warning)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let repair = repairTitle {
                        Button(repair) { Task { await command.enable() } }
                            .buttonStyle(.bordered).controlSize(.regular).disabled(command.isWorking).padding(.top, 4)
                    }
                }
                Spacer(minLength: 12)
                if command.isWorking { ProgressView().controlSize(.small) }
                Toggle("crok command in Terminal", isOn: Binding(get: { command.status.isOn }, set: setEnabled))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(!command.canToggle)
            }
        }
        .settingsCard()
        .onAppear { command.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in command.refresh() }
        .alert("Replace the existing crok command?", isPresented: $confirmingReplace) {
            Button("Replace") { Task { await command.enable(replacing: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceMessage)
        }
    }

    private var replaceMessage: String {
        guard case .taken(let target, _) = command.status else { return "" }
        let current = Self.abbreviated(target)
        return "\(command.link.path) runs \(current). The link will run Crok Desktop's Crok Build instead; \(current) itself is not changed."
    }

    private var detail: String {
        switch command.status {
        case .installed:
            return "Terminals run this app's Crok Build TUI with crok, linked at \(command.link.path)."
        case .otherCopy(let app):
            return "crok runs the Crok Desktop at \(Self.abbreviated(app))."
        case .broken(let app):
            return "crok links to a Crok Desktop that was moved or deleted (\(Self.abbreviated(app)))."
        case .taken(let target, true):
            return command.unavailableReason ?? "\(command.link.path) runs \(Self.abbreviated(target)). Turning this on replaces the link."
        case .taken:
            return "Another program is installed at \(command.link.path). Remove it to turn this on."
        case .notInstalled:
            return command.unavailableReason ?? "Type crok in any terminal to run the Crok Build TUI that comes with this app."
        }
    }

    /// Relinks a command that runs another or a missing copy of the app.
    private var repairTitle: String? {
        guard command.unavailableReason == nil else { return nil }
        switch command.status {
        case .otherCopy: return "Use This Copy"
        case .broken: return "Repair"
        default: return nil
        }
    }

    private func setEnabled(_ enabled: Bool) {
        if !enabled { Task { await command.disable() }; return }
        if case .taken(_, true) = command.status { confirmingReplace = true; return }
        Task { await command.enable() }
    }

    private static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
