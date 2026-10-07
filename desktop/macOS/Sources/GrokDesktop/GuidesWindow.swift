import AppKit
import SwiftUI

/// `/docs`: the how-to guides the harness extracts to `$CROK_HOME/docs/user-guide`, with search
/// across titles and text, and links between guides.
struct DocsWindow: View {
    @EnvironmentObject var extras: ExtrasFeatureModel
    /// Injectable so previews and tests can point at sample guides.
    let directory: URL

    private enum LoadState: Equatable { case loading, missing, loaded([GuideDocument]) }

    @State private var state = LoadState.loading
    @State private var selection: String?
    @State private var query = ""
    /// Search results, recomputed when the query or the guides change rather than on every render.
    @State private var hits: [GuideLibrary.SearchHit] = []
    @State private var scrollTarget: GuideScrollTarget?
    @State private var reloadToken = 0

    init(directory: URL = GuideLibrary.directory(), query: String = "") {
        self.directory = directory
        _query = State(initialValue: query)
    }

    private var guides: [GuideDocument] {
        if case .loaded(let guides) = state { return guides }
        return []
    }
    private var selectedGuide: GuideDocument? { guides.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 290)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 520)
        .glassWindowBackground()
        .foregroundStyle(Theme.ink)
        .environment(\.openURL, OpenURLAction(handler: followLink))
        .task(id: reloadToken) { await load() }
        .onChange(of: extras.guideRequest) { _, request in if let request { apply(request) } }
        .onChange(of: query) { _, _ in hits = GuideLibrary.search(query, in: guides) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How-to Guides").font(.system(size: 17, weight: .semibold))
                Text(caption(hits: hits.count)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            NativeSearchField(text: $query, placeholder: "Search guides", onEscape: { query = "" },
                              onSubmit: { if let first = hits.first { open(first.guide.id, highlighting: query) } })
                .frame(height: 38).padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(hits, id: \.guide.id) { hit in
                            GuideListRow(hit: hit, number: number(of: hit.guide), isSelected: hit.guide.id == selection, searching: !query.isEmpty) {
                                open(hit.guide.id, highlighting: query.isEmpty ? nil : query)
                            }.id(hit.guide.id)
                        }
                        if hits.isEmpty && !query.isEmpty && !guides.isEmpty {
                            Text("No guide mentions “\(query)”.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                                .padding(20).frame(maxWidth: .infinity)
                        }
                    }.padding(8)
                }
                .onChange(of: selection) { _, value in if let value { proxy.scrollTo(value) } }
            }
            Divider()
            HStack(spacing: 8) {
                Button { extras.openURL(GuideDocsTarget.onlineURL) } label: { Label("Online docs", systemImage: "safari") }
                    .help(GuideDocsTarget.onlineURL.absoluteString)
                Spacer()
                IconButton(icon: "folder", help: "Show the guides in Finder", size: 28) {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }.disabled(state == .missing)
            }
            .buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(SidebarMaterial())
    }

    private func caption(hits: Int) -> String {
        switch state {
        case .loading: return "Loading…"
        case .missing: return "Not on this Mac yet"
        case .loaded(let guides):
            if query.isEmpty { return "\(guides.count) guides for Crok Build" }
            return hits == 1 ? "1 guide matches" : "\(hits) guides match"
        }
    }

    private func number(of guide: GuideDocument) -> Int { (guides.firstIndex { $0.id == guide.id } ?? 0) + 1 }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch state {
        case .loading:
            ProgressView("Loading guides…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            GuidesMissingView(directory: directory, onRetry: { reloadToken += 1 }, onOpenOnline: { extras.openURL(GuideDocsTarget.onlineURL) })
        case .loaded:
            if let guide = selectedGuide {
                VStack(spacing: 0) {
                    GuideHeaderBar(guide: guide, index: number(of: guide), count: guides.count,
                                   previous: neighbour(of: guide, by: -1), next: neighbour(of: guide, by: 1)) { open($0, highlighting: nil) }
                    Divider()
                    // A new theme re-renders the Markdown, whose views would otherwise keep their colours.
                    GuideReader(guide: guide, target: $scrollTarget).id("\(guide.id)#\(extras.themeRevision)")
                }
            } else {
                Text("Choose a guide").font(.system(size: 14)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func neighbour(of guide: GuideDocument, by offset: Int) -> GuideDocument? {
        guard let index = guides.firstIndex(where: { $0.id == guide.id }), guides.indices.contains(index + offset) else { return nil }
        return guides[index + offset]
    }

    // MARK: Actions

    private func load() async {
        let directory = self.directory
        let result = await Task.detached(priority: .userInitiated) { GuideLibrary.load(from: directory) }.value
        guard let result, !result.isEmpty else { state = .missing; hits = []; return }
        state = .loaded(result)
        hits = GuideLibrary.search(query, in: result)
        if let request = extras.guideRequest { apply(request) }
        if selection == nil || !result.contains(where: { $0.id == selection }) { selection = result.first?.id }
    }

    private func apply(_ request: ExtrasFeatureModel.GuideRequest) {
        guard let fileName = request.fileName, guides.contains(where: { $0.id == fileName }) else { return }
        query = ""
        open(fileName, anchor: request.anchor)
    }

    private func open(_ fileName: String, highlighting text: String? = nil, anchor: String? = nil) {
        selection = fileName
        if let anchor { scrollTarget = GuideScrollTarget(kind: .anchor(anchor)) }
        else if let text, !text.isEmpty { scrollTarget = GuideScrollTarget(kind: .text(text)) }
        else { scrollTarget = nil }
    }

    /// Guides link to each other by file name (`10-hooks.md#matchers`) and to their own headings (`#rules`).
    private func followLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == nil || url.isFileURL {
            let name = url.lastPathComponent
            if name.hasSuffix(".md"), guides.contains(where: { $0.id == name }) {
                open(name, anchor: url.fragment)
                return .handled
            }
            if url.path.isEmpty, let fragment = url.fragment {
                scrollTarget = GuideScrollTarget(kind: .anchor(fragment))
                return .handled
            }
            if url.scheme == nil { return .discarded }
        }
        return .systemAction
    }
}

/// Where a guide should scroll once it is on screen.
struct GuideScrollTarget: Equatable {
    enum Kind: Equatable { case anchor(String), text(String) }
    let id = UUID()
    let kind: Kind
}

private struct GuideListRow: View {
    let hit: GuideLibrary.SearchHit
    let number: Int
    let isSelected: Bool
    let searching: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.muted)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.guide.title).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).lineLimit(2)
                    if let snippet = hit.snippet {
                        Text(snippet).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                    } else if !hit.guide.summary.isEmpty {
                        Text(hit.guide.summary).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(searching ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
                if searching && hit.count > 0 {
                    Text(hit.count >= 99 ? "99+" : "\(hit.count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.hover, in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(hit.guide.title)
        .accessibilityValue(hit.snippet ?? hit.guide.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GuideHeaderBar: View {
    let guide: GuideDocument
    let index: Int
    let count: Int
    let previous: GuideDocument?
    let next: GuideDocument?
    let onOpen: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book").foregroundStyle(Theme.muted)
            Text("Guide \(index) of \(count)").foregroundStyle(Theme.muted)
            Text(guide.fileName).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1)
            Spacer()
            IconButton(icon: "chevron.left", help: previous.map { "Previous: \($0.title)" } ?? "Previous", size: 26) {
                if let previous { onOpen(previous.id) }
            }.disabled(previous == nil)
            IconButton(icon: "chevron.right", help: next.map { "Next: \($0.title)" } ?? "Next", size: 26) {
                if let next { onOpen(next.id) }
            }.disabled(next == nil)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20).frame(height: 40)
    }
}

/// One guide in a readable column. Each heading section renders lazily and is a scroll anchor.
private struct GuideReader: View {
    let guide: GuideDocument
    @Binding var target: GuideScrollTarget?
    private let sections: [GuideLibrary.Section]

    init(guide: GuideDocument, target: Binding<GuideScrollTarget?>) {
        self.guide = guide
        _target = target
        sections = GuideLibrary.sections(of: GuideLibrary.reflow(guide.content))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MarkdownStyle.panel.blockSpacing + 4) {
                    ForEach(sections) { section in
                        MarkdownContent(text: section.text, style: .panel).id(section.id)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: target) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target else { return }
        let section: GuideLibrary.Section?
        switch target.kind {
        case .anchor(let anchor):
            let slug = anchor.lowercased()
            section = sections.first { $0.anchors.contains(slug) }
        case .text(let text):
            section = sections.first { $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        guard let section else { return }
        // The lazy stack needs a pass to lay out rows before a far section can be scrolled to.
        DispatchQueue.main.async { proxy.scrollTo(section.id, anchor: .top) }
    }
}

private struct GuidesMissingView: View {
    let directory: URL
    let onRetry: () -> Void
    let onOpenOnline: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 34)).foregroundStyle(Theme.muted)
            Text("The guides aren’t on this Mac yet").font(.system(size: 17, weight: .semibold))
            Text("Crok Build unpacks its how-to guides into \((directory.path as NSString).abbreviatingWithTildeInPath) each time it starts. Start a task so Crok runs once, then check again — or read them online.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Check again", action: onRetry)
                Button("Open online docs", action: onOpenOnline).keyboardShortcut(.defaultAction)
            }.buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium)).padding(.top, 4)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
