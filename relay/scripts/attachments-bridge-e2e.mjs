#!/usr/bin/env node
// End-to-end check of photos and files through a real computer (relay/DESIGN.md §2 and §4, "Photos and files"): a
// `crok agent stdio` signed in to the relay uploads the image of a prompt typed there; a phone's photo and text file
// reach the model; a session started from the phone with a photo alone runs it.
//
// Needs what scripts/bridge-e2e.mjs needs (a deployment, CROK_BIN, CROK_HOME whose default model is mock-llm.py,
// E2E_PROJECT outside the system's temp folder):
//
//   CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/home E2E_PROJECT=~/e2e-project node scripts/attachments-bridge-e2e.mjs

import { execFileSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { createInterface } from "node:readline";
import { crc32, deflateSync } from "node:zlib";
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
const person = JSON.stringify({ subject: `att-bridge-${Date.now()}`, issuer, name: "Attachments Tester", email: "att@example.com" });
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
async function until(label, fn, timeoutMs = 30_000) {
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

/** A `crok agent stdio` process (what Crok Desktop runs per task), initialized. */
async function startAgent() {
  const agent = spawn(CROK, ["agent", "stdio"], { cwd: PROJECT, env: { ...env, GROK_CLIENT_VERSION: "e2e" } });
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
      const method = message.method.replace(/^_/, "");
      if (method === "x.ai/folder_trust/request") write({ id: message.id, result: { outcome: "trust" } });
      else write({ id: message.id, error: { code: -32601, message: `unsupported: ${method}` } });
      return;
    }
    if (message.method) notifications.push({ method: message.method.replace(/^_/, ""), params: message.params });
  });
  const init = await rpc("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    _meta: { clientType: "grok_desktop", clientIdentifier: "attachments-e2e", clientVersion: "0" },
  });
  const methods = (init.authMethods ?? []).map((m) => m.id);
  if (methods.includes("xai.api_key")) await rpc("authenticate", { methodId: "xai.api_key", _meta: { headless: true } });
  return { agent, rpc, notifications, exited, stderr: () => stderr };
}

async function signIn(name) {
  const login = spawn(CROK, ["remote", "login", "--json", "--no-browser", "--server", url, "--name", name], { env });
  let stderr = "";
  login.stderr.on("data", (d) => (stderr += d));
  const done = new Promise((resolve) => login.on("exit", resolve));
  for await (const line of createInterface({ input: login.stdout })) {
    const event = JSON.parse(line);
    if (event.event === "code") approve(event.userCode);
  }
  return { code: await done, stderr };
}

const http = new ConvexHttpClient(url);
async function linkPhone() {
  const started = await http.mutation("deviceAuth:start", { kind: "phone", name: "E2E iPhone", platform: "e2e", client: "e2e 0.0" });
  approve(started.userCode);
  const tokens = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  const client = new ConvexClient(url);
  let access = tokens.accessToken;
  client.setAuth(async ({ forceRefreshToken }) => {
    if (forceRefreshToken) access = (await http.mutation("deviceAuth:refresh", { refreshToken: tokens.refreshToken })).accessToken;
    return access;
  });
  return client;
}

async function upload(client, bytes, type) {
  const { url: target } = await client.mutation("files:uploadUrl", {});
  const response = await fetch(target, { method: "POST", headers: { "Content-Type": type }, body: bytes });
  return (await response.json()).storageId;
}
async function download(target) {
  const response = await fetch(target);
  return response.ok ? Buffer.from(await response.arrayBuffer()) : null;
}

/** A real PNG (an opaque red bar), so crok's image handling and the bridge's thumbnail both decode it. */
function redPng(width, height) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 2, 0, 0, 0], 8);
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 3, Buffer.from([220, 40, 40]))]);
  const pixels = deflateSync(Buffer.concat(Array.from({ length: height }, () => row)));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", pixels),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
const png = redPng(40, 20);
const notes = Buffer.from("Release notes\nATTACHMENT-MARKER-42\n");

console.log(`Attachments bridge e2e: ${CROK}\n  relay ${url}\n  home ${HOME}\n  project ${PROJECT}`);
// A sign-in left by an earlier run belongs to that run's account: this run signs in afresh.
for (const name of ["credentials.json", "credentials-dev.json"]) rmSync(`${HOME}/remote/${name}`, { force: true });
const login = await signIn("E2E Mac");
check(login.code === 0, "crok remote login", login.stderr.slice(-400));
const phone = await linkPhone();
const { agent, rpc, exited } = await startAgent();
const { sessionId } = await rpc("session/new", { cwd: PROJECT, mcpServers: [] });

console.log("a prompt typed on the computer with an image");
const typed = await rpc("session/prompt", {
  sessionId,
  prompt: [
    { type: "text", text: "describe the attachments please" },
    { type: "image", data: png.toString("base64"), mimeType: "image/png" },
  ],
  _meta: { promptId: "local-1" },
});
check(typed.stopReason === "end_turn", "the turn runs", typed);
const row = await until("the session is mirrored", async () =>
  (await phone.query("sessions:list", {})).find((s) => s.sessionId === sessionId),
);
const sessionDocId = row?._id;
const typedItem = await until("the typed prompt's image is uploaded", async () => {
  const { events } = await phone.query("sessions:transcript", { sessionDocId });
  const item = events.find((e) => e.kind === "user" && e.text.includes("describe the attachments please"));
  return item?.attachments?.[0]?.url ? item : null;
});
const image = typedItem?.attachments?.[0];
check(image?.kind === "image" && image.mimeType === "image/png" && image.width === 40 && image.height === 20, "it is listed as a 40×20 PNG", image);
check(/^photo-\d{8}-\d{6}\.png$/.test(image?.name ?? ""), "named like a photo", image?.name);
const bytes = image?.url ? await download(image.url) : null;
check(bytes?.equals(png), "its url gives the same bytes");
const thumb = image?.thumbUrl ? await download(image.thumbUrl) : null;
check(thumb !== null && thumb[0] === 0xff && thumb[1] === 0xd8, "with a JPEG thumbnail", image?.thumbUrl);
const typedReply = await until("the model saw the image", async () => {
  const { events } = await phone.query("sessions:transcript", { sessionDocId });
  return events.find((e) => e.kind === "assistant" && e.text.includes("images="));
});
check(typedReply?.text.includes("images=1"), "the model got one image", typedReply?.text);

console.log("a photo and a text file from the phone");
const photoId = await upload(phone, png, "image/png");
const notesId = await upload(phone, notes, "text/plain");
const { commandId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId,
  text: "describe the attachments from the phone",
  clientId: crypto.randomUUID(),
  attachments: [
    { storageId: photoId, name: "photo-20261027-101500.png", width: 40, height: 20 },
    { storageId: notesId, name: "release notes.txt" },
  ],
});
const done = await until("the phone's prompt is done", async () => {
  const command = await phone.query("commands:get", { commandId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(done?.status === "done", "it runs", done?.error);
const reply = await until("the reply", async () => {
  const { events } = await phone.query("sessions:transcript", { sessionDocId });
  const user = events.findIndex((e) => e.commandId === commandId);
  return user >= 0 ? events.slice(0, user).find((e) => e.kind === "assistant" && e.text.includes("images=")) : null;
});
check(/marker=yes/.test(reply?.text ?? ""), "the text file's contents reached the model", reply?.text);
check(/images=[1-9]/.test(reply?.text ?? ""), "and the photo did", reply?.text);
const { events } = await phone.query("sessions:transcript", { sessionDocId });
const sent = events.find((e) => e.commandId === commandId);
check(
  sent?.attachments?.length === 2 && sent.attachments[1].name === "release notes.txt" && typeof sent.attachments[1].url === "string",
  "the transcript item carries both",
  sent?.attachments,
);
const saved = `${HOME}/remote/attachments/${sessionId}/${commandId}`;
check(existsSync(`${saved}/release_notes.txt`), "the file is saved on the computer", existsSync(saved) ? readdirSync(saved) : saved);

console.log("history read back from disk");
const updates = await rpc("_x.ai/session/updates", { sessionId, cwd: PROJECT, turnIndex: 5 });
const chunks = (updates?.updates ?? []).filter((u) => u.params?.update?.sessionUpdate === "user_message_chunk");
check(
  chunks.some((u) => u.params.update.content?.type === "image" && typeof u.params.update.content.data === "string"),
  "crok stores a prompt's image as an image chunk (what the bridge reads back)",
  chunks.map((u) => u.params.update.content?.type),
);

console.log("a new session from the phone, a photo alone");
const created = await phone.mutation("sessions:create", {
  deviceId: row.deviceId,
  path: PROJECT,
  clientId: crypto.randomUUID(),
  attachments: [{ storageId: await upload(phone, png, "image/png"), name: "photo.png", width: 40, height: 20 }],
});
const createdDone = await until("the new session's prompt is done", async () => {
  const command = await phone.query("commands:get", { commandId: created.commandId });
  return command?.status === "done" || command?.status === "failed" ? command : null;
}, 60_000);
check(createdDone?.status === "done", "it runs", createdDone?.error);
const createdEvents =
  (await until("the new session's transcript", async () => {
    const { events: items } = await phone.query("sessions:transcript", { sessionDocId: created.sessionDocId });
    return items.some((e) => e.kind === "assistant") ? items : null;
  })) ?? [];
check(createdEvents.some((e) => e.kind === "user" && e.text === "" && e.attachments?.[0]?.kind === "image"), "its prompt is the photo alone");
check(createdEvents.some((e) => e.kind === "assistant" && e.text.startsWith("Hi from mock")), "and the model answers", createdEvents.map((e) => e.text));
const createdRow = await until("the new session's preview", async () => {
  const listed = (await phone.query("sessions:list", {})).find((s) => s._id === created.sessionDocId);
  return listed?.preview ? listed : null;
});
check(createdRow?.preview === "🖼 photo.png" || createdRow?.preview?.startsWith("Hi from mock"), "the list's preview", createdRow?.preview);

agent.stdin.end();
await Promise.race([exited, sleep(10_000)]);
await phone.close();
console.log(failures === 0 ? "All attachment bridge checks passed." : `${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
