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
| span only | `crok.backend` (`openai_codex`, `glm`, `deepseek`, `messages`, …); `crok.cost.usd` with `crok.cost.source`: the provider's own cost when it reports one (`provider`: OpenRouter, xAI), else the model's standard API price for the call's tokens (`list_price`, from `xai-grok-models::pricing`, the table `/usage` estimates with), whatever paid for it; no cost for a model neither knows (an OpenRouter model, since a reported $0 counts as unreported and OpenRouter's catalog prices are not read here: its Broadcast export carries the bill); `crok.cancelled = true` on a call the user interrupted; `crok.unsampled = true` on a call Claude Platform was told not to export (below), with its cache reads and thinking tokens also under Claude Platform's names (`gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.reasoning.output_tokens`, zeros included) so a dashboard ratio reads both sources' spans in one query |

### crok's own report for providers without traces

Claude Platform and OpenRouter export a span of every request to Grafana themselves. OpenAI Codex
(ChatGPT sign-in), GLM (Z.ai and BigModel), DeepSeek and xAI do not, so crok's span is the only
record of those calls. That is why the span carries the cost: Agent Observability prices only the
models in its own catalog (Claude and OpenRouter's), and Tempo keeps what the span says. The
dashboards in `observability/grafana-llm` read crok's spans for every provider other than
`anthropic` and `openrouter` (which would count twice), plus the Claude calls marked
`crok.unsampled`, which Claude Platform no longer exports; its history rules keep them for
14 days. Nothing extra is switched on: it is the same span, sent wherever the rest of this goes.

Text parts are cut at 64 KiB each (the SDK refuses a generation over 4 MiB). Images are not sent.
The SDK's secret redaction runs before export (`CROK_AGENTO11Y_REDACT_SECRETS=false` turns it off),
and `AGENTO11Y_CONTENT_CAPTURE_MODE=metadata_only` keeps all text out.

Not recorded as generations: compaction (it streams outside the sampler; it is a workflow step,
below), image generation, embeddings, voice.

### Around the calls: turns, tools, steps, verdicts, ratings, guards

The session reports what happens between model calls through the same sink
(`xai-grok-sampler/src/observe_harness.rs`), and the bridge records it (`bridge/src/harness.ts`):

| | |
|---|---|
| turn | span `invoke_agent crok` (or `crok/<sub-agent>`), the root of the turn's trace. crok makes its trace and span ids when the turn starts, so the turn's generations and tool runs, recorded earlier, are its children; a sub-agent's turn is a child of the parent turn that started it. `crok.turn.outcome` (`completed`, `cancelled`, `max_turns`, `stationarity`, `error`), `crok.turn_index`, `crok.model_calls`, `crok.tool_calls`, `crok.tool_errors`, `crok.permission_mode`, `crok.origin`, `gen_ai.request.model` |
| tool run | span `execute_tool <tool>` through the SDK's tool recorder (no arguments or output: `no_tool_content`), with `crok.tool.outcome` (`success`, `error`, `cancelled`), `crok.tool.kind` (`read_only`, `mutating`, `other`), `crok.tool.exit_code`, `crok.tool.result_bytes`, `crok.tool.backgrounded`; the error's first line as the span status |
| steps | Agent Observability workflow steps on the conversation, linked to the newest generation: `permission` (decision, source, wait), `hook PreToolUse` (allow, ask, rewrite, deny; only when hooks are set up), `compaction` (trigger, model, tokens before and after, outcome), `mcp_server` (each MCP server start: connected or failed, with the error type) |
| verdicts | scores on the newest generation (`POST /api/v1/scores:export`, after the generation is flushed): `crok.goal_verdict` (`continue`, `candidate_complete`, `blocked`), `crok.laziness` (the classifier's category), `crok.identical_call_guard` (`nudged` with the run length, `halted`), `crok.max_turns_hit` |
| rating | the user's feedback, folded to good or bad (thumbs, 4-5 or 1-2 stars, NPS 9-10 or 0-6), as an Agent Observability conversation rating, beside the xAI feedback it already went to |
| guards | `POST /api/v1/hooks:evaluate` against the stack's guards (hook rules) in warn mode: postflight with the tool calls that can change something, before they run; preflight with each tool result before it goes back to the model. crok never waits for the answer and never blocks; the stack records a warn on the conversation. `CROK_AGENTO11Y_GUARDS=off` stops the checks |
| metrics | beside the SDK's `gen_ai.client.*`, over the same OTLP: `crok_turns_total` and `crok_turn_duration_seconds` (by outcome, origin, agent, model), `crok_tool_runs_total` and `crok_tool_duration_seconds` (by tool, outcome, kind, origin), `crok_workflow_steps_total` (by step and outcome: permission decisions, hook results, compactions, `mcp_server` starts and failures), `crok_guard_checks_total` (by phase, action, flagged). The SLOs and alerts in `observability/agento11y` read them |
| tags | on everything a session reports: `repo` (the `origin` remote's owner/name, else the folder), `branch`, `user`; on the process: `origin` (`local`, `headless` for `crok -p`, `eval` under `evals/run.py`, `relay` on the turns the web and phones start), `surface`, `host`, and `eval_run` / `eval_trial` in experiments |

`gen_ai.agent.version` is the release plus the commit (`2.0.1+5ba03440`), so a dev build or an
experiment run is told apart from the release. Side calls that keep the session's conversation id
for the prompt cache are named by their request id (`crok/goal-eval`), and session titles are
`crok/title` under their session.

`devtools/fake_stack.py` is a local stand-in for a stack: point an `agento11y.env` at it to see
every record crok sends, and `fake_stack.py summary` prints each turn's tree.

### Claude Platform's own export

Anthropic's API can itself export a span of every request to the organization's telemetry
destinations (Claude Console › Settings › OpenTelemetry). When that destination is the same Grafana
stack, Agent Observability turns each of those traces into a conversation of its own, under the
agent `claude-platform` and named by the trace id, so a crok session showed up once as itself and
again as one `claude-platform` conversation per turn and per side call. A call crok records
therefore goes to `api.anthropic.com` with its W3C `traceparent` marked not sampled (flags `00`,
trace and parent ids kept, or fresh ones when crok had none), and the API exports nothing for it.
The call's own span then carries `crok.unsampled = true`: it is the only trace of the call, and the
LLM dashboards count it where they count Claude Platform's spans. What crok does not record keeps
its Claude Platform spans: compaction, and every call while reporting is off
(`CROK_AGENT_OBSERVABILITY=0`). Other hosts get the header unchanged.

crok 2.0.2 and older send every Claude call both ways. Agent Observability has no way to delete
what it stored, so those copies stay until its 30-day retention drops them;
`observability/agento11y/stack.py duplicates` counts them and labels each one (see its README).

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
  (`AGENTO11Y_DEBUG=1` logs the successes too). A synchronous context manager makes a call's span
  the child of its turn, and a preset id generator gives the turn's span the ids crok chose.

## Changing the bridge

```sh
cd crates/codegen/xai-grok-agento11y/bridge
npm ci --ignore-scripts
npm run typecheck && npm test
npm run build    # rewrites dist/agento11y-bridge.mjs, which crok embeds; commit it
npm run check    # fails when the committed bundle is out of date
```

The npm packages are pinned exactly in `package-lock.json`. Building crok itself needs no Node.
