import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - /jump

/// `/jump`: "Jump to which turn?". Moving the selection scrolls the conversation behind the
/// sheet; Return stays there and esc goes back to where the reader was.
struct JumpSheet: View {
    @EnvironmentObject var tools: TranscriptToolsModel
    @State private var filter = ""

    var body: some View {
        let state = tools.jump
        let turns = state?.turns ?? []
        let visible = Self.filter(turns, filter)
        let selectedID = state.flatMap { $0.turns.indices.contains($0.selected) ? $0.turns[$0.selected].id : nil }
        DesktopPanel(title: "Jump to which turn?", subtitle: "Choosing a turn scrolls the conversation to it. Esc returns to where you were.",
                     width: 600, height: 480, onClose: { tools.cancelJump() }) {
            VStack(spacing: 0) {
                TranscriptQueryBox(text: $filter, placeholder: "Filter turns", onEscape: { tools.cancelJump() },
                                   onSubmit: { _ in tools.commitJump() }, onMove: { step($0, in: visible, selectedID: selectedID) }) {
                    if !filter.isEmpty { Text("\(visible.count) of \(turns.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).fixedSize() }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if visible.isEmpty {
                    Text("No turns match “\(filter)”.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(visible) { turn in
                                    row(turn, selected: turn.id == selectedID, onScreen: state.map { turn.number - 1 == $0.initial } ?? false,
                                        ordinalWidth: CGFloat(String(turns.count).count) * 8 + 6)
                                        .id(turn.id)
                                }
                            }.padding(.horizontal, 12).padding(.bottom, 12)
                        }
                        .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
                        .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
        } footer: {
            Text("↑↓ preview  ·  ↵ jump  ·  esc go back").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Cancel") { tools.cancelJump() }
            Button("Jump") { tools.commitJump() }.keyboardShortcut(.defaultAction).disabled(selectedID == nil)
        }
        .onChange(of: filter) { _, _ in
            let visible = Self.filter(tools.jump?.turns ?? [], filter)
            if let first = visible.first, !visible.contains(where: { $0.id == selectedID }) { tools.moveJump(to: first.number - 1) }
        }
        // Closed some other way: behave like esc. After a jump the state is already gone.
        .onDisappear { tools.cancelJump() }
    }

    static func filter(_ turns: [TranscriptTurn], _ query: String) -> [TranscriptTurn] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return turns }
        return turns.filter { $0.preview.localizedCaseInsensitiveContains(query) || String($0.number) == query }
    }

    private func step(_ direction: Int, in visible: [TranscriptTurn], selectedID: UUID?) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + direction, 0), visible.count - 1) } ?? (direction > 0 ? 0 : visible.count - 1)
        tools.moveJump(to: visible[next].number - 1)
    }

    private func row(_ turn: TranscriptTurn, selected: Bool, onScreen: Bool, ordinalWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text("\(turn.number)").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.muted)
                .frame(width: ordinalWidth, alignment: .trailing)
            Text(turn.displayPreview)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(turn.preview.isEmpty ? Theme.muted : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if onScreen {
                Text("On screen").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.hover.opacity(0.8), in: Capsule())
            }
            if let date = turn.date { Text(TranscriptTimestamp.label(date)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.accent).frame(width: 3, height: 18).padding(.leading, 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tools.moveJump(to: turn.number - 1); tools.commitJump() }
        .onTapGesture { tools.moveJump(to: turn.number - 1) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Turn \(turn.number): \(turn.displayPreview)")
    }
}

// MARK: - /history

/// `/history`: fuzzy search over prompt history. Return, Tab, or a click puts the prompt in the composer.
struct HistorySheet: View {
    @EnvironmentObject var tools: TranscriptToolsModel
    @State private var query: String
    @State private var rows: [TranscriptHistoryRow] = []
    @State private var selected = 0

    init(initialQuery: String = "") { _query = State(initialValue: initialQuery) }

    var body: some View {
        let history = tools.history
        DesktopPanel(title: "Prompt history", subtitle: subtitle, width: 680, height: 580, onClose: { tools.store?.sheet = nil }) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TranscriptQueryBox(text: $query, placeholder: "Search prompts", onEscape: { tools.store?.sheet = nil },
                                       onSubmit: { _ in insertSelection() }, onMove: move, onTab: insertSelection) {
                        if !query.isEmpty { Text("\(rows.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).fixedSize() }
                    }
                    Picker("Scope", selection: Binding(get: { history.scope }, set: { tools.loadHistory(scope: $0) })) {
                        ForEach(TranscriptHistoryState.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    .help("Prompts from every task in this project, or only this one")
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if let notice = history.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                content(history)
            }
        } footer: {
            Text("↑↓ select  ·  ↵ or ⇥ insert  ·  esc close").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Cancel") { tools.store?.sheet = nil }
            Button("Insert") { insertSelection() }.keyboardShortcut(.defaultAction).disabled(rows.isEmpty)
        }
        .task(id: TranscriptHistoryRankKey(query: query, prompts: history.prompts)) {
            let prompts = history.prompts, query = self.query
            let ranked = await Task.detached(priority: .userInitiated) {
                TranscriptPromptHistory.rank(prompts, query: query).map(TranscriptHistoryRow.init)
            }.value
            guard !Task.isCancelled else { return }
            rows = ranked
            selected = 0
        }
    }

    private var subtitle: String {
        let project = tools.store?.project?.name ?? "this project"
        return "Prompts you've sent in \(project), most recent first."
    }

    @ViewBuilder private func content(_ history: TranscriptHistoryState) -> some View {
        if history.isLoading && history.prompts.isEmpty {
            ProgressView("Loading prompt history…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
                Text(history.prompts.isEmpty ? "No prompts yet." : "No prompts match “\(query)”.").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "text.bubble").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 2)
                                Text(row.display).font(.system(size: 14)).lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(offset == selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                            .onTapGesture { tools.insertHistory(row.text) }
                            .onHover { if $0 { selected = offset } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(offset == selected ? [.isButton, .isSelected] : .isButton)
                            .id(row.id)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }
                .onChange(of: selected) { _, index in if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) } }
            }
        }
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    private func insertSelection() {
        guard rows.indices.contains(selected) else { return }
        tools.insertHistory(rows[selected].text)
    }
}

private struct TranscriptHistoryRankKey: Equatable {
    let query: String
    let prompts: [String]
}

/// A ranked prompt with its matched letters emphasised, built off the main thread.
struct TranscriptHistoryRow: Identifiable {
    let id: Int
    let text: String
    let display: AttributedString

    /// Only what three lines can show is styled.
    private static let displayLimit = 600

    init(_ match: TranscriptPromptHistory.Match) {
        id = match.index
        text = match.text
        let shown = String(match.text.prefix(Self.displayLimit))
        var display = AttributedString(shown)
        let marks = Set(match.highlights)
        if !marks.isEmpty {
            var index = display.startIndex
            var offset = 0
            while index < display.endIndex {
                let next = display.characters.index(after: index)
                if marks.contains(offset) {
                    display[index..<next].foregroundColor = Theme.accent
                    display[index..<next].font = .system(size: 14, weight: .bold)
                }
                index = next
                offset += 1
            }
        }
        self.display = display
    }
}

// MARK: - /transcript

/// One `## User`, `## Assistant`, or `## Tools` section of the export Markdown.
struct TranscriptDocumentSection: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tools, preamble }
    let id: Int
    let kind: Kind
    let body: String

    /// Splits the export at its section headers. A header only counts after a blank line, so a
    /// reply that quotes "## User" mid-paragraph stays in one piece.
    static func parse(_ markdown: String) -> [TranscriptDocumentSection] {
        var sections: [TranscriptDocumentSection] = []
        var kind: Kind = .preamble
        var lines: [Substring] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if kind != .preamble || !body.isEmpty { sections.append(TranscriptDocumentSection(id: sections.count, kind: kind, body: body)) }
            lines = []
        }
        var previousBlank = true
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let header: Kind? = switch line {
            case "## User": .user
            case "## Assistant": .assistant
            case "## Tools": .tools
            default: nil
            }
            if let header, previousBlank {
                flush()
                kind = header
            } else {
                lines.append(line)
            }
            previousBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        flush()
        return sections
    }

    var searchText: String { kind == .assistant ? TranscriptPlainText.strip(body) : body }
}

/// `/transcript`: the selected task's conversation in the export format, read-only, with its own
/// find (⌘F), Copy, and Save As….
struct TranscriptWindow: View {
    @EnvironmentObject var tools: TranscriptToolsModel
    @State private var query: String
    @State private var matches: [Int] = []
    @State private var cursor: Int?
    @State private var invalid = false
    /// The query the matches belong to; nothing is reported while a newer one is searched.
    @State private var searchedQuery = ""
    @State private var focusRequest = 0
    @State private var status: String?
    @State private var statusSerial = 0

    init(initialQuery: String = "") { _query = State(initialValue: initialQuery) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .glassWindowBackground()
        .foregroundStyle(Theme.ink)
        .overlay(alignment: .bottom) {
            if let status {
                Text(status).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(cornerRadius: 12)
                    .padding(.bottom, 18).padding(.horizontal, 40)
                    .transition(.opacity)
            }
        }
        .background { shortcuts }
        .onAppear { if tools.document == .idle { tools.loadDocument() } }
        .onReceive(tools.selectedConversationChanges) { _ in tools.loadDocument() }
        .task(id: TranscriptWindowSearchKey(query: query, document: loadedDocument?.markdown)) { await search() }
    }

    private var loadedDocument: TranscriptDocument? {
        if case .loaded(let document) = tools.document { return document }
        return nil
    }

    @ViewBuilder private var shortcuts: some View {
        Button("") { focusRequest += 1 }.keyboardShortcut("f").hidden()
        Button("") { step(1) }.keyboardShortcut("g").hidden()
        Button("") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).hidden()
        Button("") { tools.loadDocument() }.keyboardShortcut("r").hidden()
    }

    private var header: some View {
        let document = loadedDocument
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document?.title ?? tools.store?.conversation?.title ?? "Transcript")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(detail(document)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    .help(document?.source == .cli ? "Rendered by crok export from the saved session" : "Rendered from the conversation shown in Crok Desktop")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TranscriptQueryBox(text: $query, placeholder: "Find in transcript", focusRequest: focusRequest,
                               onEscape: { query = "" }, onSubmit: { step($0 ? -1 : 1) }, onMove: step) {
                if let label = searchStatus {
                    Text(label).font(.system(size: 12)).monospacedDigit().foregroundStyle(invalid ? Color.red : Theme.muted).lineLimit(1).fixedSize()
                }
            }
            .frame(width: 270)
            IconButton(icon: "arrow.clockwise", help: "Reload · ⌘R") { tools.loadDocument() }
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(document == nil)
                .help("Copy the transcript as Markdown")
            Button { saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
        }
        .buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Theme.surface)
    }

    private func detail(_ document: TranscriptDocument?) -> String {
        guard let document else { return tools.document == .loading ? "Loading…" : "Export format" }
        let lines = TranscriptClipboard.lineCount(document.markdown)
        return "Export format · \(document.markdown.utf8.count.formatted()) chars · \(lines.formatted()) \(lines == 1 ? "line" : "lines")"
    }

    private var searchStatus: String? {
        guard !query.isEmpty, searchedQuery == query else { return nil }
        if invalid { return "Invalid pattern" }
        guard let cursor, !matches.isEmpty else { return "No matches" }
        return "\(cursor + 1) of \(matches.count)"
    }

    @ViewBuilder private var content: some View {
        switch tools.document {
        case .idle, .loading:
            ProgressView("Loading transcript…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "text.alignleft").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.muted)
                Text("No conversation transcript to view yet").font(.system(size: 15, weight: .medium))
                Text("Start a task, then open /transcript again.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let document):
            let sections = TranscriptDocumentSection.parse(document.markdown)
            let current = cursor.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            TranscriptDocumentSectionView(section: section, isCurrent: section.id == current).equatable().id(section.id)
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, 32).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: current) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private func search() async {
        guard let document = loadedDocument, !query.isEmpty else { matches = []; cursor = nil; invalid = false; return }
        let query = self.query, markdown = document.markdown
        let result = await Task.detached(priority: .userInitiated) { () -> (matches: [Int], invalid: Bool) in
            let matcher = TranscriptSearchMatcher(query)
            guard !matcher.isInvalid else { return ([], true) }
            var matches: [Int] = []
            for section in TranscriptDocumentSection.parse(markdown) {
                matches += Array(repeating: section.id, count: matcher.count(in: section.searchText))
            }
            return (matches, false)
        }.value
        guard !Task.isCancelled else { return }
        invalid = result.invalid
        matches = result.matches
        cursor = matches.isEmpty ? nil : 0
        searchedQuery = query
    }

    private func step(_ direction: Int) {
        cursor = TranscriptSearch.step(cursor, by: direction, count: matches.count)
    }

    private func show(_ message: String) {
        statusSerial += 1
        let serial = statusSerial
        withAnimation(.easeOut(duration: 0.15)) { status = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard statusSerial == serial else { return }
            withAnimation(.easeIn(duration: 0.2)) { status = nil }
        }
    }

    private func copy() {
        guard let document = loadedDocument else { return }
        tools.copyDocument(document.markdown) { show($0) }
    }

    private func saveAs() {
        guard let document = loadedDocument else { return }
        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.nameFieldStringValue = Self.fileName(for: document.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let markdown = document.markdown
            Task {
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { try TranscriptClipboard.write(markdown, to: url, ownerOnly: false); return nil } catch { return error.localizedDescription }
                }.value
                show(failure.map { "Failed to write file: \($0)" } ?? "Conversation exported to \(url.path)")
            }
        }
    }

    static func fileName(for title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "transcript" : String(cleaned.prefix(80))) + ".md"
    }
}

private struct TranscriptWindowSearchKey: Equatable {
    let query: String
    let document: String?
}

private struct TranscriptDocumentSectionView: View, Equatable {
    let section: TranscriptDocumentSection
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                switch section.kind {
                case .user: Image(systemName: "person.crop.circle").font(.system(size: 15)).foregroundStyle(Theme.muted)
                case .assistant: GrokMark(size: 17)
                case .tools: Image(systemName: "wrench.and.screwdriver").font(.system(size: 13)).foregroundStyle(Theme.muted)
                case .preamble: EmptyView()
                }
                if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            }
            .accessibilityAddTraits(.isHeader)
            Group {
                switch section.kind {
                case .user:
                    MarkdownContent(text: section.body, style: .panel)
                        .padding(.horizontal, 15).padding(.vertical, 12)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                case .tools:
                    Text(section.body).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                        .textSelection(.enabled).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                case .assistant, .preamble:
                    MarkdownContent(text: section.body, style: .panel)
                }
            }
        }
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
                    .padding(-10)
            }
        }
    }

    private var title: String? {
        switch section.kind {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tools: return "Tools"
        case .preamble: return nil
        }
    }
}
