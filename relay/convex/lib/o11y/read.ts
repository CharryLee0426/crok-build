/**
 * Turning Grafana into blocks: a live dashboard's panel read the way the panel reads it (totals, the last value, the
 * week-over-week pair, a ratio, series after its renames, span rows), and PromQL of the pages' own.
 */
import type { Grafana, Series } from "./grafana";
import {
  GrafanaError,
  applyRenames,
  builtinVars,
  chartStep,
  dashboardVars,
  durationText,
  hasValue,
  interpolate,
  lastValue,
  mergeByName,
  parseDuration,
  rowsOf,
  seriesOf,
  total,
} from "./grafana";
import { nameTranslator } from "./i18n";
import type { Block, Chip, ChartSeries, Lang, ListRow, RankRow, Section, Stat, Unit } from "./types";
import { RANGE_MS } from "./types";

export const PROM_UID = "grafanacloud-prom";
export const TEMPO_UID = "grafanacloud-traces";

/** Everything a page builder needs: Grafana, the time range, the language, and a limit on parallel queries. */
export type BuildCtx = {
  g: Grafana;
  range: string;
  rangeMs: number;
  from: number;
  to: number;
  lang: Lang;
  t: (english: string) => string;
  /** A name from the data (a series, a row), translated only where i18n.ts knows it. */
  name: (name: string) => string;
  limit: <T>(work: () => Promise<T>) => Promise<T>;
  dashboards: Map<string, Promise<Dashboard>>;
};

/** At most `n` jobs at a time. */
export function limiter(n: number): <T>(work: () => Promise<T>) => Promise<T> {
  let running = 0;
  const waiting: (() => void)[] = [];
  return async (work) => {
    while (running >= n) await new Promise<void>((resolve) => waiting.push(resolve));
    running++;
    try {
      return await work();
    } finally {
      running--;
      waiting.shift()?.();
    }
  };
}

export function makeCtx(g: Grafana, range: string, lang: Lang, t: (english: string) => string, now = Date.now()): BuildCtx {
  const rangeMs = RANGE_MS[range] ?? RANGE_MS["24h"];
  return {
    g,
    range,
    rangeMs,
    from: now - rangeMs,
    to: now,
    lang,
    t,
    name: nameTranslator(lang),
    limit: limiter(4),
    dashboards: new Map(),
  };
}

export function message(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  return text.length > 300 ? `${text.slice(0, 300)}…` : text;
}

/** A titled section; whatever goes wrong while making its block becomes an error block. */
export async function section(
  title: string | undefined,
  make: () => Promise<Block>,
  footer?: string,
): Promise<Section> {
  try {
    const block = await make();
    return { title, ...(footer ? { footer } : {}), block };
  } catch (error) {
    return { title, block: { kind: "error", message: message(error) } };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Dashboards and panels

type Target = Record<string, unknown> & { refId?: string; datasource?: { type?: string; uid?: string } };
type Override = { matcher?: { id?: string; options?: unknown }; properties?: { id: string; value?: unknown }[] };

export type Panel = {
  type: string;
  title: string;
  targets?: Target[];
  transformations?: { id: string; options?: Record<string, unknown> }[] | null;
  fieldConfig?: { defaults?: { unit?: string }; overrides?: Override[] };
  options?: { reduceOptions?: { calcs?: string[] } };
  /** A panel's own range ("14d"), whatever the dashboard's. */
  timeFrom?: string;
  panels?: Panel[];
};

export type Dashboard = { uid: string; title: string; panels?: Panel[]; templating?: { list?: never[] } };

export function dashboard(ctx: BuildCtx, uid: string): Promise<Dashboard> {
  let pending = ctx.dashboards.get(uid);
  if (!pending) {
    pending = ctx.g.get(`/api/dashboards/uid/${encodeURIComponent(uid)}`).then((doc) => {
      const board = (doc as { dashboard?: Dashboard } | null)?.dashboard;
      if (!board) throw new GrafanaError(`No dashboard ${uid}.`);
      return board;
    });
    ctx.dashboards.set(uid, pending);
  }
  return pending;
}

function* walk(panels: Panel[] | undefined): Generator<Panel> {
  for (const panel of panels ?? []) {
    yield panel;
    yield* walk(panel.panels);
  }
}

export async function findPanel(ctx: BuildCtx, uid: string, title: string, type?: string): Promise<Panel> {
  const board = await dashboard(ctx, uid);
  for (const panel of walk(board.panels)) {
    if (panel.type !== "row" && panel.title === title && (!type || panel.type === type)) return panel;
  }
  throw new GrafanaError(`"${title}" is no longer on ${board.title}.`);
}

/** Grafana's unit names → the phones' units. */
export function unitOf(grafana: string | undefined): Unit {
  switch (grafana) {
    case "currencyUSD":
      return "usd";
    case "percentunit":
      return "ratio";
    case "s":
      return "seconds";
    case "ms":
      return "ms";
    case "bytes":
    case "decbytes":
      return "bytes";
    case "suffix: req/min":
      return "perMin";
    case "suffix: tok/s":
      return "tps";
    default:
      return "count";
  }
}

function overrideUnit(panel: Panel, match: (name: string) => boolean): string | undefined {
  for (const o of panel.fieldConfig?.overrides ?? []) {
    const name = String(o.matcher?.options ?? "");
    if (!match(name)) continue;
    const unit = o.properties?.find((p) => p.id === "unit")?.value;
    if (typeof unit === "string") return unit;
  }
  return undefined;
}

/** The unit of a panel's value: its own, or the one its value column / query A override sets. */
function panelUnit(panel: Panel): Unit {
  const own = panel.fieldConfig?.defaults?.unit;
  const column = overrideUnit(panel, (name) => /^(Total|Last \*|Value) \(sum\)$/.test(name) || name === "A");
  return unitOf(column ?? own);
}

type Ran = { panel: Panel; series: Series[]; rows: Record<string, unknown>[]; from: number };

/**
 * A quantile series the panel's renames left as Tempo names it, `{p=0.9, span.gen_ai.tool.name="grep"}`, becomes
 * "grep p90" (and a group-less `{p=0.9}` "p90").
 */
function quantileName(name: string): string {
  const match = /^\{p=([\d.]+)(?:, [^=]+="?([^"]*)"?)?\}$/.exec(name);
  if (!match) return name;
  const p = `p${Math.round(Number(match[1]) * 100)}`;
  return match[2] !== undefined ? `${match[2]} ${p}` : p;
}

/**
 * Runs a panel's own queries over the page's range, its variables at their saved values. `chart` gives Tempo range
 * queries and Prometheus queries without a fixed interval a chart's step; otherwise they keep the dashboard's.
 */
export async function runPanel(
  ctx: BuildCtx,
  uid: string,
  title: string,
  opts: { chart?: boolean; type?: string } = {},
): Promise<Ran> {
  const [board, panel] = await Promise.all([dashboard(ctx, uid), findPanel(ctx, uid, title, opts.type)]);
  const rangeMs = parseDuration(panel.timeFrom?.replace(/^now-/, "")) ?? ctx.rangeMs;
  const from = ctx.to - rangeMs;
  const step = chartStep(rangeMs);
  const vars = { ...dashboardVars(board as never), ...builtinVars(rangeMs, step) };
  const legends: Record<string, string | undefined> = {};
  const fill = (value: unknown): unknown =>
    typeof value === "string"
      ? interpolate(value, vars)
      : Array.isArray(value)
        ? value.map(fill)
        : value && typeof value === "object"
          ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, fill(v)]))
          : value;
  const queries = (panel.targets ?? []).map((target, index) => {
    const q = fill(target) as Target;
    q.refId = q.refId || String.fromCharCode(65 + index);
    const kind = q.datasource?.type;
    if (kind === "tempo") {
      q.datasource = { type: "tempo", uid: q.datasource?.uid || TEMPO_UID };
      if (q.tableType !== "spans" && q.metricsQueryType === "range" && (opts.chart || !q.step)) {
        q.step = durationText(step);
      }
    } else if (kind === "prometheus") {
      q.datasource = { type: "prometheus", uid: q.datasource?.uid || PROM_UID };
      const interval = parseDuration(q.interval);
      q.intervalMs = interval ?? step;
      q.maxDataPoints = 150;
      legends[q.refId] = typeof q.legendFormat === "string" ? q.legendFormat : undefined;
    }
    return q;
  });
  const response = await ctx.limit(() =>
    ctx.g.post("/api/ds/query", { queries, from: String(from), to: String(ctx.to) }),
  );
  const isSpans = queries.some((q) => q.tableType === "spans");
  if (isSpans) {
    const { rows, errors } = rowsOf(response);
    if (rows.length === 0 && errors.length > 0) throw new GrafanaError(errors[0]);
    return { panel, series: [], rows, from };
  }
  const { series, errors } = seriesOf(response, legends);
  if (!series.some(hasValue) && errors.length > 0) throw new GrafanaError(errors[0]);
  const renamed = applyRenames(series, panel.transformations).map((s) => ({ ...s, name: quantileName(s.name) }));
  return { panel, series: renamed, rows: [], from };
}

// ---------------------------------------------------------------------------------------------------------------
// Stats

export type StatSpec = {
  panel: string;
  label?: string;
  unit?: Unit;
  better?: "up" | "down" | "none";
  /** How the panel reads its value; by default as the panel does. */
  read?: "total" | "last" | "ratio" | "wow";
};

function ratioNames(panel: Panel): { left: string; right: string } | null {
  const calc = (panel.transformations ?? []).find((t) => t.id === "calculateField");
  const binary = calc?.options?.binary as { left?: string; right?: string; operator?: string } | undefined;
  return binary?.left && binary.right && binary.operator === "/" ? { left: binary.left, right: binary.right } : null;
}

function readMode(panel: Panel): NonNullable<StatSpec["read"]> {
  if (ratioNames(panel)) return "ratio";
  if (panel.options?.reduceOptions?.calcs?.includes("sum")) return "total";
  const byRef = (panel.fieldConfig?.overrides ?? []).some((o) => o.matcher?.id === "byFrameRefID");
  if (byRef && (panel.targets?.length ?? 0) === 2) return "wow";
  return "last";
}

function firstLast(series: Series[]): number | null {
  for (const s of series) {
    const value = lastValue(s);
    if (value !== null) return value;
  }
  return null;
}

/** One number from a stat panel, read as the panel reads it. */
export async function statFromPanel(ctx: BuildCtx, uid: string, spec: StatSpec): Promise<Stat> {
  const { panel, series } = await runPanel(ctx, uid, spec.panel, { type: "stat" });
  const read = spec.read ?? readMode(panel);
  let value: number | null = null;
  let change: number | null | undefined;
  if (read === "total") {
    value = series.some(hasValue) ? series.reduce((sum, s) => sum + total(s), 0) : 0;
  } else if (read === "ratio") {
    const names = ratioNames(panel)!;
    const sum = (name: string) => series.filter((s) => s.name === name).reduce((acc, s) => acc + total(s), 0);
    const right = sum(names.right);
    value = right > 0 ? sum(names.left) / right : null;
  } else if (read === "wow") {
    value = firstLast(series.filter((s) => s.refId === "A"));
    change = firstLast(series.filter((s) => s.refId === "B"));
    if (change !== null && !Number.isFinite(change)) change = null;
  } else {
    value = firstLast(series);
  }
  const unit = spec.unit ?? panelUnit(panel);
  return {
    label: spec.label ?? ctx.t(panel.title),
    value: value === null ? null : tidy(value, unit),
    unit,
    ...(change !== undefined ? { change, better: spec.better ?? "up" } : spec.better ? { better: spec.better } : {}),
  };
}

/** Counts from `increase()` and sums come out fractional; the phones show what a person would count. */
function tidy(value: number, unit: Unit): number {
  if (unit === "count" || unit === "tokens") return Math.abs(value) >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
  return value;
}

/** A grid of stat panels; a panel that fails shows "—", and only when every one fails is the block an error. */
export async function statsFromPanels(ctx: BuildCtx, uid: string, specs: StatSpec[]): Promise<Block> {
  const results = await Promise.allSettled(specs.map((spec) => statFromPanel(ctx, uid, spec)));
  if (results.every((r) => r.status === "rejected")) throw (results[0] as PromiseRejectedResult).reason;
  const items = results.map((result, i): Stat =>
    result.status === "fulfilled"
      ? result.value
      : { label: specs[i].label ?? ctx.t(specs[i].panel), value: null, unit: specs[i].unit ?? "count" },
  );
  return { kind: "stats", items };
}

// ---------------------------------------------------------------------------------------------------------------
// Charts

const ADDITIVE: Unit[] = ["usd", "count", "tokens"];

export type ChartSpec = {
  style: "line" | "bars";
  stacked?: boolean;
  unit?: Unit;
  /** Series kept; the rest fold into "Other" (bars) or are left out (lines). */
  keep?: number;
  /** Names drawn dashed (a comparison line). */
  dashed?: string[];
  /** Renames of the page's own (crok's provider names, say). */
  rename?: (name: string) => string;
  /** The name of a series Grafana names after its query ("count_over_time"): the chart's own title. */
  name?: string;
};

/** A name that is the query's expression, not a thing ("(count_over_time / count_over_time)", "Value"). */
function isExpressionName(name: string): boolean {
  return /_over_time|^\(.*\)$|^(Value|value)$/.test(name);
}

/**
 * Additive series on the step grid from `from` to `to`, a missing step as 0: Tempo sends sum_over_time only for
 * steps that had spans, and a line between those alone would lie about the steps between.
 */
function zeroFilled(series: Series[], from: number, to: number, step: number): Series[] {
  const start = Math.floor(from / step) * step;
  const grid: number[] = [];
  for (let at = start; at <= to; at += step) grid.push(at);
  if (grid.length > 400) return series;
  return series.map((s) => {
    const at = new Map<number, number>();
    for (const [time, value] of s.points) {
      if (value === null) continue;
      const slot = Math.round((time - start) / step) * step + start;
      at.set(slot, (at.get(slot) ?? 0) + value);
    }
    return { ...s, points: grid.map((time) => [time, at.get(time) ?? 0] as [number, number]) };
  });
}

/** Series → a chart block: the largest kept, slots in alphabetical order, "Other" for the rest of the bars. */
export function chartBlock(
  ctx: BuildCtx,
  input: Series[],
  spec: ChartSpec & { unit: Unit; step: number; from?: number },
): Block {
  const keep = spec.keep ?? 6;
  const renamed = input.map((s) => {
    const name = spec.rename ? spec.rename(s.name) : s.name;
    return { ...s, name: isExpressionName(name) ? (spec.name ?? ctx.t("Value")) : name };
  });
  const additive = ADDITIVE.includes(spec.unit);
  // An additive series that stayed at 0 ("Cache write, 5 min" nobody used) is noise in the legend.
  const merged = mergeByName(renamed).filter((s) => hasValue(s) && (!additive || s.points.some(([, v]) => v)));
  const series = additive ? zeroFilled(merged, spec.from ?? ctx.from, ctx.to, spec.step) : merged;
  const size = (s: Series) => {
    const values = s.points.map(([, v]) => v).filter((v): v is number => v !== null);
    return additive ? values.reduce((a, b) => a + b, 0) : values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0;
  };
  const dashedNames = new Set(spec.dashed ?? []);
  const dashed = series.filter((s) => dashedNames.has(s.name));
  const solid = series.filter((s) => !dashedNames.has(s.name)).sort((a, b) => size(b) - size(a));
  const kept = solid.slice(0, keep);
  const rest = solid.slice(keep);
  const slots = new Map([...kept].sort((a, b) => a.name.localeCompare(b.name)).map((s, i) => [s.name, (i % 8) + 1]));
  const out: ChartSeries[] = kept.map((s) => ({
    name: ctx.name(s.name),
    slot: slots.get(s.name)!,
    total: additive ? round(size(s)) : null,
    points: s.points,
  }));
  let more = 0;
  if (rest.length > 0) {
    if (spec.style === "bars" && additive) {
      const other = mergeByName(rest.map((s) => ({ ...s, name: "\u0000other" })))[0];
      out.push({ name: ctx.t("Other"), slot: 0, total: round(size(other)), points: other.points });
    } else {
      more = rest.length;
    }
  }
  for (const s of dashed) {
    out.push({ name: ctx.name(s.name), slot: 0, total: additive ? round(size(s)) : null, dashed: true, points: s.points });
  }
  return {
    kind: "chart",
    style: spec.style,
    ...(spec.stacked ? { stacked: true } : {}),
    unit: spec.unit,
    step: spec.step,
    series: out.map((s) => ({ ...s, points: s.points.map(([t, v]) => [t, v === null ? null : round(v)]) })),
    ...(more ? { more } : {}),
  };
}

function round(value: number): number {
  return Number(value.toPrecision(6));
}

/** The step a panel's chart came back at: the dashboard's fixed interval, else the chart step. */
function panelStep(ctx: BuildCtx, panel: Panel): number {
  for (const target of panel.targets ?? []) {
    const interval = parseDuration(target.interval);
    if (interval) return interval;
  }
  return chartStep(ctx.rangeMs);
}

export async function chartFromPanel(ctx: BuildCtx, uid: string, title: string, spec: ChartSpec): Promise<Block> {
  const { panel, series, from } = await runPanel(ctx, uid, title, { chart: true, type: "timeseries" });
  const dashed =
    spec.dashed ??
    (panel.fieldConfig?.overrides ?? [])
      .filter((o) => o.properties?.some((p) => p.id === "custom.lineStyle"))
      .map((o) => String(o.matcher?.options ?? ""));
  return chartBlock(ctx, series, {
    ...spec,
    dashed,
    unit: spec.unit ?? panelUnit(panel),
    step: panelStep(ctx, panel),
    from,
    name: spec.name ?? ctx.t(title),
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Rankings

export type RankingSpec = {
  unit?: Unit;
  limit?: number;
  /** Each row's share of the total as a chip (pie charts). */
  shares?: boolean;
  rename?: (name: string) => string;
  /** Smallest first (pass rates: the worst on top). */
  order?: "asc";
  /** Keeps rows whose value is 0 (a pass rate of 0 %). */
  keepZero?: boolean;
};

export function rankingBlock(ctx: BuildCtx, values: { label: string; value: number; detail?: Chip[] }[], unit: Unit, spec: RankingSpec = {}): Block {
  const limit = spec.limit ?? 8;
  const merged = new Map<string, { label: string; value: number; detail?: Chip[] }>();
  for (const row of values) {
    const label = spec.rename ? spec.rename(row.label) : row.label;
    const before = merged.get(label);
    merged.set(label, before ? { ...before, value: before.value + row.value } : { ...row, label });
  }
  const sorted = [...merged.values()]
    .filter((row) => spec.keepZero || row.value !== 0)
    .sort((a, b) => (spec.order === "asc" ? a.value - b.value : b.value - a.value));
  const sum = sorted.reduce((acc, row) => acc + row.value, 0);
  const rows: RankRow[] = sorted.slice(0, limit).map((row) => ({
    label: ctx.name(row.label),
    value: tidy(round(row.value), unit),
    ...(spec.shares && sum > 0
      ? { detail: [{ v: round(row.value / sum), u: "ratio" as const }, ...(row.detail ?? [])] }
      : row.detail
        ? { detail: row.detail }
        : {}),
  }));
  return {
    kind: "ranking",
    unit,
    rows,
    ...(sorted.length > limit ? { more: sorted.length - limit } : {}),
    empty: ctx.t("Nothing in this range"),
  };
}

/** A ranked table (or pie) panel: each name's total, or its last value for a table of percentiles. */
export async function rankingFromPanel(ctx: BuildCtx, uid: string, title: string, spec: RankingSpec = {}): Promise<Block> {
  const { panel, series } = await runPanel(ctx, uid, title);
  const reducers = (panel.transformations ?? []).find((t) => t.id === "reduce")?.options?.reducers as string[] | undefined;
  const last = reducers?.[0] === "lastNotNull";
  // A table of one percentile ("p90 tool time by tool") names its rows "grep p90"; the title already says p90.
  const suffix = /( p\d+)$/.exec(series[0]?.name ?? "")?.[1];
  const strip = suffix && series.every((s) => s.name.endsWith(suffix));
  const values = series.map((s) => ({
    label: strip ? s.name.slice(0, -suffix!.length) : s.name,
    value: last ? (lastValue(s) ?? 0) : total(s),
  }));
  return rankingBlock(ctx, values, spec.unit ?? panelUnit(panel), { shares: panel.type === "piechart", ...spec });
}

/** A week-over-week table (queries A this week, B the week before, C the change) as ranked rows with changes. */
export async function wowRankingFromPanel(
  ctx: BuildCtx,
  uid: string,
  title: string,
  spec: RankingSpec & { better?: "up" | "down" | "none" } = {},
): Promise<Block> {
  const { panel, series } = await runPanel(ctx, uid, title);
  const unit = spec.unit ?? unitOf(panel.fieldConfig?.defaults?.unit);
  const byName = (refId: string) => new Map(series.filter((s) => s.refId === refId).map((s) => [s.name, lastValue(s)]));
  const now = byName("A");
  const before = byName("B");
  const change = byName("C");
  const limit = spec.limit ?? 8;
  const sorted = [...now.entries()]
    .filter(([, v]) => v !== null && v !== 0)
    .sort((a, b) => (b[1] ?? 0) - (a[1] ?? 0));
  const rows: RankRow[] = sorted.slice(0, limit).map(([name, value]) => {
    const c = change.get(name);
    const prior = before.get(name);
    return {
      label: ctx.name(spec.rename ? spec.rename(name) : name),
      value: tidy(round(value ?? 0), unit),
      ...(prior !== undefined && prior !== null ? { detail: [{ v: tidy(round(prior), unit), u: unit, s: ctx.t("the week before") }] } : {}),
      ...(c !== undefined && c !== null && Number.isFinite(c) ? { change: round(c), better: spec.better ?? "up" } : {}),
    };
  });
  return {
    kind: "ranking",
    unit,
    rows,
    ...(sorted.length > limit ? { more: sorted.length - limit } : {}),
    empty: ctx.t("Nothing in this range"),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Span lists

const SOURCES: Record<string, string> = { "claude-platform": "Claude Platform", openrouter: "OpenRouter", crok: "crok" };
const PROVIDERS: Record<string, string> = { openai: "codex", zai: "glm" };

function str(value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined;
  const text = String(value).trim();
  return text && text !== "nil" ? text : undefined;
}

function num(value: unknown): number | undefined {
  const n = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

/** A span (a model call, a turn, a tool run) as a list row: what it was, its numbers, and how it ended. */
export function spanRow(ctx: BuildCtx, row: Record<string, unknown>): ListRow {
  const t = ctx.t;
  const chips: Chip[] = [];
  const text = (value: unknown) => {
    const s = str(value);
    if (s) chips.push({ t: s });
  };
  const count = (value: unknown, unit: Unit, suffix: string) => {
    const n = num(value);
    if (n !== undefined && n !== 0) chips.push({ v: n, u: unit, s: suffix });
  };
  const source = str(row["service.name"]);
  const provider = str(row["gen_ai.provider.name"]);
  if (source && source !== "crok") text(SOURCES[source] ?? source);
  if (provider) text(PROVIDERS[provider] ?? provider);
  text(row["trace.metadata.openrouter.provider_name"]);
  text(row["gen_ai.agent.name"]);
  text(row["crok.backend"]);
  const outcome = str(row["crok.turn.outcome"]);
  if (outcome) chips.push({ t: t(outcome) });
  count(row["gen_ai.usage.input_tokens"], "tokens", t("in"));
  count(row["gen_ai.usage.cache_read.input_tokens"] ?? row["gen_ai.usage.cache_read_input_tokens"], "tokens", t("cached"));
  count(row["gen_ai.usage.cache_write.input_tokens"], "tokens", t("written to cache"));
  count(row["gen_ai.usage.output_tokens"], "tokens", t("out"));
  count(row["crok.model_calls"], "count", t("model calls"));
  count(row["crok.tool_calls"], "count", t("tool runs"));
  count(row["crok.tool_errors"], "count", t("tool errors"));
  text(row["crok.tool.kind"]);
  const exit = num(row["crok.tool.exit_code"]);
  if (exit !== undefined) chips.push({ t: `${t("exit")} ${exit}` });
  text(row["anthropic.message.stop_reason"] ?? row["gen_ai.response.finish_reason"] ?? row["gen_ai.response.finish_reasons"]);
  text(row["gen_ai.request.reasoning.level"]);
  const error = str(row["error.type"]) ?? str(row["error.category"]);
  if (error) chips.push({ t: error });
  text(row["agento11y.tag.surface"]);
  text(row["agento11y.tag.origin"]);
  text(row["agento11y.tag.repo"]);
  text(row["agento11y.tag.host"]);
  text(row["trace.metadata.openrouter.api_key_name"]);
  const duration = num(row["duration"]);
  if (duration !== undefined) chips.push({ v: round(duration / 1e9), u: "seconds" });
  const cost = num(row["gen_ai.usage.total_cost"]) ?? num(row["crok.cost.usd"]);
  const cancelled = str(row["crok.cancelled"]) === "true";
  const failed =
    !!error || str(row["crok.tool.outcome"]) === "error" || (!!outcome && !["completed", "cancelled"].includes(outcome));
  const title =
    str(row["gen_ai.request.model"]) ?? str(row["gen_ai.tool.name"]) ?? str(row["traceName"]) ?? str(row["name"]) ?? "—";
  return {
    title,
    ...(chips.length ? { detail: chips } : {}),
    ...(cost !== undefined && cost > 0 ? { value: { v: round(cost), u: "usd" as const } } : {}),
    ...(num(row["time"]) !== undefined ? { time: num(row["time"]) } : {}),
    ...(failed ? { status: "bad" as const } : cancelled || outcome === "cancelled" ? { status: "warn" as const } : {}),
  };
}

/** A span table panel's rows, newest first. */
export async function listFromSpans(ctx: BuildCtx, uid: string, title: string, limit = 10): Promise<Block> {
  const { rows } = await runPanel(ctx, uid, title, { type: "table" });
  const sorted = rows.sort((a, b) => (num(b["time"]) ?? 0) - (num(a["time"]) ?? 0));
  return { kind: "list", rows: sorted.slice(0, limit).map((row) => spanRow(ctx, row)), empty: ctx.t("No calls in this range") };
}

// ---------------------------------------------------------------------------------------------------------------
// The pages' own PromQL

/** `$__range` and friends in `expr`, for the page's range. */
function promExpr(ctx: BuildCtx, expr: string, stepMs: number): string {
  return interpolate(expr, builtinVars(ctx.rangeMs, stepMs));
}

/** One value per label set at the end of the range. */
export async function promInstant(ctx: BuildCtx, expr: string): Promise<Series[]> {
  const query = {
    refId: "A",
    datasource: { type: "prometheus", uid: PROM_UID },
    expr: promExpr(ctx, expr, chartStep(ctx.rangeMs)),
    instant: true,
    range: false,
  };
  const response = await ctx.limit(() => ctx.g.post("/api/ds/query", { queries: [query], from: String(ctx.from), to: String(ctx.to) }));
  const { series, errors } = seriesOf(response);
  if (series.length === 0 && errors.length > 0) throw new GrafanaError(errors[0]);
  return series;
}

/** Series over the range at `stepMs` (a chart's step by default). */
export async function promRange(ctx: BuildCtx, expr: string, stepMs = chartStep(ctx.rangeMs)): Promise<Series[]> {
  const query = {
    refId: "A",
    datasource: { type: "prometheus", uid: PROM_UID },
    expr: promExpr(ctx, expr, stepMs),
    instant: false,
    range: true,
    intervalMs: stepMs,
    interval: durationText(stepMs),
    maxDataPoints: 150,
  };
  const response = await ctx.limit(() => ctx.g.post("/api/ds/query", { queries: [query], from: String(ctx.from), to: String(ctx.to) }));
  const { series, errors } = seriesOf(response);
  if (series.length === 0 && errors.length > 0) throw new GrafanaError(errors[0]);
  return series;
}

/**
 * A TraceQL metrics query of the page's own. `totals` runs it as a range at a 1-minute step (to be added up, as the
 * dashboards' totals are); `instant` gives one value per series; otherwise it is a chart at the chart step.
 */
export async function tempoQuery(ctx: BuildCtx, query: string, mode: "totals" | "instant" | "chart" = "chart"): Promise<Series[]> {
  const target = {
    refId: "A",
    datasource: { type: "tempo", uid: TEMPO_UID },
    queryType: "traceql",
    query,
    metricsQueryType: mode === "instant" ? "instant" : "range",
    ...(mode === "instant" ? {} : { step: mode === "totals" ? "1m" : durationText(chartStep(ctx.rangeMs)) }),
  };
  const response = await ctx.limit(() => ctx.g.post("/api/ds/query", { queries: [target], from: String(ctx.from), to: String(ctx.to) }));
  const { series, errors } = seriesOf(response);
  if (!series.some(hasValue) && errors.length > 0) throw new GrafanaError(errors[0]);
  return series.map((s) => ({ ...s, name: s.name === "nil" ? ctx.t("(not set)") : s.name }));
}

/** A single number from PromQL (the first series' value; 0 when the query has no series). */
export async function promValue(ctx: BuildCtx, expr: string): Promise<number> {
  const series = await promInstant(ctx, expr);
  return firstLast(series) ?? 0;
}

export function label(series: Series, key: string): string {
  const value = series.labels[key];
  return value === undefined ? "" : value.replace(/^"(.*)"$/, "$1");
}

export function statOf(label: string, value: number | null, unit: Unit, extra: Partial<Stat> = {}): Stat {
  return { label, value: value === null ? null : tidy(round(value), unit), unit, ...extra };
}

/** The change from `before` to `now` as a fraction; null when there was nothing before. */
export function changeOf(now: number | null, before: number | null): number | null {
  if (now === null || before === null || before === 0) return null;
  return round(now / before - 1);
}
