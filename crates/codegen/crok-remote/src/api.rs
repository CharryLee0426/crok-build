//! The relay's sign-in functions over Convex's HTTP API (`POST <deployment>/api/mutation`), outside the WebSocket
//! client: the client's own auth callback needs a fresh token, so it cannot wait on itself for one.

use std::time::Duration;

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::credentials::Account;

/// A failure the relay reported (`ConvexError<{ code, message }>`), or a transport failure.
#[derive(Debug)]
pub enum ApiError {
    /// The function threw. `code` is the relay's error code (`REVOKED`, `OFFLINE`, …) when it set one.
    Function {
        code: Option<String>,
        message: String,
    },
    Transport(String),
}

impl ApiError {
    pub fn code(&self) -> Option<&str> {
        match self {
            ApiError::Function { code, .. } => code.as_deref(),
            ApiError::Transport(_) => None,
        }
    }

    /// The device was signed out on the relay; its credentials are no good any more.
    pub fn is_revoked(&self) -> bool {
        self.code() == Some("REVOKED")
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Function { message, .. } => f.write_str(message),
            ApiError::Transport(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for ApiError {}

#[derive(Clone)]
pub struct Api {
    base: String,
    http: reqwest::Client,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: Option<String>,
    pub verification_url_complete: Option<String>,
    pub expires_at: f64,
    pub interval: f64,
}

#[derive(Debug, Clone)]
pub enum LoginPoll {
    Pending,
    Denied,
    Expired,
    Approved {
        device_id: String,
        refresh_token: String,
        access_token: String,
        access_token_expires_at: f64,
        account: Account,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessToken {
    pub device_id: String,
    pub access_token: String,
    pub access_token_expires_at: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PollBody {
    status: String,
    #[serde(default)]
    device_id: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    access_token_expires_at: Option<f64>,
    #[serde(default)]
    user: Option<Account>,
}

/// Turns a Convex HTTP API response body into the function's value or its error.
pub fn parse_response(body: &Value) -> Result<Value, ApiError> {
    match body.get("status").and_then(Value::as_str) {
        Some("success") => Ok(body.get("value").cloned().unwrap_or(Value::Null)),
        Some("error") => {
            let data = body.get("errorData");
            let code = data
                .and_then(|d| d.get("code"))
                .and_then(Value::as_str)
                .map(str::to_owned);
            let message = data
                .and_then(|d| d.get("message"))
                .and_then(Value::as_str)
                .or_else(|| body.get("errorMessage").and_then(Value::as_str))
                .unwrap_or("the relay returned an error")
                .to_owned();
            Err(ApiError::Function { code, message })
        }
        _ => Err(ApiError::Transport(format!(
            "unexpected relay response: {body}"
        ))),
    }
}

impl Api {
    pub fn new(server: &str) -> anyhow::Result<Api> {
        let http = xai_grok_extra_ca::build_reqwest_client(|builder| {
            builder
                .timeout(Duration::from_secs(30))
                .connect_timeout(Duration::from_secs(10))
        })?;
        Ok(Api {
            base: crate::settings::normalize_url(server),
            http,
        })
    }

    pub fn server(&self) -> &str {
        &self.base
    }

    async fn call(
        &self,
        kind: &str,
        path: &str,
        args: Value,
        bearer: Option<&str>,
    ) -> Result<Value, ApiError> {
        let mut request = self
            .http
            .post(format!("{}/api/{kind}", self.base))
            .json(&json!({ "path": path, "args": args, "format": "json" }));
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        let response = request.send().await.map_err(|e| {
            ApiError::Transport(format!("cannot reach the relay at {}: {e}", self.base))
        })?;
        let status = response.status();
        let body: Value = response.json().await.map_err(|e| {
            ApiError::Transport(format!(
                "the relay at {} answered {status} without JSON: {e}",
                self.base
            ))
        })?;
        parse_response(&body)
    }

    pub async fn mutation<T: DeserializeOwned>(
        &self,
        path: &str,
        args: Value,
    ) -> Result<T, ApiError> {
        let value = self.call("mutation", path, args, None).await?;
        serde_json::from_value(value)
            .map_err(|e| ApiError::Transport(format!("{path}: unexpected result: {e}")))
    }

    /// A query as a signed-in device, for one-off reads outside a running link.
    pub async fn query_as<T: DeserializeOwned>(
        &self,
        path: &str,
        args: Value,
        token: &str,
    ) -> Result<T, ApiError> {
        let value = self.call("query", path, args, Some(token)).await?;
        serde_json::from_value(value)
            .map_err(|e| ApiError::Transport(format!("{path}: unexpected result: {e}")))
    }

    pub async fn start_login(
        &self,
        name: &str,
        platform: &str,
        client: &str,
    ) -> Result<LoginStart, ApiError> {
        self.mutation(
            "deviceAuth:start",
            json!({ "kind": "computer", "name": name, "platform": platform, "client": client }),
        )
        .await
    }

    pub async fn poll_login(&self, device_code: &str) -> Result<LoginPoll, ApiError> {
        let body: PollBody = self
            .mutation("deviceAuth:poll", json!({ "deviceCode": device_code }))
            .await?;
        Ok(match body.status.as_str() {
            "pending" => LoginPoll::Pending,
            "denied" => LoginPoll::Denied,
            "approved" => match (body.device_id, body.refresh_token, body.access_token) {
                (Some(device_id), Some(refresh_token), Some(access_token)) => LoginPoll::Approved {
                    device_id,
                    refresh_token,
                    access_token,
                    access_token_expires_at: body.access_token_expires_at.unwrap_or_default(),
                    account: body.user.unwrap_or_default(),
                },
                _ => {
                    return Err(ApiError::Transport(
                        "the relay approved the sign-in without a token".into(),
                    ));
                }
            },
            _ => LoginPoll::Expired,
        })
    }

    pub async fn refresh(&self, refresh_token: &str) -> Result<AccessToken, ApiError> {
        self.mutation(
            "deviceAuth:refresh",
            json!({ "refreshToken": refresh_token }),
        )
        .await
    }

    pub async fn logout(&self, refresh_token: &str) -> Result<(), ApiError> {
        let _: Value = self
            .mutation(
                "deviceAuth:logout",
                json!({ "refreshToken": refresh_token }),
            )
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_and_error_bodies() {
        assert_eq!(
            parse_response(&json!({"status": "success", "value": {"a": 1}})).unwrap(),
            json!({"a": 1})
        );
        let error = parse_response(&json!({
            "status": "error",
            "errorMessage": "Uncaught ConvexError: ...",
            "errorData": {"code": "REVOKED", "message": "This device was signed out."}
        }))
        .unwrap_err();
        assert!(error.is_revoked());
        assert_eq!(error.to_string(), "This device was signed out.");
        let plain = parse_response(&json!({"status": "error", "errorMessage": "Server Error"}))
            .unwrap_err();
        assert_eq!(plain.code(), None);
        assert_eq!(plain.to_string(), "Server Error");
    }
}
