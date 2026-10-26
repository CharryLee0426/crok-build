//! The Remote panel (`/remote`, `/remote open`, `/remote new`): what Crok Desktop's "Other computers" sidebar is, in
//! the TUI. A full-screen picker over the person's other computers, their projects and sessions, kept current by
//! `x.ai/remote/sessions {watch: true}` and `x.ai/remote/sessions_changed`; a session opens here as picking its
//! `relay:` row in `/resume` does, and `n` starts one in a project after asking for the model and thinking level
//! (`x.ai/remote/models`, then `x.ai/remote/new_session`). relay/DESIGN.md §5, "the Remote panel".
//!
//! The panel asks for work through [`Request`]s; the app runs each off the UI thread with [`run`] and hands the
//! [`Response`] back to the panel, which drops any it no longer wants.

pub mod here;
pub mod tree;
pub mod tui;

#[cfg(test)]
mod tests;

use std::time::Duration;

use xai_grok_shell::remote_control::{
    REMOTE_MODELS_METHOD, REMOTE_NEW_SESSION_METHOD, REMOTE_SESSIONS_METHOD,
};

pub use tui::{Outcome, RemotePanel};

/// How often the open panel renews its watch on the list (the agent keeps sending changes for ten minutes).
pub const REWATCH: Duration = Duration::from_secs(5 * 60);
/// How soon it asks again while this computer is not connected to the relay yet.
pub const RETRY: Duration = Duration::from_secs(3);

/// Work the panel needs done off the UI thread. `generation` names the panel that asked: a response for a panel that
/// has closed since (or for one opened later) is dropped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    /// `x.ai/remote/sessions {watch: true}`.
    Sessions { generation: u64 },
    /// Nothing but time: the panel asks for the list again after `delay` if it is still open then.
    Wait { generation: u64, delay: Duration },
    /// `x.ai/remote/models {deviceId}`: what that computer can run.
    Models { generation: u64, device_id: String },
    /// `x.ai/remote/new_session {deviceId, path, model?, effort?}`.
    Create {
        generation: u64,
        device_id: String,
        path: String,
        model: Option<String>,
        effort: Option<String>,
    },
}

#[derive(Debug)]
pub enum Response {
    /// A [`Request::Wait`] is over.
    Due { generation: u64 },
    Sessions {
        generation: u64,
        result: Result<serde_json::Value, String>,
    },
    Models {
        generation: u64,
        device_id: String,
        result: Result<serde_json::Value, String>,
    },
    /// The new session's `relay:` id.
    Created {
        generation: u64,
        result: Result<String, String>,
    },
}

/// Runs a request against the agent (whose remote-control viewer answers these methods).
pub async fn run(request: Request, tx: xai_acp_lib::AcpAgentTx) -> Response {
    match request {
        Request::Wait { generation, delay } => {
            tokio::time::sleep(delay).await;
            Response::Due { generation }
        }
        Request::Sessions { generation } => {
            let result = crate::remote_cmd::ext_call(
                &tx,
                REMOTE_SESSIONS_METHOD,
                serde_json::json!({ "watch": true }),
            )
            .await;
            Response::Sessions { generation, result }
        }
        Request::Models {
            generation,
            device_id,
        } => {
            let result = crate::remote_cmd::ext_call(
                &tx,
                REMOTE_MODELS_METHOD,
                serde_json::json!({ "deviceId": device_id }),
            )
            .await;
            Response::Models {
                generation,
                device_id,
                result,
            }
        }
        Request::Create {
            generation,
            device_id,
            path,
            model,
            effort,
        } => {
            let mut params = serde_json::json!({ "deviceId": device_id, "path": path });
            if let Some(object) = params.as_object_mut() {
                // Left out rather than null: "Default" means the computer's own choice.
                if let Some(model) = model {
                    object.insert("model".into(), serde_json::json!(model));
                }
                if let Some(effort) = effort {
                    object.insert("effort".into(), serde_json::json!(effort));
                }
            }
            let result = crate::remote_cmd::ext_call(&tx, REMOTE_NEW_SESSION_METHOD, params)
                .await
                .and_then(|created| {
                    created
                        .get("sessionId")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_owned)
                        .ok_or_else(|| {
                            xai_grok_i18n::tl("The relay did not start the session.").to_string()
                        })
                });
            Response::Created { generation, result }
        }
    }
}
