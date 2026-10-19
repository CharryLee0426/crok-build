# Agent Observability for crok

Sends every model call crok makes, in the terminal and in Crok Desktop, to
[Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/),
using the agento11y TypeScript SDK (`@grafana/agento11y-core`).

## Where reports go

Every install reports, with nothing to set up and nothing in Settings: release builds carry the
destination. `build.rs` reads the settings file `CROK_AGENTO11Y_BUILTIN_ENV` names (the Makefile
passes `~/.crok/agento11y.env` when the building Mac has one; `release/publish.sh` refuses to
release without it), keeps its `AGENTO11Y_*` and `OTEL_*` lines other than `AGENTO11Y_DEBUG` and
`AGENTO11Y_ENABLED`, and masks them into the binary, so the token never enters the repository and
is not plain text in the binary. `crok version --json` names the built-in endpoint's host
(`agentObservability`).

On one machine, in order:

1. `~/.crok/agento11y.env`, when it exists, is the whole configuration (another stack, or
   `AGENTO11Y_ENABLED=false` to stop sending).
2. Else the built-in destination. Inherited `AGENTO11Y_*` and `OTEL_*` variables are ignored, so an
   exporter set up for another tool cannot redirect crok's data.
3. Else (a build without one) the same variables exported in the environment.

`[features] agent_observability = false` in `~/.crok/config.toml`, or `CROK_AGENT_OBSERVABILITY=0`,
stops sending too. Neither app shows it; it is for test runs against stand-in models.

### Writing a settings file

Get the values from the stack's Agent Observability Connection page
(`https://<stack>.grafana.net/plugins/grafana-agento11y-app`), with a Grafana Cloud access policy
token that has `sigil:write`, `metrics:write`, `traces:write` and `logs:write`. Then:

```sh
bash crates/codegen/xai-grok-agento11y/setup.sh \
  --endpoint https://agento11y-prod-<region>.grafana.net --tenant <instance id> \
  --otlp-endpoint https://otlp-gateway-prod-<region>.grafana.net/otlp
```

It asks for the token with the input hidden and writes `~/.crok/agento11y.env` (mode 600):

```dotenv
AGENTO11Y_ENDPOINT=…
AGENTO11Y_PROTOCOL=http
AGENTO11Y_AUTH_MODE=basic
AGENTO11Y_AUTH_TENANT_ID=…
AGENTO11Y_AUTH_TOKEN=glc_…
OTEL_EXPORTER_OTLP_ENDPOINT=…/otlp
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 of instance:token>"
```

The next release built on that Mac carries the new file.

Every crok process follows `config.toml` and `agento11y.env` while it runs: a TUI, and each Crok
Desktop conversation (each runs its own `crok agent stdio`). A change applies from the next model
call, with no restart.

### Node

The bridge runs on Node 20 or newer (or Bun). crok looks on `PATH`, then in nvm, Homebrew, Volta
and asdf; `CROK_AGENTO11Y_NODE=/path/to/node` in the file names one. A machine with none gets the
official Node build pinned in `src/node.rs` (an LTS release, checked against its SHA-256),
downloaded once from nodejs.org into `~/.crok/agento11y/` the first time crok makes a model call,
about 50 MB. A failed download is tried again 15 minutes later.

## What is sent

One generation per model API request (a retried request is one per attempt):

| | |
|---|---|
| agent | `crok` for the session's own turns, `crok/<type>` for a sub-agent's, `crok/<kind>` for side calls (`crok/turn-summary`, `crok/recap`, `crok/perm-classifier`, …) |
| conversation | the crok session id, named by the session title; a sub-agent has its own, and its first generation links to the parent turn that started it (`parent_generation_ids`) |
| version | crok's release (`VERSION`), as `gen_ai.agent.version` |
| request | provider, model, system prompt, tool definitions, max tokens / temperature / top-p, tool choice, reasoning effort |
| input | only what was added since the model last spoke: the user's prompt, or the tool results it asked for. The conversation view rebuilds the thread from the sequence |
| output | thinking, text and tool calls |
| result | response id and model, stop reason, tokens (input, output, cache read, cache write, reasoning), the provider's own cost when it reports one, time to first token |
| errors | the provider's message and HTTP status (429 shows as `rate_limit`); an interrupted turn as `cancelled` |
| tags | `call_kind`, `backend`, `surface` (`tui`, `desktop`, `agent`), `host` (the machine's name, without `.local`); `surface` and `host` are client tags, so they reach the spans and metrics too |

Text parts are cut at 64 KiB each (the SDK refuses a generation over 4 MiB). Images are not sent.
The SDK's secret redaction runs before export (`CROK_AGENTO11Y_REDACT_SECRETS=false` turns it off),
and `AGENTO11Y_CONTENT_CAPTURE_MODE=metadata_only` keeps all text out.

Not recorded: compaction (it streams outside the sampler), image generation, embeddings, voice.

## How it works

```
sampler (Rust)                               bridge (Node, TypeScript SDK)
  run_one_attempt / conversation_collect       startStreamingGeneration + setResult
  └ observe::watch ── JSON line on stdin ──▶   ├ generation ──▶ AGENTO11Y_ENDPOINT
                                               └ spans, gen_ai.client.* metrics ──▶ OTLP gateway
```

- `xai-grok-sampler/src/observe.rs` snapshots each request and records it when its event stream
  completes, fails or is dropped. Before the snapshot it asks the sink whether it is active; while
  it is off that costs a `stat` of `config.toml` per request and nothing is copied.
- `src/` follows the switch and the settings (`switch.rs`: each file is read again only when its
  modification time or size moves), finds or fetches Node (`node.rs`), and runs one bridge per
  crok process. The bridge
  starts at the first model call, stops after five idle minutes (`CROK_AGENTO11Y_IDLE_SECS`),
  restarts with new settings when `agento11y.env` changes, and flushes when crok exits. Records
  queue in memory (256) and are dropped, never waited on, when it lags.
- `bridge/` is the TypeScript side. It creates the OpenTelemetry tracer and meter providers the
  SDK records into (without them every span and metric is silently lost), replays each call with
  crok's own timestamps, and logs every export result to `~/.crok/logs/agento11y.log`
  (`AGENTO11Y_DEBUG=1` logs the successes too).

## Changing the bridge

```sh
cd crates/codegen/xai-grok-agento11y/bridge
npm ci --ignore-scripts
npm run typecheck && npm test
npm run build    # rewrites dist/agento11y-bridge.mjs, which crok embeds; commit it
npm run check    # fails when the committed bundle is out of date
```

The npm packages are pinned exactly in `package-lock.json`. Building crok itself needs no Node.
