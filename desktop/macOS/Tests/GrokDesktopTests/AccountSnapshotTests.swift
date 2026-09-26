import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Renders the account panels to PNGs in light and dark when GROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class AccountSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-account-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func output() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["GROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set GROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        return URL(fileURLWithPath: path)
    }

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let home = directory!
        store.features.account.grokHome = { home }
        store.features.account.downloadText = { _, _ in nil }
        return store
    }

    private func render<V: View>(_ name: String, _ view: V, store: AppStore, size: CGSize) throws {
        let folder = try output()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try SnapshotRenderer.write(view.desktopEnvironment(store).frame(width: size.width, height: size.height),
                                       size: size, appearance: appearance,
                                       to: folder.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private var usageState: UsageSheetState {
        var state = UsageSheetState()
        state.context = .loaded(UsageContextSnapshot(["used": 61_450, "total": 256_000, "systemPromptTokens": 9_800, "messageTokens": 44_200,
                                                      "toolDefinitionsCount": 38, "toolDefinitionsTokens": 12_400, "turnCount": 6,
                                                      "toolCallCount": 23, "compactionCount": 1, "usagePct": 24, "autoCompactThresholdPercent": 85,
                                                      "usageCategories": [["label": "Skills", "tokens": 1_240, "detail": "6 skills"],
                                                                          ["label": "MCP servers", "tokens": 3_900, "detail": "2 servers"],
                                                                          ["label": "AGENTS.md", "tokens": 860, "detail": "1 file"]]]))
        state.contextModel = "grok-build"
        state.sessionUsage = .loaded(UsageSessionSummary(["inputTokens": 184_220, "cachedReadTokens": 151_900, "outputTokens": 9_870,
                                                          "reasoningTokens": 4_310, "totalTokens": 194_090, "modelCalls": 14,
                                                          "apiDurationMs": 96_400, "costUsdTicks": 4_128_000_000,
                                                          "modelUsage": ["grok-build": ["inputTokens": 170_000, "outputTokens": 9_100, "costUsdTicks": 3_900_000_000],
                                                                         "grok-fast": ["inputTokens": 14_220, "outputTokens": 770, "costUsdTicks": 228_000_000]]]))
        let info = UsageSessionInfo(["sessionId": "0199a7c4-5e21-7b3a-9c1f-2d8e4b6a1f03", "cwd": "/Users/dev/Projects/grok-desktop",
                                     "model": "grok-build", "modelDisplayName": "Grok Build", "apiBackend": "responses", "turnIndex": 6,
                                     "context": ["used": 61_450, "total": 256_000, "usagePct": 24]])
        state.sessionInfo = .loaded(UsageFormatting.sessionInfoRows(info, title: "Render tables and math", shellVersion: "1.0.41",
                                                                   auth: .providerCredentials, showResolvedModel: false))
        return state
    }

    func testRenderUsageSheet() throws {
        let store = makeStore()
        let account = store.features.account
        account.showPreviewState(usage: usageState)
        for tab in UsageTab.allCases {
            account.usageTab = tab
            try render("usage-\(tab.rawValue)", UsageSheet(initialTab: tab, loadsOnAppear: false), store: store, size: CGSize(width: 680, height: 700))
        }
        var noSession = usageState
        noSession.context = .unavailable("No active session.")
        noSession.sessionUsage = .unavailable("No active session.")
        account.showPreviewState(usage: noSession)
        account.usageTab = .usage
        try render("usage-no-session-usage", UsageSheet(initialTab: .usage, loadsOnAppear: false), store: store, size: CGSize(width: 680, height: 700))
        account.usageTab = .context
        try render("usage-no-session", UsageSheet(initialTab: .context, loadsOnAppear: false), store: store, size: CGSize(width: 680, height: 700))
    }

    func testRenderFeedbackSheet() throws {
        let store = makeStore()
        store.features.account.showPreviewState(drafts: .loaded([
            FeedbackDraftRecord(id: "1", title: "Retried the same failing test", details: "It ran `swift test` eleven times without changing anything.",
                                type: .bug, taskCategory: .debug, failureMode: .stuckInALoop, createdAt: Date(timeIntervalSince1970: 1_790_000_000)),
            FeedbackDraftRecord(id: "2", title: "Remember preferred test runner", details: "Suggest remembering which test command I use per project.",
                                type: .idea, taskCategory: .shell, createdAt: Date(timeIntervalSince1970: 1_789_000_000)),
            FeedbackDraftRecord(id: "3", title: "Feedback draft", details: "Could not send: offline", createdAt: Date(timeIntervalSince1970: 1_788_000_000)),
        ]))
        let image = FeedbackAttachment(data: Self.samplePNG(), mimeType: "image/png", fileName: "diff-view.png")
        try render("feedback-write",
                   FeedbackSheet(initialText: "The diff view jumped to the top every time a new hunk streamed in, so I lost my place while reviewing.",
                                 loadsOnAppear: false, taxonomy: FeedbackTaxonomySelection(type: .bug, taskCategory: .review), images: [image]),
                   store: store, size: CGSize(width: 660, height: 640))
        try render("feedback-empty", FeedbackSheet(initialText: "", loadsOnAppear: false, error: FeedbackCopy.emptySubmit),
                   store: store, size: CGSize(width: 660, height: 640))
        try render("feedback-trace", FeedbackSheet(initialText: "It deleted a file", loadsOnAppear: false,
                                                   taxonomy: FeedbackTaxonomySelection(type: .bug), traceStep: true),
                   store: store, size: CGSize(width: 660, height: 640))
        try render("feedback-drafts", FeedbackSheet(initialText: "", loadsOnAppear: false, tab: .drafts),
                   store: store, size: CGSize(width: 660, height: 640))
    }

    func testRenderReleaseNotes() throws {
        let store = makeStore()
        store.features.account.showPreviewState(releaseNotes: ReleaseNotesState(version: "1.0.41", markdown: """
            ## 1.0.41

            ### Features
            - **Usage sheet**: context window, session usage, and session info in one place.
            - `/feedback` now attaches screenshots.

            ### Fixes
            - Long reasoning streams stay responsive.
            """, source: .remote))
        try render("release-notes", ReleaseNotesWindow(loadsOnAppear: false), store: store, size: CGSize(width: 860, height: 560))
        store.features.account.showPreviewState(releaseNotes: ReleaseNotesState(version: "1.0.41", message: "No release notes available (offline)."))
        try render("release-notes-offline", ReleaseNotesWindow(loadsOnAppear: false), store: store, size: CGSize(width: 860, height: 480))
    }

    func testRenderAnnouncementBanner() throws {
        let store = makeStore()
        let critical = GrokAnnouncement(identifier: "incident", title: "Degraded performance",
                                        message: "Some responses are slower than usual. We're working on a fix.", severity: "critical")
        let promo = GrokAnnouncement(identifier: "heavy", title: "Grok 4 Heavy is here", message: "Our most capable model is now available in Grok Build.",
                                     severity: "promo", action: .init(label: "Try it", url: URL(string: "https://x.ai")!, caption: nil))
        store.features.account.showPreviewState(announcements: [critical])
        try render("announcement-critical", VStack(spacing: 0) { AnnouncementBanner(); Spacer() }, store: store, size: CGSize(width: 900, height: 90))
        store.features.account.showPreviewState(announcements: [promo])
        try render("announcement-promo", VStack(spacing: 0) { AnnouncementBanner(); Spacer() }, store: store, size: CGSize(width: 900, height: 90))
    }

    private static func samplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.26, green: 0.39, blue: 0.30, alpha: 1), ending: NSColor(srgbRed: 0.63, green: 0.75, blue: 0.66, alpha: 1))?
                .draw(in: rect, angle: 45)
            NSColor.white.withAlphaComponent(0.85).setFill()
            for row in 0..<5 { NSBezierPath(roundedRect: NSRect(x: 16, y: 20 + row * 20, width: 96 - row * 9, height: 8), xRadius: 3, yRadius: 3).fill() }
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
