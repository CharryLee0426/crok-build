import Foundation
import Metal
import SwiftUI

/// Where the Libraries.dev effects find their compiled Metal shaders, and how often they draw.
///
/// The shaders are compiled outside SwiftPM (`build-shaders.sh`) into `LibrariesDev.metallib`,
/// which an app bundles in its Resources. Tests and command-line runs can point
/// `LIBRARIESDEV_METALLIB` at a built copy. Without one, `isAvailable` is false and callers
/// should draw their plain look instead: a missing shader function draws nothing.
public enum LibrariesDevShaders {
    /// The library's file name in a bundle's Resources.
    public static let resourceName = "LibrariesDev"

    /// The compiled library, if one was found and Metal can load it.
    public static let url: URL? = {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["LIBRARIESDEV_METALLIB"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "metallib") {
            candidates.append(bundled)
        }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // Loading it once here also catches a library this macOS cannot read.
        return candidates.first { candidate in
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let library = try? device.makeLibrary(URL: candidate) else { return false }
            return library.functionNames.contains("mfxLiquidMetal")
        }
    }()

    /// Whether the shader effects can draw.
    public static var isAvailable: Bool { url != nil }

    /// The library every effect's `colorEffect` comes from.
    public static let library: ShaderLibrary = url.map { ShaderLibrary(url: $0) } ?? .default

    /// The shortest time between two frames of an animated effect: liquid metal and voice glow.
    /// The ports draw at the display's rate (120 Hz on a ProMotion screen); 30 fps keeps the slow
    /// flow of the metal smooth for a fraction of the work, as each frame rebuilds the effect's
    /// shapes on the main thread.
    nonisolated(unsafe) public static var frameInterval: TimeInterval = 1.0 / 30.0

    /// The same for thinking orbs, whose dots drift slowly enough that 30 fps reads as smooth,
    /// and of which an app may show several at once (one per running task).
    nonisolated(unsafe) public static var orbFrameInterval: TimeInterval = 1.0 / 30.0

    /// The same for border beams, whose light travels slowly and which can stay on for as long
    /// as an agent works; each frame redraws three element-sized shader layers and a blur.
    nonisolated(unsafe) public static var beamFrameInterval: TimeInterval = 1.0 / 30.0
}
