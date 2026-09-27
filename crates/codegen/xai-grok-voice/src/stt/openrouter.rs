//! OpenRouter speech-to-text: `POST {base}/audio/transcriptions` with base64 WAV audio.
//!
//! Unlike xAI's streaming socket this is a request per utterance, so the pipeline cuts the mic stream into
//! segments at pauses (see [`crate::segment`]) and transcribes each one as it closes.

use std::time::Duration;

use base64::Engine as _;
use serde::Deserialize;

use crate::config::VoiceConfig;
use crate::error::VoiceError;

/// OpenRouter documents a 60 s limit for transcription requests.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

/// A reusable client for one voice session's config.
#[derive(Clone)]
pub struct OpenRouterTranscriber {
    client: reqwest::Client,
    url: String,
    model: String,
    language: &'static str,
    sample_rate: u32,
    user_agent: String,
}

impl std::fmt::Debug for OpenRouterTranscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenRouterTranscriber")
            .field("url", &self.url)
            .field("model", &self.model)
            .finish_non_exhaustive()
    }
}

#[derive(Deserialize)]
struct TranscriptionResponse {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct ErrorEnvelope {
    error: ErrorBody,
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    message: String,
}

impl OpenRouterTranscriber {
    pub fn new(config: &VoiceConfig) -> Result<Self, VoiceError> {
        let url = config.openrouter_transcriptions_url()?;
        let client = xai_grok_extra_ca::build_reqwest_client(|builder| {
            builder
                .timeout(REQUEST_TIMEOUT)
                .connect_timeout(Duration::from_secs(15))
        })
        .map_err(|e| VoiceError::Config(format!("HTTP client: {e}")))?;
        Ok(Self {
            client,
            url,
            model: crate::config::canonical_stt_model(Some(&config.model)),
            language: crate::language_for_api(&config.language),
            sample_rate: config.sample_rate,
            user_agent: config.user_agent.clone(),
        })
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    /// Transcribe one utterance of 16-bit little-endian mono PCM at the configured sample rate.
    pub async fn transcribe(&self, bearer: &str, pcm: &[u8]) -> Result<String, VoiceError> {
        let wav = pcm16_wav(pcm, self.sample_rate);
        let body = request_body(&self.model, self.language, &wav);
        let mut request = self
            .client
            .post(&self.url)
            .bearer_auth(bearer)
            .header("X-Title", "Crok Build")
            .json(&body);
        if !self.user_agent.is_empty() {
            request = request.header(reqwest::header::USER_AGENT, &self.user_agent);
        }
        let response = request.send().await.map_err(|e| {
            if e.is_timeout() {
                VoiceError::Stt("OpenRouter transcription timed out".into())
            } else {
                VoiceError::Stt(format!("OpenRouter request failed: {e}"))
            }
        })?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| VoiceError::Stt(format!("OpenRouter response: {e}")))?;
        parse_response(status.as_u16(), &text, &self.model)
    }
}

/// The JSON request OpenRouter accepts: the model slug, base64 audio with its container format, and the language hint.
fn request_body(model: &str, language: &str, wav: &[u8]) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "input_audio": {
            "data": base64::engine::general_purpose::STANDARD.encode(wav),
            "format": "wav",
        },
        "language": language,
    })
}

fn parse_response(status: u16, body: &str, model: &str) -> Result<String, VoiceError> {
    if (200..300).contains(&status) {
        return serde_json::from_str::<TranscriptionResponse>(body)
            .map(|r| r.text.trim().to_owned())
            .map_err(|e| VoiceError::Stt(format!("OpenRouter response parse error: {e}")));
    }
    let message = serde_json::from_str::<ErrorEnvelope>(body)
        .ok()
        .map(|e| e.error.message)
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| format!("HTTP {status}"));
    Err(VoiceError::Stt(match status {
        401 => format!(
            "OpenRouter rejected the API key ({message}); run `crok login openrouter` or set OPENROUTER_API_KEY"
        ),
        402 => format!("OpenRouter: {message} (add credits to use transcription)"),
        400 | 404 if message.contains(model) => format!(
            "OpenRouter: {message}. Pick a transcription model in settings (Voice model)"
        ),
        _ => format!("OpenRouter: {message}"),
    }))
}

/// Wrap PCM16LE mono samples in a minimal RIFF/WAVE header.
pub fn pcm16_wav(pcm: &[u8], sample_rate: u32) -> Vec<u8> {
    let data_len = u32::try_from(pcm.len()).unwrap_or(u32::MAX);
    let channels: u16 = 1;
    let bits: u16 = 16;
    let block_align = channels * bits / 8;
    let byte_rate = sample_rate * u32::from(block_align);
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&data_len.saturating_add(36).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

#[cfg(test)]
#[allow(clippy::indexing_slicing)] // fixed-offset header checks on a buffer the test just built
mod tests {
    use super::*;

    #[test]
    fn wav_header_describes_pcm16_mono() {
        let pcm = [1u8, 0, 2, 0, 3, 0];
        let wav = pcm16_wav(&pcm, 16_000);
        assert_eq!(wav.len(), 44 + pcm.len());
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 36 + 6);
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(u16::from_le_bytes(wav[22..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u32::from_le_bytes(wav[28..32].try_into().unwrap()), 32_000);
        assert_eq!(u16::from_le_bytes(wav[34..36].try_into().unwrap()), 16);
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 6);
        assert_eq!(&wav[44..], &pcm);
    }

    #[test]
    fn request_body_carries_model_audio_and_language() {
        let body = request_body("openai/whisper-1", "ja", b"RIFF");
        assert_eq!(body["model"], "openai/whisper-1");
        assert_eq!(body["input_audio"]["format"], "wav");
        assert_eq!(body["input_audio"]["data"], "UklGRg==");
        assert_eq!(body["language"], "ja");
    }

    #[test]
    fn parses_success_text() {
        let text = parse_response(
            200,
            r#"{"text":" Hello there. ","usage":{"cost":0.0001}}"#,
            "m",
        )
        .unwrap();
        assert_eq!(text, "Hello there.");
    }

    #[test]
    fn parses_error_envelope() {
        let err = parse_response(
            400,
            r#"{"error":{"message":"Model no/such-model does not exist","code":400}}"#,
            "no/such-model",
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("Model no/such-model does not exist"), "{err}");
        assert!(err.contains("Voice model"), "{err}");
    }

    #[test]
    fn unauthorized_suggests_login() {
        let err = parse_response(401, r#"{"error":{"message":"No auth"}}"#, "m")
            .unwrap_err()
            .to_string();
        assert!(err.contains("crok login openrouter"), "{err}");
    }

    #[test]
    fn non_json_error_falls_back_to_status() {
        let err = parse_response(503, "<html>", "m").unwrap_err().to_string();
        assert!(err.contains("HTTP 503"), "{err}");
    }

    /// Live check against OpenRouter (billed, so opt-in):
    /// `VOICE_TEST_WAV=clip.wav cargo test -p xai-grok-voice live_openrouter -- --ignored`
    /// The key comes from `OPENROUTER_API_KEY`, else `~/.grok/provider-auth/openrouter.json` (`grok login openrouter`).
    /// The clip must be 16 kHz mono PCM16 WAV (e.g. `afconvert -f WAVE -d LEI16@16000 -c 1 in.aiff clip.wav`).
    #[tokio::test]
    #[ignore = "calls the OpenRouter API"]
    async fn live_openrouter_transcription() {
        let key = std::env::var("OPENROUTER_API_KEY").unwrap_or_else(|_| {
            let path = std::path::Path::new(&std::env::var("HOME").unwrap())
                .join(".grok/provider-auth/openrouter.json");
            let stored: serde_json::Value =
                serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
            stored["access_token"].as_str().unwrap().to_owned()
        });
        let wav = std::fs::read(std::env::var("VOICE_TEST_WAV").expect("VOICE_TEST_WAV")).unwrap();
        let t = OpenRouterTranscriber::new(&VoiceConfig::default()).unwrap();
        // Skip the source header; `transcribe` writes its own
        let text = t.transcribe(&key, &wav[44..]).await.unwrap();
        println!("transcript: {text}");
        assert!(!text.is_empty());
    }

    #[test]
    fn transcriber_uses_configured_model_and_language() {
        let config = VoiceConfig {
            model: " openai/whisper-1 ".into(),
            language: "fr".into(),
            ..VoiceConfig::default()
        };
        let t = OpenRouterTranscriber::new(&config).unwrap();
        assert_eq!(t.model(), "openai/whisper-1");
        assert_eq!(t.language, "fr");
        assert_eq!(t.url, "https://openrouter.ai/api/v1/audio/transcriptions");
    }
}
