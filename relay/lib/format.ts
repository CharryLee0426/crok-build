import type { Lang } from "./i18n";

const DAY = 24 * 60 * 60 * 1000;

function startOfDay(ts: number): number {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Calendar days between two timestamps in local time (0 = same day). */
export function daysApart(a: number, b: number): number {
  return Math.round((startOfDay(b) - startOfDay(a)) / DAY);
}

export function formatClock(ts: number, lang: Lang): string {
  return new Intl.DateTimeFormat(lang, { hour: "numeric", minute: "2-digit" }).format(ts);
}

/** The chat list's time column, like Telegram: a clock time today, a weekday this week, a date before that. */
export function formatListTime(ts: number, lang: Lang, now: number): string {
  const days = daysApart(ts, now);
  if (days <= 0) return formatClock(ts, lang);
  if (days < 7) return new Intl.DateTimeFormat(lang, { weekday: "short" }).format(ts);
  const sameYear = new Date(ts).getFullYear() === new Date(now).getFullYear();
  return new Intl.DateTimeFormat(lang, sameYear ? { month: "short", day: "numeric" } : { dateStyle: "short" }).format(ts);
}

/** "3 minutes ago", "yesterday", "in 5 minutes" — localized by the browser. */
export function formatRelative(ts: number, lang: Lang, now: number): string {
  const rtf = new Intl.RelativeTimeFormat(lang, { numeric: "auto" });
  const diff = ts - now;
  const abs = Math.abs(diff);
  const sec = 1000;
  const min = 60 * sec;
  const hour = 60 * min;
  if (abs < 45 * sec) return rtf.format(0, "second");
  if (abs < 45 * min) return rtf.format(Math.round(diff / min), "minute");
  if (abs < 22 * hour) return rtf.format(Math.round(diff / hour), "hour");
  if (abs < 6 * DAY) return rtf.format(Math.round(diff / DAY), "day");
  if (abs < 28 * DAY) return rtf.format(Math.round(diff / (7 * DAY)), "week");
  if (abs < 330 * DAY) return rtf.format(Math.round(diff / (30 * DAY)), "month");
  return rtf.format(Math.round(diff / (365 * DAY)), "year");
}

/** A transcript day header: today / yesterday are words from the dictionary; older days are dates. */
export function formatDayHeader(ts: number, lang: Lang, now: number, words: { today: string; yesterday: string }): string {
  const days = daysApart(ts, now);
  if (days === 0) return words.today;
  if (days === 1) return words.yesterday;
  const sameYear = new Date(ts).getFullYear() === new Date(now).getFullYear();
  return new Intl.DateTimeFormat(
    lang,
    sameYear ? { weekday: "long", month: "long", day: "numeric" } : { year: "numeric", month: "long", day: "numeric" },
  ).format(ts);
}

export function formatDateTime(ts: number, lang: Lang): string {
  return new Intl.DateTimeFormat(lang, { dateStyle: "medium", timeStyle: "short" }).format(ts);
}

/** 12.3K tokens. */
export function formatCount(n: number, lang: Lang): string {
  if (n < 10_000) return new Intl.NumberFormat(lang).format(n);
  return new Intl.NumberFormat(lang, { notation: "compact", maximumFractionDigits: 1 }).format(n);
}

export function formatCost(usd: number, lang: Lang): string {
  const digits = usd !== 0 && Math.abs(usd) < 0.1 ? 4 : 2;
  return new Intl.NumberFormat(lang, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: digits,
  }).format(usd);
}

export function formatPercent(ratio: number, lang: Lang): string {
  return new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(ratio);
}

/** m:ss for countdowns. */
export function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

/** The last path component of a working directory, for "computer · folder". */
export function folderName(cwd: string): string {
  const trimmed = cwd.replace(/[\\/]+$/, "");
  const parts = trimmed.split(/[\\/]/);
  return parts[parts.length - 1] || cwd || "~";
}

/** Shortens /Users/name/… and /home/name/… to ~/… for display. */
export function tildePath(cwd: string): string {
  return cwd.replace(/^\/(Users|home)\/[^/]+(?=\/|$)/, "~");
}

/**
 * One or two letters for a project avatar, the phones' rule: the first letters of the first two words of the folder
 * name ("crok-build" → "CB", "relay" → "R").
 */
export function projectInitials(cwd: string, fallback: string): string {
  const name = folderName(cwd) || fallback;
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const letters = words.slice(0, 2).map((w) => Array.from(w)[0] ?? "");
  return letters.join("").toLocaleUpperCase() || "·";
}

/** A stable hue per project, so each folder keeps its avatar colour. */
export function projectHue(key: string): number {
  let hash = 0;
  for (let i = 0; i < key.length; i++) hash = (hash * 31 + key.charCodeAt(i)) | 0;
  const hues = [140, 200, 28, 265, 340, 175, 48, 300, 112, 225];
  return hues[Math.abs(hash) % hues.length];
}
