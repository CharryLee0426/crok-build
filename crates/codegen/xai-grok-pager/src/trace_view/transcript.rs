//! The recorded conversation, placed on the timing recorded beside it.
//!
//! `chat_history.jsonl` is the transcript the model saw, but it has no timestamps.
//! `events.jsonl` records when each model call and tool ran, and `updates.jsonl`
//! records when prompts, reasoning, replies, and tool calls reached the client.
//! Entries join those streams by turn number, model-call order, and tool-call ID.
//! An entry that cannot be joined stays untimed rather than receiving a guess.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::data::{
    Encryption, TraceData, TraceEvent, number, payload, string, text_content, time_ms,
};

/// Timeline lane of a transcript entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    System,
    User,
    Reasoning,
    Assistant,
    Tool,
}

impl EntryKind {
    pub const ALL: [Self; 5] = [
        Self::System,
        Self::User,
        Self::Reasoning,
        Self::Assistant,
        Self::Tool,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::User => "User",
            Self::Reasoning => "Reasoning",
            Self::Assistant => "Assistant",
            Self::Tool => "Tool",
        }
    }

    pub fn lane_label(self) -> &'static str {
        match self {
            Self::Tool => "Tools",
            other => other.label(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptEntry {
    pub index: usize,
    pub kind: EntryKind,
    pub title: String,
    /// Readable content; for tools, a one-line summary of the input.
    pub text: String,
    pub turn: Option<u64>,
    /// Recorded start, in Unix milliseconds. `None` when no stream timed it.
    pub start_ms: Option<i64>,
    /// Recorded end; equal to the start for instantaneous records and `None`
    /// when a started call never recorded completion.
    pub end_ms: Option<i64>,
    /// Time from sending the model request to its first token.
    pub wait_ms: Option<u64>,
    pub tool_call_id: Option<String>,
    pub status: Option<String>,
    /// Whether this reasoning can be read, and whether an encrypted copy was recorded with it.
    #[serde(default)]
    pub encryption: Encryption,
    /// Indices of the raw records behind this entry in `TraceData::events`.
    pub event_indices: Vec<usize>,
}

/// Classify a transcript entry from the records it was built from.
///
/// A signature or ciphertext attached to readable text means the text is a summary,
/// not that the summary itself is unreadable.
pub(super) fn entry_encryption(entry: &TranscriptEntry, events: &[TraceEvent]) -> Encryption {
    if entry.kind != EntryKind::Reasoning {
        return Encryption::None;
    }
    let sealed = entry
        .event_indices
        .iter()
        .fold(Encryption::None, |level, index| {
            level.join(
                events
                    .get(*index)
                    .map(|event| event.encryption)
                    .unwrap_or_default(),
            )
        });
    if sealed.is_encrypted() && reasoning_is_readable(&entry.text) {
        Encryption::Partial
    } else {
        sealed
    }
}

fn reasoning_is_readable(text: &str) -> bool {
    let text = text.trim();
    !text.is_empty() && text != super::data::ENCRYPTED_ONLY
}

/// Streamed chunks and the stored record of one block differ only in whitespace.
fn same_text(left: &str, right: &str) -> bool {
    let visible = |text: &str| {
        text.chars()
            .filter(|character| !character.is_whitespace())
            .collect::<String>()
    };
    let left = visible(left);
    !left.is_empty() && left == visible(right)
}

impl TranscriptEntry {
    pub fn duration_ms(&self) -> Option<u64> {
        u64::try_from(self.end_ms? - self.start_ms?).ok()
    }

    pub fn is_error(&self) -> bool {
        self.status.as_deref().is_some_and(|status| {
            ["error", "fail", "cancel", "reject", "denied", "invalid"]
                .iter()
                .any(|word| status.contains(word))
        })
    }
}

/// One model request, as recorded by `events.jsonl`.
#[derive(Debug, Clone, Default)]
struct ModelCall {
    start: i64,
    first_token: Option<i64>,
    text_start: Option<i64>,
    end: Option<i64>,
    tool_ids: Vec<String>,
}

impl ModelCall {
    fn wait_ms(&self) -> Option<u64> {
        u64::try_from(self.first_token? - self.start).ok()
    }
}

#[derive(Debug, Clone, Default)]
struct ToolTiming {
    start: Option<i64>,
    end: Option<i64>,
}

#[derive(Default)]
struct Timing {
    session_start: Option<i64>,
    prompts: BTreeMap<u64, i64>,
    calls: BTreeMap<Option<u64>, Vec<ModelCall>>,
    tools: HashMap<String, ToolTiming>,
    /// Non-prompt user messages (shell commands, for example), in order.
    user_messages: VecDeque<i64>,
}

impl Timing {
    fn from_streams(events: &[&TraceEvent], updates: &[&TraceEvent]) -> Self {
        fn close(
            timing: &mut Timing,
            turn: Option<u64>,
            open: &mut Option<ModelCall>,
            time: Option<i64>,
        ) {
            // A call that ended before any output produced no transcript entry. A
            // reply made only of tool calls records no first token, only the
            // switch to tool execution.
            if let Some(mut call) = open.take()
                && (call.first_token.is_some() || call.end.is_some())
            {
                call.end = call.end.or(time);
                timing.calls.entry(turn).or_default().push(call);
            }
        }
        let mut timing = Self::default();
        let mut turn = None;
        let mut open: Option<ModelCall> = None;
        for event in events {
            let Some(time) = time_ms(&event.timestamp) else {
                continue;
            };
            let value = payload(&event.raw);
            timing.session_start = Some(timing.session_start.map_or(time, |t| t.min(time)));
            match event.kind.as_str() {
                "turn_started" => {
                    close(&mut timing, turn, &mut open, Some(time));
                    turn = number(value, &["turn_number", "turnNumber"]);
                    if let Some(number) = turn {
                        timing.prompts.entry(number).or_insert(time);
                    }
                }
                "turn_ended" => close(&mut timing, turn, &mut open, Some(time)),
                "loop_started" => {
                    close(&mut timing, turn, &mut open, Some(time));
                    open = Some(ModelCall {
                        start: time,
                        ..ModelCall::default()
                    });
                }
                "first_token" => {
                    if let Some(call) = open.as_mut() {
                        call.first_token.get_or_insert(time);
                    }
                }
                "phase_changed" => {
                    let Some(call) = open.as_mut() else { continue };
                    match string(value, &["phase"]).as_deref() {
                        Some("streaming_text") => {
                            call.text_start.get_or_insert(time);
                        }
                        Some("tool_execution" | "permission_prompt") if call.end.is_none() => {
                            call.end = Some(time);
                        }
                        _ => {}
                    }
                }
                "tool_completed" | "mcp_tool_call_completed" => {
                    let Some(id) = event.tool_call_id.clone() else {
                        continue;
                    };
                    let duration = number(value, &["duration_ms", "durationMs"])
                        .and_then(|ms| i64::try_from(ms).ok());
                    timing.tools.insert(
                        id.clone(),
                        ToolTiming {
                            start: duration.map(|ms| time - ms),
                            end: Some(time),
                        },
                    );
                    if let Some(call) = open.as_mut() {
                        call.tool_ids.push(id);
                    }
                }
                _ => {}
            }
        }
        // A call still streaming when the snapshot was taken keeps an open end.
        close(&mut timing, turn, &mut open, None);
        for event in updates {
            let Some(time) = time_ms(&event.timestamp) else {
                continue;
            };
            let value = payload(&event.raw);
            timing.session_start = Some(timing.session_start.map_or(time, |t| t.min(time)));
            match event.kind.as_str() {
                "user_message_chunk" => match prompt_index(value) {
                    Some(index) => {
                        timing.prompts.entry(index).or_insert(time);
                    }
                    None => timing.user_messages.push_back(time),
                },
                "tool_call" | "tool_call_update" => {
                    let Some(id) = event.tool_call_id.clone() else {
                        continue;
                    };
                    let tool = timing.tools.entry(id).or_default();
                    if event.kind == "tool_call" {
                        tool.start.get_or_insert(time);
                    }
                    if string(value, &["status"]).is_some_and(|status| finished(&status)) {
                        tool.end.get_or_insert(time);
                    }
                }
                _ => {}
            }
        }
        timing
    }

    /// Claim the model call that produced an assistant record. A tool-call ID
    /// is an exact join; otherwise take the next call not anchored elsewhere.
    fn claim(
        &self,
        cursors: &mut HashMap<Option<u64>, usize>,
        turn: Option<u64>,
        ids: &[String],
    ) -> Option<ModelCall> {
        let calls = self.calls.get(&turn)?;
        let cursor = cursors.entry(turn).or_default();
        let anchored = (*cursor..calls.len()).find(|&index| {
            calls
                .get(index)
                .is_some_and(|call| call.tool_ids.iter().any(|id| ids.contains(id)))
        });
        let index = anchored.or_else(|| {
            calls
                .get(*cursor)
                .filter(|call| call.tool_ids.is_empty())
                .map(|_| *cursor)
        })?;
        *cursor = index + 1;
        calls.get(index).cloned()
    }

    /// The latest model call that started before `time`.
    fn call_before(&self, time: i64) -> Option<&ModelCall> {
        self.calls
            .values()
            .flatten()
            .filter(|call| call.start <= time)
            .max_by_key(|call| call.start)
    }
}

fn finished(status: &str) -> bool {
    !matches!(status, "pending" | "in_progress" | "running")
}

fn prompt_index(value: &Value) -> Option<u64> {
    number(value, &["prompt_index", "promptIndex"]).or_else(|| {
        value
            .get("_meta")
            .and_then(|meta| number(meta, &["promptIndex", "prompt_index"]))
    })
}

/// The top-level copy of a stream; subagent and checkpoint copies are separate recordings.
fn primary_source(data: &TraceData, file: &str) -> Option<String> {
    data.events
        .iter()
        .filter(|event| {
            event.kind != "artifact"
                && Path::new(&event.source)
                    .file_name()
                    .and_then(|name| name.to_str())
                    == Some(file)
                && !event
                    .source
                    .split('/')
                    .any(|part| part == "compaction_checkpoints")
        })
        .map(|event| &event.source)
        .min_by_key(|source| (source.matches('/').count(), source.len()))
        .cloned()
}

fn stream<'a>(data: &'a TraceData, source: Option<&str>) -> Vec<&'a TraceEvent> {
    let Some(source) = source else {
        return vec![];
    };
    let mut records: Vec<_> = data
        .events
        .iter()
        .filter(|event| event.source == source)
        .collect();
    // Restore file order; records split from one line keep their relative order.
    records.sort_by_key(|event| event.line);
    records
}

/// Build the transcript from the most complete recorded conversation.
pub fn build(data: &TraceData) -> (Vec<TranscriptEntry>, Vec<String>) {
    let chat_source = primary_source(data, "chat_history.jsonl");
    let updates_source = primary_source(data, "updates.jsonl");
    let chat = stream(data, chat_source.as_deref());
    let updates = stream(data, updates_source.as_deref());
    let timing = Timing::from_streams(
        &stream(data, primary_source(data, "events.jsonl").as_deref()),
        &updates,
    );
    let compacted = data.artifacts.iter().any(|artifact| {
        artifact
            .name
            .split('/')
            .any(|part| part == "compaction_checkpoints")
    });
    let mut builder = Builder::new(data, timing);
    let mut notes = vec![];
    // Compaction replaces the model-visible history with a summary, but the
    // client stream still holds every earlier prompt, reply, and tool call.
    if !chat.is_empty() && (!compacted || updates.is_empty()) {
        builder.read_chat(&chat);
    } else if !updates.is_empty() {
        if let Some(system) = chat.iter().find(|event| event.kind == "system") {
            builder.system(system);
        }
        builder.read_updates(&updates);
        builder.attach_chat_reasoning(&chat);
        if compacted {
            notes.push("The chat history was compacted, so the transcript is rebuilt from the client update stream (updates.jsonl). Context the harness injected before compaction is not included.".into());
        }
    }
    let mut entries = builder.entries;
    for (index, entry) in entries.iter_mut().enumerate() {
        entry.index = index;
    }
    link_sealed_updates(data, updates_source.as_deref(), &mut entries);
    for entry in &mut entries {
        entry.encryption = entry_encryption(entry, &data.events);
    }
    let untimed = entries
        .iter()
        .filter(|entry| entry.start_ms.is_none())
        .count();
    if untimed > 0 {
        notes.push(format!(
            "{untimed} transcript {} no recorded timing and {} not drawn on the timeline.",
            if untimed == 1 {
                "entry has"
            } else {
                "entries have"
            },
            if untimed == 1 { "is" } else { "are" }
        ));
    }
    (entries, notes)
}

struct Builder<'a> {
    data: &'a TraceData,
    timing: Timing,
    entries: Vec<TranscriptEntry>,
    turn: Option<u64>,
    /// Latest recorded time reached by the transcript so far.
    cursor: Option<i64>,
    call_cursors: HashMap<Option<u64>, usize>,
    pending_reasoning: Vec<usize>,
    pending_users: Vec<usize>,
    tools: HashMap<String, usize>,
}

enum UserBoundary {
    /// Context injected ahead of the prompt that starts a turn.
    Prompt(Option<i64>),
    /// Injected between model calls.
    MidTurn,
    /// Trailing messages, such as a shell command run after the reply.
    End,
}

impl<'a> Builder<'a> {
    fn new(data: &'a TraceData, timing: Timing) -> Self {
        Self {
            data,
            timing,
            entries: vec![],
            turn: None,
            cursor: None,
            call_cursors: HashMap::new(),
            pending_reasoning: vec![],
            pending_users: vec![],
            tools: HashMap::new(),
        }
    }

    fn push(
        &mut self,
        kind: EntryKind,
        title: impl Into<String>,
        text: String,
        event: &TraceEvent,
    ) -> usize {
        self.entries.push(TranscriptEntry {
            index: 0,
            kind,
            title: title.into(),
            text,
            turn: self.turn,
            start_ms: None,
            end_ms: None,
            wait_ms: None,
            tool_call_id: None,
            status: None,
            encryption: Encryption::None,
            event_indices: vec![event.index],
        });
        self.entries.len() - 1
    }

    fn place(&mut self, entry: usize, start: Option<i64>, end: Option<i64>) {
        if let Some(entry) = self.entries.get_mut(entry) {
            entry.start_ms = start;
            entry.end_ms = end;
        }
        if let Some(time) = end.or(start) {
            self.cursor = Some(self.cursor.map_or(time, |cursor| cursor.max(time)));
        }
    }

    fn set_wait(&mut self, entry: usize, wait_ms: Option<u64>) {
        if let Some(entry) = self.entries.get_mut(entry) {
            entry.wait_ms = wait_ms;
        }
    }

    /// Add a raw record to an entry once.
    fn link(&mut self, entry: usize, event: usize) {
        if let Some(entry) = self.entries.get_mut(entry)
            && !entry.event_indices.contains(&event)
        {
            entry.event_indices.push(event);
        }
    }

    fn system(&mut self, event: &TraceEvent) {
        let text = text_content(payload(&event.raw).get("content").unwrap_or(&Value::Null));
        let entry = self.push(EntryKind::System, "System prompt", text, event);
        let start = self.timing.session_start;
        self.place(entry, start, start);
    }

    fn read_chat(&mut self, chat: &[&TraceEvent]) {
        for event in chat {
            let value = payload(&event.raw);
            match event.kind.as_str() {
                "system" => self.system(event),
                "user" => {
                    let text = text_content(value.get("content").unwrap_or(&Value::Null));
                    if let Some(index) = prompt_index(value) {
                        self.finish_model_output();
                        self.turn = Some(index);
                        let time = self.timing.prompts.get(&index).copied();
                        self.resolve_users(UserBoundary::Prompt(time));
                        let entry = self.push(EntryKind::User, "Prompt", text, event);
                        self.place(entry, time, time);
                    } else {
                        let title = user_title(value, &text);
                        let entry = self.push(EntryKind::User, title, text, event);
                        self.pending_users.push(entry);
                    }
                }
                "reasoning" => {
                    self.resolve_users(UserBoundary::MidTurn);
                    let text = super::data::reasoning_text(value);
                    let entry = self.push(EntryKind::Reasoning, "Reasoning", text, event);
                    self.pending_reasoning.push(entry);
                }
                "assistant" => {
                    self.resolve_users(UserBoundary::MidTurn);
                    self.assistant(event, value);
                }
                "tool_call" => self.tool_call(event),
                "tool_result" | "tool" | "backend_tool_call" => self.tool_result(event),
                _ => {}
            }
        }
        self.finish_model_output();
        self.resolve_users(UserBoundary::End);
    }

    fn assistant(&mut self, event: &TraceEvent, value: &Value) {
        let text = text_content(value.get("content").unwrap_or(&Value::Null));
        let ids: Vec<String> = value
            .get("tool_calls")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|call| string(call, &["id", "call_id"]))
            .collect();
        let call = self.timing.claim(&mut self.call_cursors, self.turn, &ids);
        let reasoning = std::mem::take(&mut self.pending_reasoning);
        let has_text = !text.trim().is_empty();
        let reasoning_end = call
            .as_ref()
            .and_then(|call| call.text_start.filter(|_| has_text).or(call.end));
        for &entry in &reasoning {
            self.set_wait(entry, call.as_ref().and_then(ModelCall::wait_ms));
            self.place(entry, call.as_ref().map(|call| call.start), reasoning_end);
        }
        // A tool-call-only reply is represented by its reasoning and tool entries.
        if has_text || reasoning.is_empty() {
            let title = if has_text {
                "Assistant"
            } else {
                "Tool request"
            };
            let entry = self.push(EntryKind::Assistant, title, text, event);
            if let Some(call) = &call {
                let start = if reasoning.is_empty() {
                    self.set_wait(entry, call.wait_ms());
                    Some(call.start)
                } else {
                    reasoning_end
                };
                self.place(entry, start, call.end);
            }
        } else if let Some(&last) = reasoning.last() {
            self.link(last, event.index);
        }
    }

    /// Place reasoning that never received a reply, such as an interrupted call.
    fn finish_model_output(&mut self) {
        let reasoning = std::mem::take(&mut self.pending_reasoning);
        if reasoning.is_empty() {
            return;
        }
        let call = self.timing.claim(&mut self.call_cursors, self.turn, &[]);
        for entry in reasoning {
            if let Some(call) = &call {
                self.set_wait(entry, call.wait_ms());
                self.place(entry, Some(call.start), call.end);
            }
        }
    }

    fn tool_call(&mut self, event: &TraceEvent) {
        let Some(id) = event.tool_call_id.clone() else {
            return;
        };
        let tool = self.data.tools.iter().find(|tool| tool.id == id);
        let title = tool.map_or_else(|| event.title.clone(), |tool| tool.name.clone());
        let summary = tool
            .and_then(|tool| tool.input.as_ref())
            .map_or_else(|| event.text.clone(), summarize_input);
        let entry = self.push(EntryKind::Tool, title, summary, event);
        if let Some(entry) = self.entries.get_mut(entry) {
            // Every stream's record of this call: request, result, timing, and client updates.
            if let Some(tool) = tool {
                entry.event_indices.extend(&tool.event_indices);
                entry.event_indices.sort_unstable();
                entry.event_indices.dedup();
            }
            entry.tool_call_id = Some(id.clone());
            entry.status = tool.map(|tool| tool.status.clone());
        }
        let timing = self.timing.tools.get(&id).cloned().unwrap_or_default();
        // A started call with no recorded completion is drawn as a start marker.
        let start = timing.start.or(timing.end).or(self.cursor);
        self.place(entry, start, timing.end);
        self.tools.insert(id, entry);
    }

    fn tool_result(&mut self, event: &TraceEvent) {
        if let Some(&entry) = event
            .tool_call_id
            .as_ref()
            .and_then(|id| self.tools.get(id))
        {
            self.link(entry, event.index);
            return;
        }
        // Results without a recorded call (and backend tools) stand alone.
        self.tool_call(event);
        if event.tool_call_id.is_none() {
            let entry = self.push(
                EntryKind::Tool,
                event.title.clone(),
                event.text.clone(),
                event,
            );
            if let Some(entry) = self.entries.get_mut(entry) {
                entry.status = event.status.clone();
            }
        }
    }

    fn resolve_users(&mut self, boundary: UserBoundary) {
        for entry in std::mem::take(&mut self.pending_users) {
            let time = match boundary {
                UserBoundary::MidTurn => self.cursor,
                UserBoundary::Prompt(prompt) => match self.next_user_message(prompt) {
                    Some(time) => Some(time),
                    None => {
                        // Injected with the prompt, so it belongs to the prompt's turn.
                        let turn = self.turn;
                        if let Some(entry) = self.entries.get_mut(entry) {
                            entry.turn = turn;
                        }
                        prompt
                    }
                },
                UserBoundary::End => self.next_user_message(None).or(self.cursor),
            };
            self.place(entry, time, time);
        }
    }

    /// The next recorded non-prompt message between the transcript cursor and `limit`.
    fn next_user_message(&mut self, limit: Option<i64>) -> Option<i64> {
        let queue = &mut self.timing.user_messages;
        while queue
            .front()
            .is_some_and(|&time| self.cursor.is_some_and(|cursor| time < cursor))
        {
            queue.pop_front();
        }
        queue
            .front()
            .copied()
            .filter(|&time| limit.is_none_or(|limit| time <= limit))
            .inspect(|_| {
                queue.pop_front();
            })
    }

    /// Join the chat history's reasoning records to the entries rebuilt from the update stream.
    ///
    /// Updates carry only readable thought text; whether the model also returned encrypted
    /// reasoning is recorded in chat history. A session that switches between models that do
    /// and do not encrypt is compacted, so the history covers only later turns and each record
    /// is matched to its own entry: readable reasoning by its text, and sealed reasoning by the
    /// reply that followed it. Records that match nothing stay in the record view.
    fn attach_chat_reasoning(&mut self, chat: &[&TraceEvent]) {
        let mut cursor = 0;
        for (position, event) in chat.iter().enumerate() {
            if event.kind != "reasoning" {
                continue;
            }
            let same_turn = |entry: &TranscriptEntry| {
                event.turn.is_none() || entry.turn.is_none() || entry.turn == event.turn
            };
            let text = super::data::reasoning_text(payload(&event.raw));
            let found = if reasoning_is_readable(&text) {
                (cursor..self.entries.len()).find(|&index| {
                    let entry = &self.entries[index];
                    entry.kind == EntryKind::Reasoning
                        && same_turn(entry)
                        && same_text(&entry.text, &text)
                })
            } else {
                let reply = chat[position + 1..]
                    .iter()
                    .take_while(|next| next.kind != "reasoning" && next.kind != "user")
                    .find(|next| next.kind == "assistant");
                reply
                    .and_then(|reply| self.reply_entry(reply, cursor))
                    .filter(|&anchor| same_turn(&self.entries[anchor]))
                    .map(|anchor| {
                        let previous = anchor.checked_sub(1).filter(|&index| {
                            let entry = &self.entries[index];
                            index >= cursor
                                && entry.kind == EntryKind::Reasoning
                                && same_turn(entry)
                        });
                        previous.unwrap_or_else(|| self.insert_sealed_reasoning(anchor, event))
                    })
            };
            if let Some(index) = found {
                if let Some(entry) = self.entries.get_mut(index)
                    && !entry.event_indices.contains(&event.index)
                {
                    entry.event_indices.push(event.index);
                    entry.event_indices.sort_unstable();
                }
                cursor = index + 1;
            }
        }
    }

    /// The first entry at or after `from` that shows a chat history reply.
    fn reply_entry(&self, reply: &TraceEvent, from: usize) -> Option<usize> {
        let value = payload(&reply.raw);
        let text = text_content(value.get("content").unwrap_or(&Value::Null));
        let ids: Vec<String> = value
            .get("tool_calls")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|call| string(call, &["id", "call_id"]))
            .collect();
        (from..self.entries.len()).find(|&index| {
            let entry = &self.entries[index];
            match entry.kind {
                EntryKind::Tool => entry
                    .tool_call_id
                    .as_ref()
                    .is_some_and(|id| ids.contains(id)),
                EntryKind::Assistant => !text.trim().is_empty() && same_text(&entry.text, &text),
                _ => false,
            }
        })
    }

    /// Show sealed reasoning that produced no thought text, before the reply it led to.
    fn insert_sealed_reasoning(&mut self, anchor: usize, event: &TraceEvent) -> usize {
        let reply = &self.entries[anchor];
        let call = reply
            .start_ms
            .and_then(|time| self.timing.call_before(time));
        let (start, end, wait) = match call {
            Some(call) => (
                Some(call.start),
                call.text_start.or(call.end),
                call.wait_ms(),
            ),
            None => (reply.start_ms, reply.start_ms, None),
        };
        let entry = TranscriptEntry {
            index: 0,
            kind: EntryKind::Reasoning,
            title: "Reasoning".into(),
            text: super::data::ENCRYPTED_ONLY.into(),
            turn: reply.turn,
            start_ms: start,
            end_ms: end,
            wait_ms: wait,
            tool_call_id: None,
            status: None,
            encryption: Encryption::None,
            event_indices: vec![],
        };
        self.entries.insert(anchor, entry);
        anchor
    }

    fn read_updates(&mut self, updates: &[&TraceEvent]) {
        // (kind, entry, whether the entry's timing came from its model call)
        let mut previous: Option<(&str, usize, bool)> = None;
        let mut latest_reasoning: Option<usize> = None;
        for event in updates {
            let value = payload(&event.raw);
            let time = time_ms(&event.timestamp);
            let kind = event.kind.as_str();
            let text = value.get("content").map(text_content).unwrap_or_default();
            // Streamed chunks of one block become one entry.
            if let Some((previous_kind, entry, from_call)) = previous
                && previous_kind == kind
                && matches!(
                    kind,
                    "user_message_chunk" | "agent_thought_chunk" | "agent_message_chunk"
                )
            {
                let Some(merged) = self.entries.get_mut(entry) else {
                    continue;
                };
                merged.text.push_str(&text);
                merged.event_indices.push(event.index);
                let (start, end) = (merged.start_ms, merged.end_ms);
                if kind != "user_message_chunk" && !from_call {
                    self.place(entry, start.or(time), end.max(time));
                }
                continue;
            }
            previous = None;
            match kind {
                "user_message_chunk" => {
                    let index = prompt_index(value);
                    self.turn = index.or(self.turn);
                    let title = if index.is_some() {
                        "Prompt"
                    } else {
                        user_title(value, &text)
                    };
                    let entry = self.push(EntryKind::User, title, text, event);
                    self.place(entry, time, time);
                    previous = Some((kind, entry, false));
                }
                "agent_thought_chunk" | "agent_message_chunk" => {
                    let reasoning = kind == "agent_thought_chunk";
                    let (entry_kind, title) = if reasoning {
                        (EntryKind::Reasoning, "Reasoning")
                    } else {
                        (EntryKind::Assistant, "Assistant")
                    };
                    let entry_text = if reasoning && text.is_empty() {
                        super::data::reasoning_text(value)
                    } else {
                        text
                    };
                    let entry = self.push(entry_kind, title, entry_text, event);
                    if reasoning {
                        latest_reasoning = Some(entry);
                    }
                    // Chunks are flushed when a call finishes, so block boundaries
                    // come from the call's recorded phases rather than chunk times.
                    let call = time.and_then(|time| self.timing.call_before(time)).cloned();
                    let from_call = call.is_some();
                    match call {
                        Some(call) => {
                            let previous_reasoning = entry
                                .checked_sub(1)
                                .and_then(|index| self.entries.get(index))
                                .filter(|entry| {
                                    entry.kind == EntryKind::Reasoning
                                        && entry.start_ms == Some(call.start)
                                })
                                .map(|entry| entry.end_ms);
                            let (start, end) = match previous_reasoning {
                                _ if reasoning => (Some(call.start), call.text_start.or(call.end)),
                                Some(reasoning_end) => {
                                    (call.text_start.or(reasoning_end), call.end)
                                }
                                None => (Some(call.start), call.end),
                            };
                            if start == Some(call.start) {
                                self.set_wait(entry, call.wait_ms());
                            }
                            self.place(entry, start, end.or(time));
                        }
                        None => self.place(entry, time, time),
                    }
                    previous = Some((kind, entry, from_call));
                }
                "reasoning" | "reasoning_completed" => {
                    if kind == "reasoning" || event.encryption.is_encrypted() {
                        let text = super::data::reasoning_text(value);
                        // A call that returned only sealed reasoning must not lock the
                        // readable reasoning of an earlier call.
                        let call_start = time
                            .and_then(|time| self.timing.call_before(time))
                            .map(|call| call.start);
                        let entry = latest_reasoning
                            .filter(|index| {
                                self.entries.get(*index).is_some_and(|entry| {
                                    entry.kind == EntryKind::Reasoning
                                        && entry.turn == self.turn
                                        && call_start.is_none_or(|call| {
                                            entry.start_ms.is_none_or(|start| start >= call)
                                        })
                                })
                            })
                            .unwrap_or_else(|| {
                                self.push(EntryKind::Reasoning, "Reasoning", text, event)
                            });
                        self.link(entry, event.index);
                        latest_reasoning = Some(entry);
                    }
                }
                "tool_call"
                    if event
                        .tool_call_id
                        .as_ref()
                        .is_some_and(|id| !self.tools.contains_key(id)) =>
                {
                    self.tool_call(event);
                }
                "tool_call" | "tool_call_update" => {
                    if let Some(&entry) = event
                        .tool_call_id
                        .as_ref()
                        .and_then(|id| self.tools.get(id))
                    {
                        self.link(entry, event.index);
                        let finished =
                            string(value, &["status"]).is_some_and(|status| finished(&status));
                        let open = self
                            .entries
                            .get(entry)
                            .filter(|entry| entry.end_ms.is_none())
                            .map(|entry| entry.start_ms);
                        if let (true, Some(start)) = (finished, open) {
                            self.place(entry, start, time);
                        }
                    }
                }
                _ => {}
            }
        }
    }
}

fn user_title(value: &Value, text: &str) -> &'static str {
    let trimmed = text.trim_start();
    if value.get("synthetic_reason").is_some()
        || trimmed.starts_with("<system-reminder>")
        || trimmed.starts_with("<user_info>")
    {
        "Context"
    } else if value.pointer("/_meta/bash_command").is_some()
        || value.pointer("/content/_meta/bash_command").is_some()
        || trimmed.starts_with("I executed a terminal command")
    {
        "Shell command"
    } else {
        "User message"
    }
}

/// Attach a sealed update that never met its reasoning entry.
///
/// The Messages backend sends a thinking block's signature on a separate
/// `reasoning_completed` update. When chat history is the transcript, that update
/// is not part of the entry yet, so the signature would not be classified with it.
/// Only the session's own stream is used: a subagent or bundled copy may run a different model.
fn link_sealed_updates(data: &TraceData, source: Option<&str>, entries: &mut [TranscriptEntry]) {
    let Some(source) = source else {
        return;
    };
    for event in data
        .events
        .iter()
        .filter(|event| event.encryption.is_encrypted() && event.source == source)
    {
        if entries
            .iter()
            .any(|entry| entry.event_indices.contains(&event.index))
        {
            continue;
        }
        let event_time = time_ms(&event.timestamp);
        let Some(entry_index) = entries.iter().enumerate().rev().find_map(|(index, entry)| {
            (entry.kind == EntryKind::Reasoning
                && (event.turn.is_none() || entry.turn.is_none() || entry.turn == event.turn)
                && event_time.is_none_or(|time| entry.start_ms.is_none_or(|start| time >= start)))
            .then_some(index)
        }) else {
            continue;
        };
        let Some(entry) = entries.get_mut(entry_index) else {
            continue;
        };
        entry.event_indices.push(event.index);
        entry.event_indices.sort_unstable();
    }
}

/// A one-line description of a tool input for lists and timeline labels.
fn summarize_input(input: &Value) -> String {
    let summary = [
        "command",
        "file_path",
        "target_file",
        "path",
        "pattern",
        "query",
        "url",
        "prompt",
        "description",
    ]
    .iter()
    .find_map(|key| input.get(*key).and_then(Value::as_str))
    .map(str::to_owned)
    .unwrap_or_else(|| match input {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    });
    let line = summary.split_whitespace().collect::<Vec<_>>().join(" ");
    match line.char_indices().nth(300) {
        Some((end, _)) => format!("{}…", &line[..end]),
        None => line,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::super::data::load;
    use super::Encryption;
    use super::*;

    fn kinds(data: &TraceData) -> Vec<(EntryKind, &str)> {
        data.transcript
            .iter()
            .map(|entry| (entry.kind, entry.title.as_str()))
            .collect()
    }

    fn session(files: &[(&str, &str)]) -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        for (name, contents) in files {
            let path = directory.path().join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, contents).unwrap();
        }
        directory
    }

    #[test]
    fn chat_history_takes_model_and_tool_timing_from_the_event_log() {
        let data = load(Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/trace_view/fixtures/session"
        )))
        .unwrap();
        assert!(data.transcript.iter().all(|entry| entry.start_ms.is_some()));
        let at = |index: usize| &data.transcript[index];
        // Reasoning runs from the request to the first text; the wait is time to first token.
        assert_eq!(
            (at(2).kind, at(2).duration_ms(), at(2).wait_ms),
            (EntryKind::Reasoning, Some(2_920), Some(1_190))
        );
        assert_eq!(
            (at(3).kind, at(3).duration_ms()),
            (EntryKind::Assistant, Some(740))
        );
        // Tool bars are recorded execution time, excluding the permission wait.
        assert_eq!(
            (at(6).title.as_str(), at(6).duration_ms()),
            ("bash", Some(1_040))
        );
        assert!(at(6).is_error());
        assert_eq!(at(6).event_indices.len(), 4);
        // A reminder injected between calls sits where the transcript had reached.
        assert_eq!(
            (at(7).title.as_str(), at(7).start_ms),
            ("Context", at(6).end_ms)
        );
        assert!(
            data.transcript[1..]
                .iter()
                .all(|entry| entry.turn == Some(0))
        );
        assert_eq!(data.turns.first().unwrap().number, 0);
    }

    #[test]
    fn replies_made_only_of_tool_calls_are_timed_without_a_first_token() {
        let directory = session(&[
            (
                "chat_history.jsonl",
                concat!(
                    "{\"type\":\"user\",\"prompt_index\":0,\"content\":\"List files\"}\n",
                    "{\"type\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"a\",\"name\":\"ls\",\"arguments\":\"{}\"}]}\n",
                    "{\"type\":\"tool_result\",\"tool_call_id\":\"a\",\"content\":\"src\"}\n",
                    "{\"type\":\"assistant\",\"content\":\"Done\"}\n"
                ),
            ),
            (
                "events.jsonl",
                concat!(
                    "{\"ts\":\"2026-01-01T00:00:00.000Z\",\"type\":\"turn_started\",\"turn_number\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:00.100Z\",\"type\":\"loop_started\",\"loop_index\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:02.100Z\",\"type\":\"phase_changed\",\"phase\":\"tool_execution\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:02.600Z\",\"type\":\"tool_completed\",\"tool_call_id\":\"a\",\"duration_ms\":500,\"outcome\":\"success\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:02.700Z\",\"type\":\"loop_started\",\"loop_index\":1}\n",
                    "{\"ts\":\"2026-01-01T00:00:03.700Z\",\"type\":\"first_token\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:04.700Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n"
                ),
            ),
        ]);
        let data = load(directory.path()).unwrap();
        assert_eq!(
            kinds(&data),
            vec![
                (EntryKind::User, "Prompt"),
                (EntryKind::Assistant, "Tool request"),
                (EntryKind::Tool, "ls"),
                (EntryKind::Assistant, "Assistant"),
            ]
        );
        let durations: Vec<_> = data
            .transcript
            .iter()
            .map(TranscriptEntry::duration_ms)
            .collect();
        assert_eq!(
            durations,
            vec![Some(0), Some(2_000), Some(500), Some(2_000)]
        );
        assert_eq!(data.transcript[3].wait_ms, Some(1_000));
        // The tool result is part of its call, not a separate entry.
        assert_eq!(data.transcript[2].event_indices.len(), 3);
    }

    #[test]
    fn compacted_history_is_rebuilt_from_the_update_stream() {
        let update = |ms: u64, update: &str| {
            format!(
                "{{\"method\":\"session/update\",\"params\":{{\"update\":{update},\"_meta\":{{\"agentTimestampMs\":{ms}}}}}}}\n"
            )
        };
        let base = 1_767_225_600_000_u64;
        let updates = [
            update(base, r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Move the app"},"_meta":{"promptIndex":0}}"#),
            update(base + 3_000, r#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Find it "}}"#),
            update(base + 3_001, r#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"first."}}"#),
            update(base + 3_002, r#"{"sessionUpdate":"reasoning_completed","signature":"opaque"}"#),
            update(base + 3_003, r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Looking."}}"#),
            update(base + 3_003, r#"{"sessionUpdate":"tool_call","toolCallId":"t","title":"ls","rawInput":{"command":"ls"}}"#),
            update(base + 4_000, r#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"completed","rawOutput":"App.app"}"#),
        ]
        .concat();
        let directory = session(&[
            (
                "chat_history.jsonl",
                concat!(
                    "{\"type\":\"system\",\"content\":\"You are Grok\"}\n",
                    "{\"type\":\"user\",\"content\":\"This session is being continued from a previous conversation.\"}\n"
                ),
            ),
            (
                "compaction_checkpoints/c1.json",
                "{\"compacted_history\":[]}",
            ),
            (
                "events.jsonl",
                concat!(
                    "{\"ts\":\"2026-01-01T00:00:00.000Z\",\"type\":\"turn_started\",\"turn_number\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:00.100Z\",\"type\":\"loop_started\",\"loop_index\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:01.100Z\",\"type\":\"first_token\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:02.000Z\",\"type\":\"phase_changed\",\"phase\":\"streaming_text\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:02.500Z\",\"type\":\"phase_changed\",\"phase\":\"tool_execution\"}\n"
                ),
            ),
            ("updates.jsonl", &updates),
        ]);
        let data = load(directory.path()).unwrap();
        assert_eq!(
            kinds(&data),
            vec![
                (EntryKind::System, "System prompt"),
                (EntryKind::User, "Prompt"),
                (EntryKind::Reasoning, "Reasoning"),
                (EntryKind::Assistant, "Assistant"),
                (EntryKind::Tool, "ls"),
            ]
        );
        let reasoning = &data.transcript[2];
        // The thought text is readable; the signature is an encrypted copy of the full reasoning.
        assert_eq!(reasoning.encryption, Encryption::Partial);
        // Chunks of one block merge; boundaries come from the call's phases.
        assert_eq!(reasoning.text, "Find it first.");
        assert_eq!(
            (reasoning.duration_ms(), reasoning.wait_ms),
            (Some(1_900), Some(1_000))
        );
        assert_eq!(data.transcript[3].duration_ms(), Some(500));
        assert_eq!(data.transcript[4].duration_ms(), Some(997));
        assert!(
            data.warnings
                .iter()
                .any(|warning| warning.contains("compacted"))
        );
    }

    #[test]
    fn update_signature_marks_reasoning_even_when_chat_history_is_primary() {
        let directory = session(&[
            (
                "chat_history.jsonl",
                concat!(
                    "{\"type\":\"user\",\"prompt_index\":0,\"content\":\"Hi\"}\n",
                    "{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Visible\"}]}\n",
                    "{\"type\":\"assistant\",\"content\":\"Hello\"}\n"
                ),
            ),
            (
                "updates.jsonl",
                "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"reasoning_completed\",\"signature\":\"opaque\"},\"_meta\":{\"agentTimestampMs\":1767225600000}}}\n",
            ),
        ]);
        let data = load(directory.path()).unwrap();
        let reasoning = &data.transcript[1];
        assert_eq!(reasoning.encryption, Encryption::Partial);
        assert_eq!(reasoning.text, "Visible");
        assert!(
            reasoning
                .event_indices
                .iter()
                .any(|index| data.events[*index].encryption == Encryption::Full)
        );
    }

    #[test]
    fn switching_between_encrypting_and_plain_models_classifies_each_turn() {
        let update = |ms: u64, update: &str| {
            format!(
                "{{\"method\":\"session/update\",\"params\":{{\"update\":{update},\"_meta\":{{\"agentTimestampMs\":{ms}}}}}}}\n"
            )
        };
        let thought = |ms: u64, text: &str| {
            update(
                ms,
                &format!(
                    r#"{{"sessionUpdate":"agent_thought_chunk","content":{{"type":"text","text":"{text}"}}}}"#
                ),
            )
        };
        let tool = |ms: u64, id: &str| {
            [
                update(
                    ms,
                    &format!(
                        r#"{{"sessionUpdate":"tool_call","toolCallId":"{id}","title":"ls","rawInput":{{"command":"ls"}}}}"#
                    ),
                ),
                update(
                    ms + 10,
                    &format!(
                        r#"{{"sessionUpdate":"tool_call_update","toolCallId":"{id}","status":"completed","rawOutput":"ok"}}"#
                    ),
                ),
            ]
            .concat()
        };
        let base = 1_767_225_600_000_u64;
        // Turn 0 ran a plain model; its history was compacted away when the model switched.
        // Turn 1 ran a model that returns a summary with, or without, encrypted reasoning.
        let updates = [
            update(base, r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"First"},"_meta":{"promptIndex":0}}"#),
            thought(base + 100, "Plain thinking."),
            update(base + 200, r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"One"}}"#),
            update(base + 1_000, r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Second"},"_meta":{"promptIndex":1}}"#),
            thought(base + 1_100, "**Plan**"),
            thought(base + 1_101, "\\n\\nList it."),
            tool(base + 1_200, "a"),
            tool(base + 1_400, "b"),
            thought(base + 1_500, "Wrap up."),
            update(base + 1_600, r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Two"}}"#),
        ]
        .concat();
        let details = |details: serde_json::Value| serde_json::Value::String(details.to_string());
        let reasoning = |summary: &str, encrypted: serde_json::Value| {
            serde_json::json!({"type": "reasoning", "id": "grok_openrouter_reasoning_v1",
                "summary": [{"type": "summary_text", "text": summary}],
                "encrypted_content": encrypted})
            .to_string()
        };
        let chat = [
            r#"{"type":"system","content":"You are Grok"}"#.to_owned(),
            r#"{"type":"user","content":"This session is being continued from a previous conversation."}"#.into(),
            r#"{"type":"user","prompt_index":1,"content":"Second"}"#.into(),
            reasoning(
                "**Plan**\nList it.",
                details(serde_json::json!([
                    {"type": "reasoning.summary", "summary": "**Plan**\nList it."},
                    {"type": "reasoning.encrypted", "data": "gAAAAABopaque"}
                ])),
            ),
            r#"{"type":"assistant","content":"","tool_calls":[{"id":"a","name":"ls","arguments":"{}"}]}"#.into(),
            r#"{"type":"tool_result","tool_call_id":"a","content":"ok"}"#.into(),
            reasoning(
                "",
                details(serde_json::json!([{"type": "reasoning.encrypted", "data": "gAAAAAB"}])),
            ),
            r#"{"type":"assistant","content":"","tool_calls":[{"id":"b","name":"ls","arguments":"{}"}]}"#.into(),
            r#"{"type":"tool_result","tool_call_id":"b","content":"ok"}"#.into(),
            reasoning(
                "Wrap up.",
                details(serde_json::json!([{"type": "reasoning.text", "text": "Wrap up."}])),
            ),
            r#"{"type":"assistant","content":"Two"}"#.into(),
        ]
        .join("\n");
        let directory = session(&[
            ("chat_history.jsonl", &chat),
            (
                "compaction_checkpoints/c1.json",
                "{\"compacted_history\":[]}",
            ),
            ("updates.jsonl", &updates),
        ]);
        let data = load(directory.path()).unwrap();
        let entries: Vec<_> = data
            .transcript
            .iter()
            .filter(|entry| entry.kind != EntryKind::System)
            .map(|entry| {
                (
                    entry.kind,
                    entry.turn,
                    entry.encryption,
                    entry.text.as_str(),
                )
            })
            .collect();
        assert_eq!(
            entries,
            vec![
                (EntryKind::User, Some(0), Encryption::None, "First"),
                (
                    EntryKind::Reasoning,
                    Some(0),
                    Encryption::None,
                    "Plain thinking."
                ),
                (EntryKind::Assistant, Some(0), Encryption::None, "One"),
                (EntryKind::User, Some(1), Encryption::None, "Second"),
                (
                    EntryKind::Reasoning,
                    Some(1),
                    Encryption::Partial,
                    "**Plan**\n\nList it."
                ),
                (EntryKind::Tool, Some(1), Encryption::None, "{}"),
                (
                    EntryKind::Reasoning,
                    Some(1),
                    Encryption::Full,
                    super::super::data::ENCRYPTED_ONLY
                ),
                (EntryKind::Tool, Some(1), Encryption::None, "{}"),
                (EntryKind::Reasoning, Some(1), Encryption::None, "Wrap up."),
                (EntryKind::Assistant, Some(1), Encryption::None, "Two"),
            ]
        );
        // Sealed reasoning with no thought text sits where its call ran.
        let sealed = data
            .transcript
            .iter()
            .find(|entry| entry.encryption == Encryption::Full)
            .unwrap();
        assert!(sealed.start_ms.is_some());
    }

    #[test]
    fn a_signature_from_another_stream_or_call_does_not_lock_plain_reasoning() {
        let update = |ms: u64, update: &str| {
            format!(
                "{{\"method\":\"session/update\",\"params\":{{\"update\":{update},\"_meta\":{{\"agentTimestampMs\":{ms}}}}}}}\n"
            )
        };
        let signature = r#"{"sessionUpdate":"reasoning_completed","signature":"opaque"}"#;
        // The session's plain model shares the directory with a subagent that signs its thinking.
        let directory = session(&[
            (
                "chat_history.jsonl",
                concat!(
                    "{\"type\":\"user\",\"prompt_index\":0,\"content\":\"Hi\"}\n",
                    "{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Visible\"}]}\n",
                    "{\"type\":\"assistant\",\"content\":\"Hello\"}\n"
                ),
            ),
            (
                "updates.jsonl",
                &update(
                    1_767_225_600_000,
                    r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Hi"},"_meta":{"promptIndex":0}}"#,
                ),
            ),
            (
                "subagents/child/updates.jsonl",
                &update(1_767_225_600_500, signature),
            ),
        ]);
        let data = load(directory.path()).unwrap();
        assert_eq!(data.transcript[1].encryption, Encryption::None);

        // Two calls in one turn: plain reasoning, then a call that returned only a signature.
        let base = 1_767_225_600_000_u64;
        let updates = [
            update(base, r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Go"},"_meta":{"promptIndex":0}}"#),
            update(base + 1_100, r#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Plain."}}"#),
            update(base + 1_200, r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"One"}}"#),
            update(base + 3_100, signature),
            update(base + 3_200, r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Two"}}"#),
        ]
        .concat();
        let directory = session(&[
            (
                "events.jsonl",
                concat!(
                    "{\"ts\":\"2026-01-01T00:00:00.000Z\",\"type\":\"turn_started\",\"turn_number\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:01.000Z\",\"type\":\"loop_started\",\"loop_index\":0}\n",
                    "{\"ts\":\"2026-01-01T00:00:01.050Z\",\"type\":\"first_token\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:03.000Z\",\"type\":\"loop_started\",\"loop_index\":1}\n",
                    "{\"ts\":\"2026-01-01T00:00:03.050Z\",\"type\":\"first_token\"}\n",
                    "{\"ts\":\"2026-01-01T00:00:04.000Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n"
                ),
            ),
            ("updates.jsonl", &updates),
        ]);
        let data = load(directory.path()).unwrap();
        let reasoning: Vec<_> = data
            .transcript
            .iter()
            .filter(|entry| entry.kind == EntryKind::Reasoning)
            .map(|entry| (entry.encryption, entry.text.as_str()))
            .collect();
        assert_eq!(
            reasoning,
            vec![
                (Encryption::None, "Plain."),
                (Encryption::Full, super::super::data::ENCRYPTED_ONLY),
            ]
        );
    }

    #[test]
    fn entries_without_recorded_timing_stay_untimed() {
        let directory = session(&[(
            "chat_history.jsonl",
            concat!(
                "{\"type\":\"user\",\"prompt_index\":0,\"content\":\"Hi\"}\n",
                "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}\n",
                "{\"type\":\"assistant\",\"content\":\"Hello\"}\n"
            ),
        )]);
        let data = load(directory.path()).unwrap();
        assert_eq!(data.transcript.len(), 3);
        assert!(data.transcript.iter().all(|entry| entry.start_ms.is_none()));
        assert_eq!(data.transcript[1].encryption, Encryption::Full);
        assert!(data.transcript[1].text.contains("unavailable"));
        assert!(
            data.warnings
                .iter()
                .any(|warning| warning.contains("3 transcript entries"))
        );
    }
}
