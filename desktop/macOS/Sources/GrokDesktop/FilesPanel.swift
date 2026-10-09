import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A project's files as a tree of relative paths.
struct ProjectFileIndex: Sendable {
    struct Entry: Hashable, Sendable {
        let name: String
        /// Relative to the project folder.
        let path: String
        let isDirectory: Bool
    }

    let root: String
    let files: [String]
    let isTruncated: Bool
    /// Each folder's entries, folders first. The project folder itself is "".
    let children: [String: [Entry]]

    init(root: String, files: [String], isTruncated: Bool) {
        self.root = root
        self.files = files
        self.isTruncated = isTruncated
        var children: [String: Set<Entry>] = [:]
        for file in files {
            var parent = ""
            let parts = file.split(separator: "/", omittingEmptySubsequences: true)
            for (index, part) in parts.enumerated() {
                let path = parent.isEmpty ? String(part) : parent + "/" + part
                let isDirectory = index < parts.count - 1
                children[parent, default: []].insert(Entry(name: String(part), path: path, isDirectory: isDirectory))
                parent = path
            }
        }
        self.children = children.mapValues { entries in
            entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    struct Row: Identifiable, Hashable {
        let entry: Entry
        let depth: Int
        var id: String { entry.path }
    }

    /// The rows on screen: every entry whose parent folders are open.
    func rows(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func walk(_ folder: String, depth: Int) {
            for entry in children[folder] ?? [] {
                rows.append(Row(entry: entry, depth: depth))
                if entry.isDirectory && expanded.contains(entry.path) { walk(entry.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return rows
    }

    /// Files whose path matches the query, best first: name matches, then path matches, then
    /// paths that contain the query's characters in order.
    func search(_ query: String, limit: Int = 300) -> [String] {
        let needle = query.lowercased()
        var ranked: [(score: Int, path: String)] = []
        for file in files {
            let lower = file.lowercased()
            let name = (lower as NSString).lastPathComponent
            let score: Int
            if name.hasPrefix(needle) { score = 0 }
            else if name.contains(needle) { score = 1 }
            else if lower.contains(needle) { score = 2 }
            else {
                var remaining = needle[...]
                for character in lower where remaining.first == character { remaining = remaining.dropFirst() }
                guard remaining.isEmpty else { continue }
                score = 3
            }
            ranked.append((score, file))
        }
        ranked.sort { $0.score == $1.score ? $0.path.count < $1.path.count : $0.score < $1.score }
        return ranked.prefix(limit).map(\.path)
    }
}

/// What the Files tab shows for the selected file.
enum FilePreviewContent {
    case none
    case loading
    case text(String, language: String?, truncated: Bool)
    case image(NSImage, bytes: Int)
    case binary(bytes: Int)
    case failed(String)
}

/// The Files tab's state: the project's file tree, the filter, and the selected file's preview.
@MainActor
final class FilesPanelModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case all, changes
        var id: String { rawValue }
    }

    weak var store: AppStore?
    @Published var scope: Scope = .all
    @Published var filter = "" { didSet { if filter != oldValue { rebuildRows() } } }
    @Published private(set) var index: ProjectFileIndex?
    @Published private(set) var loading = false
    @Published private(set) var rows: [ProjectFileIndex.Row] = []
    @Published private(set) var matches: [String] = []
    @Published private(set) var expanded: Set<String> = []
    /// The selected file's absolute path.
    @Published private(set) var selection: String?
    @Published private(set) var preview: FilePreviewContent = .none
    /// Changed files show their diff unless the reader asks for the file itself.
    @Published var showsDiff = true
    /// Git's changes by absolute path, for the tree's badges.
    @Published private(set) var changesByPath: [String: GitFileChange] = [:]

    private let service = WorkspaceService()
    private var loadedProjectPath: String?
    private var loadID: UUID?
    private var previewID: UUID?
    nonisolated static let previewLimit = 1_024 * 1_024

    init(store: AppStore) { self.store = store }

    // MARK: Loading

    /// Loads the project's files once per project; `force` reloads them.
    func load(force: Bool = false) {
        guard let project = store?.project else {
            loadedProjectPath = nil; index = nil; rows = []; matches = []; selection = nil; preview = .none
            return
        }
        if project.path != loadedProjectPath {
            expanded = []; filter = ""; selection = nil; preview = .none; index = nil; rows = []
        } else if !force, index != nil || loading { return }
        loadedProjectPath = project.path
        let requestID = UUID()
        loadID = requestID
        loading = true
        Task { [weak self, service] in
            let listing = await service.listFiles(path: project.path)
            let index = await Task.detached(priority: .userInitiated) {
                ProjectFileIndex(root: project.path, files: listing.files, isTruncated: listing.truncated)
            }.value
            guard let self, self.loadID == requestID else { return }
            self.index = index
            self.loading = false
            self.rebuildRows()
        }
    }

    private func rebuildRows() {
        guard let index else { rows = []; matches = []; return }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { matches = []; rows = index.rows(expanded: expanded) }
        else { matches = index.search(query) }
    }

    func toggle(_ folder: String) {
        if expanded.remove(folder) == nil { expanded.insert(folder) }
        rebuildRows()
    }

    /// Opens every folder above a file so it shows in the tree.
    func reveal(_ relativePath: String) {
        var parent = (relativePath as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "." {
            expanded.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        rebuildRows()
    }

    // MARK: Selection

    func absolutePath(_ relative: String) -> String? {
        guard let root = loadedProjectPath ?? store?.project?.path else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(relative).path
    }

    /// The change Git reports for a file, if any.
    func change(atAbsolutePath path: String) -> GitFileChange? { changesByPath[path] }

    /// Follows a new Git snapshot: the tree's badges and the selected file's preview. When the
    /// set of changed files moves, files were probably created or deleted, so the tree reloads.
    func workspaceDidChange() {
        var map: [String: GitFileChange] = [:]
        if let store, let root = store.workspace.rootPath {
            let base = URL(fileURLWithPath: root)
            for change in store.workspace.changes { map[base.appendingPathComponent(change.path).path] = change }
        }
        let filesMoved = Set(map.keys) != Set(changesByPath.keys)
        if map != changesByPath { changesByPath = map }
        if filesMoved, index != nil, loadedProjectPath == store?.project?.path { load(force: true) }
        refreshSelection()
    }

    func repositoryPath(_ change: GitFileChange) -> String? {
        guard let root = store?.workspace.rootPath else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(change.path).path
    }

    func select(_ path: String?) {
        guard let store else { return }
        selection = path
        guard let path else {
            preview = .none; store.selectedFile = nil; store.diffText = ""
            return
        }
        if let change = change(atAbsolutePath: path) {
            Task { await store.selectFile(change.path) }
        } else {
            store.selectedFile = nil; store.diffText = ""
        }
        loadPreview(path)
    }

    /// The selected file changed on disk or in Git: keep its preview current. A deleted file
    /// stays selected while Git still shows its diff.
    func refreshSelection() {
        guard let selection else { return }
        if !FileManager.default.fileExists(atPath: selection) {
            if change(atAbsolutePath: selection) == nil { select(nil) }
            return
        }
        loadPreview(selection, showsProgress: false)
    }

    private func loadPreview(_ path: String, showsProgress: Bool = true) {
        let requestID = UUID()
        previewID = requestID
        if showsProgress { preview = .loading }
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) { Self.readPreview(path) }.value
            guard let self, self.previewID == requestID, self.selection == path else { return }
            self.preview = content
        }
    }

    nonisolated static func readPreview(_ path: String) -> FilePreviewContent {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return .failed("This is a folder.") }
        let size = values?.fileSize ?? 0
        if let type = values?.contentType, type.conforms(to: .image), type != .svg {
            if let image = NSImage(contentsOf: url), image.isValid { return .image(image, bytes: size) }
            return .binary(bytes: size)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failed("Crok Desktop can't read this file.") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: previewLimit + 1)) ?? Data()
        let sample = data.prefix(8_192)
        if sample.contains(0) { return .binary(bytes: size) }
        let text = String(decoding: data.prefix(previewLimit), as: UTF8.self)
        let language = SyntaxHighlighter.language(for: url.lastPathComponent)?.id ?? SyntaxHighlighter.language(for: url.pathExtension)?.id
        return .text(text, language: language, truncated: data.count > previewLimit)
    }

    // MARK: Actions

    func attach(_ path: String) { store?.features.attachments.add(urls: [URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func revealInFinder(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func copyPath(_ path: String, relative: Bool) {
        var value = path
        if relative, let root = loadedProjectPath, path.hasPrefix(root + "/") { value = String(path.dropFirst(root.count + 1)) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - View

struct FilesPanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var files: FilesPanelModel
    /// The directory column's width while a file is previewed beside it.
    @AppStorage("filesTreeWidth") private var treeWidth = FilesPanelView.defaultTreeWidth
    @AppStorage("filesTreeVisible") private var showsTree = true

    static let defaultTreeWidth = 240.0
    static let minimumTreeWidth = 180.0
    /// Room the preview keeps beside the directory column; narrower than this, the column hides.
    static let minimumPreviewWidth = 280.0

    var body: some View {
        VStack(spacing: 0) {
            if store.project == nil {
                SidePanelEmptyState(symbol: "folder", title: "No project", detail: "Open a project to browse its files.")
            } else if files.selection == nil {
                browser
            } else {
                // As in Codex, the directory stays on the left and the selected file opens beside it.
                GeometryReader { geometry in
                    let available = Double(geometry.size.width)
                    let maximum = max(Self.minimumTreeWidth, min(480, available - Self.minimumPreviewWidth))
                    let treeFits = available - Self.minimumTreeWidth >= Self.minimumPreviewWidth
                    HStack(spacing: 0) {
                        if showsTree && treeFits {
                            browser
                                .frame(width: min(max(treeWidth, Self.minimumTreeWidth), maximum))
                                .overlay(alignment: .trailing) {
                                    ResizeHandle(axis: .horizontal, value: $treeWidth, range: Self.minimumTreeWidth...maximum,
                                                 defaultValue: Self.defaultTreeWidth, label: "File tree width")
                                        .offset(x: 4.5)
                                }
                                .zIndex(1)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        FilePreviewPane(showsTree: $showsTree, canShowTree: treeFits)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task(id: store.project?.path) { files.load(); files.workspaceDidChange() }
        .onChange(of: store.workspace) { _, _ in files.workspaceDidChange() }
    }

    /// The directory: the scope picker, the filter, and the tree or the changed files.
    private var browser: some View {
        VStack(spacing: 0) {
            header
            list.frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                // A segmented control never squeezes below its natural width, and the directory column
                // can be narrower than the picker with its count: the count goes first, then the picker shrinks.
                ViewThatFits(in: .horizontal) {
                    scopePicker(showsCount: true, size: .regular)
                    scopePicker(showsCount: false, size: .regular)
                    scopePicker(showsCount: false, size: .small)
                    scopePicker(showsCount: false, size: .mini)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                // In the reload button's place, so the picker keeps its room while the files load.
                if files.loading {
                    ProgressView().controlSize(.mini).frame(width: 26, height: 26)
                } else {
                    IconButton(icon: "arrow.clockwise", help: "Reload files and changes", size: 26) {
                        files.load(force: true)
                        Task { await store.refreshWorkspace() }
                    }
                }
            }
            if files.scope == .all {
                NativeSearchField(text: $files.filter, placeholder: "Filter files", onEscape: { files.filter = "" }, focusesOnAppear: false)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private func scopePicker(showsCount: Bool, size: ControlSize) -> some View {
        Picker("Show", selection: $files.scope) {
            Text("All files").tag(FilesPanelModel.Scope.all)
            Text(showsCount && !store.workspace.changes.isEmpty ? "Changes \(store.workspace.changes.count)" : "Changes").tag(FilesPanelModel.Scope.changes)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(size).fixedSize()
    }

    @ViewBuilder
    private var list: some View {
        switch files.scope {
        case .all: tree
        case .changes: changes
        }
    }

    @ViewBuilder
    private var tree: some View {
        if let index = files.index {
            if index.files.isEmpty {
                SidePanelEmptyState(symbol: "doc", title: "No files", detail: "This folder has no files Crok can list.")
            } else if !files.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                if files.matches.isEmpty {
                    SidePanelEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "No file path contains \u{201C}\(files.filter)\u{201D}.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(files.matches, id: \.self) { path in
                                FileTreeRow(name: (path as NSString).lastPathComponent, detail: (path as NSString).deletingLastPathComponent,
                                            depth: 0, isDirectory: false, isExpanded: false, relativePath: path)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(files.rows) { row in
                            FileTreeRow(name: row.entry.name, detail: nil, depth: row.depth, isDirectory: row.entry.isDirectory,
                                        isExpanded: files.expanded.contains(row.entry.path), relativePath: row.entry.path)
                        }
                        if index.isTruncated {
                            Text("Showing the first \(index.files.count.formatted()) files.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var changes: some View {
        if let error = store.workspace.error {
            SidePanelEmptyState(symbol: "folder.badge.questionmark", title: "No Git repository", detail: error)
        } else if store.workspace.changes.isEmpty {
            SidePanelEmptyState(symbol: "checkmark.circle", title: "No changes", detail: "Files Crok or you change appear here.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(store.workspace.changes.count) changed files").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("+\(store.workspace.changes.reduce(0) { $0 + $1.additions })").foregroundStyle(Theme.green)
                    Text("−\(store.workspace.changes.reduce(0) { $0 + $1.deletions })").foregroundStyle(Theme.red)
                }
                .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 16).padding(.bottom, 6)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.workspace.changes) { change in ChangedFileRow(change: change) }
                    }.padding(.horizontal, 8).padding(.bottom, 6)
                }
            }
        }
    }
}

/// One row of the file tree, or of the filtered list when `detail` names the folder.
private struct FileTreeRow: View {
    @EnvironmentObject var files: FilesPanelModel
    let name: String
    let detail: String?
    let depth: Int
    let isDirectory: Bool
    let isExpanded: Bool
    let relativePath: String
    @State private var hovered = false

    var body: some View {
        let absolute = files.absolutePath(relativePath) ?? relativePath
        let change = isDirectory ? nil : files.change(atAbsolutePath: absolute)
        let selected = files.selection == absolute
        Button {
            if isDirectory { FoldMotion.toggle { files.toggle(relativePath) } }
            else if !selected { files.select(absolute) }
        } label: {
            HStack(spacing: 6) {
                if isDirectory {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                FileIcon(path: absolute, isDirectory: isDirectory, isExpanded: isExpanded).frame(width: 16, height: 16)
                Text(name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(change.map { FileStatusBadge.color($0.status) } ?? Theme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let change { FileStatusBadge(status: change.status) }
            }
            .padding(.leading, CGFloat(depth) * 14 + 4).padding(.trailing, 6)
            .frame(height: 24).contentShape(Rectangle())
            .background(selected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(relativePath)
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: absolute) as NSURL) }
        .contextMenu { FileActions(path: absolute, isDirectory: isDirectory) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isDirectory { files.open(absolute) } })
        .accessibilityLabel(isDirectory ? "\(name) folder" : name)
        .accessibilityValue(isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : (change.map { FileStatusBadge.description($0.status) } ?? ""))
    }
}

private struct ChangedFileRow: View {
    @EnvironmentObject var files: FilesPanelModel
    let change: GitFileChange
    @State private var hovered = false

    var body: some View {
        let absolute = files.repositoryPath(change) ?? change.path
        let selected = files.selection == absolute
        Button { if !selected { files.select(absolute) } } label: {
            HStack(spacing: 8) {
                FileIcon(path: absolute, isDirectory: false, isExpanded: false).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text((change.path as NSString).lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
                    if change.path.contains("/") {
                        Text((change.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Group {
                    if change.isBinary { Text("binary").foregroundStyle(Theme.muted) }
                    else {
                        Text("+\(change.additions)").foregroundStyle(Theme.green)
                        Text("−\(change.deletions)").foregroundStyle(Theme.red)
                    }
                }.font(.system(size: 11, design: .monospaced))
                FileStatusBadge(status: change.status)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
            .background(selected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(change.path)
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: absolute) as NSURL) }
        .contextMenu { FileActions(path: absolute, isDirectory: false) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { files.open(absolute) })
    }
}

private struct FileActions: View {
    @EnvironmentObject var files: FilesPanelModel
    let path: String
    let isDirectory: Bool

    var body: some View {
        Button("Attach to Prompt", systemImage: "paperclip") { files.attach(path) }
        if !isDirectory { Button("Open", systemImage: "arrow.up.forward.app") { files.open(path) } }
        Button("Reveal in Finder", systemImage: "folder") { files.revealInFinder(path) }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { files.copyPath(path, relative: false) }
        Button("Copy Relative Path") { files.copyPath(path, relative: true) }
    }
}

/// Git's status letter for a file, coloured by kind.
struct FileStatusBadge: View {
    let status: String

    var body: some View {
        Text(Self.letter(status)).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Self.color(status)).frame(minWidth: 12)
            .help(Self.description(status))
    }

    static func letter(_ status: String) -> String {
        if status == "??" { return "U" }
        let code = status.trimmingCharacters(in: .whitespaces)
        return String(code.first ?? "M")
    }

    static func color(_ status: String) -> Color {
        switch letter(status) {
        case "U", "A": return Theme.green
        case "D": return Theme.red
        case "R", "C": return Theme.accent
        default: return Color.orange
        }
    }

    static func description(_ status: String) -> String {
        switch letter(status) {
        case "U": return "Untracked"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        default: return "Modified"
        }
    }
}

/// The system's icon for a file or folder.
private struct FileIcon: View {
    let path: String
    let isDirectory: Bool
    let isExpanded: Bool

    var body: some View {
        if isDirectory {
            Image(systemName: isExpanded ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(Theme.accent.opacity(0.85))
        } else {
            Image(nsImage: FileIconCache.icon(forExtension: (path as NSString).pathExtension)).resizable().interpolation(.high)
        }
    }
}

@MainActor
enum FileIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forExtension pathExtension: String) -> NSImage {
        let key = pathExtension.lowercased()
        if let icon = icons[key] { return icon }
        let type = UTType(filenameExtension: key) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icons[key] = icon
        return icon
    }
}

/// The selected file beside the directory: its diff or its contents, with actions.
private struct FilePreviewPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var files: FilesPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showsTree: Bool
    /// Whether the panel is wide enough for the directory column.
    let canShowTree: Bool

    var body: some View {
        if let path = files.selection {
            let change = files.change(atAbsolutePath: path)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if canShowTree {
                        IconButton(icon: "sidebar.left", help: showsTree ? "Hide file tree" : "Show file tree", size: 24) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showsTree.toggle() }
                        }
                    }
                    FileIcon(path: path, isDirectory: false, isExpanded: false).frame(width: 16, height: 16)
                    Text((path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        .truncationMode(.middle).layoutPriority(1)
                    if let folder = relativeFolder(path) {
                        Text(folder).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                    }
                    if let change { FileStatusBadge(status: change.status) }
                    Spacer(minLength: 4)
                    if change != nil {
                        Picker("View", selection: $files.showsDiff) {
                            Text("Diff").tag(true)
                            Text("File").tag(false)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    }
                    IconButton(icon: "paperclip", help: "Attach to prompt", size: 24) { files.attach(path) }
                    IconButton(icon: "arrow.up.forward.app", help: "Open", size: 24) { files.open(path) }
                    IconButton(icon: "xmark", help: "Close preview", size: 24) { files.select(nil) }
                }
                .padding(.horizontal, 10).frame(height: 40)
                Divider().overlay(Theme.line.opacity(0.4))
                Group {
                    if change != nil && files.showsDiff {
                        ReadOnlyTextView(text: store.diffText, style: .diff, wrapsLines: false, sizing: .fill)
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.codeBackground.opacity(0.6))
        }
    }

    /// The file's folder inside the project, shown dimmed after its name.
    private func relativeFolder(_ path: String) -> String? {
        guard let root = store.project?.path, path.hasPrefix(root + "/") else { return nil }
        let folder = (String(path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    @ViewBuilder
    private var content: some View {
        switch files.preview {
        case .none: Color.clear
        case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let language, let truncated):
            VStack(spacing: 0) {
                ReadOnlyTextView(text: text, style: .code(language: language), wrapsLines: false, sizing: .fill)
                    .padding(.leading, 12)
                if truncated {
                    Text("Showing the first 1 MB.").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(6)
                }
            }
        case .image(let image, let bytes):
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.bottom, 8)
            }
        case .binary(let bytes):
            SidePanelEmptyState(symbol: "doc.zipper", title: "Binary file", detail: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        case .failed(let message):
            SidePanelEmptyState(symbol: "exclamationmark.triangle", title: "No preview", detail: message)
        }
    }
}

/// A centred placeholder for an empty side panel tab.
struct SidePanelEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
