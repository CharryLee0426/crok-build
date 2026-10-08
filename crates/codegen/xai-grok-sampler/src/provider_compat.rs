//! Provider-specific wire adaptation. Authentication is resolved by the caller.
use std::collections::{BTreeMap, HashMap};
use std::sync::{LazyLock, Mutex, PoisonError};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use xai_grok_sampling_types::{ApiBackend, Result, SamplingError, rs};

/// Codex's sticky-routing token. The first response of a turn carries it; every later request of
/// that turn echoes it so the turn stays on the backend holding its prompt cache. Another turn
/// must not send it.
pub(crate) const CODEX_TURN_STATE_HEADER: &str = "x-codex-turn-state";

/// Every request builds a new sampling client, so the tokens outlive clients here.
pub(crate) static CODEX_TURN_STATES: LazyLock<CodexTurnStates> =
    LazyLock::new(CodexTurnStates::default);

/// A token is only ever read back for its session's current turn, so a full map is cleared
/// rather than pruned.
const CODEX_TURN_STATE_SESSIONS: usize = 256;

/// The turn-state token each Codex session received, with the turn it belongs to.
#[derive(Default)]
pub(crate) struct CodexTurnStates(Mutex<HashMap<String, (String, String)>>);

impl CodexTurnStates {
    /// The token `session` received during `turn`. One from an earlier turn is forgotten.
    pub(crate) fn get(&self, session: &str, turn: &str) -> Option<String> {
        let mut states = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        match states.get(session) {
            Some((stored_turn, token)) if stored_turn == turn => Some(token.clone()),
            Some(_) => {
                states.remove(session);
                None
            }
            None => None,
        }
    }

    /// The first token a turn receives wins, as in the Codex CLI.
    pub(crate) fn remember(&self, session: &str, turn: &str, token: &str) {
        let mut states = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if states
            .get(session)
            .is_some_and(|(stored_turn, _)| stored_turn == turn)
        {
            return;
        }
        if states.len() >= CODEX_TURN_STATE_SESSIONS && !states.contains_key(session) {
            states.clear();
        }
        states.insert(session.to_owned(), (turn.to_owned(), token.to_owned()));
    }
}

/// Read a routing claim from the bearer sent on this request. This is not JWT
/// validation; authorization remains the subscription server's responsibility.
pub(crate) fn codex_account_id(bearer: &str) -> Option<String> {
    let payload = bearer.split('.').nth(1)?;
    let claims: Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok()?)
            .ok()?;
    claims
        .get("https://api.openai.com/auth")?
        .get("chatgpt_account_id")?
        .as_str()
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

pub(crate) fn codex_base_url(base_url: &str) -> String {
    let Ok(mut url) = reqwest::Url::parse(base_url) else {
        return base_url.to_owned();
    };
    let path = url.path().trim_end_matches('/');
    let path = path.strip_suffix("/responses").unwrap_or(path);
    let path = if path.ends_with("/codex") {
        path.to_owned()
    } else {
        format!("{path}/codex")
    };
    url.set_path(&path);
    url.to_string()
}

pub(crate) fn prepare_codex_request(body: &mut Value) {
    let Some(body) = body.as_object_mut() else {
        return;
    };
    body.insert("store".into(), json!(false));
    body.insert("stream".into(), json!(true));
    // Subscription inference does not accept the general Responses API's
    // output limit, stateful response lookup or xAI streaming extension.
    for key in [
        "max_output_tokens",
        "max_tool_calls",
        "temperature",
        "top_p",
        "stream_tool_calls",
        "previous_response_id",
        "conversation",
        "truncation",
        "prompt_cache_retention",
    ] {
        body.remove(key);
    }
    let mut instructions = body
        .remove("instructions")
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    if let Some(input) = body.get_mut("input").and_then(Value::as_array_mut) {
        // The initial system prompt belongs in `instructions`. Later system
        // reminders retain their position as developer messages.
        while input
            .first()
            .and_then(|item| item.get("role"))
            .and_then(Value::as_str)
            == Some("system")
        {
            let item = input.remove(0);
            let content = item.get("content");
            let text = content
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    content
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(|part| part.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join("\n")
                });
            if !instructions.is_empty() && !text.is_empty() {
                instructions.push_str("\n\n");
            }
            instructions.push_str(&text);
        }
        for item in input.iter_mut() {
            if item.get("role").and_then(Value::as_str) == Some("system") {
                item["role"] = json!("developer");
            }
        }
        // Plaintext reasoning synthesized by a different provider has no
        // server-issued identity/signature and cannot be replayed to Codex.
        input.retain(|item| {
            item.get("type").and_then(Value::as_str) != Some("reasoning")
                || item
                    .get("encrypted_content")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty())
        });
    }
    if instructions.is_empty() {
        instructions = "You are a helpful assistant.".into();
    }
    body.insert("instructions".into(), json!(instructions));
    body.entry("parallel_tool_calls").or_insert(json!(true));
    body.entry("tool_choice").or_insert(json!("auto"));
    if let Some(tools) = body.get_mut("tools").and_then(Value::as_array_mut) {
        for tool in tools {
            if tool.get("type").and_then(Value::as_str) == Some("function") {
                // Coding tool schemas have optional fields; do not opt them
                // into Responses' stricter required-field interpretation.
                tool["strict"] = Value::Null;
            }
        }
    }
}

/// OpenRouter's documented limit for `session_id`.
const OPENROUTER_SESSION_ID_MAX_CHARS: usize = 256;

/// `cache_key` names the conversation whose prompt cache this request should reuse.
pub(crate) fn prepare_openrouter_request(
    body: &mut Value,
    supports_tools: Option<bool>,
    cache_key: Option<&str>,
) {
    let Some(body) = body.as_object_mut() else {
        return;
    };
    if let Some(effort) = body.remove("reasoning_effort") {
        body.insert("reasoning".into(), json!({"effort": effort}));
    }
    body.remove("search_parameters");
    if supports_tools == Some(false) {
        for key in ["tools", "tool_choice", "parallel_tool_calls"] {
            body.remove(key);
        }
    }
    // Without a session OpenRouter pins a provider only after it has seen a cache hit, so the first
    // requests of a conversation can land on providers that each keep their own cache.
    // OpenAI and Meta route on `prompt_cache_key` themselves.
    if let Some(key) = cache_key
        .filter(|key| !key.is_empty() && key.chars().count() <= OPENROUTER_SESSION_ID_MAX_CHARS)
    {
        body.insert("session_id".into(), json!(key));
        body.insert("prompt_cache_key".into(), json!(key));
    }
    let explicit_cache = body
        .get("model")
        .and_then(Value::as_str)
        .is_some_and(caches_only_at_breakpoints);
    if let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) {
        for message in messages.iter_mut() {
            if let Some(message) = message.as_object_mut() {
                message.remove("model_id");
                if let Some(reasoning) = message.remove("reasoning_content")
                    && message
                        .get("reasoning_details")
                        .and_then(Value::as_array)
                        .is_none_or(Vec::is_empty)
                {
                    message.insert("reasoning".into(), reasoning);
                }
            }
        }
        if explicit_cache {
            mark_cache_breakpoints(messages);
        }
    }
}

/// Only Claude needs marked breakpoints to cache at all. Other models on OpenRouter cache prefixes
/// by themselves, and marking them would only add cache writes (GPT-5.6 and later bill those).
fn caches_only_at_breakpoints(model: &str) -> bool {
    model
        .strip_prefix('~')
        .unwrap_or(model)
        .starts_with("anthropic/")
}

/// Marks the system prompt, the newest message, and where the previous request ended: three of the
/// four breakpoints Anthropic allows. The last one keeps a turn that appended more than the 20-block
/// lookback reading the previous request's entry instead of writing the whole prefix again.
fn mark_cache_breakpoints(messages: &mut [Value]) {
    fn role(message: &Value) -> Option<&str> {
        message.get("role").and_then(Value::as_str)
    }
    fn carries_breakpoint(message: &Value) -> bool {
        matches!(role(message), Some("user" | "tool"))
    }
    if let Some(system) = messages
        .iter_mut()
        .find(|message| role(message) == Some("system"))
    {
        mark_cache_breakpoint(system);
    }
    let Some(tip) = messages.iter().rposition(carries_breakpoint) else {
        return;
    };
    let previous = messages.get(..tip).and_then(|before_tip| {
        let assistant = before_tip
            .iter()
            .rposition(|message| role(message) == Some("assistant"))?;
        before_tip
            .get(..assistant)?
            .iter()
            .rposition(carries_breakpoint)
    });
    for index in std::iter::once(tip).chain(previous) {
        if let Some(message) = messages.get_mut(index) {
            mark_cache_breakpoint(message);
        }
    }
}

/// A tool result takes the marker on the message, as OpenRouter's own SDK sends it; other roles
/// take it on their last text part, so plain-string content becomes a one-part array.
fn mark_cache_breakpoint(message: &mut Value) {
    let marker = json!({"type": "ephemeral"});
    let Some(message) = message.as_object_mut() else {
        return;
    };
    if message.get("role").and_then(Value::as_str) == Some("tool") {
        message.insert("cache_control".into(), marker);
        return;
    }
    let Some(content) = message.get_mut("content") else {
        return;
    };
    match content {
        // Anthropic rejects an empty text block, so an empty message stays as it is.
        Value::String(text) if !text.is_empty() => {
            let text = std::mem::take(text);
            *content = json!([{"type": "text", "text": text, "cache_control": marker}]);
        }
        Value::Array(parts) => {
            let last_text = parts
                .iter()
                .rposition(|part| part.get("type").and_then(Value::as_str) == Some("text"));
            if let Some(part) = last_text
                .or_else(|| parts.len().checked_sub(1))
                .and_then(|index| parts.get_mut(index))
                .and_then(Value::as_object_mut)
            {
                part.insert("cache_control".into(), marker);
            }
        }
        _ => {}
    }
}

/// A Chat Completions host whose requests and responses differ from the OpenAI shape.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ChatDialect {
    DeepSeek,
    Glm,
}

impl ChatDialect {
    pub(crate) fn of(backend: &ApiBackend) -> Option<Self> {
        match backend {
            ApiBackend::DeepSeek => Some(Self::DeepSeek),
            ApiBackend::Glm => Some(Self::Glm),
            ApiBackend::ChatCompletions
            | ApiBackend::Responses
            | ApiBackend::OpenRouter
            | ApiBackend::OpenAiCodex
            | ApiBackend::Messages => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::DeepSeek => "DeepSeek",
            Self::Glm => "GLM",
        }
    }

    /// The largest `max_tokens` the host accepts.
    fn max_output_tokens(self) -> u64 {
        match self {
            Self::DeepSeek => 393_216,
            Self::Glm => 131_072,
        }
    }
}

/// The least output a forced tool call is given on GLM, whose reasoning cannot be turned off.
const GLM_FORCED_TOOL_MIN_TOKENS: u64 = 1024;

/// Rewrite a serialized Chat Completions request into what `dialect` accepts.
/// `supports_images` is the model's catalog capability; `Some(false)` replaces every image with a note.
pub(crate) fn prepare_dialect_request(
    dialect: ChatDialect,
    body: &mut Value,
    supports_images: Option<bool>,
) {
    let Some(body) = body.as_object_mut() else {
        return;
    };
    body.remove("search_parameters");
    // Both hosts take `json_object` only; a schema is enforced through the StructuredOutput tool instead.
    let response_format = body.get("response_format").and_then(|f| f.get("type"));
    if response_format.and_then(Value::as_str) == Some("json_schema") {
        body.remove("response_format");
    }
    if let Some(limit) = body.get("max_tokens").and_then(Value::as_u64)
        && limit > dialect.max_output_tokens()
    {
        body.insert("max_tokens".into(), json!(dialect.max_output_tokens()));
    }
    let mut has_tools = body
        .get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| !tools.is_empty());
    let tool_choice = body.get("tool_choice").cloned();
    // `required`, or an object naming one function.
    let forced_tool = has_tools
        && tool_choice
            .as_ref()
            .is_some_and(|choice| choice.is_object() || choice.as_str() == Some("required"));
    let effort = body
        .remove("reasoning_effort")
        .and_then(|effort| effort.as_str().map(str::to_owned));
    // Whether earlier assistant turns must each carry `reasoning_content`, even an empty one.
    let mut reasoning_required = false;
    match dialect {
        ChatDialect::DeepSeek => {
            // Thinking mode answers a forced tool call with HTTP 400, so such a request runs without it.
            if forced_tool || effort.as_deref() == Some("none") {
                body.insert("thinking".into(), json!({"type": "disabled"}));
            } else {
                if let Some(effort) = effort.as_deref() {
                    let effort = match effort {
                        "minimal" | "low" => "low",
                        "max" => "max",
                        _ => "high",
                    };
                    body.insert("reasoning_effort".into(), json!(effort));
                }
                // With tools, DeepSeek rejects a history in which any assistant turn lacks the field.
                reasoning_required = has_tools;
            }
        }
        ChatDialect::Glm => {
            // The plan's models always reason. Keep earlier turns' reasoning in context, since it is sent back.
            body.insert(
                "thinking".into(),
                json!({"type": "enabled", "clear_thinking": false}),
            );
            let effort = if forced_tool {
                // A forced call is a mechanical step; `auto` is the only choice the host accepts.
                Some("low")
            } else {
                effort.as_deref().map(|effort| match effort {
                    "none" | "minimal" | "low" => "low",
                    "xhigh" | "max" => "max",
                    _ => "high",
                })
            };
            if let Some(effort) = effort {
                body.insert("reasoning_effort".into(), json!(effort));
            }
            // A forced call is asked for with a budget sized for its arguments alone (a session title gets 100 tokens).
            // Here the reasoning comes out of the same budget, so leave room for it.
            if forced_tool
                && body
                    .get("max_tokens")
                    .and_then(Value::as_u64)
                    .is_some_and(|limit| limit < GLM_FORCED_TOOL_MIN_TOKENS)
            {
                body.insert("max_tokens".into(), json!(GLM_FORCED_TOOL_MIN_TOKENS));
            }
            match tool_choice.as_ref().and_then(Value::as_str) {
                Some("auto") => {}
                Some("none") => {
                    // The only way to rule tool calls out.
                    body.remove("tools");
                    body.remove("tool_choice");
                    has_tools = false;
                }
                _ if tool_choice.is_some() => {
                    body.insert("tool_choice".into(), json!("auto"));
                }
                _ => {}
            }
            // Without this a tool call arrives whole at the end, after a silence long enough to look stalled.
            if has_tools && body.get("stream").and_then(Value::as_bool) == Some(true) {
                body.insert("tool_stream".into(), json!(true));
            }
            if let Some(temperature) = body.get("temperature").and_then(Value::as_f64)
                && !(0.0..=1.0).contains(&temperature)
            {
                body.insert("temperature".into(), json!(temperature.clamp(0.0, 1.0)));
            }
        }
    }
    let model = body
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("This model")
        .to_owned();
    if let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) {
        let mut prepared = Vec::with_capacity(messages.len());
        // Images a tool returned, waiting for the end of its run of results.
        let mut tool_images: Vec<Value> = Vec::new();
        for mut message in std::mem::take(messages) {
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if role != "tool" {
                flush_tool_images(&mut prepared, &mut tool_images);
            }
            if let Some(message) = message.as_object_mut() {
                message.remove("model_id");
                if reasoning_required && role == "assistant" {
                    message
                        .entry("reasoning_content")
                        .or_insert_with(|| json!(""));
                }
                if let Some(content) = message.get_mut("content") {
                    let images =
                        take_images(content, role != "user" || supports_images == Some(false));
                    if supports_images == Some(false) {
                        if !images.is_empty() {
                            append_text(
                                content,
                                &format!(
                                    "[{} image(s) left out: {model} reads text only.]",
                                    images.len()
                                ),
                            );
                        }
                    } else {
                        // Only a user message may carry images.
                        tool_images.extend(images);
                    }
                }
            }
            prepared.push(message);
        }
        flush_tool_images(&mut prepared, &mut tool_images);
        *messages = prepared;
    }
}

/// Follow a run of tool results with the images they returned, as a user message.
fn flush_tool_images(messages: &mut Vec<Value>, images: &mut Vec<Value>) {
    if images.is_empty() {
        return;
    }
    let mut content =
        vec![json!({"type": "text", "text": "Images returned by the tool call(s) above:"})];
    content.append(images);
    messages.push(json!({"role": "user", "content": content}));
}

/// Remove the image parts from a message's content when `remove` is set and return them.
/// Content left with text only becomes a plain string, the one form every role accepts.
fn take_images(content: &mut Value, remove: bool) -> Vec<Value> {
    let Some(parts) = content.as_array_mut() else {
        return Vec::new();
    };
    if !remove {
        return Vec::new();
    }
    let (images, text): (Vec<Value>, Vec<Value>) = std::mem::take(parts)
        .into_iter()
        .partition(|part| part.get("type").and_then(Value::as_str) == Some("image_url"));
    let text = text
        .iter()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    *content = Value::String(text);
    images
}

fn append_text(content: &mut Value, note: &str) {
    match content {
        Value::String(text) if text.is_empty() => *text = note.to_owned(),
        Value::String(text) => {
            text.push('\n');
            text.push_str(note);
        }
        other => *other = Value::String(note.to_owned()),
    }
}

/// Bring one stream chunk, or a whole non-streaming reply, into the shape the shared parser reads.
/// A reply the host cut short is returned as the error it is.
pub(crate) fn normalize_dialect_response(dialect: ChatDialect, data: &str) -> Result<String> {
    let Ok(Value::Object(mut reply)) = serde_json::from_str::<Value>(data) else {
        // Let the shared parser report what is wrong with it.
        return Ok(data.to_owned());
    };
    let streaming = reply
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .is_none_or(|choice| choice.get("message").is_none());
    // GLM replies carry no `object`, and the parser requires these four.
    reply.entry("id").or_insert_with(|| json!(""));
    reply.entry("object").or_insert_with(|| {
        json!(if streaming {
            "chat.completion.chunk"
        } else {
            "chat.completion"
        })
    });
    reply.entry("created").or_insert_with(|| json!(0));
    reply.entry("model").or_insert_with(|| json!(""));
    if !reply.get("choices").is_some_and(Value::is_array) {
        reply.insert("choices".into(), json!([]));
    }
    let choices = reply.get_mut("choices").and_then(Value::as_array_mut);
    for (position, choice) in choices.into_iter().flatten().enumerate() {
        let Some(choice) = choice.as_object_mut() else {
            continue;
        };
        choice.entry("index").or_insert_with(|| json!(position));
        if streaming {
            choice.entry("delta").or_insert_with(|| json!({}));
        }
        let reason = choice
            .get("finish_reason")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let finish = match reason.as_deref() {
            None => continue,
            Some("") => Value::Null,
            Some("stop" | "length" | "tool_calls" | "content_filter" | "function_call") => continue,
            Some("sensitive") => json!("content_filter"),
            Some("model_context_window_exceeded") => {
                return Err(SamplingError::StreamError {
                    error_type: "model_context_window_exceeded".into(),
                    message: format!(
                        "{} stopped: the conversation is over the model's maximum context length",
                        dialect.name()
                    ),
                    code: Some(xai_grok_sampling_types::ApiErrorCode::parse(
                        "context_length_exceeded",
                    )),
                });
            }
            Some(reason @ ("insufficient_system_resource" | "aborted" | "network_error")) => {
                return Err(SamplingError::StreamError {
                    error_type: reason.to_owned(),
                    message: format!(
                        "{} cut the response short ({reason}). Try again.",
                        dialect.name()
                    ),
                    code: None,
                });
            }
            Some(other) => {
                tracing::warn!(
                    finish_reason = other,
                    provider = dialect.name(),
                    "unknown finish reason; treating it as stop"
                );
                json!("stop")
            }
        };
        choice.insert("finish_reason".into(), finish);
    }
    if let Some(usage) = reply.get_mut("usage").and_then(Value::as_object_mut) {
        let count = |usage: &serde_json::Map<String, Value>, key: &str| {
            usage.get(key).and_then(Value::as_u64).unwrap_or(0)
        };
        let (prompt, completion) = (
            count(usage, "prompt_tokens"),
            count(usage, "completion_tokens"),
        );
        usage
            .entry("prompt_tokens")
            .or_insert_with(|| json!(prompt));
        usage
            .entry("completion_tokens")
            .or_insert_with(|| json!(completion));
        usage
            .entry("total_tokens")
            .or_insert_with(|| json!(prompt + completion));
        // DeepSeek also reports its cache hits under its own name.
        if usage
            .get("prompt_tokens_details")
            .and_then(|details| details.get("cached_tokens"))
            .is_none()
            && let Some(hits) = usage.get("prompt_cache_hit_tokens").and_then(Value::as_u64)
        {
            usage.insert(
                "prompt_tokens_details".into(),
                json!({"cached_tokens": hits}),
            );
        }
    }
    Ok(Value::Object(reply).to_string())
}

/// Codex sometimes ends with `response.done` and omits output on the final
/// response. Reassemble completed items without losing tool calls or reasoning.
#[derive(Default)]
pub(crate) struct CodexEventDecoder {
    output: BTreeMap<u64, Value>,
}

impl CodexEventDecoder {
    pub(crate) fn decode(&mut self, data: &str) -> Result<Option<rs::ResponseStreamEvent>> {
        let mut value: Value = serde_json::from_str(data).map_err(SamplingError::Serialization)?;
        let Some(kind) = value.get("type").and_then(Value::as_str).map(str::to_owned) else {
            return Ok(None);
        };
        if kind == "response.output_item.done" {
            if let (Some(index), Some(item)) = (
                value.get("output_index").and_then(Value::as_u64),
                value.get("item"),
            ) {
                self.output.insert(index, item.clone());
            }
        }
        let terminal = matches!(
            kind.as_str(),
            "response.done" | "response.completed" | "response.incomplete" | "response.failed"
        );
        if kind == "response.done" {
            value["type"] = json!(
                match value.pointer("/response/status").and_then(Value::as_str) {
                    Some("incomplete") => "response.incomplete",
                    Some("failed" | "cancelled") => "response.failed",
                    _ => "response.completed",
                }
            );
        }
        if let Some(object) = value.as_object_mut() {
            object.entry("sequence_number").or_insert(json!(0));
        }
        if let Some(response) = value.get_mut("response").and_then(Value::as_object_mut) {
            response.entry("object").or_insert(json!("response"));
            response.entry("created_at").or_insert(json!(0));
            response.entry("model").or_insert(json!(""));
            response.entry("id").or_insert(json!(""));
            if terminal
                && response
                    .get("output")
                    .and_then(Value::as_array)
                    .is_none_or(Vec::is_empty)
            {
                response.insert(
                    "output".into(),
                    Value::Array(self.output.values().cloned().collect()),
                );
            } else {
                response.entry("output").or_insert(json!([]));
            }
            if let Some(usage) = response.get_mut("usage").and_then(Value::as_object_mut) {
                usage
                    .entry("input_tokens_details")
                    .or_insert(json!({"cached_tokens": 0}));
                usage
                    .entry("output_tokens_details")
                    .or_insert(json!({"reasoning_tokens": 0}));
                let total = usage
                    .get("input_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
                    + usage
                        .get("output_tokens")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                usage.entry("total_tokens").or_insert(json!(total));
            }
        }
        // New auxiliary events should not break otherwise valid generations.
        if !kind.starts_with("response.") && kind != "error" {
            return Ok(None);
        }
        match super::client::deserialize_response_event(&value.to_string()) {
            Ok(event) => Ok(Some(event)),
            Err(SamplingError::Serialization(error))
                if error
                    .to_string()
                    .contains(&format!("unknown variant `{kind}`"))
                    && !terminal =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_endpoint_accepts_base_codex_and_full_endpoint_with_query() {
        for input in [
            "https://chatgpt.com/backend-api",
            "https://chatgpt.com/backend-api/codex/",
            "https://chatgpt.com/backend-api/codex/responses",
        ] {
            assert_eq!(
                codex_base_url(input),
                "https://chatgpt.com/backend-api/codex"
            );
        }
        assert_eq!(
            codex_base_url("https://example.test/backend-api?tenant=one"),
            "https://example.test/backend-api/codex?tenant=one"
        );
    }

    #[test]
    fn codex_preserves_reminder_position_and_native_encrypted_reasoning() {
        let mut body = json!({"input":[
            {"role":"system","content":"Initial rules"},
            {"role":"user","content":"Task"},
            {"role":"system","content":"Later reminder"},
            {"type":"reasoning","id":"","summary":[]},
            {"type":"reasoning","id":"rs_123","encrypted_content":"opaque","summary":[]}
        ],"store":true,"max_output_tokens":100,"top_p":0.5});
        prepare_codex_request(&mut body);
        assert_eq!(body.get("instructions"), Some(&json!("Initial rules")));
        assert_eq!(body.pointer("/input/1/role"), Some(&json!("developer")));
        assert_eq!(
            body.pointer("/input/2/encrypted_content"),
            Some(&json!("opaque"))
        );
        assert_eq!(body.get("input").unwrap().as_array().unwrap().len(), 3);
        assert!(body.get("max_output_tokens").is_none());
    }

    #[test]
    fn a_codex_turn_keeps_its_first_token_and_never_lends_it_to_another_turn() {
        let states = CodexTurnStates::default();
        assert_eq!(states.get("session", "1"), None);
        states.remember("session", "1", "first");
        states.remember("session", "1", "second");
        assert_eq!(states.get("session", "1").as_deref(), Some("first"));
        assert_eq!(states.get("other-session", "1"), None);
        assert_eq!(states.get("session", "2"), None);
        assert_eq!(
            states.get("session", "1"),
            None,
            "asking for a later turn forgets the earlier token"
        );
        states.remember("session", "2", "next");
        assert_eq!(states.get("session", "2").as_deref(), Some("next"));
    }

    #[test]
    fn openrouter_omits_tools_for_models_without_tool_support() {
        let mut body = json!({"messages":[],"tools":[{"type":"function"}],"tool_choice":"auto","parallel_tool_calls":true});
        prepare_openrouter_request(&mut body, Some(false), None);
        assert!(body.get("tools").is_none());
        assert!(body.get("tool_choice").is_none());
        assert!(body.get("parallel_tool_calls").is_none());
    }

    fn cache_markers(body: &Value) -> Vec<String> {
        fn walk(value: &Value, path: String, found: &mut Vec<String>) {
            match value {
                Value::Object(map) => {
                    for (key, child) in map {
                        if key == "cache_control" {
                            found.push(path.clone());
                        } else {
                            walk(child, format!("{path}/{key}"), found);
                        }
                    }
                }
                Value::Array(items) => {
                    for (index, child) in items.iter().enumerate() {
                        walk(child, format!("{path}/{index}"), found);
                    }
                }
                _ => {}
            }
        }
        let mut found = Vec::new();
        walk(body, String::new(), &mut found);
        found
    }

    /// The second request of a tool loop, plus a reminder the turn appended after the result.
    fn claude_tool_loop(model: &str) -> Value {
        json!({
            "model": model,
            "messages": [
                {"role": "system", "content": "Be precise."},
                {"role": "user", "content": "Read hello.txt"},
                {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "call-1", "type": "function", "function": {"name": "read", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call-1", "content": "hello"},
                {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "call-2", "type": "function", "function": {"name": "read", "arguments": "{}"}},
                    {"id": "call-3", "type": "function", "function": {"name": "read", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call-2", "content": "a"},
                {"role": "tool", "tool_call_id": "call-3", "content": "b"},
                {"role": "user", "content": [
                    {"type": "text", "text": "<system-reminder>Keep going.</system-reminder>"},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}]}
            ]
        })
    }

    #[test]
    fn claude_on_openrouter_caches_at_the_system_prompt_the_tip_and_the_previous_tip() {
        for model in [
            "anthropic/claude-opus-5.5",
            "~anthropic/claude-haiku-latest",
        ] {
            let mut body = claude_tool_loop(model);
            prepare_openrouter_request(&mut body, None, Some("session-1"));
            assert_eq!(
                cache_markers(&body),
                [
                    "/messages/0/content/0",
                    // The previous request ended on the last result of the first tool call.
                    "/messages/3",
                    // The newest message carries its marker on its last text part, not on the image.
                    "/messages/7/content/0",
                ],
                "{model}"
            );
            assert_eq!(
                body.pointer("/messages/0/content/0/text"),
                Some(&json!("Be precise."))
            );
            assert_eq!(
                body.pointer("/messages/3/cache_control"),
                Some(&json!({"type": "ephemeral"}))
            );
            assert_eq!(body.pointer("/messages/3/content"), Some(&json!("hello")));
        }

        // The first request: no assistant turn yet, so only the system prompt and the prompt itself.
        let mut first = json!({"model": "anthropic/claude-sonnet-5.5", "messages": [
            {"role": "system", "content": "Be precise."},
            {"role": "user", "content": "Read hello.txt"}]});
        prepare_openrouter_request(&mut first, None, None);
        assert_eq!(
            cache_markers(&first),
            ["/messages/0/content/0", "/messages/1/content/0"]
        );

        // A tool result as the newest message; an empty message gets no empty text block.
        let mut tool_tip = json!({"model": "anthropic/claude-sonnet-5.5", "messages": [
            {"role": "system", "content": ""},
            {"role": "user", "content": "Read it"},
            {"role": "assistant", "content": "", "tool_calls": [
                {"id": "call-1", "type": "function", "function": {"name": "read", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "call-1", "content": "hello"}]});
        prepare_openrouter_request(&mut tool_tip, None, None);
        assert_eq!(
            cache_markers(&tool_tip),
            ["/messages/1/content/0", "/messages/3"]
        );
        assert_eq!(tool_tip.pointer("/messages/0/content"), Some(&json!("")));
    }

    #[test]
    fn models_that_cache_on_their_own_get_no_markers_but_every_model_gets_a_session() {
        for model in [
            "openai/gpt-5.6-sol",
            "meta/muse-spark-1.3",
            "x-ai/grok-4.6",
            "openrouter/auto",
        ] {
            let mut body = claude_tool_loop(model);
            prepare_openrouter_request(&mut body, None, Some("session-1"));
            assert!(cache_markers(&body).is_empty(), "{model}");
            assert_eq!(
                body.pointer("/messages/0/content"),
                Some(&json!("Be precise."))
            );
            assert_eq!(body.get("session_id"), Some(&json!("session-1")), "{model}");
            assert_eq!(body.get("prompt_cache_key"), Some(&json!("session-1")));
        }

        // OpenRouter rejects a session id over 256 characters, and an empty one routes nowhere.
        for key in ["", &"k".repeat(257)] {
            let mut body = claude_tool_loop("openai/gpt-5.6-sol");
            prepare_openrouter_request(&mut body, None, Some(key));
            assert!(body.get("session_id").is_none());
            assert!(body.get("prompt_cache_key").is_none());
        }
    }

    fn set(body: &mut Value, key: &str, value: Value) {
        body.as_object_mut().unwrap().insert(key.into(), value);
    }

    fn messages(body: &Value) -> &Vec<Value> {
        body.get("messages").and_then(Value::as_array).unwrap()
    }

    /// A tool loop as the shared mapping serializes it: xAI's `model_id` on assistant turns,
    /// reasoning on the turn that had some, and a later assistant turn that had none.
    fn tool_loop() -> Value {
        json!({
            "model": "fixture-model",
            "messages": [
                {"role": "system", "content": "Be precise."},
                {"role": "user", "content": "Read hello.txt"},
                {"role": "assistant", "content": "", "model_id": "fixture-model", "reasoning_content": "Need the file.",
                 "tool_calls": [{"id": "call-1", "type": "function", "function": {"name": "read", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call-1", "content": "hello"},
                {"role": "assistant", "content": "It says hello.", "model_id": "another-model"},
                {"role": "user", "content": "And again?"}
            ],
            "tools": [{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}],
            "tool_choice": "auto",
            "search_parameters": {"mode": "off"},
            "stream": true,
            "stream_options": {"include_usage": true}
        })
    }

    fn prepared(dialect: ChatDialect, mut body: Value) -> Value {
        prepare_dialect_request(dialect, &mut body, None);
        body
    }

    #[test]
    fn deepseek_tool_loop_carries_reasoning_on_every_assistant_turn() {
        let mut body = tool_loop();
        set(&mut body, "reasoning_effort", json!("medium"));
        let body = prepared(ChatDialect::DeepSeek, body);
        assert_eq!(body.get("reasoning_effort"), Some(&json!("high")));
        assert!(body.get("thinking").is_none(), "thinking is on by default");
        assert!(body.get("search_parameters").is_none());
        assert_eq!(
            body.pointer("/stream_options/include_usage"),
            Some(&json!(true))
        );
        // Sent back as given where there was reasoning, and present but empty where there was none.
        assert_eq!(
            body.pointer("/messages/2/reasoning_content"),
            Some(&json!("Need the file."))
        );
        assert_eq!(
            body.pointer("/messages/4/reasoning_content"),
            Some(&json!(""))
        );
        for message in messages(&body) {
            assert!(message.get("model_id").is_none());
            if message.get("role") != Some(&json!("assistant")) {
                assert!(message.get("reasoning_content").is_none());
            }
        }

        // Without tools nothing has to be sent back, so nothing is invented.
        let mut chat = tool_loop();
        chat.as_object_mut().unwrap().remove("tools");
        let chat = prepared(ChatDialect::DeepSeek, chat);
        assert!(chat.pointer("/messages/4/reasoning_content").is_none());
    }

    #[test]
    fn deepseek_turns_thinking_off_for_effort_none_and_for_a_forced_tool() {
        let mut off = tool_loop();
        set(&mut off, "reasoning_effort", json!("none"));
        let off = prepared(ChatDialect::DeepSeek, off);
        assert_eq!(off.pointer("/thinking/type"), Some(&json!("disabled")));
        assert!(off.get("reasoning_effort").is_none());
        assert!(off.pointer("/messages/4/reasoning_content").is_none());

        // Thinking mode answers a named or required tool with HTTP 400.
        for choice in [
            json!("required"),
            json!({"type": "function", "function": {"name": "read"}}),
        ] {
            let mut forced = tool_loop();
            set(&mut forced, "reasoning_effort", json!("max"));
            set(&mut forced, "tool_choice", choice.clone());
            let forced = prepared(ChatDialect::DeepSeek, forced);
            assert_eq!(forced.pointer("/thinking/type"), Some(&json!("disabled")));
            assert_eq!(forced.get("tool_choice"), Some(&choice));
            assert!(forced.get("reasoning_effort").is_none());
        }
        for (asked, sent) in [
            ("minimal", "low"),
            ("low", "low"),
            ("xhigh", "high"),
            ("max", "max"),
        ] {
            let mut body = tool_loop();
            set(&mut body, "reasoning_effort", json!(asked));
            let body = prepared(ChatDialect::DeepSeek, body);
            assert_eq!(body.get("reasoning_effort"), Some(&json!(sent)), "{asked}");
        }
    }

    #[test]
    fn glm_always_reasons_and_only_ever_asks_for_auto_tools() {
        let mut body = tool_loop();
        set(&mut body, "reasoning_effort", json!("none"));
        set(&mut body, "temperature", json!(1.5));
        set(&mut body, "max_tokens", json!(500_000));
        set(
            &mut body,
            "response_format",
            json!({"type": "json_schema", "json_schema": {"name": "out"}}),
        );
        let body = prepared(ChatDialect::Glm, body);
        // Reasoning cannot be turned off; the lowest effort stands in, and earlier reasoning stays in context.
        assert_eq!(body.pointer("/thinking/type"), Some(&json!("enabled")));
        assert_eq!(
            body.pointer("/thinking/clear_thinking"),
            Some(&json!(false))
        );
        assert_eq!(body.get("reasoning_effort"), Some(&json!("low")));
        assert_eq!(body.get("tool_stream"), Some(&json!(true)));
        assert_eq!(body.get("tool_choice"), Some(&json!("auto")));
        assert_eq!(body.get("temperature"), Some(&json!(1.0)));
        assert_eq!(body.get("max_tokens"), Some(&json!(131_072)));
        for dropped in ["search_parameters", "response_format"] {
            assert!(body.get(dropped).is_none(), "{dropped}");
        }
        // Usage is asked for, as every OpenAI client of this endpoint does.
        assert_eq!(
            body.pointer("/stream_options/include_usage"),
            Some(&json!(true))
        );
        // Reasoning goes back exactly as it came, and none is made up.
        assert_eq!(
            body.pointer("/messages/2/reasoning_content"),
            Some(&json!("Need the file."))
        );
        assert!(body.pointer("/messages/4/reasoning_content").is_none());
        assert!(body.pointer("/messages/2/model_id").is_none());

        // A forced call becomes `auto`, the only choice there is. Its budget, sized for the
        // arguments alone, is raised so that reasoning does not use all of it.
        let mut forced = tool_loop();
        set(&mut forced, "reasoning_effort", json!("max"));
        set(&mut forced, "max_tokens", json!(100));
        set(
            &mut forced,
            "tool_choice",
            json!({"type": "function", "function": {"name": "read"}}),
        );
        let forced = prepared(ChatDialect::Glm, forced);
        assert_eq!(forced.get("tool_choice"), Some(&json!("auto")));
        assert_eq!(forced.get("reasoning_effort"), Some(&json!("low")));
        assert_eq!(forced.get("max_tokens"), Some(&json!(1024)));
        // An ordinary turn keeps the budget it asked for, however small.
        let mut small = tool_loop();
        set(&mut small, "max_tokens", json!(100));
        let small = prepared(ChatDialect::Glm, small);
        assert_eq!(small.get("max_tokens"), Some(&json!(100)));

        // "No tools" can only be said by sending none.
        let mut none = tool_loop();
        set(&mut none, "tool_choice", json!("none"));
        let none = prepared(ChatDialect::Glm, none);
        for dropped in ["tools", "tool_choice", "tool_stream"] {
            assert!(none.get(dropped).is_none(), "{dropped}");
        }
        for (asked, sent) in [("medium", "high"), ("high", "high"), ("xhigh", "max")] {
            let mut body = tool_loop();
            set(&mut body, "reasoning_effort", json!(asked));
            let body = prepared(ChatDialect::Glm, body);
            assert_eq!(body.get("reasoning_effort"), Some(&json!(sent)), "{asked}");
        }
        // A non-streaming request has no tool stream to ask for, and no effort is sent unasked.
        let mut unary = tool_loop();
        unary.as_object_mut().unwrap().remove("stream");
        let unary = prepared(ChatDialect::Glm, unary);
        assert!(unary.get("tool_stream").is_none());
        assert!(unary.get("reasoning_effort").is_none());
    }

    fn with_images() -> Value {
        let image = |name: &str| json!({"type": "image_url", "image_url": {"url": format!("data:image/png;base64,{name}")}});
        json!({
            "model": "fixture-model",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "What is this?"}, image("pasted")]},
                {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "call-1", "type": "function", "function": {"name": "view", "arguments": "{}"}},
                    {"id": "call-2", "type": "function", "function": {"name": "view", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call-1", "content": [{"type": "text", "text": "a.png"}, image("first")]},
                {"role": "tool", "tool_call_id": "call-2", "content": [{"type": "text", "text": "b.png"}, image("second")]},
                {"role": "assistant", "content": "Two screenshots."}
            ]
        })
    }

    #[test]
    fn images_from_tools_follow_their_results_in_a_user_message() {
        let mut body = with_images();
        prepare_dialect_request(ChatDialect::DeepSeek, &mut body, Some(true));
        let messages = messages(&body);
        let roles: Vec<_> = messages
            .iter()
            .map(|m| m.get("role").and_then(Value::as_str).unwrap())
            .collect();
        // Both results stay next to the call that asked for them; their images come right after.
        assert_eq!(
            roles,
            ["user", "assistant", "tool", "tool", "user", "assistant"]
        );
        assert_eq!(
            body.pointer("/messages/0/content/1/type"),
            Some(&json!("image_url")),
            "a user's own image is sent as it is"
        );
        assert_eq!(body.pointer("/messages/2/content"), Some(&json!("a.png")));
        assert_eq!(body.pointer("/messages/3/content"), Some(&json!("b.png")));
        let urls: Vec<_> = (1..=2)
            .map(|part| {
                body.pointer(&format!("/messages/4/content/{part}/image_url/url"))
                    .and_then(Value::as_str)
                    .unwrap()
            })
            .collect();
        assert_eq!(
            urls,
            [
                "data:image/png;base64,first",
                "data:image/png;base64,second"
            ]
        );
    }

    #[test]
    fn a_text_only_model_gets_a_note_in_place_of_each_image() {
        let mut body = with_images();
        prepare_dialect_request(ChatDialect::Glm, &mut body, Some(false));
        let sent = body.to_string();
        assert!(!sent.contains("image_url"), "{sent}");
        assert_eq!(messages(&body).len(), 5);
        let user = body
            .pointer("/messages/0/content")
            .and_then(Value::as_str)
            .unwrap();
        assert!(
            user.starts_with("What is this?\n[1 image(s) left out"),
            "{user}"
        );
        assert!(user.contains("fixture-model reads text only"), "{user}");
        let tool = body
            .pointer("/messages/2/content")
            .and_then(Value::as_str)
            .unwrap();
        assert!(tool.starts_with("a.png\n[1 image(s) left out"), "{tool}");
    }

    fn chunk(
        reply: &str,
        dialect: ChatDialect,
    ) -> Result<xai_grok_sampling_types::ChatCompletionChunk> {
        let reply = normalize_dialect_response(dialect, reply)?;
        serde_json::from_str(&reply).map_err(SamplingError::Serialization)
    }

    #[test]
    fn glm_chunks_parse_without_the_fields_the_service_leaves_out() {
        // As the service sends them: no `object`, and a reason of its own.
        let delta = r#"{"id":"2026","created":1,"model":"glm-5.3","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"Hm."}}]}"#;
        let parsed = chunk(delta, ChatDialect::Glm).unwrap();
        assert_eq!(parsed.object, "chat.completion.chunk");
        let choice = parsed.choices.first().unwrap();
        assert_eq!(choice.delta.reasoning_content.as_deref(), Some("Hm."));
        assert!(choice.finish_reason.is_none());

        let last = r#"{"id":"2026","created":1,"model":"glm-5.3","choices":[{"index":0,"delta":{},"finish_reason":"sensitive"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}"#;
        let parsed = chunk(last, ChatDialect::Glm).unwrap();
        assert_eq!(
            parsed.choices.first().unwrap().finish_reason,
            Some(xai_grok_sampling_types::FinishReason::ContentFilter)
        );
        let usage = parsed.usage.unwrap();
        assert_eq!(usage.total_tokens, 15);
        assert_eq!(usage.prompt_tokens_details.unwrap().cached_tokens, 4);

        // A reason this build has never seen ends the turn rather than failing it.
        let odd = r#"{"choices":[{"delta":{"content":"Done."},"finish_reason":"something_new"}]}"#;
        let parsed = chunk(odd, ChatDialect::Glm).unwrap();
        assert_eq!(
            parsed.choices.first().unwrap().finish_reason,
            Some(xai_grok_sampling_types::FinishReason::Stop)
        );
    }

    #[test]
    fn a_reply_the_provider_cut_short_is_an_error_not_an_answer() {
        let ended = |reason: &str| {
            format!(
                r#"{{"id":"1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{{"index":0,"delta":{{}},"finish_reason":"{reason}"}}]}}"#
            )
        };
        for (dialect, reason) in [
            (ChatDialect::DeepSeek, "insufficient_system_resource"),
            (ChatDialect::DeepSeek, "aborted"),
            (ChatDialect::Glm, "network_error"),
        ] {
            let Err(SamplingError::StreamError {
                error_type, code, ..
            }) = chunk(&ended(reason), dialect)
            else {
                panic!("{reason} must not read as a finished answer");
            };
            assert_eq!(error_type, reason);
            assert_eq!(code, None);
        }
        // Over the context window: reported the way the session already knows how to handle.
        let Err(SamplingError::StreamError { message, code, .. }) =
            chunk(&ended("model_context_window_exceeded"), ChatDialect::Glm)
        else {
            panic!("an overflow must not read as a finished answer");
        };
        assert!(matches!(
            code,
            Some(xai_grok_sampling_types::ApiErrorCode::ContextOverflow(_))
        ));
        assert!(
            xai_grok_sampling_types::is_context_length_error(&message),
            "{message}"
        );
    }

    #[test]
    fn deepseek_cache_hits_count_and_whole_replies_are_normalized_too() {
        let last = r#"{"id":"1","object":"chat.completion.chunk","created":1,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":7,"total_tokens":107,"prompt_cache_hit_tokens":64,"prompt_cache_miss_tokens":36}}"#;
        let usage = chunk(last, ChatDialect::DeepSeek).unwrap().usage.unwrap();
        assert_eq!(usage.prompt_tokens_details.unwrap().cached_tokens, 64);

        let whole = r#"{"id":"2026","created":1,"model":"glm-5.3","choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}"#;
        let reply = normalize_dialect_response(ChatDialect::Glm, whole).unwrap();
        let parsed: xai_grok_sampling_types::ChatCompletionResponse =
            serde_json::from_str(&reply).unwrap();
        assert_eq!(parsed.object, "chat.completion");
        assert_eq!(
            parsed.choices.first().unwrap().message.content.as_deref(),
            Some("Hi")
        );
        // Something that is not a reply at all is left for the shared parser to report.
        assert_eq!(
            normalize_dialect_response(ChatDialect::Glm, "not json").unwrap(),
            "not json"
        );
    }

    #[test]
    fn codex_incomplete_terminal_remains_incomplete() {
        let mut decoder = CodexEventDecoder::default();
        let event = decoder.decode(&json!({"type":"response.done","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}).to_string()).unwrap().unwrap();
        assert!(matches!(
            event,
            rs::ResponseStreamEvent::ResponseIncomplete(_)
        ));
    }
}
