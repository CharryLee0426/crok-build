//! Photos and files sent with prompts (relay/DESIGN.md §2, "Photos and files"): downloading what another device
//! uploaded for a prompt, uploading the images of a prompt typed here, and the folder their files are saved in.

use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime};

use anyhow::{Context, anyhow, bail};
use futures::StreamExt;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::link::{CallKind, ToRelay};

/// What the relay takes per file.
pub const MAX_FILE_BYTES: usize = 20 * 1024 * 1024;
/// Saved files are kept this long (a session may read them again on a later turn).
const KEEP: Duration = Duration::from_secs(30 * 24 * 60 * 60);

fn http() -> anyhow::Result<&'static reqwest::Client> {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client);
    }
    let client = xai_grok_extra_ca::build_reqwest_client(|builder| {
        builder
            .timeout(Duration::from_secs(120))
            .connect_timeout(Duration::from_secs(10))
    })?;
    Ok(CLIENT.get_or_init(|| client))
}

/// Downloads an attachment from the relay's storage URL, refusing anything over `max` bytes.
pub async fn download(url: &str, max: usize) -> anyhow::Result<Vec<u8>> {
    let response = http()?.get(url).send().await?.error_for_status()?;
    if response
        .content_length()
        .is_some_and(|length| length > max as u64)
    {
        bail!("it is larger than {} MB", max / (1024 * 1024));
    }
    let mut bytes = Vec::new();
    let mut body = response.bytes_stream();
    while let Some(chunk) = body.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > max {
            bail!("it is larger than {} MB", max / (1024 * 1024));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

/// Uploads bytes to the relay's file storage (`files:uploadUrl`, then a `POST`) and returns the storage id, which a
/// transcript item names to claim it for its session.
pub async fn upload(
    link: &mpsc::UnboundedSender<ToRelay>,
    bytes: Vec<u8>,
    content_type: &str,
) -> anyhow::Result<String> {
    let (reply, answer) = oneshot::channel();
    link.send(ToRelay::Call {
        kind: CallKind::Mutation,
        path: "files:uploadUrl".into(),
        args: json!({}),
        reply,
    })
    .map_err(|_| anyhow!("the relay connection closed"))?;
    let target = tokio::time::timeout(Duration::from_secs(30), answer)
        .await
        .context("the relay did not answer")?
        .context("the relay connection closed")?
        .map_err(|error| anyhow!("{error}"))?;
    let target = target
        .get("url")
        .and_then(Value::as_str)
        .context("the relay gave no upload URL")?;
    let answer: Value = http()?
        .post(target)
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .body(bytes)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    answer
        .get("storageId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .context("the upload answered no storage id")
}

/// Where a prompt's files from other devices are saved: `$CROK_HOME/remote/attachments/<session>/<command>/`.
pub fn attachments_dir(session_id: &str, command_id: &str) -> PathBuf {
    crate::credentials::dir()
        .join("attachments")
        .join(safe_name(session_id))
        .join(safe_name(command_id))
}

/// A file name that is safe on disk and in an `@path` mention: no folders, no control characters, no whitespace.
pub fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = base
        .chars()
        .map(|c| {
            if c.is_whitespace() {
                '_'
            } else if c.is_control() || matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|') {
                '-'
            } else {
                c
            }
        })
        .collect();
    let clean = clean.trim_matches('.').to_string();
    if clean.is_empty() {
        return "file".into();
    }
    let mut cut = clean;
    while cut.len() > 120 {
        // Keep the extension: drop characters before it.
        let at = cut
            .rfind('.')
            .filter(|&i| cut.len() - i <= 16)
            .unwrap_or(cut.len());
        let Some((index, _)) = cut
            .get(..at)
            .and_then(|head| head.char_indices().next_back())
        else {
            break;
        };
        cut.remove(index);
    }
    cut
}

/// Deletes saved attachment folders not touched for 30 days (at most once per process start).
pub fn prune_saved() {
    let root = crate::credentials::dir().join("attachments");
    let Ok(sessions) = std::fs::read_dir(&root) else {
        return;
    };
    let now = SystemTime::now();
    for session in sessions.flatten() {
        let Ok(commands) = std::fs::read_dir(session.path()) else {
            continue;
        };
        let mut left = 0;
        for command in commands.flatten() {
            let old = command
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|time| now.duration_since(time).ok())
                .is_some_and(|age| age > KEEP);
            if old {
                let _ = std::fs::remove_dir_all(command.path());
            } else {
                left += 1;
            }
        }
        if left == 0 {
            let _ = std::fs::remove_dir(session.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_names_have_no_folders_or_spaces_and_keep_the_extension() {
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("My Report (final).pdf"), "My_Report_(final).pdf");
        assert_eq!(safe_name("C:\\Users\\x\\a b.txt"), "a_b.txt");
        assert_eq!(safe_name(".."), "file");
        assert_eq!(safe_name("what?.md"), "what-.md");
        let long = format!("{}.tar.gz", "a".repeat(200));
        let cut = safe_name(&long);
        assert_eq!(cut.len(), 120);
        assert!(cut.ends_with(".gz"));
        assert_eq!(safe_name("名前 です.png"), "名前_です.png");
    }
}
