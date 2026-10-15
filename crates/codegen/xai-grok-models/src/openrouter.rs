//! Live OpenRouter model discovery. Cache metadata, never credentials.
//!
//! The public catalog returns every model when pagination/filter parameters are
//! omitted. Keep models without tool support: they can still serve normal chat.
//! See https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.

use std::collections::{BTreeMap, HashMap};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

pub const OPENROUTER_BASE_URL: &str = "https://openrouter.ai/api/v1";
pub const OPENROUTER_MODELS_URL: &str = "https://openrouter.ai/api/v1/models";
pub const CACHE_TTL: Duration = Duration::from_secs(60 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CATALOG_BYTES: usize = 16 * 1024 * 1024;
const CACHE_VERSION: u32 = 1;

// Model resolution is synchronous and frequent. Retain parsed snapshots so it
// neither rereads hundreds of catalog entries nor loses successful live fetches
// when the home directory is read-only. Periodic refresh checks disk again so
// updates made by another process are eventually observed.
static MEMORY_CACHE: LazyLock<Mutex<HashMap<PathBuf, CachedCatalog>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct OpenRouterArchitecture {
    #[serde(default)]
    pub input_modalities: Vec<String>,
    #[serde(default)]
    pub output_modalities: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct OpenRouterTopProvider {
    pub context_length: Option<u64>,
    pub max_completion_tokens: Option<u64>,
}

/// Prices are decimal USD per token, as returned by OpenRouter.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct OpenRouterPricing {
    pub prompt: Option<String>,
    pub completion: Option<String>,
    pub input_cache_read: Option<String>,
    pub input_cache_write: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct OpenRouterReasoning {
    #[serde(default)]
    pub supported_efforts: Vec<String>,
    pub default_effort: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct OpenRouterModel {
    /// API routing slug, e.g. `anthropic/claude-sonnet-4`.
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub description: Option<String>,
    pub context_length: Option<u64>,
    #[serde(default, deserialize_with = "null_default")]
    pub supported_parameters: Vec<String>,
    #[serde(default, deserialize_with = "null_default")]
    pub architecture: OpenRouterArchitecture,
    #[serde(default, deserialize_with = "null_default")]
    pub top_provider: OpenRouterTopProvider,
    #[serde(default, deserialize_with = "null_default")]
    pub pricing: OpenRouterPricing,
    #[serde(default, deserialize_with = "null_default")]
    pub reasoning: OpenRouterReasoning,
}

fn null_default<'de, D, T>(deserializer: D) -> std::result::Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

impl OpenRouterModel {
    /// Namespaced local picker ID; send `id`, not this value, to OpenRouter.
    pub fn catalog_id(&self) -> String {
        format!("openrouter/{}", self.id)
    }

    pub fn supports_tools(&self) -> bool {
        self.supports_parameter("tools")
    }

    pub fn supports_images(&self) -> bool {
        self.architecture
            .input_modalities
            .iter()
            .any(|modality| modality == "image")
    }

    pub fn supports_reasoning(&self) -> bool {
        self.supports_parameter("reasoning") || self.supports_parameter("reasoning_effort")
    }

    pub fn supports_parameter(&self, parameter: &str) -> bool {
        self.supported_parameters.iter().any(|p| p == parameter)
    }

    fn supports_text_output(&self) -> bool {
        // Older API responses omit modality metadata. Do not discard those.
        self.architecture.output_modalities.is_empty()
            || self
                .architecture
                .output_modalities
                .iter()
                .any(|m| m == "text")
    }
}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<OpenRouterModel>,
}

#[derive(Clone, Deserialize, Serialize)]
struct CachedCatalog {
    version: u32,
    fetched_at: u64,
    models: Vec<OpenRouterModel>,
}

impl CachedCatalog {
    fn fresh_at(&self, now: u64) -> bool {
        // A clock adjustment must not leave a future-dated cache fresh forever.
        now.checked_sub(self.fetched_at)
            .is_some_and(|age| age < CACHE_TTL.as_secs())
    }
}

/// Read the last valid catalog without making network requests. Its age does not
/// affect usability, so offline startup can still populate the model picker.
pub fn read_cached_models(cache_path: &Path) -> Result<Vec<OpenRouterModel>> {
    if let Some(cache) = memory_cache(cache_path) {
        return Ok(cache.models);
    }
    let cache = read_cache(cache_path)?;
    remember_cache(cache_path, &cache);
    Ok(cache.models)
}

/// One model's prices from the last valid catalog, without a network request or a copy of the
/// whole catalog. `id` is the routing slug, without the `openrouter/` picker prefix.
pub fn cached_pricing(cache_path: &Path, id: &str) -> Option<OpenRouterPricing> {
    let find = |cache: &CachedCatalog| {
        cache
            .models
            .iter()
            .find(|model| model.id == id)
            .map(|model| model.pricing.clone())
    };
    {
        let memory = MEMORY_CACHE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(cache) = memory.get(cache_path) {
            return find(cache);
        }
    }
    let cache = read_cache(cache_path).ok()?;
    remember_cache(cache_path, &cache);
    find(&cache)
}

/// Refresh an absent/stale catalog, or force a refresh regardless of age.
///
/// Call at startup and periodically (e.g. every [`CACHE_TTL`]) so newly published
/// models appear without changing the binary or editing configuration. A valid
/// cached catalog is returned on automatic refresh failures. A forced refresh
/// propagates HTTP or malformed-response failures so an explicit CLI refresh
/// cannot report success using old data. A failed refresh never advances the cache
/// timestamp, so later calls retry. Successful responses replace the snapshot,
/// adding new models and dropping models removed by OpenRouter.
///
/// The catalog is public: deliberately send no authentication or user data.
pub async fn refresh_models(
    client: &reqwest::Client,
    cache_path: &Path,
    force: bool,
) -> Result<Vec<OpenRouterModel>> {
    refresh_models_from(client, cache_path, force, OPENROUTER_MODELS_URL).await
}

async fn refresh_models_from(
    client: &reqwest::Client,
    cache_path: &Path,
    force: bool,
    models_url: &str,
) -> Result<Vec<OpenRouterModel>> {
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

    match fetch_models(client, models_url).await {
        Ok(models) => {
            let cache = CachedCatalog {
                version: CACHE_VERSION,
                fetched_at: unix_now(),
                models,
            };
            remember_cache(cache_path, &cache);
            // A read-only home must not prevent use of the live catalog.
            if let Err(error) = write_cache(cache_path, &cache) {
                tracing::warn!(%error, "could not persist OpenRouter model catalog");
            }
            Ok(cache.models)
        }
        Err(error) if force => Err(error),
        Err(error) => match cached {
            Some(cache) => {
                tracing::warn!(%error, "OpenRouter catalog refresh failed; using cached models");
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

async fn fetch_models(client: &reqwest::Client, models_url: &str) -> Result<Vec<OpenRouterModel>> {
    let mut response = client
        .get(models_url)
        .timeout(FETCH_TIMEOUT)
        .send()
        .await
        .context("fetch OpenRouter model catalog")?
        .error_for_status()
        .context("OpenRouter model catalog request failed")?;
    if response
        .content_length()
        .is_some_and(|len| len > MAX_CATALOG_BYTES as u64)
    {
        bail!("OpenRouter model catalog exceeds size limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .context("read OpenRouter model catalog")?
    {
        ensure!(
            bytes.len().saturating_add(chunk.len()) <= MAX_CATALOG_BYTES,
            "OpenRouter model catalog exceeds size limit"
        );
        bytes.extend_from_slice(&chunk);
    }
    let response: ModelsResponse =
        serde_json::from_slice(&bytes).context("invalid OpenRouter model catalog")?;
    normalize_models(response.data)
}

fn normalize_models(models: Vec<OpenRouterModel>) -> Result<Vec<OpenRouterModel>> {
    let mut unique = BTreeMap::new();
    for mut model in models {
        // Reject invalid routing slugs and non-chat models, but never filter by
        // tool support, provider, pricing or an allowlist of known model names.
        if model.id.is_empty()
            || model.id.chars().any(char::is_whitespace)
            || !model.supports_text_output()
        {
            continue;
        }
        if model.name.is_empty() {
            model.name = model.id.clone();
        }
        unique.insert(model.id.clone(), model);
    }
    ensure!(
        !unique.is_empty(),
        "OpenRouter returned no valid chat models"
    );
    Ok(unique.into_values().collect())
}

fn read_cache(cache_path: &Path) -> Result<CachedCatalog> {
    let file = std::fs::File::open(cache_path).context("open OpenRouter model cache")?;
    ensure!(
        file.metadata()?.len() <= MAX_CATALOG_BYTES as u64,
        "OpenRouter model cache exceeds size limit"
    );
    let mut cache: CachedCatalog =
        serde_json::from_reader(BufReader::new(file)).context("invalid OpenRouter model cache")?;
    ensure!(
        cache.version == CACHE_VERSION,
        "unsupported OpenRouter model cache version"
    );
    cache.models = normalize_models(cache.models)?;
    Ok(cache)
}

fn write_cache(cache_path: &Path, cache: &CachedCatalog) -> Result<()> {
    let parent = cache_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).context("create OpenRouter model cache directory")?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(temporary.as_file_mut(), cache)?;
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(cache_path)
        .context("replace OpenRouter model cache")?;
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

    fn model(id: &str) -> OpenRouterModel {
        serde_json::from_value(serde_json::json!({"id": id})).unwrap()
    }

    fn cache(path: &Path, ids: &[&str], fetched_at: u64) {
        write_cache(
            path,
            &CachedCatalog {
                version: CACHE_VERSION,
                fetched_at,
                models: ids.iter().map(|id| model(id)).collect(),
            },
        )
        .unwrap();
    }

    async fn serve_once(status: u16, body: String) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/models", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let count = socket.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(request.get(..count).unwrap());
            assert!(!request.to_lowercase().contains("authorization:"));
            let response = format!(
                "HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        (url, server)
    }

    #[test]
    fn retains_models_without_tools_and_discovers_metadata() {
        let raw = serde_json::json!({"data": [
            {"id": "new-provider/new-model", "context_length": 123456,
             "supported_parameters": ["tools", "reasoning"],
             "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
             "top_provider": {"max_completion_tokens": 8192},
             "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
            {"id": "provider/plain-chat", "supported_parameters": []},
            {"id": "provider/image", "architecture": {"output_modalities": ["image"]}},
            {"id": ""}, {"id": "provider/plain-chat"}
        ]});
        let response: ModelsResponse = serde_json::from_value(raw).unwrap();
        let models = normalize_models(response.data).unwrap();
        assert_eq!(models.len(), 2);
        let new_model = models
            .iter()
            .find(|m| m.id == "new-provider/new-model")
            .unwrap();
        assert_eq!(new_model.catalog_id(), "openrouter/new-provider/new-model");
        assert!(new_model.supports_tools());
        assert!(new_model.supports_images());
        assert!(new_model.supports_reasoning());
        assert_eq!(new_model.top_provider.max_completion_tokens, Some(8192));
        assert_eq!(new_model.pricing.prompt.as_deref(), Some("0.000001"));
        assert!(
            models
                .iter()
                .any(|m| m.id == "provider/plain-chat" && !m.supports_tools())
        );
    }

    #[test]
    fn cache_expiry_and_future_timestamps() {
        let cache = CachedCatalog {
            version: CACHE_VERSION,
            fetched_at: 100,
            models: vec![model("a/b")],
        };
        assert!(cache.fresh_at(100));
        assert!(cache.fresh_at(100 + CACHE_TTL.as_secs() - 1));
        assert!(!cache.fresh_at(100 + CACHE_TTL.as_secs()));
        assert!(!cache.fresh_at(99));
    }

    #[tokio::test]
    async fn fresh_cache_avoids_network_and_force_adds_new_models() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("models.json");
        cache(&path, &["provider/old"], unix_now());
        let client = reqwest::Client::new();
        let old = refresh_models_from(&client, &path, false, "invalid://not-used")
            .await
            .unwrap();
        assert_eq!(old.first().unwrap().id, "provider/old");

        let (url, server) = serve_once(
            200,
            r#"{"data":[{"id":"provider/old"},{"id":"new/new-chat"}]}"#.into(),
        )
        .await;
        let new = refresh_models_from(&client, &path, true, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(new.len(), 2);
        assert!(new.iter().any(|m| m.id == "new/new-chat"));
        assert_eq!(read_cached_models(&path).unwrap(), new);
    }

    #[tokio::test]
    async fn expired_cache_refresh_replaces_removed_models() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/models.json");
        cache(&path, &["provider/retired"], 1);
        let (url, server) = serve_once(200, r#"{"data":[{"id":"provider/new"}]}"#.into()).await;
        let models = refresh_models_from(&reqwest::Client::new(), &path, false, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models.first().unwrap().id, "provider/new");
        assert!(read_cache(&path).unwrap().fetched_at > 1);
    }

    #[tokio::test]
    async fn failed_or_invalid_refresh_preserves_stale_cache_and_timestamp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("models.json");
        cache(&path, &["provider/available-offline"], 1);
        let before = std::fs::read(&path).unwrap();
        for (status, body) in [
            (503, "unavailable"),
            (200, "not-json"),
            (200, r#"{"data":[]}"#),
            (200, r#"{"error":{"message":"bad response"}}"#),
        ] {
            let (url, server) = serve_once(status, body.into()).await;
            let models = refresh_models_from(&reqwest::Client::new(), &path, false, &url)
                .await
                .unwrap();
            server.await.unwrap();
            assert_eq!(models.first().unwrap().id, "provider/available-offline");
            assert_eq!(std::fs::read(&path).unwrap(), before);
        }
    }

    #[tokio::test]
    async fn corrupt_cache_recovers_and_empty_first_fetch_errors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("models.json");
        std::fs::write(&path, "corrupt").unwrap();
        let (url, server) = serve_once(200, r#"{"data":[]}"#.into()).await;
        assert!(
            refresh_models_from(&reqwest::Client::new(), &path, false, &url)
                .await
                .is_err()
        );
        server.await.unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "corrupt");

        let (url, server) =
            serve_once(200, r#"{"data":[{"id":"provider/recovered"}]}"#.into()).await;
        refresh_models_from(&reqwest::Client::new(), &path, false, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(
            read_cached_models(&path).unwrap().first().unwrap().id,
            "provider/recovered"
        );
    }

    #[tokio::test]
    async fn successful_fetch_survives_cache_write_failure_in_memory() {
        let dir = tempfile::tempdir().unwrap();
        // A regular file cannot be the parent directory of the cache, reliably
        // simulating a write failure even when tests run with elevated access.
        let parent = dir.path().join("not-a-directory");
        std::fs::write(&parent, "file").unwrap();
        let path = parent.join("models.json");
        let (url, server) =
            serve_once(200, r#"{"data":[{"id":"provider/live-only"}]}"#.into()).await;
        let models = refresh_models_from(&reqwest::Client::new(), &path, false, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert!(!path.exists());
        assert_eq!(read_cached_models(&path).unwrap(), models);
        let cached =
            refresh_models_from(&reqwest::Client::new(), &path, false, "invalid://not-used")
                .await
                .unwrap();
        assert_eq!(cached, models);
    }

    #[tokio::test]
    async fn periodic_refresh_observes_a_newer_snapshot_from_another_process() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("models.json");
        cache(&path, &["provider/old"], 1);
        assert_eq!(
            read_cached_models(&path).unwrap().first().unwrap().id,
            "provider/old"
        );

        // Simulate an atomic update by another running CLI process. Normal reads
        // stay in memory until periodic refresh picks up the newer disk snapshot.
        cache(&path, &["provider/added-elsewhere"], unix_now());
        let models =
            refresh_models_from(&reqwest::Client::new(), &path, false, "invalid://not-used")
                .await
                .unwrap();
        assert_eq!(models.first().unwrap().id, "provider/added-elsewhere");
        assert_eq!(read_cached_models(&path).unwrap(), models);
    }

    #[tokio::test]
    async fn explicit_refresh_reports_failure_without_losing_cached_models() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("models.json");
        cache(&path, &["provider/available-offline"], 1);
        let before = std::fs::read(&path).unwrap();
        let (url, server) = serve_once(503, "unavailable".into()).await;
        assert!(
            refresh_models_from(&reqwest::Client::new(), &path, true, &url)
                .await
                .is_err()
        );
        server.await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            read_cached_models(&path).unwrap().first().unwrap().id,
            "provider/available-offline"
        );
    }
}
