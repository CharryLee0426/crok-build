# Authentication

Crok signs in to model providers: OpenAI Codex (ChatGPT subscription), OpenRouter, the Claude API, DeepSeek, and the GLM Coding Plan. xAI accounts are not supported in this build.

## OpenRouter and OpenAI Codex

Sign in to OpenRouter in your browser:

```bash
crok login openrouter
crok models
crok --model openrouter/anthropic/claude-sonnet-4.6
```

Alternatively, set `OPENROUTER_API_KEY`, or save a key from stdin:

```bash
printenv OPENROUTER_API_KEY | crok login openrouter --with-api-key
```

An environment key takes precedence over the saved OpenRouter credential. OpenRouter's OAuth PKCE flow exchanges browser authorization for a provider API key; it uses the same inference path as an API key supplied directly.

For a ChatGPT subscription, sign in to Codex:

```bash
crok login openai-codex
crok --model openai-codex/gpt-6-astra
```

The browser callback runs on loopback (`localhost:1455` for Codex; a free local port for OpenRouter). The command also prints the login URL. Codex access tokens refresh automatically before use; subscription model access and limits depend on your account. This uses the Codex subscription endpoint, not OpenAI Platform API billing.

## Anthropic (Claude API)

The Claude API signs in with an API key from the [Claude Console](https://platform.claude.com/settings/keys) and is billed per token against the Console's credit. There is no browser sign-in. A Claude subscription (Pro or Max) is a different product and does not sign in here.

```bash
crok login anthropic        # `crok login claude` is the same command
crok models
crok --model anthropic/claude-opus-5-5
```

`crok login anthropic` asks for the key in the terminal and does not show it as you paste. Crok checks the key with Anthropic before saving it. Two other credentials look like an API key and cannot send messages: an Admin API key (`sk-ant-admin...`) and a Claude subscription token (`sk-ant-oat...`). Both are refused with a message that says which one it is. Alternatively, set `ANTHROPIC_API_KEY`, or save a key from stdin:

```bash
printenv ANTHROPIC_API_KEY | crok login anthropic --with-api-key
```

`ANTHROPIC_API_KEY` is a variable other tools set too. If it is in your environment, Crok offers the Anthropic models and bills that key when you pick one. With no other provider signed in, it starts on `anthropic/claude-opus-5-5`.

Signing in fetches your account's model list, which then refreshes every hour. `/effort` offers the levels each model lists (`low` to `max` on current models), with the model's own default preselected: `medium` on Opus 5.5 and Haiku 5.5, `high` on the others. Models that only think with a token budget (Haiku 4.5 and the 4.5 generation) run without thinking.

### Prompt caching

Anthropic bills input it has cached at a tenth of the input price or less, and it caches only up to the points a request marks. A request may mark four, and Crok uses all four: the tool list, the system prompt, the end of the previous request, and the newest message. Each request then reads everything the one before it sent and pays the full price only for what was added.

Entries are kept for an hour. Anthropic's default is five minutes, which is cheaper to write (1.25 times the input price, against 2 times) and is lost whenever more than five minutes pass between two requests: while you read a reply, during a long build, or while a permission prompt waits. The next request then writes the whole conversation again. For unattended runs whose requests follow each other without a pause, the five-minute lifetime costs less:

```bash
CROK_ANTHROPIC_CACHE_TTL=5m crok agent ...
```

Some things start the cache over, because they change the conversation the model reads: switching model or effort level, compaction, a rewind, and the pruning of old tool results, which runs on every fifth prompt for that reason (see [`prune_every_n_turns`](13-memory.md#pruning-settings-compactionpruning)).

`crok usage <session-id>` prints what a session used, turn by turn. In a healthy session `cachedReadTokens` is close to `inputTokens` and `cacheCreationTokens` is small.

### Credit balance and usage

Anthropic has no API that returns your remaining credit. The balance is on the Console's [Billing page](https://platform.claude.com/settings/billing), where you can also turn on auto-reload.

What it does have is spend. The Admin API reports tokens and cost per day, model, workspace and API key. It needs an Admin API key (`sk-ant-admin01-...`), which only an organization can create (Console, Settings, Organization); an individual account has no Admin API. Reports lag about five minutes behind the requests.

```bash
# Cost in USD cents per day for one month, by model
curl "https://api.anthropic.com/v1/organizations/cost_report?starting_at=2026-10-01T00:00:00Z&ending_at=2026-11-01T00:00:00Z&group_by[]=description" \
  -H "anthropic-version: 2023-06-01" -H "x-api-key: $ANTHROPIC_ADMIN_KEY"

# Tokens per day, with cache reads and writes separated
curl "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-10-01T00:00:00Z&ending_at=2026-11-01T00:00:00Z&bucket_width=1d&group_by[]=model" \
  -H "anthropic-version: 2023-06-01" -H "x-api-key: $ANTHROPIC_ADMIN_KEY"
```

Remaining credit is then the balance the Billing page showed on a given day, less the cost reported since. Credit grants and their expiry are not in the report.

## DeepSeek

DeepSeek signs in with an API key from [platform.deepseek.com](https://platform.deepseek.com/api_keys). There is no browser sign-in.

```bash
crok login deepseek
crok models
crok --model deepseek/deepseek-v4-pro
```

`crok login deepseek` asks for the key in the terminal and does not show it as you paste. Crok checks the key with DeepSeek before saving it, so a mistyped key is refused on the spot. Alternatively, set `DEEPSEEK_API_KEY`, or save a key from stdin:

```bash
printenv DEEPSEEK_API_KEY | crok login deepseek --with-api-key
```

Signing in fetches your account's model list, which then refreshes every hour, so a model DeepSeek releases later appears without updating Crok. Usage is billed to your DeepSeek balance.

Thinking is on by default. `/effort` offers the levels DeepSeek lists for the model (`low`, `high`, `max`) and `none`, which turns thinking off. `deepseek-v4-pro` reads text only: an image in the conversation is replaced by a short note rather than sent.

## GLM Coding Plan

A [GLM Coding Plan](https://docs.z.ai/devpack/overview) subscription signs in with the API key of the account that holds it. There is no browser sign-in. The plan is sold on two sites that keep separate accounts, and a key from one is refused by the other, so sign in to the one you subscribed on:

| Subscribed on | Sign in | Create the key at | Environment key |
|---|---|---|---|
| z.ai | `crok login glm` | [z.ai/manage-apikey/apikey-list](https://z.ai/manage-apikey/apikey-list) | `ZAI_API_KEY` |
| bigmodel.cn (China mainland) | `crok login glm-cn` | [bigmodel.cn/coding-plan/personal/overview](https://bigmodel.cn/coding-plan/personal/overview) | `ZHIPU_API_KEY` |

```bash
crok login glm
crok --model glm/glm-5.3

# or, for a subscription from bigmodel.cn
crok login glm-cn
crok --model glm-cn/glm-5.3
```

Both commands ask for the key in the terminal without showing it, and check it with the site before saving. A refused key is not saved, and the message names the other command, since a key from the other site is the usual cause. To save a key from stdin instead:

```bash
printenv ZAI_API_KEY | crok login glm --with-api-key
```

Requests go to the plan's own coding endpoint, which is what draws on the subscription's quota. Every plan tier includes `glm-5.3` (text only) and `glm-5.3-flash` (also reads images). These models always reason: `/effort` offers `low`, `high`, and `max`, and there is no way to turn reasoning off.

The plan's terms limit it to the coding tools its provider lists ([z.ai](https://docs.z.ai/devpack/tool/others)), and Crok is not on that list. Whether to use your subscription here is your decision; the provider may restrict a subscription used outside its listed tools.

## Credentials

Provider credentials are kept in `~/.crok/provider-auth/` (under `$CROK_HOME` when set), with atomic writes and owner-only file permissions on Unix. To remove saved credentials:

```bash
crok logout openrouter
crok logout openai-codex
crok logout anthropic
crok logout deepseek
crok logout glm        # or glm-cn
```

A key in the environment (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `ZHIPU_API_KEY`) takes precedence over the saved one, and `crok logout` does not remove it; unset it as well if you want to stop using it. Plain `crok logout` signs out of every provider. See [custom models](11-custom-models.md#openrouter-model-discovery) for catalog refresh and provider configuration.

## First launch

On the first interactive launch without a provider credential or an explicit model choice, Crok asks which provider to sign in to: OpenAI Codex, OpenRouter, DeepSeek, a GLM Coding Plan from z.ai or bigmodel.cn, or the Claude API. If you skip it, or start the TUI with no usable credential, the welcome screen tells you to quit and run `crok login` with a provider.

## Headless and CI

Set the provider's key in the environment (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, or `ZHIPU_API_KEY`), or pipe a key to `crok login <provider> --with-api-key` once. Codex sign-in needs a browser, so run `crok login openai-codex` on a machine with one and copy `~/.crok/provider-auth/` if needed.

## Custom models

A `[model.<id>]` entry with its own `api_key` or `env_key` authenticates by itself and needs no provider sign-in. See [custom models](11-custom-models.md).

## xAI accounts

xAI account support has been removed from this build:

- `crok login` requires a provider; `--oauth`, `--device-auth`, and browser login to grok.com are gone, as are enterprise OIDC/SSO and external auth provider commands.
- Saved xAI sessions in `~/.crok/auth.json` are ignored.
- The `/login`, `/logout`, and `/privacy` commands are gone, along with SuperGrok billing and the xAI voice provider.
- Models served by xAI's own API are hidden from the model picker unless `XAI_API_KEY` is set in the environment (a plain API key, not an account sign-in). Grok models are also available through OpenRouter, for example `crok --model openrouter/x-ai/grok-4`.
