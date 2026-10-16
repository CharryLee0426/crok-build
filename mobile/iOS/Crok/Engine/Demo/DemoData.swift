import Foundation

extension DemoWorld {
    /// Fills the world with sample data relative to `now`, so times read "now", "4m", "2h", "3d".
    func build(now: Date) {
        let t = now.milliseconds
        let minute = 60_000.0
        let hour = 60 * minute
        let day = 24 * hour

        devices = [
            DeviceRow(
                id: "demo-phone", kind: .phone, name: "Charlie's iPhone", platform: "iOS 26.0", client: AppInfo.clientName,
                createdAt: t - 20 * day, lastSeenAt: t, online: true, isCurrent: true, liveSessionCount: 0),
            DeviceRow(
                id: "mbp", kind: .computer, name: "MacBook Pro", platform: "macOS 26.1 arm64", client: "Crok Desktop 1.5.0",
                createdAt: t - 30 * day, lastSeenAt: t - 2 * minute, online: true, isCurrent: false, liveSessionCount: 3),
            DeviceRow(
                id: "studio", kind: .computer, name: "Studio", platform: "macOS 15.6 arm64", client: "crok 1.0.45",
                createdAt: t - 60 * day, lastSeenAt: t - 3 * hour, online: false, isCurrent: false, liveSessionCount: 0),
            DeviceRow(
                id: "ipad", kind: .phone, name: "iPad Air", platform: "iPadOS 26.0", client: "Crok iOS 1.0 (1)",
                createdAt: t - 12 * day, lastSeenAt: t - 2 * day, online: false, isCurrent: false, liveSessionCount: 0),
        ]

        func detail(
            _ id: String, title: String, cwd: String, device: String, app: HostApp, status: SessionStatus, online: Bool,
            last: Double, created: Double, pinned: Bool = false, archived: Bool = false, unread: Double = 0,
            model: String = "grok-code-fast-1", effort: String? = "high", branch: String? = "main",
            plan: [PlanEntry] = [], usage: SessionUsage? = nil, history: HistoryState? = nil
        ) -> SessionDetail {
            let deviceRow = devices.first(where: { $0.id == device })
            return SessionDetail(
                id: id, sessionId: "0199e2\(id.hashValue.magnitude % 100_000)-7c1d-7e2f-9a10-5d3c2b1a0f9e", title: title,
                cwd: cwd, model: model, effort: effort, gitBranch: branch, status: status, online: online, app: app,
                deviceId: device, deviceName: deviceRow?.name ?? "", devicePlatform: deviceRow?.platform ?? "",
                deviceOnline: deviceRow?.online ?? false, createdAt: created, lastActivityAt: last, plan: plan, usage: usage,
                pinned: pinned, archived: archived, unread: unread, eventSeq: 0, historyState: history)
        }
        let crokBuild = "/Users/charlie/src/crok-build"

        // 1. Running, pinned, with a plan and every kind of event.
        let flakyPlan = [
            PlanEntry(content: "Reproduce the flaky upload test", status: "completed"),
            PlanEntry(content: "Find what depends on wall-clock time", status: "completed"),
            PlanEntry(content: "Inject a clock into UploadQueue", status: "completed"),
            PlanEntry(content: "Run the test 50 times", status: "in_progress"),
            PlanEntry(content: "Update the retry docs", status: "pending"),
            PlanEntry(content: "Open a pull request", status: "pending"),
            PlanEntry(content: "Ask for review", status: "pending"),
        ]
        var flaky = Session(
            detail: detail(
                "s-flaky", title: "Fix the flaky upload test", cwd: "/Users/charlie/src/crok-build", device: "mbp", app: .tui,
                status: .running, online: true, last: t - 0.4 * minute, created: t - 3 * hour, pinned: true, unread: 2,
                branch: "fix/upload-flake", plan: flakyPlan,
                usage: SessionUsage(
                    inputTokens: 184_220, outputTokens: 12_940, cachedTokens: 151_000, reasoningTokens: 4_310,
                    costUsd: 0.4187, contextTokens: 61_400, contextWindow: 256_000)),
            events: [], commands: [], preview: "Running cargo test -p crok-remote", previewKind: .tool)
        let base = t - 2.5 * hour
        func ev(_ seq: Double, _ kind: EventKind, _ text: String, at: Double, title: String? = nil, toolKind: String? = nil,
                status: String? = nil, origin: String? = nil, commandId: String? = nil, fromLabel: String? = nil) -> TranscriptEvent
        {
            TranscriptEvent(
                id: "e-flaky-\(Int(seq))", seq: seq, key: "k\(Int(seq))", kind: kind, text: text, title: title, toolKind: toolKind,
                status: status, origin: origin, commandId: commandId, fromLabel: fromLabel, at: at)
        }
        flaky.events = [
            ev(1, .user, "The upload test fails about one run in ten on CI. Can you find out why?", at: base - day, origin: "local"),
            ev(2, .thought, "The test waits on a retry. Retries use `Task.sleep` with real time, so a slow runner could miss the deadline. Check the queue first.", at: base - day + 20_000),
            ev(3, .tool, "Sources/Relay/UploadQueue.swift", at: base - day + 30_000, title: "Read UploadQueue.swift", toolKind: "read", status: "completed"),
            ev(4, .tool, "rg -n \"Task.sleep\" Sources/Relay\nSources/Relay/UploadQueue.swift:88:        try await Task.sleep(for: backoff)", at: base - day + 40_000, title: "Search for sleeps", toolKind: "search", status: "completed"),
            ev(5, .assistant, "Found it: `UploadQueue` sleeps on the **real** clock between retries, and the test only waits 2 s. On a slow runner the second retry is late.\n\nI can make the queue take a clock so the test controls time. Want me to?", at: base - day + 60_000),
            ev(6, .system, "", at: base - day + 61_000, status: "end_turn"),
            ev(7, .user, "Yes, do that. Keep the public API the same.", at: base, origin: "remote", commandId: "c-flaky-1", fromLabel: "Charlie's iPhone"),
            ev(8, .tool, "Sources/Relay/UploadQueue.swift\n+    init(clock: some Clock<Duration> = ContinuousClock())", at: base + 40_000, title: "Edit UploadQueue.swift", toolKind: "edit", status: "completed"),
            ev(9, .tool, "swift test --filter UploadQueueTests\nerror: no such module 'RelayTestSupport'", at: base + 90_000, title: "Run swift test", toolKind: "execute", status: "failed"),
            ev(10, .error, "The test helper module is missing from Package.swift.", at: base + 95_000),
            ev(11, .assistant, "The tests need `RelayTestSupport`, which `Package.swift` never declared. Adding it as a test-only target.", at: base + 100_000),
            ev(12, .system, "", at: base + 101_000, status: "cancelled"),
            ev(13, .user, "Go on, and run it 50 times when it builds.", at: t - 6 * minute, origin: "remote", commandId: "c-flaky-2", fromLabel: "Charlie's iPhone"),
            ev(14, .thought, "Add the target, rebuild, then loop the test.", at: t - 5.8 * minute),
            ev(15, .tool, "Package.swift\n+        .target(name: \"RelayTestSupport\", path: \"Tests/Support\"),", at: t - 5.5 * minute, title: "Edit Package.swift", toolKind: "edit", status: "completed"),
            ev(16, .assistant, "Added the target. The build is clean:\n\n- `UploadQueue` takes a `Clock`\n- tests use `TestClock`\n- no public API change\n\nNow looping the test.", at: t - 4 * minute),
            ev(17, .tool, "for i in $(seq 50); do swift test --filter UploadQueueTests || break; done\nTest Suite 'UploadQueueTests' passed (31/50)", at: t - 0.4 * minute, title: "Run the test 50 times", toolKind: "execute", status: "in_progress"),
        ]
        flaky.commands = [
            PromptCommand(id: "c-flaky-1", clientId: "demo-client-1", text: "Yes, do that. Keep the public API the same.", status: .done, error: nil, fromLabel: "Charlie's iPhone", createdAt: base - 2_000, updatedAt: base + 101_000),
            PromptCommand(id: "c-flaky-2", clientId: "demo-client-2", text: "Go on, and run it 50 times when it builds.", status: .delivered, error: nil, fromLabel: "Charlie's iPhone", createdAt: t - 6.1 * minute, updatedAt: t - 6 * minute),
            PromptCommand(id: "c-flaky-3", clientId: "demo-client-3", text: "Also check the download test", status: .failed, error: "The computer was busy and dropped the prompt. Try again.", fromLabel: "Charlie's iPhone", createdAt: t - 1.5 * minute, updatedAt: t - 1 * minute),
        ]
        flaky.detail.eventSeq = 17

        // 2. Waiting for approval on the computer.
        var darkMode = Session(
            detail: detail(
                "s-dark", title: "Add dark mode to Settings", cwd: "/Users/charlie/src/crok-build/desktop/macOS", device: "mbp",
                app: .desktop, status: .waiting, online: true, last: t - 4 * minute, created: t - 50 * minute,
                model: "claude-sonnet-4-5", effort: "medium", branch: "feat/settings-dark",
                plan: [PlanEntry(content: "Theme tokens", status: "completed"), PlanEntry(content: "Settings pane", status: "in_progress")],
                usage: SessionUsage(inputTokens: 40_100, outputTokens: 3_200, cachedTokens: 31_000, reasoningTokens: 0, costUsd: 0.093, contextTokens: 22_000, contextWindow: 200_000)),
            events: [], commands: [], preview: "Allow `xcodebuild -scheme Crok build`?", previewKind: .tool,
            projectPath: crokBuild)
        darkMode.events = [
            TranscriptEvent(id: "e-dark-1", seq: 1, key: "k1", kind: .user, text: "Add a dark variant to the Settings pane.", origin: "local", at: t - 50 * minute),
            TranscriptEvent(id: "e-dark-2", seq: 2, key: "k2", kind: .tool, text: "xcodebuild -scheme Crok build", title: "Run xcodebuild", toolKind: "execute", status: "pending", at: t - 4 * minute),
        ]

        // 2b. Waiting on a permission request any device can answer (`pending`): allowing it runs the command and
        // finishes the turn; denying it ends the turn.
        var deps = Session(
            detail: detail(
                "s-deps", title: "Bump the relay's dependencies", cwd: "\(crokBuild)/relay", device: "mbp", app: .tui,
                status: .waiting, online: true, last: t - 1 * minute, created: t - 20 * minute, branch: "chore/deps",
                usage: SessionUsage(inputTokens: 21_300, outputTokens: 1_450, cachedTokens: 17_800, reasoningTokens: 600, costUsd: 0.034, contextTokens: 14_200, contextWindow: 256_000)),
            events: [], commands: [], preview: "Run npm install", previewKind: .tool, projectPath: crokBuild)
        deps.events = [
            TranscriptEvent(id: "e-deps-1", seq: 1, key: "k1", kind: .user, text: "Update convex and next in the relay to their latest versions.", origin: "local", at: t - 20 * minute),
            TranscriptEvent(id: "e-deps-2", seq: 2, key: "k2", kind: .tool, text: "relay/package.json", title: "Read package.json", toolKind: "read", status: "completed", at: t - 19.5 * minute),
            TranscriptEvent(id: "e-deps-3", seq: 3, key: "k3", kind: .assistant, text: "`convex` is on 1.25.4 and `next` on 15.3.2; both have newer releases with fixes the relay wants. Installing them, then I'll run the tests.", at: t - 1.2 * minute),
            TranscriptEvent(id: "e-deps-4", seq: 4, key: "k4", kind: .tool, text: DemoWorld.installCommand, title: "Run npm install", toolKind: "execute", status: "pending", at: t - 1 * minute),
        ]
        deps.detail.pending = PendingInteraction(
            id: "call_deps#1", title: "Run \(DemoWorld.installCommand)", detail: "cd relay && \(DemoWorld.installCommand)",
            toolKind: "execute",
            options: [
                PendingOption(optionId: "allow-once", name: "Allow once", kind: "allow_once"),
                PendingOption(optionId: "allow-always", name: "Always allow npm install", kind: "allow_always"),
                PendingOption(optionId: "reject-once", name: "Deny", kind: "reject_once"),
            ],
            at: t - 1 * minute)

        // 3. Idle, last word from the phone.
        var relay = Session(
            detail: detail(
                "s-relay", title: "Relay: device sign-in", cwd: "/Users/charlie/src/crok-build/relay", device: "mbp", app: .tui,
                status: .idle, online: true, last: t - 2 * hour, created: t - 5 * hour,
                usage: SessionUsage(inputTokens: 98_000, outputTokens: 7_400, cachedTokens: 80_000, reasoningTokens: 1_200, costUsd: 0.21, contextTokens: 48_000, contextWindow: 256_000)),
            events: [], commands: [], preview: "Ship it", previewKind: .user, projectPath: crokBuild)
        relay.events = [
            TranscriptEvent(id: "e-relay-0", seq: 1, key: "k0", kind: .user, text: "Do device codes work more than once?", origin: "remote", commandId: "c-relay-0", fromLabel: "Web", at: t - 2.3 * hour),
            TranscriptEvent(id: "e-relay-1", seq: 2, key: "k1", kind: .assistant, text: "Not any more: device codes now expire after ten minutes and work once.", at: t - 2.1 * hour),
            TranscriptEvent(id: "e-relay-2", seq: 3, key: "k2", kind: .user, text: "Ship it", origin: "remote", commandId: "c-relay-1", fromLabel: "Charlie's iPhone", at: t - 2 * hour),
        ]
        relay.commands = [
            PromptCommand(id: "c-relay-1", clientId: "demo-client-4", text: "Ship it", status: .done, error: nil, fromLabel: "Charlie's iPhone", fromDeviceId: "demo-phone", mine: true, createdAt: t - 2 * hour, updatedAt: t - 2 * hour),
            PromptCommand(id: "c-relay-0", clientId: "web-client-1", text: "Do device codes work more than once?", status: .done, error: nil, fromLabel: "Web", fromDeviceId: nil, mine: false, createdAt: t - 2.3 * hour, updatedAt: t - 2.2 * hour),
        ]

        // 4. On the second computer (offline since), with an unread reply.
        var bench = Session(
            detail: detail(
                "s-bench", title: "Benchmark the tokenizer", cwd: "/Users/charlie/src/tokenizer", device: "studio", app: .tui,
                status: .idle, online: false, last: t - 5 * hour, created: t - 9 * hour, unread: 1, model: "grok-4",
                usage: SessionUsage(inputTokens: 220_000, outputTokens: 18_000, cachedTokens: 190_000, reasoningTokens: 9_000, costUsd: 1.12, contextTokens: 130_000, contextWindow: 256_000)),
            events: [], commands: [], preview: "The SIMD path is 3.1× faster on long inputs; short inputs are unchanged.", previewKind: .assistant)
        bench.events = [
            TranscriptEvent(id: "e-bench-1", seq: 1, key: "k1", kind: .assistant, text: "The SIMD path is 3.1× faster on long inputs; short inputs are unchanged.", at: t - 5 * hour),
        ]

        // 5. Offline (the process exited).
        var pager = Session(
            detail: detail(
                "s-pager", title: "Refactor the pager's scroll model", cwd: "/home/charlie/xai-grok-pager", device: "studio",
                app: .tui, status: .idle, online: false, last: t - 26 * hour, created: t - 30 * hour),
            events: [], commands: [], preview: "Moved the anchor logic into ScrollModel.", previewKind: .assistant)
        pager.events = [
            TranscriptEvent(id: "e-pager-1", seq: 1, key: "k1", kind: .assistant, text: "Moved the anchor logic into `ScrollModel`.", at: t - 26 * hour),
        ]

        // 6. Offline, a few days old.
        var notes = Session(
            detail: detail(
                "s-notes", title: "Release notes for 1.5", cwd: "/Users/charlie/src/crok-build", device: "mbp", app: .desktop,
                status: .idle, online: false, last: t - 3 * day, created: t - 3 * day - hour),
            events: [], commands: [], preview: "Wrote the notes in six languages.", previewKind: .assistant)
        notes.events = [
            TranscriptEvent(id: "e-notes-1", seq: 1, key: "k1", kind: .assistant, text: "Wrote the notes in six languages.", at: t - 3 * day),
        ]

        // 7. Archived.
        var old = Session(
            detail: detail(
                "s-old", title: "Try a different diff renderer", cwd: "/Users/charlie/scratch", device: "mbp", app: .tui,
                status: .idle, online: false, last: t - 12 * day, created: t - 12 * day, archived: true),
            events: [], commands: [], preview: "Kept the current renderer.", previewKind: .assistant)
        old.events = [
            TranscriptEvent(id: "e-old-1", seq: 1, key: "k1", kind: .assistant, text: "Kept the current renderer.", at: t - 12 * day),
        ]

        // 8. Listed from the computers' disks (no crok runs them): their transcripts come over when they are opened,
        // while the computer is online.
        func listed(_ prefix: String, _ seq: Double, _ kind: EventKind, _ text: String, at: Double, title: String? = nil,
                toolKind: String? = nil, status: String? = nil) -> TranscriptEvent
        {
            TranscriptEvent(
                id: "e-\(prefix)-\(Int(seq))", seq: seq, key: "k\(Int(seq))", kind: kind, text: text, title: title,
                toolKind: toolKind, status: status, origin: "local", at: at)
        }
        let website = "/Users/charlie/src/website"
        var pricing = Session(
            detail: detail(
                "s-pricing", title: "Fix the pricing page layout", cwd: website, device: "mbp", app: .tui, status: .idle,
                online: false, last: t - 7 * hour, created: t - 8 * hour, history: .notFetched),
            events: [], commands: [], preview: "Moved the plan cards into a grid; phones now stack them.",
            previewKind: .assistant)
        pricing.historyOnComputer = [
            listed("pricing", 1, .user, "The pricing cards overflow on small screens. Can you fix the layout?", at: t - 8 * hour),
            listed("pricing", 2, .tool, "src/pages/pricing.tsx", at: t - 8 * hour + 20_000, title: "Read pricing.tsx", toolKind: "read", status: "completed"),
            listed("pricing", 3, .assistant, "Moved the plan cards into a CSS grid with `minmax(240px, 1fr)` columns. On phones they now stack, and the comparison table scrolls sideways.", at: t - 7 * hour),
            listed("pricing", 4, .system, "", at: t - 7 * hour + 1_000, status: "end_turn"),
        ]
        var changelog = Session(
            detail: detail(
                "s-changelog", title: "Add a changelog page", cwd: website, device: "mbp", app: .tui, status: .idle,
                online: false, last: t - 2 * day, created: t - 2 * day - hour, history: .notFetched),
            events: [], commands: [], preview: nil, previewKind: nil)
        changelog.historyOnComputer = [
            listed("changelog", 1, .user, "Add a changelog page that reads CHANGELOG.md at build time.", at: t - 2 * day),
        ]
        var releaseScript = Session(
            detail: detail(
                "s-release-script", title: "Tidy the release script", cwd: "\(crokBuild)/release", device: "mbp", app: .tui,
                status: .idle, online: false, last: t - 5 * day, created: t - 5 * day - hour, history: .notFetched),
            events: [], commands: [], preview: "publish.sh now checks the signature before uploading.", previewKind: .assistant,
            projectPath: crokBuild)
        releaseScript.historyOnComputer = [
            listed("release", 1, .user, "Make publish.sh refuse to upload an unsigned build.", at: t - 5 * day - hour),
            listed("release", 2, .assistant, "`publish.sh` now checks the signature before uploading and stops with a clear message when it is missing.", at: t - 5 * day),
        ]
        var settingsI18n = Session(
            detail: detail(
                "s-i18n", title: "Translate the settings pane", cwd: crokBuild, device: "mbp", app: .desktop, status: .idle,
                online: false, last: t - 6 * day, created: t - 6 * day - hour, history: .notFetched),
            events: [], commands: [], preview: "All six languages are in.", previewKind: .assistant)
        settingsI18n.historyOnComputer = [
            listed("i18n", 1, .user, "Translate the new settings pane into the other five languages.", at: t - 6 * day - hour),
            listed("i18n", 2, .assistant, "All six languages are in.", at: t - 6 * day),
        ]
        var lexer = Session(
            detail: detail(
                "s-lexer", title: "Port the lexer to Rust", cwd: "/Users/charlie/src/tokenizer", device: "studio", app: .tui,
                status: .idle, online: false, last: t - 4 * day, created: t - 4 * day - 2 * hour, model: "grok-4",
                history: .notFetched),
            events: [], commands: [], preview: "Started with the number literals.", previewKind: .assistant)
        lexer.historyOnComputer = [
            listed("lexer", 1, .user, "Port the lexer to Rust, starting with literals.", at: t - 4 * day - 2 * hour),
            listed("lexer", 2, .assistant, "Started with the number literals.", at: t - 4 * day),
        ]

        sessions = [
            flaky, darkMode, deps, relay, bench, pager, notes, old, pricing, changelog, releaseScript, settingsI18n, lexer,
        ]
            .map { session in
                var session = session
                session.detail.eventSeq = session.events.map(\.seq).max() ?? 0
                return session
            }
    }
}
