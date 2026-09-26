import AVFoundation
import XCTest
@testable import GrokDesktop

/// Argument parsing, queue logic, preferences, prompt read-back, and dictation plumbing for the composer.
@MainActor
final class ComposerFeatureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-composer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: /model and /effort

    private let levels = ["low", "medium", "high"].map { ModelOption(id: $0, name: $0.capitalized) }
    private var models: [ModelOption] {
        [ModelOption(id: "grok-4", name: "Grok 4", reasoningOptions: levels),
         ModelOption(id: "grok-4-fast", name: "Grok 4 Fast", reasoningOptions: levels),
         ModelOption(id: "plain-model", name: "Plain Model")]
    }

    func testModelResolutionPrefersExactNameOrIdIgnoringCase() {
        XCTAssertEqual(try ComposerModelArguments.resolveModel("grok 4", models: models).get(), .init(modelID: "grok-4", effortID: nil))
        XCTAssertEqual(try ComposerModelArguments.resolveModel("GROK-4-FAST", models: models).get(), .init(modelID: "grok-4-fast", effortID: nil))
        XCTAssertEqual(try ComposerModelArguments.resolveModel("  Plain Model ", models: models).get(), .init(modelID: "plain-model", effortID: nil))
    }

    func testModelResolutionTakesLongestReasoningPrefixThenEffort() {
        XCTAssertEqual(try ComposerModelArguments.resolveModel("Grok 4 Fast high", models: models).get(), .init(modelID: "grok-4-fast", effortID: "high"))
        XCTAssertEqual(try ComposerModelArguments.resolveModel("grok 4 LOW", models: models).get(), .init(modelID: "grok-4", effortID: "low"))
        XCTAssertEqual(try ComposerModelArguments.resolveModel("grok-4-fast Medium", models: models).get(), .init(modelID: "grok-4-fast", effortID: "medium"))
    }

    func testModelResolutionErrorsUseTheTerminalWording() {
        XCTAssertEqual(failure(ComposerModelArguments.resolveModel("grok-5", models: models)), "Unknown model: grok-5")
        // Only models that support reasoning take a trailing effort word.
        XCTAssertEqual(failure(ComposerModelArguments.resolveModel("Plain Model high", models: models)), "Unknown model: Plain Model high")
        XCTAssertEqual(failure(ComposerModelArguments.resolveModel("Grok 4 xhigh", models: models)), "unknown effort level 'xhigh'; use one of: low, medium, high")
        // "Grok 4" must be followed by whitespace to count as a prefix.
        XCTAssertEqual(failure(ComposerModelArguments.resolveModel("Grok 4x", models: models)), "Unknown model: Grok 4x")
    }

    func testEffortAcceptsIdsLabelsAndStandardNames() {
        let menu = [ModelOption(id: "deep", name: "Deep"), ModelOption(id: "xhigh", name: "Extra high"), ModelOption(id: "low", name: "Low")]
        XCTAssertEqual(try ComposerModelArguments.resolveEffort("DEEP", options: menu).get(), "deep")
        XCTAssertEqual(try ComposerModelArguments.resolveEffort("extra high", options: menu).get(), "xhigh")
        XCTAssertEqual(try ComposerModelArguments.resolveEffort("X-High", options: menu).get(), "xhigh")
        XCTAssertEqual(try ComposerModelArguments.resolveEffort("xhigh", options: menu).get(), "xhigh")
        XCTAssertEqual(try ComposerModelArguments.resolveEffort(" Low ", options: menu).get(), "low")
        // A standard level the menu does not offer is unknown, listing only the offered ids.
        XCTAssertEqual(failure(ComposerModelArguments.resolveEffort("max", options: menu)), "unknown effort level 'max'; use one of: deep, xhigh, low")
        XCTAssertEqual(failure(ComposerModelArguments.resolveEffort("high", options: [])), "current model does not support reasoning effort")
        // A menu labelled with the terminal's names still matches the standard names.
        let terminalMenu = [ModelOption(id: "x", name: "X-High")]
        XCTAssertEqual(try ComposerModelArguments.resolveEffort("xhigh", options: terminalMenu).get(), "x")
    }

    func testEffortUsageAndSwitchWording() {
        XCTAssertEqual(ComposerModelArguments.effortUsage(options: levels, current: "medium"), "Usage: /effort <low|medium|high> (current: medium)")
        XCTAssertEqual(ComposerModelArguments.effortUsage(options: [], current: ""), "Usage: /effort <level>")
        XCTAssertEqual(ComposerModelArguments.effortWord("xhigh", options: []), "xhigh")
        XCTAssertEqual(ComposerModelArguments.effortWord("deep", options: [ModelOption(id: "deep", name: "Extra high")]), "xhigh")
        XCTAssertEqual(ComposerModelArguments.effortWord("custom", options: [ModelOption(id: "custom", name: "Custom")]), "custom")
    }

    private func failure<T>(_ result: Result<T, ComposerCommandMessage>) -> String? {
        if case .failure(let message) = result { return message.text }
        return nil
    }

    // MARK: Queue

    func testQueueKeepsOrderAndSupportsEditingReorderingAndRemoval() {
        var book = ComposerQueueBook()
        let task = UUID(), other = UUID()
        let first = book.append("first", to: task)
        let second = book.append("second\nwith detail\nand more", to: task)
        let third = book.append("third", to: task)
        book.append("elsewhere", to: other)
        XCTAssertEqual(book.items(task).map(\.text), ["first", "second\nwith detail\nand more", "third"])
        XCTAssertEqual(second.firstLine, "second")
        XCTAssertEqual(second.extraLinesLabel, "+2 more lines")
        XCTAssertNil(first.extraLinesLabel)

        book.move(third.id, by: -1, in: task)
        XCTAssertEqual(book.items(task).map(\.id), [first.id, third.id, second.id])
        book.move(first.id, by: -5, in: task)
        XCTAssertEqual(book.items(task).first?.id, first.id, "moves clamp at the ends")
        book.moveToFront(second.id, in: task)
        XCTAssertEqual(book.items(task).map(\.id), [second.id, first.id, third.id])
        book.update(first.id, text: "first, edited", in: task)
        XCTAssertEqual(book.items(task)[1].text, "first, edited")
        book.update(third.id, text: "  \n", in: task)
        XCTAssertEqual(book.items(task).map(\.id), [second.id, first.id], "an empty edit removes the entry")

        XCTAssertEqual(book.popNext(for: task)?.id, second.id)
        book.pause(task)
        XCTAssertTrue(book.isPaused(task))
        XCTAssertEqual(book.remove(first.id, from: task)?.text, "first, edited")
        XCTAssertTrue(book.items(task).isEmpty)
        XCTAssertFalse(book.isPaused(task), "an emptied queue forgets its pause")
        XCTAssertEqual(book.items(other).map(\.text), ["elsewhere"], "queues are per task")
    }

    func testQueueDispatchWaitsForAReadyTaskUnlessTheUserAsks() {
        XCTAssertTrue(ComposerQueueBook.mayDispatch(isRunning: false, phase: "Ready", paused: false, sendNow: false))
        XCTAssertFalse(ComposerQueueBook.mayDispatch(isRunning: true, phase: "Working", paused: false, sendNow: true))
        XCTAssertFalse(ComposerQueueBook.mayDispatch(isRunning: false, phase: "Stopped", paused: true, sendNow: false))
        XCTAssertFalse(ComposerQueueBook.mayDispatch(isRunning: false, phase: "Needs attention", paused: false, sendNow: false))
        XCTAssertTrue(ComposerQueueBook.mayDispatch(isRunning: false, phase: "Stopped", paused: true, sendNow: true))
    }

    func testQueuedCompactRunsNatively() {
        XCTAssertEqual(ComposerQueuedPrompt(text: "/compact keep the API notes").compactInstructions, "keep the API notes")
        XCTAssertEqual(ComposerQueuedPrompt(text: "/compact").compactInstructions, "")
        XCTAssertNil(ComposerQueuedPrompt(text: "/compacted").compactInstructions)
        XCTAssertNil(ComposerQueuedPrompt(text: "compact this").compactInstructions)
    }

    func testHarnessQueueChangedParsesCamelCaseAndSkipsTheRunningPrompt() {
        let snapshot = HarnessPromptQueue([
            "sessionId": "s1", "runningPromptId": "p0", "runningText": "running now",
            "entries": [
                ["id": "p2", "version": 3, "owner": "grok-shell", "kind": "prompt", "text": "second", "position": 1],
                ["id": "p0", "version": 0, "kind": "prompt", "text": "running now", "position": 0],
                ["id": "p1", "version": 1, "kind": "bash", "text": "ignored", "combinedTexts": ["a", "b"], "position": 0],
            ],
        ])
        XCTAssertEqual(snapshot.runningPromptID, "p0")
        XCTAssertEqual(snapshot.entries.map(\.id), ["p1", "p2"])
        XCTAssertEqual(snapshot.entries.first?.text, "a\nb")
        XCTAssertEqual(snapshot.entries.last?.version, 3)
        XCTAssertEqual(snapshot.entries.last?.owner, "grok-shell")
    }

    func testQueueEnqueueAndEmptyQueueBanner() throws {
        let store = makeStore()
        let composer = store.features.composer
        let task = Conversation(projectID: store.state.projects[0].id)
        store.state.conversations = [task]
        store.state.selectedConversationID = task.id
        composer.showQueue()
        XCTAssertEqual(store.banner, "Queue is empty.")
        store.banner = nil
        XCTAssertTrue(composer.enqueue("follow up", conversationID: task.id))
        XCTAssertEqual(composer.queue.items(task.id).map(\.text), ["follow up"])
        composer.queuePanelExpanded = false
        composer.showQueue()
        XCTAssertNil(store.banner)
        XCTAssertTrue(composer.queuePanelExpanded)
        XCTAssertFalse(composer.enqueue("unknown task", conversationID: UUID()))
    }

    // MARK: Permission mode

    func testPermissionModeReadsConfigWithLegacyKeys() {
        XCTAssertEqual(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\npermission_mode = \"auto\"\n")), .auto)
        XCTAssertEqual(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\npermission_mode = \"default\"\n")), .standard)
        XCTAssertEqual(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\napproval_mode = \"always-approve\"\nyolo = false\n")), .alwaysApprove)
        XCTAssertEqual(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\nyolo = true\n")), .alwaysApprove)
        XCTAssertEqual(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\nyolo = false\n")), .ask)
        XCTAssertNil(ComposerPermissionMode.configured(in: GrokConfig(text: "[ui]\ntheme = \"grokday\"\n")))
    }

    func testPermissionNotificationAndMessagesMatchTheTerminal() {
        XCTAssertEqual(ComposerPermissionMode.alwaysApprove.notificationParams as NSDictionary,
                       ["yolo_mode": true, "auto_mode": false, "permission_mode": "always-approve"] as NSDictionary)
        XCTAssertEqual(ComposerPermissionMode.auto.notificationParams as NSDictionary,
                       ["yolo_mode": false, "auto_mode": true, "permission_mode": "auto"] as NSDictionary)
        XCTAssertEqual(ComposerPermissionMode.ask.notificationParams as NSDictionary,
                       ["yolo_mode": false, "auto_mode": false, "permission_mode": "ask"] as NSDictionary)
        XCTAssertEqual(ComposerPermissionMode.alwaysApprove.confirmation(planMode: false), "⚠ Always-approve ON: all tool actions auto-run")
        XCTAssertEqual(ComposerPermissionMode.alwaysApprove.confirmation(planMode: true), "⚠ Always-approve ON: plan mode still blocks file edits until you exit plan mode")
        XCTAssertEqual(ComposerPermissionMode.auto.confirmation(planMode: false), "✓ Permission mode: Auto (classifier)")
        XCTAssertEqual(ComposerPermissionMode.ask.confirmation(planMode: false), "✓ Permission mode: Ask")
        XCTAssertTrue(ComposerPermissionMode.alwaysApproveTarget("", current: .ask))
        XCTAssertFalse(ComposerPermissionMode.alwaysApproveTarget("", current: .alwaysApprove))
        for off in ["off", "FALSE", "0", "no", "disable"] { XCTAssertFalse(ComposerPermissionMode.alwaysApproveTarget(off, current: .ask)) }
        for on in ["on", "yes", "true", "please"] { XCTAssertTrue(ComposerPermissionMode.alwaysApproveTarget(on, current: .alwaysApprove)) }
    }

    func testPermissionModePersistsToConfigAndSeedsNewSessions() async throws {
        let store = makeStore()
        let composer = store.features.composer
        let config = directory.appendingPathComponent("config.toml")
        try "# Grok\n[ui]\ntheme = \"grokday\"\n".write(to: config, atomically: true, encoding: .utf8)
        composer.configURL = config
        composer.reloadPreferences()
        XCTAssertEqual(composer.permissionMode, .ask)
        XCTAssertTrue(composer.sessionMeta().isEmpty, "the harness keeps its own default until the user picks a mode")

        composer.setAlwaysApprove("")
        try await eventually { store.banner == "⚠ Always-approve ON: all tool actions auto-run" }
        XCTAssertEqual(composer.permissionMode, .alwaysApprove)
        let saved = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(saved, "# Grok\n[ui]\ntheme = \"grokday\"\npermission_mode = \"always-approve\"\n")
        XCTAssertEqual(composer.sessionMeta() as NSDictionary, ["yoloMode": true, "autoMode": false] as NSDictionary)

        composer.toggleAutoMode()
        try await eventually { store.banner == "✓ Permission mode: Auto (classifier)" }
        XCTAssertEqual(GrokConfig(url: config).string("permission_mode", in: "ui"), "auto")
        XCTAssertEqual(composer.sessionMeta() as NSDictionary, ["yoloMode": false, "autoMode": true] as NSDictionary)
        composer.toggleAutoMode()
        try await eventually { store.banner == "✓ Permission mode: Ask" }
        composer.setAlwaysApprove("off")
        try await eventually { store.banner == "✓ Always-approve: off" }
        XCTAssertEqual(GrokConfig(url: config).string("permission_mode", in: "ui"), "ask")

        // A new launch reads the saved mode.
        composer.reloadPreferences()
        XCTAssertEqual(composer.permissionMode, .ask)
        XCTAssertEqual(composer.sessionMeta() as NSDictionary, ["yoloMode": false, "autoMode": false] as NSDictionary)
    }

    func testPermissionModeRollsBackWhenConfigCannotBeSaved() async throws {
        let store = makeStore()
        let composer = store.features.composer
        let config = directory.appendingPathComponent("config.toml")
        // Dotted keys are a layout the desktop refuses to rewrite.
        try "ui.theme = \"grokday\"\n".write(to: config, atomically: true, encoding: .utf8)
        composer.configURL = config
        composer.reloadPreferences()
        composer.setPermissionMode(.alwaysApprove)
        try await eventually { store.banner?.hasPrefix("Couldn't save the permission mode") == true }
        XCTAssertEqual(composer.permissionMode, .ask)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "ui.theme = \"grokday\"\n")
    }

    func testRemoteSettingsGateAutoMode() throws {
        let store = makeStore()
        let composer = store.features.composer
        let task = Conversation(projectID: store.state.projects[0].id)
        store.state.conversations = [task]
        XCTAssertTrue(composer.autoModeAvailable)
        XCTAssertFalse(composer.handle(method: "x.ai/settings/update", params: ["auto_permission_mode_enabled": false, "permission_mode": "auto"], update: nil, conversationID: task.id))
        XCTAssertFalse(composer.autoModeAvailable)
        XCTAssertEqual(composer.permissionMode, .ask, "Auto degrades to Ask while the gate is off")
        composer.toggleAutoMode()
        XCTAssertEqual(store.banner, "Auto permission mode is not available for this account.")
        _ = composer.handle(method: "x.ai/settings/update", params: ["auto_permission_mode_enabled": true], update: nil, conversationID: task.id)
        XCTAssertTrue(composer.autoModeAvailable)
        XCTAssertEqual(composer.permissionMode, .auto, "the remote soft default applies until the user chooses")
    }

    // MARK: Compaction and formatting

    func testCompactionMessagesAndDurations() {
        XCTAssertEqual(ComposerCompactionStatus.running(started: Date()).message, "Compacting conversation…")
        XCTAssertEqual(ComposerCompactionStatus.completed(4.21).message, "Compaction completed in 4.2s.")
        XCTAssertEqual(ComposerCompactionStatus.failed("context too small").message, "Compaction failed - context too small")
        XCTAssertEqual(ComposerCompactionStatus.failed(" ").message, "Compaction failed.")
        XCTAssertEqual(ComposerCompactionStatus.cancelled.message, "Compaction cancelled.")
        XCTAssertEqual(ComposerFormat.duration(0.5), "0.5s")
        XCTAssertEqual(ComposerFormat.duration(12.3), "12s")
        XCTAssertEqual(ComposerFormat.duration(125), "2m5s")
        XCTAssertEqual(ComposerFormat.duration(3725), "1h2m")
        XCTAssertEqual(ComposerFormat.wordCount("  one two\nthree\t four  "), 4)
        XCTAssertEqual(ComposerFormat.wordCount(""), 0)
    }

    // MARK: /edit-prompt

    func testEditPromptFileIsPrivateAndReadBackFollowsTheTerminalRules() throws {
        let file = try ExternalPromptEditor.createPromptFile("draft", directory: directory)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("grok-prompt-") && file.pathExtension == "md")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try ExternalPromptEditor.readBack(file, original: "draft").get(), "draft")

        func readBack(_ data: Data, original: String) -> Result<String, ComposerCommandMessage> {
            let url = directory.appendingPathComponent(UUID().uuidString + ".md")
            try? data.write(to: url)
            return ExternalPromptEditor.readBack(url, original: original)
        }
        // One editor-added newline is removed only when the draft had none.
        XCTAssertEqual(try readBack(Data("edited\n".utf8), original: "draft").get(), "edited")
        XCTAssertEqual(try readBack(Data("edited\r\n".utf8), original: "draft").get(), "edited")
        XCTAssertEqual(try readBack(Data("edited\n\n".utf8), original: "draft").get(), "edited\n")
        XCTAssertEqual(try readBack(Data("edited\n".utf8), original: "draft\n").get(), "edited\n")
        XCTAssertEqual(failure(readBack(Data([0x66, 0xFF, 0xFE]), original: "")), ExternalPromptEditor.invalidUTF8)
        XCTAssertEqual(failure(readBack(Data(count: ExternalPromptEditor.maximumBytes + 1), original: "")), ExternalPromptEditor.tooLarge)
        XCTAssertEqual(try readBack(Data(repeating: 0x61, count: ExternalPromptEditor.maximumBytes), original: "").get().count, ExternalPromptEditor.maximumBytes)
        XCTAssertEqual(failure(ExternalPromptEditor.readBack(directory.appendingPathComponent("missing.md"), original: "")), ExternalPromptEditor.failure)
        XCTAssertEqual(ExternalPromptEditor.tooLarge, "External prompt editor saved a draft larger than 4 MiB; the original draft was kept.")
        XCTAssertEqual(ExternalPromptEditor.stale, "The draft changed while the external editor was open; the newer draft was kept.")
    }

    func testEditPromptEditorCommandAndTerminalScript() {
        XCTAssertEqual(ExternalPromptEditor.editorCommand(environment: ["VISUAL": "code --wait", "EDITOR": "vim"]), "code --wait")
        XCTAssertEqual(ExternalPromptEditor.editorCommand(environment: ["VISUAL": "  ", "EDITOR": "nvim"]), "nvim")
        XCTAssertNil(ExternalPromptEditor.editorCommand(environment: [:]))
        let script = ExternalPromptEditor.terminalScript(editor: "subl -w", file: URL(fileURLWithPath: "/tmp/it's.md"), statusFile: URL(fileURLWithPath: "/tmp/s.status"))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("GROK_EDITOR='subl -w'"))
        XCTAssertTrue(script.contains("GROK_PROMPT_FILE='/tmp/it'\\''s.md'"))
        XCTAssertTrue(script.contains(#"eval "$GROK_EDITOR \"\$GROK_PROMPT_FILE\"""#))
    }

    func testEditPromptIsRefusedWhileDictating() {
        let store = makeStore()
        let composer = store.features.composer
        composer.voice.showPreview(phase: .recording)
        composer.openEditPrompt(keepDraft: true)
        XCTAssertEqual(store.banner, "External prompt editing is not available while voice input is active.")
        XCTAssertNil(store.sheet)
        composer.voice.cancel()
        store.draft = "Current draft"
        composer.openEditPrompt(keepDraft: true)
        XCTAssertEqual(store.sheet, .editPrompt(text: "Current draft"))
        composer.openEditPrompt(keepDraft: false)
        XCTAssertEqual(store.sheet, .editPrompt(text: ""))
        composer.useEditedPrompt("Longer prompt")
        XCTAssertEqual(store.draft, "Longer prompt")
        XCTAssertNil(store.sheet)
    }

    // MARK: Voice

    func testDictationSpacingMatchesTheTerminal() {
        XCTAssertEqual(VoiceTextInsertion.spaced("world", in: "hello", at: 5), " world")
        XCTAssertEqual(VoiceTextInsertion.spaced("big", in: "a  cat", at: 2), "big")
        XCTAssertEqual(VoiceTextInsertion.spaced("big", in: "a cat", at: 2), "big ")
        XCTAssertEqual(VoiceTextInsertion.spaced("very", in: "a big", at: 1), " very")
        XCTAssertEqual(VoiceTextInsertion.spaced("start", in: "", at: 0), "start")
        XCTAssertEqual(VoiceTextInsertion.merge("new text", into: "   ", replacing: nil).text, "new text")
        let merged = VoiceTextInsertion.merge("quick", into: "the brown fox", replacing: NSRange(location: 4, length: 0))
        XCTAssertEqual(merged.text, "the quick brown fox")
        XCTAssertEqual(merged.caret, 10)
        XCTAssertEqual(VoiceTextInsertion.merge("red", into: "the brown fox", replacing: NSRange(location: 4, length: 5)).text, "the red fox")
        XCTAssertEqual(VoiceTextInsertion.merge("end", into: "emoji 😀", replacing: nil).text, "emoji 😀 end")
    }

    func testDictationLanguages() throws {
        let configured = VoiceSTTSettings(config: GrokConfig(text: "[voice]\nlanguage = \"de\"\n[ui]\nvoice_stt_language = \"ja\"\n"))
        XCTAssertEqual(configured.language, "ja", "[ui].voice_stt_language overrides [voice].language")
        XCTAssertEqual(VoiceSTTSettings(config: GrokConfig(text: "[voice]\nlanguage = \"de\"\n")).language, "de")
        XCTAssertEqual(VoiceSTTSettings.languageForAPI("pt-BR"), "pt")
        XCTAssertEqual(VoiceSTTSettings.canonicalLanguage("AUTO"), "auto")
        XCTAssertEqual(VoiceSTTSettings.canonicalLanguage("tl_PH"), "fil")
        XCTAssertEqual(VoiceSTTSettings.canonicalLanguage("klingon"), "en")
        XCTAssertEqual(VoiceSTTSettings.languageForAPI("auto", preferred: ["fr-CA", "en-US"]), "fr")
        XCTAssertEqual(VoiceSTTSettings.languageForAPI("auto", preferred: ["zz-ZZ"]), "en")
    }

    func testPCMConversionResamplesToSixteenKilohertzMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = try XCTUnwrap(VoicePCMConverter(inputFormat: format))
        var bytes = Data()
        // One second of a 440 Hz tone at half scale, delivered in 100 ms buffers like the tap does.
        for block in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            for channel in 0..<2 {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for index in 0..<4_800 {
                    let time = Double(block * 4_800 + index) / 48_000
                    samples[index] = Float(0.5 * sin(2 * .pi * 440 * time))
                }
            }
            bytes.append(converter.convert(buffer))
        }
        XCTAssertEqual(converter.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        XCTAssertEqual(bytes.count % 2, 0)
        let samples = bytes.withUnsafeBytes { raw in (0..<raw.count / 2).map { Int16(littleEndian: raw.load(fromByteOffset: $0 * 2, as: Int16.self)) } }
        XCTAssertGreaterThan(samples.count, 15_000)
        XCTAssertLessThanOrEqual(samples.count, 16_000)
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 12_000, "a half-scale tone stays near 16,384 after mixing down")
        XCTAssertLessThan(peak, 20_000)
        XCTAssertEqual(VoicePCMConverter.int16(1.5), Int16.max)
        XCTAssertEqual(VoicePCMConverter.int16(-2), Int16.min)
        XCTAssertEqual(VoicePCMConverter.int16(0), 0)
    }

    func testPCMChunkerEmitsSixtyFourMillisecondFrames() {
        var chunker = VoicePCMChunker()
        XCTAssertTrue(chunker.append(Data(count: 2_000)).isEmpty)
        let frames = chunker.append(Data(count: 4_200))
        XCTAssertEqual(frames.map(\.count), [2_048, 2_048, 2_048])
        XCTAssertEqual(chunker.flush()?.count, 56)
        XCTAssertNil(chunker.flush())
    }

    func testVoiceModelComesFromTheSharedUIKeys() throws {
        let defaults = VoiceSTTSettings(config: GrokConfig(text: ""))
        XCTAssertEqual(defaults.model, "openai/gpt-4o-mini-transcribe")
        XCTAssertEqual(try defaults.transcriptionURL().absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        let configured = VoiceSTTSettings(config: GrokConfig(text: "[voice]\nprovider = \"openrouter\"\nmodel = \"openai/whisper-1\"\nopenrouter_api_base = \"https://proxy.example.com/api/v1/\"\n[ui]\nvoice_stt_provider = \"xai\"\nvoice_stt_model = \" mistralai/voxtral-mini-transcribe \"\n"))
        XCTAssertEqual(configured.model, "mistralai/voxtral-mini-transcribe", "[ui] overrides [voice]")
        XCTAssertEqual(try configured.transcriptionURL().absoluteString, "https://proxy.example.com/api/v1/audio/transcriptions")
        let fallback = VoiceSTTSettings(config: GrokConfig(text: "[voice]\nprovider = \"xai\"\nmodel = \"openai/whisper-1\"\n[ui]\nvoice_stt_provider = \"bogus\"\nvoice_stt_model = \"\"\n"))
        XCTAssertEqual(fallback.model, "openai/whisper-1")
        XCTAssertEqual(try fallback.transcriptionURL().absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions",
                       "a legacy xAI provider setting still dictates with OpenRouter")
        var insecure = VoiceSTTSettings()
        insecure.openRouterBase = "HTTP://localhost/api/v1"
        XCTAssertThrowsError(try insecure.transcriptionURL())
    }

    func testOpenRouterRequestAndResponses() throws {
        let wav = VoiceOpenRouterTranscriber.wav(Data([1, 0, 2, 0]), sampleRate: 16_000)
        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 16_000)
        XCTAssertEqual(wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 4)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: VoiceOpenRouterTranscriber.requestBody(model: "openai/whisper-1", language: "ja", wav: Data("RIFF".utf8))) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(body["language"] as? String, "ja")
        XCTAssertEqual((body["input_audio"] as? [String: String])?["data"], "UklGRg==")
        XCTAssertEqual((body["input_audio"] as? [String: String])?["format"], "wav")

        XCTAssertEqual(try VoiceOpenRouterTranscriber.result(status: 200, body: Data(#"{"text":" Hello. ","usage":{}}"#.utf8), model: "m").get(), "Hello.")
        XCTAssertThrowsError(try VoiceOpenRouterTranscriber.result(status: 400, body: Data(#"{"error":{"message":"Model no/such does not exist"}}"#.utf8), model: "no/such").get()) { error in
            XCTAssertTrue((error as? ComposerCommandMessage)?.text.contains("Pick a transcription model") == true)
        }
        XCTAssertThrowsError(try VoiceOpenRouterTranscriber.result(status: 401, body: Data(), model: "m").get()) { error in
            XCTAssertTrue((error as? ComposerCommandMessage)?.text.contains("Sign in to OpenRouter") == true)
        }
        XCTAssertThrowsError(try VoiceOpenRouterTranscriber.result(status: 503, body: Data("<html>".utf8), model: "m").get()) { error in
            XCTAssertEqual((error as? ComposerCommandMessage)?.text, "OpenRouter: HTTP 503")
        }
    }

    func testSegmenterClosesUtterancesAtPausesAndDropsSilence() {
        func tone(_ amplitude: Int16, ms: Int = 100) -> Data {
            var data = Data()
            for index in 0..<(16 * ms) {
                var sample = (index % 2 == 0 ? amplitude : -amplitude).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return data
        }
        var segmenter = VoiceSegmenter()
        for _ in 0..<50 { XCTAssertNil(segmenter.push(tone(20)).segment) }
        var closed: [Data] = []
        for _ in 0..<10 { if let segment = segmenter.push(tone(3_000)).segment { closed.append(segment) } }
        XCTAssertTrue(closed.isEmpty)
        for _ in 0..<10 { if let segment = segmenter.push(tone(20)).segment { closed.append(segment) } }
        XCTAssertEqual(closed.map { segmenter.milliseconds($0.count) }, [2_000], "300 ms pre-roll + 1 s speech + 700 ms pause")
        XCTAssertNil(segmenter.finish())
        _ = segmenter.push(tone(3_000))
        XCTAssertEqual(segmenter.finish().map { segmenter.milliseconds($0.count) }, 100, "the last finish dropped the pre-roll")
        var fan = VoiceSegmenter()
        XCTAssertFalse((0..<30).contains { _ in fan.push(tone(400)).voiced })
        XCTAssertTrue(fan.push(tone(4_000)).voiced)
        XCTAssertEqual(VoiceSegmenter.rms(tone(1_000)), 1_000, accuracy: 1e-9)
    }

    func testSegmentSinkKeepsUtterancesInOrderThroughTheStop() {
        var notified = 0
        let sink = VoiceSegmentSink(sampleRate: 16_000) { notified += 1 }
        var speech = Data(), quiet = Data()
        for index in 0..<1_600 {
            var loud = (index % 2 == 0 ? Int16(3_000) : -3_000).littleEndian
            withUnsafeBytes(of: &loud) { speech.append(contentsOf: $0) }
            var soft = (index % 2 == 0 ? Int16(20) : -20).littleEndian
            withUnsafeBytes(of: &soft) { quiet.append(contentsOf: $0) }
        }
        for _ in 0..<10 { sink.push(speech) }
        for _ in 0..<7 { sink.push(quiet) }
        sink.push(speech)
        XCTAssertEqual(notified, 2, "first speech, then the closed utterance")
        let finished = sink.finish()
        XCTAssertEqual(finished.map(\.count), [3_200 * 17, 3_200], "the undrained utterance precedes the trailing one")
        XCTAssertTrue(sink.drain().segments.isEmpty)
    }

    func testOpenRouterCredentialPrefersTheEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(VoiceOpenRouterCredential.read(home: home, environment: [:]))
        let auth = home.appendingPathComponent("provider-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try Data(#"{"provider":"openrouter","access_token":" sk-or-file ","issued_at":1}"#.utf8).write(to: auth.appendingPathComponent("openrouter.json"))
        XCTAssertEqual(VoiceOpenRouterCredential.read(home: home, environment: [:]), "sk-or-file")
        XCTAssertEqual(VoiceOpenRouterCredential.read(home: home, environment: ["OPENROUTER_API_KEY": "sk-or-env"]), "sk-or-env")
        XCTAssertEqual(VoiceOpenRouterCredential.read(home: home, environment: ["OPENROUTER_API_KEY": "  "]), "sk-or-file")
    }

    func testModelCatalogParsesAndSortsOpenRouterModels() {
        let json = #"{"data":[{"id":"openai/whisper-1","name":"OpenAI: Whisper 1"},{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"},{"name":"missing id"}]}"#
        XCTAssertEqual(VoiceModelCatalog.parse(Data(json.utf8)), [
            VoiceModelOption(id: "deepgram/nova-3", name: "Deepgram: Nova-3"),
            VoiceModelOption(id: "openai/whisper-1", name: "OpenAI: Whisper 1"),
        ])
        XCTAssertEqual(VoiceModelCatalog.parse(Data("nope".utf8)), [])
    }

    func testVoiceModelSettingPersistsToTheUITable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[ui]\nvoice_stt_language = \"fr\"\n".utf8).write(to: url)
        let store = makeStore()
        let composer = store.features.composer
        composer.configURL = url
        composer.reloadPreferences()
        XCTAssertEqual(composer.voiceModel, VoiceSTTSettings.defaultModel)
        composer.setVoiceModel("  openai/whisper-1 ")
        composer.setVoiceModel("has space")
        XCTAssertEqual(composer.voiceModel, "openai/whisper-1")
        XCTAssertNotNil(store.banner)
        for _ in 0..<50 {
            let saved = VoiceSTTSettings(config: GrokConfig(url: url))
            if saved.model == "openai/whisper-1" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let saved = VoiceSTTSettings(config: GrokConfig(url: url))
        XCTAssertEqual(saved.model, "openai/whisper-1")
        XCTAssertEqual(saved.language, "fr")
    }

    func testVoiceRefusesToTouchTheMicrophoneOutsideTheAppBundle() throws {
        // The test bundle declares no microphone use, like an unbundled build.
        VoiceDictationController.infoBundle = Bundle(for: ComposerFeatureTests.self)
        defer { VoiceDictationController.infoBundle = .main }
        XCTAssertFalse(VoiceDictationController.canRequestMicrophone)
        let store = makeStore()
        store.harnessMeta.initialize = ["voiceMode": true]
        store.features.composer.toggleVoice()
        XCTAssertTrue(store.banner?.contains("scripts/build-app.sh") == true)
        XCTAssertFalse(store.features.composer.voice.isActive)
        store.harnessMeta.initialize = ["voiceMode": false]
        store.features.composer.toggleVoice()
        XCTAssertEqual(store.banner, "Voice input is turned off for this account.")
    }

    func testDictationInsertsIntoTheDraftWithoutATextView() {
        let store = makeStore()
        let composer = store.features.composer
        store.draft = "Please"
        composer.insertDictation("  fix the build ")
        XCTAssertEqual(store.draft, "Please fix the build")
        store.draft = " "
        composer.insertDictation("Start over")
        XCTAssertEqual(store.draft, "Start over")
    }

    // MARK: Helpers

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        return store
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }
}
