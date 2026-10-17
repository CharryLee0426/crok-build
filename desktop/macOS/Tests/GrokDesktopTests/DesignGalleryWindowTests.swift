import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The main window's looks, pictured for a design review: the welcome page, a saved task, and a
/// task at work, each in light and dark. Like `TranscriptWindowTests`, the window is real but kept
/// under the desktop, so the window server draws its chrome, glass, and shader effects without
/// anyone seeing it. Runs with CROK_DESKTOP_DESIGN_SHOTS=<folder>, which receives the pictures;
/// set LIBRARIESDEV_METALLIB to a built LibrariesDev.metallib to see the liquid metal and beams
/// (third_party/LibrariesDev/build-shaders.sh), or leave it unset for the plain look.
@MainActor
final class DesignGalleryWindowTests: XCTestCase {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private var capture: Capture!
    private var directory: URL!
    private var store: AppStore!
    private var window: NSWindow!
    private var folder: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_DESIGN_SHOTS"] else {
            throw XCTSkip("Set CROK_DESKTOP_DESIGN_SHOTS=<folder> to picture the main window's looks")
        }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { throw XCTSkip("This macOS cannot picture a window by its number") }
        capture = unsafeBitCast(symbol, to: Capture.self)
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-design-gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentView = nil
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private enum Look: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
    }

    private func open(_ look: Look, tasks: [[Message]], selected: Int?, size: NSSize = NSSize(width: 1_240, height: 800)) -> [Conversation] {
        let folder = directory.appendingPathComponent("aurora", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(path: folder.path)
        let titles = ["Refactor the transcript list", "Ship the release notes", "Why does the build hang?", "Polish the welcome page"]
        let conversations = tasks.enumerated().map { Conversation(projectID: project.id, title: titles[$0.offset % titles.count], messages: $0.element) }
        store = AppStore(stateFile: directory.appendingPathComponent("state-\(look.rawValue)-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: conversations, selectedProjectID: project.id,
                                   selectedConversationID: selected.map { conversations[$0].id })
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = look.appearance
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        window.orderFrontRegardless()
        spin(1.4)
        return conversations
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @discardableResult
    private func picture(_ name: String, of shown: NSWindow? = nil) throws -> NSBitmapImageRep {
        // The test harness cannot list models; its banner is not part of the look.
        store.banner = nil
        spin(0.4)
        let target = shown ?? window!
        let image = try XCTUnwrap(capture(.null, 1 << 3, UInt32(target.windowNumber), 1)?.takeRetainedValue(), "the window server pictured the window")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private func close() {
        window.orderOut(nil)
        window.contentView = nil
        store.shutdown()
    }

    func testTheWelcomePage() throws {
        for look in Look.allCases {
            _ = open(look, tasks: [TranscriptListFixtures.showcase(), [], [], []], selected: nil)
            try picture("welcome-\(look.rawValue)")
            close()
        }
    }

    func testASavedTask() throws {
        for look in Look.allCases {
            _ = open(look, tasks: [TranscriptListFixtures.showcase(), [], [], []], selected: 0)
            try picture("task-\(look.rawValue)")
            close()
        }
    }

    func testSettings() throws {
        for look in Look.allCases {
            _ = open(look, tasks: [TranscriptListFixtures.showcase()], selected: 0, size: NSSize(width: 1_240, height: 900))
            store.showSettings = true
            let deadline = Date().addingTimeInterval(6)
            while window.attachedSheet == nil && Date() < deadline { spin(0.1) }
            spin(1.2)
            let sheet = try XCTUnwrap(window.attachedSheet, "Settings opens as a sheet")
            try picture("settings-\(look.rawValue)", of: sheet)
            store.showSettings = false
            spin(0.5)
            close()
        }
    }

    /// A turn in its two stages: the prompt waiting for an answer, when the composer's beam
    /// lights the wait, and the reasoning streaming in, when the thinking orbs show the work.
    func testATaskAtWork() throws {
        // These windows are never active or uncovered; let the effects run as they would on screen.
        WorkingBeam.runsInactive = true
        AgentOrbView.animatesWhenCovered = true
        defer { WorkingBeam.runsInactive = false; AgentOrbView.animatesWhenCovered = false }
        for look in Look.allCases {
            let prompt = Message(kind: .user, text: "Refactor how the transcript measures its rows")
            let conversations = open(look, tasks: [[prompt], [], [], []], selected: 0)
            var run = store.run
            run.isRunning = true
            run.phase = "Thinking"
            store.runs[conversations[0].id] = run
            // The beam fades in, then travels; partway along it is at its brightest.
            spin(2.4)
            try picture("waiting-\(look.rawValue)")
            store.state.conversations[0].messages.append(
                Message(kind: .thought, text: "Reading the list's layout code before changing how rows are measured.", status: "in_progress"))
            store.draft = "Also check the find bar"
            spin(1.2)
            try picture("working-\(look.rawValue)")
            close()
        }
    }
}
