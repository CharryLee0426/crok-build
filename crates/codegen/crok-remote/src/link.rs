//! The network side of one running crok process: its own thread and Tokio runtime holding the Convex WebSocket, so
//! the agent's thread never waits on the network.
//!
//! The process registers as a host (`bridge:connect`), heartbeats every 30 s, writes its sessions' mirrors in order,
//! and streams `bridge:inbox` back. A device that was signed out elsewhere (`REVOKED`) deletes its credentials and
//! reports [`FromRelay::SignedOut`].

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use convex::{
    AuthenticationToken, ConvexClient, ConvexClientBuilder, FunctionResult, WebSocketState,
};
use futures::StreamExt;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::api::{Api, ApiError};
use crate::credentials::{self, Credentials};
use crate::types::{
    CatalogEntry, CommandOutcome, EventInput, EventKind, HostApp, Inbox, ModelOption,
    PendingInteraction, SessionFields, SlashCommand,
};

const HEARTBEAT: Duration = Duration::from_secs(30);
const MAX_EVENTS_PER_CALL: usize = 100;
const MAX_CATALOG_PER_CALL: usize = 100;
/// Refresh the access token this long before it expires.
const REFRESH_MARGIN_MS: f64 = 5.0 * 60.0 * 1000.0;

#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub credentials: Credentials,
    pub app: HostApp,
    pub app_version: String,
    /// This process opens sessions nobody runs when a prompt arrives for one (`bridge:connect`'s `canAdopt`).
    pub can_adopt: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallKind {
    Query,
    Mutation,
}

/// The value a relay function returned, or its error (`code` is the relay's error code, such as `OFFLINE`).
pub type CallResult = Result<Value, ApiError>;

/// What the agent side asks the relay to do. Mirror writes go out in order; calls and subscriptions (this computer
/// viewing other computers' sessions) run beside them.
#[derive(Debug)]
pub enum ToRelay {
    UpsertSession {
        session_id: String,
        fields: Box<SessionFields>,
    },
    /// A branch this computer's git command checked out, for a session another process may run.
    SetBranch {
        session_id: String,
        branch: String,
    },
    PushEvents {
        session_id: String,
        events: Vec<EventInput>,
        replace: bool,
    },
    CloseSession {
        session_id: String,
    },
    Claim {
        command_id: String,
        reply: oneshot::Sender<bool>,
    },
    Complete {
        command_id: String,
        outcome: CommandOutcome,
        result: Option<Value>,
        error: Option<String>,
    },
    /// Asks whether this process should list the computer's sessions now; the reply is the upload's id, or `None`
    /// when another crok here did it lately.
    BeginCatalog {
        reply: oneshot::Sender<Option<String>>,
    },
    /// Every session on disk, for the upload `BeginCatalog` started.
    Catalog {
        sync_id: String,
        entries: Vec<CatalogEntry>,
    },
    /// A transcript read from disk for a session no crok runs, then the `history` command that asked for it completes.
    PushHistory {
        session_doc_id: String,
        command_id: String,
        events: Vec<EventInput>,
        preview: Option<(EventKind, String)>,
    },
    /// The session's permission request waiting for an answer, or none.
    SetPending {
        session_id: String,
        pending: Option<PendingInteraction>,
    },
    /// The crok session opened for a claimed `create` command replaces the relay row's `pending:` id; the reply is the
    /// relay's error message when it refused.
    BindSession {
        session_doc_id: String,
        session_id: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// The models this process can run (the relay keeps the computer's latest list).
    SetModels {
        models: Vec<ModelOption>,
    },
    /// A mirrored session's slash commands.
    SetCommands {
        session_id: String,
        commands: Vec<SlashCommand>,
    },
    /// Any viewer function (`sessions:get`, `commands:sendPrompt`, …), answered on `reply`.
    Call {
        kind: CallKind,
        path: String,
        args: Value,
        reply: oneshot::Sender<CallResult>,
    },
    /// Keeps a query's value coming as [`FromRelay::Query`] with this `id` until [`ToRelay::Unsubscribe`].
    Subscribe {
        id: u64,
        path: String,
        args: Value,
    },
    Unsubscribe {
        id: u64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkState {
    Connecting,
    Connected,
}

#[derive(Debug)]
pub enum FromRelay {
    State(LinkState),
    /// A session's mirror exists; `created` or an empty transcript (`event_seq == 0`) means it needs its history.
    Registered {
        session_id: String,
        created: bool,
        event_seq: f64,
    },
    Inbox(Inbox),
    /// A write of the session's fields failed: the relay may lack any of them (a turn's end among them).
    FieldsLost {
        session_id: String,
    },
    /// A subscribed query's current value.
    Query {
        id: u64,
        result: CallResult,
    },
    /// The device was signed out from another device; the credentials file is gone.
    SignedOut,
}

/// A running link. Dropping it closes the connection (the host is marked offline).
pub struct Link {
    tx: mpsc::UnboundedSender<ToRelay>,
    stop: Option<oneshot::Sender<()>>,
    done: Option<oneshot::Receiver<()>>,
}

impl Link {
    /// Starts the link thread. What the relay says comes back on the returned receiver.
    pub fn spawn(
        config: LinkConfig,
    ) -> std::io::Result<(Link, mpsc::UnboundedReceiver<FromRelay>)> {
        let (tx, to_relay) = mpsc::unbounded_channel();
        let (from_relay, rx) = mpsc::unbounded_channel();
        let (stop, stopped) = oneshot::channel();
        let (done_tx, done) = oneshot::channel();
        std::thread::Builder::new()
            .name("crok-remote-link".into())
            .spawn(move || {
                match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime.block_on(run(config, to_relay, from_relay, stopped)),
                    Err(error) => tracing::warn!(%error, "remote link: no runtime"),
                }
                let _ = done_tx.send(());
            })?;
        Ok((
            Link {
                tx,
                stop: Some(stop),
                done: Some(done),
            },
            rx,
        ))
    }

    pub fn send(&self, message: ToRelay) {
        let _ = self.tx.send(message);
    }

    /// A sender for the same link, for callers that outlive a borrow of it (it stops working when the link stops).
    pub fn sender(&self) -> mpsc::UnboundedSender<ToRelay> {
        self.tx.clone()
    }

    /// Closes the link; the returned receiver completes once the relay was told this host is offline (or gave up).
    pub fn stop(mut self) -> oneshot::Receiver<()> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.done.take().unwrap_or_else(|| oneshot::channel().1)
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

/// Plain JSON → Convex arguments. `null`s are dropped: an optional field must be absent, not null.
pub fn to_args(value: Value) -> BTreeMap<String, convex::Value> {
    fn strip(value: Value) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.into_iter()
                    .filter(|(_, v)| !v.is_null())
                    .map(|(k, v)| (k, strip(v)))
                    .collect(),
            ),
            Value::Array(items) => Value::Array(items.into_iter().map(strip).collect()),
            other => other,
        }
    }
    let Value::Object(map) = strip(value) else {
        return BTreeMap::new();
    };
    map.into_iter()
        .filter_map(|(key, value)| convex::Value::try_from(value).ok().map(|v| (key, v)))
        .collect()
}

/// Plain JSON → Convex arguments, nulls kept: viewer functions take explicit nulls (a first page's `cursor`).
pub fn to_args_with_nulls(value: Value) -> BTreeMap<String, convex::Value> {
    let Value::Object(map) = value else {
        return BTreeMap::new();
    };
    map.into_iter()
        .filter_map(|(key, value)| convex::Value::try_from(value).ok().map(|v| (key, v)))
        .collect()
}

/// The error code a relay function threw (`REVOKED`, `NOT_FOUND`, …), if any.
fn error_code(result: &FunctionResult) -> Option<String> {
    match result {
        FunctionResult::ConvexError(error) => error
            .data
            .clone()
            .export()
            .get("code")
            .and_then(Value::as_str)
            .map(str::to_owned),
        _ => None,
    }
}

fn describe(result: &FunctionResult) -> String {
    match result {
        FunctionResult::Value(_) => String::new(),
        FunctionResult::ErrorMessage(message) => message.clone(),
        FunctionResult::ConvexError(error) => error.message.clone(),
    }
}

/// A function's result as plain JSON, or the relay's `{code, message}` error.
fn call_result(result: anyhow::Result<FunctionResult>) -> CallResult {
    match result {
        Ok(FunctionResult::Value(value)) => Ok(value.export()),
        Ok(FunctionResult::ConvexError(error)) => {
            let data = error.data.clone().export();
            Err(ApiError::Function {
                code: data.get("code").and_then(Value::as_str).map(str::to_owned),
                message: data
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| error.message.clone()),
            })
        }
        Ok(FunctionResult::ErrorMessage(message)) => Err(ApiError::Function {
            code: None,
            message,
        }),
        Err(error) => Err(ApiError::Transport(error.to_string())),
    }
}

/// The current access token, refreshed through the HTTP API when it is near its end or the client asks.
struct Tokens {
    api: Api,
    refresh_token: String,
    current: Mutex<Option<(String, f64)>>,
    revoked: AtomicBool,
}

impl Tokens {
    async fn get(&self, force: bool) -> Result<String, ApiError> {
        if !force
            && let Ok(guard) = self.current.lock()
            && let Some((token, expires_at)) = guard.as_ref()
            && *expires_at - crate::types::now_ms() > REFRESH_MARGIN_MS
        {
            return Ok(token.clone());
        }
        match self.api.refresh(&self.refresh_token).await {
            Ok(fresh) => {
                if let Ok(mut guard) = self.current.lock() {
                    *guard = Some((fresh.access_token.clone(), fresh.access_token_expires_at));
                }
                Ok(fresh.access_token)
            }
            Err(error) => {
                if error.is_revoked() {
                    self.revoked.store(true, Ordering::SeqCst);
                }
                Err(error)
            }
        }
    }
}

type BoxFuture<T> = Pin<Box<dyn std::future::Future<Output = T> + Send>>;

async fn run(
    config: LinkConfig,
    mut to_relay: mpsc::UnboundedReceiver<ToRelay>,
    from_relay: mpsc::UnboundedSender<FromRelay>,
    mut stopped: oneshot::Receiver<()>,
) {
    xai_grok_extra_ca::ensure_default_crypto_provider();
    let server = config.credentials.server.clone();
    let api = match Api::new(&server) {
        Ok(api) => api,
        Err(error) => {
            tracing::warn!(%error, "remote link: bad relay URL");
            return;
        }
    };
    let tokens = Arc::new(Tokens {
        api,
        refresh_token: config.credentials.refresh_token.clone(),
        current: Mutex::new(None),
        revoked: AtomicBool::new(false),
    });
    let signed_out = |from_relay: &mpsc::UnboundedSender<FromRelay>| {
        let _ = credentials::remove();
        let _ = from_relay.send(FromRelay::SignedOut);
    };

    // A first token before connecting: no point opening a socket for a device that was signed out.
    let mut backoff = Duration::from_secs(1);
    loop {
        match tokens.get(true).await {
            Ok(_) => break,
            Err(error) if error.is_revoked() => return signed_out(&from_relay),
            Err(error) => {
                tracing::debug!(%error, "remote link: cannot get a token yet");
                let _ = from_relay.send(FromRelay::State(LinkState::Connecting));
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = &mut stopped => return,
                }
                backoff = (backoff * 2).min(Duration::from_secs(60));
            }
        }
    }

    let (state_tx, mut state_rx) = mpsc::channel(8);
    let client_id = format!("crok-{}-{}", config.app.as_str(), config.app_version);
    let mut client: ConvexClient = match ConvexClientBuilder::new(&server)
        .with_client_id(&client_id)
        .with_on_state_change(state_tx)
        .build()
        .await
    {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!(%error, "remote link: cannot open the relay connection");
            return;
        }
    };
    let fetcher_tokens = tokens.clone();
    client
        .set_auth_callback(Some(Box::new(move |force: bool| {
            let tokens = fetcher_tokens.clone();
            Box::pin(async move {
                Ok(match tokens.get(force).await {
                    Ok(token) => AuthenticationToken::User(token),
                    Err(_) => AuthenticationToken::None,
                })
            }) as BoxFuture<anyhow::Result<AuthenticationToken>>
        })))
        .await;

    let instance_id = uuid::Uuid::new_v4().to_string();
    let connect_args = json!({
        "instanceId": instance_id,
        "app": config.app.as_str(),
        "appVersion": config.app_version,
        "pid": f64::from(std::process::id()),
        "canAdopt": config.can_adopt,
        // Command types this process handles beyond the first relay's; `setup`: a `create` command's model and
        // thinking level are applied before its first prompt (the relay gives such a session only to a crok that does).
        "features": ["create", "config", "git", "setup"],
    });
    let host_id = loop {
        match client
            .mutation("bridge:connect", to_args(connect_args.clone()))
            .await
        {
            Ok(FunctionResult::Value(value)) => {
                if let Some(id) = value.export().get("hostId").and_then(Value::as_str) {
                    break id.to_string();
                }
            }
            Ok(other) => {
                if matches!(
                    error_code(&other).as_deref(),
                    Some("REVOKED" | "UNAUTHENTICATED")
                ) || tokens.revoked.load(Ordering::SeqCst)
                {
                    return signed_out(&from_relay);
                }
                tracing::warn!(error = %describe(&other), "remote link: connect failed");
            }
            Err(error) => tracing::warn!(%error, "remote link: connect failed"),
        }
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(5)) => {}
            _ = &mut stopped => return,
        }
    };
    let _ = from_relay.send(FromRelay::State(LinkState::Connected));

    let mut inbox = match client
        .subscribe("bridge:inbox", to_args(json!({ "hostId": host_id })))
        .await
    {
        Ok(subscription) => subscription,
        Err(error) => {
            tracing::warn!(%error, "remote link: cannot subscribe to the inbox");
            return;
        }
    };

    // Writes run on their own task, in order, so a slow mutation never holds up the inbox.
    let (work_tx, work_rx) = mpsc::unbounded_channel::<ToRelay>();
    let writer = tokio::spawn(write_loop(
        client.clone(),
        host_id.clone(),
        work_rx,
        from_relay.clone(),
        tokens.clone(),
    ));
    let mut heartbeat = tokio::time::interval(HEARTBEAT);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    heartbeat.tick().await;
    // Queries this process watches as a viewer (other computers' sessions), each on its own task.
    let mut watches: HashMap<u64, tokio::task::JoinHandle<()>> = HashMap::new();

    loop {
        if tokens.revoked.load(Ordering::SeqCst) {
            writer.abort();
            watches.values().for_each(|task| task.abort());
            return signed_out(&from_relay);
        }
        tokio::select! {
            _ = &mut stopped => break,
            message = to_relay.recv() => match message {
                Some(ToRelay::Call { kind, path, args, reply }) => {
                    let mut client = client.clone();
                    tokio::spawn(async move {
                        let args = to_args_with_nulls(args);
                        let result = match kind {
                            CallKind::Query => client.query(&path, args).await,
                            CallKind::Mutation => client.mutation(&path, args).await,
                        };
                        let _ = reply.send(call_result(result));
                    });
                }
                Some(ToRelay::Subscribe { id, path, args }) => {
                    let mut client = client.clone();
                    let from_relay = from_relay.clone();
                    let task = tokio::spawn(async move {
                        let mut subscription = match client.subscribe(&path, to_args_with_nulls(args)).await {
                            Ok(subscription) => subscription,
                            Err(error) => {
                                let result = Err(ApiError::Transport(error.to_string()));
                                let _ = from_relay.send(FromRelay::Query { id, result });
                                return;
                            }
                        };
                        while let Some(result) = subscription.next().await {
                            let result = call_result(Ok(result));
                            if from_relay.send(FromRelay::Query { id, result }).is_err() {
                                break;
                            }
                        }
                    });
                    if let Some(old) = watches.insert(id, task) {
                        old.abort();
                    }
                }
                Some(ToRelay::Unsubscribe { id }) => {
                    if let Some(task) = watches.remove(&id) {
                        task.abort();
                    }
                }
                Some(message) => { let _ = work_tx.send(message); }
                None => break,
            },
            Some(state) = state_rx.recv() => {
                let state = match state {
                    WebSocketState::Connected => LinkState::Connected,
                    WebSocketState::Connecting => LinkState::Connecting,
                };
                let _ = from_relay.send(FromRelay::State(state));
            }
            result = inbox.next() => match result {
                Some(FunctionResult::Value(value)) => {
                    match serde_json::from_value::<Inbox>(value.export()) {
                        Ok(parsed) => { let _ = from_relay.send(FromRelay::Inbox(parsed)); }
                        Err(error) => tracing::warn!(%error, "remote link: unexpected inbox"),
                    }
                }
                Some(other) => {
                    if error_code(&other).as_deref() == Some("REVOKED") {
                        writer.abort();
                        return signed_out(&from_relay);
                    }
                    tracing::debug!(error = %describe(&other), "remote link: inbox error");
                }
                None => break,
            },
            _ = heartbeat.tick() => {
                let mut client = client.clone();
                let args = to_args(json!({ "hostId": host_id }));
                let tokens = tokens.clone();
                tokio::spawn(async move {
                    if let Ok(result) = client.mutation("bridge:heartbeat", args).await
                        && error_code(&result).as_deref() == Some("REVOKED")
                    {
                        tokens.revoked.store(true, Ordering::SeqCst);
                    }
                });
            }
        }
    }
    writer.abort();
    watches.values().for_each(|task| task.abort());
    // A clean exit marks the host and its sessions offline at once instead of after the 90 s heartbeat timeout.
    let _ = tokio::time::timeout(
        Duration::from_secs(3),
        client.mutation("bridge:disconnect", to_args(json!({ "hostId": host_id }))),
    )
    .await;
}

async fn write_loop(
    mut client: ConvexClient,
    host_id: String,
    mut work: mpsc::UnboundedReceiver<ToRelay>,
    from_relay: mpsc::UnboundedSender<FromRelay>,
    tokens: Arc<Tokens>,
) {
    let mut doc_ids: HashMap<String, String> = HashMap::new();
    // Writes wait here while the previous one is out. Each takes a round trip, so a far relay can answer slower than a
    // busy turn changes; what piles up meanwhile is folded, and the newest state is never more than a few writes away.
    let mut backlog: VecDeque<ToRelay> = VecDeque::new();
    loop {
        if backlog.is_empty() {
            match work.recv().await {
                Some(message) => backlog.push_back(message),
                None => break,
            }
        }
        while let Ok(message) = work.try_recv() {
            backlog.push_back(message);
        }
        fold_backlog(&mut backlog, &doc_ids);
        let Some(message) = backlog.pop_front() else {
            continue;
        };
        let fields_of = match &message {
            ToRelay::UpsertSession { session_id, .. } => Some(session_id.clone()),
            _ => None,
        };
        let result = match message {
            ToRelay::UpsertSession { session_id, fields } => {
                let args = json!({ "hostId": host_id, "sessionId": session_id, "fields": fields });
                let result = client.mutation("bridge:upsertSession", to_args(args)).await;
                if let Ok(FunctionResult::Value(value)) = &result {
                    let value = value.clone().export();
                    if let Some(doc) = value.get("sessionDocId").and_then(Value::as_str) {
                        doc_ids.insert(session_id.clone(), doc.to_string());
                        let _ = from_relay.send(FromRelay::Registered {
                            session_id,
                            created: value
                                .get("created")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                            event_seq: value.get("eventSeq").and_then(Value::as_f64).unwrap_or(0.0),
                        });
                    }
                }
                result
            }
            ToRelay::SetBranch { session_id, branch } => {
                let args = json!({ "hostId": host_id, "sessionId": session_id, "branch": branch });
                client.mutation("bridge:setBranch", to_args(args)).await
            }
            ToRelay::PushEvents {
                session_id,
                events,
                replace,
            } => {
                let Some(doc) = doc_ids.get(&session_id).cloned() else {
                    tracing::debug!(%session_id, "remote link: events for an unregistered session");
                    continue;
                };
                let mut last = Ok(FunctionResult::Value(convex::Value::Null));
                for (index, chunk) in events.chunks(MAX_EVENTS_PER_CALL).enumerate() {
                    let args = json!({
                        "hostId": host_id,
                        "sessionDocId": doc,
                        "replace": replace && index == 0,
                        "events": chunk,
                    });
                    last = client.mutation("bridge:pushEvents", to_args(args)).await;
                    if !matches!(last, Ok(FunctionResult::Value(_))) {
                        break;
                    }
                }
                last
            }
            ToRelay::CloseSession { session_id } => {
                let args = json!({ "hostId": host_id, "sessionId": session_id });
                client.mutation("bridge:closeSession", to_args(args)).await
            }
            ToRelay::Claim { command_id, reply } => {
                let args = json!({ "hostId": host_id, "commandId": command_id });
                let result = client.mutation("bridge:claimCommand", to_args(args)).await;
                let claimed = matches!(
                    &result,
                    Ok(FunctionResult::Value(convex::Value::Boolean(true)))
                );
                let _ = reply.send(claimed);
                result
            }
            ToRelay::Complete {
                command_id,
                outcome,
                result,
                error,
            } => {
                let args = json!({
                    "hostId": host_id,
                    "commandId": command_id,
                    "status": outcome,
                    "result": result,
                    "error": error,
                });
                client
                    .mutation("bridge:completeCommand", to_args(args))
                    .await
            }
            ToRelay::BeginCatalog { reply } => {
                let args = json!({ "hostId": host_id });
                let result = client.mutation("bridge:beginCatalog", to_args(args)).await;
                let sync_id = match &result {
                    Ok(FunctionResult::Value(value)) => value
                        .clone()
                        .export()
                        .get("syncId")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    _ => None,
                };
                let _ = reply.send(sync_id);
                result
            }
            ToRelay::Catalog { sync_id, entries } => {
                upload_catalog(&mut client, &host_id, &sync_id, &entries).await
            }
            ToRelay::PushHistory {
                session_doc_id,
                command_id,
                events,
                preview,
            } => {
                let pushed =
                    push_history(&mut client, &host_id, &session_doc_id, &events, preview).await;
                let (status, error) = match &pushed {
                    Ok(FunctionResult::Value(_)) => ("done", None),
                    Ok(other) => ("failed", Some(describe(other))),
                    Err(error) => ("failed", Some(error.to_string())),
                };
                let args = json!({
                    "hostId": host_id,
                    "commandId": command_id,
                    "status": status,
                    "error": error,
                });
                let completed = client
                    .mutation("bridge:completeCommand", to_args(args))
                    .await;
                if matches!(pushed, Ok(FunctionResult::Value(_))) {
                    completed
                } else {
                    pushed
                }
            }
            ToRelay::SetPending {
                session_id,
                pending,
            } => {
                let args =
                    json!({ "hostId": host_id, "sessionId": session_id, "pending": pending });
                client.mutation("bridge:setPending", to_args(args)).await
            }
            ToRelay::BindSession {
                session_doc_id,
                session_id,
                reply,
            } => {
                let args = json!({
                    "hostId": host_id,
                    "sessionDocId": session_doc_id,
                    "sessionId": session_id,
                });
                let result = client.mutation("bridge:bindSession", to_args(args)).await;
                let outcome = match &result {
                    Ok(FunctionResult::Value(_)) => {
                        doc_ids.insert(session_id, session_doc_id);
                        Ok(())
                    }
                    Ok(other) => Err(describe(other)),
                    Err(error) => Err(error.to_string()),
                };
                let _ = reply.send(outcome);
                result
            }
            ToRelay::SetModels { models } => {
                let args = json!({ "hostId": host_id, "models": models });
                client.mutation("bridge:setModels", to_args(args)).await
            }
            ToRelay::SetCommands {
                session_id,
                commands,
            } => {
                let args =
                    json!({ "hostId": host_id, "sessionId": session_id, "commands": commands });
                client.mutation("bridge:setCommands", to_args(args)).await
            }
            // Handled by the run loop, beside the writes.
            ToRelay::Call { .. } | ToRelay::Subscribe { .. } | ToRelay::Unsubscribe { .. } => {
                continue;
            }
        };
        if let Some(session_id) = fields_of
            && !matches!(result, Ok(FunctionResult::Value(_)))
        {
            let _ = from_relay.send(FromRelay::FieldsLost { session_id });
        }
        match result {
            Ok(FunctionResult::Value(_)) => {}
            Ok(other) => {
                let code = error_code(&other);
                if code.as_deref() == Some("REVOKED") {
                    tokens.revoked.store(true, Ordering::SeqCst);
                }
                // A write the relay refuses as invalid (a limit, a shape it does not take) fails the same way every
                // time: say so where it can be found.
                if code.as_deref() == Some("INVALID") {
                    tracing::warn!(error = %describe(&other), "remote link: the relay refused a write");
                } else {
                    tracing::debug!(error = %describe(&other), "remote link: write failed");
                }
            }
            Err(error) => tracing::debug!(%error, "remote link: write failed"),
        }
    }
}

/// Folds the writes waiting in `backlog`. Between two writes that must keep their place (claims, completions, closes, a
/// replaced transcript, …), each session's field updates become one upsert with the latest value of every field, and its
/// transcript items one push with each item once, in its latest state. They go where the session's first upsert and
/// first push were. A session the relay has given no row yet (not in `registered`) keeps its writes as they are: its
/// first upsert creates the row.
fn fold_backlog(backlog: &mut VecDeque<ToRelay>, registered: &HashMap<String, String>) {
    if backlog.len() < 2 {
        return;
    }
    let mut folded: VecDeque<ToRelay> = VecDeque::with_capacity(backlog.len());
    // Where each session's upsert and push went since the last write that keeps its place.
    let mut upserts: HashMap<String, usize> = HashMap::new();
    let mut pushes: HashMap<String, usize> = HashMap::new();
    for message in backlog.drain(..) {
        match message {
            ToRelay::UpsertSession { session_id, fields }
                if registered.contains_key(&session_id) =>
            {
                let at = upserts.get(&session_id).copied();
                if let Some(ToRelay::UpsertSession {
                    fields: earlier, ..
                }) = at.and_then(|at| folded.get_mut(at))
                {
                    earlier.merge(*fields);
                } else {
                    upserts.insert(session_id.clone(), folded.len());
                    folded.push_back(ToRelay::UpsertSession { session_id, fields });
                }
            }
            ToRelay::PushEvents {
                session_id,
                events,
                replace: false,
            } if registered.contains_key(&session_id) => {
                let at = pushes.get(&session_id).copied();
                if let Some(ToRelay::PushEvents {
                    events: earlier, ..
                }) = at.and_then(|at| folded.get_mut(at))
                {
                    merge_events(earlier, events);
                } else {
                    pushes.insert(session_id.clone(), folded.len());
                    folded.push_back(ToRelay::PushEvents {
                        session_id,
                        events,
                        replace: false,
                    });
                }
            }
            other => {
                upserts.clear();
                pushes.clear();
                folded.push_back(other);
            }
        }
    }
    *backlog = folded;
}

/// Adds `later` to `events`: an item already there (same key) takes its later state where it is, new ones go last.
fn merge_events(events: &mut Vec<EventInput>, later: Vec<EventInput>) {
    let mut at: HashMap<String, usize> = events
        .iter()
        .enumerate()
        .map(|(index, event)| (event.key.clone(), index))
        .collect();
    for event in later {
        match at.get(&event.key).and_then(|index| events.get_mut(*index)) {
            Some(existing) => *existing = event,
            None => {
                at.insert(event.key.clone(), events.len());
                events.push(event);
            }
        }
    }
}

/// Uploads the catalog in batches, then ends it with every id listed (the relay drops offline sessions missing from it).
/// Stops at the first failure: an upload another process took over answers `EXPIRED`.
async fn upload_catalog(
    client: &mut ConvexClient,
    host_id: &str,
    sync_id: &str,
    entries: &[CatalogEntry],
) -> anyhow::Result<FunctionResult> {
    for chunk in entries.chunks(MAX_CATALOG_PER_CALL) {
        let args = json!({ "hostId": host_id, "syncId": sync_id, "sessions": chunk });
        let result = client
            .mutation("bridge:catalogBatch", to_args(args))
            .await?;
        if !matches!(result, FunctionResult::Value(_)) {
            return Ok(result);
        }
    }
    let ids: Vec<&str> = entries.iter().map(|e| e.session_id.as_str()).collect();
    let args = json!({ "hostId": host_id, "syncId": sync_id, "sessionIds": ids });
    client.mutation("bridge:finishCatalog", to_args(args)).await
}

/// Replaces a session's transcript on the relay; the first call clears the old one even when there is nothing to add,
/// and the last sets the list's preview.
async fn push_history(
    client: &mut ConvexClient,
    host_id: &str,
    session_doc_id: &str,
    events: &[EventInput],
    preview: Option<(EventKind, String)>,
) -> anyhow::Result<FunctionResult> {
    let chunks: Vec<&[EventInput]> = if events.is_empty() {
        vec![&[]]
    } else {
        events.chunks(MAX_EVENTS_PER_CALL).collect()
    };
    let last = chunks.len() - 1;
    let mut result = FunctionResult::Value(convex::Value::Null);
    for (index, chunk) in chunks.into_iter().enumerate() {
        let (preview_kind, preview_text) = match (&preview, index == last) {
            (Some((kind, text)), true) => (Some(*kind), Some(text.clone())),
            _ => (None, None),
        };
        let args = json!({
            "hostId": host_id,
            "sessionDocId": session_doc_id,
            "replace": index == 0,
            "events": chunk,
            "preview": preview_text,
            "previewKind": preview_kind,
        });
        result = client.mutation("bridge:pushEvents", to_args(args)).await?;
        if !matches!(result, FunctionResult::Value(_)) {
            break;
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn args_drop_nulls_and_keep_floats() {
        let args =
            to_args(json!({"a": null, "b": 1.5, "c": {"d": null, "e": "x"}, "f": [1.0, null]}));
        assert!(!args.contains_key("a"));
        assert_eq!(args.get("b"), Some(&convex::Value::Float64(1.5)));
        let c = args.get("c").unwrap().clone().export();
        assert_eq!(c, json!({"e": "x"}));
        assert!(args.contains_key("f"));
    }

    #[test]
    fn viewer_args_keep_nulls() {
        let args =
            to_args_with_nulls(json!({"paginationOpts": {"numItems": 40.0, "cursor": null}}));
        let opts = args.get("paginationOpts").unwrap().clone().export();
        assert_eq!(opts, json!({"numItems": 40.0, "cursor": null}));
    }

    fn event(key: &str, text: &str) -> EventInput {
        EventInput {
            key: key.into(),
            kind: EventKind::Assistant,
            text: text.into(),
            title: None,
            tool_kind: None,
            status: None,
            origin: None,
            command_id: None,
            from_label: None,
            at: 1.0,
        }
    }

    fn upsert(
        session: &str,
        status: Option<crate::types::SessionStatus>,
        preview: Option<&str>,
    ) -> ToRelay {
        ToRelay::UpsertSession {
            session_id: session.into(),
            fields: Box::new(SessionFields {
                status,
                preview: preview.map(str::to_owned),
                ..SessionFields::default()
            }),
        }
    }

    fn push(session: &str, events: Vec<EventInput>) -> ToRelay {
        ToRelay::PushEvents {
            session_id: session.into(),
            events,
            replace: false,
        }
    }

    fn registered(sessions: &[&str]) -> HashMap<String, String> {
        sessions
            .iter()
            .map(|s| (s.to_string(), format!("doc-{s}")))
            .collect()
    }

    /// What a folded backlog holds, in order: `U s status preview`, `P s key=text…`, or another write's name.
    fn shape(backlog: &VecDeque<ToRelay>) -> Vec<String> {
        backlog
            .iter()
            .map(|message| match message {
                ToRelay::UpsertSession { session_id, fields } => format!(
                    "U {session_id} {:?} {}",
                    fields.status,
                    fields.preview.as_deref().unwrap_or("-")
                ),
                ToRelay::PushEvents {
                    session_id,
                    events,
                    replace,
                } => format!(
                    "P{} {session_id} {}",
                    if *replace { "!" } else { "" },
                    events
                        .iter()
                        .map(|e| format!("{}={}", e.key, e.text))
                        .collect::<Vec<_>>()
                        .join(",")
                ),
                ToRelay::Complete { command_id, .. } => format!("C {command_id}"),
                other => format!("{other:?}"),
            })
            .collect()
    }

    #[test]
    fn a_busy_sessions_backlog_folds_into_one_push_and_one_upsert_with_the_latest_state() {
        use crate::types::SessionStatus::{Idle, Running};
        let mut backlog: VecDeque<ToRelay> = VecDeque::from(vec![
            push("s", vec![event("a", "He")]),
            upsert("s", Some(Running), None),
            push("s", vec![event("a", "Hello"), event("b", "ls")]),
            push("t", vec![event("x", "other")]),
            upsert("s", None, Some("Hello")),
            push("s", vec![event("b", "ls -la"), event("c", "Done")]),
            upsert("s", Some(Idle), Some("Done")),
        ]);
        fold_backlog(&mut backlog, &registered(&["s", "t"]));
        assert_eq!(
            shape(&backlog),
            [
                "P s a=Hello,b=ls -la,c=Done",
                "U s Some(Idle) Done",
                "P t x=other",
            ]
        );
    }

    #[test]
    fn writes_that_keep_their_place_are_never_crossed() {
        use crate::types::SessionStatus::{Idle, Running};
        let mut backlog: VecDeque<ToRelay> = VecDeque::from(vec![
            upsert("s", Some(Running), None),
            push("s", vec![event("a", "Hi")]),
            ToRelay::Complete {
                command_id: "c1".into(),
                outcome: CommandOutcome::Done,
                result: None,
                error: None,
            },
            push("s", vec![event("a", "Hi there")]),
            upsert("s", Some(Idle), None),
            ToRelay::PushEvents {
                session_id: "s".into(),
                events: vec![event("z", "history")],
                replace: true,
            },
            push("s", vec![event("b", "new")]),
        ]);
        fold_backlog(&mut backlog, &registered(&["s"]));
        assert_eq!(
            shape(&backlog),
            [
                "U s Some(Running) -",
                "P s a=Hi",
                "C c1",
                "P s a=Hi there",
                "U s Some(Idle) -",
                "P! s z=history",
                "P s b=new",
            ]
        );
    }

    #[test]
    fn a_session_without_a_row_keeps_its_writes() {
        use crate::types::SessionStatus::{Idle, Running};
        let mut backlog: VecDeque<ToRelay> = VecDeque::from(vec![
            upsert("new", Some(Running), None),
            upsert("new", Some(Idle), None),
        ]);
        fold_backlog(&mut backlog, &registered(&[]));
        assert_eq!(
            shape(&backlog),
            ["U new Some(Running) -", "U new Some(Idle) -"]
        );
    }
}
