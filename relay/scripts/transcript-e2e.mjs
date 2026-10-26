#!/usr/bin/env node
// Long transcripts over `sessions:transcript` (relay/DESIGN.md §3, "Loading long transcripts"), against a running
// deployment (by default the local one in .env.local): a computer mirrors a session of ROUNDS turns (each a prompt, a
// long thought, a tool call with output, a reply and an end-of-turn marker); a phone opens it, walks it back to the
// beginning in parts, and watches the live end while a reply streams. Prints what each way of loading costs.
//
//   npx convex dev            # in another terminal
//   CROK_E2E_ROUNDS=3000 node scripts/transcript-e2e.mjs

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const ROUNDS = Number(process.env.CROK_E2E_ROUNDS ?? 3000);
const THOUGHT = Number(process.env.CROK_E2E_THOUGHT ?? 6000);
const OUTPUT = Number(process.env.CROK_E2E_OUTPUT ?? 3000);
const REPLY = Number(process.env.CROK_E2E_REPLY ?? 1500);

function envLocal(name) {
  if (process.env[name]) return process.env[name];
  try {
    const line = readFileSync(".env.local", "utf8")
      .split("\n")
      .find((l) => l.startsWith(`${name}=`));
    return line?.slice(name.length + 1).trim();
  } catch {
    return undefined;
  }
}

const url = envLocal("NEXT_PUBLIC_CONVEX_URL") ?? envLocal("CONVEX_URL");
if (!url) throw new Error("No deployment URL: run `npx convex dev` first or set CONVEX_URL");
const issuer = (() => {
  try {
    return execFileSync("npx", ["convex", "env", "get", "CLERK_JWT_ISSUER_DOMAIN"], { encoding: "utf8" }).trim();
  } catch {
    return "https://placeholder.clerk.accounts.dev";
  }
})();

let failures = 0;
function check(condition, label, detail) {
  if (condition) {
    console.log(`  ok  ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail).slice(0, 400)}`}`);
  }
}

const http = new ConvexHttpClient(url);

function runAs(person, fn, args) {
  const out = execFileSync("npx", ["convex", "run", fn, JSON.stringify(args), "--identity", person], {
    encoding: "utf8",
  });
  return out.trim() ? JSON.parse(out) : null;
}

async function link(person, kind, name) {
  const started = await http.mutation("deviceAuth:start", { kind, name, platform: "e2e", client: "e2e 0.0" });
  runAs(person, "deviceAuth:approve", { userCode: started.userCode });
  const approved = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  if (approved.status !== "approved") throw new Error(`${kind} not approved: ${approved.status}`);
  return approved;
}

function authedClient(tokens) {
  const client = new ConvexClient(url);
  let access = tokens.accessToken;
  client.setAuth(async ({ forceRefreshToken }) => {
    if (forceRefreshToken) {
      const fresh = await http.mutation("deviceAuth:refresh", { refreshToken: tokens.refreshToken });
      access = fresh.accessToken;
    }
    return access;
  });
  return client;
}

async function code(work) {
  try {
    await work();
    return null;
  } catch (error) {
    return error?.data?.code ?? String(error);
  }
}

const kb = (value) => `${(JSON.stringify(value).length / 1024).toFixed(1)} kB`;
const words = (n, seed) => {
  const base = `${seed} lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor `;
  return base.repeat(Math.ceil(n / base.length)).slice(0, n);
};

async function timed(work) {
  const start = performance.now();
  const value = await work();
  return { value, ms: performance.now() - start };
}

console.log(`Long transcripts against ${url}: ${ROUNDS} rounds (${ROUNDS * 5} items)`);
const stamp = Date.now();
const person = JSON.stringify({ subject: `transcript-e2e-${stamp}`, issuer, name: "Transcript E2E" });
const stranger = JSON.stringify({ subject: `transcript-e2e-other-${stamp}`, issuer, name: "Someone Else" });
const computer = authedClient(await link(person, "computer", "E2E Studio"));
const phone = authedClient(await link(person, "phone", "E2E iPhone"));
const otherPhone = authedClient(await link(stranger, "phone", "Someone's phone"));

const { hostId } = await computer.mutation("bridge:connect", {
  instanceId: `transcript-e2e-${process.pid}`,
  app: "tui",
  appVersion: "crok e2e",
  pid: process.pid,
});
const sessionId = `0199e2e1-${stamp.toString(16)}`;
const { sessionDocId } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId,
  fields: { title: "A very long session", cwd: "/Users/e2e/long", model: "grok-code", status: "running" },
});

console.log("Mirroring");
const items = [];
for (let round = 0; round < ROUNDS; round++) {
  const at = stamp - (ROUNDS - round) * 60_000;
  items.push(
    { key: `u${round}`, kind: "user", text: `Prompt ${round}: ${words(180, round)}`, origin: "local", at },
    { key: `t${round}`, kind: "thought", text: words(THOUGHT, `thinking ${round}`), at: at + 1000 },
    round % 7 === 0
      ? { key: `c${round}`, kind: "tool", text: `cargo test -p crate${round}\n${words(OUTPUT, round)}`, toolKind: "execute", status: "completed", at: at + 2000 }
      : { key: `c${round}`, kind: "tool", title: `Execute \`cargo test -p crate${round}\``, text: words(OUTPUT, round), toolKind: "execute", status: round % 5 === 0 ? "failed" : "completed", at: at + 2000 },
    { key: `a${round}`, kind: "assistant", text: `Reply ${round}: ${words(REPLY, round)}`, at: at + 3000 },
    { key: `e${round}`, kind: "system", text: "", status: "end_turn", at: at + 4000 },
  );
}
const pushed = await timed(async () => {
  for (let i = 0; i < items.length; i += 100) {
    await computer.mutation("bridge:pushEvents", { hostId, sessionDocId, events: items.slice(i, i + 100) });
  }
});
const total = items.length;
console.log(`  pushed ${total} items in ${(pushed.ms / 1000).toFixed(1)} s`);

console.log("Opening");
const legacy = await timed(() =>
  phone.query("sessions:events", { sessionDocId, paginationOpts: { numItems: 50, cursor: null } }),
);
const opening = await timed(() => phone.query("sessions:transcript", { sessionDocId, limit: 40 }));
console.log(`  sessions:events newest 50:      ${kb(legacy.value)} in ${legacy.ms.toFixed(0)} ms`);
console.log(`  sessions:transcript newest 40:  ${kb(opening.value)} in ${opening.ms.toFixed(0)} ms`);
check(opening.value.events.length === 40 && opening.value.more, "the newest 40, with more before them", opening.value.events.length);
check(
  opening.value.events.every((e, i, all) => i === 0 || all[i - 1].seq === e.seq + 1) && opening.value.events[0].seq === total,
  "newest first, contiguous",
);
const statusOnly = opening.value.events.filter((e) => e.kind === "thought" || e.kind === "tool");
check(statusOnly.length > 0 && statusOnly.every((e) => e.text === ""), "thoughts and tool calls come without their text");
check(
  opening.value.events.filter((e) => e.kind === "tool").every((e) => e.title && e.status),
  "tool calls keep their title and status",
);
const untitled = (await phone.query("sessions:transcript", { sessionDocId, throughSeq: 3, limit: 1 })).events[0];
check(untitled?.kind === "tool" && untitled.title === "cargo test -p crate0", "a tool without a title is named by its detail's first line", untitled);
check(
  opening.value.events.filter((e) => e.kind === "assistant").every((e) => e.text.length > REPLY),
  "replies keep their text",
);
check(
  JSON.stringify(opening.value).length * 4 < JSON.stringify(legacy.value).length,
  "the opening answer is a fraction of the legacy page",
  [JSON.stringify(opening.value).length, JSON.stringify(legacy.value).length],
);

console.log("Walking back to the beginning");
const lowest = opening.value.events.at(-1).seq;
const seen = new Map();
let bytes = 0;
let parts = 0;
const walk = await timed(async () => {
  const live = await phone.query("sessions:transcript", { sessionDocId, afterSeq: lowest - 1, limit: 200 });
  bytes += JSON.stringify(live).length;
  parts++;
  for (const e of live.events) seen.set(e.seq, (seen.get(e.seq) ?? 0) + 1);
  let floor = lowest;
  let more = true;
  while (more) {
    const older = await phone.query("sessions:transcript", { sessionDocId, throughSeq: floor - 1, limit: 60 });
    bytes += JSON.stringify(older).length;
    parts++;
    for (const e of older.events) seen.set(e.seq, (seen.get(e.seq) ?? 0) + 1);
    more = older.more;
    if (older.events.length > 0) floor = older.events.at(-1).seq;
    else break;
  }
});
check(seen.size === total && [...seen.values()].every((n) => n === 1), `every item once (${seen.size}/${total})`);
check(seen.has(1) && seen.has(total), "from the first item to the newest");
console.log(`  ${parts} parts, ${(bytes / 1024 / 1024).toFixed(2)} MB in ${(walk.ms / 1000).toFixed(1)} s`);
let legacyBytes = 0;
const legacyWalk = await timed(async () => {
  let cursor = null;
  for (;;) {
    const page = await phone.query("sessions:events", { sessionDocId, paginationOpts: { numItems: 50, cursor } });
    legacyBytes += JSON.stringify(page).length;
    if (page.isDone) break;
    cursor = page.continueCursor;
  }
});
console.log(`  sessions:events, 50 a page: ${(legacyBytes / 1024 / 1024).toFixed(2)} MB in ${(legacyWalk.ms / 1000).toFixed(1)} s`);

console.log("Access");
check((await code(() => otherPhone.query("sessions:transcript", { sessionDocId, limit: 5 }))) === "NOT_FOUND", "another person's phone cannot read it");
check((await code(() => phone.query("sessions:transcript", { sessionDocId: "not-an-id", limit: 5 }))) === "NOT_FOUND", "a malformed id is NOT_FOUND");
const empty = await phone.query("sessions:transcript", { sessionDocId, afterSeq: total + 10, limit: 5 });
check(empty.events.length === 0 && !empty.more, "an empty range answers nothing", empty);
check((await code(() => otherPhone.query("sessions:transcript", { sessionDocId, afterSeq: total + 10 }))) === "NOT_FOUND", "an empty range still checks access");

console.log("Live end while a reply streams");
const counts = { live: 0, fixed: 0 };
const latest = { live: null };
const unsubscribeLive = phone.onUpdate("sessions:transcript", { sessionDocId, afterSeq: total - 40, limit: 200 }, (v) => {
  counts.live++;
  latest.live = v;
});
const unsubscribeFixed = phone.onUpdate("sessions:transcript", { sessionDocId, afterSeq: 100, throughSeq: 200, limit: 200 }, () => {
  counts.fixed++;
});
await new Promise((r) => setTimeout(r, 1500));
const before = { ...counts };
let reply = "";
for (let step = 0; step < 10; step++) {
  reply += words(400, `stream ${step}`);
  await computer.mutation("bridge:pushEvents", {
    hostId,
    sessionDocId,
    events: [{ key: `a${ROUNDS - 1}`, kind: "assistant", text: reply, at: stamp }],
    preview: reply.slice(0, 280),
    previewKind: "assistant",
  });
  await new Promise((r) => setTimeout(r, 150));
}
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    { key: "tnew", kind: "thought", text: words(20_000, "new thinking"), at: stamp },
    { key: "cnew", kind: "tool", title: "Read `main.rs`", text: words(20_000, "file"), toolKind: "read", status: "in_progress", at: stamp },
  ],
});
await computer.mutation("bridge:upsertSession", { hostId, sessionId, fields: { status: "running", title: "Renamed" } });
await new Promise((r) => setTimeout(r, 2000));
check(counts.live - before.live >= 5, "the live end follows the reply and the new items", counts);
check(counts.fixed === before.fixed, "an older fixed part gets nothing while the reply streams and items arrive", counts);
check(latest.live?.events[0]?.key === "cnew" && latest.live.events[0].text === "", "new items reach the live end, status only", latest.live?.events[0]);
check(latest.live?.events.find((e) => e.key === `a${ROUNDS - 1}`)?.text === reply, "the streamed reply is current");
unsubscribeLive();
unsubscribeFixed();

console.log("Text limit");
const { sessionDocId: bigDoc } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId: `${sessionId}-big`,
  fields: { title: "Huge replies", cwd: "/Users/e2e/long", status: "idle" },
});
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId: bigDoc,
  events: Array.from({ length: 20 }, (_, i) => ({ key: `big${i}`, kind: "assistant", text: words(32_000, i), at: stamp + i })),
});
const big = await phone.query("sessions:transcript", { sessionDocId: bigDoc, limit: 40 });
const bigText = big.events.reduce((n, e) => n + e.text.length, 0);
check(big.more && big.events.length < 20 && bigText <= 400_000, "one answer holds about 400 000 characters at most", [big.events.length, bigText]);
const rest = await phone.query("sessions:transcript", { sessionDocId: bigDoc, throughSeq: big.events.at(-1).seq - 1, limit: 60 });
check(rest.events.length + big.events.length === 20, "the next part goes on from there", rest.events.length);

await computer.close();
await phone.close();
await otherPhone.close();
console.log(failures === 0 ? "All transcript checks passed." : `${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
