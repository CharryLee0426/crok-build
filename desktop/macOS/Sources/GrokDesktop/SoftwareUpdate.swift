import AppKit
import SwiftUI

/// Check for Updates: the bundled `crok upgrade --json` finds the latest GitHub release of the fork,
/// downloads the disk image for this Mac, checks it against the release signature, and swaps the
/// app bundle once Crok Desktop has quit. The TUI inside the bundle updates with the app, so the
/// `crok` command and the desktop never drift apart.
///
/// The model drives the helper; the view shows its phase. The helper is injected so tests run
/// without a release.

/// One line of `crok upgrade --json`.
enum SoftwareUpdateEvent: Equatable {
    struct Check: Equatable {
        let current: String
        let latest: String
        let page: String
        let notes: String?
        let updateAvailable: Bool
        let asset: String?
        /// Why this installation cannot take the release, when it cannot.
        let unavailable: String?
    }

    case check(Check)
    case progress(bytes: Int64, total: Int64?)
    case status(phase: String, message: String)
    /// The new app is staged; the helper waits for this process to quit.
    case ready
    case installed(version: String)
    case error(String)

    static func parse(_ line: String) -> SoftwareUpdateEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else { return nil }
        switch event {
        case "check":
            guard let current = object["current"] as? String, let latest = object["latest"] as? String else { return nil }
            return .check(Check(current: current, latest: latest, page: object["page"] as? String ?? "",
                                notes: object["notes"] as? String, updateAvailable: object["updateAvailable"] as? Bool ?? false,
                                asset: object["asset"] as? String, unavailable: object["unavailable"] as? String))
        case "progress":
            let bytes = (object["bytes"] as? NSNumber)?.int64Value ?? 0
            return .progress(bytes: bytes, total: (object["total"] as? NSNumber)?.int64Value)
        case "status":
            return .status(phase: object["phase"] as? String ?? "", message: object["message"] as? String ?? "")
        case "ready":
            return .ready
        case "installed":
            return .installed(version: object["version"] as? String ?? "")
        case "error":
            return .error(object["message"] as? String ?? "unknown error")
        default:
            return nil
        }
    }
}

/// Runs the bundled `crok upgrade`.
struct SoftwareUpdateHelper {
    struct Result {
        let status: Int32
        let lines: [String]
        let stderr: String
    }

    /// The bundled crok, or nil when this is not a packaged app (`swift run`, tests).
    let executable: String?
    /// Runs `crok` with the arguments to completion.
    var run: @Sendable (_ arguments: [String]) async throws -> Result
    /// Starts `crok` with the arguments, delivering stdout lines as they arrive and the exit at the
    /// end. Returns an action that stops it.
    var stream: @MainActor (_ arguments: [String],
                            _ onLine: @escaping @Sendable (String) -> Void,
                            _ onExit: @escaping @Sendable (Int32, String) -> Void) throws -> () -> Void

    /// The helper inside this app bundle.
    static func bundled(bundle: URL = Bundle.main.bundleURL) -> SoftwareUpdateHelper {
        let candidate = bundle.appendingPathComponent("Contents/Resources/crok").path
        let executable = FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        return SoftwareUpdateHelper(
            executable: executable,
            run: { arguments in
                guard let executable else { throw DesktopError.message("The bundled Crok runtime is missing.") }
                let output = try await GrokCLI.run(executable, arguments: arguments, environment: environment, timeout: 120)
                let lines = output.text.split(separator: "\n").map(String.init)
                return Result(status: output.status, lines: lines, stderr: output.stderr)
            },
            stream: { arguments, onLine, onExit in
                guard let executable else { throw DesktopError.message("The bundled Crok runtime is missing.") }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env.merge(environment) { $1 }
                process.environment = env
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                let buffer = LineBuffer()
                output.fileHandleForReading.readabilityHandler = { handle in
                    for line in buffer.append(handle.availableData) { onLine(line) }
                }
                let collectedErrors = LineBuffer()
                errors.fileHandleForReading.readabilityHandler = { handle in _ = collectedErrors.append(handle.availableData) }
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    for line in buffer.flush() { onLine(line) }
                    onExit(process.terminationStatus, collectedErrors.text)
                }
                try process.run()
                return { if process.isRunning { process.terminate() } }
            }
        )
    }

    /// `crok upgrade` is the fork's updater; grok's own must stay off, as everywhere the app runs crok.
    private static let environment = ["CROK_DISABLE_AUTOUPDATER": "1"]

    /// Splits a byte stream into lines, across chunks.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var all = Data()

        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            all.append(data)
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }

        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            guard !pending.isEmpty else { return [] }
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return [line]
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: all, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@MainActor
final class SoftwareUpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(SoftwareUpdateEvent.Check)
        /// This copy cannot be upgraded here (an unpackaged build, a test build, a read-only folder).
        case unavailable(String)
        /// Download progress, as a fraction when the size is known.
        case downloading(Double?)
        case installing(String)
        /// The new app is staged and the helper is waiting for Crok Desktop to quit.
        case waitingToQuit
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    let currentVersion: String
    /// Quits the app; the helper then swaps the bundle and opens the new one. Tests replace it.
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }

    private let helper: SoftwareUpdateHelper
    private var stopInstall: (() -> Void)?
    private var lastCheck: SoftwareUpdateEvent.Check?

    init(helper: SoftwareUpdateHelper = .bundled(), currentVersion: String = DesktopVersion.current) {
        self.helper = helper
        self.currentVersion = currentVersion
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing, .waitingToQuit: return true
        default: return false
        }
    }

    var canInstall: Bool {
        if case .available(let check) = phase { return check.unavailable == nil }
        return false
    }

    func check() async {
        guard !isBusy else { return }
        guard helper.executable != nil else {
            phase = .unavailable(L10n.t("update_unavailable_dev", "Updates come with the installed Crok Desktop app."))
            return
        }
        phase = .checking
        do {
            let result = try await helper.run(["upgrade", "--check", "--json"])
            var seen: Phase?
            for line in result.lines {
                guard let event = SoftwareUpdateEvent.parse(line) else { continue }
                switch event {
                case .check(let check):
                    lastCheck = check
                    seen = check.updateAvailable ? .available(check) : .upToDate
                case .error(let message):
                    seen = .failed(message)
                default:
                    break
                }
            }
            if let seen {
                phase = seen
            } else if result.status != 0 {
                phase = .failed(result.stderr.isEmpty ? "crok upgrade exited with status \(result.status)" : result.stderr)
            } else {
                phase = .failed("crok upgrade gave no answer")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        lastChecked = Date()
        DesktopLog.info("update.check", ["phase": String(describing: phase)])
    }

    /// Downloads and stages the release, then quits so the helper can swap the bundle and relaunch.
    func install() {
        guard canInstall else { return }
        phase = .downloading(nil)
        let arguments = ["upgrade", "--json", "--wait-for-pid", String(ProcessInfo.processInfo.processIdentifier), "--relaunch"]
        do {
            stopInstall = try helper.stream(arguments, { line in
                Task { @MainActor in self.handle(line) }
            }, { status, errors in
                Task { @MainActor in self.installExited(status: status, errors: errors) }
            })
        } catch {
            phase = .failed(error.localizedDescription)
        }
        DesktopLog.info("update.install", ["arguments": arguments])
    }

    /// Stops a download or a staged install; the helper removes what it staged.
    func cancel() {
        stopInstall?()
        stopInstall = nil
        if let lastCheck { phase = .available(lastCheck) } else { phase = .idle }
    }

    /// Quits now, for the helper that is waiting.
    func quitAndInstall() {
        guard case .waitingToQuit = phase else { return }
        terminate()
    }

    func handle(_ line: String) {
        guard let event = SoftwareUpdateEvent.parse(line) else { return }
        handle(event)
    }

    func handle(_ event: SoftwareUpdateEvent) {
        switch event {
        case .check, .installed:
            break
        case .progress(let bytes, let total):
            if let total, total > 0 {
                phase = .downloading(min(1, Double(bytes) / Double(total)))
            } else {
                phase = .downloading(nil)
            }
        case .status(let stage, let message):
            if stage == "download" { phase = .downloading(nil) } else { phase = .installing(message) }
        case .ready:
            phase = .waitingToQuit
            terminate()
            // Still here: the quit was cancelled (a task was running). The helper keeps waiting, so
            // the update installs whenever the app quits next.
        case .error(let message):
            stopInstall = nil
            phase = .failed(message)
        }
    }

    private func installExited(status: Int32, errors: String) {
        stopInstall = nil
        if case .failed = phase { return }
        if status != 0 {
            phase = .failed(errors.isEmpty ? "crok upgrade exited with status \(status)" : errors)
        }
    }
}

/// The Software Update sheet.
struct SoftwareUpdateSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: SoftwareUpdateModel

    var body: some View {
        DesktopPanel(title: L10n.t("software_update", "Software Update"), subtitle: "Crok Desktop · \(model.currentVersion)",
                     width: 540, onClose: close) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.muted).frame(width: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        progress
                    }
                }
                if case .available(let check) = model.phase, let notes = Self.summary(of: check.notes) {
                    ScrollView {
                        Text(notes).font(.system(size: 12)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
                    }
                    .frame(maxHeight: 200)
                    .background(Theme.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
        } footer: {
            if let lastChecked = model.lastChecked {
                Text(L10n.t("last_checked", "Last checked {time}")
                    .replacingOccurrences(of: "{time}", with: lastChecked.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            footerButtons
        }
        .task { if case .idle = model.phase { await model.check() } }
    }

    @ViewBuilder private var footerButtons: some View {
        switch model.phase {
        case .available(let check):
            if let url = URL(string: check.page), !check.page.isEmpty {
                Button(L10n.t("release_notes", "Release Notes")) { NSWorkspace.shared.open(url) }
            }
            Button(L10n.t("install_and_relaunch", "Install and Relaunch")) { model.install() }
                .keyboardShortcut(.defaultAction).disabled(!model.canInstall)
        case .downloading, .installing:
            Button(L10n.t("cancel", "Cancel")) { model.cancel() }
        case .waitingToQuit:
            Button(L10n.t("cancel", "Cancel")) { model.cancel() }
            Button(L10n.t("quit_and_install", "Quit and Install")) { model.quitAndInstall() }.keyboardShortcut(.defaultAction)
        case .checking:
            Button(L10n.t("done", "Done"), action: close).keyboardShortcut(.defaultAction)
        case .idle, .upToDate, .unavailable, .failed:
            Button(L10n.t("check_again", "Check Again")) { Task { await model.check() } }
            Button(L10n.t("done", "Done"), action: close).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var progress: some View {
        switch model.phase {
        case .checking, .installing, .waitingToQuit:
            ProgressView().controlSize(.small).padding(.top, 2)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 320).padding(.top, 2)
            } else {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 320).padding(.top, 2)
            }
        default:
            EmptyView()
        }
    }

    private var symbol: String {
        switch model.phase {
        case .available, .downloading, .installing, .waitingToQuit: return "arrow.down.circle"
        case .upToDate: return "checkmark.circle"
        case .failed, .unavailable: return "exclamationmark.triangle"
        case .idle, .checking: return "arrow.triangle.2.circlepath.circle"
        }
    }

    private var headline: String {
        switch model.phase {
        case .idle, .checking:
            return L10n.t("update_checking", "Checking for updates…")
        case .upToDate:
            return L10n.t("update_up_to_date", "Crok Desktop {version} is the latest version.")
                .replacingOccurrences(of: "{version}", with: model.currentVersion)
        case .available(let check):
            return L10n.t("update_available", "Crok Desktop {latest} is available. You have {current}.")
                .replacingOccurrences(of: "{latest}", with: check.latest)
                .replacingOccurrences(of: "{current}", with: check.current == "0.0.0" ? model.currentVersion : check.current)
        case .unavailable(let reason):
            return reason
        case .downloading:
            return L10n.t("update_downloading", "Downloading…")
        case .installing(let message):
            return message
        case .waitingToQuit:
            return L10n.t("update_quit_to_install", "The update is ready. Crok Desktop installs it when it quits.")
        case .failed:
            return L10n.t("update_failed_title", "The update did not finish.")
        }
    }

    private var detail: String? {
        switch model.phase {
        case .available(let check):
            return check.unavailable ?? L10n.t("update_detail", "The new app and its crok command download from GitHub, are checked against the release signature, and replace this copy. Crok Desktop quits and opens again.")
        case .failed(let message):
            return message
        case .waitingToQuit:
            return L10n.t("update_quit_detail", "Quit when your tasks are done; the new version opens by itself.")
        default:
            return nil
        }
    }

    /// The English part of the notes, before the translations, with blank lines folded.
    static func summary(of notes: String?) -> String? {
        guard let notes else { return nil }
        let english = notes.components(separatedBy: "<details").first ?? notes
        let lines = english.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var folded: [String] = []
        for line in lines where !(line.isEmpty && folded.last?.isEmpty ?? true) { folded.append(line) }
        let text = folded.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func close() { store.sheet = nil }
}

/// The sheet over the store's model, which outlives the sheet so a download continues when it closes.
struct SoftwareUpdateSheetHost: View {
    @EnvironmentObject var store: AppStore

    var body: some View { SoftwareUpdateSheet(model: store.softwareUpdate) }
}
