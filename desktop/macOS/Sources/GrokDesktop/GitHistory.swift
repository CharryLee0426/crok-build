import Foundation

// MARK: - Branches

/// A branch the composer's branch picker can switch to.
struct GitBranch: Identifiable, Hashable, Sendable {
    var id: String { refName }
    /// `refs/heads/main`, or `refs/remotes/origin/main`.
    let refName: String
    /// `main`, or `origin/main` for a remote branch.
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let date: Date?
    let subject: String

    /// The local branch `git switch --track` makes from a remote branch: its name without the remote.
    var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

struct GitBranchList: Equatable, Sendable {
    /// The current branch first, then the most recently committed.
    var local: [GitBranch] = []
    /// Remote branches without a local branch of the same name, most recent first.
    var remote: [GitBranch] = []
    var error: String?

    var current: GitBranch? { local.first { $0.isCurrent } }
}

// MARK: - History

/// Which commits the graph shows.
enum GitGraphScope: String, CaseIterable, Identifiable, Sendable {
    case all, current
    var id: String { rawValue }
    var title: String { self == .all ? "All branches" : "Current branch" }
}

/// A branch or tag pointing at a commit.
struct GitRef: Hashable, Sendable {
    enum Kind: Int, Sendable { case head, local, remote, tag }
    let name: String
    let kind: Kind
}

struct GitCommit: Identifiable, Hashable, Sendable {
    /// The full hash, or `uncommittedID` for the working tree's changes.
    let id: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    let body: String
    var refs: [GitRef] = []

    static let uncommittedID = "*uncommitted"
    var isUncommitted: Bool { id == Self.uncommittedID }
    var isMerge: Bool { parents.count > 1 }
    var shortID: String { isUncommitted ? "*" : String(id.prefix(7)) }
    var message: String { body.isEmpty ? subject : subject + "\n\n" + body }
}

/// A file a commit changed, against its first parent.
struct GitCommitFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    /// Git's status letter: `A`, `M`, `D`, or `T`.
    let status: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}

/// A loaded page of history, laid out as a graph.
struct GitGraph: Equatable, Sendable {
    var root: String
    var currentBranch: String?
    var headID: String?
    var commits: [GitCommit]
    var rows: [GitGraphRow]
    var laneCount: Int
    /// More commits exist past the loaded limit.
    var hasMore: Bool
    var branchCount: Int
    var remoteCount: Int
    var tagCount: Int
}

enum GitGraphLoad: Equatable, Sendable {
    case notRepository(String)
    case loaded(GitGraph)
    case failed(String)
}

// MARK: - Graph layout

/// One commit's slice of the graph. Lanes are columns; each row draws the lanes crossing it,
/// the commit's node in `column`, and the curves joining lanes to that node.
struct GitGraphRow: Equatable, Sendable {
    struct Edge: Equatable, Sendable {
        var lane: Int
        var color: Int
        /// The lane starts here, for a merge parent no other lane was waiting for.
        var isNew = false
    }

    var column: Int
    /// Palette index of the node and of its lane.
    var color: Int
    /// A lane arrives from the row above (false for a branch tip).
    var up: Bool
    /// The lane continues to the row below (false for a root commit).
    var down: Bool
    /// Each lane's colour where it enters the row from above; nil for an empty lane.
    var above: [Int?]
    /// Each lane's colour where it leaves the row below.
    var below: [Int?]
    /// Other lanes that end at this commit: children on other branches, drawn from the top into the node.
    var mergesIn: [Edge]
    /// Lanes toward the commit's other parents, drawn from the node to the bottom.
    var branchesOut: [Edge]

    var laneCount: Int { max(above.count, below.count, column + 1) }

    /// A lane that runs straight through the row without touching its node.
    func passesThrough(_ lane: Int) -> Bool {
        lane != column && lane < above.count && above[lane] != nil && !mergesIn.contains { $0.lane == lane }
    }
}

/// Assigns commits to lanes. Commits must come children first (`git log --topo-order`).
/// The terminal's `/git-graph` (`src/git_graph/layout.rs`) uses the same rules.
enum GitGraphLayout {
    static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        struct Lane {
            var target: String
            var color: Int
        }
        var lanes: [Lane?] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let before = lanes
            let column: Int
            let isTip: Bool
            if let index = lanes.firstIndex(where: { $0?.target == commit.id }) {
                column = index
                isTip = false
            } else {
                column = lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
                if column == lanes.count { lanes.append(nil) }
                lanes[column] = Lane(target: commit.id, color: nextColor)
                nextColor += 1
                isTip = true
            }
            let color = lanes[column]?.color ?? 0
            var mergesIn: [GitGraphRow.Edge] = []
            for index in lanes.indices where index != column {
                if let lane = lanes[index], lane.target == commit.id {
                    mergesIn.append(.init(lane: index, color: lane.color))
                    lanes[index] = nil
                }
            }
            if let first = commit.parents.first { lanes[column]?.target = first } else { lanes[column] = nil }
            var branchesOut: [GitGraphRow.Edge] = []
            for parent in commit.parents.dropFirst() {
                if let index = lanes.firstIndex(where: { $0?.target == parent }), let lane = lanes[index] {
                    branchesOut.append(.init(lane: index, color: lane.color))
                    continue
                }
                // A new lane takes a slot that was empty above and below this row, so a lane
                // ending here is never mistaken for one continuing.
                var index = 0
                while index < lanes.count, lanes[index] != nil || index == column || (index < before.count && before[index] != nil) {
                    index += 1
                }
                if index == lanes.count { lanes.append(nil) }
                lanes[index] = Lane(target: parent, color: nextColor)
                branchesOut.append(.init(lane: index, color: nextColor, isNew: true))
                nextColor += 1
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(GitGraphRow(column: column, color: color, up: !isTip, down: !commit.parents.isEmpty,
                                    above: before.map { $0?.color }, below: lanes.map { $0?.color },
                                    mergesIn: mergesIn, branchesOut: branchesOut))
        }
        return rows
    }
}

// MARK: - Reading and switching

extension WorkspaceService {
    /// Local branches, and remote branches that have no local branch yet.
    func branches(path: String) async -> GitBranchList {
        await Task.detached(priority: .userInitiated) {
            let format = "%(refname)%00%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(HEAD)%00%(contents:subject)"
            let result = Self.git(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"], at: path, includeErrors: false)
            guard result.code == 0 else {
                let message = Self.git(["rev-parse", "--show-toplevel"], at: path).text.trimmingCharacters(in: .whitespacesAndNewlines)
                return GitBranchList(error: message.isEmpty ? "Could not list branches." : message)
            }
            return Self.parseBranches(result.text)
        }.value
    }

    /// Switches to `branch`; a remote branch gets a local branch tracking it.
    /// Returns nil on success, or git's explanation.
    func switchBranch(path: String, to branch: GitBranch) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard !branch.name.hasPrefix("-") else { return "“\(branch.name)” is not a branch name." }
            let arguments = branch.isRemote ? ["switch", "--track", branch.name] : ["switch", branch.name]
            let result = Self.git(arguments, at: path)
            return result.code == 0 ? nil : Self.message(result.text, fallback: "Could not switch to \(branch.name).")
        }.value
    }

    /// Creates `name` at the current commit and switches to it. Returns nil on success.
    func createBranch(path: String, name: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasPrefix("-"),
                  Self.git(["check-ref-format", "--branch", name], at: path).code == 0 else {
                return "“\(name)” is not a valid branch name."
            }
            let result = Self.git(["switch", "-c", name], at: path)
            return result.code == 0 ? nil : Self.message(result.text, fallback: "Could not create \(name).")
        }.value
    }

    /// Up to `limit` commits in graph order, with their branches and tags. `uncommitted` files
    /// in the working tree add a row above the current commit.
    func graph(path: String, scope: GitGraphScope, limit: Int, uncommitted: Int) async -> GitGraphLoad {
        await Task.detached(priority: .userInitiated) {
            Self.graphSynchronously(path: path, scope: scope, limit: limit, uncommitted: uncommitted)
        }.value
    }

    /// The files `commit` changed, against its first parent.
    func commitFiles(path: String, commit: GitCommit) async -> Result<[GitCommitFile], GitHistoryError> {
        await Task.detached(priority: .userInitiated) {
            let range = Self.diffRange(commit)
            let common = ["diff-tree", "-r", "--no-commit-id", "--no-renames", "--no-ext-diff", "--no-textconv", "-z"]
            let status = Self.git(common + ["--name-status"] + range, at: path, includeErrors: false)
            let numstat = Self.git(common + ["--numstat"] + range, at: path, includeErrors: false)
            guard status.code == 0, numstat.code == 0 else { return .failure(GitHistoryError(message: "Could not read the files in \(commit.shortID).")) }
            return .success(Self.parseCommitFiles(status: status.data, numstat: numstat.data))
        }.value
    }

    /// The patch `commit` made to `file`.
    func commitDiff(path: String, commit: GitCommit, file: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { return "The selected file is outside the repository." }
            let arguments = ["diff-tree", "-p", "-r", "--no-commit-id", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color",
                             "--src-prefix=a/", "--dst-prefix=b/"] + Self.diffRange(commit) + ["--", file]
            let result = Self.git(arguments, at: path, limit: 1_024 * 1_024)
            guard result.code == 0 else { return result.text }
            if result.data.isEmpty { return "No textual changes for this file." }
            return result.text + (result.truncated ? "\n\n[Preview truncated at 1 MiB]" : "")
        }.value
    }

    /// Every ref and HEAD, as one string that changes whenever any of them moves.
    func refsSignature(path: String) async -> String? {
        await Task.detached(priority: .utility) {
            let result = Self.git(["show-ref", "--head"], at: path, includeErrors: false)
            // show-ref exits 1 in a repository with no refs yet.
            return result.code <= 1 ? result.text : nil
        }.value
    }

    private static func diffRange(_ commit: GitCommit) -> [String] {
        commit.parents.first.map { [$0, commit.id] } ?? ["--root", commit.id]
    }

    private static func message(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func graphSynchronously(path: String, scope: GitGraphScope, limit: Int, uncommitted: Int) -> GitGraphLoad {
        let rootResult = repositoryRoot(at: path)
        guard rootResult.code == 0 else {
            return .notRepository(rootResult.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let root = rootResult.text.trimmingCharacters(in: .newlines)
        let head = git(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, includeErrors: false)
        let headID = head.code == 0 ? head.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let symbolic = git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root, includeErrors: false)
        let currentBranch = symbolic.code == 0 ? symbolic.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let refsResult = git(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
                             at: root, includeErrors: false)
        let refs = refsResult.code == 0 ? parseRefs(refsResult.text, currentBranch: currentBranch) : [:]

        var revisions: [String]
        switch scope {
        case .all: revisions = ["--branches", "--remotes", "--tags"] + (headID == nil ? [] : ["HEAD"])
        case .current: revisions = headID == nil ? [] : ["HEAD"]
        }
        var commits: [GitCommit] = []
        var hasMore = false
        if !revisions.isEmpty && (headID != nil || !refs.isEmpty) {
            let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b"
            let log = git(["-c", "log.showSignature=false", "log", "--topo-order", "--no-color", "-z", "--max-count=\(limit + 1)", format] + revisions + ["--"],
                          at: root, limit: 64 * 1_024 * 1_024, includeErrors: false)
            guard log.code == 0 else {
                let error = git(["log", "--max-count=1"] + revisions + ["--"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(error.isEmpty ? "Could not read the history." : error)
            }
            commits = parseLog(log.data, refs: refs)
            if commits.count > limit { commits.removeLast(commits.count - limit); hasMore = true }
        }
        if uncommitted > 0, let headID {
            let subject = uncommitted == 1 ? "Uncommitted changes · 1 file" : "Uncommitted changes · \(uncommitted) files"
            commits.insert(GitCommit(id: GitCommit.uncommittedID, parents: [headID], author: "", email: "", date: Date(), subject: subject, body: ""), at: 0)
        }
        let rows = GitGraphLayout.rows(for: commits)
        let kinds = refs.values.joined().map(\.kind)
        return .loaded(GitGraph(root: root, currentBranch: currentBranch, headID: headID, commits: commits, rows: rows,
                                laneCount: rows.map(\.laneCount).max() ?? 0, hasMore: hasMore,
                                branchCount: kinds.filter { $0 == .head || $0 == .local }.count,
                                remoteCount: kinds.filter { $0 == .remote }.count,
                                tagCount: kinds.filter { $0 == .tag }.count))
    }

    // MARK: Parsing

    static func parseBranches(_ text: String) -> GitBranchList {
        var local: [GitBranch] = []
        var remote: [GitBranch] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\u{0}", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { continue }
            let refName = fields[0]
            let isRemote = refName.hasPrefix("refs/remotes/")
            // `origin/HEAD` points at another remote branch and is not one itself.
            if isRemote && refName.hasSuffix("/HEAD") { continue }
            let (ahead, behind) = parseTrack(fields[3])
            let branch = GitBranch(refName: refName, name: fields[1], isRemote: isRemote, isCurrent: fields[5] == "*",
                                   upstream: fields[2].isEmpty ? nil : fields[2], ahead: ahead, behind: behind,
                                   date: TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) }, subject: fields[6])
            if isRemote { remote.append(branch) } else { local.append(branch) }
        }
        let localNames = Set(local.map(\.name))
        remote.removeAll { localNames.contains($0.localName) }
        if let current = local.firstIndex(where: \.isCurrent) { local.insert(local.remove(at: current), at: 0) }
        return GitBranchList(local: local, remote: remote)
    }

    /// `ahead 2, behind 1`, `ahead 2`, `behind 1`, `gone`, or empty.
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int) {
        var ahead = 0, behind = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }

    /// Commit hash to the branches and tags pointing at it, current branch first, then local
    /// branches, remote branches, and tags. Annotated tags point at the commit they tag.
    static func parseRefs(_ text: String, currentBranch: String?) -> [String: [GitRef]] {
        var refs: [String: [GitRef]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\u{0}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let commit = fields[1].isEmpty ? fields[0] : fields[1]
            let refName = fields[2]
            let ref: GitRef
            if refName.hasPrefix("refs/heads/") {
                let name = String(refName.dropFirst("refs/heads/".count))
                ref = GitRef(name: name, kind: name == currentBranch ? .head : .local)
            } else if refName.hasPrefix("refs/remotes/") {
                guard !refName.hasSuffix("/HEAD") else { continue }
                ref = GitRef(name: String(refName.dropFirst("refs/remotes/".count)), kind: .remote)
            } else if refName.hasPrefix("refs/tags/") {
                ref = GitRef(name: String(refName.dropFirst("refs/tags/".count)), kind: .tag)
            } else {
                continue
            }
            refs[commit, default: []].append(ref)
        }
        for key in refs.keys {
            refs[key]?.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        }
        return refs
    }

    /// `git log -z` records of hash, parents, author, email, time, subject, and body.
    static func parseLog(_ data: Data, refs: [String: [GitRef]]) -> [GitCommit] {
        var commits: [GitCommit] = []
        for record in data.split(separator: 0) {
            let fields = record.split(separator: 0x1F, maxSplits: 6, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 7 else { continue }
            // With -z, git separates records with a NUL but may keep the newline before it.
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            commits.append(GitCommit(id: id, parents: fields[1].split(separator: " ").map(String.init),
                                     author: fields[2], email: fields[3],
                                     date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                                     subject: fields[5], body: fields[6].trimmingCharacters(in: .whitespacesAndNewlines),
                                     refs: refs[id] ?? []))
        }
        return commits
    }

    /// Joins `--name-status -z` (status NUL path NUL) with `--numstat -z` (added TAB removed TAB path NUL).
    static func parseCommitFiles(status: Data, numstat: Data) -> [GitCommitFile] {
        var counts: [String: (Int, Int, Bool)] = [:]
        for field in numstat.split(separator: 0) {
            let columns = field.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let added = String(decoding: columns[0], as: UTF8.self)
            let removed = String(decoding: columns[1], as: UTF8.self)
            let path = String(decoding: columns[2], as: UTF8.self).trimmingCharacters(in: .newlines)
            counts[path] = (Int(added) ?? 0, Int(removed) ?? 0, added == "-" || removed == "-")
        }
        let fields = status.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [GitCommitFile] = []
        var index = 0
        while index + 1 < fields.count {
            let code = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let path = fields[index + 1]
            index += 2
            guard let letter = code.first, !path.isEmpty else { continue }
            let (additions, deletions, binary) = counts[path] ?? (0, 0, false)
            files.append(GitCommitFile(path: path, status: String(letter), additions: additions, deletions: deletions, isBinary: binary))
        }
        return files
    }
}

struct GitHistoryError: Error, Equatable, Sendable {
    let message: String
}

enum GitDateFormat {
    /// "just now", "5m ago", "3h ago", "2d ago", then "Mar 4" or "Mar 4, 2023". A date in the
    /// future (a skewed clock) is shown as a date.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds >= 0 && seconds < 60 { return "just now" }
        if seconds >= 0 && seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds >= 0 && seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        if seconds >= 0 && seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    static func full(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
