//! Reads a repository's history for the `/git-graph` explorer. Every call runs `git` directly
//! (never a shell), without optional locks, pagers, colour, or signature checks, and ignores
//! `GIT_DIR`-style variables inherited from the launching shell.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::layout::{self, Row};

/// Commits read per load; `m` in the explorer reads this many more.
pub const PAGE: usize = 1000;

/// The hash standing in for the working tree's uncommitted changes.
pub const UNCOMMITTED: &str = "uncommitted";

/// Which history to show.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Scope {
    /// Every local branch, remote-tracking branch, and tag, plus HEAD.
    #[default]
    All,
    /// Only what HEAD reaches.
    Current,
}

impl Scope {
    pub fn toggled(self) -> Self {
        match self {
            Self::All => Self::Current,
            Self::Current => Self::All,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::All => "All branches",
            Self::Current => "Current branch",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum RefKind {
    /// Sorted first: the branch HEAD points to.
    Head,
    Local,
    Remote,
    Tag,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitRef {
    pub name: String,
    pub kind: RefKind,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Commit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    /// Author time, Unix seconds.
    pub time: i64,
    pub subject: String,
    pub body: String,
    pub refs: Vec<GitRef>,
    /// HEAD points at this commit.
    pub is_head: bool,
    /// For the uncommitted-changes row: how many paths changed.
    pub uncommitted: Option<usize>,
}

impl Commit {
    pub fn short(&self) -> &str {
        if self.uncommitted.is_some() {
            return "";
        }
        self.hash.get(..7).unwrap_or(&self.hash)
    }

    pub fn is_merge(&self) -> bool {
        self.parents.len() > 1
    }
}

/// One load of the graph.
#[derive(Clone, Debug, Default)]
pub struct GraphData {
    pub root: PathBuf,
    /// The checked-out branch; `None` when HEAD is detached or unborn.
    pub branch: Option<String>,
    pub head: Option<String>,
    pub scope: Scope,
    pub limit: usize,
    /// More history exists past `limit`.
    pub truncated: bool,
    pub commits: Vec<Commit>,
    pub rows: Vec<Row>,
    /// The widest row, in lanes.
    pub lanes: usize,
    pub local_branches: usize,
    pub remote_branches: usize,
    pub tags: usize,
}

/// A path a commit changed. `None` counts mean a binary file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileStat {
    pub path: String,
    pub added: Option<u64>,
    pub removed: Option<u64>,
}

/// Reads the graph for the repository containing `cwd`.
pub fn load(cwd: &Path, scope: Scope, limit: usize) -> Result<GraphData, String> {
    let top = git(cwd, &["rev-parse", "--show-toplevel"])
        .map_err(|_| format!("Not a git repository: {}", cwd.display()))?;
    let root = PathBuf::from(String::from_utf8_lossy(&top).trim_end_matches(['\n', '\r']));
    let head = git(&root, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .ok()
        .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
        .filter(|hash| !hash.is_empty());
    let branch = git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .ok()
        .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
        .filter(|name| !name.is_empty());
    let refs = parse_refs(&git(
        &root,
        &[
            "for-each-ref",
            "--format=%(objectname)%00%(*objectname)%00%(refname)",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
        ],
    )?);

    let mut commits = Vec::new();
    let mut truncated = false;
    if head.is_some() || (scope == Scope::All && !refs.is_empty()) {
        let max_count = format!("--max-count={}", limit.saturating_add(1));
        let mut args = vec![
            "log",
            "--topo-order",
            "-z",
            max_count.as_str(),
            "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b",
        ];
        if scope == Scope::All {
            args.extend(["--branches", "--remotes", "--tags"]);
        }
        if head.is_some() {
            args.push("HEAD");
        }
        args.push("--");
        commits = parse_log(&git(&root, &args)?);
        if commits.len() > limit {
            commits.truncate(limit);
            truncated = true;
        }
    }

    let mut by_hash: HashMap<&str, Vec<GitRef>> = HashMap::new();
    let (mut local_branches, mut remote_branches, mut tags) = (0, 0, 0);
    for (hash, reference) in &refs {
        match reference.kind {
            RefKind::Local | RefKind::Head => local_branches += 1,
            RefKind::Remote => remote_branches += 1,
            RefKind::Tag => tags += 1,
        }
        let mut reference = reference.clone();
        if reference.kind == RefKind::Local && branch.as_deref() == Some(reference.name.as_str()) {
            reference.kind = RefKind::Head;
        }
        by_hash.entry(hash.as_str()).or_default().push(reference);
    }
    for commit in &mut commits {
        if let Some(mut found) = by_hash.remove(commit.hash.as_str()) {
            found.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));
            commit.refs = found;
        }
        commit.is_head = head.as_deref() == Some(commit.hash.as_str());
    }

    if let Some(head) = &head {
        let changed = git(
            &root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        )
        .map(|out| count_status_entries(&out))
        .unwrap_or(0);
        if changed > 0 {
            commits.insert(
                0,
                Commit {
                    hash: UNCOMMITTED.to_owned(),
                    parents: vec![head.clone()],
                    subject: format!(
                        "Uncommitted changes · {changed} {}",
                        if changed == 1 { "file" } else { "files" }
                    ),
                    uncommitted: Some(changed),
                    ..Commit::default()
                },
            );
        }
    }

    let rows = layout::layout(commits.iter().map(|commit| {
        (
            commit.hash.as_str(),
            commit.parents.iter().map(String::as_str),
        )
    }));
    let lanes = rows.iter().map(Row::width).max().unwrap_or(0);
    Ok(GraphData {
        root,
        branch,
        head,
        scope,
        limit,
        truncated,
        commits,
        rows,
        lanes,
        local_branches,
        remote_branches,
        tags,
    })
}

/// The paths `hash` changed against its first parent; for [`UNCOMMITTED`], the working tree
/// against HEAD plus untracked files.
pub fn load_files(root: &Path, hash: &str, parents: &[String]) -> Result<Vec<FileStat>, String> {
    let common = [
        "--numstat",
        "-z",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
    ];
    if hash == UNCOMMITTED {
        let mut args = vec!["diff"];
        args.extend(common);
        args.extend(["HEAD", "--"]);
        let mut files = parse_numstat(&git(root, &args)?);
        let untracked = git(
            root,
            &["ls-files", "--others", "--exclude-standard", "-z", "--"],
        )?;
        files.extend(
            untracked
                .split(|&byte| byte == 0)
                .filter(|name| !name.is_empty())
                .map(|name| FileStat {
                    path: String::from_utf8_lossy(name).into_owned(),
                    added: None,
                    removed: None,
                }),
        );
        return Ok(files);
    }
    let output = match parents {
        [first, _, ..] => {
            let mut args = vec!["diff"];
            args.extend(common);
            args.extend([first.as_str(), hash, "--"]);
            git(root, &args)?
        }
        _ => {
            let mut args = vec!["diff-tree", "-r", "--no-commit-id", "--root"];
            args.extend(common);
            args.extend([hash, "--"]);
            git(root, &args)?
        }
    };
    Ok(parse_numstat(&output))
}

fn git(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut command = Command::new("git");
    command
        .args([
            "--no-optional-locks",
            "-c",
            "color.ui=never",
            "-c",
            "log.showSignature=false",
            "-c",
            "core.quotePath=false",
            "-C",
        ])
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .stdin(std::process::Stdio::null());
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
    ] {
        command.env_remove(key);
    }
    let output = command
        .output()
        .map_err(|error| format!("Could not run git: {error}"))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!(
            "git {} failed: {}",
            args.first().unwrap_or(&""),
            stderr.trim()
        ))
    }
}

/// `git log -z` with seven `\x1f`-separated fields per commit.
pub(crate) fn parse_log(output: &[u8]) -> Vec<Commit> {
    output
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            let record = record.trim_start_matches('\n');
            if record.is_empty() {
                return None;
            }
            let mut fields = record.splitn(7, '\u{1f}');
            let hash = fields.next()?.trim().to_owned();
            if hash.is_empty() {
                return None;
            }
            let parents = fields
                .next()
                .unwrap_or("")
                .split_whitespace()
                .map(str::to_owned)
                .collect();
            Some(Commit {
                hash,
                parents,
                author: fields.next().unwrap_or("").to_owned(),
                email: fields.next().unwrap_or("").to_owned(),
                time: fields.next().unwrap_or("").trim().parse().unwrap_or(0),
                subject: fields.next().unwrap_or("").to_owned(),
                body: fields.next().unwrap_or("").trim_end().to_owned(),
                ..Commit::default()
            })
        })
        .collect()
}

/// `for-each-ref` lines of `objectname NUL *objectname NUL refname`, keyed by the commit each
/// ref names (annotated tags peeled). Remote `HEAD` aliases are skipped.
pub(crate) fn parse_refs(output: &[u8]) -> Vec<(String, GitRef)> {
    output
        .split(|&byte| byte == b'\n')
        .filter_map(|line| {
            let line = String::from_utf8_lossy(line);
            let mut fields = line.split('\0');
            let object = fields.next()?.trim();
            let peeled = fields.next().unwrap_or("").trim();
            let name = fields.next()?.trim();
            let (kind, short) = if let Some(short) = name.strip_prefix("refs/heads/") {
                (RefKind::Local, short)
            } else if let Some(short) = name.strip_prefix("refs/remotes/") {
                if short.ends_with("/HEAD") {
                    return None;
                }
                (RefKind::Remote, short)
            } else if let Some(short) = name.strip_prefix("refs/tags/") {
                (RefKind::Tag, short)
            } else {
                return None;
            };
            let target = if peeled.is_empty() { object } else { peeled };
            if target.is_empty() || short.is_empty() {
                return None;
            }
            Some((
                target.to_owned(),
                GitRef {
                    name: short.to_owned(),
                    kind,
                },
            ))
        })
        .collect()
}

/// Paths in `git status --porcelain=v1 -z`; a rename or copy carries its source as an extra field.
pub(crate) fn count_status_entries(output: &[u8]) -> usize {
    let mut fields = output.split(|&byte| byte == 0);
    let mut count = 0;
    while let Some(field) = fields.next() {
        if field.len() < 4 {
            continue;
        }
        count += 1;
        if field.iter().take(2).any(|code| matches!(code, b'R' | b'C')) {
            fields.next();
        }
    }
    count
}

/// `--numstat -z` without renames: `added TAB removed TAB path NUL`; binary files count `-`.
pub(crate) fn parse_numstat(output: &[u8]) -> Vec<FileStat> {
    output
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            let record = record.trim_start_matches('\n');
            let mut fields = record.splitn(3, '\t');
            let added = fields.next()?;
            let removed = fields.next()?;
            let path = fields.next()?;
            if path.is_empty() {
                return None;
            }
            Some(FileStat {
                path: path.to_owned(),
                added: added.parse().ok(),
                removed: removed.parse().ok(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_log_records_with_multiline_bodies() {
        let output = b"aaaaaaa1\x1fbbbbbbb2 ccccccc3\x1fAda\x1fada@example.com\x1f1700000000\x1fMerge topic\x1fFirst line\n\nSecond\n\0bbbbbbb2\x1f\x1fBo\x1fbo@example.com\x1f1600000000\x1fRoot\x1f\n\0";
        let commits = parse_log(output);
        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].hash, "aaaaaaa1");
        assert_eq!(commits[0].parents, vec!["bbbbbbb2", "ccccccc3"]);
        assert_eq!(commits[0].author, "Ada");
        assert_eq!(commits[0].email, "ada@example.com");
        assert_eq!(commits[0].time, 1_700_000_000);
        assert_eq!(commits[0].subject, "Merge topic");
        assert_eq!(commits[0].body, "First line\n\nSecond");
        assert!(commits[0].is_merge());
        assert!(commits[1].parents.is_empty());
        assert_eq!(commits[1].body, "");
        assert_eq!(commits[1].short(), "bbbbbbb");
    }

    #[test]
    fn parses_refs_peeling_tags_and_skipping_remote_head() {
        let output = b"c1\0\0refs/heads/main\nc2\0\0refs/remotes/origin/main\nc2\0\0refs/remotes/origin/HEAD\nt1\0c1\0refs/tags/v1.0\nc3\0\0refs/tags/light\nc4\0\0refs/notes/x\n";
        let refs = parse_refs(output);
        let names: Vec<(&str, &str, RefKind)> = refs
            .iter()
            .map(|(hash, r)| (hash.as_str(), r.name.as_str(), r.kind))
            .collect();
        assert_eq!(
            names,
            vec![
                ("c1", "main", RefKind::Local),
                ("c2", "origin/main", RefKind::Remote),
                ("c1", "v1.0", RefKind::Tag),
                ("c3", "light", RefKind::Tag),
            ]
        );
    }

    #[test]
    fn counts_status_entries_with_rename_sources() {
        let output = b" M a.txt\0R  new.txt\0old.txt\0?? b.txt\0";
        assert_eq!(count_status_entries(output), 3);
        assert_eq!(count_status_entries(b""), 0);
    }

    #[test]
    fn parses_numstat_including_binary_files() {
        let output = b"3\t1\tsrc/main.rs\0-\t-\timage.png\0";
        assert_eq!(
            parse_numstat(output),
            vec![
                FileStat {
                    path: "src/main.rs".into(),
                    added: Some(3),
                    removed: Some(1)
                },
                FileStat {
                    path: "image.png".into(),
                    added: None,
                    removed: None
                },
            ]
        );
    }

    #[test]
    fn scope_toggles_and_names() {
        assert_eq!(Scope::All.toggled(), Scope::Current);
        assert_eq!(Scope::Current.toggled().label(), "All branches");
    }
}
