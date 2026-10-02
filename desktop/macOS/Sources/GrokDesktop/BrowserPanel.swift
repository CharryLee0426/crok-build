import AppKit
import SwiftUI
import WebKit

/// The side panel's Browser tab: a toolbar, the open tabs, and the page.
///
/// None of these views observe the store, so a streaming task redraws nothing here; the toolbar
/// and the tab strip observe their page, and the address bar its own model.
struct BrowserPanelView: View {
    @EnvironmentObject var browser: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if let page = browser.page {
                BrowserToolbar(page: page, address: browser.address)
                if browser.pages.count > 1 { BrowserTabStrip() }
                Divider().overlay(Theme.line.opacity(0.4))
                BrowserContent(page: page)
                    .id(page.id)
                    .overlay(alignment: .top) { BrowserSuggestions(address: browser.address) }
            } else {
                Color.clear
            }
        }
        .onAppear { browser.prepare() }
        .task(id: browser.selectedID) { browser.page?.activate() }
    }
}

// MARK: - Toolbar

private struct BrowserToolbar: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var page: BrowserPage
    let address: BrowserAddressModel

    var body: some View {
        HStack(spacing: 4) {
            IconButton(icon: "chevron.left", help: "Back · ⌘[", size: 26) { page.goBack() }
                .disabled(!page.canGoBack).opacity(page.canGoBack ? 1 : 0.4)
            IconButton(icon: "chevron.right", help: "Forward · ⌘]", size: 26) { page.goForward() }
                .disabled(!page.canGoForward).opacity(page.canGoForward ? 1 : 0.4)
            IconButton(icon: page.isLoading ? "xmark" : "arrow.clockwise", help: page.isLoading ? "Stop loading" : "Reload · ⌘R", size: 26) {
                if page.isLoading { page.stop() } else { page.reload() }
            }
            .disabled(page.isBlank).opacity(page.isBlank ? 0.4 : 1)
            BrowserAddressBar(address: address, page: page).padding(.horizontal, 2)
            IconButton(icon: "plus", help: "New tab · ⌘T", size: 26) { browser.newTab() }
            BrowserMenu(page: page)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            // How far along the page is, on the toolbar's lower edge.
            GeometryReader { geometry in
                Rectangle().fill(Theme.accent)
                    .frame(width: geometry.size.width * (page.isLoading ? max(0.08, page.progress) : 0), height: 2)
                    .animation(.easeOut(duration: 0.2), value: page.progress)
            }
            .frame(height: 2).opacity(page.isLoading ? 1 : 0).accessibilityHidden(true)
        }
    }
}

private struct BrowserAddressBar: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var address: BrowserAddressModel
    @ObservedObject var page: BrowserPage

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                .frame(width: 14).help(security).accessibilityHidden(true)
            BrowserAddressInput(text: Binding(get: { address.text }, set: { address.typed($0) }), focusRequest: address.focusRequest,
                                onFocus: { address.begin(showing: page.url) }, onBlur: { address.end(showing: browser.page?.url) },
                                onSubmit: { browser.submitAddress() }, onEscape: { browser.cancelAddress() }, onMove: { address.move($0) })
                .frame(height: 18)
            if !address.isEditing, let url = page.url, ChromeData.isWebAddress(url.absoluteString) {
                let bookmarked = browser.isBookmarked(url)
                Button { browser.toggleBookmark(page) } label: {
                    Image(systemName: bookmarked ? "star.fill" : "star").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(bookmarked ? Theme.accent : Theme.muted).frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(bookmarked ? "Remove bookmark" : "Bookmark this page")
                .accessibilityLabel(bookmarked ? "Remove bookmark" : "Bookmark this page")
            }
        }
        .padding(.leading, 10).padding(.trailing, 7).frame(height: 30)
        .modifier(InputSurface(focused: address.isEditing))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { address.requestFocus() }
    }

    private var symbol: String {
        if address.isEditing || page.isBlank { return "magnifyingglass" }
        switch page.url?.scheme {
        case "https": return "lock.fill"
        case "file": return "doc"
        default: return page.url?.host.map(BrowserAddress.isLocal) == true ? "desktopcomputer" : "lock.open"
        }
    }

    private var security: String {
        if address.isEditing || page.isBlank { return "Search or enter an address" }
        switch page.url?.scheme {
        case "https": return "The connection to this site is encrypted."
        case "file": return "A file on this Mac."
        default: return page.url?.host.map(BrowserAddress.isLocal) == true ? "A page served from this Mac or your network." : "The connection to this site is not encrypted."
        }
    }
}

/// AppKit's text field, for the same reasons as `NativeSearchField`: explicit focus, and input
/// methods that compose before they commit.
private struct BrowserAddressInput: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var onFocus: () -> Void
    var onBlur: () -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onMove: (Int) -> Void

    func makeNSView(context: Context) -> AddressField {
        let field = AddressField()
        field.delegate = context.coordinator
        field.placeholderString = "Search or enter address"
        field.font = .systemFont(ofSize: 12.5)
        field.focusRingType = .none
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Address and search")
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focused() }
        // Requests made before the bar existed are not for it.
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: AddressField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isShowingText = true
        field.showText(text)
        coordinator.isShowingText = false
        if coordinator.selectsAll {
            coordinator.selectsAll = false
            field.currentEditor()?.selectAll(nil)
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BrowserAddressInput
        var focusRequest = 0
        var isShowingText = false
        /// Set as the bar takes the keyboard: the whole address is selected once it is shown.
        var selectsAll = false

        init(_ parent: BrowserAddressInput) { self.parent = parent }

        func focused() {
            selectsAll = true
            parent.onFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isShowingText, let field = notification.object as? NSTextField else { return }
            parent.text = (field.currentEditor() as? NSTextView)?.committedString ?? field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            selectsAll = false
            parent.onBlur()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                control.window?.makeFirstResponder(nil)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                control.window?.makeFirstResponder(nil)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            default: return false
            }
            return true
        }
    }

    final class AddressField: NSTextField {
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            // After the click that brought the keyboard here has finished placing the insertion point.
            if accepted { DispatchQueue.main.async { [weak self] in self?.onFocus?(); self?.currentEditor()?.selectAll(nil) } }
            return accepted
        }
    }
}

private struct BrowserMenu: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var page: BrowserPage

    var body: some View {
        Menu {
            Button("New Tab", systemImage: "plus") { browser.newTab() }
            if page.url != nil {
                Divider()
                Button("Add Link to Prompt", systemImage: "text.insert") { browser.addLinkToPrompt(page) }
                Button("Copy Link", systemImage: "doc.on.doc") { browser.copyLink(page) }
                Button("Open in Default Browser", systemImage: "arrow.up.forward.app") { browser.openInDefaultBrowser(page) }
            }
            if page.webView != nil {
                Divider()
                Button("Zoom In", systemImage: "plus.magnifyingglass") { page.zoom(.zoomIn) }
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { page.zoom(.zoomOut) }
                Button("Actual Size") { page.zoom(.actualSize) }
            }
            if !browser.bookmarks.isEmpty {
                Divider()
                Menu("Bookmarks") {
                    ForEach(browser.bookmarks.prefix(BrowserMenu.bookmarkLimit)) { bookmark in
                        Button(bookmark.title.isEmpty ? bookmark.url : bookmark.title) { browser.open(bookmark.url) }
                    }
                    if browser.bookmarks.count > BrowserMenu.bookmarkLimit {
                        Divider()
                        Button("All \(browser.bookmarks.count.formatted()) Bookmarks…") { browser.newTab() }
                    }
                }
            }
            Divider()
            Button("Import from Chrome…", systemImage: "square.and.arrow.down") { browser.showChromeImport() }
            Button("Clear History") { browser.clearHistory() }
            Button("Clear Browsing Data…") { browser.confirmClearBrowsingData() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Theme.muted)
        .help("Bookmarks, import, and more").accessibilityLabel("Browser menu")
    }

    /// A menu is for a handful; the start page lists them all.
    static let bookmarkLimit = 25
}

// MARK: - Tabs

private struct BrowserTabStrip: View {
    @EnvironmentObject var browser: BrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browser.pages) { page in
                    BrowserTabChip(page: page, isSelected: page.id == browser.selectedID)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28).padding(.bottom, 6)
    }
}

private struct BrowserTabChip: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var page: BrowserPage
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button { browser.select(page.id) } label: {
                HStack(spacing: 6) {
                    Group {
                        if page.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.75) }
                        else { Image(systemName: page.isBlank ? "plus.square.dashed" : "globe").font(.system(size: 11)) }
                    }
                    .frame(width: 14, height: 14)
                    Text(page.displayTitle).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                .frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.displayTitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            Button { browser.close(page) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(hovered || isSelected ? 1 : 0)
            .help("Close tab · ⌘W").accessibilityLabel("Close \(page.displayTitle)")
        }
        .padding(.leading, 9).padding(.trailing, 5).frame(height: 26)
        .background(isSelected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
        .help(page.url?.absoluteString ?? "New Tab")
    }
}

// MARK: - Content

private struct BrowserContent: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var page: BrowserPage

    var body: some View {
        Group {
            if let failure = page.failure {
                BrowserFailureView(failure: failure, address: BrowserAddress.display(page.url)) { page.reload() }
            } else if let webView = page.webView {
                BrowserWebHost(webView: webView, focusRequest: browser.pageFocusRequest)
            } else if page.isBlank {
                BrowserStartPage()
            } else {
                // A tab from the last session, about to load.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts a tab's long-lived web view: the same view moves between hosts as the panel is rebuilt,
/// and a web view that is in no window draws nothing and throttles its page.
private struct BrowserWebHost: NSViewRepresentable {
    let webView: BrowserWebView
    let focusRequest: Int

    func makeNSView(context: Context) -> ContainerView {
        // Requests made before the page was on screen are not for it.
        context.coordinator.focusRequest = focusRequest
        return ContainerView()
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        BrowserActivity.updatedHost()
        container.host(webView)
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak webView] in
                guard let webView, let window = webView.window else { return }
                window.makeFirstResponder(webView)
            }
        }
    }

    static func dismantleNSView(_ container: ContainerView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var focusRequest = 0 }

    final class ContainerView: NSView {
        func host(_ view: NSView) {
            guard view.superview !== self else { return }
            subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }
}

private struct BrowserFailureView: View {
    let failure: BrowserPage.Failure
    let address: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
            Text(failure.title).font(.system(size: 14, weight: .medium))
            if !address.isEmpty {
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(failure.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry).buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).padding(.top, 4)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Suggestions

/// Pages from the history that match what is being typed, under the address bar and over the page.
private struct BrowserSuggestions: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var address: BrowserAddressModel

    var body: some View {
        if address.isEditing, !address.suggestions.isEmpty {
            VStack(spacing: 1) {
                ForEach(Array(address.suggestions.enumerated()), id: \.element.id) { index, item in
                    BrowserLinkRow(title: item.title, address: item.url, symbol: "clock", isHighlighted: address.highlighted == index) {
                        browser.open(item.url)
                    }
                }
            }
            .padding(5)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.horizontal, 10).padding(.top, 4)
            .transition(.opacity)
        }
    }
}

/// One page in a list: a suggestion, a bookmark, or a visited page.
private struct BrowserLinkRow: View {
    let title: String
    let address: String
    let symbol: String
    var isHighlighted = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(Theme.muted).frame(width: 16)
                Text(title.isEmpty ? BrowserAddress.display(URL(string: address)) : title).font(.system(size: 12.5)).lineLimit(1)
                    .layoutPriority(1)
                if !title.isEmpty {
                    Text(BrowserAddress.display(URL(string: address))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            .background(isHighlighted ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(address)
    }
}

// MARK: - Start page

/// A new tab: bookmarks, the pages visited last, and the way in from Chrome.
private struct BrowserStartPage: View {
    @EnvironmentObject var browser: BrowserModel
    @State private var showsAllBookmarks = false

    /// Bookmarks shown before "Show all".
    static let bookmarkPreview = 8

    var body: some View {
        if browser.bookmarks.isEmpty && browser.recent.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
                Text("Browse beside your task").font(.system(size: 14, weight: .medium))
                Text("Preview what Crok builds, read the docs, and keep a page in view while you work. Type an address or a search above.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { browser.showChromeImport() } label: { Label("Import from Chrome…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium)).padding(.top, 6)
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !browser.bookmarks.isEmpty {
                        let shown = showsAllBookmarks ? browser.bookmarks[...] : browser.bookmarks.prefix(Self.bookmarkPreview)
                        header("Bookmarks", count: browser.bookmarks.count)
                        ForEach(shown) { bookmark in
                            BrowserLinkRow(title: bookmark.title, address: bookmark.url, symbol: "star") { browser.open(bookmark.url) }
                                .contextMenu {
                                    Button("Open in New Tab", systemImage: "plus.square.on.square") { open(bookmark.url) }
                                    Button("Remove Bookmark", systemImage: "star.slash") { browser.removeBookmark(bookmark.id) }
                                }
                        }
                        if browser.bookmarks.count > Self.bookmarkPreview {
                            Button(showsAllBookmarks ? "Show fewer" : "Show all \(browser.bookmarks.count.formatted())") { showsAllBookmarks.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                    if !browser.recent.isEmpty {
                        header("Recently visited", count: nil).padding(.top, browser.bookmarks.isEmpty ? 0 : 10)
                        ForEach(browser.recent) { item in
                            BrowserLinkRow(title: item.title, address: item.url, symbol: "clock") { browser.open(item.url) }
                                .contextMenu { Button("Open in New Tab", systemImage: "plus.square.on.square") { open(item.url) } }
                        }
                    }
                    Button { browser.showChromeImport() } label: { Label("Import from Chrome…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.top, 14)
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
            .onAppear { browser.refreshRecent() }
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            if let count { Text(count.formatted()).font(.system(size: 11)).foregroundStyle(Theme.muted.opacity(0.7)) }
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { browser.openTab(url) }
    }
}
