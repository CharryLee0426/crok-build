#!/usr/bin/env node
// How soon other devices see a turn end. A real `crok agent stdio` mirrors its session through a relay connection that
// adds LATENCY_MS each way (a relay far away), while a "phone" watches the session directly. Each case ends a turn on
// the computer and measures how long the relay keeps showing it as running ("working…" on the web and phones):
//
//   1. a long agent turn (many tool calls and streamed text) while the phone has the session open,
//   2. a turn stopped inside a tool call,
//   3. a queued prompt taken off the queue before it ran, then a prompt from the phone (it must not wait behind a turn
//      that is over).
//
// Needs a running deployment (`npx convex dev`, CLERK_JWT_ISSUER_DOMAIN set to any value), a crok binary and
// scripts/mock-llm.py as the default model of CROK_HOME/config.toml:
//
//   CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/home E2E_PROJECT=~/e2e-project LATENCY_MS=150 node scripts/status-e2e.mjs
//
// MAX_LAG_MS (default 3000) is how late the relay may say a turn ended. BUSY_ROUNDS (default 40) sizes the long turn.

import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import net from "node:net";
import { createInterface } from "node:readline";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const CROK = process.env.CROK_BIN;
const HOME = process.env.CROK_HOME;
const PROJECT = process.env.E2E_PROJECT ?? process.cwd();
const LATENCY_MS = Number(process.env.LATENCY_MS ?? 150);
const MAX_LAG_MS = Number(process.env.MAX_LAG_MS ?? 3_000);
const BUSY_ROUNDS = Number(process.env.BUSY_ROUNDS ?? 40);
if (!CROK || !HOME) throw new Error("set CROK_BIN and CROK_HOME");

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
const person = JSON.stringify({ subject: `status-e2e-${Date.now()}`, issuer, name: "Status Tester", email: "status@example.com" });
const env = { ...process.env, CROK_HOME: HOME, CROK_DISABLE_AUTOUPDATER: "1" };

let failures = 0;
function check(condition, label, detail) {
  if (condition) console.log(`  ok  ${label}`);
  else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail).slice(0, 600)}`}`);
  }
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(label, fn, timeoutMs = 20_000) {
  const end = Date.now() + timeoutMs;
  let last;
  while (Date.now() < end) {
    try {
      last = await fn();
      if (last) return last;
    } catch (error) {
      last = error;
    }
    await sleep(50);
  }
  check(false, `timed out: ${label}`, last instanceof Error ? last.message : last);
  return null;
}
function approve(userCode) {
  execFileSync("npx", ["convex", "run", "deviceAuth:approve", JSON.stringify({ userCode }), "--identity", person], {
    encoding: "utf8",
  });
}

/** A TCP proxy to `target` that holds every chunk `delayMs` in each direction, in order. */
function latencyProxy(target, delayMs) {
  const { hostname, port } = new URL(target);
  const server = net.createServer((client) => {
    const upstream = net.connect(Number(port), hostname);
    const pipe = (from, to) => {
      from.on("data", (chunk) => setTimeout(() => to.destroyed || to.write(chunk), delayMs));
      from.on("end", () => setTimeout(() => to.end(), delayMs));
      from.on("error", () => to.destroy());
      from.on("close", () => setTimeout(() => to.destroy(), delayMs));
    };
    pipe(client, upstream);
    pipe(upstream, client);
  });
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve({ server, url: `http://127.0.0.1:${server.address().port}` })),
  );
}

/** A `crok agent stdio` process (what Crok Desktop runs per task), initialized and signed in to its model. */
async function startAgent() {
  const agent = spawn(CROK, ["agent", "stdio"], { cwd: PROJECT, env: { ...env, GROK_CLIENT_VERSION: "e2e" } });
  let stderr = "";
  agent.stderr.on("data", (d) => (stderr += d));
  const exited = new Promise((resolve) => agent.on("exit", resolve));
  let nextId = 1;
  const pending = new Map();
  const notifications = [];
  const write = (obj) => agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...obj })}\n`);
  const rpc = (method, params, timeoutMs = 180_000) => {
    const id = nextId++;
    write({ id, method, params });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      pending.set(id, { resolve, reject, timer });
    });
  };
  createInterface({ input: agent.stdout }).on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id !== undefined && (message.result !== undefined || message.error !== undefined) && !message.method) {
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
      else if (method === "session/request_permission") {
        const allow = message.params.options.find((o) => o.kind === "allow_once") ?? message.params.options[0];
        write({ id: message.id, result: { outcome: { outcome: "selected", optionId: allow.optionId } } });
      } else write({ id: message.id, error: { code: -32601, message: `unsupported: ${method}` } });
      return;
    }
    if (message.method) notifications.push({ at: Date.now(), method: message.method.replace(/^_/, ""), params: message.params });
  });
  const notify = (method, params) => write({ method, params });
  const init = await rpc("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    _meta: { clientType: "grok_desktop", clientIdentifier: "status-e2e", clientVersion: "0" },
  });
  const methods = (init.authMethods ?? []).map((m) => m.id);
  if (methods.includes("xai.api_key")) await rpc("authenticate", { methodId: "xai.api_key", _meta: { headless: true } });
  return { agent, rpc, notify, notifications, exited, stderr: () => stderr };
}

// The files the long turn reads, one per round (the mock model reads steps/step-<round>.txt).
mkdirSync(`${PROJECT}/steps`, { recursive: true });
for (let i = 0; i < BUSY_ROUNDS; i++) writeFileSync(`${PROJECT}/steps/step-${i}.txt`, `step ${i}\n`);

const proxy = await latencyProxy(url, LATENCY_MS);
console.log(`Status e2e: ${CROK}\n  relay ${url}, crok through ${proxy.url} (+${LATENCY_MS} ms each way)\n  project ${PROJECT}`);

// The computer signs in through the slow connection; its bridge then talks to the relay through it too.
const login = spawn(CROK, ["remote", "login", "--json", "--no-browser", "--force", "--server", proxy.url, "--name", "Far Mac"], {
  env,
});
const loginDone = new Promise((resolve) => login.on("exit", resolve));
for await (const line of createInterface({ input: login.stdout })) {
  const event = JSON.parse(line);
  if (event.event === "code") approve(event.userCode);
}
check((await loginDone) === 0, "the computer signs in through the slow connection");

const { agent, rpc, notify, notifications, exited } = await startAgent();
const { sessionId } = await rpc("session/new", { cwd: PROJECT, mcpServers: [] });
await rpc("session/prompt", { sessionId, prompt: [{ type: "text", text: "hello" }], _meta: { promptId: "hello-1" } });

const http = new ConvexHttpClient(url);
const started = await http.mutation("deviceAuth:start", { kind: "phone", name: "Near iPhone", platform: "iOS", client: "e2e" });
approve(started.userCode);
const phoneTokens = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
const phone = new ConvexClient(url);
phone.setAuth(async ({ forceRefreshToken }) => {
  if (!forceRefreshToken) return phoneTokens.accessToken;
  return (await http.mutation("deviceAuth:refresh", { refreshToken: phoneTokens.refreshToken })).accessToken;
});
const row = await until("the session shows up", async () => {
  const list = await phone.query("sessions:list", {});
  return list.find((s) => s.sessionId === sessionId && s.online);
}, 30_000);
const sessionDocId = row?._id;
if (!sessionDocId) {
  agent.kill();
  process.exit(1);
}

// The phone keeps the session open (as a phone showing it does), and notes when its status changes.
const watch = () => phone.mutation("sessions:watch", { sessionDocId }).catch(() => {});
await watch();
const watching = setInterval(watch, 15_000);
const seen = { status: row?.status, at: Date.now() };
const transitions = [];
phone.onUpdate("sessions:get", { sessionDocId }, (session) => {
  if (!session || session.status === seen.status) return;
  seen.status = session.status;
  seen.at = Date.now();
  transitions.push({ status: session.status, at: seen.at });
});
await until("the phone sees the session idle", async () => seen.status === "idle");

/** How long after `endedAt` the phone saw the session idle for good (it must stay idle `settleMs`). */
async function lagAfter(endedAt, settleMs = 2_000, timeoutMs = 300_000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (seen.status === "idle" && Date.now() - seen.at >= settleMs) return Math.max(0, seen.at - endedAt);
    await sleep(50);
  }
  return Infinity;
}
// When the long turn's last reply reached the phone.
let replyAt = null;
phone.onUpdate("sessions:events", { sessionDocId, paginationOpts: { numItems: 30, cursor: null } }, (result) => {
  const done = result?.page?.some((e) => e.kind === "assistant" && e.text.includes(`All ${BUSY_ROUNDS} steps are done`));
  if (done && replyAt === null) replyAt = Date.now();
});

// 1. A long turn while the phone watches.
console.log(`a long turn (${BUSY_ROUNDS} tool calls)`);
const busyStart = Date.now();
const busy = await rpc("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: `please do the busy ${BUSY_ROUNDS} job` }],
  _meta: { promptId: "busy-1" },
});
const busyEnded = Date.now();
check(busy.stopReason === "end_turn", "the long turn ends on the computer", busy);
const sawRunning = transitions.some((t) => t.status === "running" && t.at >= busyStart);
const busyLag = await lagAfter(busyEnded);
console.log(`      turn took ${((busyEnded - busyStart) / 1000).toFixed(1)} s; the phone saw it end ${busyLag} ms later`);
check(sawRunning, "the phone saw it working");
check(busyLag <= MAX_LAG_MS, `the phone sees it end within ${MAX_LAG_MS} ms`, busyLag);
await until("the last reply reaches the phone", async () => replyAt !== null, 300_000);
const replyLag = Math.max(0, replyAt - busyEnded);
console.log(`      its last reply was there ${replyLag} ms after it ended`);
check(replyLag <= MAX_LAG_MS, `the last reply reaches the phone within ${MAX_LAG_MS} ms`, replyLag);

// 2. A turn stopped inside a tool call.
console.log("a turn stopped inside a tool call");
const sleepy = rpc("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: "a sleepy one" }],
  _meta: { promptId: "sleepy-1" },
});
await until("the tool call starts", async () =>
  notifications.some((n) => n.params?.update?.sessionUpdate === "tool_call" && JSON.stringify(n.params).includes("sleep 30")),
);
await until("the phone sees it working", async () => seen.status === "running");
await sleep(500);
notify("session/cancel", { sessionId });
const stopped = await sleepy;
const stoppedAt = Date.now();
check(stopped.stopReason === "cancelled", "the turn stops on the computer", stopped);
await sleep(1_500);
const trailing = notifications
  .filter((n) => n.at > stoppedAt && n.params?.sessionId === sessionId)
  .map((n) => n.params?.update?.sessionUpdate ?? n.method);
console.log(`      after the stop the computer still heard: ${trailing.join(", ") || "nothing"}`);
const stopLag = await lagAfter(stoppedAt);
console.log(`      the phone saw it end ${stopLag} ms later`);
check(stopLag <= MAX_LAG_MS, `the phone sees the stopped turn end within ${MAX_LAG_MS} ms`, stopLag);

// 3. A queued prompt taken off the queue, then a prompt from the phone.
console.log("a queued prompt taken off the queue");
const slow = rpc("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: "a slow answer please" }],
  _meta: { promptId: "slow-1" },
});
await until("the slow turn runs", async () => seen.status === "running");
const queued = rpc("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: "and then this" }],
  _meta: { promptId: "queued-2" },
});
await until("the second prompt is queued", async () =>
  notifications.some((n) => n.method === "x.ai/queue/changed" && n.params?.entries?.some((e) => e.id === "queued-2")),
);
notify("_x.ai/queue/remove", { sessionId, id: "queued-2", expectedVersion: 0 });
const removed = await queued;
check(
  ["removedFromQueue", "removed_from_queue"].includes(removed._meta?.completionKind),
  "the queued prompt comes back unrun",
  removed,
);
const slowDone = await slow;
const slowEnded = Date.now();
check(slowDone.stopReason === "end_turn", "the running turn ends on the computer", slowDone);
const queueLag = await lagAfter(slowEnded);
console.log(`      the phone saw it end ${queueLag} ms later`);
check(queueLag <= MAX_LAG_MS, `the phone sees it end within ${MAX_LAG_MS} ms`, queueLag);
const sent = Date.now();
const { commandId } = await phone.mutation("commands:sendPrompt", { sessionDocId, text: "one from the phone", clientId: crypto.randomUUID() });
const command = await until("the phone's prompt runs", async () => {
  const c = await phone.query("commands:get", { commandId });
  return c?.status === "done" || c?.status === "failed" ? c : null;
}, 60_000);
check(command?.status === "done", "the phone's prompt runs at once, not behind a finished turn", command);
console.log(`      it was done ${Date.now() - sent} ms after it was sent`);

clearInterval(watching);
agent.stdin.end();
await Promise.race([exited, sleep(10_000)]);
agent.kill();
await phone.close();
proxy.server.close();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
