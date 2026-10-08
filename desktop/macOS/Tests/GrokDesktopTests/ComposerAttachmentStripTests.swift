import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// More attachments than the composer is wide: they stay in its card and scroll sideways.
@MainActor
final class ComposerAttachmentStripTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!

    /// The window, and how far the composer's card is from each of its sides.
    private let size = CGSize(width: 820, height: 300)
    private let margin: CGFloat = 60

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-attachment-strip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.contentView = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        return store
    }

    /// Files whose names are long enough for each chip to be as wide as a chip gets.
    private func files(_ range: Range<Int>) throws -> [URL] {
        try range.map { index in
            let url = directory.appendingPathComponent("tesla_invoice_2026_\(index)_c0ffee9b94e0e.pdf")
            try Data(repeating: 0x20, count: 1_024).write(to: url)
            return url
        }
    }

    private func show(_ store: AppStore) {
        let scene = VStack(spacing: 0) {
            Spacer(minLength: 0)
            ComposerView().padding(.horizontal, margin).padding(.bottom, 20)
        }
        .frame(width: size.width, height: size.height).foregroundStyle(Theme.ink).desktopEnvironment(store).background(Theme.canvas)
        host = NSHostingView(rootView: AnyView(scene))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        settle()
    }

    private func settle(_ seconds: Double = 0.5) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    private func picture(_ name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("composer-attachment-strip-\(name).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        return bitmap
    }

    /// How many sampled points between two x positions (in points) are drawn in something other than the window's background.
    private func inked(_ bitmap: NSBitmapImageRep, from minX: CGFloat, to maxX: CGFloat) throws -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let background = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: Int(minX * scale), to: Int(maxX * scale), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let difference = abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > 0.04 { count += 1 }
            }
        }
        return count
    }

    /// The strip: the scroll view that scrolls sideways (the prompt's own scrolls up and down).
    private func strip() throws -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, document.frame.width > scroll.contentView.bounds.width + 1 { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try XCTUnwrap(find(host), "no scroll view holds more than it shows")
    }

    func testManyAttachmentsStayInsideTheCard() throws {
        let store = makeStore()
        store.features.attachments.add(urls: try files(0..<8))
        show(store)

        let scroll = try strip()
        let frame = scroll.convert(scroll.bounds, to: host)
        XCTAssertEqual(frame.minX, margin, accuracy: 0.5, "the strip runs to the card's left edge")
        XCTAssertEqual(frame.maxX, size.width - margin, accuracy: 0.5, "and to its right edge")

        let start = try picture("start")
        XCTAssertGreaterThan(try inked(start, from: margin + 20, to: size.width - margin - 20), 500, "the chips are drawn")
        XCTAssertEqual(try inked(start, from: 0, to: margin - 1), 0, "nothing is drawn left of the card")
        XCTAssertEqual(try inked(start, from: size.width - margin + 1, to: size.width), 0, "nothing is drawn right of the card")

        // Scrolled part of the way, chips leave the card on both sides.
        scroll.contentView.scroll(to: CGPoint(x: 400, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.2)
        let middle = try picture("middle")
        XCTAssertEqual(try inked(middle, from: 0, to: margin - 1), 0, "nothing is drawn left of the card once scrolled")
        XCTAssertEqual(try inked(middle, from: size.width - margin + 1, to: size.width), 0, "nothing is drawn right of the card once scrolled")
    }

    func testAnAddedAttachmentIsScrolledIntoView() throws {
        let store = makeStore()
        let attachments = store.features.attachments
        attachments.add(urls: try files(0..<8))
        show(store)
        let scroll = try strip()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5, "the strip starts at its first attachment")

        attachments.add(urls: try files(8..<9))
        settle(0.8)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.contentView.bounds.maxX, document.frame.maxX, accuracy: 1, "the new attachment, the last one, is in view")
        _ = try picture("added")

        // Removing one leaves the strip where the user has it.
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.2)
        attachments.remove(try XCTUnwrap(attachments.current.first?.id))
        settle(0.8)
        XCTAssertEqual(scroll.contentView.bounds.minX, 300, accuracy: 1)
    }

    func testEachDraftsStripStartsAtItsFirstAttachment() throws {
        let store = makeStore()
        let attachments = store.features.attachments
        attachments.add(urls: try files(0..<8))
        let task = Conversation(projectID: try XCTUnwrap(store.state.selectedProjectID), title: "Another task")
        store.state.conversations = [task]
        store.selectConversation(task)
        attachments.add(urls: try files(0..<9))
        show(store)

        var scroll = try strip()
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.2)
        store.newTask()
        settle(0.8)
        scroll = try strip()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5, "the new task's draft is not scrolled as the task's was")

        // Going back shows more attachments than before, but none was added.
        store.selectConversation(task)
        settle(0.8)
        scroll = try strip()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5, "the task's draft is not scrolled to its end")
    }

    func testAFewAttachmentsStayWhereTheyAre() throws {
        let store = makeStore()
        let attachments = store.features.attachments
        attachments.add(urls: try files(0..<1))
        show(store)
        attachments.add(urls: try files(1..<2))
        settle(0.8)

        // Two chips fit, so there is nothing to scroll: the first sits at the card's padding.
        let bitmap = try picture("few")
        XCTAssertEqual(try inked(bitmap, from: margin, to: margin + 15), 0, "the padding left of the first chip is empty")
        XCTAssertGreaterThan(try inked(bitmap, from: margin + 16, to: margin + 60), 50, "the first chip starts after it")
    }
}
