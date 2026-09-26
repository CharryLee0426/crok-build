import XCTest
@testable import GrokDesktop

/// Parsing, formatting, and local-file rules behind /usage, /context, /session-info, /feedback,
/// /release-notes, and /announcements.
@MainActor
final class AccountFeatureTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func makeStore() -> (AppStore, AccountFeatureModel, OpenedLinks) {
        let store = AppStore(stateFile: home.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let account = store.features.account
        let links = OpenedLinks()
        account.grokHome = { [home] in home! }
        account.openURL = { links.urls.append($0) }
        account.downloadText = { _, _ in nil }
        return (store, account, links)
    }

    private final class OpenedLinks { var urls: [URL] = [] }

    // MARK: /usage and account commands

    func testUsageTakesNoArgumentsAndNeverOpensBilling() {
        let (store, account, links) = makeStore()
        for argument in ["manage", "show", "plans"] {
            store.banner = nil
            account.usage(argument)
            XCTAssertEqual(store.banner, "Unknown argument: \(argument). Use /usage")
            XCTAssertNil(store.sheet)
        }
        XCTAssertTrue(links.urls.isEmpty, "there is no billing page to open")
        XCTAssertTrue(store.handleDesktopCommand("cost", arguments: ""))
        XCTAssertEqual(store.sheet, .usage(.usage))
        XCTAssertEqual(account.usageTab, .usage)
        // An open sheet switches tabs in place instead of reopening.
        XCTAssertTrue(store.handleDesktopCommand("context", arguments: ""))
        XCTAssertEqual(store.sheet, .usage(.usage))
        XCTAssertEqual(account.usageTab, .context)
        XCTAssertTrue(store.handleDesktopCommand("status", arguments: ""))
        XCTAssertEqual(account.usageTab, .session)
        XCTAssertEqual(UsageTab.allCases, [.context, .usage, .session])
    }

    func testXAIAccountCommandsAreGone() {
        let (store, _, _) = makeStore()
        let names = DesktopCommands.catalog.flatMap { [$0.name] + $0.aliases }
        XCTAssertFalse(names.contains("logout"))
        XCTAssertFalse(names.contains("privacy"))
        XCTAssertFalse(store.handleDesktopCommand("logout", arguments: ""), "/logout is not a desktop command")
        XCTAssertFalse(store.handleDesktopCommand("privacy", arguments: ""), "/privacy is not a desktop command")
        let usage = DesktopCommands.catalog.first { $0.name == "usage" }
        XCTAssertNil(usage?.argumentHint, "no `show|manage`")
        XCTAssertTrue(store.availableCommands.contains { $0.name == "usage" }, "/usage is always offered")
        XCTAssertEqual(DesktopCommands.catalog.first { $0.name == "login" }?.description, "Sign in to OpenRouter or OpenAI Codex")
        XCTAssertTrue(store.handleDesktopCommand("login", arguments: ""))
        XCTAssertTrue(store.showSettings, "/login opens Settings › Accounts")
        XCTAssertEqual(AccountAuthDescription.providerCredentials.method, "Provider credentials")
    }

    // MARK: Context

    func testTokenCountsAndShares() {
        XCTAssertEqual(UsageFormatting.tokens(999), "999")
        XCTAssertEqual(UsageFormatting.tokens(1_000), "1.0k")
        XCTAssertEqual(UsageFormatting.tokens(99_499), "99.5k")
        XCTAssertEqual(UsageFormatting.tokens(99_500), "100k")
        XCTAssertEqual(UsageFormatting.tokensBig(999_999), "1000k")
        XCTAssertEqual(UsageFormatting.tokensBig(1_234_567), "1.2m")
        XCTAssertEqual(UsageFormatting.percentOfWindow(1, 1_000_000), "0.1%")
        XCTAssertEqual(UsageFormatting.percentOfWindow(0, 1_000), "0.0%")
        XCTAssertEqual(UsageFormatting.percentOfWindow(50_000, 200_000), "25%")
        XCTAssertEqual(UsageFormatting.percentOfWindow(5, 0), "-")
        XCTAssertEqual(UsageFormatting.groupThousands(1_234_567), "1,234,567")
        XCTAssertEqual(UsageFormatting.groupThousands(12), "12")
        XCTAssertEqual(UsageFormatting.duration(milliseconds: 5_240), "5.2s")
        XCTAssertEqual(UsageFormatting.duration(milliseconds: 32_000), "32s")
        XCTAssertEqual(UsageFormatting.duration(milliseconds: 125_000), "2m5s")
        XCTAssertEqual(UsageFormatting.duration(milliseconds: 3_720_000), "1h2m")
    }

    func testContextBreakdownClampsToTheWindow() {
        let snapshot = UsageContextSnapshot(["used": 12_345, "total": 256_000, "systemPromptTokens": 8_200, "messageTokens": 3_000,
                                             "toolDefinitionsCount": 1, "toolDefinitionsTokens": 4_100, "usagePct": 4,
                                             "turnCount": 3, "toolCallCount": 7, "compactionCount": 0,
                                             "usageCategories": [["label": "Skills", "tokens": 900, "detail": "3 skills"], ["tokens": 5]]])
        XCTAssertEqual(snapshot.summary, "12.3k / 256k tokens (4.82%)")
        XCTAssertEqual(snapshot.window.system, 8_200)
        XCTAssertEqual(snapshot.window.messages, 3_000)
        XCTAssertEqual(snapshot.window.overhead, 1_145)
        XCTAssertEqual(snapshot.window.free, 243_655)
        XCTAssertEqual(snapshot.categories.map(\.label), ["Skills"], "rows without a label are dropped")
        XCTAssertEqual(snapshot.autoCompactThresholdPercent, 85, "the harness default when absent")
        XCTAssertEqual(snapshot.stats, "Turns: 3 · Tool calls: 7 · Compactions: 0")
        XCTAssertEqual(UsageFormatting.countDetail(1, "tool"), "1 tool")
        let over = UsageContextSnapshot(["used": 150, "total": 100, "systemPromptTokens": 80, "messageTokens": 50])
        XCTAssertEqual(over.window.system, 80)
        XCTAssertEqual(over.window.messages, 20)
        XCTAssertEqual(over.window.overhead, 0)
        XCTAssertEqual(over.window.free, 0)
    }

    func testAutoCompactLineAndCompactTip() {
        var snapshot = UsageContextSnapshot(["used": 100_000, "total": 200_000, "usagePct": 50, "autoCompactThresholdPercent": 85])
        XCTAssertEqual(snapshot.autoCompact?.text, "Auto-compact at 85% · ~70.0k tokens remaining")
        XCTAssertEqual(snapshot.autoCompact?.warning, false)
        XCTAssertFalse(snapshot.showsCompactTip)
        snapshot.usagePercent = 80
        XCTAssertTrue(snapshot.showsCompactTip)
        snapshot.usagePercent = 85
        XCTAssertFalse(snapshot.showsCompactTip, "no tip once auto-compact is due")
        XCTAssertEqual(snapshot.autoCompact?.text, "Auto-compact triggers next turn (at 85%)")
        XCTAssertEqual(snapshot.autoCompact?.warning, true)
        XCTAssertNil(UsageContextSnapshot(["used": 1]).autoCompact, "no window, no line")
        let tiny = UsageContextSnapshot(["used": 1, "total": 3, "usagePct": 33, "autoCompactThresholdPercent": 85])
        XCTAssertEqual(tiny.autoCompact?.text, "Auto-compact at 85% · ~2 tokens remaining", "the threshold rounds up")
    }

    // MARK: Session usage and info

    func testSessionUsageSummary() {
        XCTAssertEqual(UsageSessionSummary(["modelCalls": 0]).emptyMessage, "Session usage: no model calls yet in this session.")
        XCTAssertEqual(UsageSessionSummary(["usageIsIncomplete": true]).emptyMessage,
                       "Session usage: none recorded, but tracking is incomplete and may under-count.")
        let summary = UsageSessionSummary(["inputTokens": 12_345, "cachedReadTokens": 1_234, "outputTokens": 678, "reasoningTokens": 90,
                                           "totalTokens": 13_023, "modelCalls": 3, "apiDurationMs": 5_240, "costUsdTicks": 1_234_000_000,
                                           "modelUsage": ["grok-b": ["inputTokens": 1_000, "outputTokens": 200, "costIsPartial": true],
                                                          "grok-a": ["inputTokens": 11_345, "outputTokens": 478, "costUsdTicks": 100_000_000]]])
        XCTAssertEqual(summary.rows.map(\.value), ["12,345 (1,234 cached)", "678 (90 reasoning)", "13,023", "3 · API time: 5.2s", "$0.1234"])
        XCTAssertEqual(summary.models.map(\.label), ["grok-a", "grok-b"])
        XCTAssertEqual(summary.models.last?.value, "1,000 in / 200 out · not available (not reported for some calls)")
        XCTAssertTrue(summary.text.hasPrefix("Session usage (since start or last resume):\n  Input tokens: 12,345 (1,234 cached)"))
        let single = UsageSessionSummary(["modelCalls": 1, "usageIsIncomplete": true, "modelUsage": ["grok": ["inputTokens": 1]]])
        XCTAssertTrue(single.models.isEmpty, "the per-model list appears only for several models")
        XCTAssertEqual(single.rows.last?.value, "not available (not reported)")
        XCTAssertTrue(single.text.hasSuffix("  Note: usage is incomplete and may under-count."))
    }

    func testSessionInfoRowsMatchTheTerminal() {
        let info = UsageSessionInfo(["sessionId": "sid-1", "cwd": "/work/app", "model": "grok-build", "resolvedModelId": "grok-build-0923",
                                     "modelFingerprint": "fp_abc", "showModelFingerprint": false, "conversationId": "",
                                     "apiBackend": "responses", "turnIndex": 4,
                                     "context": ["used": 1_000, "total": 4_000, "usagePct": 25]])
        let rows = UsageFormatting.sessionInfoRows(info, title: "Fix login", shellVersion: "1.0.41",
                                                   auth: AccountAuthDescription(method: "OAuth", note: nil), showResolvedModel: true)
        XCTAssertEqual(rows.map(\.label), ["Title", "Shell version", "Auth method", "Session ID", "Working directory", "Model", "API Backend", "Turn", "Context"])
        XCTAssertEqual(rows.first { $0.label == "Model" }?.value, "grok-build (grok-build-0923)")
        XCTAssertEqual(rows.last?.value, "1,000 / 4,000 tokens (25%)")
        let shown = UsageSessionInfo(["sessionId": "sid-2", "cwd": "/w", "modelDisplayName": "Grok Build", "model": "grok-build",
                                      "modelFingerprint": "fp_abc", "showModelFingerprint": true, "conversationId": "conv-9"])
        let other = UsageFormatting.sessionInfoRows(shown, title: nil, shellVersion: nil, auth: .providerCredentials, showResolvedModel: false)
        XCTAssertEqual(other.first?.label, "Shell version")
        XCTAssertEqual(other.first?.value, "unknown")
        XCTAssertEqual(other.first { $0.label == "Model" }?.value, "Grok Build")
        XCTAssertEqual(other.first { $0.label == "Model Hash" }?.value, "fp_abc")
        XCTAssertEqual(other.first { $0.label == "Conversation ID" }?.value, "conv-9")
        XCTAssertTrue(UsageFormatting.copyText(other).contains("Session ID: sid-2"))
    }

    // MARK: Announcements

    func testAnnouncementKeysAndSelection() {
        XCTAssertEqual(GrokAnnouncement(identifier: "  launch-1 ", message: "x").hideKey, "launch-1")
        XCTAssertEqual(GrokAnnouncement(identifier: "  ", title: "Outage", message: "Degraded").hideKey, "content:Outage\u{1F}Degraded")
        XCTAssertEqual(GrokAnnouncement(message: "Only a message").hideKey, "content:\u{1F}Only a message")
        let now = Date()
        let promo = GrokAnnouncement(identifier: "promo", message: "Try Heavy", severity: "promo")
        let critical = GrokAnnouncement(identifier: "crit", title: "Incident", message: "Slow responses", severity: "critical")
        let pinned = GrokAnnouncement(identifier: "pinned", message: "Must read", severity: "critical", dismissible: false)
        let expired = GrokAnnouncement(identifier: "old", message: "Gone", severity: "critical", expiresAt: now.addingTimeInterval(-1))
        let info = GrokAnnouncement(identifier: "info", message: "Welcome only", severity: "info")
        let blank = GrokAnnouncement(identifier: "blank", message: "  ", severity: "critical")
        XCTAssertEqual(AnnouncementRules.current([promo, critical], hidden: [], now: now), critical, "critical beats promo")
        XCTAssertEqual(AnnouncementRules.current([promo, critical], hidden: ["crit"], now: now), promo)
        XCTAssertNil(AnnouncementRules.current([expired, info, blank], hidden: [], now: now))
        XCTAssertEqual(AnnouncementRules.current([pinned], hidden: ["pinned"], now: now), pinned, "only dismissible items can be hidden")
        XCTAssertEqual(AnnouncementRules.sessionHideKeys([promo, critical, expired, info], now: now), ["promo", "crit"])
        var hidden: Set<String> = ["promo", "stale"]
        XCTAssertTrue(AnnouncementRules.prune(&hidden, active: [promo]))
        XCTAssertEqual(hidden, ["promo"])
        XCTAssertFalse(AnnouncementRules.prune(&hidden, active: [promo]))
    }

    func testAnnouncementActionsAreWebLinksOnly() {
        let good = GrokAnnouncement(["id": "a", "message": "m", "cta": ["label": " Upgrade ", "url": "https://grok.com/plans", "caption": "or later"]])
        XCTAssertEqual(good.action?.label, "Upgrade")
        XCTAssertEqual(good.action?.url.absoluteString, "https://grok.com/plans")
        XCTAssertNil(GrokAnnouncement(["message": "m", "cta": ["label": "Open", "url": "file:///etc/passwd"]]).action)
        XCTAssertNil(GrokAnnouncement(["message": "m", "cta": ["label": "", "url": "https://x.ai"]]).action)
    }

    func testHiddenAnnouncementsFileIsSharedWithTheTerminal() throws {
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), [], "missing file hides nothing")
        try Data("not json".utf8).write(to: AnnouncementHiddenFile.url(home: home))
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), [])
        try Data(#"{"hidden":true}"#.utf8).write(to: AnnouncementHiddenFile.url(home: home))
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), [], "the legacy shape carries no ids")
        try AnnouncementHiddenFile.write(["zeta", "alpha"], home: home)
        XCTAssertEqual(String(decoding: try Data(contentsOf: AnnouncementHiddenFile.url(home: home)), as: UTF8.self), #"{"hidden_ids":["alpha","zeta"]}"#)
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), ["alpha", "zeta"])
    }

    func testAnnouncementUpdatesHideShowAndPrune() async throws {
        let (store, account, links) = makeStore()
        try AnnouncementHiddenFile.write(["stale-key", "promo-1"], home: home)
        let update: [String: Any] = ["gen": 10, "announcements": [
            ["id": "promo-1", "message": "Grok Heavy is here", "severity": "promo", "cta": ["label": "Learn more", "url": "https://x.ai/heavy"]],
            ["id": "crit-1", "title": "Degraded service", "message": "Responses may be slow.", "severity": "critical"],
        ]]
        XCTAssertTrue(account.handleGlobal(method: "x.ai/announcements/update", params: update))
        account.flushAnnouncementWrites()
        XCTAssertEqual(account.currentAnnouncement?.identifier, "crit-1")
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), ["promo-1"], "keys for announcements that are gone are pruned")
        XCTAssertTrue(store.handleDesktopCommand("announcements", arguments: "hide"))
        account.flushAnnouncementWrites()
        XCTAssertNil(account.currentAnnouncement)
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), ["promo-1", "crit-1"])
        store.executeCommand(name: "announcements", arguments: "show now")
        account.flushAnnouncementWrites()
        XCTAssertEqual(account.currentAnnouncement?.identifier, "crit-1")
        XCTAssertEqual(AnnouncementHiddenFile.read(home: home), [])
        // An older generation from another harness process never replaces a newer list.
        _ = account.handleGlobal(method: "x.ai/announcements/update", params: ["gen": 9, "announcements": []])
        XCTAssertEqual(account.announcements.count, 2)
        store.executeCommand(name: "announcements", arguments: "")
        XCTAssertEqual(store.banner, "Usage: /announcements hide | show")
        store.banner = nil
        store.executeCommand(name: "announcements", arguments: "HIDE")
        XCTAssertEqual(store.banner, "Usage: /announcements hide | show")
        _ = account.handleGlobal(method: "x.ai/announcements/update", params: ["gen": 11, "announcements": [
            ["id": "pinned", "message": "Required update", "severity": "critical", "dismissible": false],
        ]])
        account.hideCurrentAnnouncement()
        account.flushAnnouncementWrites()
        XCTAssertEqual(account.currentAnnouncement?.identifier, "pinned", "a pinned banner cannot be hidden")
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        _ = account.handleGlobal(method: "x.ai/announcements/update", params: ["gen": 12, "announcements": [
            ["id": "brief", "message": "Maintenance now", "severity": "critical", "expires_at": soon],
        ]])
        XCTAssertEqual(account.currentAnnouncement?.identifier, "brief")
        let deadline = Date().addingTimeInterval(6)
        while account.hasSessionAnnouncements && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(account.hasSessionAnnouncements, "expired announcements are taken down")
        XCTAssertNil(account.currentAnnouncement)
        account.openAnnouncementAction(GrokAnnouncement(["message": "m", "cta": ["label": "Go", "url": "https://x.ai/go"]]))
        XCTAssertEqual(links.urls.last?.absoluteString, "https://x.ai/go")
    }

    // MARK: Feedback

    func testFeedbackWriteRequestIsSnakeCaseWithStructuredTaxonomy() throws {
        let image = try XCTUnwrap(FeedbackAttachment.make(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), fileName: "shot.png"))
        let params = FeedbackRequests.write(sessionID: "sid", text: "It crashed", images: [image],
                                            taxonomy: FeedbackTaxonomySelection(type: .missingCapability, taskCategory: .codeEdit, failureMode: nil),
                                            requestTraceUploadToken: true, clientVersion: "0.1.0")
        XCTAssertEqual(params["session_id"] as? String, "sid")
        XCTAssertEqual(params["client_type"] as? String, "desktop")
        XCTAssertEqual(params["feedback_text"] as? String, "It crashed")
        XCTAssertEqual(params["request_trace_upload_token"] as? Bool, true)
        XCTAssertEqual(params["client_version"] as? String, "0.1.0")
        let envelope = try XCTUnwrap((params["metadata"] as? [String: Any])?["structured_feedback"] as? [String: Any])
        XCTAssertEqual(envelope["schema_version"] as? Int, 1)
        XCTAssertEqual(envelope["source"] as? String, "write")
        XCTAssertEqual(envelope["type"] as? String, "missing_capability")
        XCTAssertEqual(envelope["task_category"] as? String, "code_edit")
        XCTAssertNil(envelope["failure_mode"], "absent enums are omitted, never null")
        let wire = try XCTUnwrap((params["images"] as? [[String: Any]])?.first)
        XCTAssertEqual(wire["mimeType"] as? String, "image/png")
        XCTAssertEqual(wire["fileName"] as? String, "shot.png")
        XCTAssertEqual(wire["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(params))
    }

    func testDraftSendKeepsFormFieldsInsideEditedBody() throws {
        let params = FeedbackRequests.draft(sessionID: "sid", draftID: "d1", title: "Title", details: "Details", area: " ", type: .bug,
                                            taxonomy: FeedbackTaxonomySelection(type: .bug, taskCategory: nil, failureMode: .stuckInALoop),
                                            images: [], requestTraceUploadToken: false, clientVersion: "0.1.0")
        XCTAssertEqual(Set(params.keys), ["session_id", "draft_id", "request_trace_upload_token", "edited_body"])
        let body = try XCTUnwrap(params["edited_body"] as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "bug")
        XCTAssertEqual(body["failure_mode"] as? String, "stuck_in_a_loop")
        XCTAssertNil(body["area"], "a blank area is dropped")
        XCTAssertNil(body["task_category"])
        let update = FeedbackRequests.update(sessionID: "sid", draftID: "d1", title: "T", details: "D", area: "tui", type: .idea,
                                             taxonomy: FeedbackTaxonomySelection(type: .idea, taskCategory: .plan))
        XCTAssertEqual(update["task_category"] as? String, "plan")
        XCTAssertEqual(update["area"] as? String, "tui")
        XCTAssertEqual(update["draft_id"] as? String, "d1")
    }

    func testFeedbackTaxonomyValuesAndLabels() {
        XCTAssertEqual(FeedbackKind.allCases.map(\.rawValue), ["bug", "idea", "missing_capability"])
        XCTAssertEqual(FeedbackTaskCategory.allCases.map(\.rawValue), ["code_edit", "debug", "explain", "plan", "shell", "search", "review", "other"])
        XCTAssertEqual(FeedbackFailureMode.allCases.map(\.rawValue), ["overeager", "stopped_early", "unwanted_scope", "didnt_ask_for_help",
                                                                      "excessive_questions", "subagent_overspawn", "over_correction",
                                                                      "ignored_instructions", "hallucinated", "sloppy_code", "destructive",
                                                                      "lost_context", "stuck_in_a_loop", "model_regression", "disputed",
                                                                      "wrong_tone", "unclear_output", "other"])
        XCTAssertEqual(FeedbackFailureMode.groups.flatMap(\.modes), FeedbackFailureMode.allCases, "every mode sits in exactly one section")
        XCTAssertEqual(FeedbackFailureMode(wire: "did_too_much"), .overeager)
        XCTAssertEqual(FeedbackFailureMode.hallucinated.label, "Overconfidence and hallucination")
        XCTAssertEqual(FeedbackCopy.tracePrompt(for: .idea), "Attach this session's trace to give this idea context?")
        XCTAssertEqual(FeedbackCopy.tracePrompt(for: nil), "Attach this session's trace to your feedback?")
        XCTAssertEqual(FeedbackTraceChoice.allCases.map(\.label), ["Send this session's trace", "No, just the feedback", "No, and don't ask again"])
    }

    func testFeedbackRepliesDraftRowsAndTitles() {
        XCTAssertEqual(FeedbackResponse(["success": true]).outcome, .submitted, "an older harness omits the outcome")
        let reply = FeedbackResponse(["success": false, "outcome": "outcome_unknown", "traceUploadToken": "tok"])
        XCTAssertEqual(reply.outcome, .outcomeUnknown)
        XCTAssertFalse(reply.posted)
        XCTAssertEqual(FeedbackResponse(["outcome": "submitted_cleanup_failed"]).posted, true)
        XCTAssertEqual(FeedbackResponse(["outcome": "from_the_future"]).outcome, .other)
        let row = FeedbackDraftRecord(["id": "d1", "title": "Stuck", "details": "\n  \nIt looped forever\nmore", "type": "bug",
                                       "failure_mode": "stuck_in_loop", "created_at": 1_700_000_000, "revision": 2])
        XCTAssertEqual(row?.classification, "Bug · Other · Repetition and looping")
        XCTAssertEqual(row?.preview, "It looped forever")
        XCTAssertEqual(FeedbackDraftRecord(["id": "d2", "text": "legacy"])?.classification, "Unclassified · Other")
        XCTAssertNil(FeedbackDraftRecord(["title": "no id"]))
        XCTAssertEqual(row?.matches("LOOPED"), true)
        XCTAssertEqual(FeedbackText.deriveTitle("\n   \n  First line here  \nsecond"), "First line here")
        XCTAssertEqual(FeedbackText.deriveTitle(String(repeating: "é", count: 100)).count, 80)
        XCTAssertEqual(FeedbackText.deriveTitle("   "), "Feedback draft")
        XCTAssertEqual(FeedbackText.postText(title: " T ", details: " D \n"), "T\n\nD")
    }

    func testFeedbackImageLimits() throws {
        func image(_ bytes: Int, _ name: String) -> FeedbackAttachment {
            FeedbackAttachment(data: Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: max(0, bytes - 3))), mimeType: "image/jpeg", fileName: name)
        }
        XCTAssertEqual(FeedbackAttachment.sniffedType(Data([0x47, 0x49, 0x46, 0x38, 0x39])), "image/gif")
        XCTAssertEqual(FeedbackAttachment.sniffedType(Data("RIFF0000WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(FeedbackAttachment.make(data: Data("not an image".utf8), fileName: "notes.txt"))
        let three = (0..<3).map { image(10, "\($0).jpg") }
        let admitted = FeedbackImageRules.admit([image(10, "a.jpg"), image(10, "b.jpg")], to: three)
        XCTAssertEqual(admitted.accepted.count, 1)
        XCTAssertEqual(admitted.notice, "Feedback takes up to 4 images.")
        let large = FeedbackImageRules.admit([image(FeedbackImageRules.maximumBytes + 1, "huge.png")], to: [])
        XCTAssertTrue(large.accepted.isEmpty)
        XCTAssertEqual(large.notice, "huge.png is larger than 8 MB.")
        let total = FeedbackImageRules.admit([image(7 * 1024 * 1024, "a"), image(7 * 1024 * 1024, "b"), image(3 * 1024 * 1024, "c")], to: [])
        XCTAssertEqual(total.accepted.map(\.fileName), ["a", "b"])
        XCTAssertEqual(total.notice, "Images can add up to at most 16 MB.")
    }

    func testUnsentFeedbackIsKeptAsALocalDraft() throws {
        let session = home.appendingPathComponent("sessions/%2Fwork/sid-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let first = try FeedbackPredraftStore.append(sessionDirectory: session, title: "Crash on start", details: "Crash on start\nstack…")
        let second = try FeedbackPredraftStore.append(sessionDirectory: session, title: "Second", details: "More")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.appendingPathComponent("feedback_drafts.json"))) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        let drafts = try XCTUnwrap(document["drafts"] as? [[String: Any]])
        XCTAssertEqual(drafts.map { $0["id"] as? String }, [first, second])
        XCTAssertEqual(drafts.first?["revision"] as? Int, 1)
        XCTAssertNil(drafts.first?["type"], "a predraft has no taxonomy yet")
        XCTAssertNotNil(drafts.first?["created_at"] as? Int)
        let id = first
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(Array(id)[14], "7", "UUIDv7")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent(".feedback_drafts.lock").path))
        // A document from a newer schema is never rewritten.
        let newer = Data(#"{"schema_version":2,"drafts":[]}"#.utf8)
        try newer.write(to: session.appendingPathComponent("feedback_drafts.json"))
        XCTAssertThrowsError(try FeedbackPredraftStore.append(sessionDirectory: session, title: "T", details: "D"))
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("feedback_drafts.json")), newer)
        XCTAssertThrowsError(try FeedbackPredraftStore.append(sessionDirectory: home.appendingPathComponent("missing"), title: "T", details: "D"))
        XCTAssertThrowsError(try FeedbackPredraftStore.append(sessionDirectory: session, title: " ", details: "D"))
    }

    func testFeedbackTraceOfferGates() throws {
        let (store, account, _) = makeStore()
        store.harnessMeta.initialize = ["feedbackTraceOffer": true]
        store.harnessMeta.authenticate = ["coding_data_retention_opt_out": false]
        XCTAssertTrue(account.feedbackTraceOffered)
        store.harnessMeta.authenticate["team_name"] = "Acme"
        XCTAssertFalse(account.feedbackTraceOffered, "never offered on a team")
        store.harnessMeta.authenticate = ["coding_data_retention_opt_out": true]
        XCTAssertFalse(account.feedbackTraceOffered, "only offered to people who opted in")
        store.harnessMeta.authenticate = ["coding_data_retention_opt_out": false, "is_zdr": true]
        XCTAssertFalse(account.feedbackTraceOffered)
        store.harnessMeta.authenticate = ["coding_data_retention_opt_out": false]
        try Data("[features]\nfeedback_trace_card = false\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        XCTAssertFalse(account.feedbackTraceOffered, "'don't ask again' from the terminal is honoured")
    }

    // MARK: Error text

    func testErrorText() {
        XCTAssertEqual(AccountErrorText.describe(ACPClientError.remote(code: -32603, message: "Internal error", data: "Session service error: HTTP 503")),
                       "Session service error: HTTP 503")
        XCTAssertEqual(AccountErrorText.describe(ACPClientError.remote(code: -32603, message: "Internal error", data: ["message": "Bad request"])), "Bad request")
        XCTAssertEqual(AccountErrorText.describe(ACPClientError.remote(code: -32603, message: "Internal error", data: nil)), "Internal error")
    }

    // MARK: Release notes

    func testReleaseNotesPreferTheCDNAndFallBackToTheCache() async throws {
        var requested: [URL] = []
        let remote = await ReleaseNotesLoader.load(version: "1.0.41", home: home, environment: [:]) { url, timeout in
            requested.append(url)
            XCTAssertEqual(timeout, 3)
            return "## 1.0.41\n\n- Faster\n"
        }
        XCTAssertEqual(requested, [URL(string: "https://x.ai/cli/changelogs/1.0.41.external.md")!])
        XCTAssertEqual(remote?.source, .remote)
        XCTAssertEqual(remote?.markdown, "## 1.0.41\n\n- Faster")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("CHANGELOG.md"), encoding: .utf8), "## 1.0.41\n\n- Faster\n", "downloads refresh the cache")
        let cached = await ReleaseNotesLoader.load(version: "1.0.41", home: home, environment: [:]) { _, _ in nil }
        XCTAssertEqual(cached?.source, .cache)
        let offline = await ReleaseNotesLoader.load(version: "1.0.41", home: home, environment: ["GROK_CHANGELOG_OFFLINE": "1"]) { _, _ in
            XCTFail("offline mode must not download"); return "remote"
        }
        XCTAssertEqual(offline?.source, .cache)
        XCTAssertNil(ReleaseNotesLoader.url(version: "../../etc"))
        try FileManager.default.removeItem(at: home.appendingPathComponent("CHANGELOG.md"))
        let nothing = await ReleaseNotesLoader.load(version: nil, home: home, environment: [:]) { _, _ in "unused" }
        XCTAssertNil(nothing)
        XCTAssertEqual(ReleaseNotesLoader.parseVersion(Data(#"{"currentVersion":"1.0.41 (ef60bab1fc85)","channel":"stable"}"#.utf8)), "1.0.41")
    }

    func testReleaseNotesWindowStateUsesTheRuntimeVersion() async throws {
        let (store, account, _) = makeStore()
        store.harnessMeta.initialize = ["agentVersion": "2.0.0"]
        var asked: URL?
        account.downloadText = { url, _ in asked = url; return nil }
        account.loadReleaseNotes()
        let deadline = Date().addingTimeInterval(5)
        while account.releaseNotes.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(asked?.lastPathComponent, "2.0.0.external.md")
        XCTAssertEqual(account.releaseNotes.message, "No release notes available (offline).")
        XCTAssertEqual(account.releaseNotes.version, "2.0.0")
    }
}
