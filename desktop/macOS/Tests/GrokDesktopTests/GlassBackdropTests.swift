import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The window's glass: how much of the desktop each region shows, and how many layers blur it.
/// Every blur of the desktop is a layer the window server renders again whenever anything in the
/// window changes, so the conversation and the side panel tint the window's blur instead of adding
/// their own, and an inactive window has none.
@MainActor
final class GlassBackdropTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-glass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        store?.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testATintOverTheWindowsBackdropShowsTheDesktopAsItsOwnBlurDid() {
        for systemLook in [true, false] {
            for level in stride(from: 0.0, through: 1.0, by: 0.1) {
                let beneath = GlassPreference.tintOpacity(for: .sidebar, level: level, systemLook: systemLook)
                for role in [GlassBackdrop.Role.canvas, .panel] {
                    let own = GlassPreference.tintOpacity(for: role, level: level, systemLook: systemLook)
                    let overlay = GlassPreference.overlayOpacity(own, over: beneath)
                    XCTAssert((0...1).contains(overlay))
                    // What shows of the blur through both tints, and through the region's own tint before.
                    XCTAssertEqual((1 - beneath) * (1 - overlay), 1 - own, accuracy: 1e-9, "\(role) at \(level), system look \(systemLook)")
                }
            }
        }
    }

    func testSolidStaysSolidAndARegionNeverShowsMoreThanTheOneUnderIt() {
        XCTAssertEqual(GlassPreference.overlayOpacity(1, over: 1), 1)
        XCTAssertEqual(GlassPreference.overlayOpacity(0.4, over: 1), 1, "nothing shows through a solid backdrop")
        XCTAssertEqual(GlassPreference.overlayOpacity(0.2, over: 0.5), 0)
        XCTAssertEqual(GlassPreference.overlayOpacity(0.5, over: 0.5), 0, "the same tint twice adds nothing")
    }

    func testTheMainWindowBlursTheDesktopOnceAndOnlyWhileActive() throws {
        let project = Project(path: directory.path)
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        store.state = DesktopState(projects: [project], conversations: [], selectedProjectID: project.id, selectedConversationID: nil)
        store.showInspector = true
        self.store = store
        let previous = UserDefaults.standard.object(forKey: GlassPreference.key)
        UserDefaults.standard.set(GlassPreference.defaultLevel, forKey: GlassPreference.key)
        defer { UserDefaults.standard.set(previous, forKey: GlassPreference.key) }

        for active in [true, false] {
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1_240, height: 780),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView().environment(\.appearsActive, active).desktopEnvironment(store))
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.5)
            let blurs = Self.views(in: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSVisualEffectView }
                .filter { $0.blendingMode == .behindWindow && $0.material == .underWindowBackground }
            // The window's, and the sidebar column's (it covers the system's glass sidebar); the
            // conversation and the side panel tint the window's.
            XCTAssertEqual(blurs.count, active ? 2 : 0, active ? "one for the window and one for the sidebar" : "an inactive window is solid")
            let frames = blurs.map { $0.convert($0.bounds, to: nil) }
            XCTAssertEqual(frames.filter { $0.width >= window.frame.width - 1 }.count, active ? 1 : 0, "\(frames)")
            XCTAssertTrue(frames.allSatisfy { $0.width >= window.frame.width - 1 || $0.maxX <= 340 }, "nothing blurs in the detail column: \(frames)")
            window.contentView = nil
        }
    }

    /// Liquid Glass is rendered again whenever anything in its window changes, a blinking caret
    /// included, so the composer and the other raised controls only look like it.
    func testRaisedControlsLookLikeLiquidGlassWithoutUsingIt() throws {
        // Liquid Glass is drawn from signed distance fields (`CASDFLayer`, `SDFPortalLayer`).
        func glassLayers(_ view: some View) throws -> [String] {
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 480, height: 320),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view.environment(\.appearsActive, true))
            defer { window.contentView = nil }
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            spin(0.3)
            let layers = Self.layers(in: content.layer).map { String(describing: type(of: $0)) }
            return layers.filter { $0.contains("SDF") }
        }

        let controls = VStack(spacing: 20) {
            Text("Ask Crok").padding(24).glassSurface(cornerRadius: 24)
            Text("project").padding(8).glassSurface(in: Capsule(), interactive: true)
        }.padding(40)
        XCTAssertEqual(try glassLayers(controls), [])

        // The check sees Liquid Glass where there is some.
        #if canImport(SwiftUI, _version: 7)
        if #available(macOS 26.0, *) {
            XCTAssertNotEqual(try glassLayers(Text("Ask Crok").padding(24).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))), [])
        }
        #endif
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    private static func layers(in layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap(layers(in:))
    }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
