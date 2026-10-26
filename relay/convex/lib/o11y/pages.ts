/**
 * The o11y pages (relay/DESIGN.md §3 "o11y"): what each shows and where it comes from. Dashboard pages name panels of
 * the live LLM Observability dashboards (observability/grafana-llm); the evaluation and Agent Observability pages run
 * their own PromQL and TraceQL and read the Agent Observability, SLO and alerting APIs. Text goes through `t`.
 */
import type { Grafana, Series } from "./grafana";
import { chartStep, lastValue, total } from "./grafana";
import { translator } from "./i18n";
import type { BuildCtx, StatSpec } from "./read";
import {
  makeCtx,
  changeOf,
  chartBlock,
  chartFromPanel,
  label,
  listFromSpans,
  message,
  promInstant,
  promRange,
  promValue,
  rankingBlock,
  rankingFromPanel,
  section,
  statOf,
  statsFromPanels,
  tempoQuery,
  wowRankingFromPanel,
} from "./read";
import type { Block, Chip, Lang, LinkRow, ListRow, Page, Section, Stat } from "./types";
import { LANGS } from "./types";

export type PageDef = {
  id: string;
  title: string;
  subtitle: string;
  ranges: string[];
  range: string;
  url: (base: string, range: string) => string;
  build: (ctx: BuildCtx) => Promise<Section[]>;
};

const TRACES = ["1h", "6h", "24h"];
const METRICS = ["24h", "7d", "14d"];
const AO = "/api/plugins/grafana-agento11y-app/resources";

const dashboardUrl = (uid: string) => (base: string, range: string) => `${base}/d/${uid}?from=now-${range}&to=now`;
const appUrl = (path: string) => (base: string) => `${base}${path}`;

/** "{n} of {m} met" with the numbers filled in. */
function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) => (key in values ? String(values[key]) : match));
}

const PROVIDERS: Record<string, string> = { openai: "codex", zai: "glm" };
const provider = (name: string) => PROVIDERS[name] ?? name;

/** Runs every section maker at once; each one's failure stays its own. */
function sections(makers: Promise<Section>[]): Promise<Section[]> {
  return Promise.all(makers);
}

function items<T = Record<string, unknown>>(doc: unknown): T[] {
  if (Array.isArray(doc)) return doc as T[];
  const d = doc as Record<string, unknown> | null;
  for (const key of ["items", "data", "slos", "experiments", "agents", "conversations", "rules"]) {
    if (d && Array.isArray(d[key])) return d[key] as T[];
  }
  return [];
}

function time(value: unknown): number | undefined {
  if (typeof value === "number") return value > 1e12 ? value : value * 1000;
  if (typeof value !== "string") return undefined;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : undefined;
}

function clip(text: string, max = 160): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

// ---------------------------------------------------------------------------------------------------------------
// Home

const ICON = {
  overview: "#3D8BF2",
  claude: "#F09A37",
  openrouter: "#5B5FE8",
  crok: "#4CC75F",
  harness: "#4FB6E8",
  history: "#E95A52",
  explorer: "#8E8E93",
  evaluators: "#4CC75F",
  guards: "#F2C04A",
  experiments: "#A65EEB",
  agents: "#3D8BF2",
  conversations: "#4CC75F",
  slos: "#E95A52",
  alerts: "#F09A37",
} as const;

function link(ctx: BuildCtx, page: keyof typeof ICON, title: string, subtitle: string, value?: LinkRow["value"]): LinkRow {
  return { page, title: ctx.t(title), subtitle, icon: page, color: ICON[page], ...(value ? { value } : {}) };
}

async function settle<T>(work: Promise<T>): Promise<T | undefined> {
  try {
    return await work;
  } catch {
    return undefined;
  }
}

/** Pass rate and warns over the last 7 days, whatever the home page's range. */
async function evaluationLinks(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const [scores, passed, warns, runs] = await Promise.all([
    settle(promValue(ctx, "sum(increase(agento11y_eval_scores_total[7d]))")),
    settle(promValue(ctx, 'sum(increase(agento11y_eval_scores_total{passed="true"}[7d]))')),
    settle(promValue(ctx, 'sum(increase(agento11y_hook_rule_outcomes_total{outcome!="pass"}[7d]))')),
    settle(ctx.g.get(`${AO}/eval/experiments`).then((doc) => items(doc).length)),
  ]);
  const rate = scores && passed !== undefined ? passed / scores : undefined;
  return {
    kind: "links",
    rows: [
      link(ctx, "evaluators", "Evaluators", t("Pass rate of the online scores, 7 days"),
        rate !== undefined ? { v: Number(rate.toPrecision(4)), u: "ratio" } : undefined),
      link(ctx, "guards", "Guards", t("Warns on risky tool calls, 7 days"),
        warns !== undefined ? { v: Math.round(warns), u: "count" } : undefined),
      link(ctx, "experiments", "Experiments", t("Offline eval runs over fixture repos"),
        runs !== undefined ? { v: runs, u: "count" } : undefined),
    ],
  };
}

async function agentLinks(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const [agents, conversations, slos, firing] = await Promise.all([
    settle(ctx.g.get(`${AO}/query/agents?limit=100`).then((doc) => items(doc).length)),
    settle(
      ctx.g.get(`${AO}/query/conversations?limit=100`).then(
        (doc) => items(doc).filter((c) => (time(c.last_generation_at) ?? 0) > ctx.to - 86_400_000).length,
      ),
    ),
    settle(sloStates(ctx)),
    settle(alertRules(ctx).then((rules) => rules.filter((r) => r.state === "firing").length)),
  ]);
  const met = slos?.filter((s) => s.sli !== null && s.sli >= s.objective).length;
  return {
    kind: "links",
    rows: [
      link(ctx, "agents", "Agents", t("Every agent and its calls"), agents !== undefined ? { v: agents, u: "count" } : undefined),
      link(ctx, "conversations", "Conversations", t("Active in the last 24 hours"),
        conversations !== undefined ? { v: conversations, u: "count" } : undefined),
      link(ctx, "slos", "SLOs", slos ? fill(t("{n} of {m} met over 28 days"), { n: met ?? 0, m: slos.length }) : t("Objectives over 28 days")),
      link(ctx, "alerts", "Alerts", t("Firing now"), firing !== undefined ? { v: firing, u: "count" } : undefined),
    ],
  };
}

const home: PageDef = {
  id: "home",
  title: "o11y",
  subtitle: "Grafana Cloud",
  ranges: ["24h"],
  range: "24h",
  url: appUrl("/dashboards"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("Last 24 hours"), () =>
        statsFromPanels(ctx, "llm-overview", [
          { panel: "Spend", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Tokens", better: "none" },
          { panel: "Error rate", better: "down" },
        ]),
      ),
      section(t("Spend per day"), () =>
        chartFromPanel(ctx, "llm-overview", "Spend per day by provider (last 14 days)", { style: "bars", stacked: true }),
      ),
      section(t("Dashboards"), async () => ({
        kind: "links",
        rows: [
          link(ctx, "overview", "LLM Overview", t("Every provider at a glance")),
          link(ctx, "claude", "Claude Platform", t("Claude API calls, from Claude Platform")),
          link(ctx, "openrouter", "OpenRouter", t("OpenRouter generations, billed")),
          link(ctx, "crok", "Codex, GLM and DeepSeek", t("Calls crok reports itself")),
          link(ctx, "harness", "crok Harness", t("Turns and tool runs")),
          link(ctx, "history", "LLM Spend History", t("Recorded spend, 14 days")),
          link(ctx, "explorer", "LLM Request Explorer", t("Failed, slow and expensive calls")),
        ],
      })),
      section(t("Evaluation"), () => evaluationLinks(ctx)),
      section(t("Agent Observability"), () => agentLinks(ctx)),
    ]);
  },
};

// ---------------------------------------------------------------------------------------------------------------
// The LLM Observability dashboards

function wowStats(ctx: BuildCtx): StatSpec[] {
  const t = ctx.t;
  return [
    { panel: "Spend, week over week", label: t("Spend, last 7 days"), better: "down" },
    { panel: "Requests, week over week", label: t("Calls, last 7 days"), better: "none" },
    { panel: "Tokens, week over week", label: t("Tokens, last 7 days"), better: "none" },
    { panel: "Error rate, week over week", label: t("Error rate, last 7 days"), better: "down" },
  ];
}

const overview: PageDef = {
  id: "overview",
  title: "LLM Overview",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-overview"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-overview";
    return sections([
      section(t("At a glance"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Spend", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Tokens", better: "none" },
          { panel: "Error rate", better: "down" },
          { panel: "Claude cache hit rate", better: "up" },
          { panel: "p95 latency", better: "down" },
        ]),
      ),
      section(t("Week over week"), () => statsFromPanels(ctx, uid, wowStats(ctx)), t("Recorded history: the last 7 days against the 7 before.")),
      section(t("Spend per day by provider"), () =>
        chartFromPanel(ctx, uid, "Spend per day by provider (last 14 days)", { style: "bars", stacked: true }),
      ),
      section(t("Calls per minute"), () => chartFromPanel(ctx, uid, "Requests per minute", { style: "line" })),
      section(t("Latency p50 / p95"), () => chartFromPanel(ctx, uid, "Latency p50 / p95", { style: "line" })),
      section(t("Spend by model"), () => rankingFromPanel(ctx, uid, "Spend by model")),
      section(t("Calls by model"), () => rankingFromPanel(ctx, uid, "Requests by model")),
      section(t("p95 latency by model"), () => rankingFromPanel(ctx, uid, "p95 latency by model")),
      section(t("Latest calls"), () => listFromSpans(ctx, uid, "Latest LLM calls")),
    ]);
  },
};

const claude: PageDef = {
  id: "claude",
  title: "Claude Platform",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-claude-platform"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-claude-platform";
    return sections([
      section(t("At a glance"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Estimated spend", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Input tokens", unit: "tokens", better: "none" },
          { panel: "Output tokens", unit: "tokens", better: "none" },
          { panel: "Cache hit rate", better: "up" },
          { panel: "p95 latency", better: "down" },
          { panel: "Error rate", better: "down" },
          { panel: "Output speed", better: "up" },
        ]),
        t("Claude Platform sends tokens, not prices: spend is estimated from list prices."),
      ),
      section(t("Estimated spend by model"), () => chartFromPanel(ctx, uid, "Estimated spend by model", { style: "line" })),
      section(t("Token mix"), () => chartFromPanel(ctx, uid, "Token mix", { style: "line" })),
      section(t("Estimated spend by model"), () => rankingFromPanel(ctx, uid, "Estimated spend by model")),
      section(t("Call duration by model"), () => chartFromPanel(ctx, uid, "Request duration by model", { style: "line" })),
      section(t("Stop reasons"), () => rankingFromPanel(ctx, uid, "Stop reasons")),
      section(t("Effort level"), () => rankingFromPanel(ctx, uid, "Effort level")),
      section(t("Errors by type"), () => chartFromPanel(ctx, uid, "Errors by type", { style: "line" })),
      section(t("Latest calls"), () => listFromSpans(ctx, uid, "Latest requests")),
    ]);
  },
};

const openrouter: PageDef = {
  id: "openrouter",
  title: "OpenRouter",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-openrouter"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-openrouter";
    return sections([
      section(t("At a glance"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Spend", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Avg cost / request", label: t("Cost per call"), better: "down" },
          { panel: "Tokens", unit: "tokens", better: "none" },
          { panel: "Cached input share", better: "up" },
          { panel: "p95 latency", better: "down" },
        ]),
      ),
      section(t("Spend by model"), () => chartFromPanel(ctx, uid, "Spend by model", { style: "line" })),
      section(t("Spend by upstream provider"), () => rankingFromPanel(ctx, uid, "Spend by upstream provider")),
      section(t("Spend by API key"), () => rankingFromPanel(ctx, uid, "Spend by API key")),
      section(t("Calls per minute by model"), () => chartFromPanel(ctx, uid, "Requests per minute by model", { style: "line" })),
      section(t("Call duration by model"), () => chartFromPanel(ctx, uid, "Duration by model", { style: "line" })),
      section(t("Finish reasons"), () => rankingFromPanel(ctx, uid, "Finish reasons")),
      section(t("Latest generations"), () => listFromSpans(ctx, uid, "Latest generations")),
    ]);
  },
};

const crok: PageDef = {
  id: "crok",
  title: "Codex, GLM and DeepSeek",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-crok"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-crok";
    return sections([
      section(t("At a glance"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Spend", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Tokens", unit: "tokens", better: "none" },
          { panel: "Cache hit rate", better: "up" },
          { panel: "Error rate", better: "down" },
          { panel: "p95 latency", better: "down" },
          { panel: "Cancelled", better: "none" },
          { panel: "Output speed", better: "up" },
        ]),
      ),
      section(t("Week over week"), () => statsFromPanels(ctx, uid, wowStats(ctx)), t("Recorded history: the last 7 days against the 7 before.")),
      section(t("Spend by model, week over week"), () =>
        wowRankingFromPanel(ctx, uid, "Spend by model, week over week", { better: "down" }),
      ),
      section(t("Spend per day by provider"), () =>
        chartFromPanel(ctx, uid, "Spend per day by provider (last 14 days)", { style: "bars", stacked: true }),
      ),
      section(t("Spend by model"), () => chartFromPanel(ctx, uid, "Spend by model", { style: "line" })),
      section(t("Spend by provider"), () => rankingFromPanel(ctx, uid, "Spend by provider")),
      section(t("Time to first token by provider"), () =>
        chartFromPanel(ctx, uid, "Time to first token by provider", { style: "line" }),
      ),
      section(t("Failures by category"), () => chartFromPanel(ctx, uid, "Failures by category", { style: "line" })),
      section(t("Calls by machine"), () => rankingFromPanel(ctx, uid, "Requests by machine")),
      section(t("Finish reasons"), () => rankingFromPanel(ctx, uid, "Finish reasons")),
      section(t("Latest calls"), () => listFromSpans(ctx, uid, "Latest calls")),
    ]);
  },
};

const harness: PageDef = {
  id: "harness",
  title: "crok Harness",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-crok-harness"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-crok-harness";
    return sections([
      section(t("Turns"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Turns", better: "none" },
          { panel: "Completed", better: "up" },
          { panel: "p50 turn time", better: "down" },
          { panel: "p90 turn time", better: "down" },
          { panel: "Model calls per turn", better: "none" },
          { panel: "Tool runs per turn", better: "none" },
        ]),
        t("Turns from crok releases after 2.0.1; experiment runs left out."),
      ),
      section(t("Turns by outcome"), () => chartFromPanel(ctx, uid, "Turns by outcome", { style: "line" })),
      section(t("Turns by model"), () => rankingFromPanel(ctx, uid, "Turns by model")),
      section(t("Tool runs by tool"), () => rankingFromPanel(ctx, uid, "Tool runs by tool")),
      section(t("Failed tool runs by tool"), () => rankingFromPanel(ctx, uid, "Failed tool runs by tool")),
      section(t("Tool failure rate"), () => chartFromPanel(ctx, uid, "Tool failure rate", { style: "line" })),
      section(t("p90 tool time by tool"), () => rankingFromPanel(ctx, uid, "p90 tool time by tool")),
      section(t("Latest turns"), () => listFromSpans(ctx, uid, "Latest turns")),
      section(t("Turns that did not complete"), () => listFromSpans(ctx, uid, "Turns that did not complete")),
      section(t("Failed tool runs"), () => listFromSpans(ctx, uid, "Failed tool runs")),
    ]);
  },
};

const history: PageDef = {
  id: "history",
  title: "LLM Spend History",
  subtitle: "LLM Observability",
  ranges: METRICS,
  range: "14d",
  url: dashboardUrl("llm-history"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-history";
    return sections([
      section(t("Totals"), () =>
        statsFromPanels(ctx, uid, [
          { panel: "Spend", better: "down" },
          { panel: "Claude, estimated", better: "down" },
          { panel: "OpenRouter, billed", better: "down" },
          { panel: "Codex, GLM, DeepSeek", better: "down" },
          { panel: "Requests", label: t("Calls"), better: "none" },
          { panel: "Tokens", unit: "tokens", better: "none" },
          { panel: "Error rate", better: "down" },
        ]),
        t("Recorded every 10 minutes, about 20 to 30 minutes behind."),
      ),
      section(t("Week over week"), () => statsFromPanels(ctx, uid, wowStats(ctx))),
      section(t("Spend per day, and 7 days earlier"), () =>
        chartFromPanel(ctx, uid, "Spend per day, and 7 days earlier", { style: "bars" }),
      ),
      section(t("Spend per day by provider"), () => chartFromPanel(ctx, uid, "Spend per day", { style: "bars", stacked: true })),
      section(t("Calls per day"), () => chartFromPanel(ctx, uid, "Requests per day", { style: "bars", stacked: true })),
      section(t("Tokens per day"), () => chartFromPanel(ctx, uid, "Tokens per day", { style: "bars", stacked: true })),
      section(t("Spend by provider, week over week"), () =>
        wowRankingFromPanel(ctx, uid, "Spend by provider, week over week", { better: "down" }),
      ),
      section(t("Spend by price group"), () => rankingFromPanel(ctx, uid, "Spend by price group", { unit: "usd" })),
    ]);
  },
};

const explorer: PageDef = {
  id: "explorer",
  title: "LLM Request Explorer",
  subtitle: "LLM Observability",
  ranges: TRACES,
  range: "24h",
  url: dashboardUrl("llm-request-explorer"),
  build: (ctx) => {
    const t = ctx.t;
    const uid = "llm-request-explorer";
    const saved = (title: string) => section(t(title), () => listFromSpans(ctx, uid, title, 8));
    return sections([
      saved("Failed calls"),
      saved("Slowest calls (over 30 s)"),
      saved("Expensive calls (over $0.05)"),
      saved("Cut off by the token limit"),
      saved("Huge prompts (over 150K tokens)"),
      saved("Cache misses on big prompts"),
    ]);
  },
};

// ---------------------------------------------------------------------------------------------------------------
// Evaluation

/**
 * A value over the page's range and the same range before it. Counts come whole: `increase()` extrapolates, and
 * "3.1 warns" is not a thing.
 */
async function withChange(
  ctx: BuildCtx,
  expr: (window: string) => string,
  whole = true,
): Promise<{ now: number; before: number }> {
  const range = `${Math.round(ctx.rangeMs / 1000)}s`;
  const [now, before] = await Promise.all([promValue(ctx, expr(`[${range}]`)), promValue(ctx, expr(`[${range}] offset ${range}`))]);
  return whole ? { now: Math.round(now), before: Math.round(before) } : { now, before };
}

/** Counts per step from `increase()`, whole. */
function wholePoints(series: Series[]): Series[] {
  return series.map((s) => ({ ...s, points: s.points.map(([t, v]) => [t, v === null ? null : Math.round(v)]) }));
}

function byLabel(series: Series[], key: string, value: (s: Series) => number | null = lastValue): Map<string, number> {
  const out = new Map<string, number>();
  for (const s of series) {
    const v = value(s);
    if (v === null) continue;
    const name = label(s, key) || "—";
    out.set(name, (out.get(name) ?? 0) + v);
  }
  return out;
}

const SCORES = "agento11y_eval_scores_total";

async function evaluatorStats(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const [scores, passed, judge, failedRuns] = await Promise.all([
    withChange(ctx, (w) => `sum(increase(${SCORES}${w}))`),
    withChange(ctx, (w) => `sum(increase(${SCORES}{passed="true"}${w}))`),
    withChange(ctx, (w) => `sum(increase(agento11y_eval_judge_cost_usd_total${w}))`, false),
    withChange(ctx, (w) => `sum(increase(agento11y_eval_executions_total{status="failed"}${w}))`),
  ]);
  const rate = (p: number, s: number) => (s > 0 ? p / s : null);
  const items: Stat[] = [
    statOf(t("Scores"), scores.now, "count", { change: changeOf(scores.now, scores.before), better: "none" }),
    statOf(t("Pass rate"), rate(passed.now, scores.now), "ratio", {
      change: changeOf(rate(passed.now, scores.now), rate(passed.before, scores.before)),
      better: "up",
    }),
    statOf(t("Failed scores"), scores.now - passed.now, "count", {
      change: changeOf(scores.now - passed.now, scores.before - passed.before),
      better: "down",
    }),
    statOf(t("Judge spend"), judge.now, "usd", { change: changeOf(judge.now, judge.before), better: "down" }),
    statOf(t("Evaluations that failed to run"), failedRuns.now, "count", { better: "down" }),
  ];
  return { kind: "stats", items };
}

async function passRates(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const series = await promInstant(ctx, `sum by (evaluator, passed) (increase(${SCORES}[$__range]))`);
  const totals = byLabel(series, "evaluator");
  const passed = byLabel(series.filter((s) => label(s, "passed") === "true"), "evaluator");
  const rows = [...totals.entries()]
    .filter(([, n]) => n >= 0.5)
    .map(([name, n]) => ({
      label: name,
      value: (passed.get(name) ?? 0) / n,
      detail: [
        { v: Math.round(n), u: "count" as const, s: t("scores") },
        ...(n - (passed.get(name) ?? 0) >= 0.5 ? [{ v: Math.round(n - (passed.get(name) ?? 0)), u: "count" as const, s: t("failed") }] : []),
      ] as Chip[],
    }));
  return rankingBlock(ctx, rows, "ratio", { order: "asc", keepZero: true, limit: 20 });
}

async function scoresOverTime(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const series = await promRange(ctx, `sum by (passed) (increase(${SCORES}[$__interval]))`);
  const named = wholePoints(series).map((s) => ({ ...s, name: label(s, "passed") === "true" ? t("Passed") : t("Failed") }));
  return chartBlock(ctx, named, { style: "bars", stacked: true, unit: "count", step: chartStepOf(ctx) });
}

/** The step promRange and tempoQuery charts use. */
function chartStepOf(ctx: BuildCtx): number {
  return chartStep(ctx.rangeMs);
}

async function rankedProm(ctx: BuildCtx, expr: string, key: string, unit: "count" | "usd", rename?: (n: string) => string): Promise<Block> {
  const series = await promInstant(ctx, expr);
  const rows = [...byLabel(series, key).entries()].map(([name, value]) => ({ label: rename ? rename(name) : name, value }));
  return rankingBlock(ctx, rows, unit);
}

type Score = {
  evaluator_id?: string;
  conversation_title?: string;
  conversation_id?: string;
  explanation?: string;
  created_at?: string;
  score_key?: string;
};

async function recentFailures(ctx: BuildCtx): Promise<Block> {
  const rules = items<{ rule_id?: string; id?: string }>(await ctx.g.get(`${AO}/eval/rules`))
    .map((r) => r.rule_id ?? r.id)
    .filter((id): id is string => !!id);
  const pages = await Promise.all(
    rules.map((id) =>
      settle(ctx.g.get(`${AO}/eval/rules/${encodeURIComponent(id)}/scores?limit=10&passed=false&sort_by=created_at&sort_dir=desc`)),
    ),
  );
  const scores = pages.flatMap((doc) => items<Score>(doc ?? []));
  const rows: ListRow[] = scores
    .map((s) => ({ s, at: time(s.created_at) ?? 0 }))
    .filter(({ at }) => at >= ctx.from)
    .sort((a, b) => b.at - a.at)
    .slice(0, 12)
    .map(({ s, at }) => ({
      title: s.evaluator_id ?? s.score_key ?? "—",
      detail: [
        ...(s.conversation_title ? [{ t: clip(s.conversation_title, 80) }] : []),
        ...(s.explanation ? [{ t: clip(s.explanation) }] : []),
      ],
      time: at,
      status: "bad" as const,
    }));
  return { kind: "list", rows, empty: ctx.t("No failed scores in this range") };
}

const evaluators: PageDef = {
  id: "evaluators",
  title: "Evaluators",
  subtitle: "Evaluation",
  ranges: METRICS,
  range: "7d",
  url: appUrl("/a/grafana-agento11y-app"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("Online scores"), () => evaluatorStats(ctx), t("Changes compare with the same length of time before.")),
      section(t("Pass rate by evaluator"), () => passRates(ctx), t("Lowest first.")),
      section(t("Scores over time"), () => scoresOverTime(ctx)),
      section(t("Recent failures"), () => recentFailures(ctx)),
      section(t("Failed scores by model"), () =>
        rankedProm(ctx, `sum by (gen_ai_request_model) (increase(${SCORES}{passed="false"}[$__range]))`, "gen_ai_request_model", "count"),
      ),
      section(t("Scores by rule"), () => rankedProm(ctx, `sum by (rule) (increase(${SCORES}[$__range]))`, "rule", "count")),
      section(t("Judge spend by model"), () =>
        rankedProm(ctx, `sum by (model) (increase(agento11y_eval_judge_cost_usd_total[$__range]))`, "model", "usd"),
      ),
    ]);
  },
};

const HOOKS = "agento11y_hook_rule_outcomes_total";

async function guardStats(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const [checks, warns, denies, flagged] = await Promise.all([
    withChange(ctx, (w) => `sum(increase(${HOOKS}${w}))`),
    withChange(ctx, (w) => `sum(increase(${HOOKS}{outcome="warn"}${w}))`),
    withChange(ctx, (w) => `sum(increase(${HOOKS}{outcome="deny"}${w}))`),
    withChange(ctx, (w) => `sum(increase(crok_guard_checks_total{flagged="true"}${w}))`),
  ]);
  return {
    kind: "stats",
    items: [
      statOf(t("Checks"), checks.now, "count", { change: changeOf(checks.now, checks.before), better: "none" }),
      statOf(t("Warns"), warns.now, "count", { change: changeOf(warns.now, warns.before), better: "down" }),
      statOf(t("Denied"), denies.now, "count", { better: "down" }),
      statOf(t("Flagged by crok"), flagged.now, "count", { change: changeOf(flagged.now, flagged.before), better: "down" }),
    ],
  };
}

async function checksOverTime(ctx: BuildCtx): Promise<Block> {
  const series = await promRange(ctx, `sum by (outcome) (increase(${HOOKS}[$__interval]))`);
  const named = wholePoints(series).map((s) => ({ ...s, name: ctx.t(label(s, "outcome") || "pass") }));
  return chartBlock(ctx, named, { style: "bars", stacked: true, unit: "count", step: chartStepOf(ctx) });
}

const guards: PageDef = {
  id: "guards",
  title: "Guards",
  subtitle: "Evaluation",
  ranges: METRICS,
  range: "7d",
  url: appUrl("/a/grafana-agento11y-app"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("Guard checks"), () => guardStats(ctx), t("Guards run in warn mode: a warn is recorded and the call goes ahead.")),
      section(t("Warns by guard"), () =>
        rankedProm(ctx, `sum by (rule_id) (increase(${HOOKS}{outcome!="pass"}[$__range]))`, "rule_id", "count"),
      ),
      section(t("Checks by guard"), () => rankedProm(ctx, `sum by (rule_id) (increase(${HOOKS}[$__range]))`, "rule_id", "count")),
      section(t("Checks over time"), () => checksOverTime(ctx)),
      section(t("Checks by phase"), () =>
        rankedProm(ctx, `sum by (phase) (increase(${HOOKS}[$__range]))`, "phase", "count", (n) => ctx.t(n)),
      ),
    ]);
  },
};

type Experiment = Record<string, unknown>;

async function publishedExperiments(ctx: BuildCtx): Promise<Block> {
  const runs = items<Experiment>(await ctx.g.get(`${AO}/eval/experiments`));
  const rows: ListRow[] = runs
    .map((run) => {
      const created = time(run.created_at ?? run.started_at);
      const status = String(run.status ?? "");
      const chips: Chip[] = [];
      for (const key of ["status", "model", "agent_version", "commit"]) {
        const value = run[key];
        if (typeof value === "string" && value) chips.push({ t: key === "status" ? ctx.t(value) : value });
      }
      return {
        title: String(run.name ?? run.display_name ?? run.run_id ?? run.id ?? "—"),
        ...(chips.length ? { detail: chips } : {}),
        ...(created ? { time: created } : {}),
        ...(status === "failed" ? { status: "bad" as const } : status === "completed" || status === "finalized" ? { status: "ok" as const } : {}),
      };
    })
    .sort((a, b) => (b.time ?? 0) - (a.time ?? 0))
    .slice(0, 15);
  return { kind: "list", rows, empty: ctx.t("No experiments published yet: evals/run.py run --publish sends one.") };
}

/** The eval runs seen in crok's own metrics (origin=eval), newest first: each trial is its own crok process. */
async function evalRuns(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const filter = 'agento11y_tag_origin="eval",gen_ai_operation_name="streamText"';
  const [calls, failed, trials, tokens] = await Promise.all([
    promInstant(ctx, `sum by (agento11y_tag_eval_run) (max_over_time(gen_ai_client_operation_duration_seconds_count{${filter}}[$__range]))`),
    promInstant(ctx, `sum by (agento11y_tag_eval_run) (max_over_time(gen_ai_client_operation_duration_seconds_count{${filter},error_type!=""}[$__range]))`),
    promInstant(ctx, `count by (agento11y_tag_eval_run) (count by (agento11y_tag_eval_run, agento11y_tag_eval_trial) (max_over_time(gen_ai_client_operation_duration_seconds_count{${filter}}[$__range])))`),
    promInstant(ctx, `sum by (agento11y_tag_eval_run) (max_over_time(gen_ai_client_token_usage_sum{${filter}}[$__range]))`),
  ]);
  const key = "agento11y_tag_eval_run";
  const callsBy = byLabel(calls, key);
  const failedBy = byLabel(failed, key);
  const trialsBy = byLabel(trials, key);
  const tokensBy = byLabel(tokens, key);
  const runTime = (run: string) => {
    const m = /(\d{8})T(\d{6})Z/.exec(run);
    return m ? Date.UTC(+m[1].slice(0, 4), +m[1].slice(4, 6) - 1, +m[1].slice(6, 8), +m[2].slice(0, 2), +m[2].slice(2, 4), +m[2].slice(4, 6)) : undefined;
  };
  const rows: ListRow[] = [...callsBy.entries()]
    .map(([run, n]) => {
      const fails = Math.round(failedBy.get(run) ?? 0);
      const at = runTime(run);
      return {
        title: run,
        detail: [
          { v: Math.round(trialsBy.get(run) ?? 0), u: "count" as const, s: t("trials") },
          { v: Math.round(n), u: "count" as const, s: t("model calls") },
          ...(tokensBy.get(run) ? [{ v: Math.round(tokensBy.get(run)!), u: "tokens" as const, s: t("tokens") }] : []),
          ...(fails ? [{ v: fails, u: "count" as const, s: t("failed") }] : []),
        ] as Chip[],
        ...(at ? { time: at } : {}),
        ...(fails ? { status: "warn" as const } : {}),
      };
    })
    .sort((a, b) => (b.time ?? 0) - (a.time ?? 0))
    .slice(0, 15);
  return { kind: "list", rows, empty: t("No eval runs in this range") };
}

const experiments: PageDef = {
  id: "experiments",
  title: "Experiments",
  subtitle: "Evaluation",
  ranges: METRICS,
  range: "14d",
  url: appUrl("/a/grafana-agento11y-app"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("Published experiments"), () => publishedExperiments(ctx)),
      section(t("Eval runs in the traffic"), () => evalRuns(ctx), t("Runs of evals/run.py, from crok's own metrics (origin eval).")),
    ]);
  },
};

// ---------------------------------------------------------------------------------------------------------------
// Agent Observability

const CROK_CALLS = '{resource.service.name="crok"&&span.gen_ai.operation.name!="invoke_agent"&&span.gen_ai.operation.name!="execute_tool"&&span.gen_ai.request.model!=nil}';

type Agent = {
  agent_name?: string;
  generation_count?: number;
  version_count?: number;
  tool_count?: number;
  latest_declared_version?: string;
  latest_seen_at?: string;
  token_estimate?: { total?: number };
};

async function agentList(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const agents = items<Agent>(await ctx.g.get(`${AO}/query/agents?limit=100`));
  const rows: ListRow[] = agents
    .map((a) => ({
      title: a.agent_name ?? "—",
      detail: [
        ...(a.generation_count ? [{ v: a.generation_count, u: "count" as const, s: t("generations") }] : []),
        ...(a.version_count ? [{ v: a.version_count, u: "count" as const, s: t("versions") }] : []),
        ...(a.tool_count ? [{ v: a.tool_count, u: "count" as const, s: t("tools") }] : []),
        ...(a.token_estimate?.total ? [{ v: a.token_estimate.total, u: "tokens" as const, s: t("tokens of prompt") }] : []),
        ...(a.latest_declared_version ? [{ t: a.latest_declared_version }] : []),
      ] as Chip[],
      ...(time(a.latest_seen_at) ? { time: time(a.latest_seen_at) } : {}),
    }))
    .sort((a, b) => (b.time ?? 0) - (a.time ?? 0));
  return { kind: "list", rows, empty: t("No agents yet") };
}

async function agentStats(ctx: BuildCtx): Promise<Block> {
  const t = ctx.t;
  const [calls, failed, p50, p95] = await Promise.all([
    tempoQuery(ctx, `${CROK_CALLS}|count_over_time()`, "totals"),
    tempoQuery(ctx, `{resource.service.name="crok"&&span.gen_ai.request.model!=nil&&span.gen_ai.operation.name!="invoke_agent"&&span.gen_ai.operation.name!="execute_tool"&&status=error&&span.crok.cancelled=nil}|count_over_time()`, "totals"),
    tempoQuery(ctx, `${CROK_CALLS}|quantile_over_time(duration,0.5)`, "instant"),
    tempoQuery(ctx, `${CROK_CALLS}|quantile_over_time(duration,0.95)`, "instant"),
  ]);
  const sum = (s: Series[]) => s.reduce((acc, x) => acc + total(x), 0);
  const first = (s: Series[]) => s.map(lastValue).find((v) => v !== null) ?? null;
  const n = sum(calls);
  return {
    kind: "stats",
    items: [
      statOf(t("Model calls"), n, "count", { better: "none" }),
      statOf(t("Error rate"), n > 0 ? sum(failed) / n : null, "ratio", { better: "down" }),
      statOf(t("p50 call time"), first(p50), "seconds", { better: "down" }),
      statOf(t("p95 call time"), first(p95), "seconds", { better: "down" }),
    ],
  };
}

async function callsByAgent(ctx: BuildCtx, chart: boolean): Promise<Block> {
  const series = await tempoQuery(ctx, `${CROK_CALLS}|count_over_time() by(span.gen_ai.agent.name)`, chart ? "chart" : "totals");
  if (chart) return chartBlock(ctx, series, { style: "line", unit: "count", step: chartStepOf(ctx) });
  return rankingBlock(ctx, series.map((s) => ({ label: s.name, value: total(s) })), "count");
}

async function rankedTempo(ctx: BuildCtx, query: string, unit: "count" | "tokens", rename?: (n: string) => string): Promise<Block> {
  const series = await tempoQuery(ctx, query, "totals");
  return rankingBlock(ctx, series.map((s) => ({ label: rename ? rename(s.name) : s.name, value: total(s) })), unit);
}

const agents: PageDef = {
  id: "agents",
  title: "Agents",
  subtitle: "Agent Observability",
  ranges: TRACES,
  range: "24h",
  url: appUrl("/a/grafana-agento11y-app"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("crok's model calls"), () => agentStats(ctx), t("Every model call crok makes, whichever provider.")),
      section(t("Calls by agent"), () => callsByAgent(ctx, false)),
      section(t("Calls over time by agent"), () => callsByAgent(ctx, true)),
      section(t("Calls by provider"), () =>
        rankedTempo(ctx, `${CROK_CALLS}|count_over_time() by(span.gen_ai.provider.name)`, "count", provider),
      ),
      section(t("Calls by surface"), () =>
        rankedTempo(ctx, `${CROK_CALLS}|count_over_time() by(span.agento11y.tag.surface)`, "count", (n) => ctx.t(n)),
      ),
      section(t("Calls by machine"), () => rankedTempo(ctx, `${CROK_CALLS}|count_over_time() by(span.agento11y.tag.host)`, "count")),
      section(t("Agents"), () => agentList(ctx), t("Generations since each agent was first seen.")),
    ]);
  },
};

type Conversation = { id?: string; title?: string; generation_count?: number; last_generation_at?: string; created_at?: string };

const conversations: PageDef = {
  id: "conversations",
  title: "Conversations",
  subtitle: "Agent Observability",
  ranges: [],
  range: "24h",
  url: appUrl("/a/grafana-agento11y-app"),
  build: (ctx) => {
    const t = ctx.t;
    return sections([
      section(t("Latest conversations"), async () => {
        const list = items<Conversation>(await ctx.g.get(`${AO}/query/conversations?limit=30`));
        const rows: ListRow[] = list.map((c) => {
          const title = c.title && c.title !== c.id ? clip(c.title, 120) : t("Untitled");
          const at = time(c.last_generation_at ?? c.created_at);
          return {
            title,
            detail: [
              ...(c.generation_count ? [{ v: c.generation_count, u: "count" as const, s: t("generations") }] : []),
              ...(c.created_at && time(c.created_at) !== at ? [{ t: fill(t("started {date}"), { date: (c.created_at ?? "").slice(0, 10) }) }] : []),
            ] as Chip[],
            ...(at ? { time: at } : {}),
          };
        });
        return { kind: "list", rows, empty: t("No conversations yet") };
      }),
    ]);
  },
};

type SloState = { uuid: string; name: string; objective: number; window: string; sli: number | null; byProvider: Map<string, number> };

async function sloStates(ctx: BuildCtx): Promise<SloState[]> {
  const [slos, sli] = await Promise.all([
    ctx.g.get("/api/plugins/grafana-slo-app/resources/v1/slo"),
    promInstant(ctx, "grafana_slo_sli_window"),
  ]);
  return items<{ uuid?: string; name?: string; objectives?: { value?: number; window?: string }[] }>(slos).map((slo) => {
    const uuid = slo.uuid ?? "";
    const mine = sli.filter((s) => label(s, "grafana_slo_uuid") === uuid);
    const overall = mine.find((s) => !label(s, "gen_ai_provider_name"));
    const byProvider = new Map<string, number>();
    for (const s of mine) {
      const p = label(s, "gen_ai_provider_name");
      const v = lastValue(s);
      if (p && v !== null) byProvider.set(provider(p), v);
    }
    return {
      uuid,
      name: slo.name ?? uuid,
      objective: slo.objectives?.[0]?.value ?? 0,
      window: slo.objectives?.[0]?.window ?? "28d",
      sli: overall ? lastValue(overall) : null,
      byProvider,
    };
  });
}

const slos: PageDef = {
  id: "slos",
  title: "SLOs",
  subtitle: "Agent Observability",
  ranges: [],
  range: "24h",
  url: appUrl("/a/grafana-slo-app/manage-slos"),
  build: async (ctx) => {
    const t = ctx.t;
    let states: SloState[];
    try {
      states = await sloStates(ctx);
    } catch (error) {
      return [{ title: t("SLOs"), block: { kind: "error", message: message(error) } }];
    }
    if (states.length === 0) return [{ block: { kind: "note", text: t("No SLOs on this stack yet.") } }];
    const out: Section[] = [];
    for (const s of states) {
      // An SLO grouped by provider alone has no overall SLI: its worst provider stands for it.
      const worst = s.byProvider.size > 0 ? Math.min(...s.byProvider.values()) : null;
      const sli = s.sli ?? worst;
      const budget = sli === null || s.objective >= 1 ? null : 1 - (1 - sli) / (1 - s.objective);
      out.push({
        title: s.name,
        footer: fill(t("Objective {objective} over {window}."), { objective: `${Math.round(s.objective * 1000) / 10}%`, window: s.window }),
        block: {
          kind: "stats",
          items: [
            statOf(s.sli === null && worst !== null ? t("Worst provider") : t("Now"), sli, "ratio", { better: "up" }),
            statOf(t("Objective"), s.objective, "ratio"),
            statOf(t("Error budget left"), budget, "ratio", { better: "up" }),
          ],
        },
      });
      if (s.byProvider.size > 0) {
        out.push({
          title: fill(t("{name}, by provider"), { name: s.name }),
          block: rankingBlock(ctx, [...s.byProvider.entries()].map(([label, value]) => ({ label, value })), "ratio", {
            order: "asc",
            keepZero: true,
          }),
        });
      }
    }
    return out;
  },
};

type Rule = { name: string; state: string; health: string; type?: string; labels?: Record<string, string>; lastEvaluation?: string; activeAt?: string; lastError?: string };
type RuleGroup = { name: string; file?: string; rules: Rule[] };

async function ruleGroups(ctx: BuildCtx): Promise<RuleGroup[]> {
  const doc = (await ctx.g.get("/api/prometheus/grafana/api/v1/rules")) as { data?: { groups?: RuleGroup[] } } | null;
  return doc?.data?.groups ?? [];
}

async function alertRules(ctx: BuildCtx): Promise<(Rule & { group: string })[]> {
  const groups = await ruleGroups(ctx);
  return groups.flatMap((g) => g.rules.filter((r) => r.type === "alerting").map((r) => ({ ...r, group: g.name })));
}

const alerts: PageDef = {
  id: "alerts",
  title: "Alerts",
  subtitle: "Agent Observability",
  ranges: [],
  range: "24h",
  url: appUrl("/alerting/list"),
  build: async (ctx) => {
    const t = ctx.t;
    let groups: RuleGroup[];
    try {
      groups = await ruleGroups(ctx);
    } catch (error) {
      return [{ title: t("Alert rules"), block: { kind: "error", message: message(error) } }];
    }
    const alerting = groups.flatMap((g) => g.rules.filter((r) => r.type === "alerting").map((r) => ({ ...r, group: g.name })));
    const recording = groups.filter((g) => g.rules.length > 0 && g.rules.every((r) => r.type === "recording"));
    const alertRows: ListRow[] = alerting.map((r) => {
      const state = r.state === "firing" ? "bad" : r.state === "pending" ? "warn" : r.health !== "ok" ? "warn" : "ok";
      return {
        title: r.name,
        detail: [
          { t: t(r.state === "inactive" ? "normal" : r.state) },
          ...(r.labels?.severity ? [{ t: t(r.labels.severity) }] : []),
          ...(r.health !== "ok" ? [{ t: r.lastError ? clip(r.lastError, 100) : t(r.health) }] : []),
          { t: r.group },
        ] as Chip[],
        ...(time(r.activeAt ?? r.lastEvaluation) ? { time: time(r.state === "inactive" ? r.lastEvaluation : (r.activeAt ?? r.lastEvaluation)) } : {}),
        status: state as ListRow["status"],
      };
    });
    const groupRows: ListRow[] = recording.map((g) => {
      const bad = g.rules.filter((r) => r.health !== "ok").length;
      const last = Math.max(0, ...g.rules.map((r) => time(r.lastEvaluation) ?? 0));
      return {
        title: g.name,
        detail: [
          { v: g.rules.length, u: "count" as const, s: t("rules") },
          ...(bad ? [{ v: bad, u: "count" as const, s: t("unhealthy") }] : []),
          ...(g.file ? [{ t: g.file }] : []),
        ] as Chip[],
        ...(last ? { time: last } : {}),
        status: bad ? "bad" : "ok",
      };
    });
    return [
      { title: t("Alert rules"), footer: t("The time is when a rule last ran, or since when it fires."), block: { kind: "list", rows: alertRows, empty: t("No alert rules yet") } },
      { title: t("Recording rules"), block: { kind: "list", rows: groupRows, empty: t("No recording rules") } },
    ];
  },
};

export const PAGES: Record<string, PageDef> = Object.fromEntries(
  [home, overview, claude, openrouter, crok, harness, history, explorer, evaluators, guards, experiments, agents, conversations, slos, alerts].map(
    (p) => [p.id, p],
  ),
);

/** The arguments as the cache keys them: a known range of the page (else its default) and a known language. */
export function normalize(page: PageDef, range: string | undefined, lang: string | undefined): { range: string; lang: Lang } {
  const short = (lang ?? "en").toLowerCase().split(/[-_]/)[0];
  return {
    range: range && page.ranges.includes(range) ? range : page.range,
    lang: (LANGS as readonly string[]).includes(short) ? (short as Lang) : "en",
  };
}

/** Builds one page from Grafana. Panels that fail become error blocks; only a missing page throws. */
export async function buildPage(g: Grafana, id: string, range: string | undefined, lang: string | undefined, now = Date.now()): Promise<Page> {
  const def = PAGES[id];
  if (!def) throw new Error(`No page ${id}.`);
  const args = normalize(def, range, lang);
  const t = translator(args.lang);
  const ctx = makeCtx(g, args.range, args.lang, t, now);
  const built = await def.build(ctx);
  return {
    id,
    title: t(def.title),
    subtitle: t(def.subtitle),
    range: args.range,
    ranges: def.ranges,
    url: def.url(g.url, args.range),
    builtAt: Date.now(),
    sections: built,
  };
}
