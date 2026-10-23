import Foundation

/// Git on the computer that has a remote task's session. The local harness's viewer forwards each request over the
/// relay (`x.ai/remote/git`), and the other computer runs the same commands a local task's Git Graph does; branch
/// changes run there only when the person picks one.
extension AppStore {
    func remoteGit(_ request: [String: Any], conversationID id: UUID, timeout: TimeInterval = 45) async throws -> [String: Any] {
        let (client, session) = try await session(for: id)
        var params = request
        params["sessionId"] = session
        let response = try await client.request("_x.ai/remote/git", params: params, timeout: timeout)
        let result = try ExtensionResponse.unwrap(response)
        if let error = result["error"] as? String { throw DesktopError.message(error) }
        return result
    }

    /// The branches of a remote task's repository, in the same shape as `WorkspaceService.branches`.
    func remoteBranches(conversationID id: UUID) async -> GitBranchList {
        do {
            let result = try await remoteGit(["op": "branches"], conversationID: id)
            let rows = result["branches"] as? [[String: Any]] ?? []
            var local: [GitBranch] = []
            var remote: [GitBranch] = []
            for row in rows {
                let isRemote = row["isRemote"] as? Bool ?? false
                let (ahead, behind) = WorkspaceService.parseTrack(row["track"] as? String ?? "")
                let branch = GitBranch(
                    refName: row["refName"] as? String ?? "",
                    name: row["name"] as? String ?? "",
                    isRemote: isRemote,
                    isCurrent: row["current"] as? Bool ?? false,
                    upstream: (row["upstream"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    ahead: ahead, behind: behind,
                    date: (row["date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    subject: row["subject"] as? String ?? "")
                if isRemote { remote.append(branch) } else { local.append(branch) }
            }
            let localNames = Set(local.map(\.name))
            remote.removeAll { localNames.contains($0.localName) }
            if let current = local.firstIndex(where: \.isCurrent) { local.insert(local.remove(at: current), at: 0) }
            return GitBranchList(local: local, remote: remote)
        } catch {
            return GitBranchList(error: AccountErrorText.describe(error))
        }
    }

    /// The history of a remote task's repository, laid out the way `WorkspaceService.graph` lays out a local one.
    func remoteGraph(conversationID id: UUID, scope: GitGraphScope, limit: Int) async -> GitGraphLoad {
        do {
            let result = try await remoteGit(["op": "graph", "scope": scope.rawValue, "limit": limit], conversationID: id)
            guard let root = result["root"] as? String, !root.isEmpty else {
                return .notRepository(result["error"] as? String ?? "This project is not a Git repository.")
            }
            let currentBranch = result["branch"] as? String
            let headID = result["head"] as? String
            let refs = Self.remoteRefs(result["refs"])
            var commits = (result["commits"] as? [[String: Any]] ?? []).map { row in
                GitCommit(
                    id: row["id"] as? String ?? "",
                    parents: row["parents"] as? [String] ?? [],
                    author: row["author"] as? String ?? "",
                    email: row["email"] as? String ?? "",
                    date: Date(timeIntervalSince1970: (row["date"] as? NSNumber)?.doubleValue ?? 0),
                    subject: row["subject"] as? String ?? "",
                    body: row["body"] as? String ?? "",
                    refs: refs[row["id"] as? String ?? ""] ?? [])
            }.filter { !$0.id.isEmpty }
            let uncommitted = (result["uncommitted"] as? NSNumber)?.intValue ?? 0
            if uncommitted > 0, let headID {
                let subject = uncommitted == 1 ? "Uncommitted changes · 1 file" : "Uncommitted changes · \(uncommitted) files"
                commits.insert(GitCommit(id: GitCommit.uncommittedID, parents: [headID], author: "", email: "", date: Date(),
                                         subject: subject, body: ""), at: 0)
            }
            let rows = GitGraphLayout.rows(for: commits)
            let kinds = refs.values.joined().map(\.kind)
            return .loaded(GitGraph(
                root: root, scope: scope, currentBranch: currentBranch, headID: headID, commits: commits, rows: rows,
                laneCount: rows.map(\.laneCount).max() ?? 0, hasMore: result["hasMore"] as? Bool ?? false,
                branchCount: kinds.filter { $0 == .head || $0 == .local }.count,
                remoteCount: kinds.filter { $0 == .remote }.count,
                tagCount: kinds.filter { $0 == .tag }.count))
        } catch {
            let message = AccountErrorText.describe(error)
            return message.localizedCaseInsensitiveContains("not a git repository")
                ? .notRepository(message) : .failed(message)
        }
    }

    /// The files a remote commit changed, against its first parent.
    func remoteCommitFiles(conversationID id: UUID, commit: GitCommit) async -> Result<[GitCommitFile], GitHistoryError> {
        do {
            let result = try await remoteGit(["op": "files", "commit": commit.id, "parents": commit.parents], conversationID: id)
            let files = (result["files"] as? [[String: Any]] ?? []).map { row in
                GitCommitFile(
                    path: row["path"] as? String ?? "",
                    status: row["status"] as? String ?? "",
                    additions: (row["additions"] as? NSNumber)?.intValue ?? 0,
                    deletions: (row["deletions"] as? NSNumber)?.intValue ?? 0,
                    isBinary: row["isBinary"] as? Bool ?? false)
            }
            return .success(files)
        } catch {
            return .failure(GitHistoryError(message: AccountErrorText.describe(error)))
        }
    }

    /// The patch a remote commit made to one file.
    func remoteCommitDiff(conversationID id: UUID, commit: GitCommit, file: String) async -> String {
        do {
            let result = try await remoteGit(["op": "diff", "commit": commit.id, "parents": commit.parents, "file": file], conversationID: id)
            return result["text"] as? String ?? "No textual changes for this file."
        } catch {
            return AccountErrorText.describe(error)
        }
    }

    /// The working tree's changed files on the remote computer, for the graph's uncommitted row.
    func remoteWorkspaceChanges(conversationID id: UUID) async -> [GitCommitFile] {
        do {
            let result = try await remoteGit(["op": "workspace"], conversationID: id)
            return (result["changes"] as? [[String: Any]] ?? []).map { row in
                GitCommitFile(
                    path: row["path"] as? String ?? "",
                    status: FileStatusBadge.letter(row["status"] as? String ?? ""),
                    additions: (row["additions"] as? NSNumber)?.intValue ?? 0,
                    deletions: (row["deletions"] as? NSNumber)?.intValue ?? 0,
                    isBinary: row["isBinary"] as? Bool ?? false)
            }
        } catch {
            return []
        }
    }

    /// An uncommitted remote file's changes in the working tree.
    func remoteWorkspaceDiff(conversationID id: UUID, file: String) async -> String {
        do {
            let result = try await remoteGit(["op": "workspace_diff", "file": file], conversationID: id)
            return result["text"] as? String ?? "No textual changes for this file."
        } catch {
            return AccountErrorText.describe(error)
        }
    }

    /// Every ref of a remote repository, to notice commits and branch moves while the graph is open.
    func remoteRefsSignature(conversationID id: UUID) async -> String? {
        (try? await remoteGit(["op": "signature"], conversationID: id))?["text"] as? String
    }

    /// Switches a remote task's repository to `branch`; nil on success, or why git refused.
    func remoteSwitchBranch(conversationID id: UUID, to branch: GitBranch) async -> String? {
        do {
            let result = try await remoteGit(["op": "switch", "branch": branch.name, "remote": branch.isRemote], conversationID: id)
            if let name = result["branch"] as? String, !name.isEmpty {
                workspace = GitWorkspaceSnapshot(branch: name, changes: workspace.changes, isRemote: true)
            }
            return nil
        } catch {
            return AccountErrorText.describe(error)
        }
    }

    /// Creates a remote branch at its current commit and switches to it; nil on success.
    func remoteCreateBranch(conversationID id: UUID, named name: String) async -> String? {
        do {
            let result = try await remoteGit(["op": "create", "name": name], conversationID: id)
            if let branch = result["branch"] as? String, !branch.isEmpty {
                workspace = GitWorkspaceSnapshot(branch: branch, changes: workspace.changes, isRemote: true)
            }
            return nil
        } catch {
            return AccountErrorText.describe(error)
        }
    }

    /// `for-each-ref` rows as `WorkspaceService.parseRefs` groups them.
    private static func remoteRefs(_ value: Any?) -> [String: [GitRef]] {
        var refs: [String: [GitRef]] = [:]
        for row in value as? [[String: Any]] ?? [] {
            guard let commit = row["commit"] as? String, let name = row["name"] as? String else { continue }
            let kind: GitRef.Kind
            switch row["kind"] as? String {
            case "head": kind = .head
            case "remote": kind = .remote
            case "tag": kind = .tag
            default: kind = .local
            }
            let ref = GitRef(name: name, kind: kind)
            refs[commit, default: []].append(ref)
        }
        for key in refs.keys {
            refs[key]?.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        }
        return refs
    }
}
