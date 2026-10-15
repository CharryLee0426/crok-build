#!/usr/bin/env node
// End-to-end check of the computer side: a real `crok` signs in with `crok remote login`, a `crok agent stdio` (the
// process Crok Desktop runs per task) mirrors its session, and a "phone" reads it, sends a prompt, asks for session
// info, stops a running turn, and sees the session go offline when the process exits.
//
// Needs: a running deployment (`npx convex dev`, with CLERK_JWT_ISSUER_DOMAIN set to any value), a crok binary, and a
// model the agent can call (an OpenAI-compatible server; see the config below).
//
//   CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/home E2E_PROJECT=/tmp/project node scripts/bridge-e2e.mjs
//
// CROK_HOME/config.toml should point the default model at that server and may set [remote] url.

import { execFileSync, spawn } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { createInterface } from "node:readline";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const CROK = process.env.CROK_BIN;
const HOME = process.env.CROK_HOME;
const PROJECT = process.env.E2E_PROJECT ?? process.cwd();
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
const person = JSON.stringify({ subject: `bridge-e2e-${Date.now()}`, issuer, name: "Bridge Tester", email: "bridge@example.com" });
const env = { ...process.env, CROK_HOME: HOME, CROK_DISABLE_AUTOUPDATER: "1" };

let failures = 0;
function check(condition, label, detail) {
  if (condition) console.log(`  ok  ${label}`);
  else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail).slice(0, 400)}`}`);
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
    await sleep(300);
  }
  check(false, `timed out: ${label}`, last instanceof Error ? last.message : last);
  return null;
}
function approve(userCode) {
  execFileSync("npx", ["convex", "run", "deviceAuth:approve", JSON.stringify({ userCode }), "--identity", person], {
    encoding: "utf8",
  });
}

console.log(`Bridge e2e: ${CROK}\n  relay ${url}\n  home ${HOME}`);

// 1. `crok remote login` signs this computer in.
console.log("crok remote login");
const login = spawn(CROK, ["remote", "login", "--json", "--no-browser", "--server", url, "--name", "E2E Mac"], { env });
const loginEvents = [];
let loginErr = "";
login.stderr.on("data", (d) => (loginErr += d));
const loginDone = new Promise((resolve) => login.on("exit", resolve));
for await (const line of createInterface({ input: login.stdout })) {
  const event = JSON.parse(line);
  loginEvents.push(event);
  if (event.event === "code") approve(event.userCode);
}
const loginCode = await loginDone;
check(loginCode === 0, "login exits 0", loginErr.slice(-500));
check(loginEvents[0]?.event === "code" && /^[B-Z]{4}-[B-Z]{4}$/.test(loginEvents[0].userCode), "prints the code first");
check(loginEvents.at(-1)?.event === "signed_in" && loginEvents.at(-1).account.name === "Bridge Tester", "then signed_in with the account");
const credentialsPath = `${HOME}/remote/credentials.json`;
check((statSync(credentialsPath).mode & 0o777) === 0o600, "credentials are 0600");
const status = JSON.parse(execFileSync(CROK, ["remote", "status", "--json"], { env, encoding: "utf8" }).trim());
check(status.signedIn && status.reachable && status.deviceName === "E2E Mac", "crok remote status", status);

// 2. A task process, driven like Crok Desktop drives it.
console.log("crok agent stdio");
const agent = spawn(CROK, ["agent", "stdio"], { cwd: PROJECT, env: { ...env, GROK_CLIENT_VERSION: "e2e" } });
let agentErr = "";
agent.stderr.on("data", (d) => (agentErr += d));
const agentExit = new Promise((resolve) => agent.on("exit", resolve));
let nextId = 1;
const pending = new Map();
const notifications = [];
function write(obj) {
  agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...obj })}\n`);
}
function rpc(method, params, timeoutMs = 120_000) {
  const id = nextId++;
  write({ id, method, params });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
    pending.set(id, { resolve, reject, timer });
  });
}
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
    // Requests from the agent: trust the folder, refuse everything else.
    const method = message.method.replace(/^_/, "");
    if (method === "x.ai/folder_trust/request") write({ id: message.id, result: { outcome: "trust" } });
    else if (method === "session/request_permission") write({ id: message.id, result: { outcome: { outcome: "cancelled" } } });
    else write({ id: message.id, error: { code: -32601, message: `unsupported: ${method}` } });
    return;
  }
  if (message.method) notifications.push({ method: message.method.replace(/^_/, ""), params: message.params });
});

const init = await rpc("initialize", {
  protocolVersion: 1,
  clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
  _meta: { clientType: "grok_desktop", clientIdentifier: "bridge-e2e", clientVersion: "0" },
});
const methods = (init.authMethods ?? []).map((m) => m.id);
if (methods.includes("xai.api_key")) await rpc("authenticate", { methodId: "xai.api_key", _meta: { headless: true } });
const { sessionId } = await rpc("session/new", { cwd: PROJECT, mcpServers: [] });
check(typeof sessionId === "string", "session/new", sessionId);
const firstTurn = await rpc("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: "hello there from the desk" }],
  _meta: { promptId: "local-1" },
});
check(firstTurn.stopReason === "end_turn", "a local prompt runs", firstTurn);

// 3. The phone.
console.log("phone");
const http = new ConvexHttpClient(url);
const started = await http.mutation("deviceAuth:start", { kind: "phone", name: "E2E iPhone", platform: "iOS", client: "e2e" });
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
});
check(row?.deviceName === "E2E Mac" && row?.app === "desktop", "listed under the computer, as Crok Desktop", row);
const sessionDocId = row?._id;
const events = async () =>
  (await phone.query("sessions:events", { sessionDocId, paginationOpts: { numItems: 100, cursor: null } })).page.reverse();
const firstEvents = await until("the first turn is mirrored", async () => {
  const page = await events();
  return page.some((e) => e.kind === "assistant" && e.text.includes("Hi from mock")) ? page : null;
});
check(firstEvents?.[0]?.kind === "user" && firstEvents[0].text === "hello there from the desk", "the typed prompt is the first item", firstEvents?.[0]);
check(
  notifications.some((n) => n.method === "x.ai/remote/status" && n.params?.state === "connected"),
  "the front end hears the link is connected",
  notifications.filter((n) => n.method.startsWith("x.ai/remote")).map((n) => n.params),
);
await phone.mutation("sessions:watch", { sessionDocId });

// 4. A prompt from the phone.
console.log("remote prompt");
const clientId = crypto.randomUUID();
const { commandId } = await phone.mutation("commands:sendPrompt", { sessionDocId, text: "remote hello", clientId });
const done = await until("the remote prompt finishes", async () => {
  const command = await phone.query("commands:get", { commandId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(done?.status === "done", "the command ends done (two ticks)", done);
const afterRemote = await until("the reply is mirrored", async () => {
  const page = await events();
  const prompt = page.find((e) => e.commandId === commandId);
  return prompt && page.some((e) => e.kind === "assistant" && e.seq > prompt.seq && e.text.includes("Hi from mock"))
    ? page
    : null;
});
const remoteUser = afterRemote?.find((e) => e.commandId === commandId);
check(remoteUser?.origin === "remote" && remoteUser?.text === "remote hello", "the prompt is in the transcript as remote", remoteUser ?? (await events()).map((e) => [e.seq, e.kind, e.text.slice(0, 40), e.commandId]));
const shown = notifications.find((n) => n.method === "x.ai/remote/prompt");
check(shown?.params?.text === "remote hello" && shown?.params?.from === "E2E iPhone", "the front end is told about it", shown?.params);

// 5. Session info.
console.log("session info");
const { commandId: infoId } = await phone.mutation("commands:requestInfo", { sessionDocId });
const info = await until("info arrives", async () => {
  const command = await phone.query("commands:get", { commandId: infoId });
  return command?.status === "done" ? command.result : null;
});
check(Boolean(info?.model) && info?.cwd === PROJECT, "model and folder", info);
check((info?.usage?.outputTokens ?? 0) > 0, "token usage", info?.usage);
const sessionRow = await phone.query("sessions:get", { sessionDocId });
check(sessionRow.usage?.outputTokens > 0, "usage is kept on the session too", sessionRow.usage);

// 6. Stop a running turn.
console.log("stop");
const { commandId: slowId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId,
  text: "be slow about it",
  clientId: crypto.randomUUID(),
});
await until("the slow turn is running", async () => (await phone.query("sessions:get", { sessionDocId })).status === "running");
await until("some of it streamed", async () =>
  (await events()).some((e) => e.kind === "assistant" && e.text.includes("word3")),
);
const { commandId: stopId } = await phone.mutation("commands:stop", { sessionDocId });
const stopped = await until("the stop lands", async () => {
  const page = await events();
  return page.some((e) => e.kind === "system" && e.status === "cancelled") ? page : null;
}, 30_000);
check(Boolean(stopped), "a Stopped line ends the turn");
const slow = await phone.query("commands:get", { commandId: slowId });
const stop = await phone.query("commands:get", { commandId: stopId });
check(stop?.status === "done" && slow?.status === "done", "both commands are done", [stop?.status, slow?.status]);
const idle = await until("back to idle", async () => (await phone.query("sessions:get", { sessionDocId })).status === "idle");
check(Boolean(idle), "the session is idle again");
const partial = (await events()).find((e) => e.kind === "assistant" && e.text.includes("word0"));
check(partial && !partial.text.includes("word59"), "the reply was cut short", partial?.text?.slice(-40));

// 7. The task closes.
console.log("task closes");
agent.stdin.end();
await Promise.race([agentExit, sleep(15_000)]);
const offline = await until("the session goes offline", async () => !(await phone.query("sessions:get", { sessionDocId })).online, 15_000);
check(Boolean(offline), "offline right after the process exits");

// 8. Sign out.
console.log("crok remote logout");
const logout = JSON.parse(execFileSync(CROK, ["remote", "logout", "--json"], { env, encoding: "utf8" }).trim());
check(logout.event === "signed_out" && logout.unlinked, "logout unlinks", logout);
const devices = await phone.query("devices:list", {});
check(!devices.some((d) => d.name === "E2E Mac"), "the computer is gone from the phone's devices", devices.map((d) => d.name));

// Leave nothing behind but the test person: drop the session's copy and unlink the phone.
await phone.mutation("sessions:remove", { sessionDocId });
await http.mutation("deviceAuth:logout", { refreshToken: phoneTokens.refreshToken });

await phone.close();
if (failures) console.log(`\nagent stderr tail:\n${agentErr.slice(-1500)}`);
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
