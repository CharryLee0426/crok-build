//! Session updates (live from the gateway, or replayed from `updates.jsonl`) → the relay's transcript items.
//!
//! Both arrive as the same JSON: `{"sessionId", "update": {"sessionUpdate": "agent_message_chunk", …}, "_meta"}` on
//! `session/update`, and xAI's extensions on `_x.ai/session/update` / `x.ai/session_notification`. Converting from
//! JSON keeps live mirroring and history backfill on one code path.

use std::collections::HashMap;

use crok_remote::types::{EventInput, EventKind, PlanEntry};
use serde_json::Value;

/// Detail kept for a tool call (command plus the tail of its output).
const TOOL_DETAIL_MAX: usize = 4_000;
const TOOL_OUTPUT_TAIL: usize = 1_500;
/// The list preview of a session: the start of its last message.
pub(crate) const PREVIEW_MAX: usize = 200;

/// What an update means for the session beyond its transcript.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Signal {
    Plan(Vec<PlanEntry>),
    Title(String),
    Model(String),
    /// A permission, question or plan approval is waiting on the computer.
    NeedsInput,
    InputResolved,
    TurnCompleted {
        prompt_id: Option<String>,
        stop_reason: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TextKind {
    User,
    Assistant,
    Thought,
}

impl TextKind {
    fn event_kind(self) -> EventKind {
        match self {
            TextKind::User => EventKind::User,
            TextKind::Assistant => EventKind::Assistant,
            TextKind::Thought => EventKind::Thought,
        }
    }

    fn letter(self) -> char {
        match self {
            TextKind::User => 'u',
            TextKind::Assistant => 'a',
            TextKind::Thought => 'r',
        }
    }
}

#[derive(Clone, Debug)]
struct OpenText {
    kind: TextKind,
    key: String,
    text: String,
    at: f64,
}

#[derive(Clone, Debug, Default)]
struct Tool {
    title: Option<String>,
    tool_kind: Option<String>,
    status: Option<String>,
    command: Option<String>,
    paths: Vec<String>,
    output: Option<String>,
    at: f64,
}

/// Builds one session's transcript items. Keys are unique per builder (`prefix`), except tool calls, which are keyed by
/// their own id so a backfilled call that finishes live is updated in place.
pub(crate) struct Transcript {
    prefix: String,
    counter: u64,
    open: Option<OpenText>,
    tools: HashMap<String, Tool>,
    /// Items changed since the last [`Transcript::take_dirty`], in first-change order.
    dirty: Vec<String>,
    events: HashMap<String, EventInput>,
    /// Whether to turn `user_message_chunk`s into items. Live, prompts are recorded where they are sent instead.
    record_user_chunks: bool,
    last_message: Option<(EventKind, String)>,
}

impl Transcript {
    pub(crate) fn new(prefix: impl Into<String>, record_user_chunks: bool) -> Transcript {
        Transcript {
            prefix: prefix.into(),
            counter: 0,
            open: None,
            tools: HashMap::new(),
            dirty: Vec::new(),
            events: HashMap::new(),
            record_user_chunks,
            last_message: None,
        }
    }

    fn next_key(&mut self, letter: char) -> String {
        self.counter += 1;
        format!("{}{letter}{}", self.prefix, self.counter)
    }

    fn mark(&mut self, event: EventInput) {
        if !self.dirty.contains(&event.key) {
            self.dirty.push(event.key.clone());
        }
        self.events.insert(event.key.clone(), event);
    }

    /// Ends the open text block; returns true when there was one (a boundary worth flushing at).
    pub(crate) fn close_text(&mut self) -> bool {
        match self.open.take() {
            Some(open) => {
                if matches!(open.kind, TextKind::User | TextKind::Assistant)
                    && !open.text.trim().is_empty()
                {
                    self.last_message = Some((open.kind.event_kind(), open.text));
                }
                true
            }
            None => false,
        }
    }

    fn append_text(&mut self, kind: TextKind, text: &str, at: f64) -> bool {
        let mut boundary = false;
        if self.open.as_ref().is_some_and(|open| open.kind != kind) {
            boundary = self.close_text();
        }
        if self.open.is_none() {
            let key = self.next_key(kind.letter());
            self.open = Some(OpenText {
                kind,
                key,
                text: String::new(),
                at,
            });
        }
        let Some(open) = self.open.as_mut() else {
            return boundary;
        };
        open.text.push_str(text);
        let event = EventInput {
            key: open.key.clone(),
            kind: kind.event_kind(),
            text: open.text.clone(),
            title: None,
            tool_kind: None,
            status: None,
            origin: None,
            command_id: None,
            from_label: None,
            at: open.at,
        };
        self.mark(event);
        boundary
    }

    /// A prompt sent into the session, recorded where it was sent (typed on the computer, or a remote command).
    pub(crate) fn user_prompt(
        &mut self,
        text: &str,
        origin: &str,
        command_id: Option<&str>,
        from_label: Option<&str>,
        at: f64,
    ) {
        self.close_text();
        let key = match command_id {
            Some(id) => format!("{}c{id}", self.prefix),
            None => self.next_key('p'),
        };
        let event = EventInput {
            key,
            kind: EventKind::User,
            text: text.to_string(),
            title: None,
            tool_kind: None,
            status: None,
            origin: Some(origin.to_string()),
            command_id: command_id.map(str::to_owned),
            from_label: from_label.map(str::to_owned),
            at,
        };
        self.last_message = Some((EventKind::User, text.to_string()));
        self.mark(event);
    }

    /// A line of its own: a turn that stopped early, a failure.
    pub(crate) fn notice(&mut self, kind: EventKind, text: &str, status: Option<&str>, at: f64) {
        self.close_text();
        let key = self.next_key('s');
        self.mark(EventInput {
            key,
            kind,
            text: text.to_string(),
            title: None,
            tool_kind: None,
            status: status.map(str::to_owned),
            origin: None,
            command_id: None,
            from_label: None,
            at,
        });
    }

    /// Applies one update. Returns the signals it carries and whether it closed an item (a good moment to flush).
    pub(crate) fn apply(&mut self, method: &str, params: &Value, at: f64) -> (Vec<Signal>, bool) {
        let Some(update) = params.get("update") else {
            return (Vec::new(), false);
        };
        let kind = update
            .get("sessionUpdate")
            .and_then(Value::as_str)
            .unwrap_or("");
        let at = params
            .get("_meta")
            .and_then(|m| m.get("agentTimestampMs"))
            .and_then(Value::as_f64)
            .unwrap_or(at);
        if method.ends_with("session/update") && !method.contains("x.ai") {
            self.apply_acp(kind, update, at)
        } else {
            self.apply_xai(kind, update, at)
        }
    }

    fn apply_acp(&mut self, kind: &str, update: &Value, at: f64) -> (Vec<Signal>, bool) {
        let text = || {
            update
                .get("content")
                .and_then(|c| c.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("")
        };
        match kind {
            "agent_message_chunk" => (
                Vec::new(),
                self.append_text(TextKind::Assistant, text(), at),
            ),
            "agent_thought_chunk" => (Vec::new(), self.append_text(TextKind::Thought, text(), at)),
            "user_message_chunk" if self.record_user_chunks => {
                (Vec::new(), self.append_text(TextKind::User, text(), at))
            }
            "tool_call" | "tool_call_update" => {
                let boundary = self.close_text();
                let changed_status = self.apply_tool(update, at);
                (Vec::new(), boundary || changed_status)
            }
            "plan" => {
                let entries = update
                    .get("entries")
                    .and_then(Value::as_array)
                    .map(|entries| {
                        entries
                            .iter()
                            .map(|entry| PlanEntry {
                                content: entry
                                    .get("content")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                                status: entry
                                    .get("status")
                                    .and_then(Value::as_str)
                                    .unwrap_or("pending")
                                    .to_string(),
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                (vec![Signal::Plan(entries)], false)
            }
            _ => (Vec::new(), false),
        }
    }

    fn apply_xai(&mut self, kind: &str, update: &Value, at: f64) -> (Vec<Signal>, bool) {
        let string = |name: &str| update.get(name).and_then(Value::as_str).map(str::to_owned);
        match kind {
            "session_summary_generated" => (
                string("session_summary")
                    .map(Signal::Title)
                    .into_iter()
                    .collect(),
                false,
            ),
            "model_changed" | "model_auto_switched" => {
                let model = string("model_id")
                    .or_else(|| string("new_model_id"))
                    .or_else(|| string("to_model"))
                    .or_else(|| string("model"));
                (model.map(Signal::Model).into_iter().collect(), false)
            }
            "pending_interaction" => (vec![Signal::NeedsInput], false),
            "interaction_resolved" => (vec![Signal::InputResolved], false),
            "turn_completed" => {
                self.close_text();
                let stop_reason = string("stop_reason").unwrap_or_else(|| "end_turn".into());
                match stop_reason.as_str() {
                    "end_turn" => {}
                    "cancelled" => self.notice(EventKind::System, "Stopped", Some("cancelled"), at),
                    other => {
                        let failed = string("error_kind").is_some()
                            || matches!(other, "error" | "refusal" | "failed");
                        let text =
                            string("agent_result").unwrap_or_else(|| other.replace('_', " "));
                        let kind = if failed {
                            EventKind::Error
                        } else {
                            EventKind::System
                        };
                        self.notice(kind, &text, Some(other), at);
                    }
                }
                (
                    vec![Signal::TurnCompleted {
                        prompt_id: string("prompt_id"),
                        stop_reason,
                    }],
                    true,
                )
            }
            "retry_state" if string("type").as_deref() == Some("failed") => {
                let message = string("message").unwrap_or_else(|| "The request failed".into());
                self.notice(EventKind::Error, &message, Some("failed"), at);
                (Vec::new(), true)
            }
            _ => (Vec::new(), false),
        }
    }

    /// Returns true when the tool's status changed (started, finished, failed).
    fn apply_tool(&mut self, update: &Value, at: f64) -> bool {
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
            return false;
        };
        let meta_tool = update.get("_meta").and_then(|m| m.get("x.ai/tool"));
        let tool = self.tools.entry(id.to_string()).or_insert_with(|| Tool {
            at,
            ..Tool::default()
        });
        let name = meta_tool
            .and_then(|t| t.get("name"))
            .and_then(Value::as_str);
        if let Some(title) = update.get("title").and_then(Value::as_str)
            && Some(title) != name
        {
            tool.title = Some(title.to_string());
        } else if tool.title.is_none() {
            tool.title = meta_tool
                .and_then(|t| t.get("label"))
                .and_then(Value::as_str)
                .or(name)
                .map(str::to_owned);
        }
        if let Some(kind) = update.get("kind").and_then(Value::as_str).or_else(|| {
            meta_tool
                .and_then(|t| t.get("kind"))
                .and_then(Value::as_str)
        }) {
            tool.tool_kind = Some(kind.to_string());
        }
        let old_status = tool.status.clone();
        if let Some(status) = update.get("status").and_then(Value::as_str) {
            tool.status = Some(status.to_string());
        } else if tool.status.is_none() {
            tool.status = Some("pending".into());
        }
        if let Some(input) = update.get("rawInput") {
            if let Some(command) = input.get("command").and_then(Value::as_str) {
                tool.command = Some(command.to_string());
            }
            for name in [
                "path",
                "file_path",
                "filePath",
                "target_file",
                "pattern",
                "url",
                "query",
            ] {
                if let Some(value) = input.get(name).and_then(Value::as_str)
                    && !tool.paths.iter().any(|p| p == value)
                {
                    tool.paths.push(value.to_string());
                }
            }
        }
        if let Some(locations) = update.get("locations").and_then(Value::as_array) {
            for location in locations {
                if let Some(path) = location.get("path").and_then(Value::as_str)
                    && !tool.paths.iter().any(|p| p == path)
                {
                    tool.paths.push(path.to_string());
                }
            }
        }
        if let Some(content) = update.get("content").and_then(Value::as_array) {
            let text: Vec<&str> = content
                .iter()
                .filter_map(|item| {
                    item.get("content")
                        .and_then(|c| c.get("text"))
                        .and_then(Value::as_str)
                })
                .collect();
            if !text.is_empty() {
                tool.output = Some(text.join("\n"));
            }
        }
        let detail = tool_detail(tool);
        let event = EventInput {
            key: format!("t:{id}"),
            kind: EventKind::Tool,
            text: detail,
            title: tool.title.clone(),
            tool_kind: tool.tool_kind.clone(),
            status: tool.status.clone(),
            origin: None,
            command_id: None,
            from_label: None,
            at: tool.at,
        };
        let changed = old_status != tool.status;
        self.mark(event);
        changed
    }

    /// The changed items since the last call, oldest first.
    pub(crate) fn take_dirty(&mut self) -> Vec<EventInput> {
        let keys = std::mem::take(&mut self.dirty);
        keys.into_iter()
            .filter_map(|key| self.events.get(&key).cloned())
            .collect()
    }

    pub(crate) fn has_dirty(&self) -> bool {
        !self.dirty.is_empty()
    }

    /// The last finished user or assistant message, shortened for the session list.
    pub(crate) fn preview(&self) -> Option<(EventKind, String)> {
        let (kind, text) = self.last_message.as_ref()?;
        Some((*kind, shorten(text, PREVIEW_MAX)))
    }

    /// Drops the item bodies kept for re-sending, once nothing is pending (long sessions keep only open state).
    pub(crate) fn compact(&mut self) {
        if !self.dirty.is_empty() {
            return;
        }
        let open_key = self.open.as_ref().map(|o| o.key.clone());
        let tool_keys: Vec<String> = self
            .tools
            .iter()
            .filter(|(_, t)| matches!(t.status.as_deref(), Some("pending" | "in_progress")))
            .map(|(id, _)| format!("t:{id}"))
            .collect();
        self.events
            .retain(|key, _| Some(key) == open_key.as_ref() || tool_keys.contains(key));
        self.tools
            .retain(|_, t| matches!(t.status.as_deref(), Some("pending" | "in_progress")));
    }
}

fn tool_detail(tool: &Tool) -> String {
    let mut detail = String::new();
    if let Some(command) = &tool.command {
        detail.push_str("$ ");
        detail.push_str(command);
    } else if !tool.paths.is_empty() {
        detail.push_str(&tool.paths.join("\n"));
    }
    if let Some(output) = &tool.output {
        let output = strip_ansi(output);
        let output = output.trim();
        if !output.is_empty() && Some(output) != tool.command.as_deref() {
            if !detail.is_empty() {
                detail.push_str("\n\n");
            }
            detail.push_str(&tail(output, TOOL_OUTPUT_TAIL));
        }
    }
    shorten(&detail, TOOL_DETAIL_MAX)
}

/// Removes terminal escape sequences (colours in command output).
pub(crate) fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                while let Some(next) = chars.next() {
                    if next == '\u{7}' {
                        break;
                    }
                    if next == '\u{1b}' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// At most `max` characters, cut at a character boundary with an ellipsis.
pub(crate) fn shorten(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// The last `max` characters, with an ellipsis in front when cut.
fn tail(text: &str, max: usize) -> String {
    let count = text.chars().count();
    if count <= max {
        return text.to_string();
    }
    let mut out = String::from("…");
    out.extend(text.chars().skip(count - max + 1));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn acp(update: Value) -> Value {
        json!({ "sessionId": "s", "update": update })
    }

    #[test]
    fn streamed_text_grows_one_item_until_the_kind_changes() {
        let mut t = Transcript::new("x", false);
        t.apply("session/update", &acp(json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Hmm"}})), 1.0);
        t.apply("session/update", &acp(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hel"}})), 2.0);
        t.apply("session/update", &acp(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "lo"}})), 3.0);
        let events = t.take_dirty();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, EventKind::Thought);
        assert_eq!(events[1].kind, EventKind::Assistant);
        assert_eq!(events[1].text, "Hello");
        assert_eq!(events[1].at, 2.0);
        t.apply("session/update", &acp(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "!"}})), 4.0);
        let events = t.take_dirty();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].text, "Hello!");
    }

    #[test]
    fn tool_calls_merge_by_id_and_show_command_and_output() {
        let mut t = Transcript::new("x", false);
        let (_, boundary) = t.apply(
            "session/update",
            &acp(json!({"sessionUpdate": "tool_call", "toolCallId": "tc1", "title": "run_terminal_command",
                        "rawInput": {"command": "cargo test"},
                        "_meta": {"x.ai/tool": {"name": "run_terminal_command", "kind": "execute", "label": "Run Command"}}})),
            1.0,
        );
        assert!(boundary);
        t.apply(
            "session/update",
            &acp(json!({"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "completed",
                        "title": "Execute `cargo test`",
                        "content": [{"type": "content", "content": {"type": "text", "text": "\u{1b}[32mok\u{1b}[0m 3 passed"}}]})),
            2.0,
        );
        let events = t.take_dirty();
        assert_eq!(events.len(), 1);
        let tool = &events[0];
        assert_eq!(tool.key, "t:tc1");
        assert_eq!(tool.title.as_deref(), Some("Execute `cargo test`"));
        assert_eq!(tool.tool_kind.as_deref(), Some("execute"));
        assert_eq!(tool.status.as_deref(), Some("completed"));
        assert_eq!(tool.text, "$ cargo test\n\nok 3 passed");
    }

    #[test]
    fn a_tool_without_a_title_uses_its_label() {
        let mut t = Transcript::new("x", false);
        t.apply(
            "session/update",
            &acp(json!({"sessionUpdate": "tool_call", "toolCallId": "tc2", "title": "read_file",
                        "rawInput": {"path": "/a/b.rs"},
                        "_meta": {"x.ai/tool": {"name": "read_file", "kind": "read", "label": "Read File"}}})),
            1.0,
        );
        let tool = &t.take_dirty()[0];
        assert_eq!(tool.title.as_deref(), Some("Read File"));
        assert_eq!(tool.text, "/a/b.rs");
        assert_eq!(tool.status.as_deref(), Some("pending"));
    }

    #[test]
    fn user_chunks_only_when_replaying() {
        let chunk = acp(
            json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "fix it"}}),
        );
        let mut live = Transcript::new("x", false);
        live.apply("session/update", &chunk, 1.0);
        assert!(live.take_dirty().is_empty());
        let mut replay = Transcript::new("x", true);
        replay.apply("session/update", &chunk, 1.0);
        let events = replay.take_dirty();
        assert_eq!(events[0].kind, EventKind::User);
        assert_eq!(events[0].text, "fix it");
    }

    #[test]
    fn turn_end_signals_and_notes_a_stop() {
        let mut t = Transcript::new("x", false);
        let (signals, boundary) = t.apply(
            "_x.ai/session/update",
            &acp(json!({"sessionUpdate": "turn_completed", "prompt_id": "p1", "stop_reason": "cancelled"})),
            5.0,
        );
        assert!(boundary);
        assert_eq!(
            signals,
            vec![Signal::TurnCompleted {
                prompt_id: Some("p1".into()),
                stop_reason: "cancelled".into()
            }]
        );
        let events = t.take_dirty();
        assert_eq!(events[0].kind, EventKind::System);
        assert_eq!(events[0].status.as_deref(), Some("cancelled"));
        let (_, _) = t.apply(
            "_x.ai/session/update",
            &acp(json!({"sessionUpdate": "turn_completed", "prompt_id": "p2", "stop_reason": "end_turn"})),
            6.0,
        );
        assert!(t.take_dirty().is_empty(), "a normal end adds no line");
    }

    #[test]
    fn plan_title_and_input_signals() {
        let mut t = Transcript::new("x", false);
        let (signals, _) = t.apply(
            "session/update",
            &acp(json!({"sessionUpdate": "plan", "entries": [{"content": "Write tests", "priority": "high", "status": "in_progress"}]})),
            1.0,
        );
        assert_eq!(
            signals,
            vec![Signal::Plan(vec![PlanEntry {
                content: "Write tests".into(),
                status: "in_progress".into()
            }])]
        );
        let (signals, _) = t.apply(
            "x.ai/session_notification",
            &acp(json!({"sessionUpdate": "session_summary_generated", "session_summary": "Fix flaky test"})),
            1.0,
        );
        assert_eq!(signals, vec![Signal::Title("Fix flaky test".into())]);
        let (signals, _) = t.apply(
            "x.ai/session_notification",
            &acp(json!({"sessionUpdate": "pending_interaction", "tool_call_id": "t", "kind": "permission"})),
            1.0,
        );
        assert_eq!(signals, vec![Signal::NeedsInput]);
    }

    #[test]
    fn prompts_close_the_open_reply_and_set_the_preview() {
        let mut t = Transcript::new("x", false);
        t.apply("session/update", &acp(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done."}})), 1.0);
        t.user_prompt("Now run it", "remote", Some("cmd1"), Some("iPhone"), 2.0);
        let events = t.take_dirty();
        assert_eq!(events[1].key, "xccmd1");
        assert_eq!(events[1].command_id.as_deref(), Some("cmd1"));
        assert_eq!(events[1].origin.as_deref(), Some("remote"));
        assert_eq!(events[1].from_label.as_deref(), Some("iPhone"));
        assert_eq!(t.preview(), Some((EventKind::User, "Now run it".into())));
    }

    #[test]
    fn helpers() {
        assert_eq!(
            strip_ansi("\u{1b}[1;31mred\u{1b}[0m \u{1b}]8;;http://x\u{7}link"),
            "red link"
        );
        assert_eq!(shorten("abcdef", 4), "abc…");
        assert_eq!(tail("abcdef", 4), "…def");
    }
}
