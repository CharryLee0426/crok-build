//! Remote control: mirrors this process's sessions to the relay and runs commands from phones and the web
//! (`relay/DESIGN.md` §4).
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

mod bridge;
pub(crate) mod transcript;

use std::cell::Cell;
use std::rc::Rc;

use agent_client_protocol as acp;
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};
use xai_acp_lib::AcpClientMessage;

pub use crok_remote::HostApp;

use crate::agent::MvpAgent;

/// Ext notification to the front end before a remote prompt runs: `{sessionId, promptId, text, from, fromKind}`
/// (`fromKind`: `phone` or `web`). Crok Desktop
/// shows the prompt from it; the TUI already gets it through its user-message echo and shows a toast.
pub const REMOTE_PROMPT_METHOD: &str = "x.ai/remote/prompt";
/// Ext notification of the bridge's state: `{state: "off" | "connecting" | "connected", account?, device?}`.
pub const REMOTE_STATUS_METHOD: &str = "x.ai/remote/status";

/// What the bridge sees of the agent and its front end.
#[derive(Debug)]
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
}

struct ObserverInner {
    tx: mpsc::UnboundedSender<Observed>,
    /// Copy session updates only while signed in: serializing every chunk costs CPU for nothing otherwise.
    live: Cell<bool>,
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
            })),
            rx,
        })
    }

    /// Puts the bridge between the agent and its front end's receiver: every message passes through unchanged and
    /// session notifications are copied to the bridge. Must run on the agent's `LocalSet`.
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
                if to_front_end.send(message).is_err() {
                    break;
                }
            }
        });
    }

    /// The agent the front end's connection should call, so the bridge sees sessions opened and prompts sent.
    pub fn observe<A: acp::Agent>(&self, agent: A) -> ObservedAgent<A> {
        ObservedAgent {
            inner: agent,
            observer: Some(self.observer.clone()),
        }
    }

    /// Starts the bridge on the current `LocalSet`.
    pub fn start(self, agent: &Rc<MvpAgent>) -> RemoteHandle {
        let (stop_tx, stop_rx) = oneshot::channel();
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

/// An agent whose front end the bridge watches: like `RequestLog`, every call passes through untouched.
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
        self.tell(Observed::PromptSent {
            session_id: args.session_id.to_string(),
            prompt_id,
            text: prompt_text(&args.prompt),
        });
        self.inner.prompt(args).await
    }

    async fn cancel(&self, args: acp::CancelNotification) -> acp::Result<()> {
        self.inner.cancel(args).await
    }

    async fn set_session_mode(
        &self,
        args: acp::SetSessionModeRequest,
    ) -> acp::Result<acp::SetSessionModeResponse> {
        self.inner.set_session_mode(args).await
    }

    async fn set_session_model(
        &self,
        args: acp::SetSessionModelRequest,
    ) -> acp::Result<acp::SetSessionModelResponse> {
        self.inner.set_session_model(args).await
    }

    async fn set_session_config_option(
        &self,
        args: acp::SetSessionConfigOptionRequest,
    ) -> acp::Result<acp::SetSessionConfigOptionResponse> {
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
        self.inner.fork_session(args).await
    }

    async fn resume_session(
        &self,
        args: acp::ResumeSessionRequest,
    ) -> acp::Result<acp::ResumeSessionResponse> {
        let session_id = args.session_id.to_string();
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
        let response = self.inner.close_session(args).await?;
        self.tell(Observed::SessionClosed { session_id });
        Ok(response)
    }

    async fn ext_method(&self, args: acp::ExtRequest) -> acp::Result<acp::ExtResponse> {
        let closing = (args.method.trim_start_matches('_') == "x.ai/session/close")
            .then(|| serde_json::from_str::<Value>(args.params.get()).ok())
            .flatten()
            .and_then(|params| {
                params
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
        let response = self.inner.ext_method(args).await?;
        if let Some(session_id) = closing {
            self.tell(Observed::SessionClosed { session_id });
        }
        Ok(response)
    }

    async fn ext_notification(&self, args: acp::ExtNotification) -> acp::Result<()> {
        self.inner.ext_notification(args).await
    }
}
