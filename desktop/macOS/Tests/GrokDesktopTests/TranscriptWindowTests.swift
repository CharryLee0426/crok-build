import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The transcript in the real main window, as the window server composites it: under the title
/// bar and its glass, beside the sidebar and the side panel, with the find bar over it. The
/// offscreen pictures the other tests take (`cacheDisplay`) draw neither the window's chrome nor
/// Core Animation's masks and motion as the screen shows them; these do.
///
/// The window is real and ordered in, but kept under the desktop, where nobody sees it and no
/// click reaches it, and the pictures are the app's own windows, which need no screen-recording
/// permission. Runs with CROK_DESKTOP_WINDOW_SHOTS=<folder>, which receives the pictures.
@MainActor
final class TranscriptWindowTests: XCTestCase {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private var capture: Capture!
    private var directory: URL!
    private var store: AppStore!
    private var window: NSWindow!
    private var folder: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_WINDOW_SHOTS"] else {
            throw XCTSkip("Set CROK_DESKTOP_WINDOW_SHOTS=<folder> to draw the main window for real, under the desktop")
        }
        // Still there on macOS 27, though the SDK no longer declares it.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { throw XCTSkip("This macOS cannot picture a window by its number") }
        capture = unsafeBitCast(symbol, to: Capture.self)
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-transcript-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func open(_ tasks: [[Message]], size: NSSize = NSSize(width: 1_240, height: 780)) -> [Conversation] {
        let project = Project(path: directory.path)
        let conversations = tasks.enumerated().map { Conversation(projectID: project.id, title: "Task \($0.offset + 1)", messages: $0.element) }
        store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: conversations, selectedProjectID: project.id, selectedConversationID: conversations[0].id)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        window.orderFrontRegardless()
        spin(1.2)
        return conversations
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The window as the window server draws it, without its shadow.
    @discardableResult
    private func picture(_ name: String) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue(), "the window server pictured the window")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private var list: TranscriptListView {
        get throws {
            func find(_ view: NSView) -> TranscriptListView? { (view as? TranscriptListView) ?? view.subviews.lazy.compactMap(find).first }
            return try XCTUnwrap(window.contentView.flatMap(find), "the transcript is the AppKit list")
        }
    }

    private var titleBar: CGFloat { window.frame.height - window.contentLayoutRect.height }
    private var tools: TranscriptToolsModel { store.features.transcript }

    /// How far below the window's top a row's top is.
    private func top(of id: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let list = try list
        let row = try XCTUnwrap(list.rowView(for: id), "the row is in sight", file: file, line: line)
        return window.frame.height - row.convert(row.bounds, to: nil).maxY
    }

    func testTheRowsStayClearOfTheTitleBarAndTheFindBar() throws {
        let messages = TranscriptListFixtures.showcase()
        _ = open([messages])
        let list = try list
        XCTAssertGreaterThan(titleBar, 20, "the window has its title bar and toolbar")
        // The list runs under the title bar, to the window's top, and keeps its rows out from under it.
        XCTAssertEqual(list.convert(list.bounds, to: nil).maxY, window.frame.height, accuracy: 0.5, "the list reaches the top of the window")
        XCTAssertEqual(list.scrollView.contentInsets.top, titleBar, accuracy: 0.5)
        XCTAssertTrue(list.isFollowing)
        try picture("1-at-its-end")
        // At its very start a transcript rests with its first row under the title bar and its padding.
        let clip = list.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -10_000))
        spin(0.4)
        XCTAssertEqual(try top(of: messages[0].id), titleBar + TranscriptMetrics.topPadding, accuracy: 1)
        try picture("2-at-its-start")
        // The find bar opens under the title bar; the row it finds is under the find bar.
        tools.openFind("kind of row")
        spin(0.8)
        XCTAssertEqual(tools.currentFindMessageID, messages[0].id)
        XCTAssertGreaterThan(list.scrollView.contentInsets.top, titleBar + 40, "the find bar covers more of the list's top")
        XCTAssertEqual(try top(of: messages[0].id), list.scrollView.contentInsets.top, accuracy: 1, "the match is just under it")
        try picture("3-find")
        tools.closeFind()
        spin(0.4)
        XCTAssertEqual(list.scrollView.contentInsets.top, titleBar, accuracy: 0.5, "and gives it back when it closes")
    }

    func testALongTaskStaysAtItsEndAsTheWindowAndItsPanelsChange() throws {
        let messages = TranscriptListFixtures.longSession(rounds: 3_000)
        _ = open([messages])
        var list = try list
        func atEnd(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            let clip = list.scrollView.contentView.bounds
            XCTAssertLessThanOrEqual(abs(list.documentHeight - clip.maxY), 1, "\(what): the end is in sight", file: file, line: line)
            XCTAssertEqual(list.topVisibleRow.map { $0 > messages.count - 60 }, true, "\(what): the newest rows are", file: file, line: line)
            XCTAssertLessThan(list.realizedRowCount, 160, "\(what): a screenful of rows has views", file: file, line: line)
        }
        atEnd("opened")
        try picture("4-long-task")
        for size in [NSSize(width: 1_000, height: 700), NSSize(width: 1_440, height: 860), NSSize(width: 1_240, height: 780)] {
            window.setContentSize(size)
            spin(0.5)
            list = try self.list
            atEnd("at \(Int(size.width)) × \(Int(size.height))")
        }
        // A side panel slides in and out beside the transcript.
        store.sidePanelTab = .files
        store.showInspector = true
        spin(0.8)
        list = try self.list
        atEnd("with the side panel")
        try picture("5-side-panel")
        store.showInspector = false
        spin(0.8)
        list = try self.list
        atEnd("without it again")
        // A reader in the middle keeps their place through the same.
        let id = messages[7_501].id
        tools.requestScroll(.message(id))
        spin(0.5)
        XCTAssertEqual(try top(of: id), titleBar, accuracy: 1, "the message asked for is just under the title bar")
        for size in [NSSize(width: 1_000, height: 700), NSSize(width: 1_440, height: 860)] {
            window.setContentSize(size)
            spin(0.5)
            XCTAssertEqual(try top(of: id), titleBar, accuracy: 1, "and still is at \(Int(size.width)) × \(Int(size.height))")
        }
        try picture("6-middle")
    }

    func testABlockOpensInPlaceWhileTheRowsAfterItSlide() throws {
        let messages = TranscriptListFixtures.showcase()
        _ = open([messages])
        let list = try list
        list.scrollView.contentView.scroll(to: NSPoint(x: 0, y: -10_000))
        spin(0.4)
        // The command after the one that opens: where it is, frame by frame.
        let opened = messages[2].id, after = messages[4].id
        let folded = try top(of: after), block = try top(of: opened)
        tools.setExpanded(opened, true)
        var seen: [CGFloat] = []
        for frame in 0..<12 {
            spin(0.02)
            if frame == 1 { try picture("7-opening") }
            if let row = list.rowView(for: after), let shown = row.layer?.presentation() {
                // Where Core Animation has the row now, on its way.
                seen.append(shown.frame.minY - (row.layer?.frame.minY ?? 0))
            }
        }
        spin(0.4)
        let unfolded = try top(of: after)
        XCTAssertGreaterThan(unfolded, folded + 40, "the rows after the block moved down")
        XCTAssertEqual(try top(of: opened), block, accuracy: 0.5, "the block opened where it was")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(seen.contains { $0 < -1 }, "they were carried there, from where they had been: \(seen)")
            XCTAssertEqual(seen.sorted(), seen, "without turning back")
        }
        try picture("7-opened-fully")
    }

    func testReasoningThatStreamsFadesAtItsTop() throws {
        var messages = Array(TranscriptListFixtures.showcase().prefix(1))
        messages.append(Message(kind: .thought, text: MarkdownTestDocuments.thinking(lines: 12)))
        // The list alone, on the window's canvas: a stream needs no harness here.
        let list = TranscriptListView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let canvas = TranscriptFillView(color: Theme.palette.canvasNS, radius: 0)
        canvas.frame = list.frame
        canvas.addSubview(list)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = canvas
        window.orderFrontRegardless()
        list.apply(messages: messages, display: TranscriptDisplay(conversation: UUID(), streamingID: messages[1].id, status: "Thinking…"))
        spin(0.6)
        let bitmap = try picture("8-streaming")
        func boxes(_ view: NSView) -> [TranscriptTextBox] { ((view as? TranscriptTextBox).map { [$0] } ?? []) + view.subviews.flatMap(boxes) }
        let glimpse = try XCTUnwrap(boxes(list).first { $0.fadesTop }, "the folded block shows a glimpse of its newest lines")
        let frame = glimpse.convert(glimpse.bounds, to: nil)
        let scale = CGFloat(bitmap.pixelsHigh) / window.frame.height
        /// The darkest the text gets in a band of the glimpse, from 0 (black) to 1.
        func darkest(from start: CGFloat, to end: CGFloat) -> CGFloat {
            var darkest: CGFloat = 1
            for y in stride(from: Int((window.frame.height - frame.maxY + start) * scale), to: Int((window.frame.height - frame.maxY + end) * scale), by: 1) {
                for x in stride(from: Int(frame.minX * scale), to: Int((frame.minX + 500) * scale), by: 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { darkest = min(darkest, (color.redComponent + color.greenComponent + color.blueComponent) / 3) }
                }
            }
            return darkest
        }
        let top = darkest(from: 0, to: 8), middle = darkest(from: 40, to: 70), bottom = darkest(from: frame.height - 22, to: frame.height - 2)
        XCTAssertGreaterThan(top, middle + 0.15, "the lines fade as they leave by the top: \(top) against \(middle)")
        XCTAssertEqual(bottom, middle, accuracy: 0.08, "and the newest line is as dark as the rest")
    }
}
