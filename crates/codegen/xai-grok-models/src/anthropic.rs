//! Anthropic's model list. Cache metadata, never credentials.
//!
//! `GET /v1/models` needs the account's key and describes each model: its context
//! window, output limit, and what it accepts (images, adaptive thinking, effort
//! levels). The built-in list stands in until the first successful fetch.
//! See https://platform.claude.com/docs/en/api/models/list.

use std::collections::HashMap;
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const ANTHROPIC_BASE_URL: &str = "https://api.anthropic.com/v1";
pub const ANTHROPIC_MODELS_URL: &str = "https://api.anthropic.com/v1/models";
/// The API version every request names. See https://platform.claude.com/docs/en/api/versioning.
pub const ANTHROPIC_VERSION: &str = "2023-06-01";
pub const CACHE_TTL: Duration = Duration::from_secs(60 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CATALOG_BYTES: usize = 1024 * 1024;
const CACHE_VERSION: u32 = 1;
/// The largest page the endpoint serves; an account's whole list fits in one.
const PAGE_SIZE: u32 = 1000;
/// A list that keeps saying there is more is cut off here.
const MAX_PAGES: usize = 5;
/// The value a model takes when the list does not say.
const DEFAULT_CONTEXT_WINDOW: u64 = 200_000;
/// `output_config.effort` values, lowest first.
const EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

// Model resolution is synchronous and frequent, so keep the parsed list in memory.
static MEMORY_CACHE: LazyLock<Mutex<HashMap<PathBuf, CachedCatalog>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct AnthropicModel {
    /// The id sent on the wire, e.g. `claude-opus-5-5`.
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub context_window: Option<u64>,
    pub max_output_tokens: Option<u64>,
    /// `None` when the list does not say.
    pub supports_images: Option<bool>,
    /// Whether the model takes `thinking: {"type": "adaptive"}`. Earlier models think only with a token budget.
    #[serde(default)]
    pub adaptive_thinking: bool,
    /// The `output_config.effort` values the model accepts, lowest first. Empty when it takes none.
    #[serde(default)]
    pub efforts: Vec<String>,
}

impl AnthropicModel {
    /// Namespaced local picker ID; send `id`, not this value, to Anthropic.
    pub fn catalog_id(&self) -> String {
        format!("anthropic/{}", self.id)
    }

    pub fn context_window(&self) -> u64 {
        self.context_window
            .filter(|n| *n > 0)
            .unwrap_or(DEFAULT_CONTEXT_WINDOW)
    }

    /// One entry of the documented `GET /v1/models` response.
    /// `capabilities` is a tree with `supported` at each leaf; a branch this build does not know is ignored.
    fn from_listing(entry: &Value) -> Option<Self> {
        let id = entry.get("id")?.as_str()?.to_owned();
        let name = entry
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let context_window = entry.get("max_input_tokens").and_then(Value::as_u64);
        let max_output_tokens = entry.get("max_tokens").and_then(Value::as_u64);
        // A listing that describes no capabilities says nothing either way. For a model this build
        // knows, what it knows stands: without it the model would be offered no effort level.
        if entry.get("capabilities").is_none()
            && let Some(known) = builtin_models().into_iter().find(|model| model.id == id)
        {
            return Some(Self {
                name: if name.is_empty() { known.name } else { name },
                context_window: context_window.or(known.context_window),
                max_output_tokens: max_output_tokens.or(known.max_output_tokens),
                ..known
            });
        }
        let supported = |path: &[&str]| {
            path.iter()
                .try_fold(entry.get("capabilities")?, |node, key| node.get(key))?
                .get("supported")?
                .as_bool()
        };
        let efforts = if supported(&["effort"]) == Some(false) {
            Vec::new()
        } else {
            EFFORT_LEVELS
                .iter()
                .filter(|level| supported(&["effort", **level]) == Some(true))
                .map(|level| (*level).to_owned())
                .collect()
        };
        Some(Self {
            name,
            context_window,
            max_output_tokens,
            supports_images: supported(&["image_input"]),
            adaptive_thinking: supported(&["thinking", "types", "adaptive"]) == Some(true),
            efforts,
            id,
        })
    }
}

/// The current models as of this build, for use before the account's own list is fetched.
pub fn builtin_models() -> Vec<AnthropicModel> {
    let model = |id: &str, name: &str| AnthropicModel {
        id: id.into(),
        name: name.into(),
        context_window: Some(1_000_000),
        max_output_tokens: Some(128_000),
        supports_images: Some(true),
        adaptive_thinking: true,
        efforts: EFFORT_LEVELS.iter().map(|l| (*l).to_owned()).collect(),
    };
    vec![
        model("claude-opus-5-5", "Claude Opus 5.5"),
        model("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        model("claude-haiku-5-5", "Claude Haiku 5.5"),
        model("claude-fable-5-1", "Claude Fable 5.1"),
    ]
}

/// The provider refused the key (HTTP 401). Any other failure is an ordinary error.
#[derive(Debug)]
pub struct KeyRejected;

impl std::fmt::Display for KeyRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Anthropic did not accept the API key")
    }
}

impl std::error::Error for KeyRejected {}

#[derive(Deserialize)]
struct ModelsPage {
    data: Vec<Value>,
    #[serde(default)]
    has_more: bool,
    #[serde(default)]
    last_id: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
struct CachedCatalog {
    version: u32,
    fetched_at: u64,
    models: Vec<AnthropicModel>,
}

impl CachedCatalog {
    fn fresh_at(&self, now: u64) -> bool {
        // A clock adjustment must not leave a future-dated cache fresh forever.
        now.checked_sub(self.fetched_at)
            .is_some_and(|age| age < CACHE_TTL.as_secs())
    }
}

/// The last fetched list, without a network request and whatever its age.
pub fn read_cached_models(cache_path: &Path) -> Result<Vec<AnthropicModel>> {
    if let Some(cache) = memory_cache(cache_path) {
        return Ok(cache.models);
    }
    let cache = read_cache(cache_path)?;
    remember_cache(cache_path, &cache);
    Ok(cache.models)
}

/// Refresh an absent or stale list, or force a refresh regardless of age.
///
/// An automatic refresh that fails returns the cached list when there is one.
/// A forced refresh returns the failure, so signing in can tell a refused key
/// ([`KeyRejected`]) from a list that merely could not be fetched.
pub async fn refresh_models(
    client: &reqwest::Client,
    cache_path: &Path,
    api_key: &str,
    force: bool,
) -> Result<Vec<AnthropicModel>> {
    refresh_models_from(client, cache_path, api_key, force, ANTHROPIC_MODELS_URL).await
}

async fn refresh_models_from(
    client: &reqwest::Client,
    cache_path: &Path,
    api_key: &str,
    force: bool,
    models_url: &str,
) -> Result<Vec<AnthropicModel>> {
    let cached = match (memory_cache(cache_path), read_cache(cache_path).ok()) {
        (Some(memory), Some(disk)) if disk.fetched_at > memory.fetched_at => Some(disk),
        (Some(memory), _) => Some(memory),
        (None, disk) => disk,
    };
    if let Some(cache) = &cached {
        remember_cache(cache_path, cache);
    }
    if !force
        && let Some(cache) = &cached
        && cache.fresh_at(unix_now())
    {
        return Ok(cache.models.clone());
    }

    match fetch_models(client, models_url, api_key).await {
        Ok(models) => {
            let cache = CachedCatalog {
                version: CACHE_VERSION,
                fetched_at: unix_now(),
                models,
            };
            remember_cache(cache_path, &cache);
            // A read-only home must not prevent use of the live list.
            if let Err(error) = write_cache(cache_path, &cache) {
                tracing::warn!(%error, "could not persist Anthropic model list");
            }
            Ok(cache.models)
        }
        Err(error) if force => Err(error),
        Err(error) => match cached {
            Some(cache) => {
                tracing::warn!(%error, "Anthropic model list refresh failed; using cached models");
                Ok(cache.models)
            }
            None => Err(error),
        },
    }
}

fn memory_cache(cache_path: &Path) -> Option<CachedCatalog> {
    MEMORY_CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(cache_path)
        .cloned()
}

fn remember_cache(cache_path: &Path, cache: &CachedCatalog) {
    MEMORY_CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(cache_path.to_path_buf(), cache.clone());
}

async fn fetch_models(
    client: &reqwest::Client,
    models_url: &str,
    api_key: &str,
) -> Result<Vec<AnthropicModel>> {
    let mut models = Vec::new();
    let mut after_id: Option<String> = None;
    for _ in 0..MAX_PAGES {
        let page = fetch_page(client, models_url, api_key, after_id.as_deref()).await?;
        models.extend(page.data.iter().filter_map(AnthropicModel::from_listing));
        match page.last_id {
            Some(last) if page.has_more => after_id = Some(last),
            _ => break,
        }
    }
    normalize_models(models)
}

async fn fetch_page(
    client: &reqwest::Client,
    models_url: &str,
    api_key: &str,
    after_id: Option<&str>,
) -> Result<ModelsPage> {
    let mut request = client
        .get(models_url)
        .query(&[("limit", PAGE_SIZE)])
        // An API key goes in `x-api-key`; `Authorization: Bearer` is for OAuth tokens.
        .header("x-api-key", api_key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .timeout(FETCH_TIMEOUT);
    if let Some(after_id) = after_id {
        request = request.query(&[("after_id", after_id)]);
    }
    let mut response = request
        .send()
        .await
        // The request carries the key; keep the error to what went wrong, not what was sent.
        .map_err(|error| anyhow::anyhow!("fetch Anthropic model list: {}", error.without_url()))?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err(KeyRejected.into());
    }
    ensure!(
        response.status().is_success(),
        "Anthropic model list request failed (HTTP {})",
        response.status().as_u16()
    );
    if response
        .content_length()
        .is_some_and(|len| len > MAX_CATALOG_BYTES as u64)
    {
        bail!("Anthropic model list exceeds size limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| anyhow::anyhow!("read Anthropic model list: {}", error.without_url()))?
    {
        ensure!(
            bytes.len().saturating_add(chunk.len()) <= MAX_CATALOG_BYTES,
            "Anthropic model list exceeds size limit"
        );
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).context("invalid Anthropic model list")
}

/// Keeps the order Anthropic lists them in, newest first, which is the order the picker shows.
fn normalize_models(models: Vec<AnthropicModel>) -> Result<Vec<AnthropicModel>> {
    let mut seen = std::collections::HashSet::new();
    let models: Vec<_> = models
        .into_iter()
        .filter(|model| !model.id.is_empty() && !model.id.chars().any(char::is_whitespace))
        .filter(|model| seen.insert(model.id.clone()))
        .map(|mut model| {
            if model.name.is_empty() {
                model.name = model.id.clone();
            }
            model
        })
        .collect();
    ensure!(!models.is_empty(), "Anthropic returned no models");
    Ok(models)
}

fn read_cache(cache_path: &Path) -> Result<CachedCatalog> {
    let file = std::fs::File::open(cache_path).context("open Anthropic model cache")?;
    ensure!(
        file.metadata()?.len() <= MAX_CATALOG_BYTES as u64,
        "Anthropic model cache exceeds size limit"
    );
    let mut cache: CachedCatalog =
        serde_json::from_reader(BufReader::new(file)).context("invalid Anthropic model cache")?;
    ensure!(
        cache.version == CACHE_VERSION,
        "unsupported Anthropic model cache version"
    );
    cache.models = normalize_models(cache.models)?;
    Ok(cache)
}

fn write_cache(cache_path: &Path, cache: &CachedCatalog) -> Result<()> {
    let parent = cache_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).context("create Anthropic model cache directory")?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(temporary.as_file_mut(), cache)?;
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(cache_path)
        .context("replace Anthropic model cache")?;
    Ok(())
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "clients only connect to the local test server"
)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Serve one response and hand back the request that was received.
    async fn serve_once(status: u16, body: String) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1/models", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let count = socket.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(request.get(..count).unwrap()).into_owned();
            let response = format!(
                "HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(response.as_bytes()).await.unwrap();
            request
        });
        (url, server)
    }

    /// The documented response: a current model, an earlier one that thinks only with a
    /// budget and takes no effort, and one this build has never heard of.
    fn listing() -> String {
        let leaf = |supported: bool| serde_json::json!({"supported": supported});
        serde_json::json!({"data": [
            {"type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5",
             "created_at": "2026-09-01T00:00:00Z", "max_input_tokens": 1000000, "max_tokens": 128000,
             "capabilities": {
                 "image_input": leaf(true),
                 "structured_outputs": leaf(true),
                 "thinking": {"supported": true, "types": {"enabled": leaf(false), "adaptive": leaf(true)}},
                 "effort": {"supported": true, "low": leaf(true), "medium": leaf(true),
                            "high": leaf(true), "xhigh": leaf(true), "max": leaf(true)}}},
            {"type": "model", "id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5",
             "max_input_tokens": 200000, "max_tokens": 64000,
             "capabilities": {
                 "image_input": leaf(true),
                 "thinking": {"supported": true, "types": {"enabled": leaf(true), "adaptive": leaf(false)}},
                 "effort": {"supported": false, "low": leaf(false), "high": leaf(false)}}},
            {"type": "model", "id": "claude-next"},
            {"type": "model", "id": ""}
        ], "has_more": false, "first_id": "claude-opus-5-5", "last_id": "claude-next"})
        .to_string()
    }

    #[tokio::test]
    async fn the_list_is_fetched_with_the_key_and_cached_without_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("anthropic-models.json");
        let (url, server) = serve_once(200, listing()).await;
        let models = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "sk-ant-fixture-secret",
            true,
            &url,
        )
        .await
        .unwrap();
        let request = server.await.unwrap().to_lowercase();
        assert!(request.contains("x-api-key: sk-ant-fixture-secret"));
        assert!(request.contains("anthropic-version: 2023-06-01"));
        assert!(!request.contains("authorization:"));
        assert!(request.contains("limit=1000"));

        // Anthropic's order, newest first, is kept.
        let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "claude-opus-5-5",
                "claude-haiku-4-5-20251001",
                "claude-next"
            ]
        );
        let opus = models.first().unwrap();
        assert_eq!(opus.catalog_id(), "anthropic/claude-opus-5-5");
        assert_eq!(opus.context_window(), 1_000_000);
        assert_eq!(opus.max_output_tokens, Some(128_000));
        assert_eq!(opus.supports_images, Some(true));
        assert!(opus.adaptive_thinking);
        assert_eq!(opus.efforts, ["low", "medium", "high", "xhigh", "max"]);
        let haiku = models.get(1).unwrap();
        assert!(!haiku.adaptive_thinking);
        assert!(haiku.efforts.is_empty());
        // A model released after this build needs no code change, and claims nothing it did not list.
        let next = models.get(2).unwrap();
        assert_eq!(next.name, "claude-next");
        assert_eq!(next.context_window(), DEFAULT_CONTEXT_WINDOW);
        assert_eq!(next.supports_images, None);
        assert!(!next.adaptive_thinking && next.efforts.is_empty());

        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(!saved.contains("sk-ant-fixture-secret"));
        // Fresh: no request is made, so the unreachable address is never used.
        let again = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "sk-ant-fixture-secret",
            false,
            "http://127.0.0.1:1/unreachable",
        )
        .await
        .unwrap();
        assert_eq!(again, models);
        assert_eq!(read_cached_models(&path).unwrap(), models);
    }

    #[tokio::test]
    async fn a_refused_key_is_told_apart_from_other_failures() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("anthropic-models.json");
        let body = r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#;
        let (url, server) = serve_once(401, body.into()).await;
        let error =
            refresh_models_from(&reqwest::Client::new(), &path, "sk-ant-secret", true, &url)
                .await
                .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_some());
        assert!(!path.exists());

        let (url, server) = serve_once(529, "{}".into()).await;
        let error =
            refresh_models_from(&reqwest::Client::new(), &path, "sk-ant-secret", true, &url)
                .await
                .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_none());
        assert!(!format!("{error:#}").contains("sk-ant-secret"));
    }

    #[tokio::test]
    async fn a_failed_automatic_refresh_keeps_the_stale_list() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("anthropic-models.json");
        write_cache(
            &path,
            &CachedCatalog {
                version: CACHE_VERSION,
                fetched_at: 1,
                models: builtin_models(),
            },
        )
        .unwrap();
        let (url, server) = serve_once(500, "{}".into()).await;
        let models =
            refresh_models_from(&reqwest::Client::new(), &path, "sk-ant-secret", false, &url)
                .await
                .unwrap();
        server.await.unwrap();
        assert_eq!(models.len(), builtin_models().len());
    }

    #[test]
    fn a_listing_without_capabilities_keeps_what_is_known_of_a_current_model() {
        let listed = |entry: serde_json::Value| AnthropicModel::from_listing(&entry).unwrap();
        let sonnet = listed(serde_json::json!({
            "type": "model", "id": "claude-sonnet-5-5", "display_name": "Sonnet", "max_tokens": 64000
        }));
        assert_eq!(sonnet.name, "Sonnet");
        assert_eq!(sonnet.max_output_tokens, Some(64_000));
        assert_eq!(sonnet.context_window(), 1_000_000);
        assert!(sonnet.adaptive_thinking);
        assert_eq!(sonnet.efforts.len(), EFFORT_LEVELS.len());
        // What the listing does say wins, including that a model takes no effort.
        let described = listed(serde_json::json!({
            "type": "model", "id": "claude-sonnet-5-5",
            "capabilities": {"effort": {"supported": false}}
        }));
        assert!(!described.adaptive_thinking && described.efforts.is_empty());
        // A model this build has never heard of claims nothing.
        let unknown =
            listed(serde_json::json!({"type": "model", "id": "claude-sonnet-5-5-preview"}));
        assert!(!unknown.adaptive_thinking && unknown.efforts.is_empty());
    }

    #[test]
    fn the_builtin_list_leads_with_the_default_model() {
        let models = builtin_models();
        assert_eq!(models.first().unwrap().id, "claude-opus-5-5");
        assert!(models.iter().all(|m| m.adaptive_thinking
            && m.supports_images == Some(true)
            && m.context_window() == 1_000_000));
    }
}
