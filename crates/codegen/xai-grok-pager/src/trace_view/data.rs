//! Read-only, format-tolerant projection of the records the harness actually saved.
//! Missing timings and usage stay unknown; raw records retain their source and line.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Component, Path};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::transcript::{self, TranscriptEntry};

const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ARCHIVE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_FILES: usize = 4096;
const MAX_RECORDS: usize = 100_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceData {
    pub schema_version: u32,
    pub source: String,
    pub session_id: String,
    pub title: String,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
    pub summary: TraceSummary,
    pub events: Vec<TraceEvent>,
    pub turns: Vec<TraceTurn>,
    pub tools: Vec<TraceTool>,
    pub artifacts: Vec<TraceArtifact>,
    pub warnings: Vec<String>,
    /// The recorded conversation placed on recorded timing; `events` keeps every raw record.
    #[serde(default)]
    pub transcript: Vec<TranscriptEntry>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TraceSummary {
    pub event_count: usize,
    pub turn_count: usize,
    pub tool_count: usize,
    pub error_count: usize,
    pub duration_ms: Option<u64>,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cached_input_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceEvent {
    pub index: usize,
    pub source: String,
    pub line: Option<usize>,
    pub kind: String,
    pub title: String,
    pub text: String,
    pub timestamp: Option<String>,
    pub elapsed_ms: Option<u64>,
    pub duration_ms: Option<u64>,
    pub turn: Option<u64>,
    pub tool_call_id: Option<String>,
    pub status: Option<String>,
    /// How much of the record's reasoning can be read.
    #[serde(default)]
    pub encryption: Encryption,
    pub raw: Value,
}

/// How much of a reasoning record, or of a transcript entry built from records, can be read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Encryption {
    /// Readable, or not reasoning.
    #[default]
    None,
    /// Readable text, usually a summary, came with an encrypted copy of the full reasoning.
    Partial,
    /// Only encrypted reasoning was recorded.
    Full,
}

impl Encryption {
    pub fn is_encrypted(self) -> bool {
        self != Self::None
    }

    /// The stronger classification. Fully sealed reasoning wins over a readable summary.
    pub fn join(self, other: Self) -> Self {
        match (self, other) {
            (Self::Full, _) | (_, Self::Full) => Self::Full,
            (Self::Partial, _) | (_, Self::Partial) => Self::Partial,
            _ => Self::None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceTool {
    pub id: String,
    pub name: String,
    pub turn: Option<u64>,
    pub status: String,
    pub input: Option<Value>,
    pub output: Option<Value>,
    pub duration_ms: Option<u64>,
    pub event_indices: Vec<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceTurn {
    pub number: u64,
    pub model: Option<String>,
    pub status: Option<String>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub duration_ms: Option<u64>,
    pub event_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceArtifact {
    pub name: String,
    pub content: Value,
}

#[derive(Default)]
struct Input {
    files: BTreeMap<String, Vec<u8>>,
    bytes: u64,
    entries: usize,
    warnings: Vec<String>,
}

impl Input {
    fn accept(&mut self, name: String, reader: impl Read, size: u64) -> Result<()> {
        if size > MAX_FILE_BYTES || self.bytes.saturating_add(size) > MAX_TOTAL_BYTES {
            self.warnings.push(format!(
                "Skipped {name}: trace input size limit (32 MiB per file, 128 MiB total)."
            ));
            return Ok(());
        }
        let mut bytes = Vec::new();
        reader.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_FILE_BYTES
            || self.bytes.saturating_add(bytes.len() as u64) > MAX_TOTAL_BYTES
        {
            self.warnings.push(format!(
                "Skipped {name}: file grew beyond the trace input size limit."
            ));
            return Ok(());
        }
        self.bytes += bytes.len() as u64;
        match self.files.entry(name) {
            std::collections::btree_map::Entry::Occupied(entry) => {
                self.warnings
                    .push(format!("Ignored duplicate archive entry {}.", entry.key()));
            }
            std::collections::btree_map::Entry::Vacant(entry) => {
                entry.insert(bytes);
            }
        }
        Ok(())
    }

    fn directory(&mut self, root: &Path, directory: &Path, depth: usize) -> Result<()> {
        if depth > 8 {
            self.warnings.push(format!(
                "Skipped deeply nested directory {}.",
                directory.display()
            ));
            return Ok(());
        }
        let mut entries = fs::read_dir(directory)?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            self.entries += 1;
            if self.entries > MAX_FILES {
                bail!(
                    "Trace has more than {MAX_FILES} directory entries; select a smaller session directory"
                );
            }
            let path = entry.path();
            let name = path
                .strip_prefix(root)?
                .to_string_lossy()
                .replace('\\', "/");
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                self.warnings.push(format!(
                    "Skipped symlink {name}; linked files are not followed."
                ));
            } else if file_type.is_dir() {
                if entry.file_name() != ".git" {
                    self.directory(root, &path, depth + 1)?;
                }
            } else if file_type.is_file() && supported(&path) {
                let size = entry.metadata()?.len();
                self.accept(name, File::open(path)?, size)?;
            }
        }
        Ok(())
    }

    fn archive(&mut self, path: &Path) -> Result<()> {
        // Never extract an archive. Bound the entire decompressed stream, including
        // ignored members, so a huge padding/binary member cannot bypass limits.
        let decoder = flate2::read::GzDecoder::new(File::open(path)?);
        let mut archive = tar::Archive::new(decoder.take(MAX_ARCHIVE_BYTES + 1));
        for entry in archive.entries()? {
            self.entries += 1;
            if self.entries > MAX_FILES {
                bail!("Trace archive has more than {MAX_FILES} entries");
            }
            let mut entry =
                entry.context("Invalid or oversized trace archive (256 MiB decompressed limit)")?;
            let path = entry.path()?.into_owned();
            if path
                .components()
                .any(|part| !matches!(part, Component::Normal(_) | Component::CurDir))
            {
                bail!("Unsafe path in trace archive: {}", path.display());
            }
            let name = path.to_string_lossy().replace('\\', "/");
            if entry.header().entry_type().is_dir() {
                continue;
            }
            if !entry.header().entry_type().is_file() {
                self.warnings
                    .push(format!("Skipped non-file archive entry {name}."));
                continue;
            }
            if supported(&path) {
                let size = entry.size();
                self.accept(name, &mut entry, size)?;
            }
        }
        if archive.into_inner().limit() == 0 {
            bail!("Trace archive exceeds 256 MiB decompressed limit");
        }
        Ok(())
    }
}

fn supported(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("json" | "jsonl" | "txt" | "log" | "md" | "patch" | "diff")
    )
}

/// Load a session directory, its summary file, JSON/JSONL records, or a local
/// `grok trace --local` tar.gz. This function does not modify or upload anything.
pub fn load(source: &Path) -> Result<TraceData> {
    let mut input = Input::default();
    let meta = fs::symlink_metadata(source)
        .with_context(|| format!("Cannot open trace {}", source.display()))?;
    if meta.file_type().is_symlink() {
        bail!("Trace source is a symlink; provide its actual file or directory path");
    }
    if meta.is_dir() {
        input.directory(source, source, 0)?;
    } else if source.file_name().and_then(|name| name.to_str()) == Some("summary.json") {
        let parent = source.parent().unwrap_or_else(|| Path::new("."));
        input.directory(parent, parent, 0)?;
    } else if source.to_string_lossy().ends_with(".tar.gz")
        || source.extension().and_then(|ext| ext.to_str()) == Some("tgz")
    {
        input.archive(source)?;
    } else if meta.is_file() && supported(source) {
        let name = source
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        input.accept(name, File::open(source)?, meta.len())?;
    } else {
        bail!("Expected a session directory, JSON/JSONL file, or .tar.gz trace export");
    }
    if input.files.is_empty() {
        bail!("No readable trace records found in {}", source.display());
    }
    build(source, input)
}

fn build(source: &Path, input: Input) -> Result<TraceData> {
    if input.files.len() == 1
        && let Some((name, bytes)) = input.files.first_key_value()
        && name.ends_with(".json")
        && let Ok(value) = serde_json::from_slice::<Value>(bytes)
        && value.get("schema_version").is_some()
        && value.get("events").is_some()
        && value.get("summary").is_some()
        && value.get("tools").is_some()
    {
        let mut saved: TraceData =
            serde_json::from_value(value).context("Invalid normalized trace JSON")?;
        if saved.schema_version != 1 {
            bail!(
                "Unsupported normalized trace schema version {}",
                saved.schema_version
            );
        }
        if saved.events.len() > MAX_RECORDS {
            bail!("Trace exceeds {MAX_RECORDS} records");
        }
        if saved.tools.iter().any(|tool| {
            tool.event_indices
                .iter()
                .any(|index| *index >= saved.events.len())
        }) {
            bail!("Normalized trace contains an invalid tool event reference");
        }
        for (index, event) in saved.events.iter_mut().enumerate() {
            event.index = index;
        }
        saved.source = source.display().to_string();
        saved.warnings.extend(input.warnings);
        refresh_encryption(&mut saved);
        if saved.transcript.is_empty() {
            let (entries, notes) = transcript::build(&saved);
            saved.transcript = entries;
            saved.warnings.extend(notes);
        }
        return Ok(saved);
    }
    let mut data = TraceData {
        schema_version: 1,
        source: source.display().to_string(),
        session_id: source
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        title: "Agent trace".into(),
        model: None,
        cwd: None,
        created_at: None,
        updated_at: None,
        summary: TraceSummary::default(),
        events: vec![],
        turns: vec![],
        tools: vec![],
        artifacts: vec![],
        warnings: input.warnings,
        transcript: vec![],
    };
    let summary_name = shortest_named(&input.files, "summary.json");
    let usage_name = shortest_named(&input.files, "usage.json");
    let export_name = shortest_named(&input.files, "export_metadata.json");
    for (name, bytes) in input.files {
        let text = String::from_utf8_lossy(&bytes);
        if matches!(text, std::borrow::Cow::Owned(_)) {
            data.warnings.push(format!(
                "{name} contains invalid UTF-8; replacement characters are shown."
            ));
        }
        if name.split('/').any(|part| part == "compaction_checkpoints") {
            // Historical records must not inflate the live timeline or metrics.
            let value = if name.ends_with(".json") {
                serde_json::from_str(&text).unwrap_or_else(|_| Value::String(text.into_owned()))
            } else {
                Value::String(text.into_owned())
            };
            add_artifact_event(&mut data, &name, &value);
            data.artifacts.push(TraceArtifact {
                name,
                content: value,
            });
        } else if name.ends_with(".jsonl") {
            let mut stream_turn = None;
            for (line, record) in text.lines().enumerate() {
                if record.trim().is_empty() {
                    continue;
                }
                if data.events.len() >= MAX_RECORDS {
                    bail!("Trace exceeds {MAX_RECORDS} records; select a smaller input");
                }
                match serde_json::from_str::<Value>(record) {
                    Ok(value) => {
                        add_record(&mut data, &name, Some(line + 1), value, &mut stream_turn)
                    }
                    Err(error) => {
                        data.warnings
                            .push(format!("{name}:{} is malformed JSON: {error}", line + 1));
                        data.events.push(TraceEvent {
                            index: 0,
                            source: name.clone(),
                            line: Some(line + 1),
                            kind: "parse_error".into(),
                            title: "Malformed saved record".into(),
                            text: record.into(),
                            timestamp: None,
                            elapsed_ms: None,
                            duration_ms: None,
                            turn: stream_turn,
                            tool_call_id: None,
                            status: Some("error".into()),
                            encryption: Encryption::None,
                            raw: Value::String(record.into()),
                        });
                    }
                }
            }
        } else if name.ends_with(".json") {
            match serde_json::from_str::<Value>(&text) {
                Ok(value) => {
                    if summary_name.as_deref() == Some(&name) {
                        apply_metadata(&mut data, &value);
                    }
                    if summary_name.is_none() && export_name.as_deref() == Some(&name) {
                        apply_metadata(&mut data, &value);
                    }
                    if usage_name.as_deref() == Some(&name) {
                        apply_usage(&mut data, &value);
                    }
                    let is_container = ["events", "messages", "updates", "chat_history"]
                        .iter()
                        .any(|key| value.get(*key).and_then(Value::as_array).is_some());
                    if let Some(records) = value
                        .as_array()
                        .filter(|_| !name.ends_with("tool_definitions.json"))
                    {
                        let mut stream_turn = None;
                        for record in records {
                            add_record(&mut data, &name, None, record.clone(), &mut stream_turn);
                        }
                    } else if is_container {
                        apply_metadata(&mut data, value.get("metadata").unwrap_or(&value));
                        for key in ["events", "messages", "updates", "chat_history"] {
                            let mut stream_turn = None;
                            if let Some(records) = value.get(key).and_then(Value::as_array) {
                                for record in records {
                                    add_record(
                                        &mut data,
                                        &name,
                                        None,
                                        record.clone(),
                                        &mut stream_turn,
                                    );
                                }
                            }
                        }
                    } else if value.get("type").is_some()
                        || value.get("role").is_some()
                        || value.get("method").is_some()
                    {
                        add_record(&mut data, &name, None, value.clone(), &mut None);
                    } else {
                        add_artifact_event(&mut data, &name, &value);
                    }
                    data.artifacts.push(TraceArtifact {
                        name,
                        content: value,
                    });
                }
                Err(error) => {
                    data.warnings
                        .push(format!("{name} is malformed JSON: {error}"));
                    let value = Value::String(text.into_owned());
                    add_artifact_event(&mut data, &name, &value);
                    data.artifacts.push(TraceArtifact {
                        name,
                        content: value,
                    });
                }
            }
        } else {
            let value = Value::String(text.into_owned());
            add_artifact_event(&mut data, &name, &value);
            data.artifacts.push(TraceArtifact {
                name,
                content: value,
            });
        }
        if data.events.len() > MAX_RECORDS {
            bail!("Trace exceeds {MAX_RECORDS} records");
        }
    }
    finish(&mut data);
    Ok(data)
}

fn shortest_named(files: &BTreeMap<String, Vec<u8>>, suffix: &str) -> Option<String> {
    files
        .keys()
        .filter(|name| Path::new(name).file_name().and_then(|name| name.to_str()) == Some(suffix))
        .min_by_key(|name| (name.matches('/').count(), name.len()))
        .cloned()
}

pub(super) fn string(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    })
}

pub(super) fn number(value: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_u64))
}

fn apply_metadata(data: &mut TraceData, value: &Value) {
    if let Some(id) = string(value, &["session_id", "sessionId", "id"]).or_else(|| {
        value
            .get("info")
            .and_then(|v| string(v, &["session_id", "sessionId", "id"]))
    }) {
        data.session_id = id;
    }
    if let Some(title) = string(value, &["generated_title", "title", "session_summary"]) {
        data.title = title;
    }
    data.model = string(value, &["current_model_id", "model_id", "model"]).or(data.model.take());
    data.cwd = string(value, &["cwd"])
        .or_else(|| value.get("info").and_then(|v| string(v, &["cwd"])))
        .or(data.cwd.take());
    data.created_at = string(value, &["created_at", "createdAt"]).or(data.created_at.take());
    data.updated_at = string(value, &["updated_at", "updatedAt"]).or(data.updated_at.take());
}

fn apply_usage(data: &mut TraceData, value: &Value) {
    let value = value.get("session").unwrap_or(value);
    data.summary.input_tokens = number(value, &["inputTokens", "input_tokens", "prompt_tokens"]);
    data.summary.output_tokens = number(
        value,
        &["outputTokens", "output_tokens", "completion_tokens"],
    );
    data.summary.cached_input_tokens = number(
        value,
        &["cachedReadTokens", "cached_input_tokens", "cached_tokens"],
    );
    data.summary.total_tokens = number(value, &["totalTokens", "total_tokens"]);
    if value.get("usageIsIncomplete").and_then(Value::as_bool) == Some(true) {
        data.warnings
            .push("Recorded usage is incomplete; totals include only reported model calls.".into());
    }
}

pub(super) fn payload(record: &Value) -> &Value {
    record
        .pointer("/params/update")
        .or_else(|| record.get("update"))
        .unwrap_or(record)
}

/// Transcript text for reasoning recorded only in encrypted form.
pub(super) const ENCRYPTED_ONLY: &str =
    "Only encrypted reasoning was recorded; readable reasoning is unavailable.";

pub(super) fn is_reasoning_kind(kind: &str) -> bool {
    let kind = kind.trim().to_ascii_lowercase();
    kind.contains("reasoning")
        || kind == "agent_thought_chunk"
        || kind == "thinking"
        || kind.ends_with("_thinking")
}

fn has_payload(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::String(value)) => !value.trim().is_empty(),
        Some(Value::Array(values)) => !values.is_empty(),
        Some(Value::Object(values)) => !values.is_empty(),
        Some(Value::Bool(value)) => *value,
        Some(_) => true,
    }
}

/// A signature is an encrypted copy of the full reasoning (Anthropic thinking blocks), and
/// redacted thinking carries only encrypted data.
fn sealed(block: &Value) -> bool {
    has_payload(block.get("signature"))
        || (block.get("type").and_then(Value::as_str) == Some("redacted_thinking")
            && has_payload(block.get("data")))
}

/// Ciphertext, signatures, and base64 are unbroken ASCII; prose has spaces or non-ASCII letters.
fn reads_as_text(text: &str) -> bool {
    text.contains(' ') || !text.is_ascii()
}

fn same_words(left: &str, right: &str) -> bool {
    left.split_whitespace().eq(right.split_whitespace())
}

/// What the payload fields of a reasoning record actually hold.
#[derive(Default)]
struct Payload {
    /// Readable reasoning stored in a payload field, such as OpenRouter's `reasoning.text`.
    text: Vec<String>,
    /// Ciphertext, a signature, or redacted data.
    opaque: bool,
}

impl Payload {
    /// `encrypted_content` also holds readable copies: OpenRouter stores its
    /// `reasoning_details` there, and their `reasoning.text` repeats the summary.
    fn inspect(&mut self, value: &Value, readable: &str) {
        match value {
            Value::Null => {}
            Value::Bool(encrypted) => self.opaque |= *encrypted,
            Value::Number(_) => self.opaque = true,
            Value::String(text) => {
                let text = text.trim();
                if text.is_empty() {
                    return;
                }
                match serde_json::from_str::<Value>(text) {
                    Ok(parsed @ (Value::Array(_) | Value::Object(_))) => {
                        self.inspect(&parsed, readable);
                    }
                    _ if reads_as_text(text) || same_words(text, readable) => {
                        self.text.push(text.to_owned());
                    }
                    _ => self.opaque = true,
                }
            }
            Value::Array(items) => {
                for item in items {
                    self.inspect(item, readable);
                }
            }
            Value::Object(_) => self.block(value),
        }
    }

    /// An OpenRouter reasoning detail or a provider thinking block.
    fn block(&mut self, block: &Value) {
        for key in ["text", "summary", "thinking"] {
            let text = block.get(key).map(text_content).unwrap_or_default();
            if !text.trim().is_empty() {
                self.text.push(text);
            }
        }
        self.opaque |= ["signature", "data", "encrypted_content", "encrypted"]
            .into_iter()
            .any(|key| has_payload(block.get(key)));
    }
}

/// A reasoning record's readable text, and whether it also carries reasoning that can't be read.
fn read_reasoning(value: &Value) -> (String, bool) {
    let recorded = [
        value.get("content"),
        value.get("summary"),
        value.get("thinking"),
        value.pointer("/reasoning/text"),
    ]
    .into_iter()
    .flatten()
    .map(text_content)
    .find(|text| !text.trim().is_empty())
    .unwrap_or_default();
    let mut payload = Payload::default();
    for field in [
        value.get("encrypted_content"),
        value.get("encrypted"),
        value.pointer("/reasoning/encrypted"),
        value.pointer("/reasoning/encrypted_content"),
    ]
    .into_iter()
    .flatten()
    {
        payload.inspect(field, &recorded);
    }
    payload.opaque |= sealed(value)
        || ["content", "summary"]
            .into_iter()
            .filter_map(|key| value.get(key).and_then(Value::as_array))
            .flatten()
            .any(sealed);
    let text = if recorded.trim().is_empty() {
        payload.text.join("\n")
    } else {
        recorded
    };
    (text, payload.opaque)
}

/// Classify a reasoning record by what a reader can see. A payload that only repeats the
/// readable text, such as OpenRouter's `reasoning.text`, is not encryption; ciphertext,
/// signatures, and redacted data are.
pub(super) fn reasoning_encryption(value: &Value, kind: &str) -> Encryption {
    if !is_reasoning_kind(kind) {
        return Encryption::None;
    }
    match read_reasoning(value) {
        (_, false) => Encryption::None,
        (text, true) if text.trim().is_empty() => Encryption::Full,
        (_, true) => Encryption::Partial,
    }
}

/// The readable reasoning of a record, or a notice when only encrypted reasoning was recorded.
pub(super) fn reasoning_text(value: &Value) -> String {
    match read_reasoning(value) {
        (text, true) if text.trim().is_empty() => ENCRYPTED_ONLY.into(),
        (text, _) => text,
    }
}

/// Recompute from the raw records; saved traces may carry flags from an older rule.
fn refresh_encryption(data: &mut TraceData) {
    for event in &mut data.events {
        event.encryption = reasoning_encryption(payload(&event.raw), &event.kind);
    }
    for entry in &mut data.transcript {
        entry.encryption = transcript::entry_encryption(entry, &data.events);
    }
}

fn timestamp(record: &Value) -> Option<String> {
    // ACP's disk envelope is second precision. The agent timestamp, when
    // present, records the actual update time with millisecond precision.
    if let Some(milliseconds) = record
        .pointer("/params/_meta/agentTimestampMs")
        .or_else(|| record.pointer("/_meta/agentTimestampMs"))
        .and_then(Value::as_i64)
        && let Some(time) = chrono::DateTime::from_timestamp_millis(milliseconds)
    {
        return Some(time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    }
    if let Some(time) = string(record, &["ts", "timestamp", "created_at", "createdAt"]) {
        return Some(time);
    }
    let time = number(record, &["timestamp", "ts"])?;
    if time == 0 {
        return None;
    }
    let milliseconds = if time > 100_000_000_000 {
        time
    } else {
        time.checked_mul(1000)?
    };
    chrono::DateTime::from_timestamp_millis(i64::try_from(milliseconds).ok()?)
        .map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

pub(super) fn time_ms(value: &Option<String>) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value.as_deref()?)
        .ok()
        .map(|time| time.timestamp_millis())
}

pub(super) fn text_content(value: &Value) -> String {
    if let Some(text) = value.as_str() {
        return text.into();
    }
    if let Some(parts) = value.as_array() {
        return parts
            .iter()
            .map(text_content)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
    }
    if let Some(text) = string(value, &["text"]) {
        return text;
    }
    if let Some(content) = value.get("content") {
        return text_content(content);
    }
    String::new()
}

fn record_status(value: &Value, kind: &str) -> Option<String> {
    if let Some(status) = string(value, &["status", "outcome"]) {
        return Some(status);
    }
    if value.get("success").and_then(Value::as_bool) == Some(false)
        || value.get("isError").and_then(Value::as_bool) == Some(true)
        || value
            .get("error")
            .is_some_and(|error| !error.is_null() && error != "")
        || kind.ends_with("_failed")
        || kind.ends_with("_error")
    {
        return Some("error".into());
    }
    if value.get("success").and_then(Value::as_bool) == Some(true) {
        return Some("success".into());
    }
    None
}

fn add_record(
    data: &mut TraceData,
    source: &str,
    line: Option<usize>,
    raw: Value,
    stream_turn: &mut Option<u64>,
) {
    let value = payload(&raw);
    let kind = string(value, &["sessionUpdate", "session_update", "type", "role"])
        .unwrap_or_else(|| "record".into());
    let encryption = reasoning_encryption(value, &kind);
    if kind == "turn_started" {
        *stream_turn = number(value, &["turn_number", "turnNumber"]);
        if let Some(session_id) = string(value, &["session_id", "sessionId"]) {
            data.session_id = session_id;
        }
        data.model = string(value, &["model_id", "modelId"]).or(data.model.take());
    }
    // Prompt indices and `turn_started.turn_number` share one zero-based sequence.
    if kind == "user"
        && let Some(index) = number(value, &["prompt_index"])
    {
        *stream_turn = Some(index);
    }
    let turn = number(value, &["turn_number", "turnNumber"])
        .or_else(|| number(&raw, &["turn_number", "turnNumber"]))
        .or(*stream_turn);
    if kind == "turn_ended" {
        *stream_turn = None;
    }
    let call_id = string(value, &["tool_call_id", "toolCallId", "call_id"])
        .or_else(|| {
            (kind == "backend_tool_call")
                .then(|| value.get("kind").and_then(|kind| string(kind, &["id"])))
                .flatten()
        })
        .or_else(|| {
            (kind == "tool_call")
                .then(|| string(value, &["id"]))
                .flatten()
        });
    let name = string(value, &["tool_name", "name", "title", "server_name"]);
    let title = name
        .as_ref()
        .map(|name| format!("{} · {name}", kind.replace('_', " ")))
        .unwrap_or_else(|| kind.replace('_', " "));
    let mut text = value.get("content").map(text_content).unwrap_or_default();
    if text.is_empty() {
        text = string(
            value,
            &["text", "error_message", "error", "reason", "phase"],
        )
        .unwrap_or_default();
    }
    if kind == "reasoning" && text.is_empty() {
        text = reasoning_text(value);
    }
    let duration_ms = number(
        value,
        &["duration_ms", "durationMs", "latency_ms", "wait_ms"],
    );
    let status = record_status(value, &kind);
    let event_timestamp = timestamp(&raw).or_else(|| timestamp(value));
    // Separate nested assistant calls so parallel tools are inspectable and linked.
    let calls = value
        .get("tool_calls")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    data.events.push(TraceEvent {
        index: 0,
        source: source.into(),
        line,
        kind,
        title,
        text,
        timestamp: event_timestamp.clone(),
        elapsed_ms: None,
        duration_ms,
        turn,
        tool_call_id: call_id,
        status,
        encryption,
        raw,
    });
    for call in calls {
        let function = call.get("function").unwrap_or(&call);
        let name = string(function, &["name"]).unwrap_or_else(|| "unknown tool".into());
        let input = function.get("arguments").cloned().unwrap_or(Value::Null);
        data.events.push(TraceEvent {
            index: 0,
            source: source.into(),
            line,
            kind: "tool_call".into(),
            title: name,
            text: input
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| input.to_string()),
            timestamp: event_timestamp.clone(),
            elapsed_ms: None,
            duration_ms: None,
            turn,
            tool_call_id: string(&call, &["id", "call_id"]),
            status: None,
            encryption: Encryption::None,
            raw: call,
        });
    }
}

fn add_artifact_event(data: &mut TraceData, name: &str, value: &Value) {
    let is_subagent = (name.ends_with("meta.json") && value.get("child_session_id").is_some())
        || name.ends_with("subagent.json");
    data.events.push(TraceEvent {
        index: 0,
        source: name.into(),
        line: None,
        kind: if is_subagent { "subagent" } else { "artifact" }.into(),
        title: name.into(),
        text: value
            .as_str()
            .map(str::to_owned)
            .or_else(|| string(value, &["description"]))
            .unwrap_or_default(),
        timestamp: if is_subagent {
            string(value, &["started_at", "startedAt"])
        } else {
            None
        },
        elapsed_ms: None,
        duration_ms: number(value, &["duration_ms", "durationMs"]),
        turn: None,
        tool_call_id: None,
        status: string(value, &["status"]),
        encryption: Encryption::None,
        raw: value.clone(),
    });
}

fn finish(data: &mut TraceData) {
    // Stable sort: retain recorded order for equal/absent timestamps. Untimed
    // transcript is a separate sequence; never invent wall-clock positions.
    data.events
        .sort_by_key(|event| time_ms(&event.timestamp).map_or((1, 0), |time| (0, time)));
    let first_time = data
        .events
        .iter()
        .find_map(|event| time_ms(&event.timestamp));
    let last_time = data
        .events
        .iter()
        .rev()
        .find_map(|event| time_ms(&event.timestamp));
    let mut active_turn = None;
    let mut turns = BTreeMap::<u64, TraceTurn>::new();
    for (index, event) in data.events.iter_mut().enumerate() {
        event.index = index;
        event.elapsed_ms = time_ms(&event.timestamp)
            .zip(first_time)
            .and_then(|(time, first)| u64::try_from(time - first).ok());
        if event.kind == "turn_started" {
            active_turn = event.turn;
        }
        if event.turn.is_none() && event.timestamp.is_some() {
            event.turn = active_turn;
        }
        if let Some(number) = event.turn {
            let turn = turns.entry(number).or_insert(TraceTurn {
                number,
                model: None,
                status: None,
                started_at: None,
                ended_at: None,
                duration_ms: None,
                event_count: 0,
            });
            turn.event_count += 1;
            if event.kind == "turn_started" {
                turn.started_at = event.timestamp.clone();
                turn.model = string(payload(&event.raw), &["model_id", "modelId"]);
            }
            if event.kind == "turn_ended" {
                turn.ended_at = event.timestamp.clone();
                turn.status = event.status.clone();
                active_turn = None;
            }
        }
    }
    let mut tools = BTreeMap::<String, TraceTool>::new();
    let mut status_priorities = BTreeMap::<String, u8>::new();
    for event in &data.events {
        let Some(id) = &event.tool_call_id else {
            continue;
        };
        let value = payload(&event.raw);
        let tool = tools.entry(id.clone()).or_insert(TraceTool {
            id: id.clone(),
            name: "unknown tool".into(),
            turn: event.turn,
            status: "unknown".into(),
            input: None,
            output: None,
            duration_ms: None,
            event_indices: vec![],
        });
        tool.event_indices.push(event.index);
        let function = if event.kind == "backend_tool_call" {
            value.get("kind").unwrap_or(value)
        } else {
            value.get("function").unwrap_or(value)
        };
        if let Some(name) = string(function, &["tool_name", "name", "title", "tool_type"]) {
            tool.name = name;
        }
        tool.turn = tool.turn.or(event.turn);
        tool.duration_ms = event.duration_ms.or(tool.duration_ms);
        let recorded_status = event
            .status
            .clone()
            .or_else(|| string(function, &["status"]));
        if let Some(status) = &recorded_status {
            let priority = if terminal_status(status) {
                if matches!(
                    event.kind.as_str(),
                    "tool_completed" | "mcp_tool_call_completed"
                ) {
                    3
                } else {
                    2
                }
            } else {
                1
            };
            if priority >= status_priorities.get(id).copied().unwrap_or(0) {
                tool.status = status.clone();
                status_priorities.insert(id.clone(), priority);
            }
        }
        if event.kind == "tool_call"
            && let Some(arguments) = function
                .get("arguments")
                .or_else(|| function.get("rawInput"))
                .or_else(|| function.get("input"))
        {
            tool.input = Some(
                arguments
                    .as_str()
                    .and_then(|text| serde_json::from_str(text).ok())
                    .unwrap_or_else(|| arguments.clone()),
            );
        }
        if event.kind == "backend_tool_call" {
            tool.input = function
                .get("action")
                .or_else(|| function.get("input"))
                .or_else(|| function.get("code"))
                .cloned()
                .or(tool.input.take());
            tool.output = function
                .get("outputs")
                .or_else(|| function.get("output"))
                .or_else(|| function.get("results"))
                .cloned()
                .or(tool.output.take());
        }
        if matches!(
            event.kind.as_str(),
            "tool_result" | "tool" | "tool_call_update"
        ) && let Some(output) = value
            .get("rawOutput")
            .or_else(|| value.get("content"))
            .or_else(|| value.get("output"))
        {
            tool.output = Some(output.clone());
            if tool.status == "unknown" {
                tool.status = "result recorded".into();
            }
        }
    }
    // The call ID is the only reliable cross-stream join; names are not unique.
    for event in &mut data.events {
        if let Some(tool) = event.tool_call_id.as_ref().and_then(|id| tools.get(id)) {
            event.turn = event.turn.or(tool.turn);
            if event.kind == "tool_result" {
                event.title = format!("Tool result · {}", tool.name);
            }
        }
    }
    for turn in turns.values_mut() {
        turn.duration_ms = time_ms(&turn.ended_at)
            .zip(time_ms(&turn.started_at))
            .and_then(|(end, start)| u64::try_from(end - start).ok());
        turn.event_count = data
            .events
            .iter()
            .filter(|event| event.turn == Some(turn.number))
            .count();
    }
    data.tools = tools.into_values().collect();
    data.tools
        .sort_by_key(|tool| tool.event_indices.first().copied());
    data.turns = turns.into_values().collect();
    data.summary.event_count = data.events.len();
    data.summary.turn_count = data.turns.len();
    data.summary.tool_count = data.tools.len();
    data.summary.error_count = data
        .events
        .iter()
        .filter(|event| {
            event
                .status
                .as_deref()
                .is_some_and(|status| matches!(status, "error" | "failed" | "failure"))
        })
        .count();
    data.summary.duration_ms = last_time
        .zip(first_time)
        .and_then(|(last, first)| u64::try_from(last - first).ok());
    if data.summary.total_tokens.is_none() {
        data.warnings
            .push("Token totals were not recorded in usage.json; token counts are unknown.".into());
    }
    if data
        .events
        .iter()
        .any(|event| event.timestamp.is_none() && event.kind != "artifact")
    {
        data.warnings.push("Some records have no timestamps. Timed records appear first; untimed records preserve file order and cannot establish cross-stream chronology. Turns use recorded numbers/prompt indices, timed lifecycle boundaries, and exact tool-call IDs; equal timestamps cannot establish ordering across files.".into());
    }
    if !data.events.iter().any(|event| event.kind == "turn_started") {
        data.warnings.push("No turn lifecycle events were recorded; turn boundaries and durations may be unavailable.".into());
    }
    if data.events.iter().any(|event| event.kind == "subagent") {
        data.warnings.push("Subagent metadata is included. Child sessions are stored separately; open each child's session to inspect its complete trace.".into());
    }
    let missing_ids = data
        .events
        .iter()
        .filter(|event| {
            matches!(
                event.kind.as_str(),
                "tool_started" | "tool_completed" | "tool_call"
            ) && event.tool_call_id.is_none()
        })
        .count();
    if missing_ids > 0 {
        data.warnings.push(format!("{missing_ids} tool records have no call ID and cannot be reliably correlated; they remain visible as individual records."));
    }
    let (entries, notes) = transcript::build(data);
    data.transcript = entries;
    data.warnings.extend(notes);
    let mut seen = BTreeSet::new();
    data.warnings.retain(|warning| seen.insert(warning.clone()));
}

fn terminal_status(status: &str) -> bool {
    matches!(
        status,
        "completed"
            | "success"
            | "failed"
            | "failure"
            | "error"
            | "cancelled"
            | "canceled"
            | "denied"
            | "permission_rejected"
            | "permission_cancelled"
            | "hook_denied"
            | "invalid_tool"
            | "followup"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn write(root: &Path, name: &str, contents: &str) {
        fs::write(root.join(name), contents).unwrap();
    }

    #[test]
    fn joins_concurrent_calls_by_id_and_preserves_raw_records() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "summary.json",
            r#"{"info":{"id":"session-a","cwd":"/work"},"generated_title":"Debug a failure","current_model_id":"grok"}"#,
        );
        write(
            directory.path(),
            "events.jsonl",
            concat!(
                "{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"turn_started\",\"turn_number\":1,\"model_id\":\"grok\"}\n",
                "{\"ts\":\"2026-01-01T00:00:01Z\",\"type\":\"tool_completed\",\"tool_name\":\"bash\",\"tool_call_id\":\"b\",\"duration_ms\":80,\"outcome\":\"error\"}\n",
                "{\"ts\":\"2026-01-01T00:00:02Z\",\"type\":\"tool_completed\",\"tool_name\":\"bash\",\"tool_call_id\":\"a\",\"duration_ms\":120,\"outcome\":\"success\"}\n",
                "{\"ts\":\"2026-01-01T00:00:03Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n"
            ),
        );
        write(
            directory.path(),
            "chat_history.jsonl",
            concat!(
                "{\"type\":\"assistant\",\"content\":\"Checking\",\"tool_calls\":[{\"id\":\"a\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"},{\"id\":\"b\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"false\\\"}\"}]}\n",
                "{\"type\":\"tool_result\",\"tool_call_id\":\"b\",\"content\":\"exit 1\"}\n",
                "{\"type\":\"tool_result\",\"tool_call_id\":\"a\",\"content\":\"/work\"}\n"
            ),
        );
        write(
            directory.path(),
            "usage.json",
            r#"{"session":{"inputTokens":10,"outputTokens":4,"cachedReadTokens":3,"totalTokens":14,"modelCalls":2}}"#,
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(trace.session_id, "session-a");
        assert_eq!(trace.summary.total_tokens, Some(14));
        assert_eq!(trace.summary.tool_count, 2);
        assert_eq!(trace.summary.duration_ms, Some(3000));
        let a = trace.tools.iter().find(|tool| tool.id == "a").unwrap();
        let b = trace.tools.iter().find(|tool| tool.id == "b").unwrap();
        assert_eq!(a.input, Some(json!({"command":"pwd"})));
        assert_eq!(a.output, Some(json!("/work")));
        assert_eq!(a.duration_ms, Some(120));
        assert_eq!(b.status, "error");
        assert_eq!(b.output, Some(json!("exit 1")));
        assert!(
            trace
                .events
                .iter()
                .any(|event| event.source == "chat_history.jsonl"
                    && event.line == Some(1)
                    && event.raw.get("tool_calls").is_some())
        );
    }

    #[test]
    fn accepts_acp_envelopes_and_retains_malformed_lines() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "updates.jsonl",
            concat!(
                "{\"timestamp\":1767225600,\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"read_file\",\"rawInput\":{\"path\":\"a.txt\"}}}}\n",
                "{\"timestamp\":1767225601,\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t\",\"status\":\"completed\",\"rawOutput\":\"hello\"}}}\n",
                "{torn\n"
            ),
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(trace.summary.total_tokens, None);
        assert_eq!(trace.tools.first().unwrap().output, Some(json!("hello")));
        assert_eq!(
            trace.events.first().unwrap().timestamp.as_deref(),
            Some("2026-01-01T00:00:00.000Z")
        );
        assert!(
            trace
                .events
                .iter()
                .any(|event| event.kind == "parse_error" && event.line == Some(3))
        );
    }

    fn reasoning_record(summary: &str, encrypted_content: Value) -> Value {
        json!({"type": "reasoning", "summary": [{"type": "summary_text", "text": summary}],
            "encrypted_content": encrypted_content})
    }

    #[test]
    fn readable_copies_are_not_encrypted_but_ciphertext_and_signatures_are() {
        // OpenRouter stores its reasoning details as JSON in `encrypted_content`.
        let details = |details: Value| Value::String(details.to_string());
        let cases = [
            (
                reasoning_record(
                    "Check the branch.",
                    details(
                        json!([{"type": "reasoning.text", "text": "Check the branch.",
                        "format": "unknown", "index": 0}]),
                    ),
                ),
                "reasoning",
                Encryption::None,
            ),
            (
                reasoning_record(
                    "**Plan**",
                    details(json!([
                        {"type": "reasoning.summary", "summary": "**Plan**"},
                        {"type": "reasoning.encrypted", "data": "gAAAAABopaque"}
                    ])),
                ),
                "reasoning",
                Encryption::Partial,
            ),
            (
                reasoning_record(
                    "",
                    details(json!([{"type": "reasoning.encrypted", "data": "gAAAAABopaque"}])),
                ),
                "reasoning",
                Encryption::Full,
            ),
            (
                reasoning_record(
                    "Count the files.",
                    details(
                        json!([{"type": "reasoning.text", "text": "Count the files.",
                        "signature": "EqQBopaque"}]),
                    ),
                ),
                "reasoning",
                Encryption::Partial,
            ),
            (
                reasoning_record("Done.", json!("Done.")),
                "reasoning",
                Encryption::None,
            ),
            (
                json!({"type": "reasoning", "encrypted_content": "The user wants a list."}),
                "reasoning",
                Encryption::None,
            ),
            // The Messages backend stores a thinking block's signature in `encrypted_content`.
            (
                reasoning_record("Count the files.", json!("EqQBCgIYAhIM1gbcDa9G")),
                "reasoning",
                Encryption::Partial,
            ),
            (
                json!({"type": "reasoning", "encrypted_content": "opaque"}),
                "reasoning",
                Encryption::Full,
            ),
            (
                json!({"type": "reasoning", "encrypted_content": "  "}),
                "reasoning",
                Encryption::None,
            ),
            (
                json!({"type": "reasoning", "encrypted_content": null}),
                "reasoning",
                Encryption::None,
            ),
            (
                json!({"type": "reasoning", "encrypted": false}),
                "reasoning",
                Encryption::None,
            ),
            (
                json!({"type": "reasoning", "signature": "opaque"}),
                "reasoning",
                Encryption::Full,
            ),
            (
                json!({"sessionUpdate": "reasoning_completed", "signature": "opaque"}),
                "reasoning_completed",
                Encryption::Full,
            ),
            (
                json!({"sessionUpdate": "agent_thought_chunk",
                    "content": {"type": "text", "text": "Look."}}),
                "agent_thought_chunk",
                Encryption::None,
            ),
            (
                json!({"type": "redacted_thinking", "data": "opaque"}),
                "redacted_thinking",
                Encryption::Full,
            ),
            (
                json!({"type": "reasoning", "reasoning": {"encrypted": "opaque"}}),
                "reasoning",
                Encryption::Full,
            ),
            (
                json!({"type": "response_completed", "signature": "opaque"}),
                "response_completed",
                Encryption::None,
            ),
            (
                json!({"type": "thinking_config", "signature": "opaque"}),
                "thinking_config",
                Encryption::None,
            ),
        ];
        for (value, kind, expected) in cases {
            assert_eq!(
                reasoning_encryption(&value, kind),
                expected,
                "value={value}"
            );
        }
        assert_eq!(
            reasoning_text(&json!({"type": "reasoning",
                "encrypted_content": "The user wants a list."})),
            "The user wants a list."
        );
        assert_eq!(
            reasoning_text(&reasoning_record("", json!("opaque"))),
            ENCRYPTED_ONLY
        );
    }

    #[test]
    fn openrouter_details_lock_only_reasoning_that_cannot_be_read() {
        let directory = tempfile::tempdir().unwrap();
        let record = |summary: &str, details: Value| {
            let mut record = reasoning_record(summary, Value::String(details.to_string()));
            record["id"] = json!("grok_openrouter_reasoning_v1");
            record.to_string()
        };
        let lines = [
            json!({"type": "user", "prompt_index": 0, "content": "Hi"}).to_string(),
            record(
                "Read the log.",
                json!([{"type": "reasoning.text", "text": "Read the log.", "format": "unknown", "index": 0}]),
            ),
            record(
                "**Checking**",
                json!([{"type": "reasoning.summary", "summary": "**Checking**"},
                    {"type": "reasoning.encrypted", "data": "gAAAAAB"}]),
            ),
            record(
                "",
                json!([{"type": "reasoning.encrypted", "data": "gAAAAAB"}]),
            ),
            json!({"type": "assistant", "content": "Done"}).to_string(),
        ];
        write(directory.path(), "chat_history.jsonl", &lines.join("\n"));
        let trace = load(directory.path()).unwrap();
        let reasoning: Vec<_> = trace
            .transcript
            .iter()
            .filter(|entry| entry.kind == transcript::EntryKind::Reasoning)
            .map(|entry| (entry.encryption, entry.text.as_str()))
            .collect();
        assert_eq!(
            reasoning,
            vec![
                (Encryption::None, "Read the log."),
                (Encryption::Partial, "**Checking**"),
                (Encryption::Full, ENCRYPTED_ONLY),
            ]
        );
    }

    #[test]
    fn saved_traces_are_reclassified_with_the_current_rule() {
        let directory = tempfile::tempdir().unwrap();
        let lines = [
            json!({"type": "user", "prompt_index": 0, "content": "Hi"}).to_string(),
            reasoning_record(
                "Plan",
                Value::String(json!([{"type": "reasoning.text", "text": "Plan"}]).to_string()),
            )
            .to_string(),
            json!({"type": "assistant", "content": "Hello"}).to_string(),
        ];
        write(directory.path(), "chat_history.jsonl", &lines.join("\n"));
        let mut saved = serde_json::to_value(load(directory.path()).unwrap()).unwrap();
        for list in ["events", "transcript"] {
            for item in saved[list].as_array_mut().unwrap() {
                item["encrypted"] = json!(true);
                item["encryption"] = json!("full");
            }
        }
        let output = directory.path().join("normalized.json");
        fs::write(&output, saved.to_string()).unwrap();
        let restored = load(&output).unwrap();
        assert!(
            restored
                .events
                .iter()
                .all(|event| event.encryption == Encryption::None)
        );
        assert!(
            restored
                .transcript
                .iter()
                .all(|entry| entry.encryption == Encryption::None)
        );
    }

    #[test]
    fn preserves_reasoning_synthetic_context_and_unknown_event_fields() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "chat_history.jsonl",
            concat!(
                "{\"type\":\"user\",\"prompt_index\":4,\"content\":[{\"type\":\"text\",\"text\":\"Debug\"}]}\n",
                "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}\n",
                "{\"type\":\"future_event\",\"new_field\":{\"x\":1}}\n"
            ),
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(trace.turns.first().unwrap().number, 4);
        assert!(trace.events.iter().any(|event| event.kind == "reasoning"
            && event.encryption == Encryption::Full
            && event.text == ENCRYPTED_ONLY));
        assert!(trace.transcript.iter().any(|entry| {
            entry.kind == transcript::EntryKind::Reasoning && entry.encryption == Encryption::Full
        }));
        assert!(
            trace
                .events
                .iter()
                .any(|event| event.raw.pointer("/new_field/x") == Some(&json!(1)))
        );
    }

    #[test]
    fn reads_export_without_extracting_and_skips_links() {
        let directory = tempfile::tempdir().unwrap();
        let archive_path = directory.path().join("trace.tar.gz");
        let encoder = flate2::write::GzEncoder::new(
            File::create(&archive_path).unwrap(),
            flate2::Compression::default(),
        );
        let mut archive = tar::Builder::new(encoder);
        let content = b"{\"info\":{\"id\":\"archived-session\"}}";
        let mut header = tar::Header::new_gnu();
        header.set_size(content.len() as u64);
        header.set_mode(0o600);
        header.set_cksum();
        archive
            .append_data(
                &mut header,
                "archived-session/summary.json",
                content.as_slice(),
            )
            .unwrap();
        let mut link = tar::Header::new_gnu();
        link.set_entry_type(tar::EntryType::Symlink);
        link.set_size(0);
        link.set_mode(0o600);
        link.set_link_name("/etc/passwd").unwrap();
        link.set_cksum();
        archive
            .append_data(&mut link, "archived-session/private.json", std::io::empty())
            .unwrap();
        archive.into_inner().unwrap().finish().unwrap();
        let trace = load(&archive_path).unwrap();
        assert_eq!(trace.session_id, "archived-session");
        assert!(
            trace
                .warnings
                .iter()
                .any(|warning| warning.contains("non-file"))
        );
        assert!(!directory.path().join("archived-session").exists());
    }

    #[test]
    fn reports_oversized_files_and_does_not_follow_symlinks() {
        let directory = tempfile::tempdir().unwrap();
        write(directory.path(), "summary.json", "{}");
        let huge = File::create(directory.path().join("huge.json")).unwrap();
        huge.set_len(MAX_FILE_BYTES + 1).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc/passwd", directory.path().join("secret.json")).unwrap();
        let trace = load(directory.path()).unwrap();
        assert!(
            trace
                .warnings
                .iter()
                .any(|warning| warning.contains("size limit"))
        );
        #[cfg(unix)]
        assert!(
            trace
                .warnings
                .iter()
                .any(|warning| warning.contains("symlink"))
        );
    }

    #[test]
    fn reopens_normalized_json_losslessly() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "events.jsonl",
            "{\"type\":\"future_event\",\"new_field\":42}\n",
        );
        let original = load(directory.path()).unwrap();
        let output = directory.path().join("normalized.json");
        fs::write(&output, serde_json::to_vec(&original).unwrap()).unwrap();
        let restored = load(&output).unwrap();
        assert_eq!(
            serde_json::to_value(&original.events).unwrap(),
            serde_json::to_value(&restored.events).unwrap()
        );
        assert_eq!(original.warnings, restored.warnings);
        assert_eq!(restored.source, output.display().to_string());
    }

    #[test]
    fn terminal_outcome_survives_untimed_pending_update() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "events.jsonl",
            "{\"ts\":\"2026-01-01T00:00:01Z\",\"type\":\"tool_completed\",\"tool_name\":\"bash\",\"tool_call_id\":\"a\",\"outcome\":\"error\"}\n",
        );
        write(
            directory.path(),
            "updates.jsonl",
            "{\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"a\",\"status\":\"pending\",\"title\":\"bash\"}}\n",
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(trace.tools.first().unwrap().status, "error");
    }

    #[test]
    fn json_arrays_and_chat_only_containers_keep_turn_context() {
        for records in [
            json!([{"type":"user","prompt_index":2,"content":"Hi"},{"type":"assistant","content":"Hello"}]),
            json!({"chat_history":[{"type":"user","prompt_index":2,"content":"Hi"},{"type":"assistant","content":"Hello"}]}),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("records.json");
            fs::write(&path, records.to_string()).unwrap();
            let trace = load(&path).unwrap();
            assert_eq!(trace.events.len(), 2);
            assert!(trace.events.iter().all(|event| event.turn == Some(2)));
        }
    }

    #[test]
    fn backend_tools_expose_io_and_finished_turn_does_not_capture_later_events() {
        let directory = tempfile::tempdir().unwrap();
        write(
            directory.path(),
            "events.jsonl",
            concat!(
                "{\"type\":\"turn_started\",\"turn_number\":1}\n",
                "{\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n",
                "{\"type\":\"mcp_server_connected\",\"server_name\":\"demo\"}\n"
            ),
        );
        write(
            directory.path(),
            "chat_history.jsonl",
            "{\"type\":\"backend_tool_call\",\"kind\":{\"tool_type\":\"code_interpreter\",\"id\":\"backend-1\",\"status\":\"completed\",\"code\":\"print(1)\",\"outputs\":[{\"type\":\"logs\",\"logs\":\"1\"}]}}\n",
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(
            trace
                .events
                .iter()
                .find(|event| event.kind == "mcp_server_connected")
                .unwrap()
                .turn,
            None
        );
        let tool = trace.tools.first().unwrap();
        assert_eq!(tool.name, "code_interpreter");
        assert_eq!(tool.status, "completed");
        assert_eq!(tool.input, Some(json!("print(1)")));
        assert!(tool.output.as_ref().unwrap().is_array());
    }

    #[test]
    fn prefers_millisecond_agent_timestamp_over_disk_envelope() {
        let record = json!({"timestamp":1767225600,"params":{"_meta":{"agentTimestampMs":1767225600750_u64}}});
        assert_eq!(
            timestamp(&record).as_deref(),
            Some("2026-01-01T00:00:00.750Z")
        );
    }

    #[test]
    fn checkpoints_are_inspectable_without_inflating_live_tool_counts() {
        let directory = tempfile::tempdir().unwrap();
        fs::create_dir_all(directory.path().join("compaction_checkpoints/1")).unwrap();
        write(
            directory.path(),
            "compaction_checkpoints/1/chat_history.jsonl",
            "{\"type\":\"tool_result\",\"tool_call_id\":\"old\",\"content\":\"historical\"}\n",
        );
        let trace = load(directory.path()).unwrap();
        assert_eq!(trace.summary.tool_count, 0);
        assert_eq!(trace.artifacts.len(), 1);
        assert!(
            trace
                .artifacts
                .first()
                .unwrap()
                .content
                .as_str()
                .unwrap()
                .contains("historical")
        );
    }
}
