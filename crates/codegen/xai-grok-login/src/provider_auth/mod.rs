//! Provider-specific credentials, deliberately separate from xAI login state.
//!
//! OpenRouter's PKCE exchange produces an API key. Codex uses the ChatGPT
//! authorization-code grant and refresh tokens, as in Pi's Codex provider.

mod oauth;
mod storage;

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use std::path::Path;

pub use oauth::{login_with_oauth, login_with_oauth_input};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelProvider {
    #[serde(rename = "openrouter")]
    OpenRouter,
    #[serde(rename = "openai-codex")]
    OpenAiCodex,
}

impl ModelProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenRouter => "openrouter",
            Self::OpenAiCodex => "openai-codex",
        }
    }
}

impl std::fmt::Display for ModelProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Secrets are never included in Debug or an authentication error.
#[derive(Clone, Serialize, Deserialize)]
pub struct ProviderCredential {
    provider: ModelProvider,
    access_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    refresh_token: Option<String>,
    /// Unix seconds, unlike Pi's millisecond expiry representation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expires_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    account_id: Option<String>,
    #[serde(default)]
    issued_at: u64,
}

impl std::fmt::Debug for ProviderCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderCredential")
            .field("provider", &self.provider)
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

impl ProviderCredential {
    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    pub fn account_id(&self) -> Option<&str> {
        self.account_id.as_deref()
    }

    pub fn expires_at(&self) -> Option<u64> {
        self.expires_at
    }

    pub fn is_expired_or_near(&self) -> bool {
        self.expires_at
            .is_some_and(|at| at <= now().saturating_add(60))
    }

    fn api_key(key: &str) -> anyhow::Result<Self> {
        let key = key.trim();
        if key.is_empty() || key.chars().any(char::is_control) {
            bail!("OpenRouter API key must be nonempty and contain no control characters");
        }
        Ok(Self {
            provider: ModelProvider::OpenRouter,
            access_token: key.to_owned(),
            refresh_token: None,
            expires_at: None,
            account_id: None,
            issued_at: now(),
        })
    }

    fn validate(&self, provider: ModelProvider) -> anyhow::Result<()> {
        if self.provider != provider || self.access_token.is_empty() {
            bail!("Invalid {provider} credential file; run `crok login {provider}` again");
        }
        if provider == ModelProvider::OpenAiCodex
            && (self.refresh_token.as_ref().is_none_or(String::is_empty)
                || self.account_id.as_ref().is_none_or(String::is_empty)
                || self.expires_at.is_none())
        {
            bail!("Incomplete Codex OAuth credential; run `crok login openai-codex` again");
        }
        Ok(())
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Synchronous, network-free read for model discovery and request headers.
/// OpenRouter's environment key takes precedence over its stored credential.
/// A Codex credential returned here may need refresh before sending a request.
pub fn read_provider_credential(
    home: &Path,
    provider: ModelProvider,
) -> anyhow::Result<Option<ProviderCredential>> {
    if provider == ModelProvider::OpenRouter
        && let Ok(key) = std::env::var("OPENROUTER_API_KEY")
        && !key.trim().is_empty()
    {
        return ProviderCredential::api_key(&key).map(Some);
    }
    storage::read(home, provider)
}

pub fn has_provider_credential(home: &Path, provider: ModelProvider) -> bool {
    read_provider_credential(home, provider)
        .ok()
        .flatten()
        .is_some()
}

pub async fn store_openrouter_api_key(home: &Path, key: &str) -> anyhow::Result<()> {
    let credential = ProviderCredential::api_key(key)?;
    let _lock = storage::lock(home, ModelProvider::OpenRouter).await?;
    storage::write(home, &credential)
}

/// Removes only this provider's persisted credential. Environment keys are not modified.
pub async fn remove_provider_credential(
    home: &Path,
    provider: ModelProvider,
) -> anyhow::Result<()> {
    let _lock = storage::lock(home, provider).await?;
    storage::remove(home, provider)
}

/// Load a usable bearer, refreshing Codex tokens before expiry. File locking and
/// re-reading under the lock avoid reusing a rotated refresh token across processes.
pub async fn load_provider_credential(
    home: &Path,
    provider: ModelProvider,
) -> anyhow::Result<Option<ProviderCredential>> {
    load_with_refresh(home, provider, None, oauth::CODEX_TOKEN_URL).await
}

pub(crate) async fn recover_provider_credential(
    home: &Path,
    provider: ModelProvider,
    rejected: &str,
) -> anyhow::Result<Option<ProviderCredential>> {
    load_with_refresh(home, provider, Some(rejected), oauth::CODEX_TOKEN_URL).await
}

async fn load_with_refresh(
    home: &Path,
    provider: ModelProvider,
    rejected: Option<&str>,
    token_url: &str,
) -> anyhow::Result<Option<ProviderCredential>> {
    let Some(credential) = read_provider_credential(home, provider)? else {
        return Ok(None);
    };
    if provider == ModelProvider::OpenRouter {
        return Ok(Some(credential));
    }
    let should_refresh = |credential: &ProviderCredential| {
        credential.is_expired_or_near()
            || (rejected == Some(credential.access_token())
                && now().saturating_sub(credential.issued_at) >= 30)
    };
    if !should_refresh(&credential) {
        return Ok(Some(credential));
    }
    let _lock = storage::lock(home, provider).await?;
    let Some(credential) = storage::read(home, provider)? else {
        return Ok(None);
    };
    if !should_refresh(&credential) {
        return Ok(Some(credential));
    }
    let refreshed = oauth::refresh_codex(&credential, token_url)
        .await
        .context("Codex authentication refresh failed; run `crok login openai-codex` if your session was revoked")?;
    storage::write(home, &refreshed)?;
    Ok(Some(refreshed))
}

#[cfg(test)]
mod tests;
