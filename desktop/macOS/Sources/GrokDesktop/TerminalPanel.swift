import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// One login shell per project, kept while the app runs so switching tabs or tasks leaves it running.
@MainActor
final class TerminalSessions: ObservableObject {
    struct Status: Equatable {
        var title: String
        var directory: String
        /// Set once the shell exits; nil while it runs.
        var exitCode: Int32?
        var hasExited = false
    }

    @Published private(set) var statuses: [String: Status] = [:]
    private var views: [String: GrokTerminalView] = [:]
    /// Bumped to move keyboard focus into the terminal.
    @Published private(set) var focusRequest = 0
    /// The shell new terminals run, as a login shell.
    var shell = TerminalSessions.loginShell

    func requestFocus() { focusRequest += 1 }

    /// Starts the project's shell unless it is already running.
    @discardableResult
    func ensureTerminal(for project: Project) -> GrokTerminalView {
        if let view = views[project.path] { return view }
        let view = GrokTerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        views[project.path] = view
        start(view, projectPath: project.path)
        return view
    }

    /// The project's terminal, if its shell has been started.
    func terminal(for project: Project) -> GrokTerminalView? { views[project.path] }

    func status(for project: Project) -> Status? { statuses[project.path] }

    /// Replaces an exited (or running) shell with a new one in the same place.
    func restart(_ project: Project) {
        if let old = views.removeValue(forKey: project.path) {
            old.processDelegate = nil
            old.terminate()
            old.removeFromSuperview()
        }
        statuses.removeValue(forKey: project.path)
        ensureTerminal(for: project)
        requestFocus()
    }

    /// Sends Control-L, which shells and full-screen programs take as "clear and redraw".
    func clear(_ project: Project) {
        views[project.path]?.send(data: [0x0C][...])
    }

    func terminateAll() {
        for view in views.values { view.processDelegate = nil; view.terminate() }
        views.removeAll()
        statuses.removeAll()
    }

    private func start(_ view: GrokTerminalView, projectPath: String) {
        let name = (shell as NSString).lastPathComponent
        statuses[projectPath] = Status(title: name, directory: projectPath)
        view.onTitle = { [weak self] title in self?.statuses[projectPath]?.title = title.isEmpty ? name : title }
        view.onDirectory = { [weak self] directory in
            guard let directory, let url = URL(string: directory), url.isFileURL else { return }
            self?.statuses[projectPath]?.directory = url.path
        }
        view.onExit = { [weak self] code in
            self?.statuses[projectPath]?.exitCode = code
            self?.statuses[projectPath]?.hasExited = true
        }
        // A leading "-" in argv[0] makes the shell a login shell, as Terminal does.
        view.startProcess(executable: shell, args: [], environment: Self.environment(shell: shell), execName: "-" + name, currentDirectory: projectPath)
    }

    /// The user's login shell from the directory service, which apps opened from Finder do not inherit as $SHELL.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    static func environment(shell: String, commandDirectory: String? = GrokCommand.bundledCommandDirectory) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CROK_DESKTOP_") { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "GrokDesktop"
        environment["SHELL"] = shell
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        if environment["LANG"] == nil && environment["LC_ALL"] == nil { environment["LANG"] = preferredLocale }
        // Last, so `grok` works here even with the command off, and a grok the user installed still wins.
        // Login shells keep entries they inherit when they rebuild PATH.
        if let commandDirectory {
            let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !path.split(separator: ":").contains(Substring(commandDirectory)) { environment["PATH"] = path + ":" + commandDirectory }
        }
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The user's locale as a UTF-8 locale name the system knows, as Terminal sets it.
    private static var preferredLocale: String {
        let locale = Locale.current
        let identifier = locale.identifier.replacingOccurrences(of: "-", with: "_")
        var candidates: [String] = []
        // "zh-Hans_CN" is known to the system as zh_CN.
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier { candidates.append("\(language)_\(region)") }
        candidates += [identifier, identifier.split(separator: "@").first.map(String.init) ?? identifier]
        for candidate in candidates where FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate).UTF-8") {
            return candidate + ".UTF-8"
        }
        return "en_US.UTF-8"
    }
}

/// SwiftTerm's local-process terminal, styled for the panel: system monospace type, colours that
/// follow the appearance, and no background of its own so the glass shows through.
final class GrokTerminalView: LocalProcessTerminalView {
    var onTitle: ((String) -> Void)? {
        get { observer.onTitle }
        set { observer.onTitle = newValue }
    }
    var onDirectory: ((String?) -> Void)? {
        get { observer.onDirectory }
        set { observer.onDirectory = newValue }
    }
    var onExit: ((Int32?) -> Void)? {
        get { observer.onExit }
        set { observer.onExit = newValue }
    }
    /// `processDelegate` is weak; the view keeps its observer.
    private let observer = TerminalProcessObserver()

    override init(frame: CGRect) {
        super.init(frame: frame)
        processDelegate = observer
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // As in Terminal: Option types the characters it types everywhere else.
        optionAsMetaKey = false
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        installColors(dark ? TerminalPalette.dark : TerminalPalette.light)
        nativeForegroundColor = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        nativeBackgroundColor = .clear
        caretColor = dark ? NSColor(white: 0.93, alpha: 0.9) : NSColor(white: 0.1, alpha: 0.85)
        selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(dark ? 0.6 : 0.45)
    }
}

private final class TerminalProcessObserver: LocalProcessTerminalViewDelegate {
    var onTitle: ((String) -> Void)?
    var onDirectory: ((String?) -> Void)?
    var onExit: ((Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { onDirectory?(directory) }
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
}

/// ANSI colours that stay readable on light and dark glass.
enum TerminalPalette {
    static let light: [SwiftTerm.Color] = [
        0x1D1D1F, 0xC4262E, 0x2A7E3B, 0x986801, 0x1F5FBF, 0x9A3DB4, 0x0F7C87, 0x6E6E73,
        0x55555A, 0xE0453C, 0x3A9A4D, 0xB07D12, 0x3478F6, 0xB45BD0, 0x1596A3, 0x8E8E93,
    ].map(color)

    static let dark: [SwiftTerm.Color] = [
        0x3A3A3C, 0xFF6B63, 0x62D079, 0xF2C94C, 0x6CA8FF, 0xD68BFF, 0x5FD4DE, 0xD1D1D6,
        0x8E8E93, 0xFF8A80, 0x86E09A, 0xFFDB70, 0x93BFFF, 0xE3A9FF, 0x86E3EA, 0xF2F2F7,
    ].map(color)

    private static func color(_ value: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((value >> 16) & 0xFF), green8: UInt16((value >> 8) & 0xFF), blue8: UInt16(value & 0xFF))
    }
}

// MARK: - View

struct TerminalPanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var terminals: TerminalSessions

    var body: some View {
        if let project = store.project {
            let status = terminals.status(for: project)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Text(status?.title ?? "Terminal").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text((status?.directory ?? project.path).abbreviatingWithTildeInPath)
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    IconButton(icon: "eraser", help: "Clear the screen · ⌃L", size: 24) { terminals.clear(project) }
                    IconButton(icon: "arrow.clockwise", help: "Restart the shell", size: 24) { terminals.restart(project) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Group {
                    if let terminal = terminals.terminal(for: project) {
                        TerminalHost(terminal: terminal, focusRequest: terminals.focusRequest)
                    } else {
                        Color.clear
                    }
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.bottom, 6)
                .id(project.path)
                if status?.hasExited == true {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle").foregroundStyle(Theme.muted)
                        Text(status?.exitCode.map { "The shell exited with status \($0)." } ?? "The shell exited.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer(minLength: 4)
                        Button("Restart") { terminals.restart(project) }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.sidebar)
                }
            }
            .task(id: project.path) {
                terminals.ensureTerminal(for: project)
                terminals.requestFocus()
            }
        } else {
            SidePanelEmptyState(symbol: "terminal", title: "No project", detail: "Open a project to use a terminal in its folder.")
        }
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Hosts a long-lived terminal view: the same view moves between hosts as the panel is rebuilt.
private struct TerminalHost: NSViewRepresentable {
    let terminal: GrokTerminalView
    let focusRequest: Int

    func makeNSView(context: Context) -> TerminalContainerView { TerminalContainerView() }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.host(terminal)
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, let window = terminal.window else { return }
                window.makeFirstResponder(terminal)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var focusRequest = -1 }
}

/// Keeps its terminal filling it, but never at zero size: that would tell the shell its window is empty.
private final class TerminalContainerView: NSView {
    func host(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        if !bounds.isEmpty { terminal.frame = bounds }
        addSubview(terminal)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !bounds.isEmpty else { return }
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}
