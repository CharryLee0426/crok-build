//! Standard pay-as-you-go API prices, for a model call whose provider reports no cost.
//!
//! A cost worked out here is an estimate: what the call would have cost on the provider's public
//! API, whatever actually paid for it (a ChatGPT or GLM Coding Plan subscription, say). Prices are
//! USD per million tokens, read from each provider's pricing page on 2026-10-14:
//! - Anthropic: <https://platform.claude.com/docs/en/about-claude/pricing>
//! - OpenAI: <https://developers.openai.com/api/docs/pricing>
//! - DeepSeek: <https://api-docs.deepseek.com/quick_start/pricing>
//! - Z.ai: <https://docs.z.ai/guides/overview/pricing>
//! - xAI: <https://docs.x.ai/docs/models>
//!
//! OpenRouter publishes each model's price in its catalog, which [`openrouter_price`] reads.

use std::time::{SystemTime, UNIX_EPOCH};

/// 1 USD is 10^10 ticks, the unit costs are kept in.
pub const USD_TICKS_PER_USD: f64 = 1e10;

/// USD per million tokens.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rates {
    /// Prompt tokens neither read from nor written to a cache.
    pub input: f64,
    pub cache_read: f64,
    /// Prompt tokens written to the cache. Anthropic's five-minute lifetime here.
    pub cache_write: f64,
    /// Anthropic's one-hour cache lifetime, which costs more to write.
    pub cache_write_one_hour: Option<f64>,
    pub output: f64,
}

impl Rates {
    const fn new(input: f64, cache_read: f64, cache_write: f64, output: f64) -> Self {
        Self {
            input,
            cache_read,
            cache_write,
            cache_write_one_hour: None,
            output,
        }
    }

    /// Anthropic's prices: a five-minute write is 1.25 times the input price, a one-hour one twice.
    const fn anthropic(input: f64, cache_read: f64, output: f64) -> Self {
        Self {
            input,
            cache_read,
            cache_write: input * 1.25,
            cache_write_one_hour: Some(input * 2.0),
            output,
        }
    }

    fn scaled(self, factor: f64) -> Self {
        Self {
            input: self.input * factor,
            cache_read: self.cache_read * factor,
            cache_write: self.cache_write * factor,
            cache_write_one_hour: self.cache_write_one_hour.map(|rate| rate * factor),
            output: self.output * factor,
        }
    }
}

/// A model's price. A request whose prompt reaches `long_context.from` tokens pays the long rates
/// for all of its tokens.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ModelPrice {
    pub rates: Rates,
    pub long_context: Option<LongContext>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LongContext {
    /// The smallest prompt, in tokens, that pays `rates`.
    pub from: u64,
    pub rates: Rates,
}

/// One call's tokens in disjoint buckets: `input` is the prompt that was neither read from nor
/// written to a cache.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CallTokens {
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
}

impl CallTokens {
    pub fn prompt(&self) -> u64 {
        self.input
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
    }
}

impl ModelPrice {
    const fn flat(rates: Rates) -> Self {
        Self {
            rates,
            long_context: None,
        }
    }

    const fn tiered(rates: Rates, from: u64, long: Rates) -> Self {
        Self {
            rates,
            long_context: Some(LongContext { from, rates: long }),
        }
    }

    /// The call's cost in USD. `one_hour_cache` prices cache writes at the one-hour rate, where the
    /// model has one.
    pub fn cost_usd(&self, tokens: &CallTokens, one_hour_cache: bool) -> f64 {
        priced(self.rates_for(tokens.prompt()), tokens, one_hour_cache)
    }

    /// The call's cost in USD ticks, rounded to the nearest tick.
    pub fn cost_usd_ticks(&self, tokens: &CallTokens, one_hour_cache: bool) -> i64 {
        usd_to_ticks(self.cost_usd(tokens, one_hour_cache))
    }

    /// Several calls' tokens added together, in USD ticks. Each call's own prompt size is not
    /// known, so the rates are those of the average prompt.
    pub fn cost_usd_ticks_over_calls(
        &self,
        tokens: &CallTokens,
        calls: u64,
        one_hour_cache: bool,
    ) -> i64 {
        let rates = self.rates_for(tokens.prompt() / calls.max(1));
        usd_to_ticks(priced(rates, tokens, one_hour_cache))
    }

    /// The rates a request whose prompt is `prompt_tokens` long pays.
    fn rates_for(&self, prompt_tokens: u64) -> Rates {
        match self.long_context {
            Some(long) if prompt_tokens >= long.from => long.rates,
            _ => self.rates,
        }
    }
}

fn priced(rates: Rates, tokens: &CallTokens, one_hour_cache: bool) -> f64 {
    let cache_write = if one_hour_cache {
        rates.cache_write_one_hour.unwrap_or(rates.cache_write)
    } else {
        rates.cache_write
    };
    (tokens.input as f64 * rates.input
        + tokens.cache_read as f64 * rates.cache_read
        + tokens.cache_write as f64 * cache_write
        + tokens.output as f64 * rates.output)
        / 1_000_000.0
}

fn usd_to_ticks(usd: f64) -> i64 {
    let ticks = (usd * USD_TICKS_PER_USD).round();
    if ticks.is_finite() {
        ticks.clamp(0.0, i64::MAX as f64) as i64
    } else {
        0
    }
}

/// Whose price list a model is looked up in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PriceList {
    Anthropic,
    OpenAi,
    DeepSeek,
    Glm,
    Xai,
    OpenRouter,
}

impl PriceList {
    /// The list for an endpoint, by its host. `None` for a host this build does not know.
    pub fn for_base_url(base_url: &str) -> Option<Self> {
        let authority = base_url
            .split_once("://")
            .map_or(base_url, |(_, rest)| rest)
            .split(['/', '?', '#'])
            .next()
            .unwrap_or_default();
        let host = authority
            .rsplit_once('@')
            .map_or(authority, |(_, host)| host);
        let host = host
            .split(':')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        let is = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
        if is("anthropic.com") {
            Some(Self::Anthropic)
        } else if is("openai.com") || is("chatgpt.com") {
            Some(Self::OpenAi)
        } else if is("deepseek.com") {
            Some(Self::DeepSeek)
        } else if is("z.ai") || is("bigmodel.cn") {
            Some(Self::Glm)
        } else if is("x.ai") {
            Some(Self::Xai)
        } else if is("openrouter.ai") {
            Some(Self::OpenRouter)
        } else {
            None
        }
    }
}

/// The standard price of `model` on `list`, at time `at` (DeepSeek charges less off-peak).
/// With no list (an endpoint this build does not know), every list is searched by the model's id.
/// OpenRouter models are priced by [`openrouter_price`] instead.
pub fn listed_price(list: Option<PriceList>, model: &str, at: SystemTime) -> Option<ModelPrice> {
    let id = normalize(model);
    let lists: &[PriceList] = match list {
        Some(PriceList::OpenRouter) => return None,
        Some(list) => &[list][..],
        None => &[
            PriceList::Anthropic,
            PriceList::OpenAi,
            PriceList::DeepSeek,
            PriceList::Glm,
            PriceList::Xai,
        ],
    };
    lists.iter().find_map(|list| match list {
        PriceList::Anthropic => anthropic(&id),
        PriceList::OpenAi => openai(&id),
        PriceList::DeepSeek => deepseek(&id, at),
        PriceList::Glm => glm(&id),
        PriceList::Xai => xai(&id),
        PriceList::OpenRouter => None,
    })
}

/// A model's price from OpenRouter's catalog, which gives decimal USD per token.
pub fn openrouter_price(pricing: &crate::openrouter::OpenRouterPricing) -> Option<ModelPrice> {
    let per_million = |value: &Option<String>| {
        value
            .as_deref()
            .and_then(|text| text.trim().parse::<f64>().ok())
            .filter(|rate| rate.is_finite() && *rate >= 0.0)
            .map(|rate| rate * 1_000_000.0)
    };
    let input = per_million(&pricing.prompt)?;
    let output = per_million(&pricing.completion)?;
    Some(ModelPrice::flat(Rates::new(
        input,
        per_million(&pricing.input_cache_read).unwrap_or(input),
        per_million(&pricing.input_cache_write).unwrap_or(input),
        output,
    )))
}

/// Lowercase, without a provider namespace (`anthropic/…`) or a release-date suffix.
fn normalize(model: &str) -> String {
    let id = model.trim().to_ascii_lowercase();
    let id = id.rsplit('/').next().unwrap_or_default().to_owned();
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit());
    // `claude-haiku-4-5-20251001`
    if let Some((stem, date)) = id.rsplit_once('-')
        && date.len() == 8
        && digits(date)
    {
        return stem.to_owned();
    }
    // `gpt-5.5-2026-04-23`
    let parts: Vec<&str> = id.rsplitn(4, '-').collect();
    if let [day, month, year, stem] = parts.as_slice()
        && year.len() == 4
        && month.len() == 2
        && day.len() == 2
        && digits(year)
        && digits(month)
        && digits(day)
    {
        return (*stem).to_owned();
    }
    id
}

fn anthropic(id: &str) -> Option<ModelPrice> {
    let price = match id {
        "claude-fable-5-1" | "claude-mythos-5-1" => {
            ModelPrice::flat(Rates::anthropic(10.0, 0.25, 50.0))
        }
        "claude-opus-5-5" => ModelPrice::flat(Rates::anthropic(4.0, 0.20, 20.0)),
        "claude-sonnet-5-5" => ModelPrice::flat(Rates::anthropic(2.0, 0.10, 10.0)),
        // Above 100K prompt tokens, cache reads and writes included, the whole request pays more.
        "claude-haiku-5-5" => ModelPrice::tiered(
            Rates::anthropic(0.10, 0.01, 0.50),
            100_001,
            Rates::anthropic(0.50, 0.05, 2.50),
        ),
        "claude-fable-5" | "claude-mythos-5" => ModelPrice::flat(Rates::anthropic(10.0, 1.0, 50.0)),
        "claude-opus-5" | "claude-opus-4-8" | "claude-opus-4-7" | "claude-opus-4-6"
        | "claude-opus-4-5" => ModelPrice::flat(Rates::anthropic(5.0, 0.50, 25.0)),
        "claude-sonnet-5" => ModelPrice::flat(Rates::anthropic(2.0, 0.20, 10.0)),
        "claude-sonnet-4-6" | "claude-sonnet-4-5" | "claude-sonnet-4" => {
            ModelPrice::flat(Rates::anthropic(3.0, 0.30, 15.0))
        }
        "claude-haiku-4-5" => ModelPrice::flat(Rates::anthropic(1.0, 0.10, 5.0)),
        // Retired from the Claude API, still served elsewhere.
        "claude-opus-4-1" | "claude-opus-4" => ModelPrice::flat(Rates::anthropic(15.0, 1.50, 75.0)),
        "claude-3-5-haiku" => ModelPrice::flat(Rates::anthropic(0.80, 0.08, 4.0)),
        _ => return None,
    };
    Some(price)
}

/// Above 272K input tokens the whole request pays the long rates. A model with no cache-write
/// rate bills those tokens as input.
fn openai(id: &str) -> Option<ModelPrice> {
    const LONG: u64 = 272_001;
    let price = match id {
        "gpt-6-astra" => ModelPrice::tiered(
            Rates::new(10.0, 1.0, 12.50, 50.0),
            LONG,
            Rates::new(20.0, 2.0, 25.0, 75.0),
        ),
        "gpt-6.1-sol" => ModelPrice::tiered(
            Rates::new(2.0, 0.10, 2.50, 10.0),
            LONG,
            Rates::new(4.0, 0.20, 5.0, 15.0),
        ),
        "gpt-6-sol" => ModelPrice::tiered(
            Rates::new(2.0, 0.20, 2.50, 10.0),
            LONG,
            Rates::new(4.0, 0.40, 5.0, 15.0),
        ),
        "gpt-6-luna" => ModelPrice::tiered(
            Rates::new(0.10, 0.01, 0.125, 0.50),
            LONG,
            Rates::new(0.20, 0.02, 0.25, 0.75),
        ),
        // A promotional price, "at least through November 21, 2026".
        "gpt-5.6-sol" => ModelPrice::tiered(
            Rates::new(4.0, 0.40, 5.0, 20.0),
            LONG,
            Rates::new(8.0, 0.80, 10.0, 30.0),
        ),
        "gpt-5.6-terra" => ModelPrice::tiered(
            Rates::new(2.0, 0.20, 2.50, 12.0),
            LONG,
            Rates::new(4.0, 0.40, 5.0, 18.0),
        ),
        "gpt-5.6-luna" => ModelPrice::tiered(
            Rates::new(0.20, 0.02, 0.25, 1.20),
            LONG,
            Rates::new(0.40, 0.04, 0.50, 1.80),
        ),
        "gpt-5.5" => ModelPrice::tiered(
            Rates::new(5.0, 0.50, 5.0, 30.0),
            LONG,
            Rates::new(10.0, 1.0, 10.0, 45.0),
        ),
        "gpt-5.4" => ModelPrice::tiered(
            Rates::new(2.50, 0.25, 2.50, 15.0),
            LONG,
            Rates::new(5.0, 0.50, 5.0, 22.50),
        ),
        "gpt-5.3-codex" => ModelPrice::flat(Rates::new(1.75, 0.175, 1.75, 14.0)),
        // `gpt-5.3-codex-spark` was only ever served in Codex and has no API price.
        _ => return None,
    };
    Some(price)
}

/// Off-peak is half the peak price. Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday to
/// Friday (Chinese public holidays, which are off-peak too, are not known here).
fn deepseek(id: &str, at: SystemTime) -> Option<ModelPrice> {
    // There is no cache-write charge: a cache miss is billed as input.
    let peak = match id {
        "deepseek-v4-pro" => Rates::new(1.32, 0.044, 1.32, 3.96),
        "deepseek-flash" | "deepseek-v4-flash" | "deepseek-v4-flash-vision-exp" => {
            Rates::new(0.30, 0.006, 0.30, 1.20)
        }
        _ => return None,
    };
    let rates = if deepseek_peak(at) {
        peak
    } else {
        peak.scaled(0.5)
    };
    Some(ModelPrice::flat(rates))
}

fn deepseek_peak(at: SystemTime) -> bool {
    let seconds = at
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let days = seconds / 86_400;
    let hour = (seconds % 86_400) / 3_600;
    // 1970-01-01 was a Thursday; 0 is Monday here.
    let weekday = (days + 3) % 7;
    weekday < 5 && ((1..4).contains(&hour) || (6..10).contains(&hour))
}

/// Z.ai's USD prices; bigmodel.cn bills the same models in CNY. Cache storage is free for now and
/// writes are billed as input.
fn glm(id: &str) -> Option<ModelPrice> {
    let price = match id {
        "glm-5.3" => ModelPrice::flat(Rates::new(1.40, 0.26, 1.40, 4.40)),
        "glm-5.3-flash" => ModelPrice::flat(Rates::new(0.15, 0.03, 0.15, 0.50)),
        "glm-5.3-flashx" => ModelPrice::flat(Rates::new(0.37, 0.075, 0.37, 1.25)),
        _ => return None,
    };
    Some(price)
}

/// A request whose prompt reaches 200K tokens pays the long rates for all of its tokens. xAI
/// reports each request's cost itself, so these stand in only when it does not.
fn xai(id: &str) -> Option<ModelPrice> {
    let price = match id {
        "grok-4.7" | "grok-4.6" => ModelPrice::tiered(
            Rates::new(2.0, 0.50, 2.0, 6.0),
            200_000,
            Rates::new(4.0, 1.0, 4.0, 12.0),
        ),
        "grok-4.5" => ModelPrice::tiered(
            Rates::new(2.0, 0.30, 2.0, 6.0),
            200_000,
            Rates::new(4.0, 0.60, 4.0, 12.0),
        ),
        _ => return None,
    };
    Some(price)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// Saturday 2026-10-17 12:00 UTC: off-peak for DeepSeek.
    fn weekend() -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_792_238_400)
    }

    fn tokens(input: u64, cache_read: u64, cache_write: u64, output: u64) -> CallTokens {
        CallTokens {
            input,
            cache_read,
            cache_write,
            output,
        }
    }

    #[test]
    fn hosts_pick_their_list() {
        for (url, list) in [
            ("https://api.anthropic.com/v1", Some(PriceList::Anthropic)),
            (
                "https://chatgpt.com/backend-api/codex",
                Some(PriceList::OpenAi),
            ),
            ("https://api.openai.com/v1", Some(PriceList::OpenAi)),
            ("https://api.deepseek.com", Some(PriceList::DeepSeek)),
            ("https://api.z.ai/api/coding/paas/v4", Some(PriceList::Glm)),
            (
                "https://open.bigmodel.cn/api/coding/paas/v4",
                Some(PriceList::Glm),
            ),
            ("https://api.x.ai/v1", Some(PriceList::Xai)),
            ("https://openrouter.ai/api/v1", Some(PriceList::OpenRouter)),
            ("http://127.0.0.1:9/v1", None),
            ("https://notanthropic.com/v1", None),
            (
                "https://user@api.anthropic.com:443/v1",
                Some(PriceList::Anthropic),
            ),
        ] {
            assert_eq!(PriceList::for_base_url(url), list, "{url}");
        }
    }

    #[test]
    fn ids_lose_their_namespace_and_release_date() {
        assert_eq!(normalize("anthropic/claude-opus-5-5"), "claude-opus-5-5");
        assert_eq!(normalize("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
        assert_eq!(normalize("GPT-5.5-2026-04-23"), "gpt-5.5");
        assert_eq!(normalize("gpt-5.6-sol"), "gpt-5.6-sol");
        assert_eq!(normalize("glm-5.3"), "glm-5.3");
    }

    #[test]
    fn an_anthropic_call_pays_for_each_bucket() {
        let price = listed_price(Some(PriceList::Anthropic), "claude-opus-5-5", weekend()).unwrap();
        // 1M uncached at $4, 10M read at $0.20, 1M written at $8 (one hour) or $5, 100K out at $20.
        let call = tokens(1_000_000, 10_000_000, 1_000_000, 100_000);
        assert!((price.cost_usd(&call, true) - 16.0).abs() < 1e-9);
        assert!((price.cost_usd(&call, false) - 13.0).abs() < 1e-9);
        assert_eq!(price.cost_usd_ticks(&call, true), 160_000_000_000);
    }

    #[test]
    fn a_long_prompt_pays_the_long_rates_for_everything() {
        let haiku = listed_price(None, "claude-haiku-5-5", weekend()).unwrap();
        let short = tokens(100_000, 0, 0, 1_000_000);
        let long = tokens(100_001, 0, 0, 1_000_000);
        assert!((haiku.cost_usd(&short, false) - (0.01 + 0.50)).abs() < 1e-9);
        assert!((haiku.cost_usd(&long, false) - (0.0500005 + 2.50)).abs() < 1e-9);
        let grok = listed_price(Some(PriceList::Xai), "grok-4.6", weekend()).unwrap();
        assert!((grok.cost_usd(&tokens(0, 200_000, 0, 0), false) - 0.2).abs() < 1e-9);
    }

    #[test]
    fn calls_added_together_pay_the_rates_of_their_average_prompt() {
        let haiku = listed_price(None, "claude-haiku-5-5", weekend()).unwrap();
        // Ten calls, 1.5M prompt tokens: 150K each on average, so all pay the >100K rates.
        let long = tokens(1_500_000, 0, 0, 0);
        assert_eq!(
            haiku.cost_usd_ticks_over_calls(&long, 10, false),
            7_500_000_000
        );
        // Twenty calls of 75K each pay the short rates.
        assert_eq!(
            haiku.cost_usd_ticks_over_calls(&long, 20, false),
            1_500_000_000
        );
        // Zero calls counts as one rather than dividing by zero.
        assert_eq!(
            haiku.cost_usd_ticks_over_calls(&tokens(1_000, 0, 0, 0), 0, false),
            1_000_000
        );
    }

    #[test]
    fn deepseek_is_cheaper_off_peak() {
        // Wednesday 2026-10-14 02:00 UTC is peak; 12:00 the same day is not.
        let peak = UNIX_EPOCH + Duration::from_secs(1_791_943_200);
        let afternoon = peak + Duration::from_secs(10 * 3_600);
        let call = tokens(1_000_000, 0, 0, 1_000_000);
        let at = |time| {
            listed_price(Some(PriceList::DeepSeek), "deepseek-v4-pro", time)
                .unwrap()
                .cost_usd(&call, false)
        };
        assert!((at(peak) - 5.28).abs() < 1e-9);
        assert!((at(afternoon) - 2.64).abs() < 1e-9);
        assert!((at(weekend()) - 2.64).abs() < 1e-9);
    }

    #[test]
    fn unknown_models_and_hosts_have_no_price() {
        assert!(listed_price(Some(PriceList::OpenAi), "gpt-5.3-codex-spark", weekend()).is_none());
        assert!(listed_price(None, "llama3", weekend()).is_none());
        // OpenRouter is priced from its catalog.
        assert!(
            listed_price(
                Some(PriceList::OpenRouter),
                "anthropic/claude-opus-5-5",
                weekend()
            )
            .is_none()
        );
        // An endpoint this build does not know is searched by model id.
        assert!(listed_price(None, "glm-5.3", weekend()).is_some());
    }

    #[test]
    fn openrouter_prices_come_per_token() {
        let pricing = crate::openrouter::OpenRouterPricing {
            prompt: Some("0.000003".into()),
            completion: Some("0.000015".into()),
            input_cache_read: Some("0.0000003".into()),
            input_cache_write: None,
        };
        let price = openrouter_price(&pricing).unwrap();
        assert!((price.rates.input - 3.0).abs() < 1e-9);
        assert!((price.rates.cache_read - 0.3).abs() < 1e-9);
        assert!((price.rates.cache_write - 3.0).abs() < 1e-9);
        assert!((price.rates.output - 15.0).abs() < 1e-9);
        assert!(openrouter_price(&crate::openrouter::OpenRouterPricing::default()).is_none());
    }
}
