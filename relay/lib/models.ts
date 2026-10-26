/**
 * The model picker's rules (mobile/DESIGN.md "Model and thinking level"): sections by provider, search, and a name
 * shortened in the middle for the composer's pill.
 */
import type { ModelChoice } from "./types";

/** `anthropic/claude-sonnet-4.5` → `anthropic`; ids without a `/` have no provider of their own. */
export function providerOf(id: string): string | null {
  const slash = id.indexOf("/");
  return slash > 0 ? id.slice(0, slash) : null;
}

export type ModelSection = { title: string; models: ModelChoice[] };

/**
 * Sections in the order their providers first appear in the list (the relay sends picker order: the computer's
 * default, its own providers, then OpenRouter); ids without a `/` go in a section named after the computer.
 */
export function modelSections(models: readonly ModelChoice[], computer: string): ModelSection[] {
  const sections: ModelSection[] = [];
  const byTitle = new Map<string, ModelSection>();
  for (const model of models) {
    const title = providerOf(model.id) ?? computer;
    let section = byTitle.get(title);
    if (!section) {
      section = { title, models: [] };
      byTitle.set(title, section);
      sections.push(section);
    }
    section.models.push(model);
  }
  return sections;
}

/** Case-insensitive substring of the name, id or description. */
export function filterModels(models: readonly ModelChoice[], query: string): ModelChoice[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [...models];
  return models.filter((m) =>
    [m.name, m.id, m.description ?? ""].some((field) => field.toLowerCase().includes(needle)),
  );
}

/**
 * Splits a name for truncation in the middle: the head ellipsizes, the tail always shows ("Claude Son…et 4.5").
 * Short names stay whole.
 */
export function middleSplit(text: string, tail = 7): [string, string] {
  const chars = Array.from(text);
  if (chars.length <= tail * 2 + 2) return [text, ""];
  return [chars.slice(0, -tail).join(""), chars.slice(-tail).join("")];
}
