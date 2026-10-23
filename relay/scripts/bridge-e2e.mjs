#!/usr/bin/env node
// End-to-end check of the computer side: a real `crok` signs in with `crok remote login`, a `crok agent stdio` (the
// process Crok Desktop runs per task) mirrors its session, and a "phone" reads it, sends a prompt, asks for session
// info, stops a running turn, and sees the session go offline when the process exits.
//
// Needs: a running deployment (`npx convex dev`, with CLERK_JWT_ISSUER_DOMAIN set to any value), a crok binary, and a
// model the agent can call (an OpenAI-compatible server; see the config below).
//
//   CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/home E2E_PROJECT=~/e2e-project node scripts/bridge-e2e.mjs
//
// CROK_HOME/config.toml should point the default model at that server. E2E_PROJECT must not be under the system's
// temp folder (crok leaves sessions there out of the list of every session). It also checks that a session from before
// the sign-in is listed, grouped with the running one, and that opening it fetches its transcript from disk.

import { execFileSync, spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
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

/**
 * A `crok agent stdio` process (what Crok Desktop runs per task), initialized and signed in to its model. Permission
 * requests are held in `permissions` for the test to answer (`answer(request, optionId)`), not refused.
 */
async function startAgent(agentEnv = env) {
  const agent = spawn(CROK, ["agent", "stdio"], { cwd: PROJECT, env: { ...agentEnv, GROK_CLIENT_VERSION: "e2e" } });
  const permissions = [];
  let stderr = "";
  agent.stderr.on("data", (d) => (stderr += d));
  const exited = new Promise((resolve) => agent.on("exit", resolve));
  let nextId = 1;
  const pending = new Map();
  const notifications = [];
  const write = (obj) => agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...obj })}\n`);
  const rpc = (method, params, timeoutMs = 120_000) => {
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
      // Requests from the agent: trust the folder, refuse everything else.
      const method = message.method.replace(/^_/, "");
      if (method === "x.ai/folder_trust/request") write({ id: message.id, result: { outcome: "trust" } });
      else if (method === "session/request_permission") permissions.push({ id: message.id, params: message.params });
      else write({ id: message.id, error: { code: -32601, message: `unsupported: ${method}` } });
      return;
    }
    if (message.method) notifications.push({ method: message.method.replace(/^_/, ""), params: message.params });
  });
  const answer = (request, optionId) =>
    write({
      id: request.id,
      result: { outcome: optionId ? { outcome: "selected", optionId } : { outcome: "cancelled" } },
    });
  const notify = (method, params) => write({ method, params });
  const init = await rpc("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    _meta: { clientType: "grok_desktop", clientIdentifier: "bridge-e2e", clientVersion: "0" },
  });
  const methods = (init.authMethods ?? []).map((m) => m.id);
  if (methods.includes("xai.api_key")) await rpc("authenticate", { methodId: "xai.api_key", _meta: { headless: true } });
  return { agent, rpc, notify, notifications, permissions, answer, exited, stderr: () => stderr };
}

// The file the mock model's "marker command" touches (start mock-llm.py with the same E2E_MARKER).
const marker = process.env.E2E_MARKER ?? "/tmp/.e2e-permission-marker";
const markerName = marker.split("/").pop();
rmSync(marker, { force: true });
/** The phone's choice for a pending request: the first "allow once" option. */
const allowOnce = (pending) => pending.options.find((o) => o.kind === "allow_once")?.optionId ?? pending.options[0]?.optionId;

console.log(`Bridge e2e: ${CROK}\n  relay ${url}\n  home ${HOME}\n  project ${PROJECT}`);

// 0. A session from before this computer was signed in: on disk, run by nobody. The catalog must list it.
console.log("an older session, signed out");
const older = await startAgent();
const { sessionId: olderId } = await older.rpc("session/new", { cwd: PROJECT, mcpServers: [] });
const olderTurn = await older.rpc("session/prompt", {
  sessionId: olderId,
  prompt: [{ type: "text", text: "an older question from yesterday" }],
  _meta: { promptId: "older-1" },
});
check(olderTurn.stopReason === "end_turn", "an older session runs while signed out", olderTurn);
older.agent.stdin.end();
await Promise.race([older.exited, sleep(15_000)]);

/** `crok remote login` for a computer, approved as the test person; returns the exit code, events and stderr. */
async function signIn(loginEnv, name) {
  const login = spawn(CROK, ["remote", "login", "--json", "--no-browser", "--server", url, "--name", name], { env: loginEnv });
  const events = [];
  let stderr = "";
  login.stderr.on("data", (d) => (stderr += d));
  const done = new Promise((resolve) => login.on("exit", resolve));
  for await (const line of createInterface({ input: login.stdout })) {
    const event = JSON.parse(line);
    events.push(event);
    if (event.event === "code") approve(event.userCode);
  }
  return { code: await done, events, stderr };
}

// 1. `crok remote login` signs this computer in.
console.log("crok remote login");
const { code: loginCode, events: loginEvents, stderr: loginErr } = await signIn(env, "E2E Mac");
check(loginCode === 0, "login exits 0", loginErr.slice(-500));
check(loginEvents[0]?.event === "code" && /^[B-Z]{4}-[B-Z]{4}$/.test(loginEvents[0].userCode), "prints the code first");
check(loginEvents.at(-1)?.event === "signed_in" && loginEvents.at(-1).account.name === "Bridge Tester", "then signed_in with the account");
const credentialsPath = `${HOME}/remote/credentials.json`;
check((statSync(credentialsPath).mode & 0o777) === 0o600, "credentials are 0600");
const status = JSON.parse(execFileSync(CROK, ["remote", "status", "--json"], { env, encoding: "utf8" }).trim());
check(status.signedIn && status.reachable && status.deviceName === "E2E Mac", "crok remote status", status);

// 2. A task process, driven like Crok Desktop drives it.
console.log("crok agent stdio");
const {
  agent,
  rpc,
  notifications,
  permissions,
  answer: answerHere,
  exited: agentExit,
  stderr: agentStderr,
} = await startAgent();
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

// 3b. Every session on disk, grouped by project; an older one's transcript is read from disk when opened.
console.log("every session, by project");
const project = await until("the older session is listed", async () => {
  const groups = await phone.query("sessions:groups", {});
  return groups.find((g) => g.sessions.some((s) => s.sessionId === olderId));
});
const olderRow = project?.sessions.find((s) => s.sessionId === olderId);
check(
  project?.sessions.some((s) => s.sessionId === sessionId) && olderRow && !olderRow.online && olderRow.historyState === "none",
  "the older session sits in the same project as the running one, offline, its transcript not here yet",
  project && { name: project.name, sessions: project.sessions.map((s) => [s.title, s.online, s.historyState]) },
);
check(project?.deviceName === "E2E Mac", "the project is under this computer", project?.deviceName);
await phone.mutation("sessions:watch", { sessionDocId: olderRow?._id });
const olderEvents = await until("its transcript arrives", async () => {
  const page = (await phone.query("sessions:events", { sessionDocId: olderRow._id, paginationOpts: { numItems: 50, cursor: null } })).page;
  return page.some((e) => e.kind === "assistant" && e.text.includes("Hi from mock")) ? page.reverse() : null;
}, 30_000);
check(
  olderEvents?.[0]?.kind === "user" && olderEvents[0].text === "an older question from yesterday",
  "the transcript was read from disk by the running crok",
  olderEvents?.map((e) => [e.kind, e.text.slice(0, 40)]),
);
const olderNow = await phone.query("sessions:get", { sessionDocId: olderRow?._id });
check(olderNow?.historyState === "ready" && !olderNow.online, "it is marked loaded, and nobody runs it", olderNow?.historyState);

// 3c. A prompt for it all the same: the running crok opens the session (out of its front end's sight) and runs it.
console.log("a prompt for a session nobody runs");
const { commandId: olderPromptId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId: olderRow._id,
  text: "and one more thing",
  clientId: crypto.randomUUID(),
});
const olderPrompt = await until("the prompt to the older session finishes", async () => {
  const command = await phone.query("commands:get", { commandId: olderPromptId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(olderPrompt?.status === "done", "it runs to the end (two ticks)", olderPrompt);
const olderReplied = await until("its reply is mirrored", async () => {
  const page = (await phone.query("sessions:events", { sessionDocId: olderRow._id, paginationOpts: { numItems: 50, cursor: null } })).page.reverse();
  const prompt = page.find((e) => e.commandId === olderPromptId);
  return prompt && page.some((e) => e.kind === "assistant" && e.seq > prompt.seq && e.text.includes("Hi from mock")) ? page : null;
}, 30_000);
check(
  olderReplied?.filter((e) => e.kind === "user").map((e) => e.text).join(" | ") === "an older question from yesterday | and one more thing",
  "the transcript holds the old turn and the new one, once each",
  olderReplied?.map((e) => [e.kind, e.text.slice(0, 30)]),
);
const olderLive = await phone.query("sessions:get", { sessionDocId: olderRow._id });
check(olderLive?.online && olderLive.status === "idle", "the session now runs on the computer, idle", olderLive && [olderLive.online, olderLive.status]);
// Its permission requests go to the other devices only: nobody on this computer sees the session.
const { commandId: olderMarkerId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId: olderRow._id,
  text: "please run the marker command",
  clientId: crypto.randomUUID(),
});
const olderAsk = await until("its permission request reaches the relay", async () => (await phone.query("sessions:get", { sessionDocId: olderRow._id })).pending, 60_000);
check(
  olderAsk?.kind === "permission" && (olderAsk.detail ?? "").includes(markerName) && olderAsk.options.length >= 2,
  "the phone sees what the hidden session asks, with its choices",
  olderAsk,
);
check((await phone.query("sessions:get", { sessionDocId: olderRow._id })).status === "waiting", "the session shows it waits");
await phone.mutation("commands:answer", { sessionDocId: olderRow._id, interactionId: olderAsk.id, optionId: allowOnce(olderAsk) });
const olderMarker = await until("the allowed turn ends", async () => {
  const command = await phone.query("commands:get", { commandId: olderMarkerId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(olderMarker?.status === "done" && existsSync(marker), "allowed from the phone, the command ran", olderMarker);
check((await phone.query("sessions:get", { sessionDocId: olderRow._id })).pending === null, "nothing is pending any more");
rmSync(marker, { force: true });
check(
  !notifications.some((n) => n.params?.sessionId === olderId) && !permissions.some((p) => p.params?.sessionId === olderId),
  "the computer's front end heard nothing of it, requests included",
  notifications.filter((n) => n.params?.sessionId === olderId).map((n) => n.method),
);

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
const previewRow = await until("the list shows the reply", async () => {
  const listed = (await phone.query("sessions:list", {})).find((s) => s._id === sessionDocId);
  // Not the prompt the turn started with: the preview waits for the turn's end, then shows the reply.
  return listed?.previewKind === "assistant" && listed.preview?.startsWith("Hi from mock") ? listed : null;
});
check(Boolean(previewRow), "a finished turn leaves its reply as the list's preview", previewRow?.preview);

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
// 5b. What the computer can run, the session's slash commands, and changing the model from the phone.
console.log("models, thinking level and slash commands");
const withModels = await until("the computer's models are on the relay", async () => {
  const detail = await phone.query("sessions:get", { sessionDocId });
  return detail.models?.length ? detail : null;
});
check(
  withModels?.models.some((m) => m.id === withModels.model),
  "sessions:get lists the computer's models, the session's among them",
  withModels && { model: withModels.model, models: withModels.models.map((m) => m.id) },
);
const slash = await until("the session's slash commands are on the relay", async () => {
  const list = await phone.query("sessions:commands", { sessionDocId });
  return list.source === "session" && list.commands.length ? list : null;
});
check(slash?.commands.some((c) => c.name === "compact"), "crok's own commands are listed", slash?.commands.map((c) => c.name));
const currentModel = withModels?.model;
const { commandId: modelCommandId } = await phone.mutation("commands:setConfig", {
  sessionDocId,
  configId: "model",
  value: currentModel,
});
const modelSet = await until("the model change is applied", async () => {
  const command = await phone.query("commands:get", { commandId: modelCommandId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
});
check(modelSet?.status === "done" && modelSet.result?.model === currentModel, "the computer applies the model", modelSet);
const effortChoice = withModels?.models.find((m) => m.id === currentModel)?.efforts.find((e) => (e.value ?? e.id) !== withModels.effort);
if (effortChoice) {
  const { commandId: effortCommandId } = await phone.mutation("commands:setConfig", {
    sessionDocId,
    configId: "reasoning_effort",
    value: effortChoice.id,
  });
  const effortSet = await until("the thinking level is applied", async () => {
    const command = await phone.query("commands:get", { commandId: effortCommandId });
    return command?.status === "done" || command?.status === "failed" ? command : null;
  });
  check(effortSet?.status === "done", "the computer applies the thinking level", effortSet);
  const effortRow = await until("the session reports it", async () => {
    const detail = await phone.query("sessions:get", { sessionDocId });
    return detail.effort === (effortChoice.value ?? effortChoice.id) ? detail : null;
  });
  check(Boolean(effortRow), "the session's effort follows");
} else {
  console.log("  --  (the model has no other thinking level; skipped)");
}

// 5c. A new session in this project, started from the phone: a crok here opens it and runs the prompt.
console.log("a new session from the phone");
const computerDevice = (await phone.query("devices:list", {})).find((d) => d.name === "E2E Mac");
const deviceModels = await phone.query("devices:models", { deviceId: computerDevice?._id });
check(deviceModels?.length > 0, "the phone lists what that computer can run", deviceModels?.map((m) => m.id));
// The model this computer's session runs (the mock one), with a thinking level when it has one: chosen before the
// session exists.
const setupModel = deviceModels?.find((m) => m.id === withModels?.model) ?? deviceModels?.[0];
const setupEffort = setupModel?.efforts?.[0];
const created = await phone.mutation("sessions:create", {
  deviceId: computerDevice?._id,
  path: PROJECT,
  text: "hello from a new phone session",
  model: setupModel?.id,
  effort: setupEffort?.id,
  clientId: crypto.randomUUID(),
});
const createdRow = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(
  createdRow.starting && createdRow.title === "hello from a new phone session" &&
    (!setupModel || createdRow.model === setupModel.id) &&
    (!setupEffort || createdRow.effort === (setupEffort.value ?? setupEffort.id)),
  "it is listed at once, starting, with the chosen model and thinking level",
  createdRow,
);
const createdDone = await until("its first prompt finishes", async () => {
  const command = await phone.query("commands:get", { commandId: created.commandId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(createdDone?.status === "done", "the computer started it and ran the prompt", createdDone);
const createdNow = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(!createdNow.starting && createdNow.online && /^[0-9a-f-]{36}$/.test(createdNow.sessionId), "it has crok's own id now", createdNow.sessionId);
check(!setupModel || createdNow.model === setupModel.id, "it runs with the model chosen before it started", createdNow);
const createdReply = await until("its reply is mirrored", async () => {
  const page = await phone.query("sessions:events", { sessionDocId: created.sessionDocId, paginationOpts: { numItems: 20, cursor: null } });
  // A new session's first prompt reaches the model wrapped in its opening context, so the mock's echo differs.
  return page.page.some((e) => e.kind === "assistant" && e.text.includes("Hi from mock")) ? page.page : null;
});
check(Boolean(createdReply), "the reply is in its transcript");
check(
  createdReply?.some((e) => e.kind === "user" && e.commandId === created.commandId),
  "the prompt is in it as the phone's, matching its bubble",
);
check(
  !notifications.some((n) => n.method === "session/update" && n.params?.sessionId === createdNow.sessionId && n.params?.update?.sessionUpdate === "agent_message_chunk"),
  "the task's own front end does not show it",
);

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

// 6b. A permission request in a session the computer shows: the computer and the phone are both asked; the phone wins.
console.log("permission, answered on the phone");
const { commandId: markerId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId,
  text: "please run the marker command",
  clientId: crypto.randomUUID(),
});
const asked = await until("the request is on the relay", async () => (await phone.query("sessions:get", { sessionDocId })).pending, 60_000);
check(asked?.kind === "permission" && (asked.detail ?? "").includes(markerName), "the phone sees what is asked", asked);
const askedHere = permissions.find((p) => p.params?.sessionId === sessionId);
check(Boolean(askedHere), "the computer is asked too");
await phone.mutation("commands:answer", { sessionDocId, interactionId: asked.id, optionId: allowOnce(asked) });
const markerDone = await until("the allowed turn ends", async () => {
  const command = await phone.query("commands:get", { commandId: markerId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(markerDone?.status === "done" && existsSync(marker), "the command ran once the phone allowed it", markerDone);
check(
  notifications.some((n) => n.method === "x.ai/remote/permission_resolved" && n.params?.sessionId === sessionId),
  "the computer is told to drop its own prompt",
);
if (askedHere) answerHere(askedHere, null);
rmSync(marker, { force: true });

// 6c. A second computer of the same person lists this one's sessions, opens one and works in it.
console.log("a second computer");
const home2 = `${HOME}-second`;
rmSync(home2, { recursive: true, force: true });
mkdirSync(home2, { recursive: true });
cpSync(`${HOME}/config.toml`, `${home2}/config.toml`);
const env2 = { ...env, CROK_HOME: home2 };
const secondLogin = await signIn(env2, "E2E Mac 2");
check(secondLogin.code === 0, "the second computer signs in", secondLogin.stderr.slice(-300));
const second = await startAgent(env2);
const remoteId = `relay:${sessionDocId}`;
const listed = await until("this computer's sessions are listed there", async () => {
  const list = await second.rpc("_x.ai/remote/sessions", { watch: true });
  const here = list.computers?.find((c) => c.deviceName === "E2E Mac");
  return here?.projects.flatMap((p) => p.sessions).some((s) => s.sessionId === remoteId) ? list : null;
}, 30_000);
check(
  listed && !listed.computers.some((c) => c.deviceName === "E2E Mac 2"),
  "it lists the other computer's sessions, not its own",
  listed?.computers.map((c) => c.deviceName),
);
const firstDeviceId = listed?.computers.find((c) => c.deviceName === "E2E Mac")?.deviceId;
const listedModels = await second.rpc("_x.ai/remote/models", { deviceId: firstDeviceId });
check(
  listedModels?.models?.length > 0 &&
    listedModels.availableModels?.length === listedModels.models.length &&
    listedModels.availableModels.every((m) => m.modelId && m._meta),
  "a new session there can choose from that computer's models before it exists (x.ai/remote/models)",
  listedModels && { models: listedModels.models?.map((m) => m.id), available: listedModels.availableModels?.length },
);
const remoteLoad = await second.rpc("session/load", { sessionId: remoteId, cwd: PROJECT, mcpServers: [] });
check(
  remoteLoad?.models?.availableModels?.length > 0 && remoteLoad.configOptions?.some((o) => o.id === "model"),
  "opening it offers that computer's models",
  remoteLoad && { models: remoteLoad.models, options: remoteLoad.configOptions?.map((o) => o.id) },
);
const remoteModel = remoteLoad?.models?.currentModelId;
const remoteSet = await second.rpc("session/set_config_option", { sessionId: remoteId, configId: "model", value: remoteModel });
check(
  remoteSet?.configOptions?.find((o) => o.id === "model")?.currentValue === remoteModel,
  "picking its model there is applied here",
  remoteSet,
);
const replayed = second.notifications.filter((n) => n.method === "session/update" && n.params.sessionId === remoteId);
check(
  replayed.some(
    (n) => n.params._meta?.isReplay && n.params.update.sessionUpdate === "user_message_chunk" && n.params.update.content.text === "hello there from the desk",
  ),
  "opening it replays its transcript",
  replayed.length,
);
let mark = second.notifications.length;
const turn = await second.rpc("session/prompt", {
  sessionId: remoteId,
  prompt: [{ type: "text", text: "hello from the other desk" }],
  _meta: { promptId: "second-1" },
});
check(turn.stopReason === "end_turn", "a prompt there returns when its turn ends here", turn);
const streamed = second.notifications.slice(mark).filter((n) => n.params?.sessionId === remoteId);
const reply = streamed
  .filter((n) => n.params.update?.sessionUpdate === "agent_message_chunk" && n.params._meta?.promptId === "second-1")
  .map((n) => n.params.update.content.text)
  .join("");
check(reply.includes("Hi from mock"), "the reply streams there, stamped with its prompt", reply);
const ended = await until("its end arrives", async () =>
  second.notifications.slice(mark).some((n) => n.method === "x.ai/session/prompt_complete" && n.params.promptId === "second-1"),
);
check(Boolean(ended), "and its end");
check(
  (await events()).some((e) => e.kind === "user" && e.text === "hello from the other desk" && e.fromLabel === "E2E Mac 2"),
  "this computer ran it as a prompt from the second",
);
mark = second.notifications.length;
await rpc("session/prompt", { sessionId, prompt: [{ type: "text", text: "typed at the first desk" }], _meta: { promptId: "local-2" } });
const typedSeen = await until("a turn typed here shows there", async () => {
  const after = second.notifications.slice(mark);
  return after.some((n) => n.method === "x.ai/remote/prompt" && n.params.text === "typed at the first desk") &&
    after.some((n) => n.method === "x.ai/session/prompt_complete" && n.params.sessionId === remoteId)
    ? after
    : null;
}, 30_000);
check(Boolean(typedSeen), "a turn typed on this computer streams to the second, start to end");
const markerTurn = second.rpc("session/prompt", {
  sessionId: remoteId,
  prompt: [{ type: "text", text: "please run the marker command again" }],
  _meta: { promptId: "second-2" },
});
const remoteAsk = await until("the second computer is asked", async () => second.permissions.find((p) => p.params?.sessionId === remoteId), 60_000);
check(Boolean(remoteAsk?.params?.toolCall?.title), "the second computer is asked as for a session of its own", remoteAsk?.params);
second.answer(remoteAsk, remoteAsk?.params?.options?.find((o) => o.kind === "allow_once")?.optionId);
const markerTurnDone = await markerTurn;
check(markerTurnDone.stopReason === "end_turn" && existsSync(marker), "allowed there, the command ran here", markerTurnDone);
rmSync(marker, { force: true });
for (const held of permissions.filter((p) => p.params?.sessionId === sessionId && p !== askedHere)) answerHere(held, null);
const slowThere = second.rpc("session/prompt", {
  sessionId: remoteId,
  prompt: [{ type: "text", text: "be slow over there" }],
  _meta: { promptId: "second-3" },
});
await until("the slow turn streams there", async () =>
  second.notifications.some((n) => n.params?._meta?.promptId === "second-3" && (n.params.update?.content?.text ?? "").includes("word2")),
30_000);
second.notify("session/cancel", { sessionId: remoteId });
const slowThereDone = await slowThere;
check(slowThereDone.stopReason === "cancelled", "Stop there stops the turn here", slowThereDone);
await until("this session is idle again", async () => (await phone.query("sessions:get", { sessionDocId })).status === "idle");
const remoteNew = await second.rpc("_x.ai/remote/new_session", {
  deviceId: computerDevice?._id,
  path: PROJECT,
  text: "hello new from the other desk",
  model: remoteModel,
});
check(remoteNew?.sessionId?.startsWith("relay:"), "the second computer starts a session here", remoteNew);
const remoteNewDoc = remoteNew?.sessionId?.slice("relay:".length);
const remoteNewReply = await until("the new session runs here", async () => {
  const page = await phone.query("sessions:events", { sessionDocId: remoteNewDoc, paginationOpts: { numItems: 20, cursor: null } });
  return page.page.some((e) => e.kind === "user" && e.text === "hello new from the other desk") &&
    page.page.some((e) => e.kind === "assistant" && e.text.includes("Hi from mock"))
    ? page
    : null;
}, 60_000);
check(Boolean(remoteNewReply), "its first prompt ran on this computer");
const remoteNewDetail = await phone.query("sessions:get", { sessionDocId: remoteNewDoc });
check(remoteNewDetail.model === remoteModel, "with the model the other computer picked", remoteNewDetail.model);
second.agent.stdin.end();
await Promise.race([second.exited, sleep(15_000)]);
execFileSync(CROK, ["remote", "logout", "--json"], { env: env2, encoding: "utf8" });
rmSync(home2, { recursive: true, force: true });

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

// Leave nothing behind but the test person: drop the sessions' copies and unlink the phone.
await phone.mutation("sessions:remove", { sessionDocId });
for (const doc of [created.sessionDocId, remoteNewDoc]) {
  if (doc) await phone.mutation("sessions:remove", { sessionDocId: doc }).catch(() => {});
}
if (olderRow) await phone.mutation("sessions:remove", { sessionDocId: olderRow._id });
await http.mutation("deviceAuth:logout", { refreshToken: phoneTokens.refreshToken });

await phone.close();
if (failures) console.log(`\nagent stderr tail:\n${agentStderr().slice(-1500)}`);
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
