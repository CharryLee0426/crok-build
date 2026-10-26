#!/usr/bin/env node
// Builds the phones' o11y pages (convex/lib/o11y) against the live Grafana stack through gcx's sign-in, with no
// relay and no token: what a page will say before it is deployed (relay/DESIGN.md §3 "o11y").
//
//   gcx login <stack> --server https://<stack>.grafana.net --oauth      (once)
//   node scripts/o11y-preview.mjs                    # every page at its default range, a summary each
//   node scripts/o11y-preview.mjs overview 6h zh     # one page, range, language
//   node scripts/o11y-preview.mjs --json overview    # the page as the phones get it
//   node scripts/o11y-preview.mjs --out <dir>        # every page, range and language as JSON files in <dir>
//   node scripts/o11y-preview.mjs --strings <file>   # every word the pages ask t() for, and the ones i18n.ts lacks
//
// Run it in relay/. It bundles the page code with esbuild (a dependency of convex) into the system temp folder.
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), "o11y-preview-"));
const bundle = path.join(work, "pages.mjs");
await build({
  entryPoints: [path.join(here, "..", "convex", "lib", "o11y", "pages.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile: bundle,
  logLevel: "error",
});
globalThis.o11yStrings = new Set();
const { PAGES, buildPage } = await import(pathToFileURL(bundle).href);
const { STRINGS } = await import(pathToFileURL(bundle).href).then(async () => {
  const i18n = path.join(work, "i18n.mjs");
  await build({ entryPoints: [path.join(here, "..", "convex", "lib", "o11y", "i18n.ts")], bundle: true, format: "esm", platform: "node", outfile: i18n, logLevel: "error" });
  return import(pathToFileURL(i18n).href);
});

/** Words t() gets from the data rather than the code: turn outcomes, alert states, guard phases, surfaces. */
const DATA_WORDS = [
  "completed", "cancelled", "failed", "error", "interrupted", "max_turns", "normal", "pending", "firing", "recovering",
  "nodata", "ok", "unknown", "warning", "info", "critical", "preflight", "postflight", "pass", "warn", "deny", "tui",
  "desktop", "headless", "cli", "running", "finalized", "(not set)",
];

/** t("…") literals in the page code, link() titles and the pages' titles and subtitles. */
function literals() {
  const dir = path.join(here, "..", "convex", "lib", "o11y");
  const out = new Set();
  for (const file of ["pages.ts", "read.ts"]) {
    const text = readFileSync(path.join(dir, file), "utf8");
    for (const m of text.matchAll(/\bt\(\s*"((?:[^"\\]|\\.)*)"\s*\)/g)) out.add(JSON.parse(`"${m[1]}"`));
    for (const m of text.matchAll(/\blink\(ctx, "\w+", "((?:[^"\\]|\\.)*)"/g)) out.add(JSON.parse(`"${m[1]}"`));
    for (const m of text.matchAll(/^\s+(?:title|subtitle): "((?:[^"\\]|\\.)*)",$/gm)) out.add(JSON.parse(`"${m[1]}"`));
  }
  return out;
}

let calls = 0;
/** `gcx api`, following the files it spills large answers to. */
function gcx(method, apiPath, body) {
  calls++;
  return new Promise((resolve, reject) => {
    const args = ["api", apiPath, "-X", method];
    if (body !== undefined) {
      const file = path.join(work, `body-${calls}.json`);
      writeFileSync(file, JSON.stringify(body));
      args.push("-d", `@${file}`);
    }
    execFile("gcx", args, { maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
      const docs = [];
      const text = stdout + stderr;
      for (const line of text.split("\n")) {
        const s = line.trim();
        if (!s.startsWith("{") && !s.startsWith("[")) continue;
        try {
          docs.push(JSON.parse(s));
        } catch {}
      }
      let doc = docs.filter((d) => !(d && d.class === "hint")).pop();
      if (doc === undefined) {
        try {
          doc = JSON.parse(stdout);
        } catch {
          return reject(new Error(`gcx api ${apiPath}: ${(stderr || stdout || String(error)).slice(0, 300)}`));
        }
      }
      if (doc && doc.type === "gcx.spill_reference") doc = JSON.parse(readFileSync(doc.spilled_to, "utf8"));
      if (doc && doc.type === "gcx.error") return reject(new Error(`gcx api ${apiPath}: ${JSON.stringify(doc.error).slice(0, 300)}`));
      resolve(doc);
    });
  });
}

// The signed-in stack's address, for the pages' links (GRAFANA_URL wins).
const current =
  process.env.GRAFANA_URL ??
  (await new Promise((resolve) =>
    execFile("gcx", ["config", "view", "--minify", "-o", "json"], (_e, out) => {
      try {
        const doc = JSON.parse(out.slice(out.indexOf("{\n")));
        const name = doc["current-context"];
        const stack = doc.contexts?.[name]?.stack ?? name;
        resolve(doc.stacks?.[stack]?.grafana?.server ?? "https://grafana.invalid");
      } catch {
        resolve("https://grafana.invalid");
      }
    }),
  ));
const grafana = { url: String(current).replace(/\/+$/, ""), get: (p) => gcx("GET", p), post: (p, b) => gcx("POST", p, b) };

function summarize(page) {
  const lines = [`${page.id} · ${page.title} · ${page.range} · ${page.sections.length} sections · ${page.url ?? ""}`];
  for (const s of page.sections) {
    const b = s.block;
    let what = b.kind;
    if (b.kind === "stats") what += " " + b.items.map((i) => `${i.label}=${i.value === null ? "—" : +i.value.toPrecision(4)}${i.change != null ? ` (${(i.change * 100).toFixed(0)}%)` : ""}`).join(", ");
    if (b.kind === "chart") what += ` ${b.style}${b.stacked ? " stacked" : ""} ${b.unit} step ${b.step / 60000}m: ` + b.series.map((x) => `${x.name}[${x.slot}]${x.total != null ? "=" + +x.total.toPrecision(4) : ""} ${x.points.length}p`).join(", ") + (b.more ? ` +${b.more}` : "");
    if (b.kind === "ranking") what += ` ${b.unit}: ` + b.rows.map((r) => `${r.label}=${+r.value.toPrecision(4)}${r.change != null ? ` (${(r.change * 100).toFixed(0)}%)` : ""}`).join(", ") + (b.more ? ` +${b.more}` : "") + (b.rows.length ? "" : ` (${b.empty})`);
    if (b.kind === "list") what += ` ${b.rows.length} rows` + (b.rows[0] ? `: ${b.rows[0].title} · ${(b.rows[0].detail ?? []).map((c) => c.t ?? `${c.v}${c.s ? " " + c.s : ""}`).join(" · ")}${b.rows[0].value ? ` · $${b.rows[0].value.v}` : ""}${b.rows[0].status ? ` [${b.rows[0].status}]` : ""}` : ` (${b.empty})`);
    if (b.kind === "links") what += " " + b.rows.map((r) => `${r.title}${r.value ? "=" + r.value.v : ""}`).join(", ");
    if (b.kind === "note") what += ` ${b.text}`;
    if (b.kind === "error") what += ` !! ${b.message}`;
    lines.push(`  [${s.title ?? ""}] ${what}`);
  }
  return lines.join("\n");
}

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const outIndex = args.indexOf("--out");
const outDir = outIndex >= 0 ? args[outIndex + 1] : null;
const stringsIndex = args.indexOf("--strings");
const stringsFile = stringsIndex >= 0 ? args[stringsIndex + 1] : null;
const rest = args.filter(
  (a, i) => !a.startsWith("--") && (outIndex < 0 || i !== outIndex + 1) && (stringsIndex < 0 || i !== stringsIndex + 1),
);
const [only, range, lang] = rest;

if (stringsFile) {
  for (const id of Object.keys(PAGES)) await buildPage(grafana, id, undefined, "en");
  const all = new Set([...globalThis.o11yStrings, ...literals(), ...DATA_WORDS]);
  const words = [...all].filter((w) => w && !/^[\w./-]+@/.test(w)).sort((a, b) => a.localeCompare(b));
  const missing = words.filter((w) => ["zh", "ja", "es", "fr", "de"].some((l) => !STRINGS[w]?.[l]));
  writeFileSync(stringsFile, JSON.stringify({ words, missing }, null, 1));
  console.log(`${words.length} words, ${missing.length} without all five translations → ${stringsFile}`);
} else if (outDir) {
  mkdirSync(outDir, { recursive: true });
  for (const id of Object.keys(PAGES)) {
    const def = PAGES[id];
    for (const r of def.ranges.length ? def.ranges : [def.range]) {
      const page = await buildPage(grafana, id, r, lang ?? "en");
      writeFileSync(path.join(outDir, `${id}-${r}.json`), JSON.stringify(page, null, 1));
      console.log(`${id} ${r}: ${JSON.stringify(page).length} bytes, ${page.sections.filter((s) => s.block.kind === "error").length} errors`);
    }
  }
} else {
  for (const id of only ? [only] : Object.keys(PAGES)) {
    const started = Date.now();
    const before = calls;
    const page = await buildPage(grafana, id, range, lang);
    if (asJson) console.log(JSON.stringify(page, null, 1));
    else console.log(`${summarize(page)}\n  (${((Date.now() - started) / 1000).toFixed(1)} s, ${calls - before} calls, ${JSON.stringify(page).length} bytes)\n`);
  }
}
