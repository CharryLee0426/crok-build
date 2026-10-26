# LLM observability in Grafana Cloud (Claude Platform + OpenRouter + crok)

For people who bring their own keys: send the OpenTelemetry traces of every Claude API and
OpenRouter request to Grafana Cloud, and get dashboards for spend, tokens, prompt cache, latency,
errors and single requests. Claude Platform and OpenRouter export the traces themselves, for any
client.

Providers that export nothing (OpenAI Codex, GLM, DeepSeek, xAI, local models) are covered by crok
itself: its Agent Observability bridge (`crates/codegen/xai-grok-agento11y`, on by default, same
stack) sends a span of every model call, with crok's own figure for what the call cost. The
dashboards read those spans for every provider except Claude and OpenRouter, which would count
twice. crok 2.0.0 and older send no figure; the dashboards price their calls from their tokens.
Nothing to set up for them.

One exception for Claude: crok after 2.0.2 asks Claude Platform not to export the Claude calls it
reports itself (Agent Observability made a second, `claude-platform` conversation of each), and
marks its own span of such a call `crok.unsampled = true`. That span is then the call's only one,
and the dashboards count it with Claude's: Claude Platform's spans plus crok's marked ones. Older
crok's Claude calls still reach Claude Platform's export, so their crok spans stay left out.

| File | What it is |
| --- | --- |
| `setup.sh` | The guided setup, one subcommand per step. Made for agents to run; people can run it too. |
| `build_dashboards.py` | Builds the seven dashboards and the history recording rules for a stack (standard library only). |
| `prices.json` | Claude list prices used to estimate Claude spend, and Codex, DeepSeek and GLM prices for the calls of crok 2.0.0 and older. Same tables as `xai-grok-models::pricing`. |
| `dashboards/` | The last built dashboards as gcx manifests (folder `llm-observability`). |
| `rules/llm-history.json` | The last built recording-rule group (Grafana provisioning API format). |
| `backfill.py` | Fetches Claude and OpenRouter usage from their APIs for the time the recording rules did not record (standard library only). |
| `backfill/llm-backfill.json` | Its daily totals, embedded in LLM Spend History. `backfill/raw/` keeps the API responses (git-ignored). |

## Quick start

```sh
observability/grafana-llm/setup.sh all
```

It installs `gcx` (the Grafana Cloud CLI), signs it in to your stack in the browser, prints the
values to paste into the Claude Console and OpenRouter, waits for the first spans, and pushes the
dashboards. Run `setup.sh help` for the single steps.

## For agents

Run the steps one at a time and stop at every `ACTION FOR THE USER` block: show it to the user and
continue when they say it is done.

1. `setup.sh install`, then `setup.sh login https://<stack>.grafana.net` (ask the user for the
   stack URL if `setup.sh login` says it needs one). The user approves the sign-in in the browser.
2. `setup.sh info` shows the instance ID and OTLP endpoint the next steps need.
3. `setup.sh token`, `setup.sh claude`, `setup.sh openrouter` print what the user does in
   grafana.com, the Claude Console and OpenRouter. Skip a provider the user does not use.
4. `setup.sh verify --wait 10` until spans arrive from each provider in use. It also lists crok's
   own reports; those need no step (a crok session that calls Codex, GLM or DeepSeek sends them).
5. `setup.sh dashboards` (dashboards and history rules), then `setup.sh snapshot <dir>` and look
   at the PNGs.
6. Optional: `setup.sh backfill` adds up to two months of earlier usage to LLM Spend History. It
   needs a Claude Admin API key and an OpenRouter management key in the user's Keychain; it prints
   how when they are missing.

Rules:

- Never ask for a token or key in the chat. The token goes from grafana.com straight into the
  Claude Console and OpenRouter forms. `setup.sh claude-api` reads `ANTHROPIC_ADMIN_KEY` and
  `GRAFANA_OTLP_TOKEN` from the environment of the user's own shell, and adds the destination only
  after the user agrees (`YES=1`).
- "Full content" export puts prompts and responses in Grafana. Let the user choose it.
- Check the result with `setup.sh verify` and `setup.sh snapshot`, not by assuming.

## What the dashboards show

- **LLM Overview**: requests, spend, tokens, Claude cache hit rate, error rate and p95 latency over
  the time range; week over week (last 7 days against the 7 before) and the last 14 days per day,
  from the recorded history; traffic, spend, latency and errors over time (crok's reports split
  by provider); models ranked; latest calls.
- **Claude Platform**: estimated spend by model, token mix (uncached input, cache reads, 5-minute
  and 1-hour cache writes, output), cache hit rate by model, latency and output speed, stop
  reasons, errors, HTTP status, effort, service tier, workspaces, latest requests with their
  request-id, and server/MCP tools and Managed Agents (collapsed). Requests, spend, tokens, cache
  hit rate, thinking share, latency, errors and the latest requests include the Claude calls crok
  reports in Claude Platform's place (spend at crok's own figure); token mix, stop reasons, error
  types, HTTP status, effort, tier and workspaces are Claude Platform's spans alone.
- **OpenRouter**: billed spend by model, API key, upstream provider, user and session; tokens;
  latency; finish reasons; errors; latest generations. Filters: model and API key (regex).
- **Codex, GLM and DeepSeek** (`llm-crok`): what crok reported for providers without traces of
  their own. Spend (crok's figure per call; for crok 2.0.0 and older, the call's tokens at
  `prices.json` rates), tokens, provider cache hit rate, errors, cancelled
  and rate-limited calls, unpriced calls; week over week and 14 days per day by provider and
  model; spend by model, provider and agent; token kinds; duration, time to first token (the SDK's
  Prometheus histogram) and output speed; finish reasons, failure categories, backend, agent,
  surface (TUI or Desktop) and machine; latest calls. Filters: provider and model.
- **crok Harness** (`llm-crok-harness`): what crok does between model calls, from the turn traces crok
  releases after 2.0.1 send (a turn is one trace: its `invoke_agent` root span holds its model calls
  and `execute_tool` spans). Turns, completion rate, p50 and p90 turn time, model calls and tool
  runs per turn; turns by outcome over time, by origin (local, headless, relay), model and agent
  version; p90 turn time and model calls per turn by model; tool runs, failures and p90 time by tool,
  tool failure rate, tool kinds, backgrounded commands; tables of the latest turns, the turns that
  did not complete and the failed tool runs. Filter: repository (regex). Experiment runs
  (`origin=eval`) are left out. Evaluation scores, rules and guards are in Agent Observability
  (`observability/agento11y/`).
- **LLM Request Explorer**: find single calls by source (Claude Platform, OpenRouter, crok),
  model, minimum duration and status (failed, succeeded, cancelled), over any range up to 14 days,
  plus saved searches: failed, slow, cut off by max_tokens, huge prompts, expensive calls
  (OpenRouter's bill or crok's figure), cache misses on big prompts.
- **LLM Spend History**: spend, requests, tokens and error rate per day and for any range up to the
  metrics retention (opens on 14 days, as long as the free tier keeps metrics), by provider, Claude
  price group and crok-reported model; week over week: totals, a table per provider (last 7 days,
  the 7 before, change) and each day against the same weekday a week earlier. Fed by 70 recording
  rules (group `llm-history`) from the day they are installed, plus, after `setup.sh backfill`,
  daily totals from the providers' usage APIs for the time before and any window the rules missed.

The history providers are `claude`, `openrouter`, and from crok's reports `codex` (every OpenAI
call crok makes: the ChatGPT sign-in, or an OpenAI API key), `glm` (Z.ai and BigModel),
`deepseek` and `other` (xAI, local models, anything else). The trace dashboards name crok's
providers the same way.

## Backfill

`setup.sh backfill` (or `backfill.py fetch`, then `setup.sh dashboards`) reads the rule history to
find the time nothing recorded: the two months before the rules started (`--since` changes that)
and every 10-minute window they skipped since. For that time it fetches:

- Claude: the Admin API usage report (`/v1/organizations/usage_report/messages`), tokens by model,
  all workspaces, in day buckets, then hour and minute buckets up to the exact edge of the rule
  history. Spend is estimated from `prices.json` like the rules do. The cost report is fetched only
  to print a cross-check. The usage report has no request or error counts, so backfilled time has
  no Claude requests, and the error rate comes from the traces only. Prompts over 100K tokens on
  Haiku 5.5 are priced at the base rate (the report does not say which prompts were long).
- OpenRouter: the analytics API (`/api/v1/analytics/query`), filtered to the default workspace
  (`--openrouter-workspace` picks another): requests, prompt and completion tokens and billed spend
  by model.

Keys: `ANTHROPIC_ADMIN_KEY` and `OPENROUTER_MANAGEMENT_KEY`, or the Keychain items
`llm-backfill-anthropic-admin` and `llm-backfill-openrouter-management`. Both keys can do much more
than read usage; delete them afterwards if they are not needed. The result is daily totals in
`backfill/llm-backfill.json` (no secrets), which `build_dashboards.py` embeds as Infinity inline
data. Run it again to pick up windows the rules miss later; each run replaces the file.

## Facts the design depends on

Checked against Grafana Cloud Traces (Tempo) on 2026-10-15. If Grafana changes them, revisit
`build_dashboards.py`.

- A TraceQL metrics query covers at most **25 hours**. The dashboards open on the last 24 hours;
  longer ranges show an error.
- A single-value (instant) TraceQL metrics query leaves out roughly the **newest 15 minutes**, and
  a range query leaves out up to one step at its end. Totals (requests, tokens, spend) are range
  queries at a 1-minute step that Grafana adds up; ratios and percentiles are instant queries and
  say "up to about 15 minutes ago".
- Some TraceQL queries **over 1024 characters fail to parse** ("unexpected $end"), depending on
  where a long attribute name crosses that mark. The builder refuses queries over 1000 characters.
- TraceQL arithmetic is an inner join: a side with no data (a model nobody called) empties the
  whole result, and series of different models cannot be added. Each Claude price group is its
  own query; Grafana adds them. The join is made at every time step, so a range query also loses
  each step in which one side has no spans (checked 2026-10-22).
- `sum_over_time(span.x)` comes out **too low when some of the spans it selects lack `x`**, and
  differently in instant and range queries (checked 2026-10-22 against the spans themselves: a day
  of OpenRouter's billed cost read $0.19 or $0.21 instead of $0.23; crok's tokens were low too).
  The builder adds `&& span.x != nil` to the filter of every such sum (`guarded`), which gives the
  exact figures. Claude's price queries are left as they are: Claude Platform puts every usage
  attribute on every request span, zeros and failed requests included, and five guarded terms
  would not fit the parser. Arithmetic inside `sum_over_time` does not parse.
- The Tempo datasource ignores legendFormat and overwrites each frame's refId with the series
  name. Series are named by their group-by values; a query that needs a fixed name groups by an
  attribute with one known value (see `CONSTANT_GROUPS`) and a regex renames it.
- The Tempo value pickers only know attributes seen in the last few minutes, so the filters are
  regex text boxes.
- Claude Platform puts the same token counts on `anthropic.messages.create` and on its
  `anthropic.model_request` children. Only request spans (`kind = server`) are counted.
  `gen_ai.usage.input_tokens` already includes cache reads and writes.
- Claude spans carry tokens, not cost: spend is tokens × `prices.json` (list prices, standard
  tier; batch, priority and negotiated discounts are not applied). OpenRouter spans carry the
  billed cost (`gen_ai.usage.total_cost`).
- History: every 10 minutes each recording rule records the 10 minutes that ended 20 minutes
  earlier (complete, no overlap) into the stack's Prometheus as `llm_requests`, `llm_errors`,
  `llm_tokens{direction}` and `llm_spend_usd{price_group}`, all with a `provider` label;
  `sum_over_time()` over a range gives that range's total. Mimir rejects label names with dots, so
  a rule cannot keep TraceQL group-by labels: each rule is one ungrouped total with fixed labels.
  A Tempo result has to pass through a `reduce` expression before Grafana can write it.
- History panels add two sources per UTC day: Prometheus (the rules) and the inline backfill rows.
  Grafana merges the rows, sums rows of the same day and dimensions, and splits them into series
  (`merge`, `groupBy`, `partitionByValues`). Every Prometheus query there is a range query at a
  one-day step summing one day per step, because Grafana Cloud's Prometheus refuses a query that
  spans more than 32 days (`err-mimir-max-query-length`), so `[$__range]` totals broke on longer
  ranges. When Prometheus has no rows, Grafana names the inline frame's value field after its
  query ("B"); the `organize` step renames it back to `Value`.
- Why the backfill is not in Prometheus: Grafana Cloud's Prometheus (Mimir) rejects samples more
  than two hours older than the newest sample it has, and a free stack keeps metrics for 14 days.
- The recording rules only run while the hosted Grafana runs them. On 2026-10-15 four evaluations
  (21:39:50 to 22:09:50 UTC) were skipped while nobody used the stack; all rules reported
  healthy, and Grafana does not evaluate skipped windows later. `backfill.py plan` lists such gaps.
- crok sends a W3C `traceparent` with its Claude requests, so a crok turn's Claude calls are one
  trace whose root reads "<root span not yet received>". That is expected. crok's own spans (below)
  are separate traces. From the release after 2.0.2, a Claude call crok reports to Agent
  Observability goes out with that `traceparent` marked not sampled, and Claude Platform exports
  nothing for it (Agent Observability showed every Claude Platform trace as a `claude-platform`
  conversation, so each crok turn appeared twice). Claude Platform still exports what crok does not
  report: compaction calls, and every call while crok's reporting is off
  (`CROK_AGENT_OBSERVABILITY=0`).
- crok's span of such a call carries `crok.unsampled = true` and, beside the SDK's own names, its
  cache reads and thinking tokens as `gen_ai.usage.cache_read.input_tokens` and
  `gen_ai.usage.reasoning.output_tokens` (zeros included, as Claude Platform sends them). With
  those, one filter (`claude_calls()` in `build_dashboards.py`) reads both sources' spans for
  counts, tokens, durations and the cache and thinking ratios; a sum of two sources inside one
  TraceQL expression would come back empty whenever one of them has no spans. Spend stays two
  queries (Claude Platform's from `prices.json`, crok's `crok.cost.usd`) that Grafana adds up. The
  history records crok's part as `provider="claude", reporter="crok"` (spend `price_group="crok"`).
- crok's own spans (service.name `crok`, name `streamText <model>`, kind client) come from the
  agento11y SDK: `gen_ai.provider.name` (`openai` for Codex, `zai` for GLM, `deepseek`, `xai`, or
  the host), request and response model, `gen_ai.usage.input_tokens` (the whole prompt, cache
  included), `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens`,
  `reasoning_tokens`, `error.category`, and crok's additions `crok.cost.usd`, `crok.cost.source`,
  `crok.backend`, `crok.cancelled` and `crok.unsampled`. The SDK sets a token attribute only when
  it is not zero, so a missing one is zero.
- crok 2.0.0 and older send no `crok.*` attributes; newer crok always sends `crok.backend`, so
  `span.crok.backend = nil` picks the older calls out. Their spend is their tokens at the
  `prices.json` `crok` rates (the same as crok's own table), for the models those releases call
  through Codex, DeepSeek and GLM. Because of the per-step join, each price group is two queries
  whose spans carry every attribute they add up: calls that read from the prompt cache (input,
  cache read, output) and calls that did not (input, output). DeepSeek is priced at its off-peak
  rate (TraceQL cannot tell a call's hour; peak hours, 35 of 168 a week, cost twice as much).
  Time series panels add up the series of the same model (`summed_by_name`). In the history the
  older calls' spend starts when these rules were installed (2026-10-22).
- crok marks a call the user interrupted as an error span too. `crok.cancelled = true` is set on
  those alone, so failures are `status = error && span.crok.cancelled = nil`, which keeps older
  crok's failures and every Claude Platform and OpenRouter span.
- Mimir rejects dotted labels, but TraceQL's span `name` groups as a plain `name` label, so crok's
  history rules group by it and keep every model: the label reads `"streamText deepseek-flash"`,
  quotes included, and the dashboards take the model out with `label_replace`.
- Week over week is `sum_over_time(m[7d])` against the same `offset 7d`, as instant queries at the
  end of the time range: both windows lag the rules by the same 20-30 minutes, and the query reaches
  14 days back, which is all a free stack keeps. It works from the day the history is 14 days old;
  before that "the 7 days before" is partly empty. TraceQL search (the tables) reaches 14 days too;
  TraceQL metrics stop at 25 hours, so long ranges on the trace dashboards come from the history.
- Grafana Cloud Free (this stack after its trial ends on 2026-10-29) keeps metrics and traces for
  14 days, and the rules record into those metrics, so 14 days is as far back as anything goes.
  Checked on 2026-10-21: from 2026-10-15 to 10-21 the rules recorded every 10-minute window that
  had traffic (compare each sample with a TraceQL instant query of its window to check again).

## Maintenance

- New Claude model or price: edit `prices.json` (`match` is an anchored regex for
  `gen_ai.response.model`; keep it short), then `setup.sh dashboards`. The "Unpriced model
  requests" tile counts requests to models the table misses.
- New price for a Codex, DeepSeek or GLM model: change `crates/codegen/xai-grok-models/src/pricing.rs`
  (newer crok) and the `crok` table in `prices.json` (calls of crok 2.0.0 and older), then
  `setup.sh dashboards`. Only models those releases can call need a row there.
- Different service names: set `CLAUDE_SERVICE` / `OPENROUTER_SERVICE` / `CROK_SERVICE`.
- crok's Claude or OpenRouter calls do not reach those providers' own exports at all (no Claude
  Console destination, say): set `CROK_SKIP_PROVIDERS` to the providers that do export (for
  example `openrouter`, or empty for none), then `setup.sh dashboards`. The Claude calls crok
  keeps out of Claude Platform's export itself (`crok.unsampled`) need nothing: they are counted
  either way.
- A new provider crok should report by name: add it to `CROK_PROVIDERS` in `build_dashboards.py`
  (history label, `gen_ai.provider.name`). Its earlier history stays under `other`.
- Fill windows the rules missed: `setup.sh backfill` (`python3 backfill.py plan` lists them first).
- Drop the backfill: delete `backfill/llm-backfill.json`, then `setup.sh dashboards`.
- Remove everything: `gcx api /api/v1/provisioning/folder/llm-observability/rule-groups/llm-history
  -X DELETE`, then `gcx resources delete dashboards/llm-overview dashboards/llm-claude-platform
  dashboards/llm-openrouter dashboards/llm-crok dashboards/llm-crok-harness dashboards/llm-request-explorer
  dashboards/llm-history folders/llm-observability`.
