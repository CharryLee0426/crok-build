// Crok patch: MetalFxKit was written for iOS, where the ring bends with the phone's tilt and a
// magnet near it. A Mac has neither sensor (CMMotionManager is unavailable on macOS), so there
// the kit's motion manager is a stand-in that never has data: the tilt and magnet sources read
// nothing and a ring holds its shape. On a Mac the pointer (`source: .pointer`) bends it.
import CoreMotion
import Foundation

#if os(macOS)
final class MetalMotionManager {
    var isDeviceMotionAvailable: Bool { false }
    var isDeviceMotionActive: Bool { false }
    var isMagnetometerAvailable: Bool { false }
    var isMagnetometerActive: Bool { false }
    var deviceMotionUpdateInterval: TimeInterval = 0
    var magnetometerUpdateInterval: TimeInterval = 0
    var deviceMotion: CMDeviceMotion? { nil }
    var magnetometerData: MetalMagnetometerData? { nil }
    func startDeviceMotionUpdates() {}
    func stopDeviceMotionUpdates() {}
    func startMagnetometerUpdates() {}
    func stopMagnetometerUpdates() {}
}

/// The magnetometer reading the kit reads, which macOS does not have.
struct MetalMagnetometerData {
    struct Field { var x = 0.0, y = 0.0, z = 0.0 }
    var magneticField = Field()
}

/// UIKit's interface orientations, which the iOS sources map device axes with.
public enum UIInterfaceOrientation: Sendable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}
#else
typealias MetalMotionManager = CMMotionManager
#endif
