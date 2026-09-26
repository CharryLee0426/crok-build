import AppKit
import Darwin
import SwiftUI

/// The terminal's external prompt editor (P/app/external_editor.rs): the draft goes to
/// `<tmp>/grok-prompt-<uuid>.md` (0600), opens in `$VISUAL`/`$EDITOR`, and is read back with the same
/// rules and messages. On the desktop the editor runs in Terminal, or the default app for Markdown
/// when no editor is configured.
enum ExternalPromptEditor {
    static let maximumBytes = 4 * 1024 * 1024
    static let voiceMessage = "External prompt editing is not available while voice input is active."
    static let prepareFailure = "Could not open the draft in an external editor; the original draft was kept."
    static let failure = "External prompt editor failed; the original draft was kept."
    static let nonzeroExit = "External prompt editor exited unsuccessfully; the original draft was kept."
    static let invalidUTF8 = "External prompt editor saved invalid UTF-8; the original draft was kept."
    static let tooLarge = "External prompt editor saved a draft larger than 4 MiB; the original draft was kept."
    static let stale = "The draft changed while the external editor was open; the newer draft was kept."

    /// `$VISUAL`, then `$EDITOR`, ignoring blank values.
    static func editorCommand(environment: [String: String]) -> String? {
        [environment["VISUAL"], environment["EDITOR"]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Creates the prompt file; it must not exist yet, and only the user may read it.
    static func createPromptFile(_ text: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("grok-prompt-\(UUID().uuidString.lowercased()).md")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Reads the edited prompt. Editors add a final newline when saving a buffer that lacks one, so
    /// one trailing newline (and a CR before it) is removed when the original draft had none.
    static func readBack(_ url: URL, original: String) -> Result<String, ComposerCommandMessage> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(ComposerCommandMessage(failure)) }
        defer { try? handle.close() }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > maximumBytes {
            return .failure(ComposerCommandMessage(tooLarge))
        }
        guard let data = try? handle.read(upToCount: maximumBytes + 1) ?? Data() else { return .failure(ComposerCommandMessage(failure)) }
        guard data.count <= maximumBytes else { return .failure(ComposerCommandMessage(tooLarge)) }
        guard let text = String(bytes: data, encoding: .utf8) else { return .failure(ComposerCommandMessage(invalidUTF8)) }
        var scalars = text.unicodeScalars
        if original.unicodeScalars.last != "\n", scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" { scalars.removeLast() }
        }
        return .success(String(scalars))
    }

    /// A shell script Terminal runs: the editor, then its exit status for the app to pick up.
    static func terminalScript(editor: String, file: URL, statusFile: URL) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        # Crok Desktop: edit the prompt, then save and quit the editor to return it to the app.
        CROK_EDITOR=\(quoted(editor))
        CROK_PROMPT_FILE=\(quoted(file.path))
        CROK_STATUS_FILE=\(quoted(statusFile.path))
        clear
        eval "$CROK_EDITOR \\"\\$CROK_PROMPT_FILE\\""
        status=$?
        printf '%s' "$status" > "$CROK_STATUS_FILE.tmp" && mv "$CROK_STATUS_FILE.tmp" "$CROK_STATUS_FILE"
        printf '\\nThe prompt is back in Crok Desktop. You can close this window.\\n'
        exit "$status"

        """
    }

    @MainActor private static var discoveredEditor: String??

    /// `$VISUAL`/`$EDITOR` from the app's environment or, for an app opened from the Finder (which
    /// does not inherit the shell's environment), from the user's login shell. Nil when neither is set.
    @MainActor
    static func discoverEditor() async -> String? {
        if let command = editorCommand(environment: ProcessInfo.processInfo.environment) { return command }
        if let cached = discoveredEditor { return cached }
        let environment = await loginShellEditorEnvironment()
        let command = editorCommand(environment: environment)
        discoveredEditor = .some(command)
        return command
    }

    private static func loginShellEditorEnvironment() async -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-ilc", #"printf '\n__GROK_VISUAL__=%s\n__GROK_EDITOR__=%s\n' "$VISUAL" "$EDITOR""#]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { once.resume([:]); return }
                // A shell that never exits (for example one that starts tmux) must not hold up the sheet.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { process.terminate() }
                    once.resume([:])
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                var values: [String: String] = [:]
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    if line.hasPrefix("__GROK_VISUAL__=") { values["VISUAL"] = String(line.dropFirst(16)) }
                    if line.hasPrefix("__GROK_EDITOR__=") { values["EDITOR"] = String(line.dropFirst(16)) }
                }
                once.resume(values)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String: String], Never>?
        init(_ continuation: CheckedContinuation<[String: String], Never>) { self.continuation = continuation }
        func resume(_ value: [String: String]) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// One round trip through an external editor for the edit-prompt sheet.
@MainActor
final class ExternalPromptEditorSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        /// `$VISUAL`/`$EDITOR` runs in Terminal; the prompt returns when the editor exits.
        case terminal(editor: String)
        /// The default Markdown app; each save updates the prompt.
        case application(name: String)
    }

    @Published private(set) var state: State = .idle
    /// The outcome of the last read-back, when it kept the original draft.
    @Published var notice: String?

    private var files: [URL] = []
    private var original = ""
    private var lastApplied = ""
    private var watcher: Task<Void, Never>?
    private var read: () -> String = { "" }
    private var apply: (String) -> Void = { _ in }

    func open(text: String, read: @escaping () -> String, apply: @escaping (String) -> Void) {
        guard state == .idle else { return }
        state = .preparing
        notice = nil
        self.read = read
        self.apply = apply
        Task { @MainActor [weak self] in
            let editor = await ExternalPromptEditor.discoverEditor()
            self?.launch(text: text, editor: editor)
        }
    }

    private func launch(text: String, editor: String?) {
        guard state == .preparing else { return }
        let promptFile: URL
        do { promptFile = try ExternalPromptEditor.createPromptFile(text) }
        catch { finish(notice: ExternalPromptEditor.prepareFailure); return }
        files = [promptFile]
        original = text
        lastApplied = text
        if let editor { launchTerminal(editor: editor, promptFile: promptFile) }
        else { launchApplication(promptFile: promptFile) }
    }

    private func launchTerminal(editor: String, promptFile: URL) {
        let base = promptFile.deletingPathExtension()
        let statusFile = base.appendingPathExtension("status")
        let script = base.appendingPathExtension("command")
        do {
            try Data(ExternalPromptEditor.terminalScript(editor: editor, file: promptFile, statusFile: statusFile).utf8).write(to: script, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { finish(notice: ExternalPromptEditor.prepareFailure); return }
        files += [script, statusFile]
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.finish(notice: ExternalPromptEditor.prepareFailure) }
        }
        state = .terminal(editor: editor)
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let status = try? String(contentsOf: statusFile, encoding: .utf8) else { continue }
                self.completeTerminal(status: status.trimmingCharacters(in: .whitespacesAndNewlines), promptFile: promptFile)
                return
            }
        }
    }

    private func completeTerminal(status: String, promptFile: URL) {
        guard status == "0" else { finish(notice: ExternalPromptEditor.nonzeroExit); return }
        switch ExternalPromptEditor.readBack(promptFile, original: original) {
        case .failure(let message): finish(notice: message.text)
        case .success(let text):
            if read() != original { finish(notice: ExternalPromptEditor.stale); return }
            apply(text)
            finish(notice: nil)
        }
    }

    private func launchApplication(promptFile: URL) {
        let application = NSWorkspace.shared.urlForApplication(toOpen: promptFile)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([promptFile], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.finish(notice: ExternalPromptEditor.prepareFailure) }
        }
        state = .application(name: FileManager.default.displayName(atPath: application.path).replacingOccurrences(of: ".app", with: ""))
        var lastModified = Self.modificationDate(promptFile)
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                let modified = Self.modificationDate(promptFile)
                guard modified != lastModified else { continue }
                lastModified = modified
                switch ExternalPromptEditor.readBack(promptFile, original: self.original) {
                case .failure(let message): self.finish(notice: message.text); return
                case .success(let text):
                    guard self.read() == self.lastApplied else { self.finish(notice: ExternalPromptEditor.stale); return }
                    if text != self.lastApplied { self.apply(text); self.lastApplied = text }
                }
            }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Stops waiting and deletes the temporary files.
    func finish(notice: String? = nil) {
        watcher?.cancel()
        watcher = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        self.notice = notice
        state = .idle
    }
}

/// `/edit-prompt`: a larger editor for writing the prompt, with an external-editor round trip.
struct EditPromptSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var composer: ComposerFeatureModel
    let initialText: String
    @State private var text = ""
    @State private var loaded = false
    @AppStorage("editPromptMonospaced") private var monospaced = false
    @StateObject private var external = ExternalPromptEditorSession()
    @FocusState private var focused: Bool

    var body: some View {
        DesktopPanel(title: "Edit prompt", subtitle: "Write at length. The prompt returns to the composer, where you can review and send it.",
                     width: 760, height: 620, onClose: close) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Toggle("Monospaced", isOn: $monospaced).toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    Text(counts).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                        .accessibilityLabel(counts)
                }
                if external.state != .idle { externalStatus }
                if let notice = external.notice { noticeRow(notice) }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(monospaced ? .system(size: 13.5, design: .monospaced) : .system(size: 15))
                        .lineSpacing(monospaced ? 2 : 3)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .accessibilityLabel("Prompt")
                    if text.isEmpty {
                        Text("Describe the task, paste context, or outline steps. Markdown is sent as written.")
                            .font(monospaced ? .system(size: 13.5, design: .monospaced) : .system(size: 15))
                            .foregroundStyle(Theme.muted).padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(InputSurface(focused: focused))
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        } footer: {
            Button {
                external.open(text: text, read: { text }, apply: { text = $0 })
            } label: {
                Label("Open in External Editor…", systemImage: "square.and.arrow.up.on.square")
            }.disabled(external.state != .idle)
                .help("Edit in $VISUAL or $EDITOR in Terminal, or in your Markdown app")
            Spacer()
            Button("Cancel", action: close)
            Button("Use Prompt") { composer.useEditedPrompt(text) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(external.state != .idle)
                .help("Put this prompt in the composer · ⌘↵")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = initialText
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { external.finish() }
    }

    private var counts: String {
        let words = ComposerFormat.wordCount(text), characters = text.count
        return "\(words.formatted()) word\(words == 1 ? "" : "s") · \(characters.formatted()) character\(characters == 1 ? "" : "s")"
    }

    private var externalStatus: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Group {
                switch external.state {
                case .terminal(let editor):
                    Text("Editing in Terminal with ") + Text(editor).font(.system(size: 12, design: .monospaced)) + Text(". Save and quit the editor to bring the prompt back.")
                case .application(let name):
                    Text("Editing in \(name). Each save updates the prompt here; choose Done when you have finished.")
                default:
                    Text("Opening the external editor…")
                }
            }.font(.system(size: 12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(isApplication ? "Done" : "Stop Waiting") { external.finish() }
                .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isApplication: Bool { if case .application = external.state { return true }; return false }

    private func noticeRow(_ notice: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ComposerPalette.warning).accessibilityHidden(true)
            Text(notice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton(icon: "xmark", help: "Dismiss", size: 24) { external.notice = nil }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(ComposerPalette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func close() {
        external.finish()
        store.sheet = nil
    }
}

enum ComposerPalette {
    /// Warnings: always-approve and failed operations.
    static let warning = Theme.adaptive(0xB45309, 0xF5A524)
    /// Dictation. A fixed color rather than the system red, which glass surfaces restyle.
    static let recording = Theme.adaptive(0xD93036, 0xFF6166)
}
