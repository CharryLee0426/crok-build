import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// A `browser` or `computer` tool call as the model made it. The transcript and the approval card
/// word it from this each time they draw, so it follows the interface language.
struct DeviceCall: Codable, Sendable, Equatable {
    /// The `computer` tool; the `browser` tool otherwise.
    var computer: Bool
    var action: String
    var ref: String?
    var coordinate: [Double]?
    var url: String?
    var text: String?
    var query: String?
    var tab: String?
    var direction: String?
    var duration: Double?
    var paths: [String]?

    /// The call in a tool call's `rawInput`, which names its tool in `variant`.
    init?(rawInput: Any?) {
        guard let input = rawInput as? [String: Any], let action = input["action"] as? String else { return nil }
        switch input["variant"] as? String {
        case "Browser": computer = false
        case "Computer": computer = true
        default: return nil
        }
        self.action = action
        ref = input["ref"] as? String
        coordinate = (input["coordinate"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        url = input["url"] as? String
        text = input["text"] as? String
        query = input["query"] as? String
        tab = input["tab_id"] as? String ?? (input["tab_id"] as? NSNumber)?.stringValue
        direction = input["scroll_direction"] as? String
        duration = (input["duration"] as? NSNumber)?.doubleValue
        paths = (input["paths"] as? [Any])?.compactMap { $0 as? String }
    }

    /// The tool's name, as a title starts.
    var family: String { computer ? L10n.t("device_computer", "Computer") : L10n.t("device_browser", "Browser") }

    var symbol: String { computer ? "cursorarrow.rays" : "globe" }

    /// The tool and the action on one line: "Browser: Click ref_3".
    var title: String { L10n.t("device_title", "{family}: {action}", ["family": family, "action": phrase]) }

    /// What would be typed, run, uploaded, or opened, for the approval card to show under its title.
    var approvalDetail: String {
        switch action {
        case "type", "javascript_exec":
            return (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n")
        case "file_upload": return (paths ?? []).joined(separator: "\n")
        // The title shortens a long address.
        case "navigate": return (url?.count ?? 0) > Self.urlLength ? url ?? "" : ""
        default: return ""
        }
    }

    /// What the call does: "Click ref_3", "Open https://example.com".
    var phrase: String {
        switch action {
        case "navigate":
            switch Self.trimmed(url) {
            case "back"?: return L10n.t("device_go_back", "Go back")
            case "forward"?: return L10n.t("device_go_forward", "Go forward")
            case "reload"?: return L10n.t("device_reload", "Reload page")
            case let url?: return L10n.t("device_open_url", "Open {url}", ["url": Self.short(url, Self.urlLength)])
            case nil: return L10n.t("device_open_page", "Open a page")
            }
        case "screenshot": return L10n.t("device_screenshot", "Take a screenshot")
        case "zoom": return L10n.t("device_zoom", "Zoom in")
        case "left_click":
            return target.map { L10n.t("device_click_target", "Click {target}", ["target": $0]) } ?? L10n.t("device_click", "Click")
        case "right_click":
            return target.map { L10n.t("device_right_click_target", "Right-click {target}", ["target": $0]) } ?? L10n.t("device_right_click", "Right-click")
        case "middle_click":
            return target.map { L10n.t("device_middle_click_target", "Middle-click {target}", ["target": $0]) } ?? L10n.t("device_middle_click", "Middle-click")
        case "double_click":
            return target.map { L10n.t("device_double_click_target", "Double-click {target}", ["target": $0]) } ?? L10n.t("device_double_click", "Double-click")
        case "triple_click":
            return target.map { L10n.t("device_triple_click_target", "Triple-click {target}", ["target": $0]) } ?? L10n.t("device_triple_click", "Triple-click")
        case "hover":
            return target.map { L10n.t("device_hover_target", "Hover over {target}", ["target": $0]) } ?? L10n.t("device_move_pointer", "Move the pointer")
        case "mouse_move":
            return target.map { L10n.t("device_move_pointer_to", "Move the pointer to {target}", ["target": $0]) } ?? L10n.t("device_move_pointer", "Move the pointer")
        case "left_click_drag":
            return target.map { L10n.t("device_drag_to", "Drag to {target}", ["target": $0]) } ?? L10n.t("device_drag", "Drag")
        case "left_mouse_down": return L10n.t("device_mouse_down", "Press the mouse button")
        case "left_mouse_up": return L10n.t("device_mouse_up", "Release the mouse button")
        case "scroll":
            switch Self.trimmed(direction) {
            case "up"?: return L10n.t("device_scroll_up", "Scroll up")
            case "down"?: return L10n.t("device_scroll_down", "Scroll down")
            case "left"?: return L10n.t("device_scroll_left", "Scroll left")
            case "right"?: return L10n.t("device_scroll_right", "Scroll right")
            default: return L10n.t("device_scroll_page", "Scroll the page")
            }
        case "scroll_to":
            return target.map { L10n.t("device_scroll_to", "Scroll to {target}", ["target": $0]) } ?? L10n.t("device_scroll_page", "Scroll the page")
        case "type": return L10n.t("device_type", "Type “{text}”", ["text": shortText])
        case "key": return L10n.t("device_press", "Press {keys}", ["keys": shortText])
        case "hold_key": return L10n.t("device_hold", "Hold {keys}", ["keys": shortText])
        case "wait": return L10n.t("device_wait", "Wait {seconds} s", ["seconds": seconds])
        case "read_page": return L10n.t("device_read_page", "Read the page")
        case "find": return L10n.t("device_find", "Find “{query}”", ["query": Self.short(Self.trimmed(query) ?? "", 48)])
        case "get_page_text": return L10n.t("device_page_text", "Read the page text")
        case "form_input":
            return target.map { L10n.t("device_fill_target", "Fill in {target}", ["target": $0]) } ?? L10n.t("device_fill_field", "Fill in a field")
        case "file_upload": return L10n.t("device_upload", "Upload files")
        case "read_console": return L10n.t("device_console", "Read the console")
        case "read_network": return L10n.t("device_network", "Read network requests")
        case "javascript_exec": return L10n.t("device_javascript", "Run JavaScript")
        case "new_tab": return L10n.t("device_new_tab", "Open a new tab")
        case "list_tabs": return L10n.t("device_list_tabs", "List tabs")
        case "switch_tab": return L10n.t("device_switch_tab", "Switch to {tab}", ["tab": Self.trimmed(tab) ?? ""])
        case "close_tab": return L10n.t("device_close_tab", "Close {tab}", ["tab": Self.trimmed(tab) ?? ""])
        case "cursor_position": return L10n.t("device_cursor", "Find the pointer")
        default: return action
        }
    }

    private static let urlLength = 96

    /// What the call points at: an element reference, or a point in the screenshot.
    private var target: String? {
        if let ref = Self.trimmed(ref) { return ref }
        guard let point = coordinate, point.count == 2 else { return nil }
        return "(\(Int(point[0].rounded())), \(Int(point[1].rounded())))"
    }

    /// The text typed or the keys pressed, on one line and cut short.
    private var shortText: String { Self.short((Self.trimmed(text) ?? "").replacingOccurrences(of: "\n", with: " "), 48) }

    private var seconds: String {
        guard let duration else { return "" }
        return duration.rounded() == duration ? String(Int(duration)) : String(duration)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func short(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

extension Message {
    /// A tool call's title: a browser or computer call worded in the interface language, any other as the harness titled it.
    var toolTitle: String { device?.title ?? text }

    /// A tool call's status in the interface language.
    var statusLabel: String {
        switch status ?? "pending" {
        case "pending": return L10n.t("tool_status_pending", "pending")
        case "in_progress": return L10n.t("tool_status_in_progress", "in progress")
        case "completed": return L10n.t("tool_status_completed", "completed")
        case "failed": return L10n.t("tool_status_failed", "failed")
        case let other: return other.replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension Approval {
    /// The card's title: a browser or computer action worded in the interface language.
    var shownTitle: String { device.map { L10n.t("device_allow", "Allow {tool}?", ["tool": $0.title]) } ?? title }
}

extension PermissionOption {
    /// The answer in the interface language when the harness worded it; any other as it arrived.
    var shownName: String {
        switch name {
        case "Yes": return L10n.t("permission_yes", "Yes")
        case "Yes, proceed": return L10n.t("permission_yes_proceed", "Yes, proceed")
        case "Yes, allow once": return L10n.t("permission_yes_allow_once", "Yes, allow once")
        case "Yes, send once": return L10n.t("permission_yes_send_once", "Yes, send once")
        case "Yes, allow all edits during this session": return L10n.t("permission_edits_session", "Yes, allow all edits during this session")
        case "Yes, allow browser actions for this session": return L10n.t("permission_browser_session", "Yes, allow browser actions for this session")
        case "Yes, allow computer use for this session": return L10n.t("permission_computer_session", "Yes, allow computer use for this session")
        case "Yes, and don't ask again for anything (always-approve mode)":
            return L10n.t("permission_always_approve", "Yes, and don't ask again for anything (always-approve mode)")
        case "Yes, and don't ask again for bash commands": return L10n.t("permission_always_bash", "Yes, and don't ask again for bash commands")
        case "No, and tell Crok what to do differently": return L10n.t("permission_reject_tell", "No, and tell Crok what to do differently")
        case "No, and don't ask again for this command": return L10n.t("permission_reject_command", "No, and don't ask again for this command")
        case "always allow": return L10n.t("permission_always_allow", "always allow")
        case "allow once": return L10n.t("permission_allow_once", "allow once")
        case "reject once": return L10n.t("permission_reject_once", "reject once")
        default: break
        }
        // Answers that name a site or a tool, recognized by the words around the name.
        let named: [(pattern: String, word: (String) -> String)] = [
            ("Yes, always allow {name} for this project", { L10n.t("permission_always_project", "Yes, always allow {name} for this project", ["name": $0]) }),
            ("No, never allow {name} for this project", { L10n.t("permission_never_project", "No, never allow {name} for this project", ["name": $0]) }),
            ("Always allow: {name}", { L10n.t("permission_always_named", "Always allow: {name}", ["name": $0]) }),
            ("Never allow: {name}", { L10n.t("permission_never_named", "Never allow: {name}", ["name": $0]) }),
        ]
        for answer in named {
            let (head, tail) = L10n.split(answer.pattern, around: "name")
            guard name.count > head.count + tail.count, name.hasPrefix(head), name.hasSuffix(tail) else { continue }
            return answer.word(String(name.dropFirst(head.count).dropLast(tail.count)))
        }
        return name
    }
}

/// Whether new tasks get the `browser` and `computer` tools (`[features]` in config.toml, shared
/// with the terminal), and the macOS permissions computer use needs.
@MainActor
final class DeviceUseSettings: ObservableObject {
    /// Tests that run `/browser-use` or open Settings write a file of their own, never the user's config.toml.
    static let shared = DeviceUseSettings(configURL: NSClassFromString("XCTestCase") == nil ? GrokPaths.configFile
        : FileManager.default.temporaryDirectory.appendingPathComponent("crok-device-use-\(ProcessInfo.processInfo.processIdentifier).toml"))

    enum Feature {
        case browser, computer
        /// The key under `[features]`.
        var key: String { self == .browser ? "browser_use" : "computer_use" }
    }

    enum Permission {
        case screenRecording, accessibility
        /// Its page in System Settings › Privacy & Security.
        var settingsURL: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"))!
        }
    }

    @Published private(set) var browserUse = false
    @Published private(set) var computerUse = false
    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false

    private let configURL: URL
    /// The permissions macOS has been asked for since launch. It prompts once; after that Allow opens System Settings.
    private var asked: Set<Permission> = []

    init(configURL: URL) {
        self.configURL = configURL
        refresh()
    }

    func isOn(_ feature: Feature) -> Bool { feature == .browser ? browserUse : computerUse }

    func isGranted(_ permission: Permission) -> Bool { permission == .screenRecording ? screenRecording : accessibility }

    /// Reads the switches from config.toml and the permissions from macOS.
    func refresh() {
        let config = GrokConfig(url: configURL)
        browserUse = config.bool(Feature.browser.key, in: "features") ?? false
        computerUse = config.bool(Feature.computer.key, in: "features") ?? false
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Saves a switch for new tasks; returns the banner that says what happened. Turning computer
    /// use on asks macOS for what it still lacks, so its prompts come while the user is here.
    @discardableResult
    func set(_ feature: Feature, _ on: Bool) -> String {
        do {
            try GrokConfig.update(url: configURL) { try $0.set(feature.key, to: .bool(on), in: "features") }
        } catch {
            refresh()
            return L10n.t("device_save_failed", "Could not save [features].{key}: {error}", ["key": feature.key, "error": error.localizedDescription])
        }
        switch feature {
        case .browser: browserUse = on
        case .computer: computerUse = on
        }
        if feature == .computer, on {
            for permission in [Permission.screenRecording, .accessibility] where !isGranted(permission) && !asked.contains(permission) { prompt(permission) }
            refresh()
        }
        return feature == .browser
            ? L10n.t("device_banner_browser", "✓ Browser use: {state} · new tasks get it", ["state": L10n.onOff(on)])
            : L10n.t("device_banner_computer", "✓ Computer use: {state} · new tasks get it", ["state": L10n.onOff(on)])
    }

    /// `/browser-use` and `/computer-use`: on, off, or nothing to switch it, as in the terminal.
    func command(_ feature: Feature, arguments: String) -> String {
        refresh()
        switch arguments.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return set(feature, !isOn(feature))
        case "on", "true", "yes", "enable", "enabled": return set(feature, true)
        case "off", "false", "no", "disable", "disabled": return set(feature, false)
        default: return L10n.t("device_command_usage", "Use on or off, or no argument to switch it")
        }
    }

    /// The Allow button: macOS's own prompt the first time, the permission's page in System Settings after that.
    func request(_ permission: Permission) {
        if asked.contains(permission) { NSWorkspace.shared.open(permission.settingsURL) } else { prompt(permission) }
        refresh()
    }

    private func prompt(_ permission: Permission) {
        asked.insert(permission)
        switch permission {
        case .screenRecording: CGRequestScreenCaptureAccess()
        case .accessibility: AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }
}

/// Settings › Browser and computer use: the two switches, and for computer use the macOS
/// permissions it needs.
struct DeviceUseSettingsSection: View {
    @ObservedObject private var language = L10n.state
    @EnvironmentObject var store: AppStore
    @ObservedObject private var model: DeviceUseSettings

    /// Tests pass a `model` reading a config file of their own.
    init(model: DeviceUseSettings = .shared) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("device_settings_title", "Browser and computer use"), systemImage: "cursorarrow.rays").font(.system(size: 15, weight: .semibold))
            row(L10n.t("device_browser_use", "Browser use"),
                detail: L10n.t("device_browser_use_detail", "Crok opens web pages in a Chrome, Edge, Brave, or Chromium window with a profile of its own, apart from yours, and clicks, types, and reads in them. New tasks get it.")) {
                Toggle(L10n.t("device_browser_use", "Browser use"), isOn: binding(.browser)).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            row(L10n.t("device_computer_use", "Computer use"),
                detail: L10n.t("device_computer_use_detail", "Crok sees the screen and uses the mouse and keyboard; one task at a time has control. New tasks get it.")) {
                Toggle(L10n.t("device_computer_use", "Computer use"), isOn: binding(.computer)).labelsHidden().toggleStyle(.switch)
            }
            if model.computerUse {
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(.screenRecording)
                    permissionRow(.accessibility)
                    Text(L10n.t("device_permissions_note", "macOS grants these to Crok Desktop. When Crok runs in a terminal, macOS asks for the terminal app instead."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 16)
            }
            Divider()
            Text(L10n.t("device_approvals_note", "Crok asks before each action; from that prompt you can allow them for the rest of the session."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
        .onAppear { model.refresh() }
        // Back from System Settings with a permission granted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private func binding(_ feature: DeviceUseSettings.Feature) -> Binding<Bool> {
        Binding(get: { model.isOn(feature) }, set: { store.banner = model.set(feature, $0) })
    }

    private func permissionRow(_ permission: DeviceUseSettings.Permission) -> some View {
        let screen = permission == .screenRecording
        let title = screen ? L10n.t("device_screen_recording", "Screen Recording") : L10n.t("device_accessibility", "Accessibility")
        let detail = screen
            ? L10n.t("device_screen_recording_detail", "Lets Crok take screenshots to see what is on the screen.")
            : L10n.t("device_accessibility_detail", "Lets Crok move the pointer, click, and type.")
        return row(title, detail: detail) {
            if model.isGranted(permission) {
                Label(L10n.t("device_permission_allowed", "Allowed"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green).fixedSize()
            } else {
                Button(L10n.t("device_permission_allow", "Allow…")) { model.request(permission) }
                    .buttonStyle(.bordered)
                    .help(L10n.t("device_permission_allow_help", "Ask macOS for {permission}, or open its page in System Settings", ["permission": title]))
            }
        }
    }

    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
