import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// What the desktop's look costs (`Atelier.swift`): each effect's share of a core while it moves,
/// and the main window's while it rests on the welcome page and while a task works. The windows
/// are real but under the desktop, so they draw as on screen; the effects that stop in a covered
/// or inactive window are told to run anyway. Runs with CROK_DESKTOP_EFFECTS_CPU=1 (and
/// LIBRARIESDEV_METALLIB for the shader effects) and prints its figures, for comparing builds.
@MainActor
final class EffectsPerformanceTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_EFFECTS_CPU"] != nil else {
            throw XCTSkip("Set CROK_DESKTOP_EFFECTS_CPU=1 to measure what the effects cost")
        }
        AgentOrbView.animatesWhenCovered = true
        WorkingBeam.runsInactive = true
    }

    override func tearDown() async throws {
        AgentOrbView.animatesWhenCovered = false
        WorkingBeam.runsInactive = false
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func underDesktop(_ size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        return window
    }

    /// Share of one core over `seconds`, after a settling spin.
    private func share(settle: Double = 2, over seconds: Double = 8) -> Double {
        spin(settle)
        let start = cpuSeconds()
        spin(seconds)
        return (cpuSeconds() - start) / seconds * 100
    }

    func testEachEffect() throws {
        func measure(_ name: String, _ make: () -> NSView) -> String {
            let window = underDesktop(NSSize(width: 600, height: 300))
            window.contentView = make()
            window.orderFrontRegardless()
            let value = share()
            window.orderOut(nil)
            window.contentView = nil
            return String(format: "%@=%.1f%%", name, value)
        }
        var lines: [String] = []
        lines.append(measure("empty") { NSHostingView(rootView: Color.black) })
        lines.append(measure("spinner") { NSHostingView(rootView: ProgressView().controlSize(.mini).frame(width: 600, height: 300)) })
        lines.append(measure("orb") { NSHostingView(rootView: AgentOrb(activity: .working, size: 16).frame(width: 600, height: 300)) })
        lines.append(measure("orb-status") { let view = NSView(); view.addSubview(AgentOrbView(activity: .thinking, size: 20)); return view })
        lines.append(measure("beam") { NSHostingView(rootView: Color.gray.frame(width: 500, height: 120).workingBeam(true, cornerRadius: 24).frame(width: 600, height: 300)) })
        let send = { NSHostingView(rootView: MetalSendButton(symbol: "arrow.up", enabled: true, help: "", label: "", action: {}).frame(width: 600, height: 300)) }
        lines.append(measure("metal-still", send))
        MetalLiveness.alwaysLive = true
        defer { MetalLiveness.alwaysLive = false }
        lines.append(measure("metal-live", send))
        print("EFFECTS-EACH " + lines.joined(separator: " "))
    }

    func testTheWindowAtRestAndAtWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("effects-cpu-\(UUID().uuidString)/aurora", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let project = Project(path: directory.path)
        var working = Conversation(projectID: project.id, title: "Refactor the transcript list")
        working.messages = [Message(kind: .user, text: "Show me every kind of row"),
                            Message(kind: .thought, text: "Reading the list's layout code before changing how rows are measured.", status: "in_progress")]
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        store.state = DesktopState(projects: [project], conversations: [working], selectedProjectID: project.id, selectedConversationID: nil)
        let window = underDesktop(NSSize(width: 1_240, height: 800))
        window.contentView = NSHostingView(rootView: ContentView().desktopEnvironment(store))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        // Past every start-up animation, then a quiet stretch on the welcome page.
        let welcome = share(settle: 8, over: 10)
        store.selectConversation(store.state.conversations[0])
        var run = store.run
        run.isRunning = true
        run.phase = "Thinking"
        store.runs[working.id] = run
        let busy = share(settle: 4, over: 10)
        // Before the turn's first output: the composer's beam lights the wait.
        store.state.conversations[0].messages.removeLast()
        let waiting = share(settle: 2, over: 10)
        print(String(format: "EFFECTS-WINDOW welcome_idle=%.1f%% working=%.1f%% waiting=%.1f%%", welcome, busy, waiting))
    }
}
