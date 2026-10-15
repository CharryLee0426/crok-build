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
    CommandOutcome, CommandType, EventInput, EventKind, InboxCommand, SessionFields, SessionStatus,
    SessionUsage, now_ms,
};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::transcript::{Signal, Transcript, shorten};
use super::{HostApp, Observed, Observer, REMOTE_PROMPT_METHOD, REMOTE_STATUS_METHOD};
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
const TITLE_FALLBACK_MAX: usize = 80;

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
}

impl Mirror {
    fn new(cwd: String, prefix: &str) -> Mirror {
        Mirror {
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

fn status_from_activity(activity: &str) -> Option<SessionStatus> {
    match activity {
        "working" => Some(SessionStatus::Running),
        "needs_input" => Some(SessionStatus::Waiting),
        "idle" | "completed" | "dormant" => Some(SessionStatus::Idle),
        "dead" => Some(SessionStatus::Error),
        _ => None,
    }
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
        };
        let (link, link_rx) = match Link::spawn(config) {
            Ok(pair) => pair,
            Err(error) => {
                tracing::warn!(%error, "remote control: cannot start the link");
                return;
            }
        };
        self.activations += 1;
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
    }

    fn deactivate(&mut self) {
        self.link = None;
        self.link_rx = None;
        self.observer.set_live(false);
        self.watched.clear();
        self.handled.clear();
        for mirror in self.mirrors.values_mut() {
            mirror.requested = false;
            mirror.registered = false;
            mirror.backfill_pending = false;
            mirror.sent = SessionFields::default();
            mirror.remote_running = None;
            mirror.queue.clear();
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
                if let Some(mirror) = self.mirrors.remove(&session_id)
                    && mirror.requested
                {
                    self.send(ToRelay::CloseSession { session_id });
                }
            }
            Observed::Outgoing { method, params } => self.on_outgoing(&method, &params),
        }
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
            FromRelay::Registered { session_id, .. } => {
                let Some(mirror) = self.mirrors.get_mut(&session_id) else {
                    return;
                };
                mirror.registered = true;
                if mirror.backfill_pending {
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
                for command in inbox.commands {
                    if !self.handled.insert(command.id.clone()) {
                        continue;
                    }
                    if !self
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
        let session_id = command.session_id.clone();
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
                if mirror.turn_running || mirror.remote_running.is_some() {
                    // Delivered and waiting: it runs when the current turn ends.
                    mirror.queue.push_back(command);
                } else {
                    self.start_prompt(command);
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
        }
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

    fn run_next(&mut self, session_id: &str) {
        let next = self.mirrors.get_mut(session_id).and_then(|m| {
            if m.turn_running || m.remote_running.is_some() {
                None
            } else {
                m.queue.pop_front()
            }
        });
        if let Some(command) = next {
            self.start_prompt(command);
        }
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
            let response = ext_json(
                &agent,
                "x.ai/session/updates",
                json!({ "sessionId": session_id, "cwd": cwd, "turnIndex": BACKFILL_TURNS }),
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
                if skip_prompt.is_some() && prompt_id == skip_prompt.as_deref() {
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
            let events = transcript.take_dirty();
            let preview = transcript.preview();
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
                mirror.boundary = false;
                if let Some((kind, text)) = mirror.transcript.preview() {
                    mirror.desired.preview = Some(text);
                    mirror.desired.preview_kind = Some(kind);
                }
                mirror.transcript.compact();
            } else if !mirror.transcript.has_dirty() {
                mirror.boundary = false;
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
