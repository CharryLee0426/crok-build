import CoreGraphics
import Foundation

// winwait <pid> <spawn-epoch-seconds> <limit-seconds>: milliseconds from the spawn until the process
// owns a normal window at least 400 points wide. Works on a locked screen: it asks the window server.
let pid = Int(CommandLine.arguments[1])!
let spawned = Double(CommandLine.arguments[2])!
let limit = Double(CommandLine.arguments[3]) ?? 30
while Date().timeIntervalSince1970 - spawned < limit {
    if let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
            if let bounds = window[kCGWindowBounds as String] as? [String: Any], (bounds["Width"] as? Double ?? 0) >= 400 {
                print(Int((Date().timeIntervalSince1970 - spawned) * 1000))
                exit(0)
            }
        }
    }
    usleep(5_000)
}
print("timeout")
exit(1)
