/**
 * The o11y pages' own words in the six languages (relay/DESIGN.md §6). Keys are the English text the page specs use;
 * a word missing here stays English. Product names (Claude Platform, OpenRouter, crok, Grafana) and model, provider,
 * evaluator and rule ids are never translated.
 */
import type { Lang } from "./types";

type Translations = Partial<Record<Exclude<Lang, "en">, string>>;

export const STRINGS: Record<string, Translations> = {};

/** Set by relay/scripts/o11y-strings.mjs to list every word the pages ask for. */
type Recorder = { o11yStrings?: Set<string> };

export function translator(lang: Lang): (english: string) => string {
  const record = (globalThis as Recorder).o11yStrings;
  if (lang === "en") return (english) => (record?.add(english), english);
  return (english) => (record?.add(english), STRINGS[english]?.[lang] ?? english);
}
