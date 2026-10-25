//! The tags a session reports to Agent Observability with: `repo`, `branch` and `user`, which its
//! Coding agents view groups by. Read from the files under `.git`, without running git, so session
//! start does not wait on a subprocess.

use std::path::{Path, PathBuf};

/// Tags the session's generations, turns and tool runs with where it works and who runs it.
pub(crate) fn tag_session(session_id: &str, cwd: &Path) {
    if !xai_grok_sampler::observe::is_enabled() {
        return;
    }
    let repo = GitDirs::find(cwd);
    let name = repo.as_ref().and_then(GitDirs::origin_repo).or_else(|| {
        repo.as_ref()
            .and_then(|dirs| dirs.work_tree.file_name())
            .or_else(|| cwd.file_name())
            .map(|name| name.to_string_lossy().into_owned())
    });
    let branch = repo.as_ref().and_then(GitDirs::branch);
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .ok();
    for (key, value) in [("repo", name), ("branch", branch), ("user", user)] {
        if let Some(value) = value {
            xai_grok_sampler::observe::set_session_tag(session_id, key, &value);
        }
    }
}

/// A checkout's git directory (its own, for a linked worktree) and the shared one with `config`.
struct GitDirs {
    work_tree: PathBuf,
    git_dir: PathBuf,
    common_dir: PathBuf,
}

impl GitDirs {
    fn find(start: &Path) -> Option<Self> {
        for dir in start.ancestors() {
            let dot_git = dir.join(".git");
            if dot_git.is_dir() {
                return Some(Self {
                    work_tree: dir.to_owned(),
                    git_dir: dot_git.clone(),
                    common_dir: dot_git,
                });
            }
            if dot_git.is_file() {
                // A linked worktree: `.git` says `gitdir: <main>/.git/worktrees/<name>`.
                let text = std::fs::read_to_string(&dot_git).ok()?;
                let target = text.trim().strip_prefix("gitdir:")?.trim();
                let git_dir = dir.join(target);
                let common_dir = std::fs::read_to_string(git_dir.join("commondir"))
                    .ok()
                    .map(|common| git_dir.join(common.trim()))
                    .unwrap_or_else(|| git_dir.clone());
                return Some(Self {
                    work_tree: dir.to_owned(),
                    git_dir,
                    common_dir,
                });
            }
        }
        None
    }

    /// The checked-out branch; `None` on a detached HEAD.
    fn branch(&self) -> Option<String> {
        let head = std::fs::read_to_string(self.git_dir.join("HEAD")).ok()?;
        let branch = head.trim().strip_prefix("ref: refs/heads/")?;
        (!branch.is_empty()).then(|| branch.to_owned())
    }

    /// `owner/name` of the `origin` remote, without credentials or a `.git` suffix.
    fn origin_repo(&self) -> Option<String> {
        let config = std::fs::read_to_string(self.common_dir.join("config")).ok()?;
        let mut in_origin = false;
        for line in config.lines().map(str::trim) {
            if line.starts_with('[') {
                in_origin = line == "[remote \"origin\"]";
                continue;
            }
            if in_origin
                && let Some((key, value)) = line.split_once('=')
                && key.trim() == "url"
            {
                return repo_from_url(value.trim());
            }
        }
        None
    }
}

/// `https://github.com/owner/name.git`, `git@github.com:owner/name` → `owner/name`.
fn repo_from_url(url: &str) -> Option<String> {
    let path = match url.split_once("://") {
        Some((_, rest)) => rest.split_once('/').map(|(_, path)| path)?,
        None => url.split_once(':').map(|(_, path)| path)?,
    };
    let path = path.trim_end_matches('/').trim_end_matches(".git");
    let mut parts = path.rsplit('/');
    let name = parts.next().filter(|name| !name.is_empty())?;
    match parts.next().filter(|owner| !owner.is_empty()) {
        Some(owner) => Some(format!("{owner}/{name}")),
        None => Some(name.to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_urls_become_owner_and_name() {
        assert_eq!(
            repo_from_url("https://github.com/CharryLee0426/crok-build.git").as_deref(),
            Some("CharryLee0426/crok-build")
        );
        assert_eq!(
            repo_from_url("git@github.com:CharryLee0426/crok-build").as_deref(),
            Some("CharryLee0426/crok-build")
        );
        assert_eq!(
            repo_from_url("https://user:token@example.com/a/b/c.git/").as_deref(),
            Some("b/c")
        );
        assert_eq!(repo_from_url("not a url"), None);
    }

    #[test]
    fn a_linked_worktree_reads_its_own_head_and_the_shared_config() {
        let root = tempfile::tempdir().unwrap();
        let main = root.path().join("main");
        let git = main.join(".git");
        std::fs::create_dir_all(git.join("worktrees/wt")).unwrap();
        std::fs::write(git.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(
            git.join("config"),
            "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:me/proj.git\n",
        )
        .unwrap();
        std::fs::write(git.join("worktrees/wt/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
        std::fs::write(git.join("worktrees/wt/commondir"), "../..\n").unwrap();
        let wt = root.path().join("wt");
        std::fs::create_dir_all(wt.join("src")).unwrap();
        std::fs::write(
            wt.join(".git"),
            format!("gitdir: {}\n", git.join("worktrees/wt").display()),
        )
        .unwrap();

        let dirs = GitDirs::find(&wt.join("src")).unwrap();
        assert_eq!(dirs.branch().as_deref(), Some("feature/x"));
        assert_eq!(dirs.origin_repo().as_deref(), Some("me/proj"));
        let main_dirs = GitDirs::find(&main).unwrap();
        assert_eq!(main_dirs.branch().as_deref(), Some("main"));
    }
}
