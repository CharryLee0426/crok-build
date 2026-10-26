//! Per-call observation for an external sink: one [`ObservedCall`] per model API request.
//!
//! crok's Grafana Agent Observability bridge (`xai-grok-agento11y`) installs the sink once per process with
//! [`install_sink`]. Until then every hook here returns at the first check and allocates nothing; while the
//! sink says it is not active ([`GenerationSink::is_active`]), requests are not snapshotted either.
//!
//! Calls are observed where a [`ConversationRequest`] meets its Layer-2 event stream:
//! - the actor's per-attempt loop (`run_one_attempt`): main turns, sub-agent turns;
//! - [`SamplingClient::conversation_collect`]: side calls (titles, recaps, memory, classifiers).
//!
//! Each HTTP attempt is one observation, so a retried request shows as several.
//! Compaction parses raw chunks itself and is not observed as a call (the session reports it as a step).
//!
//! A recorded call to Anthropic's own endpoint goes out with an unsampled `traceparent`, so Claude
//! Platform's telemetry export does not report it a second time ([`send_recorded`]).
//!
//! The record format ([`ObservedCall::to_json_line`]) is the agento11y SDK's `GenerationStart` and
//! `GenerationResult`, read by the bridge in `xai-grok-agento11y/bridge/src/protocol.ts`, plus
//! `spanAttributes` the bridge puts on the call's span: crok's own report of what the call cost,
//! for providers that export no traces of their own (Codex, GLM, DeepSeek, ...).
//!
//! What happens around the calls (turns, tool runs, permission and hook steps, verdicts, ratings,
//! guard checks) reaches the same sink as [`HarnessEvent`]s; see `observe_harness.rs`. A call made
//! while its session runs a turn names the turn's span as its parent.

use std::collections::{HashMap, VecDeque};
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::stream::{BoxStream, Stream, StreamExt};
use serde::Serialize;
use xai_grok_models::pricing::{self, CallTokens, PriceList};
use xai_grok_sampling_types::{
    ApiBackend, ChatCompletionChunk, ContentPart, ConversationItem, ConversationRequest,
    ConversationResponse, ConversationToolChoice, SamplingError, TokenUsage, ToolSpec, rs,
};

use crate::client::SamplingClient;
use crate::events::{SamplingErrorInfo, SamplingEvent};

#[path = "observe_harness.rs"]
mod harness;
pub use harness::{
    GuardCheck, GuardToolCall, GuardToolResult, HarnessEvent, Rating, SpanRef, Step, ToolRun,
    ToolRunOutcome, TurnEnd, TurnScope, TurnStart, Verdict, VerdictValue, begin_turn, check_guard,
    current_surface, guard_provider, note_prompt_origin, record_rating, record_step, record_tool,
    record_verdict, set_session_tag,
};

/// Receives every observed call. Called on the sampler's task: hand the call off and return.
pub trait GenerationSink: Send + Sync {
    fn record(&self, call: ObservedCall);

    /// Receives what happened around the calls (turns, tool runs, steps, scores, ratings, guard
    /// checks). Only sent while [`Self::is_active`]; called on the reporting task, so hand it off.
    fn record_event(&self, _event: HarnessEvent) {}

    /// Whether calls starting now are wanted; checked before each request is snapshotted, so it must be cheap.
    /// A sink that can be switched on and off while crok runs answers here.
    fn is_active(&self) -> bool {
        true
    }
}

static SINK: OnceLock<Arc<dyn GenerationSink>> = OnceLock::new();
/// Agent name of the session's own turns; side calls and sub-agents are named under it.
static AGENT_NAME: OnceLock<String> = OnceLock::new();
const DEFAULT_AGENT_NAME: &str = "crok";

/// Installs the process's sink; the first call wins. `agent_name` names main turns (`crok` when empty).
pub fn install_sink(sink: Arc<dyn GenerationSink>, agent_name: &str) -> bool {
    let name = agent_name.trim();
    let _ = AGENT_NAME.set(if name.is_empty() {
        DEFAULT_AGENT_NAME.to_owned()
    } else {
        name.to_owned()
    });
    SINK.set(sink).is_ok()
}

/// Whether a sink is installed, active or not. Sessions are registered while it is switched off, so a
/// session that started then still has its title and parent once recording is switched on.
pub fn is_enabled() -> bool {
    SINK.get().is_some()
}

fn agent_name_base() -> &'static str {
    AGENT_NAME.get().map_or(DEFAULT_AGENT_NAME, String::as_str)
}

// ---------------------------------------------------------------------------------------------
// Session registry: what the sampler cannot see on a request (title, sub-agent identity).
// ---------------------------------------------------------------------------------------------

/// Sessions kept in the registry; the oldest is forgotten past this (a long desktop run spawns many sub-agents).
const MAX_SESSIONS: usize = 512;

#[derive(Default)]
struct Registry {
    sessions: HashMap<String, SessionEntry>,
    order: VecDeque<String>,
    /// Who drives this process (`tui`, `desktop`, ...), sent as a tag.
    surface: Option<String>,
}

#[derive(Default, Clone)]
struct SessionEntry {
    subagent_type: Option<String>,
    parent_session_id: Option<String>,
    title: Option<String>,
    /// The session's newest completed turn, which a sub-agent it spawns links back to.
    last_generation_id: Option<String>,
    /// A sub-agent links its first completed turn to the parent's; later turns follow from the conversation.
    linked_to_parent: bool,
    /// The turn the session is running; its calls, tool runs and steps hang under its span.
    turn: Option<harness::ActiveTurn>,
    /// `repo`, `branch`, `user`, `origin`: tags on everything the session reports.
    tags: Vec<(&'static str, String)>,
    /// Where the next prompt came from, for the turn it starts (`relay`).
    next_origin: Option<&'static str>,
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

fn with_registry<R>(f: impl FnOnce(&mut Registry) -> R) -> R {
    let mut guard = registry()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    f(&mut guard)
}

impl Registry {
    fn entry(&mut self, session_id: &str) -> &mut SessionEntry {
        if !self.sessions.contains_key(session_id) {
            if self.order.len() >= MAX_SESSIONS
                && let Some(oldest) = self.order.pop_front()
            {
                self.sessions.remove(&oldest);
            }
            self.order.push_back(session_id.to_owned());
        }
        self.sessions.entry(session_id.to_owned()).or_default()
    }
}

/// Records a session's identity when it starts. `subagent_type` and `parent_session_id` are `None` for a top-level session.
pub fn register_session(
    session_id: &str,
    subagent_type: Option<&str>,
    parent_session_id: Option<&str>,
) {
    if !is_enabled() {
        return;
    }
    with_registry(|r| {
        let entry = r.entry(session_id);
        entry.subagent_type = subagent_type.map(str::to_owned);
        entry.parent_session_id = parent_session_id.map(str::to_owned);
    });
}

/// Records a session's title whenever it changes, so generations carry it as the conversation title.
pub fn set_session_title(session_id: &str, title: &str) {
    if !is_enabled() {
        return;
    }
    let title = title.trim();
    with_registry(|r| {
        r.entry(session_id).title = (!title.is_empty()).then(|| title.to_owned());
    });
}

/// Names what drives this process, e.g. `tui`, `desktop` (Crok Desktop) or `agent` (another ACP client).
pub fn set_surface(surface: &str) {
    with_registry(|r| r.surface = Some(surface.to_owned()));
}

pub fn surface() -> Option<String> {
    with_registry(|r| r.surface.clone())
}

// ---------------------------------------------------------------------------------------------
// Claude Platform's own export
// ---------------------------------------------------------------------------------------------

tokio::task_local! {
    /// The tap of the recorded call whose HTTP request is being built and sent.
    static RECORDED_SEND: Arc<Mutex<ResponseTap>>;
}

/// Sends the request of the call `observation` records; `None` (nothing records it) sends it as is.
///
/// Anthropic's endpoint exports a span of each request to the organization's telemetry destinations
/// unless its `traceparent` says it is not sampled, and Agent Observability turns each of those
/// traces into a conversation of its own (agent `claude-platform`, named by the trace id). A call
/// recorded here would then show twice: in its session and again beside it. While `send` runs,
/// [`SamplingClient::post`] marks the request's `traceparent` as not sampled
/// ([`unsample_if_recorded`]), and the API exports nothing for it; the call's own span says so with
/// `crok.unsampled`, so the dashboards count it in Claude Platform's place. Calls no sink records
/// (compaction, or any call while the sink is off) keep their Claude Platform spans.
pub(crate) async fn send_recorded<F: std::future::Future>(
    observation: &Option<Observation>,
    send: F,
) -> F::Output {
    match observation {
        Some(observation) => {
            RECORDED_SEND
                .scope(Arc::clone(&observation.tap), send)
                .await
        }
        None => send.await,
    }
}

/// Marks the `traceparent` of a recorded call's request as not sampled, and the call as sent so;
/// a request no sink records is left alone. See [`send_recorded`].
pub(crate) fn unsample_if_recorded(headers: &mut reqwest::header::HeaderMap) {
    let _ = RECORDED_SEND.try_with(|tap| {
        unsample_traceparent(headers);
        if let Ok(mut tap) = tap.lock() {
            tap.unsampled = true;
        }
    });
}

/// Clears the sampled flag of the request's `traceparent`, or adds an unsampled one.
fn unsample_traceparent(headers: &mut reqwest::header::HeaderMap) {
    let current = headers
        .get("traceparent")
        .and_then(|value| value.to_str().ok());
    if let Ok(value) = reqwest::header::HeaderValue::from_str(&unsampled_traceparent(current)) {
        headers.insert("traceparent", value);
    }
}

/// `traceparent` with the sampled flag (`01`) cleared, keeping its trace and parent ids; a fresh
/// unsampled one when there is none or it is not a version-00 W3C trace context.
fn unsampled_traceparent(current: Option<&str>) -> String {
    const SAMPLED: u8 = 0x01;
    let parts = current.map(|traceparent| traceparent.split('-').collect::<Vec<_>>());
    if let Some(["00", trace_id, parent_id, flags]) = parts.as_deref()
        && is_w3c_id(trace_id, 32)
        && is_w3c_id(parent_id, 16)
        && flags.len() == 2
        && is_lower_hex(flags)
        && let Ok(flags) = u8::from_str_radix(flags, 16)
    {
        return format!("00-{trace_id}-{parent_id}-{:02x}", flags & !SAMPLED);
    }
    let trace_id = uuid::Uuid::new_v4().simple();
    // The low half of a v4 uuid holds its variant bits, so it is never all zeros.
    let (_, parent_id) = uuid::Uuid::new_v4().as_u64_pair();
    format!("00-{trace_id}-{parent_id:016x}-00")
}

/// `len` lowercase hex digits, not all zeros, as W3C trace context requires of its ids.
fn is_w3c_id(id: &str, len: usize) -> bool {
    id.len() == len && is_lower_hex(id) && id.bytes().any(|b| b != b'0')
}

fn is_lower_hex(text: &str) -> bool {
    text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

// ---------------------------------------------------------------------------------------------
// One observed call
// ---------------------------------------------------------------------------------------------

/// Which caller made the request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallPath {
    /// The session's own turn, through the sampler actor (with retries).
    Turn,
    /// A one-shot side call through `conversation_collect`.
    SideCall,
}

/// One finished, failed or abandoned model API request, as the sink receives it.
/// Holds cheap clones of the request and response; [`Self::to_json_line`] does the conversion, off the sampler's task.
pub struct ObservedCall {
    generation_id: String,
    path: CallPath,
    call_kind: String,
    agent_name: String,
    conversation_id: Option<String>,
    conversation_title: Option<String>,
    parent_generation_ids: Vec<String>,
    /// The span of the turn the call belongs to (the session's running turn).
    parent_span: Option<SpanRef>,
    /// The session's own tags (`repo`, `branch`, `user`, `origin`).
    session_tags: Vec<(&'static str, String)>,
    session_id: Option<String>,
    request_id: Option<String>,
    turn_index: Option<String>,
    parent_session_id: Option<String>,
    subagent_type: Option<String>,
    surface: Option<String>,
    backend: ApiBackend,
    provider: String,
    model: String,
    /// Whose standard prices the call is estimated at, by the endpoint's host.
    price_list: Option<PriceList>,
    one_hour_cache: bool,
    request: RequestSnapshot,
    started_at: SystemTime,
    first_token_at: Option<SystemTime>,
    completed_at: SystemTime,
    outcome: CallOutcome,
    response_id: Option<String>,
    response_model: Option<String>,
    /// Sent with an unsampled `traceparent`, so Claude Platform exported no span of it.
    unsampled: bool,
}

struct RequestSnapshot {
    system_prompt: Option<String>,
    /// Items added since the model last spoke: the prompt, or the tool results it asked for.
    new_items: Vec<ConversationItem>,
    /// Tool names for the tool results in `new_items`, from the assistant turn that called them.
    tool_names: HashMap<String, String>,
    tools: Vec<ToolSpec>,
    hosted_tools: Vec<&'static str>,
    max_tokens: Option<u32>,
    temperature: Option<f32>,
    top_p: Option<f32>,
    tool_choice: Option<String>,
    reasoning_effort: Option<&'static str>,
}

enum CallOutcome {
    Completed(Box<ConversationResponse>),
    Failed {
        message: String,
        status_code: Option<u16>,
    },
    /// The caller dropped the stream before it ended (the user interrupted the turn).
    Abandoned,
}

impl ObservedCall {
    pub fn generation_id(&self) -> &str {
        &self.generation_id
    }

    pub fn agent_name(&self) -> &str {
        &self.agent_name
    }

    pub fn conversation_id(&self) -> Option<&str> {
        self.conversation_id.as_deref()
    }

    /// The bridge's stdin line for this call (no trailing newline).
    pub fn to_json_line(&self) -> String {
        serde_json::to_string(&self.to_record()).unwrap_or_default()
    }

    fn to_record(&self) -> GenerationRecord<'_> {
        let request = &self.request;
        let mut tags = HashMap::from([
            ("call_kind", self.call_kind.clone()),
            ("backend", backend_label(&self.backend).to_owned()),
        ]);
        if let Some(surface) = &self.surface {
            tags.insert("surface", surface.clone());
        }
        for (key, value) in &self.session_tags {
            tags.insert(*key, value.clone());
        }
        let mut metadata = serde_json::Map::new();
        let mut put = |key: &str, value: Option<&str>| {
            if let Some(value) = value {
                metadata.insert(key.to_owned(), value.into());
            }
        };
        put("crok.session_id", self.session_id.as_deref());
        put("crok.request_id", self.request_id.as_deref());
        put("crok.turn_index", self.turn_index.as_deref());
        put("crok.parent_session_id", self.parent_session_id.as_deref());
        put("crok.subagent_type", self.subagent_type.as_deref());
        put("crok.reasoning_effort", request.reasoning_effort);
        put(
            "crok.call_path",
            Some(match self.path {
                CallPath::Turn => "turn",
                CallPath::SideCall => "side_call",
            }),
        );

        let (output, usage, stop_reason, result_metadata, error) = match &self.outcome {
            CallOutcome::Completed(response) => {
                let mut result_metadata = serde_json::Map::new();
                if let Some(ticks) = response.cost_usd_ticks {
                    // 1 USD = 1e10 ticks; the provider's own figure (OpenRouter reports one).
                    result_metadata.insert(
                        "crok.provider_cost_usd".to_owned(),
                        serde_json::json!(ticks as f64 / 1e10),
                    );
                }
                (
                    output_messages(response),
                    response.usage.as_ref().map(usage_of),
                    response
                        .raw_stop_reason
                        .clone()
                        .or_else(|| response.stop_reason.map(|r| r.as_ref().to_owned())),
                    result_metadata,
                    None,
                )
            }
            CallOutcome::Failed {
                message,
                status_code,
            } => (
                Vec::new(),
                None,
                None,
                serde_json::Map::new(),
                Some(CallErrorRecord {
                    message: message.clone(),
                    status_code: *status_code,
                }),
            ),
            CallOutcome::Abandoned => (
                Vec::new(),
                None,
                None,
                serde_json::Map::new(),
                Some(CallErrorRecord {
                    message: "cancelled: the request was abandoned before the model finished"
                        .to_owned(),
                    status_code: None,
                }),
            ),
        };

        let mut span_attributes = serde_json::Map::new();
        span_attributes.insert(
            "crok.backend".to_owned(),
            backend_label(&self.backend).into(),
        );
        match &self.outcome {
            CallOutcome::Completed(response) => {
                if let Some((usd, source)) = self.cost(response) {
                    span_attributes.insert("crok.cost.usd".to_owned(), serde_json::json!(usd));
                    span_attributes.insert("crok.cost.source".to_owned(), source.into());
                }
            }
            // Set only here, so dashboards count `crok.cancelled = nil` as a real failure, older crok included.
            CallOutcome::Abandoned => {
                span_attributes.insert("crok.cancelled".to_owned(), true.into());
            }
            CallOutcome::Failed { .. } => {}
        }
        // Set only here: this span is the call's only trace, so dashboards count it in Claude
        // Platform's place, where older crok's calls of the same kind are already counted. It also
        // carries the counts a ratio reads under Claude Platform's names (the SDK's differ), zeros
        // included as Claude Platform sends them, so one query reads both sources' spans.
        if self.unsampled {
            span_attributes.insert("crok.unsampled".to_owned(), true.into());
            if let CallOutcome::Completed(response) = &self.outcome
                && let Some(usage) = &response.usage
            {
                span_attributes.insert(
                    "gen_ai.usage.cache_read.input_tokens".to_owned(),
                    usage.cached_prompt_tokens.into(),
                );
                span_attributes.insert(
                    "gen_ai.usage.reasoning.output_tokens".to_owned(),
                    usage.reasoning_tokens.into(),
                );
            }
        }

        GenerationRecord {
            kind: "generation",
            start: StartRecord {
                id: &self.generation_id,
                mode: "STREAM",
                model: ModelRecord {
                    provider: &self.provider,
                    name: &self.model,
                },
                started_at_ms: epoch_ms(self.started_at),
                conversation_id: self.conversation_id.as_deref(),
                conversation_title: self.conversation_title.as_deref(),
                agent_name: &self.agent_name,
                system_prompt: request.system_prompt.as_deref(),
                max_tokens: request.max_tokens,
                temperature: request.temperature,
                top_p: request.top_p,
                tool_choice: request.tool_choice.as_deref(),
                thinking_enabled: request.reasoning_effort.map(|effort| effort != "none"),
                parent_generation_ids: &self.parent_generation_ids,
                tools: tool_records(&request.tools, &request.hosted_tools),
                tags,
                metadata,
            },
            first_token_at_ms: self.first_token_at.map(epoch_ms),
            result: ResultRecord {
                completed_at_ms: epoch_ms(self.completed_at),
                response_id: self.response_id.as_deref(),
                response_model: self.response_model.as_deref(),
                input: input_messages(&request.new_items, &request.tool_names),
                output,
                usage,
                stop_reason,
                metadata: result_metadata,
            },
            error,
            span_attributes,
            parent: self.parent_span.as_ref(),
        }
    }

    /// What the call cost in USD, and where the figure comes from: the provider's own when it reports
    /// one (OpenRouter, xAI), else the model's standard API price for the call's tokens (`list_price`),
    /// whatever actually paid for it (a Codex or GLM Coding Plan subscription, say). `None` for a model
    /// no price list knows. The model the provider says answered is tried before the requested one.
    fn cost(&self, response: &ConversationResponse) -> Option<(f64, &'static str)> {
        if let Some(ticks) = response.cost_usd_ticks {
            return Some((ticks as f64 / pricing::USD_TICKS_PER_USD, "provider"));
        }
        let usage = response.usage.as_ref()?;
        let price = [self.response_model.as_deref(), Some(self.model.as_str())]
            .into_iter()
            .flatten()
            .map(str::trim)
            .filter(|model| !model.is_empty())
            .find_map(|model| pricing::listed_price(self.price_list, model, self.started_at))?;
        // `prompt_tokens` counts the whole prompt; the price list wants disjoint buckets.
        let cache_read = u64::from(usage.cached_prompt_tokens);
        let cache_write = u64::from(usage.cache_creation_prompt_tokens);
        let tokens = CallTokens {
            input: u64::from(usage.prompt_tokens)
                .saturating_sub(cache_read)
                .saturating_sub(cache_write),
            cache_read,
            cache_write,
            output: u64::from(usage.completion_tokens),
        };
        Some((price.cost_usd(&tokens, self.one_hour_cache), "list_price"))
    }
}

/// The start of one call, alive from just before the HTTP send until the stream ends.
pub(crate) struct Observation {
    sink: Arc<dyn GenerationSink>,
    call: ObservedCall,
    /// Response id and model read off the raw stream, for the backends whose L2 response drops
    /// them, and whether the request went out unsampled ([`send_recorded`]).
    tap: Arc<Mutex<ResponseTap>>,
}

#[derive(Default)]
struct ResponseTap {
    id: Option<String>,
    model: Option<String>,
    unsampled: bool,
}

impl Observation {
    /// Snapshots `request` when a sink is installed and active; call before `request` moves into the send.
    pub(crate) fn start(
        client: &SamplingClient,
        request: &ConversationRequest,
        path: CallPath,
    ) -> Option<Self> {
        let sink = SINK.get().filter(|sink| sink.is_active())?.clone();
        let session_id = request.x_grok_session_id.clone();
        let conv_id = request.x_grok_conv_id.clone();
        let session = session_id
            .as_deref()
            .and_then(|id| with_registry(|r| r.sessions.get(id).cloned()));
        let subagent_type = session.as_ref().and_then(|s| s.subagent_type.clone());
        let parent_session_id = session.as_ref().and_then(|s| s.parent_session_id.clone());
        let base = agent_name_base();
        let (call_kind, agent_name) = match path {
            CallPath::Turn => match (&subagent_type, &parent_session_id) {
                (None, None) => ("turn".to_owned(), base.to_owned()),
                (kind, _) => (
                    "subagent_turn".to_owned(),
                    format!("{base}/{}", kind.as_deref().unwrap_or("subagent")),
                ),
            },
            CallPath::SideCall => {
                let kind = side_call_kind(
                    conv_id.as_deref(),
                    session_id.as_deref(),
                    request.x_grok_req_id.as_deref(),
                );
                let name = format!("{base}/{kind}");
                (kind, name)
            }
        };
        let parent = parent_session_id
            .as_deref()
            .and_then(|id| with_registry(|r| r.sessions.get(id).cloned()));
        let conversation_title = session.as_ref().and_then(|s| s.title.clone()).or_else(|| {
            subagent_type.as_deref().map(|kind| {
                match parent.as_ref().and_then(|p| p.title.as_deref()) {
                    Some(parent_title) => format!("{kind} sub-agent · {parent_title}"),
                    None => format!("{kind} sub-agent"),
                }
            })
        });
        let parent_generation_ids = match (&path, &session, &parent) {
            (CallPath::Turn, Some(s), Some(p)) if !s.linked_to_parent => {
                p.last_generation_id.iter().cloned().collect()
            }
            _ => Vec::new(),
        };
        let parent_span = session_id.as_deref().and_then(harness::current_turn_span);
        let session_tags = session_id
            .as_deref()
            .map(harness::session_tags)
            .unwrap_or_default();
        let backend = client.api_backend();
        let model = request
            .model
            .clone()
            .unwrap_or_else(|| client.observed_default_model().to_owned());
        let call = ObservedCall {
            generation_id: format!("gen_{}", uuid::Uuid::new_v4().simple()),
            path,
            call_kind,
            agent_name,
            conversation_id: session_id.clone().or_else(|| conv_id.clone()),
            conversation_title,
            parent_generation_ids,
            parent_span,
            session_tags,
            request_id: request.x_grok_req_id.clone(),
            turn_index: request.x_grok_turn_idx.clone(),
            session_id,
            parent_session_id,
            subagent_type,
            surface: surface(),
            provider: provider_name(&backend, client.observed_base_url()),
            backend,
            model,
            price_list: PriceList::for_base_url(client.observed_base_url()),
            one_hour_cache: client.observed_one_hour_cache(),
            request: snapshot(client, request),
            started_at: SystemTime::now(),
            first_token_at: None,
            completed_at: SystemTime::now(),
            outcome: CallOutcome::Abandoned,
            response_id: None,
            response_model: None,
            unsampled: false,
        };
        Some(Self {
            sink,
            call,
            tap: Arc::default(),
        })
    }

    fn finish(mut self, outcome: CallOutcome) {
        self.call.completed_at = SystemTime::now();
        if let Ok(tap) = self.tap.lock() {
            self.call.response_id = tap.id.clone();
            self.call.response_model = tap.model.clone();
            self.call.unsampled = tap.unsampled;
        }
        if let CallOutcome::Completed(response) = &outcome {
            if let Some(id) = &response.message_id {
                self.call.response_id = Some(id.clone());
            }
            if let Some(model) = response.assistant().and_then(|a| a.model_id.clone()) {
                self.call.response_model = Some(model);
            }
            if self.call.path == CallPath::Turn
                && let Some(session_id) = self.call.session_id.as_deref()
            {
                let generation_id = self.call.generation_id.clone();
                with_registry(|r| {
                    let entry = r.entry(session_id);
                    entry.last_generation_id = Some(generation_id);
                    entry.linked_to_parent = true;
                });
            }
        }
        if self.call.path == CallPath::Turn
            && let Some(session_id) = self.call.session_id.as_deref()
        {
            harness::count_model_call(session_id);
        }
        self.call.outcome = outcome;
        self.sink.record(self.call);
    }
}

/// Records a call that failed before its stream opened (connection error, non-2xx status).
pub(crate) fn record_send_error(observation: Option<Observation>, error: &SamplingError) {
    let Some(observation) = observation else {
        return;
    };
    let status_code = match error {
        SamplingError::Api { status, .. } => Some(status.as_u16()),
        SamplingError::Auth { .. } => Some(401),
        _ => None,
    };
    observation.finish(CallOutcome::Failed {
        message: error.to_string(),
        status_code,
    });
}

/// Reads the response id and model off a Chat Completions stream (its L2 response keeps neither).
pub(crate) fn tap_chat(
    observation: &Option<Observation>,
    raw: BoxStream<'static, xai_grok_sampling_types::Result<ChatCompletionChunk>>,
) -> BoxStream<'static, xai_grok_sampling_types::Result<ChatCompletionChunk>> {
    let Some(observation) = observation else {
        return raw;
    };
    let tap = Arc::clone(&observation.tap);
    raw.inspect(move |chunk| {
        if let Ok(chunk) = chunk
            && let Ok(mut tap) = tap.lock()
            && tap.id.is_none()
            && !chunk.id.is_empty()
        {
            tap.id = Some(chunk.id.clone());
            tap.model = (!chunk.model.is_empty()).then(|| chunk.model.clone());
        }
    })
    .boxed()
}

/// Reads the response id and model off a Responses stream's `response.created` event.
pub(crate) fn tap_responses(
    observation: &Option<Observation>,
    raw: BoxStream<'static, xai_grok_sampling_types::Result<rs::ResponseStreamEvent>>,
) -> BoxStream<'static, xai_grok_sampling_types::Result<rs::ResponseStreamEvent>> {
    let Some(observation) = observation else {
        return raw;
    };
    let tap = Arc::clone(&observation.tap);
    raw.inspect(move |event| {
        if let Ok(rs::ResponseStreamEvent::ResponseCreated(created)) = event
            && let Ok(mut tap) = tap.lock()
        {
            tap.id = Some(created.response.id.clone());
            tap.model = Some(created.response.model.clone());
        }
    })
    .boxed()
}

/// Passes `events` through unchanged and records the call when it completes, fails, or is dropped first.
pub(crate) fn watch<S>(observation: Option<Observation>, events: S) -> ObservedEvents<S>
where
    S: Stream<Item = SamplingEvent>,
{
    ObservedEvents {
        inner: Box::pin(events),
        observation,
    }
}

pub(crate) struct ObservedEvents<S> {
    inner: Pin<Box<S>>,
    observation: Option<Observation>,
}

impl<S: Stream<Item = SamplingEvent>> Stream for ObservedEvents<S> {
    type Item = SamplingEvent;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = &mut *self;
        let next = this.inner.as_mut().poll_next(cx);
        if let Poll::Ready(Some(event)) = &next
            && let Some(observation) = this.observation.as_mut()
        {
            match event {
                SamplingEvent::FirstToken { .. }
                | SamplingEvent::ChannelToken { .. }
                | SamplingEvent::ToolCallDelta { .. } => {
                    if observation.call.first_token_at.is_none() {
                        observation.call.first_token_at = Some(SystemTime::now());
                    }
                }
                SamplingEvent::ResponseStarted {
                    message_id, model, ..
                } => {
                    if let Ok(mut tap) = observation.tap.lock() {
                        tap.id = Some(message_id.clone());
                        tap.model = Some(model.clone());
                    }
                }
                SamplingEvent::Completed { response, .. } => {
                    if let Some(observation) = this.observation.take() {
                        observation.finish(CallOutcome::Completed(response.clone()));
                    }
                }
                SamplingEvent::Failed { error, .. } => {
                    if let Some(observation) = this.observation.take() {
                        observation.finish(failed_outcome(error));
                    }
                }
                _ => {}
            }
        }
        next
    }
}

impl<S> Drop for ObservedEvents<S> {
    fn drop(&mut self) {
        if let Some(observation) = self.observation.take() {
            observation.finish(CallOutcome::Abandoned);
        }
    }
}

fn failed_outcome(error: &SamplingErrorInfo) -> CallOutcome {
    CallOutcome::Failed {
        message: error.message.clone(),
        status_code: error.status_code,
    }
}

// ---------------------------------------------------------------------------------------------
// Mapping crok's conversation items to the SDK's messages
// ---------------------------------------------------------------------------------------------

/// Longest text sent for one message part. The SDK rejects a generation over 4 MiB, and a tool
/// result can be a whole file; the rest is replaced by a note saying how much was left out.
const MAX_PART_BYTES: usize = 64 * 1024;

fn snapshot(client: &SamplingClient, request: &ConversationRequest) -> RequestSnapshot {
    let items = &request.items;
    let leading_system = items
        .iter()
        .take_while(|item| matches!(item, ConversationItem::System(_)))
        .count();
    let system_prompt = items
        .iter()
        .take(leading_system)
        .filter_map(|item| match item {
            ConversationItem::System(system) => Some(system.content.as_ref()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    let last_assistant = items
        .iter()
        .rposition(|item| matches!(item, ConversationItem::Assistant(_)));
    let first_new = last_assistant.map_or(leading_system, |index| index + 1);
    let new_items: Vec<ConversationItem> = items.iter().skip(first_new).cloned().collect();
    let tool_names = new_items
        .iter()
        .filter_map(|item| match item {
            ConversationItem::ToolResult(result) => Some(result.tool_call_id.as_str()),
            _ => None,
        })
        .filter_map(|id| {
            items.iter().find_map(|item| match item {
                ConversationItem::Assistant(assistant) => assistant
                    .tool_calls
                    .iter()
                    .find(|call| call.id.as_ref() == id)
                    .map(|call| (id.to_owned(), call.name.clone())),
                _ => None,
            })
        })
        .collect();
    let (temperature, top_p, max_tokens) = client.observed_defaults();
    RequestSnapshot {
        system_prompt: (!system_prompt.is_empty()).then(|| capped(&system_prompt)),
        new_items,
        tool_names,
        tools: request.tools.clone(),
        hosted_tools: request.hosted_tools.iter().map(|t| t.wire_name()).collect(),
        max_tokens: request.max_output_tokens.or(max_tokens),
        temperature: request.temperature.or(temperature),
        top_p: request.top_p.or(top_p),
        tool_choice: request.tool_choice.as_ref().map(|choice| match choice {
            ConversationToolChoice::Auto => "auto".to_owned(),
            ConversationToolChoice::None => "none".to_owned(),
            ConversationToolChoice::Required => "required".to_owned(),
            ConversationToolChoice::Function(name) => name.clone(),
        }),
        reasoning_effort: request.reasoning_effort.map(|effort| effort.into()),
    }
}

fn input_messages(
    items: &[ConversationItem],
    tool_names: &HashMap<String, String>,
) -> Vec<MessageRecord> {
    items
        .iter()
        .filter_map(|item| match item {
            ConversationItem::User(user) => Some(MessageRecord {
                role: "user",
                parts: user
                    .content
                    .iter()
                    .filter(|part| !is_blank_text(part))
                    .map(content_part)
                    .collect(),
            }),
            // A runtime reminder injected mid-conversation; the SDK has no system role.
            ConversationItem::System(system) => Some(MessageRecord {
                role: "user",
                parts: vec![PartRecord::Text {
                    text: capped(&format!("[system]\n{}", system.content)),
                }],
            }),
            ConversationItem::ToolResult(result) => {
                let mut content = result.content.to_string();
                if !result.images.is_empty() {
                    content.push_str(&format!("\n[{} image(s) not sent]", result.images.len()));
                }
                Some(MessageRecord {
                    role: "tool",
                    parts: vec![PartRecord::ToolResult {
                        tool_result: ToolResultRecord {
                            tool_call_id: result.tool_call_id.clone(),
                            name: tool_names.get(&result.tool_call_id).cloned(),
                            content: capped(&content),
                        },
                    }],
                })
            }
            ConversationItem::Assistant(_)
            | ConversationItem::BackendToolCall(_)
            | ConversationItem::Reasoning(_) => None,
        })
        .filter(|message| !message.parts.is_empty())
        .collect()
}

fn is_blank_text(part: &ContentPart) -> bool {
    matches!(part, ContentPart::Text { text } if text.trim().is_empty())
}

fn content_part(part: &ContentPart) -> PartRecord {
    match part {
        ContentPart::Text { text } => PartRecord::Text { text: capped(text) },
        ContentPart::Image { .. } => PartRecord::Text {
            text: "[image not sent]".to_owned(),
        },
    }
}

/// The model's reply as one assistant message: thinking, text and tool calls in the order produced.
fn output_messages(response: &ConversationResponse) -> Vec<MessageRecord> {
    let mut parts = Vec::new();
    for item in &response.items {
        match item {
            ConversationItem::Reasoning(reasoning) => {
                let text = reasoning_text(reasoning);
                // The SDK refuses a part with blank text (and the whole generation with it).
                if !text.trim().is_empty() {
                    parts.push(PartRecord::Thinking {
                        thinking: capped(&text),
                    });
                }
            }
            ConversationItem::Assistant(assistant) => {
                if !assistant.content.trim().is_empty() {
                    parts.push(PartRecord::Text {
                        text: capped(&assistant.content),
                    });
                }
                for call in &assistant.tool_calls {
                    parts.push(PartRecord::ToolCall {
                        tool_call: ToolCallRecord {
                            id: call.id.to_string(),
                            name: call.name.clone(),
                            input_json: capped(&call.arguments),
                        },
                    });
                }
            }
            ConversationItem::BackendToolCall(call) => {
                parts.push(PartRecord::ToolCall {
                    tool_call: ToolCallRecord {
                        id: call.id().to_owned(),
                        name: backend_tool_name(&call.kind).to_owned(),
                        input_json: String::new(),
                    },
                });
            }
            ConversationItem::User(_)
            | ConversationItem::System(_)
            | ConversationItem::ToolResult(_) => {}
        }
    }
    if parts.is_empty() {
        Vec::new()
    } else {
        vec![MessageRecord {
            role: "assistant",
            parts,
        }]
    }
}

fn reasoning_text(reasoning: &rs::ReasoningItem) -> String {
    let content: Vec<&str> = reasoning
        .content
        .iter()
        .flatten()
        .map(|c| c.text.as_str())
        .collect();
    if !content.is_empty() {
        return content.join("\n");
    }
    reasoning
        .summary
        .iter()
        .map(|part| match part {
            rs::SummaryPart::SummaryText(summary) => summary.text.as_str(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn backend_tool_name(kind: &xai_grok_sampling_types::BackendToolKind) -> &'static str {
    use xai_grok_sampling_types::BackendToolKind;
    match kind {
        BackendToolKind::WebSearch(_) => "web_search",
        BackendToolKind::XSearch(_) => "x_search",
        BackendToolKind::CodeInterpreter(_) => "code_interpreter",
    }
}

fn tool_records(tools: &[ToolSpec], hosted: &[&'static str]) -> Vec<ToolRecord> {
    tools
        .iter()
        .map(|tool| ToolRecord {
            name: tool.name.clone(),
            description: tool.description.clone(),
            kind: "function",
            input_schema_json: serde_json::to_string(&tool.parameters).ok(),
        })
        .chain(hosted.iter().map(|name| ToolRecord {
            name: (*name).to_owned(),
            description: None,
            kind: "hosted",
            input_schema_json: None,
        }))
        .collect()
}

/// crok's usage is already inclusive: `prompt_tokens` counts cache reads and writes, which are subsets of it.
fn usage_of(usage: &TokenUsage) -> UsageRecord {
    UsageRecord {
        input_tokens: usage.prompt_tokens,
        output_tokens: usage.completion_tokens,
        total_tokens: usage.total_tokens,
        cache_read_input_tokens: usage.cached_prompt_tokens,
        cache_write_input_tokens: usage.cache_creation_prompt_tokens,
        reasoning_tokens: usage.reasoning_tokens,
        input_semantics: "inclusive",
    }
}

fn capped(text: &str) -> String {
    if text.len() <= MAX_PART_BYTES {
        return text.to_owned();
    }
    let mut end = MAX_PART_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let kept = text.get(..end).unwrap_or_default();
    format!(
        "{kept}\n[crok: {} more bytes not sent]",
        text.len().saturating_sub(end)
    )
}

/// A side call's kind from its synthetic conversation id (`recap-<uuid>` is `recap`), else, for a
/// call that keeps the session's own conversation id (for the prompt cache), from its request id
/// (`xai-goal-eval-<uuid>` is `goal-eval`); `side` otherwise.
fn side_call_kind(conv_id: Option<&str>, session_id: Option<&str>, req_id: Option<&str>) -> String {
    labelled_kind(conv_id.filter(|id| Some(*id) != session_id))
        .or_else(|| labelled_kind(req_id.map(|id| id.strip_prefix("xai-").unwrap_or(id))))
        .unwrap_or("side")
        .to_owned()
}

/// `<kind>-<uuid>` → `kind`, when `kind` is a plain label.
fn labelled_kind(id: Option<&str>) -> Option<&str> {
    const UUID_LEN: usize = 36;
    let conv_id = id?;
    let split = conv_id.len().saturating_sub(UUID_LEN + 1);
    conv_id
        .get(..split)
        .zip(conv_id.get(split..))
        .and_then(|(kind, rest)| {
            let uuid = rest.strip_prefix('-')?;
            uuid::Uuid::parse_str(uuid).ok()?;
            Some(kind)
        })
        .filter(|kind| {
            !kind.is_empty()
                && kind
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        })
}

fn backend_label(backend: &ApiBackend) -> &'static str {
    match backend {
        ApiBackend::ChatCompletions => "chat_completions",
        ApiBackend::Responses => "responses",
        ApiBackend::OpenRouter => "openrouter",
        ApiBackend::OpenAiCodex => "openai_codex",
        ApiBackend::DeepSeek => "deepseek",
        ApiBackend::Glm => "glm",
        ApiBackend::Messages => "messages",
    }
}

/// The provider name Agent Observability prices by: from the host when it is a known one, else from the backend.
fn provider_name(backend: &ApiBackend, base_url: &str) -> String {
    let host = base_url
        .split_once("://")
        .map_or(base_url, |(_, rest)| rest)
        .split(['/', ':', '?'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let known = [
        ("anthropic.com", "anthropic"),
        ("openai.com", "openai"),
        ("chatgpt.com", "openai"),
        ("x.ai", "xai"),
        ("openrouter.ai", "openrouter"),
        ("deepseek.com", "deepseek"),
        ("bigmodel.cn", "zai"),
        ("z.ai", "zai"),
    ];
    if let Some((_, name)) = known
        .iter()
        .find(|(domain, _)| host == *domain || host.ends_with(&format!(".{domain}")))
    {
        return (*name).to_owned();
    }
    match backend {
        ApiBackend::Messages => "anthropic".to_owned(),
        ApiBackend::OpenRouter => "openrouter".to_owned(),
        ApiBackend::OpenAiCodex => "openai".to_owned(),
        ApiBackend::DeepSeek => "deepseek".to_owned(),
        ApiBackend::Glm => "zai".to_owned(),
        ApiBackend::ChatCompletions | ApiBackend::Responses if !host.is_empty() => host,
        ApiBackend::ChatCompletions | ApiBackend::Responses => "unknown".to_owned(),
    }
}

fn epoch_ms(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

// ---------------------------------------------------------------------------------------------
// The wire record (see bridge/src/protocol.ts)
// ---------------------------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GenerationRecord<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    start: StartRecord<'a>,
    result: ResultRecord<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    first_token_at_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<CallErrorRecord>,
    /// Attributes the bridge adds to the call's span (`crok.*`); the SDK has no field for them.
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    span_attributes: serde_json::Map<String, serde_json::Value>,
    /// The turn span the call's span is a child of.
    #[serde(skip_serializing_if = "Option::is_none")]
    parent: Option<&'a SpanRef>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StartRecord<'a> {
    id: &'a str,
    mode: &'static str,
    model: ModelRecord<'a>,
    started_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    conversation_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    conversation_title: Option<&'a str>,
    agent_name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    system_prompt: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    top_p: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_choice: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thinking_enabled: Option<bool>,
    #[serde(skip_serializing_if = "<[String]>::is_empty")]
    parent_generation_ids: &'a [String],
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<ToolRecord>,
    tags: HashMap<&'static str, String>,
    metadata: serde_json::Map<String, serde_json::Value>,
}

#[derive(Serialize)]
struct ModelRecord<'a> {
    provider: &'a str,
    name: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolRecord {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(rename = "type")]
    kind: &'static str,
    #[serde(rename = "inputSchemaJSON", skip_serializing_if = "Option::is_none")]
    input_schema_json: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResultRecord<'a> {
    completed_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_model: Option<&'a str>,
    input: Vec<MessageRecord>,
    output: Vec<MessageRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<UsageRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stop_reason: Option<String>,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    metadata: serde_json::Map<String, serde_json::Value>,
}

#[derive(Serialize)]
struct MessageRecord {
    role: &'static str,
    parts: Vec<PartRecord>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum PartRecord {
    Text {
        text: String,
    },
    Thinking {
        thinking: String,
    },
    ToolCall {
        #[serde(rename = "toolCall")]
        tool_call: ToolCallRecord,
    },
    ToolResult {
        #[serde(rename = "toolResult")]
        tool_result: ToolResultRecord,
    },
}

#[derive(Serialize)]
struct ToolCallRecord {
    id: String,
    name: String,
    #[serde(rename = "inputJSON", skip_serializing_if = "String::is_empty")]
    input_json: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolResultRecord {
    tool_call_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    content: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageRecord {
    input_tokens: u32,
    output_tokens: u32,
    total_tokens: u32,
    cache_read_input_tokens: u32,
    cache_write_input_tokens: u32,
    reasoning_tokens: u32,
    input_semantics: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CallErrorRecord {
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    status_code: Option<u16>,
}

#[cfg(test)]
#[path = "observe_tests.rs"]
mod tests;
