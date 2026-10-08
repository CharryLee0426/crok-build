//! DeepSeek's model list. Cache metadata, never credentials.
//!
//! `GET /models` needs the account's key and describes each model: its context
//! window, output limit, input types and reasoning effort levels. The built-in
//! list stands in until the first successful fetch.
//! See https://api-docs.deepseek.com/api/list-models.

use std::collections::{BTreeMap, HashMap};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

pub const DEEPSEEK_BASE_URL: &str = "https://api.deepseek.com";
pub const DEEPSEEK_MODELS_URL: &str = "https://api.deepseek.com/models";
pub const CACHE_TTL: Duration = Duration::from_secs(60 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CATALOG_BYTES: usize = 1024 * 1024;
const CACHE_VERSION: u32 = 1;
/// Both current models; the value a model takes when the list does not say.
const DEFAULT_CONTEXT_WINDOW: u64 = 1_048_576;

// Model resolution is synchronous and frequent, so keep the parsed list in memory.
static MEMORY_CACHE: LazyLock<Mutex<HashMap<PathBuf, CachedCatalog>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct DeepSeekEffort {
    /// The values `reasoning_effort` accepts, in display order. `none`, which turns thinking off, is not listed.
    #[serde(default)]
    pub supported_levels: Vec<String>,
    pub default_level: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct DeepSeekModel {
    /// The id sent on the wire, e.g. `deepseek-v4-pro`.
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub context_window: Option<u64>,
    pub max_output_tokens: Option<u64>,
    #[serde(default, deserialize_with = "null_default")]
    pub input_modalities: Vec<String>,
    #[serde(default, deserialize_with = "null_default")]
    pub effort: DeepSeekEffort,
}

fn null_default<'de, D, T>(deserializer: D) -> std::result::Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

impl DeepSeekModel {
    /// Namespaced local picker ID; send `id`, not this value, to DeepSeek.
    pub fn catalog_id(&self) -> String {
        format!("deepseek/{}", self.id)
    }

    pub fn context_window(&self) -> u64 {
        self.context_window
            .filter(|n| *n > 0)
            .unwrap_or(DEFAULT_CONTEXT_WINDOW)
    }

    /// An older list without modalities says nothing either way.
    pub fn supports_images(&self) -> Option<bool> {
        (!self.input_modalities.is_empty())
            .then(|| self.input_modalities.iter().any(|m| m == "image"))
    }
}

/// The models DeepSeek serves as of this build, for use before the account's own list is fetched.
pub fn builtin_models() -> Vec<DeepSeekModel> {
    let model = |id: &str, name: &str, modalities: &[&str]| DeepSeekModel {
        id: id.into(),
        name: name.into(),
        context_window: Some(DEFAULT_CONTEXT_WINDOW),
        max_output_tokens: Some(393_216),
        input_modalities: modalities.iter().map(|m| (*m).to_owned()).collect(),
        effort: DeepSeekEffort {
            supported_levels: vec!["low".into(), "high".into(), "max".into()],
            default_level: Some("high".into()),
        },
    };
    vec![
        model("deepseek-v4-pro", "DeepSeek V4 Pro", &["text"]),
        model("deepseek-flash", "DeepSeek V4.1 Flash", &["text", "image"]),
    ]
}

/// The provider refused the key (HTTP 401). Any other failure is an ordinary error.
#[derive(Debug)]
pub struct KeyRejected;

impl std::fmt::Display for KeyRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DeepSeek did not accept the API key")
    }
}

impl std::error::Error for KeyRejected {}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<DeepSeekModel>,
}

#[derive(Clone, Deserialize, Serialize)]
struct CachedCatalog {
    version: u32,
    fetched_at: u64,
    models: Vec<DeepSeekModel>,
}

impl CachedCatalog {
    fn fresh_at(&self, now: u64) -> bool {
        // A clock adjustment must not leave a future-dated cache fresh forever.
        now.checked_sub(self.fetched_at)
            .is_some_and(|age| age < CACHE_TTL.as_secs())
    }
}

/// The last fetched list, without a network request and whatever its age.
pub fn read_cached_models(cache_path: &Path) -> Result<Vec<DeepSeekModel>> {
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
) -> Result<Vec<DeepSeekModel>> {
    refresh_models_from(client, cache_path, api_key, force, DEEPSEEK_MODELS_URL).await
}

async fn refresh_models_from(
    client: &reqwest::Client,
    cache_path: &Path,
    api_key: &str,
    force: bool,
    models_url: &str,
) -> Result<Vec<DeepSeekModel>> {
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
                tracing::warn!(%error, "could not persist DeepSeek model list");
            }
            Ok(cache.models)
        }
        Err(error) if force => Err(error),
        Err(error) => match cached {
            Some(cache) => {
                tracing::warn!(%error, "DeepSeek model list refresh failed; using cached models");
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
) -> Result<Vec<DeepSeekModel>> {
    let mut response = client
        .get(models_url)
        .bearer_auth(api_key)
        .timeout(FETCH_TIMEOUT)
        .send()
        .await
        // The request carries the key; keep the error to what went wrong, not what was sent.
        .map_err(|error| anyhow::anyhow!("fetch DeepSeek model list: {}", error.without_url()))?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err(KeyRejected.into());
    }
    ensure!(
        response.status().is_success(),
        "DeepSeek model list request failed (HTTP {})",
        response.status().as_u16()
    );
    if response
        .content_length()
        .is_some_and(|len| len > MAX_CATALOG_BYTES as u64)
    {
        bail!("DeepSeek model list exceeds size limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| anyhow::anyhow!("read DeepSeek model list: {}", error.without_url()))?
    {
        ensure!(
            bytes.len().saturating_add(chunk.len()) <= MAX_CATALOG_BYTES,
            "DeepSeek model list exceeds size limit"
        );
        bytes.extend_from_slice(&chunk);
    }
    let response: ModelsResponse =
        serde_json::from_slice(&bytes).context("invalid DeepSeek model list")?;
    normalize_models(response.data)
}

fn normalize_models(models: Vec<DeepSeekModel>) -> Result<Vec<DeepSeekModel>> {
    let mut unique = BTreeMap::new();
    for mut model in models {
        if model.id.is_empty() || model.id.chars().any(char::is_whitespace) {
            continue;
        }
        if model.name.is_empty() {
            model.name = model.id.clone();
        }
        unique.insert(model.id.clone(), model);
    }
    ensure!(!unique.is_empty(), "DeepSeek returned no models");
    Ok(unique.into_values().collect())
}

fn read_cache(cache_path: &Path) -> Result<CachedCatalog> {
    let file = std::fs::File::open(cache_path).context("open DeepSeek model cache")?;
    ensure!(
        file.metadata()?.len() <= MAX_CATALOG_BYTES as u64,
        "DeepSeek model cache exceeds size limit"
    );
    let mut cache: CachedCatalog =
        serde_json::from_reader(BufReader::new(file)).context("invalid DeepSeek model cache")?;
    ensure!(
        cache.version == CACHE_VERSION,
        "unsupported DeepSeek model cache version"
    );
    cache.models = normalize_models(cache.models)?;
    Ok(cache)
}

fn write_cache(cache_path: &Path, cache: &CachedCatalog) -> Result<()> {
    let parent = cache_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).context("create DeepSeek model cache directory")?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(temporary.as_file_mut(), cache)?;
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(cache_path)
        .context("replace DeepSeek model cache")?;
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
        let url = format!("http://{}/models", listener.local_addr().unwrap());
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

    /// The documented response, with a model this build has never heard of.
    fn listing() -> String {
        serde_json::json!({"object": "list", "data": [
            {"id": "deepseek-flash", "object": "model", "owned_by": "deepseek", "name": "DeepSeek-V4.1-Flash",
             "context_window": 1048576, "max_output_tokens": 393216,
             "input_modalities": ["text", "image"], "output_modalities": ["text"],
             "effort": {"supported_levels": ["low", "high", "max"], "default_level": "high"},
             "api_capabilities": {"anthropic_messages": {"system_prompt_update": "in-history"}}},
            {"id": "deepseek-next", "object": "model", "owned_by": "deepseek",
             "context_window": 2000000, "input_modalities": ["text"], "effort": null},
            {"id": "", "object": "model"}
        ]})
        .to_string()
    }

    #[tokio::test]
    async fn the_list_is_fetched_with_the_key_and_cached_without_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deepseek-models.json");
        let (url, server) = serve_once(200, listing()).await;
        let models = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "sk-fixture-secret",
            true,
            &url,
        )
        .await
        .unwrap();
        let request = server.await.unwrap().to_lowercase();
        assert!(request.contains("authorization: bearer sk-fixture-secret"));

        let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["deepseek-flash", "deepseek-next"]);
        let flash = models.first().unwrap();
        assert_eq!(flash.catalog_id(), "deepseek/deepseek-flash");
        assert_eq!(flash.supports_images(), Some(true));
        assert_eq!(flash.effort.default_level.as_deref(), Some("high"));
        // A model released after this build needs no code change.
        let next = models.get(1).unwrap();
        assert_eq!(next.name, "deepseek-next");
        assert_eq!(next.context_window(), 2_000_000);
        assert_eq!(next.supports_images(), Some(false));
        assert!(next.effort.supported_levels.is_empty());

        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(!saved.contains("sk-fixture-secret"));
        // Fresh: no request is made, so the unreachable address is never used.
        let again = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "sk-fixture-secret",
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
        let path = dir.path().join("deepseek-models.json");
        let body = r#"{"error":{"message":"Authentication Fails, Your api key: ****cret is invalid","type":"authentication_error","param":null,"code":"invalid_request_error"}}"#;
        let (url, server) = serve_once(401, body.into()).await;
        let error = refresh_models_from(&reqwest::Client::new(), &path, "sk-secret", true, &url)
            .await
            .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_some());
        assert!(!path.exists());

        let (url, server) = serve_once(503, "{}".into()).await;
        let error = refresh_models_from(&reqwest::Client::new(), &path, "sk-secret", true, &url)
            .await
            .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_none());
        assert!(!format!("{error:#}").contains("sk-secret"));
    }

    #[tokio::test]
    async fn a_failed_automatic_refresh_keeps_the_stale_list() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deepseek-models.json");
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
        let models = refresh_models_from(&reqwest::Client::new(), &path, "sk-secret", false, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(models.len(), builtin_models().len());
    }

    #[test]
    fn the_builtin_list_names_both_models_and_what_they_read() {
        let models = builtin_models();
        let pro = models.iter().find(|m| m.id == "deepseek-v4-pro").unwrap();
        assert_eq!(pro.supports_images(), Some(false));
        assert_eq!(pro.context_window(), 1_048_576);
        let flash = models.iter().find(|m| m.id == "deepseek-flash").unwrap();
        assert_eq!(flash.supports_images(), Some(true));
    }
}
