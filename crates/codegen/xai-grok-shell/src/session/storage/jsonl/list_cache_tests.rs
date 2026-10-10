//! A listing parses a `summary.json` once and reuses it until the file changes.

use agent_client_protocol as acp;
use serial_test::serial;
use tempfile::TempDir;
use xai_grok_test_support::EnvGuard;

use crate::session::info::Info;
use crate::session::persistence::{Summary, default_model_id};
use crate::session::storage::{JsonlStorageAdapter, StorageAdapter};

fn write_summary(session_dir: &std::path::Path, info: &Info, num_messages: usize) {
    std::fs::create_dir_all(session_dir).unwrap();
    let mut summary = Summary::new(info, default_model_id()).unwrap();
    summary.num_messages = num_messages;
    std::fs::write(
        session_dir.join("summary.json"),
        serde_json::to_vec_pretty(&summary).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
#[serial]
async fn list_sessions_reuses_a_parsed_summary_until_the_file_changes() {
    let home = TempDir::new().unwrap();
    let _env = EnvGuard::set("GROK_HOME", home.path());
    let cwd = home.path().join("project");
    std::fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.to_string_lossy().into_owned();
    let adapter = JsonlStorageAdapter::with_root(home.path().to_path_buf());
    let infos: Vec<Info> = (0..3)
        .map(|i| Info {
            id: acp::SessionId::new(format!("cached-{i}")),
            cwd: cwd.clone(),
        })
        .collect();
    for (i, info) in infos.iter().enumerate() {
        write_summary(&adapter.session_dir(info), info, i);
    }

    let first = adapter.list_sessions(None).await.unwrap();
    assert_eq!(first.len(), 3);
    let second = adapter.list_sessions(None).await.unwrap();
    assert_eq!(
        second.iter().map(|s| s.num_messages).collect::<Vec<_>>(),
        first.iter().map(|s| s.num_messages).collect::<Vec<_>>(),
        "an unchanged store lists the same rows"
    );

    // A rewrite with a different length is seen on the next listing.
    let target = infos.get(1).unwrap();
    write_summary(&adapter.session_dir(target), target, 1234);
    let third = adapter.list_sessions(None).await.unwrap();
    assert_eq!(
        third
            .iter()
            .find(|s| s.info.id == target.id)
            .map(|s| s.num_messages),
        Some(1234),
        "a changed summary is read again"
    );

    // A removed session leaves the listing although its summary was cached.
    std::fs::remove_dir_all(adapter.session_dir(infos.get(2).unwrap())).unwrap();
    let fourth = adapter.list_sessions(None).await.unwrap();
    assert_eq!(
        fourth.len(),
        2,
        "a deleted session is gone: {:?}",
        fourth
            .iter()
            .map(|s| s.info.id.0.to_string())
            .collect::<Vec<_>>()
    );

    // A session hidden after it was cached disappears too.
    let hidden = infos.first().unwrap();
    let mut summary: Summary = serde_json::from_slice(
        &std::fs::read(adapter.session_dir(hidden).join("summary.json")).unwrap(),
    )
    .unwrap();
    summary.hidden = Some(true);
    std::fs::write(
        adapter.session_dir(hidden).join("summary.json"),
        serde_json::to_vec_pretty(&summary).unwrap(),
    )
    .unwrap();
    let fifth = adapter.list_sessions(None).await.unwrap();
    assert_eq!(fifth.len(), 1, "a hidden session is gone");
}
