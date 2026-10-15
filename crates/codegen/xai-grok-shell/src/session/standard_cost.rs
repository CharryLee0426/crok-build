//! A model call's cost at the model's standard API price, for a provider that reports none.
//!
//! Only xAI reports each request's cost, and OpenRouter its own; every other provider (and every
//! subscription plan) leaves the ledger without one. The estimate prices the call's tokens from
//! [`xai_grok_models::pricing`], and the ledger keeps it apart from reported costs so every surface
//! can say it is an estimate.

use std::path::Path;
use std::time::SystemTime;

use xai_chat_state::{UsageLedger, UsageTotals};
use xai_grok_models::openrouter;
use xai_grok_models::pricing::{self, CallTokens, ModelPrice, PriceList};
use xai_grok_sampling_types::{ApiBackend, PromptCacheTtl, SamplingConfig, TokenUsage};

use crate::session::usage_file::{SessionUsageFile, UsageSummary};

/// The call's cost in USD ticks, or `None` when no standard price is known for the model.
/// `response_model` is the model the provider says answered; the configured one is tried after it.
pub(crate) fn standard_cost_ticks(
    config: &SamplingConfig,
    response_model: Option<&str>,
    usage: &TokenUsage,
    at: SystemTime,
) -> Option<i64> {
    let list = PriceList::for_base_url(&config.base_url);
    let price = [response_model, Some(config.model.as_str())]
        .into_iter()
        .flatten()
        .map(str::trim)
        .filter(|model| !model.is_empty())
        .find_map(|model| match list {
            Some(PriceList::OpenRouter) => openrouter::cached_pricing(
                &crate::agent::builtin_providers::openrouter_cache_path(),
                model,
            )
            .as_ref()
            .and_then(pricing::openrouter_price),
            _ => pricing::listed_price(list, model, at),
        })?;
    // Anthropic's own endpoint keeps cache entries for an hour unless told otherwise, and such a write costs more.
    let one_hour_cache =
        crate::agent::builtin_providers::anthropic_options(&config.api_backend, &config.base_url)
            .is_some_and(|options| options.cache_ttl == PromptCacheTtl::OneHour);
    let tokens = call_tokens(usage);
    Some(price.cost_usd_ticks(&tokens, one_hour_cache)).filter(|ticks| *ticks > 0)
}

/// What a session's `usage.json` in `session_dir` recorded, as a ledger: every turn the agent
/// processes before this one ran. `None` for a session with nothing recorded.
pub(crate) fn recorded_session_usage(session_dir: &Path) -> Option<UsageLedger> {
    let path = session_dir.join(crate::session::storage::USAGE_FILE);
    let data = std::fs::read(&path).ok()?;
    match serde_json::from_slice::<SessionUsageFile>(&data) {
        Ok(file) => recorded_usage(&file),
        Err(error) => {
            tracing::warn!(%error, path = %path.display(), "unreadable usage.json; session usage counts from this process");
            None
        }
    }
}

/// The turns of a `usage.json` as a ledger. A model row recorded without a cost (a turn from
/// before costs were estimated) is priced here at the model's standard API price as of the time
/// its turn ended; a row no price list knows stays without one, so the total says it is partial.
pub(crate) fn recorded_usage(file: &SessionUsageFile) -> Option<UsageLedger> {
    let mut ledger = UsageLedger::default();
    let mut recorded = false;
    for turn in &file.turns {
        let at = chrono::DateTime::parse_from_rfc3339(&turn.ended_at)
            .map(SystemTime::from)
            .unwrap_or_else(|_| SystemTime::now());
        let rows: Vec<(&str, &UsageSummary)> = if turn.usage.model_usage.is_empty() {
            vec![(
                turn.usage.primary_model_id.as_deref().unwrap_or_default(),
                &turn.usage,
            )]
        } else {
            turn.usage
                .model_usage
                .iter()
                .map(|(model, row)| (model.as_str(), row))
                .collect()
        };
        for (model, row) in rows {
            if row.model_calls == 0 && row.input_tokens == 0 && row.output_tokens == 0 {
                continue;
            }
            recorded = true;
            ledger.fold(model, &recorded_totals(model, row, at));
        }
        if turn.usage.usage_is_incomplete {
            ledger.mark_incomplete();
        }
    }
    recorded.then_some(ledger)
}

fn recorded_totals(model: &str, row: &UsageSummary, at: SystemTime) -> UsageTotals {
    let mut totals = UsageTotals {
        input_tokens: row.input_tokens,
        output_tokens: row.output_tokens,
        cached_read_tokens: row.cached_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        reasoning_tokens: row.reasoning_tokens,
        model_calls: row.model_calls,
        api_duration_ms: row.api_duration_ms,
        cost_usd_ticks: row.cost_usd_ticks,
        // The file keeps whether a row's cost was partial or estimated, not for how many calls.
        cost_missing_calls: u64::from(row.cost_is_partial),
        cost_estimated_calls: u64::from(row.cost_is_estimated),
        decode_duration_ms: row.decode_duration_ms,
        decode_output_tokens: row.decode_output_tokens,
    };
    if totals.cost_usd_ticks.is_none() && row.model_calls > 0 {
        let estimate = recorded_model_price(model, at).map(|(price, one_hour)| {
            let tokens = CallTokens {
                input: row
                    .input_tokens
                    .saturating_sub(row.cached_read_tokens)
                    .saturating_sub(row.cache_creation_tokens),
                cache_read: row.cached_read_tokens,
                cache_write: row.cache_creation_tokens,
                output: row.output_tokens,
            };
            price.cost_usd_ticks_over_calls(&tokens, row.model_calls, one_hour)
        });
        match estimate.filter(|ticks| *ticks > 0) {
            Some(ticks) => {
                totals.cost_usd_ticks = Some(ticks);
                totals.cost_estimated_calls = row.model_calls;
            }
            None => totals.cost_missing_calls = row.model_calls,
        }
    }
    totals
}

/// The standard price of a model as a ledger names it, which says nothing of the endpoint: a
/// routing slug (`meta/muse-spark-1.3`) is looked up in OpenRouter's catalog first, and anything
/// else in the providers' lists by its id.
fn recorded_model_price(model: &str, at: SystemTime) -> Option<(ModelPrice, bool)> {
    let model = model.trim();
    if model.is_empty() {
        return None;
    }
    if model.contains('/')
        && let Some(price) = openrouter::cached_pricing(
            &crate::agent::builtin_providers::openrouter_cache_path(),
            model,
        )
        .as_ref()
        .and_then(pricing::openrouter_price)
    {
        return Some((price, false));
    }
    let price = pricing::listed_price(None, model, at)?;
    // A bare Claude id is the Claude API's own, which keeps cache entries for an hour unless told otherwise.
    let one_hour_cache = !model.contains('/')
        && model.starts_with("claude-")
        && crate::agent::builtin_providers::anthropic_options(
            &ApiBackend::Messages,
            xai_grok_models::anthropic::ANTHROPIC_BASE_URL,
        )
        .is_some_and(|options| options.cache_ttl == PromptCacheTtl::OneHour);
    Some((price, one_hour_cache))
}

/// `prompt_tokens` counts the whole prompt; the price list wants disjoint buckets.
fn call_tokens(usage: &TokenUsage) -> CallTokens {
    let cache_read = u64::from(usage.cached_prompt_tokens);
    let cache_write = u64::from(usage.cache_creation_prompt_tokens);
    CallTokens {
        input: u64::from(usage.prompt_tokens)
            .saturating_sub(cache_read)
            .saturating_sub(cache_write),
        cache_read,
        cache_write,
        output: u64::from(usage.completion_tokens),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use xai_grok_sampling_types::ApiBackend;

    fn usage(prompt: u32, cached: u32, written: u32, completion: u32) -> TokenUsage {
        TokenUsage {
            prompt_tokens: prompt,
            completion_tokens: completion,
            total_tokens: prompt + completion,
            reasoning_tokens: 0,
            cached_prompt_tokens: cached,
            cache_creation_prompt_tokens: written,
        }
    }

    fn config(base_url: &str, model: &str, api_backend: ApiBackend) -> SamplingConfig {
        SamplingConfig {
            base_url: base_url.into(),
            model: model.into(),
            api_backend,
            ..Default::default()
        }
    }

    #[test]
    fn a_claude_call_is_priced_with_one_hour_cache_writes() {
        let config = config(
            "https://api.anthropic.com/v1",
            "claude-opus-5-5",
            ApiBackend::Messages,
        );
        // 1M uncached at $4, 10M read at $0.20, 1M written for an hour at $8, 100K out at $20.
        let ticks = standard_cost_ticks(
            &config,
            Some("claude-opus-5-5"),
            &usage(12_000_000, 10_000_000, 1_000_000, 100_000),
            SystemTime::now(),
        );
        assert_eq!(ticks, Some(160_000_000_000));
    }

    #[test]
    fn a_subscription_model_is_priced_at_its_api_price() {
        let config = config(
            "https://chatgpt.com/backend-api/codex",
            "gpt-5.5",
            ApiBackend::OpenAiCodex,
        );
        // 100K in at $5, 100K out at $30.
        let ticks = standard_cost_ticks(
            &config,
            None,
            &usage(100_000, 0, 0, 100_000),
            SystemTime::now(),
        );
        assert_eq!(ticks, Some(35_000_000_000));
        // Past 272K input tokens the whole request pays $10 in and $45 out.
        let long = standard_cost_ticks(
            &config,
            None,
            &usage(300_000, 0, 0, 100_000),
            SystemTime::now(),
        );
        assert_eq!(long, Some(75_000_000_000));
    }

    #[test]
    fn the_answering_model_is_priced_before_the_configured_one() {
        let config = config(
            "https://api.z.ai/api/coding/paas/v4",
            "glm-5.3",
            ApiBackend::Glm,
        );
        let flash = standard_cost_ticks(
            &config,
            Some("glm-5.3-flash"),
            &usage(1_000_000, 0, 0, 0),
            SystemTime::now(),
        );
        assert_eq!(flash, Some(1_500_000_000));
        // A model the list does not know falls back to the configured one.
        let fallback = standard_cost_ticks(
            &config,
            Some("glm-unknown"),
            &usage(1_000_000, 0, 0, 0),
            SystemTime::now(),
        );
        assert_eq!(fallback, Some(14_000_000_000));
    }

    fn turn(
        number: u32,
        ended_at: &str,
        rows: &[(&str, UsageSummary)],
    ) -> crate::session::usage_file::TurnUsage {
        let mut usage = UsageSummary::default();
        for (model, row) in rows {
            usage.model_usage.insert((*model).to_owned(), row.clone());
        }
        crate::session::usage_file::TurnUsage {
            turn_number: number,
            ended_at: ended_at.into(),
            usage,
        }
    }

    fn row(prompt: u64, cached: u64, written: u64, output: u64, calls: u64) -> UsageSummary {
        UsageSummary {
            input_tokens: prompt,
            cached_read_tokens: cached,
            cache_creation_tokens: written,
            output_tokens: output,
            total_tokens: prompt + output,
            model_calls: calls,
            ..Default::default()
        }
    }

    /// Turns recorded before costs were estimated are priced from their tokens; a recorded cost
    /// stands; a model with no price leaves the total partial.
    #[test]
    fn recorded_turns_become_the_sessions_earlier_bill() {
        let mut priced = row(0, 0, 0, 0, 1);
        priced.cost_usd_ticks = Some(25);
        let mut file = SessionUsageFile::new("s");
        file.turns = vec![
            // 10 calls: 1M uncached at $4, 10M read at $0.20, 1M written for an hour at $8, 100K out at $20.
            turn(
                1,
                "2026-10-13T20:00:00Z",
                &[(
                    "claude-opus-5-5",
                    row(12_000_000, 10_000_000, 1_000_000, 100_000, 10),
                )],
            ),
            turn(2, "2026-10-14T20:00:00Z", &[("grok-4.6", priced)]),
        ];
        let ledger = recorded_usage(&file).unwrap();
        assert_eq!(ledger.main_loop_model_calls, 0);
        assert_eq!(ledger.totals.model_calls, 11);
        assert_eq!(ledger.totals.cost_usd_ticks, Some(160_000_000_000 + 25));
        assert!(ledger.totals.cost_is_estimated());
        assert!(!ledger.totals.cost_is_partial());
        assert_eq!(
            ledger
                .by_model
                .get("grok-4.6")
                .and_then(|m| m.cost_usd_ticks),
            Some(25)
        );

        file.turns.push(turn(
            3,
            "2026-10-14T21:00:00Z",
            &[("gpt-5.3-codex-spark", row(1_000, 0, 0, 10, 1))],
        ));
        let ledger = recorded_usage(&file).unwrap();
        assert!(ledger.totals.cost_is_partial());
        assert_eq!(SessionUsageFile::new("empty").turns.len(), 0);
        assert!(recorded_usage(&SessionUsageFile::new("empty")).is_none());
    }

    #[test]
    fn the_recorded_file_is_read_from_the_session_directory() {
        let dir = tempfile::tempdir().unwrap();
        assert!(recorded_session_usage(dir.path()).is_none());
        let mut file = SessionUsageFile::new("s");
        file.apply_turn(1, "2026-10-14T20:00:00Z", &row(1_000, 0, 0, 40, 1), None);
        // `apply_turn` keeps rows by model only when the live summary has them.
        assert!(file.turns[0].usage.model_usage.is_empty());
        file.turns[0].usage.primary_model_id = Some("gpt-5.5".into());
        std::fs::write(
            dir.path().join("usage.json"),
            serde_json::to_vec(&file).unwrap(),
        )
        .unwrap();
        let ledger = recorded_session_usage(dir.path()).unwrap();
        // 1,000 in at $5, 40 out at $30.
        assert_eq!(ledger.totals.cost_usd_ticks, Some(62_000_000));
        assert_eq!(ledger.by_model.keys().collect::<Vec<_>>(), ["gpt-5.5"]);
        std::fs::write(dir.path().join("usage.json"), b"not json").unwrap();
        assert!(recorded_session_usage(dir.path()).is_none());
    }

    #[test]
    fn an_unknown_model_or_an_empty_call_has_no_cost() {
        let local = config(
            "http://127.0.0.1:9/v1",
            "llama3",
            ApiBackend::ChatCompletions,
        );
        assert_eq!(
            standard_cost_ticks(&local, None, &usage(1_000, 0, 0, 10), SystemTime::now()),
            None
        );
        let claude = config(
            "https://api.anthropic.com/v1",
            "claude-opus-5-5",
            ApiBackend::Messages,
        );
        assert_eq!(
            standard_cost_ticks(&claude, None, &usage(0, 0, 0, 0), SystemTime::now()),
            None
        );
    }
}
