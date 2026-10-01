import AppKit
import WebKit
import XCTest
@testable import GrokDesktop

/// The side panel's browser: addresses, history, tabs, and importing from a Chrome profile. Chrome
/// here is `ChromeProfileFixture`; the keychain and macOS's authentication are stand-ins.
@MainActor
final class BrowserTests: XCTestCase {
    private var directory: URL!
    /// Shut down after each test, so no web view or WebKit process outlives it.
    private var stores: [AppStore] = []

    override func setUpWithError() throws {
        // Resolved, as the web view reports the files it loads.
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("grok-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.shutdown() }
        stores = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> AppStore {
        let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString)/state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        store.state = DesktopState(projects: [project], selectedProjectID: project.id)
        store.features.browser.makeDataStore = { .nonPersistent() }
        stores.append(store)
        return store
    }

    private func eventually(timeout: TimeInterval = 10, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Condition was not reached before timeout", file: file, line: line)
    }

    private func access(root: URL, authenticated: @escaping () -> Void = {}, password: String = ChromeProfileFixture.password) -> ChromeImportAccess {
        ChromeImportAccess(root: root, authenticate: { _ in authenticated() }, cookiePassword: { password })
    }

    // MARK: Addresses

    func testAddressesLoadAsTypedAndEverythingElseIsSearched() {
        func resolve(_ text: String) -> String? { BrowserAddress.resolve(text, searchEngine: .google)?.absoluteString }
        XCTAssertEqual(resolve("https://example.com/a?b=c"), "https://example.com/a?b=c")
        XCTAssertEqual(resolve("  http://example.com  "), "http://example.com")
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("docs.swift.org/swift-book/"), "https://docs.swift.org/swift-book/")
        XCTAssertEqual(resolve("localhost:3000"), "http://localhost:3000", "a dev server on this Mac is plain HTTP")
        XCTAssertEqual(resolve("localhost:5173/app?x=1"), "http://localhost:5173/app?x=1")
        XCTAssertEqual(resolve("127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(resolve("192.168.1.20"), "http://192.168.1.20")
        XCTAssertEqual(resolve("8.8.8.8"), "https://8.8.8.8")
        XCTAssertEqual(resolve("about:blank"), "about:blank")
        XCTAssertEqual(resolve("swift concurrency"), "https://www.google.com/search?q=swift%20concurrency")
        XCTAssertEqual(resolve("what is a.b"), "https://www.google.com/search?q=what%20is%20a.b", "words with a dot in them are still a search")
        XCTAssertEqual(resolve("readme"), "https://www.google.com/search?q=readme")
        XCTAssertEqual(resolve("javascript:alert(1)"), "https://www.google.com/search?q=javascript:alert(1)", "a script is searched for, never run")
        XCTAssertNil(resolve("   "))
        XCTAssertEqual(BrowserAddress.resolve("rust", searchEngine: .duckDuckGo)?.absoluteString, "https://duckduckgo.com/?q=rust")
        XCTAssertEqual(BrowserAddress.resolve("rust", searchEngine: .bing)?.host, "www.bing.com")
    }

    func testAFileOnThisMacOpensByPath() throws {
        let file = directory.appendingPathComponent("index.html")
        try Data("<title>Local</title>".utf8).write(to: file)
        XCTAssertEqual(BrowserAddress.resolve(file.path)?.isFileURL, true)
        XCTAssertEqual(BrowserAddress.resolve(file.path)?.path, file.path)
        XCTAssertEqual(BrowserAddress.resolve("/no/such/file.html")?.host, "www.google.com")
    }

    func testTheAddressBarShowsAddressesTheWayBrowsersDo() {
        XCTAssertEqual(BrowserAddress.display(URL(string: "https://example.com/")), "example.com")
        XCTAssertEqual(BrowserAddress.display(URL(string: "https://example.com/a/b?c=d")), "example.com/a/b?c=d")
        XCTAssertEqual(BrowserAddress.display(URL(string: "http://localhost:3000/")), "http://localhost:3000", "an unencrypted address keeps its scheme")
        XCTAssertEqual(BrowserAddress.display(URL(string: "about:blank")), "")
        XCTAssertEqual(BrowserAddress.display(URL(fileURLWithPath: "/tmp/a.html")), "/tmp/a.html")
        XCTAssertEqual(BrowserAddress.display(nil), "")
    }

    func testOnlyAPageWithTheKeyboardTakesBrowserShortcuts() {
        func event(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        XCTAssertEqual(BrowserShortcut(event("l", .command)), .focusAddress)
        XCTAssertEqual(BrowserShortcut(event("r", .command)), .reload)
        XCTAssertEqual(BrowserShortcut(event("[", .command)), .back)
        XCTAssertEqual(BrowserShortcut(event("]", .command)), .forward)
        XCTAssertEqual(BrowserShortcut(event("t", .command)), .newTab)
        XCTAssertEqual(BrowserShortcut(event("w", .command)), .closeTab)
        XCTAssertEqual(BrowserShortcut(event("=", .command)), .zoomIn)
        XCTAssertEqual(BrowserShortcut(event("-", .command)), .zoomOut)
        XCTAssertEqual(BrowserShortcut(event("0", .command)), .actualSize)
        XCTAssertNil(BrowserShortcut(event("l", [])), "typing a letter is typing")
        XCTAssertNil(BrowserShortcut(event("j", .command)), "the side panel's own shortcut passes through")
        XCTAssertNil(BrowserShortcut(event("b", [.command, .option])))
        XCTAssertNil(BrowserShortcut(event("r", [.command, .option])))
    }

    func testDownloadsNeverReplaceAFileOrLeaveTheFolder() throws {
        let folder = directory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(BrowserDownloads.destination(for: "report.pdf", in: folder).lastPathComponent, "report.pdf")
        try Data().write(to: folder.appendingPathComponent("report.pdf"))
        XCTAssertEqual(BrowserDownloads.destination(for: "report.pdf", in: folder).lastPathComponent, "report 2.pdf")
        try Data().write(to: folder.appendingPathComponent("report 2.pdf"))
        XCTAssertEqual(BrowserDownloads.destination(for: "report.pdf", in: folder).lastPathComponent, "report 3.pdf")
        XCTAssertEqual(BrowserDownloads.destination(for: "../../etc/passwd", in: folder).path, folder.appendingPathComponent("passwd").path)
        XCTAssertEqual(BrowserDownloads.destination(for: ".zshrc", in: folder).lastPathComponent, "zshrc", "a download is never a hidden file")
        XCTAssertEqual(BrowserDownloads.destination(for: "", in: folder).lastPathComponent, "download")
    }

    // MARK: History

    func testHistoryCountsVisitsAndSuggestsTheMostVisitedMatches() async throws {
        let history = BrowserHistoryStore(file: directory.appendingPathComponent("browser/history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await history.record(url: "https://swift.org/documentation/", title: "Swift Documentation", at: start)
        await history.record(url: "https://swift.org/documentation/", title: "", at: start.addingTimeInterval(60))
        await history.record(url: "https://developer.apple.com/swift/", title: "Swift - Apple Developer", at: start.addingTimeInterval(120))
        await history.record(url: "https://www.rust-lang.org/", title: "Rust", at: start.addingTimeInterval(180))
        await history.record(url: "chrome://version", title: "not a web page", at: start)
        await history.record(url: "file:///tmp/a.html", title: "not a web page either", at: start)
        let count = await history.count()
        XCTAssertEqual(count, 3)

        let swift = await history.suggestions(for: "swift")
        XCTAssertEqual(swift.map(\.url), ["https://swift.org/documentation/", "https://developer.apple.com/swift/"], "the page visited twice comes first")
        XCTAssertEqual(swift.first?.visitCount, 2)
        XCTAssertEqual(swift.first?.title, "Swift Documentation", "a visit without a title keeps the title already known")
        XCTAssertEqual(swift.first?.lastVisit, start.addingTimeInterval(60))
        let words = await history.suggestions(for: "apple SWIFT")
        XCTAssertEqual(words.map(\.url), ["https://developer.apple.com/swift/"], "every word must match, in the address or the title")
        let nothing = await history.suggestions(for: "100%")
        XCTAssertEqual(nothing, [], "a % is a character to find, not a wildcard")
        let underscore = await history.suggestions(for: "_")
        XCTAssertEqual(underscore, [])
        let empty = await history.suggestions(for: "   ")
        XCTAssertEqual(empty, [])

        await history.setTitle("The Rust Programming Language", for: "https://www.rust-lang.org/")
        let recent = await history.recent(limit: 2)
        XCTAssertEqual(recent.map(\.title), ["The Rust Programming Language", "Swift - Apple Developer"])

        // A second store on the same file reads what the first wrote.
        let reopened = BrowserHistoryStore(file: directory.appendingPathComponent("browser/history.sqlite"))
        let kept = await reopened.count()
        XCTAssertEqual(kept, 3)
        await reopened.clear()
        let cleared = await history.count()
        XCTAssertEqual(cleared, 0)
    }

    func testMergingImportedHistoryKeepsTheLaterVisitAndTheLargerCount() async throws {
        let history = BrowserHistoryStore(file: nil)
        let visited = Date(timeIntervalSince1970: 1_700_000_000)
        await history.record(url: "https://a.example/", title: "Mine", at: visited)
        let merged = try await history.merge([
            BrowserHistoryItem(url: "https://a.example/", title: "Chrome's", visitCount: 7, lastVisit: visited.addingTimeInterval(-500)),
            BrowserHistoryItem(url: "https://b.example/", title: "B", visitCount: 2, lastVisit: visited.addingTimeInterval(10)),
        ])
        XCTAssertEqual(merged, 2)
        let pages = await history.recent()
        XCTAssertEqual(pages, [
            BrowserHistoryItem(url: "https://b.example/", title: "B", visitCount: 2, lastVisit: visited.addingTimeInterval(10)),
            BrowserHistoryItem(url: "https://a.example/", title: "Mine", visitCount: 7, lastVisit: visited),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/:memory:"), "a store without a file writes none")
    }

    // MARK: Chrome's data

    func testChromeTimesCountMicrosecondsFrom1601() {
        XCTAssertEqual(ChromeTime.date(13_350_000_000_000_000), Date(timeIntervalSince1970: 1_705_526_400))
        XCTAssertNil(ChromeTime.date(0))
        XCTAssertEqual(ChromeTime.microseconds(Date(timeIntervalSince1970: 1_705_526_400)), 13_350_000_000_000_000)
    }

    func testProfilesAreListedByNameWithTheLastUsedFirst() throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, profiles: [("Profile 2", "Personal", nil), ("Default", "Work", "me@example.com")])
        // Folders Chrome keeps beside its profiles are not profiles.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Crashpad"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 9"), withIntermediateDirectories: true)
        let profiles = ChromeData.profiles(in: root)
        XCTAssertEqual(profiles.map(\.id), ["Profile 2", "Default"])
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(profiles.map(\.account), [nil, "me@example.com"])
        XCTAssertEqual(ChromeData.profiles(in: directory.appendingPathComponent("NoChrome")), [])
    }

    func testCookiesAreDecryptedWithTheKeychainKey() throws {
        let cipher = ChromeCookieCipher(password: ChromeProfileFixture.password)
        XCTAssertEqual(cipher.key.count, 16)
        let host = ".example.com"
        XCTAssertEqual(cipher.decrypt(ChromeProfileFixture.encrypt("token=abc; 123", host: host), host: host), "token=abc; 123")
        XCTAssertEqual(cipher.decrypt(ChromeProfileFixture.encrypt("before-130", host: host, withHostDigest: false), host: host), "before-130",
                       "values from before Chrome 130 carry no host digest")
        XCTAssertEqual(cipher.decrypt(ChromeProfileFixture.encrypt("", host: host), host: host), "")
        XCTAssertNil(ChromeCookieCipher(password: "wrong").decrypt(ChromeProfileFixture.encrypt("secret", host: host), host: host), "another key reads nothing")
        XCTAssertNil(cipher.decrypt(Data("v11abcdefghijklmnop".utf8), host: host), "an unknown format is not guessed at")
        XCTAssertNil(cipher.decrypt(Data("v10".utf8), host: host))
        XCTAssertNil(cipher.decrypt(Data(), host: host))
    }

    func testAProfilesCookiesHistoryAndBookmarksAreRead() throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, size: .init(history: 25, cookies: 12, bookmarks: 6))
        let profile = root.appendingPathComponent("Default")

        let history = try ChromeData.history(in: profile)
        XCTAssertEqual(history.count, 25, "hidden pages and chrome:// pages are left out")
        XCTAssertEqual(history.first?.url, "https://site0.example.com/docs/page-0?ref=fixture", "the newest first")
        XCTAssertEqual(history.first?.visitCount, 1)
        XCTAssertEqual(try ChromeData.history(in: profile, limit: 5).count, 5)

        let result = try ChromeData.cookies(in: profile, cipher: ChromeCookieCipher(password: ChromeProfileFixture.password))
        XCTAssertEqual(result.cookies.count, 14, "the 12, the unencrypted one, and the session cookie")
        XCTAssertEqual(result.undecryptable, 1, "the cookie under another key")
        XCTAssertEqual(result.skipped, 2, "the expired cookie and the partitioned one")
        let first = try XCTUnwrap(result.cookies.first { $0.name == "session0" })
        XCTAssertEqual(first.domain, "site0.example.com")
        XCTAssertEqual(first.value, "value-0-")
        XCTAssertTrue(first.isSecure && first.isHTTPOnly)
        XCTAssertEqual(first.sameSite, .none)
        XCTAssertEqual(result.cookies.first { $0.name == "session1" }?.sameSite, .lax)
        XCTAssertEqual(result.cookies.first { $0.name == "session2" }?.sameSite, .strict)
        XCTAssertEqual(result.cookies.first { $0.name == "plain" }?.value, "not-encrypted")
        XCTAssertNil(try XCTUnwrap(result.cookies.first { $0.name == "tab" }).expires, "a session cookie has no expiry")

        let cookie = try XCTUnwrap(first.httpCookie)
        XCTAssertEqual(cookie.domain, "site0.example.com")
        XCTAssertTrue(cookie.isSecure && cookie.isHTTPOnly)
        XCTAssertEqual(result.cookies.first { $0.name == "session1" }?.httpCookie?.domain, ".site1.example.com", "a leading dot covers subdomains")
        XCTAssertEqual(result.cookies.first { $0.name == "session1" }?.httpCookie?.sameSitePolicy, .sameSiteLax)
        XCTAssertEqual(result.cookies.first { $0.name == "tab" }?.httpCookie?.isSessionOnly, true)

        let wrongKey = try ChromeData.cookies(in: profile, cipher: ChromeCookieCipher(password: "wrong"))
        XCTAssertEqual(wrongKey.cookies.map(\.name), ["plain"], "without the key, only what Chrome left unencrypted")
        XCTAssertEqual(wrongKey.undecryptable, 14)

        let bookmarks = try ChromeData.bookmarks(in: profile)
        XCTAssertEqual(bookmarks.map(\.title), ["Bookmark 0", "Bookmark 1", "Bookmark 2", "Bookmark 3", "Bookmark 4", "Bookmark 5", "Elsewhere"])
        XCTAssertEqual(bookmarks.map(\.folder), ["Bookmarks Bar", "Bookmarks Bar", "Bookmarks Bar", "Bookmarks Bar / Reading", "Bookmarks Bar / Reading",
                                                 "Bookmarks Bar / Reading", "Other Bookmarks"])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("crok-chrome-import-") }
        XCTAssertEqual(leftovers, [], "the private copies of Chrome's databases are removed")
    }

    func testOlderChromeProfilesAndNewerLayoutsAreRead() throws {
        // Before SameSite and partitioning; and the `Network` folder newer versions keep cookies in.
        let profile = directory.appendingPathComponent("Old/Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Network"), withIntermediateDirectories: true)
        try ChromeProfileFixture.writeCookies(profile.appendingPathComponent("Network/Cookies"), count: 4, now: Date(), legacy: true)
        let result = try ChromeData.cookies(in: profile, cipher: ChromeCookieCipher(password: ChromeProfileFixture.password))
        XCTAssertEqual(result.cookies.map(\.value), ["old-0", "old-1", "old-2", "old-3"])
        XCTAssertEqual(Set(result.cookies.map(\.sameSite)), [.unspecified])
        // A profile with nothing in it imports nothing, without an error.
        let empty = directory.appendingPathComponent("Empty/Default")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(try ChromeData.history(in: empty), [])
        XCTAssertEqual(try ChromeData.bookmarks(in: empty), [])
        XCTAssertEqual(try ChromeData.cookies(in: empty, cipher: ChromeCookieCipher(password: "x")), ChromeData.CookieResult())
        try Data("not json".utf8).write(to: empty.appendingPathComponent("Bookmarks"))
        XCTAssertThrowsError(try ChromeData.bookmarks(in: empty))
        try Data("not a database".utf8).write(to: empty.appendingPathComponent("History"))
        XCTAssertThrowsError(try ChromeData.history(in: empty))
    }

    // MARK: Importing

    func testNothingOfChromesIsReadUntilMacOSConfirmsTheOwner() async throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, size: .init(history: 10, cookies: 5, bookmarks: 4))
        let store = makeStore()
        let browser = store.features.browser
        var keychainRequests = 0

        // The owner dismisses the request: nothing is read, and the sheet is back where it was.
        let cancelled = ChromeImportModel(access: ChromeImportAccess(root: root, authenticate: { _ in throw ChromeImportError.authenticationCancelled },
                                                                    cookiePassword: { keychainRequests += 1; return ChromeProfileFixture.password }))
        await cancelled.load()
        XCTAssertEqual(cancelled.profile?.name, "Work")
        await cancelled.run(browser: browser)
        XCTAssertEqual(cancelled.phase, .ready)
        // macOS cannot confirm them: the sheet says why.
        let refused = ChromeImportModel(access: ChromeImportAccess(root: root, authenticate: { _ in throw ChromeImportError.notAuthenticated("No password is set.") },
                                                                  cookiePassword: { keychainRequests += 1; return ChromeProfileFixture.password }))
        await refused.load()
        await refused.run(browser: browser)
        guard case .failed(let message) = refused.phase else { return XCTFail("expected a failure, got \(refused.phase)") }
        XCTAssertTrue(message.contains("nothing was read from Chrome"), message)
        XCTAssertEqual(keychainRequests, 0, "the keychain is not asked for Chrome's key")
        let pages = await browser.history.count()
        XCTAssertEqual(pages, 0)
        XCTAssertEqual(browser.bookmarks, [])
        let cookies = await browser.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookies, [])
    }

    func testImportingBringsSignInsHistoryAndBookmarksIntoTheBrowser() async throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, size: .init(history: 30, cookies: 9, bookmarks: 6))
        let store = makeStore()
        let browser = store.features.browser
        var reasons: [String] = []
        var authenticated = false
        let model = ChromeImportModel(access: ChromeImportAccess(root: root, authenticate: { reasons.append($0); authenticated = true }, cookiePassword: {
            XCTAssertTrue(authenticated, "the keychain is asked only after the owner is confirmed")
            return ChromeProfileFixture.password
        }))
        await model.load()
        XCTAssertTrue(model.canImport)
        await model.run(browser: browser)
        XCTAssertEqual(reasons, ["import your Chrome cookies, history, and bookmarks"])
        XCTAssertEqual(model.phase, .finished(ChromeImportResult(cookies: 11, history: 30, bookmarks: 7,
                                                                 problems: ["1 cookie could not be decrypted and was left out."])))

        let cookies = await browser.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.count, 11)
        let session = try XCTUnwrap(cookies.first { $0.name == "session4" })
        XCTAssertEqual(session.value, "value-4-xxxx")
        XCTAssertEqual(session.domain, ".site4.example.com")
        XCTAssertTrue(session.isSecure)
        let suggestions = await browser.history.suggestions(for: "page-7")
        XCTAssertEqual(suggestions.map(\.url), ["https://site7.example.com/docs/page-7?ref=fixture"])
        XCTAssertEqual(browser.bookmarks.count, 7)
        XCTAssertEqual(browser.bookmarks.last?.folder, "Other Bookmarks")
        try await eventually { browser.recent.count == BrowserModel.recentLimit }

        // Importing again adds nothing twice.
        model.reset()
        await model.run(browser: browser)
        XCTAssertEqual(model.phase, .finished(ChromeImportResult(cookies: 11, history: 30, bookmarks: 0,
                                                                 problems: ["1 cookie could not be decrypted and was left out."])))
        let again = await browser.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(again.count, 11)
        let pages = await browser.history.count()
        XCTAssertEqual(pages, 30)
        XCTAssertEqual(browser.bookmarks.count, 7)
        // Bookmarks are on disk for the next launch.
        try await eventually { FileManager.default.fileExists(atPath: browser.directory.appendingPathComponent("bookmarks.json").path) }
    }

    func testAKeychainRefusalStillImportsWhatNeedsNoKey() async throws {
        let root = directory.appendingPathComponent("Chrome", isDirectory: true)
        try ChromeProfileFixture.make(root: root, size: .init(history: 8, cookies: 5, bookmarks: 2))
        let browser = makeStore().features.browser
        let model = ChromeImportModel(access: ChromeImportAccess(root: root, authenticate: { _ in }, cookiePassword: { throw ChromeImportError.keychainDenied }))
        await model.load()
        await model.run(browser: browser)
        guard case .finished(let result) = model.phase else { return XCTFail("expected a result, got \(model.phase)") }
        XCTAssertNil(result.cookies)
        XCTAssertEqual(result.history, 8)
        XCTAssertEqual(result.bookmarks, 3)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.problems[0].contains("Chrome Safe Storage"), result.problems[0])

        // Only cookies selected, and no key: nothing came in, which is a failure.
        let onlyCookies = ChromeImportModel(access: ChromeImportAccess(root: root, authenticate: { _ in }, cookiePassword: { throw ChromeImportError.keychainDenied }))
        await onlyCookies.load()
        onlyCookies.selection = ChromeImportSelection(cookies: true, history: false, bookmarks: false)
        await onlyCookies.run(browser: browser)
        guard case .failed = onlyCookies.phase else { return XCTFail("expected a failure, got \(onlyCookies.phase)") }
        onlyCookies.reset()
        onlyCookies.selection = ChromeImportSelection(cookies: false, history: false, bookmarks: false)
        XCTAssertFalse(onlyCookies.canImport, "there is nothing to import with nothing selected")
        XCTAssertEqual(ChromeImportSelection(cookies: true, history: false, bookmarks: true).summary, "cookies and bookmarks")
    }

    // MARK: Tabs and pages

    func testTheBrowserDoesNoWorkUntilItIsOpened() throws {
        let created = BrowserActivity.webViewsCreated
        let store = makeStore()
        let browser = store.features.browser
        XCTAssertEqual(browser.pages.count, 0, "no tabs before the browser is first shown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.directory.path), "and nothing on disk")
        browser.prepare()
        XCTAssertEqual(browser.pages.count, 1)
        XCTAssertTrue(try XCTUnwrap(browser.page).isBlank)
        XCTAssertNil(browser.page?.webView, "a blank tab has no web view")
        browser.newTab()
        browser.newTab()
        XCTAssertEqual(browser.pages.count, 3)
        XCTAssertEqual(BrowserActivity.webViewsCreated, created, "blank tabs start no web processes")
        store.shutdown()
    }

    func testOpeningTheBrowserShowsItsSidePanelTab() {
        let store = makeStore()
        XCTAssertFalse(store.showInspector)
        store.openBrowser()
        XCTAssertTrue(store.showInspector)
        XCTAssertEqual(store.sidePanelTab, .browser)
        XCTAssertEqual(store.features.browser.address.focusRequest, 1, "ready for an address")
        XCTAssertTrue(SidePanelTab.allCases.contains(.browser))
        XCTAssertEqual(DesktopCommands.canonical("web"), "browser")
        XCTAssertEqual(DesktopCommands.turnPolicy("browser", arguments: "example.com"), .runNow, "browsing never waits for a turn")
        store.showInspector = false
        XCTAssertTrue(store.handleDesktopCommand("browse", arguments: ""))
        XCTAssertTrue(store.showInspector)
        store.shutdown()
    }

    func testTabsOpenCloseAndComeBackNextLaunch() async throws {
        let stateFile = directory.appendingPathComponent("session/state.json")
        let first = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        first.features.browser.makeDataStore = { .nonPersistent() }
        let page = directory.appendingPathComponent("page.html")
        try Data("<!doctype html><title>Fixture page</title><h1>Hello</h1>".utf8).write(to: page)
        let other = directory.appendingPathComponent("other.html")
        try Data("<!doctype html><title>Other page</title>".utf8).write(to: other)

        let browser = first.features.browser
        browser.open(page.path)
        let tab = try XCTUnwrap(browser.page)
        XCTAssertNotNil(tab.webView)
        try await eventually { tab.title == "Fixture page" && !tab.isLoading }
        XCTAssertEqual(tab.url?.path, page.path)
        XCTAssertEqual(browser.address.text, page.path)
        XCTAssertNil(tab.failure)

        let second = browser.openTab(other)
        XCTAssertEqual(browser.pages.map(\.id), [tab.id, second.id], "a new tab opens beside the one it came from")
        XCTAssertEqual(browser.selectedID, second.id)
        try await eventually { second.title == "Other page" }
        browser.select(tab.id)
        XCTAssertEqual(browser.address.text, page.path)
        browser.newTab()
        XCTAssertEqual(browser.pages.count, 3)
        XCTAssertEqual(browser.address.text, "")
        browser.close(try XCTUnwrap(browser.page))
        XCTAssertEqual(browser.pages.map(\.id), [tab.id, second.id])
        XCTAssertEqual(browser.selectedID, second.id, "closing a tab selects its neighbour")
        browser.select(tab.id)
        first.shutdown()
        XCTAssertNil(tab.webView, "quitting lets go of the web views")

        // The next launch reopens the tabs, and loads one only when it is shown.
        let created = BrowserActivity.webViewsCreated
        let next = AppStore(stateFile: stateFile, binaryPath: "/usr/bin/false")
        next.features.browser.makeDataStore = { .nonPersistent() }
        let restored = next.features.browser
        restored.prepare()
        XCTAssertEqual(restored.pages.map { $0.url?.path }, [page.path, other.path])
        XCTAssertEqual(restored.pages.map(\.title), ["Fixture page", "Other page"])
        XCTAssertEqual(restored.page?.url?.path, page.path)
        XCTAssertEqual(BrowserActivity.webViewsCreated, created, "reopened tabs wait to be shown")
        restored.page?.activate()
        XCTAssertEqual(BrowserActivity.webViewsCreated, created + 1, "only the tab on screen loads")
        try await eventually { restored.page?.isLoading == false && restored.page?.title == "Fixture page" }
        // Closing the last tab leaves a blank one.
        restored.pages.forEach { restored.close($0) }
        XCTAssertEqual(restored.pages.count, 1)
        XCTAssertTrue(try XCTUnwrap(restored.page).isBlank)
        next.shutdown()
    }

    func testVisitedWebPagesAreRememberedAndCanBeBookmarked() async throws {
        let store = makeStore()
        let browser = store.features.browser
        browser.prepare()
        let tab = try XCTUnwrap(browser.page)
        // What a page reports as it loads, without the network.
        browser.visited(URL(string: "https://example.com/guide")!, title: "")
        for _ in 0..<500 where await browser.history.count() == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        browser.titled(URL(string: "https://example.com/guide")!, "The Guide")
        for _ in 0..<500 where await browser.history.recent().first?.title != "The Guide" { try await Task.sleep(nanoseconds: 10_000_000) }
        browser.refreshRecent()
        try await eventually { browser.recent.map(\.title) == ["The Guide"] }

        XCTAssertFalse(browser.isBookmarked(URL(string: "https://example.com/guide")))
        XCTAssertEqual(browser.addBookmarks([BrowserBookmark(title: "Guide", url: "https://example.com/guide"),
                                             BrowserBookmark(title: "Guide again", url: "https://example.com/guide"),
                                             BrowserBookmark(title: "Other", url: "https://example.org/")]), 2)
        XCTAssertTrue(browser.isBookmarked(URL(string: "https://example.com/guide")))
        browser.removeBookmark(browser.bookmarks[0].id)
        XCTAssertEqual(browser.bookmarks.map(\.title), ["Other"])
        browser.toggleBookmark(tab)
        XCTAssertEqual(browser.bookmarks.count, 1, "a blank tab is not a page to bookmark")

        browser.address.begin(showing: nil)
        browser.address.typed("guide")
        try await eventually { browser.address.suggestions.map(\.url) == ["https://example.com/guide"] }
        XCTAssertEqual(browser.address.submission, "guide")
        browser.address.move(1)
        XCTAssertEqual(browser.address.submission, "https://example.com/guide", "Return opens the highlighted suggestion")
        browser.address.move(1)
        XCTAssertEqual(browser.address.submission, "guide", "moving past the list returns to what was typed")
        browser.address.end(showing: nil)
        XCTAssertEqual(browser.address.suggestions, [])
        XCTAssertEqual(browser.address.text, "")

        store.draft = "Summarize"
        store.features.browser.addLinkToPrompt(tab)
        XCTAssertEqual(store.draft, "Summarize", "a blank tab has no link to add")
        browser.clearHistory()
        try await eventually { browser.recent.isEmpty }
        let pages = await browser.history.count()
        XCTAssertEqual(pages, 0)
        store.shutdown()
    }

    func testAPageThatCannotLoadSaysSoAndCanBeRetried() async throws {
        let store = makeStore()
        let browser = store.features.browser
        // A port nothing listens on: one the system just handed out and took back.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(listener, $0, length); _ = getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        close(listener)
        browser.open("127.0.0.1:\(port)")
        let tab = try XCTUnwrap(browser.page)
        try await eventually(timeout: 20) { tab.failure != nil }
        XCTAssertEqual(tab.failure?.title, "This page didn't open")
        XCTAssertEqual(tab.failure?.detail, "Could not connect to the server.")
        XCTAssertEqual(browser.address.text, "http://127.0.0.1:\(port)")
        // WebKit will not load a port reserved for another service, and says nothing; the tab does.
        browser.open("http://127.0.0.1:9/")
        try await eventually(timeout: 20) { tab.failure?.detail.contains("reserved") == true }
        XCTAssertEqual(browser.address.text, "http://127.0.0.1:9")
        let page = directory.appendingPathComponent("ok.html")
        try Data("<!doctype html><title>Recovered</title>".utf8).write(to: page)
        browser.open(page.path)
        try await eventually { tab.title == "Recovered" }
        XCTAssertNil(tab.failure, "a page that loads clears the failure")
        store.shutdown()
    }
}
