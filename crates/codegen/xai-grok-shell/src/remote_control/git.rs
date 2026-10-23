//! Git queries for a front end on another computer (`x.ai/remote/git`). The relay carries the request to the
//! computer that has the session; this runs the same git commands Crok Desktop's own Git Graph runs, in the
//! session's folder. Writes are limited to switching and creating a branch, which the person asks for.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};

/// How long one git command may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_DIFF: usize = 1_024 * 1_024;
const MAX_BODY: usize = 500;
const MAX_COMMITS: usize = 1_000;

/// Runs one request and answers a JSON object. A refusal or a git failure is `{"error": "..."}`.
pub(crate) async fn handle(cwd: &str, request: Value) -> Value {
    if cwd.is_empty() || !Path::new(cwd).is_absolute() || !Path::new(cwd).is_dir() {
        return json!({ "error": "The session's folder is unknown on its computer." });
    }
    match request
        .get("op")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "graph" => graph(cwd, &request).await,
        "branches" => branches(cwd).await,
        "files" => files(cwd, &request).await,
        "diff" => commit_diff(cwd, &request).await,
        "workspace" => workspace(cwd).await,
        "workspace_diff" => workspace_diff(cwd, &request).await,
        "signature" => signature(cwd).await,
        "switch" => switch_branch(cwd, &request).await,
        "create" => create_branch(cwd, &request).await,
        _ => json!({ "error": "Unknown git request." }),
    }
}

async fn graph(cwd: &str, request: &Value) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => return json!({ "error": error }),
    };
    let head = git(&root, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .await
        .ok()
        .map(|out| trimmed(&out))
        .filter(|hash| !hash.is_empty());
    let branch = git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .ok()
        .map(|out| trimmed(&out))
        .filter(|name| !name.is_empty());
    let refs = git(
        &root,
        &[
            "for-each-ref",
            "--format=%(objectname)%00%(*objectname)%00%(refname)",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
        ],
    )
    .await
    .map(|out| parse_refs(&out, branch.as_deref()))
    .unwrap_or_default();

    let scope = request
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("all");
    let limit = request
        .get("limit")
        .and_then(Value::as_u64)
        .map(|value| value.clamp(1, MAX_COMMITS as u64) as usize)
        .unwrap_or(500);
    let mut commits = Vec::new();
    let mut has_more = false;
    if head.is_some() || (scope == "all" && !refs.is_empty()) {
        let max_count = format!("--max-count={}", limit + 1);
        let mut args = vec![
            "log",
            "--topo-order",
            "-z",
            max_count.as_str(),
            "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b",
        ];
        match scope {
            "local" => args.push("--branches"),
            "current" => {}
            _ => args.extend(["--branches", "--remotes", "--tags"]),
        }
        if head.is_some() {
            args.push("HEAD");
        }
        args.push("--");
        match git(&root, &args).await {
            Ok(out) => {
                commits = parse_commits(&out);
                if commits.len() > limit {
                    commits.truncate(limit);
                    has_more = true;
                }
            }
            Err(error) => return json!({ "error": error }),
        }
    }
    // Refs point at commits that may be past the page; the front end groups them by commit.
    let uncommitted = status_count(&root).await;
    json!({
        "root": root,
        "head": head,
        "branch": branch,
        "refs": refs,
        "commits": commits,
        "hasMore": has_more,
        "uncommitted": uncommitted,
    })
}

async fn branches(cwd: &str) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => return json!({ "error": error }),
    };
    let format = "%(refname)%00%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(HEAD)%00%(contents:subject)";
    match git(
        &root,
        &[
            "for-each-ref",
            "--sort=-committerdate",
            &format!("--format={format}"),
            "refs/heads",
            "refs/remotes",
        ],
    )
    .await
    {
        Ok(out) => {
            let mut rows = Vec::new();
            for line in String::from_utf8_lossy(&out).lines() {
                let fields: Vec<&str> = line.split('\0').collect();
                if fields.len() < 7 {
                    continue;
                }
                let ref_name = fields[0];
                let is_remote = ref_name.starts_with("refs/remotes/");
                if is_remote && ref_name.ends_with("/HEAD") {
                    continue;
                }
                rows.push(json!({
                    "refName": ref_name,
                    "name": fields[1],
                    "upstream": fields[2],
                    "track": fields[3],
                    "date": fields[4].parse::<f64>().ok(),
                    "current": fields[5] == "*",
                    "subject": fields[6],
                    "isRemote": is_remote,
                }));
            }
            json!({ "branches": rows })
        }
        Err(error) => json!({ "error": error }),
    }
}

async fn files(cwd: &str, request: &Value) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => return json!({ "error": error }),
    };
    let Some(commit) = request.get("commit").and_then(Value::as_str) else {
        return json!({ "error": "Which commit?" });
    };
    if !is_hash(commit) {
        return json!({ "error": "That is not a commit." });
    }
    let parents: Vec<String> = request
        .get("parents")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .filter(|value| is_hash(value))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let range: Vec<&str> = match parents.first() {
        Some(parent) => vec![parent.as_str(), commit],
        None => vec!["--root", commit],
    };
    let common = [
        "diff-tree",
        "-r",
        "--no-commit-id",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
        "-z",
    ];
    let mut status_args = common.to_vec();
    status_args.push("--name-status");
    status_args.extend(range.iter());
    status_args.push("--");
    let status = match git(&root, &status_args).await {
        Ok(out) => out,
        Err(error) => return json!({ "error": error }),
    };
    let mut numstat_args = common.to_vec();
    numstat_args.push("--numstat");
    numstat_args.extend(range.iter());
    numstat_args.push("--");
    let numstat = match git(&root, &numstat_args).await {
        Ok(out) => out,
        Err(error) => return json!({ "error": error }),
    };
    json!({ "files": parse_files(&status, &numstat) })
}

async fn commit_diff(cwd: &str, request: &Value) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => return json!({ "error": error }),
    };
    let Some(commit) = request.get("commit").and_then(Value::as_str) else {
        return json!({ "error": "Which commit?" });
    };
    let Some(file) = request.get("file").and_then(Value::as_str) else {
        return json!({ "error": "Which file?" });
    };
    if !is_hash(commit) {
        return json!({ "error": "That is not a commit." });
    }
    let Some(file) = safe_path(file) else {
        return json!({ "error": "The selected file is outside the repository." });
    };
    let parents: Vec<String> = request
        .get("parents")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .filter(|value| is_hash(value))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let range: Vec<&str> = match parents.first() {
        Some(parent) => vec![parent.as_str(), commit],
        None => vec!["--root", commit],
    };
    let mut args = vec![
        "diff-tree",
        "-p",
        "-r",
        "--no-commit-id",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    args.extend(range.iter());
    args.push("--");
    args.push(file);
    match git(&root, &args).await {
        Ok(out) => json!({ "text": capped(&out, MAX_DIFF) }),
        Err(error) => json!({ "error": error }),
    }
}

/// The working tree's files against HEAD, for the uncommitted row and the composer's change count.
async fn workspace(cwd: &str) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => {
            return json!({ "root": Value::Null, "branch": "No repository", "changes": [], "error": error });
        }
    };
    let branch = git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .ok()
        .map(|out| trimmed(&out))
        .filter(|name| !name.is_empty());
    let status = match git(
        &root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )
    .await
    {
        Ok(out) => out,
        Err(error) => {
            return json!({ "root": root, "branch": branch, "changes": [], "error": error });
        }
    };
    let mut counts: Vec<(String, u64, u64, bool)> = Vec::new();
    for arguments in [
        vec!["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z"],
        vec![
            "diff",
            "--cached",
            "--no-ext-diff",
            "--no-textconv",
            "--numstat",
            "-z",
        ],
    ] {
        if let Ok(out) = git(&root, &arguments).await {
            for (path, added, removed, binary) in parse_numstat(&out) {
                if let Some(found) = counts.iter_mut().find(|(name, _, _, _)| *name == path) {
                    found.1 += added;
                    found.2 += removed;
                    found.3 = found.3 || binary;
                } else {
                    counts.push((path, added, removed, binary));
                }
            }
        }
    }
    let mut changes = Vec::new();
    let mut fields = status.split(|&byte| byte == 0);
    while let Some(entry) = fields.next() {
        if entry.len() < 4 {
            continue;
        }
        let bytes = &entry[..3];
        let code = String::from_utf8_lossy(&bytes[..2]).into_owned();
        let path = String::from_utf8_lossy(&entry[3..]).into_owned();
        if bytes
            .first()
            .is_some_and(|code| matches!(code, b'R' | b'C'))
            || bytes.get(1).is_some_and(|code| matches!(code, b'R' | b'C'))
        {
            fields.next();
        }
        let (added, removed, binary) = counts
            .iter()
            .find(|(name, _, _, _)| *name == path)
            .map(|(_, added, removed, binary)| (*added, *removed, *binary))
            .unwrap_or((0, 0, false));
        changes.push(json!({
            "path": path,
            "status": code,
            "additions": added,
            "deletions": removed,
            "isBinary": binary,
        }));
    }
    changes.sort_by(|left, right| {
        left.get("path")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_lowercase()
            .cmp(
                &right
                    .get("path")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_lowercase(),
            )
    });
    json!({ "root": root, "branch": branch, "changes": changes })
}

async fn workspace_diff(cwd: &str, request: &Value) -> Value {
    let root = match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => trimmed(&out),
        Err(error) => return json!({ "error": error }),
    };
    let Some(file) = request.get("file").and_then(Value::as_str) else {
        return json!({ "error": "Which file?" });
    };
    let Some(file) = safe_path(file) else {
        return json!({ "error": "The selected file is outside the repository." });
    };
    let common = [
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    let mut staged_args = vec!["diff", "--cached"];
    staged_args.extend(common.iter());
    staged_args.extend(["--", file]);
    let mut unstaged_args = vec!["diff"];
    unstaged_args.extend(common.iter());
    unstaged_args.extend(["--", file]);
    let staged = git(&root, &staged_args).await.unwrap_or_default();
    let unstaged = git(&root, &unstaged_args).await.unwrap_or_default();
    let mut sections = Vec::new();
    if !staged.is_empty() {
        sections.push(format!("Staged changes\n\n{}", capped(&staged, MAX_DIFF)));
    }
    if !unstaged.is_empty() {
        sections.push(format!(
            "Working tree changes\n\n{}",
            capped(&unstaged, MAX_DIFF)
        ));
    }
    if sections.is_empty() {
        // An untracked file has no diff against the index; show it the way the app's own view does.
        let untracked = git(
            &root,
            &[
                "ls-files",
                "--others",
                "--exclude-standard",
                "-z",
                "--",
                file,
            ],
        )
        .await
        .unwrap_or_default();
        if !untracked.is_empty() {
            let mut args = vec!["diff", "--no-index", "--no-color", "--"];
            args.push("/dev/null");
            args.push(file);
            if let Ok(diff) = git_allow_failure(&root, &args).await {
                sections.push(format!("New file\n\n{}", capped(&diff, MAX_DIFF)));
            }
        }
    }
    if sections.is_empty() {
        json!({ "text": "No textual changes for this file." })
    } else {
        json!({ "text": sections.join("\n\n") })
    }
}

async fn signature(cwd: &str) -> Value {
    match git(cwd, &["rev-parse", "--show-toplevel"]).await {
        Ok(out) => {
            let root = trimmed(&out);
            match git_allow_failure(&root, &["show-ref", "--head"]).await {
                Ok(out) => json!({ "text": String::from_utf8_lossy(&out) }),
                Err(error) => json!({ "error": error }),
            }
        }
        Err(error) => json!({ "error": error }),
    }
}

async fn switch_branch(cwd: &str, request: &Value) -> Value {
    let Some(branch) = request.get("branch").and_then(Value::as_str) else {
        return json!({ "error": "Which branch?" });
    };
    if branch.starts_with('-') || branch.trim().is_empty() {
        return json!({ "error": "That is not a branch name." });
    }
    let remote = request
        .get("remote")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let arguments: Vec<&str> = if remote {
        vec!["switch", "--track", branch]
    } else {
        vec!["switch", branch]
    };
    match git(cwd, &arguments).await {
        Ok(_) => current_branch(cwd).await,
        Err(error) => json!({ "error": error }),
    }
}

async fn create_branch(cwd: &str, request: &Value) -> Value {
    let Some(name) = request.get("name").and_then(Value::as_str) else {
        return json!({ "error": "Which branch name?" });
    };
    let name = name.trim();
    if name.is_empty() || name.starts_with('-') {
        return json!({ "error": "That is not a branch name." });
    }
    if git(cwd, &["check-ref-format", "--branch", name])
        .await
        .is_err()
    {
        return json!({ "error": format!("“{name}” is not a valid branch name.") });
    }
    match git(cwd, &["switch", "-c", name]).await {
        Ok(_) => current_branch(cwd).await,
        Err(error) => json!({ "error": error }),
    }
}

async fn current_branch(cwd: &str) -> Value {
    let branch = git(cwd, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .ok()
        .map(|out| trimmed(&out))
        .filter(|name| !name.is_empty());
    json!({ "branch": branch })
}

async fn status_count(root: &str) -> u64 {
    match git(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )
    .await
    {
        Ok(out) => count_status(&out) as u64,
        Err(_) => 0,
    }
}

fn count_status(output: &[u8]) -> usize {
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

/// `for-each-ref` lines of `objectname NUL *objectname NUL refname`, keyed by the commit each names.
fn parse_refs(output: &[u8], current: Option<&str>) -> Vec<Value> {
    output
        .split(|&byte| byte == b'\n')
        .filter_map(|line| {
            let line = String::from_utf8_lossy(line);
            let mut fields = line.split('\0');
            let object = fields.next()?.trim();
            let peeled = fields.next().unwrap_or("").trim();
            let name = fields.next()?.trim();
            let (kind, short) = if let Some(short) = name.strip_prefix("refs/heads/") {
                (
                    if current == Some(short) {
                        "head"
                    } else {
                        "local"
                    },
                    short,
                )
            } else if let Some(short) = name.strip_prefix("refs/remotes/") {
                if short.ends_with("/HEAD") {
                    return None;
                }
                ("remote", short)
            } else if let Some(short) = name.strip_prefix("refs/tags/") {
                ("tag", short)
            } else {
                return None;
            };
            let target = if peeled.is_empty() { object } else { peeled };
            if target.is_empty() || short.is_empty() {
                return None;
            }
            Some(json!({ "commit": target, "name": short, "kind": kind }))
        })
        .collect()
}

/// `git log -z` records of hash, parents, author, email, time, subject, and body.
fn parse_commits(output: &[u8]) -> Vec<Value> {
    output
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            let record = record.trim_start_matches('\n');
            if record.is_empty() {
                return None;
            }
            let mut fields = record.splitn(7, '\u{1f}');
            let id = fields.next()?.trim();
            if id.is_empty() {
                return None;
            }
            let parents: Vec<&str> = fields.next().unwrap_or("").split_whitespace().collect();
            Some(json!({
                "id": id,
                "parents": parents,
                "author": fields.next().unwrap_or(""),
                "email": fields.next().unwrap_or(""),
                "date": fields.next().unwrap_or("").trim().parse::<f64>().unwrap_or(0.0),
                "subject": fields.next().unwrap_or(""),
                "body": capped(fields.next().unwrap_or("").trim_end().as_bytes(), MAX_BODY),
            }))
        })
        .collect()
}

/// Joins `--name-status -z` (status NUL path NUL) with `--numstat -z` (added TAB removed TAB path NUL).
fn parse_files(status: &[u8], numstat: &[u8]) -> Vec<Value> {
    let mut counts: Vec<(String, u64, u64, bool)> = parse_numstat(numstat);
    let fields: Vec<String> = status
        .split(|&byte| byte == 0)
        .map(|field| String::from_utf8_lossy(field).into_owned())
        .collect();
    let mut files = Vec::new();
    let mut index = 0;
    while index + 1 < fields.len() {
        let code = fields[index].trim();
        let path = fields[index + 1].clone();
        index += 2;
        let Some(letter) = code.chars().next().filter(|_| !path.is_empty()) else {
            continue;
        };
        let (added, removed, binary) = counts
            .iter()
            .position(|(name, _, _, _)| *name == path)
            .map(|position| counts.remove(position))
            .map(|(_, added, removed, binary)| (added, removed, binary))
            .unwrap_or((0, 0, false));
        files.push(json!({
            "path": path,
            "status": letter.to_string(),
            "additions": added,
            "deletions": removed,
            "isBinary": binary,
        }));
    }
    files
}

/// `--numstat -z` without renames: `added TAB removed TAB path NUL`; binary files count `-`.
fn parse_numstat(output: &[u8]) -> Vec<(String, u64, u64, bool)> {
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
            Some((
                path.to_owned(),
                added.parse::<u64>().unwrap_or(0),
                removed.parse::<u64>().unwrap_or(0),
                added == "-" || removed == "-",
            ))
        })
        .collect()
}

fn is_hash(value: &str) -> bool {
    (7..=64).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn safe_path(value: &str) -> Option<&str> {
    if value.starts_with('/') || value.contains('\\') || value.split('/').any(|part| part == "..") {
        return None;
    }
    Some(value)
}

fn trimmed(output: &[u8]) -> String {
    String::from_utf8_lossy(output)
        .trim_matches(['\n', '\r'])
        .to_string()
}

fn capped(output: &[u8], limit: usize) -> String {
    let text = String::from_utf8_lossy(&output[..output.len().min(limit)]).into_owned();
    if output.len() > limit {
        let shown = if limit >= 1_024 * 1_024 {
            format!("{} MiB", limit / (1_024 * 1_024))
        } else {
            format!("{limit} characters")
        };
        format!("{text}\n\n[Preview truncated at {shown}]")
    } else {
        text
    }
}

async fn git(dir: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let output = run_git(dir, args).await?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        let error = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(if error.is_empty() {
            format!("git {} failed.", args.first().unwrap_or(&""))
        } else {
            error
        })
    }
}

/// For commands whose non-zero exit is a normal answer (`show-ref` with no refs, `diff --no-index`).
async fn git_allow_failure(dir: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let output = run_git(dir, args).await?;
    if output.status.success() || output.status.code() == Some(1) {
        Ok(output.stdout)
    } else {
        let error = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(if error.is_empty() {
            format!("git {} failed.", args.first().unwrap_or(&""))
        } else {
            error
        })
    }
}

async fn run_git(dir: &str, args: &[&str]) -> Result<std::process::Output, String> {
    let mut command = tokio::process::Command::new("git");
    command
        .args([
            "--no-optional-locks",
            "--literal-pathspecs",
            "-c",
            "color.ui=never",
            "-c",
            "log.showSignature=false",
            "-c",
            "core.quotePath=false",
            "-C",
            dir,
        ])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
    ] {
        command.env_remove(key);
    }
    match tokio::time::timeout(GIT_TIMEOUT, command.output()).await {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => Err(format!("Could not run git: {error}")),
        Err(_) => Err("git did not answer in time.".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn repo() -> tempfile::TempDir {
        let directory = tempfile::tempdir().expect("temp dir");
        let run = |args: &[&str]| {
            let status = Command::new("git")
                .args(args)
                .current_dir(directory.path())
                .status()
                .expect("git");
            assert!(status.success(), "git {args:?}");
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "test@example.com"]);
        run(&["config", "user.name", "Test"]);
        std::fs::write(directory.path().join("a.txt"), "one\n").expect("write");
        run(&["add", "a.txt"]);
        run(&["commit", "-q", "-m", "first"]);
        std::fs::write(directory.path().join("a.txt"), "one\ntwo\n").expect("write");
        directory
    }

    #[test]
    fn hashes_are_hex_only() {
        assert!(is_hash("0123456789abcdef0123456789abcdef01234567"));
        assert!(!is_hash("--output=/tmp/x"));
        assert!(!is_hash("HEAD"));
    }

    #[test]
    fn paths_stay_inside_the_repository() {
        assert_eq!(safe_path("src/main.rs"), Some("src/main.rs"));
        assert_eq!(safe_path("../etc/passwd"), None);
        assert_eq!(safe_path("/etc/passwd"), None);
        assert_eq!(safe_path("..\\etc\\passwd"), None);
    }

    #[tokio::test]
    async fn graph_has_the_branch_and_commits() {
        let directory = repo();
        let value = handle(
            directory.path().to_str().unwrap(),
            json!({ "op": "graph", "scope": "all", "limit": 10 }),
        )
        .await;
        assert_eq!(value.get("error"), None, "{value}");
        assert_eq!(value["commits"].as_array().unwrap().len(), 1);
        assert_eq!(value["commits"][0]["subject"], "first");
        assert!(!value["branch"].as_str().unwrap().is_empty());
        assert_eq!(value["uncommitted"], 1);
    }

    #[tokio::test]
    async fn workspace_lists_changed_files() {
        let directory = repo();
        let value = handle(
            directory.path().to_str().unwrap(),
            json!({ "op": "workspace" }),
        )
        .await;
        let changes = value["changes"].as_array().unwrap();
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0]["path"], "a.txt");
        assert_eq!(changes[0]["additions"], 1);
    }

    #[tokio::test]
    async fn commit_files_and_diff_read_a_commit() {
        let directory = repo();
        let output = Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(directory.path())
            .output()
            .expect("rev-parse");
        let hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let listed = handle(
            directory.path().to_str().unwrap(),
            json!({ "op": "files", "commit": hash, "parents": [] }),
        )
        .await;
        assert_eq!(listed["files"][0]["path"], "a.txt", "{listed}");
        let diff = handle(
            directory.path().to_str().unwrap(),
            json!({ "op": "diff", "commit": hash, "parents": [], "file": "a.txt" }),
        )
        .await;
        assert!(diff["text"].as_str().unwrap().contains("+one"), "{diff}");
    }

    #[tokio::test]
    async fn a_folder_outside_git_says_so() {
        let directory = tempfile::tempdir().expect("temp dir");
        let value = handle(directory.path().to_str().unwrap(), json!({ "op": "graph" })).await;
        assert!(value["error"].as_str().unwrap().contains("git"));
    }
}
