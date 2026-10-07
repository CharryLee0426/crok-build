import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Writes PNGs of the composer's states when CROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
@MainActor
final class ComposerSnapshotTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-composer-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }

    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    private func makeStore(running: Bool) -> (AppStore, UUID) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
        let project = Project(path: "/tmp/grok-desktop")
        let task = Conversation(projectID: project.id, title: "Tighten the parser")
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        let levels = ["low", "medium", "high"].map { ModelOption(id: $0, name: $0.capitalized) }
        var run = RunState()
        run.isRunning = running
        run.phase = running ? "Working" : "Ready"
        run.models = [ModelOption(id: "grok-code-fast", name: "Grok Code Fast", reasoningOptions: levels)]
        run.modelID = "grok-code-fast"
        run.reasoningOptions = levels
        run.reasoningID = "high"
        store.runs[task.id] = run
        store.harnessMeta.initialize = ["voiceMode": true]
        store.workspace = GitWorkspaceSnapshot(branch: "feature/parser", changes: [])
        return (store, task.id)
    }

    private func composerScene(_ store: AppStore, width: CGFloat = 820, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ComposerView().padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 12)
        }
        .frame(width: width, height: height)
        // As in the main window. Glass itself is not drawn offscreen, so the composer card has no fill here.
        .foregroundStyle(Theme.ink)
        .desktopEnvironment(store)
    }

    private func write<V: View>(_ view: V, size: CGSize, name: String) throws {
        for (suffix, appearance) in appearances {
            try SnapshotRenderer.write(view, size: size, appearance: appearance, to: output.appendingPathComponent("composer-\(name)-\(suffix).png"))
        }
    }

    func testRenderQueue() throws {
        let (store, id) = makeStore(running: true)
        let composer = store.features.composer
        _ = composer.enqueue("Run the parser tests again once the fix lands", conversationID: id)
        _ = composer.enqueue("Then update the docs:\n- the grammar table\n- the migration notes", conversationID: id)
        _ = composer.enqueue("/compact keep the parser decisions", conversationID: id)
        _ = composer.handle(method: "x.ai/queue/changed", params: [
            "entries": [["id": "q1", "version": 1, "owner": "grok-shell", "kind": "prompt", "text": "Summarize the failing cases", "position": 0]],
        ], update: nil, conversationID: id)
        store.draft = "Also add a regression test for nested brackets"
        try write(composerScene(store, height: 470), size: CGSize(width: 820, height: 470), name: "queue")
    }

    func testRenderRecordingAndPermission() throws {
        let (store, _) = makeStore(running: false)
        let composer = store.features.composer
        store.draft = "Refactor the tokenizer so that"
        composer.voice.showPreview(phase: .recording, interim: "string literals keep their escapes and")
        composer.setPermissionMode(.alwaysApprove)
        try write(composerScene(store, height: 300), size: CGSize(width: 820, height: 300), name: "recording")
        composer.voice.cancel()
    }

    func testRenderCompactionRows() throws {
        let (store, id) = makeStore(running: true)
        let composer = store.features.composer
        composer.showCompactionPreview(.running(started: Date().addingTimeInterval(-4.2)), for: id)
        store.draft = ""
        try write(composerScene(store, height: 260), size: CGSize(width: 820, height: 260), name: "compacting")
        let rows = VStack(spacing: 10) {
            ComposerCompactionRow(status: .completed(42.4), onStop: {}, onDismiss: {})
            ComposerCompactionRow(status: .failed("the summary request timed out"), onStop: {}, onDismiss: {})
            ComposerCompactionRow(status: .cancelled, onStop: {}, onDismiss: {})
        }.padding(24).frame(width: 760)
        try write(rows, size: CGSize(width: 760, height: 190), name: "compaction-outcomes")
    }

    func testRenderPermissionMenu() throws {
        let menu = ComposerPermissionMenu(current: .alwaysApprove, autoAvailable: true) { _ in }
            .padding(6).frame(width: 320)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .padding(20)
        try write(menu, size: CGSize(width: 360, height: 330), name: "permission-menu")
    }

    func testRenderNarrowComposer() throws {
        let (store, _) = makeStore(running: true)
        store.draft = "Queue this follow-up"
        try write(composerScene(store, width: 520, height: 220), size: CGSize(width: 520, height: 220), name: "narrow")
    }

    func testRenderEditPromptSheet() throws {
        let (store, _) = makeStore(running: false)
        let text = """
        # Parser cleanup

        Refactor `Tokenizer.next()` so string literals keep their escapes.

        1. Add failing tests for nested brackets and escaped quotes.
        2. Fix the tokenizer without changing the public API.
        3. Update the grammar table in docs/grammar.md.
        """
        try write(EditPromptSheet(initialText: text).desktopEnvironment(store), size: CGSize(width: 760, height: 620), name: "edit-prompt")
    }

    func testRenderBehaviorSettings() throws {
        let (store, _) = makeStore(running: false)
        let settings = BehaviorSettingsSection().desktopEnvironment(store).padding(20).frame(width: 640)
            .foregroundStyle(Theme.ink)
        try write(settings, size: CGSize(width: 640, height: 420), name: "settings")
    }
}
