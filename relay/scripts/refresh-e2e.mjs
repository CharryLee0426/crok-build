#!/usr/bin/env node
// Refresh (relay/DESIGN.md §2 "Every session, not only running ones", §3 `sessions:refresh`): a viewer asks every
// online computer to list all its sessions again now, rather than at the holder's next 30 s check. Two computers, A and
// B, each a CROK_HOME signed in with `crok remote login`, run real `crok agent stdio` processes; a "phone" presses
// Refresh.
//
//   1. B runs one crok with a bridge, so it holds B's catalog; sessions made on B's disk with remote control off are
//      listed at its regular check, as before.
//   2. A session renamed on B's disk shows its new title right after the phone presses Refresh
//      (`sessions:refreshState` goes from B pending to none pending): the holder itself lists everything again. Twice,
//      each checked as not shown before the press, so a regular check landing in the window cannot pass it alone.
//   3. Deleted on B's disk, it leaves the list right after Refresh; afterwards B's crok still sends what changes.
//   4. A's remote host (what Crok Desktop runs) answers `_x.ai/remote/refresh` once both computers listed again.
//   5. With B's crok gone, Refresh says B cannot list (`offline`).
//
// Needs a running deployment (`npx convex dev`, CLERK_JWT_ISSUER_DOMAIN set to any value), a crok binary and
// scripts/mock-llm.py as the default model of both homes' config.toml. Projects must not be under the system's temp
// folder. Both homes must be signed out.
//
//   CROK_BIN=…/xai-grok-pager HOME_A=/x/a HOME_B=/x/b PROJ_A=~/p/a PROJ_B=~/p/b node scripts/refresh-e2e.mjs
//
// REFRESH_MS (default 10000) is how soon after Refresh the list must show a change; LIST_WAIT_MS (default 45000) how
// long a change may take without one.

import { execFileSync, spawn } from "node:child_process";
import { readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const CROK = process.env.CROK_BIN;
const HOME_A = process.env.HOME_A;
const HOME_B = process.env.HOME_B;
const PROJ_A = process.env.PROJ_A;
const PROJ_B = process.env.PROJ_B;
const REFRESH_MS = Number(process.env.REFRESH_MS ?? 10_000);
const LIST_WAIT_MS = Number(process.env.LIST_WAIT_MS ?? 45_000);
if (!CROK || !HOME_A || !HOME_B || !PROJ_A || !PROJ_B) throw new Error("set CROK_BIN, HOME_A, HOME_B, PROJ_A and PROJ_B");

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
const issuer = execFileSync("npx", ["convex", "env", "get", "CLERK_JWT_ISSUER_DOMAIN"], { encoding: "utf8" }).trim();
const person = JSON.stringify({ subject: `refresh-e2e-${Date.now()}`, issuer, name: "Refresh Tester", email: "refresh@example.com" });

let failures = 0;
function check(condition, label, detail) {
  if (condition) console.log(`  ok  ${label}`);
  else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail).slice(0, 600)}`}`);
  }
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(fn, timeoutMs) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const value = await fn();
    if (value || Date.now() >= end) return value;
    await sleep(250);
  }
}
const approve = (userCode) =>
  execFileSync("npx", ["convex", "run", "deviceAuth:approve", JSON.stringify({ userCode }), "--identity", person], {
    encoding: "utf8",
  });

async function signIn(home, name) {
  const login = spawn(CROK, ["remote", "login", "--json", "--no-browser", "--server", url, "--name", name], {
    env: { ...process.env, CROK_HOME: home, CROK_DISABLE_AUTOUPDATER: "1" },
  });
  const done = new Promise((resolve) => login.on("exit", resolve));
  for await (const line of createInterface({ input: login.stdout })) {
    const event = JSON.parse(line);
    if (event.event === "code") approve(event.userCode);
  }
  return done;
}

/** A `crok agent stdio` (a Crok Desktop task, or its remote host), initialized; `bridge: false` runs it without one. */
async function agent(home, cwd, { bridge = true } = {}) {
  const env = { ...process.env, CROK_HOME: home, CROK_DISABLE_AUTOUPDATER: "1", GROK_CLIENT_VERSION: "e2e" };
  if (!bridge) env.CROK_REMOTE_BRIDGE = "0";
  const proc = spawn(CROK, ["agent", "stdio"], { cwd, env });
  proc.stderr.on("data", () => {});
  const exited = new Promise((resolve) => proc.on("exit", resolve));
  let next = 1;
  const pending = new Map();
  const notes = [];
  const write = (message) => proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  createInterface({ input: proc.stdout }).on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id !== undefined && !message.method) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      clearTimeout(waiter.timer);
      if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
      else waiter.resolve(message.result);
      return;
    }
    if (message.method && message.id !== undefined) {
      const method = message.method.replace(/^_/, "");
      if (method === "x.ai/folder_trust/request") write({ id: message.id, result: { outcome: "trust" } });
      else write({ id: message.id, error: { code: -32601, message: `unsupported: ${method}` } });
      return;
    }
    if (message.method) notes.push({ method: message.method.replace(/^_/, ""), params: message.params, at: Date.now() });
  });
  const rpc = (method, params, timeoutMs = 120_000) => {
    const id = next++;
    write({ id, method, params });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      pending.set(id, { resolve, reject, timer });
    });
  };
  await rpc("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    _meta: { clientType: "grok_desktop", clientIdentifier: "refresh-e2e", clientVersion: "0" },
  });
  const stop = async () => {
    proc.stdin.end();
    await Promise.race([exited, sleep(15_000)]);
  };
  return { rpc, notes, stop };
}

/** A session with one turn, made by `agent` in `cwd`; its crok id. */
async function sessionWithTurn(agent, cwd, text) {
  const { sessionId } = await agent.rpc("session/new", { cwd, mcpServers: [] });
  await agent.rpc("session/prompt", { sessionId, prompt: [{ type: "text", text }], _meta: { promptId: `p-${Date.now()}` } });
  return sessionId;
}

/** The session's folder under a crok home (`sessions/<encoded cwd>/<id>`). */
function sessionDir(home, sessionId) {
  const root = join(home, "sessions");
  for (const folder of readdirSync(root)) {
    const dir = join(root, folder, sessionId);
    try {
      if (statSync(dir).isDirectory()) return dir;
    } catch {}
  }
  return null;
}

console.log(`Refresh e2e: ${CROK}\n  relay ${url}`);
console.log("two computers and a phone sign in");
await signIn(HOME_A, "Mac A");
await signIn(HOME_B, "Mac B");
const http = new ConvexHttpClient(url);
const start = await http.mutation("deviceAuth:start", { kind: "phone", name: "Refresh phone", platform: "Terminal", client: "e2e" });
approve(start.userCode);
let refreshToken;
while (!refreshToken) {
  await sleep(start.interval * 1000);
  const poll = await http.mutation("deviceAuth:poll", { deviceCode: start.deviceCode });
  if (poll.status === "approved") refreshToken = poll.refreshToken;
}
const phone = new ConvexClient(url);
phone.setAuth(async () => (await http.mutation("deviceAuth:refresh", { refreshToken })).accessToken);
let groups = [];
phone.onUpdate("sessions:groups", {}, (value) => {
  groups = value;
});
const rows = () => groups.flatMap((g) => g.sessions);
const listed = (sessionId) => rows().find((s) => s.sessionId === sessionId);

/** Presses Refresh; how long until `check` holds, and what `sessions:refreshState` said on the way. */
async function refreshUntil(check) {
  const pressed = Date.now();
  const answer = await phone.mutation("sessions:refresh", {});
  const states = [];
  let shown = false;
  await until(async () => {
    const state = await phone.query("sessions:refreshState", { since: answer.at });
    states.push(state.pending.length);
    shown = shown || Boolean(check());
    return shown && state.pending.length === 0;
  }, REFRESH_MS);
  return { answer, states, shown, seconds: (Date.now() - pressed) / 1000 };
}

// 1. B's only crok holds its catalog and sends what changes on disk, as before Refresh.
console.log("1. B's holder lists a session made on its disk without a bridge");
const b1 = await agent(HOME_B, PROJ_B);
await sessionWithTurn(b1, PROJ_B, "B is online");
const made = [];
for (const round of [1, 2]) {
  const quiet = await agent(HOME_B, PROJ_B, { bridge: false });
  made.push(await sessionWithTurn(quiet, PROJ_B, `made with remote control off (${round})`));
  await quiet.stop();
}
const madeAt = Date.now();
check(
  await until(() => made.every((id) => listed(id)), LIST_WAIT_MS),
  `listed without Refresh (${((Date.now() - madeAt) / 1000).toFixed(1)} s)`,
);

// 2. Renamed on B's disk, then Refresh at once: the new title shows right after, not at the next 30 s check.
console.log("2. renamed on B's disk, then Refresh");
for (const round of [1, 2]) {
  const id = made[round - 1];
  const title = `Renamed on B (${round}) ${Date.now()}`;
  const summary = join(sessionDir(HOME_B, id), "summary.json");
  const data = JSON.parse(readFileSync(summary, "utf8"));
  data.generated_title = title;
  writeFileSync(summary, JSON.stringify(data));
  const before = listed(id)?.title === title;
  const result = await refreshUntil(() => listed(id)?.title === title);
  check(result.answer.asked === 1 && result.answer.offline === 1, `round ${round}: Refresh asks B; A has no crok yet`, result.answer);
  check(!before && result.states[0] === 1, `round ${round}: not shown before, B pending at first`, { before, states: result.states });
  check(
    result.shown && result.states.at(-1) === 0,
    `round ${round}: shown and done ${result.seconds.toFixed(1)} s after Refresh (≤ ${REFRESH_MS / 1000} s)`,
    result,
  );
}

// 3. Deleted on B's disk, then Refresh at once: gone right after.
console.log("3. deleted on B's disk, then Refresh");
const dir = sessionDir(HOME_B, made[0]);
check(dir, "its folder is on B's disk", HOME_B);
if (dir) rmSync(dir, { recursive: true, force: true });
const removal = await refreshUntil(() => !listed(made[0]));
check(removal.states[0] === 1, "B pending at first", removal.states);
check(removal.shown && removal.states.at(-1) === 0, `gone ${removal.seconds.toFixed(1)} s after Refresh`, removal);
check(listed(made[1]), "the other one stays");

// After Refresh, B's crok still holds the catalog and sends what changes.
const quiet = await agent(HOME_B, PROJ_B, { bridge: false });
const later = await sessionWithTurn(quiet, PROJ_B, "made after Refresh");
await quiet.stop();
const laterAt = Date.now();
check(
  await until(() => listed(later), LIST_WAIT_MS),
  `B still sends what changes after Refresh (${((Date.now() - laterAt) / 1000).toFixed(1)} s)`,
);

// 4. A's remote host (Crok Desktop's): Refresh through crok.
console.log("4. A's remote host refreshes");
const aHost = await agent(HOME_A, PROJ_A);
await aHost.rpc("_x.ai/remote/sessions", { watch: true });
await sleep(3_000);
const viaHost = await aHost.rpc("_x.ai/remote/refresh", {}, 30_000);
const hostAnswer = viaHost.asked !== undefined ? viaHost : viaHost.result;
check(hostAnswer?.asked === 2 && hostAnswer?.offline === 0, "it asks both computers", hostAnswer);
check(Array.isArray(hostAnswer?.pending) && hostAnswer.pending.length === 0, "and answers once both listed again", hostAnswer);

// 5. B's crok quits: B cannot list.
console.log("5. B's crok quits, then Refresh");
await b1.stop();
const devices = await phone.query("devices:list", {});
const macB = devices.find((d) => d.name === "Mac B");
// The bridge says goodbye on exit; the cron would mark it offline after 90 s otherwise.
const offline = await until(async () => {
  const list = await phone.query("devices:list", {});
  return list.find((d) => d._id === macB._id && !d.online);
}, 30_000);
check(offline, "B shows offline");
const lone = await phone.mutation("sessions:refresh", {});
check(lone.asked === 1 && lone.offline === 1, "Refresh asks A and says B is offline", lone);
const after = await phone.query("sessions:refreshState", { since: lone.at });
check(!after.pending.includes(macB._id), "B is never pending while offline", after);
check(listed(made[1]), "B's sessions stay listed as it last listed them");

await aHost.stop();
await phone.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
