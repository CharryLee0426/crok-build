//! Speech-to-Text: xAI streaming `wss://api.x.ai/v1/stt`, and OpenRouter's per-utterance `/audio/transcriptions`.

mod openrouter;
mod streaming;
mod types;

pub use openrouter::{OpenRouterTranscriber, pcm16_wav};
pub use streaming::{StreamingSttEvent, StreamingSttSession};
pub use types::{SttServerEvent, SttTranscriptPartial};
