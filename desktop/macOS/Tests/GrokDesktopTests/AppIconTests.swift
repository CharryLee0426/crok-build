import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrokDesktop

final class AppIconTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("app-icon-\(UUID().uuidString).app", isDirectory: true)
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        // As build-app.sh names them: hashed, with or without the extension.
        let info: [String: Any] = ["CFBundleIdentifier": "dev.chenli.crok.desktop.icon-test",
                                   "CFBundleIconFile": "AppIcon-0123456789ab",
                                   "GrokDesktopDarkIconFile": "AppIconDark-ba9876543210.icns"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try writeIcon(pixels: 16, to: resources.appendingPathComponent("AppIcon-0123456789ab.icns"))
        try writeIcon(pixels: 32, to: resources.appendingPathComponent("AppIconDark-ba9876543210.icns"))
    }

    override func tearDownWithError() throws { if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) } }

    func testAnExplicitAppearanceKeepsItsArtworkWhateverTheSystemDoes() {
        for systemIsDark in [false, true] {
            XCTAssertEqual(AppIconVariant(appearance: "light", systemIsDark: systemIsDark), .light)
            XCTAssertEqual(AppIconVariant(appearance: "dark", systemIsDark: systemIsDark), .dark)
        }
    }

    func testTheAutoThemeFollowsTheSystem() {
        XCTAssertEqual(AppIconVariant(appearance: GrokTheme.auto.appearance, systemIsDark: false), .light)
        XCTAssertEqual(AppIconVariant(appearance: GrokTheme.auto.appearance, systemIsDark: true), .dark)
        // Before any theme is chosen there is no preference, which also follows the system.
        XCTAssertEqual(AppIconVariant(appearance: nil, systemIsDark: false), .light)
        XCTAssertEqual(AppIconVariant(appearance: nil, systemIsDark: true), .dark)
    }

    func testFixedThemesPickTheirAppearancesArtwork() {
        XCTAssertEqual(AppIconVariant(appearance: GrokTheme.grokday.appearance, systemIsDark: true), .light)
        XCTAssertEqual(AppIconVariant(appearance: GrokTheme.groknight.appearance, systemIsDark: false), .dark)
    }

    @MainActor
    func testLoadsEachVariantFromTheFileItsInfoPlistKeyNames() throws {
        let controller = AppIconController(bundle: try XCTUnwrap(Bundle(url: bundleURL)), apply: { _ in })
        XCTAssertEqual(controller.image(for: .light)?.representations.first?.pixelsWide, 16)
        XCTAssertEqual(controller.image(for: .dark)?.representations.first?.pixelsWide, 32)
    }

    @MainActor
    func testSwitchesAsTheSystemAndThePreferenceChange() throws {
        let app = NSApplication.shared
        let systemAppearance = app.appearance
        defer { app.appearance = systemAppearance }
        let suite = "dev.chenli.crok.desktop.icon-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(GrokTheme.auto.appearance, forKey: GrokThemePreferences.appearanceKey)
        var applied: [Int] = []
        let controller = AppIconController(bundle: try XCTUnwrap(Bundle(url: bundleURL)), defaults: defaults,
                                           apply: { applied.append($0.representations.first?.pixelsWide ?? 0) })

        app.appearance = NSAppearance(named: .aqua)
        controller.start()
        XCTAssertEqual(controller.shown, .light)

        app.appearance = NSAppearance(named: .darkAqua)
        settle()
        XCTAssertEqual(controller.shown, .dark)

        defaults.set(GrokTheme.grokday.appearance, forKey: GrokThemePreferences.appearanceKey)
        settle()
        XCTAssertEqual(controller.shown, .light)

        // Changes that keep the variant do not touch the Dock again.
        defaults.set("unrelated", forKey: "someOtherPreference")
        settle()
        XCTAssertEqual(applied, [16, 32, 16])
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func writeIcon(pixels: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
