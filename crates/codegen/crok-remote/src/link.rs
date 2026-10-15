//! The network side of one running crok process: its own thread and Tokio runtime holding the Convex WebSocket, so
//! the agent's thread never waits on the network.
//!
//! The process registers as a host (`bridge:connect`), heartbeats every 30 s, writes its sessions' mirrors in order,
//! and streams `bridge:inbox` back. A device that was signed out elsewhere (`REVOKED`) deletes its credentials and
//! reports [`FromRelay::SignedOut`].

use std::collections::{BTreeMap, HashMap};
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
use crate::types::{CommandOutcome, EventInput, HostApp, Inbox, SessionFields};

const HEARTBEAT: Duration = Duration::from_secs(30);
const MAX_EVENTS_PER_CALL: usize = 100;
/// Refresh the access token this long before it expires.
const REFRESH_MARGIN_MS: f64 = 5.0 * 60.0 * 1000.0;

#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub credentials: Credentials,
    pub app: HostApp,
    pub app_version: String,
}

/// What the agent side asks the relay to do, in order.
#[derive(Debug)]
pub enum ToRelay {
    UpsertSession {
        session_id: String,
        fields: Box<SessionFields>,
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

    loop {
        if tokens.revoked.load(Ordering::SeqCst) {
            writer.abort();
            return signed_out(&from_relay);
        }
        tokio::select! {
            _ = &mut stopped => break,
            message = to_relay.recv() => match message {
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
    while let Some(message) = work.recv().await {
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
        };
        match result {
            Ok(FunctionResult::Value(_)) => {}
            Ok(other) => {
                if error_code(&other).as_deref() == Some("REVOKED") {
                    tokens.revoked.store(true, Ordering::SeqCst);
                }
                tracing::debug!(error = %describe(&other), "remote link: write failed");
            }
            Err(error) => tracing::debug!(%error, "remote link: write failed"),
        }
    }
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
}
