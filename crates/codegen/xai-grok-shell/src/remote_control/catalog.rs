//! The catalog: every session on this computer's disk, so phones and the web list all of them, not only the ones a
//! running crok mirrors (`relay/DESIGN.md` §2, "Every session, not only running ones").

use std::path::{Path, PathBuf};

use crok_remote::types::CatalogEntry;

use crate::session::persistence::{self, Summary};

const PREVIEW_MAX: usize = 280;

/// Every listable session on disk, newest first; `None` when the sessions folder cannot be read (the relay must not
/// take that for "everything was deleted").
pub(crate) async fn list() -> Option<Vec<CatalogEntry>> {
    match persistence::list_summaries(None).await {
        Ok(summaries) => Some(entries(&summaries, &temp_roots())),
        Err(error) => {
            tracing::debug!(%error, "remote control: cannot list sessions");
            None
        }
    }
}

/// The catalog rows for these summaries: not hidden ones (subagents), headless runs, unused husks, or sessions under
/// the system's temp folder (test runs and scratch checkouts).
pub(crate) fn entries(summaries: &[Summary], temp_roots: &[PathBuf]) -> Vec<CatalogEntry> {
    summaries
        .iter()
        .filter(|s| !s.is_hidden() && !s.is_headless() && !s.is_unused_optimistic_husk())
        .filter(|s| !s.info.cwd.is_empty() && !under_any(&s.info.cwd, temp_roots))
        .map(entry)
        .collect()
}

fn entry(summary: &Summary) -> CatalogEntry {
    let preview = summary
        .last_turn_summary
        .as_deref()
        .or(summary.last_recap.as_deref())
        .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|text| !text.is_empty())
        .map(|text| super::transcript::shorten(&text, PREVIEW_MAX));
    CatalogEntry {
        session_id: summary.info.id.0.to_string(),
        title: summary.display_title_opt().unwrap_or_default(),
        cwd: summary.info.cwd.clone(),
        project_path: project_path(summary),
        created_at: summary.created_at.timestamp_millis() as f64,
        last_activity_at: summary.last_change_unix_ms() as f64,
        model: Some(summary.current_model_id.0.to_string()).filter(|m| !m.is_empty()),
        effort: summary
            .reasoning_effort
            .as_ref()
            .and_then(|e| serde_json::to_value(e).ok())
            .and_then(|v| v.as_str().map(str::to_owned)),
        git_branch: summary
            .head_branch
            .clone()
            .filter(|b| !b.is_empty() && b != "HEAD"),
        preview,
    }
}

/// The project a session is grouped under: a crok worktree's source workspace, else its git root, else its folder.
pub(crate) fn project_path(summary: &Summary) -> String {
    [
        summary.source_workspace_dir.as_deref(),
        summary.git_root_dir.as_deref(),
        Some(summary.info.cwd.as_str()),
    ]
    .into_iter()
    .flatten()
    .find_map(clean_path)
    .unwrap_or_else(|| "/".to_string())
}

/// Without a trailing slash (`/repo/` and `/repo` are one project); `None` for an empty path.
fn clean_path(path: &str) -> Option<String> {
    let path = path.trim();
    if path.is_empty() {
        return None;
    }
    let trimmed = path.trim_end_matches(['/', '\\']);
    Some(if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    })
}

/// The system's temp folders, as given and as resolved (`/var/folders/…` is `/private/var/folders/…` on macOS).
fn temp_roots() -> Vec<PathBuf> {
    let mut roots = vec![std::env::temp_dir()];
    if let Ok(resolved) = std::env::temp_dir().canonicalize() {
        roots.push(resolved);
    }
    if cfg!(unix) {
        roots.push(PathBuf::from("/tmp"));
        roots.push(PathBuf::from("/private/tmp"));
    }
    roots.retain(|root| root.components().count() > 1);
    roots
}

fn under_any(cwd: &str, roots: &[PathBuf]) -> bool {
    let cwd = Path::new(cwd);
    roots.iter().any(|root| cwd.starts_with(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn summary(extra: serde_json::Value) -> Summary {
        let mut value = json!({
            "info": { "id": "01a1386a-ba3c-71f1-83fc-f67fabd04c5b", "cwd": "/Users/ada/code/crok" },
            "session_summary": "Fix the build",
            "created_at": "2026-10-14T03:18:01Z",
            "updated_at": "2026-10-14T03:36:45Z",
            "num_messages": 12,
            "current_model_id": "anthropic/claude-opus-5-5",
        });
        if let (Some(base), Some(extra)) = (value.as_object_mut(), extra.as_object()) {
            for (key, field) in extra {
                base.insert(key.clone(), field.clone());
            }
        }
        serde_json::from_value(value).expect("a summary")
    }

    #[test]
    fn a_session_becomes_a_catalog_row() {
        let rows = entries(
            &[summary(json!({
                "generated_title": "Fix the release build",
                "last_active_at": "2026-10-14T04:00:00Z",
                "head_branch": "main",
                "reasoning_effort": "max",
                "last_turn_summary": "Fixed  the\nlinker flags",
            }))],
            &[],
        );
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(row.session_id, "01a1386a-ba3c-71f1-83fc-f67fabd04c5b");
        assert_eq!(row.title, "Fix the release build");
        assert_eq!(row.project_path, "/Users/ada/code/crok");
        assert_eq!(row.model.as_deref(), Some("anthropic/claude-opus-5-5"));
        assert_eq!(row.effort.as_deref(), Some("max"));
        assert_eq!(row.git_branch.as_deref(), Some("main"));
        assert_eq!(row.preview.as_deref(), Some("Fixed the linker flags"));
        assert_eq!(row.created_at, 1_791_947_881_000.0);
        assert_eq!(row.last_activity_at, 1_791_950_400_000.0);
    }

    #[test]
    fn projects_follow_the_worktree_source_then_the_git_root() {
        let worktree = summary(json!({
            "session_kind": "worktree",
            "source_workspace_dir": "/Users/ada/code/crok/",
            "git_root_dir": "/Users/ada/.crok/worktrees/crok/feature/",
        }));
        assert_eq!(project_path(&worktree), "/Users/ada/code/crok");
        let nested = summary(json!({
            "info": { "id": "x", "cwd": "/Users/ada/code/crok/crates/remote" },
            "git_root_dir": "/Users/ada/code/crok/",
        }));
        assert_eq!(project_path(&nested), "/Users/ada/code/crok");
        let plain = summary(json!({ "info": { "id": "y", "cwd": "/Users/ada/notes/" } }));
        assert_eq!(project_path(&plain), "/Users/ada/notes");
    }

    #[test]
    fn hidden_headless_husks_and_temp_folders_are_left_out() {
        let temp = vec![PathBuf::from("/private/var/folders/hk/T")];
        let rows = entries(
            &[
                summary(json!({ "session_kind": "subagent" })),
                summary(json!({ "session_kind": "headless" })),
                summary(json!({ "session_summary": "", "num_messages": 0 })),
                summary(
                    json!({ "info": { "id": "t", "cwd": "/private/var/folders/hk/T/.tmpAb12/repo" } }),
                ),
                summary(json!({ "info": { "id": "kept", "cwd": "/Users/ada/code/crok" } })),
            ],
            &temp,
        );
        assert_eq!(
            rows.iter()
                .map(|r| r.session_id.as_str())
                .collect::<Vec<_>>(),
            ["kept"]
        );
    }
}
