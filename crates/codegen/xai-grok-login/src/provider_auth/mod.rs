//! Provider-specific credentials, deliberately separate from xAI login state.
//!
//! OpenRouter's PKCE exchange produces an API key. Codex uses the ChatGPT
//! authorization-code grant and refresh tokens, as in Pi's Codex provider.
//! DeepSeek, the GLM Coding Plan and Anthropic have no browser flow: the user
//! pastes an API key from the provider's console.

mod oauth;
mod storage;
mod verify;

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use std::path::Path;

pub use oauth::{login_with_oauth, login_with_oauth_input};
pub use verify::{KeyCheck, check_provider_api_key};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelProvider {
    #[serde(rename = "openrouter")]
    OpenRouter,
    #[serde(rename = "openai-codex")]
    OpenAiCodex,
    #[serde(rename = "deepseek")]
    DeepSeek,
    /// GLM Coding Plan subscription bought on z.ai (international).
    #[serde(rename = "glm")]
    Glm,
    /// GLM Coding Plan subscription bought on bigmodel.cn (China mainland).
    /// A separate account system: its keys are not accepted by z.ai, nor z.ai's here.
    #[serde(rename = "glm-cn")]
    GlmCn,
    /// The Claude API with a Claude Console API key, billed per token.
    /// A Claude subscription (Pro, Max) is a different product and does not sign in here.
    #[serde(rename = "anthropic")]
    Anthropic,
}

impl ModelProvider {
    pub const ALL: [Self; 6] = [
        Self::OpenAiCodex,
        Self::OpenRouter,
        Self::DeepSeek,
        Self::Glm,
        Self::GlmCn,
        Self::Anthropic,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenRouter => "openrouter",
            Self::OpenAiCodex => "openai-codex",
            Self::DeepSeek => "deepseek",
            Self::Glm => "glm",
            Self::GlmCn => "glm-cn",
            Self::Anthropic => "anthropic",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|provider| provider.as_str() == id)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::OpenRouter => "OpenRouter",
            Self::OpenAiCodex => "OpenAI Codex",
            Self::DeepSeek => "DeepSeek",
            Self::Glm => "GLM Coding Plan",
            Self::GlmCn => "GLM Coding Plan (China)",
            Self::Anthropic => "Anthropic",
        }
    }

    /// Environment variables that supply this provider's API key; the first one set wins.
    /// Empty for Codex, whose subscription token only comes from browser sign-in.
    pub fn api_key_env_vars(self) -> &'static [&'static str] {
        match self {
            Self::OpenRouter => &["OPENROUTER_API_KEY"],
            Self::OpenAiCodex => &[],
            Self::DeepSeek => &["DEEPSEEK_API_KEY"],
            Self::Glm => &["ZAI_API_KEY"],
            Self::GlmCn => &["ZHIPU_API_KEY"],
            Self::Anthropic => &["ANTHROPIC_API_KEY"],
        }
    }

    /// The page where the user creates the key, for a provider that signs in with nothing else.
    pub fn api_key_page(self) -> Option<&'static str> {
        match self {
            Self::OpenRouter | Self::OpenAiCodex => None,
            Self::DeepSeek => Some("https://platform.deepseek.com/api_keys"),
            Self::Glm => Some("https://z.ai/manage-apikey/apikey-list"),
            Self::GlmCn => Some("https://bigmodel.cn/coding-plan/personal/overview"),
            Self::Anthropic => Some("https://platform.claude.com/settings/keys"),
        }
    }

    /// Whether a pasted or piped API key is a way to sign in.
    pub fn accepts_api_key(self) -> bool {
        self != Self::OpenAiCodex
    }

    /// Whether `crok login` can open a browser for this provider.
    pub fn has_browser_sign_in(self) -> bool {
        matches!(self, Self::OpenRouter | Self::OpenAiCodex)
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

    fn api_key(provider: ModelProvider, key: &str) -> anyhow::Result<Self> {
        let name = provider.display_name();
        if !provider.accepts_api_key() {
            bail!("{name} does not sign in with an API key");
        }
        let key = key.trim();
        if key.is_empty() || key.chars().any(char::is_control) {
            bail!("{name} API key must be nonempty and contain no control characters");
        }
        Ok(Self {
            provider,
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

/// The provider's key variable that is set to something usable, if any.
pub fn provider_api_key_env_var(provider: ModelProvider) -> Option<&'static str> {
    provider
        .api_key_env_vars()
        .iter()
        .copied()
        .find(|var| std::env::var(var).is_ok_and(|key| !key.trim().is_empty()))
}

/// Synchronous, network-free read for model discovery and request headers.
/// A key in the provider's environment variable takes precedence over its stored credential.
/// A Codex credential returned here may need refresh before sending a request.
pub fn read_provider_credential(
    home: &Path,
    provider: ModelProvider,
) -> anyhow::Result<Option<ProviderCredential>> {
    if let Some(var) = provider_api_key_env_var(provider)
        && let Ok(key) = std::env::var(var)
    {
        return ProviderCredential::api_key(provider, &key).map(Some);
    }
    storage::read(home, provider)
}

pub fn has_provider_credential(home: &Path, provider: ModelProvider) -> bool {
    read_provider_credential(home, provider)
        .ok()
        .flatten()
        .is_some()
}

pub async fn store_provider_api_key(
    home: &Path,
    provider: ModelProvider,
    key: &str,
) -> anyhow::Result<()> {
    let credential = ProviderCredential::api_key(provider, key)?;
    let _lock = storage::lock(home, provider).await?;
    storage::write(home, &credential)
}

pub async fn store_openrouter_api_key(home: &Path, key: &str) -> anyhow::Result<()> {
    store_provider_api_key(home, ModelProvider::OpenRouter, key).await
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
    // Only the Codex subscription token expires and refreshes; API keys are used as stored.
    if provider != ModelProvider::OpenAiCodex {
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
