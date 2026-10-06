//! Records every ACP request the agent fails, at the one place they all leave it.
//!
//! A handler that fails returns an `acp::Error`, and the client is shown its `message`. For the several hundred sites
//! that build one with `acp::Error::internal_error().data(…)` that message is the bare "Internal error": the cause is
//! in `data`, which a client is free to drop, and in a `tracing` line, which nothing keeps. [`RequestLog`] wraps the
//! agent handed to the connection and writes each failure to the unified log as `acp.request_failed`, with the method,
//! the session, the code and the full `data`.

use std::time::{Duration, Instant};

use agent_client_protocol as acp;
use serde_json::json;
use xai_grok_telemetry::unified_log;

/// Longest serialized `data` kept in an entry. An error that embeds a response body is cut here.
const MAX_DATA_BYTES: usize = 8 * 1024;

/// An agent whose failed requests are written to the unified log. Responses pass through untouched.
pub struct RequestLog<A>(pub A);

impl<A> RequestLog<A> {
    async fn run<T>(
        method: &str,
        session: Option<String>,
        request: impl std::future::Future<Output = acp::Result<T>>,
    ) -> acp::Result<T> {
        let started = Instant::now();
        let result = request.await;
        if let Err(error) = &result {
            report(method, session.as_deref(), error, started.elapsed());
        }
        result
    }
}

/// `error` for an internal error, which is always a defect or an unhandled condition. Other codes (auth required,
/// invalid params, not found) are answers a client can act on, so they are warnings.
fn report(method: &str, session: Option<&str>, error: &acp::Error, elapsed: Duration) {
    let ctx = json!({
        "method": method,
        "code": i32::from(error.code),
        "message": error.message,
        "data": error.data.as_ref().map(bounded),
        "duration_ms": u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX),
    });
    if error.code == acp::ErrorCode::InternalError {
        unified_log::error("acp.request_failed", session, Some(ctx));
    } else {
        unified_log::warn("acp.request_failed", session, Some(ctx));
    }
}

/// `data` as given, or its JSON text cut to [`MAX_DATA_BYTES`] when it is larger.
fn bounded(data: &serde_json::Value) -> serde_json::Value {
    let mut text = match data {
        serde_json::Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    if text.len() <= MAX_DATA_BYTES {
        return data.clone();
    }
    text.truncate(text.floor_char_boundary(MAX_DATA_BYTES));
    text.push('…');
    text.into()
}

/// The session an extension call names, read only once the call has failed.
fn session_in(params: &serde_json::value::RawValue) -> Option<String> {
    let params: serde_json::Value = serde_json::from_str(params.get()).ok()?;
    ["sessionId", "session_id"]
        .iter()
        .find_map(|key| params.get(key)?.as_str())
        .map(str::to_owned)
}

#[async_trait::async_trait(?Send)]
impl<A: acp::Agent> acp::Agent for RequestLog<A> {
    async fn initialize(
        &self,
        args: acp::InitializeRequest,
    ) -> acp::Result<acp::InitializeResponse> {
        Self::run("initialize", None, self.0.initialize(args)).await
    }

    async fn authenticate(
        &self,
        args: acp::AuthenticateRequest,
    ) -> acp::Result<acp::AuthenticateResponse> {
        Self::run("authenticate", None, self.0.authenticate(args)).await
    }

    async fn logout(&self, args: acp::LogoutRequest) -> acp::Result<acp::LogoutResponse> {
        Self::run("logout", None, self.0.logout(args)).await
    }

    async fn new_session(
        &self,
        args: acp::NewSessionRequest,
    ) -> acp::Result<acp::NewSessionResponse> {
        Self::run("session/new", None, self.0.new_session(args)).await
    }

    async fn load_session(
        &self,
        args: acp::LoadSessionRequest,
    ) -> acp::Result<acp::LoadSessionResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/load", session, self.0.load_session(args)).await
    }

    async fn prompt(&self, args: acp::PromptRequest) -> acp::Result<acp::PromptResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/prompt", session, self.0.prompt(args)).await
    }

    async fn cancel(&self, args: acp::CancelNotification) -> acp::Result<()> {
        let session = Some(args.session_id.to_string());
        Self::run("session/cancel", session, self.0.cancel(args)).await
    }

    async fn set_session_mode(
        &self,
        args: acp::SetSessionModeRequest,
    ) -> acp::Result<acp::SetSessionModeResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/set_mode", session, self.0.set_session_mode(args)).await
    }

    async fn set_session_model(
        &self,
        args: acp::SetSessionModelRequest,
    ) -> acp::Result<acp::SetSessionModelResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/set_model", session, self.0.set_session_model(args)).await
    }

    async fn set_session_config_option(
        &self,
        args: acp::SetSessionConfigOptionRequest,
    ) -> acp::Result<acp::SetSessionConfigOptionResponse> {
        let session = Some(args.session_id.to_string());
        Self::run(
            "session/set_config_option",
            session,
            self.0.set_session_config_option(args),
        )
        .await
    }

    async fn list_sessions(
        &self,
        args: acp::ListSessionsRequest,
    ) -> acp::Result<acp::ListSessionsResponse> {
        Self::run("session/list", None, self.0.list_sessions(args)).await
    }

    async fn fork_session(
        &self,
        args: acp::ForkSessionRequest,
    ) -> acp::Result<acp::ForkSessionResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/fork", session, self.0.fork_session(args)).await
    }

    async fn resume_session(
        &self,
        args: acp::ResumeSessionRequest,
    ) -> acp::Result<acp::ResumeSessionResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/resume", session, self.0.resume_session(args)).await
    }

    async fn close_session(
        &self,
        args: acp::CloseSessionRequest,
    ) -> acp::Result<acp::CloseSessionResponse> {
        let session = Some(args.session_id.to_string());
        Self::run("session/close", session, self.0.close_session(args)).await
    }

    async fn ext_method(&self, args: acp::ExtRequest) -> acp::Result<acp::ExtResponse> {
        let (method, params) = (args.method.clone(), args.params.clone());
        let started = Instant::now();
        let result = self.0.ext_method(args).await;
        if let Err(error) = &result {
            report(
                &method,
                session_in(&params).as_deref(),
                error,
                started.elapsed(),
            );
        }
        result
    }

    async fn ext_notification(&self, args: acp::ExtNotification) -> acp::Result<()> {
        let (method, params) = (args.method.clone(), args.params.clone());
        let started = Instant::now();
        let result = self.0.ext_notification(args).await;
        if let Err(error) = &result {
            report(
                &method,
                session_in(&params).as_deref(),
                error,
                started.elapsed(),
            );
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use acp::Agent as _;

    use super::*;

    /// Fails every call with the error it was built with; the trait's defaults answer the rest.
    struct Failing(acp::Error);

    #[async_trait::async_trait(?Send)]
    impl acp::Agent for Failing {
        async fn initialize(
            &self,
            _: acp::InitializeRequest,
        ) -> acp::Result<acp::InitializeResponse> {
            Err(self.0.clone())
        }

        async fn authenticate(
            &self,
            _: acp::AuthenticateRequest,
        ) -> acp::Result<acp::AuthenticateResponse> {
            Err(self.0.clone())
        }

        async fn new_session(
            &self,
            _: acp::NewSessionRequest,
        ) -> acp::Result<acp::NewSessionResponse> {
            Err(self.0.clone())
        }

        async fn prompt(&self, _: acp::PromptRequest) -> acp::Result<acp::PromptResponse> {
            Err(self.0.clone())
        }

        async fn cancel(&self, _: acp::CancelNotification) -> acp::Result<()> {
            Ok(())
        }

        async fn ext_method(&self, _: acp::ExtRequest) -> acp::Result<acp::ExtResponse> {
            Err(self.0.clone())
        }
    }

    fn entries(session: &str) -> Vec<serde_json::Value> {
        let log = unified_log::snapshot_session_log(session).unwrap_or_default();
        String::from_utf8_lossy(&log)
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn ext(method: &str, params: &str) -> acp::ExtRequest {
        let raw = serde_json::value::RawValue::from_string(params.to_owned()).unwrap();
        acp::ExtRequest::new(method, Arc::from(raw))
    }

    #[tokio::test]
    async fn an_internal_error_is_logged_with_its_cause_and_returned_unchanged() {
        unified_log::redirect_to_temp_for_tests();
        let cause = acp::Error::internal_error().data("session store: disk I/O error");
        let agent = RequestLog(Failing(cause.clone()));

        let error = agent
            .prompt(acp::PromptRequest::new("request-log-sid-1", Vec::new()))
            .await
            .unwrap_err();
        assert_eq!(error.message, cause.message);
        assert_eq!(error.data, cause.data);

        let logged = entries("request-log-sid-1");
        assert_eq!(logged.len(), 1, "{logged:?}");
        let entry = &logged[0];
        assert_eq!(entry["msg"], "acp.request_failed");
        assert_eq!(entry["lvl"], "error");
        assert_eq!(entry["ctx"]["method"], "session/prompt");
        assert_eq!(entry["ctx"]["code"], -32603);
        assert_eq!(entry["ctx"]["data"], "session store: disk I/O error");
        assert!(entry["ctx"]["duration_ms"].is_u64());
    }

    #[tokio::test]
    async fn an_extension_failure_names_its_method_and_session() {
        unified_log::redirect_to_temp_for_tests();
        let agent = RequestLog(Failing(
            acp::Error::invalid_params().data(json!({ "message": "unknown session id" })),
        ));

        let _ = agent
            .ext_method(ext(
                "x.ai/session/info",
                r#"{"sessionId":"request-log-sid-2"}"#,
            ))
            .await
            .unwrap_err();

        let logged = entries("request-log-sid-2");
        assert_eq!(logged.len(), 1, "{logged:?}");
        let entry = &logged[0];
        // Not an internal error: the client was told what to fix.
        assert_eq!(entry["lvl"], "warn");
        assert_eq!(entry["ctx"]["method"], "x.ai/session/info");
        assert_eq!(entry["ctx"]["data"]["message"], "unknown session id");
    }

    #[tokio::test]
    async fn a_request_that_succeeds_writes_nothing() {
        unified_log::redirect_to_temp_for_tests();
        let agent = RequestLog(Failing(acp::Error::internal_error()));
        agent
            .cancel(acp::CancelNotification::new("request-log-sid-3"))
            .await
            .unwrap();
        assert!(entries("request-log-sid-3").is_empty());
    }

    #[test]
    fn oversized_data_is_cut_to_text() {
        let small = json!({ "message": "short" });
        assert_eq!(bounded(&small), small);

        let large = json!({ "body": "é".repeat(MAX_DATA_BYTES) });
        let cut = bounded(&large);
        let text = cut.as_str().expect("cut data becomes text");
        assert!(text.len() <= MAX_DATA_BYTES + '…'.len_utf8());
        assert!(text.ends_with('…'));
    }
}
