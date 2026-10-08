use super::*;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use wiremock::matchers::{body_string_contains, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn jwt(account: &str, extra: &str) -> String {
    let claims = serde_json::json!({"https://api.openai.com/auth": {"chatgpt_account_id": account}, "test": extra});
    format!(
        "e30.{}.signature",
        URL_SAFE_NO_PAD.encode(claims.to_string())
    )
}

fn expired_codex() -> ProviderCredential {
    ProviderCredential {
        provider: ModelProvider::OpenAiCodex,
        access_token: jwt("account-1", "old"),
        refresh_token: Some("old-refresh-secret".to_owned()),
        account_id: Some("account-1".to_owned()),
        expires_at: Some(now().saturating_sub(1)),
        issued_at: now().saturating_sub(3600),
    }
}

#[tokio::test]
async fn provider_storage_is_separate_and_private() {
    let dir = tempfile::tempdir().unwrap();
    let xai = dir.path().join("auth.json");
    std::fs::write(&xai, "xai credential sentinel").unwrap();
    store_openrouter_api_key(dir.path(), " openrouter-key ")
        .await
        .unwrap();
    let codex = expired_codex();
    storage::write(dir.path(), &codex).unwrap();
    assert_eq!(
        storage::read(dir.path(), ModelProvider::OpenRouter)
            .unwrap()
            .unwrap()
            .access_token(),
        "openrouter-key"
    );
    assert_eq!(
        storage::read(dir.path(), ModelProvider::OpenAiCodex)
            .unwrap()
            .unwrap()
            .account_id(),
        Some("account-1")
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(dir.path().join("provider-auth/openrouter.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        let mode = std::fs::metadata(dir.path().join("provider-auth"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    remove_provider_credential(dir.path(), ModelProvider::OpenRouter)
        .await
        .unwrap();
    assert!(
        storage::read(dir.path(), ModelProvider::OpenRouter)
            .unwrap()
            .is_none()
    );
    assert!(
        storage::read(dir.path(), ModelProvider::OpenAiCodex)
            .unwrap()
            .is_some()
    );
    assert_eq!(
        std::fs::read_to_string(xai).unwrap(),
        "xai credential sentinel"
    );
}

#[test]
fn malformed_store_and_debug_do_not_reveal_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let credential = expired_codex();
    let debug = format!("{credential:?}");
    assert!(!debug.contains("old-refresh-secret"));
    assert!(!debug.contains(&credential.access_token));
    storage::write(dir.path(), &credential).unwrap();
    let file = dir.path().join("provider-auth/openai-codex.json");
    std::fs::write(file, r#"{"provider":"secret-value-in-invalid-field"}"#).unwrap();
    let error = storage::read(dir.path(), ModelProvider::OpenAiCodex).unwrap_err();
    assert!(!error.to_string().contains("secret-value"));
}

#[test]
fn credential_provider_mismatch_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    storage::write(dir.path(), &expired_codex()).unwrap();
    std::fs::copy(
        dir.path().join("provider-auth/openai-codex.json"),
        dir.path().join("provider-auth/openrouter.json"),
    )
    .unwrap();
    assert!(storage::read(dir.path(), ModelProvider::OpenRouter).is_err());
}

#[test]
fn openrouter_environment_key_takes_precedence_without_changing_saved_key() {
    let dir = tempfile::tempdir().unwrap();
    storage::write(
        dir.path(),
        &ProviderCredential::api_key(ModelProvider::OpenRouter, "saved-key").unwrap(),
    )
    .unwrap();
    let _env = xai_grok_shell_base::env::EnvVarGuard::set("OPENROUTER_API_KEY", "environment-key");
    assert_eq!(
        read_provider_credential(dir.path(), ModelProvider::OpenRouter)
            .unwrap()
            .unwrap()
            .access_token(),
        "environment-key"
    );
    assert_eq!(
        storage::read(dir.path(), ModelProvider::OpenRouter)
            .unwrap()
            .unwrap()
            .access_token(),
        "saved-key"
    );
}

#[tokio::test]
async fn key_providers_each_keep_their_own_key_and_are_used_as_stored() {
    // An environment key would be read in place of the stored one.
    let _env = xai_grok_shell_base::env::EnvVarGuard::remove("DEEPSEEK_API_KEY")
        .and_remove("ZAI_API_KEY")
        .and_remove("ZHIPU_API_KEY");
    let dir = tempfile::tempdir().unwrap();
    let keys = [
        (ModelProvider::DeepSeek, "sk-deepseek-fixture"),
        (ModelProvider::Glm, "zai-fixture.key"),
        (ModelProvider::GlmCn, "bigmodel-fixture.key"),
    ];
    for (provider, key) in keys {
        assert!(provider.accepts_api_key() && !provider.has_browser_sign_in());
        store_provider_api_key(dir.path(), provider, &format!(" {key}\n"))
            .await
            .unwrap();
    }
    for (provider, key) in keys {
        // The two GLM sites never read each other's key.
        assert!(
            dir.path()
                .join(format!("provider-auth/{provider}.json"))
                .exists()
        );
        let loaded = load_with_refresh(
            dir.path(),
            provider,
            Some(key),
            "http://127.0.0.1:1/no-network-expected",
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(loaded.access_token(), key);
        assert!(!loaded.is_expired_or_near());
    }
    remove_provider_credential(dir.path(), ModelProvider::Glm)
        .await
        .unwrap();
    assert!(!has_provider_credential(dir.path(), ModelProvider::Glm));
    assert!(has_provider_credential(dir.path(), ModelProvider::GlmCn));
    assert!(has_provider_credential(dir.path(), ModelProvider::DeepSeek));
}

#[tokio::test]
async fn sign_in_methods_do_not_cross() {
    let dir = tempfile::tempdir().unwrap();
    // A ChatGPT subscription is not a key, and an empty or multi-line paste is not one either.
    assert!(
        store_provider_api_key(dir.path(), ModelProvider::OpenAiCodex, "sk-anything")
            .await
            .is_err()
    );
    for bad in ["", "   ", "line-one\nline-two"] {
        let error = store_provider_api_key(dir.path(), ModelProvider::DeepSeek, bad)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("DeepSeek"), "{error}");
    }
    assert!(!dir.path().join("provider-auth").exists());
    // Key-only providers never open a browser or bind the callback port.
    for provider in [
        ModelProvider::DeepSeek,
        ModelProvider::Glm,
        ModelProvider::GlmCn,
    ] {
        let error = login_with_oauth(dir.path(), provider, |_| {
            panic!("no sign-in page exists for {provider}")
        })
        .await
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains(&format!("crok login {provider}")),
            "{error}"
        );
    }
}

#[test]
fn each_provider_reads_only_its_own_environment_key() {
    let dir = tempfile::tempdir().unwrap();
    let env = xai_grok_shell_base::env::EnvVarGuard::remove("OPENROUTER_API_KEY")
        .and_remove("DEEPSEEK_API_KEY")
        .and_remove("ZAI_API_KEY")
        .and_remove("ZHIPU_API_KEY");
    for provider in ModelProvider::ALL {
        assert_eq!(provider_api_key_env_var(provider), None);
        assert_eq!(ModelProvider::from_id(provider.as_str()), Some(provider));
        assert!(!has_provider_credential(dir.path(), provider));
    }
    let _env = env
        .and_set("ZAI_API_KEY", "zai-environment-key")
        .and_set("DEEPSEEK_API_KEY", "  ");
    assert_eq!(
        read_provider_credential(dir.path(), ModelProvider::Glm)
            .unwrap()
            .unwrap()
            .access_token(),
        "zai-environment-key"
    );
    // A z.ai key says nothing about a bigmodel.cn subscription, and a blank variable is no key.
    assert!(!has_provider_credential(dir.path(), ModelProvider::GlmCn));
    assert!(!has_provider_credential(
        dir.path(),
        ModelProvider::DeepSeek
    ));
    assert_eq!(
        provider_api_key_env_var(ModelProvider::Glm),
        Some("ZAI_API_KEY")
    );
}

#[tokio::test]
async fn concurrent_refresh_reuses_rotated_credential() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    storage::write(dir.path(), &expired_codex()).unwrap();
    let access = jwt("account-1", "new");
    Mock::given(method("POST"))
        .and(path("/token"))
        .and(body_string_contains("grant_type=refresh_token"))
        .and(body_string_contains("refresh_token=old-refresh-secret"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": access, "refresh_token": "rotated-refresh-secret", "expires_in": 3600
        })))
        .expect(1)
        .mount(&server)
        .await;
    let endpoint = format!("{}/token", server.uri());
    let (first, second) = tokio::join!(
        load_with_refresh(dir.path(), ModelProvider::OpenAiCodex, None, &endpoint),
        load_with_refresh(dir.path(), ModelProvider::OpenAiCodex, None, &endpoint),
    );
    assert_eq!(first.unwrap().unwrap().access_token(), access);
    assert_eq!(second.unwrap().unwrap().access_token(), access);
    assert_eq!(
        storage::read(dir.path(), ModelProvider::OpenAiCodex)
            .unwrap()
            .unwrap()
            .refresh_token
            .as_deref(),
        Some("rotated-refresh-secret")
    );
}

#[tokio::test]
async fn failed_refresh_preserves_stored_credential_and_redacts_body() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let old = expired_codex();
    storage::write(dir.path(), &old).unwrap();
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(401).set_body_string("sensitive-provider-error"))
        .mount(&server)
        .await;
    let error = load_with_refresh(dir.path(), ModelProvider::OpenAiCodex, None, &server.uri())
        .await
        .unwrap_err();
    assert!(!format!("{error:#}").contains("sensitive-provider-error"));
    assert_eq!(
        storage::read(dir.path(), ModelProvider::OpenAiCodex)
            .unwrap()
            .unwrap()
            .access_token(),
        old.access_token()
    );
}

#[tokio::test]
async fn refresh_can_keep_existing_refresh_token_and_rejects_account_change() {
    let server = MockServer::start().await;
    let old = expired_codex();
    Mock::given(path("/same"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": jwt("account-1", "new"), "expires_in": 3600
        })))
        .mount(&server)
        .await;
    let refreshed = oauth::refresh_codex(&old, &format!("{}/same", server.uri()))
        .await
        .unwrap();
    assert_eq!(refreshed.refresh_token, old.refresh_token);
    Mock::given(path("/changed"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": jwt("account-2", "new"), "refresh_token": "new", "expires_in": 3600
        })))
        .mount(&server)
        .await;
    assert!(
        oauth::refresh_codex(&old, &format!("{}/changed", server.uri()))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn rejected_recent_token_is_not_refreshed_again() {
    let dir = tempfile::tempdir().unwrap();
    let mut credential = expired_codex();
    credential.issued_at = now();
    credential.expires_at = Some(now() + 3600);
    storage::write(dir.path(), &credential).unwrap();
    let loaded = load_with_refresh(
        dir.path(),
        ModelProvider::OpenAiCodex,
        Some(credential.access_token()),
        "http://127.0.0.1:1/no-network-expected",
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(loaded.access_token(), credential.access_token());
}

#[tokio::test]
async fn builtin_privilege_is_local_and_does_not_round_trip() {
    let mut provider = crate::AuthProviderRef::builtin(ModelProvider::OpenAiCodex);
    provider.attach_trusted_config(None);
    assert_eq!(
        provider.builtin_provider(),
        Some(ModelProvider::OpenAiCodex)
    );
    let encoded = serde_json::to_string(&provider).unwrap();
    let mut restored: crate::AuthProviderRef = serde_json::from_str(&encoded).unwrap();
    assert_eq!(restored.builtin_provider(), None);
    assert_ne!(provider, restored);
    assert!(restored.cached_token().is_none());
    assert!(matches!(
        restored.ensure_fresh_token(None).await,
        crate::ProviderRefreshOutcome::Unusable
    ));
    restored.attach_trusted_config(None);
    assert_eq!(restored.builtin_provider(), None);
    assert_ne!(provider, restored);
    assert!(restored.cached_token().is_none());
}
