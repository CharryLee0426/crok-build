//! One cheap question at sign-in: does the provider accept this key?
//!
//! A pasted key is easy to get wrong, and the GLM Coding Plan has two sites whose
//! keys look alike and are refused by each other. A refused key is not saved. When
//! there is no answer (offline, or a reply this build does not understand) the key
//! is saved unchecked, since the first request will settle it.

use super::ModelProvider;
use serde::Deserialize;
use std::time::Duration;

const DEEPSEEK_MODELS_URL: &str = "https://api.deepseek.com/models";
/// The plan's usage report, as z.ai's own usage plugin reads it. It takes the bare key, not a Bearer token.
const GLM_QUOTA_URL: &str = "https://api.z.ai/api/monitor/usage/quota/limit";
const GLM_CN_QUOTA_URL: &str = "https://open.bigmodel.cn/api/monitor/usage/quota/limit";
/// One model is enough to learn whether the key is accepted.
const ANTHROPIC_MODELS_URL: &str = "https://api.anthropic.com/v1/models?limit=1";
/// The API version every Anthropic request names. See https://platform.claude.com/docs/en/api/versioning.
const ANTHROPIC_VERSION: &str = "2023-06-01";
const CHECK_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyCheck {
    Accepted,
    /// The provider refused the key. The text says so and what to try, without the key.
    Rejected(String),
    /// No verdict; the text says why.
    Unverified(String),
}

/// Ask `provider` whether it accepts `key`. Providers with no check return [`KeyCheck::Accepted`].
pub async fn check_provider_api_key(provider: ModelProvider, key: &str) -> KeyCheck {
    let url = match provider {
        ModelProvider::DeepSeek => DEEPSEEK_MODELS_URL,
        ModelProvider::Glm => GLM_QUOTA_URL,
        ModelProvider::GlmCn => GLM_CN_QUOTA_URL,
        ModelProvider::Anthropic => {
            if let Some(wrong_kind) = anthropic_wrong_kind_of_key(key) {
                return wrong_kind;
            }
            ANTHROPIC_MODELS_URL
        }
        ModelProvider::OpenRouter | ModelProvider::OpenAiCodex => return KeyCheck::Accepted,
    };
    check_at(provider, key, url).await
}

/// Anthropic issues other credentials that look like an API key and cannot send messages.
/// Saying which one was pasted is more use than the 401 the API would answer with.
fn anthropic_wrong_kind_of_key(key: &str) -> Option<KeyCheck> {
    let key = key.trim();
    if key.starts_with("sk-ant-admin") {
        return Some(KeyCheck::Rejected(
            "This is an Admin API key: it manages an organization and reads its usage reports, \
             and Anthropic does not accept it for messages. Create an API key on the API keys page \
             of the Claude Console and use that one."
                .to_owned(),
        ));
    }
    if key.starts_with("sk-ant-oat") {
        return Some(KeyCheck::Rejected(
            "This is a Claude subscription token, not an API key. Signing in here takes an API \
             key from the Claude Console, which is billed per token."
                .to_owned(),
        ));
    }
    None
}

fn rejected(provider: ModelProvider) -> KeyCheck {
    KeyCheck::Rejected(match provider {
        // The usual cause is a key from the other site. The text is shown in the terminal and in Crok Desktop.
        ModelProvider::Glm => "z.ai did not accept this API key. If your subscription is from \
                               bigmodel.cn, use that site's sign-in instead (crok login glm-cn)."
            .to_owned(),
        ModelProvider::GlmCn => "bigmodel.cn did not accept this API key. If your subscription is \
                                 from z.ai, use that site's sign-in instead (crok login glm)."
            .to_owned(),
        other => format!("{} did not accept this API key.", other.display_name()),
    })
}

async fn check_at(provider: ModelProvider, key: &str, url: &str) -> KeyCheck {
    let unverified = |why: String| KeyCheck::Unverified(why);
    let client = match super::oauth::http_client() {
        Ok(client) => client,
        Err(error) => return unverified(error.to_string()),
    };
    let request = client.get(url).timeout(CHECK_TIMEOUT);
    let request = match provider {
        ModelProvider::Glm | ModelProvider::GlmCn => request
            .header(reqwest::header::AUTHORIZATION, key)
            .header(reqwest::header::ACCEPT_LANGUAGE, "en-US,en"),
        // An API key goes in `x-api-key`; `Authorization: Bearer` is for OAuth tokens.
        ModelProvider::Anthropic => request
            .header("x-api-key", key)
            .header("anthropic-version", ANTHROPIC_VERSION),
        _ => request.bearer_auth(key),
    };
    let response = match request.send().await {
        Ok(response) => response,
        // The request carries the key; report only what went wrong.
        Err(error) => {
            let host = provider.display_name();
            return unverified(if error.is_timeout() {
                format!("{host} did not answer in time")
            } else {
                format!("could not reach {host}")
            });
        }
    };
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED {
        return rejected(provider);
    }
    if !status.is_success() {
        return unverified(format!("unexpected reply (HTTP {})", status.as_u16()));
    }
    match provider {
        ModelProvider::Glm | ModelProvider::GlmCn => {
            /// The usage report answers HTTP 200 either way and says which in the body.
            #[derive(Deserialize)]
            struct Report {
                #[serde(default)]
                success: bool,
                #[serde(default)]
                code: Option<i64>,
            }
            match response.json::<Report>().await {
                Ok(Report { success: true, .. }) => KeyCheck::Accepted,
                // 1000-1004 are the service's authentication failures.
                Ok(Report {
                    code: Some(1000..=1004),
                    ..
                }) => rejected(provider),
                Ok(Report { code, .. }) => unverified(match code {
                    Some(code) => format!("unexpected reply (code {code})"),
                    None => "unexpected reply".to_owned(),
                }),
                Err(_) => unverified("unexpected reply".to_owned()),
            }
        }
        _ => KeyCheck::Accepted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn deepseek_key_is_checked_as_a_bearer_and_judged_by_status() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/models"))
            .and(header("authorization", "Bearer sk-good"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": []})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/models"))
            .respond_with(ResponseTemplate::new(401).set_body_json(serde_json::json!({
                "error": {"message": "Authentication Fails, Your api key: ****-bad is invalid"}
            })))
            .mount(&server)
            .await;
        let url = format!("{}/models", server.uri());
        assert_eq!(
            check_at(ModelProvider::DeepSeek, "sk-good", &url).await,
            KeyCheck::Accepted
        );
        let KeyCheck::Rejected(why) = check_at(ModelProvider::DeepSeek, "sk-bad", &url).await
        else {
            panic!("a 401 must refuse the key");
        };
        assert!(why.contains("DeepSeek"));
        assert!(!why.contains("sk-bad"));
    }

    #[tokio::test]
    async fn glm_key_is_sent_bare_and_judged_by_the_report_body() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(header("authorization", "good.key"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "code": 200, "msg": "Operation successful", "success": true, "data": {"limits": []}
            })))
            .mount(&server)
            .await;
        // What both sites answer for an unknown key: HTTP 200 with the refusal in the body.
        Mock::given(method("GET"))
            .and(header("authorization", "bad.key"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "code": 1000, "msg": "Authentication Failed", "success": false
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(header("authorization", "odd.key"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "code": 500, "msg": "Internal error", "success": false
            })))
            .mount(&server)
            .await;
        let url = server.uri();
        assert_eq!(
            check_at(ModelProvider::Glm, "good.key", &url).await,
            KeyCheck::Accepted
        );
        // Each site points at the other, the likeliest reason for a refusal.
        let KeyCheck::Rejected(why) = check_at(ModelProvider::Glm, "bad.key", &url).await else {
            panic!("an authentication code must refuse the key");
        };
        assert!(why.contains("crok login glm-cn") && !why.contains("bad.key"));
        let KeyCheck::Rejected(why) = check_at(ModelProvider::GlmCn, "bad.key", &url).await else {
            panic!("an authentication code must refuse the key");
        };
        assert!(why.contains("(crok login glm)"));
        // Anything else is no verdict, so a working key is never turned away by a service fault.
        assert!(matches!(
            check_at(ModelProvider::Glm, "odd.key", &url).await,
            KeyCheck::Unverified(_)
        ));
    }

    #[tokio::test]
    async fn anthropic_key_goes_in_x_api_key_with_the_api_version() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1/models"))
            .and(header("x-api-key", "sk-ant-api03-good"))
            .and(header("anthropic-version", "2023-06-01"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": []})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/v1/models"))
            .respond_with(ResponseTemplate::new(401).set_body_json(serde_json::json!({
                "type": "error",
                "error": {"type": "authentication_error", "message": "invalid x-api-key"}
            })))
            .mount(&server)
            .await;
        let url = format!("{}/v1/models?limit=1", server.uri());
        assert_eq!(
            check_at(ModelProvider::Anthropic, "sk-ant-api03-good", &url).await,
            KeyCheck::Accepted
        );
        let KeyCheck::Rejected(why) =
            check_at(ModelProvider::Anthropic, "sk-ant-api03-bad", &url).await
        else {
            panic!("a 401 must refuse the key");
        };
        assert!(why.contains("Anthropic") && !why.contains("sk-ant-api03-bad"));
    }

    #[tokio::test]
    async fn anthropic_credentials_that_cannot_send_messages_are_named_without_a_request() {
        let KeyCheck::Rejected(why) =
            check_provider_api_key(ModelProvider::Anthropic, " sk-ant-admin01-secret ").await
        else {
            panic!("an Admin API key cannot send messages");
        };
        assert!(why.contains("Admin API key") && !why.contains("secret"));
        let KeyCheck::Rejected(why) =
            check_provider_api_key(ModelProvider::Anthropic, "sk-ant-oat01-secret").await
        else {
            panic!("a subscription token is not an API key");
        };
        assert!(why.contains("subscription") && !why.contains("secret"));
        assert!(anthropic_wrong_kind_of_key("sk-ant-api03-anything").is_none());
    }

    #[tokio::test]
    async fn an_unreachable_provider_gives_no_verdict_and_does_not_echo_the_key() {
        let check = check_at(
            ModelProvider::DeepSeek,
            "sk-secret-key",
            "http://127.0.0.1:1/models",
        )
        .await;
        let KeyCheck::Unverified(why) = check else {
            panic!("no answer is no verdict");
        };
        assert!(!why.contains("sk-secret-key"));
        assert_eq!(
            check_provider_api_key(ModelProvider::OpenRouter, "anything").await,
            KeyCheck::Accepted
        );
    }
}
