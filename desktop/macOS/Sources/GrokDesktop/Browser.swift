import AppKit
import SwiftUI
import WebKit

// The side panel's browser: its tabs, their web views, bookmarks, and the session that reopens
// them. Nothing here runs until the Browser tab is first shown, and a tab makes its web view (and
// WebKit's processes) only when it loads a page.

struct BrowserBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    /// The folders it was filed under where it came from, joined with " / ".
    var folder = ""
}

/// Keys the browser takes while a page has the keyboard, as other browsers do. ⌘W is also the
/// File menu's Close, which closes the tab wherever the keyboard is while the browser shows.
enum BrowserShortcut: Equatable {
    case focusAddress, reload, back, forward, newTab, closeTab, zoomIn, zoomOut, actualSize

    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l" where modifiers == .command: self = .focusAddress
        case "r" where modifiers == .command: self = .reload
        case "[" where modifiers == .command: self = .back
        case "]" where modifiers == .command: self = .forward
        case "t" where modifiers == .command: self = .newTab
        case "w" where modifiers == .command: self = .closeTab
        case "=", "+": self = .zoomIn
        case "-" where modifiers == .command: self = .zoomOut
        case "0" where modifiers == .command: self = .actualSize
        default: return nil
        }
    }
}

final class BrowserWebView: WKWebView {
    /// Returns whether the shortcut was handled.
    var onShortcut: ((BrowserShortcut) -> Bool)?

    /// Key equivalents reach every view in the window, so only a page that has the keyboard takes them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let shortcut = BrowserShortcut(event), let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self),
           onShortcut?(shortcut) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Counts the work the browser does, for the performance tests: a browser nobody opened does none.
@MainActor
enum BrowserActivity {
    private(set) static var webViewsCreated = 0
    private(set) static var hostUpdates = 0

    static func createdWebView() { webViewsCreated += 1 }
    static func updatedHost() { hostUpdates += 1 }
}

// MARK: - Page

/// One tab. The toolbar and the tab strip observe it, so a loading page redraws only them.
@MainActor
final class BrowserPage: NSObject, ObservableObject, Identifiable {
    struct Failure: Equatable {
        var title: String
        var detail: String
    }

    let id = UUID()
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: Failure?
    /// Made when the tab first loads a page.
    @Published private(set) var webView: BrowserWebView?

    /// A page from the last session, loaded when its tab is first shown.
    private var pendingURL: URL?
    /// The page whose title the web view reports.
    private var committedURL: URL?
    private weak var browser: BrowserModel?
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: URL] = [:]

    init(browser: BrowserModel, restoring url: URL? = nil, title: String = "") {
        self.browser = browser
        self.url = url
        self.title = title
        pendingURL = url
        super.init()
    }

    /// What the tab strip shows.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host, !host.isEmpty { return host }
        if let name = url?.lastPathComponent, !name.isEmpty { return name }
        return "New Tab"
    }

    /// The start page shows until the tab has somewhere to go.
    var isBlank: Bool { url == nil && webView == nil }

    func load(_ url: URL) {
        failure = nil
        pendingURL = nil
        self.url = url
        let view = ensureWebView()
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: browser?.readAccessRoot(for: url) ?? url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// Loads the page kept from the last session, the first time its tab is shown.
    func activate() {
        guard let pendingURL, webView == nil else { return }
        load(pendingURL)
    }

    func reload() {
        if let webView, webView.url != nil { failure = nil; webView.reload() } else if let url { load(url) }
    }

    func stop() { webView?.stopLoading() }
    func goBack() { failure = nil; webView?.goBack() }
    func goForward() { failure = nil; webView?.goForward() }

    func zoom(_ shortcut: BrowserShortcut) {
        guard let webView else { return }
        switch shortcut {
        case .zoomIn: webView.pageZoom = min(3, webView.pageZoom + 0.1)
        case .zoomOut: webView.pageZoom = max(0.5, webView.pageZoom - 0.1)
        default: webView.pageZoom = 1
        }
    }

    /// Stops the page and lets go of its web view, which ends its web process.
    func dispose() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onShortcut = nil
            webView.removeFromSuperview()
        }
        webView = nil
    }

    /// The tab's web view: its own, or one WebKit asks for when a page opens a window.
    @discardableResult
    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> BrowserWebView {
        if let webView { return webView }
        let view = BrowserWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration ?? browser?.makeConfiguration() ?? WKWebViewConfiguration())
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        // Web Inspector from the page's context menu, for the pages a project serves.
        view.isInspectable = true
        view.onShortcut = { [weak self] shortcut in
            guard let self, let browser = self.browser else { return false }
            return browser.perform(shortcut, on: self)
        }
        observations = [
            view.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.urlChanged(view.url) } },
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.titleChanged(view.title ?? "", at: view.url) } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loadingChanged(view.isLoading) } },
            view.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progressChanged(view.estimatedProgress) } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { if self?.canGoBack != view.canGoBack { self?.canGoBack = view.canGoBack } } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { if self?.canGoForward != view.canGoForward { self?.canGoForward = view.canGoForward } } },
        ]
        BrowserActivity.createdWebView()
        webView = view
        return view
    }

    private func urlChanged(_ new: URL?) {
        guard let new, new.absoluteString != "about:blank", url != new else { return }
        url = new
        browser?.pageChanged(self)
    }

    private func titleChanged(_ new: String, at url: URL?) {
        // While a page is on its way, the web view still reports the title of the page it is leaving.
        guard url == committedURL else { return }
        if title != new { title = new }
        if let url, !new.isEmpty { browser?.titled(url, new) }
    }

    private func loadingChanged(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if !loading { progress = 0 }
    }

    /// WebKit reports progress far more often than a bar two points tall can show.
    private func progressChanged(_ value: Double) {
        guard abs(value - progress) >= 0.03 || value >= 1 else { return }
        progress = value
    }

    private func fail(_ error: Error) {
        let error = error as NSError
        // A navigation the user or a newer one stopped, and a load that became a download.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code) { return }
        if let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { url = failing; browser?.pageChanged(self) }
        failure = Failure(title: "This page didn't open", detail: error.localizedDescription)
    }
}

extension BrowserPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        guard BrowserAddress.loadableSchemes.contains(url.scheme?.lowercased() ?? "") else {
            // mailto:, tel:, and other apps' links go to the system, but only when the user clicked one.
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            browser?.openTab(url, select: navigationAction.modifierFlags.contains(.shift))
            return .cancel
        }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedURL = webView.url
        title = webView.title ?? ""
        // WebKit answers an address it will not load (a port reserved for mail, say) with an empty page and no error.
        if webView.url?.absoluteString == "about:blank", let asked = url, asked.absoluteString != "about:blank" {
            failure = Failure(title: "This page didn't open", detail: "The browser does not load this address: its port is reserved for another kind of service.")
            return
        }
        failure = nil
        if let url = webView.url { browser?.visited(url, title: title) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        titleChanged(webView.title ?? "", at: webView.url)
        browser?.sessionChanged()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = Failure(title: "This page stopped", detail: "Its web process quit. Reload to open the page again.")
    }
}

extension BrowserPage: WKUIDelegate {
    /// `window.open` and links that ask for a new window open a tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        browser?.openTab(configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) { browser?.close(self) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await BrowserDialog.run(message: message, from: frame, in: webView, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await BrowserDialog.run(message: message, from: frame, in: webView, buttons: ["OK", "Cancel"]).confirmed
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await BrowserDialog.run(message: prompt, from: frame, in: webView, buttons: ["OK", "Cancel"], input: defaultText ?? "")
        return answer.confirmed ? answer.text : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = webView.window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    /// The browser is for reading and previewing; pages do not get the camera or the microphone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

extension BrowserPage: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destination = BrowserDownloads.destination(for: suggestedFilename)
        downloads[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        browser?.downloaded(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let file = downloads.removeValue(forKey: ObjectIdentifier(download))
        browser?.downloadFailed(file, error: error)
    }
}

/// Where downloads go: the Downloads folder, under a name that replaces nothing.
enum BrowserDownloads {
    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func destination(for suggested: String, in folder: URL = folder) -> URL {
        // A name from a server is only ever a name: no folders, and not hidden.
        var name = (suggested as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var count = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            count += 1
            candidate = folder.appendingPathComponent(suffix.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(suffix)")
        }
        return candidate
    }
}

/// A page's `alert`, `confirm`, or `prompt`, as a sheet on the window. A page in a tab that is not
/// on screen gets no answer rather than a dialog from nowhere.
@MainActor
enum BrowserDialog {
    struct Answer {
        var confirmed = false
        var text = ""
    }

    static func run(message: String, from frame: WKFrameInfo, in webView: WKWebView, buttons: [String], input: String? = nil) async -> Answer {
        guard let window = webView.window else { return Answer() }
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = String(message.prefix(2_000))
        buttons.forEach { alert.addButton(withTitle: $0) }
        var field: NSTextField?
        if let input {
            let text = NSTextField(string: input)
            text.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = text
            alert.window.initialFirstResponder = text
            field = text
        }
        let response = await alert.beginSheetModal(for: window)
        return Answer(confirmed: response == .alertFirstButtonReturn, text: field?.stringValue ?? "")
    }
}

// MARK: - Address bar

/// What is being typed in the address bar. Its own object, so typing redraws the bar and its
/// suggestions, not the page.
@MainActor
final class BrowserAddressModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var isEditing = false
    @Published private(set) var suggestions: [BrowserHistoryItem] = []
    @Published private(set) var highlighted: Int?
    /// Bumped to move the keyboard into the address bar.
    @Published private(set) var focusRequest = 0

    private let history: BrowserHistoryStore
    private var lookup: Task<Void, Never>?

    init(history: BrowserHistoryStore) { self.history = history }

    func requestFocus() { focusRequest += 1 }

    /// The address bar took the keyboard: it shows the whole address, ready to be replaced.
    func begin(showing url: URL?) {
        isEditing = true
        text = url?.absoluteString ?? ""
    }

    func end(showing url: URL?) {
        isEditing = false
        lookup?.cancel()
        suggestions = []
        highlighted = nil
        text = BrowserAddress.display(url)
    }

    /// The page moved on while the bar was not being edited.
    func show(_ url: URL?) {
        guard !isEditing else { return }
        let display = BrowserAddress.display(url)
        if text != display { text = display }
    }

    func typed(_ new: String) {
        text = new
        highlighted = nil
        lookup?.cancel()
        let query = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditing, !query.isEmpty else { suggestions = []; return }
        lookup = Task { [history] in
            let found = await history.suggestions(for: query)
            guard !Task.isCancelled, self.isEditing else { return }
            self.suggestions = found
        }
    }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (highlighted ?? (delta > 0 ? -1 : suggestions.count)) + delta
        highlighted = next < 0 || next >= suggestions.count ? nil : next
    }

    /// What Return opens: the highlighted suggestion, or what was typed.
    var submission: String { highlighted.flatMap { suggestions.indices.contains($0) ? suggestions[$0].url : nil } ?? text }
}

// MARK: - Browser

@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var pages: [BrowserPage] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    /// The pages visited last, for the start page.
    @Published private(set) var recent: [BrowserHistoryItem] = []
    /// Bumped to move the keyboard into the page.
    @Published private(set) var pageFocusRequest = 0

    let history: BrowserHistoryStore
    let address: BrowserAddressModel
    /// `browser/` beside the desktop state file: history, bookmarks, and the open tabs.
    let directory: URL
    /// Tests give the browser a store that leaves nothing on disk.
    var makeDataStore: () -> WKWebsiteDataStore = BrowserModel.defaultDataStore
    private(set) lazy var dataStore: WKWebsiteDataStore = makeDataStore()

    private weak var store: AppStore?
    private var isPrepared = false
    private var sessionSave: Task<Void, Never>?

    static let dataStoreIdentifier = UUID(uuidString: "6B1F2C9E-52D7-4C0B-9B0E-5C2A0D7B3E41")!
    /// Recent pages on the start page.
    static let recentLimit = 12

    init(store: AppStore, directory: URL) {
        self.store = store
        self.directory = directory
        history = BrowserHistoryStore(file: directory.appendingPathComponent("history.sqlite"))
        address = BrowserAddressModel(history: history)
    }

    /// The browser's own cookies and site data, kept between launches. Runs that name their own
    /// state file (the performance harness) and unit tests get a store that leaves nothing behind.
    static func defaultDataStore() -> WKWebsiteDataStore {
        if ProcessInfo.processInfo.environment["CROK_DESKTOP_STATE_FILE"] != nil || NSClassFromString("XCTestCase") != nil { return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Sites decide what to serve from this: without a Safari version, many serve a fallback page.
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    var page: BrowserPage? { pages.first { $0.id == selectedID } }

    // MARK: Session

    private struct Session: Codable {
        struct Tab: Codable {
            var url: String?
            var title: String
        }
        var tabs: [Tab]
        var selected: Int
    }

    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private var bookmarksFile: URL { directory.appendingPathComponent("bookmarks.json") }

    /// Reopens the last session's tabs (without loading them) and reads the bookmarks, the first
    /// time the browser is shown or used.
    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        if let data = try? Data(contentsOf: bookmarksFile), let saved = try? JSONDecoder().decode([BrowserBookmark].self, from: data) { bookmarks = saved }
        if let data = try? Data(contentsOf: sessionFile), let session = try? JSONDecoder().decode(Session.self, from: data), !session.tabs.isEmpty {
            pages = session.tabs.map { BrowserPage(browser: self, restoring: $0.url.flatMap(URL.init(string:)), title: $0.title) }
            selectedID = pages[min(max(session.selected, 0), pages.count - 1)].id
        } else {
            let page = BrowserPage(browser: self)
            pages = [page]
            selectedID = page.id
        }
        address.show(page?.url)
        refreshRecent()
    }

    /// The open tabs changed; they are written once the changes settle.
    func sessionChanged() {
        guard isPrepared else { return }
        sessionSave?.cancel()
        sessionSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    private func saveSession() {
        guard isPrepared else { return }
        sessionSave?.cancel()
        sessionSave = nil
        let session = Session(tabs: pages.map { Session.Tab(url: $0.url?.absoluteString, title: $0.title) },
                              selected: pages.firstIndex { $0.id == selectedID } ?? 0)
        guard let data = try? JSONEncoder().encode(session) else { return }
        let file = sessionFile
        Task.detached(priority: .utility) { BrowserModel.write(data, to: file) }
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        let file = bookmarksFile
        Task.detached(priority: .utility) { BrowserModel.write(data, to: file) }
    }

    private nonisolated static func write(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Before the app quits: the open tabs are written now, and the web views are let go.
    func shutdown() {
        guard isPrepared else { return }
        sessionSave?.cancel()
        let session = Session(tabs: pages.map { Session.Tab(url: $0.url?.absoluteString, title: $0.title) },
                              selected: pages.firstIndex { $0.id == selectedID } ?? 0)
        if let data = try? JSONEncoder().encode(session) { Self.write(data, to: sessionFile) }
        pages.forEach { $0.dispose() }
    }

    // MARK: Tabs

    func select(_ id: UUID) {
        guard selectedID != id, pages.contains(where: { $0.id == id }) else { return }
        selectedID = id
        address.end(showing: page?.url)
        page?.activate()
        sessionChanged()
    }

    /// A blank tab, with the keyboard in the address bar.
    @discardableResult
    func newTab() -> BrowserPage {
        prepare()
        let page = BrowserPage(browser: self)
        insert(page, select: true)
        address.requestFocus()
        return page
    }

    /// A tab for a link opened from a page.
    @discardableResult
    func openTab(_ url: URL, select: Bool = true) -> BrowserPage {
        prepare()
        let page = BrowserPage(browser: self)
        insert(page, select: select)
        page.load(url)
        return page
    }

    /// A tab for a window a page opened, around the web view WebKit configured for it.
    func openTab(configuration: WKWebViewConfiguration) -> BrowserPage {
        prepare()
        let page = BrowserPage(browser: self)
        page.ensureWebView(configuration: configuration)
        insert(page, select: true)
        return page
    }

    private func insert(_ page: BrowserPage, select: Bool) {
        let index = pages.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? pages.count
        pages.insert(page, at: index)
        if select || selectedID == nil {
            selectedID = page.id
            address.end(showing: page.url)
        }
        sessionChanged()
    }

    /// Whether there is a tab to close: a start page on its own is what closing the last tab leaves.
    var canCloseTab: Bool { pages.count > 1 || page?.isBlank == false }

    /// Closes the selected tab. Returns whether there was one to close.
    @discardableResult
    func closeTab() -> Bool {
        guard let page, canCloseTab else { return false }
        close(page)
        return true
    }

    func close(_ page: BrowserPage) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        // The start page on its own stays as it is, rather than being replaced by another.
        if pages.count == 1, page.isBlank { return }
        page.dispose()
        pages.remove(at: index)
        if pages.isEmpty { pages = [BrowserPage(browser: self)] }
        if selectedID == page.id {
            selectedID = pages[min(index, pages.count - 1)].id
            address.end(showing: self.page?.url)
            self.page?.activate()
        }
        sessionChanged()
    }

    // MARK: Navigation

    /// Loads an address or a search in the selected tab.
    func open(_ input: String) {
        prepare()
        guard let url = BrowserAddress.resolve(input, searchEngine: BrowserAddress.searchEngine()) else { return }
        open(url)
    }

    func open(_ url: URL) {
        prepare()
        guard let page else { return }
        page.load(url)
        address.end(showing: url)
        sessionChanged()
    }

    func submitAddress() {
        let input = address.submission
        guard BrowserAddress.resolve(input, searchEngine: BrowserAddress.searchEngine()) != nil else { return }
        open(input)
        pageFocusRequest += 1
    }

    /// Escape in the address bar: back to the page's address, and to the page.
    func cancelAddress() {
        address.end(showing: page?.url)
        pageFocusRequest += 1
    }

    func focusAddress() {
        prepare()
        address.requestFocus()
    }

    // MARK: Menu actions

    func showChromeImport() { store?.sheet = .importChrome }

    /// Puts the page's address in the prompt, for Crok to read or act on.
    func addLinkToPrompt(_ page: BrowserPage) {
        guard let store, let link = page.url?.absoluteString else { return }
        let draft = store.draft
        store.draft = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + link : draft + " " + link
        NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
    }

    func copyLink(_ page: BrowserPage) {
        guard let link = page.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func openInDefaultBrowser(_ page: BrowserPage) {
        if let url = page.url { NSWorkspace.shared.open(url) }
    }

    /// Asks first: signing in again everywhere is not something to do by accident.
    func confirmClearBrowsingData() {
        let alert = NSAlert()
        alert.messageText = "Clear the browser's data?"
        alert.informativeText = "This removes its cookies, sign-ins, caches, and history. Bookmarks are kept. Chrome is not affected."
        alert.addButton(withTitle: "Clear"); alert.addButton(withTitle: "Cancel")
        let clear = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.clearBrowsingData() }
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: clear) } else { clear(alert.runModal()) }
    }

    func perform(_ shortcut: BrowserShortcut, on page: BrowserPage) -> Bool {
        switch shortcut {
        case .focusAddress: address.requestFocus()
        case .reload: page.reload()
        case .back: page.goBack()
        case .forward: page.goForward()
        case .newTab: newTab()
        case .closeTab: close(page)
        case .zoomIn, .zoomOut, .actualSize: page.zoom(shortcut)
        }
        return true
    }

    /// A local page may read the files beside it: the project's, when it is inside the project.
    func readAccessRoot(for file: URL) -> URL {
        if let root = store?.project?.path, file.path.hasPrefix(root + "/") { return URL(fileURLWithPath: root, isDirectory: true) }
        return file.deletingLastPathComponent()
    }

    // MARK: Pages report

    func pageChanged(_ page: BrowserPage) {
        if page.id == selectedID { address.show(page.url) }
    }

    func visited(_ url: URL, title: String) {
        let address = url.absoluteString
        Task { [history] in await history.record(url: address, title: title) }
    }

    func titled(_ url: URL, _ title: String) {
        let address = url.absoluteString
        Task { [history] in await history.setTitle(title, for: address) }
    }

    func refreshRecent() {
        Task { [history] in
            let items = await history.recent(limit: Self.recentLimit)
            if self.recent != items { self.recent = items }
        }
    }

    func downloaded(_ file: URL) {
        store?.banner = "Downloaded \(file.lastPathComponent) to your Downloads folder."
    }

    func downloadFailed(_ file: URL?, error: Error) {
        store?.banner = "Could not download \(file?.lastPathComponent ?? "the file"): \(error.localizedDescription)"
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        guard let address = url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == address }
    }

    func toggleBookmark(_ page: BrowserPage) {
        guard let url = page.url, ChromeData.isWebAddress(url.absoluteString) else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(BrowserBookmark(title: page.title.isEmpty ? BrowserAddress.display(url) : page.title, url: url.absoluteString), at: 0)
        }
        saveBookmarks()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    /// Adds bookmarks from elsewhere, skipping pages already bookmarked. Returns how many were new.
    @discardableResult
    func addBookmarks(_ imported: [BrowserBookmark]) -> Int {
        var known = Set(bookmarks.map(\.url))
        let new = imported.filter { known.insert($0.url).inserted }
        guard !new.isEmpty else { return 0 }
        bookmarks.append(contentsOf: new)
        saveBookmarks()
        return new.count
    }

    // MARK: Clearing

    func clearHistory() {
        Task { [history] in
            await history.clear()
            self.recent = []
        }
    }

    /// Cookies, caches, and everything else sites stored, and the history with them.
    func clearBrowsingData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await history.clear()
        recent = []
        store?.banner = "Cleared the browser's cookies, site data, and history."
    }
}
