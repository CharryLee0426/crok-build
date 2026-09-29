import Foundation
import XCTest
@testable import GrokDesktop

final class GitGraphLayoutTests: XCTestCase {
    private func commit(_ id: String, _ parents: String...) -> GitCommit {
        GitCommit(id: id, parents: parents, author: "A", email: "a@example.invalid", date: Date(timeIntervalSince1970: 0), subject: id, body: "")
    }

    func testLinearHistoryStaysInOneLane() {
        let rows = GitGraphLayout.rows(for: [commit("c", "b"), commit("b", "a"), commit("a")])
        XCTAssertEqual(rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(rows.map(\.color), [0, 0, 0])
        XCTAssertEqual(rows.map(\.up), [false, true, true])
        XCTAssertEqual(rows.map(\.down), [true, true, false])
        XCTAssertEqual(rows[2].below, [], "a root commit ends its lane")
        XCTAssertTrue(rows.allSatisfy { $0.mergesIn.isEmpty && $0.branchesOut.isEmpty })
    }

    func testMergeOpensALaneThatJoinsBackAtTheForkPoint() {
        // m merges feature (f2 → f1) into main (m1); both fork from base.
        let rows = GitGraphLayout.rows(for: [
            commit("m", "m1", "f2"), commit("f2", "f1"), commit("m1", "base"), commit("f1", "base"), commit("base"),
        ])
        XCTAssertEqual(rows[0].column, 0)
        XCTAssertEqual(rows[0].branchesOut, [GitGraphRow.Edge(lane: 1, color: 1, isNew: true)])
        XCTAssertEqual(rows[0].below, [0, 1])
        XCTAssertEqual(rows[1].column, 1, "the merged branch continues in its own lane")
        XCTAssertEqual(rows[1].color, 1)
        XCTAssertTrue(rows[1].passesThrough(0))
        XCTAssertEqual(rows[2].column, 0)
        XCTAssertTrue(rows[2].passesThrough(1))
        XCTAssertEqual(rows[3].column, 1)
        // base is the first parent of both lanes: lane 1 ends by joining lane 0.
        XCTAssertEqual(rows[4].column, 0)
        XCTAssertEqual(rows[4].mergesIn, [GitGraphRow.Edge(lane: 1, color: 1)])
        XCTAssertFalse(rows[4].passesThrough(1))
        XCTAssertEqual(rows[4].below, [])
    }

    func testBranchTipsGetNewLanesAndColoursFollowTheFirstParentChain() {
        let rows = GitGraphLayout.rows(for: [commit("x", "b"), commit("y", "b"), commit("b", "a"), commit("a")])
        XCTAssertEqual(rows.map(\.column), [0, 1, 0, 0])
        XCTAssertFalse(rows[1].up, "a second tip starts a lane")
        XCTAssertEqual(rows[1].color, 1)
        XCTAssertEqual(rows[2].mergesIn.map(\.lane), [1], "two children converge on their parent")
        XCTAssertEqual(rows[2].color, 0)
        XCTAssertEqual(rows[3].color, 0)
    }

    func testOctopusMergeOpensALaneForEachParent() {
        let rows = GitGraphLayout.rows(for: [
            commit("o", "p1", "p2", "p3"), commit("p3", "r"), commit("p2", "r"), commit("p1", "r"), commit("r"),
        ])
        XCTAssertEqual(rows[0].branchesOut.map(\.lane), [1, 2])
        XCTAssertEqual(rows[0].branchesOut.map(\.isNew), [true, true])
        XCTAssertEqual(Set(rows[0].branchesOut.map(\.color)).count, 2)
        XCTAssertEqual(rows[1].column, 2)
        XCTAssertEqual(rows[2].column, 1)
        XCTAssertEqual(rows[3].column, 0)
        XCTAssertEqual(rows[4].mergesIn.map(\.lane).sorted(), [1, 2])
    }

    func testMergeIntoAnExistingLaneReusesIt() {
        // Both merges take `side` as a second parent; the second one finds its lane already open.
        let rows = GitGraphLayout.rows(for: [
            commit("m2", "m1", "side"), commit("m1", "base", "side"), commit("side", "base"), commit("base"),
        ])
        XCTAssertEqual(rows[0].branchesOut, [GitGraphRow.Edge(lane: 1, color: 1, isNew: true)])
        XCTAssertEqual(rows[1].branchesOut, [GitGraphRow.Edge(lane: 1, color: 1, isNew: false)])
        XCTAssertTrue(rows[1].passesThrough(1))
    }

    func testSlotFreedOnARowIsNotReusedOnThatRow() {
        // At `b`, lane 1 (from tip y) ends; b's second parent must not start in that same slot.
        let rows = GitGraphLayout.rows(for: [commit("x", "b"), commit("y", "b"), commit("b", "a", "z"), commit("z"), commit("a")])
        XCTAssertEqual(rows[2].mergesIn.map(\.lane), [1])
        XCTAssertEqual(rows[2].branchesOut.map(\.lane), [2])
        XCTAssertEqual(rows[2].below, [0, nil, 2])
        XCTAssertEqual(rows[3].column, 2)
        XCTAssertEqual(rows[3].laneCount, 3)
    }

    func testHistoryCutAtTheLimitLeavesLanesOpen() {
        let rows = GitGraphLayout.rows(for: [commit("c", "b"), commit("b", "a")])
        XCTAssertEqual(rows.last?.below, [0])
        XCTAssertTrue(rows.last?.down == true)
    }
}

final class GitHistoryParsingTests: XCTestCase {
    func testBranchesPutTheCurrentFirstAndHideRemotesThatAreAlreadyLocal() {
        let text = [
            "refs/heads/feature\u{0}feature\u{0}\u{0}\u{0}200\u{0} \u{0}Add feature",
            "refs/heads/main\u{0}main\u{0}origin/main\u{0}ahead 2, behind 1\u{0}100\u{0}*\u{0}Initial",
            "refs/remotes/origin/HEAD\u{0}origin\u{0}\u{0}\u{0}100\u{0} \u{0}Initial",
            "refs/remotes/origin/main\u{0}origin/main\u{0}\u{0}\u{0}100\u{0} \u{0}Initial",
            "refs/remotes/origin/review\u{0}origin/review\u{0}\u{0}\u{0}150\u{0} \u{0}Review fixes",
        ].joined(separator: "\n")
        let list = WorkspaceService.parseBranches(text)
        XCTAssertEqual(list.local.map(\.name), ["main", "feature"])
        XCTAssertEqual(list.current?.name, "main")
        XCTAssertEqual(list.local[0].ahead, 2)
        XCTAssertEqual(list.local[0].behind, 1)
        XCTAssertEqual(list.local[0].upstream, "origin/main")
        XCTAssertEqual(list.remote.map(\.name), ["origin/review"])
        XCTAssertEqual(list.remote.first?.localName, "review")
        XCTAssertEqual(list.remote.first?.subject, "Review fixes")
    }

    func testTrackingText() {
        XCTAssertTrue(WorkspaceService.parseTrack("") == (0, 0))
        XCTAssertTrue(WorkspaceService.parseTrack("gone") == (0, 0))
        XCTAssertTrue(WorkspaceService.parseTrack("ahead 3") == (3, 0))
        XCTAssertTrue(WorkspaceService.parseTrack("behind 4") == (0, 4))
        XCTAssertTrue(WorkspaceService.parseTrack("ahead 1, behind 12") == (1, 12))
    }

    func testRefsPeelAnnotatedTagsAndSortTheCurrentBranchFirst() {
        let text = [
            "aaa\u{0}\u{0}refs/heads/main",
            "aaa\u{0}\u{0}refs/heads/alpha",
            "aaa\u{0}\u{0}refs/remotes/origin/main",
            "aaa\u{0}\u{0}refs/remotes/origin/HEAD",
            "ttt\u{0}bbb\u{0}refs/tags/v1.0",
            "bbb\u{0}\u{0}refs/tags/light",
        ].joined(separator: "\n")
        let refs = WorkspaceService.parseRefs(text, currentBranch: "main")
        XCTAssertEqual(refs["aaa"], [GitRef(name: "main", kind: .head), GitRef(name: "alpha", kind: .local), GitRef(name: "origin/main", kind: .remote)])
        XCTAssertEqual(refs["bbb"], [GitRef(name: "light", kind: .tag), GitRef(name: "v1.0", kind: .tag)])
        XCTAssertNil(refs["ttt"])
    }

    func testLogRecordsKeepMultilineBodies() {
        let record1 = "aaa\u{1F}bbb ccc\u{1F}Ada\u{1F}ada@example.invalid\u{1F}1700000000\u{1F}Merge feature\u{1F}Body line 1\nBody line 2\n"
        let record2 = "\nbbb\u{1F}\u{1F}Bob\u{1F}bob@example.invalid\u{1F}1600000000\u{1F}Root\u{1F}"
        let data = Data((record1 + "\u{0}" + record2 + "\u{0}").utf8)
        let commits = WorkspaceService.parseLog(data, refs: ["aaa": [GitRef(name: "main", kind: .head)]])
        XCTAssertEqual(commits.map(\.id), ["aaa", "bbb"])
        XCTAssertEqual(commits[0].parents, ["bbb", "ccc"])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[0].body, "Body line 1\nBody line 2")
        XCTAssertEqual(commits[0].refs.first?.name, "main")
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertEqual(commits[1].date, Date(timeIntervalSince1970: 1_600_000_000))
    }

    func testCommitFilesJoinStatusAndCounts() {
        let status = Data("M\u{0}src/a.swift\u{0}A\u{0}image.png\u{0}D\u{0}old name.txt\u{0}".utf8)
        let numstat = Data("3\t1\tsrc/a.swift\u{0}-\t-\timage.png\u{0}0\t7\told name.txt\u{0}".utf8)
        let files = WorkspaceService.parseCommitFiles(status: status, numstat: numstat)
        XCTAssertEqual(files, [
            GitCommitFile(path: "src/a.swift", status: "M", additions: 3, deletions: 1, isBinary: false),
            GitCommitFile(path: "image.png", status: "A", additions: 0, deletions: 0, isBinary: true),
            GitCommitFile(path: "old name.txt", status: "D", additions: 0, deletions: 7, isBinary: false),
        ])
    }

    func testRefBadgesFoldMatchingRemotesIntoTheirBranch() {
        let badges = GitRefBadge.badges(for: [
            GitRef(name: "main", kind: .head), GitRef(name: "origin/main", kind: .remote),
            GitRef(name: "upstream/main", kind: .remote), GitRef(name: "origin/other", kind: .remote), GitRef(name: "v2", kind: .tag),
        ])
        XCTAssertEqual(badges.map(\.ref.name), ["main", "origin/other", "v2"])
        XCTAssertEqual(badges[0].remotes, ["origin", "upstream"])
    }

    func testTheSameBranchOnSeveralRemotesIsOneBadge() {
        let badges = GitRefBadge.badges(for: [
            GitRef(name: "fork/push-gateway", kind: .remote), GitRef(name: "origin/push-gateway", kind: .remote),
            GitRef(name: "fork/solo", kind: .remote),
        ])
        XCTAssertEqual(badges.map(\.ref.name), ["push-gateway", "fork/solo"])
        XCTAssertEqual(badges[0].remotes, ["fork", "origin"])
        XCTAssertEqual(badges[0].target, GitRef(name: "origin/push-gateway", kind: .remote), "a checkout tracks origin when it has the branch")
        XCTAssertEqual(badges[0].label, "push-gateway (fork, origin)")
        XCTAssertEqual(badges[1].target, GitRef(name: "fork/solo", kind: .remote))
    }

    func testColumnLayoutKeepsFewLanesAtFullWidth() {
        let layout = GitGraphColumnLayout.make(width: 1000, lanes: 3)
        XCTAssertEqual(layout.laneWidth, 16)
        XCTAssertEqual(layout.visibleLanes, 3)
        XCTAssertFalse(layout.isClipped)
        XCTAssertEqual(layout.graph, GitGraphColumnLayout.minGraph, "two or three lanes still leave room for the column title")
        XCTAssertGreaterThan(layout.author, 0)
        XCTAssertGreaterThan(layout.date, 0)
        XCTAssertGreaterThan(layout.hash, 0)
    }

    func testColumnLayoutNarrowsManyLanesBeforeClippingAny() {
        // The default window's list, with a history 33 lanes wide.
        let layout = GitGraphColumnLayout.make(width: 879, lanes: 33)
        XCTAssertEqual(layout.laneWidth, 7.5)
        XCTAssertEqual(layout.visibleLanes, 33)
        XCTAssertFalse(layout.isClipped)
        XCTAssertGreaterThanOrEqual(layout.description, GitGraphColumnLayout.minDescription)

        let crowded = GitGraphColumnLayout.make(width: 879, lanes: 80)
        XCTAssertEqual(crowded.laneWidth, GitGraphColumnLayout.minLaneWidth)
        XCTAssertTrue(crowded.isClipped)
        XCTAssertLessThan(crowded.visibleLanes, 80)
        XCTAssertGreaterThanOrEqual(crowded.description, GitGraphColumnLayout.minDescription)
    }

    func testColumnLayoutDropsAuthorThenHashThenDate() {
        let narrow = GitGraphColumnLayout.make(width: 500, lanes: 33)
        XCTAssertEqual(narrow.author, 0)
        XCTAssertEqual(narrow.hash, 0)
        XCTAssertGreaterThan(narrow.date, 0)
        let narrower = GitGraphColumnLayout.make(width: 380, lanes: 33)
        XCTAssertEqual(narrower.date, 0)
    }

    func testColumnLayoutNeverOverflowsTheList() {
        for width in stride(from: 320.0, through: 2_400, by: 37) {
            for lanes in [1, 2, 5, 12, 24, 33, 60, 150] {
                let layout = GitGraphColumnLayout.make(width: width, lanes: lanes)
                let used = GitGraphColumnLayout.leading + layout.graph + layout.description + layout.author + layout.date + layout.hash
                    + GitGraphColumnLayout.trailing
                XCTAssertLessThanOrEqual(used, width + 0.5, "width \(width), lanes \(lanes)")
                XCTAssertLessThanOrEqual(layout.visibleLanes, lanes)
                XCTAssertGreaterThanOrEqual(layout.laneWidth, GitGraphColumnLayout.minLaneWidth)
            }
        }
    }

    func testRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(GitDateFormat.relative(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(GitDateFormat.relative(now.addingTimeInterval(-600), now: now), "10m ago")
        XCTAssertEqual(GitDateFormat.relative(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(GitDateFormat.relative(now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        XCTAssertFalse(GitDateFormat.relative(now.addingTimeInterval(3_600), now: now).contains("ago"), "a future date is not relative")
    }
}

final class GitHistoryRepositoryTests: XCTestCase {
    private var directory: URL!
    private let service = WorkspaceService()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-git-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "user.name", "Fixture Person"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "tag.gpgsign", "false"])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testGraphOfABranchMergedBackWithATag() async throws {
        try commit("base.txt", "base\n", message: "Base")
        try git(["switch", "-c", "feature"])
        try commit("feature.txt", "one\n", message: "Feature one")
        try commit("feature.txt", "one\ntwo\n", message: "Feature two\n\nWith a body.")
        try git(["switch", "main"])
        try commit("main.txt", "main\n", message: "Main work")
        try git(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        try git(["tag", "-a", "v1.0", "-m", "Release"])

        guard case .loaded(let graph) = await service.graph(path: directory.path, scope: .all, limit: 100, uncommitted: 0) else {
            return XCTFail("expected a graph")
        }
        XCTAssertEqual(graph.currentBranch, "main")
        // Topological order keeps each line of history together; only the ends are fixed.
        XCTAssertEqual(Set(graph.commits.map(\.subject)), ["Merge feature", "Feature two", "Feature one", "Main work", "Base"])
        XCTAssertEqual(graph.commits.first?.subject, "Merge feature")
        XCTAssertEqual(graph.commits.last?.subject, "Base")
        XCTAssertEqual(graph.commits.count, 5)
        XCTAssertEqual(graph.commits.first?.id, graph.headID)
        XCTAssertEqual(Set(graph.commits.first?.refs ?? []), [GitRef(name: "main", kind: .head), GitRef(name: "v1.0", kind: .tag)])
        XCTAssertTrue(graph.commits.contains { $0.refs.contains(GitRef(name: "feature", kind: .local)) })
        XCTAssertEqual(graph.commits.first { $0.subject == "Feature two" }?.body, "With a body.")
        XCTAssertEqual(graph.laneCount, 2)
        XCTAssertEqual(graph.branchCount, 2)
        XCTAssertEqual(graph.tagCount, 1)
        XCTAssertFalse(graph.hasMore)
        XCTAssertEqual(graph.rows.first?.branchesOut.count, 1)

        guard case .loaded(let page) = await service.graph(path: directory.path, scope: .all, limit: 2, uncommitted: 3) else {
            return XCTFail("expected a graph")
        }
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.commits.count, 3, "two commits and the uncommitted row")
        XCTAssertTrue(page.commits[0].isUncommitted)
        XCTAssertEqual(page.commits[0].subject, "Uncommitted changes · 3 files")
        XCTAssertEqual(page.commits[0].parents, [graph.headID].compactMap { $0 })
        XCTAssertEqual(page.rows[1].column, page.rows[0].column, "HEAD continues the uncommitted row's lane")

        let merge = try XCTUnwrap(graph.commits.first)
        let mergeFiles = await service.commitFiles(path: directory.path, commit: merge)
        XCTAssertEqual(try mergeFiles.get().map(\.path), ["feature.txt"], "a merge shows what it brought in against its first parent")
        let featureTwo = try XCTUnwrap(graph.commits.first { $0.subject == "Feature two" })
        let files = try await service.commitFiles(path: directory.path, commit: featureTwo).get()
        XCTAssertEqual(files, [GitCommitFile(path: "feature.txt", status: "M", additions: 1, deletions: 0, isBinary: false)])
        let patch = await service.commitDiff(path: directory.path, commit: featureTwo, file: "feature.txt")
        XCTAssertTrue(patch.contains("+two"))
        let root = try XCTUnwrap(graph.commits.last)
        let rootFiles = try await service.commitFiles(path: directory.path, commit: root).get()
        XCTAssertEqual(rootFiles.map(\.status), ["A"])

        guard case .loaded(let current) = await service.graph(path: directory.path, scope: .current, limit: 100, uncommitted: 0) else {
            return XCTFail("expected a graph")
        }
        XCTAssertEqual(current.commits.count, 5, "the merged branch is part of main's history")
    }

    func testBranchListingSwitchingAndCreating() async throws {
        try commit("a.txt", "a\n", message: "First")
        try git(["branch", "topic"])
        // A remote-tracking branch with no local branch, as after a fetch. Nothing is fetched.
        try git(["remote", "add", "origin", "https://example.invalid/fixture.git"])
        try git(["update-ref", "refs/remotes/origin/review", "HEAD"])
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"])

        let list = await service.branches(path: directory.path)
        XCTAssertNil(list.error)
        XCTAssertEqual(list.local.first?.name, "main")
        XCTAssertEqual(Set(list.local.map(\.name)), ["main", "topic"])
        XCTAssertEqual(list.remote.map(\.name), ["origin/review"])

        let topic = try XCTUnwrap(list.local.first { $0.name == "topic" })
        let switched = await service.switchBranch(path: directory.path, to: topic)
        XCTAssertNil(switched)
        let afterSwitch = await service.inspect(path: directory.path)
        XCTAssertEqual(afterSwitch.branch, "topic")

        let review = try XCTUnwrap(list.remote.first)
        let tracked = await service.switchBranch(path: directory.path, to: review)
        XCTAssertNil(tracked)
        let afterTrack = await service.branches(path: directory.path)
        XCTAssertEqual(afterTrack.current?.name, "review")
        XCTAssertEqual(afterTrack.current?.upstream, "origin/review")

        let invalid = await service.createBranch(path: directory.path, name: "bad..name")
        XCTAssertEqual(invalid, "“bad..name” is not a valid branch name.")
        let created = await service.createBranch(path: directory.path, name: "fresh-idea")
        XCTAssertNil(created)
        let afterCreate = await service.inspect(path: directory.path)
        XCTAssertEqual(afterCreate.branch, "fresh-idea")

        // A switch that would overwrite local changes is refused, with git's reason.
        try git(["switch", "main"])
        try commit("a.txt", "main change\n", message: "Main change")
        try write("uncommitted\n", to: "a.txt")
        let refused = await service.switchBranch(path: directory.path, to: topic)
        XCTAssertNotNil(refused)
        XCTAssertTrue(refused?.contains("a.txt") == true, refused ?? "")
        let stillMain = await service.inspect(path: directory.path)
        XCTAssertEqual(stillMain.branch, "main")
    }

    func testEmptyRepositoryAndPlainFolder() async throws {
        guard case .loaded(let empty) = await service.graph(path: directory.path, scope: .all, limit: 100, uncommitted: 2) else {
            return XCTFail("an unborn branch is still a repository")
        }
        XCTAssertTrue(empty.commits.isEmpty, "no uncommitted row without a commit to hang it on")
        XCTAssertNil(empty.headID)
        let signature = await service.refsSignature(path: directory.path)
        XCTAssertNotNil(signature)

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("crok-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        guard case .notRepository = await service.graph(path: plain.path, scope: .all, limit: 100, uncommitted: 0) else {
            return XCTFail("a plain folder is not a repository")
        }
        let branches = await service.branches(path: plain.path)
        XCTAssertNotNil(branches.error)
    }

    private func commit(_ file: String, _ contents: String, message: String) throws {
        try write(contents, to: file)
        try git(["add", file])
        try git(["commit", "-q", "-m", message])
    }

    private func write(_ value: String, to file: String) throws {
        try Data(value.utf8).write(to: directory.appendingPathComponent(file))
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }
}
