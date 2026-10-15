import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Browser and computer use in Crok Desktop: how a call is worded in each language, what the
/// approval card shows, and the switches in config.toml.
@MainActor
final class DeviceUseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-device-use-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        L10n.setLanguage(.en)
    }

    override func tearDownWithError() throws {
        L10n.setLanguage(.auto)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Wording

    func testCallsAreWordedFromTheirInput() throws {
        let click = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Browser", "action": "left_click", "ref": "ref_3"]))
        XCTAssertFalse(click.computer)
        XCTAssertEqual(click.title, "Browser: Click ref_3")
        XCTAssertEqual(click.symbol, "globe")
        XCTAssertEqual(click.approvalDetail, "", "a click has nothing more to show")
        let at = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Computer", "action": "double_click", "coordinate": [640.4, 359.6]]))
        XCTAssertTrue(at.computer)
        XCTAssertEqual(at.phrase, "Double-click (640, 360)")
        XCTAssertEqual(at.symbol, "cursorarrow.rays")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Computer", "action": "left_click"])?.phrase, "Click")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Browser", "action": "navigate", "url": "back"])?.phrase, "Go back")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Browser", "action": "scroll", "scroll_direction": "down"])?.phrase, "Scroll down")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Browser", "action": "switch_tab", "tab_id": "tab_2"])?.phrase, "Switch to tab_2")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Computer", "action": "wait", "duration": 1.5])?.phrase, "Wait 1.5 s")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Computer", "action": "wait", "duration": 2])?.phrase, "Wait 2 s")
        let typed = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Computer", "action": "type", "text": "hello\nworld"]))
        XCTAssertEqual(typed.phrase, "Type “hello world”")
        XCTAssertEqual(typed.approvalDetail, "hello\nworld", "the card shows what would be typed")
        let long = "https://example.com/" + String(repeating: "a", count: 120)
        let open = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Browser", "action": "navigate", "url": long]))
        XCTAssertTrue(open.phrase.hasSuffix("…"))
        XCTAssertEqual(open.approvalDetail, long, "the card shows the whole address the title shortens")

        XCTAssertNil(DeviceCall(rawInput: ["variant": "WebFetch", "action": "fetch"]))
        XCTAssertNil(DeviceCall(rawInput: ["variant": "Browser"]))
        XCTAssertNil(DeviceCall(rawInput: ["action": "screenshot"]), "the model's own arguments do not name the tool")
        XCTAssertNil(DeviceCall(rawInput: nil))

        L10n.setLanguage(.zhHans)
        XCTAssertEqual(click.title, "浏览器：点击 ref_3")
        L10n.setLanguage(.de)
        XCTAssertEqual(typed.title, "Computer: „hello world“ eingeben")
    }

    func testTheReducerKeepsTheCallSoItsTitleFollowsTheLanguage() throws {
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "b1", "title": "browser", "status": "pending",
                                 "rawInput": ["action": "screenshot"]], to: &messages)
        XCTAssertNil(messages[0].device)
        XCTAssertEqual(messages[0].toolTitle, "browser")
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "b1", "title": "Browser: Take a screenshot",
                                 "rawInput": ["variant": "Browser", "action": "screenshot"]], to: &messages)
        XCTAssertEqual(messages[0].device?.action, "screenshot")
        XCTAssertEqual(messages[0].toolTitle, "Browser: Take a screenshot")
        L10n.setLanguage(.ja)
        XCTAssertEqual(messages[0].toolTitle, "ブラウザ：スクリーンショットを撮る")
        XCTAssertEqual(messages[0].statusLabel, "待機中")
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "b1", "status": "completed"], to: &messages)
        XCTAssertNotNil(messages[0].device, "an update without input keeps the call")
        XCTAssertEqual(messages[0].statusLabel, "完了")

        // Saved and loaded again, as a task is between launches; a task saved before this keeps loading.
        let data = try JSONEncoder().encode(messages)
        XCTAssertEqual(try JSONDecoder().decode([Message].self, from: data).first?.device, messages[0].device)
        let saved = #"[{"id":"\#(UUID().uuidString)","kind":"tool","text":"Run `ls`","status":"completed"}]"#
        XCTAssertNil(try JSONDecoder().decode([Message].self, from: Data(saved.utf8)).first?.device)
    }

    func testTheApprovalCardWordsTheActionAndTheAnswers() throws {
        let call = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Browser", "action": "left_click", "ref": "ref_7"]))
        let approval = Approval(requestID: 1, title: "Browser: Click ref_7", detail: call.approvalDetail,
                                options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"),
                                          PermissionOption(id: "allow-tool-session", name: "Yes, allow browser actions for this session", kind: "allow_always"),
                                          PermissionOption(id: "reject-once", name: "No, and tell Crok what to do differently", kind: "reject_once")],
                                device: call)
        XCTAssertEqual(approval.shownTitle, "Allow Browser: Click ref_7?")
        XCTAssertEqual(approval.options.map(\.shownName), approval.options.map(\.name))
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(approval.shownTitle, "允许 浏览器：点击 ref_7？")
        XCTAssertEqual(approval.options.map(\.shownName), ["是", "是，本次会话中允许浏览器操作", "否，并告诉 Crok 该怎么改"])
        XCTAssertEqual(PermissionOption(id: "always", name: "Always allow: example.com", kind: "allow_always").shownName, "始终允许：example.com")
        XCTAssertEqual(PermissionOption(id: "new", name: "Something new", kind: "allow_once").shownName, "Something new",
                       "an answer Crok Desktop does not know stays as it came")
        XCTAssertEqual(Approval(requestID: 2, title: "Edit `a.swift`", detail: "", options: []).shownTitle, "Edit `a.swift`")
    }

    func testToolRowsFollowTheLanguage() throws {
        let message = Message(kind: .tool, text: "Browser: Click ref_3", toolID: "c1", status: "completed", detail: "",
                              device: DeviceCall(rawInput: ["variant": "Browser", "action": "left_click", "ref": "ref_3"]))
        let list = TranscriptListView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: list.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = list
        defer { window.contentView = nil }
        var display = TranscriptDisplay(conversation: UUID(), language: L10n.resolvedCode)
        list.apply(messages: [message], display: display)
        list.layoutSubtreeIfNeeded()
        var shown = labels(in: try XCTUnwrap(list.rowView(for: message.id)))
        XCTAssertTrue(shown.contains("Browser: Click ref_3"), "\(shown)")
        XCTAssertTrue(shown.contains("completed"), "\(shown)")

        L10n.setLanguage(.es)
        display.language = L10n.resolvedCode
        list.apply(messages: [message], display: display)
        list.layoutSubtreeIfNeeded()
        shown = labels(in: try XCTUnwrap(list.rowView(for: message.id)))
        XCTAssertTrue(shown.contains("Navegador: Hacer clic en ref_3"), "\(shown)")
        XCTAssertTrue(shown.contains("completado"), "\(shown)")
    }

    /// What a row's labels say, and what its parts tell VoiceOver.
    private func labels(in view: NSView) -> [String] {
        var found: [String] = []
        if let label = view as? TranscriptTextLabel { found.append(label.attributedText?.string ?? label.text) }
        if let name = view.accessibilityLabel(), !name.isEmpty { found.append(name) }
        return found + view.subviews.flatMap { labels(in: $0) }
    }

    // MARK: Switches

    func testTheSwitchesAreSavedUnderFeatures() throws {
        let url = directory.appendingPathComponent("config.toml")
        try "[ui]\ntheme = \"dark\"\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = DeviceUseSettings(configURL: url)
        XCTAssertFalse(settings.browserUse)
        XCTAssertEqual(settings.command(.browser, arguments: ""), "✓ Browser use: on · new tasks get it")
        XCTAssertTrue(settings.browserUse)
        XCTAssertEqual(GrokConfig(url: url).bool("browser_use", in: "features"), true)
        XCTAssertEqual(GrokConfig(url: url).string("theme", in: "ui"), "dark", "the rest of the file is kept")
        XCTAssertEqual(settings.command(.browser, arguments: " OFF "), "✓ Browser use: off · new tasks get it")
        XCTAssertEqual(GrokConfig(url: url).bool("browser_use", in: "features"), false)
        XCTAssertEqual(settings.command(.browser, arguments: "maybe"), "Use on or off, or no argument to switch it")
        XCTAssertEqual(settings.command(.computer, arguments: "disable"), "✓ Computer use: off · new tasks get it")
        XCTAssertEqual(GrokConfig(url: url).bool("computer_use", in: "features"), false)

        // Turned on in the terminal meanwhile: switching reads the file first.
        try GrokConfig.update(url: url) { try $0.set("browser_use", to: .bool(true), in: "features") }
        XCTAssertEqual(settings.command(.browser, arguments: ""), "✓ Browser use: off · new tasks get it")
        L10n.setLanguage(.fr)
        XCTAssertEqual(settings.set(.browser, true), "✓ Utilisation du navigateur : activé · s'applique aux nouvelles tâches")
    }

    func testAFileThatCannotBeEditedIsLeftAlone() throws {
        let url = directory.appendingPathComponent("config.toml")
        let broken = "[features\nbrowser_use = "
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let settings = DeviceUseSettings(configURL: url)
        XCTAssertTrue(settings.set(.browser, true).hasPrefix("Could not save [features].browser_use: "))
        XCTAssertFalse(settings.browserUse)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
    }

    func testTheCommandsAreOffered() {
        let names = Set(DesktopCommands.catalog.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["browser-use", "computer-use", "phone-use"]))
        XCTAssertEqual(DesktopCommands.catalog.first { $0.name == "phone-use" }?.symbol, "iphone")
        XCTAssertEqual(DesktopCommands.turnPolicy("phone-use", arguments: "off"), .runNow)
        XCTAssertEqual(DesktopCommands.turnPolicy("browser-use", arguments: "on"), .runNow, "switching does not wait for the turn")
        XCTAssertEqual(DesktopCommands.catalog.first { $0.name == "computer-use" }?.symbol, "cursorarrow.rays")
        XCTAssertEqual(DesktopCommands.catalog.first { $0.name == "browser-use" }?.argumentHint, "[on|off]")
    }
}

// MARK: - Phone use

/// Phone use in Crok Desktop: how a `phone` call is worded, what its approval card shows, and its
/// switch, which is on until turned off.
@MainActor
final class PhoneUseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-phone-use-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        L10n.setLanguage(.en)
    }

    override func tearDownWithError() throws {
        L10n.setLanguage(.auto)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPhoneCallsAreWordedFromTheirInput() throws {
        let tap = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "action": "tap", "text": "Weather"]))
        XCTAssertTrue(tap.isPhone)
        XCTAssertFalse(tap.computer)
        XCTAssertEqual(tap.title, "Phone: Tap “Weather”")
        XCTAssertEqual(tap.symbol, "iphone")
        let at = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "device": "iphone", "action": "tap", "coordinate": [120.2, 399.7]]))
        XCTAssertEqual(at.title, "iPhone: Tap (120, 400)")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "device": "android", "action": "scroll", "direction": "down"])?.title, "Android: Scroll down")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "action": "swipe", "direction": "left"])?.phrase, "Swipe left")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "action": "open_app", "text": "Settings"])?.phrase, "Open Settings")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "action": "screenshot"])?.phrase, "Take a screenshot")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "action": "read_screen"])?.phrase, "Read the screen")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Phone", "action": "home"])?.phrase, "Go to the Home Screen")
        let pair = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "action": "pair_android", "text": "123456"]))
        XCTAssertEqual(pair.phrase, "Pair an Android phone")
        XCTAssertEqual(pair.approvalDetail, "", "the pairing code is not shown")
        let typed = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "action": "type", "text": "hi\nthere"]))
        XCTAssertEqual(typed.phrase, "Type “hi there”")
        XCTAssertEqual(typed.approvalDetail, "hi\nthere", "the card shows what would be typed")
        XCTAssertEqual(DeviceCall(rawInput: ["variant": "Computer", "action": "left_click", "text": "shift"])?.phrase, "Click",
                       "only a phone call touches text")

        L10n.setLanguage(.zhHans)
        XCTAssertEqual(tap.title, "手机：轻点 “Weather”")
        L10n.setLanguage(.ja)
        XCTAssertEqual(at.title, "iPhone：(120, 400) をタップ")
    }

    func testTasksSavedBeforePhoneUseKeepLoading() throws {
        let old = #"{"computer":true,"action":"screenshot"}"#
        let call = try JSONDecoder().decode(DeviceCall.self, from: Data(old.utf8))
        XCTAssertFalse(call.isPhone)
        XCTAssertEqual(call.title, "Computer: Take a screenshot")
        let phone = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "device": "android", "action": "home"]))
        XCTAssertEqual(try JSONDecoder().decode(DeviceCall.self, from: JSONEncoder().encode(phone)), phone)
    }

    func testTheApprovalCardWordsAPhoneAction() throws {
        let call = try XCTUnwrap(DeviceCall(rawInput: ["variant": "Phone", "device": "iphone", "action": "tap", "text": "Send"]))
        let approval = Approval(requestID: 1, title: "iPhone: tap \"Send\"", detail: call.approvalDetail,
                                options: [PermissionOption(id: "allow-tool-session", name: "Yes, allow phone actions for this session", kind: "allow_always"),
                                          PermissionOption(id: "allow-once", name: "Yes, allow once", kind: "allow_once")],
                                device: call)
        XCTAssertEqual(approval.shownTitle, "Allow iPhone: Tap “Send”?")
        XCTAssertEqual(approval.options.map(\.shownName), approval.options.map(\.name))
        L10n.setLanguage(.de)
        XCTAssertEqual(approval.options.first?.shownName, "Ja, Telefonaktionen in dieser Sitzung erlauben")
    }

    func testPhoneUseIsOnUntilTurnedOff() throws {
        let url = directory.appendingPathComponent("config.toml")
        try "[ui]\ntheme = \"dark\"\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = DeviceUseSettings(configURL: url)
        XCTAssertTrue(settings.phoneUse, "on when config.toml says nothing")
        XCTAssertTrue(settings.isOn(.phone))
        XCTAssertEqual(settings.command(.phone, arguments: ""), "✓ Phone use: off · new tasks get it")
        XCTAssertEqual(GrokConfig(url: url).bool("phone_use", in: "features"), false)
        XCTAssertEqual(GrokConfig(url: url).string("theme", in: "ui"), "dark", "the rest of the file is kept")
        XCTAssertEqual(settings.command(.phone, arguments: "on"), "✓ Phone use: on · new tasks get it")
        XCTAssertTrue(settings.phoneUse)
        L10n.setLanguage(.es)
        XCTAssertEqual(settings.set(.phone, false), "✓ Uso del teléfono: desactivado · se aplica a las tareas nuevas")
    }

    func testTheGuideIsListed() {
        XCTAssertTrue(GuideLibrary.catalog.contains { $0.fileName == "29-phone-use.md" })
    }
}

/// PNGs of browser and computer use, written when CROK_DESKTOP_SNAPSHOT_DIR is set: the Settings
/// section with computer use on, an approval card, and a conversation of browser and computer calls
/// in each state, in English and Simplified Chinese.
@MainActor
final class DeviceUseSnapshotTests: XCTestCase {
    private var output: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-device-use-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        L10n.setLanguage(.auto)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func call(_ input: [String: Any]) -> DeviceCall? { DeviceCall(rawInput: input) }

    private var messages: [Message] {
        [
            Message(kind: .user, text: "Check that the sign-up form on localhost:3000 refuses a short password."),
            Message(kind: .tool, text: "Browser: Open http://localhost:3000/signup", toolID: "1", status: "completed",
                    detail: "Tab Context:\n- tab_1 (active): Sign up · http://localhost:3000/signup",
                    device: call(["variant": "Browser", "action": "navigate", "url": "http://localhost:3000/signup"])),
            Message(kind: .tool, text: "Browser: Fill in ref_4", toolID: "2", status: "completed", detail: "",
                    device: call(["variant": "Browser", "action": "form_input", "ref": "ref_4", "value": "abc"])),
            Message(kind: .tool, text: "Browser: Click ref_7", toolID: "3", status: "failed",
                    detail: "ref_7 is no longer on the page; read the page again.",
                    device: call(["variant": "Browser", "action": "left_click", "ref": "ref_7"])),
            Message(kind: .tool, text: "Computer: Take a screenshot", toolID: "4", status: "in_progress", detail: "",
                    device: call(["variant": "Computer", "action": "screenshot"])),
            Message(kind: .tool, text: "iPhone: tap \"Weather\"", toolID: "5", status: "completed", detail: "Tapped \"Weather\" at (240, 820).",
                    device: call(["variant": "Phone", "device": "iphone", "action": "tap", "text": "Weather"])),
            Message(kind: .tool, text: "Android: scroll down", toolID: "6", status: "pending", detail: "",
                    device: call(["variant": "Phone", "device": "android", "action": "scroll", "direction": "down"])),
        ]
    }

    func testDeviceUseInEachLanguage() throws {
        let config = directory.appendingPathComponent("config.toml")
        try "[features]\nbrowser_use = true\ncomputer_use = true\n".write(to: config, atomically: true, encoding: .utf8)
        for language in [AppLanguage.en, .zhHans] {
            L10n.setLanguage(language)
            let name = language.configValue
            let store = AppStore(stateFile: directory.appendingPathComponent("state-\(name).json"), binaryPath: "/usr/bin/false")
            let typed = call(["variant": "Computer", "action": "type", "text": "correct horse battery staple"])
            let approval = Approval(requestID: 1, title: "Computer: Type", detail: typed?.approvalDetail ?? "",
                                    options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"),
                                              PermissionOption(id: "allow-tool-session", name: "Yes, allow computer use for this session", kind: "allow_always"),
                                              PermissionOption(id: "reject-once", name: "No, and tell Crok what to do differently", kind: "reject_once")],
                                    device: typed)
            let view = VStack(alignment: .leading, spacing: 16) {
                DeviceUseSettingsSection(model: DeviceUseSettings(configURL: config))
                PhoneUseSettingsSection(model: DeviceUseSettings(configURL: config))
                ApprovalCard(approval: approval)
            }
            .padding(24).frame(width: 660).foregroundStyle(Theme.ink).desktopEnvironment(store)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try SnapshotRenderer.write(view, size: CGSize(width: 660, height: 1240), appearance: appearance,
                                           to: output.appendingPathComponent("device-use-settings-\(name)-\(suffix).png"))
                try renderConversation(appearance: appearance, to: output.appendingPathComponent("device-use-transcript-\(name)-\(suffix).png"))
            }
        }
    }

    /// The AppKit conversation as a running turn shows it, with the failed call open.
    private func renderConversation(appearance: NSAppearance.Name, to url: URL) throws {
        let messages = self.messages
        let list = TranscriptListView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        let canvas = TranscriptFillView(color: Theme.palette.canvasNS, radius: 0)
        canvas.frame = list.frame
        list.autoresizingMask = [.width, .height]
        canvas.addSubview(list)
        let window = NSWindow(contentRect: list.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = canvas
        defer { window.contentView = nil }
        let display = TranscriptDisplay(conversation: UUID(), expanded: [messages[3].id], status: "Working…", language: L10n.resolvedCode)
        list.apply(messages: messages, display: display)
        for _ in 0..<3 {
            list.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        canvas.displayIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
