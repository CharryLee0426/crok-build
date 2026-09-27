use std::sync::Arc;

use chrono::{Duration, Utc};
use pretty_assertions::assert_eq;
use xai_grok_login::{AuthManager, AuthMode, GrokAuth, GrokComConfig};
use xai_grok_test_support::EnvGuard;
use xai_grok_voice::VoiceAuthError;

use super::build_voice_auth;

fn session(issuer: &str) -> GrokAuth {
    GrokAuth {
        key: "session-token".to_owned(),
        auth_mode: AuthMode::Oidc,
        oidc_issuer: Some(issuer.to_owned()),
        refresh_token: Some("rt".to_owned()),
        expires_at: Some(Utc::now() + Duration::hours(1)),
        ..GrokAuth::test_default()
    }
}

/// OpenRouter voice uses only the OpenRouter key: the environment key first, then `grok login openrouter`.
#[tokio::test]
#[serial_test::serial]
async fn openrouter_voice_reads_env_then_stored_key() {
    let _env = EnvGuard::unset("OPENROUTER_API_KEY");
    let dir = tempfile::tempdir().unwrap();
    let auth = super::openrouter_voice_auth(dir.path().to_path_buf());
    assert_eq!(
        Err(VoiceAuthError::OpenRouterNotSignedIn),
        auth.bearer().await
    );

    xai_grok_login::provider_auth::store_openrouter_api_key(dir.path(), "sk-or-stored")
        .await
        .unwrap();
    assert_eq!(Ok("sk-or-stored".to_owned()), auth.bearer().await);

    let _env = EnvGuard::set("OPENROUTER_API_KEY", "sk-or-env");
    assert_eq!(Ok("sk-or-env".to_owned()), auth.bearer().await);
}

/// The positive case is a static key, which every build of the manager serves; the xAI-session case is pinned in
/// `xai-grok-login`.
#[tokio::test]
#[serial_test::serial]
async fn foreign_session_is_refused_and_xai_credential_is_served() {
    let _xai = EnvGuard::unset("XAI_API_KEY");
    let _legacy = EnvGuard::unset("GROK_CODE_XAI_API_KEY");
    let _auth_path = EnvGuard::unset("GROK_AUTH_PATH");
    let dir = tempfile::tempdir().unwrap();
    let mgr = Arc::new(AuthManager::new(dir.path(), GrokComConfig::default()));
    let auth = build_voice_auth(mgr.clone(), xai_grok_voice::VoiceProvider::Xai);

    mgr.hot_swap(session("https://cursor.com"));
    assert_eq!(Err(VoiceAuthError::ForeignSession), auth.bearer().await);

    mgr.set_process_static_api_key(Some("xai-static-key".to_owned()));
    assert_eq!(Ok("xai-static-key".to_owned()), auth.bearer().await);

    mgr.set_process_static_api_key(None);
    mgr.clear().unwrap();
    assert_eq!(Err(VoiceAuthError::NotSignedIn), auth.bearer().await);
}
