use serde::{Deserialize, Serialize};

use crate::error::VoiceError;

/// Default STT capture rate (Hz). Shared with the `__mic-capture` helper's argv default so parent and child agree when `--rate` is omitted.
pub const DEFAULT_SAMPLE_RATE: u32 = 16_000;

/// OpenRouter speech-to-text model used when none is configured (`[ui].voice_stt_model` / `[voice].model`).
/// Any slug from `https://openrouter.ai/api/v1/models?output_modalities=transcription` works.
pub const DEFAULT_OPENROUTER_STT_MODEL: &str = "openai/gpt-4o-mini-transcribe";

/// OpenRouter API root; transcription posts to `{base}/audio/transcriptions`.
pub const DEFAULT_OPENROUTER_API_BASE: &str = "https://openrouter.ai/api/v1";

/// Which speech-to-text service dictation uses.
#[derive(Debug, Clone, Copy, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum VoiceProvider {
    /// OpenRouter's `/audio/transcriptions` with a configurable model, billed to the OpenRouter key.
    #[default]
    #[serde(rename = "openrouter")]
    OpenRouter,
    /// xAI streaming STT (`wss://api.x.ai/v1/stt`), which needs an xAI credential.
    Xai,
}

impl VoiceProvider {
    /// The value stored in `config.toml`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenRouter => "openrouter",
            Self::Xai => "xai",
        }
    }

    /// Parses a stored value, ignoring case and separators; `None` for anything unrecognized.
    pub fn parse(value: &str) -> Option<Self> {
        match value
            .trim()
            .to_ascii_lowercase()
            .replace(['_', '-', ' '], "")
            .as_str()
        {
            "openrouter" => Some(Self::OpenRouter),
            // xAI account sign-in is not supported, so a stored `xai` falls back to OpenRouter.
            _ => None,
        }
    }

    /// A stored value, with blank and unknown values falling back to the default provider.
    pub fn canonical(value: Option<&str>) -> Self {
        value.and_then(Self::parse).unwrap_or_default()
    }
}

impl<'de> Deserialize<'de> for VoiceProvider {
    /// Lenient so a typo in `[voice].provider` falls back to the default instead of discarding the whole `[voice]` table.
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Ok(Self::canonical(Some(&raw)))
    }
}

/// The OpenRouter model slug to use: the trimmed value, or [`DEFAULT_OPENROUTER_STT_MODEL`] when blank.
pub fn canonical_stt_model(value: Option<&str>) -> String {
    non_empty_str(value)
        .unwrap_or(DEFAULT_OPENROUTER_STT_MODEL)
        .to_owned()
}

/// Prefer https `api_base` (same shape as chat). [`Self::stt_ws_url`] derives `wss://`. When `[voice].api_base` is unset,
/// inherits `[endpoints].xai_api_base_url` so enterprise proxies need no second knob.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct VoiceConfig {
    /// HTTPS API root (or bare host).
    /// Bases may end in `/v1` or `/xai/v1`; the default STT path de-duplicates a leading `v1/` so both become `…/v1/stt`.
    pub api_base: String,
    pub stt_ws_path: String,
    /// Preferred STT language (catalog code or `"auto"`). [`crate::language_for_api`] resolves it at connect time.
    pub language: String,
    pub sample_rate: u32,
    pub stt_endpointing_ms: u32,
    pub stt_interim_results: bool,
    /// Speech-to-text service. `[ui].voice_stt_provider` (written by the settings UIs) overrides `[voice].provider`.
    pub provider: VoiceProvider,
    /// OpenRouter transcription model slug. `[ui].voice_stt_model` overrides `[voice].model`.
    pub model: String,
    /// OpenRouter API root (HTTPS). Independent of `api_base`, which is the xAI endpoint.
    pub openrouter_api_base: String,

    /// The pager stamps this request identity; `serde(skip)` keeps user config from setting it.
    #[serde(skip)]
    pub client_identifier: String,
    #[serde(skip)]
    pub user_agent: String,
}

impl Default for VoiceConfig {
    fn default() -> Self {
        Self {
            api_base: "https://api.x.ai".into(),
            stt_ws_path: "/v1/stt".into(),
            language: "en".into(),
            sample_rate: DEFAULT_SAMPLE_RATE,
            stt_endpointing_ms: 400,
            stt_interim_results: true,
            provider: VoiceProvider::default(),
            model: DEFAULT_OPENROUTER_STT_MODEL.into(),
            openrouter_api_base: DEFAULT_OPENROUTER_API_BASE.into(),
            client_identifier: String::new(),
            user_agent: String::new(),
        }
    }
}

impl VoiceConfig {
    /// Streaming STT WebSocket URL. Rejects plaintext `http://` / `ws://`.
    pub fn stt_ws_url(&self) -> Result<String, VoiceError> {
        ws_url(&self.api_base, &self.stt_ws_path)
    }

    /// `api_base`: non-empty `[voice].api_base`, else `[endpoints].xai_api_base_url` from `root`, else `resolved_endpoints_base`, else the default.
    ///
    /// `resolved_endpoints_base` carries the caller's env/CLI overrides; it ranks below the raw table so config keeps beating env (shell precedence).
    pub fn from_config_table(root: &toml::Table, resolved_endpoints_base: Option<&str>) -> Self {
        let voice_table = root.get("voice").and_then(|v| v.as_table());
        let mut cfg: Self = voice_table
            .and_then(|t| toml::Value::Table(t.clone()).try_into().ok())
            .unwrap_or_default();

        // Read `[voice].api_base` from the raw table, not `cfg`: serde default makes "unset" and an explicit `https://api.x.ai` indistinguishable
        cfg.api_base = non_empty_str(
            voice_table
                .and_then(|t| t.get("api_base"))
                .and_then(|v| v.as_str()),
        )
        .or_else(|| {
            non_empty_str(
                root.get("endpoints")
                    .and_then(|e| e.get("xai_api_base_url"))
                    .and_then(|v| v.as_str()),
            )
        })
        .or_else(|| non_empty_str(resolved_endpoints_base))
        .map(|base| base.trim_end_matches('/').to_owned())
        .unwrap_or_else(|| Self::default().api_base);
        cfg.model = canonical_stt_model(Some(&cfg.model));
        cfg.openrouter_api_base = non_empty_str(Some(&cfg.openrouter_api_base))
            .unwrap_or(DEFAULT_OPENROUTER_API_BASE)
            .trim_end_matches('/')
            .to_owned();
        // The settings UIs (TUI and desktop) persist to `[ui]`, which wins over the hand-edited `[voice]` table
        let ui = root.get("ui").and_then(|v| v.as_table());
        if let Some(provider) = ui
            .and_then(|t| t.get("voice_stt_provider"))
            .and_then(|v| v.as_str())
            .and_then(VoiceProvider::parse)
        {
            cfg.provider = provider;
        }
        if let Some(model) = non_empty_str(
            ui.and_then(|t| t.get("voice_stt_model"))
                .and_then(|v| v.as_str()),
        ) {
            cfg.model = model.to_owned();
        }
        cfg
    }

    /// OpenRouter transcription endpoint. Rejects plaintext `http://` so the API key never travels unencrypted.
    pub fn openrouter_transcriptions_url(&self) -> Result<String, VoiceError> {
        let base = self.openrouter_api_base.trim().trim_end_matches('/');
        if strip_scheme(base, "http://").is_some() {
            return Err(VoiceError::Config(format!(
                "insecure voice openrouter_api_base {base:?}: voice requires an https:// endpoint. \
                 Refusing to send the API key over a plaintext connection."
            )));
        }
        let rest = strip_scheme(base, "https://").unwrap_or(base);
        Ok(format!("https://{rest}/audio/transcriptions"))
    }
}

fn non_empty_str(s: Option<&str>) -> Option<&str> {
    s.map(str::trim).filter(|s| !s.is_empty())
}

/// `strip_prefix` ignoring ASCII case: RFC 3986 schemes are case-insensitive.
/// `HTTP://` must hit the plaintext rejection and `HTTPS://` must work.
fn strip_scheme<'a>(s: &'a str, scheme: &str) -> Option<&'a str> {
    s.get(..scheme.len())
        .filter(|p| p.eq_ignore_ascii_case(scheme))
        .and_then(|_| s.get(scheme.len()..))
}

fn ws_url(api_base: &str, path: &str) -> Result<String, VoiceError> {
    let base = api_base.trim().trim_end_matches('/');
    let path = path.trim().trim_start_matches('/');
    if strip_scheme(base, "http://").is_some() || strip_scheme(base, "ws://").is_some() {
        return Err(VoiceError::Config(format!(
            "insecure voice api_base {api_base:?}: voice requires a TLS endpoint \
             (https:// / wss://). Refusing to send the bearer token over a \
             plaintext connection."
        )));
    }
    let rest = strip_scheme(base, "https://")
        .or_else(|| strip_scheme(base, "wss://"))
        .unwrap_or(base);
    // The default path is `/v1/stt`; bases often end in `/v1` or `/xai/v1`
    let path = match (rest.ends_with("/v1"), path.strip_prefix("v1/")) {
        (true, Some(rest_path)) => rest_path,
        _ => path,
    };
    Ok(format!("wss://{rest}/{path}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_stt_ws_uses_wss() {
        assert_eq!(
            VoiceConfig::default().stt_ws_url().unwrap(),
            "wss://api.x.ai/v1/stt"
        );
    }

    #[test]
    fn scheme_less_and_wss_bases() {
        for base in ["api.x.ai", "wss://api.x.ai", "HTTPS://api.x.ai"] {
            let cfg = VoiceConfig {
                api_base: base.into(),
                ..VoiceConfig::default()
            };
            assert_eq!(cfg.stt_ws_url().unwrap(), "wss://api.x.ai/v1/stt");
        }
    }

    #[test]
    fn v1_base_dedupes_default_path() {
        let cfg = VoiceConfig {
            api_base: "https://proxy.example.com/v1".into(),
            ..VoiceConfig::default()
        };
        assert_eq!(cfg.stt_ws_url().unwrap(), "wss://proxy.example.com/v1/stt");
    }

    #[test]
    fn xai_v1_base_preserves_prefix() {
        let cfg = VoiceConfig {
            api_base: "https://proxy.example.com/xai/v1".into(),
            ..VoiceConfig::default()
        };
        assert_eq!(
            cfg.stt_ws_url().unwrap(),
            "wss://proxy.example.com/xai/v1/stt"
        );
    }

    #[test]
    fn rejects_plaintext_bases() {
        for base in [
            "http://localhost:8080",
            "ws://localhost:8080",
            "HTTP://localhost:8080",
            "Ws://localhost:8080",
        ] {
            let cfg = VoiceConfig {
                api_base: base.into(),
                ..VoiceConfig::default()
            };
            assert!(matches!(cfg.stt_ws_url(), Err(VoiceError::Config(_))));
        }
    }

    #[test]
    fn inherits_endpoints_when_voice_api_base_unset() {
        let table: toml::Table = toml::from_str(
            r#"
[endpoints]
xai_api_base_url = "https://proxy.example.com/xai/v1"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.api_base, "https://proxy.example.com/xai/v1");
        assert_eq!(
            cfg.stt_ws_url().unwrap(),
            "wss://proxy.example.com/xai/v1/stt"
        );
    }

    #[test]
    fn empty_voice_api_base_still_inherits_endpoints() {
        let table: toml::Table = toml::from_str(
            r#"
[endpoints]
xai_api_base_url = "https://proxy.example.com/xai/v1"
[voice]
api_base = "  "
language = "fr"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.api_base, "https://proxy.example.com/xai/v1");
        assert_eq!(cfg.language, "fr");
    }

    #[test]
    fn whitespace_voice_api_base_without_endpoints_uses_default() {
        let table: toml::Table = toml::from_str(
            r#"
[voice]
api_base = "  "
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.api_base, VoiceConfig::default().api_base);
        assert_eq!(cfg.stt_ws_url().unwrap(), "wss://api.x.ai/v1/stt");
    }

    #[test]
    fn resolved_endpoints_base_used_when_table_has_none() {
        let cfg = VoiceConfig::from_config_table(
            &toml::Table::new(),
            Some("https://proxy.example.com/v1/"),
        );
        assert_eq!(cfg.api_base, "https://proxy.example.com/v1");
        assert_eq!(cfg.stt_ws_url().unwrap(), "wss://proxy.example.com/v1/stt");

        // Whitespace-only resolved base falls through to the default.
        let cfg = VoiceConfig::from_config_table(&toml::Table::new(), Some("  "));
        assert_eq!(cfg.api_base, VoiceConfig::default().api_base);
    }

    /// config.toml beats the env/CLI fallback, matching the shell's endpoints precedence.
    #[test]
    fn table_endpoints_beat_resolved_endpoints_base() {
        let table: toml::Table = toml::from_str(
            r#"
[endpoints]
xai_api_base_url = "https://config.example.com"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, Some("https://env.example.com"));
        assert_eq!(cfg.api_base, "https://config.example.com");
    }

    #[test]
    fn voice_api_base_overrides_endpoints() {
        let table: toml::Table = toml::from_str(
            r#"
[endpoints]
xai_api_base_url = "https://proxy.example.com/xai/v1"
[voice]
api_base = "https://api.x.ai"
language = "es"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.api_base, "https://api.x.ai");
        assert_eq!(cfg.language, "es");
        assert_eq!(cfg.stt_ws_url().unwrap(), "wss://api.x.ai/v1/stt");
    }

    #[test]
    fn defaults_to_openrouter_with_default_model() {
        let cfg = VoiceConfig::from_config_table(&toml::Table::new(), None);
        assert_eq!(cfg.provider, VoiceProvider::OpenRouter);
        assert_eq!(cfg.model, DEFAULT_OPENROUTER_STT_MODEL);
        assert_eq!(
            cfg.openrouter_transcriptions_url().unwrap(),
            "https://openrouter.ai/api/v1/audio/transcriptions"
        );
    }

    #[test]
    fn ui_provider_and_model_override_voice_table() {
        let table: toml::Table = toml::from_str(
            r#"
[voice]
provider = "openrouter"
model = "openai/whisper-1"
language = "fr"
[ui]
voice_stt_provider = "xai"
voice_stt_model = "  mistralai/voxtral-mini-transcribe "
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.provider, VoiceProvider::OpenRouter);
        assert_eq!(cfg.model, "mistralai/voxtral-mini-transcribe");
        assert_eq!(cfg.language, "fr");
    }

    #[test]
    fn voice_table_provider_and_model_apply_without_ui() {
        let table: toml::Table = toml::from_str(
            r#"
[voice]
provider = "xai"
model = "openai/whisper-1"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.provider, VoiceProvider::OpenRouter);
        assert_eq!(cfg.model, "openai/whisper-1");
    }

    #[test]
    fn unknown_provider_keeps_rest_of_voice_table() {
        let table: toml::Table = toml::from_str(
            r#"
[voice]
provider = "whisper-local"
model = ""
language = "de"
openrouter_api_base = "https://proxy.example.com/api/v1/"
[ui]
voice_stt_provider = "nonsense"
voice_stt_model = " "
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.provider, VoiceProvider::OpenRouter);
        assert_eq!(cfg.model, DEFAULT_OPENROUTER_STT_MODEL);
        assert_eq!(cfg.language, "de");
        assert_eq!(
            cfg.openrouter_transcriptions_url().unwrap(),
            "https://proxy.example.com/api/v1/audio/transcriptions"
        );
    }

    #[test]
    fn provider_parse_accepts_aliases() {
        assert_eq!(
            VoiceProvider::parse("OpenRouter"),
            Some(VoiceProvider::OpenRouter)
        );
        assert_eq!(
            VoiceProvider::parse("open_router"),
            Some(VoiceProvider::OpenRouter)
        );
        assert_eq!(VoiceProvider::parse(" XAI "), None);
        assert_eq!(VoiceProvider::parse("grok"), None);
        assert_eq!(VoiceProvider::parse("other"), None);
        assert_eq!(VoiceProvider::canonical(None), VoiceProvider::OpenRouter);
    }

    #[test]
    fn rejects_plaintext_openrouter_base() {
        let cfg = VoiceConfig {
            openrouter_api_base: "HTTP://localhost:8080/api/v1".into(),
            ..VoiceConfig::default()
        };
        assert!(matches!(
            cfg.openrouter_transcriptions_url(),
            Err(VoiceError::Config(_))
        ));
    }

    #[test]
    fn ignores_unknown_and_identity_fields() {
        let table: toml::Table = toml::from_str(
            r#"
[voice]
enabled = false
client_identifier = "spoofed"
user_agent = "malicious/9.9"
language = "es"
"#,
        )
        .unwrap();
        let cfg = VoiceConfig::from_config_table(&table, None);
        assert_eq!(cfg.language, "es");
        assert!(cfg.client_identifier.is_empty());
        assert!(cfg.user_agent.is_empty());
    }
}
