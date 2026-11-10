//! Meta Model API's model list. Cache metadata, never credentials.
//!
//! `GET /v1/models` needs the account's key. Its entries may name only an id, so
//! what this build knows about a model fills in the rest; the built-in list stands
//! in until the first successful fetch.
//! See https://dev.meta.ai/docs/models and https://dev.meta.ai/docs/quickstart.

use std::collections::{HashMap, HashSet};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const META_BASE_URL: &str = "https://api.meta.ai/v1";
pub const META_MODELS_URL: &str = "https://api.meta.ai/v1/models";
pub const CACHE_TTL: Duration = Duration::from_secs(60 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CATALOG_BYTES: usize = 1024 * 1024;
const CACHE_VERSION: u32 = 1;
/// Every reasoning model on the API shares this window.
const DEFAULT_CONTEXT_WINDOW: u64 = 1_048_576;
/// The output ceiling the API documents for Muse Spark.
const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 131_072;
/// `reasoning_effort` values, lowest first. `none` is not one: the reasoning models refuse it.
const EFFORT_LEVELS: [&str; 6] = ["minimal", "low", "medium", "high", "xhigh", "max"];

// Model resolution is synchronous and frequent, so keep the parsed list in memory.
static MEMORY_CACHE: LazyLock<Mutex<HashMap<PathBuf, CachedCatalog>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct MetaEffort {
    /// The `reasoning_effort` values the model accepts, in display order.
    #[serde(default)]
    pub supported_levels: Vec<String>,
    pub default_level: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct MetaModel {
    /// The id sent on the wire, e.g. `muse-spark-1.3`.
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub context_window: Option<u64>,
    pub max_output_tokens: Option<u64>,
    #[serde(default)]
    pub input_modalities: Vec<String>,
    #[serde(default)]
    pub effort: MetaEffort,
}

impl MetaModel {
    /// Namespaced local picker ID; send `id`, not this value, to Meta.
    pub fn catalog_id(&self) -> String {
        format!("meta/{}", self.id)
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

    /// One entry of `GET /v1/models`, which may describe only the id.
    /// What the list leaves out is filled from the built-in entry for a model this build knows.
    fn from_listing(entry: &Value) -> Option<Self> {
        let id = entry.get("id")?.as_str()?.to_owned();
        let text = |path: &[&str]| {
            path.iter()
                .try_fold(entry, |node, key| node.get(key))?
                .as_str()
                .filter(|text| !text.is_empty())
                .map(str::to_owned)
        };
        let number = |path: &[&str]| {
            path.iter()
                .try_fold(entry, |node, key| node.get(key))?
                .as_u64()
                .filter(|n| *n > 0)
        };
        let name = text(&["name"])
            .or_else(|| text(&["display_name"]))
            .unwrap_or_default();
        let context_window = number(&["context_window"]).or_else(|| number(&["context_length"]));
        let max_output_tokens = number(&["max_output_tokens"])
            .or_else(|| number(&["max_completion_tokens"]))
            .or_else(|| number(&["max_tokens"]));
        let input_modalities = entry
            .get("input_modalities")
            .or_else(|| entry.pointer("/architecture/input_modalities"))
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let effort = meta_effort(entry);

        let mut model = Self {
            id: id.clone(),
            name,
            context_window,
            max_output_tokens,
            input_modalities,
            effort,
        };
        if let Some(known) = builtin_models().into_iter().find(|known| known.id == id) {
            if model.name.is_empty() {
                model.name = known.name;
            }
            model.context_window = model.context_window.or(known.context_window);
            model.max_output_tokens = model.max_output_tokens.or(known.max_output_tokens);
            if model.input_modalities.is_empty() {
                model.input_modalities = known.input_modalities;
            }
            if model.effort.supported_levels.is_empty() {
                model.effort = known.effort;
            }
        }
        if model.name.is_empty() {
            model.name = model.id.clone();
        }
        Some(model)
    }
}

/// The effort levels a listing names, under any of the shapes the API and compatible
/// catalogs use. An entry that names none leaves the field empty.
fn meta_effort(entry: &Value) -> MetaEffort {
    let object = entry
        .get("effort")
        .or_else(|| entry.get("reasoning_effort"))
        .filter(|value| value.is_object());
    let levels = entry
        .get("reasoning_efforts")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(|value| match value {
                    Value::String(level) => Some(level.clone()),
                    Value::Object(map) => map
                        .get("value")
                        .or_else(|| map.get("id"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    _ => None,
                })
                .collect::<Vec<_>>()
        })
        .or_else(|| {
            object
                .and_then(|effort| {
                    effort
                        .get("supported_levels")
                        .or_else(|| effort.get("supported_efforts"))
                })
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
        })
        .unwrap_or_default();
    let default_level = object
        .and_then(|effort| {
            effort
                .get("default_level")
                .or_else(|| effort.get("default_effort"))
        })
        .and_then(Value::as_str)
        .filter(|level| !level.is_empty())
        .map(str::to_owned);
    MetaEffort {
        supported_levels: levels
            .into_iter()
            .filter(|level| EFFORT_LEVELS.contains(&level.as_str()))
            .collect(),
        default_level,
    }
}

/// The models Meta serves as of this build, for use before the account's own list is fetched.
pub fn builtin_models() -> Vec<MetaModel> {
    let modalities = ["text", "image", "video", "audio", "pdf"];
    let model = |id: &str, name: &str, levels: &[&str], default: &str| MetaModel {
        id: id.into(),
        name: name.into(),
        context_window: Some(DEFAULT_CONTEXT_WINDOW),
        max_output_tokens: Some(DEFAULT_MAX_OUTPUT_TOKENS),
        input_modalities: modalities.iter().map(|m| (*m).to_owned()).collect(),
        effort: MetaEffort {
            supported_levels: levels.iter().map(|level| (*level).to_owned()).collect(),
            default_level: Some(default.into()),
        },
    };
    // Muse Wonder is the most capable model and leads the picker, as the Claude API's Opus does.
    vec![
        model("muse-wonder-1.0", "Muse Wonder", &EFFORT_LEVELS, "max"),
        model("muse-spark-1.3", "Muse Spark 1.3", &EFFORT_LEVELS, "high"),
        model("muse-spark-1.2", "Muse Spark 1.2", &EFFORT_LEVELS, "high"),
        model("muse-spark-1.1", "Muse Spark 1.1", &EFFORT_LEVELS, "high"),
        // Contributor mode: `max` is not available; the model is otherwise Muse Spark 1.3 or 1.2.
        model(
            "muse-spark-1.3-contributor",
            "Muse Spark 1.3 Contributor",
            &EFFORT_LEVELS[..5],
            "high",
        ),
        model(
            "muse-spark-1.2-contributor",
            "Muse Spark 1.2 Contributor",
            &EFFORT_LEVELS[..5],
            "high",
        ),
        model("muse-ember-1.0", "Muse Ember", &EFFORT_LEVELS, "max"),
    ]
}

/// The provider refused the key (HTTP 401). Any other failure is an ordinary error.
#[derive(Debug)]
pub struct KeyRejected;

impl std::fmt::Display for KeyRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Meta did not accept the API key")
    }
}

impl std::error::Error for KeyRejected {}

#[derive(Deserialize)]
#[serde(untagged)]
enum ModelsResponse {
    /// What the OpenAI-compatible `GET /v1/models` returns.
    Wrapped { data: Vec<Value> },
    /// A bare list, should a compatible catalog serve one.
    Bare(Vec<Value>),
}

impl ModelsResponse {
    fn entries(self) -> Vec<Value> {
        match self {
            Self::Wrapped { data } => data,
            Self::Bare(data) => data,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
struct CachedCatalog {
    version: u32,
    fetched_at: u64,
    models: Vec<MetaModel>,
}

impl CachedCatalog {
    fn fresh_at(&self, now: u64) -> bool {
        // A clock adjustment must not leave a future-dated cache fresh forever.
        now.checked_sub(self.fetched_at)
            .is_some_and(|age| age < CACHE_TTL.as_secs())
    }
}

/// The last fetched list, without a network request and whatever its age.
pub fn read_cached_models(cache_path: &Path) -> Result<Vec<MetaModel>> {
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
) -> Result<Vec<MetaModel>> {
    refresh_models_from(client, cache_path, api_key, force, META_MODELS_URL).await
}

async fn refresh_models_from(
    client: &reqwest::Client,
    cache_path: &Path,
    api_key: &str,
    force: bool,
    models_url: &str,
) -> Result<Vec<MetaModel>> {
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
                tracing::warn!(%error, "could not persist Meta model list");
            }
            Ok(cache.models)
        }
        Err(error) if force => Err(error),
        Err(error) => match cached {
            Some(cache) => {
                tracing::warn!(%error, "Meta model list refresh failed; using cached models");
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
) -> Result<Vec<MetaModel>> {
    let mut response = client
        .get(models_url)
        .bearer_auth(api_key)
        .timeout(FETCH_TIMEOUT)
        .send()
        .await
        // The request carries the key; keep the error to what went wrong, not what was sent.
        .map_err(|error| anyhow::anyhow!("fetch Meta model list: {}", error.without_url()))?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err(KeyRejected.into());
    }
    ensure!(
        response.status().is_success(),
        "Meta model list request failed (HTTP {})",
        response.status().as_u16()
    );
    if response
        .content_length()
        .is_some_and(|len| len > MAX_CATALOG_BYTES as u64)
    {
        bail!("Meta model list exceeds size limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| anyhow::anyhow!("read Meta model list: {}", error.without_url()))?
    {
        ensure!(
            bytes.len().saturating_add(chunk.len()) <= MAX_CATALOG_BYTES,
            "Meta model list exceeds size limit"
        );
        bytes.extend_from_slice(&chunk);
    }
    let response: ModelsResponse =
        serde_json::from_slice(&bytes).context("invalid Meta model list")?;
    normalize_models(
        response
            .entries()
            .iter()
            .filter_map(MetaModel::from_listing)
            .collect(),
    )
}

/// Keeps the order the account's list gives them, which is the order the picker shows.
fn normalize_models(models: Vec<MetaModel>) -> Result<Vec<MetaModel>> {
    let mut seen = HashSet::new();
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
    ensure!(!models.is_empty(), "Meta returned no models");
    Ok(models)
}

fn read_cache(cache_path: &Path) -> Result<CachedCatalog> {
    let file = std::fs::File::open(cache_path).context("open Meta model cache")?;
    ensure!(
        file.metadata()?.len() <= MAX_CATALOG_BYTES as u64,
        "Meta model cache exceeds size limit"
    );
    let mut cache: CachedCatalog =
        serde_json::from_reader(BufReader::new(file)).context("invalid Meta model cache")?;
    ensure!(
        cache.version == CACHE_VERSION,
        "unsupported Meta model cache version"
    );
    cache.models = normalize_models(cache.models)?;
    Ok(cache)
}

fn write_cache(cache_path: &Path, cache: &CachedCatalog) -> Result<()> {
    let parent = cache_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).context("create Meta model cache directory")?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(temporary.as_file_mut(), cache)?;
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(cache_path)
        .context("replace Meta model cache")?;
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

    /// A listing that names one known model with full metadata, one bare, and one
    /// this build has never heard of.
    fn listing() -> String {
        serde_json::json!({"object": "list", "data": [
            {"id": "muse-spark-1.3", "object": "model", "owned_by": "meta",
             "context_window": 1048576, "max_output_tokens": 131072,
             "input_modalities": ["text", "image", "video", "audio", "pdf"],
             "effort": {"supported_levels": ["minimal", "low", "medium", "high", "xhigh", "max"],
                        "default_level": "high"}},
            {"id": "muse-wonder-1.0", "object": "model", "owned_by": "meta"},
            {"id": "muse-next-2.0", "object": "model", "owned_by": "meta",
             "context_window": 2000000, "reasoning_efforts": ["low", "high"]},
            {"id": "", "object": "model"}
        ]})
        .to_string()
    }

    #[tokio::test]
    async fn the_list_is_fetched_with_the_key_and_cached_without_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("meta-models.json");
        let (url, server) = serve_once(200, listing()).await;
        let models = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "LLM_1607358788850350_fixture",
            true,
            &url,
        )
        .await
        .unwrap();
        let request = server.await.unwrap().to_lowercase();
        assert!(request.contains("authorization: bearer llm_1607358788850350_fixture"));

        let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["muse-spark-1.3", "muse-wonder-1.0", "muse-next-2.0"]);
        let spark = models.first().unwrap();
        assert_eq!(spark.catalog_id(), "meta/muse-spark-1.3");
        assert_eq!(spark.context_window(), 1_048_576);
        assert_eq!(spark.max_output_tokens, Some(131_072));
        assert_eq!(spark.supports_images(), Some(true));
        assert_eq!(spark.effort.default_level.as_deref(), Some("high"));
        // A bare id keeps what this build knows of a current model.
        let wonder = models.get(1).unwrap();
        assert_eq!(wonder.name, "Muse Wonder");
        assert_eq!(wonder.effort.default_level.as_deref(), Some("max"));
        assert_eq!(wonder.effort.supported_levels.len(), EFFORT_LEVELS.len());
        // A model released after this build needs no code change.
        let next = models.get(2).unwrap();
        assert_eq!(next.name, "muse-next-2.0");
        assert_eq!(next.context_window(), 2_000_000);
        assert_eq!(next.effort.supported_levels, ["low", "high"]);
        assert_eq!(next.supports_images(), None);

        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(!saved.contains("LLM_1607358788850350_fixture"));
        // Fresh: no request is made, so the unreachable address is never used.
        let again = refresh_models_from(
            &reqwest::Client::new(),
            &path,
            "LLM_1607358788850350_fixture",
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
        let path = dir.path().join("meta-models.json");
        let body = r#"{"error":{"message":"Unauthorized","type":"authentication_error","param":null,"code":"invalid_api_key"}}"#;
        let (url, server) = serve_once(401, body.into()).await;
        let error = refresh_models_from(&reqwest::Client::new(), &path, "LLM_secret", true, &url)
            .await
            .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_some());
        assert!(!path.exists());

        let (url, server) = serve_once(503, "{}".into()).await;
        let error = refresh_models_from(&reqwest::Client::new(), &path, "LLM_secret", true, &url)
            .await
            .unwrap_err();
        server.await.unwrap();
        assert!(error.downcast_ref::<KeyRejected>().is_none());
        assert!(!format!("{error:#}").contains("LLM_secret"));
    }

    #[tokio::test]
    async fn a_failed_automatic_refresh_keeps_the_stale_list() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("meta-models.json");
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
        let models = refresh_models_from(&reqwest::Client::new(), &path, "LLM_secret", false, &url)
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(models.len(), builtin_models().len());
    }

    #[test]
    fn the_builtin_list_leads_with_muse_wonder_and_names_every_effort() {
        let models = builtin_models();
        assert_eq!(models.first().unwrap().id, "muse-wonder-1.0");
        let spark = models.iter().find(|m| m.id == "muse-spark-1.3").unwrap();
        assert_eq!(spark.effort.supported_levels, EFFORT_LEVELS);
        assert_eq!(spark.effort.default_level.as_deref(), Some("high"));
        let contributor = models
            .iter()
            .find(|m| m.id == "muse-spark-1.3-contributor")
            .unwrap();
        assert!(
            !contributor
                .effort
                .supported_levels
                .iter()
                .any(|l| l == "max")
        );
        assert!(models.iter().all(|m| m.supports_images() == Some(true)));
    }

    #[test]
    fn a_listing_without_metadata_keeps_what_is_known_of_a_current_model() {
        let listed = |entry: serde_json::Value| MetaModel::from_listing(&entry).unwrap();
        let wonder = listed(serde_json::json!({"id": "muse-wonder-1.0"}));
        assert_eq!(wonder.name, "Muse Wonder");
        assert_eq!(wonder.context_window(), DEFAULT_CONTEXT_WINDOW);
        assert_eq!(wonder.max_output_tokens, Some(DEFAULT_MAX_OUTPUT_TOKENS));
        assert_eq!(wonder.effort.default_level.as_deref(), Some("max"));
        // What the listing does say wins.
        let described = listed(serde_json::json!({
            "id": "muse-wonder-1.0", "name": "Wonder preview", "context_length": 2000000,
            "reasoning_effort": {"supported_levels": ["low", "high"], "default_level": "low"}
        }));
        assert_eq!(described.name, "Wonder preview");
        assert_eq!(described.context_window(), 2_000_000);
        assert_eq!(described.effort.supported_levels, ["low", "high"]);
        assert_eq!(described.effort.default_level.as_deref(), Some("low"));
        // A model this build has never heard of claims only what the listing says.
        let unknown = listed(serde_json::json!({"id": "muse-next-2.0"}));
        assert_eq!(unknown.name, "muse-next-2.0");
        assert_eq!(unknown.context_window(), DEFAULT_CONTEXT_WINDOW);
        assert_eq!(unknown.max_output_tokens, None);
        assert_eq!(unknown.supports_images(), None);
        assert!(unknown.effort.supported_levels.is_empty());
    }
}
