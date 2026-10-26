/**
 * The pages the phones' o11y tab draws (relay/DESIGN.md §3 "o11y", mobile/DESIGN.md "o11y"). Text is in the page's
 * language; numbers are raw, with a unit the phones format.
 */

export type Unit = "usd" | "count" | "tokens" | "ratio" | "seconds" | "ms" | "bytes" | "perMin" | "tps";

/** A detail chip: text, or a value with an optional suffix ("12.3K in"). */
export type Chip = { t: string } | { v: number; u: Unit; s?: string };

export type Stat = {
  label: string;
  value: number | null;
  unit: Unit;
  /** Against the period before, as a fraction (0.12 = +12 %). */
  change?: number | null;
  /** Which way is good: colours the change. */
  better?: "up" | "down" | "none";
};

export type ChartSeries = {
  name: string;
  /** 1–8: the categorical palette slot; 0: "Other". */
  slot: number;
  total: number | null;
  dashed?: boolean;
  points: [number, number | null][];
};

export type RankRow = {
  label: string;
  value: number;
  slot?: number;
  detail?: Chip[];
  /** Against the period before (week-over-week tables), coloured as a stat's. */
  change?: number | null;
  better?: "up" | "down" | "none";
};

export type ListRow = {
  title: string;
  detail?: Chip[];
  value?: { v: number; u: Unit };
  time?: number;
  status?: "ok" | "warn" | "bad" | "info";
  page?: string;
};

export type LinkRow = {
  page: string;
  title: string;
  subtitle?: string;
  icon: string;
  color: string;
  value?: { v: number; u: Unit };
};

export type Block =
  | { kind: "stats"; items: Stat[] }
  | {
      kind: "chart";
      style: "line" | "bars";
      stacked?: boolean;
      unit: Unit;
      step: number;
      series: ChartSeries[];
      more?: number;
    }
  | { kind: "ranking"; unit: Unit; rows: RankRow[]; more?: number; empty: string }
  | { kind: "list"; rows: ListRow[]; empty: string }
  | { kind: "links"; rows: LinkRow[] }
  | { kind: "note"; text: string }
  | { kind: "error"; message: string };

export type Section = { title?: string; footer?: string; block: Block };

export type Page = {
  id: string;
  title: string;
  subtitle?: string;
  range: string;
  ranges: string[];
  url?: string;
  builtAt: number;
  sections: Section[];
};

export const LANGS = ["en", "zh", "ja", "es", "fr", "de"] as const;
export type Lang = (typeof LANGS)[number];

export const RANGE_MS: Record<string, number> = {
  "1h": 3_600_000,
  "6h": 6 * 3_600_000,
  "24h": 24 * 3_600_000,
  "7d": 7 * 86_400_000,
  "14d": 14 * 86_400_000,
};
