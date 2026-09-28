// Measures and drives a running Crok Desktop from outside, through the Accessibility API.
//
// The app answers accessibility requests on its main thread, so the time one takes to come
// back is how long the main thread was busy: the same number for any build, with nothing
// compiled into the app. The terminal running this needs Accessibility permission.
//
//   swiftc -O ax-probe.swift -o ax-probe
//   ax-probe probe <pid> <out.csv> [interval-ms]   one line per request: Unix time, latency ms, AXError
//   ax-probe wait-window <pid> [timeout-s]         prints ms until the app has a window that answers
//   ax-probe send <pid> <text>                     types into the composer and presses Send
//   ax-probe press <pid> <title>                   presses the button with this title (a sidebar task)
//   ax-probe scroll <pid> <0…1>                    moves the transcript's scroller (0 is the top)
//   ax-probe action <pid> <title> <action>          performs a named action (e.g. "Move up") on a row
//   ax-probe drag <pid> <from> <to> [shot.png]      drags one sidebar row onto another with the real
//                                                   mouse, capturing the window halfway; moves the pointer
import AppKit
import ApplicationServices
import Foundation

func element(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 60)
    return app
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

/// Depth-first walk, stopping inside rows the caller has no use for.
func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, String) -> Bool) {
    guard depth < 40 else { return }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    guard visit(element, role) else { return }
    for child in children(element) { walk(child, depth: depth + 1, visit) }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
    FileHandle.standardError.write("usage: ax-probe probe|wait-window|send|press|scroll <pid> …\n".data(using: .utf8)!)
    exit(2)
}
let app = element(pid)

switch args[1] {
case "probe":
    let out = FileHandle(forWritingAtPath: args[3]) ?? {
        FileManager.default.createFile(atPath: args[3], contents: nil); return FileHandle(forWritingAtPath: args[3])!
    }()
    let interval = (args.count > 4 ? Double(args[4]) : nil) ?? 50
    signal(SIGTERM) { _ in exit(0) }
    while kill(pid, 0) == 0 {
        let wall = Date().timeIntervalSince1970
        let t0 = now()
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        let latency = (now() - t0) * 1000
        out.write(String(format: "%.3f,%.2f,%d\n", wall, latency, status.rawValue).data(using: .utf8)!)
        let rest = interval / 1000 - (now() - t0)
        if rest > 0 { usleep(useconds_t(rest * 1e6)) }
    }
case "wait-window":
    let timeout = (args.count > 3 ? Double(args[3]) : nil) ?? 120
    let start = now()
    while now() - start < timeout {
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty {
            print(String(format: "%.0f", (now() - start) * 1000)); exit(0)
        }
        usleep(20_000)
    }
    print("timeout"); exit(1)
case "send":
    var areas: [AXUIElement] = []
    var sendButton: AXUIElement?
    walk(app) { element, role in
        if role == kAXTextAreaRole as String { areas.append(element) }
        if role == kAXButtonRole as String, attribute(element, kAXDescriptionAttribute) as? String == "Send message" { sendButton = element }
        return true
    }
    guard let composer = areas.last else { print("no composer"); exit(1) }
    AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, args[3] as CFString)
    usleep(300_000)
    guard let sendButton else { print("no send button"); exit(1) }
    print(AXUIElementPerformAction(sendButton, kAXPressAction as CFString) == .success ? "sent" : "press failed")
case "press":
    var target: AXUIElement?
    walk(app) { element, role in
        guard target == nil else { return false }
        if role == kAXButtonRole as String,
           [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (attribute(element, $0) as? String)?.hasPrefix(args[3]) == true }) {
            target = element; return false
        }
        return true
    }
    guard let target else { print("no button \(args[3])"); exit(1) }
    let t0 = now()
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print(String(format: "%@ %.0f", result == .success ? "pressed" : "failed", (now() - t0) * 1000))
case "scroll":
    // The transcript is the tallest scroll area; its vertical scroller takes a 0…1 value.
    var best: (AXUIElement, CGFloat)?
    walk(app) { element, role in
        if role == kAXScrollAreaRole as String, let size = attribute(element, kAXSizeAttribute) {
            var cg = CGSize.zero
            AXValueGetValue(size as! AXValue, .cgSize, &cg)
            if cg.height * cg.width > (best?.1 ?? 0) { best = (element, cg.height * cg.width) }
        }
        return role != kAXScrollAreaRole as String
    }
    guard let area = best?.0, let bar = attribute(area, kAXVerticalScrollBarAttribute) else { print("no scroller"); exit(1) }
    let t0 = now()
    let status = AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, NSNumber(value: Double(args[3]) ?? 0))
    print(String(format: "%d %.0f", status.rawValue, (now() - t0) * 1000))
case "action", "drag":
    func find(_ title: String) -> AXUIElement? {
        var found: AXUIElement?
        walk(app) { element, role in
            guard found == nil else { return false }
            if role == kAXButtonRole as String,
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (attribute(element, $0) as? String)?.hasPrefix(title) == true }) {
                found = element; return false
            }
            return true
        }
        return found
    }
    func center(_ element: AXUIElement) -> CGPoint {
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(attribute(element, kAXPositionAttribute) as! AXValue, .cgPoint, &origin)
        AXValueGetValue(attribute(element, kAXSizeAttribute) as! AXValue, .cgSize, &size)
        return CGPoint(x: origin.x + min(size.width / 2, 60), y: origin.y + size.height / 2)
    }
    guard let source = find(args[3]) else { print("no row \(args[3])"); exit(1) }
    if args[1] == "action" {
        // Custom actions live on the row or the element that contains it.
        var target: AXUIElement? = source
        while let element = target {
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            if let name = (names as? [String])?.first(where: { $0.contains(args[4]) }) {
                print(AXUIElementPerformAction(element, name as CFString) == .success ? "performed \(args[4])" : "failed"); exit(0)
            }
            target = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        print("no action \(args[4])"); exit(1)
    }
    guard let destination = find(args[4]) else { print("no row \(args[4])"); exit(1) }
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(400_000)
    let from = center(source), to = center(destination)
    let saved = CGEvent(source: nil)?.location ?? .zero
    func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, from); usleep(150_000)
    post(.leftMouseDown, from); usleep(120_000)
    let steps = 24
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: from.x, y: from.y + (to.y - from.y) * t + (to.y > from.y ? 4 : -4) * t))
        usleep(25_000)
        if step == steps * 3 / 4, args.count > 5 {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if let id = windows.first(where: { $0[kCGWindowOwnerPID as String] as? pid_t == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowNumber as String] as? Int {
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", String(id), args[5]]
                try? shot.run(); shot.waitUntilExit()
            }
        }
    }
    usleep(150_000)
    post(.leftMouseUp, CGPoint(x: from.x, y: to.y + (to.y > from.y ? 4 : -4)))
    usleep(400_000)
    post(.mouseMoved, saved)
    print("dragged \(args[3]) → \(args[4])")
default:
    print("unknown command \(args[1])"); exit(2)
}
