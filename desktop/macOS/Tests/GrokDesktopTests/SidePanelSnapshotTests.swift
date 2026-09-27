import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// PNGs of the side panel, composer attachments, and sent attachments, written when
/// GROK_DESKTOP_SNAPSHOT_DIR is set. Glass is not drawn offscreen, so surfaces show their tints only.
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

    func testMainWindowWithSidePanel() throws {
        let (store, _) = makeStore()
        store.showInspector = true
        store.sidePanelTab = .sideChat
        try write(ContentView().desktopEnvironment(store).frame(width: 1320, height: 780), "main-side-panel", size: CGSize(width: 1320, height: 780))
    }
}
