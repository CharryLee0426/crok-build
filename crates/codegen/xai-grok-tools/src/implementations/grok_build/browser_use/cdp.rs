//! A Chrome DevTools Protocol client over one WebSocket.
//!
//! Commands are matched to their answers by id; events go to every subscriber. Page targets are
//! reached through flattened sessions (`Target.attachToTarget` with `flatten: true`), so one
//! connection serves every tab.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

/// How long a command may take before the call fails.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
const EVENT_CAPACITY: usize = 4096;

/// One event the browser sent.
#[derive(Debug, Clone)]
pub struct CdpEvent {
    pub session_id: Option<String>,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, thiserror::Error)]
pub enum CdpError {
    /// The browser answered the command with an error.
    #[error("{0}")]
    Protocol(String),
    #[error("the browser connection closed")]
    Closed,
    #[error("the browser did not answer {method} within {secs} s")]
    Timeout { method: String, secs: u64 },
    #[error("could not connect to the browser: {0}")]
    Connect(String),
}

type Pending = Arc<parking_lot::Mutex<HashMap<u64, oneshot::Sender<Result<Value, CdpError>>>>>;

/// A live connection to the browser's DevTools endpoint.
pub struct CdpConnection {
    outgoing: mpsc::UnboundedSender<Message>,
    pending: Pending,
    events: broadcast::Sender<CdpEvent>,
    next_id: AtomicU64,
    closed: Arc<AtomicBool>,
    tasks: [tokio::task::JoinHandle<()>; 2],
}

impl Drop for CdpConnection {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl CdpConnection {
    /// Connect to a `ws://` DevTools URL.
    pub async fn connect(ws_url: &str, timeout: Duration) -> Result<Arc<Self>, CdpError> {
        let (stream, _) = tokio::time::timeout(timeout, tokio_tungstenite::connect_async(ws_url))
            .await
            .map_err(|_| CdpError::Connect(format!("no answer from {ws_url}")))?
            .map_err(|e| CdpError::Connect(e.to_string()))?;
        let (mut sink, mut source) = stream.split();
        let (outgoing, mut outgoing_rx) = mpsc::unbounded_channel::<Message>();
        let pending: Pending = Arc::default();
        let (events, _) = broadcast::channel(EVENT_CAPACITY);
        let closed = Arc::new(AtomicBool::new(false));

        let writer = tokio::spawn(async move {
            while let Some(message) = outgoing_rx.recv().await {
                if sink.send(message).await.is_err() {
                    break;
                }
            }
            let _ = sink.close().await;
        });

        let reader = {
            let pending = Arc::clone(&pending);
            let events = events.clone();
            let closed = Arc::clone(&closed);
            tokio::spawn(async move {
                while let Some(message) = source.next().await {
                    let text = match message {
                        Ok(Message::Text(text)) => text.as_str().to_owned(),
                        Ok(Message::Binary(bytes)) => String::from_utf8_lossy(&bytes).into_owned(),
                        Ok(Message::Close(_)) | Err(_) => break,
                        Ok(_) => continue,
                    };
                    let Ok(value) = serde_json::from_str::<Value>(&text) else {
                        continue;
                    };
                    if let Some(id) = value.get("id").and_then(Value::as_u64) {
                        let Some(sender) = pending.lock().remove(&id) else {
                            continue;
                        };
                        let answer = match value.get("error") {
                            Some(error) => Err(CdpError::Protocol(protocol_message(error))),
                            None => Ok(value.get("result").cloned().unwrap_or_else(|| json!({}))),
                        };
                        let _ = sender.send(answer);
                    } else if let Some(method) = value.get("method").and_then(Value::as_str) {
                        let _ = events.send(CdpEvent {
                            session_id: value
                                .get("sessionId")
                                .and_then(Value::as_str)
                                .map(str::to_owned),
                            method: method.to_owned(),
                            params: value.get("params").cloned().unwrap_or(Value::Null),
                        });
                    }
                }
                closed.store(true, Ordering::SeqCst);
                for (_, sender) in pending.lock().drain() {
                    let _ = sender.send(Err(CdpError::Closed));
                }
            })
        };

        Ok(Arc::new(Self {
            outgoing,
            pending,
            events,
            next_id: AtomicU64::new(1),
            closed,
            tasks: [writer, reader],
        }))
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Every event from now on.
    pub fn subscribe(&self) -> broadcast::Receiver<CdpEvent> {
        self.events.subscribe()
    }

    /// Send a command to the browser (`session_id` `None`) or to an attached target.
    pub async fn send(
        &self,
        session_id: Option<&str>,
        method: &str,
        params: Value,
    ) -> Result<Value, CdpError> {
        self.send_with_timeout(session_id, method, params, DEFAULT_TIMEOUT)
            .await
    }

    pub async fn send_with_timeout(
        &self,
        session_id: Option<&str>,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, CdpError> {
        if self.is_closed() {
            return Err(CdpError::Closed);
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (answer_tx, answer_rx) = oneshot::channel();
        self.pending.lock().insert(id, answer_tx);
        let message = match session_id {
            Some(session_id) => {
                json!({ "id": id, "method": method, "params": params, "sessionId": session_id })
            }
            None => json!({ "id": id, "method": method, "params": params }),
        };
        if self
            .outgoing
            .send(Message::Text(message.to_string().into()))
            .is_err()
        {
            self.pending.lock().remove(&id);
            return Err(CdpError::Closed);
        }
        match tokio::time::timeout(timeout, answer_rx).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Err(CdpError::Closed),
            Err(_) => {
                self.pending.lock().remove(&id);
                Err(CdpError::Timeout {
                    method: method.to_owned(),
                    secs: timeout.as_secs(),
                })
            }
        }
    }
}

fn protocol_message(error: &Value) -> String {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown error");
    match error.get("data").and_then(Value::as_str) {
        Some(data) if !data.is_empty() => format!("{message} ({data})"),
        _ => message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_errors_keep_their_data() {
        assert_eq!(
            protocol_message(&json!({"code": -32000, "message": "No node", "data": "id 4"})),
            "No node (id 4)"
        );
        assert_eq!(protocol_message(&json!({"message": "Bad"})), "Bad");
    }

    #[tokio::test]
    async fn commands_and_events_round_trip_over_a_socket() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            while let Some(Ok(Message::Text(text))) = socket.next().await {
                let request: Value = serde_json::from_str(text.as_str()).unwrap();
                let event =
                    json!({"method": "Page.loadEventFired", "sessionId": "s1", "params": {}});
                socket
                    .send(Message::Text(event.to_string().into()))
                    .await
                    .unwrap();
                let answer = if request["method"] == "Fail.me" {
                    json!({"id": request["id"], "error": {"message": "nope"}})
                } else {
                    json!({"id": request["id"], "result": {"echo": request["params"]}})
                };
                socket
                    .send(Message::Text(answer.to_string().into()))
                    .await
                    .unwrap();
            }
        });
        let connection = CdpConnection::connect(&format!("ws://{address}"), Duration::from_secs(5))
            .await
            .unwrap();
        let mut events = connection.subscribe();
        let answer = connection
            .send(Some("s1"), "Echo.me", json!({"x": 1}))
            .await
            .unwrap();
        assert_eq!(answer["echo"]["x"], 1);
        let event = events.recv().await.unwrap();
        assert_eq!(event.method, "Page.loadEventFired");
        assert_eq!(event.session_id.as_deref(), Some("s1"));
        let error = connection
            .send(None, "Fail.me", json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), "nope");
        drop(connection);
        server.abort();
    }
}
