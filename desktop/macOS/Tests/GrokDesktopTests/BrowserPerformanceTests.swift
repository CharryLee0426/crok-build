import XCTest
import SwiftUI
import WebKit
@testable import GrokDesktop

/// What the side panel's browser costs: importing a large Chrome profile, suggesting from a large
/// history, opening the tab, loading pages, and keeping a page open beside a streaming task.
///
/// The PERF lines are the numbers the browser's performance report quotes; run them optimized
/// (`swift build -c release --build-tests -Xswiftc -enable-testing`, then `swift test -c release
/// --skip-build --filter BrowserPerformance`). Time bounds are asserted only in optimized builds and
/// leave several times the measured headroom. The data tests always run; the ones that host views
/// take about a minute and need CROK_DESKTOP_UI_TESTS=1. Web pages here are files written by the
/// test, in a window that is never shown: WebKit loads and runs them in its own processes but does
/// not draw them, so what is measured is this app's side of the work, which is the side that can
/// stall the conversation. Chrome is `ChromeProfileFixture`.
@MainActor
final class BrowserPerformanceTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore?
    private var host: NSHostingView<AnyView>?
    private var window: NSWindow?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("grok-browser-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("project"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.contentView = nil
        store?.shutdown()
        unsetenv("CROK_FIXTURE_CHUNK_SECONDS")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private static var isOptimized: Bool {
        var optimized = true
        assert({ optimized = false; return true }())
        return optimized
    }

    private func requireUITests() throws {
        guard ProcessInfo.processInfo.environment["CROK_DESKTOP_UI_TESTS"] != nil else {
            throw XCTSkip("Set CROK_DESKTOP_UI_TESTS=1 to measure the browser's views (about a minute)")
        }
    }

    private func makeStore(harness: String = "/usr/bin/false") -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString)/state.json"), binaryPath: harness)
        let project = Project(path: directory.appendingPathComponent("project").path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        store.features.browser.makeDataStore = { .nonPersistent() }
        self.store = store
        return store
    }

    private func show<V: View>(_ view: V, in store: AppStore, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.desktopEnvironment(store).background(Theme.canvas)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        self.host = host
        self.window = window
        return host
    }

    @discardableResult
    private func frame() -> Double {
        guard let host else { return 0 }
        let start = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @discardableResult
    private func shown(_ seconds: Double) async throws -> [Double] {
        var times: [Double] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            times.append(frame())
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        return times
    }

    private func eventually(timeout: TimeInterval = 20, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    private static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let ordered = values.sorted()
        return ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int((p / 100 * Double(ordered.count - 1)).rounded()))]
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func megabytes(_ bytes: UInt64?) -> Double { Double(bytes ?? 0) / 1_048_576 }
    private static var footprint: UInt64? { ProcessProbe.usage(of: getpid())?.footprint }

    /// A page with `rows` rows of text and a script that keeps changing it, as a dev server's page does.
    private func writePage(_ name: String, title: String, rows: Int = 200, busy: Bool = false) throws -> URL {
        let body = (0..<rows).map { "<p class=\"row\">Row \($0): the quick brown fox jumps over the lazy dog, \($0 * 7919 % 1009) times.</p>" }.joined(separator: "\n")
        let script = busy ? """
            <style>@keyframes spin { to { transform: rotate(360deg) } } #spinner { width: 40px; height: 40px; background: teal; animation: spin 1s linear infinite }</style>
            <div id="spinner"></div><p id="clock"></p>
            <script>let n = 0; function tick() { document.getElementById('clock').textContent = 'frame ' + (n++); requestAnimationFrame(tick) } tick();
            setInterval(() => { document.title = '\(title) ' + n }, 250)</script>
            """ : ""
        let file = directory.appendingPathComponent("project/\(name).html")
        try Data("<!doctype html><meta charset=\"utf-8\"><title>\(title)</title>\(script)\n\(body)".utf8).write(to: file)
        return file
    }

    // MARK: Chrome import

    /// A profile of someone who has used Chrome for years: the 20,000 pages the import takes, 3,000
    /// cookies, 600 bookmarks. The reading happens off the main thread; the window must stay responsive.
    func testImportingALargeChromeProfile() async throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, size: .init(history: 20_000, cookies: 3_000, bookmarks: 600))
        let profile = root.appendingPathComponent("Default")
        let browser = makeStore().features.browser
        let access = ChromeImportAccess(root: root, authenticate: { _ in }, cookiePassword: { ChromeProfileFixture.password })

        // The parts, timed one at a time.
        var start = DispatchTime.now().uptimeNanoseconds
        let history = try ChromeData.history(in: profile)
        let historyRead = Self.milliseconds(since: start)
        start = DispatchTime.now().uptimeNanoseconds
        let cookies = try ChromeData.cookies(in: profile, cipher: ChromeCookieCipher(password: ChromeProfileFixture.password))
        let cookiesRead = Self.milliseconds(since: start)
        start = DispatchTime.now().uptimeNanoseconds
        let bookmarks = try ChromeData.bookmarks(in: profile)
        let bookmarksRead = Self.milliseconds(since: start)
        XCTAssertEqual(history.count, 20_000)
        XCTAssertEqual(cookies.cookies.count, 3_002)
        XCTAssertEqual(bookmarks.count, 601)

        // The whole import as the sheet runs it, with the main thread watched for stalls.
        let memory = Self.footprint
        let watchdog = MainThreadWatchdog()
        watchdog.start(every: .milliseconds(10))
        let model = ChromeImportModel(access: access)
        await model.load()
        start = DispatchTime.now().uptimeNanoseconds
        await model.run(browser: browser)
        let total = Self.milliseconds(since: start)
        // The watchdog's last ping is answered on the main thread.
        try await Task.sleep(nanoseconds: 50_000_000)
        let stall = watchdog.drain()
        watchdog.stop()
        guard case .finished(let result) = model.phase else { return XCTFail("the import finished: \(model.phase)") }
        XCTAssertEqual(result.history, 20_000)
        XCTAssertEqual(result.cookies, 3_002)
        XCTAssertEqual(result.bookmarks, 601)
        let stored = await browser.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(stored.count, 3_002)

        print(String(format: "PERF Chrome import, read: 20,000 pages %.0f ms, 3,000 cookies (copied and decrypted) %.0f ms, 600 bookmarks %.1f ms",
                     historyRead, cookiesRead, bookmarksRead))
        print(String(format: "PERF Chrome import, whole (read, merge history, store cookies): %.0f ms; longest main-thread stall %.0f ms; memory +%.1f MB",
                     total, stall, Self.megabytes(Self.footprint) - Self.megabytes(memory)))
        if Self.isOptimized {
            XCTAssertLessThan(total, 8_000, "a large profile imports in seconds")
            XCTAssertLessThan(stall, 250, "the window stays responsive while it does")
        }
    }

    // MARK: History

    /// Every keystroke in the address bar asks the history for matches.
    func testSuggestionsFromALargeHistory() async throws {
        func pages(_ count: Int) -> [BrowserHistoryItem] {
            (0..<count).map { index in
                BrowserHistoryItem(url: "https://\(ChromeProfileFixture.host(index))/docs/\(ChromeProfileFixture.topics[index % 8])/page-\(index)?ref=\(index % 13)",
                                   title: "Page \(index) · \(ChromeProfileFixture.topics[index % 8]) guide to \(ChromeProfileFixture.topics[(index / 8) % 8])",
                                   visitCount: 1 + index % 23, lastVisit: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            }
        }
        // What someone types on the way to a page: each prefix is a query.
        let typed = ["s", "sw", "swi", "swif", "swift", "swift g", "swift gu", "site12", "site123.ex", "page-4", "page-42", "webkit sqlite", "keychain guide page", "zzz-nothing"]
        for (count, file) in [(20_000, "history-20k.sqlite"), (100_000, "history-100k.sqlite")] {
            let history = BrowserHistoryStore(file: directory.appendingPathComponent(file))
            var start = DispatchTime.now().uptimeNanoseconds
            try await history.merge(pages(count))
            let merge = Self.milliseconds(since: start)
            var times: [Double] = []
            for _ in 0..<8 {
                for query in typed {
                    start = DispatchTime.now().uptimeNanoseconds
                    let found = await history.suggestions(for: query)
                    times.append(Self.milliseconds(since: start))
                    XCTAssertEqual(found.isEmpty, query == "zzz-nothing", query)
                }
            }
            start = DispatchTime.now().uptimeNanoseconds
            let recent = await history.recent(limit: BrowserModel.recentLimit)
            let recentTime = Self.milliseconds(since: start)
            XCTAssertEqual(recent.count, BrowserModel.recentLimit)
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.size] as? Int) ?? 0
            print(String(format: "PERF history of %@ pages: merge %.0f ms, suggestions p50 %.1f p95 %.1f max %.1f ms, recent pages %.2f ms, %.1f MB on disk",
                         count.formatted(), merge, Self.percentile(times, 50), Self.percentile(times, 95), times.max() ?? 0, recentTime, Double(size) / 1_048_576))
            if Self.isOptimized, count == 20_000 { XCTAssertLessThan(Self.percentile(times, 95), 60, "suggestions keep up with typing") }
        }
    }

    func testRecordingVisitsResolvingAddressesAndDecryptingCookies() async throws {
        let history = BrowserHistoryStore(file: directory.appendingPathComponent("visits.sqlite"))
        try await history.merge((0..<20_000).map { BrowserHistoryItem(url: "https://old\($0).example.com/", title: "Old \($0)", visitCount: 1, lastVisit: Date()) })
        var start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<2_000 { await history.record(url: "https://site\(index % 300).example.com/page/\(index % 700)", title: "Page \(index)") }
        let record = Self.milliseconds(since: start) / 2_000

        let inputs = ["example.com", "localhost:3000/app", "how do actors work in swift", "https://docs.swift.org/swift-book/documentation/", "192.168.1.4:8080", "readme.md"]
        start = DispatchTime.now().uptimeNanoseconds
        var resolved = 0
        for index in 0..<60_000 where BrowserAddress.resolve(inputs[index % inputs.count], searchEngine: .google) != nil { resolved += 1 }
        let resolve = Self.milliseconds(since: start) / 60_000 * 1_000
        XCTAssertEqual(resolved, 60_000)

        let cipher = ChromeCookieCipher(password: ChromeProfileFixture.password)
        let values = (0..<200).map { ChromeProfileFixture.encrypt("value-\($0)-\(String(repeating: "y", count: 80))", host: ".site\($0).example.com") }
        start = DispatchTime.now().uptimeNanoseconds
        var decrypted = 0
        for index in 0..<20_000 where cipher.decrypt(values[index % 200], host: ".site\(index % 200).example.com") != nil { decrypted += 1 }
        let decrypt = Self.milliseconds(since: start) / 20_000 * 1_000
        XCTAssertEqual(decrypted, 20_000)
        start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = ChromeCookieCipher(password: ChromeProfileFixture.password) }
        let derive = Self.milliseconds(since: start) / 20

        print(String(format: "PERF browser small work: record a visit %.3f ms, resolve an address %.2f µs, decrypt a cookie %.2f µs, derive Chrome's key %.2f ms",
                     record, resolve, decrypt, derive))
        if Self.isOptimized {
            XCTAssertLessThan(record, 2)
            XCTAssertLessThan(resolve, 100)
        }
    }

    // MARK: The tab

    /// A browser nobody opened: no tabs, no web view, no WebKit process, nothing read or written.
    func testABrowserNobodyOpenedCostsNothing() async throws {
        let created = BrowserActivity.webViewsCreated, updates = BrowserActivity.hostUpdates
        var start = DispatchTime.now().uptimeNanoseconds
        let store = makeStore()
        _ = store.features
        let features = Self.milliseconds(since: start)
        start = DispatchTime.now().uptimeNanoseconds
        let model = BrowserModel(store: store, directory: directory.appendingPathComponent("unused"))
        let construction = Self.milliseconds(since: start)
        _ = model
        // The main window with the side panel on its other tabs.
        store.showInspector = true
        store.sidePanelTab = .files
        _ = show(ContentView(), in: store, size: CGSize(width: 1320, height: 780))
        try await shown(0.6)
        store.sidePanelTab = .sideChat
        try await shown(0.3)
        let browser = store.features.browser
        XCTAssertEqual(browser.pages.count, 0)
        XCTAssertEqual(BrowserActivity.webViewsCreated, created)
        XCTAssertEqual(BrowserActivity.hostUpdates, updates)
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.directory.path), "no history database, bookmarks, or session file")
        print(String(format: "PERF browser unopened: 0 tabs, 0 web views, 0 files; its model takes %.3f ms to make (all feature models %.1f ms)", construction, features))
        if Self.isOptimized { XCTAssertLessThan(construction, 2) }
    }

    /// Opening the tab, and then a page: when WebKit starts, and what that costs this app.
    func testOpeningTheTabAndLoadingAPage() async throws {
        try requireUITests()
        let store = makeStore()
        let browser = store.features.browser
        store.showInspector = true
        store.sidePanelTab = .files
        _ = show(SidePanelView(containerWidth: 1400), in: store, size: CGSize(width: 560, height: 760))
        try await shown(0.8)

        let created = BrowserActivity.webViewsCreated
        store.sidePanelTab = .browser
        let open = frame()
        try await shown(0.4)
        XCTAssertEqual(browser.pages.count, 1)
        XCTAssertEqual(BrowserActivity.webViewsCreated, created, "the start page is native; WebKit has not started")

        let small = try writePage("small", title: "Small page")
        let large = try writePage("large", title: "Large page", rows: 20_000)
        let memory = Self.footprint
        let watchdog = MainThreadWatchdog()
        watchdog.start(every: .milliseconds(10))
        // The first page: the web view is made and WebKit's processes start.
        var start = DispatchTime.now().uptimeNanoseconds
        browser.open(small.path)
        let webView = Self.milliseconds(since: start)
        let tab = try XCTUnwrap(browser.page)
        while tab.title != "Small page" || tab.isLoading { frame(); try await Task.sleep(nanoseconds: 5_000_000) }
        let firstLoad = Self.milliseconds(since: start)
        // Later pages reuse them.
        var loads: [Double] = []
        for round in 0..<6 {
            let page = round % 2 == 0 ? large : small, title = round % 2 == 0 ? "Large page" : "Small page"
            start = DispatchTime.now().uptimeNanoseconds
            browser.open(page.path)
            while tab.title != title || tab.isLoading { frame(); try await Task.sleep(nanoseconds: 5_000_000) }
            if round % 2 == 0 { loads.append(Self.milliseconds(since: start)) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let stall = watchdog.drain()
        watchdog.stop()
        print(String(format: "PERF browser tab: first open %.1f ms (start page, no web view); making the web view %.1f ms; first page shown after %.0f ms; a 20,000-row page %.0f ms median",
                     open, webView, firstLoad, Self.percentile(loads, 50)))
        print(String(format: "PERF browser tab: longest main-thread stall while loading %.0f ms; this app's memory +%.1f MB with one page open (WebKit's processes are its own)",
                     stall, Self.megabytes(Self.footprint) - Self.megabytes(memory)))
        if Self.isOptimized {
            XCTAssertLessThan(open, 150, "opening the tab is a frame or two")
            XCTAssertLessThan(stall, 400, "making the web view is the only pause, and a short one")
        }
    }

    /// Eight tabs opened and closed: closing a tab gives back its web view.
    func testTabsGiveBackTheirWebViews() async throws {
        let browser = makeStore().features.browser
        let page = try writePage("tab", title: "Tab page", rows: 2_000)
        browser.prepare()
        let before = Self.footprint
        var start = DispatchTime.now().uptimeNanoseconds
        let tabs = (0..<8).map { _ in browser.openTab(page) }
        let opened = Self.milliseconds(since: start)
        try await eventually { tabs.allSatisfy { $0.title == "Tab page" && !$0.isLoading } }
        let loaded = Self.milliseconds(since: start)
        let open = Self.footprint
        weak var view = tabs[0].webView
        XCTAssertNotNil(view)
        start = DispatchTime.now().uptimeNanoseconds
        tabs.forEach { browser.close($0) }
        let closed = Self.milliseconds(since: start)
        XCTAssertEqual(browser.pages.count, 1)
        try await eventually(timeout: 10) { view == nil }
        XCTAssertNil(view, "a closed tab's web view is released")
        try await Task.sleep(nanoseconds: 500_000_000)
        print(String(format: "PERF browser tabs: 8 tabs made in %.0f ms (%.1f ms each), loaded after %.0f ms, closed in %.1f ms; this app's memory +%.1f MB open, +%.1f MB after closing",
                     opened, opened / 8, loaded, closed, Self.megabytes(open) - Self.megabytes(before), Self.megabytes(Self.footprint) - Self.megabytes(before)))
    }

    // MARK: Beside a streaming task

    private struct Scene: View {
        @EnvironmentObject var store: AppStore

        var body: some View {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ConversationView().frame(maxWidth: .infinity)
                    if store.showInspector { SidePanelView(containerWidth: geometry.size.width) }
                }
            }
        }
    }

    /// A task streams while the browser shows a page that keeps changing. The store publishes every
    /// chunk; none of that may reach the browser's views, and the conversation's frames must be what
    /// they are beside the Side chat tab, which 1.2.1 already had: an open panel has its own cost.
    func testAPageStaysOutOfAStreamingTasksWay() async throws {
        try requireUITests()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Requires /usr/bin/python3") }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/mock-grok.py")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
        let executable = directory.appendingPathComponent("fixture-grok")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let store = makeStore(harness: executable.path)
        let browser = store.features.browser
        _ = show(Scene(), in: store, size: CGSize(width: 1400, height: 800))
        let page = try writePage("busy", title: "Busy page", rows: 400, busy: true)

        setenv("CROK_FIXTURE_CHUNK_SECONDS", "0.01", 1)
        let configured = Date().addingTimeInterval(20)
        try await shown(0.3)
        while store.run.isConfiguring && Date() < configured { try await shown(0.1) }
        store.draft = "fixture:mixed:125:2000"
        store.send()
        let started = Date().addingTimeInterval(20)
        while !(store.run.isRunning && (store.conversation?.messages.count ?? 0) > TranscriptPage.size) && Date() < started { try await shown(0.1) }
        XCTAssertTrue(store.run.isRunning, "the task is streaming (phase \(store.run.phase), banner \(store.banner ?? "none"))")
        try await shown(2)

        struct Sample { var frames: [Double] = []; var cpu = 0.0; var wall = 0.0; var messages = 0; var hostUpdates = 0 }
        var samples: [SidePanelTab?: Sample] = [:]
        let seconds = Double(ProcessInfo.processInfo.environment["CROK_SIDE_PANEL_SECONDS"] ?? "6") ?? 6
        for pass in 0..<2 {
            for tab in [nil, SidePanelTab.sideChat, .browser] {
                if let tab {
                    store.sidePanelTab = tab
                    store.showInspector = true
                    if pass == 0, tab == .browser {
                        try await shown(0.3)
                        browser.open(page.path)
                        let tab = try XCTUnwrap(browser.page)
                        let loaded = Date().addingTimeInterval(20)
                        while !tab.title.hasPrefix("Busy page") && Date() < loaded { try await shown(0.1) }
                        XCTAssertTrue(tab.title.hasPrefix("Busy page"), "the page loaded beside the streaming task")
                    }
                } else {
                    store.showInspector = false
                }
                try await shown(1)
                let cpu = Self.cpuSeconds(), wall = Date(), messages = store.conversation?.messages.count ?? 0, updates = BrowserActivity.hostUpdates
                let frames = try await shown(seconds)
                var sample = samples[tab] ?? Sample()
                sample.frames += frames
                sample.cpu += Self.cpuSeconds() - cpu
                sample.wall += Date().timeIntervalSince(wall)
                sample.messages += (store.conversation?.messages.count ?? 0) - messages
                sample.hostUpdates += BrowserActivity.hostUpdates - updates
                samples[tab] = sample
                XCTAssertTrue(store.run.isRunning, "the task is still streaming")
            }
        }
        let closed = samples[nil] ?? Sample(), sideChat = samples[.sideChat] ?? Sample(), open = samples[.browser] ?? Sample()
        for (name, sample) in [("panel closed", closed), ("side chat", sideChat), ("page open", open)] {
            print(String(format: "PERF browser beside a streaming task [%@]: %d frames, frame p50 %.2f p95 %.2f p99 %.2f max %.1f ms, over 16 ms %d, CPU %.0f%% of a core, %.0f messages/s, web view updates %d",
                         name, sample.frames.count, Self.percentile(sample.frames, 50), Self.percentile(sample.frames, 95), Self.percentile(sample.frames, 99),
                         sample.frames.max() ?? 0, sample.frames.filter { $0 > 16 }.count, sample.cpu / max(sample.wall, 0.001) * 100,
                         Double(sample.messages) / max(sample.wall, 0.001), sample.hostUpdates))
        }
        XCTAssertGreaterThan(open.messages, 20, "messages kept arriving while the page was open")
        // The page's own title changes four times a second and reaches the tab strip, not the web view's host.
        XCTAssertLessThanOrEqual(open.hostUpdates, 4, "streaming does not rebuild the page's host: \(open.hostUpdates) updates for \(open.messages) messages")
        let sideChatP95 = Self.percentile(sideChat.frames, 95), openP95 = Self.percentile(open.frames, 95)
        XCTAssertLessThan(openP95, max(sideChatP95 * 2, sideChatP95 + 6), "frames with a page open (p95 \(openP95) ms) against the side chat (p95 \(sideChatP95) ms)")
    }
}
