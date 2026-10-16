# Agent Observability for crok

Sends every model call crok makes, in the terminal and in Crok Desktop, to
[Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/),
using the agento11y TypeScript SDK (`@grafana/agento11y-core`).

## Turning it on

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

New crok processes read it at start: a new TUI, or a new Crok Desktop conversation (each runs its
own `crok agent stdio`). Without the file, the same variables exported in the environment work too;
with it, inherited `AGENTO11Y_*` and `OTEL_*` variables are ignored. Delete the file, or add
`AGENTO11Y_ENABLED=false`, to stop.

Node 20 or newer is needed (or Bun). crok looks on `PATH`, then in nvm, Homebrew, Volta and asdf;
`CROK_AGENTO11Y_NODE=/path/to/node` in the file names one.

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
| tags | `call_kind`, `backend`, `surface` (`tui`, `desktop`, `agent`); `surface` is also a client tag, so it reaches the spans and metrics |

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
  completes, fails or is dropped. It costs one atomic load per request when nothing is installed.
- `src/` loads the settings, finds Node, and runs one bridge per crok process. The bridge starts
  at the first model call, stops after five idle minutes (`CROK_AGENTO11Y_IDLE_SECS`), and flushes
  when crok exits. Records queue in memory (256) and are dropped, never waited on, when it lags.
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
