//! A model call's cost at the model's standard API price, for a provider that reports none.
//!
//! Only xAI reports each request's cost, and OpenRouter its own; every other provider (and every
//! subscription plan) leaves the ledger without one. The estimate prices the call's tokens from
//! [`xai_grok_models::pricing`], and the ledger keeps it apart from reported costs so every surface
//! can say it is an estimate.

use std::time::SystemTime;

use xai_grok_models::openrouter;
use xai_grok_models::pricing::{self, CallTokens, PriceList};
use xai_grok_sampling_types::{PromptCacheTtl, SamplingConfig, TokenUsage};

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
