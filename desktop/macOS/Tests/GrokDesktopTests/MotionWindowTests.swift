import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// What moves, as the window server shows it: a running tool call's spinner and blue sweep, the
/// thinking sparkle's turn, and the welcome page's starters rolling. Offscreen pictures draw no
/// Core Animation motion, so these picture a real window, kept under the desktop where nobody sees
/// it, a moment apart. Runs with CROK_DESKTOP_WINDOW_SHOTS=<folder>, which receives the pictures.
@MainActor
final class MotionWindowTests: XCTestCase {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private var capture: Capture!
    private var window: NSWindow!
    private var folder: URL!
    private var directory: URL!
    private var store: AppStore?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_WINDOW_SHOTS"] else {
            throw XCTSkip("Set CROK_DESKTOP_WINDOW_SHOTS=<folder> to picture motion in a real window, under the desktop")
        }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { throw XCTSkip("This macOS cannot picture a window by its number") }
        capture = unsafeBitCast(symbol, to: Capture.self)
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func show(_ view: NSView, size: NSSize) {
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFrontRegardless()
        spin(0.8)
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func picture(_ name: String) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue(), "the window server pictured the window")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        return bitmap
    }

    /// A view's frame in the window, from its top-left corner, in points.
    private func frame(of view: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: nil)
        return NSRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// How differently two pictures colour a region, on average per pixel (0 alike, 3 opposite).
    private func change(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: NSRect) -> Double {
        let scale = CGFloat(a.pixelsWide) / window.frame.width
        var total = 0.0, count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func testRunningToolsAndThinkingMoveAndStopWhenDone() throws {
        let tool = Message(kind: .tool, text: "Run `swift test --filter Snapshot`", toolID: "running", status: "in_progress", detail: "")
        let thought = Message(kind: .thought, text: "Reading the composer first, then the transcript rows.")
        var messages = [Message(kind: .user, text: "Polish the desktop app."), tool, thought]
        let list = TranscriptListView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        var display = TranscriptDisplay(conversation: UUID(), streamingID: thought.id, status: "Working…")
        list.apply(messages: messages, display: display)
        let canvas = TranscriptFillView(color: Theme.palette.canvasNS, radius: 0)
        canvas.frame = list.frame
        canvas.addSubview(list)
        show(canvas, size: list.frame.size)

        let toolRow = try XCTUnwrap(list.rowView(for: tool.id))
        let spinner = try XCTUnwrap(find(SpinnerLayerView.self, in: toolRow), "a running call has a spinner")
        let sparkle = try XCTUnwrap(find(TurningSymbolView.self, in: try XCTUnwrap(list.rowView(for: thought.id))))
        let spinnerFrame = frame(of: spinner), sparkleFrame = frame(of: sparkle)
        // The rim along the call's top edge, where the blue sweep runs.
        let rowFrame = frame(of: toolRow)
        let rim = NSRect(x: rowFrame.minX + 40, y: rowFrame.minY - 3, width: rowFrame.width - 80, height: 6)

        let first = try picture("motion-running-1")
        spin(0.23)
        let second = try picture("motion-running-2")
        XCTAssertGreaterThan(change(first, second, in: spinnerFrame), 0.02, "the spinner turns")
        XCTAssertGreaterThan(change(first, second, in: sparkleFrame), 0.01, "the sparkle turns while the model thinks")
        XCTAssertGreaterThan(change(first, second, in: rim), 0.005, "the blue sweep runs along the call")

        // The call completes and the turn ends: nothing moves any more.
        messages[1].status = "completed"
        display.streamingID = nil
        display.status = nil
        list.apply(messages: messages, display: display)
        spin(0.5)
        XCTAssertNil(find(SpinnerLayerView.self, in: toolRow), "a finished call has no spinner")
        let third = try picture("motion-done-1")
        spin(0.23)
        let fourth = try picture("motion-done-2")
        XCTAssertLessThan(change(third, fourth, in: spinnerFrame), 0.001, "the finished call is still")
        XCTAssertLessThan(change(third, fourth, in: sparkleFrame), 0.001, "the sparkle rests once the thinking is done")
        XCTAssertLessThan(change(third, fourth, in: rim), 0.001)
    }

    /// Where a large spinner's gap is, in degrees clockwise from twelve o'clock, picture by picture.
    private func gapAngles(_ spinner: SpinnerLayerView, pictures: Int = 4) throws -> [Double] {
        let center = spinner.convert(NSPoint(x: spinner.bounds.midX, y: spinner.bounds.midY), to: nil)
        let radius = Double(spinner.bounds.width) / 2 - 5
        var angles: [Double] = []
        for index in 0..<pictures {
            let bitmap = try picture("motion-spinner-\(index)")
            let scale = Double(bitmap.pixelsWide) / Double(window.frame.width)
            let x0 = Double(center.x), y0 = Double(window.frame.height - center.y)
            let lit = (0..<360).map { step -> Bool in
                let radians = Double(step) * .pi / 180
                let color = bitmap.colorAt(x: Int((x0 + radius * sin(radians)) * scale), y: Int((y0 - radius * cos(radians)) * scale))?.usingColorSpace(.sRGB)
                return (color?.redComponent ?? 0) > 0.5
            }
            // The middle of the longest unlit run.
            var best = (start: 0, length: 0), run = (start: 0, length: 0)
            for step in 0..<720 {
                if lit[step % 360] { run = (step + 1, 0) } else { run.length += 1; if run.length > best.length { best = run } }
            }
            angles.append(Double((best.start + best.length / 2) % 360))
            spin(0.1)
        }
        return angles
    }

    func testSpinnersTurnClockwiseWhereverTheySit() throws {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        struct Holder: NSViewRepresentable {
            let view: NSView
            func makeNSView(context: Context) -> NSView { view }
            func updateNSView(_ nsView: NSView, context: Context) {}
        }
        let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let cases: [(String, (NSView) -> NSView)] = [
            ("in a flipped view", { $0 }),
            ("in a plain view", { box in let plain = NSView(frame: frame); plain.addSubview(box); return plain }),
            ("under SwiftUI", { box in let host = NSHostingView(rootView: Holder(view: box).frame(width: 200, height: 200)); host.frame = frame; return host }),
        ]
        for (name, wrap) in cases {
            let box = Flipped(frame: frame)
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.cgColor
            let spinner = SpinnerLayerView(color: .white, lineWidth: 10)
            spinner.frame = NSRect(x: 40, y: 40, width: 120, height: 120)
            box.addSubview(spinner)
            show(wrap(box), size: frame.size)
            let angles = try gapAngles(spinner)
            let turned = zip(angles, angles.dropFirst()).map { (($1 - $0) + 540).truncatingRemainder(dividingBy: 360) - 180 }
            XCTAssertTrue(turned.allSatisfy { $0 > 10 && $0 < 90 }, "\(name), the gap moves clockwise a little each time: \(angles)")
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    func testTheStartersRollOneAfterAnother() throws {
        let project = Project(path: directory.path)
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: [], selectedProjectID: project.id, selectedConversationID: nil)
        self.store = store
        let host = NSHostingView(rootView: WelcomeView().foregroundStyle(Theme.ink).background(Theme.canvas).desktopEnvironment(store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        show(host, size: host.frame.size)
        let first = try picture("motion-welcome-1")
        spin(0.5)
        let settled = try picture("motion-welcome-2")
        let whole = NSRect(origin: .zero, size: window.frame.size)
        XCTAssertLessThan(change(first, settled, in: whole), 0.0005, "between rolls the page is still")
        spin(Double(StarterTicker.dwell) / 1_000_000_000)
        let rolled = try picture("motion-welcome-3")
        XCTAssertGreaterThan(change(settled, rolled, in: whole), 0.002, "another starter has rolled in")
    }
}
