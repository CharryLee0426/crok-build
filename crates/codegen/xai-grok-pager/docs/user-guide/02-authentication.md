# Authentication

Grok signs in to model providers: OpenRouter and OpenAI Codex (ChatGPT subscription). xAI accounts are not supported in this build.

## OpenRouter and OpenAI Codex

Sign in to OpenRouter in your browser:

```bash
grok login openrouter
grok models
grok --model openrouter/anthropic/claude-sonnet-4.6
```

Alternatively, set `OPENROUTER_API_KEY`, or save a key from stdin:

```bash
printenv OPENROUTER_API_KEY | grok login openrouter --with-api-key
```

An environment key takes precedence over the saved OpenRouter credential. OpenRouter's OAuth PKCE flow exchanges browser authorization for a provider API key; it uses the same inference path as an API key supplied directly.

For a ChatGPT subscription, sign in to Codex:

```bash
grok login openai-codex
grok --model openai-codex/gpt-6-astra
```

The browser callback runs on loopback (`localhost:1455` for Codex; a free local port for OpenRouter). The command also prints the login URL. Codex access tokens refresh automatically before use; subscription model access and limits depend on your account. This uses the Codex subscription endpoint, not OpenAI Platform API billing.

Provider credentials are kept in `~/.grok/provider-auth/` (under `$GROK_HOME` when set), with atomic writes and owner-only file permissions on Unix. To remove saved credentials:

```bash
grok logout openrouter
grok logout openai-codex
```

Unset `OPENROUTER_API_KEY` as well if you want to stop using an environment key. Plain `grok logout` signs out of every provider. See [custom models](11-custom-models.md#openrouter-model-discovery) for catalog refresh and provider configuration.

## First launch

On the first interactive launch without a provider credential or an explicit model choice, Grok asks which provider to sign in to (OpenAI Codex or OpenRouter). If you skip it, or start the TUI with no usable credential, the welcome screen tells you to quit and run `grok login openai-codex` or `grok login openrouter`.

## Headless and CI

Set `OPENROUTER_API_KEY` in the environment, or pipe a key to `grok login openrouter --with-api-key` once. Codex sign-in needs a browser, so run `grok login openai-codex` on a machine with one and copy `~/.grok/provider-auth/` if needed.

## Custom models

A `[model.<id>]` entry with its own `api_key` or `env_key` authenticates by itself and needs no provider sign-in. See [custom models](11-custom-models.md).

## xAI accounts

xAI account support has been removed from this build:

- `grok login` requires a provider; `--oauth`, `--device-auth`, and browser login to grok.com are gone, as are enterprise OIDC/SSO and external auth provider commands.
- Saved xAI sessions in `~/.grok/auth.json` are ignored.
- The `/login`, `/logout`, and `/privacy` commands are gone, along with SuperGrok billing and the xAI voice provider.
- Models served by xAI's own API are hidden from the model picker unless `XAI_API_KEY` is set in the environment (a plain API key, not an account sign-in). Grok models are also available through OpenRouter, for example `grok --model openrouter/x-ai/grok-4`.
