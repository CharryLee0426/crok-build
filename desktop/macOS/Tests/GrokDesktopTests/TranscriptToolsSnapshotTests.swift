import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// PNGs of the transcript tools for visual review, written when GROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class TranscriptToolsSnapshotTests: XCTestCase {
    private var directory: URL!
    private var defaultsName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] != nil else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "GrokDesktopTranscriptSnapshots.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: defaultsName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()) }

    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private static let messages: [Message] = [
        Message(kind: .user, text: "Render the pricing tables with borders and a total row", createdAt: base),
        Message(kind: .thought, text: "The table renderer lives in MarkdownView. Borders need a stroke per cell.", createdAt: base.addingTimeInterval(4)),
        Message(kind: .tool, text: "Read `Sources/GrokDesktop/MarkdownView.swift`", status: "completed", detail: "struct MarkdownTableView: View {\n    let table: MarkdownTable\n}", createdAt: base.addingTimeInterval(6)),
        Message(kind: .assistant, text: "I added borders to every table cell and a bold total row. The table now reads well in both light and dark mode.", createdAt: base.addingTimeInterval(20)),
        Message(kind: .user, text: "Now make the header row sticky when the table scrolls", createdAt: base.addingTimeInterval(300)),
        Message(kind: .tool, text: "Edit `Sources/GrokDesktop/MarkdownView.swift`", status: "completed", detail: "+ .pinnedViews([.sectionHeaders])", createdAt: base.addingTimeInterval(310)),
        Message(kind: .assistant, text: "Done. The header row of each table now stays pinned while the rows scroll beneath it.", createdAt: base.addingTimeInterval(330)),
        Message(kind: .user, text: "Explain how the table width is measured", createdAt: base.addingTimeInterval(600)),
        Message(kind: .assistant, text: "Each column takes the widest cell, capped at half the reading width, and the table scrolls sideways past that.", createdAt: base.addingTimeInterval(640)),
    ]

    private func makeFixture(messages: [Message]? = nil) throws -> (AppStore, TranscriptToolsModel) {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), defaults: defaults, binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, title: "Render pricing tables", messages: messages ?? Self.messages)
        store.state = DesktopState(projects: [project], conversations: [task], selectedProjectID: project.id, selectedConversationID: task.id)
        let tools = TranscriptToolsModel(store: store, defaults: defaults, configURL: directory.appendingPathComponent("config.toml"))
        tools.grokHomeOverride = directory
        tools.pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.grok.desktop.snapshots.\(UUID().uuidString)"))
        return (store, tools)
    }

    private func render<V: View>(_ view: V, store: AppStore, tools: TranscriptToolsModel, size: CGSize, name: String) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // Offscreen windows do not pass their appearance to SwiftUI's color scheme, so set both.
            let styled = view.foregroundStyle(Theme.ink).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .environmentObject(tools).desktopEnvironment(store).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: styled.background(Theme.canvas))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            // Longer than the shared renderer waits, so searches and rankings started on appear land.
            for _ in 0..<12 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
            window.contentView = nil
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testFindBarTimelineAndTimestamps() async throws {
        let (store, tools) = try makeFixture()
        tools.setTimeline(true)
        tools.openFind("table")
        try await eventually { tools.findMatches.count > 1 }
        tools.moveFind(1)
        tools.visibleMessagesChanged(topIndex: 3, topID: Self.messages[3].id)
        try render(TranscriptView(), store: store, tools: tools, size: CGSize(width: 980, height: 760), name: "transcript-find")
    }

    func testTimelineHoverAndVimFocus() throws {
        let (store, tools) = try makeFixture()
        tools.setVimMode(true)
        tools.visibleMessagesChanged(topIndex: 4, topID: Self.messages[4].id)
        tools.handleVimKey(.down)
        let turns = TranscriptTurns.list(Self.messages)
        let ticks = TranscriptTimelineLayout.ticks(messages: Self.messages, turns: turns, expanded: [], compact: false)
        let view = HStack(spacing: 0) {
            TranscriptView().frame(width: 700)
            Color.clear.frame(width: 20)
        }
        .overlay(alignment: .trailing) {
            TranscriptTimelineRail(ticks: ticks, viewport: tools.viewport, onSelect: { _ in }, hovered: 1)
                .frame(height: 760)
        }
        try render(view, store: store, tools: tools, size: CGSize(width: 760, height: 760), name: "transcript-timeline-vim")
    }

    func testJumpSheet() throws {
        var messages = Self.messages
        for index in 0..<9 {
            messages.append(Message(kind: .user, text: index == 3 ? "  \n" : "Follow-up question number \(index + 4) about table layout, sticky headers, and very long previews that need to be truncated in the list", createdAt: Self.base.addingTimeInterval(Double(900 + index * 60))))
            messages.append(Message(kind: .assistant, text: "Answer \(index)"))
        }
        let (store, tools) = try makeFixture(messages: messages)
        tools.isFollowingOutput = false
        tools.visibleMessagesChanged(topIndex: 4, topID: messages[4].id)
        tools.openJump()
        tools.moveJump(to: 3)
        try render(JumpSheet(), store: store, tools: tools, size: CGSize(width: 600, height: 480), name: "jump-sheet")
    }

    func testHistorySheet() throws {
        let messages = ["fix the flaky transcript test", "add a timeline rail beside the conversation", "Explain the export format",
                        "refactor the find bar so it uses regular expressions\nand smart case", "rename the history sheet", "write tests for /copy"]
            .enumerated().map { Message(kind: .user, text: $0.element, createdAt: Self.base.addingTimeInterval(Double($0.offset * 60))) }
        let (store, tools) = try makeFixture(messages: messages)
        tools.loadHistory(scope: .task)
        try render(HistorySheet(initialQuery: "tr"), store: store, tools: tools, size: CGSize(width: 680, height: 580), name: "history-sheet")
    }

    /// Synchronous on purpose: a nested run loop inside an async test cannot run the main-actor
    /// tasks the window starts on appear (its search).
    func testTranscriptWindow() throws {
        let (store, tools) = try makeFixture()
        tools.loadDocument()
        let deadline = Date().addingTimeInterval(5)
        while tools.document == .loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try render(TranscriptWindow(), store: store, tools: tools, size: CGSize(width: 900, height: 700), name: "transcript-window")
        try render(TranscriptWindow(initialQuery: "sticky"), store: store, tools: tools, size: CGSize(width: 900, height: 560), name: "transcript-window-find")
    }

    func testDebugOverlay() throws {
        let (store, tools) = try makeFixture()
        tools.debug("scroll")
        tools.debug("fps")
        tools.debug("log")
        var timestamp: CFTimeInterval = 100
        for index in 0..<120 { timestamp += index % 17 == 0 ? 0.034 : 0.0167; tools.debugHUD.recordFrame(timestamp: timestamp) }
        tools.recordScroll(TranscriptScrollSample(offsetY: 1_240, contentHeight: 5_860, viewportHeight: 640))
        tools.recordScrollPhase("decelerating")
        tools.debugHUD.refresh()
        // Rows kept clear of the panels: offscreen, AppKit draws selectable text and scroll views
        // above SwiftUI overlays, which the live window does not.
        let view = ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 23) {
                ForEach(Self.messages.suffix(5)) { MessageView(message: $0, timestamp: $0.createdAt) }
            }.padding(.leading, 36).padding(.trailing, 320).padding(.top, 34).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            DebugOverlay()
        }
        try render(view, store: store, tools: tools, size: CGSize(width: 900, height: 520), name: "debug-hud")
        tools.debug("log")
    }

    func testDisplaySettings() throws {
        let (store, tools) = try makeFixture()
        tools.setTimeline(true)
        let view = DisplaySettingsSection().padding(24)
        try render(view, store: store, tools: tools, size: CGSize(width: 660, height: 420), name: "display-settings")
    }
}
