//! The session's token readout: what the shell has counted, plus an estimate for the response still streaming.
//!
//! The shell reports exact figures once per model response, so the counts would otherwise stand still while text streams.
//! Between those reports the meter estimates from the bytes that have arrived, and the next report replaces the estimate.
//! Rendering is `views::token_meter`.

use std::time::{Duration, Instant};

use xai_grok_shell::extensions::notification::ResponseUsage;

/// The stream has to run this long before its rate is shown; a rate over a few chunks swings wildly.
const MIN_LIVE_RATE_WINDOW: Duration = Duration::from_secs(1);

/// What the status bar draws.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct TokenReadout {
    /// Every prompt token sent this session, cached or not.
    pub(crate) input_tokens: u64,
    /// Includes the estimate for a response in flight.
    pub(crate) output_tokens: u64,
    /// Share of `input_tokens` served from the provider's cache, `None` before any input is counted.
    pub(crate) cache_hit_pct: Option<f64>,
    pub(crate) rate: Option<TokenRate>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum TokenRate {
    /// The shell's figure for the last completed response.
    Measured(f64),
    /// From the bytes streamed so far.
    Estimated(f64),
}

impl TokenRate {
    pub(crate) fn tokens_per_sec(self) -> f64 {
        match self {
            Self::Measured(rate) | Self::Estimated(rate) => rate,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct TokenMeter {
    session: Option<ResponseUsage>,
    last_rate: Option<f64>,
    live: Option<LiveResponse>,
}

/// One response's stream, from its first chunk.
#[derive(Debug, Clone, PartialEq)]
struct LiveResponse {
    /// Tells a new turn's stream from one a cancelled turn left behind, which no completion ever closed.
    prompt_id: Option<String>,
    first_chunk_at: Instant,
    last_chunk_at: Instant,
    bytes: u64,
    /// Generated before the clock started, so left out of the rate.
    first_chunk_bytes: u64,
}

impl LiveResponse {
    fn estimated_tokens(&self) -> u64 {
        self.bytes / xai_token_estimation::BYTES_PER_TOKEN
    }

    fn rate(&self) -> Option<f64> {
        let window = self.last_chunk_at.duration_since(self.first_chunk_at);
        if window < MIN_LIVE_RATE_WINDOW {
            return None;
        }
        let tokens = (self.bytes - self.first_chunk_bytes) as f64
            / xai_token_estimation::BYTES_PER_TOKEN as f64;
        Some(tokens / window.as_secs_f64())
    }
}

impl TokenMeter {
    /// Streamed model output: message text, reasoning, or a tool call's arguments.
    /// A tool call's deltas carry no prompt id, so only two ids that differ start a new stream.
    pub(crate) fn note_stream_bytes(
        &mut self,
        bytes: usize,
        prompt_id: Option<&str>,
        now: Instant,
    ) {
        if bytes == 0 {
            return;
        }
        let bytes = bytes as u64;
        match self.live.as_mut() {
            Some(live)
                if prompt_id.is_none()
                    || live.prompt_id.is_none()
                    || live.prompt_id.as_deref() == prompt_id =>
            {
                live.bytes += bytes;
                live.last_chunk_at = now;
                if live.prompt_id.is_none() {
                    live.prompt_id = prompt_id.map(str::to_owned);
                }
            }
            _ => {
                self.live = Some(LiveResponse {
                    prompt_id: prompt_id.map(str::to_owned),
                    first_chunk_at: now,
                    last_chunk_at: now,
                    bytes,
                    first_chunk_bytes: bytes,
                });
            }
        }
    }

    /// The turn ended. A response it cut short never completes, so its stream is dropped here.
    pub(crate) fn end_stream(&mut self) {
        self.live = None;
    }

    /// One model response finished. Returns whether the readout changed.
    /// `session_usage` is the shell's own total; a shell that sends none has its per-response `usage` summed instead.
    pub(crate) fn complete_response(
        &mut self,
        usage: Option<&ResponseUsage>,
        session_usage: Option<&ResponseUsage>,
        tokens_per_sec: Option<f64>,
    ) -> bool {
        let before = self.clone();
        self.live = None;
        match (session_usage, usage) {
            (Some(total), _) => self.session = Some(total.clone()),
            (None, Some(call)) => {
                let total = self.session.get_or_insert_with(ResponseUsage::default);
                total.input_tokens += call.input_tokens;
                total.output_tokens += call.output_tokens;
                total.cache_read_input_tokens += call.cache_read_input_tokens;
                total.cache_creation_input_tokens += call.cache_creation_input_tokens;
                total.reasoning_tokens += call.reasoning_tokens;
            }
            (None, None) => {}
        }
        if let Some(rate) = tokens_per_sec.filter(|rate| rate.is_finite() && *rate > 0.0) {
            self.last_rate = Some(rate);
        }
        *self != before
    }

    /// `None` until something has been counted, so a fresh session draws no zeros.
    /// `turn_running` is false once a turn ends; a stream it left open no longer counts.
    pub(crate) fn readout(&self, turn_running: bool) -> Option<TokenReadout> {
        let live = self.live.as_ref().filter(|_| turn_running);
        if self.session.is_none() && live.is_none() {
            return None;
        }
        let session = self.session.clone().unwrap_or_default();
        let input_tokens = session.input_tokens
            + session.cache_read_input_tokens
            + session.cache_creation_input_tokens;
        let rate = live
            .and_then(LiveResponse::rate)
            .map(TokenRate::Estimated)
            .or(self.last_rate.map(TokenRate::Measured));
        Some(TokenReadout {
            input_tokens,
            output_tokens: session.output_tokens + live.map_or(0, LiveResponse::estimated_tokens),
            cache_hit_pct: (input_tokens > 0)
                .then(|| session.cache_read_input_tokens as f64 * 100.0 / input_tokens as f64),
            rate,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage(input: u64, cache_read: u64, cache_creation: u64, output: u64) -> ResponseUsage {
        ResponseUsage {
            input_tokens: input,
            output_tokens: output,
            cache_read_input_tokens: cache_read,
            cache_creation_input_tokens: cache_creation,
            reasoning_tokens: 0,
        }
    }

    #[test]
    fn an_untouched_meter_draws_nothing() {
        assert_eq!(TokenMeter::default().readout(true), None);
    }

    #[test]
    fn session_totals_replace_rather_than_add() {
        let mut meter = TokenMeter::default();
        assert!(meter.complete_response(
            Some(&usage(100, 300, 0, 20)),
            Some(&usage(100, 300, 0, 20)),
            Some(40.0),
        ));
        // The second total already contains the first response, and a subagent's spend on top.
        meter.complete_response(
            Some(&usage(50, 400, 0, 10)),
            Some(&usage(1_000, 2_800, 200, 90)),
            Some(55.5),
        );
        let readout = meter.readout(false).unwrap();
        assert_eq!(readout.input_tokens, 4_000);
        assert_eq!(readout.output_tokens, 90);
        assert_eq!(readout.cache_hit_pct, Some(70.0));
        assert_eq!(readout.rate, Some(TokenRate::Measured(55.5)));
    }

    #[test]
    fn a_shell_without_session_totals_has_its_responses_summed() {
        let mut meter = TokenMeter::default();
        meter.complete_response(Some(&usage(100, 300, 0, 20)), None, None);
        meter.complete_response(Some(&usage(50, 500, 50, 10)), None, None);
        let readout = meter.readout(false).unwrap();
        assert_eq!(readout.input_tokens, 1_000);
        assert_eq!(readout.output_tokens, 30);
        assert_eq!(readout.cache_hit_pct, Some(80.0));
        assert_eq!(readout.rate, None);
    }

    #[test]
    fn a_stream_is_estimated_until_its_response_completes() {
        let mut meter = TokenMeter::default();
        meter.complete_response(None, Some(&usage(10, 0, 0, 100)), Some(30.0));
        let start = Instant::now();
        meter.note_stream_bytes(40, Some("p1"), start);
        // Too short a window to trust: the last measured rate stands, but the output already counts.
        let readout = meter.readout(true).unwrap();
        assert_eq!(readout.output_tokens, 110);
        assert_eq!(readout.rate, Some(TokenRate::Measured(30.0)));

        meter.note_stream_bytes(800, Some("p1"), start + Duration::from_secs(2));
        let readout = meter.readout(true).unwrap();
        assert_eq!(readout.output_tokens, 310);
        // 800 bytes after the first chunk, over two seconds.
        assert_eq!(readout.rate, Some(TokenRate::Estimated(100.0)));

        meter.complete_response(None, Some(&usage(10, 0, 0, 290)), Some(88.0));
        let readout = meter.readout(true).unwrap();
        assert_eq!(readout.output_tokens, 290);
        assert_eq!(readout.rate, Some(TokenRate::Measured(88.0)));
    }

    #[test]
    fn a_cancelled_stream_stops_counting_and_does_not_leak_into_the_next_turn() {
        let mut meter = TokenMeter::default();
        let start = Instant::now();
        meter.note_stream_bytes(400, Some("p1"), start);
        meter.note_stream_bytes(400, Some("p1"), start + Duration::from_secs(4));
        assert_eq!(meter.readout(true).unwrap().output_tokens, 200);
        // The turn was cancelled: no completion arrives, and nothing was counted by the shell.
        assert_eq!(meter.readout(false), None);

        meter.note_stream_bytes(40, Some("p2"), start + Duration::from_secs(60));
        let readout = meter.readout(true).unwrap();
        assert_eq!(readout.output_tokens, 10);
        assert_eq!(readout.rate, None);
    }

    #[test]
    fn a_tool_call_delta_without_a_prompt_id_joins_the_stream_in_flight() {
        let mut meter = TokenMeter::default();
        let start = Instant::now();
        meter.note_stream_bytes(40, None, start);
        meter.note_stream_bytes(40, Some("p1"), start + Duration::from_secs(1));
        meter.note_stream_bytes(40, None, start + Duration::from_secs(2));
        assert_eq!(meter.readout(true).unwrap().output_tokens, 30);

        // The stream took the id it was given, so the next turn's first chunk still restarts it.
        meter.note_stream_bytes(40, Some("p2"), start + Duration::from_secs(3));
        assert_eq!(meter.readout(true).unwrap().output_tokens, 10);

        meter.end_stream();
        assert_eq!(meter.readout(true), None);
    }

    #[test]
    fn a_meaningless_rate_keeps_the_last_good_one() {
        let mut meter = TokenMeter::default();
        meter.complete_response(None, Some(&usage(1, 0, 0, 1)), Some(42.0));
        assert!(!meter.complete_response(None, Some(&usage(1, 0, 0, 1)), Some(f64::NAN)));
        assert!(!meter.complete_response(None, Some(&usage(1, 0, 0, 1)), Some(0.0)));
        assert_eq!(
            meter.readout(false).unwrap().rate,
            Some(TokenRate::Measured(42.0))
        );
    }
}
