# Authentication

Crok signs in to model providers: OpenAI Codex (ChatGPT subscription), OpenRouter, DeepSeek, and the GLM Coding Plan. xAI accounts are not supported in this build.

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
crok logout deepseek
crok logout glm        # or glm-cn
```

A key in the environment (`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `ZHIPU_API_KEY`) takes precedence over the saved one, and `crok logout` does not remove it; unset it as well if you want to stop using it. Plain `crok logout` signs out of every provider. See [custom models](11-custom-models.md#openrouter-model-discovery) for catalog refresh and provider configuration.

## First launch

On the first interactive launch without a provider credential or an explicit model choice, Crok asks which provider to sign in to: OpenAI Codex, OpenRouter, DeepSeek, or a GLM Coding Plan from z.ai or bigmodel.cn. If you skip it, or start the TUI with no usable credential, the welcome screen tells you to quit and run `crok login` with a provider.

## Headless and CI

Set the provider's key in the environment (`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, or `ZHIPU_API_KEY`), or pipe a key to `crok login <provider> --with-api-key` once. Codex sign-in needs a browser, so run `crok login openai-codex` on a machine with one and copy `~/.crok/provider-auth/` if needed.

## Custom models

A `[model.<id>]` entry with its own `api_key` or `env_key` authenticates by itself and needs no provider sign-in. See [custom models](11-custom-models.md).

## xAI accounts

xAI account support has been removed from this build:

- `crok login` requires a provider; `--oauth`, `--device-auth`, and browser login to grok.com are gone, as are enterprise OIDC/SSO and external auth provider commands.
- Saved xAI sessions in `~/.crok/auth.json` are ignored.
- The `/login`, `/logout`, and `/privacy` commands are gone, along with SuperGrok billing and the xAI voice provider.
- Models served by xAI's own API are hidden from the model picker unless `XAI_API_KEY` is set in the environment (a plain API key, not an account sign-in). Grok models are also available through OpenRouter, for example `crok --model openrouter/x-ai/grok-4`.
