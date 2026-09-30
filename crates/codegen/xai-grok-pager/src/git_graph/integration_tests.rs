//! `/git-graph` against a real repository built with the `git` on PATH (skipped without one).

use std::path::Path;
use std::process::Command;

use super::data::{self, RefKind, Scope, UNCOMMITTED};
use super::{Request, Response, run};

fn git(dir: &Path, args: &[&str], time: u32) {
    let date = format!("{} +0000", 1_700_000_000 + time * 60);
    let status = Command::new("git")
        .args([
            "-c",
            "user.name=Ada",
            "-c",
            "user.email=ada@example.com",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "tag.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
        ])
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_DATE", &date)
        .env("GIT_COMMITTER_DATE", &date)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .expect("git runs");
    assert!(
        status.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&status.stderr)
    );
}

fn commit(dir: &Path, file: &str, message: &str, time: u32) {
    std::fs::write(dir.join(file), format!("{message}\n")).unwrap();
    git(dir, &["add", file], time);
    git(dir, &["commit", "-q", "-m", message], time);
}

fn git_available() -> bool {
    Command::new("git")
        .arg("--version")
        .output()
        .is_ok_and(|output| output.status.success())
}

#[test]
fn loads_branches_merges_tags_and_uncommitted_changes() {
    if !git_available() {
        eprintln!("skipping: git is not on PATH");
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let repo = temp.path().join("repo");
    std::fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"], 0);
    git(&repo, &["symbolic-ref", "HEAD", "refs/heads/main"], 0);
    commit(&repo, "a.txt", "Initial commit", 1);
    git(&repo, &["switch", "-q", "-c", "feature"], 2);
    commit(&repo, "f.txt", "Add the feature", 3);
    git(&repo, &["switch", "-q", "main"], 4);
    commit(&repo, "b.txt", "Fix the build", 5);
    git(
        &repo,
        &["merge", "-q", "--no-ff", "-m", "Merge feature", "feature"],
        6,
    );
    git(&repo, &["tag", "-a", "v1", "-m", "Version 1"], 7);
    git(&repo, &["switch", "-q", "-c", "topic", "HEAD~1"], 8);
    commit(&repo, "t.txt", "Topic work", 9);
    git(&repo, &["switch", "-q", "main"], 10);
    std::fs::write(repo.join("a.txt"), "changed\n").unwrap();
    std::fs::write(repo.join("new.txt"), "new\n").unwrap();

    let graph = data::load(&repo.join("."), Scope::All, data::PAGE).expect("loads");
    assert_eq!(graph.branch.as_deref(), Some("main"));
    assert_eq!(
        (graph.local_branches, graph.remote_branches, graph.tags),
        (3, 0, 1)
    );
    assert!(!graph.truncated);
    let subjects: Vec<&str> = graph.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects[0], "Uncommitted changes · 2 files");
    assert_eq!(graph.commits[0].uncommitted, Some(2));
    assert_eq!(subjects.len(), 6, "{subjects:?}");
    assert!(subjects.contains(&"Topic work"));
    assert_eq!(graph.rows.len(), graph.commits.len());

    let merge = graph
        .commits
        .iter()
        .position(|c| c.subject == "Merge feature")
        .unwrap();
    let head = &graph.commits[merge];
    assert!(head.is_head && head.is_merge());
    let refs: Vec<(&str, RefKind)> = head
        .refs
        .iter()
        .map(|r| (r.name.as_str(), r.kind))
        .collect();
    assert_eq!(refs, vec![("main", RefKind::Head), ("v1", RefKind::Tag)]);
    assert_eq!(graph.rows[merge].branches_out.len(), 1);
    assert_eq!(graph.commits[0].parents, vec![head.hash.clone()]);
    let feature = graph
        .commits
        .iter()
        .find(|c| c.subject == "Add the feature")
        .unwrap();
    assert_eq!(feature.refs[0].name, "feature");
    assert!(graph.lanes >= 2);

    // The current branch hides the unmerged topic branch.
    let current = data::load(&repo, Scope::Current, data::PAGE).unwrap();
    assert!(!current.commits.iter().any(|c| c.subject == "Topic work"));

    // A limit truncates and says so; the uncommitted row is extra.
    let short = data::load(&repo, Scope::All, 2).unwrap();
    assert!(short.truncated);
    assert_eq!(short.commits.len(), 3);

    // Changed files: a merge against its first parent, a root commit, and the working tree.
    let Response::Files { result, .. } = run(Request::Files {
        root: graph.root.clone(),
        hash: head.hash.clone(),
        parents: head.parents.clone(),
    }) else {
        unreachable!()
    };
    let files = result.unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "f.txt");
    assert_eq!((files[0].added, files[0].removed), (Some(1), Some(0)));
    let root = graph.commits.last().unwrap();
    let files = data::load_files(&graph.root, &root.hash, &root.parents).unwrap();
    assert_eq!(files[0].path, "a.txt");
    let files = data::load_files(&graph.root, UNCOMMITTED, &graph.commits[0].parents).unwrap();
    let paths: Vec<(&str, Option<u64>)> =
        files.iter().map(|f| (f.path.as_str(), f.added)).collect();
    assert_eq!(paths, vec![("a.txt", Some(1)), ("new.txt", None)]);

    // Loading through the request runner, as the app does.
    let Response::Loaded { generation, result } = run(Request::Load {
        cwd: repo.clone(),
        scope: Scope::All,
        limit: data::PAGE,
        generation: 7,
    }) else {
        unreachable!()
    };
    assert_eq!(generation, 7);
    assert_eq!(result.unwrap().commits.len(), 6);
}

#[test]
fn outside_a_repository_is_an_error() {
    if !git_available() {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let error = data::load(temp.path(), Scope::All, data::PAGE).unwrap_err();
    assert!(error.starts_with("Not a git repository"), "{error}");
}

#[test]
fn an_empty_repository_has_no_commits() {
    if !git_available() {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    git(temp.path(), &["init", "-q"], 0);
    let graph = data::load(temp.path(), Scope::All, data::PAGE).unwrap();
    assert!(graph.commits.is_empty());
    assert!(graph.head.is_none());
    let graph = data::load(temp.path(), Scope::Current, data::PAGE).unwrap();
    assert!(graph.commits.is_empty());
}
