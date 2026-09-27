//! Bridge the shell's `AuthManager` (xAI) or the OpenRouter credential onto the voice crate's bearer provider.
//!
//! OpenRouter (the default voice provider) takes the OpenRouter API key from `grok login openrouter` or `OPENROUTER_API_KEY`.
//!
//! voice-api accepts an xAI API key or an xAI OAuth2 token at `api.x.ai` and attributes per-user billing for OAuth.
//! The bearer comes from the shell's side-call resolver, the same one the Imagine tools use, so a login issued by a
//! foreign authority is refused here and no socket opens for it.
//!
//! Resolved per request: the agent's refreshing manager in direct-spawn mode.
//! In leader mode, a non-refreshing one adopts the agent's rotated `auth.json` token under the file lock (see [`crate::acp`]).

use std::future::{Future, ready};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use xai_grok_tools::types::SharedApiKeyProvider;
use xai_grok_tools::types::api_key_provider::SideCallBearerError;
use xai_grok_voice::{SharedVoiceAuth, VoiceAuthError, VoiceAuthProvider, VoiceProvider};

/// Adapts the shell's `ApiKeyProvider` onto [`VoiceAuthProvider`].
///
/// Resolves a token per request (never a static snapshot), so a long session follows the `AuthManager` instead of pinning a token that 401s.
struct AuthManagerVoiceAuth(SharedApiKeyProvider);

impl std::fmt::Debug for AuthManagerVoiceAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AuthManagerVoiceAuth")
    }
}

fn voice_auth_error(error: SideCallBearerError) -> VoiceAuthError {
    match error {
        SideCallBearerError::ForeignSession => VoiceAuthError::ForeignSession,
        SideCallBearerError::Missing => VoiceAuthError::NotSignedIn,
    }
}

impl VoiceAuthProvider for AuthManagerVoiceAuth {
    fn bearer(&self) -> Pin<Box<dyn Future<Output = Result<String, VoiceAuthError>> + Send + '_>> {
        let provider = self.0.clone();
        Box::pin(async move { provider.side_call_bearer().await.map_err(voice_auth_error) })
    }
}

/// The OpenRouter key for transcription: `OPENROUTER_API_KEY`, else the `grok login openrouter` credential under `home`.
/// Read per request (a local file read), so logging in mid-session takes effect on the next utterance.
struct OpenRouterVoiceAuth {
    home: PathBuf,
}

impl std::fmt::Debug for OpenRouterVoiceAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OpenRouterVoiceAuth")
    }
}

impl VoiceAuthProvider for OpenRouterVoiceAuth {
    fn bearer(&self) -> Pin<Box<dyn Future<Output = Result<String, VoiceAuthError>> + Send + '_>> {
        let credential = xai_grok_login::provider_auth::read_provider_credential(
            &self.home,
            xai_grok_login::provider_auth::ModelProvider::OpenRouter,
        );
        Box::pin(ready(match credential {
            Ok(Some(credential)) => Ok(credential.access_token().to_owned()),
            Ok(None) | Err(_) => Err(VoiceAuthError::OpenRouterNotSignedIn),
        }))
    }
}

fn openrouter_voice_auth(home: PathBuf) -> SharedVoiceAuth {
    Arc::new(OpenRouterVoiceAuth { home })
}

/// Build the voice bearer provider for `provider`.
///
/// xAI serves xAI logins and `XAI_API_KEY` / per-model BYOK keys from the connection's `AuthManager`; a foreign-issuer
/// login resolves to [`VoiceAuthError::ForeignSession`] instead of a bearer. OpenRouter uses the OpenRouter key only.
pub fn build_voice_auth(
    auth_manager: Arc<xai_grok_login::AuthManager>,
    provider: VoiceProvider,
) -> SharedVoiceAuth {
    match provider {
        VoiceProvider::Xai => Arc::new(AuthManagerVoiceAuth(
            xai_grok_login::shared_api_key_provider(auth_manager),
        )),
        VoiceProvider::OpenRouter => openrouter_voice_auth(xai_grok_config::grok_home()),
    }
}

#[cfg(test)]
#[path = "auth_tests.rs"]
mod tests;
