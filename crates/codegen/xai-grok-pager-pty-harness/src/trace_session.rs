//! Materialize a recorded session from a `crok trace` export into a sandbox crok home, so a PTY scenario can `--resume` it.
//!
//! The trace export (`trace-exports/<id>.html` or its embedded `trace-data` JSON) carries every persisted session file as `events`.
//! Each event has `source` (the file name), `line` (1-based line in that file), `index` (global order), and `raw` (the record).
//! JSONL files can fan out into several events per line (an assistant record plus one event per tool call); the first event by `index` holds the full record.
//! Whole-file JSON artifacts (`summary.json`, `signals.json`, ...) are under `artifacts` as `{name, content}`.
//!
//! Resume needs `summary.json` (session discovery by id), `updates.jsonl` (the ACP history the agent replays to the TUI), and `chat_history.jsonl` (model context).
//! [`TraceSession::materialize`] writes those by default; [`MaterializeOptions::all_files`] also writes every other recorded file.
//! Every occurrence of the recorded cwd is rewritten to the sandbox cwd so tool paths render relative to the project like they did live.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::Value;

const TRACE_DATA_OPEN: &str = r#"<script type="application/json" id="trace-data">"#;
const SCRIPT_CLOSE: &str = "</script>";

/// Files [`TraceSession::materialize`] writes when [`MaterializeOptions::all_files`] is off.
const MINIMAL_FILES: &[&str] = &["updates.jsonl", "chat_history.jsonl", "summary.json"];

/// A recorded session parsed out of a trace export.
pub struct TraceSession {
    pub session_id: String,
    /// The cwd the session was recorded in (rewritten on materialize).
    pub original_cwd: String,
    /// `source` → lines in file order (JSONL files, one serialized record per line).
    jsonl: BTreeMap<String, Vec<String>>,
    /// `name` → file bytes (whole-file artifacts).
    artifacts: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MaterializeOptions {
    /// Write every recorded file (events.jsonl, rewind points, terminal logs, ...) instead of the minimal resume set.
    pub all_files: bool,
}

/// What [`TraceSession::materialize`] wrote.
#[derive(Debug, Clone)]
pub struct SeededSession {
    pub session_id: String,
    pub session_dir: PathBuf,
    pub cwd: PathBuf,
    pub updates_lines: usize,
    pub updates_bytes: u64,
    pub files_written: Vec<String>,
}

impl TraceSession {
    /// Load a trace export: either the `.html` viewer (with an embedded `trace-data` script) or the bare JSON.
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("read trace export {}", path.display()))?;
        let json = extract_trace_json(&text)
            .with_context(|| format!("locate trace JSON in {}", path.display()))?;
        let value: Value = serde_json::from_str(json)
            .with_context(|| format!("parse trace JSON from {}", path.display()))?;
        Self::from_value(value)
    }

    pub fn from_value(value: Value) -> Result<Self> {
        let session_id = value
            .get("session_id")
            .and_then(Value::as_str)
            .context("trace JSON has no session_id")?
            .to_owned();
        let original_cwd = value
            .get("cwd")
            .and_then(Value::as_str)
            .context("trace JSON has no cwd")?
            .to_owned();
        let events = value
            .get("events")
            .and_then(Value::as_array)
            .context("trace JSON has no events array")?;

        // source -> line -> (index, raw); keep the lowest-index event per line.
        let mut by_line: BTreeMap<String, BTreeMap<u64, (u64, &Value)>> = BTreeMap::new();
        for event in events {
            let Some(source) = event.get("source").and_then(Value::as_str) else {
                continue;
            };
            if !source.ends_with(".jsonl") {
                continue;
            }
            let (Some(line), Some(raw)) = (event.get("line").and_then(as_u64), event.get("raw"))
            else {
                continue;
            };
            let index = event.get("index").and_then(as_u64).unwrap_or(u64::MAX);
            let slot = by_line
                .entry(source.to_owned())
                .or_default()
                .entry(line)
                .or_insert((index, raw));
            if index < slot.0 {
                *slot = (index, raw);
            }
        }
        let mut jsonl = BTreeMap::new();
        for (source, lines) in by_line {
            let mut out = Vec::with_capacity(lines.len());
            for (_, raw) in lines.into_values() {
                out.push(match raw {
                    // An unparseable recorded line is kept verbatim.
                    Value::String(s) => s.clone(),
                    other => serde_json::to_string(other).context("serialize JSONL record")?,
                });
            }
            jsonl.insert(source, out);
        }

        let mut artifacts = BTreeMap::new();
        for artifact in value
            .get("artifacts")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
            let Some(name) = artifact.get("name").and_then(Value::as_str) else {
                continue;
            };
            let body = match artifact.get("content") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Null) | None => continue,
                Some(other) => serde_json::to_string_pretty(other).context("serialize artifact")?,
            };
            artifacts.insert(name.to_owned(), body);
        }

        if !jsonl.contains_key("updates.jsonl") {
            bail!("trace has no updates.jsonl records; nothing to replay");
        }
        if !artifacts.contains_key("summary.json") {
            bail!("trace has no summary.json artifact; resume cannot discover the session");
        }
        Ok(Self {
            session_id,
            original_cwd,
            jsonl,
            artifacts,
        })
    }

    /// Recorded `updates.jsonl` lines (serialized records, file order).
    pub fn updates_lines(&self) -> &[String] {
        self.jsonl
            .get("updates.jsonl")
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    /// Text of the last recorded `agent_message_chunk`, the tail a resumed TUI shows at the bottom.
    pub fn last_agent_message(&self) -> Option<String> {
        self.updates_lines().iter().rev().find_map(|line| {
            let v: Value = serde_json::from_str(line).ok()?;
            let update = v.get("params")?.get("update")?;
            (update.get("sessionUpdate")?.as_str()? == "agent_message_chunk")
                .then(|| {
                    update
                        .get("content")?
                        .get("text")?
                        .as_str()
                        .map(str::to_owned)
                })
                .flatten()
        })
    }

    /// Write the session under `grok_home/sessions/<encoded cwd>/<session id>/`, rewriting the recorded cwd to `cwd`.
    pub fn materialize(
        &self,
        grok_home: &Path,
        cwd: &Path,
        options: MaterializeOptions,
    ) -> Result<SeededSession> {
        let cwd_str = cwd
            .to_str()
            .context("sandbox cwd is not valid UTF-8")?
            .to_owned();
        let session_dir = grok_home
            .join("sessions")
            .join(encode_cwd_dirname(&cwd_str))
            .join(&self.session_id);
        std::fs::create_dir_all(&session_dir)
            .with_context(|| format!("create {}", session_dir.display()))?;
        let rewrite = |s: &str| s.replace(&self.original_cwd, &cwd_str);
        let wanted = |name: &str| options.all_files || MINIMAL_FILES.contains(&name);

        let mut files_written = Vec::new();
        let mut updates_lines = 0;
        let mut updates_bytes = 0;
        for (name, lines) in &self.jsonl {
            if !wanted(name) {
                continue;
            }
            let mut body = String::with_capacity(lines.iter().map(|l| l.len() + 1).sum());
            for line in lines {
                body.push_str(&rewrite(line));
                body.push('\n');
            }
            if name == "updates.jsonl" {
                updates_lines = lines.len();
                updates_bytes = body.len() as u64;
            }
            write_file(&session_dir, name, &body)?;
            files_written.push(name.clone());
        }
        for (name, body) in &self.artifacts {
            if !wanted(name) {
                continue;
            }
            let body = if name == "summary.json" {
                rewrite_summary(body, &cwd_str, grok_home)?
            } else {
                rewrite(body)
            };
            write_file(&session_dir, name, &body)?;
            files_written.push(name.clone());
        }
        Ok(SeededSession {
            session_id: self.session_id.clone(),
            session_dir,
            cwd: cwd.to_path_buf(),
            updates_lines,
            updates_bytes,
            files_written,
        })
    }
}

fn write_file(session_dir: &Path, name: &str, body: &str) -> Result<()> {
    // Names come from the trace (`terminal/<id>.log`); refuse anything that escapes the session dir.
    if Path::new(name)
        .components()
        .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        bail!("refusing to write trace file with unsafe name {name:?}");
    }
    let path = session_dir.join(name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    std::fs::write(&path, body).with_context(|| format!("write {}", path.display()))
}

/// Point `info.cwd` / `grok_home` at the sandbox and drop repo fields that name the recording machine's checkout.
fn rewrite_summary(body: &str, cwd: &str, grok_home: &Path) -> Result<String> {
    let mut summary: Value = serde_json::from_str(body).context("parse summary.json artifact")?;
    let obj = summary
        .as_object_mut()
        .context("summary.json is not an object")?;
    if let Some(info) = obj.get_mut("info").and_then(Value::as_object_mut) {
        info.insert("cwd".into(), Value::String(cwd.to_owned()));
    }
    obj.insert(
        "grok_home".into(),
        Value::String(grok_home.to_string_lossy().into_owned()),
    );
    for key in ["git_root_dir", "git_remotes", "head_commit", "head_branch"] {
        obj.remove(key);
    }
    serde_json::to_string_pretty(&summary).context("serialize summary.json")
}

fn as_u64(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn extract_trace_json(text: &str) -> Result<&str> {
    let trimmed = text.trim_start();
    if trimmed.starts_with('{') {
        return Ok(trimmed);
    }
    let start = text
        .find(TRACE_DATA_OPEN)
        .context("no <script id=\"trace-data\"> block (and the file is not bare JSON)")?
        + TRACE_DATA_OPEN.len();
    let len = text[start..]
        .find(SCRIPT_CLOSE)
        .context("unterminated trace-data script block")?;
    Ok(&text[start..start + len])
}

/// Mirror of `xai_grok_config::paths::encode_cwd_dirname` for short cwds (`urlencoding::encode`: keep `[A-Za-z0-9-_.~]`).
/// Long cwds use a hashed form there; the sandbox cwd is always well under the 255-byte limit.
fn encode_cwd_dirname(cwd: &str) -> String {
    let mut out = String::with_capacity(cwd.len() * 3);
    for b in cwd.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::json!({
            "session_id": "sid-1",
            "cwd": "/rec/proj",
            "events": [
                {"index": 3, "source": "chat_history.jsonl", "line": 1, "raw": {"type": "assistant", "tool_calls": [1]}},
                {"index": 4, "source": "chat_history.jsonl", "line": 1, "raw": {"id": "tool"}},
                {"index": 1, "source": "updates.jsonl", "line": 2, "raw": {"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "tail in /rec/proj/x"}}}}},
                {"index": 0, "source": "updates.jsonl", "line": 1, "raw": {"method": "session/update", "params": {"update": {"sessionUpdate": "user_message_chunk"}}}},
                {"index": 9, "source": "events.jsonl", "line": 1, "raw": {"type": "x"}},
            ],
            "artifacts": [
                {"name": "summary.json", "content": {"info": {"id": "sid-1", "cwd": "/rec/proj"}, "git_root_dir": "/rec/proj"}},
                {"name": "terminal/a.log", "content": "log"},
            ],
        })
    }

    #[test]
    fn materialize_writes_minimal_set_with_rewritten_cwd() {
        let trace = TraceSession::from_value(fixture()).unwrap();
        assert_eq!(
            trace.last_agent_message().as_deref(),
            Some("tail in /rec/proj/x")
        );
        let home = tempfile::tempdir().unwrap();
        let seeded = trace
            .materialize(
                home.path(),
                Path::new("/new/cwd"),
                MaterializeOptions::default(),
            )
            .unwrap();
        assert_eq!(
            seeded.session_dir,
            home.path().join("sessions/%2Fnew%2Fcwd/sid-1")
        );
        let updates = std::fs::read_to_string(seeded.session_dir.join("updates.jsonl")).unwrap();
        let lines: Vec<_> = updates.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("user_message_chunk"));
        assert!(lines[1].contains("/new/cwd/x"));
        let chat = std::fs::read_to_string(seeded.session_dir.join("chat_history.jsonl")).unwrap();
        assert!(chat.contains("tool_calls"), "{chat}");
        let summary: Value = serde_json::from_str(
            &std::fs::read_to_string(seeded.session_dir.join("summary.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(summary["info"]["cwd"], "/new/cwd");
        assert!(summary.get("git_root_dir").is_none());
        assert!(!seeded.session_dir.join("events.jsonl").exists());
        assert!(!seeded.session_dir.join("terminal/a.log").exists());
    }

    #[test]
    fn extracts_json_from_html_viewer() {
        let html = format!(
            "<html><script type=\"application/json\" id=\"trace-data\">{}</script></html>",
            fixture()
        );
        let json = extract_trace_json(&html).unwrap();
        assert!(TraceSession::from_value(serde_json::from_str(json).unwrap()).is_ok());
    }
}
