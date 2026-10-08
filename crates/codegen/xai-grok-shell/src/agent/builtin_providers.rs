//! Locally authenticated providers, kept separate from the xAI remote catalog.

use std::num::NonZeroU64;
use std::path::PathBuf;

use indexmap::IndexMap;
use xai_grok_login::AuthProviderRef;
use xai_grok_login::provider_auth::{ModelProvider, has_provider_credential};
use xai_grok_models::deepseek::{self, DeepSeekModel};
use xai_grok_models::glm;
use xai_grok_models::openrouter::{self, OpenRouterModel};
use xai_grok_sampling_types::{ApiBackend, ReasoningEffort, ReasoningEffortOption};

use super::config::{Config, ModelEntry, ModelInfo};
use super::model_providers::ModelProviderConfig;

pub use xai_grok_models::deepseek::DEEPSEEK_BASE_URL;
pub use xai_grok_models::glm::{GLM_BASE_URL, GLM_CN_BASE_URL};
pub use xai_grok_models::openrouter::OPENROUTER_BASE_URL;
pub const CODEX_BASE_URL: &str = "https://chatgpt.com/backend-api/codex";

/// Shown wherever a sign-in is needed. xAI account sign-in is not supported, so a provider
/// sign-in (or a `[model.*]` entry with its own key, or `XAI_API_KEY`) is the only route.
pub const PROVIDER_SIGN_IN_REQUIRED: &str = "No model provider is signed in. Quit and run \
`crok login openai-codex`, `crok login openrouter`, `crok login deepseek` or `crok login glm` \
(or set OPENROUTER_API_KEY, DEEPSEEK_API_KEY or ZAI_API_KEY), then start Crok again.";

/// Offer provider setup only when no explicit model choice or usable credential applies.
pub fn needs_provider_setup(cfg: &Config) -> bool {
    if cfg.default_model_override.is_some()
        || cfg.models.default.is_some()
        || std::env::var("GROK_DEFAULT_MODEL").is_ok()
    {
        return false;
    }
    let models = super::config::resolve_model_list(cfg, None);
    !super::auth_method::should_advertise_xai_api_key(false, models.values())
}

/// Keep only the non-interactive `xai.api_key` method, which carries provider, `[model.*]`,
/// and `XAI_API_KEY` credentials; the xAI account methods (`cached_token`, `grok.com`,
/// `oidc`) are never advertised. With no credential the list is empty and the client
/// shows [`PROVIDER_SIGN_IN_REQUIRED`].
pub(crate) fn provider_auth_methods(
    built: super::auth_method::BuiltAuthMethods,
) -> super::auth_method::BuiltAuthMethods {
    use super::auth_method::{AuthMethodKind, BuiltAuthMethods, XAI_API_KEY_METHOD_ID};
    let methods: Vec<_> = built
        .methods
        .into_iter()
        .filter(|m| AuthMethodKind::from_id(m.id()).is_api_key())
        .collect();
    let default_auth_method_id = (!methods.is_empty())
        .then(|| agent_client_protocol::AuthMethodId::new(XAI_API_KEY_METHOD_ID));
    BuiltAuthMethods {
        methods,
        default_auth_method_id,
    }
}

pub fn openrouter_cache_path() -> PathBuf {
    xai_grok_config::grok_home().join("openrouter-models.json")
}

pub fn deepseek_cache_path() -> PathBuf {
    xai_grok_config::grok_home().join("deepseek-models.json")
}

pub(crate) fn provider_from_id(id: &str) -> Option<ModelProvider> {
    ModelProvider::from_id(id)
}

/// The provider's own endpoint and the wire format spoken there. Its credential goes nowhere else.
fn route(provider: ModelProvider) -> (&'static str, ApiBackend) {
    match provider {
        ModelProvider::OpenRouter => (OPENROUTER_BASE_URL, ApiBackend::OpenRouter),
        ModelProvider::OpenAiCodex => (CODEX_BASE_URL, ApiBackend::OpenAiCodex),
        ModelProvider::DeepSeek => (DEEPSEEK_BASE_URL, ApiBackend::DeepSeek),
        ModelProvider::Glm => (GLM_BASE_URL, ApiBackend::Glm),
        ModelProvider::GlmCn => (GLM_CN_BASE_URL, ApiBackend::Glm),
    }
}

pub(crate) fn provider_defaults(id: &str) -> Option<ModelProviderConfig> {
    let (base_url, api_backend) = route(provider_from_id(id)?);
    Some(ModelProviderConfig {
        base_url: Some(base_url.into()),
        api_backend: Some(api_backend),
        ..Default::default()
    })
}

/// Provider configuration may supply just a key, headers, or context override;
/// retain the built-in endpoint and wire protocol for any unspecified fields.
pub(crate) fn resolved_provider_defaults(cfg: &Config, id: &str) -> Option<ModelProviderConfig> {
    let defaults = provider_defaults(id)?;
    let mut configured = cfg.model_providers.get(id).cloned().unwrap_or_default();
    configured.base_url = configured.base_url.or(defaults.base_url);
    configured.api_backend = configured.api_backend.or(defaults.api_backend);
    Some(configured)
}

pub(crate) fn enabled(cfg: &Config, provider: ModelProvider) -> bool {
    let id = provider.as_str();
    let prefix = format!("{id}/");
    has_provider_credential(&xai_grok_config::grok_home(), provider)
        || cfg.model_providers.contains_key(id)
        || cfg.config_models.iter().any(|(key, model)| {
            key.starts_with(&prefix) || model.model_provider.as_deref() == Some(id)
        })
        || cfg
            .default_model_override
            .as_deref()
            .is_some_and(|m| m.starts_with(&prefix))
        || cfg
            .models
            .default
            .as_deref()
            .is_some_and(|m| m.starts_with(&prefix))
        || std::env::var("GROK_DEFAULT_MODEL").is_ok_and(|m| m.starts_with(&prefix))
}

/// Refreshing is public for `grok models --refresh`; routine starts honor the TTL.
pub async fn refresh_openrouter_models(cfg: &Config, force: bool) -> anyhow::Result<usize> {
    if !enabled(cfg, ModelProvider::OpenRouter) && !force {
        return Ok(0);
    }
    let models = openrouter::refresh_models(
        &xai_grok_http::shared_client(),
        &openrouter_cache_path(),
        force,
    )
    .await?;
    Ok(models.len())
}

/// Fetch DeepSeek's model list with the signed-in key. Public for `crok login deepseek` and
/// `crok models --refresh`; routine starts honor the TTL. Without a key there is nothing to ask with.
pub async fn refresh_deepseek_models(cfg: &Config, force: bool) -> anyhow::Result<usize> {
    if !enabled(cfg, ModelProvider::DeepSeek) && !force {
        return Ok(0);
    }
    let home = xai_grok_config::grok_home();
    let Some(credential) =
        xai_grok_login::provider_auth::read_provider_credential(&home, ModelProvider::DeepSeek)?
    else {
        return Ok(0);
    };
    let models = deepseek::refresh_models(
        &xai_grok_http::shared_client(),
        &deepseek_cache_path(),
        credential.access_token(),
        force,
    )
    .await?;
    Ok(models.len())
}

pub(crate) async fn warm_catalog(cfg: &Config) {
    if !crate::util::config::resolve_remote_fetch_enabled() {
        return;
    }
    let (openrouter, deepseek) = tokio::join!(
        refresh_openrouter_models(cfg, false),
        refresh_deepseek_models(cfg, false)
    );
    if let Err(error) = openrouter {
        tracing::warn!(%error, "OpenRouter model discovery failed; using cached models");
    }
    if let Err(error) = deepseek {
        tracing::warn!(%error, "DeepSeek model discovery failed; using cached models");
    }
}

pub(crate) fn warm_catalog_blocking(cfg: &Config) {
    if !(enabled(cfg, ModelProvider::OpenRouter) || enabled(cfg, ModelProvider::DeepSeek))
        || !crate::util::config::resolve_remote_fetch_enabled()
    {
        return;
    }
    let cfg = cfg.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    let _ = std::thread::Builder::new()
        .name("provider-models".into())
        .spawn(move || {
            if let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                runtime.block_on(warm_catalog(&cfg));
            }
            let _ = tx.send(());
        });
    let _ = rx.recv_timeout(std::time::Duration::from_secs(11));
}

pub(crate) fn cached_models() -> Vec<OpenRouterModel> {
    openrouter::read_cached_models(&openrouter_cache_path()).unwrap_or_default()
}

/// The account's own model list once fetched, and the built-in one until then.
pub(crate) fn deepseek_models() -> Vec<DeepSeekModel> {
    deepseek::read_cached_models(&deepseek_cache_path())
        .unwrap_or_else(|_| deepseek::builtin_models())
}

/// Whether tools apply to `model` on `backend`, where the provider's catalog says.
/// Only OpenRouter lists models without them.
pub(crate) fn tool_support(backend: &ApiBackend, model: &str) -> Option<bool> {
    (*backend == ApiBackend::OpenRouter)
        .then(|| {
            cached_models()
                .iter()
                .find(|entry| entry.id == model)
                .map(OpenRouterModel::supports_tools)
        })
        .flatten()
}

/// Whether `model` on `backend` reads images, where the provider's catalog says.
/// The sampler leaves images out of requests to a model that does not.
pub(crate) fn image_support(backend: &ApiBackend, model: &str) -> Option<bool> {
    match backend {
        ApiBackend::DeepSeek => deepseek_models()
            .iter()
            .find(|entry| entry.id == model)
            .and_then(DeepSeekModel::supports_images),
        ApiBackend::Glm => glm::model(model).map(|entry| entry.supports_images),
        ApiBackend::ChatCompletions
        | ApiBackend::Responses
        | ApiBackend::OpenRouter
        | ApiBackend::OpenAiCodex
        | ApiBackend::Messages => None,
    }
}

fn entry(provider: ModelProvider, id: &str, slug: &str, name: &str, context: u64) -> ModelEntry {
    let (base_url, backend) = route(provider);
    ModelEntry {
        info: ModelInfo {
            id: Some(id.into()),
            model: slug.into(),
            name: Some(name.into()),
            base_url: base_url.into(),
            api_backend: backend,
            context_window: NonZeroU64::new(context.max(1)).unwrap(),
            ..Default::default()
        },
        mtls_cert_dir: None,
        api_key: None,
        env_key: None,
        auth_provider: Some(AuthProviderRef::builtin(provider)),
        api_base_url: None,
    }
}

pub(crate) fn openrouter_entry(model: &OpenRouterModel) -> ModelEntry {
    let context = model
        .context_length
        .filter(|n| *n > 0)
        .or(model.top_provider.context_length.filter(|n| *n > 0))
        .unwrap_or(200_000);
    let mut entry = entry(
        ModelProvider::OpenRouter,
        &model.catalog_id(),
        &model.id,
        &model.name,
        context,
    );
    entry.info.description = model.description.clone();
    entry.info.model_family = model.id.split('/').next().map(str::to_owned);
    entry.info.supports_reasoning_effort = model.supports_reasoning();
    let mut efforts: Vec<ReasoningEffortOption> = model
        .reasoning
        .supported_efforts
        .iter()
        .filter_map(|effort| serde_json::from_value(serde_json::Value::String(effort.clone())).ok())
        .collect();
    let declared_default = model
        .reasoning
        .default_effort
        .as_deref()
        .and_then(|effort| effort.parse::<ReasoningEffort>().ok());
    if !efforts.is_empty() {
        let default_effort = declared_default
            .filter(|default| efforts.iter().any(|e| e.value == *default))
            .or_else(|| efforts.first().map(|e| e.value));
        for effort in &mut efforts {
            effort.default = Some(effort.value) == default_effort;
        }
        entry.info.supports_reasoning_effort = true;
        entry.info.reasoning_effort = default_effort;
        entry.info.reasoning_efforts = efforts;
    } else if model.reasoning.supported_efforts.is_empty() && model.supports_reasoning() {
        // Older catalog responses may not enumerate efforts. Keep their
        // explicit default, but do not invent an effort the provider disallows.
        entry.info.reasoning_effort = declared_default;
    } else if !model.reasoning.supported_efforts.is_empty() {
        // New effort names do not invalidate the model; leave reasoning at the
        // service default until the client understands those effort values.
        entry.info.supports_reasoning_effort = false;
    }
    entry.info.max_completion_tokens = model
        .top_provider
        .max_completion_tokens
        .filter(|n| *n > 0)
        .and_then(|n| u32::try_from(n).ok());
    entry
}

/// A provider's effort menu: `levels` in its order, with `default` (or else the first) preselected.
fn set_efforts(
    entry: &mut ModelEntry,
    levels: &[ReasoningEffort],
    default: Option<ReasoningEffort>,
) {
    let default = default
        .filter(|level| levels.contains(level))
        .or(levels.first().copied());
    entry.info.supports_reasoning_effort = !levels.is_empty();
    entry.info.reasoning_effort = default;
    entry.info.reasoning_efforts = levels
        .iter()
        .map(|level| ReasoningEffortOption {
            id: <&'static str>::from(*level).to_owned(),
            value: *level,
            label: xai_grok_sampling_types::effort_label(*level),
            description: None,
            default: Some(*level) == default,
        })
        .collect();
}

pub(crate) fn deepseek_entry(model: &DeepSeekModel) -> ModelEntry {
    let mut entry = entry(
        ModelProvider::DeepSeek,
        &model.catalog_id(),
        &model.id,
        &model.name,
        model.context_window(),
    );
    entry.info.model_family = Some("deepseek".into());
    // The output limit is left to the service (64K while thinking): its 384K ceiling is a cap, not a default.
    let listed: Vec<ReasoningEffort> = model
        .effort
        .supported_levels
        .iter()
        .filter_map(|level| level.parse().ok())
        .collect();
    if !listed.is_empty() {
        let default = model
            .effort
            .default_level
            .as_deref()
            .and_then(|level| level.parse().ok())
            .or(listed.first().copied());
        // `none` turns thinking off; DeepSeek lists only the levels that keep it on.
        let levels: Vec<_> = std::iter::once(ReasoningEffort::None)
            .chain(listed)
            .collect();
        set_efforts(&mut entry, &levels, default);
    }
    entry
}

/// The plan's models reason at `low`, `high` or `max` and cannot be told not to.
fn glm_entry(provider: ModelProvider, model: &glm::GlmModel) -> ModelEntry {
    let id = format!("{provider}/{}", model.id);
    let mut entry = entry(provider, &id, model.id, model.name, model.context_window);
    entry.info.model_family = Some("glm".into());
    entry.info.max_completion_tokens = Some(model.max_output_tokens);
    set_efforts(
        &mut entry,
        &[
            ReasoningEffort::Low,
            ReasoningEffort::High,
            ReasoningEffort::Max,
        ],
        Some(ReasoningEffort::Max),
    );
    entry
}

pub(crate) fn extend_catalog(cfg: &Config, catalog: &mut IndexMap<String, ModelEntry>) {
    extend_catalog_with_models(cfg, catalog, cached_models);
    hide_xai_hosted_models(catalog);
}

/// The built-in and remote catalog entries are served by xAI. Without `XAI_API_KEY` they
/// could only authenticate through an xAI account, which is not supported, so once a
/// provider catalog is active they stay resolvable by id but leave the picker and the
/// default. Grok models remain available through OpenRouter (`openrouter/x-ai/...`).
fn hide_xai_hosted_models(catalog: &mut IndexMap<String, ModelEntry>) {
    let has_provider = catalog.values().any(|entry| {
        entry
            .auth_provider
            .as_ref()
            .is_some_and(|provider| provider.builtin_provider().is_some())
    });
    if !has_provider || super::auth_method::has_xai_api_key_env() {
        return;
    }
    for entry in catalog.values_mut() {
        // `hidden`, not `user_selectable`: the allowlist pass rewrites selectability later.
        if !entry.has_own_credentials() {
            entry.info.hidden = true;
        }
    }
}

fn extend_catalog_with_models(
    cfg: &Config,
    catalog: &mut IndexMap<String, ModelEntry>,
    load_models: impl FnOnce() -> Vec<OpenRouterModel>,
) {
    if enabled(cfg, ModelProvider::OpenRouter) {
        for model in load_models() {
            catalog.insert(model.catalog_id(), openrouter_entry(&model));
        }
        // This routing alias also works before the first successful discovery.
        catalog
            .entry("openrouter/openrouter/auto".into())
            .or_insert_with(|| {
                entry(
                    ModelProvider::OpenRouter,
                    "openrouter/openrouter/auto",
                    "openrouter/auto",
                    "OpenRouter Auto",
                    200_000,
                )
            });
    }
    if enabled(cfg, ModelProvider::OpenAiCodex) {
        // Pi's subscription catalog. Explicit provider config accepts further slugs.
        for (slug, name, context) in [
            ("gpt-6-astra", "GPT-6 Astra", 272_000),
            ("gpt-5.6-sol", "GPT-5.6 Sol", 272_000),
            ("gpt-5.6-terra", "GPT-5.6 Terra", 272_000),
            ("gpt-5.6-luna", "GPT-5.6 Luna", 272_000),
            ("gpt-5.5", "GPT-5.5", 272_000),
            ("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", 128_000),
        ] {
            let id = format!("openai-codex/{slug}");
            let mut model = entry(ModelProvider::OpenAiCodex, &id, slug, name, context);
            model.info.model_family = Some("openai".into());
            model.info.supports_reasoning_effort = true;
            model.info.reasoning_effort = Some(ReasoningEffort::Medium);
            catalog.insert(id, model);
        }
    }
    if enabled(cfg, ModelProvider::DeepSeek) {
        for model in deepseek_models() {
            catalog.insert(model.catalog_id(), deepseek_entry(&model));
        }
    }
    for provider in [ModelProvider::Glm, ModelProvider::GlmCn] {
        if enabled(cfg, provider) {
            for model in &glm::MODELS {
                let entry = glm_entry(provider, model);
                catalog.insert(format!("{provider}/{}", model.id), entry);
            }
        }
    }
    // Allow explicit provider-prefixed slugs even before discovery catches up.
    for id in cfg
        .default_model_override
        .iter()
        .chain(cfg.models.default.iter())
        .chain(cfg.config_models.keys())
        .cloned()
        .chain(std::env::var("GROK_DEFAULT_MODEL").ok())
    {
        if let Some((provider_id, slug)) = id.split_once('/')
            && let Some(provider) = provider_from_id(provider_id)
            && !slug.is_empty()
        {
            catalog
                .entry(id.clone())
                .or_insert_with(|| entry(provider, &id, slug, slug, 200_000));
        }
    }
    // Provider-level credentials and connection settings apply to discovered models too.
    for (id, model) in catalog.iter_mut() {
        let Some((provider_id, _)) = id.split_once('/') else {
            continue;
        };
        if !cfg.model_providers.contains_key(provider_id) {
            continue;
        }
        let Some(provider) = resolved_provider_defaults(cfg, provider_id) else {
            continue;
        };
        let overrides = super::config::ConfigModelOverride::default()
            .with_provider_defaults(&provider, provider_id);
        *model = overrides.apply(id, Some(model.clone()), &cfg.endpoints);
    }
}

/// Attach credentials only to the provider's canonical HTTPS endpoint. Model URL
/// overrides must never redirect a subscription token or stored API key.
pub(crate) fn matches_auth_route(
    provider: ModelProvider,
    base_url: &str,
    api_backend: ApiBackend,
) -> bool {
    let (expected_url, expected_backend) = route(provider);
    base_url.trim_end_matches('/') == expected_url && api_backend == expected_backend
}

pub(crate) fn attach_auth(model: &mut ModelEntry, provider: ModelProvider) {
    if !matches_auth_route(
        provider,
        &model.info.base_url,
        model.info.api_backend.clone(),
    ) || model.api_base_url.is_some()
    {
        if model
            .auth_provider
            .as_ref()
            .is_some_and(|p| p.builtin_provider().is_some())
        {
            model.auth_provider = Some(AuthProviderRef::fail_closed(
                "provider endpoint override".into(),
            ));
        }
        return;
    }
    if model.auth_provider.is_none()
        || model
            .auth_provider
            .as_ref()
            .is_some_and(|p| p.builtin_provider().is_some())
    {
        model.auth_provider = Some(AuthProviderRef::builtin(provider));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::config::{resolve_credentials, resolve_model_list};
    use crate::agent::remote_config::resolve_default_model;
    use serial_test::serial;
    use xai_grok_test_support::EnvGuard;

    fn config(source: &str) -> Config {
        Config::new_from_toml_cfg(&toml::from_str(source).unwrap()).unwrap()
    }

    fn discovered_model(id: &str) -> OpenRouterModel {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": "Newly released chat model", "context_length": 65536,
            "description": "Discovered dynamically", "supported_parameters": [],
            "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}
        }))
        .unwrap()
    }

    fn isolate_default_env() -> [EnvGuard; 4] {
        [
            EnvGuard::unset("XAI_API_KEY"),
            EnvGuard::unset("GROK_CODE_XAI_API_KEY"),
            EnvGuard::unset("GROK_DEFAULT_MODEL"),
            EnvGuard::unset("GROK_DEPLOYMENT_KEY"),
        ]
    }

    fn provider_only_catalog(cfg: &Config) -> IndexMap<String, ModelEntry> {
        let mut catalog = IndexMap::new();
        let native = xai_grok_models::default_model();
        catalog.insert(native.into(), ModelEntry::fallback(native, &cfg.endpoints));
        let mut router = entry(
            ModelProvider::OpenRouter,
            "openrouter/openrouter/auto",
            "openrouter/auto",
            "OpenRouter Auto",
            200_000,
        );
        router.api_key = Some("sk-openrouter-fixture".into());
        catalog.insert("openrouter/openrouter/auto".into(), router);
        catalog
    }

    #[test]
    #[serial]
    fn first_run_setup_respects_credentials_and_model_choice() {
        let _env = isolate_default_env();
        let home = tempfile::tempdir().unwrap();
        let _home = EnvGuard::set("GROK_HOME", home.path().to_str().unwrap());
        let _router = EnvGuard::unset("OPENROUTER_API_KEY");
        assert!(needs_provider_setup(&config("")));
        {
            let _key = EnvGuard::set("OPENROUTER_API_KEY", "fixture");
            assert!(!needs_provider_setup(&config("")));
        }
        // xAI account policy no longer stands in for a provider: setup still runs.
        let mut cfg = config("");
        cfg.grok_com_config.disable_api_key_auth = Some(true);
        assert!(needs_provider_setup(&cfg));
        cfg.grok_com_config.disable_api_key_auth = None;
        cfg.models.default = Some("explicit-model".into());
        assert!(!needs_provider_setup(&cfg));
    }

    #[test]
    fn provider_auth_methods_never_advertise_xai_account_sign_in() {
        use crate::agent::auth_method::{
            AuthMethodsBuildInputs, CACHED_TOKEN_AUTH_METHOD_ID, XAI_API_KEY_METHOD_ID,
            build_auth_methods,
        };
        let build = |has_external_api_key| {
            provider_auth_methods(build_auth_methods(AuthMethodsBuildInputs {
                has_external_api_key,
                has_cached_token: true,
                has_enterprise_oidc: false,
                enterprise_oidc_issuer: None,
                login_label: None,
                has_auth_provider_command: false,
                preferred_method: None,
            }))
        };
        let with_key = build(true);
        let ids: Vec<_> = with_key
            .methods
            .iter()
            .map(|m| m.id().0.to_string())
            .collect();
        assert_eq!(ids, [XAI_API_KEY_METHOD_ID]);
        assert_eq!(
            with_key
                .default_auth_method_id
                .map(|id| id.0.to_string())
                .as_deref(),
            Some(XAI_API_KEY_METHOD_ID),
            "a cached xAI session must not become the default: {CACHED_TOKEN_AUTH_METHOD_ID}"
        );
        let without_key = build(false);
        assert!(
            without_key.methods.is_empty(),
            "no grok.com / cached_token fallback"
        );
        assert!(without_key.default_auth_method_id.is_none());
    }

    #[test]
    #[serial]
    fn xai_hosted_models_leave_the_picker_without_an_xai_api_key() {
        let _env = isolate_default_env();
        let cfg = config("");
        let native = xai_grok_models::default_model();
        let native_only = || {
            let mut catalog = IndexMap::new();
            catalog.insert(
                native.to_string(),
                ModelEntry::fallback(native, &cfg.endpoints),
            );
            let mut byok = ModelEntry::fallback("custom", &cfg.endpoints);
            byok.api_key = Some("fixture".into());
            catalog.insert("custom".into(), byok);
            catalog
        };
        let mut catalog = native_only();
        hide_xai_hosted_models(&mut catalog);
        assert!(
            !catalog[native].info.hidden,
            "no provider catalog: nothing changes"
        );

        let mut catalog = provider_only_catalog(&cfg);
        let mut byok = ModelEntry::fallback("custom", &cfg.endpoints);
        byok.api_key = Some("fixture".into());
        catalog.insert("custom".into(), byok);
        hide_xai_hosted_models(&mut catalog);
        assert!(catalog[native].info.hidden);
        assert!(
            !catalog["custom"].info.hidden,
            "own-key models stay pickable"
        );
        assert!(!catalog["openrouter/openrouter/auto"].info.hidden);

        let _set = EnvGuard::set("XAI_API_KEY", "xai-fixture");
        let mut catalog = provider_only_catalog(&cfg);
        hide_xai_hosted_models(&mut catalog);
        assert!(
            !catalog[native].info.hidden,
            "XAI_API_KEY keeps native models usable"
        );
    }

    #[test]
    #[serial]
    fn provider_only_startup_selects_an_authenticated_provider_without_xai_login() {
        let _env = isolate_default_env();
        let cfg = config("");
        let catalog = provider_only_catalog(&cfg);
        let (id, _, source) = resolve_default_model(&cfg, &catalog, false);
        assert_eq!(id, "openrouter/openrouter/auto");
        assert_eq!(source, super::super::config::ConfigSource::Default);

        // Built-in OAuth references are BYOK even while their expired token is
        // awaiting its pre-turn refresh; startup must not demand an xAI login.
        let oauth = entry(
            ModelProvider::OpenAiCodex,
            "openai-codex/gpt-5.5",
            "gpt-5.5",
            "Codex",
            272_000,
        );
        assert!(crate::agent::auth_method::should_advertise_xai_api_key(
            false,
            [&oauth]
        ));
    }

    #[test]
    #[serial]
    fn explicit_xai_model_preferences_are_not_replaced_by_provider_default() {
        let _env = isolate_default_env();
        let native = xai_grok_models::default_model();
        let mut cfg = config("");
        let catalog = provider_only_catalog(&cfg);

        cfg.default_model_override = Some(native.into());
        assert_eq!(resolve_default_model(&cfg, &catalog, false).0, native);
        cfg.default_model_override = None;
        cfg.models.default = Some(native.into());
        assert_eq!(resolve_default_model(&cfg, &catalog, false).0, native);
        cfg.models.default = None;
        let _explicit_env = EnvGuard::set("GROK_DEFAULT_MODEL", native);
        assert_eq!(resolve_default_model(&cfg, &catalog, false).0, native);
    }

    #[test]
    #[serial]
    fn existing_xai_credentials_preserve_the_native_default() {
        let _env = isolate_default_env();
        let mut cfg = config("");
        let catalog = provider_only_catalog(&cfg);
        let native = xai_grok_models::default_model();
        assert_eq!(resolve_default_model(&cfg, &catalog, true).0, native);
        {
            let _key = EnvGuard::set("XAI_API_KEY", "xai-fixture");
            assert_eq!(resolve_default_model(&cfg, &catalog, false).0, native);
        }
        cfg.endpoints.deployment_key = Some("deployment-fixture".into());
        assert_eq!(resolve_default_model(&cfg, &catalog, false).0, native);
    }

    #[test]
    fn discovery_keeps_native_models_and_adds_models_without_tools() {
        let cfg = config("[model_providers.openrouter]\n[model_providers.openai-codex]");
        let mut catalog = IndexMap::new();
        catalog.insert(
            "native-model".into(),
            ModelEntry::fallback("native-model", &cfg.endpoints),
        );
        extend_catalog_with_models(&cfg, &mut catalog, || {
            vec![discovered_model("fixture/new-model")]
        });

        assert!(catalog.contains_key("native-model"));
        assert!(catalog.contains_key("openai-codex/gpt-5.5"));
        assert!(catalog.contains_key("openrouter/openrouter/auto"));
        let discovered = catalog.get("openrouter/fixture/new-model").unwrap();
        assert_eq!(discovered.info.model, "fixture/new-model");
        assert_eq!(discovered.info.base_url, OPENROUTER_BASE_URL);
        assert_eq!(discovered.info.api_backend, ApiBackend::OpenRouter);
        assert_eq!(discovered.info.context_window.get(), 65536);
        assert_eq!(
            discovered
                .auth_provider
                .as_ref()
                .unwrap()
                .builtin_provider(),
            Some(ModelProvider::OpenRouter)
        );

        // A later snapshot can introduce arbitrary provider/model slugs without
        // adding a constant or changing configuration.
        extend_catalog_with_models(&cfg, &mut catalog, || {
            vec![
                discovered_model("fixture/new-model"),
                discovered_model("brand-new-provider/next-release"),
            ]
        });
        assert_eq!(
            catalog
                .get("openrouter/brand-new-provider/next-release")
                .unwrap()
                .info
                .model,
            "brand-new-provider/next-release"
        );
    }

    #[test]
    fn positive_context_fallback_and_catalog_reasoning_options_are_preserved() {
        let model: OpenRouterModel = serde_json::from_value(serde_json::json!({
            "id": "fixture/reasoner", "context_length": 0,
            "top_provider": {"context_length": 32768, "max_completion_tokens": 4096},
            "supported_parameters": ["reasoning"],
            "reasoning": {"supported_efforts": ["xhigh", "medium", "future-effort"], "default_effort": "xhigh"}
        })).unwrap();
        let entry = openrouter_entry(&model);
        assert_eq!(entry.info.context_window.get(), 32768);
        assert_eq!(entry.info.max_completion_tokens, Some(4096));
        assert_eq!(entry.info.reasoning_effort, Some(ReasoningEffort::Xhigh));
        assert!(entry.info.supports_reasoning_effort);
        assert_eq!(
            entry
                .info
                .reasoning_efforts
                .iter()
                .map(|e| e.value)
                .collect::<Vec<_>>(),
            vec![ReasoningEffort::Xhigh, ReasoningEffort::Medium]
        );
        assert_eq!(
            entry
                .info
                .reasoning_efforts
                .iter()
                .filter(|e| e.default)
                .count(),
            1
        );

        let unknown: OpenRouterModel = serde_json::from_value(serde_json::json!({
            "id": "fixture/future-reasoner", "context_length": 0,
            "supported_parameters": ["reasoning"],
            "reasoning": {"supported_efforts": ["future-effort"], "default_effort": "future-effort"}
        }))
        .unwrap();
        let unknown = openrouter_entry(&unknown);
        assert_eq!(unknown.info.context_window.get(), 200_000);
        assert!(!unknown.info.supports_reasoning_effort);
        assert_eq!(unknown.info.reasoning_effort, None);
    }

    #[test]
    fn prefixed_models_route_without_a_cached_catalog_entry() {
        let cfg = config(
            r#"
            [models]
            default = "openrouter/fixture-provider/next-default"

            [model."openrouter/fixture-provider/next-configured"]
            name = "Configured before discovery"

            [model."openai-codex/next-codex-model"]
            name = "Future subscription model"

            [model."deepseek/deepseek-v5"]
            [model."glm/glm-6"]
            [model."glm-cn/glm-6"]
        "#,
        );
        let catalog = resolve_model_list(&cfg, None);
        for (id, slug, base_url, backend, provider) in [
            (
                "openrouter/fixture-provider/next-default",
                "fixture-provider/next-default",
                OPENROUTER_BASE_URL,
                ApiBackend::OpenRouter,
                ModelProvider::OpenRouter,
            ),
            (
                "openrouter/fixture-provider/next-configured",
                "fixture-provider/next-configured",
                OPENROUTER_BASE_URL,
                ApiBackend::OpenRouter,
                ModelProvider::OpenRouter,
            ),
            (
                "openai-codex/next-codex-model",
                "next-codex-model",
                CODEX_BASE_URL,
                ApiBackend::OpenAiCodex,
                ModelProvider::OpenAiCodex,
            ),
            (
                "deepseek/deepseek-v5",
                "deepseek-v5",
                DEEPSEEK_BASE_URL,
                ApiBackend::DeepSeek,
                ModelProvider::DeepSeek,
            ),
            (
                "glm/glm-6",
                "glm-6",
                GLM_BASE_URL,
                ApiBackend::Glm,
                ModelProvider::Glm,
            ),
            (
                "glm-cn/glm-6",
                "glm-6",
                GLM_CN_BASE_URL,
                ApiBackend::Glm,
                ModelProvider::GlmCn,
            ),
        ] {
            let model = catalog.get(id).unwrap();
            assert_eq!(model.info.model, slug);
            assert_eq!(model.info.base_url, base_url);
            assert_eq!(model.info.api_backend, backend);
            assert_eq!(
                model.auth_provider.as_ref().unwrap().builtin_provider(),
                Some(provider)
            );
        }
    }

    #[test]
    fn provider_keys_keep_builtin_connection_defaults_for_aliases() {
        let cfg = config(
            r#"
            [model_providers.openrouter]
            api_key = "sk-provider-fixture"
            context_window = 123456

            [model.alias]
            model = "fixture/chat"
            model_provider = "openrouter"
        "#,
        );
        let catalog = resolve_model_list(&cfg, None);
        let model = catalog.get("alias").unwrap();
        assert_eq!(model.info.base_url, OPENROUTER_BASE_URL);
        assert_eq!(model.info.api_backend, ApiBackend::OpenRouter);
        assert_eq!(model.info.context_window.get(), 123456);
        assert_eq!(
            resolve_credentials(model, Some("xai-session-fixture"))
                .api_key
                .as_deref(),
            Some("sk-provider-fixture")
        );
    }

    #[test]
    fn model_config_overrides_discovery_and_provider_defaults() {
        let cfg = config(
            r#"
            [model_providers.openrouter]
            api_key = "sk-provider-fixture"
            context_window = 80000

            [model."openrouter/fixture-priority/new-model"]
            name = "My name"
            context_window = 96000
            api_key = "sk-model-fixture"
        "#,
        );
        let mut discovered = IndexMap::new();
        extend_catalog_with_models(&cfg, &mut discovered, || {
            vec![discovered_model("fixture-priority/new-model")]
        });
        let catalog = resolve_model_list(&cfg, Some(discovered));
        let model = catalog
            .get("openrouter/fixture-priority/new-model")
            .unwrap();
        assert_eq!(model.info.name.as_deref(), Some("My name"));
        assert_eq!(
            model.info.description.as_deref(),
            Some("Discovered dynamically")
        );
        assert_eq!(model.info.context_window.get(), 96000);
        assert_eq!(model.info.model, "fixture-priority/new-model");
        assert_eq!(
            resolve_credentials(model, Some("xai-session-fixture"))
                .api_key
                .as_deref(),
            Some("sk-model-fixture")
        );
    }

    #[test]
    fn shared_wire_slugs_resolve_credentials_only_for_the_active_route() {
        let mut catalog = IndexMap::new();
        catalog.insert(
            "openai-codex/gpt-5.5".into(),
            entry(
                ModelProvider::OpenAiCodex,
                "openai-codex/gpt-5.5",
                "gpt-5.5",
                "Codex",
                272_000,
            ),
        );
        let mut custom = entry(
            ModelProvider::OpenAiCodex,
            "custom",
            "gpt-5.5",
            "Custom",
            200_000,
        );
        custom.info.base_url = "https://proxy.example/v1".into();
        custom.info.api_backend = ApiBackend::Responses;
        custom.api_key = Some("custom-key".into());
        attach_auth(&mut custom, ModelProvider::OpenAiCodex);
        catalog.insert("custom".into(), custom);

        let resolved = crate::agent::config::find_model_by_route(
            &catalog,
            "gpt-5.5",
            "https://proxy.example/v1",
            ApiBackend::Responses,
        )
        .unwrap();
        assert_eq!(resolved.info.id.as_deref(), Some("custom"));
        assert_eq!(
            resolve_credentials(resolved, None).api_key.as_deref(),
            Some("custom-key")
        );
        assert!(
            crate::agent::config::find_model_by_route(
                &catalog,
                "gpt-5.5",
                "https://another.example/v1",
                ApiBackend::OpenAiCodex,
            )
            .is_none()
        );
        assert!(
            crate::agent::config::find_model_by_route(
                &catalog,
                "gpt-5.5",
                CODEX_BASE_URL,
                ApiBackend::ChatCompletions,
            )
            .is_none()
        );
        assert!(matches_auth_route(
            ModelProvider::OpenAiCodex,
            CODEX_BASE_URL,
            ApiBackend::OpenAiCodex
        ));
        assert!(!matches_auth_route(
            ModelProvider::OpenAiCodex,
            CODEX_BASE_URL,
            ApiBackend::OpenRouter
        ));
    }

    #[test]
    fn endpoint_overrides_cannot_reuse_builtin_or_xai_credentials() {
        for provider in ModelProvider::ALL {
            for override_kind in ["base_url", "api_base_url", "api_backend"] {
                let mut model = entry(provider, "fixture", "fixture", "Fixture", 200_000);
                match override_kind {
                    "api_base_url" => {
                        model.api_base_url = Some("https://untrusted.example/api".into())
                    }
                    "api_backend" => model.info.api_backend = ApiBackend::ChatCompletions,
                    _ => model.info.base_url = "https://untrusted.example/v1".into(),
                }
                attach_auth(&mut model, provider);
                let auth = model.auth_provider.as_ref().unwrap();
                assert!(auth.is_fail_closed());
                assert_eq!(auth.builtin_provider(), None);
                assert_eq!(
                    resolve_credentials(&model, Some("xai-session-fixture")).api_key,
                    None
                );
            }
        }

        let cfg = config(
            r#"
            [model_providers.openrouter]
            base_url = "https://untrusted.example/v1"

            [model."openrouter/fixture-provider/redirected"]
        "#,
        );
        let catalog = resolve_model_list(&cfg, None);
        let model = catalog
            .get("openrouter/fixture-provider/redirected")
            .unwrap();
        assert!(model.auth_provider.as_ref().unwrap().is_fail_closed());
        assert_eq!(
            resolve_credentials(model, Some("xai-session-fixture")).api_key,
            None
        );
    }

    // The home directory is fixed for the life of the test process, so these tests never
    // assume what is or is not signed in on the machine: a provider is switched on by its
    // config table or its environment key, and a default is chosen from a catalog built here.

    #[test]
    fn key_providers_join_the_catalog_on_their_own_routes() {
        let cfg =
            config("[model_providers.deepseek]\n[model_providers.glm]\n[model_providers.glm-cn]");
        let mut catalog = IndexMap::new();
        extend_catalog_with_models(&cfg, &mut catalog, Vec::new);
        for (provider, base_url, backend) in [
            (
                ModelProvider::DeepSeek,
                DEEPSEEK_BASE_URL,
                ApiBackend::DeepSeek,
            ),
            (ModelProvider::Glm, GLM_BASE_URL, ApiBackend::Glm),
            (ModelProvider::GlmCn, GLM_CN_BASE_URL, ApiBackend::Glm),
        ] {
            let prefix = format!("{provider}/");
            let models: Vec<_> = catalog
                .iter()
                .filter(|(id, _)| id.starts_with(&prefix))
                .collect();
            assert!(!models.is_empty(), "{provider} offers no models");
            for (id, model) in models {
                assert_eq!(Some(model.info.model.as_str()), id.strip_prefix(&prefix));
                assert_eq!(model.info.base_url, base_url, "{id}");
                assert_eq!(model.info.api_backend, backend, "{id}");
                assert_eq!(
                    model.auth_provider.as_ref().unwrap().builtin_provider(),
                    Some(provider),
                    "{id}"
                );
                assert!(!model.info.hidden, "{id}");
            }
        }
        for id in [
            "glm/glm-5.3",
            "glm/glm-5.3-flash",
            "glm-cn/glm-5.3",
            "glm-cn/glm-5.3-flash",
        ] {
            assert!(catalog.contains_key(id), "{id}");
        }
    }

    #[test]
    fn each_provider_offers_the_effort_levels_it_accepts() {
        let models = deepseek::builtin_models();
        let pro = deepseek_entry(models.iter().find(|m| m.id == "deepseek-v4-pro").unwrap());
        assert_eq!(pro.info.id.as_deref(), Some("deepseek/deepseek-v4-pro"));
        assert_eq!(pro.info.context_window.get(), 1_048_576);
        assert_eq!(
            pro.info.max_completion_tokens, None,
            "left to the service's own default"
        );
        // Thinking can be turned off, and DeepSeek's own default is preselected.
        let levels = |entry: &ModelEntry| -> Vec<ReasoningEffort> {
            entry
                .info
                .reasoning_efforts
                .iter()
                .map(|e| e.value)
                .collect()
        };
        assert_eq!(
            levels(&pro),
            [
                ReasoningEffort::None,
                ReasoningEffort::Low,
                ReasoningEffort::High,
                ReasoningEffort::Max
            ]
        );
        assert_eq!(pro.info.reasoning_effort, Some(ReasoningEffort::High));
        assert_eq!(
            pro.info
                .reasoning_efforts
                .iter()
                .filter(|e| e.default)
                .count(),
            1
        );

        // A later model is described by the fetched list alone. A level this build cannot name is left out.
        let next: DeepSeekModel = serde_json::from_value(serde_json::json!({
            "id": "deepseek-v5", "name": "DeepSeek V5", "context_window": 2_000_000,
            "effort": {"supported_levels": ["low", "max", "future-level"], "default_level": "max"}
        }))
        .unwrap();
        let next = deepseek_entry(&next);
        assert_eq!(next.info.name.as_deref(), Some("DeepSeek V5"));
        assert_eq!(next.info.context_window.get(), 2_000_000);
        assert_eq!(
            levels(&next),
            [
                ReasoningEffort::None,
                ReasoningEffort::Low,
                ReasoningEffort::Max
            ]
        );
        assert_eq!(next.info.reasoning_effort, Some(ReasoningEffort::Max));
        let plain: DeepSeekModel =
            serde_json::from_value(serde_json::json!({"id": "deepseek-lite"})).unwrap();
        assert!(!deepseek_entry(&plain).info.supports_reasoning_effort);

        // The plan's models cannot stop reasoning, and reason hardest unless told otherwise.
        let glm = glm_entry(ModelProvider::GlmCn, glm::model("glm-5.3").unwrap());
        assert_eq!(glm.info.id.as_deref(), Some("glm-cn/glm-5.3"));
        assert_eq!(glm.info.max_completion_tokens, Some(131_072));
        assert_eq!(
            levels(&glm),
            [
                ReasoningEffort::Low,
                ReasoningEffort::High,
                ReasoningEffort::Max
            ]
        );
        assert_eq!(glm.info.reasoning_effort, Some(ReasoningEffort::Max));
    }

    #[test]
    #[serial]
    fn an_environment_key_signs_a_provider_in_and_is_the_credential_sent() {
        let _env = isolate_default_env();
        let _deepseek = EnvGuard::set("DEEPSEEK_API_KEY", "sk-deepseek-fixture");
        let _glm = EnvGuard::set("ZAI_API_KEY", "zai-fixture.key");
        let _cn = EnvGuard::set("ZHIPU_API_KEY", "bigmodel-fixture.key");
        assert!(!needs_provider_setup(&config("")));
        let catalog = resolve_model_list(&config(""), None);
        // Each site's models get that site's key, never the other's and never the xAI session.
        for (id, key) in [
            ("glm/glm-5.3", "zai-fixture.key"),
            ("glm-cn/glm-5.3", "bigmodel-fixture.key"),
        ] {
            assert_eq!(
                resolve_credentials(catalog.get(id).unwrap(), Some("xai-session-fixture"))
                    .api_key
                    .as_deref(),
                Some(key),
                "{id}"
            );
        }
        let (id, deepseek) = catalog
            .iter()
            .find(|(id, _)| id.starts_with("deepseek/"))
            .unwrap();
        assert_eq!(
            resolve_credentials(deepseek, Some("xai-session-fixture"))
                .api_key
                .as_deref(),
            Some("sk-deepseek-fixture"),
            "{id}"
        );
    }

    #[test]
    fn a_providers_key_goes_to_its_own_endpoint_and_nowhere_else() {
        for provider in ModelProvider::ALL {
            let (base_url, backend) = route(provider);
            assert!(matches_auth_route(provider, base_url, backend.clone()));
            assert!(matches_auth_route(
                provider,
                &format!("{base_url}/"),
                backend
            ));
        }
        // The two GLM sites speak the same wire format for different accounts: neither key goes
        // to the other host, nor to the general API endpoint that does not draw on the plan.
        for (provider, url) in [
            (ModelProvider::GlmCn, GLM_BASE_URL),
            (ModelProvider::Glm, GLM_CN_BASE_URL),
            (ModelProvider::Glm, "https://api.z.ai/api/paas/v4"),
            (
                ModelProvider::Glm,
                "https://api.z.ai.example/api/coding/paas/v4",
            ),
            (ModelProvider::DeepSeek, GLM_BASE_URL),
        ] {
            assert!(
                !matches_auth_route(provider, url, ApiBackend::Glm),
                "{provider} at {url}"
            );
        }
        assert!(!matches_auth_route(
            ModelProvider::DeepSeek,
            DEEPSEEK_BASE_URL,
            ApiBackend::ChatCompletions
        ));
    }

    #[test]
    #[serial]
    fn a_new_sign_in_becomes_the_default_only_when_nothing_older_is_signed_in() {
        let _env = isolate_default_env();
        let cfg = config("");
        let signed_in = |mut entry: ModelEntry| {
            entry.api_key = Some("fixture".into());
            entry
        };
        let native = xai_grok_models::default_model();
        let mut catalog = IndexMap::new();
        catalog.insert(native.into(), ModelEntry::fallback(native, &cfg.endpoints));
        let default =
            |catalog: &IndexMap<String, ModelEntry>| resolve_default_model(&cfg, catalog, false).0;

        // The lighter model sorts first in a fetched list; the main one is still the default.
        let mut models = deepseek::builtin_models();
        models.sort_by(|a, b| a.id.cmp(&b.id));
        for model in &models {
            catalog.insert(model.catalog_id(), signed_in(deepseek_entry(model)));
        }
        assert_eq!(default(&catalog), "deepseek/deepseek-v4-pro");

        // The subscription's main model comes before a pay-per-token key.
        for model in glm::MODELS.iter().rev() {
            let entry = signed_in(glm_entry(ModelProvider::GlmCn, model));
            catalog.insert(format!("glm-cn/{}", model.id), entry);
        }
        assert_eq!(default(&catalog), "glm-cn/glm-5.3");

        // Someone already on OpenRouter keeps the default they had.
        let router = entry(
            ModelProvider::OpenRouter,
            "openrouter/openrouter/auto",
            "openrouter/auto",
            "OpenRouter Auto",
            200_000,
        );
        catalog.insert("openrouter/openrouter/auto".into(), signed_in(router));
        assert_eq!(default(&catalog), "openrouter/openrouter/auto");
    }

    #[test]
    fn capabilities_come_from_each_providers_own_list() {
        assert_eq!(image_support(&ApiBackend::Glm, "glm-5.3"), Some(false));
        assert_eq!(image_support(&ApiBackend::Glm, "glm-5.3-flash"), Some(true));
        // A model no list describes is sent images as they are.
        assert_eq!(image_support(&ApiBackend::Glm, "glm-6"), None);
        assert_eq!(image_support(&ApiBackend::DeepSeek, "not-a-model"), None);
        for backend in [
            ApiBackend::ChatCompletions,
            ApiBackend::Responses,
            ApiBackend::Messages,
            ApiBackend::OpenAiCodex,
        ] {
            assert_eq!(image_support(&backend, "glm-5.3"), None);
            assert_eq!(tool_support(&backend, "glm-5.3"), None);
        }
        // Tools are never withheld from DeepSeek or GLM models: all of theirs take them.
        assert_eq!(tool_support(&ApiBackend::DeepSeek, "deepseek-v4-pro"), None);
        assert_eq!(tool_support(&ApiBackend::Glm, "glm-5.3"), None);
    }
}
