#!/usr/bin/env node
// Every device's list of sessions stays current (relay/DESIGN.md §2 "Every session, not only running ones", §4
// "Sessions on other computers"). Two computers, A and B, each a CROK_HOME signed in with `crok remote login`, run real
// `crok agent stdio` processes; a "phone" watches `sessions:groups`.
//
//   1. B's sessions reach the phone as they run, and A's remote host (what Crok Desktop runs in the background) gets
//      them in its first `x.ai/remote/sessions` answer.
//   2. A session B makes on disk without any bridge (a crok with remote control off) is listed within the holder's
//      check interval, and dropped again once it is deleted there.
//   3. When B's catalog holder quits, B's other crok takes the catalog over at once (`catalogWanted`) and keeps it
//      current.
//   4. A session the phone starts on A appears on A itself: in A's `x.ai/remote/sessions_changed` under `here`, with
//      its crok id and the phone's name; the same list is never sent twice in a row.
//
// Needs a running deployment (`npx convex dev`, CLERK_JWT_ISSUER_DOMAIN set to any value), a crok binary and
// scripts/mock-llm.py as the default model of both homes' config.toml. Projects must not be under the system's temp
// folder (crok leaves sessions there out of the catalog). Both homes must be signed out.
//
//   CROK_BIN=…/xai-grok-pager HOME_A=/x/a HOME_B=/x/b PROJ_A=~/p/a PROJ_B=~/p/b node scripts/sessions-live-e2e.mjs
//
// LIST_WAIT_MS (default 45000) is how long a change on disk may take to reach the phone.

import { execFileSync, spawn } from "node:child_process";
import { readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const CROK = process.env.CROK_BIN;
const HOME_A = process.env.HOME_A;
const HOME_B = process.env.HOME_B;
const PROJ_A = process.env.PROJ_A;
const PROJ_B = process.env.PROJ_B;
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
const person = JSON.stringify({ subject: `live-e2e-${Date.now()}`, issuer, name: "Live Tester", email: "live@example.com" });

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
    _meta: { clientType: "grok_desktop", clientIdentifier: "sessions-live-e2e", clientVersion: "0" },
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

console.log(`Sessions-live e2e: ${CROK}\n  relay ${url}`);
console.log("two computers and a phone sign in");
await signIn(HOME_A, "Mac A");
await signIn(HOME_B, "Mac B");
const http = new ConvexHttpClient(url);
const start = await http.mutation("deviceAuth:start", { kind: "phone", name: "Live phone", platform: "Terminal", client: "e2e" });
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
const rows = () => groups.flatMap((g) => g.sessions.map((s) => ({ ...s, deviceName: g.deviceName })));
const listed = (sessionId) => rows().find((s) => s.sessionId === sessionId);

// 1. B runs a task; the phone and A's remote host list it.
console.log("1. a session running on B");
const b1 = await agent(HOME_B, PROJ_B);
const bLive = await sessionWithTurn(b1, PROJ_B, "hello from B");
check(await until(() => listed(bLive), 10_000), "the phone lists B's running session at once");
const aHost = await agent(HOME_A, PROJ_A);
const first = await aHost.rpc("_x.ai/remote/sessions", { watch: true });
const firstList = first.computers ? first : first.result;
const firstB = firstList?.computers?.find((c) => c.deviceName === "Mac B");
check(
  firstB?.projects.some((p) => p.sessions.some((s) => s.sessionId.startsWith("relay:"))),
  "A's remote host gets B's sessions in its first answer",
  firstList,
);
check(Array.isArray(firstList?.here?.sessions) && firstList.here.sessions.length === 0, "and an empty `here`", firstList?.here);

// 2. A session made on B's disk by a crok without a bridge, then deleted there.
console.log("2. a session B makes and deletes on disk, no bridge");
const quiet = await agent(HOME_B, PROJ_B, { bridge: false });
const bDisk = await sessionWithTurn(quiet, PROJ_B, "made with remote control off");
await quiet.stop();
const madeAt = Date.now();
const diskRow = await until(() => listed(bDisk), LIST_WAIT_MS);
check(diskRow, `the phone lists it within ${LIST_WAIT_MS / 1000} s (${((Date.now() - madeAt) / 1000).toFixed(1)} s)`);
check(diskRow && !diskRow.online && diskRow.historyState === "none", "offline, its transcript still on B", diskRow);
const dir = sessionDir(HOME_B, bDisk);
check(dir, "its folder is on B's disk", HOME_B);
if (dir) rmSync(dir, { recursive: true, force: true });
const deletedAt = Date.now();
const gone = await until(() => !listed(bDisk), LIST_WAIT_MS);
check(gone, `deleted on B, it leaves the phone's list within ${LIST_WAIT_MS / 1000} s (${((Date.now() - deletedAt) / 1000).toFixed(1)} s)`);
check(listed(bLive), "the running session stays");

// 3. B's holder quits; B's other crok takes the catalog over.
console.log("3. B's catalog holder quits");
const b2 = await agent(HOME_B, PROJ_B);
await sleep(3_000);
await b1.stop();
await sleep(1_000);
const quiet2 = await agent(HOME_B, PROJ_B, { bridge: false });
const bDisk2 = await sessionWithTurn(quiet2, PROJ_B, "made after the holder quit");
await quiet2.stop();
const madeAt2 = Date.now();
check(
  await until(() => listed(bDisk2), LIST_WAIT_MS),
  `B's other crok lists sessions made afterwards (${((Date.now() - madeAt2) / 1000).toFixed(1)} s)`,
);

// 4. The phone starts a session on A: A's own front end hears of it.
console.log("4. the phone starts a session on A");
const devices = await phone.query("devices:list", {});
const macA = devices.find((d) => d.name === "Mac A");
const created = await phone.mutation("sessions:create", {
  deviceId: macA._id,
  path: PROJ_A,
  text: "started from the phone",
  clientId: crypto.randomUUID(),
});
const row = await until(() => rows().find((s) => s._id === created.sessionDocId && !s.starting), 30_000);
check(row?.startedFrom?.kind === "phone" && row.startedFrom.name === "Live phone", "the relay row says the phone started it", row);
const hereNote = await until(
  () =>
    aHost.notes
      .filter((n) => n.method === "x.ai/remote/sessions_changed")
      .map((n) => n.params?.here?.sessions?.find((s) => s.relayId === `relay:${created.sessionDocId}`))
      .find(Boolean),
  30_000,
);
check(hereNote && !hereNote.sessionId.startsWith("pending:"), "A's front end gets it under `here`, by its crok id", hereNote);
check(hereNote?.startedFrom?.name === "Live phone" && hereNote?.projectPath === PROJ_A, "with the phone's name and its project", hereNote);
// Once its first turn is over, the session is on A's disk like one typed there.
await until(() => rows().find((s) => s._id === created.sessionDocId && s.status === "idle"), 60_000);
const a2 = await agent(HOME_A, PROJ_A);
let local;
const onDisk = await until(async () => {
  local = await a2.rpc("session/list", { cwd: PROJ_A });
  return local.sessions?.some((s) => s.sessionId === hereNote?.sessionId);
}, 20_000);
check(onDisk, "another crok on A lists it from disk (/resume)", local);
const changes = aHost.notes.filter((n) => n.method === "x.ai/remote/sessions_changed").map((n) => JSON.stringify(n.params));
check(changes.every((c, i) => i === 0 || c !== changes[i - 1]), `no list is sent twice in a row (${changes.length} sent)`);

await Promise.all([aHost.stop(), a2.stop(), b2.stop()]);
await phone.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
