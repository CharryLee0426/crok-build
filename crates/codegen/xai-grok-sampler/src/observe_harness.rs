//! What crok does around its model calls, for the same sink: each turn as the root span its
//! generations and tool runs hang under, every tool run, the steps between them (permission and
//! hook decisions, compaction), crok's own verdicts as scores, the user's rating, and guard checks.
//!
//! The session crate reports these through the functions here; like the per-call hooks they
//! return at the first check while no sink is installed. Each one becomes a [`HarnessEvent`], a
//! JSON line the bridge (`xai-grok-agento11y/bridge/src/harness.ts`) turns into an OpenTelemetry
//! span, an Agent Observability workflow step, a score, a rating or a hook evaluation.
//!
//! Trace ids are made here, not in the bridge: a turn's id is known before its first model call
//! and its span is written when the turn ends, after its children. The bridge may restart in
//! between (it stops after five idle minutes), and the children still name the right parent.

use std::time::SystemTime;

use serde::Serialize;
use serde_json::{Map, Value, json};

use super::{SINK, agent_name_base, capped, epoch_ms, surface, with_registry};

/// A span in a turn's trace, as W3C ids in lowercase hex.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpanRef {
    pub trace_id: String,
    pub span_id: String,
}

impl SpanRef {
    fn root() -> Self {
        Self {
            trace_id: uuid::Uuid::new_v4().simple().to_string(),
            span_id: new_span_id(),
        }
    }

    fn child_of(parent: &SpanRef) -> Self {
        Self {
            trace_id: parent.trace_id.clone(),
            span_id: new_span_id(),
        }
    }
}

fn new_span_id() -> String {
    let id = uuid::Uuid::new_v4().simple().to_string();
    id.get(..16).unwrap_or(&id).to_owned()
}

/// The turn a session is running, kept in its registry entry.
#[derive(Clone, Debug)]
pub(super) struct ActiveTurn {
    pub(super) span: SpanRef,
    model_calls: u32,
    tool_calls: u32,
    tool_errors: u32,
}

/// One line for the bridge, other than a model call.
pub struct HarnessEvent {
    kind: &'static str,
    line: Value,
}

impl HarnessEvent {
    /// `turn`, `tool`, `step`, `score`, `rating` or `guard`.
    pub fn kind(&self) -> &'static str {
        self.kind
    }

    /// The bridge's stdin line for this event (no trailing newline).
    pub fn to_json_line(&self) -> String {
        serde_json::to_string(&self.line).unwrap_or_default()
    }
}

fn emit(kind: &'static str, mut line: Value) {
    let Some(sink) = SINK.get().filter(|sink| sink.is_active()) else {
        return;
    };
    if let Value::Object(map) = &mut line {
        map.insert("type".to_owned(), kind.into());
    }
    sink.record_event(HarnessEvent { kind, line });
}

/// The session's identity as Agent Observability shows it: agent name, title, and the parent
/// session for a sub-agent.
struct Who {
    agent_name: String,
    conversation_title: Option<String>,
    parent_session_id: Option<String>,
    tags: Map<String, Value>,
}

fn who(session_id: &str) -> Who {
    let base = agent_name_base();
    with_registry(|r| {
        let entry = r.sessions.get(session_id).cloned().unwrap_or_default();
        let agent_name = match (&entry.subagent_type, &entry.parent_session_id) {
            (None, None) => base.to_owned(),
            (kind, _) => format!("{base}/{}", kind.as_deref().unwrap_or("subagent")),
        };
        let mut tags: Map<String, Value> = entry
            .tags
            .iter()
            .map(|(key, value)| ((*key).to_owned(), value.clone().into()))
            .collect();
        if let Some(surface) = &r.surface {
            tags.insert("surface".to_owned(), surface.clone().into());
        }
        Who {
            agent_name,
            conversation_title: entry.title.clone(),
            parent_session_id: entry.parent_session_id.clone(),
            tags,
        }
    })
}

/// The span a session's events hang under right now: its running turn, if any.
pub(super) fn current_turn_span(session_id: &str) -> Option<SpanRef> {
    with_registry(|r| {
        r.sessions
            .get(session_id)
            .and_then(|entry| entry.turn.as_ref().map(|turn| turn.span.clone()))
    })
}

/// Counts a finished model call of the session's own turn.
pub(super) fn count_model_call(session_id: &str) {
    with_registry(|r| {
        if let Some(turn) = r.sessions.get_mut(session_id).and_then(|e| e.turn.as_mut()) {
            turn.model_calls = turn.model_calls.saturating_add(1);
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Session tags
// ---------------------------------------------------------------------------------------------

/// Tags a session's generations, turns and tool runs carry: `repo`, `branch`, `user`, `origin`.
/// Agent Observability's Coding agents view groups by them. A tag set again replaces the old value;
/// an empty value removes it.
pub fn set_session_tag(session_id: &str, key: &'static str, value: &str) {
    if !super::is_enabled() {
        return;
    }
    let value = value.trim();
    with_registry(|r| {
        let entry = r.entry(session_id);
        entry.tags.retain(|(k, _)| *k != key);
        if !value.is_empty() {
            entry.tags.push((key, value.to_owned()));
        }
    });
}

/// Where the session's next prompt came from (`relay` for the web and phones); its turn carries it
/// as the `origin` tag, then the session's default applies again.
pub fn note_prompt_origin(session_id: &str, origin: &'static str) {
    if !super::is_enabled() {
        return;
    }
    with_registry(|r| r.entry(session_id).next_origin = Some(origin));
}

/// The session's tags as the generation record wants them.
pub(super) fn session_tags(session_id: &str) -> Vec<(&'static str, String)> {
    with_registry(|r| {
        r.sessions
            .get(session_id)
            .map(|entry| entry.tags.clone())
            .unwrap_or_default()
    })
}

// ---------------------------------------------------------------------------------------------
// Turns
// ---------------------------------------------------------------------------------------------

pub struct TurnStart<'a> {
    pub session_id: &'a str,
    /// The session's turn number, as crok counts them.
    pub turn_index: Option<u64>,
    pub model: Option<&'a str>,
    /// `default`, `accept-edits`, `plan`, `yolo`, ...
    pub permission_mode: Option<&'a str>,
}

/// How a turn ended, as `crok.turn.outcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnEnd {
    Completed,
    Cancelled,
    MaxTurns,
    Stationarity,
    Error,
}

impl TurnEnd {
    pub fn as_str(self) -> &'static str {
        match self {
            TurnEnd::Completed => "completed",
            TurnEnd::Cancelled => "cancelled",
            TurnEnd::MaxTurns => "max_turns",
            TurnEnd::Stationarity => "stationarity",
            TurnEnd::Error => "error",
        }
    }
}

/// A running turn. Its span is sent when it ends; dropped without [`TurnScope::end`] (the turn's
/// future was dropped: the user interrupted it) it ends as cancelled.
pub struct TurnScope {
    session_id: String,
    span: SpanRef,
    parent: Option<SpanRef>,
    started_at: SystemTime,
    turn_index: Option<u64>,
    model: Option<String>,
    permission_mode: Option<String>,
    origin: Option<&'static str>,
    ended: bool,
}

/// Opens a turn: its model calls, tool runs and steps hang under it until it ends. A sub-agent's
/// turn joins the trace of the parent turn that started it. `None` while no sink is installed.
pub fn begin_turn(start: TurnStart<'_>) -> Option<TurnScope> {
    if !super::is_enabled() {
        return None;
    }
    let (span, parent, origin) = with_registry(|r| {
        let parent_turn = r
            .sessions
            .get(start.session_id)
            .and_then(|entry| entry.parent_session_id.clone())
            .and_then(|parent| r.sessions.get(&parent))
            .and_then(|entry| entry.turn.as_ref().map(|turn| turn.span.clone()));
        let span = parent_turn
            .as_ref()
            .map_or_else(SpanRef::root, SpanRef::child_of);
        let entry = r.entry(start.session_id);
        entry.turn = Some(ActiveTurn {
            span: span.clone(),
            model_calls: 0,
            tool_calls: 0,
            tool_errors: 0,
        });
        let origin = entry.next_origin.take();
        // The turn's own records (its generations too) say where its prompt came from.
        if let Some(origin) = origin {
            entry.tags.retain(|(key, _)| *key != "origin");
            entry.tags.push(("origin", origin.to_owned()));
        }
        (span, parent_turn, origin)
    });
    Some(TurnScope {
        session_id: start.session_id.to_owned(),
        span,
        parent,
        started_at: SystemTime::now(),
        turn_index: start.turn_index,
        model: start.model.map(str::to_owned),
        permission_mode: start.permission_mode.map(str::to_owned),
        origin,
        ended: false,
    })
}

impl TurnScope {
    pub fn span(&self) -> &SpanRef {
        &self.span
    }

    pub fn end(mut self, end: TurnEnd, error: Option<&str>) {
        self.finish(end, error);
    }

    fn finish(&mut self, end: TurnEnd, error: Option<&str>) {
        if self.ended {
            return;
        }
        self.ended = true;
        let counts = with_registry(|r| {
            let entry = r.sessions.get_mut(&self.session_id)?;
            let mine = entry
                .turn
                .as_ref()
                .is_some_and(|turn| turn.span == self.span);
            if mine { entry.turn.take() } else { None }
        });
        let who = who(&self.session_id);
        if let Some(origin) = self.origin {
            with_registry(|r| {
                if let Some(entry) = r.sessions.get_mut(&self.session_id) {
                    entry
                        .tags
                        .retain(|(key, value)| !(*key == "origin" && value == origin));
                }
            });
        }
        let tags = who.tags;
        let mut attributes = Map::new();
        attributes.insert("crok.turn.outcome".to_owned(), end.as_str().into());
        if let Some(index) = self.turn_index {
            attributes.insert("crok.turn_index".to_owned(), index.into());
        }
        if let Some(turn) = &counts {
            attributes.insert("crok.model_calls".to_owned(), turn.model_calls.into());
            attributes.insert("crok.tool_calls".to_owned(), turn.tool_calls.into());
            attributes.insert("crok.tool_errors".to_owned(), turn.tool_errors.into());
        }
        if let Some(mode) = &self.permission_mode {
            attributes.insert("crok.permission_mode".to_owned(), mode.clone().into());
        }
        if let Some(Value::String(origin)) = tags.get("origin") {
            attributes.insert("crok.origin".to_owned(), origin.clone().into());
        }
        if let Some(model) = &self.model {
            attributes.insert("gen_ai.request.model".to_owned(), model.clone().into());
        }
        if let Some(parent) = &who.parent_session_id {
            attributes.insert("crok.parent_session_id".to_owned(), parent.clone().into());
        }
        emit(
            "turn",
            json!({
                "span": self.span,
                "parent": self.parent,
                "conversationId": self.session_id,
                "conversationTitle": who.conversation_title,
                "agentName": who.agent_name,
                "startedAtMs": epoch_ms(self.started_at),
                "completedAtMs": epoch_ms(SystemTime::now()),
                "error": error.map(short_error),
                "attributes": attributes,
                "tags": tags,
            }),
        );
    }
}

impl Drop for TurnScope {
    fn drop(&mut self) {
        self.finish(TurnEnd::Cancelled, None);
    }
}

// ---------------------------------------------------------------------------------------------
// Tool runs
// ---------------------------------------------------------------------------------------------

/// How a tool run ended, as `crok.tool.outcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolRunOutcome {
    Success,
    Error,
    Denied,
    Timeout,
    Cancelled,
}

impl ToolRunOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            ToolRunOutcome::Success => "success",
            ToolRunOutcome::Error => "error",
            ToolRunOutcome::Denied => "denied",
            ToolRunOutcome::Timeout => "timeout",
            ToolRunOutcome::Cancelled => "cancelled",
        }
    }
}

pub struct ToolRun<'a> {
    pub session_id: &'a str,
    pub tool_name: &'a str,
    pub tool_call_id: &'a str,
    pub started_at: SystemTime,
    pub completed_at: SystemTime,
    pub outcome: ToolRunOutcome,
    /// `read_only`, `mutating` or `other`.
    pub kind: &'static str,
    pub exit_code: Option<i32>,
    /// Size of what the model gets back.
    pub result_bytes: Option<u64>,
    /// The tool started a background task and returned at once.
    pub backgrounded: bool,
    /// What went wrong, for a failed run; only its first line is sent.
    pub error: Option<&'a str>,
    /// The model that asked for the call.
    pub model: Option<&'a str>,
}

/// Records one tool run as an `execute_tool` span under the session's turn.
pub fn record_tool(run: ToolRun<'_>) {
    if !super::is_enabled() {
        return;
    }
    let parent = with_registry(|r| {
        let turn = r.sessions.get_mut(run.session_id)?.turn.as_mut()?;
        turn.tool_calls = turn.tool_calls.saturating_add(1);
        if run.outcome != ToolRunOutcome::Success {
            turn.tool_errors = turn.tool_errors.saturating_add(1);
        }
        Some(turn.span.clone())
    });
    let who = who(run.session_id);
    let mut attributes = Map::new();
    attributes.insert("crok.tool.outcome".to_owned(), run.outcome.as_str().into());
    attributes.insert("crok.tool.kind".to_owned(), run.kind.into());
    if let Some(code) = run.exit_code {
        attributes.insert("crok.tool.exit_code".to_owned(), code.into());
    }
    if let Some(bytes) = run.result_bytes {
        attributes.insert("crok.tool.result_bytes".to_owned(), bytes.into());
    }
    if run.backgrounded {
        attributes.insert("crok.tool.backgrounded".to_owned(), true.into());
    }
    emit(
        "tool",
        json!({
            "parent": parent,
            "conversationId": run.session_id,
            "conversationTitle": who.conversation_title,
            "agentName": who.agent_name,
            "toolName": run.tool_name,
            "toolCallId": run.tool_call_id,
            "requestModel": run.model,
            "startedAtMs": epoch_ms(run.started_at),
            "completedAtMs": epoch_ms(run.completed_at),
            "error": run.error.map(short_error),
            "attributes": attributes,
            "tags": who.tags,
        }),
    );
}

// ---------------------------------------------------------------------------------------------
// Workflow steps
// ---------------------------------------------------------------------------------------------

pub struct Step<'a> {
    pub session_id: &'a str,
    /// `permission`, `hook PreToolUse`, `compaction`, ...
    pub name: &'a str,
    pub started_at: SystemTime,
    pub completed_at: SystemTime,
    /// Small, content-free facts: decisions, sources, counts.
    pub input: Map<String, Value>,
    pub output: Map<String, Value>,
    pub error: Option<&'a str>,
}

/// Records a step of the session's workflow beside its generations, linked to the newest one.
pub fn record_step(step: Step<'_>) {
    if !super::is_enabled() {
        return;
    }
    let (parent, last_generation) = with_registry(|r| {
        let entry = r.sessions.get(step.session_id);
        (
            entry.and_then(|e| e.turn.as_ref().map(|turn| turn.span.clone())),
            entry.and_then(|e| e.last_generation_id.clone()),
        )
    });
    let who = who(step.session_id);
    emit(
        "step",
        json!({
            "id": format!("step_{}", uuid::Uuid::new_v4().simple()),
            "parent": parent,
            "conversationId": step.session_id,
            "agentName": who.agent_name,
            "stepName": step.name,
            "startedAtMs": epoch_ms(step.started_at),
            "completedAtMs": epoch_ms(step.completed_at),
            "inputState": step.input,
            "outputState": step.output,
            "error": step.error.map(short_error),
            "linkedGenerationIds": last_generation.into_iter().collect::<Vec<_>>(),
            "tags": who.tags,
        }),
    );
}

// ---------------------------------------------------------------------------------------------
// Verdicts, ratings
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
pub enum VerdictValue<'a> {
    Number(f64),
    Bool(bool),
    Label(&'a str),
}

/// One of crok's own judgements of a turn: the goal evaluator's verdict, the laziness classifier,
/// the identical-call guard, the `--max-turns` limit.
pub struct Verdict<'a> {
    pub session_id: &'a str,
    /// `crok.goal_verdict`, `crok.laziness`, ...
    pub evaluator: &'a str,
    pub key: &'a str,
    pub value: VerdictValue<'a>,
    pub passed: Option<bool>,
    pub explanation: Option<&'a str>,
}

/// Records a verdict as a score on the session's newest turn generation. Dropped when the session
/// has made no model call yet (a score needs a generation).
pub fn record_verdict(verdict: Verdict<'_>) {
    if !super::is_enabled() {
        return;
    }
    let (generation, span) = with_registry(|r| {
        let entry = r.sessions.get(verdict.session_id);
        (
            entry.and_then(|e| e.last_generation_id.clone()),
            entry.and_then(|e| e.turn.as_ref().map(|turn| turn.span.clone())),
        )
    });
    let Some(generation_id) = generation else {
        return;
    };
    let value = match verdict.value {
        VerdictValue::Number(number) => json!({ "number": number }),
        VerdictValue::Bool(flag) => json!({ "bool": flag }),
        VerdictValue::Label(label) => json!({ "string": label }),
    };
    emit(
        "score",
        json!({
            "scoreId": format!("crok_{}", uuid::Uuid::new_v4().simple()),
            "evaluatorId": verdict.evaluator,
            "scoreKey": verdict.key,
            "value": value,
            "passed": verdict.passed,
            "explanation": verdict.explanation.map(|text| capped_to(text, 2_000)),
            "generationId": generation_id,
            "conversationId": verdict.session_id,
            "traceId": span.as_ref().map(|s| s.trace_id.clone()),
            "spanId": span.as_ref().map(|s| s.span_id.clone()),
        }),
    );
}

pub struct Rating<'a> {
    pub session_id: &'a str,
    pub good: bool,
    pub comment: Option<&'a str>,
    /// What the user said the rating is about (`bug`, `quality`, ...).
    pub category: Option<&'a str>,
}

/// Records the user's thumbs up or down (or star rating, folded to good or bad) on the conversation.
pub fn record_rating(rating: Rating<'_>) {
    if !super::is_enabled() {
        return;
    }
    let generation = with_registry(|r| {
        r.sessions
            .get(rating.session_id)
            .and_then(|e| e.last_generation_id.clone())
    });
    emit(
        "rating",
        json!({
            "conversationId": rating.session_id,
            "ratingId": format!("crok_{}", uuid::Uuid::new_v4().simple()),
            "rating": if rating.good {
                "CONVERSATION_RATING_VALUE_GOOD"
            } else {
                "CONVERSATION_RATING_VALUE_BAD"
            },
            "comment": rating.comment.map(|text| capped_to(text, 4_000)),
            "generationId": generation,
            "category": rating.category,
        }),
    );
}

// ---------------------------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------------------------

/// A tool call the model asked for, as a postflight guard sees it.
pub struct GuardToolCall<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub arguments: &'a str,
}

/// A tool result about to go to the model, as a preflight guard sees it.
pub struct GuardToolResult<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub content: &'a str,
}

pub enum GuardCheck<'a> {
    /// The tool calls the model returned, before any of them runs.
    Postflight {
        session_id: &'a str,
        provider: &'a str,
        model: &'a str,
        calls: Vec<GuardToolCall<'a>>,
    },
    /// The tool results about to be sent to the model.
    Preflight {
        session_id: &'a str,
        provider: &'a str,
        model: &'a str,
        results: Vec<GuardToolResult<'a>>,
    },
}

/// Asks the stack's guards about a step of the turn. The bridge evaluates it off crok's path and
/// logs the verdict; the stack records a `warn` or `deny` on the conversation. Nothing here waits
/// for the answer, so a guard never slows or blocks a turn (warn mode).
pub fn check_guard(check: GuardCheck<'_>) {
    if !super::is_enabled() {
        return;
    }
    let (phase, session_id, provider, model, input) = match check {
        GuardCheck::Postflight {
            session_id,
            provider,
            model,
            calls,
        } => {
            if calls.is_empty() {
                return;
            }
            let parts: Vec<Value> = calls
                .iter()
                .map(|call| {
                    json!({
                        "type": "tool_call",
                        "toolCall": {
                            "id": call.id,
                            "name": call.name,
                            "inputJSON": capped(call.arguments),
                        },
                    })
                })
                .collect();
            (
                "postflight",
                session_id,
                provider,
                model,
                json!({ "output": [{ "role": "assistant", "parts": parts }] }),
            )
        }
        GuardCheck::Preflight {
            session_id,
            provider,
            model,
            results,
        } => {
            if results.is_empty() {
                return;
            }
            let messages: Vec<Value> = results
                .iter()
                .map(|result| {
                    json!({
                        "role": "tool",
                        "parts": [{
                            "type": "tool_result",
                            "toolResult": {
                                "toolCallId": result.id,
                                "name": result.name,
                                "content": capped(result.content),
                            },
                        }],
                    })
                })
                .collect();
            (
                "preflight",
                session_id,
                provider,
                model,
                json!({ "messages": messages }),
            )
        }
    };
    let span = current_turn_span(session_id);
    let who = who(session_id);
    emit(
        "guard",
        json!({
            "phase": phase,
            "conversationId": session_id,
            "agentName": who.agent_name,
            "model": { "provider": provider, "name": model },
            "traceId": span.as_ref().map(|s| s.trace_id.clone()),
            "spanId": span.as_ref().map(|s| s.span_id.clone()),
            "input": input,
            "tags": who.tags,
        }),
    );
}

/// The provider a guard check names for a model id as crok spells it (`openrouter/...`,
/// `claude-...`, `deepseek-...`); hook rules can match on it.
pub fn guard_provider(model: &str) -> &'static str {
    let model = model.to_ascii_lowercase();
    if model.starts_with("openrouter/") {
        "openrouter"
    } else if model.starts_with("claude") || model.contains("anthropic") {
        "anthropic"
    } else if model.starts_with("deepseek") {
        "deepseek"
    } else if model.starts_with("glm") {
        "zai"
    } else if model.starts_with("gpt") || model.starts_with("o3") || model.contains("codex") {
        "openai"
    } else if model.starts_with("grok") {
        "xai"
    } else {
        "unknown"
    }
}

/// The surface this process reports as, for callers that tag by it.
pub fn current_surface() -> Option<String> {
    surface()
}

fn short_error(text: &str) -> String {
    let first = text.lines().next().unwrap_or_default().trim();
    capped_to(first, 300)
}

fn capped_to(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", text.get(..end).unwrap_or_default())
}
