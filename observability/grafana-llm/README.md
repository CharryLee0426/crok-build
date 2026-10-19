# LLM observability in Grafana Cloud (Claude Platform + OpenRouter)

For people who bring their own keys: send the OpenTelemetry traces of every Claude API and
OpenRouter request to Grafana Cloud, and get dashboards for spend, tokens, prompt cache, latency,
errors and single requests. Nothing in crok has to change: Claude Platform and OpenRouter export
the traces themselves, for any client.

| File | What it is |
| --- | --- |
| `setup.sh` | The guided setup, one subcommand per step. Made for agents to run; people can run it too. |
| `build_dashboards.py` | Builds the five dashboards and the history recording rules for a stack (standard library only). |
| `prices.json` | Claude list prices used to estimate Claude spend. Same table as `xai-grok-models::pricing`. |
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
4. `setup.sh verify --wait 10` until spans arrive from each provider in use.
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
  the time range; traffic, spend, latency and errors over time; models ranked; latest calls.
- **Claude Platform**: estimated spend by model, token mix (uncached input, cache reads, 5-minute
  and 1-hour cache writes, output), cache hit rate by model, latency and output speed, stop
  reasons, errors, HTTP status, effort, service tier, workspaces, latest requests with their
  request-id, and server/MCP tools and Managed Agents (collapsed).
- **OpenRouter**: billed spend by model, API key, upstream provider, user and session; tokens;
  latency; finish reasons; errors; latest generations. Filters: model and API key (regex).
- **LLM Request Explorer**: find single calls by source, model, minimum duration and status, plus
  saved searches: failed, slow, cut off by max_tokens, huge prompts, expensive OpenRouter calls,
  Claude cache misses on big prompts.
- **LLM Spend History**: spend, requests, tokens and error rate per day and for any range up to the
  metrics retention (opens on 30 days), by provider and Claude price group. Fed by 22 recording
  rules (group `llm-history`) from the day they are installed, plus, after `setup.sh backfill`,
  daily totals from the providers' usage APIs for the time before and any window the rules missed.

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
  own query; Grafana adds them.
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
- crok sends a W3C `traceparent` but does not export its own spans, so a crok session is one trace
  whose root reads "<root span not yet received>". That is expected.

## Maintenance

- New Claude model or price: edit `prices.json` (`match` is an anchored regex for
  `gen_ai.response.model`; keep it short), then `setup.sh dashboards`. The "Unpriced model
  requests" tile counts requests to models the table misses.
- Different service names: set `CLAUDE_SERVICE` / `OPENROUTER_SERVICE`.
- Fill windows the rules missed: `setup.sh backfill` (`python3 backfill.py plan` lists them first).
- Drop the backfill: delete `backfill/llm-backfill.json`, then `setup.sh dashboards`.
- Remove everything: `gcx api /api/v1/provisioning/folder/llm-observability/rule-groups/llm-history
  -X DELETE`, then `gcx resources delete dashboards/llm-overview dashboards/llm-claude-platform
  dashboards/llm-openrouter dashboards/llm-request-explorer dashboards/llm-history
  folders/llm-observability`.
