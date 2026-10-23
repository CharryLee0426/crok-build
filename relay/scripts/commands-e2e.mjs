#!/usr/bin/env node
// End-to-end check of new sessions from any device, model and thinking-level changes, and slash command lists
// (relay/DESIGN.md §2) against a running deployment (by default the local one in .env.local). Like scripts/e2e.mjs,
// `npx convex run --identity` stands in for the Clerk user who approves the sign-ins.
//
//   npx convex dev            # in another terminal
//   node scripts/commands-e2e.mjs

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

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
const person = JSON.stringify({ subject: `cmd-e2e-${Date.now()}`, issuer, name: "E2E Tester", email: "e2e@example.com" });

let failures = 0;
function check(condition, label, detail) {
  if (condition) {
    console.log(`  ok  ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail)}`}`);
  }
}

function runAsPerson(fn, args) {
  const out = execFileSync("npx", ["convex", "run", fn, JSON.stringify(args), "--identity", person], {
    encoding: "utf8",
  });
  return out.trim() ? JSON.parse(out) : null;
}

const http = new ConvexHttpClient(url);

async function link(kind, name) {
  const started = await http.mutation("deviceAuth:start", { kind, name, platform: "e2e", client: "e2e 0.0" });
  runAsPerson("deviceAuth:approve", { userCode: started.userCode });
  const approved = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  if (approved.status !== "approved") throw new Error(`${kind} sign-in: ${approved.status}`);
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

/** The relay's error code for a call expected to fail, or "ok". */
async function codeOf(promise) {
  try {
    await promise;
    return "ok";
  } catch (error) {
    return error?.data?.code ?? String(error);
  }
}

console.log(`Commands e2e against ${url}`);
const computerTokens = await link("computer", "E2E Mac Studio");
const idleTokens = await link("computer", "E2E Old Laptop");
const phoneTokens = await link("phone", "E2E Pixel");
const computer = authedClient(computerTokens);
const idle = authedClient(idleTokens);
const phone = authedClient(phoneTokens);
const project = "/Users/e2e/webapp";

const { hostId, deviceId } = await computer.mutation("bridge:connect", {
  instanceId: `cmd-e2e-${process.pid}`,
  app: "desktop",
  appVersion: "crok e2e",
  canAdopt: true,
  features: ["create", "config"],
});
// An older crok on the same computer: it must never be handed the command types it cannot parse.
const { hostId: oldHostId } = await computer.mutation("bridge:connect", {
  instanceId: `cmd-e2e-old-${process.pid}`,
  app: "tui",
  appVersion: "crok 1.0.45 (old)",
  canAdopt: true,
});
const idleMe = await idle.query("users:me", {});
const idleDeviceId = idleMe.device.deviceId;
const phoneMe = await phone.query("users:me", {});

console.log("Models");
await computer.mutation("bridge:setModels", {
  hostId,
  models: [
    {
      id: "grok-4",
      name: "Grok 4",
      description: "Smartest",
      efforts: [
        { id: "low", name: "Low" },
        { id: "high", name: "High" },
      ],
      defaultEffort: "high",
    },
    { id: "grok-code-fast", name: "Grok Code Fast", efforts: [] },
  ],
});
const sessionId = `0199c0de-${Date.now().toString(16)}`;
const { sessionDocId } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId,
  fields: { title: "Running one", cwd: project, model: "grok-4", effort: "high", status: "idle" },
});
const detail = await phone.query("sessions:get", { sessionDocId });
check(detail.models?.length === 2 && detail.models[0].efforts.length === 2, "sessions:get lists the computer's models", detail.models);
check(detail.starting === false, "a mirrored session is not starting");

console.log("Model and thinking level");
const { commandId: modelId } = await phone.mutation("commands:setConfig", {
  sessionDocId,
  configId: "model",
  value: "grok-code-fast",
});
const inbox1 = await computer.query("bridge:inbox", { hostId });
const modelCommand = inbox1.commands.find((c) => c._id === modelId);
check(
  modelCommand?.type === "config" && modelCommand.configId === "model" && modelCommand.text === "grok-code-fast" && !modelCommand.adopt,
  "the computer gets the model change",
  modelCommand,
);
check(await computer.mutation("bridge:claimCommand", { hostId, commandId: modelId }), "it claims it");
await computer.mutation("bridge:completeCommand", {
  hostId,
  commandId: modelId,
  status: "done",
  result: { model: "grok-code-fast", effort: null },
});
const modelDone = await phone.query("commands:get", { commandId: modelId });
check(modelDone?.status === "done" && modelDone.result?.model === "grok-code-fast", "the phone sees the result", modelDone);
check(
  (await codeOf(phone.mutation("commands:setConfig", { sessionDocId, configId: "model", value: "gpt-9" }))) === "INVALID",
  "an unknown model is INVALID",
);
check(
  (await codeOf(phone.mutation("commands:setConfig", { sessionDocId, configId: "reasoning_effort", value: "max" }))) === "INVALID",
  "a thinking level the current model lacks is INVALID",
);

console.log("A new session's model and thinking level");
const computerModels = await phone.query("devices:models", { deviceId });
check(
  computerModels?.length === 2 && computerModels[0].efforts.length === 2,
  "devices:models lists what a computer can run before a session exists",
  computerModels,
);
check(
  (await phone.query("devices:models", { deviceId: idleDeviceId })) === null,
  "an offline computer has no models to choose from",
);

console.log("A long model list (OpenRouter's)");
const shortList = computerModels;
const longList = Array.from({ length: 500 }, (_, i) => ({
  id: `openrouter/vendor-${i % 40}/model-${i}`,
  name: `Vendor ${i % 40}: Model ${i}`,
  description: "A capable general model with a long context window, tools and structured output. ".repeat(3),
  efforts:
    i % 2 === 0
      ? ["minimal", "low", "medium", "high", "xhigh"].map((level) => ({
          id: level,
          name: level,
          value: level,
          description: `Think ${level} before answering, trading speed for quality.`,
        }))
      : [],
  ...(i % 2 === 0 ? { defaultEffort: "medium" } : {}),
}));
await computer.mutation("bridge:setModels", { hostId, models: longList });
const longModels = await phone.query("devices:models", { deviceId });
check(longModels?.length === 500, "a computer can publish 500 models", longModels?.length);
check(
  longModels?.[498]?.efforts.length === 5 && longModels?.[499]?.efforts.length === 0,
  "every model keeps its thinking levels",
);
check(
  (await phone.query("sessions:get", { sessionDocId })).models === null,
  "sessions:get leaves a long list to devices:models (it re-runs with every transcript item)",
);
const { commandId: longModelId } = await phone.mutation("commands:setConfig", {
  sessionDocId,
  configId: "model",
  value: "openrouter/vendor-18/model-498",
});
check(Boolean(longModelId), "a model from the end of a long list can be chosen");
await computer.mutation("bridge:claimCommand", { hostId, commandId: longModelId });
await computer.mutation("bridge:completeCommand", { hostId, commandId: longModelId, status: "done", result: {} });
check(
  (await codeOf(computer.mutation("bridge:setModels", { hostId, models: [...longList, ...longList, ...longList] }))) ===
    "INVALID",
  "more than 1,000 models is INVALID",
);
await computer.mutation("bridge:setModels", { hostId, models: shortList });
check((await phone.query("sessions:get", { sessionDocId })).models?.length === 2, "a short list is embedded again");
const configured = await phone.mutation("sessions:create", {
  deviceId,
  path: project,
  text: "Use Grok 4 with high thinking",
  model: "grok-4",
  effort: "high",
  clientId: crypto.randomUUID(),
});
const configuredDetail = await phone.query("sessions:get", { sessionDocId: configured.sessionDocId });
check(
  configuredDetail.model === "grok-4" && configuredDetail.effort === "high",
  "a new session carries the chosen model and thinking level",
  configuredDetail,
);
const configuredCommand = (await computer.query("bridge:inbox", { hostId })).commands.find(
  (c) => c._id === configured.commandId,
);
check(
  configuredCommand?.model === "grok-4" && configuredCommand?.effort === "high",
  "its create command carries them",
  configuredCommand,
);
check(
  (await codeOf(phone.mutation("sessions:create", { deviceId, path: project, model: "gpt-9", clientId: crypto.randomUUID() }))) ===
    "INVALID",
  "a model that computer lacks is INVALID",
);
check(
  (await codeOf(
    phone.mutation("sessions:create", {
      deviceId,
      path: project,
      model: "grok-code-fast",
      effort: "high",
      clientId: crypto.randomUUID(),
    }),
  )) === "INVALID",
  "a thinking level its model lacks is INVALID",
);
check(
  (await codeOf(phone.mutation("sessions:create", { deviceId, path: project, effort: "high", clientId: crypto.randomUUID() }))) ===
    "INVALID",
  "a thinking level needs the model it belongs to",
);

console.log("Slash commands");
const none = await phone.query("sessions:commands", { sessionDocId });
check(none.source === "none" && none.commands.length === 0, "no list yet", none);
await computer.mutation("bridge:setCommands", {
  hostId,
  sessionId,
  commands: [
    { name: "compact", description: "Compress conversation history" },
    { name: "/review-pr", description: "Review a pull request", hint: "<number>" },
  ],
});
const own = await phone.query("sessions:commands", { sessionDocId });
check(
  own.source === "session" && own.commands.length === 2 && own.commands[1].name === "review-pr" && own.commands[1].hint === "<number>",
  "the session's list (leading / dropped)",
  own,
);

console.log("New sessions");
check(
  (await codeOf(phone.mutation("sessions:create", { deviceId: idleDeviceId, path: project, clientId: crypto.randomUUID() }))) ===
    "OFFLINE",
  "a computer with no crok running is OFFLINE",
);
check(
  (await codeOf(phone.mutation("sessions:create", { deviceId, path: "webapp", clientId: crypto.randomUUID() }))) === "INVALID",
  "a relative folder is INVALID",
);
check(
  (await codeOf(
    phone.mutation("sessions:create", { deviceId: phoneMe.device.deviceId, path: project, clientId: crypto.randomUUID() }),
  )) === "FORBIDDEN",
  "a phone cannot run sessions",
);
const clientId = crypto.randomUUID();
const created = await phone.mutation("sessions:create", {
  deviceId,
  path: project,
  text: "Add a dark mode toggle\nwith a test",
  clientId,
});
const again = await phone.mutation("sessions:create", { deviceId, path: project, text: "Add a dark mode toggle", clientId });
check(again.sessionDocId === created.sessionDocId && again.commandId === created.commandId, "a resend is the same session");
const starting = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(
  starting.starting && starting.status === "running" && starting.title === "Add a dark mode toggle" && starting.projectPath === project,
  "the new session is listed at once, starting",
  starting,
);
const groups = await phone.query("sessions:groups", {});
const startingRow = groups.flatMap((g) => g.sessions).find((s) => s._id === created.sessionDocId);
check(startingRow?.starting === true, "list rows say starting", startingRow);
const ticks = await phone.query("commands:forSession", { sessionDocId: created.sessionDocId });
check(ticks[0]?.type === "create" && ticks[0]?.clientId === clientId && ticks[0]?.mine, "the first prompt shows with ticks", ticks[0]);

// A catalog upload while it is starting does not drop it (it is not on the computer's disk yet).
const begun = await computer.mutation("bridge:beginCatalog", { hostId });
if (begun) {
  await computer.mutation("bridge:finishCatalog", { hostId, syncId: begun.syncId, sessionIds: [sessionId] });
  check((await phone.query("sessions:get", { sessionDocId: created.sessionDocId }))?.starting, "a catalog upload keeps it");
}

const oldInbox = await computer.query("bridge:inbox", { hostId: oldHostId });
check(!oldInbox.commands.some((c) => c.type === "create" || c.type === "config"), "an older crok is not offered create or config", oldInbox.commands.map((c) => c.type));
check(
  !(await computer.mutation("bridge:claimCommand", { hostId: oldHostId, commandId: created.commandId })),
  "nor can it claim them",
);
const inbox2 = await computer.query("bridge:inbox", { hostId });
const createCommand = inbox2.commands.find((c) => c._id === created.commandId);
check(
  createCommand?.type === "create" && createCommand.cwd === project && createCommand.text?.startsWith("Add a dark mode"),
  "the computer gets the create command",
  createCommand,
);
check(await computer.mutation("bridge:claimCommand", { hostId, commandId: created.commandId }), "it claims it");
const claimed = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(claimed.online && claimed.starting, "claiming makes it the runner (still starting)", claimed);
const realId = `0199beef-${Date.now().toString(16)}`;
const bound = await computer.mutation("bridge:bindSession", { hostId, sessionDocId: created.sessionDocId, sessionId: realId });
check(bound.sessionDocId === created.sessionDocId, "binding keeps the row");
const upserted = await computer.mutation("bridge:upsertSession", { hostId, sessionId: realId, fields: { status: "running" } });
check(upserted.sessionDocId === created.sessionDocId && !upserted.created, "the mirror finds the row by crok's id", upserted);
const opened = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(!opened.starting && opened.sessionId === realId, "it is an ordinary session now", opened);
check(
  (await codeOf(computer.mutation("bridge:bindSession", { hostId, sessionDocId: created.sessionDocId, sessionId: "other" }))) ===
    "INVALID",
  "it cannot be bound twice",
);
await computer.mutation("bridge:completeCommand", { hostId, commandId: created.commandId, status: "done" });

console.log("A new session that fails to open");
const failing = await phone.mutation("sessions:create", { deviceId, path: "/nowhere", text: "hi", clientId: crypto.randomUUID() });
await computer.mutation("bridge:claimCommand", { hostId, commandId: failing.commandId });
await computer.mutation("bridge:completeCommand", {
  hostId,
  commandId: failing.commandId,
  status: "failed",
  error: "The computer could not start this session: /nowhere is not a folder on this computer.",
});
const failed = await phone.query("sessions:get", { sessionDocId: failing.sessionDocId });
check(failed.status === "error" && !failed.online && failed.starting, "it shows the error, offline", failed);
const failedEvents = await phone.query("sessions:events", {
  sessionDocId: failing.sessionDocId,
  paginationOpts: { numItems: 5, cursor: null },
});
check(failedEvents.page[0]?.kind === "error" && failedEvents.page[0].text.includes("/nowhere"), "with an error item", failedEvents.page);
const retry = await phone.mutation("commands:sendPrompt", {
  sessionDocId: failing.sessionDocId,
  text: "try again",
  clientId: crypto.randomUUID(),
});
const retried = (await computer.query("bridge:inbox", { hostId })).commands.find((c) => c._id === retry.commandId);
check(retried?.type === "create" && retried.cwd === "/nowhere", "a prompt to it tries to open it again", retried);
const { commandId: stopId } = await phone.mutation("commands:stop", { sessionDocId: failing.sessionDocId });
const stopped = await phone.query("commands:get", { commandId: retry.commandId });
check(stopped?.status === "failed", "Stop drops the waiting create", stopped);
check((await phone.query("commands:get", { commandId: stopId }))?.status === "done", "and is done at once");

console.log("Config for a session nobody runs");
await computer.mutation("bridge:closeSession", { hostId, sessionId });
const { commandId: offlineConfig } = await phone.mutation("commands:setConfig", {
  sessionDocId,
  configId: "reasoning_effort",
  value: "low",
});
const adoptConfig = (await computer.query("bridge:inbox", { hostId })).commands.find((c) => c._id === offlineConfig);
check(adoptConfig?.adopt === true && adoptConfig.type === "config", "it is offered for adoption", adoptConfig);
await computer.mutation("bridge:claimCommand", { hostId, commandId: offlineConfig });
const adoptedConfig = await phone.query("sessions:get", { sessionDocId });
check(adoptedConfig.online && adoptedConfig.status === "idle", "claiming it makes the host the runner without a turn", adoptedConfig);

console.log("Computer fallback list");
const otherId = `0199c0df-${Date.now().toString(16)}`;
const { sessionDocId: otherDoc } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId: otherId,
  fields: { title: "No list yet", cwd: project, status: "idle" },
});
const fallback = await phone.query("sessions:commands", { sessionDocId: otherDoc });
check(fallback.source === "computer" && fallback.commands.length === 2, "a session without its own list gets the computer's", fallback);

await computer.mutation("bridge:disconnect", { hostId });
check(
  (await codeOf(phone.mutation("sessions:create", { deviceId, path: project, clientId: crypto.randomUUID() }))) === "OFFLINE",
  "with only an older crok running there, a new session asks to update crok",
);
await computer.mutation("bridge:disconnect", { hostId: oldHostId });
const offlineModels = await phone.query("sessions:get", { sessionDocId });
check(offlineModels.models === null, "no models while the computer is offline", offlineModels.models);

await computer.close();
await idle.close();
await phone.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
