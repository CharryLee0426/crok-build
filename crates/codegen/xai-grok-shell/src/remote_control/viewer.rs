//! Sessions on the person's other computers, opened in this crok as if they ran here (`relay/DESIGN.md` §4,
//! "Sessions on other computers").
//!
//! A front end (the TUI, a Crok Desktop task) names such a session `relay:<sessionDocId>`, and
//! [`super::ObservedAgent`] hands every call for it here instead of to the agent:
//!
//! - loading reads the transcript from the relay and replays it as ordinary `session/update`s (`_meta.isReplay`);
//! - a prompt becomes `commands:sendPrompt`; the turn streams back from the relay's copy of the transcript and the
//!   prompt returns when the computer running the session says the turn is over;
//! - Stop is `commands:stop`; a permission request waiting on the session is asked here like a local one and the
//!   choice goes back as `commands:answer` (whichever device answers first wins);
//! - turns started elsewhere (typed on that computer, sent from a phone) show up the way a phone's prompt shows up in
//!   a local session: a user message, `x.ai/remote/prompt`, then `x.ai/session/prompt_complete`.
//!
//! The computer that runs the session does the work; nothing of it runs here.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::rc::Rc;
use std::time::{Duration, Instant};

use agent_client_protocol::{self as acp, Client as _};
use crok_remote::link::{CallKind, ToRelay};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use xai_acp_lib::AcpAgentGatewaySender as GatewaySender;

/// Session ids a front end uses for a session on another computer: this prefix and the relay's document id.
pub const RELAY_PREFIX: &str = "relay:";
/// Ext method: the person's other computers and their sessions (`{watch: true}` keeps
/// [`REMOTE_SESSIONS_CHANGED_METHOD`] coming for ten minutes).
pub const REMOTE_SESSIONS_METHOD: &str = "x.ai/remote/sessions";
/// Ext notification: the same list as [`REMOTE_SESSIONS_METHOD`] returns, after any change.
pub const REMOTE_SESSIONS_CHANGED_METHOD: &str = "x.ai/remote/sessions_changed";
/// Ext notification `{sessionId, toolCallId}`: a permission request was answered on another device; a front end drops
/// its own prompt for it.
pub const PERMISSION_RESOLVED_METHOD: &str = "x.ai/remote/permission_resolved";
/// Ext method `{deviceId, path, text?, model?, effort?}` → `{sessionId: "relay:<id>"}`: starts a session in a folder of
/// another computer, with the model and thinking level its composer offered.
pub const REMOTE_NEW_SESSION_METHOD: &str = "x.ai/remote/new_session";
/// Ext method `{deviceId}` → `{models, availableModels}`: what another computer can run, before any session there is
/// open (`devices:models`: `models` in the relay's shape, null while it is offline; `availableModels` in the agent's).
pub const REMOTE_MODELS_METHOD: &str = "x.ai/remote/models";

const CALL_TIMEOUT: Duration = Duration::from_secs(20);
/// How much transcript a session starts with when opened here.
const HISTORY_EVENTS: f64 = 200.0;
/// The newest items, watched for changes while the session is open.
const TAIL_EVENTS: f64 = 40.0;
const WATCH_EVERY: Duration = Duration::from_secs(60);
/// The list of other computers' sessions is kept current this long after a front end last asked for it.
const LIST_KEEP: Duration = Duration::from_secs(10 * 60);
/// How long to wait for the first list when a front end asks before it arrived.
const LIST_FIRST_WAIT: Duration = Duration::from_secs(4);
/// After a turn ends, a moment for the relay's last transcript writes to arrive before the prompt returns: each query
/// streams on its own, so the transcript's last update can come after the command's "done".
const SETTLE: Duration = Duration::from_millis(600);
/// The longest a finished prompt waits for the session to show idle.
const SETTLE_MAX: Duration = Duration::from_secs(3);
/// How long a model or thinking-level change may take on the other computer (it may have to open the session first).
const CONFIG_WAIT: Duration = Duration::from_secs(75);
const CONFIG_POLL: Duration = Duration::from_millis(400);

pub(crate) fn doc_id(session_id: &str) -> Option<&str> {
    session_id
        .strip_prefix(RELAY_PREFIX)
        .filter(|id| !id.is_empty())
}

pub(crate) fn is_relay_session(session_id: &str) -> bool {
    doc_id(session_id).is_some()
}

fn error(message: impl Into<String>) -> acp::Error {
    acp::Error::new(-32603, message.into())
}

fn text_hash(kind: &str, text: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    kind.hash(&mut hasher);
    text.trim().hash(&mut hasher);
    hasher.finish()
}

fn str_of<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn rfc3339(ms: f64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp_millis(ms as i64)
        .unwrap_or_default()
        .to_rfc3339()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Feed {
    Detail,
    Events,
    Commands,
    Groups,
    /// `devices:models` for the session's computer.
    Models,
}

#[derive(Clone, Debug)]
struct Seen {
    kind: String,
    text: String,
    title: Option<String>,
    status: Option<String>,
}

/// A prompt this front end sent.
struct Mine {
    prompt_id: String,
    command_id: Option<String>,
    waiter: Option<oneshot::Sender<Result<acp::StopReason, String>>>,
    cancelled: bool,
    /// The computer finished it: (when, outcome). It returns once the session is idle or after [`SETTLE`].
    finished: Option<(Instant, Result<(), String>)>,
}

struct View {
    acp_id: String,
    feeds: Vec<u64>,
    detail: Value,
    seen: HashMap<String, Seen>,
    /// Text items by content, so a transcript the computer re-sent under new keys is not shown twice.
    by_content: HashMap<u64, String>,
    /// The prompt id agent output is stamped with (the turn running now).
    turn_prompt: Option<String>,
    /// Whether that turn was started elsewhere (it ends when the session goes idle).
    turn_foreign: bool,
    mine: HashMap<String, Mine>,
    asked: Option<String>,
    last_watch: Instant,
    /// The computer's models from `devices:models`: unlike `sessions:get`'s copy, there for any length of list.
    models: Option<Value>,
}

impl View {
    fn status(&self) -> &str {
        str_of(&self.detail, "status").unwrap_or("idle")
    }

    fn choices(&self) -> Choices {
        Choices::of(&self.detail, self.models.as_ref())
    }

    fn computer(&self) -> String {
        str_of(&self.detail, "deviceName")
            .unwrap_or("another computer")
            .to_string()
    }
}

#[derive(Default)]
struct ListState {
    feed: Option<u64>,
    groups: Option<Value>,
    last_use: Option<Instant>,
    /// A front end wants [`REMOTE_SESSIONS_CHANGED_METHOD`] until then.
    watch_until: Option<Instant>,
    waiters: Vec<oneshot::Sender<()>>,
}

/// Other computers' sessions open in this process. One per process, shared by the bridge (which owns the link) and the
/// front end's connection.
pub(crate) struct Viewer {
    link: RefCell<Option<mpsc::UnboundedSender<ToRelay>>>,
    /// This computer, left out of the list of other computers.
    device_id: RefCell<Option<String>>,
    gateway: RefCell<Option<GatewaySender>>,
    next_feed: Cell<u64>,
    feeds: RefCell<HashMap<u64, (Feed, String)>>,
    views: RefCell<HashMap<String, View>>,
    list: RefCell<ListState>,
}

impl Viewer {
    pub(crate) fn new() -> Rc<Viewer> {
        Rc::new(Viewer {
            link: RefCell::new(None),
            device_id: RefCell::new(None),
            gateway: RefCell::new(None),
            next_feed: Cell::new(1),
            feeds: RefCell::new(HashMap::new()),
            views: RefCell::new(HashMap::new()),
            list: RefCell::new(ListState::default()),
        })
    }

    pub(crate) fn set_gateway(&self, gateway: GatewaySender) {
        *self.gateway.borrow_mut() = Some(gateway);
    }

    /// The bridge signed in (a new link) or out (`None`). Open sessions and the list follow the new link.
    pub(crate) fn set_link(
        &self,
        link: Option<mpsc::UnboundedSender<ToRelay>>,
        device_id: Option<String>,
    ) {
        *self.link.borrow_mut() = link.clone();
        *self.device_id.borrow_mut() = device_id;
        self.feeds.borrow_mut().clear();
        let ids: Vec<String> = self.views.borrow().keys().cloned().collect();
        for doc in ids {
            if let Some(view) = self.views.borrow_mut().get_mut(&doc) {
                view.feeds.clear();
            }
            if link.is_some() {
                self.subscribe_view(&doc);
            }
        }
        let wanted = {
            let mut list = self.list.borrow_mut();
            list.feed = None;
            list.last_use.is_some_and(|t| t.elapsed() < LIST_KEEP)
        };
        if link.is_none() {
            self.list.borrow_mut().groups = None;
        } else if wanted {
            self.subscribe_list();
        }
    }

    fn signed_in(&self) -> bool {
        self.link.borrow().is_some()
    }

    async fn call(&self, kind: CallKind, path: &str, args: Value) -> acp::Result<Value> {
        let Some(link) = self.link.borrow().clone() else {
            return Err(error(
                "Remote control is signed out here: sign in with /remote login (or in Settings) to open sessions on your other computers.",
            ));
        };
        let (reply, answer) = oneshot::channel();
        link.send(ToRelay::Call {
            kind,
            path: path.to_string(),
            args,
            reply,
        })
        .map_err(|_| error("The relay connection closed."))?;
        match tokio::time::timeout(CALL_TIMEOUT, answer).await {
            Ok(Ok(Ok(value))) => Ok(value),
            // The relay's code (`OFFLINE`, `INVALID`, …) rides along for front ends that word it themselves.
            Ok(Ok(Err(failure))) => Err(match failure.code() {
                Some(code) => error(failure.to_string()).data(json!({ "code": code })),
                None => error(failure.to_string()),
            }),
            Ok(Err(_)) => Err(error("The relay connection closed.")),
            Err(_) => Err(error("The relay did not answer in time.")),
        }
    }

    /// A mutation whose result nobody waits for.
    fn fire(&self, path: &str, args: Value) {
        let Some(link) = self.link.borrow().clone() else {
            return;
        };
        let (reply, _) = oneshot::channel();
        let _ = link.send(ToRelay::Call {
            kind: CallKind::Mutation,
            path: path.to_string(),
            args,
            reply,
        });
    }

    fn subscribe(&self, feed: Feed, doc: &str, path: &str, args: Value) -> Option<u64> {
        let link = self.link.borrow().clone()?;
        let id = self.next_feed.get();
        self.next_feed.set(id + 1);
        self.feeds.borrow_mut().insert(id, (feed, doc.to_string()));
        let _ = link.send(ToRelay::Subscribe {
            id,
            path: path.to_string(),
            args,
        });
        Some(id)
    }

    fn unsubscribe(&self, id: u64) {
        self.feeds.borrow_mut().remove(&id);
        if let Some(link) = self.link.borrow().as_ref() {
            let _ = link.send(ToRelay::Unsubscribe { id });
        }
    }

    fn subscribe_view(&self, doc: &str) {
        let args = json!({ "sessionDocId": doc });
        let mut feeds = Vec::new();
        feeds.extend(self.subscribe(Feed::Detail, doc, "sessions:get", args.clone()));
        feeds.extend(self.subscribe(
            Feed::Events,
            doc,
            "sessions:events",
            json!({ "sessionDocId": doc, "paginationOpts": { "numItems": TAIL_EVENTS, "cursor": null } }),
        ));
        feeds.extend(self.subscribe(Feed::Commands, doc, "commands:forSession", args));
        let device = self
            .views
            .borrow()
            .get(doc)
            .and_then(|view| str_of(&view.detail, "deviceId").map(str::to_owned));
        if let Some(device) = device {
            feeds.extend(self.subscribe(
                Feed::Models,
                doc,
                "devices:models",
                json!({ "deviceId": device }),
            ));
        }
        if let Some(view) = self.views.borrow_mut().get_mut(doc) {
            view.feeds = feeds;
        }
    }

    /// `devices:models` once: a computer's list, or None when the relay cannot say (an older relay has no such query).
    async fn device_models(&self, device: &str) -> Option<Value> {
        self.call(
            CallKind::Query,
            "devices:models",
            json!({ "deviceId": device }),
        )
        .await
        .ok()
    }

    // MARK: Emitting to the front end

    fn gateway(&self) -> Option<GatewaySender> {
        self.gateway.borrow().clone()
    }

    /// Sends a session update to the front end. A replayed one comes with the receiver that completes once it was
    /// delivered: a load returns only after its history is there, or a front end drops it as a stray replay.
    fn notify(
        &self,
        acp_id: &str,
        update: Value,
        prompt_id: Option<&str>,
        replay: bool,
    ) -> Option<oneshot::Receiver<xai_acp_lib::AcpResult<()>>> {
        let gateway = self.gateway()?;
        let mut meta = serde_json::Map::new();
        meta.insert(
            "agentTimestampMs".into(),
            json!(chrono::Utc::now().timestamp_millis()),
        );
        if let Some(prompt_id) = prompt_id {
            meta.insert("promptId".into(), json!(prompt_id));
        }
        if replay {
            meta.insert("isReplay".into(), json!(true));
        }
        let notification = json!({ "sessionId": acp_id, "update": update, "_meta": meta });
        match serde_json::from_value::<acp::SessionNotification>(notification) {
            Ok(notification) if replay => Some(gateway.forward_with_completion(notification)),
            Ok(notification) => {
                gateway.forward_fire_and_forget(notification);
                None
            }
            Err(failure) => {
                tracing::debug!(%failure, "remote viewer: unexpected update shape");
                None
            }
        }
    }

    fn ext_notify(&self, method: &str, params: Value) {
        let Some(gateway) = self.gateway() else {
            return;
        };
        if let Ok(raw) = serde_json::value::to_raw_value(&params) {
            gateway.forward_fire_and_forget(acp::ExtNotification::new(method, raw.into()));
        }
    }

    // MARK: Front end calls

    /// Opens a session of another computer: replays its transcript, then keeps it current.
    pub(crate) async fn load(
        self: &Rc<Self>,
        acp_id: &str,
    ) -> acp::Result<acp::LoadSessionResponse> {
        let doc = doc_id(acp_id)
            .ok_or_else(|| error("Not a session of another computer."))?
            .to_string();
        let detail = self
            .call(
                CallKind::Query,
                "sessions:get",
                json!({ "sessionDocId": doc }),
            )
            .await?;
        let page = self
            .call(
                CallKind::Query,
                "sessions:events",
                json!({ "sessionDocId": doc, "paginationOpts": { "numItems": HISTORY_EVENTS, "cursor": null } }),
            )
            .await?;
        let models = match str_of(&detail, "deviceId") {
            Some(device) => self.device_models(device).await,
            None => None,
        };
        self.close(acp_id);
        let view = View {
            acp_id: acp_id.to_string(),
            feeds: Vec::new(),
            detail,
            seen: HashMap::new(),
            by_content: HashMap::new(),
            turn_prompt: None,
            turn_foreign: false,
            mine: HashMap::new(),
            asked: None,
            last_watch: Instant::now(),
            models,
        };
        self.views.borrow_mut().insert(doc.clone(), view);
        let mut events: Vec<Value> = page
            .get("page")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        events.reverse();
        for delivered in self.apply_events(&doc, &events, true) {
            let _ = tokio::time::timeout(CALL_TIMEOUT, delivered).await;
        }
        // A turn already running there (a new session's first prompt, say) is adopted like one started elsewhere: the
        // front end shows it running and hears `prompt_complete` when the session goes idle.
        let running = self.views.borrow_mut().get_mut(&doc).and_then(|view| {
            if view.status() == "idle" || view.status() == "error" {
                return None;
            }
            let last_prompt = events
                .iter()
                .rev()
                .find(|e| str_of(e, "kind") == Some("user"))
                .and_then(|e| str_of(e, "commandId").or_else(|| str_of(e, "key")))
                .unwrap_or("running");
            let prompt_id = format!("remote-{last_prompt}");
            view.turn_prompt = Some(prompt_id.clone());
            view.turn_foreign = true;
            Some(prompt_id)
        });
        self.fire("sessions:watch", json!({ "sessionDocId": doc }));
        self.fire("sessions:markRead", json!({ "sessionDocId": doc }));
        self.subscribe_view(&doc);
        // A front end opening the session sees the figures its computer last reported even before the next turn.
        if let Some(usage) = self
            .views
            .borrow()
            .get(&doc)
            .and_then(|view| view.detail.get("usage"))
            .filter(|usage| usage.is_object())
            .cloned()
        {
            self.notify_usage(acp_id, usage);
        }
        let choices = self
            .views
            .borrow()
            .get(&doc)
            .map(View::choices)
            .unwrap_or_default();
        let mut response = json!({
            "models": choices.model_state(),
            "configOptions": choices.config_options(),
        });
        if let Some(prompt_id) = running {
            set(
                &mut response,
                "_meta",
                json!({ "x.ai/runningPromptId": prompt_id }),
            );
        }
        serde_json::from_value(response)
            .map_err(|failure| error(format!("cannot build the load response: {failure}")))
    }

    /// Changes the session's model (and, from the TUI's picker, its thinking level with it) on its computer.
    pub(crate) async fn set_model(
        &self,
        acp_id: &str,
        model: &str,
        effort: Option<String>,
    ) -> acp::Result<acp::SetSessionModelResponse> {
        let doc = doc_id(acp_id)
            .ok_or_else(|| error("Not a session of another computer."))?
            .to_string();
        let current = self.detail(&doc).await?;
        if str_of(&current, "model") != Some(model) {
            self.change(&doc, "model", model).await?;
        }
        if let Some(level) = effort {
            let choices = self.choices(&doc).await?;
            if choices.effort.as_deref() != Some(level.as_str())
                && let Some(id) = choices.effort_id(&level)
            {
                self.change(&doc, "reasoning_effort", &id).await?;
            }
        }
        serde_json::from_value(json!({ "_meta": { "model": model } }))
            .map_err(|failure| error(format!("cannot build the response: {failure}")))
    }

    /// `session/set_config_option` (`model`, `reasoning_effort`) for a session of another computer.
    pub(crate) async fn set_config(
        &self,
        acp_id: &str,
        config_id: &str,
        value: &str,
    ) -> acp::Result<acp::SetSessionConfigOptionResponse> {
        let doc = doc_id(acp_id)
            .ok_or_else(|| error("Not a session of another computer."))?
            .to_string();
        if config_id != "model" && config_id != "reasoning_effort" {
            return Err(error(format!("unknown config option: {config_id}")));
        }
        self.change(&doc, config_id, value).await?;
        let choices = self.choices(&doc).await?;
        serde_json::from_value(json!({ "configOptions": choices.config_options() }))
            .map_err(|failure| error(format!("cannot build the response: {failure}")))
    }

    /// What the session offers to choose now: its detail with its computer's list (the open view's, else read once).
    async fn choices(&self, doc: &str) -> acp::Result<Choices> {
        let detail = self.detail(doc).await?;
        let held = self
            .views
            .borrow()
            .get(doc)
            .and_then(|view| view.models.clone());
        let models = match (held, str_of(&detail, "deviceId")) {
            (Some(models), _) => Some(models),
            (None, Some(device)) => self.device_models(device).await,
            (None, None) => None,
        };
        Ok(Choices::of(&detail, models.as_ref()))
    }

    /// `x.ai/remote/models`: what one of the person's other computers can run, for a session about to start there.
    pub(crate) async fn models(&self, params: &Value) -> acp::Result<Value> {
        let device = str_of(params, "deviceId").ok_or_else(|| error("Which computer?"))?;
        let models = self
            .call(
                CallKind::Query,
                "devices:models",
                json!({ "deviceId": device }),
            )
            .await?;
        let choices = Choices::of(&json!({}), Some(&models));
        Ok(json!({
            "deviceId": device,
            "models": models,
            "availableModels": choices.model_state().get("availableModels"),
        }))
    }

    /// The session as the relay has it: the open view's copy, else a fresh read.
    async fn detail(&self, doc: &str) -> acp::Result<Value> {
        let held = self
            .views
            .borrow()
            .get(doc)
            .map(|view| view.detail.clone())
            .filter(|detail| !detail.is_null());
        match held {
            Some(detail) => Ok(detail),
            None => {
                self.call(
                    CallKind::Query,
                    "sessions:get",
                    json!({ "sessionDocId": doc }),
                )
                .await
            }
        }
    }

    /// Sends `commands:setConfig` and waits until the computer applied it; the open view takes the new value at once.
    async fn change(&self, doc: &str, config_id: &str, value: &str) -> acp::Result<()> {
        let sent = self
            .call(
                CallKind::Mutation,
                "commands:setConfig",
                json!({ "sessionDocId": doc, "configId": config_id, "value": value }),
            )
            .await?;
        let command_id = str_of(&sent, "commandId")
            .ok_or_else(|| error("The relay did not take the change."))?
            .to_string();
        let started = Instant::now();
        loop {
            tokio::time::sleep(CONFIG_POLL).await;
            let command = self
                .call(
                    CallKind::Query,
                    "commands:get",
                    json!({ "commandId": command_id }),
                )
                .await?;
            match str_of(&command, "status") {
                Some("done") => {
                    let result = command.get("result").cloned().unwrap_or(Value::Null);
                    if let Some(view) = self.views.borrow_mut().get_mut(doc) {
                        for key in ["model", "effort"] {
                            if let Some(value) = result.get(key).filter(|v| v.is_string()) {
                                set(&mut view.detail, key, value.clone());
                            }
                        }
                    }
                    return Ok(());
                }
                Some("failed") => {
                    return Err(error(
                        str_of(&command, "error")
                            .unwrap_or("The other computer could not change it.")
                            .to_string(),
                    ));
                }
                _ if started.elapsed() >= CONFIG_WAIT => {
                    return Err(error("The other computer did not answer in time."));
                }
                _ => {}
            }
        }
    }

    /// `x.ai/remote/new_session`: starts a session in a folder of another computer and names it for the front end.
    pub(crate) async fn new_session(&self, params: &Value) -> acp::Result<Value> {
        let device = str_of(params, "deviceId").ok_or_else(|| error("Which computer?"))?;
        let path = str_of(params, "path").ok_or_else(|| error("Which folder?"))?;
        let mut args = json!({
            "deviceId": device,
            "path": path,
            "clientId": uuid::Uuid::new_v4().to_string(),
        });
        // Optional arguments are left out, never sent as null.
        if let Some(text) = str_of(params, "text").filter(|t| !t.trim().is_empty()) {
            set(&mut args, "text", json!(text));
        }
        // The composer's model and thinking-level choices, from that computer's own list.
        for key in ["model", "effort"] {
            if let Some(value) = str_of(params, key).filter(|v| !v.trim().is_empty()) {
                set(&mut args, key, json!(value));
            }
        }
        let created = self
            .call(CallKind::Mutation, "sessions:create", args)
            .await?;
        let doc = str_of(&created, "sessionDocId")
            .ok_or_else(|| error("The relay did not start the session."))?;
        Ok(json!({
            "sessionId": format!("{RELAY_PREFIX}{doc}"),
            "commandId": created.get("commandId"),
        }))
    }

    /// Sends a prompt to the computer running the session and waits for its turn to end there.
    pub(crate) async fn prompt(
        self: &Rc<Self>,
        acp_id: &str,
        prompt_id: Option<String>,
        text: String,
    ) -> acp::Result<acp::PromptResponse> {
        let doc = doc_id(acp_id)
            .ok_or_else(|| error("Not a session of another computer."))?
            .to_string();
        if !self.views.borrow().contains_key(&doc) {
            self.load(acp_id).await?;
        }
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err(error("The prompt is empty."));
        }
        let client_id = uuid::Uuid::new_v4().to_string();
        let prompt_id = prompt_id.unwrap_or_else(|| format!("relay-{client_id}"));
        let (waiter, outcome) = oneshot::channel();
        if let Some(view) = self.views.borrow_mut().get_mut(&doc) {
            view.mine.insert(
                client_id.clone(),
                Mine {
                    prompt_id: prompt_id.clone(),
                    command_id: None,
                    waiter: Some(waiter),
                    cancelled: false,
                    finished: None,
                },
            );
        }
        let sent = self
            .call(
                CallKind::Mutation,
                "commands:sendPrompt",
                json!({ "sessionDocId": doc, "text": text, "clientId": client_id }),
            )
            .await;
        let command_id = match sent {
            Ok(value) => str_of(&value, "commandId").map(str::to_owned),
            Err(failure) => {
                if let Some(view) = self.views.borrow_mut().get_mut(&doc) {
                    view.mine.remove(&client_id);
                }
                return Err(failure);
            }
        };
        if let Some(view) = self.views.borrow_mut().get_mut(&doc)
            && let Some(mine) = view.mine.get_mut(&client_id)
        {
            mine.command_id = command_id;
        }
        // The agent echoes every prompt; front ends show their own from it.
        let _ = self.notify(
            acp_id,
            json!({ "sessionUpdate": "user_message_chunk", "content": { "type": "text", "text": text } }),
            Some(&prompt_id),
            false,
        );
        let stop_reason = match outcome.await {
            Ok(Ok(reason)) => reason,
            Ok(Err(message)) => {
                self.prompt_complete(acp_id, &prompt_id, "refusal");
                return Err(error(message));
            }
            Err(_) => acp::StopReason::Cancelled,
        };
        let reason = match stop_reason {
            acp::StopReason::Cancelled => "cancelled",
            _ => "end_turn",
        };
        self.prompt_complete(acp_id, &prompt_id, reason);
        serde_json::from_value(json!({ "stopReason": reason }))
            .map_err(|failure| error(format!("cannot build the prompt response: {failure}")))
    }

    fn prompt_complete(&self, acp_id: &str, prompt_id: &str, stop_reason: &str) {
        self.ext_notify(
            super::PROMPT_COMPLETE_METHOD,
            json!({ "sessionId": acp_id, "promptId": prompt_id, "stopReason": stop_reason }),
        );
    }

    pub(crate) async fn cancel(&self, acp_id: &str) -> acp::Result<()> {
        let Some(doc) = doc_id(acp_id).map(str::to_owned) else {
            return Ok(());
        };
        if let Some(view) = self.views.borrow_mut().get_mut(&doc) {
            for mine in view.mine.values_mut() {
                mine.cancelled = true;
            }
        }
        self.call(
            CallKind::Mutation,
            "commands:stop",
            json!({ "sessionDocId": doc }),
        )
        .await
        .map(|_| ())
    }

    /// The front end closed the session: stop watching it.
    pub(crate) fn close(&self, acp_id: &str) {
        let Some(doc) = doc_id(acp_id) else {
            return;
        };
        let removed = self.views.borrow_mut().remove(doc);
        if let Some(view) = removed {
            for id in view.feeds {
                self.unsubscribe(id);
            }
            for (_, mine) in view.mine {
                if let Some(waiter) = mine.waiter {
                    let _ = waiter.send(Ok(acp::StopReason::Cancelled));
                }
            }
        }
    }

    /// `x.ai/session/info` for a session of another computer: what the relay knows, in the agent's shape.
    pub(crate) async fn info(&self, acp_id: &str) -> acp::Result<Value> {
        let doc = doc_id(acp_id).ok_or_else(|| error("Not a session of another computer."))?;
        let detail = match self.views.borrow().get(doc) {
            Some(view) => view.detail.clone(),
            None => Value::Null,
        };
        let detail = if detail.is_null() {
            self.call(
                CallKind::Query,
                "sessions:get",
                json!({ "sessionDocId": doc }),
            )
            .await?
        } else {
            detail
        };
        let usage = detail.get("usage").cloned().unwrap_or(Value::Null);
        // In the agent's `ExtMethodResult` envelope, as a session of this computer answers (the TUI reads `result`).
        Ok(json!({ "result": {
            "sessionId": acp_id,
            "title": detail.get("title"),
            "cwd": detail.get("cwd"),
            "model": detail.get("model"),
            "modelId": detail.get("model"),
            "effort": detail.get("effort"),
            "gitBranch": detail.get("gitBranch"),
            "computer": detail.get("deviceName"),
            "status": detail.get("status"),
            "outputTokensPerSecond": usage.get("outputTokensPerSecond"),
            "usage": usage,
            "context": {
                "used": usage.get("contextTokens"),
                "total": usage.get("contextWindow"),
            },
            "remote": true,
        } }))
    }

    /// `x.ai/session/usage` for a session of another computer: the totals its computer last reported.
    pub(crate) async fn usage(&self, acp_id: &str) -> acp::Result<Value> {
        let doc = doc_id(acp_id).ok_or_else(|| error("Not a session of another computer."))?;
        let detail = match self.views.borrow().get(doc) {
            Some(view) if !view.detail.is_null() => view.detail.clone(),
            _ => {
                self.call(
                    CallKind::Query,
                    "sessions:get",
                    json!({ "sessionDocId": doc }),
                )
                .await?
            }
        };
        let usage = detail.get("usage").cloned().unwrap_or(Value::Null);
        let number = |key: &str| usage.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        let input = number("inputTokens");
        let output = number("outputTokens");
        let cost = usage.get("costUsd").and_then(Value::as_f64);
        let calls = if output > 0.0 || input > 0.0 { 1 } else { 0 };
        let mut totals = json!({
            "inputTokens": input,
            "outputTokens": output,
            "cachedReadTokens": number("cachedTokens"),
            "reasoningTokens": number("reasoningTokens"),
            "totalTokens": input + output,
            "modelCalls": calls,
            "apiDurationMs": 0,
        });
        if let Some(cost) = cost {
            totals["costUsdTicks"] = json!(cost * 10_000_000_000.0);
        }
        Ok(json!({ "usage": totals }))
    }

    /// `x.ai/remote/git` for a session of another computer: a read (or a branch change) in its folder, run by a
    /// crok on that computer.
    pub(crate) async fn git(self: &Rc<Self>, acp_id: &str, params: &Value) -> acp::Result<Value> {
        let doc = doc_id(acp_id)
            .ok_or_else(|| error("Not a session of another computer."))?
            .to_string();
        let request = params.get("request").cloned().unwrap_or_else(|| {
            let mut request = params.clone();
            if let Some(object) = request.as_object_mut() {
                object.remove("sessionId");
            }
            request
        });
        let sent = self
            .call(
                CallKind::Mutation,
                "commands:git",
                json!({ "sessionDocId": doc, "request": request.to_string() }),
            )
            .await?;
        let command_id = str_of(&sent, "commandId")
            .ok_or_else(|| error("The relay did not take the request."))?
            .to_string();
        let started = Instant::now();
        loop {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let command = self
                .call(
                    CallKind::Query,
                    "commands:get",
                    json!({ "commandId": command_id }),
                )
                .await?;
            match str_of(&command, "status") {
                Some("done") => {
                    let result = command.get("result").cloned().unwrap_or(Value::Null);
                    return if result.is_object() {
                        Ok(result)
                    } else {
                        Err(error("The other computer sent no answer."))
                    };
                }
                Some("failed") => {
                    return Err(error(
                        str_of(&command, "error")
                            .unwrap_or("The other computer could not read its repository.")
                            .to_string(),
                    ));
                }
                _ if started.elapsed() >= Duration::from_secs(45) => {
                    return Err(error("The other computer did not answer in time."));
                }
                _ => {}
            }
        }
    }

    // MARK: The list of other computers' sessions

    fn subscribe_list(&self) {
        if self.list.borrow().feed.is_some() {
            return;
        }
        let feed = self.subscribe(Feed::Groups, "", "sessions:groups", json!({}));
        self.list.borrow_mut().feed = feed;
    }

    /// The other computers' sessions, waiting a moment for the first copy; keeps them current for a while.
    async fn groups(&self, watch: bool) -> Option<Value> {
        if !self.signed_in() {
            return None;
        }
        {
            let mut list = self.list.borrow_mut();
            list.last_use = Some(Instant::now());
            if watch {
                list.watch_until = Some(Instant::now() + LIST_KEEP);
            }
        }
        self.subscribe_list();
        let waiting = {
            let mut list = self.list.borrow_mut();
            if list.groups.is_some() {
                None
            } else {
                let (tx, rx) = oneshot::channel();
                list.waiters.push(tx);
                Some(rx)
            }
        };
        if let Some(rx) = waiting {
            let _ = tokio::time::timeout(LIST_FIRST_WAIT, rx).await;
        }
        self.list.borrow().groups.clone()
    }

    /// The groups of `sessions:groups` that belong to other computers.
    fn foreign_groups(&self, groups: &Value) -> Vec<Value> {
        let me = self.device_id.borrow().clone();
        groups
            .as_array()
            .map(|groups| {
                groups
                    .iter()
                    .filter(|g| str_of(g, "deviceId") != me.as_deref())
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    fn list_payload(&self, groups: Option<&Value>) -> Value {
        let Some(groups) = groups else {
            return json!({ "signedIn": self.signed_in(), "computers": [] });
        };
        let mut computers: Vec<Value> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        for group in self.foreign_groups(groups) {
            let device = str_of(&group, "deviceId").unwrap_or_default().to_string();
            let at = *index.entry(device.clone()).or_insert_with(|| {
                computers.push(json!({
                    "deviceId": device,
                    "deviceName": group.get("deviceName"),
                    "online": group.get("deviceOnline"),
                    "lastSeenAt": group.get("deviceLastSeenAt"),
                    "projects": [],
                }));
                computers.len() - 1
            });
            let sessions: Vec<Value> = group
                .get("sessions")
                .and_then(Value::as_array)
                .map(|rows| rows.iter().map(session_entry).collect())
                .unwrap_or_default();
            if let Some(projects) = computers
                .get_mut(at)
                .and_then(|computer| computer.get_mut("projects"))
                .and_then(Value::as_array_mut)
            {
                projects.push(json!({
                    "key": group.get("key"),
                    "name": group.get("name"),
                    "path": group.get("path"),
                    "sessions": sessions,
                }));
            }
        }
        json!({ "signedIn": true, "computers": computers })
    }

    /// `x.ai/remote/sessions`.
    pub(crate) async fn sessions(&self, params: &Value) -> Value {
        let watch = params
            .get("watch")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let groups = self.groups(watch).await;
        self.list_payload(groups.as_ref())
    }

    /// Rows for `x.ai/session/list` (the TUI's session picker): one per session of another computer, `source: relay`.
    pub(crate) async fn picker_rows(&self) -> Vec<Value> {
        let Some(groups) = self.groups(false).await else {
            return Vec::new();
        };
        let mut rows = Vec::new();
        for group in self.foreign_groups(&groups) {
            let computer = str_of(&group, "deviceName").unwrap_or_default().to_string();
            for session in group
                .get("sessions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(doc) = str_of(session, "_id") else {
                    continue;
                };
                let last = session
                    .get("lastActivityAt")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0);
                let title = str_of(session, "title")
                    .filter(|t| !t.trim().is_empty())
                    .or_else(|| str_of(session, "projectName"))
                    .unwrap_or("session");
                rows.push(json!({
                    "sessionId": format!("{RELAY_PREFIX}{doc}"),
                    // The picker's badge says "other computer"; the summary says which one.
                    "summary": format!("{title} · {computer}"),
                    "cwd": session.get("cwd"),
                    "hostname": computer,
                    "source": "relay",
                    "updatedAt": rfc3339(last),
                    "createdAt": rfc3339(last),
                    "lastActiveAt": rfc3339(last),
                    "modelId": session.get("model"),
                    "lastTurnSummary": session.get("preview"),
                }));
            }
        }
        rows
    }

    // MARK: What the relay says

    /// A subscribed query's new value.
    pub(crate) fn on_query(self: &Rc<Self>, id: u64, result: Result<Value, String>) {
        let Some((feed, doc)) = self.feeds.borrow().get(&id).cloned() else {
            return;
        };
        let value = match result {
            Ok(value) => value,
            Err(failure) => {
                tracing::debug!(%failure, ?feed, "remote viewer: query failed");
                return;
            }
        };
        match feed {
            Feed::Detail => self.on_detail(&doc, value),
            Feed::Events => {
                let mut events: Vec<Value> = value
                    .get("page")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                events.reverse();
                let _ = self.apply_events(&doc, &events, false);
            }
            Feed::Commands => self.on_commands(&doc, &value),
            Feed::Groups => self.on_groups(value),
            Feed::Models => self.on_models(&doc, value),
        }
    }

    /// The computer's list of models arrived or changed: the front end's pickers follow it.
    fn on_models(&self, doc: &str, models: Value) {
        let changed = {
            let mut views = self.views.borrow_mut();
            let Some(view) = views.get_mut(doc) else {
                return;
            };
            if view.models.as_ref() == Some(&models) {
                return;
            }
            view.models = Some(models);
            (view.acp_id.clone(), view.choices())
        };
        let (acp_id, choices) = changed;
        let _ = self.notify(
            &acp_id,
            json!({ "sessionUpdate": "config_option_update", "configOptions": choices.config_options() }),
            None,
            false,
        );
    }

    fn on_groups(&self, value: Value) {
        let (waiters, watching) = {
            let mut list = self.list.borrow_mut();
            list.groups = Some(value.clone());
            (
                std::mem::take(&mut list.waiters),
                list.watch_until.is_some_and(|until| until > Instant::now()),
            )
        };
        for waiter in waiters {
            let _ = waiter.send(());
        }
        if watching {
            let payload = self.list_payload(Some(&value));
            self.ext_notify(REMOTE_SESSIONS_CHANGED_METHOD, payload);
        }
    }

    fn on_detail(self: &Rc<Self>, doc: &str, detail: Value) {
        let mut ask: Option<(String, Value)> = None;
        let mut resolved: Option<(String, String)> = None;
        let mut foreign_done: Option<(String, String)> = None;
        let mut changed_choices: Option<(String, Choices)> = None;
        let mut usage_changed: Option<(String, Value)> = None;
        {
            let mut views = self.views.borrow_mut();
            let Some(view) = views.get_mut(doc) else {
                return;
            };
            let was_running = view.status() != "idle";
            let before_usage = view.detail.get("usage").cloned();
            let before = (
                str_of(&view.detail, "model").map(str::to_owned),
                str_of(&view.detail, "effort").map(str::to_owned),
            );
            view.detail = detail;
            let after_usage = view.detail.get("usage").cloned();
            if before_usage != after_usage
                && let Some(usage) = after_usage.filter(|usage| usage.is_object())
            {
                usage_changed = Some((view.acp_id.clone(), usage));
            }
            let after = (
                str_of(&view.detail, "model").map(str::to_owned),
                str_of(&view.detail, "effort").map(str::to_owned),
            );
            if before != after && after.0.is_some() {
                changed_choices = Some((view.acp_id.clone(), view.choices()));
            }
            let now_idle = view.status() == "idle" || view.status() == "error";
            if was_running
                && now_idle
                && view.turn_foreign
                && let Some(prompt) = view.turn_prompt.take()
            {
                view.turn_foreign = false;
                foreign_done = Some((view.acp_id.clone(), prompt));
            }
            let pending = view
                .detail
                .get("pending")
                .filter(|p| p.is_object())
                .cloned();
            match pending {
                Some(pending) => {
                    let id = str_of(&pending, "id").unwrap_or_default().to_string();
                    if view.asked.as_deref() != Some(id.as_str()) {
                        view.asked = Some(id.clone());
                        ask = Some((id, pending));
                    }
                }
                None => {
                    if let Some(id) = view.asked.take() {
                        resolved = Some((view.acp_id.clone(), tool_call_id(&id)));
                    }
                }
            }
        }
        if let Some((acp_id, prompt)) = foreign_done {
            self.prompt_complete(&acp_id, &prompt, "end_turn");
        }
        if let Some((acp_id, usage)) = usage_changed {
            self.notify_usage(&acp_id, usage);
        }
        if let Some((acp_id, choices)) = changed_choices {
            // As the agent tells a front end about a model switch made elsewhere.
            self.ext_notify(
                "x.ai/session_notification",
                json!({
                    "sessionId": acp_id,
                    "update": {
                        "sessionUpdate": "model_changed",
                        "model_id": choices.model,
                        "reasoning_effort": choices.effort,
                    },
                }),
            );
            let _ = self.notify(
                &acp_id,
                json!({ "sessionUpdate": "config_option_update", "configOptions": choices.config_options() }),
                None,
                false,
            );
        }
        if let Some((acp_id, tool_call)) = resolved {
            self.ext_notify(
                PERMISSION_RESOLVED_METHOD,
                json!({ "sessionId": acp_id, "toolCallId": tool_call }),
            );
        }
        if let Some((id, pending)) = ask {
            self.ask_permission(doc, id, pending);
        }
        self.settle(doc);
    }

    /// The session's token and speed figures, as the agent reports a response's end. The relay carries the session's
    /// totals; its rate is the session average (`outputTokensPerSecond`).
    fn notify_usage(&self, acp_id: &str, usage: Value) {
        let mut update = json!({ "sessionUpdate": "remote_usage", "usage": usage });
        if let Some(rate) = usage
            .get("outputTokensPerSecond")
            .filter(|rate| rate.is_number())
        {
            update["tokensPerSecond"] = rate.clone();
        }
        self.ext_notify(
            "x.ai/session_notification",
            json!({ "sessionId": acp_id, "update": update }),
        );
    }

    /// Asks the front end the permission question the session waits on; its choice goes back to the relay.
    fn ask_permission(self: &Rc<Self>, doc: &str, id: String, pending: Value) {
        let Some(gateway) = self.gateway() else {
            return;
        };
        let Some(acp_id) = self.views.borrow().get(doc).map(|v| v.acp_id.clone()) else {
            return;
        };
        let options: Vec<Value> = pending
            .get("options")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut tool_call = json!({
            "toolCallId": tool_call_id(&id),
            "title": pending.get("title"),
            "status": "pending",
        });
        if let Some(kind) = str_of(&pending, "toolKind") {
            set(&mut tool_call, "kind", json!(kind));
        }
        if let Some(detail) = str_of(&pending, "detail").filter(|d| !d.is_empty()) {
            set(
                &mut tool_call,
                "content",
                json!([{ "type": "content", "content": { "type": "text", "text": detail } }]),
            );
        }
        let request = json!({ "sessionId": acp_id, "toolCall": tool_call, "options": options });
        let request = match serde_json::from_value::<acp::RequestPermissionRequest>(request) {
            Ok(request) => request,
            Err(failure) => {
                tracing::debug!(%failure, "remote viewer: unexpected permission shape");
                return;
            }
        };
        let viewer = Rc::clone(self);
        let doc = doc.to_string();
        tokio::task::spawn_local(async move {
            let Ok(response) = gateway.request_permission(request).await else {
                return;
            };
            let outcome = serde_json::to_value(&response.outcome).unwrap_or(Value::Null);
            let Some(option) = str_of(&outcome, "optionId").map(str::to_owned) else {
                return;
            };
            let still = viewer
                .views
                .borrow()
                .get(&doc)
                .is_some_and(|v| v.asked.as_deref() == Some(id.as_str()));
            if still {
                let _ = viewer
                    .call(
                        CallKind::Mutation,
                        "commands:answer",
                        json!({ "sessionDocId": doc, "interactionId": id, "optionId": option }),
                    )
                    .await;
            }
        });
    }

    fn on_commands(&self, doc: &str, value: &Value) {
        {
            let mut views = self.views.borrow_mut();
            let Some(view) = views.get_mut(doc) else {
                return;
            };
            for command in value.as_array().into_iter().flatten() {
                let Some(client_id) = str_of(command, "clientId") else {
                    continue;
                };
                let Some(mine) = view.mine.get_mut(client_id) else {
                    continue;
                };
                if mine.command_id.is_none() {
                    mine.command_id = str_of(command, "_id").map(str::to_owned);
                }
                if mine.finished.is_some() {
                    continue;
                }
                match str_of(command, "status") {
                    Some("done") => mine.finished = Some((Instant::now(), Ok(()))),
                    Some("failed") => {
                        let message = str_of(command, "error")
                            .unwrap_or("The computer could not run this prompt.")
                            .to_string();
                        mine.finished = Some((Instant::now(), Err(message)));
                    }
                    _ => {}
                }
            }
        }
        self.settle(doc);
    }

    /// Returns finished prompts a moment after the session is idle there (or a while after they finished).
    fn settle(&self, doc: &str) {
        let mut views = self.views.borrow_mut();
        let Some(view) = views.get_mut(doc) else {
            return;
        };
        let idle = view.status() != "running";
        let mut done: Vec<String> = Vec::new();
        for (client_id, mine) in &view.mine {
            if let Some((at, _)) = &mine.finished
                && ((idle && at.elapsed() >= SETTLE) || at.elapsed() >= SETTLE_MAX)
            {
                done.push(client_id.clone());
            }
        }
        for client_id in done {
            let Some(mine) = view.mine.remove(&client_id) else {
                continue;
            };
            if view.turn_prompt.as_deref() == Some(mine.prompt_id.as_str()) {
                view.turn_prompt = None;
            }
            let outcome = match mine.finished {
                Some((_, Err(message))) => Err(message),
                _ if mine.cancelled => Ok(acp::StopReason::Cancelled),
                _ => Ok(acp::StopReason::EndTurn),
            };
            if let Some(waiter) = mine.waiter {
                let _ = waiter.send(outcome);
            }
        }
    }

    /// Transcript items (oldest first) into updates for the front end: new items in full, changed ones as the part that
    /// changed. A replay returns the receivers that complete as its updates are delivered.
    fn apply_events(
        &self,
        doc: &str,
        events: &[Value],
        replay: bool,
    ) -> Vec<oneshot::Receiver<xai_acp_lib::AcpResult<()>>> {
        let mut out: Vec<(String, Value, Option<String>)> = Vec::new();
        let mut prompts: Vec<(String, Value)> = Vec::new();
        {
            let mut views = self.views.borrow_mut();
            let Some(view) = views.get_mut(doc) else {
                return Vec::new();
            };
            let present: HashSet<&str> = events.iter().filter_map(|e| str_of(e, "key")).collect();
            let computer = view.computer();
            for event in events {
                let Some(key) = str_of(event, "key").map(str::to_owned) else {
                    continue;
                };
                let kind = str_of(event, "kind").unwrap_or("system").to_string();
                let text = str_of(event, "text").unwrap_or_default().to_string();
                let title = str_of(event, "title").map(str::to_owned);
                let status = str_of(event, "status").map(str::to_owned);
                let textual = matches!(kind.as_str(), "user" | "assistant" | "thought");
                if let Some(prev) = view.seen.get(&key).cloned() {
                    match kind.as_str() {
                        "assistant" | "thought" if text != prev.text => {
                            if let Some(delta) = text.strip_prefix(prev.text.as_str()) {
                                let update = text_update(&kind, delta);
                                out.push((view.acp_id.clone(), update, view.turn_prompt.clone()));
                            }
                        }
                        "tool"
                            if text != prev.text
                                || title != prev.title
                                || status != prev.status =>
                        {
                            let mut update =
                                json!({ "sessionUpdate": "tool_call_update", "toolCallId": key });
                            if status != prev.status
                                && let Some(status) = &status
                            {
                                set(&mut update, "status", json!(status));
                            }
                            if title != prev.title
                                && let Some(title) = &title
                            {
                                set(&mut update, "title", json!(title));
                            }
                            if text != prev.text {
                                set(&mut update, "content", tool_content(&text));
                            }
                            out.push((view.acp_id.clone(), update, view.turn_prompt.clone()));
                        }
                        _ => {}
                    }
                    if textual {
                        view.by_content.remove(&text_hash(&kind, &prev.text));
                        view.by_content.insert(text_hash(&kind, &text), key.clone());
                    }
                    view.seen.insert(
                        key,
                        Seen {
                            kind,
                            text,
                            title,
                            status,
                        },
                    );
                    continue;
                }
                // The computer re-sent the transcript under new keys (it read it from disk again): same item.
                if textual
                    && !replay
                    && let Some(old) = view.by_content.get(&text_hash(&kind, &text)).cloned()
                    && !present.contains(old.as_str())
                {
                    if let Some(seen) = view.seen.remove(&old) {
                        view.seen.insert(key.clone(), seen);
                    }
                    view.by_content.insert(text_hash(&kind, &text), key);
                    continue;
                }
                match kind.as_str() {
                    "user" => {
                        let command = str_of(event, "commandId");
                        let mine = command.and_then(|command| {
                            view.mine
                                .values()
                                .find(|m| m.command_id.as_deref() == Some(command))
                                .map(|m| m.prompt_id.clone())
                        });
                        match mine {
                            Some(prompt_id) => {
                                view.turn_prompt = Some(prompt_id);
                                view.turn_foreign = false;
                            }
                            None => {
                                let prompt_id =
                                    format!("remote-{}", command.unwrap_or(key.as_str()));
                                let update = text_update("user", &text);
                                out.push((view.acp_id.clone(), update, Some(prompt_id.clone())));
                                if !replay {
                                    let from = str_of(event, "fromLabel")
                                        .map(str::to_owned)
                                        .unwrap_or_else(|| computer.clone());
                                    prompts.push((
                                        view.acp_id.clone(),
                                        json!({
                                            "sessionId": view.acp_id,
                                            "promptId": prompt_id,
                                            "text": text,
                                            "from": from,
                                            "fromKind": "computer",
                                        }),
                                    ));
                                    view.turn_prompt = Some(prompt_id);
                                    view.turn_foreign = true;
                                }
                            }
                        }
                    }
                    "assistant" | "thought" => {
                        out.push((
                            view.acp_id.clone(),
                            text_update(&kind, &text),
                            view.turn_prompt.clone(),
                        ));
                    }
                    "tool" => {
                        let mut update = json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": key,
                            "title": title.clone().unwrap_or_else(|| "Tool".into()),
                            "status": status.clone().unwrap_or_else(|| "completed".into()),
                        });
                        if let Some(tool_kind) = str_of(event, "toolKind") {
                            set(&mut update, "kind", json!(tool_kind));
                        }
                        if !text.is_empty() {
                            set(&mut update, "content", tool_content(&text));
                        }
                        out.push((view.acp_id.clone(), update, view.turn_prompt.clone()));
                    }
                    "error" if !text.is_empty() => {
                        out.push((
                            view.acp_id.clone(),
                            text_update("assistant", &format!("\n\n{text}\n")),
                            view.turn_prompt.clone(),
                        ));
                    }
                    _ => {}
                }
                if textual {
                    view.by_content.insert(text_hash(&kind, &text), key.clone());
                }
                view.seen.insert(
                    key,
                    Seen {
                        kind,
                        text,
                        title,
                        status,
                    },
                );
            }
        }
        // `x.ai/remote/prompt` first: Crok Desktop starts the turn from it and drops live user messages.
        for (_, params) in prompts {
            self.ext_notify(super::REMOTE_PROMPT_METHOD, params);
        }
        out.into_iter()
            .filter_map(|(acp_id, update, prompt_id)| {
                self.notify(&acp_id, update, prompt_id.as_deref(), replay)
            })
            .collect()
    }

    /// Every 250 ms from the bridge: keep watching open sessions, let finished prompts return, drop an unused list.
    pub(crate) fn tick(&self) {
        let due: Vec<String> = self
            .views
            .borrow_mut()
            .iter_mut()
            .filter(|(_, view)| view.last_watch.elapsed() >= WATCH_EVERY)
            .map(|(doc, view)| {
                view.last_watch = Instant::now();
                doc.clone()
            })
            .collect();
        for doc in due {
            self.fire("sessions:watch", json!({ "sessionDocId": doc }));
        }
        let docs: Vec<String> = self.views.borrow().keys().cloned().collect();
        for doc in docs {
            self.settle(&doc);
        }
        let stale = {
            let list = self.list.borrow();
            list.feed
                .filter(|_| list.last_use.is_none_or(|t| t.elapsed() >= LIST_KEEP))
        };
        if let Some(feed) = stale {
            self.unsubscribe(feed);
            let mut list = self.list.borrow_mut();
            list.feed = None;
            list.groups = None;
        }
    }
}

/// What a session of another computer offers to choose (its computer's `devices:models`, else `sessions:get`'s
/// `models`, with the session's `model` and `effort`), in the agent's shapes: `models` for the TUI's picker,
/// `configOptions` for Crok Desktop's.
#[derive(Default)]
struct Choices {
    models: Vec<Value>,
    model: Option<String>,
    /// The level itself (`high`), as sessions report it.
    effort: Option<String>,
}

impl Choices {
    /// `models` is the computer's list from `devices:models` when known (null while it is offline); `sessions:get` embeds
    /// only short lists, so its copy is the fallback for a relay without that query.
    fn of(detail: &Value, models: Option<&Value>) -> Choices {
        Choices {
            models: models
                .and_then(Value::as_array)
                .or_else(|| detail.get("models").and_then(Value::as_array))
                .cloned()
                .unwrap_or_default(),
            model: str_of(detail, "model")
                .filter(|m| !m.is_empty())
                .map(str::to_owned),
            effort: str_of(detail, "effort")
                .filter(|e| !e.is_empty())
                .map(str::to_owned),
        }
    }

    fn current(&self) -> Option<&Value> {
        let model = self.model.as_deref()?;
        self.models.iter().find(|m| str_of(m, "id") == Some(model))
    }

    fn efforts(&self) -> Vec<Value> {
        self.current()
            .and_then(|m| m.get("efforts"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }

    /// The option id of a thinking level of the current model, named by id, level or name.
    fn effort_id(&self, wanted: &str) -> Option<String> {
        self.efforts()
            .iter()
            .find(|e| {
                [str_of(e, "value"), str_of(e, "id"), str_of(e, "name")]
                    .into_iter()
                    .flatten()
                    .any(|name| name.eq_ignore_ascii_case(wanted))
            })
            .and_then(|e| str_of(e, "id"))
            .map(str::to_owned)
    }

    /// The selected thinking level's option id: the session's level, else the model's default, else the first.
    fn effort_selected(&self) -> Option<String> {
        let efforts = self.efforts();
        self.effort
            .as_deref()
            .and_then(|level| self.effort_id(level))
            .or_else(|| {
                self.current()
                    .and_then(|m| str_of(m, "defaultEffort"))
                    .map(str::to_owned)
            })
            .or_else(|| {
                efforts
                    .first()
                    .and_then(|e| str_of(e, "id"))
                    .map(str::to_owned)
            })
    }

    fn model_state(&self) -> Value {
        let mut available: Vec<Value> = self
            .models
            .iter()
            .map(|model| {
                let id = str_of(model, "id").unwrap_or_default();
                let efforts: Vec<Value> = model
                    .get("efforts")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(|e| {
                        let effort_id = str_of(e, "id").unwrap_or_default();
                        json!({
                            "id": effort_id,
                            "value": str_of(e, "value").unwrap_or(effort_id),
                            "label": e.get("name"),
                            "description": e.get("description"),
                            "default": str_of(model, "defaultEffort") == Some(effort_id),
                        })
                    })
                    .collect();
                let mut meta = json!({
                    "supportsReasoningEffort": !efforts.is_empty(),
                    "reasoningEfforts": efforts,
                });
                if Some(id) == self.model.as_deref()
                    && let Some(effort) = &self.effort
                {
                    set(&mut meta, "reasoningEffort", json!(effort));
                }
                json!({
                    "modelId": id,
                    "name": str_of(model, "name").unwrap_or(id),
                    "description": model.get("description"),
                    "_meta": meta,
                })
            })
            .collect();
        if available.is_empty()
            && let Some(model) = &self.model
        {
            // Its computer is offline: nothing to choose from, but the picker still names the model.
            available.push(json!({ "modelId": model, "name": model }));
        }
        json!({
            "currentModelId": self.model.clone().unwrap_or_default(),
            "availableModels": available,
        })
    }

    fn config_options(&self) -> Vec<Value> {
        let mut options = Vec::new();
        if !self.models.is_empty() {
            let values: Vec<acp::SessionConfigSelectOption> = self
                .models
                .iter()
                .filter_map(|m| {
                    let id = str_of(m, "id")?;
                    Some(acp::SessionConfigSelectOption::new(
                        id.to_string(),
                        str_of(m, "name").unwrap_or(id).to_string(),
                    ))
                })
                .collect();
            options.push(
                acp::SessionConfigOption::select(
                    "model",
                    "Model",
                    self.model.clone().unwrap_or_default(),
                    values,
                )
                .category(acp::SessionConfigOptionCategory::Model),
            );
        }
        let efforts = self.efforts();
        if let Some(selected) = self.effort_selected().filter(|_| !efforts.is_empty()) {
            let values: Vec<acp::SessionConfigSelectOption> = efforts
                .iter()
                .filter_map(|e| {
                    let id = str_of(e, "id")?;
                    let mut value = acp::SessionConfigSelectOption::new(
                        id.to_string(),
                        str_of(e, "name").unwrap_or(id).to_string(),
                    );
                    if let Some(description) = str_of(e, "description") {
                        value = value.description(description.to_string());
                    }
                    Some(value)
                })
                .collect();
            options.push(
                acp::SessionConfigOption::select(
                    "reasoning_effort",
                    "Reasoning Effort",
                    selected,
                    values,
                )
                .category(acp::SessionConfigOptionCategory::ThoughtLevel),
            );
        }
        options
            .iter()
            .filter_map(|option| serde_json::to_value(option).ok())
            .collect()
    }
}

/// A list row of `sessions:groups` as a front end lists it.
fn session_entry(row: &Value) -> Value {
    json!({
        "sessionId": format!("{RELAY_PREFIX}{}", str_of(row, "_id").unwrap_or_default()),
        "title": row.get("title"),
        "cwd": row.get("cwd"),
        "status": row.get("status"),
        "running": row.get("online"),
        "lastActivityAt": row.get("lastActivityAt"),
        "model": row.get("model"),
        "gitBranch": row.get("gitBranch"),
        "usage": row.get("usage"),
        "preview": row.get("preview"),
        "pinned": row.get("pinned"),
        "unread": row.get("unread"),
        "starting": row.get("starting"),
    })
}

/// The tool call a pending request is about: its id is `<toolCallId>#<n>` when the computer knew the call.
fn tool_call_id(interaction: &str) -> String {
    interaction
        .split_once('#')
        .map(|(call, _)| call)
        .unwrap_or(interaction)
        .to_string()
}

/// Sets a field of a JSON object (an update or a tool call being built).
fn set(object: &mut Value, key: &str, value: Value) {
    if let Some(object) = object.as_object_mut() {
        object.insert(key.to_string(), value);
    }
}

fn text_update(kind: &str, text: &str) -> Value {
    let update = match kind {
        "user" => "user_message_chunk",
        "thought" => "agent_thought_chunk",
        _ => "agent_message_chunk",
    };
    json!({ "sessionUpdate": update, "content": { "type": "text", "text": text } })
}

fn tool_content(text: &str) -> Value {
    json!([{ "type": "content", "content": { "type": "text", "text": text } }])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_list_row_carries_the_branch_and_token_figures() {
        let row = json!({
            "_id": "k1",
            "title": "Fix the redirect",
            "gitBranch": "fix/login-redirect",
            "usage": { "inputTokens": 1_200, "outputTokens": 300, "cachedTokens": 800 },
        });
        let entry = session_entry(&row);
        assert_eq!(entry["sessionId"], "relay:k1");
        assert_eq!(entry["gitBranch"], "fix/login-redirect");
        assert_eq!(entry["usage"]["outputTokens"], 300);
    }

    #[test]
    fn relay_ids() {
        assert_eq!(doc_id("relay:k57abc"), Some("k57abc"));
        assert_eq!(doc_id("relay:"), None);
        assert_eq!(doc_id("0199-abc"), None);
        assert!(is_relay_session("relay:x"));
    }

    #[test]
    fn interaction_ids_name_their_tool_call() {
        assert_eq!(tool_call_id("call_1#2"), "call_1");
        assert_eq!(tool_call_id("perm-7"), "perm-7");
    }

    #[test]
    fn updates_parse_as_acp() {
        for update in [
            text_update("assistant", "hi"),
            text_update("user", "hi"),
            text_update("thought", "hm"),
            json!({ "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run ls", "status": "pending",
                    "kind": "execute", "content": tool_content("ls") }),
            json!({ "sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed" }),
        ] {
            let notification =
                json!({ "sessionId": "relay:x", "update": update, "_meta": { "isReplay": true } });
            serde_json::from_value::<acp::SessionNotification>(notification).expect("parses");
        }
    }

    fn detail() -> Value {
        json!({
            "model": "grok-4",
            "effort": "medium",
            "models": [
                { "id": "grok-4", "name": "Grok 4", "defaultEffort": "deep", "efforts": [
                    { "id": "balanced", "name": "Balanced", "value": "medium" },
                    { "id": "deep", "name": "Deep", "value": "xhigh" },
                ]},
                { "id": "mini", "name": "Mini", "efforts": [] },
            ],
        })
    }

    #[test]
    fn another_computers_choices_take_the_agents_shapes() {
        let choices = Choices::of(&detail(), None);
        let state = choices.model_state();
        assert_eq!(state["currentModelId"], "grok-4");
        let first = &state["availableModels"][0];
        assert_eq!(first["_meta"]["supportsReasoningEffort"], true);
        assert_eq!(first["_meta"]["reasoningEffort"], "medium");
        assert_eq!(first["_meta"]["reasoningEfforts"][1]["default"], true);
        assert_eq!(
            state["availableModels"][1]["_meta"]["supportsReasoningEffort"],
            false
        );
        serde_json::from_value::<acp::SessionModelState>(state).expect("a model state");
        let options = choices.config_options();
        assert_eq!(options[0]["id"], "model");
        // The session reports the level; the picker selects its option id.
        assert_eq!(options[1]["id"], "reasoning_effort");
        assert_eq!(options[1]["currentValue"], "balanced");
        for option in options {
            serde_json::from_value::<acp::SessionConfigOption>(option).expect("a config option");
        }
    }

    #[test]
    fn levels_are_found_by_id_level_or_name() {
        let choices = Choices::of(&detail(), None);
        assert_eq!(choices.effort_id("xhigh").as_deref(), Some("deep"));
        assert_eq!(choices.effort_id("Balanced").as_deref(), Some("balanced"));
        assert_eq!(choices.effort_id("max"), None);
    }

    #[test]
    fn an_offline_computer_still_names_the_model() {
        let choices = Choices::of(&json!({ "model": "grok-4", "models": null }), None);
        assert_eq!(
            choices.model_state()["availableModels"][0]["modelId"],
            "grok-4"
        );
        assert!(choices.config_options().is_empty());
    }

    #[test]
    fn the_computers_own_list_wins_over_the_short_copy_in_the_session() {
        // `sessions:get` leaves out a long list (null); `devices:models` has it.
        let long: Vec<Value> = (0..450)
            .map(|i| json!({ "id": format!("openrouter/m-{i}"), "name": format!("M {i}"), "efforts": [] }))
            .collect();
        let session = json!({ "model": "openrouter/m-449", "models": null });
        let choices = Choices::of(&session, Some(&json!(long)));
        let state = choices.model_state();
        assert_eq!(state["availableModels"].as_array().map(Vec::len), Some(450));
        assert_eq!(
            choices.config_options()[0]["currentValue"],
            "openrouter/m-449"
        );
        // While the computer is offline `devices:models` is null: the session's own copy stands.
        assert_eq!(Choices::of(&detail(), Some(&Value::Null)).models.len(), 2);
    }

    #[test]
    fn picker_rows_use_relay_ids_and_skip_this_computer() {
        let viewer = Viewer::new();
        *viewer.device_id.borrow_mut() = Some("me".into());
        let groups = json!([
            { "deviceId": "me", "deviceName": "This Mac", "sessions": [{ "_id": "a" }] },
            { "deviceId": "other", "deviceName": "Office PC", "deviceOnline": true, "key": "other:/w", "name": "w",
              "path": "/w", "sessions": [{ "_id": "b", "title": "Fix it", "cwd": "/w", "lastActivityAt": 1.0 }] },
        ]);
        let payload = viewer.list_payload(Some(&groups));
        let computers = payload["computers"].as_array().unwrap();
        assert_eq!(computers.len(), 1);
        assert_eq!(computers[0]["deviceName"], "Office PC");
        assert_eq!(
            computers[0]["projects"][0]["sessions"][0]["sessionId"],
            "relay:b"
        );
    }
}
