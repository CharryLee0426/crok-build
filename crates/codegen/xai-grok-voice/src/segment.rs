//! Cuts the live PCM16LE mic stream into utterances at pauses, for per-request STT (OpenRouter).
//!
//! Streaming STT decides utterance boundaries server-side; a request-per-clip API cannot, so this does it locally with a
//! simple energy detector. A chunk counts as speech when its RMS clears an adaptive threshold (a multiple of the tracked
//! noise floor, clamped to a sane range). A segment closes after a pause following speech, and long pauseless speech is
//! cut at the first short gap after [`SOFT_MAX_MS`] (or hard at [`HARD_MAX_MS`]). Silence-only audio is never sent:
//! it costs money and makes Whisper-class models hallucinate ("Thank you.").

/// Silence after speech that closes a segment.
const PAUSE_MS: u64 = 700;
/// Segments shorter than this wait for more audio even after a pause (a lone "uh" costs a request and returns noise).
const MIN_SEGMENT_MS: u64 = 800;
/// Past this length a shorter gap is enough to cut, bounding latency for long pauseless dictation.
const SOFT_MAX_MS: u64 = 12_000;
const SOFT_MAX_GAP_MS: u64 = 150;
/// Hard cut even mid-word; OpenRouter requests time out at 60 s, and latency matters more than a clean boundary here.
const HARD_MAX_MS: u64 = 25_000;
/// Audio kept from before speech starts so the first syllable is not clipped.
const PREROLL_MS: u64 = 300;
/// Speech threshold bounds (PCM16 RMS). The lower bound is about -42 dBFS; the upper keeps a noisy-room floor from
/// ratcheting the threshold above normal speech.
const MIN_SPEECH_RMS: f64 = 250.0;
const MAX_SPEECH_RMS: f64 = 1_500.0;
const FLOOR_RATIO: f64 = 3.0;
/// How fast the noise floor follows louder non-speech audio (per chunk). It drops to quieter audio immediately.
const FLOOR_RISE: f64 = 0.05;

/// The result of feeding one chunk.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Push {
    /// The chunk looked like speech.
    pub voiced: bool,
    /// A closed utterance ready to transcribe.
    pub segment: Option<Vec<u8>>,
}

#[derive(Debug)]
pub(crate) struct Segmenter {
    sample_rate: u32,
    buf: Vec<u8>,
    has_speech: bool,
    trailing_silence_ms: u64,
    noise_floor: Option<f64>,
}

impl Segmenter {
    pub(crate) fn new(sample_rate: u32) -> Self {
        Self {
            sample_rate: sample_rate.max(1),
            buf: Vec::new(),
            has_speech: false,
            trailing_silence_ms: 0,
            noise_floor: None,
        }
    }

    fn ms(&self, bytes: usize) -> u64 {
        (bytes as u64 / 2) * 1_000 / u64::from(self.sample_rate)
    }

    fn bytes_for_ms(&self, ms: u64) -> usize {
        usize::try_from(ms * u64::from(self.sample_rate) / 1_000 * 2).unwrap_or(usize::MAX)
    }

    /// Classify a chunk as speech and update the noise floor from non-speech audio.
    fn classify(&mut self, chunk: &[u8]) -> bool {
        let level = rms(chunk);
        let floor = *self.noise_floor.get_or_insert(level);
        let threshold = (floor * FLOOR_RATIO).clamp(MIN_SPEECH_RMS, MAX_SPEECH_RMS);
        let voiced = level >= threshold;
        let next = if level < floor {
            level
        } else if voiced {
            floor
        } else {
            floor + (level - floor) * FLOOR_RISE
        };
        self.noise_floor = Some(next);
        voiced
    }

    pub(crate) fn push(&mut self, chunk: &[u8]) -> Push {
        if chunk.is_empty() {
            return Push::default();
        }
        let voiced = self.classify(chunk);
        let chunk_ms = self.ms(chunk.len());
        self.buf.extend_from_slice(chunk);
        if voiced {
            self.has_speech = true;
            self.trailing_silence_ms = 0;
        } else {
            self.trailing_silence_ms += chunk_ms;
        }

        let len_ms = self.ms(self.buf.len());
        if !self.has_speech {
            // Keep only the pre-roll while nobody is talking
            let keep = self.bytes_for_ms(PREROLL_MS);
            if self.buf.len() > keep {
                let excess = (self.buf.len() - keep) & !1;
                self.buf.drain(..excess);
            }
            return Push {
                voiced,
                segment: None,
            };
        }
        let pause_cut = self.trailing_silence_ms >= PAUSE_MS && len_ms >= MIN_SEGMENT_MS;
        let soft_cut = len_ms >= SOFT_MAX_MS && self.trailing_silence_ms >= SOFT_MAX_GAP_MS;
        let hard_cut = len_ms >= HARD_MAX_MS;
        Push {
            voiced,
            segment: (pause_cut || soft_cut || hard_cut).then(|| self.take()),
        }
    }

    /// The trailing utterance when capture ends, if it contains speech.
    pub(crate) fn finish(&mut self) -> Option<Vec<u8>> {
        if self.has_speech {
            Some(self.take())
        } else {
            self.buf.clear();
            None
        }
    }

    fn take(&mut self) -> Vec<u8> {
        self.has_speech = false;
        self.trailing_silence_ms = 0;
        std::mem::take(&mut self.buf)
    }
}

/// Root-mean-square level of PCM16LE samples (a trailing odd byte is ignored).
fn rms(pcm: &[u8]) -> f64 {
    let mut sum = 0.0f64;
    let mut n = 0usize;
    for pair in pcm.chunks_exact(2) {
        if let [lo, hi] = *pair {
            let sample = f64::from(i16::from_le_bytes([lo, hi]));
            sum += sample * sample;
            n += 1;
        }
    }
    if n == 0 { 0.0 } else { (sum / n as f64).sqrt() }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 16_000;
    /// 100 ms chunks.
    const CHUNK_SAMPLES: usize = 1_600;

    fn tone(amplitude: i16) -> Vec<u8> {
        (0..CHUNK_SAMPLES)
            .flat_map(|i| {
                let s = if i % 2 == 0 { amplitude } else { -amplitude };
                s.to_le_bytes()
            })
            .collect()
    }

    fn quiet() -> Vec<u8> {
        tone(20)
    }

    fn speech() -> Vec<u8> {
        tone(3_000)
    }

    fn feed(seg: &mut Segmenter, chunk: &[u8], times: usize) -> Vec<Vec<u8>> {
        (0..times).filter_map(|_| seg.push(chunk).segment).collect()
    }

    #[test]
    fn silence_is_never_sent() {
        let mut seg = Segmenter::new(RATE);
        assert!(feed(&mut seg, &quiet(), 100).is_empty());
        assert_eq!(seg.finish(), None);
    }

    #[test]
    fn pause_after_speech_closes_a_segment_with_preroll() {
        let mut seg = Segmenter::new(RATE);
        assert!(feed(&mut seg, &quiet(), 10).is_empty());
        assert!(feed(&mut seg, &speech(), 10).is_empty());
        let out = feed(&mut seg, &quiet(), 10);
        assert_eq!(out.len(), 1, "one segment after a 700 ms pause");
        let ms = seg.ms(out.first().map_or(0, Vec::len));
        // 300 ms pre-roll + 1 s speech + 700 ms pause
        assert_eq!(ms, 2_000);
        // The segment was taken, so nothing is left to finish
        assert_eq!(seg.finish(), None);
    }

    #[test]
    fn short_blip_waits_for_more_audio() {
        let mut seg = Segmenter::new(RATE);
        assert!(seg.push(&speech()).segment.is_none());
        // 100 ms speech + 300 ms pause stays below the minimum length until the pause reaches 700 ms
        assert!(feed(&mut seg, &quiet(), 3).is_empty());
        assert!(!feed(&mut seg, &quiet(), 4).is_empty());
    }

    #[test]
    fn finish_flushes_trailing_speech() {
        let mut seg = Segmenter::new(RATE);
        feed(&mut seg, &speech(), 5);
        let rest = seg.finish().expect("trailing speech is kept");
        assert_eq!(seg.ms(rest.len()), 500);
    }

    #[test]
    fn long_pauseless_speech_is_cut() {
        let mut seg = Segmenter::new(RATE);
        let out = feed(&mut seg, &speech(), 260);
        assert_eq!(out.len(), 1, "hard cut at 25 s");
        assert_eq!(seg.ms(out.first().map_or(0, Vec::len)), 25_000);
    }

    #[test]
    fn short_gap_cuts_after_soft_max() {
        let mut seg = Segmenter::new(RATE);
        assert!(feed(&mut seg, &speech(), 125).is_empty());
        let out = feed(&mut seg, &quiet(), 2);
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn noise_floor_adapts_to_steady_noise() {
        let mut seg = Segmenter::new(RATE);
        // Steady fan noise well above the minimum threshold never counts as speech once the floor settles
        let fan = tone(400);
        let voiced: Vec<bool> = (0..50).map(|_| seg.push(&fan).voiced).collect();
        assert!(!voiced.iter().skip(1).any(|v| *v));
        assert!(seg.push(&tone(4_000)).voiced);
    }

    #[test]
    fn rms_of_square_wave_is_its_amplitude() {
        assert!((rms(&tone(1_000)) - 1_000.0).abs() < 1e-9);
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(rms(&[1]), 0.0);
    }
}
