# crok's online evaluation, guards, alerts and SLOs

What scores crok's real traffic in Grafana Agent Observability, kept as files and applied with gcx.
The offline half (experiments over fixture repositories) is `evals/`; what crok itself sends (turns,
tool runs, steps, verdicts, ratings, guard checks) is `crates/codegen/xai-grok-agento11y/README.md`.

| File | What it is |
| --- | --- |
| `stack.json` | 13 evaluators, 5 rules, 3 guards and the `crok-regressions` collection |
| `alerts.json` | The `crok-alerts` Grafana alert rule group |
| `slos.json` | Three SLOs |
| `stack.py` | Applies the files with gcx, scores the conversations already stored, reports |

```sh
gcx login narrowgrotto289 --server https://narrowgrotto289.grafana.net --oauth
python3 observability/agento11y/stack.py inventory          # what the stack has now
python3 observability/agento11y/stack.py apply --dry-run    # what would change
python3 observability/agento11y/stack.py apply              # evaluators, rules, guards, collection
python3 observability/agento11y/stack.py backfill --since 2026-10-16
python3 observability/agento11y/stack.py report
python3 observability/agento11y/stack.py alerts
python3 observability/agento11y/stack.py slos
```

## Evaluators and rules

| Rule | Selector | Sample | Evaluators | Why |
| --- | --- | --- | --- | --- |
| `crok_all_generations_secrets` | every assistant generation | 100% | secret formats, private keys, labeled credentials, connection strings (regex, from the stack's templates) | crok has full shell and file access; keys live in `~/.crok` and `.env` files |
| `crok_final_turns_checks` | the answer of a turn | 100% | response not empty (heuristic) | 3 of 32 sampled turns ended with no answer |
| `crok_final_turns_judged` | the answer of a turn | 25% | tool-result groundedness and helpfulness (Haiku 4.5), claims verified (Sonnet 4.6) | answers summarize shell output; "tests pass" was claimed without a run; ten models need one yardstick |
| `crok_tool_steps_judged` | generations with tool calls | 10% | external action authorized, prompt-injection resistance (Haiku 4.5) | permissions are often bypassed; browser, web and phone tools read untrusted text |
| `crok_turn_summary_length` | `crok/turn-summary` | 100% | response length ≤ 140 (heuristic) | the one-line summary must stay one line |

Regex and heuristic evaluators cost nothing; the judges run on Bedrock and count against the
25 million evaluation tokens a month of the free tier (about 15 million at these samples). Lower a
rule's `sample_rate` in `stack.json` and run `apply` again if the judge spend grows.

`crok_claims_verified` is crok's own judge: it fails an answer that says tests, a build or a command
succeeded when no tool result in the turn shows it. The offline suite checks the same with
`s1-claims-verified`.

If a `user_visible_turn` rule matches traffic but its score count stays at zero, the stack does not
mark crok's final generations as user-visible: switch the rule to `all_assistant_generations` and
keep the judge prompt's `stop_reason` filter.

## Guards (warn mode)

| Guard | Phase | Shape | Catches |
| --- | --- | --- | --- |
| `guard.crok.git_rewrite` | postflight | regex evaluator on the tool calls | force pushes, `reset --hard`, `clean -f`, `branch -D`, `checkout -- .`, `filter-branch` |
| `guard.crok.destructive_shell` | postflight | regex evaluator | `rm -r` outside the project or on `/`, `~`, `..`; `sudo`; `mkfs`; `dd` to a disk; fork bombs |
| `guard.crok.secret_redaction` | preflight | redact (9 patterns) | AWS, GitHub, Anthropic, OpenAI, OpenRouter, Grafana, Slack and Stripe live keys, private key blocks, in tool results |

crok releases after 2.0.1 call the guards (`POST /api/v1/hooks:evaluate`) with every state-changing tool
call before it runs and every tool result before it goes back to the model, without waiting for the
answer: a guard never slows or blocks a turn. A failed check is recorded as a warn on the
conversation (Agent Observability shows a "Guard" step), and crok's `crok_guard_checks_total{flagged}`
counts them. `CROK_AGENTO11Y_GUARDS=off` stops the checks on one machine.

To move a guard to deny, watch its warns for two weeks (`gcx agento11y conversations search
--filters 'agent = "crok"'` and the Guard steps), fix the patterns until the false positives are
rare, then set `"action_on_fail": "deny"` in `stack.json` and run `apply`. crok does not yet wait for
guard verdicts, so a deny is recorded but does not stop the call; making crok enforce it (a
`PolicyDeny` before the tool runs) is the next step on crok's side.

## Scoring the conversations already stored

Rules score traffic from the moment they exist. `stack.py backfill` scores what came before: it
lists crok's conversations in the window (`--since`, up to Agent Observability's 30-day retention),
picks the generations each rule's selector would, runs the rule's evaluators on them with
`gcx agento11y evaluators test` (the stack's own judge; nothing stored) and exports the results as
scores (`scores:export` through the plugin, `source: backfill`). Regex and heuristic evaluators run
on everything; judges on a deterministic sample (`--judge-sample`, 25% by default). Score ids come
from evaluator and generation, so running it again adds nothing twice. The results are also kept in
`backfill/scores.jsonl` (git-ignored), and `stack.py report` prints the pass rates by evaluator and
model.

`apply` also saves crok's failed conversations of the last 30 days into the `crok-regressions`
collection. Saved conversations outlive the 30-day retention and are the inputs for new regression
cases in `evals/suites/s1`.

## Alerts

| Alert | Fires when | Reads |
| --- | --- | --- |
| a provider is failing calls | more than 10 failed calls (interruptions left out) to one provider in 15 minutes | `gen_ai_client_operation_duration_seconds_count` |
| spend today is more than twice the usual day | the last 24 hours cost over twice the median day of the week before (at least $0.50) | `llm_spend_usd` (the llm-history rules) |
| MCP servers fail to start | over 10% of at least 5 MCP server starts failed in 24 hours | `crok_workflow_steps_total{step="mcp_server"}` (crok after 2.0.1) |

Score-based alerts (a secret leak, a pass-rate drop) belong on the evaluation rules: in Agent
Observability open the rule, set a pass-rate threshold and a contact point (the rule keeps the
alert's uid in `alert_rule_uids`).

## SLOs

| SLO | Target | October |
| --- | --- | --- |
| model calls succeed, per provider | 97% over 28 days | OpenRouter 96.5%, Anthropic 97.8%, DeepSeek 100% |
| first token within 5 s, per provider | 90% over 28 days | p90 5.1 s, 3.8 s, 2.3 s |
| turns complete | 95% over 28 days | 96.3% on one Mac |

`stack.py slos` creates each SLO once its metrics exist; the turn SLO waits for a crok release after 2.0.1 to
report `crok_turns_total`.
