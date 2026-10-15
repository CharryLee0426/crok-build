import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// PNGs of the side panel, composer attachments, and sent attachments, written when
/// CROK_DESKTOP_SNAPSHOT_DIR is set. Glass is not drawn offscreen, so surfaces show their tints only.
@MainActor
final class SidePanelSnapshotTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-side-panel-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        for (file, text) in [("README.md", "# Demo\n"), ("Package.swift", "// swift-tools-version: 5.9\n"),
                             ("Sources/App/main.swift", "import SwiftUI\n\n@main\nstruct DemoApp: App {\n    var body: some Scene {\n        WindowGroup { Text(\"Hello\") }\n    }\n}\n"),
                             ("Sources/App/View.swift", "struct View {}\n")] {
            try Data(text.utf8).write(to: directory.appendingPathComponent(file))
        }
        try SidePanelAndAttachmentTests.png(width: 320, height: 200).write(to: directory.appendingPathComponent("screenshot.png"))
    }

    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }

    private func makeStore() -> (AppStore, Conversation) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let now = Date()
        let thumbnail = PromptAttachmentsModel.prepare(.data(SidePanelAndAttachmentTests.png(width: 480, height: 300)))?.thumbnailData
        let task = Conversation(projectID: project.id, title: "Polish the demo app", messages: [
            Message(kind: .user, text: "Why does the window flicker when it opens? The recording and the view are attached.", createdAt: now,
                    attachments: [MessageAttachment(kind: .image, name: "flicker.png", thumbnail: thumbnail),
                                  MessageAttachment(kind: .file, name: "main.swift", path: directory.appendingPathComponent("Sources/App/main.swift").path),
                                  MessageAttachment(kind: .folder, name: "Sources", path: directory.appendingPathComponent("Sources").path)]),
            Message(kind: .assistant, text: "The window is created before its content has a size, so the first frame is empty.", createdAt: now),
        ], sideChat: [
            SideChatMessage(role: .question, text: "Which file sets up the window?"),
            SideChatMessage(role: .answer, text: "`Sources/App/main.swift` declares the `WindowGroup`. The view itself is in `View.swift`."),
            SideChatMessage(role: .question, text: "Is the flicker only in debug builds?"),
            SideChatMessage(role: .failure, text: "Crok did not respond to x.ai/btw in time."),
        ])
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        store.workspace = GitWorkspaceSnapshot(branch: "feature/window", changes: [
            GitFileChange(path: "Sources/App/main.swift", status: " M", additions: 12, deletions: 3, isBinary: false),
            GitFileChange(path: "README.md", status: "??", additions: 1, deletions: 0, isBinary: false),
        ], rootPath: directory.path)
        return (store, task)
    }

    private func write<V: View>(_ view: V, _ name: String, size: CGSize) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(view, size: size, appearance: appearance, to: output.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private func settle(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testSidePanelTabs() throws {
        let (store, _) = makeStore()
        let files = store.features.files
        files.load()
        settle(1.2)
        files.toggle("Sources")
        files.toggle("Sources/App")
        files.select(directory.appendingPathComponent("Sources/App/main.swift").path)
        files.showsDiff = false
        settle()
        store.sidePanelTab = .files
        // A previewed file opens beside the tree, in a wider panel.
        let previewSize = CGSize(width: SidePanelView.defaultPreviewWidth, height: 720)
        try write(SidePanelView(containerWidth: 1400).desktopEnvironment(store).frame(width: previewSize.width, height: 720).foregroundStyle(Theme.ink),
                  "side-panel-files", size: previewSize)
        let size = CGSize(width: 400, height: 720)
        files.select(nil)
        try write(SidePanelView(containerWidth: 1200).desktopEnvironment(store).frame(width: 400, height: 720).foregroundStyle(Theme.ink), "side-panel-tree", size: size)
        files.scope = .changes
        try write(SidePanelView(containerWidth: 1200).desktopEnvironment(store).frame(width: 400, height: 720).foregroundStyle(Theme.ink), "side-panel-changes", size: size)
        store.sidePanelTab = .sideChat
        try write(SidePanelView(containerWidth: 1200).desktopEnvironment(store).frame(width: 400, height: 720).foregroundStyle(Theme.ink), "side-panel-side-chat", size: size)
    }

    func testComposerWithAttachments() throws {
        let (store, _) = makeStore()
        store.newTask()
        let attachments = store.features.attachments
        attachments.add(urls: [directory.appendingPathComponent("screenshot.png"), directory.appendingPathComponent("Sources/App/main.swift"),
                               directory.appendingPathComponent("Sources")])
        settle(1)
        store.draft = "Make the launch smoother"
        let scene = VStack(spacing: 0) {
            Spacer(minLength: 0)
            ComposerView().padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 12)
        }.frame(width: 820, height: 300).foregroundStyle(Theme.ink).desktopEnvironment(store)
        try write(scene, "composer-attachments", size: CGSize(width: 820, height: 300))
    }

    func testTranscriptWithSentAttachments() throws {
        let (store, _) = makeStore()
        let transcript = ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                ForEach(store.conversation?.messages ?? []) { MessageView(message: $0) }
            }.padding(36)
        }.frame(width: 820, height: 480).foregroundStyle(Theme.ink).desktopEnvironment(store)
        try write(transcript, "transcript-attachments", size: CGSize(width: 820, height: 480))
    }

    func testBrowserTab() async throws {
        let (store, _) = makeStore()
        let browser = store.features.browser
        browser.makeDataStore = { .nonPersistent() }
        store.sidePanelTab = .browser
        let size = CGSize(width: SidePanelView.defaultBrowserWidth, height: 720)
        // The panel is as wide as its container leaves it.
        func panel(width: CGFloat = size.width) -> some View {
            SidePanelView(containerWidth: width + SidePanelView.previewConversationRoom).desktopEnvironment(store).frame(width: width, height: 720)
                .foregroundStyle(Theme.ink)
        }
        // An async test's own work holds the main queue; waiting lets the browser's tasks run.
        func settle(_ seconds: Double = 0.6) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        // A new tab before anything was visited or imported.
        try write(panel(), "side-panel-browser-empty", size: size)
        // After an import: bookmarks and the pages visited last.
        browser.addBookmarks((1...11).map { BrowserBookmark(title: ["Swift Documentation", "WebKit", "Crok Build Guides", "SQLite Query Planner"][$0 % 4] + " \($0)",
                                                            url: "https://docs\($0).example.com/guide/\($0)") })
        _ = try await browser.history.merge((1...9).map {
            BrowserHistoryItem(url: "https://news\($0).example.com/articles/\($0 * 37)", title: "Article \($0): what changed in the release",
                               visitCount: $0, lastVisit: Date().addingTimeInterval(-Double($0) * 600))
        })
        browser.refreshRecent()
        try await settle()
        try write(panel(), "side-panel-browser-start", size: size)
        // Typing in the address bar: suggestions from the history, over the page.
        browser.address.begin(showing: nil)
        browser.address.typed("article")
        try await settle()
        browser.address.move(1)
        try write(panel(), "side-panel-browser-suggestions", size: size)
        browser.address.end(showing: nil)
        // One page: its tab shows, for its close button. Closing it brings the start page back.
        browser.open("http://127.0.0.1:9/")
        try await settle(1.5)
        try write(panel(), "side-panel-browser-one-tab", size: size)
        browser.closeTab()
        // Several tabs, and a page that did not open, in a panel too narrow for every tab's name.
        browser.openTab(URL(string: "http://127.0.0.1:9/")!)
        browser.newTab()
        browser.select(browser.pages[1].id)
        try await settle(1.5)
        try write(panel(width: 400), "side-panel-browser-tabs", size: CGSize(width: 400, height: 720))
        store.shutdown()
    }

    func testImportChromeSheet() throws {
        let (store, _) = makeStore()
        let profiles = [ChromeProfile(directory: URL(fileURLWithPath: "/tmp/Chrome/Default"), name: "Work", account: "me@example.com"),
                        ChromeProfile(directory: URL(fileURLWithPath: "/tmp/Chrome/Profile 1"), name: "Personal", account: nil)]
        func sheet(_ phase: ChromeImportModel.Phase) -> some View {
            ImportChromeSheet(model: ChromeImportModel(profiles: profiles, phase: phase)).desktopEnvironment(store).foregroundStyle(Theme.ink)
        }
        try write(sheet(.ready), "import-chrome", size: CGSize(width: 580, height: 470))
        try write(sheet(.applying(1_250, 3_400)), "import-chrome-working", size: CGSize(width: 580, height: 520))
        try write(sheet(.finished(ChromeImportResult(cookies: 3_388, history: 20_000, bookmarks: 214,
                                                     problems: ["12 cookies could not be decrypted and were left out."]))),
                  "import-chrome-done", size: CGSize(width: 580, height: 420))
        try write(sheet(.failed("macOS could not confirm it's you, so nothing was read from Chrome: Authentication was cancelled.")),
                  "import-chrome-failed", size: CGSize(width: 580, height: 520))
    }

    func testMainWindowWithSidePanel() throws {
        let (store, _) = makeStore()
        store.showInspector = true
        store.sidePanelTab = .sideChat
        try write(ContentView().desktopEnvironment(store).frame(width: 1320, height: 780), "main-side-panel", size: CGSize(width: 1320, height: 780))
    }

    /// Settings and the side panel in another interface language: every section of the Settings sheet
    /// at its full height, the Chrome import it opens, and the panel's tabs.
    func testSettingsAndSidePanelInAnotherLanguage() throws {
        let language = AppLanguage.parse(ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_LANGUAGE"] ?? "zh-Hans")
        L10n.setLanguage(language)
        defer { L10n.setLanguage(.auto) }
        let name = language.configValue
        let (store, _) = makeStore()
        store.features.browser.makeDataStore = { .nonPersistent() }
        let home = directory!
        try FileManager.default.createDirectory(at: home.appendingPathComponent("provider-auth"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["provider": "openrouter", "access_token": "sk-fixture"])
            .write(to: home.appendingPathComponent("provider-auth/openrouter.json"))
        let accounts = AccountStore(reader: AccountStatusReader(home: home, environment: [:]))
        let command = GrokCommandModel(link: home.appendingPathComponent("bin/crok"), bundle: home, home: home)
        let settings = VStack(alignment: .leading, spacing: 16) {
            AppearanceSettingsSection().settingsCard()
            AccountsSettingsSection(accounts: accounts)
            DisplaySettingsSection()
            BehaviorSettingsSection()
            BrowserSettingsSection()
            DeviceUseSettingsSection()
            CommandLineSettingsSection(command: command)
            DeveloperSettingsSection()
        }
        .padding(24).frame(width: 660).foregroundStyle(Theme.ink).desktopEnvironment(store)
        try write(settings, "settings-\(name)", size: CGSize(width: 660, height: 2_400))

        let profiles = [ChromeProfile(directory: URL(fileURLWithPath: "/tmp/Chrome/Default"), name: "Work", account: "me@example.com")]
        try write(ImportChromeSheet(model: ChromeImportModel(profiles: profiles, phase: .ready)).desktopEnvironment(store).foregroundStyle(Theme.ink),
                  "import-chrome-\(name)", size: CGSize(width: 580, height: 470))

        let files = store.features.files
        files.load()
        settle(1.2)
        let size = CGSize(width: 400, height: 720)
        func panel(width: CGFloat = 400) -> some View {
            SidePanelView(containerWidth: 1400).desktopEnvironment(store).frame(width: width, height: 720).foregroundStyle(Theme.ink)
        }
        store.sidePanelTab = .files
        try write(panel(), "side-panel-tree-\(name)", size: size)
        files.scope = .changes
        try write(panel(), "side-panel-changes-\(name)", size: size)
        store.sidePanelTab = .sideChat
        try write(panel(), "side-panel-side-chat-\(name)", size: size)
        // The browser tab asks for a wider panel.
        store.sidePanelTab = .browser
        let wide = CGSize(width: SidePanelView.defaultBrowserWidth, height: 720)
        try write(panel(width: wide.width), "side-panel-browser-\(name)", size: wide)
    }
}
