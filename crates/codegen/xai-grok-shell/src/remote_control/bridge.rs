//! The bridge loop, on the agent's `LocalSet`: keeps the mirrors of this process's sessions current and runs the
//! commands phones and the web send.

use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Weak;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use agent_client_protocol::{self as acp, Agent as _};
use crok_remote::credentials::{self, Credentials};
use crok_remote::link::{FromRelay, Link, LinkConfig, LinkState, ToRelay};
use crok_remote::types::{
    CatalogEntry, CommandOutcome, CommandType, EffortOption, EventInput, EventKind, InboxCommand,
    ModelOption, PendingInteraction, PendingOption, SessionFields, SessionStatus, SessionUsage,
    SlashCommand, now_ms,
};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::transcript::{Signal, Transcript, shorten};
use super::{
    HostApp, Observed, Observer, PERMISSION_RESOLVED_METHOD, PermissionAsk, REMOTE_PROMPT_METHOD,
    REMOTE_STATUS_METHOD,
};
use crate::agent::MvpAgent;

const TICK: Duration = Duration::from_millis(250);
/// While someone has the session open, streamed text goes out this often.
const WATCHED_FLUSH: Duration = Duration::from_millis(750);
/// Otherwise it goes out at message boundaries, or after this long at the latest.
const UNWATCHED_FLUSH: Duration = Duration::from_secs(30);
/// How often a running process looks for a sign-in or sign-out made elsewhere (in ticks: 5 s).
const SETTINGS_CHECK_TICKS: u32 = 20;
/// How much history a mirror starts with: the last few user turns.
const BACKFILL_TURNS: usize = 8;
/// How much of a session no crok runs a viewer gets when opening it.
const HISTORY_TURNS: usize = 20;
/// How often a process offers to list this computer's sessions (in ticks: 10 min). The relay lets one per computer.
const CATALOG_TICKS: u32 = 2_400;
const TITLE_FALLBACK_MAX: usize = 80;
/// A session opened here for a prompt from elsewhere is closed again after this long without a turn or a viewer.
const ADOPTED_IDLE: Duration = Duration::from_secs(10 * 60);
/// How often idle adopted sessions are looked for (in ticks: 5 s).
const RELEASE_CHECK_TICKS: u32 = 20;
/// How often the models this process can run are compared with what the relay has (in ticks: 2 min).
const MODELS_CHECK_TICKS: u32 = 480;
const PENDING_TITLE_MAX: usize = 300;
const PENDING_DETAIL_MAX: usize = 2_000;

enum Internal {
    Fields {
        session_id: String,
        fields: SessionFields,
        real_title: bool,
    },
    Backfilled {
        session_id: String,
        events: Vec<EventInput>,
        preview: Option<(EventKind, String)>,
    },
    Claimed {
        command: InboxCommand,
        claimed: bool,
    },
    PromptReturned {
        session_id: String,
        command_id: String,
        error: Option<String>,
    },
    /// A command a task finished (session info).
    Complete { command_id: String, result: Value },
    /// This computer's sessions, listed for the upload the relay granted (`None`: no upload this time).
    Catalog {
        upload: Option<(String, Vec<CatalogEntry>)>,
    },
    /// A transcript read from disk for a `history` command.
    History {
        command_id: String,
        session_doc_id: String,
        events: Vec<EventInput>,
        preview: Option<(EventKind, String)>,
    },
    /// A session opened for a prompt from elsewhere is loaded (or could not be).
    Opened {
        session_id: String,
        error: Option<String>,
    },
    /// A session opened for a `create` command (its crok id), or why it could not be.
    Created {
        command: InboxCommand,
        result: Result<String, String>,
    },
    /// The relay gave the new session its row (`error`: it refused).
    Bound {
        session_id: String,
        command: InboxCommand,
        error: Option<String>,
    },
    /// A config command ran: the session's model and thinking level now, or the error.
    ConfigApplied {
        session_id: String,
        command_id: String,
        result: Result<(Option<String>, Option<String>), String>,
    },
    /// A session's slash commands, read from the agent.
    Commands {
        session_id: String,
        commands: Vec<SlashCommand>,
    },
    /// A permission request was answered (`by_remote`: from another device) or dropped by the agent.
    PermissionSettled {
        session_id: String,
        id: String,
        by_remote: bool,
    },
}

/// A permission request offered to every device; the first answer wins.
struct PendingPermission {
    id: String,
    tool_call_id: String,
    /// Takes the option a device chose.
    remote: Option<oneshot::Sender<String>>,
    /// The front end shows it too (it must drop its prompt when another device answers).
    visible: bool,
}

struct Mirror {
    cwd: String,
    /// Opened with history (resumed): the mirror starts with a backfill.
    loaded: bool,
    /// A prompt was sent: worth mirroring even when new.
    had_prompt: bool,
    /// The upsert went out.
    requested: bool,
    /// The relay has it (the upsert came back).
    registered: bool,
    backfill_pending: bool,
    /// What the relay has, and what it should have; the difference goes out each tick.
    sent: SessionFields,
    desired: SessionFields,
    has_real_title: bool,
    transcript: Transcript,
    turn_running: bool,
    live_prompt_id: Option<String>,
    remote_running: Option<String>,
    queue: VecDeque<InboxCommand>,
    boundary: bool,
    last_flush: Instant,
    /// The newest preview line, published at a boundary or once the turn is over.
    latest_preview: Option<(EventKind, String)>,
    /// Opened by the bridge for a prompt sent from elsewhere; the front end does not show it.
    adopted: bool,
    /// Still loading (adopted): its prompts wait.
    opening: bool,
    /// Since when an adopted session has had nothing to do.
    idle_since: Option<Instant>,
    permission: Option<PendingPermission>,
    /// The session's slash commands as the agent advertises them, and what the relay has.
    commands: Option<Vec<SlashCommand>>,
    sent_commands: Option<Vec<SlashCommand>>,
}

impl Mirror {
    fn new(cwd: String, prefix: &str) -> Mirror {
        Mirror {
            adopted: false,
            opening: false,
            idle_since: None,
            permission: None,
            commands: None,
            sent_commands: None,
            cwd: cwd.clone(),
            loaded: false,
            had_prompt: false,
            requested: false,
            registered: false,
            backfill_pending: false,
            sent: SessionFields::default(),
            desired: SessionFields {
                cwd: Some(cwd),
                status: Some(SessionStatus::Idle),
                ..SessionFields::default()
            },
            has_real_title: false,
            transcript: Transcript::new(prefix.to_string(), false),
            turn_running: false,
            live_prompt_id: None,
            remote_running: None,
            queue: VecDeque::new(),
            boundary: false,
            last_flush: Instant::now(),
            latest_preview: None,
        }
    }

    fn publish_preview(&mut self) {
        if let Some((kind, text)) = self.latest_preview.take() {
            self.desired.preview = Some(text);
            self.desired.preview_kind = Some(kind);
        }
    }

    fn worth_mirroring(&self) -> bool {
        self.loaded || self.had_prompt
    }

    fn set_status(&mut self, status: SessionStatus) {
        self.desired.status = Some(status);
    }

    /// Until the agent names the session, its first prompt's first line does.
    fn title_from_prompt(&mut self, text: &str) {
        if self.has_real_title || self.desired.title.is_some() {
            return;
        }
        let line = text
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("");
        if !line.is_empty() {
            self.desired.title = Some(shorten(line, TITLE_FALLBACK_MAX));
        }
    }
}

pub(crate) struct Bridge {
    agent: Weak<MvpAgent>,
    app: HostApp,
    observer: Observer,
    rx: mpsc::UnboundedReceiver<Observed>,
    internal_tx: mpsc::UnboundedSender<Internal>,
    internal_rx: mpsc::UnboundedReceiver<Internal>,
    link: Option<Link>,
    link_rx: Option<mpsc::UnboundedReceiver<FromRelay>>,
    credentials: Option<Credentials>,
    /// (credentials file time, `[remote] enabled`) at the last check.
    seen: Option<(Option<SystemTime>, bool)>,
    reported: Option<&'static str>,
    mirrors: HashMap<String, Mirror>,
    handled: HashSet<String>,
    watched: HashMap<String, Instant>,
    /// Makes this process's transcript keys unique next to earlier runs' (`l3f2a…`).
    generation: String,
    activations: u32,
    /// Each listed session's project, from the last catalog, for the sessions this process mirrors.
    project_of: HashMap<String, String>,
    /// A catalog offer or upload is under way.
    catalog_busy: bool,
    /// Numbers permission requests, so an answer to an old one is told apart.
    interactions: u64,
    /// The models (with thinking levels) the relay has for this process.
    sent_models: Option<Vec<ModelOption>>,
}

async fn recv_opt<T>(rx: &mut Option<mpsc::UnboundedReceiver<T>>) -> Option<Option<T>> {
    match rx {
        Some(rx) => Some(rx.recv().await),
        None => std::future::pending().await,
    }
}

fn raw(value: &Value) -> Arc<serde_json::value::RawValue> {
    serde_json::value::to_raw_value(value)
        .map(Arc::from)
        .unwrap_or_else(|_| {
            Arc::from(serde_json::value::to_raw_value(&json!({})).expect("empty object"))
        })
}

/// An extension method's JSON result; unwraps the `{"result": …}` envelope some handlers use.
async fn ext_json(agent: &MvpAgent, method: &str, params: Value) -> Option<Value> {
    let response = agent
        .ext_method(acp::ExtRequest::new(method, raw(&params)))
        .await
        .ok()?;
    let value: Value = serde_json::from_str(response.0.get()).ok()?;
    match value.as_object() {
        Some(object) if object.contains_key("result") && object.len() <= 2 => {
            object.get("result").cloned()
        }
        _ => Some(value),
    }
}

fn number(value: Option<&Value>) -> Option<f64> {
    value.and_then(Value::as_f64)
}

/// The session's usage and context, as the relay stores them.
fn usage_fields(info: Option<&Value>, usage: Option<&Value>) -> SessionUsage {
    let totals = usage.and_then(|u| u.get("usage"));
    let ticks = number(totals.and_then(|t| t.get("costUsdTicks")));
    let context = info.and_then(|i| i.get("context"));
    SessionUsage {
        input_tokens: number(totals.and_then(|t| t.get("inputTokens"))),
        output_tokens: number(totals.and_then(|t| t.get("outputTokens"))),
        cached_tokens: number(totals.and_then(|t| t.get("cachedReadTokens"))),
        reasoning_tokens: number(totals.and_then(|t| t.get("reasoningTokens"))),
        cost_usd: ticks.map(|t| t / xai_grok_models::pricing::USD_TICKS_PER_USD),
        context_tokens: number(context.and_then(|c| c.get("used"))),
        context_window: number(context.and_then(|c| c.get("total"))).filter(|w| *w > 0.0),
    }
}

/// What a phone's info request gets back (`relay/DESIGN.md`, "An info result").
fn info_result(
    session_id: &str,
    cwd: &str,
    fields: &SessionFields,
    info: Option<&Value>,
    usage: Option<&Value>,
) -> Value {
    let totals = usage_fields(info, usage);
    let model = info
        .and_then(|i| i.get("modelDisplayName").or_else(|| i.get("model")))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| fields.model.clone());
    json!({
        "sessionId": session_id,
        "title": fields.title,
        "model": model,
        "modelId": fields.model,
        "effort": fields.effort,
        "cwd": info.and_then(|i| i.get("cwd")).cloned().unwrap_or_else(|| json!(cwd)),
        "gitBranch": fields.git_branch,
        "turns": info.and_then(|i| i.get("turns")).cloned(),
        "messages": info.and_then(|i| i.get("context")).and_then(|c| c.get("messageCount")).cloned(),
        "outputTokensPerSecond": info.and_then(|i| i.get("outputTokensPerSecond")).cloned(),
        "usage": {
            "inputTokens": totals.input_tokens,
            "outputTokens": totals.output_tokens,
            "cachedTokens": totals.cached_tokens,
            "reasoningTokens": totals.reasoning_tokens,
            "costUsd": totals.cost_usd,
        },
        "context": { "used": totals.context_tokens, "window": totals.context_window },
    })
}

fn permission_response(outcome: Value) -> acp::RequestPermissionResponse {
    serde_json::from_value(json!({ "outcome": outcome })).unwrap_or_else(|_| {
        serde_json::from_value(json!({ "outcome": { "outcome": "cancelled" } }))
            .expect("a cancelled permission response")
    })
}

fn cancelled() -> acp::RequestPermissionResponse {
    permission_response(json!({ "outcome": "cancelled" }))
}

fn selected(option_id: &str) -> acp::RequestPermissionResponse {
    permission_response(json!({ "outcome": "selected", "optionId": option_id }))
}

/// What a permission request asks, for the relay: the tool call's title, kind and command or path, and the choices.
fn pending_interaction(request: &acp::RequestPermissionRequest, number: u64) -> PendingInteraction {
    let value = serde_json::to_value(request).unwrap_or(Value::Null);
    let call = value.get("toolCall").cloned().unwrap_or(Value::Null);
    let text_content = call
        .get("content")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find_map(|item| {
                item.get("content")
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| {
                        item.get("path")
                            .and_then(Value::as_str)
                            .map(|p| format!("Edit {p}"))
                    })
            })
        });
    let raw = call.get("rawInput");
    let detail = raw
        .and_then(|r| r.get("command").or_else(|| r.get("cmd")))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            raw.and_then(|r| r.get("path").or_else(|| r.get("file_path")))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or(text_content);
    let title = call
        .get("title")
        .and_then(Value::as_str)
        .filter(|t| !t.trim().is_empty())
        .unwrap_or("Allow this?");
    let options = value
        .get("options")
        .and_then(Value::as_array)
        .map(|options| {
            options
                .iter()
                .filter_map(|o| {
                    Some(PendingOption {
                        option_id: o.get("optionId")?.as_str()?.to_string(),
                        name: o
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        kind: o
                            .get("kind")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    PendingInteraction {
        id: format!("{}#{number}", request.tool_call.tool_call_id),
        kind: "permission".into(),
        title: shorten(title, PENDING_TITLE_MAX),
        detail: detail.map(|d| shorten(&d, PENDING_DETAIL_MAX)),
        tool_kind: call.get("kind").and_then(Value::as_str).map(str::to_owned),
        options,
        at: now_ms(),
    }
}

/// A config option of `configOptions` by id (`model`, `reasoning_effort`).
fn config_option<'a>(options: &'a [Value], id: &str) -> Option<&'a Value> {
    options
        .iter()
        .find(|option| option.get("id").and_then(Value::as_str) == Some(id))
}

/// A model's thinking levels from its catalog meta (`supportsReasoningEffort`, `reasoningEfforts`), the way the TUI and
/// Crok Desktop read them, and the default one's id.
fn model_efforts(
    meta: Option<&serde_json::Map<String, Value>>,
) -> (Vec<EffortOption>, Option<String>) {
    let supported = meta
        .and_then(|m| m.get("supportsReasoningEffort"))
        .and_then(Value::as_bool)
        == Some(true);
    if !supported {
        return (Vec::new(), None);
    }
    let mut default = None;
    let mut efforts: Vec<EffortOption> = meta
        .and_then(|m| m.get("reasoningEfforts"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let value = item
                .get("value")
                .and_then(Value::as_str)
                .or_else(|| item.as_str())?
                .to_string();
            let id = item
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or(&value)
                .to_string();
            if item.get("default").and_then(Value::as_bool) == Some(true) {
                default = Some(id.clone());
            }
            Some(EffortOption {
                name: item
                    .get("label")
                    .and_then(Value::as_str)
                    .filter(|l| !l.is_empty())
                    .map(str::to_owned)
                    .unwrap_or_else(|| effort_label(&value)),
                description: item
                    .get("description")
                    .and_then(Value::as_str)
                    .filter(|d| !d.is_empty())
                    .map(str::to_owned),
                value: Some(value),
                id,
            })
        })
        .collect();
    if efforts.is_empty() {
        // Supported without a list: the agent's built-in menu.
        efforts = crate::agent::session_config::legacy_session_effort_options()
            .into_iter()
            .map(|option| EffortOption {
                name: option.label,
                description: option.description,
                value: Some(option.value.as_ref().to_string()),
                id: option.id,
            })
            .collect();
    }
    (efforts, default)
}

fn effort_label(value: &str) -> String {
    match value {
        "xhigh" => "Extra high".to_string(),
        other => {
            let mut chars = other.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect())
                .unwrap_or_default()
        }
    }
}

/// Every model this process can run, with the thinking levels each offers — what the session pickers show here.
fn model_catalog(agent: &MvpAgent) -> Vec<ModelOption> {
    agent
        .model_state(None)
        .available_models
        .iter()
        .map(|model| {
            let id = model.model_id.0.to_string();
            let (efforts, listed_default) = model_efforts(model.meta.as_ref());
            let default_effort = listed_default.or_else(|| {
                let level = agent
                    .models_manager
                    .model_default_reasoning_effort(&id)?
                    .as_ref()
                    .to_string();
                efforts
                    .iter()
                    .find(|e| e.value.as_deref() == Some(level.as_str()))
                    .map(|e| e.id.clone())
            });
            ModelOption {
                name: if model.name.is_empty() {
                    id.clone()
                } else {
                    model.name.clone()
                },
                description: model.description.clone().filter(|d| !d.is_empty()),
                efforts,
                default_effort,
                id,
            }
        })
        .collect()
}

/// Applies the model and thinking level chosen for a session started from another device, before its first prompt.
async fn apply_start_setup(
    agent: &MvpAgent,
    session_id: &str,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<(), String> {
    let model = model
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .map(str::to_owned);
    if let Some(model) = model.as_deref() {
        set_config_option(agent, session_id, "model", model).await?;
    }
    let Some(effort) = effort.map(str::trim).filter(|e| !e.is_empty()) else {
        return Ok(());
    };
    let current = model.unwrap_or_else(|| {
        agent
            .model_state(Some(&acp::SessionId::new(session_id)))
            .current_model_id
            .0
            .to_string()
    });
    let id = effort_option_id(&model_catalog(agent), &current, effort);
    set_config_option(agent, session_id, "reasoning_effort", &id).await
}

async fn set_config_option(
    agent: &MvpAgent,
    session_id: &str,
    config_id: &str,
    value: &str,
) -> Result<(), String> {
    let request = json!({
        "sessionId": session_id,
        "configId": config_id,
        "value": value,
    });
    let request = serde_json::from_value::<acp::SetSessionConfigOptionRequest>(request)
        .map_err(|error| error.to_string())?;
    agent
        .set_session_config_option(request)
        .await
        .map(|_| ())
        .map_err(|error| error.message.to_string())
}

/// The option id of a thinking level of `model`, named by its id or by the level it stands for (`high`).
fn effort_option_id(models: &[ModelOption], model: &str, wanted: &str) -> String {
    models
        .iter()
        .find(|m| m.id == model)
        .and_then(|m| {
            m.efforts
                .iter()
                .find(|e| e.id == wanted || e.value.as_deref() == Some(wanted))
        })
        .map(|e| e.id.clone())
        .unwrap_or_else(|| wanted.to_string())
}

/// The model and thinking level a `configOptions` list says are selected.
fn selected_config(options: &[Value]) -> (Option<String>, Option<String>) {
    let current = |id: &str| {
        config_option(options, id)
            .and_then(|option| option.get("currentValue"))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    (current("model"), current("reasoning_effort"))
}

/// ACP `AvailableCommand`s as the relay lists them: name, description, input hint.
fn slash_commands(commands: &[Value]) -> Vec<SlashCommand> {
    commands
        .iter()
        .filter_map(|command| {
            let name = command
                .get("name")
                .and_then(Value::as_str)?
                .trim_start_matches('/')
                .to_string();
            if name.is_empty() {
                return None;
            }
            Some(SlashCommand {
                name,
                description: command
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                hint: command
                    .get("input")
                    .and_then(|input| input.get("hint"))
                    .and_then(Value::as_str)
                    .filter(|hint| !hint.is_empty())
                    .map(str::to_owned),
            })
        })
        .collect()
}

fn status_from_activity(activity: &str) -> Option<SessionStatus> {
    match activity {
        "working" => Some(SessionStatus::Running),
        "needs_input" => Some(SessionStatus::Waiting),
        "idle" | "completed" | "dormant" => Some(SessionStatus::Idle),
        "dead" => Some(SessionStatus::Error),
        _ => None,
    }
}

/// The last `turns` user turns of a session, read from disk (`updates.jsonl`; the session need not be loaded), as
/// transcript items and the list's preview. `skip_prompt` leaves out the turn that is running now.
async fn read_transcript(
    agent: &MvpAgent,
    session_id: &str,
    cwd: &str,
    turns: usize,
    skip_prompt: Option<&str>,
    prefix: String,
) -> (Vec<EventInput>, Option<(EventKind, String)>) {
    let response = ext_json(
        agent,
        "x.ai/session/updates",
        json!({ "sessionId": session_id, "cwd": cwd, "turnIndex": turns }),
    )
    .await;
    let mut transcript = Transcript::new(prefix, true);
    let updates = response
        .as_ref()
        .and_then(|r| r.get("updates"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for update in &updates {
        let method = update.get("method").and_then(Value::as_str).unwrap_or("");
        let Some(params) = update.get("params") else {
            continue;
        };
        let prompt_id = params
            .get("_meta")
            .and_then(|m| m.get("promptId"))
            .and_then(Value::as_str);
        if skip_prompt.is_some() && prompt_id == skip_prompt {
            continue;
        }
        let at = update
            .get("timestamp")
            .and_then(Value::as_f64)
            .unwrap_or(0.0)
            * 1000.0;
        transcript.apply(method, params, at);
    }
    transcript.close_text();
    (transcript.take_dirty(), transcript.preview())
}

async fn git_branch(cwd: String) -> Option<String> {
    let output = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::process::Command::new("git")
            .args(["-C", &cwd, "rev-parse", "--abbrev-ref", "HEAD"])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!branch.is_empty() && branch != "HEAD").then_some(branch)
}

impl Bridge {
    pub(crate) fn new(
        agent: Weak<MvpAgent>,
        app: HostApp,
        observer: Observer,
        rx: mpsc::UnboundedReceiver<Observed>,
    ) -> Bridge {
        let (internal_tx, internal_rx) = mpsc::unbounded_channel();
        let generation = uuid::Uuid::new_v4().simple().to_string()[..6].to_string();
        Bridge {
            agent,
            app,
            observer,
            rx,
            internal_tx,
            internal_rx,
            link: None,
            link_rx: None,
            credentials: None,
            seen: None,
            reported: None,
            mirrors: HashMap::new(),
            handled: HashSet::new(),
            watched: HashMap::new(),
            generation,
            activations: 0,
            project_of: HashMap::new(),
            catalog_busy: false,
            interactions: 0,
            sent_models: None,
        }
    }

    fn prefix(&self) -> String {
        format!("{}{}-", self.generation, self.activations)
    }

    pub(crate) async fn run(mut self, mut stop: oneshot::Receiver<oneshot::Sender<()>>) {
        self.check_settings();
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut ticks = 0u32;
        loop {
            tokio::select! {
                done = &mut stop => {
                    if let Some(link) = self.link.take() {
                        let finished = link.stop();
                        let _ = tokio::time::timeout(Duration::from_secs(2), finished).await;
                    }
                    if let Ok(done) = done {
                        let _ = done.send(());
                    }
                    return;
                }
                observed = self.rx.recv() => match observed {
                    Some(observed) => self.on_observed(observed),
                    None => return,
                },
                Some(internal) = self.internal_rx.recv() => self.on_internal(internal),
                message = recv_opt(&mut self.link_rx) => match message {
                    Some(Some(message)) => self.on_relay(message),
                    _ => self.deactivate(),
                },
                _ = tick.tick() => {
                    ticks = ticks.wrapping_add(1);
                    if ticks.is_multiple_of(SETTINGS_CHECK_TICKS) {
                        self.check_settings();
                    }
                    if ticks.is_multiple_of(CATALOG_TICKS) {
                        self.offer_catalog();
                    }
                    if ticks.is_multiple_of(RELEASE_CHECK_TICKS) {
                        self.release_idle();
                    }
                    if ticks.is_multiple_of(MODELS_CHECK_TICKS) {
                        self.refresh_models();
                    }
                    self.observer.viewer().tick();
                    self.flush();
                }
            }
        }
    }

    fn report(&mut self, state: &'static str) {
        if self.reported == Some(state) {
            return;
        }
        self.reported = Some(state);
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let params = json!({
            "state": state,
            "account": self.credentials.as_ref().map(|c| c.account.display()),
            "device": self.credentials.as_ref().map(|c| c.device_name.clone()),
            "server": self.credentials.as_ref().map(|c| c.server.clone()),
        });
        agent
            .gateway
            .forward_fire_and_forget(acp::ExtNotification::new(
                REMOTE_STATUS_METHOD,
                raw(&params),
            ));
    }

    /// Signs the bridge in or out when `credentials.json` or `[remote] enabled` changed.
    fn check_settings(&mut self) {
        let enabled = crok_remote::settings::load().enabled;
        let current = (credentials::modified(), enabled);
        if self.seen == Some(current) {
            return;
        }
        self.seen = Some(current);
        let credentials = if enabled {
            credentials::load().ok().flatten()
        } else {
            None
        };
        match (credentials, &self.credentials) {
            (Some(new), Some(old))
                if new.device_id == old.device_id && new.server == old.server => {}
            (Some(new), _) => {
                self.deactivate();
                self.activate(new);
            }
            (None, Some(_)) => {
                self.deactivate();
                self.credentials = None;
                self.report("off");
            }
            (None, None) => self.report("off"),
        }
    }

    fn activate(&mut self, credentials: Credentials) {
        let config = LinkConfig {
            credentials: credentials.clone(),
            app: self.app,
            app_version: xai_grok_version::full_version().to_string(),
            can_adopt: true,
        };
        let (link, link_rx) = match Link::spawn(config) {
            Ok(pair) => pair,
            Err(error) => {
                tracing::warn!(%error, "remote control: cannot start the link");
                return;
            }
        };
        self.activations += 1;
        self.observer
            .viewer()
            .set_link(Some(link.sender()), Some(credentials.device_id.clone()));
        self.credentials = Some(credentials);
        self.link = Some(link);
        self.link_rx = Some(link_rx);
        self.observer.set_live(true);
        self.report("connecting");
        let prefix = self.prefix();
        let agent = self.agent.upgrade();
        let resident: HashSet<String> = agent
            .as_ref()
            .map(|agent| {
                agent
                    .resident_ids()
                    .into_iter()
                    .map(|id| id.0.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let ids: Vec<String> = self.mirrors.keys().cloned().collect();
        for id in ids {
            let Some(mirror) = self.mirrors.get_mut(&id) else {
                continue;
            };
            mirror.transcript = Transcript::new(prefix.clone(), false);
            // What the agent says now, not what was seen while signed out.
            let running = agent
                .as_ref()
                .and_then(|agent| agent.resident_handle(&acp::SessionId::new(id.as_str())))
                .and_then(|handle| {
                    handle
                        .current_prompt_id
                        .lock()
                        .ok()
                        .and_then(|current| current.clone())
                });
            mirror.turn_running = running.is_some();
            mirror.set_status(if running.is_some() {
                SessionStatus::Running
            } else {
                SessionStatus::Idle
            });
            mirror.live_prompt_id = running;
            if mirror.worth_mirroring() && resident.contains(&id) {
                // Signed in after the session started: it has history the relay has not seen.
                mirror.loaded = true;
                self.register(&id);
            }
        }
        self.fetch_roster();
        self.catalog_busy = false;
        self.offer_catalog();
        self.sent_models = None;
        self.refresh_models();
    }

    /// Tells the relay which models this process can run, with their thinking levels, when that changed.
    fn refresh_models(&mut self) {
        if !self.active() {
            return;
        }
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let models = model_catalog(&agent);
        if models.is_empty() || self.sent_models.as_ref() == Some(&models) {
            return;
        }
        self.sent_models = Some(models.clone());
        self.send(ToRelay::SetModels { models });
    }

    /// Offers to list every session on this computer's disk; the relay lets one crok process per computer do it, at
    /// most every 10 minutes. The listing runs only when granted.
    fn offer_catalog(&mut self) {
        if !self.active() || self.catalog_busy {
            return;
        }
        self.catalog_busy = true;
        let (reply, granted) = oneshot::channel();
        self.send(ToRelay::BeginCatalog { reply });
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let upload = match granted.await.ok().flatten() {
                Some(sync_id) => super::catalog::list()
                    .await
                    .map(|entries| (sync_id, entries)),
                None => None,
            };
            let _ = tx.send(Internal::Catalog { upload });
        });
    }

    fn deactivate(&mut self) {
        self.link = None;
        self.link_rx = None;
        self.observer.set_live(false);
        self.observer.viewer().set_link(None, None);
        self.watched.clear();
        self.handled.clear();
        for (session_id, mirror) in &mut self.mirrors {
            self.observer.set_shared(session_id, false);
            mirror.requested = false;
            mirror.registered = false;
            mirror.backfill_pending = false;
            mirror.sent = SessionFields::default();
            mirror.sent_commands = None;
            mirror.remote_running = None;
            mirror.queue.clear();
            // Nobody can answer from elsewhere now: the front end's own answer (if it was asked) still counts.
            if let Some(permission) = mirror.permission.as_mut() {
                permission.remote = None;
            }
            let _ = mirror.transcript.take_dirty();
        }
        if self.credentials.is_some() {
            self.report("connecting");
        }
    }

    fn send(&self, message: ToRelay) {
        if let Some(link) = &self.link {
            link.send(message);
        }
    }

    fn active(&self) -> bool {
        self.link.is_some()
    }

    /// Creates the session's mirror on the relay. History follows once it is registered.
    fn register(&mut self, session_id: &str) {
        if !self.active() {
            return;
        }
        let Some(mirror) = self.mirrors.get_mut(session_id) else {
            return;
        };
        if mirror.requested {
            return;
        }
        mirror.requested = true;
        mirror.backfill_pending = mirror.loaded;
        if mirror.desired.title.is_none() {
            mirror.desired.title = Some(String::new());
        }
        // The project the last catalog put it in; a new session's is guessed by the relay until the next catalog.
        if mirror.desired.project_path.is_none() {
            mirror.desired.project_path = self.project_of.get(session_id).cloned();
        }
        let mut fields = mirror.desired.clone();
        if fields.title.as_deref() == Some("") {
            fields.title = None;
        }
        mirror.sent = fields.clone();
        let cwd = mirror.cwd.clone();
        self.send(ToRelay::UpsertSession {
            session_id: session_id.to_string(),
            fields: Box::new(fields),
        });
        let tx = self.internal_tx.clone();
        let id = session_id.to_string();
        tokio::task::spawn_local(async move {
            if let Some(branch) = git_branch(cwd).await {
                let _ = tx.send(Internal::Fields {
                    session_id: id,
                    fields: SessionFields {
                        git_branch: Some(branch),
                        ..SessionFields::default()
                    },
                    real_title: false,
                });
            }
        });
    }

    /// Titles, models and efforts from the agent's roster (titles of resumed sessions come from disk).
    fn fetch_roster(&self) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let tx = self.internal_tx.clone();
        let wanted: HashSet<String> = self.mirrors.keys().cloned().collect();
        tokio::task::spawn_local(async move {
            for entry in agent.build_roster().await {
                if !wanted.contains(&entry.session_id) || !entry.resident {
                    continue;
                }
                let real_title = entry.title.as_deref().is_some_and(|t| !t.trim().is_empty());
                let _ = tx.send(Internal::Fields {
                    session_id: entry.session_id,
                    fields: SessionFields {
                        title: entry.title.filter(|t| !t.trim().is_empty()),
                        model: entry.model_id,
                        effort: entry
                            .reasoning_effort
                            .and_then(|e| serde_json::to_value(e).ok())
                            .and_then(|v| v.as_str().map(str::to_owned)),
                        ..SessionFields::default()
                    },
                    real_title,
                });
            }
        });
    }

    fn on_observed(&mut self, observed: Observed) {
        match observed {
            Observed::SessionOpened {
                session_id,
                cwd,
                loaded,
            } => {
                let prefix = self.prefix();
                let mirror = self
                    .mirrors
                    .entry(session_id.clone())
                    .or_insert_with(|| Mirror::new(cwd, &prefix));
                mirror.loaded |= loaded;
                // The person opened here a session the bridge was running for someone else: it is theirs now.
                mirror.adopted = false;
                mirror.idle_since = None;
                if loaded && self.active() {
                    self.register(&session_id);
                    self.fetch_roster();
                }
            }
            Observed::PromptSent {
                session_id,
                prompt_id,
                text,
            } => {
                let prefix = self.prefix();
                let active = self.active();
                let cwd = self
                    .agent
                    .upgrade()
                    .and_then(|agent| {
                        agent.resident_handle(&acp::SessionId::new(session_id.as_str()))
                    })
                    .map(|handle| handle.info.cwd.clone())
                    .unwrap_or_default();
                let mirror = self
                    .mirrors
                    .entry(session_id.clone())
                    .or_insert_with(|| Mirror::new(cwd, &prefix));
                mirror.had_prompt = true;
                mirror.turn_running = true;
                mirror.live_prompt_id = prompt_id;
                mirror.set_status(SessionStatus::Running);
                mirror.title_from_prompt(&text);
                if active {
                    mirror
                        .transcript
                        .user_prompt(&text, "local", None, None, now_ms());
                    mirror.boundary = true;
                    self.register(&session_id);
                }
            }
            Observed::SessionClosed { session_id } => {
                self.observer.set_shared(&session_id, false);
                if let Some(mirror) = self.mirrors.remove(&session_id)
                    && mirror.requested
                {
                    self.send(ToRelay::CloseSession { session_id });
                }
            }
            Observed::Outgoing { method, params } => self.on_outgoing(&method, &params),
            Observed::Permission(ask) => self.on_permission(*ask),
        }
    }

    /// A permission request from a mirrored or adopted session: offered on the relay to every device, while the front
    /// end (for a session it shows) asks on the computer too. The first answer goes to the agent.
    fn on_permission(&mut self, ask: PermissionAsk) {
        let PermissionAsk {
            session_id,
            request,
            reply,
            front_end,
        } = ask;
        let registered = self.mirrors.get(&session_id).is_some_and(|m| m.registered);
        if !self.active() || !registered {
            // Nobody else can answer: the front end decides, or (an adopted session) the request is turned down.
            tokio::task::spawn_local(async move {
                let answer = match front_end {
                    Some(front_end) => front_end.await.unwrap_or_else(|_| Ok(cancelled())),
                    None => Ok(cancelled()),
                };
                let _ = reply.send(answer);
            });
            return;
        }
        self.interactions += 1;
        let pending = pending_interaction(&request, self.interactions);
        let id = pending.id.clone();
        let (remote_tx, remote_rx) = oneshot::channel::<String>();
        if let Some(mirror) = self.mirrors.get_mut(&session_id) {
            mirror.permission = Some(PendingPermission {
                id: id.clone(),
                tool_call_id: request.tool_call.tool_call_id.to_string(),
                remote: Some(remote_tx),
                visible: front_end.is_some(),
            });
            mirror.set_status(SessionStatus::Waiting);
        }
        self.send(ToRelay::SetPending {
            session_id: session_id.clone(),
            pending: Some(pending),
        });
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let mut reply = reply;
            let mut front_end = front_end;
            let mut remote = Some(remote_rx);
            enum Heard {
                FrontEnd(Option<xai_acp_lib::AcpResult<acp::RequestPermissionResponse>>),
                Remote(Option<String>),
                Gone,
            }
            let (answer, by_remote) = loop {
                let heard = {
                    let from_front_end = async {
                        match front_end.as_mut() {
                            Some(front_end) => front_end.await.ok(),
                            None => std::future::pending().await,
                        }
                    };
                    let from_remote = async {
                        match remote.as_mut() {
                            Some(remote) => remote.await.ok(),
                            None => std::future::pending().await,
                        }
                    };
                    tokio::select! {
                        answer = from_front_end => Heard::FrontEnd(answer),
                        option = from_remote => Heard::Remote(option),
                        _ = reply.closed() => Heard::Gone,
                    }
                };
                match heard {
                    Heard::FrontEnd(Some(answer)) => break (Some(answer), false),
                    // The front end let go without answering: only another device can.
                    Heard::FrontEnd(None) => front_end = None,
                    Heard::Remote(Some(option)) => break (Some(Ok(selected(&option))), true),
                    // Signed out: only the front end can answer now.
                    Heard::Remote(None) => remote = None,
                    Heard::Gone => break (None, false),
                }
                if front_end.is_none() && remote.is_none() {
                    break (Some(Ok(cancelled())), false);
                }
            };
            if let Some(answer) = answer {
                let _ = reply.send(answer);
            }
            let _ = tx.send(Internal::PermissionSettled {
                session_id,
                id,
                by_remote,
            });
        });
    }

    fn on_outgoing(&mut self, method: &str, params: &Value) {
        if method == super::PROMPT_COMPLETE_METHOD {
            self.on_prompt_complete(params);
            return;
        }
        if !self.active() {
            return;
        }
        if method == crate::agent::roster::SESSIONS_CHANGED_METHOD {
            self.on_roster_changed(params);
            return;
        }
        let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else {
            return;
        };
        let Some(mirror) = self.mirrors.get_mut(session_id) else {
            return;
        };
        let update_kind = params
            .get("update")
            .and_then(|u| u.get("sessionUpdate"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if update_kind == "available_commands_update" {
            let commands = params
                .get("update")
                .and_then(|u| u.get("availableCommands"))
                .and_then(Value::as_array)
                .map(|commands| slash_commands(commands))
                .unwrap_or_default();
            mirror.commands = Some(commands);
            return;
        }
        let activity = matches!(
            update_kind,
            "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update"
        );
        if activity && !mirror.turn_running {
            // A turn the front end did not start (a background task finishing, a scheduled prompt).
            mirror.turn_running = true;
            mirror.set_status(SessionStatus::Running);
            if !mirror.requested && mirror.worth_mirroring() {
                let id = session_id.to_string();
                self.register(&id);
            }
        }
        let Some(mirror) = self.mirrors.get_mut(session_id) else {
            return;
        };
        if !mirror.requested {
            return;
        }
        let (signals, boundary) = mirror.transcript.apply(method, params, now_ms());
        mirror.boundary |= boundary;
        let mut finished_remote = None;
        let mut turn_done = false;
        for signal in signals {
            match signal {
                Signal::Plan(plan) => mirror.desired.plan = Some(plan),
                Signal::Title(title) => {
                    mirror.has_real_title = true;
                    mirror.desired.title = Some(title);
                }
                Signal::Model(model) => mirror.desired.model = Some(model),
                Signal::NeedsInput => mirror.set_status(SessionStatus::Waiting),
                Signal::InputResolved => {
                    if mirror.turn_running {
                        mirror.set_status(SessionStatus::Running);
                    }
                }
                Signal::TurnCompleted {
                    prompt_id,
                    stop_reason,
                } => {
                    // The end of an earlier turn (its `prompt_complete` already ended it, and the next one started).
                    if let (Some(ended), Some(live)) =
                        (prompt_id.as_deref(), mirror.live_prompt_id.as_deref())
                        && ended != live
                    {
                        continue;
                    }
                    if !mirror.turn_running {
                        continue;
                    }
                    mirror.turn_running = false;
                    mirror.live_prompt_id = None;
                    mirror.set_status(SessionStatus::Idle);
                    mirror.boundary = true;
                    turn_done = true;
                    if let Some(command_id) = mirror.remote_running.take() {
                        finished_remote = Some((command_id, stop_reason));
                    }
                }
            }
        }
        let id = session_id.to_string();
        if let Some((command_id, _)) = finished_remote {
            self.complete(&command_id, CommandOutcome::Done, None, None);
        }
        if turn_done {
            self.refresh_usage(&id);
            self.run_next(&id);
        }
    }

    /// `x.ai/session/prompt_complete`: a turn ended. Seen even while signed out, so turn state is right at sign-in.
    fn on_prompt_complete(&mut self, params: &Value) {
        let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else {
            return;
        };
        let prompt_id = params.get("promptId").and_then(Value::as_str);
        let Some(mirror) = self.mirrors.get_mut(session_id) else {
            return;
        };
        if !mirror.turn_running {
            return;
        }
        if let (Some(ended), Some(live)) = (prompt_id, mirror.live_prompt_id.as_deref())
            && ended != live
        {
            return;
        }
        mirror.turn_running = false;
        mirror.live_prompt_id = None;
        mirror.set_status(SessionStatus::Idle);
        mirror.boundary = true;
        let finished = mirror.remote_running.take();
        let id = session_id.to_string();
        if let Some(command_id) = finished {
            self.complete(&command_id, CommandOutcome::Done, None, None);
        }
        if self.active() {
            self.refresh_usage(&id);
            self.run_next(&id);
        }
    }

    fn on_roster_changed(&mut self, params: &Value) {
        if let Some(upserted) = params.get("upserted").and_then(Value::as_array) {
            for entry in upserted {
                let Some(id) = entry.get("sessionId").and_then(Value::as_str) else {
                    continue;
                };
                let Some(mirror) = self.mirrors.get_mut(id) else {
                    continue;
                };
                if let Some(title) = entry
                    .get("title")
                    .and_then(Value::as_str)
                    .filter(|t| !t.trim().is_empty())
                {
                    mirror.has_real_title = true;
                    mirror.desired.title = Some(title.to_string());
                }
                if let Some(model) = entry.get("modelId").and_then(Value::as_str) {
                    mirror.desired.model = Some(model.to_string());
                }
                if let Some(effort) = entry.get("reasoningEffort").and_then(Value::as_str) {
                    mirror.desired.effort = Some(effort.to_string());
                }
                if let Some(cwd) = entry
                    .get("cwd")
                    .and_then(Value::as_str)
                    .filter(|c| !c.is_empty())
                {
                    mirror.desired.cwd = Some(cwd.to_string());
                }
                if let Some(status) = entry
                    .get("activity")
                    .and_then(Value::as_str)
                    .and_then(status_from_activity)
                {
                    // A remote prompt waiting for its turn keeps the session busy.
                    if !(status == SessionStatus::Idle && mirror.remote_running.is_some()) {
                        mirror.set_status(status);
                    }
                }
            }
        }
        if let Some(removed) = params.get("removed").and_then(Value::as_array) {
            for id in removed.iter().filter_map(Value::as_str) {
                if let Some(mirror) = self.mirrors.get_mut(id)
                    && mirror.requested
                {
                    mirror.requested = false;
                    mirror.registered = false;
                    let session_id = id.to_string();
                    self.send(ToRelay::CloseSession { session_id });
                }
            }
        }
    }

    fn on_relay(&mut self, message: FromRelay) {
        match message {
            FromRelay::State(LinkState::Connected) => self.report("connected"),
            FromRelay::State(LinkState::Connecting) => self.report("connecting"),
            FromRelay::Query { id, result } => {
                let viewer = self.observer.viewer().clone();
                viewer.on_query(id, result.map_err(|e| e.to_string()));
            }
            FromRelay::Registered { session_id, .. } => {
                let Some(mirror) = self.mirrors.get_mut(&session_id) else {
                    return;
                };
                mirror.registered = true;
                let backfill = mirror.backfill_pending;
                let knows_commands = mirror.commands.is_some();
                self.observer.set_shared(&session_id, true);
                if !knows_commands {
                    self.fetch_commands(&session_id);
                }
                // An adopted session's prompt waited for its mirror; it starts before the backfill reads the
                // transcript, so the backfill leaves it out.
                self.run_next(&session_id);
                if backfill {
                    self.backfill(&session_id);
                }
            }
            FromRelay::Inbox(inbox) => {
                let now = Instant::now();
                self.watched.clear();
                for view in inbox.views {
                    let ahead = (view.until - inbox.server_time).max(0.0);
                    self.watched
                        .insert(view.session_id, now + Duration::from_millis(ahead as u64));
                }
                if let Some(hosted) = inbox.hosted {
                    self.release_taken(&hosted.into_iter().collect());
                }
                for command in inbox.commands {
                    // A kind of command this crok does not know (a newer relay): another crok may.
                    if command.kind == CommandType::Unknown
                        || !self.handled.insert(command.id.clone())
                    {
                        continue;
                    }
                    // A transcript to read from disk needs no mirror here: any crok on this computer can serve it.
                    // Nor does a prompt for a session nobody runs: whoever claims it opens the session.
                    let history = command.kind == CommandType::History;
                    let adopt = (command.adopt && !self.mirrors.contains_key(&command.session_id))
                        || command.kind == CommandType::Create;
                    if !history
                        && !adopt
                        && !self
                            .mirrors
                            .get(&command.session_id)
                            .is_some_and(|m| m.registered)
                    {
                        self.handled.remove(&command.id);
                        continue;
                    }
                    let (reply, claimed) = oneshot::channel();
                    self.send(ToRelay::Claim {
                        command_id: command.id.clone(),
                        reply,
                    });
                    let tx = self.internal_tx.clone();
                    tokio::task::spawn_local(async move {
                        let claimed = claimed.await.unwrap_or(false);
                        let _ = tx.send(Internal::Claimed { command, claimed });
                    });
                }
            }
            FromRelay::SignedOut => {
                self.deactivate();
                self.credentials = None;
                self.seen = None;
                self.report("off");
            }
        }
    }

    fn on_internal(&mut self, internal: Internal) {
        match internal {
            Internal::Fields {
                session_id,
                fields,
                real_title,
            } => {
                if let Some(mirror) = self.mirrors.get_mut(&session_id) {
                    if real_title {
                        mirror.has_real_title = true;
                    } else if mirror.has_real_title {
                        let mut fields = fields;
                        fields.title = None;
                        mirror.desired.merge(fields);
                        return;
                    }
                    mirror.desired.merge(fields);
                }
            }
            Internal::Backfilled {
                session_id,
                events,
                preview,
            } => {
                let Some(mirror) = self.mirrors.get_mut(&session_id) else {
                    return;
                };
                if !mirror.backfill_pending {
                    return;
                }
                mirror.backfill_pending = false;
                if let Some((kind, text)) = preview {
                    mirror.desired.preview = Some(text);
                    mirror.desired.preview_kind = Some(kind);
                }
                mirror.boundary = true;
                self.send(ToRelay::PushEvents {
                    session_id,
                    events,
                    replace: true,
                });
            }
            Internal::Claimed { command, claimed } => {
                if claimed {
                    self.execute(command);
                }
            }
            Internal::Complete { command_id, result } => {
                self.complete(&command_id, CommandOutcome::Done, Some(result), None);
            }
            Internal::Catalog { upload } => {
                self.catalog_busy = false;
                let Some((sync_id, entries)) = upload else {
                    return;
                };
                self.project_of = entries
                    .iter()
                    .map(|e| (e.session_id.clone(), e.project_path.clone()))
                    .collect();
                // Sessions mirrored here follow the projects the catalog puts them in.
                for (session_id, mirror) in &mut self.mirrors {
                    if let Some(project) = self.project_of.get(session_id) {
                        mirror.desired.project_path = Some(project.clone());
                    }
                }
                self.send(ToRelay::Catalog { sync_id, entries });
            }
            Internal::History {
                command_id,
                session_doc_id,
                events,
                preview,
            } => {
                self.send(ToRelay::PushHistory {
                    session_doc_id,
                    command_id,
                    events,
                    preview,
                });
            }
            Internal::Opened { session_id, error } => self.on_opened(session_id, error),
            Internal::Created { command, result } => self.on_created(command, result),
            Internal::Bound {
                session_id,
                command,
                error,
            } => self.on_bound(session_id, command, error),
            Internal::ConfigApplied {
                session_id,
                command_id,
                result,
            } => self.on_config_applied(session_id, command_id, result),
            Internal::Commands {
                session_id,
                commands,
            } => {
                if let Some(mirror) = self.mirrors.get_mut(&session_id)
                    && mirror.commands.is_none()
                {
                    mirror.commands = Some(commands);
                }
            }
            Internal::PermissionSettled {
                session_id,
                id,
                by_remote,
            } => {
                let Some(mirror) = self.mirrors.get_mut(&session_id) else {
                    return;
                };
                if mirror.permission.as_ref().map(|p| p.id.as_str()) != Some(id.as_str()) {
                    return;
                }
                let Some(permission) = mirror.permission.take() else {
                    return;
                };
                if mirror.turn_running {
                    mirror.set_status(SessionStatus::Running);
                }
                self.send(ToRelay::SetPending {
                    session_id: session_id.clone(),
                    pending: None,
                });
                if by_remote && permission.visible {
                    // Answered on another device: the front end drops the prompt it still shows.
                    self.tell_front_end(
                        PERMISSION_RESOLVED_METHOD,
                        json!({ "sessionId": session_id, "toolCallId": permission.tool_call_id }),
                    );
                }
            }
            Internal::PromptReturned {
                session_id,
                command_id,
                error,
            } => {
                let Some(mirror) = self.mirrors.get_mut(&session_id) else {
                    return;
                };
                if mirror.remote_running.as_deref() != Some(command_id.as_str()) {
                    return;
                }
                // The turn ended without the usual turn-completed update (rejected, or failed early).
                mirror.remote_running = None;
                mirror.turn_running = false;
                mirror.set_status(SessionStatus::Idle);
                mirror.boundary = true;
                if let Some(error) = &error {
                    mirror
                        .transcript
                        .notice(EventKind::Error, error, Some("failed"), now_ms());
                }
                let outcome = if error.is_some() {
                    CommandOutcome::Failed
                } else {
                    CommandOutcome::Done
                };
                self.complete(&command_id, outcome, None, error);
                self.run_next(&session_id);
            }
        }
    }

    fn complete(
        &self,
        command_id: &str,
        outcome: CommandOutcome,
        result: Option<Value>,
        error: Option<String>,
    ) {
        self.send(ToRelay::Complete {
            command_id: command_id.to_string(),
            outcome,
            result,
            error,
        });
    }

    fn execute(&mut self, command: InboxCommand) {
        if command.kind == CommandType::History {
            self.read_history(command);
            return;
        }
        if command.kind == CommandType::Create {
            self.create(command);
            return;
        }
        let session_id = command.session_id.clone();
        if command.adopt && !self.mirrors.contains_key(&session_id) {
            self.adopt(command);
            return;
        }
        let Some(mirror) = self.mirrors.get_mut(&session_id) else {
            self.complete(
                &command.id,
                CommandOutcome::Failed,
                None,
                Some("This session is no longer open on the computer.".into()),
            );
            return;
        };
        match command.kind {
            CommandType::Prompt => {
                if mirror.turn_running
                    || mirror.remote_running.is_some()
                    || mirror.opening
                    || !mirror.registered
                {
                    // Delivered and waiting: it runs when the current turn ends (or the session is open).
                    mirror.queue.push_back(command);
                } else {
                    self.start_prompt(command);
                }
            }
            CommandType::Config => {
                if mirror.opening || !mirror.registered {
                    mirror.queue.push_back(command);
                } else {
                    self.apply_config(command);
                }
            }
            CommandType::Answer => {
                let answers_this = mirror
                    .permission
                    .as_ref()
                    .is_some_and(|p| command.interaction_id.as_deref() == Some(p.id.as_str()));
                let remote = answers_this
                    .then(|| mirror.permission.as_mut().and_then(|p| p.remote.take()))
                    .flatten();
                match remote {
                    Some(remote) => {
                        let _ = remote.send(command.text.clone().unwrap_or_default());
                        self.complete(&command.id, CommandOutcome::Done, None, None);
                    }
                    None => self.complete(
                        &command.id,
                        CommandOutcome::Failed,
                        None,
                        Some("That request was already answered.".into()),
                    ),
                }
            }
            CommandType::Cancel => {
                let dropped: Vec<String> = mirror.queue.drain(..).map(|c| c.id).collect();
                for id in dropped {
                    self.complete(
                        &id,
                        CommandOutcome::Failed,
                        None,
                        Some("Stopped before it ran.".into()),
                    );
                }
                if let Some(agent) = self.agent.upgrade() {
                    let sid = session_id.clone();
                    tokio::task::spawn_local(async move {
                        let _ = agent.cancel(acp::CancelNotification::new(sid)).await;
                    });
                }
                self.complete(&command.id, CommandOutcome::Done, None, None);
            }
            CommandType::Info => {
                let Some(agent) = self.agent.upgrade() else {
                    return;
                };
                let fields = mirror.desired.clone();
                let cwd = mirror.cwd.clone();
                let command_id = command.id.clone();
                let tx = self.internal_tx.clone();
                tokio::task::spawn_local(async move {
                    let info = ext_json(
                        &agent,
                        "x.ai/session/info",
                        json!({ "sessionId": session_id }),
                    )
                    .await;
                    let usage = ext_json(
                        &agent,
                        "x.ai/session/usage",
                        json!({ "sessionId": session_id }),
                    )
                    .await;
                    let result =
                        info_result(&session_id, &cwd, &fields, info.as_ref(), usage.as_ref());
                    let _ = tx.send(Internal::Complete { command_id, result });
                });
            }
            CommandType::History | CommandType::Create | CommandType::Unknown => {}
        }
    }

    /// A new session asked for from another device: open it here, hidden from the front end, then give the relay its id.
    fn create(&mut self, command: InboxCommand) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let observer = self.observer.clone();
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let cwd = command.cwd.clone().unwrap_or_default();
            let folder = std::path::PathBuf::from(&cwd);
            let result = if cwd.is_empty() || !folder.is_absolute() {
                Err("The folder is unknown.".to_string())
            } else if !folder.is_dir() {
                Err(format!("{cwd} is not a folder on this computer."))
            } else {
                match agent.new_session(acp::NewSessionRequest::new(folder)).await {
                    Ok(response) => {
                        let session_id = response.session_id.to_string();
                        observer.hide(&session_id);
                        // The model and thinking level picked where the session was started apply before its first
                        // prompt, as if they had been chosen here.
                        match apply_start_setup(
                            &agent,
                            &session_id,
                            command.model.as_deref(),
                            command.effort.as_deref(),
                        )
                        .await
                        {
                            Ok(()) => Ok(session_id),
                            Err(error) => {
                                let _ = agent
                                    .close_session(acp::CloseSessionRequest::new(
                                        session_id.clone(),
                                    ))
                                    .await;
                                Err(format!(
                                    "The computer could not set its model or thinking level: {error}"
                                ))
                            }
                        }
                    }
                    Err(error) => Err(error.message.to_string()),
                }
            };
            let _ = tx.send(Internal::Created { command, result });
        });
    }

    fn on_created(&mut self, command: InboxCommand, result: Result<String, String>) {
        let session_id = match result {
            Ok(session_id) => session_id,
            Err(error) => {
                tracing::warn!(%error, "remote control: cannot start a session asked for from another device");
                self.complete(
                    &command.id,
                    CommandOutcome::Failed,
                    None,
                    Some(format!(
                        "The computer could not start this session: {error}"
                    )),
                );
                return;
            }
        };
        tracing::info!(%session_id, "remote control: started a session asked for from another device");
        let prefix = self.prefix();
        let mut mirror = Mirror::new(command.cwd.clone().unwrap_or_default(), &prefix);
        mirror.adopted = true;
        mirror.opening = true;
        mirror.had_prompt = true;
        self.mirrors.insert(session_id.clone(), mirror);
        let (reply, bound) = oneshot::channel();
        self.send(ToRelay::BindSession {
            session_doc_id: command.session_doc_id.clone(),
            session_id: session_id.clone(),
            reply,
        });
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let error = match bound.await {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error),
                Err(_) => Some("The relay connection closed.".to_string()),
            };
            let _ = tx.send(Internal::Bound {
                session_id,
                command,
                error,
            });
        });
    }

    fn on_bound(&mut self, session_id: String, mut command: InboxCommand, error: Option<String>) {
        if let Some(error) = error {
            self.complete(&command.id, CommandOutcome::Failed, None, Some(error));
            self.release(&session_id, false);
            return;
        }
        let Some(mirror) = self.mirrors.get_mut(&session_id) else {
            return;
        };
        mirror.opening = false;
        // The command still names the relay's placeholder id.
        command.session_id = session_id.clone();
        if command
            .text
            .as_deref()
            .is_some_and(|t| !t.trim().is_empty())
        {
            // Its first prompt runs once the mirror is registered.
            mirror.set_status(SessionStatus::Running);
            mirror.queue.push_back(command);
        } else {
            mirror.idle_since = Some(Instant::now());
            self.complete(
                &command.id,
                CommandOutcome::Done,
                Some(json!({ "sessionId": session_id })),
                None,
            );
        }
        self.register(&session_id);
        self.fetch_roster();
    }

    /// Sets the session's model or thinking level, as the front end's pickers do.
    fn apply_config(&mut self, command: InboxCommand) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let session_id = command.session_id.clone();
        if let Some(mirror) = self.mirrors.get_mut(&session_id) {
            mirror.idle_since = None;
        }
        let request = json!({
            "sessionId": session_id,
            "configId": command.config_id.clone().unwrap_or_default(),
            "value": command.text.clone().unwrap_or_default(),
        });
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let result = match serde_json::from_value::<acp::SetSessionConfigOptionRequest>(request)
            {
                Err(error) => Err(error.to_string()),
                Ok(request) => match agent.set_session_config_option(request).await {
                    Ok(response) => {
                        let options: Vec<Value> = response
                            .config_options
                            .iter()
                            .filter_map(|option| serde_json::to_value(option).ok())
                            .collect();
                        Ok(selected_config(&options))
                    }
                    Err(error) => Err(error.message.to_string()),
                },
            };
            let _ = tx.send(Internal::ConfigApplied {
                session_id,
                command_id: command.id,
                result,
            });
        });
    }

    fn on_config_applied(
        &mut self,
        session_id: String,
        command_id: String,
        result: Result<(Option<String>, Option<String>), String>,
    ) {
        match result {
            Ok((model, effort)) => {
                // The config option names the level by its option id; sessions report the level itself.
                let effort = effort.map(|id| {
                    self.sent_models
                        .iter()
                        .flatten()
                        .filter(|m| model.as_deref().is_none_or(|current| m.id == current))
                        .flat_map(|m| m.efforts.iter())
                        .find(|e| e.id == id)
                        .and_then(|e| e.value.clone())
                        .unwrap_or(id)
                });
                if let Some(mirror) = self.mirrors.get_mut(&session_id) {
                    if model.is_some() {
                        mirror.desired.model = model.clone();
                    }
                    if effort.is_some() {
                        mirror.desired.effort = effort.clone();
                    }
                }
                self.complete(
                    &command_id,
                    CommandOutcome::Done,
                    Some(json!({ "model": model, "effort": effort })),
                    None,
                );
                self.refresh_models();
                self.fetch_roster();
            }
            Err(error) => self.complete(&command_id, CommandOutcome::Failed, None, Some(error)),
        }
        self.run_next(&session_id);
    }

    /// The session's slash commands, for a mirror that has not seen the agent advertise them.
    fn fetch_commands(&self, session_id: &str) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let tx = self.internal_tx.clone();
        let session_id = session_id.to_string();
        tokio::task::spawn_local(async move {
            let Some(response) = ext_json(
                &agent,
                "x.ai/commands/list",
                json!({ "sessionId": session_id }),
            )
            .await
            else {
                return;
            };
            let commands = response
                .get("commands")
                .and_then(Value::as_array)
                .map(|commands| slash_commands(commands))
                .unwrap_or_default();
            let _ = tx.send(Internal::Commands {
                session_id,
                commands,
            });
        });
    }

    /// Reads the last turns of a session no crok runs from disk, for a viewer who opened it.
    fn read_history(&self, command: InboxCommand) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let prefix = format!("{}h", self.prefix());
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let cwd = command.cwd.clone().unwrap_or_default();
            let (events, preview) = read_transcript(
                &agent,
                &command.session_id,
                &cwd,
                HISTORY_TURNS,
                None,
                prefix,
            )
            .await;
            let _ = tx.send(Internal::History {
                command_id: command.id,
                session_doc_id: command.session_doc_id,
                events,
                preview,
            });
        });
    }

    fn start_prompt(&mut self, command: InboxCommand) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let session_id = command.session_id.clone();
        let Some(mirror) = self.mirrors.get_mut(&session_id) else {
            return;
        };
        let text = command.text.clone().unwrap_or_default();
        let prompt_id = format!("remote-{}", command.id);
        mirror.idle_since = None;
        mirror.remote_running = Some(command.id.clone());
        mirror.turn_running = true;
        mirror.had_prompt = true;
        mirror.live_prompt_id = Some(prompt_id.clone());
        mirror.set_status(SessionStatus::Running);
        mirror.title_from_prompt(&text);
        mirror.transcript.user_prompt(
            &text,
            "remote",
            Some(&command.id),
            Some(&command.from_label),
            now_ms(),
        );
        mirror.boundary = true;
        let notice = json!({
            "sessionId": session_id,
            "promptId": prompt_id,
            "text": text,
            "from": command.from_label,
            "fromKind": command.from_kind,
        });
        agent
            .gateway
            .forward_fire_and_forget(acp::ExtNotification::new(
                REMOTE_PROMPT_METHOD,
                raw(&notice),
            ));
        let tx = self.internal_tx.clone();
        let command_id = command.id;
        tokio::task::spawn_local(async move {
            let mut meta = acp::Meta::new();
            meta.insert("promptId".into(), Value::String(prompt_id));
            let request = acp::PromptRequest::new(
                session_id.clone(),
                vec![acp::ContentBlock::Text(acp::TextContent::new(text))],
            )
            .meta(meta);
            let error = agent
                .prompt(request)
                .await
                .err()
                .map(|e| e.message.to_string());
            let _ = tx.send(Internal::PromptReturned {
                session_id,
                command_id,
                error,
            });
        });
    }

    /// Runs what waits for the session: config changes at once, the next prompt when no turn is running.
    fn run_next(&mut self, session_id: &str) {
        loop {
            let Some(m) = self.mirrors.get_mut(session_id) else {
                return;
            };
            if m.opening || !m.registered {
                return;
            }
            let busy = m.turn_running || m.remote_running.is_some();
            let config_first = m
                .queue
                .front()
                .is_some_and(|c| c.kind == CommandType::Config);
            if busy && !config_first {
                return;
            }
            let Some(next) = m.queue.pop_front() else {
                if !busy && m.adopted && m.idle_since.is_none() {
                    m.idle_since = Some(Instant::now());
                }
                return;
            };
            if next.kind == CommandType::Config {
                self.apply_config(next);
                continue;
            }
            self.start_prompt(next);
            return;
        }
    }

    /// Sends the front end an ext notification (it passes the tee like the agent's own).
    fn tell_front_end(&self, method: &str, params: Value) {
        if let Some(agent) = self.agent.upgrade() {
            agent
                .gateway
                .forward_fire_and_forget(acp::ExtNotification::new(method, raw(&params)));
        }
    }

    /// A prompt for a session nobody on this computer runs: open it here, hidden from the front end, then run the
    /// prompt (the relay already made this process the session's runner when it handed over the command).
    fn adopt(&mut self, command: InboxCommand) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let session_id = command.session_id.clone();
        let cwd = command.cwd.clone().unwrap_or_default();
        let prefix = self.prefix();
        let mut mirror = Mirror::new(cwd.clone(), &prefix);
        mirror.adopted = true;
        mirror.opening = true;
        mirror.loaded = true;
        mirror.had_prompt = true;
        mirror.queue.push_back(command);
        self.mirrors.insert(session_id.clone(), mirror);
        self.observer.hide(&session_id);
        let tx = self.internal_tx.clone();
        tokio::task::spawn_local(async move {
            let error = if cwd.is_empty() || !std::path::Path::new(&cwd).is_absolute() {
                Some("The session's folder is unknown.".to_string())
            } else {
                let mut meta = acp::Meta::new();
                meta.insert("noReplay".into(), Value::Bool(true));
                let request =
                    acp::LoadSessionRequest::new(session_id.clone(), std::path::PathBuf::from(cwd))
                        .mcp_servers(Vec::new())
                        .meta(meta);
                agent
                    .load_session(request)
                    .await
                    .err()
                    .map(|e| e.message.to_string())
            };
            let _ = tx.send(Internal::Opened { session_id, error });
        });
    }

    fn on_opened(&mut self, session_id: String, error: Option<String>) {
        let Some(mirror) = self.mirrors.get_mut(&session_id) else {
            return;
        };
        mirror.opening = false;
        let Some(error) = error else {
            tracing::info!(%session_id, "remote control: opened a session for a remote prompt");
            self.register(&session_id);
            self.fetch_roster();
            self.run_next(&session_id);
            return;
        };
        tracing::warn!(%session_id, %error, "remote control: cannot open a session for a remote prompt");
        let waiting: Vec<String> = mirror.queue.drain(..).map(|c| c.id).collect();
        self.mirrors.remove(&session_id);
        self.observer.reveal(&session_id);
        for id in waiting {
            self.complete(
                &id,
                CommandOutcome::Failed,
                None,
                Some(format!("The computer could not open this session: {error}")),
            );
        }
        // The relay made this process its runner when the prompt was claimed: give it back.
        self.send(ToRelay::CloseSession { session_id });
    }

    /// Closes adopted sessions that have been idle a while (or at once while signed out).
    fn release_idle(&mut self) {
        let active = self.active();
        let now = Instant::now();
        let idle: Vec<String> = self
            .mirrors
            .iter()
            .filter(|(id, m)| {
                m.adopted
                    && !m.opening
                    && !m.turn_running
                    && m.remote_running.is_none()
                    && m.queue.is_empty()
                    && m.permission.is_none()
                    && self.watched.get(*id).is_none_or(|until| *until <= now)
                    && (!active || m.idle_since.is_some_and(|t| t.elapsed() >= ADOPTED_IDLE))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in idle {
            self.release(&id, true);
        }
    }

    /// Adopted sessions another crok on this computer took over (the relay no longer has them here): close them here
    /// once they are idle, so two processes do not write one session.
    fn release_taken(&mut self, hosted: &HashSet<String>) {
        let taken: Vec<String> = self
            .mirrors
            .iter()
            .filter(|(id, m)| {
                m.adopted
                    && m.registered
                    && !m.opening
                    && !m.turn_running
                    && m.remote_running.is_none()
                    && !hosted.contains(*id)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in taken {
            self.release(&id, false);
        }
    }

    fn release(&mut self, session_id: &str, tell_relay: bool) {
        let Some(mirror) = self.mirrors.remove(session_id) else {
            return;
        };
        tracing::info!(%session_id, "remote control: closing a session opened for a remote prompt");
        self.observer.set_shared(session_id, false);
        if tell_relay && mirror.requested {
            self.send(ToRelay::CloseSession {
                session_id: session_id.to_string(),
            });
        }
        let Some(agent) = self.agent.upgrade() else {
            self.observer.reveal(session_id);
            return;
        };
        let observer = self.observer.clone();
        let id = session_id.to_string();
        tokio::task::spawn_local(async move {
            let _ = agent
                .close_session(acp::CloseSessionRequest::new(id.clone()))
                .await;
            observer.reveal(&id);
        });
    }

    fn refresh_usage(&self, session_id: &str) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let tx = self.internal_tx.clone();
        let session_id = session_id.to_string();
        tokio::task::spawn_local(async move {
            let info = ext_json(
                &agent,
                "x.ai/session/info",
                json!({ "sessionId": session_id }),
            )
            .await;
            let usage = ext_json(
                &agent,
                "x.ai/session/usage",
                json!({ "sessionId": session_id }),
            )
            .await;
            let _ = tx.send(Internal::Fields {
                session_id,
                fields: SessionFields {
                    usage: Some(usage_fields(info.as_ref(), usage.as_ref())),
                    ..SessionFields::default()
                },
                real_title: false,
            });
        });
    }

    /// Replays the last few turns from disk into the mirror (replacing whatever the relay had).
    fn backfill(&self, session_id: &str) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let Some(mirror) = self.mirrors.get(session_id) else {
            return;
        };
        let cwd = mirror.cwd.clone();
        let skip_prompt = mirror.live_prompt_id.clone();
        let prefix = format!("{}b", self.prefix());
        let tx = self.internal_tx.clone();
        let session_id = session_id.to_string();
        tokio::task::spawn_local(async move {
            let (events, preview) = read_transcript(
                &agent,
                &session_id,
                &cwd,
                BACKFILL_TURNS,
                skip_prompt.as_deref(),
                prefix,
            )
            .await;
            let _ = tx.send(Internal::Backfilled {
                session_id,
                events,
                preview,
            });
        });
    }

    fn flush(&mut self) {
        if !self.active() {
            return;
        }
        let now = Instant::now();
        let mut out = Vec::new();
        for (session_id, mirror) in &mut self.mirrors {
            if !mirror.registered || mirror.backfill_pending {
                continue;
            }
            let watched = self
                .watched
                .get(session_id)
                .is_some_and(|until| *until > now);
            let since = now.duration_since(mirror.last_flush);
            let due =
                mirror.boundary || (watched && since >= WATCHED_FLUSH) || since >= UNWATCHED_FLUSH;
            if mirror.transcript.has_dirty() && due {
                let events = mirror.transcript.take_dirty();
                out.push(ToRelay::PushEvents {
                    session_id: session_id.clone(),
                    events,
                    replace: false,
                });
                mirror.last_flush = now;
                let at_boundary = mirror.boundary;
                mirror.boundary = false;
                if let Some(preview) = mirror.transcript.preview() {
                    mirror.latest_preview = Some(preview);
                }
                // Lists show "working…" for a running session, and every session write re-sends every viewer's whole
                // list: the preview goes out at message boundaries and when the turn is over, not with each chunk.
                if at_boundary {
                    mirror.publish_preview();
                }
                mirror.transcript.compact();
            } else if !mirror.transcript.has_dirty() {
                mirror.boundary = false;
            }
            if !mirror.turn_running {
                mirror.publish_preview();
            }
            if mirror.commands.is_some() && mirror.commands != mirror.sent_commands {
                mirror.sent_commands = mirror.commands.clone();
                out.push(ToRelay::SetCommands {
                    session_id: session_id.clone(),
                    commands: mirror.commands.clone().unwrap_or_default(),
                });
            }
            let mut changes = mirror.sent.changes_to(&mirror.desired);
            if changes.title.as_deref() == Some("") {
                changes.title = None;
            }
            if !changes.is_empty() {
                mirror.sent.merge(changes.clone());
                out.push(ToRelay::UpsertSession {
                    session_id: session_id.clone(),
                    fields: Box::new(changes),
                });
            }
        }
        for message in out {
            self.send(message);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn efforts_come_from_the_model_meta_with_ids_and_levels() {
        let meta = json!({
            "supportsReasoningEffort": true,
            "reasoningEfforts": [
                { "id": "balanced", "value": "medium", "label": "Balanced" },
                { "id": "deep", "value": "xhigh", "label": "Deep", "description": "Slow", "default": true },
            ],
        });
        let (efforts, default) = model_efforts(meta.as_object());
        assert_eq!(efforts.len(), 2);
        assert_eq!(efforts[0].id, "balanced");
        assert_eq!(efforts[0].value.as_deref(), Some("medium"));
        assert_eq!(efforts[1].description.as_deref(), Some("Slow"));
        assert_eq!(default.as_deref(), Some("deep"));
    }

    #[test]
    fn a_model_without_thinking_levels_offers_none_and_a_bare_flag_gets_the_built_in_menu() {
        assert!(
            model_efforts(json!({ "reasoningEfforts": [{ "value": "high" }] }).as_object())
                .0
                .is_empty()
        );
        let (built_in, _) = model_efforts(json!({ "supportsReasoningEffort": true }).as_object());
        assert!(
            built_in
                .iter()
                .any(|e| e.id == "high" && e.value.as_deref() == Some("high"))
        );
        assert_eq!(effort_label("xhigh"), "Extra high");
        assert_eq!(effort_label("low"), "Low");
    }

    #[test]
    fn slash_commands_keep_name_description_and_hint() {
        let commands = slash_commands(&[
            json!({ "name": "compact", "description": "Compress history" }),
            json!({ "name": "/review-pr", "description": "Review", "input": { "hint": "<number>" } }),
            json!({ "name": "", "description": "nameless" }),
        ]);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[1].name, "review-pr");
        assert_eq!(commands[1].hint.as_deref(), Some("<number>"));
        assert_eq!(commands[0].hint, None);
    }

    #[test]
    fn a_thinking_level_is_matched_by_option_id_or_level() {
        let models = vec![ModelOption {
            id: "grok-4".into(),
            name: "Grok 4".into(),
            description: None,
            efforts: vec![EffortOption {
                id: "deep".into(),
                name: "Deep".into(),
                value: Some("xhigh".into()),
                description: None,
            }],
            default_effort: Some("deep".into()),
        }];
        assert_eq!(effort_option_id(&models, "grok-4", "deep"), "deep");
        assert_eq!(effort_option_id(&models, "grok-4", "xhigh"), "deep");
        assert_eq!(effort_option_id(&models, "grok-4", "max"), "max");
    }

    #[test]
    fn the_selected_model_and_level_are_read_from_config_options() {
        let options = vec![
            json!({ "id": "model", "currentValue": "grok-4", "options": [] }),
            json!({ "id": "reasoning_effort", "currentValue": "deep", "options": [] }),
        ];
        assert_eq!(
            selected_config(&options),
            (Some("grok-4".to_string()), Some("deep".to_string()))
        );
        assert_eq!(selected_config(&[]), (None, None));
    }
}
