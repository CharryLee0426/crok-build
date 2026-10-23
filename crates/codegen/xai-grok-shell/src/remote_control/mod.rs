//! Remote control: mirrors this process's sessions to the relay, runs commands from phones, the web and the person's
//! other computers, and opens those other computers' sessions here (`relay/DESIGN.md` §4).
//!
//! A host (the TUI's agent thread, or a `crok agent stdio` process for Crok Desktop) wires it in three places, all
//! on the agent's `LocalSet`:
//!
//! ```ignore
//! let remote = RemoteControl::new(HostApp::Tui);           // None when the host may not run one
//! let client_rx = remote.tee(client_rx);                    // agent → front end, copied to the bridge
//! let conn = remote.observe(agent.clone());                 // front end → agent: sessions opened, prompts sent
//! let handle = remote.start(&agent);                        // the bridge loop
//! ...
//! handle.shutdown().await;                                  // marks the host offline at once
//! ```
//!
//! Nothing goes over the network until the computer is signed in (`crok remote login`); the bridge notices a sign-in
//! or sign-out made elsewhere within a few seconds.
//!
//! Three kinds of session pass through here:
//!
//! - the front end's own sessions, mirrored to the relay; their permission requests can be answered on the computer
//!   or from any other device, whichever comes first;
//! - sessions the bridge opened itself to run a prompt sent from elsewhere for a session no crok was running
//!   ("adopted"): the front end never hears of them, and the bridge answers their requests through the relay;
//! - sessions of the person's other computers (`relay:<id>`), which [`viewer`] serves to the front end in place of the
//!   agent.

mod bridge;
mod catalog;
mod git;
pub(crate) mod transcript;
pub(crate) mod viewer;

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use agent_client_protocol as acp;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use xai_acp_lib::{AcpArgs, AcpClientMessage, AcpResult};

pub use crok_remote::HostApp;
pub use viewer::{
    PERMISSION_RESOLVED_METHOD, RELAY_PREFIX, REMOTE_NEW_SESSION_METHOD,
    REMOTE_SESSIONS_CHANGED_METHOD, REMOTE_SESSIONS_METHOD,
};

use crate::agent::MvpAgent;
use viewer::Viewer;

/// Ext notification to the front end before a remote prompt runs: `{sessionId, promptId, text, from, fromKind}`
/// (`fromKind`: `phone`, `web` or `computer`). Crok Desktop
/// shows the prompt from it; the TUI already gets it through its user-message echo and shows a toast.
pub const REMOTE_PROMPT_METHOD: &str = "x.ai/remote/prompt";
/// Ext notification of the bridge's state: `{state: "off" | "connecting" | "connected", account?, device?}`.
pub const REMOTE_STATUS_METHOD: &str = "x.ai/remote/status";

/// A permission request the bridge decides with the relay. `front_end` is the front end's own answer when it was asked
/// too (a visible session); an adopted session has nobody here to ask.
pub(crate) struct PermissionAsk {
    pub(crate) session_id: String,
    pub(crate) request: acp::RequestPermissionRequest,
    pub(crate) reply: oneshot::Sender<AcpResult<acp::RequestPermissionResponse>>,
    pub(crate) front_end: Option<oneshot::Receiver<AcpResult<acp::RequestPermissionResponse>>>,
}

/// What the bridge sees of the agent and its front end.
pub(crate) enum Observed {
    /// A notification the agent sent its front end (session updates, roster changes).
    Outgoing {
        method: String,
        params: Value,
    },
    /// The front end opened a session (`loaded`: it has history).
    SessionOpened {
        session_id: String,
        cwd: String,
        loaded: bool,
    },
    /// The front end sent a prompt (typed on the computer).
    PromptSent {
        session_id: String,
        prompt_id: Option<String>,
        text: String,
    },
    SessionClosed {
        session_id: String,
    },
    Permission(Box<PermissionAsk>),
}

struct ObserverInner {
    tx: mpsc::UnboundedSender<Observed>,
    /// Copy session updates only while signed in: serializing every chunk costs CPU for nothing otherwise.
    live: Cell<bool>,
    /// Sessions the bridge runs for prompts sent from elsewhere: kept from the front end.
    hidden: RefCell<HashSet<String>>,
    /// Sessions the relay mirrors: their permission requests are offered to every device.
    shared: RefCell<HashSet<String>>,
    viewer: Rc<Viewer>,
}

#[derive(Clone)]
pub(crate) struct Observer(Rc<ObserverInner>);

impl Observer {
    fn send(&self, observed: Observed) {
        let _ = self.0.tx.send(observed);
    }

    pub(crate) fn set_live(&self, live: bool) {
        self.0.live.set(live);
    }

    fn live(&self) -> bool {
        self.0.live.get()
    }

    pub(crate) fn hide(&self, session_id: &str) {
        self.0.hidden.borrow_mut().insert(session_id.to_string());
    }

    /// The front end opened a session the bridge was running hidden: it sees it from now on.
    pub(crate) fn reveal(&self, session_id: &str) -> bool {
        self.0.hidden.borrow_mut().remove(session_id)
    }

    fn is_hidden(&self, session_id: &str) -> bool {
        let hidden = self.0.hidden.borrow();
        !hidden.is_empty() && hidden.contains(session_id)
    }

    fn any_hidden(&self) -> bool {
        !self.0.hidden.borrow().is_empty()
    }

    pub(crate) fn set_shared(&self, session_id: &str, shared: bool) {
        let mut set = self.0.shared.borrow_mut();
        if shared {
            set.insert(session_id.to_string());
        } else {
            set.remove(session_id);
        }
    }

    fn is_shared(&self, session_id: &str) -> bool {
        self.0.shared.borrow().contains(session_id)
    }

    pub(crate) fn viewer(&self) -> &Rc<Viewer> {
        &self.0.viewer
    }
}

/// Remote control for one agent host, before it starts.
pub struct RemoteControl {
    app: HostApp,
    observer: Observer,
    rx: mpsc::UnboundedReceiver<Observed>,
}

impl RemoteControl {
    /// `None` when this process must not run a bridge (Crok Desktop's helper processes set `CROK_REMOTE_BRIDGE=0`).
    pub fn new(app: HostApp) -> Option<RemoteControl> {
        if !crok_remote::settings::bridge_allowed() {
            return None;
        }
        let (tx, rx) = mpsc::unbounded_channel();
        Some(RemoteControl {
            app,
            observer: Observer(Rc::new(ObserverInner {
                tx,
                live: Cell::new(false),
                hidden: RefCell::new(HashSet::new()),
                shared: RefCell::new(HashSet::new()),
                viewer: Viewer::new(),
            })),
            rx,
        })
    }

    /// Puts the bridge between the agent and its front end's receiver: messages pass through, session notifications
    /// are copied to the bridge, and an adopted session's messages stay with the bridge. Must run on the agent's
    /// `LocalSet`.
    pub fn tee(
        &self,
        from_agent: mpsc::UnboundedReceiver<AcpClientMessage>,
    ) -> mpsc::UnboundedReceiver<AcpClientMessage> {
        let (to_front_end, front_end_rx) = mpsc::unbounded_channel();
        self.tee_to(from_agent, to_front_end);
        front_end_rx
    }

    /// [`Self::tee`] into an existing sender (the TUI's channel to its view).
    pub fn tee_to(
        &self,
        mut from_agent: mpsc::UnboundedReceiver<AcpClientMessage>,
        to_front_end: mpsc::UnboundedSender<AcpClientMessage>,
    ) {
        let observer = self.observer.clone();
        tokio::task::spawn_local(async move {
            while let Some(message) = from_agent.recv().await {
                copy_notification(&observer, &message);
                let Some(message) = route(&observer, message) else {
                    continue;
                };
                if to_front_end.send(message).is_err() {
                    break;
                }
            }
        });
    }

    /// The agent the front end's connection should call, so the bridge sees sessions opened and prompts sent, and
    /// other computers' sessions are served here.
    pub fn observe<A: acp::Agent>(&self, agent: A) -> ObservedAgent<A> {
        ObservedAgent {
            inner: agent,
            observer: Some(self.observer.clone()),
        }
    }

    /// Starts the bridge on the current `LocalSet`.
    pub fn start(self, agent: &Rc<MvpAgent>) -> RemoteHandle {
        let (stop_tx, stop_rx) = oneshot::channel();
        self.observer.viewer().set_gateway(agent.gateway.clone());
        let bridge = bridge::Bridge::new(Rc::downgrade(agent), self.app, self.observer, self.rx);
        tokio::task::spawn_local(bridge.run(stop_rx));
        RemoteHandle {
            stop: Some(stop_tx),
        }
    }
}

/// Stops the bridge. Dropping it stops the bridge too, without waiting for the relay to hear about it.
pub struct RemoteHandle {
    stop: Option<oneshot::Sender<oneshot::Sender<()>>>,
}

impl RemoteHandle {
    /// Stops the bridge and gives the relay up to two seconds to mark this host offline.
    pub async fn shutdown(mut self) {
        let Some(stop) = self.stop.take() else {
            return;
        };
        let (done_tx, done_rx) = oneshot::channel();
        if stop.send(done_tx).is_ok() {
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), done_rx).await;
        }
    }
}

/// The end of every turn, copied even while signed out (once per turn, cheap): the bridge must know which sessions are
/// mid-turn when it starts, or a phone's prompt would wait behind a turn that already ended.
pub(crate) const PROMPT_COMPLETE_METHOD: &str = "x.ai/session/prompt_complete";

fn copy_notification(observer: &Observer, message: &AcpClientMessage) {
    let live = observer.live();
    match message {
        AcpClientMessage::ExtNotification(args)
            if !live && args.request.method.trim_start_matches('_') == PROMPT_COMPLETE_METHOD =>
        {
            if let Ok(params) = serde_json::from_str::<Value>(args.request.params.get()) {
                observer.send(Observed::Outgoing {
                    method: PROMPT_COMPLETE_METHOD.into(),
                    params,
                });
            }
        }
        _ if !live => {}
        AcpClientMessage::SessionNotification(args) => {
            if let Ok(params) = serde_json::to_value(&args.request) {
                observer.send(Observed::Outgoing {
                    method: "session/update".into(),
                    params,
                });
            }
        }
        AcpClientMessage::ExtNotification(args) => {
            let method = args.request.method.trim_start_matches('_');
            let wanted = method == "x.ai/session_notification"
                || method == "x.ai/session/update"
                || method == PROMPT_COMPLETE_METHOD
                || method == crate::agent::roster::SESSIONS_CHANGED_METHOD;
            if wanted && let Ok(params) = serde_json::from_str::<Value>(args.request.params.get()) {
                observer.send(Observed::Outgoing {
                    method: method.to_string(),
                    params,
                });
            }
        }
        _ => {}
    }
}

/// The `sessionId` an ext message's params name, if any.
fn params_session(params: &serde_json::value::RawValue) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Session {
        #[serde(rename = "sessionId")]
        session_id: Option<String>,
    }
    serde_json::from_str::<Session>(params.get())
        .ok()
        .and_then(|s| s.session_id)
}

/// Decides where a message from the agent goes: to the front end (`Some`), or to the bridge only (`None`).
fn route(observer: &Observer, message: AcpClientMessage) -> Option<AcpClientMessage> {
    match message {
        AcpClientMessage::RequestPermission(args) => {
            let session_id = args.request.session_id.to_string();
            if observer.is_hidden(&session_id) {
                observer.send(Observed::Permission(Box::new(PermissionAsk {
                    session_id,
                    request: args.request,
                    reply: args.response_tx,
                    front_end: None,
                })));
                return None;
            }
            if observer.live() && observer.is_shared(&session_id) {
                let (front_tx, front_rx) = oneshot::channel();
                let request = args.request.clone();
                observer.send(Observed::Permission(Box::new(PermissionAsk {
                    session_id,
                    request: args.request,
                    reply: args.response_tx,
                    front_end: Some(front_rx),
                })));
                return Some(AcpClientMessage::RequestPermission(AcpArgs {
                    request,
                    response_tx: front_tx,
                }));
            }
            Some(AcpClientMessage::RequestPermission(args))
        }
        AcpClientMessage::SessionNotification(args)
            if observer.is_hidden(&args.request.session_id.0) =>
        {
            None
        }
        AcpClientMessage::ExtNotification(args)
            if observer.any_hidden()
                && params_session(&args.request.params).is_some_and(|s| observer.is_hidden(&s)) =>
        {
            None
        }
        AcpClientMessage::ExtMethod(args)
            if observer.any_hidden()
                && params_session(&args.request.params).is_some_and(|s| observer.is_hidden(&s)) =>
        {
            // A question or plan approval in a session nobody looks at here: refused, the turn carries on without it.
            let _ = args.response_tx.send(Err(acp::Error::new(
                -32603,
                "This session runs for a prompt sent from another device; it cannot ask questions here.".to_string(),
            )));
            None
        }
        other => Some(other),
    }
}

/// The text of a prompt, for the transcript: text blocks joined, other blocks named.
fn prompt_text(blocks: &[acp::ContentBlock]) -> String {
    let mut parts: Vec<String> = Vec::new();
    for block in blocks {
        match block {
            acp::ContentBlock::Text(text) => parts.push(text.text.clone()),
            acp::ContentBlock::Image(_) => parts.push("[image]".into()),
            acp::ContentBlock::ResourceLink(link) => parts.push(format!("@{}", link.name)),
            acp::ContentBlock::Resource(_) => parts.push("[file]".into()),
            _ => {}
        }
    }
    parts.join("\n")
}

fn ext_response(value: &Value) -> acp::Result<acp::ExtResponse> {
    serde_json::value::to_raw_value(value)
        .map(|raw| acp::ExtResponse::new(raw.into()))
        .map_err(|e| acp::Error::internal_error().data(e.to_string()))
}

fn not_here(what: &str) -> acp::Error {
    acp::Error::new(
        -32603,
        format!("{what} is not available for a session on another computer."),
    )
}

/// Whether a picker row of another computer matches a search: every word in its title, folder or computer name.
fn row_matches(row: &Value, query: &str) -> bool {
    let haystack = ["summary", "cwd", "hostname"]
        .iter()
        .filter_map(|key| row.get(*key).and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    query.split_whitespace().all(|word| haystack.contains(word))
}

/// Adds the person's other computers' sessions to a `x.ai/session/list` result (rows with `source: relay`).
fn append_rows(response: acp::ExtResponse, rows: Vec<Value>) -> acp::ExtResponse {
    if rows.is_empty() {
        return response;
    }
    let Ok(mut value) = serde_json::from_str::<Value>(response.0.get()) else {
        return response;
    };
    let sessions = if value.get("sessions").is_some() {
        value.get_mut("sessions")
    } else {
        value
            .get_mut("result")
            .and_then(|result| result.get_mut("sessions"))
    };
    match sessions.and_then(Value::as_array_mut) {
        Some(sessions) => sessions.extend(rows),
        None => return response,
    }
    ext_response(&value).unwrap_or(response)
}

/// An agent whose front end the bridge watches: like `RequestLog`, every call passes through untouched, except calls
/// for sessions of other computers, which the viewer answers.
pub struct ObservedAgent<A> {
    inner: A,
    observer: Option<Observer>,
}

impl<A> ObservedAgent<A> {
    /// The same agent with nobody watching (a host where remote control is off).
    pub fn unobserved(agent: A) -> ObservedAgent<A> {
        ObservedAgent {
            inner: agent,
            observer: None,
        }
    }

    fn tell(&self, observed: Observed) {
        if let Some(observer) = &self.observer {
            observer.send(observed);
        }
    }

    fn viewer(&self) -> acp::Result<&Rc<Viewer>> {
        self.observer.as_ref().map(Observer::viewer).ok_or_else(|| {
            acp::Error::new(
                -32603,
                "Sessions on other computers need remote control, which is off in this process."
                    .to_string(),
            )
        })
    }

    /// The front end opens a session the bridge runs hidden: show it from now on.
    fn reveal(&self, session_id: &str) {
        if let Some(observer) = &self.observer {
            observer.reveal(session_id);
        }
    }
}

#[async_trait::async_trait(?Send)]
impl<A: acp::Agent> acp::Agent for ObservedAgent<A> {
    async fn initialize(
        &self,
        args: acp::InitializeRequest,
    ) -> acp::Result<acp::InitializeResponse> {
        self.inner.initialize(args).await
    }

    async fn authenticate(
        &self,
        args: acp::AuthenticateRequest,
    ) -> acp::Result<acp::AuthenticateResponse> {
        self.inner.authenticate(args).await
    }

    async fn logout(&self, args: acp::LogoutRequest) -> acp::Result<acp::LogoutResponse> {
        self.inner.logout(args).await
    }

    async fn new_session(
        &self,
        args: acp::NewSessionRequest,
    ) -> acp::Result<acp::NewSessionResponse> {
        let cwd = args.cwd.to_string_lossy().to_string();
        let response = self.inner.new_session(args).await?;
        self.tell(Observed::SessionOpened {
            session_id: response.session_id.to_string(),
            cwd,
            loaded: false,
        });
        Ok(response)
    }

    async fn load_session(
        &self,
        args: acp::LoadSessionRequest,
    ) -> acp::Result<acp::LoadSessionResponse> {
        let session_id = args.session_id.to_string();
        if viewer::is_relay_session(&session_id) {
            return self.viewer()?.load(&session_id).await;
        }
        self.reveal(&session_id);
        let cwd = args.cwd.to_string_lossy().to_string();
        let response = self.inner.load_session(args).await?;
        self.tell(Observed::SessionOpened {
            session_id,
            cwd,
            loaded: true,
        });
        Ok(response)
    }

    async fn prompt(&self, args: acp::PromptRequest) -> acp::Result<acp::PromptResponse> {
        let prompt_id = args
            .meta
            .as_ref()
            .and_then(|m| m.get("promptId"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let session_id = args.session_id.to_string();
        if viewer::is_relay_session(&session_id) {
            let text = prompt_text(&args.prompt);
            return self.viewer()?.prompt(&session_id, prompt_id, text).await;
        }
        self.tell(Observed::PromptSent {
            session_id,
            prompt_id,
            text: prompt_text(&args.prompt),
        });
        self.inner.prompt(args).await
    }

    async fn cancel(&self, args: acp::CancelNotification) -> acp::Result<()> {
        if viewer::is_relay_session(&args.session_id.0) {
            return self.viewer()?.cancel(&args.session_id.0).await;
        }
        self.inner.cancel(args).await
    }

    async fn set_session_mode(
        &self,
        args: acp::SetSessionModeRequest,
    ) -> acp::Result<acp::SetSessionModeResponse> {
        if viewer::is_relay_session(&args.session_id.0) {
            return Err(not_here("Changing the mode"));
        }
        self.inner.set_session_mode(args).await
    }

    async fn set_session_model(
        &self,
        args: acp::SetSessionModelRequest,
    ) -> acp::Result<acp::SetSessionModelResponse> {
        if viewer::is_relay_session(&args.session_id.0) {
            // The TUI's picker sends the thinking level with the model.
            let effort = args
                .meta
                .as_ref()
                .and_then(|meta| meta.get(xai_grok_sampling_types::REASONING_EFFORT_META_KEY))
                .and_then(Value::as_str)
                .map(str::to_owned);
            return self
                .viewer()?
                .set_model(&args.session_id.0, &args.model_id.0, effort)
                .await;
        }
        self.inner.set_session_model(args).await
    }

    async fn set_session_config_option(
        &self,
        args: acp::SetSessionConfigOptionRequest,
    ) -> acp::Result<acp::SetSessionConfigOptionResponse> {
        if viewer::is_relay_session(&args.session_id.0) {
            let value = serde_json::to_value(&args.value).unwrap_or(Value::Null);
            let value = value
                .as_str()
                .map(str::to_owned)
                .or_else(|| value.get("value").and_then(Value::as_str).map(str::to_owned))
                .ok_or_else(|| acp::Error::invalid_params().data("expected a value id"))?;
            return self
                .viewer()?
                .set_config(&args.session_id.0, &args.config_id.0, &value)
                .await;
        }
        self.inner.set_session_config_option(args).await
    }

    async fn list_sessions(
        &self,
        args: acp::ListSessionsRequest,
    ) -> acp::Result<acp::ListSessionsResponse> {
        self.inner.list_sessions(args).await
    }

    async fn fork_session(
        &self,
        args: acp::ForkSessionRequest,
    ) -> acp::Result<acp::ForkSessionResponse> {
        if viewer::is_relay_session(&args.session_id.0) {
            return Err(not_here("Forking"));
        }
        self.inner.fork_session(args).await
    }

    async fn resume_session(
        &self,
        args: acp::ResumeSessionRequest,
    ) -> acp::Result<acp::ResumeSessionResponse> {
        let session_id = args.session_id.to_string();
        if viewer::is_relay_session(&session_id) {
            self.viewer()?.load(&session_id).await?;
            return serde_json::from_value(json!({}))
                .map_err(|e| acp::Error::internal_error().data(e.to_string()));
        }
        self.reveal(&session_id);
        let cwd = args.cwd.to_string_lossy().to_string();
        let response = self.inner.resume_session(args).await?;
        self.tell(Observed::SessionOpened {
            session_id,
            cwd,
            loaded: true,
        });
        Ok(response)
    }

    async fn close_session(
        &self,
        args: acp::CloseSessionRequest,
    ) -> acp::Result<acp::CloseSessionResponse> {
        let session_id = args.session_id.to_string();
        if viewer::is_relay_session(&session_id) {
            self.viewer()?.close(&session_id);
            return serde_json::from_value(json!({}))
                .map_err(|e| acp::Error::internal_error().data(e.to_string()));
        }
        let response = self.inner.close_session(args).await?;
        self.tell(Observed::SessionClosed { session_id });
        Ok(response)
    }

    async fn ext_method(&self, args: acp::ExtRequest) -> acp::Result<acp::ExtResponse> {
        let method = args.method.trim_start_matches('_').to_string();
        if method == REMOTE_SESSIONS_METHOD {
            let params: Value = serde_json::from_str(args.params.get()).unwrap_or(Value::Null);
            return ext_response(&self.viewer()?.sessions(&params).await);
        }
        if method == REMOTE_NEW_SESSION_METHOD {
            let params: Value = serde_json::from_str(args.params.get()).unwrap_or(Value::Null);
            return ext_response(&self.viewer()?.new_session(&params).await?);
        }
        let session = params_session(&args.params);
        if let Some(session_id) = session.as_deref().filter(|s| viewer::is_relay_session(s)) {
            let viewer = self.viewer()?;
            return match method.as_str() {
                "x.ai/session/info" => ext_response(&viewer.info(session_id).await?),
                "x.ai/session/usage" => ext_response(&viewer.usage(session_id).await?),
                "x.ai/remote/git" => {
                    let params: Value =
                        serde_json::from_str(args.params.get()).unwrap_or(Value::Null);
                    ext_response(&viewer.git(session_id, &params).await?)
                }
                "x.ai/session/close" => {
                    viewer.close(session_id);
                    ext_response(&json!({}))
                }
                _ => Err(acp::Error::method_not_found()),
            };
        }
        if method == "x.ai/session/list" {
            // The TUI's session picker asks for the other computers' sessions too; a search keeps the matching ones.
            let params: Value = serde_json::from_str(args.params.get()).unwrap_or(Value::Null);
            let wanted = params.get("otherComputers").and_then(Value::as_bool) == Some(true)
                || params.get("query").is_some_and(|_| self.observer.is_some());
            let query = params
                .get("query")
                .and_then(Value::as_str)
                .map(str::to_lowercase);
            let response = self.inner.ext_method(args).await?;
            if wanted && let Some(observer) = &self.observer {
                let mut rows = observer.viewer().picker_rows().await;
                if let Some(query) = query.filter(|q| !q.trim().is_empty()) {
                    rows.retain(|row| row_matches(row, &query));
                }
                return Ok(append_rows(response, rows));
            }
            return Ok(response);
        }
        let closing = (method == "x.ai/session/close")
            .then_some(session)
            .flatten();
        let response = self.inner.ext_method(args).await?;
        if let Some(session_id) = closing {
            self.tell(Observed::SessionClosed { session_id });
        }
        Ok(response)
    }

    async fn ext_notification(&self, args: acp::ExtNotification) -> acp::Result<()> {
        if params_session(&args.params).is_some_and(|s| viewer::is_relay_session(&s)) {
            return Ok(());
        }
        self.inner.ext_notification(args).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_join_the_session_list_in_either_envelope() {
        let row = json!({ "sessionId": "relay:b", "source": "relay" });
        let plain = ext_response(&json!({ "sessions": [{ "sessionId": "a" }] })).unwrap();
        let joined: Value =
            serde_json::from_str(append_rows(plain, vec![row.clone()]).0.get()).unwrap();
        assert_eq!(joined["sessions"].as_array().unwrap().len(), 2);
        let wrapped = ext_response(&json!({ "result": { "sessions": [] } })).unwrap();
        let joined: Value = serde_json::from_str(append_rows(wrapped, vec![row]).0.get()).unwrap();
        assert_eq!(joined["result"]["sessions"][0]["sessionId"], "relay:b");
    }

    #[test]
    fn search_matches_every_word_of_a_row() {
        let row = json!({ "summary": "Fix the login redirect", "cwd": "/w/webapp", "hostname": "Office PC" });
        assert!(row_matches(&row, "login redirect"));
        assert!(row_matches(&row, "office webapp"));
        assert!(!row_matches(&row, "login billing"));
    }

    #[test]
    fn ext_params_name_their_session() {
        let raw = serde_json::value::to_raw_value(&json!({ "sessionId": "s1", "x": 1 })).unwrap();
        assert_eq!(params_session(&raw).as_deref(), Some("s1"));
        let raw = serde_json::value::to_raw_value(&json!({ "cwd": "/" })).unwrap();
        assert_eq!(params_session(&raw), None);
    }
}
