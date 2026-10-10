import SwiftUI
import AppKit

@main
struct GrokDesktopApp: App {
    // Held, not observed: the window's views observe the store themselves, and the menus
    // observe `menuState`. Observing it here would rebuild the scene for every streamed chunk.
    @State private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = "system"

    /// The saved theme (shared with the terminal as `[ui].theme`) applies before any window draws.
    init() {
        ExtrasFeatureModel.restoreSavedTheme()
        L10n.configure(fromConfig: GrokConfig())
    }

    var body: some Scene {
        Window(displayName, id: "main") {
            ContentView().desktopEnvironment(store)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1240, height: 820)
        .defaultPosition(.center)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(store: store, menu: store.menuState) }

        auxiliary(.trace)
        auxiliary(.docs)
        auxiliary(.releaseNotes)
        auxiliary(.transcript)
        auxiliary(.gboom)
        auxiliary(.tutorial)
        auxiliary(.gitGraph)
    }

    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Crok Desktop"
    }

    private func auxiliary(_ window: DesktopWindow) -> some Scene {
        Window(window.title, id: window.rawValue) {
            window.content.desktopEnvironment(store)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
        .defaultSize(width: window.defaultSize.width, height: window.defaultSize.height)
        .windowResizability(.contentMinSize)
    }
}

private struct AppCommands: Commands {
    let store: AppStore
    @ObservedObject var menu: MenuState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("new_task", "New Task")) { store.newTask() }.keyboardShortcut("n")
            Button(L10n.t("open_project", "Open Project…")) { store.addProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Attach Photos & Files…") { store.features.attachments.chooseFiles() }.keyboardShortcut("u").disabled(!menu.hasProject)
            Button("Attach Folder…") { store.features.attachments.chooseFolder() }.disabled(!menu.hasProject)
            Button(L10n.t("search_tasks", "Search Tasks")) { store.showSearch.toggle() }.keyboardShortcut("k")
            Button(L10n.t("commands", "Commands…")) { store.showCommandPalette = true }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        // In place of the standard Close, which closes the main window and so quits the app.
        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("close", "Close")) { store.closeFrontmost() }.keyboardShortcut("w")
        }
        CommandGroup(after: .appInfo) {
            Button(L10n.t("check_for_updates", "Check for Updates…")) { store.checkForUpdates() }
        }
        CommandGroup(replacing: .appSettings) {
            Button(L10n.t("settings_ellipsis", "Settings…")) { store.showSettings = true }.keyboardShortcut(",")
        }
        CommandMenu("Task") {
            Button(L10n.t("plan_mode", "Plan Mode")) { store.executeCommand(name: "plan") }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(menu.isRunning)
            Button("Goal…") { store.featurePanel = .goals }.disabled(!menu.hasProject)
            Button("Subagents…") { store.featurePanel = .agents }.disabled(!menu.hasProject)
            Divider()
            Button(L10n.t("stop", "Stop")) { store.cancel() }.keyboardShortcut(".").disabled(!menu.isRunning)
            Button("Import Harness Tasks") { store.syncHistory() }.disabled(!menu.hasProject || menu.isSyncing)
            Divider()
            Button(L10n.t("side_panel", "Side Panel")) { store.toggleSidePanel() }.keyboardShortcut("j")
            Button(L10n.t("files", "Files")) { store.showSidePanel(.files) }.disabled(!menu.hasProject)
            Button("Side Chat") { store.showSidePanel(.sideChat); store.features.sideChat.requestFocus() }
            Button(L10n.t("terminal", "Terminal")) { store.openTerminal() }.keyboardShortcut("`", modifiers: .control).disabled(!menu.hasProject)
            Button(L10n.t("browser", "Browser")) { store.openBrowser() }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("Reveal Project in Finder") { store.revealProject() }.disabled(!menu.hasProject)
            Button("Git Graph") { store.features.gitGraph.open() }.keyboardShortcut("g", modifiers: [.command, .option]).disabled(!menu.hasProject)
        }
        CommandGroup(replacing: .help) {
            Button("Crok Build Guides") { store.executeCommand(name: "docs") }
            Button(L10n.t("tutorial", "Tutorial")) { store.executeCommand(name: "tutorial") }
            Divider()
            Button(L10n.t("keyboard_shortcuts", "Keyboard Shortcuts")) { store.features.extras.openKeyboardShortcuts() }.keyboardShortcut("/")
            Divider()
            Button("Reveal Log File") { store.revealLog() }
        }
        CommandMenu("Extensions") {
            Button("MCP Servers…") { store.featurePanel = .mcps }
            Button("Skills…") { store.featurePanel = .skills }
            Button("Plugins…") { store.featurePanel = .plugins }
            Button("Workflows…") { store.featurePanel = .workflows }
            Button("Agent Definitions…") { store.featurePanel = .agentDefinitions }
            Button("Personas…") { store.featurePanel = .personas }
            Button("Hooks…") { store.featurePanel = .hooks }
            Button("Memory…") { store.featurePanel = .memory }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var appIcon: AppIconController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopLog.info("app.launch", [
            "bundle": Bundle.main.bundleIdentifier, "app": Bundle.main.bundleURL, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "test_build": GrokCommand.isWorkspaceTestBuild(in: Bundle.main.bundleURL), "state_file": DesktopPaths.stateFile
        ])
        // Workspace test bundles are built locally and never install their launcher.
        if !GrokCommand.isWorkspaceTestBuild(in: Bundle.main.bundleURL) {
            GrokCommand.clearQuarantine()
        }
        startHangRecorder()
        let icon = AppIconController()
        icon.start()
        appIcon = icon
    }

    /// Test builds write a report when the main thread stops answering, and say so once it answers again.
    private func startHangRecorder() {
        guard PerformanceMonitorSettings.isAvailable else { return }
        HangRecorder.shared.start(describe: { [weak self] in HangContext.describe(store: self?.store) }) { [weak self] report, seconds in
            DesktopLog.error("ui.hang", session: self?.store?.selectedSessionID, ["seconds": seconds, "report": report])
            self?.store?.banner = String(format: "Crok Desktop stopped answering for %.0f seconds. A report is in %@", seconds, report.deletingLastPathComponent().path)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.runs.values.contains(where: { $0.isRunning }) == true {
            let alert = NSAlert()
            alert.messageText = "Quit while Crok is working?"
            alert.informativeText = "Active tasks will stop. Your conversations are saved and can be resumed."
            alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        store?.shutdown()
        DesktopLog.info("app.terminate")
        DesktopLog.shared.flush()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
