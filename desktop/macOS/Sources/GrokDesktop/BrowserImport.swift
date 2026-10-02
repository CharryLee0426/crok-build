import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

// Bringing a Chrome profile's sign-ins, history, and bookmarks into the browser. Nothing of
// Chrome's is read until macOS has confirmed the person at the Mac is its owner (Touch ID or the
// login password); the cookies also need Chrome's encryption key, which the keychain releases
// only with the login keychain password. ChromeImport.swift does the reading.

/// What stands between this app and Chrome's data. Tests replace all of it.
struct ChromeImportAccess {
    /// Where Chrome keeps its profiles.
    var root: URL = ChromeData.defaultRoot
    /// Confirms the owner is present; throws when they cancel or cannot be confirmed.
    var authenticate: (_ reason: String) async throws -> Void = ChromeImportAccess.authenticateOwner
    /// Chrome's cookie encryption password. Called off the main thread: the keychain's prompt blocks it.
    var cookiePassword: () throws -> String = ChromeSafeStorage.password

    static let system = ChromeImportAccess()

    /// Touch ID, Apple Watch, or the login password, whichever this Mac offers.
    static func authenticateOwner(reason: String) async throws {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            throw ChromeImportError.notAuthenticated(unavailable?.localizedDescription ?? "This Mac cannot confirm who is using it.")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            throw ChromeImportError.authenticationCancelled
        } catch {
            throw ChromeImportError.notAuthenticated(error.localizedDescription)
        }
    }
}

struct ChromeImportSelection: Equatable {
    var cookies = true
    var history = true
    var bookmarks = true

    var isEmpty: Bool { !cookies && !history && !bookmarks }

    /// "cookies, history, and bookmarks", for the authentication prompt.
    var summary: String {
        let parts = [cookies ? "cookies" : nil, history ? "history" : nil, bookmarks ? "bookmarks" : nil].compactMap { $0 }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

/// What a profile held, read off the main thread. A part that could not be read is nil, with the reason in `problems`.
struct ChromeImportPayload {
    var cookies: ChromeData.CookieResult?
    var history: [ChromeHistoryEntry]?
    var bookmarks: [ChromeBookmark]?
    var problems: [String] = []
}

struct ChromeImportResult: Equatable {
    /// Nil for a part that was not selected or could not be read.
    var cookies: Int?
    var history: Int?
    var bookmarks: Int?
    var problems: [String] = []

    var importedAnything: Bool { cookies != nil || history != nil || bookmarks != nil }
}

enum ChromeImporter {
    /// Reads the selected parts of a profile. One part failing leaves the others.
    static func read(profile: URL, selection: ChromeImportSelection, access: ChromeImportAccess) -> ChromeImportPayload {
        var payload = ChromeImportPayload()
        if selection.history {
            do { payload.history = try ChromeData.history(in: profile) } catch { payload.problems.append("History: \(error.localizedDescription)") }
        }
        if selection.bookmarks {
            do { payload.bookmarks = try ChromeData.bookmarks(in: profile) } catch { payload.problems.append("Bookmarks: \(error.localizedDescription)") }
        }
        if selection.cookies {
            do {
                let cipher = ChromeCookieCipher(password: try access.cookiePassword())
                let result = try ChromeData.cookies(in: profile, cipher: cipher)
                payload.cookies = result
                if result.undecryptable > 0 {
                    payload.problems.append(result.undecryptable == 1 ? "1 cookie could not be decrypted and was left out."
                        : "\(result.undecryptable.formatted()) cookies could not be decrypted and were left out.")
                }
            } catch {
                payload.problems.append("Cookies: \(error.localizedDescription)")
            }
        }
        return payload
    }

    /// Cookies handed to WebKit at once; each is a message to its network process.
    static let cookieBatch = 250

    /// Puts cookies in the browser's store, reporting how many are in so far.
    @MainActor
    static func apply(_ cookies: [ChromeCookie], to store: WKHTTPCookieStore, progress: (Int) -> Void = { _ in }) async -> Int {
        let prepared = cookies.compactMap(\.httpCookie)
        var done = 0
        while done < prepared.count {
            let batch = prepared[done..<min(done + cookieBatch, prepared.count)]
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for cookie in batch {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) { continuation.resume() }
            }
            done += batch.count
            progress(done)
        }
        return prepared.count
    }
}

extension BrowserModel {
    /// Applies what was read from Chrome: sign-ins to the web store, pages to the history, bookmarks to the list.
    func apply(_ payload: ChromeImportPayload, progress: (Int) -> Void = { _ in }) async -> ChromeImportResult {
        prepare()
        var result = ChromeImportResult(problems: payload.problems)
        if let entries = payload.history {
            let items = entries.map { BrowserHistoryItem(url: $0.url, title: $0.title, visitCount: $0.visitCount, lastVisit: $0.lastVisit) }
            do {
                result.history = try await history.merge(items)
            } catch {
                result.problems.append("History: \(error.localizedDescription)")
            }
            refreshRecent()
        }
        if let imported = payload.bookmarks {
            result.bookmarks = addBookmarks(imported.map { BrowserBookmark(title: $0.title, url: $0.url, folder: $0.folder) })
        }
        if let cookies = payload.cookies {
            result.cookies = await ChromeImporter.apply(cookies.cookies, to: dataStore.httpCookieStore, progress: progress)
        }
        return result
    }
}

// MARK: - Sheet

@MainActor
final class ChromeImportModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case authenticating
        case reading
        /// Cookies stored so far, of how many.
        case applying(Int, Int)
        case finished(ChromeImportResult)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .authenticating, .reading, .applying: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var profiles: [ChromeProfile] = []
    @Published var profileID = ""
    @Published var selection = ChromeImportSelection()

    private let access: ChromeImportAccess

    init(access: ChromeImportAccess = .system) { self.access = access }

    /// A sheet in a known state, for snapshots.
    init(profiles: [ChromeProfile], phase: Phase) {
        access = .system
        self.profiles = profiles
        profileID = profiles.first?.id ?? ""
        self.phase = phase
    }

    var profile: ChromeProfile? { profiles.first { $0.id == profileID } }
    var canImport: Bool { phase == .ready && profile != nil && !selection.isEmpty }

    /// Lists Chrome's profiles: names only, from the file Chrome keeps them in.
    func load() async {
        guard phase == .loading else { return }
        let root = access.root
        let found = await Task.detached(priority: .userInitiated) { ChromeData.profiles(in: root) }.value
        profiles = found
        profileID = found.first?.id ?? ""
        phase = .ready
    }

    func run(browser: BrowserModel) async {
        guard canImport, let profile else { return }
        let selection = selection, access = access
        phase = .authenticating
        do {
            try await access.authenticate("import your Chrome \(selection.summary)")
        } catch ChromeImportError.authenticationCancelled {
            phase = .ready
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .reading
        let directory = profile.directory
        let payload = await Task.detached(priority: .userInitiated) { ChromeImporter.read(profile: directory, selection: selection, access: access) }.value
        let total = payload.cookies?.cookies.count ?? 0
        if total > 0 { phase = .applying(0, total) }
        let result = await browser.apply(payload) { [weak self] done in self?.phase = .applying(done, total) }
        phase = result.importedAnything ? .finished(result) : .failed(result.problems.joined(separator: "\n"))
    }

    /// Back to the options, after a result or a failure.
    func reset() { phase = .ready }
}

/// Import from Chrome: which profile, what to bring, and how it went.
struct ImportChromeSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var browser: BrowserModel
    @StateObject private var model: ChromeImportModel

    init() { _model = StateObject(wrappedValue: ChromeImportModel()) }

    /// A sheet around a prepared model (snapshots and tests).
    init(model: ChromeImportModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        DesktopPanel(title: "Import from Chrome",
                     subtitle: "Bring your Chrome sign-ins, history, and bookmarks into Crok's browser. Chrome and its data are left as they are.",
                     width: 580, onClose: close) {
            content.padding(24)
        } footer: {
            footer
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            status(working: true, "Looking for Chrome profiles…")
        case .finished(let result):
            finished(result)
        default:
            if model.profiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
                    Text("No Chrome profiles").font(.system(size: 14, weight: .medium))
                    Text("Google Chrome has not been used on this Mac, so there is nothing to import.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                options
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Chrome profile", detail: model.profile?.account ?? "Not signed in to a Google account") {
                Picker("Chrome profile", selection: $model.profileID) {
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Divider()
            row("Cookies and sign-ins", detail: "Stay signed in to the sites you use in Chrome. macOS asks for your login keychain password to release Chrome's encryption key.") {
                Toggle("Cookies and sign-ins", isOn: $model.selection.cookies).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            row("History", detail: "The pages you visited, for suggestions in the address bar.") {
                Toggle("History", isOn: $model.selection.history).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            row("Bookmarks", detail: "Listed on new tabs and in the browser's menu.") {
                Toggle("Bookmarks", isOn: $model.selection.bookmarks).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            switch model.phase {
            case .authenticating: Divider(); status(working: true, "Waiting for you to confirm it's you…")
            case .reading: Divider(); status(working: true, "Reading Chrome's data… Allow the keychain request if macOS shows one.")
            case .applying(let done, let total):
                Divider()
                status(working: true, "Storing cookies… \(done.formatted()) of \(total.formatted())")
            case .failed(let message):
                Divider()
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
                    Text(message).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            default: EmptyView()
            }
        }
        .disabled(model.phase.isWorking)
    }

    private func finished(_ result: ChromeImportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Imported from \(model.profile?.name ?? "Chrome")", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 6) {
                if let cookies = result.cookies { count(cookies, "cookie", symbol: "key") }
                if let history = result.history { count(history, "visited page", symbol: "clock") }
                if let bookmarks = result.bookmarks { count(bookmarks, "new bookmark", symbol: "star") }
            }
            ForEach(result.problems, id: \.self) { problem in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ComposerPalette.warning)
                    Text(problem).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if result.cookies ?? 0 > 0 {
                Text("Reload pages that are already open to use the imported sign-ins. A few sites tie a sign-in to the browser it was made in and will ask you to sign in again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func count(_ value: Int, _ noun: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 18)
            Text("\(value.formatted()) \(value == 1 ? noun : noun + "s")").font(.system(size: 13)).monospacedDigit()
        }
    }

    private func status(working: Bool, _ text: String) -> some View {
        HStack(spacing: 9) {
            if working { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder private var footer: some View {
        Image(systemName: "touchid").foregroundStyle(Theme.muted).accessibilityHidden(true)
        Text("macOS confirms it's you before anything is read.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        Spacer()
        switch model.phase {
        case .finished:
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close", action: close)
            Button("Try Again") { model.reset() }.keyboardShortcut(.defaultAction)
        default:
            Button("Cancel", action: close).disabled(model.phase.isWorking)
            Button {
                Task { await model.run(browser: browser) }
            } label: {
                HStack(spacing: 7) {
                    if model.phase.isWorking { ProgressView().controlSize(.mini) }
                    Text("Import")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canImport)
        }
    }

    private func close() {
        guard !model.phase.isWorking else { return }
        store.sheet = nil
    }
}

/// The browser's preferences in Settings.
struct BrowserSettingsSection: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var browser: BrowserModel
    @AppStorage(BrowserAddress.searchEngineKey) private var searchEngine = BrowserAddress.SearchEngine.google.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Browser", systemImage: "globe").font(.system(size: 15, weight: .semibold))
            row("Search engine", detail: "Used when what you type in the address bar is not an address.") {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(BrowserAddress.SearchEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Divider()
            row("Chrome", detail: "Bring your sign-ins, history, and bookmarks from Google Chrome. macOS confirms it's you first.") {
                Button("Import…") {
                    store.showSettings = false
                    // After the Settings sheet has gone: a window shows one sheet at a time.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.sheet = .importChrome }
                }
                .buttonStyle(.bordered).accessibilityLabel("Import from Chrome")
            }
            Divider()
            row("Browsing data", detail: "Cookies, sign-ins, caches, and history that the browser keeps on this Mac.") {
                Button("Clear…") { browser.confirmClearBrowsingData() }.buttonStyle(.bordered).accessibilityLabel("Clear browsing data")
            }
        }
        .settingsCard()
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
