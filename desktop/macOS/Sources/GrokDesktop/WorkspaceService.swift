import Foundation

struct GitFileChange: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    /// Git's two-column index/worktree status, for example `M `, ` M`, or `??`.
    let status: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}

struct GitWorkspaceSnapshot: Equatable, Sendable {
    /// The `branch` of a project outside Git. Views translate it; the data keeps the one spelling.
    static let noRepository = "No repository"

    let branch: String
    let changes: [GitFileChange]
    let rootPath: String?
    let error: String?

    init(branch: String, changes: [GitFileChange], rootPath: String? = nil, error: String? = nil) {
        self.branch = branch
        self.changes = changes
        self.rootPath = rootPath
        self.error = error
    }
}

/// Git operations run away from the main actor. Arguments are always passed directly to git;
/// workspace paths and file names are never evaluated by a shell. Everything here only reads,
/// except the branch commands in `GitHistory.swift`.
struct WorkspaceService: Sendable {
    func inspect(path: String) async -> GitWorkspaceSnapshot {
        await Task.detached(priority: .utility) {
            Self.inspectSynchronously(path: path)
        }.value
    }

    func diff(path: String, file: String) async -> String {
        await Task.detached(priority: .utility) {
            Self.diffSynchronously(path: path, file: file)
        }.value
    }

    /// The files under `path`, relative to it: in a repository, tracked and untracked files
    /// without ignored or deleted ones; elsewhere (or in a folder Git ignores entirely), what is
    /// on disk, skipping build output.
    func listFiles(path: String, limit: Int = 50_000) async -> (files: [String], truncated: Bool) {
        await Task.detached(priority: .userInitiated) {
            if let listed = Self.gitFiles(path: path, limit: limit), !listed.files.isEmpty { return listed }
            return Self.diskFiles(path: path, limit: limit)
        }.value
    }

    private static func gitFiles(path: String, limit: Int) -> (files: [String], truncated: Bool)? {
        let listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], at: path, limit: 64 * 1_024 * 1_024)
        guard listed.code == 0 else { return nil }
        let deletedResult = git(["ls-files", "-z", "--deleted"], at: path)
        let deleted = deletedResult.code == 0 ? Set(names(deletedResult.data)) : []
        var seen = Set<String>()
        var files: [String] = []
        for name in names(listed.data) where !deleted.contains(name) && seen.insert(name).inserted {
            if files.count == limit { return (files, true) }
            files.append(name)
        }
        return (files, listed.truncated)
    }

    private static func names(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Directories that hold dependencies or build output rather than the project's own files.
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "build", "dist", "target", "DerivedData", "Pods", ".venv", "venv", "__pycache__", ".next", ".swiftpm"]

    private static func diskFiles(path: String, limit: Int) -> (files: [String], truncated: Bool) {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return ([], false) }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent == ".DS_Store" { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            if files.count == limit { return (files, true) }
            files.append(String(full.dropFirst(prefix.count)))
        }
        return (files, false)
    }

    struct GitResult {
        let code: Int32
        let data: Data
        let truncated: Bool
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    private struct Counts {
        var additions = 0
        var deletions = 0
        var isBinary = false
    }

    /// Runs git with `arguments` in `path`. Its error output is included unless `includeErrors`
    /// is false, which output that is parsed rather than shown should ask for.
    static func git(_ arguments: [String], at path: String, limit: Int = 16 * 1_024 * 1_024, includeErrors: Bool = true) -> GitResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.quotePath=false", "--literal-pathspecs", "-C", path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // A workspace opened from Finder must not inherit a different repository
        // selected by a developer shell's GIT_DIR/GIT_WORK_TREE variables.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment
        process.standardOutput = output
        process.standardError = includeErrors ? output : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return GitResult(code: -1, data: Data(error.localizedDescription.utf8), truncated: false)
        }
        // Drain the pipe while git runs, even after reaching the display limit.
        // This avoids both pipe-buffer deadlocks and unbounded diff allocations.
        var data = Data()
        var truncated = false
        while let chunk = try? output.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            let remaining = max(0, limit - data.count)
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        return GitResult(code: process.terminationStatus, data: data, truncated: truncated)
    }

    static func repositoryRoot(at path: String) -> GitResult {
        git(["rev-parse", "--show-toplevel"], at: path)
    }

    private static func inspectSynchronously(path: String) -> GitWorkspaceSnapshot {
        let rootResult = repositoryRoot(at: path)
        guard rootResult.code == 0 else {
            return GitWorkspaceSnapshot(branch: GitWorkspaceSnapshot.noRepository, changes: [], error: rootResult.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let root = rootResult.text.trimmingCharacters(in: .newlines)
        let symbolicBranch = git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch: String
        if symbolicBranch.code == 0 {
            branch = symbolicBranch.text.trimmingCharacters(in: .newlines)
        } else {
            let commit = git(["rev-parse", "--short", "HEAD"], at: root)
            branch = commit.code == 0 ? "Detached · \(commit.text.trimmingCharacters(in: .newlines))" : "HEAD"
        }
        let status = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
        guard status.code == 0, !status.truncated else {
            return GitWorkspaceSnapshot(branch: branch, changes: [], rootPath: root, error: status.truncated ? "This repository has too many changes to display." : status.text)
        }
        var counts: [String: Counts] = [:]
        for arguments in [
            ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z"],
            ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--numstat", "-z"],
        ] {
            let result = git(arguments, at: root)
            if result.code == 0 { mergeNumstat(result.data, into: &counts) }
        }
        let entries = status.data.split(separator: 0, omittingEmptySubsequences: false)
        var changes: [GitFileChange] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            guard entry.count >= 4 else { continue }
            let bytes = Array(entry.prefix(3))
            let code = String(decoding: bytes.prefix(2), as: UTF8.self)
            let filename = String(decoding: entry.dropFirst(3), as: UTF8.self)
            // In porcelain -z the destination is first; rename/copy source follows
            // as a separate NUL-terminated item (which is not another change).
            if bytes[0] == 82 || bytes[0] == 67 || bytes[1] == 82 || bytes[1] == 67 {
                index += 1
            }
            let fileCounts = code == "??" ? untrackedCounts(root: root, file: filename) : counts[filename, default: Counts()]
            changes.append(GitFileChange(path: filename, status: code, additions: fileCounts.additions, deletions: fileCounts.deletions, isBinary: fileCounts.isBinary))
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return GitWorkspaceSnapshot(branch: branch, changes: changes, rootPath: root)
    }

    private static func mergeNumstat(_ data: Data, into counts: inout [String: Counts]) {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            let columns = field.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            var filename = String(decoding: columns[2], as: UTF8.self)
            if filename.isEmpty {
                // A rename record is: added TAB removed TAB NUL old NUL new NUL.
                guard index + 1 < fields.count else { break }
                filename = String(decoding: fields[index + 1], as: UTF8.self)
                index += 2
            }
            let added = String(decoding: columns[0], as: UTF8.self)
            let removed = String(decoding: columns[1], as: UTF8.self)
            var value = counts[filename, default: Counts()]
            value.additions += Int(added) ?? 0
            value.deletions += Int(removed) ?? 0
            value.isBinary = value.isBinary || added == "-" || removed == "-"
            counts[filename] = value
        }
    }

    private static func untrackedCounts(root: String, file: String) -> Counts {
        let url = URL(fileURLWithPath: root).appendingPathComponent(file)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return Counts(additions: 1)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Counts() }
        defer { try? handle.close() }
        var lines = 0
        var lastByte: UInt8?
        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            if chunk.contains(0) { return Counts(isBinary: true) }
            lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            lastByte = chunk.last
        }
        if let lastByte, lastByte != 10 { lines += 1 }
        return Counts(additions: lines)
    }

    private static func diffSynchronously(path: String, file: String) -> String {
        let rootResult = repositoryRoot(at: path)
        guard rootResult.code == 0 else { return rootResult.text }
        let root = rootResult.text.trimmingCharacters(in: .newlines)
        // `--literal-pathspecs` prevents filenames containing *, [, or :(...) from
        // selecting other files. Reject traversal before touching untracked files.
        guard !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            return "The selected file is outside the workspace."
        }
        let common = ["--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        let staged = git(["diff", "--cached"] + common + ["--", file], at: root, limit: 1_024 * 1_024)
        let unstaged = git(["diff"] + common + ["--", file], at: root, limit: 1_024 * 1_024)
        guard staged.code == 0, unstaged.code == 0 else {
            return staged.code != 0 ? staged.text : unstaged.text
        }
        var sections: [String] = []
        if !staged.data.isEmpty { sections.append("Staged changes\n\n" + rendered(staged)) }
        if !unstaged.data.isEmpty { sections.append("Working tree changes\n\n" + rendered(unstaged)) }
        if !sections.isEmpty { return sections.joined(separator: "\n\n") }
        let untracked = git(["ls-files", "--others", "--exclude-standard", "-z", "--", file], at: root)
        guard untracked.code == 0, !untracked.data.isEmpty else { return "No textual changes for this file." }
        let url = URL(fileURLWithPath: root).appendingPathComponent(file)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return "New symbolic link\n\n+\(target)"
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Unable to read this untracked file." }
        defer { try? handle.close() }
        guard let contents = try? handle.read(upToCount: 1_024 * 1_024 + 1) else { return "Unable to read this untracked file." }
        guard !contents.contains(0), let text = String(data: contents.prefix(1_024 * 1_024), encoding: .utf8) else {
            return "New binary file: \(file)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let patch = lines.enumerated().compactMap { offset, line in
            offset == lines.count - 1 && line.isEmpty ? nil : "+\(line)"
        }.joined(separator: "\n")
        return "New file: \(file)\n\n--- /dev/null\n+++ b/\(file)\n" + patch + (contents.count > 1_024 * 1_024 ? "\n\n[Preview truncated at 1 MiB]" : "")
    }

    private static func rendered(_ result: GitResult) -> String {
        result.text + (result.truncated ? "\n\n[Preview truncated at 1 MiB]" : "")
    }
}
