#!/usr/bin/env node
// A fake crok computer for checking the phone apps and the web app against a relay without running crok. Run with
// cwd = relay/ (so `convex/browser` and `npx convex run` resolve):
//
//   cd relay && node scripts/fake-computer.mjs
//
// It signs in as FAKE_COMPUTER_AS (an identity for `npx convex run --identity`, default the "iOS Tester" the app tests
// use); sign the phone in as the same person to see its session.
//
// It links a "computer" device for the test person (approving with `npx convex run --identity`), mirrors one session
// with a short transcript, and answers the phone: prompts get a user event + a reply streamed in chunks, Stop cancels
// the running reply, info returns usage numbers. A prompt containing "slow" streams slowly so Stop can be tried. It
// also lists two models with thinking levels and a few slash commands, applies model and thinking-level changes, and
// starts new sessions asked for from other devices (`sessions:create`).

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(path.join(process.cwd(), "package.json"));
const { ConvexClient, ConvexHttpClient } = require("convex/browser");

const env = Object.fromEntries(
  readFileSync(".env.local", "utf8")
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const url = process.env.CONVEX_URL ?? env.NEXT_PUBLIC_CONVEX_URL;
const issuer = execFileSync("npx", ["convex", "env", "get", "CLERK_JWT_ISSUER_DOMAIN"], { encoding: "utf8" }).trim();
const person =
  process.env.FAKE_COMPUTER_AS ??
  JSON.stringify({ subject: "ios-tester", issuer, name: "iOS Tester", email: "ios@example.com" });
const log = (...args) => console.log(new Date().toISOString().slice(11, 23), ...args);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const http = new ConvexHttpClient(url);
const started = await http.mutation("deviceAuth:start", {
  kind: "computer",
  name: "Test MacBook",
  platform: "macOS 26.1 arm64",
  client: "crok 1.0.45 (fake)",
});
execFileSync("npx", ["convex", "run", "deviceAuth:approve", JSON.stringify({ userCode: started.userCode }), "--identity", person], {
  encoding: "utf8",
});
const tokens = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
if (tokens.status !== "approved") throw new Error(`computer not approved: ${JSON.stringify(tokens)}`);
log("computer linked", tokens.deviceId);

const client = new ConvexClient(url);
let access = tokens.accessToken;
client.setAuth(async ({ forceRefreshToken }) => {
  if (forceRefreshToken) {
    access = (await http.mutation("deviceAuth:refresh", { refreshToken: tokens.refreshToken })).accessToken;
  }
  return access;
});

const { hostId } = await client.mutation("bridge:connect", {
  instanceId: `fake-${process.pid}`,
  app: "tui",
  appVersion: "crok 1.0.45 (fake)",
  pid: process.pid,
  canAdopt: true,
  features: ["create", "config"],
});
const efforts = [
  { id: "low", name: "Low", value: "low" },
  { id: "medium", name: "Medium", value: "medium" },
  { id: "high", name: "High", value: "high" },
];
const models = [
  { id: "grok-code-fast-1", name: "Grok Code Fast", description: "Fast and cheap for everyday coding", efforts, defaultEffort: "high" },
  { id: "grok-4", name: "Grok 4", description: "The most capable model", efforts: [...efforts, { id: "xhigh", name: "Extra high", value: "xhigh" }], defaultEffort: "medium" },
  { id: "grok-3-mini", name: "Grok 3 Mini", efforts: [] },
];
const slashCommands = [
  { name: "compact", description: "Compress conversation history to save context window" },
  { name: "context", description: "Show context window usage and session stats" },
  { name: "memory", description: "Browse, view, and manage your memories" },
  { name: "review-pr", description: "Review a pull request", hint: "<number>" },
];
await client.mutation("bridge:setModels", { hostId, models });
setInterval(() => client.mutation("bridge:heartbeat", { hostId }).catch((e) => log("heartbeat", e.message)), 30_000);

const sessionId = `0199f1a2-${Date.now().toString(16)}-7c1d-9a10-fake`;
const now = Date.now();
const plan = [
  { content: "Reproduce the redirect loop", status: "completed" },
  { content: "Find where the return URL is lost", status: "completed" },
  { content: "Keep the return URL through sign-in", status: "in_progress" },
  { content: "Add a regression test", status: "pending" },
];
let usage = {
  inputTokens: 52_300,
  outputTokens: 4_100,
  cachedTokens: 40_000,
  reasoningTokens: 900,
  costUsd: 0.1234,
  contextTokens: 31_000,
  contextWindow: 256_000,
};
const { sessionDocId } = await client.mutation("bridge:upsertSession", {
  hostId,
  sessionId,
  fields: {
    title: "Fix the login redirect",
    cwd: "/Users/ios-tester/src/webapp",
    model: "grok-code-fast-1",
    effort: "high",
    gitBranch: "fix/login-redirect",
    status: "idle",
    preview: "The return URL is dropped by the callback handler.",
    previewKind: "assistant",
    plan,
    usage,
    createdAt: now - 3_600_000,
  },
});
await client.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    { key: "u0", kind: "user", text: "After signing in, users land on / instead of the page they came from. Why?", origin: "local", at: now - 3_500_000 },
    { key: "t0", kind: "thought", text: "Check how the callback route reads `returnTo`.", at: now - 3_490_000 },
    { key: "r0", kind: "tool", title: "Read app/auth/callback.ts", toolKind: "read", status: "completed", text: "app/auth/callback.ts", at: now - 3_480_000 },
    { key: "a0", kind: "assistant", text: "The return URL is dropped by the **callback handler**: it reads `returnTo` from the query, but the provider sends it back in `state`.\n\n```ts\nconst returnTo = searchParams.get(\"state\") ?? \"/\";\n```", at: now - 3_470_000 },
    { key: "s0", kind: "system", text: "", status: "end_turn", at: now - 3_469_000 },
  ],
});
log("session mirrored", sessionDocId);
await client.mutation("bridge:setCommands", { hostId, sessionId, commands: slashCommands });

const handled = new Set();
let turn = null; // { cancelled, promptId }
let messages = 5;
/** The sessions this computer runs, by relay id: the first one and any started from another device. */
const sessions = new Map([[sessionDocId, { sessionId, sessionDocId, model: "grok-code-fast-1", effort: "high" }]]);

async function prompt(command, session = sessions.get(command.sessionDocId) ?? sessions.get(sessionDocId)) {
  const { sessionId, sessionDocId } = session;
  while (turn) await sleep(200); // queued behind the running turn (status stays "delivered")
  turn = { cancelled: false, promptId: command._id };
  const t = Date.now();
  await client.mutation("bridge:pushEvents", {
    hostId,
    sessionDocId,
    events: [{ key: `u-${command._id}`, kind: "user", text: command.text, origin: "remote", commandId: command._id, fromLabel: command.fromLabel, at: t }],
  });
  await client.mutation("bridge:upsertSession", {
    hostId,
    sessionId,
    fields: { status: "running", preview: command.text, previewKind: "user", lastActivityAt: t },
  });
  await sleep(600);
  await client.mutation("bridge:pushEvents", {
    hostId,
    sessionDocId,
    events: [{ key: `r-${command._id}`, kind: "tool", title: "Run npm test -- auth", toolKind: "execute", status: "in_progress", text: "npm test -- auth", at: Date.now() }],
  });
  await sleep(900);
  await client.mutation("bridge:pushEvents", {
    hostId,
    sessionDocId,
    events: [{ key: `r-${command._id}`, kind: "tool", title: "Run npm test -- auth", toolKind: "execute", status: "completed", text: "npm test -- auth\n✓ 14 tests passed", at: Date.now() }],
  });
  const slow = /slow/i.test(command.text);
  const reply =
    `You asked: “${command.text}”. I ran the auth tests: **14 passed**.\n\n` +
    "- the callback now reads `returnTo` from `state`\n- a regression test covers the deep link\n\n" +
    "Next I would add the same check to the sign-up flow. " +
    (slow ? "This reply is long on purpose so Stop can interrupt it. ".repeat(6) : "") +
    "Done for now.";
  const words = reply.split(" ");
  const chunk = slow ? 3 : 8;
  let text = "";
  for (let i = 0; i < words.length && !turn.cancelled; i += chunk) {
    text = words.slice(0, i + chunk).join(" ");
    await client.mutation("bridge:pushEvents", {
      hostId,
      sessionDocId,
      events: [{ key: `a-${command._id}`, kind: "assistant", text, at: Date.now() }],
    });
    await sleep(slow ? 800 : 700);
  }
  messages += 3;
  if (turn.cancelled) {
    await client.mutation("bridge:pushEvents", {
      hostId,
      sessionDocId,
      events: [{ key: `s-${command._id}`, kind: "system", text: "", status: "cancelled", at: Date.now() }],
    });
    log("turn cancelled", command._id);
  } else {
    await client.mutation("bridge:pushEvents", {
      hostId,
      sessionDocId,
      events: [{ key: `s-${command._id}`, kind: "system", text: "", status: "end_turn", at: Date.now() }],
    });
  }
  usage = { ...usage, inputTokens: usage.inputTokens + 4_000, outputTokens: usage.outputTokens + 300, costUsd: usage.costUsd + 0.01, contextTokens: usage.contextTokens + 2_000 };
  await client.mutation("bridge:upsertSession", {
    hostId,
    sessionId,
    fields: { status: "idle", preview: text, previewKind: "assistant", usage, lastActivityAt: Date.now() },
  });
  await client.mutation("bridge:completeCommand", { hostId, commandId: command._id, status: "done" });
  log("prompt done", command._id);
  turn = null;
}

async function handle(command) {
  if (handled.has(command._id)) return;
  handled.add(command._id);
  const claimed = await client.mutation("bridge:claimCommand", { hostId, commandId: command._id });
  log("claimed", command.type, command._id, claimed, command.text ?? "");
  if (!claimed) return;
  if (command.type === "prompt") {
    await prompt(command);
  } else if (command.type === "create") {
    // A new session asked for from another device: open it, give the relay its id, then run the first prompt.
    await sleep(400);
    const created = { sessionId: `0199f1a3-${Date.now().toString(16)}-7c1d-9a10-fake`, sessionDocId: command.sessionDocId, model: "grok-code-fast-1", effort: "high" };
    await client.mutation("bridge:bindSession", { hostId, sessionDocId: command.sessionDocId, sessionId: created.sessionId });
    sessions.set(command.sessionDocId, created);
    await client.mutation("bridge:upsertSession", {
      hostId,
      sessionId: created.sessionId,
      fields: { cwd: command.cwd, model: created.model, effort: created.effort, status: command.text ? "running" : "idle" },
    });
    await client.mutation("bridge:setCommands", { hostId, sessionId: created.sessionId, commands: slashCommands });
    log("session started", created.sessionId, "in", command.cwd);
    if (command.text) await prompt(command, created);
    else await client.mutation("bridge:completeCommand", { hostId, commandId: command._id, status: "done", result: { sessionId: created.sessionId } });
  } else if (command.type === "config") {
    const session = sessions.get(command.sessionDocId) ?? sessions.get(sessionDocId);
    await sleep(500);
    if (command.configId === "model") {
      const model = models.find((m) => m.id === command.text);
      session.model = command.text;
      // A model without that thinking level falls back to its default, as crok does.
      if (!model?.efforts.some((e) => e.value === session.effort)) {
        session.effort = model?.efforts.find((e) => e.id === model.defaultEffort)?.value ?? undefined;
      }
    } else {
      session.effort = command.text;
    }
    await client.mutation("bridge:upsertSession", {
      hostId,
      sessionId: session.sessionId,
      fields: { model: session.model, ...(session.effort ? { effort: session.effort } : {}) },
    });
    await client.mutation("bridge:completeCommand", {
      hostId,
      commandId: command._id,
      status: "done",
      result: { model: session.model, effort: session.effort ?? null },
    });
    log("config", command.configId, "=", command.text);
  } else if (command.type === "cancel") {
    if (turn) turn.cancelled = true;
    await client.mutation("bridge:completeCommand", { hostId, commandId: command._id, status: "done" });
  } else if (command.type === "info") {
    await sleep(500);
    await client.mutation("bridge:completeCommand", {
      hostId,
      commandId: command._id,
      status: "done",
      result: {
        model: "grok-code-fast-1",
        effort: "high",
        cwd: "/Users/ios-tester/src/webapp",
        gitBranch: "fix/login-redirect",
        title: "Fix the login redirect",
        createdAt: now - 3_600_000,
        usage: { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cachedTokens: usage.cachedTokens, reasoningTokens: usage.reasoningTokens, costUsd: usage.costUsd },
        context: { used: usage.contextTokens, window: usage.contextWindow },
        messages,
        sessionId,
      },
    });
    log("info answered", command._id);
  }
}

client.onUpdate("bridge:inbox", { hostId }, (inbox) => {
  for (const command of inbox.commands) handle(command).catch((e) => log("command failed", e.message));
  if (inbox.views.length) log("watched by", inbox.views.length, "viewer(s)");
});
log("ready; waiting for commands (Ctrl-C to stop)");
process.on("SIGTERM", async () => {
  await client.mutation("bridge:disconnect", { hostId }).catch(() => {});
  process.exit(0);
});
