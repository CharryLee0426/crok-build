/**
 * Reading a Grafana Cloud stack: the HTTP client, `/api/ds/query` frames turned into named series, a dashboard's
 * variables, and the renames and steps its panels use. Nothing here knows about pages.
 */

/** What the page builders read Grafana through (a token in the relay, gcx in relay/scripts/o11y-preview.mjs). */
export interface Grafana {
  /** The stack's address, for "Open in Grafana" links. */
  readonly url: string;
  get(path: string): Promise<unknown>;
  post(path: string, body: unknown): Promise<unknown>;
}

export class GrafanaError extends Error {}

function brief(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > 200 ? `${flat.slice(0, 200)}…` : flat;
}

/** A client for `url` with a service-account token. */
export function grafanaClient(url: string, token: string, timeoutMs = 30_000): Grafana {
  const base = url.replace(/\/+$/, "");
  async function call(method: "GET" | "POST", path: string, body?: unknown): Promise<unknown> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(base + path, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
      const text = await response.text();
      let parsed: unknown = null;
      try {
        parsed = text ? JSON.parse(text) : null;
      } catch {
        parsed = null;
      }
      // /api/ds/query answers a failed query with an error status and the per-query errors in its body.
      if (!response.ok && !(parsed && typeof parsed === "object" && "results" in parsed)) {
        throw new GrafanaError(`${method} ${path.split("?")[0]}: HTTP ${response.status} ${brief(text)}`);
      }
      return parsed;
    } catch (error) {
      if (error instanceof GrafanaError) throw error;
      if (controller.signal.aborted) throw new GrafanaError(`${path.split("?")[0]}: no answer in ${timeoutMs / 1000} s`);
      throw new GrafanaError(`${path.split("?")[0]}: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      clearTimeout(timer);
    }
  }
  return {
    url: base,
    get: (path) => call("GET", path),
    post: (path, body) => call("POST", path, body),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Frames and series

/** One series of numbers over time, named the way Grafana would show it. */
export type Series = {
  refId: string;
  name: string;
  labels: Record<string, string>;
  points: [number, number | null][];
};

type Field = {
  name: string;
  type?: string;
  labels?: Record<string, string>;
  config?: { displayName?: string; displayNameFromDS?: string } | null;
};

export type Frame = {
  schema: { name?: string; refId?: string; meta?: { dataTopic?: string } | null; fields: Field[] };
  data: { values: unknown[][] };
};

type QueryResponse = { results?: Record<string, { error?: string; status?: number; frames?: Frame[] }> };

/** Label values as Tempo sends them carry their quotes. */
function unquote(value: string): string {
  return value.length >= 2 && value.startsWith('"') && value.endsWith('"') ? value.slice(1, -1) : value;
}

function formatLegend(legend: string, labels: Record<string, string>): string {
  return legend.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, key: string) => labels[key] ?? "");
}

function fieldName(field: Field, frame: Frame, legend: string | undefined): string {
  const config = field.config ?? {};
  if (config.displayNameFromDS) return config.displayNameFromDS;
  if (config.displayName) return config.displayName;
  const labels = Object.fromEntries(
    Object.entries(field.labels ?? {})
      .filter(([key]) => key !== "__name__")
      .map(([key, value]) => [key, unquote(value)]),
  );
  if (legend && legend !== "__auto") return formatLegend(legend, labels);
  const values = Object.values(labels);
  if (values.length > 0) return values.join(" · ");
  return frame.schema.name ?? field.name;
}

/** The frames of one `/api/ds/query` answer, minus exemplars, and the queries' errors. */
export function framesOf(response: unknown): { frames: { refId: string; frame: Frame }[]; errors: string[] } {
  const results = (response as QueryResponse | null)?.results ?? {};
  const frames: { refId: string; frame: Frame }[] = [];
  const errors: string[] = [];
  for (const [refId, result] of Object.entries(results)) {
    if (result.error) errors.push(result.error);
    for (const frame of result.frames ?? []) {
      if (frame.schema.meta?.dataTopic === "annotations") continue;
      frames.push({ refId, frame });
    }
  }
  return { frames, errors };
}

/** Every numeric field of every frame as a series. `legends` names Prometheus series by refId. */
export function seriesOf(response: unknown, legends: Record<string, string | undefined> = {}): {
  series: Series[];
  errors: string[];
} {
  const { frames, errors } = framesOf(response);
  const series: Series[] = [];
  for (const { refId, frame } of frames) {
    const fields = frame.schema.fields;
    const timeIndex = fields.findIndex((f) => f.type === "time");
    const times = timeIndex >= 0 ? (frame.data.values[timeIndex] as number[]) : [];
    fields.forEach((field, index) => {
      if (field.type !== "number") return;
      const values = (frame.data.values[index] ?? []) as (number | null)[];
      const points: [number, number | null][] = values.map((value, i) => [
        times[i] ?? 0,
        typeof value === "number" && Number.isFinite(value) ? value : null,
      ]);
      series.push({ refId, name: fieldName(field, frame, legends[refId]), labels: field.labels ?? {}, points });
    });
  }
  return { series, errors };
}

/** Rows of a table frame (span searches): one record per row, by field name. */
export function rowsOf(response: unknown): { rows: Record<string, unknown>[]; errors: string[] } {
  const { frames, errors } = framesOf(response);
  const rows: Record<string, unknown>[] = [];
  for (const { frame } of frames) {
    const fields = frame.schema.fields;
    const count = Math.max(0, ...frame.data.values.map((column) => column?.length ?? 0));
    for (let i = 0; i < count; i++) {
      const row: Record<string, unknown> = {};
      fields.forEach((field, index) => {
        const value = frame.data.values[index]?.[i];
        if (value !== null && value !== undefined && value !== "") row[field.name] = value;
      });
      rows.push(row);
    }
  }
  return { rows, errors };
}

export function total(series: Series): number {
  return series.points.reduce((sum, [, value]) => sum + (value ?? 0), 0);
}

export function hasValue(series: Series): boolean {
  return series.points.some(([, value]) => value !== null);
}

export function lastValue(series: Series): number | null {
  for (let i = series.points.length - 1; i >= 0; i--) {
    const value = series.points[i][1];
    if (value !== null) return value;
  }
  return null;
}

/** Series of the same name added up at each time (a model's spend from several queries). */
export function mergeByName(series: Series[]): Series[] {
  const merged = new Map<string, { first: Series; at: Map<number, number | null> }>();
  for (const s of series) {
    let entry = merged.get(s.name);
    if (!entry) {
      entry = { first: s, at: new Map() };
      merged.set(s.name, entry);
    }
    for (const [time, value] of s.points) {
      const before = entry.at.get(time);
      entry.at.set(time, value === null ? (before ?? null) : (before ?? 0) + value);
    }
  }
  return [...merged.values()].map(({ first, at }) => ({
    ...first,
    points: [...at.entries()].sort((a, b) => a[0] - b[0]),
  }));
}

// ---------------------------------------------------------------------------------------------------------------
// Panels: renames, variables, steps

type Transformation = { id: string; options?: Record<string, unknown> };

/** Grafana's `stringToJsRegex`: `/pattern/flags` or a bare pattern. */
function jsRegex(text: string): RegExp {
  const slashed = /^\/(.+)\/([gimsuy]*)$/.exec(text);
  return slashed ? new RegExp(slashed[1], slashed[2]) : new RegExp(text);
}

/** A panel's renameByRegex transformations, in order, applied to the series names. */
export function applyRenames(series: Series[], transformations: Transformation[] | null | undefined): Series[] {
  const renames = (transformations ?? [])
    .filter((t) => t.id === "renameByRegex" && typeof t.options?.regex === "string")
    .map((t) => ({ regex: jsRegex(t.options!.regex as string), to: String(t.options!.renamePattern ?? "") }));
  if (renames.length === 0) return series;
  return series.map((s) => {
    let name = s.name;
    for (const { regex, to } of renames) {
      if (regex.test(name)) name = name.replace(regex, to);
    }
    return { ...s, name };
  });
}

export type VarValue = { value: string; all?: string[]; allValue?: string };

type TemplateVar = {
  name: string;
  type: string;
  query?: unknown;
  current?: { value?: unknown };
  options?: { value?: unknown }[];
  allValue?: string | null;
};

const DEFAULT_DS: Record<string, string> = { tempo: "grafanacloud-traces", prometheus: "grafanacloud-prom" };

/** A dashboard's variables at their saved values (what the dashboard opens with). */
export function dashboardVars(dashboard: { templating?: { list?: TemplateVar[] } }): Record<string, VarValue> {
  const vars: Record<string, VarValue> = {};
  for (const v of dashboard.templating?.list ?? []) {
    const current = v.current?.value;
    const first = Array.isArray(current) ? current[0] : current;
    let value = typeof first === "string" ? first : first === undefined ? "" : String(first);
    if (v.type === "datasource" && !value) value = DEFAULT_DS[String(v.query)] ?? "";
    if (v.type === "textbox" && !value) value = typeof v.query === "string" ? v.query : "";
    if (value === "$__all") {
      const all = (v.options ?? []).map((o) => String(o.value ?? "")).filter((o) => o && o !== "$__all");
      vars[v.name] = { value, all, allValue: v.allValue ?? undefined };
    } else {
      vars[v.name] = { value };
    }
  }
  return vars;
}

function escapeRegex(text: string): string {
  return text.replace(/[\\^$*+?.()|[\]{}/]/g, "\\$&");
}

function formatVar(v: VarValue, format: string | undefined): string {
  if (v.value === "$__all") {
    if (v.allValue) return v.allValue;
    const all = v.all ?? [];
    if (format === "regex") return all.length === 1 ? escapeRegex(all[0]) : `(${all.map(escapeRegex).join("|")})`;
    if (format === "pipe") return all.join("|");
    return all.length === 1 ? all[0] : `{${all.join(",")}}`;
  }
  return format === "regex" ? escapeRegex(v.value) : v.value;
}

/** `$name`, `${name}` and `${name:format}` replaced; unknown names stay as they are. */
export function interpolate(text: string, vars: Record<string, VarValue>): string {
  return text.replace(/\$\{([\w]+)(?::(\w+))?\}|\$(__\w+|[A-Za-z_]\w*)/g, (match, braced, format, bare) => {
    const v = vars[braced ?? bare];
    return v ? formatVar(v, format) : match;
  });
}

const NICE_STEPS_MS = [
  30_000, 60_000, 120_000, 180_000, 300_000, 600_000, 720_000, 900_000, 1_800_000, 3_600_000, 7_200_000, 10_800_000,
  21_600_000, 43_200_000, 86_400_000,
];

/** A chart's step: the first round step that gives at most `points` points over the range. */
export function chartStep(rangeMs: number, points = 120): number {
  const wanted = rangeMs / points;
  return NICE_STEPS_MS.find((step) => step >= wanted) ?? 86_400_000;
}

/** Milliseconds as Tempo and Prometheus write them ("30s", "12m", "1h", "1d"). */
export function durationText(ms: number): string {
  if (ms % 86_400_000 === 0) return `${ms / 86_400_000}d`;
  if (ms % 3_600_000 === 0) return `${ms / 3_600_000}h`;
  if (ms % 60_000 === 0) return `${ms / 60_000}m`;
  return `${Math.max(1, Math.round(ms / 1000))}s`;
}

/** "1d", "12m", "30s", "1h" → ms; null for anything else. */
export function parseDuration(text: unknown): number | null {
  if (typeof text !== "string") return null;
  const match = /^(\d+(?:\.\d+)?)(ms|s|m|h|d|w)$/.exec(text.trim());
  if (!match) return null;
  const n = Number(match[1]);
  const unit = { ms: 1, s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 }[match[2]]!;
  return n * unit;
}

/** Grafana's built-in variables for a query over `rangeMs` at `stepMs`. */
export function builtinVars(rangeMs: number, stepMs: number): Record<string, VarValue> {
  return {
    __interval: { value: durationText(stepMs) },
    __rate_interval: { value: durationText(Math.max(stepMs * 4, 60_000)) },
    __range: { value: durationText(rangeMs) },
    __range_s: { value: String(Math.round(rangeMs / 1000)) },
    __range_ms: { value: String(rangeMs) },
  };
}
