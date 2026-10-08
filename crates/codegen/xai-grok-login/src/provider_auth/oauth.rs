//! Protocol reference: Pi's packages/ai/src/auth/oauth/{openrouter,openai-codex}.ts
//! https://github.com/badlogic/pi-mono/tree/main/packages/ai/src/auth/oauth
//! https://openrouter.ai/docs/guides/overview/auth/oauth

use super::{ModelProvider, ProviderCredential, now, storage};
use anyhow::{Context as _, bail};
use axum::extract::State;
use axum::http::{StatusCode, Uri};
use axum::response::IntoResponse as _;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::Deserialize;
use sha2::{Digest as _, Sha256};
use std::future::{Future, IntoFuture as _};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use url::Url;

const OPENROUTER_AUTHORIZE_URL: &str = "https://openrouter.ai/auth";
const OPENROUTER_TOKEN_URL: &str = "https://openrouter.ai/api/v1/auth/keys";
const CODEX_AUTHORIZE_URL: &str = "https://auth.openai.com/oauth/authorize";
pub(super) const CODEX_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const CODEX_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_REDIRECT_URI: &str = "http://localhost:1455/auth/callback";
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

struct AuthorizationFlow {
    provider: ModelProvider,
    verifier: String,
    state: String,
    redirect_url: Url,
    authorize_url: Url,
}

impl AuthorizationFlow {
    fn new(provider: ModelProvider, mut redirect_url: Url) -> anyhow::Result<Self> {
        let verifier = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let state = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
        let mut authorize_url = Url::parse(match provider {
            ModelProvider::OpenRouter => OPENROUTER_AUTHORIZE_URL,
            ModelProvider::OpenAiCodex => CODEX_AUTHORIZE_URL,
            ModelProvider::DeepSeek
            | ModelProvider::Glm
            | ModelProvider::GlmCn
            | ModelProvider::Anthropic => {
                bail!(no_browser_sign_in(provider))
            }
        })?;
        match provider {
            ModelProvider::OpenRouter => {
                // OpenRouter preserves query parameters in callback_url, including state.
                redirect_url.query_pairs_mut().append_pair("state", &state);
                authorize_url
                    .query_pairs_mut()
                    .append_pair("callback_url", redirect_url.as_str());
            }
            ModelProvider::OpenAiCodex => {
                authorize_url.query_pairs_mut().extend_pairs([
                    ("response_type", "code"),
                    ("client_id", CODEX_CLIENT_ID),
                    ("redirect_uri", redirect_url.as_str()),
                    ("scope", "openid profile email offline_access"),
                    ("state", state.as_str()),
                    ("id_token_add_organizations", "true"),
                    ("codex_cli_simplified_flow", "true"),
                    ("originator", "grok"),
                ]);
            }
            ModelProvider::DeepSeek
            | ModelProvider::Glm
            | ModelProvider::GlmCn
            | ModelProvider::Anthropic => {
                bail!(no_browser_sign_in(provider))
            }
        }
        authorize_url.query_pairs_mut().extend_pairs([
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ]);
        Ok(Self {
            provider,
            verifier,
            state,
            redirect_url,
            authorize_url,
        })
    }
}

fn no_browser_sign_in(provider: ModelProvider) -> String {
    format!(
        "{} has no browser sign-in; run `crok login {provider}` and paste an API key",
        provider.display_name()
    )
}

/// Open a browser and wait for the protected loopback callback, then persist the
/// provider credential. `on_url` lets the CLI display a URL when browser launch fails.
pub async fn login_with_oauth(
    home: &Path,
    provider: ModelProvider,
    on_url: impl FnOnce(&str),
) -> anyhow::Result<ProviderCredential> {
    login_flow(home, provider, on_url, std::future::pending(), false).await
}

/// Also accept a full redirect URL pasted by a remote/headless user. The URL must
/// carry the original state and match the expected callback address; bare codes
/// are deliberately rejected because they cannot authenticate the callback.
pub async fn login_with_oauth_input(
    home: &Path,
    provider: ModelProvider,
    on_url: impl FnOnce(&str),
    manual_callback: impl Future<Output = anyhow::Result<String>>,
) -> anyhow::Result<ProviderCredential> {
    login_flow(home, provider, on_url, manual_callback, true).await
}

async fn login_flow(
    home: &Path,
    provider: ModelProvider,
    on_url: impl FnOnce(&str),
    manual_callback: impl Future<Output = anyhow::Result<String>>,
    allow_manual: bool,
) -> anyhow::Result<ProviderCredential> {
    if !provider.has_browser_sign_in() {
        bail!(no_browser_sign_in(provider));
    }
    let port = if provider == ModelProvider::OpenAiCodex {
        1455
    } else {
        0
    };
    let listener = match TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await {
        Ok(listener) => Some(listener),
        Err(_) if allow_manual && provider == ModelProvider::OpenAiCodex => None,
        Err(e) => {
            return Err(e)
                .context("Cannot bind OAuth callback listener; Codex uses localhost port 1455");
        }
    };
    let redirect = if provider == ModelProvider::OpenAiCodex {
        Url::parse(CODEX_REDIRECT_URI)?
    } else {
        let port = listener
            .as_ref()
            .context("Missing OpenRouter callback listener")?
            .local_addr()?
            .port();
        Url::parse(&format!(
            "http://127.0.0.1:{port}/oauth/callback/{}",
            uuid::Uuid::new_v4()
        ))?
    };
    let flow = AuthorizationFlow::new(provider, redirect)?;
    let (tx, rx) = oneshot::channel();
    let state = CallbackState {
        redirect_url: flow.redirect_url.clone(),
        expected_state: flow.state.clone(),
        result: Arc::new(Mutex::new(Some(tx))),
    };
    let router = axum::Router::new()
        .route(flow.redirect_url.path(), axum::routing::get(callback))
        .with_state(state);
    let server = async move {
        match listener {
            Some(listener) => axum::serve(listener, router).into_future().await,
            None => std::future::pending().await,
        }
    };
    on_url(flow.authorize_url.as_str());
    // Browser launch is advisory: the printed URL always remains usable.
    let browser_url = flow.authorize_url.to_string();
    let _ = tokio::task::spawn_blocking(move || webbrowser::open(&browser_url)).await;
    let code = tokio::select! {
        result = rx => result.context("OAuth callback listener stopped")??,
        result = manual_callback => {
            let input = result?;
            let url = Url::parse(input.trim()).map_err(|_| anyhow::anyhow!("Paste the complete OAuth redirect URL, including its state parameter"))?;
            validate_callback(&flow.redirect_url, &flow.state, &url)?
        }
        result = server => {
            result.context("OAuth callback server failed")?;
            bail!("OAuth callback server stopped before authorization completed");
        }
        _ = tokio::time::sleep(LOGIN_TIMEOUT) => bail!("{provider} OAuth login timed out after five minutes"),
    };
    let credential = match provider {
        ModelProvider::OpenRouter => {
            exchange_openrouter(&code, &flow.verifier, OPENROUTER_TOKEN_URL).await?
        }
        ModelProvider::OpenAiCodex => exchange_codex(&code, &flow, CODEX_TOKEN_URL).await?,
        ModelProvider::DeepSeek
        | ModelProvider::Glm
        | ModelProvider::GlmCn
        | ModelProvider::Anthropic => {
            bail!(no_browser_sign_in(provider))
        }
    };
    let _lock = storage::lock(home, provider).await?;
    storage::write(home, &credential)?;
    Ok(credential)
}

#[derive(Clone)]
struct CallbackState {
    redirect_url: Url,
    expected_state: String,
    result: Arc<Mutex<Option<oneshot::Sender<anyhow::Result<String>>>>>,
}

async fn callback(State(state): State<CallbackState>, uri: Uri) -> axum::response::Response {
    let result = state
        .redirect_url
        .join(&uri.to_string())
        .map_err(|_| anyhow::anyhow!("Invalid OAuth callback URL"))
        .and_then(|url| validate_callback(&state.redirect_url, &state.expected_state, &url));
    let (status, message) = match result {
        Ok(code) => {
            let mut sender = state.result.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(sender) = sender.take() {
                let _ = sender.send(Ok(code));
                (
                    StatusCode::OK,
                    "Authorization received. Return to your terminal to finish signing in.",
                )
            } else {
                (
                    StatusCode::CONFLICT,
                    "This OAuth callback has already been used.",
                )
            }
        }
        Err(error) if error.downcast_ref::<AuthorizationDenied>().is_some() => {
            if let Some(sender) = state
                .result
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .take()
            {
                let _ = sender.send(Err(error));
            }
            (
                StatusCode::BAD_REQUEST,
                "Authorization was denied. Start login again in your terminal.",
            )
        }
        Err(_) => (
            StatusCode::BAD_REQUEST,
            "Invalid OAuth callback. Check the login URL and try again.",
        ),
    };
    (
        status,
        [
            ("cache-control", "no-store"),
            ("content-type", "text/plain; charset=utf-8"),
        ],
        message,
    )
        .into_response()
}

#[derive(Debug, thiserror::Error)]
#[error("OAuth authorization was denied; start login again")]
struct AuthorizationDenied;

fn validate_callback(expected: &Url, state: &str, received: &Url) -> anyhow::Result<String> {
    anyhow::ensure!(
        received.origin() == expected.origin()
            && received.path() == expected.path()
            && received.username().is_empty()
            && received.password().is_none()
            && received.fragment().is_none(),
        "OAuth callback address does not match this login"
    );
    let pairs: Vec<_> = received.query_pairs().collect();
    let values = |key: &str| {
        pairs
            .iter()
            .filter(|(name, _)| name == key)
            .map(|(_, value)| value.as_ref())
            .collect::<Vec<_>>()
    };
    let states = values("state");
    anyhow::ensure!(
        states.len() == 1 && states.first().copied() == Some(state),
        "OAuth callback state mismatch"
    );
    if !values("error").is_empty() {
        // Do not echo provider-controlled values, which may include sensitive data.
        return Err(AuthorizationDenied.into());
    }
    let codes = values("code");
    anyhow::ensure!(
        codes.len() == 1 && codes.first().is_some_and(|code| !code.is_empty()),
        "OAuth callback is missing a unique authorization code"
    );
    Ok(codes.first().context("Missing OAuth code")?.to_string())
}

pub(super) fn http_client() -> anyhow::Result<reqwest::Client> {
    xai_grok_extra_ca::build_reqwest_client(|builder| {
        builder
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
    })
    .context("Cannot create provider OAuth HTTP client")
}

async fn response_json<T: serde::de::DeserializeOwned>(
    mut response: reqwest::Response,
) -> anyhow::Result<T> {
    if !response.status().is_success() {
        bail!(
            "Provider OAuth token request failed (HTTP {})",
            response.status().as_u16()
        );
    }
    let mut data = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .context("Cannot read provider OAuth response")?
    {
        anyhow::ensure!(
            data.len().saturating_add(chunk.len()) <= 1024 * 1024,
            "Provider OAuth response is too large"
        );
        data.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&data).map_err(|_| {
        anyhow::anyhow!(
            "Provider OAuth response is missing required fields or contains invalid JSON"
        )
    })
}

async fn exchange_openrouter(
    code: &str,
    verifier: &str,
    token_url: &str,
) -> anyhow::Result<ProviderCredential> {
    #[derive(Deserialize)]
    struct KeyResponse {
        key: String,
    }
    let response = http_client()?
        .post(token_url)
        .json(&serde_json::json!({
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        }))
        .send()
        .await
        .context("Cannot exchange OpenRouter authorization code")?;
    let response: KeyResponse = response_json(response).await?;
    ProviderCredential::api_key(ModelProvider::OpenRouter, &response.key)
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    expires_in: u64,
    #[serde(default)]
    id_token: Option<String>,
}

fn credentials_from_token(
    response: TokenResponse,
    previous: Option<&ProviderCredential>,
) -> anyhow::Result<ProviderCredential> {
    anyhow::ensure!(
        !response.access_token.is_empty() && response.expires_in > 0,
        "Invalid Codex token response"
    );
    let account_id = account_id_from_token(&response.access_token)
        .or_else(|| response.id_token.as_deref().and_then(account_id_from_token))
        .context("Codex token response does not contain a ChatGPT account ID")?;
    if let Some(previous) = previous {
        anyhow::ensure!(
            previous.account_id() == Some(account_id.as_str()),
            "Codex refresh unexpectedly changed accounts; sign in again"
        );
    }
    let refresh_token = response
        .refresh_token
        .filter(|token| !token.is_empty())
        .or_else(|| previous.and_then(|credential| credential.refresh_token.clone()))
        .context("Codex token response does not contain a refresh token")?;
    let issued_at = now();
    Ok(ProviderCredential {
        provider: ModelProvider::OpenAiCodex,
        access_token: response.access_token,
        refresh_token: Some(refresh_token),
        expires_at: Some(
            issued_at
                .checked_add(response.expires_in)
                .context("Invalid Codex token expiration")?,
        ),
        account_id: Some(account_id),
        issued_at,
    })
}

fn account_id_from_token(token: &str) -> Option<String> {
    let mut parts = token.split('.');
    parts.next()?;
    let payload = parts.next()?;
    parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    claims
        .get("https://api.openai.com/auth")?
        .get("chatgpt_account_id")?
        .as_str()
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

async fn exchange_codex(
    code: &str,
    flow: &AuthorizationFlow,
    token_url: &str,
) -> anyhow::Result<ProviderCredential> {
    let response = http_client()?
        .post(token_url)
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", CODEX_CLIENT_ID),
            ("code", code),
            ("code_verifier", &flow.verifier),
            ("redirect_uri", flow.redirect_url.as_str()),
        ])
        .send()
        .await
        .context("Cannot exchange Codex authorization code")?;
    credentials_from_token(response_json(response).await?, None)
}

pub(super) async fn refresh_codex(
    previous: &ProviderCredential,
    token_url: &str,
) -> anyhow::Result<ProviderCredential> {
    let refresh_token = previous
        .refresh_token
        .as_deref()
        .context("Missing Codex refresh token; sign in again")?;
    let response = http_client()?
        .post(token_url)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CODEX_CLIENT_ID),
            ("refresh_token", refresh_token),
        ])
        .send()
        .await
        .context("Cannot refresh Codex access token")?;
    credentials_from_token(response_json(response).await?, Some(previous))
}

#[cfg(test)]
#[path = "oauth_tests.rs"]
mod tests;
