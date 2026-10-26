#!/usr/bin/env node
// Makes the phones' demo o11y pages (mobile/DESIGN.md "o11y", Demo mode) from real ones, so the demo has the real
// shape — every section, chart and list — but none of the owner's data:
//
//   node scripts/o11y-preview.mjs --out <dir>      # real pages, every range (gcx's sign-in)
//   node scripts/o11y-demo.mjs <dir>               # → mobile/iOS/Crok/Resources/o11y-demo.json and the Android
//                                                  #   debug asset (app/src/debug/assets: release builds have no demo)
//
// Numbers are scaled by a factor per page (ratios and times only nudged), times are kept (the apps move them to
// now), and every text that is not a known public word — a model, provider, tool, agent, rule, outcome — is swapped
// for demo text: hosts, repositories, API keys, conversation titles and judges' explanations never leave. The
// fixture carries the relay's translations (convex/lib/o11y/i18n.ts) for the demo to apply.
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const source = process.argv[2];
if (!source) {
  console.error("usage: node scripts/o11y-demo.mjs <dir of pages from o11y-preview.mjs --out>");
  process.exit(2);
}

const work = mkdtempSync(path.join(tmpdir(), "o11y-demo-"));
const bundled = async (file) => {
  const out = path.join(work, path.basename(file, ".ts") + ".mjs");
  await build({ entryPoints: [file], bundle: true, format: "esm", platform: "node", outfile: out, logLevel: "error" });
  return import(pathToFileURL(out).href);
};
const lib = path.join(here, "..", "convex", "lib", "o11y");
const { STRINGS } = await bundled(path.join(lib, "i18n.ts"));
const { PAGES } = await bundled(path.join(lib, "pages.ts"));

// A small deterministic generator per page.
function seeded(text) {
  let h = 2166136261;
  for (const c of text) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0;
  return () => {
    h = (Math.imul(h ^ (h >>> 15), 2246822507) ^ Math.imul(h ^ (h >>> 13), 3266489909)) >>> 0;
    return (h % 100000) / 100000;
  };
}

const PUBLIC_WORDS = new Set([
  ...Object.keys(STRINGS),
  "anthropic", "openai", "codex", "glm", "zai", "deepseek", "openrouter", "xai", "Claude Platform", "OpenRouter", "crok",
  "completed", "cancelled", "failed", "interrupted", "tool_use", "end_turn", "stop", "length", "tool_calls", "max_tokens",
  "stop_sequence", "pause_turn", "refusal", "high", "low", "medium", "xhigh", "max", "minimal", "mutating", "read_only",
  "tui", "desktop", "headless", "cli", "local", "relay", "eval", "client_error", "sdk_error", "provider_call_error",
  "tool_execution_error", "validation_error", "rate_limit", "rate_limit_error", "overloaded_error", "timeout", "unknown",
  "chat_completions", "messages", "responses", "normal", "warning", "info", "critical", "crok-alerts", "Grafana SLO",
  "LLM Observability", "llm-history", "pass", "warn", "deny", "preflight", "postflight", "Passed", "Failed",
  "LLM Generation", "billed",
  // OpenRouter's upstream providers, as its spans name them.
  "meta", "digitalocean", "wafer", "relace", "ionstream", "morph", "fireworks", "together", "deepinfra", "novita",
  "groq", "cerebras", "chutes", "baseten", "parasail", "nebius", "google", "amazon", "azure", "mistral", "moonshotai",
  "alibaba", "siliconflow", "crusoe", "friendli", "hyperbolic", "lambda", "sambanova", "venice", "minimax", "atlas-cloud",
  "inference-net", "gmicloud", "phala", "targon", "ubicloud", "z-ai", "xai", "cohere", "perplexity",
]);
const MODEL = /(claude|deepseek|gpt|glm|muse|minimax|grok|gemini|llama|qwen|kimi|mistral|aion|o\d)/i;
// crok's tools (a snake_case word that is not one of these, a repository say, is not public).
const TOOLS = new Set([
  "run_terminal_command", "read_file", "search_replace", "write", "grep", "list_dir", "get_command_or_subagent_output",
  "browser", "web_search", "web_fetch", "spawn_subagent", "phone", "edit_file", "glob", "todo_write", "computer",
  "image_gen", "ask_user", "plan", "kill_command",
]);

function isPublic(text) {
  if (PUBLIC_WORDS.has(text)) return true;
  if (/^crok(\/[\w-]+)?$/.test(text)) return true; // agent names
  if (/^crok_[a-z_]+$/.test(text) || /^guard\.crok\.[a-z_]+$/.test(text)) return true; // evaluators, rules, guards
  if (TOOLS.has(text)) return true;
  if (/^(release|eval)-[\w.-]+$/.test(text)) return true; // eval run ids
  if (/^\d{3}$/.test(text)) return true; // HTTP status codes
  if (/^\d+\.\d+(\.\d+)?([+-][\w.]+)?$/.test(text)) return true; // versions
  if (/^exit -?\d+$/.test(text)) return true;
  if (/^(crok: |crok |llm_)/.test(text) || / \(Grafana SLO\)( rules)?$/.test(text)) return true; // alert rules, SLOs
  if (/^~?[\w.~-]+(\/[\w.:~-]+)+$/.test(text) && MODEL.test(text)) return true; // provider/model ids
  if (MODEL.test(text) && /^[\w.:~-]+$/.test(text)) return true; // bare model ids
  if (/^(Sonnet|Opus|Haiku|Fable|Mythos) [\d.]+/.test(text)) return true; // Claude price groups
  if (/^[A-Z][a-zA-Z]+$/.test(text) && text.length <= 14) return true; // upstream providers (Fireworks, Together)
  if (/^(input|output|cache_read) · \w+$/.test(text)) return true;
  if (/^[\w-]+ p\d+$/.test(text) && isPublic(text.replace(/ p\d+$/, ""))) return true;
  return text.split(" · ").length > 1 && text.split(" · ").every(isPublic);
}

const HOSTS = ["MacBook Pro", "Mac Studio", "build-runner", "MacBook Air"];
const REPOS = ["crok-build", "notes-app", "website"];
const TITLES = [
  "Fix the flaky transcript test",
  "Add the o11y tab to the phones",
  "Why does the release build fail on macOS 26?",
  "Speed up the session list search",
  "Write the 2.0.3 release notes",
  "Review the Android composer change",
  "Explain the TraceQL step limit",
  "Rename the relay environments",
];
const EXPLANATIONS = [
  "The answer says the tests pass, but no test run appears in the turn.",
  "The reply repeats the question instead of answering it.",
  "The summary claims a file was changed that the tool calls never wrote.",
];
const KEYS = ["OAuth: crok", "ci", "evals"];

function demoText(text, section, rand) {
  const s = section.toLowerCase();
  const pick = (pool) => pool[Math.floor(rand() * pool.length)];
  if (/machine/.test(s)) return pick(HOSTS);
  if (/api key/.test(s)) return pick(KEYS);
  if (/conversation/.test(s)) return pick(TITLES);
  if (/failure/.test(s)) return text.length > 60 ? pick(EXPLANATIONS) : pick(TITLES);
  if (text.length > 60) return pick(EXPLANATIONS);
  return pick([...HOSTS, ...REPOS]);
}

/**
 * Money and amounts scaled by the page's factor; a whole count stays whole. Ratios stay as they are (pass rates, SLIs
 * and objectives must still agree with each other) and times are only nudged.
 */
function scale(value, unit, factor, rand) {
  if (typeof value !== "number") return value;
  if (unit === "ratio") return value;
  if (unit === "seconds" || unit === "ms" || unit === "tps" || unit === "perMin") return value * (0.8 + rand() * 0.4);
  const v = value * factor;
  if (unit === "count" || unit === "tokens") {
    return Number.isInteger(value) || Math.abs(v) >= 10 ? Math.round(v) : Math.round(v * 10) / 10;
  }
  return Number(v.toPrecision(4));
}

function sanitizeChips(chips, section, factor, rand) {
  return chips
    .map((c) => ("t" in c ? (isPublic(c.t) ? c : { t: demoText(c.t, section, rand) }) : { ...c, v: scale(c.v, c.u, factor, rand) }))
    .filter(Boolean);
}

function sanitize(page) {
  const rand = seeded(page.id);
  const factor = 0.55 + rand() * 0.9;
  for (const section of page.sections) {
    const title = section.title ?? "";
    if (title && !isPublic(title)) section.title = demoText(title, "", rand);
    const b = section.block;
    if (b.kind === "stats") for (const i of b.items) i.value = scale(i.value, i.unit, factor, rand);
    if (b.kind === "chart") {
      for (const s of b.series) {
        if (!isPublic(s.name)) s.name = demoText(s.name, title, rand);
        s.points = s.points.map(([t, v]) => [t, v === null ? null : scale(v, b.unit, factor, rand)]);
        if (s.total !== null && s.total !== undefined) {
          s.total = s.points.reduce((a, [, v]) => a + (v ?? 0), 0);
          s.total = Number(s.total.toPrecision(5));
        }
      }
    }
    if (b.kind === "ranking") {
      for (const r of b.rows) {
        if (!isPublic(r.label)) r.label = demoText(r.label, title, rand);
        r.value = scale(r.value, b.unit, factor, rand);
        if (r.detail) r.detail = sanitizeChips(r.detail, title, factor, rand);
      }
      b.rows.sort((a, c) => (title.includes("Pass rate") || /, by provider$/.test(title) ? a.value - c.value : c.value - a.value));
    }
    if (b.kind === "list") {
      for (const r of b.rows) {
        if (!isPublic(r.title)) r.title = demoText(r.title, title || page.id, rand);
        if (r.detail) r.detail = sanitizeChips(r.detail, title || page.id, factor, rand);
        if (r.value) r.value = { ...r.value, v: scale(r.value.v, r.value.u, factor, rand) };
      }
    }
    if (b.kind === "links") for (const r of b.rows) if (r.value) r.value = { ...r.value, v: scale(r.value.v, r.value.u, factor, rand) };
    if (b.kind === "error") section.block = { kind: "note", text: "—" };
  }
  page.url = page.url?.replace(/^https:\/\/[^/]+/, "https://demo.grafana.net");
  return page;
}

const files = readdirSync(source).filter((f) => f.endsWith(".json"));
const pages = {};
let builtAt = 0;
for (const [id, def] of Object.entries(PAGES)) {
  const file = files.find((f) => f === `${id}-${def.range}.json`) ?? files.find((f) => f.startsWith(`${id}-`));
  if (!file) throw new Error(`no page ${id} in ${source}`);
  const page = JSON.parse(readFileSync(path.join(source, file), "utf8"));
  builtAt = Math.max(builtAt, page.builtAt);
  pages[id] = sanitize(page);
}
const fixture = { builtAt, pages, strings: STRINGS };
const text = JSON.stringify(fixture);
for (const target of [
  path.join(repo, "mobile", "iOS", "Crok", "Resources", "o11y-demo.json"),
  path.join(repo, "mobile", "Android", "app", "src", "debug", "assets", "o11y-demo.json"),
]) {
  writeFileSync(target, text);
  console.log(`${path.relative(repo, target)}: ${text.length} bytes, ${Object.keys(pages).length} pages`);
}
