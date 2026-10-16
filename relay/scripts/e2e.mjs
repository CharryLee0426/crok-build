#!/usr/bin/env node
// End-to-end check of the relay against a running deployment (by default the local one in .env.local):
// a "computer" and a "phone" each sign in with the device flow, the computer mirrors a session, the phone reads it and
// sends a prompt, a stop and an info request, the computer handles them, and finally the phone signs the computer out.
//
// Approving a sign-in needs a signed-in person. Here `npx convex run --identity` stands in for the Clerk user, so the
// deployment needs CLERK_JWT_ISSUER_DOMAIN set (any value works for this script; see relay/README.md).
//
//   npx convex dev            # in another terminal
//   node scripts/e2e.mjs

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
const person = JSON.stringify({ subject: `e2e-${Date.now()}`, issuer, name: "E2E Tester", email: "e2e@example.com" });

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
  check(/^[B-Z]{4}-[B-Z]{4}$/.test(started.userCode), `${kind}: user code looks like XXXX-XXXX`, started.userCode);
  const pending = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  check(pending.status === "pending", `${kind}: poll before approval is pending`, pending);
  const shown = runAsPerson("deviceAuth:pendingLogin", { userCode: started.userCode.toLowerCase().replace("-", " ") });
  check(shown?.name === name && shown?.status === "pending", `${kind}: approval page sees the device`, shown);
  runAsPerson("deviceAuth:approve", { userCode: started.userCode });
  const approved = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  check(approved.status === "approved" && approved.refreshToken?.startsWith("crr_"), `${kind}: approved`, approved.status);
  const again = await http.mutation("deviceAuth:poll", { deviceCode: started.deviceCode });
  check(again.status === "expired", `${kind}: the device code works once`, again);
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

function nextValue(client, fn, args, predicate, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`timed out waiting on ${fn}`));
    }, timeoutMs);
    const unsubscribe = client.onUpdate(
      fn,
      args,
      (value) => {
        if (predicate(value)) {
          clearTimeout(timer);
          unsubscribe();
          resolve(value);
        }
      },
      (error) => {
        clearTimeout(timer);
        unsubscribe();
        reject(error);
      },
    );
  });
}

console.log(`Relay e2e against ${url}`);

console.log("Sign-in");
const computerTokens = await link("computer", "E2E MacBook");
const phoneTokens = await link("phone", "E2E iPhone");
const refreshed = await http.mutation("deviceAuth:refresh", { refreshToken: phoneTokens.refreshToken });
check(refreshed.accessToken.split(".").length === 3, "refresh returns a JWT");

const computer = authedClient(computerTokens);
const phone = authedClient(phoneTokens);

console.log("Identity");
const meComputer = await computer.query("users:me", {});
check(meComputer?.device?.kind === "computer" && meComputer.name === "E2E Tester", "the computer's JWT is accepted", meComputer);
const mePhone = await phone.query("users:me", {});
check(mePhone?.userId === meComputer?.userId, "phone and computer are the same account");

console.log("Mirroring");
const { hostId } = await computer.mutation("bridge:connect", {
  instanceId: `e2e-${process.pid}`,
  app: "tui",
  appVersion: "crok e2e",
  pid: process.pid,
});
const sessionId = `0199e2e0-${Date.now().toString(16)}`;
const { sessionDocId } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId,
  fields: { title: "Fix the flaky test", cwd: "/Users/e2e/project", model: "grok-code", status: "idle" },
});
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    { key: "u1", kind: "user", text: "Why does the test flake?", origin: "local", at: Date.now() },
    { key: "a1", kind: "assistant", text: "Look", at: Date.now() },
  ],
});
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [{ key: "a1", kind: "assistant", text: "Looking at the test now.", at: Date.now() }],
});
const list = await phone.query("sessions:list", {});
const row = list.find((s) => s.sessionId === sessionId);
check(row?.online && row.deviceName === "E2E MacBook" && row.unread === 1, "the phone lists the session", row);
const page = await phone.query("sessions:events", { sessionDocId, paginationOpts: { numItems: 20, cursor: null } });
check(
  page.page.length === 2 && page.page[0].text === "Looking at the test now." && page.page[0].seq === 2,
  "streamed text updates the same event in place",
  page.page.map((e) => [e.seq, e.text]),
);
await phone.mutation("sessions:markRead", { sessionDocId });
await phone.mutation("sessions:watch", { sessionDocId });

console.log("Commands");
const inboxWait = nextValue(computer, "bridge:inbox", { hostId }, (v) => v.commands.length > 0);
const clientId = crypto.randomUUID();
const { commandId } = await phone.mutation("commands:sendPrompt", { sessionDocId, text: "Run it 20 times", clientId });
const resend = await phone.mutation("commands:sendPrompt", { sessionDocId, text: "Run it 20 times", clientId });
check(resend.commandId === commandId, "a resend with the same clientId is the same command");
const inbox = await inboxWait;
check(inbox.commands[0]?.text === "Run it 20 times" && inbox.commands[0]?.sessionId === sessionId, "the computer gets the prompt", inbox.commands);
check(inbox.views.some((view) => view.sessionDocId === sessionDocId), "the computer knows the phone is watching", inbox.views);
check(await computer.mutation("bridge:claimCommand", { hostId, commandId }), "the computer claims it");
check(!(await computer.mutation("bridge:claimCommand", { hostId, commandId })), "a second claim loses");
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [{ key: "u2", kind: "user", text: "Run it 20 times", origin: "remote", commandId, at: Date.now() }],
});
await computer.mutation("bridge:upsertSession", { hostId, sessionId, fields: { status: "running" } });
const stopWait = nextValue(computer, "bridge:inbox", { hostId }, (v) => v.commands.some((c) => c.type === "cancel"));
const { commandId: stopId } = await phone.mutation("commands:stop", { sessionDocId });
const stopInbox = await stopWait;
check(stopInbox.commands.some((c) => c._id === stopId), "the computer gets the stop");
await computer.mutation("bridge:claimCommand", { hostId, commandId: stopId });
await computer.mutation("bridge:completeCommand", { hostId, commandId: stopId, status: "done" });
await computer.mutation("bridge:completeCommand", { hostId, commandId, status: "done" });
await computer.mutation("bridge:upsertSession", { hostId, sessionId, fields: { status: "idle" } });
const sent = await phone.query("commands:forSession", { sessionDocId });
check(sent[0]?.clientId === clientId && sent[0]?.status === "done", "the phone sees its prompt done (two ticks)", sent[0]);

const { commandId: infoId } = await phone.mutation("commands:requestInfo", { sessionDocId });
await computer.mutation("bridge:claimCommand", { hostId, commandId: infoId });
await computer.mutation("bridge:completeCommand", {
  hostId,
  commandId: infoId,
  status: "done",
  // The shape the crok bridge sends (relay/DESIGN.md, "An info result").
  result: {
    model: "grok-code",
    cwd: "/Users/e2e/project",
    usage: { inputTokens: 1200, outputTokens: 300, costUsd: 0.01 },
    context: { used: 4000, window: 256000 },
  },
});
const info = await phone.query("commands:get", { commandId: infoId });
check(info?.result?.model === "grok-code" && info?.result?.usage?.inputTokens === 1200, "the phone gets the session info", info?.result);

console.log("Projects, catalog and order");
// A session that ran here earlier and was closed: not on disk any more, so the catalog drops it.
const goneId = `0199e2e1-${Date.now().toString(16)}`;
const { sessionDocId: goneDoc } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId: goneId,
  fields: { title: "Deleted on the computer", cwd: "/Users/e2e/project", status: "idle" },
});
await computer.mutation("bridge:closeSession", { hostId, sessionId: goneId });
const begun = await computer.mutation("bridge:beginCatalog", { hostId });
check(typeof begun?.syncId === "string", "the computer may list its sessions", begun);
check((await computer.mutation("bridge:beginCatalog", { hostId })) === null, "a second listing waits for the first");
const oldTime = Date.now() - 3 * 24 * 3600 * 1000;
const catOne = `0199e2e2-${Date.now().toString(16)}`;
const catTwo = `0199e2e3-${Date.now().toString(16)}`;
await computer.mutation("bridge:catalogBatch", {
  hostId,
  syncId: begun.syncId,
  sessions: [
    { sessionId, title: "Fix the flaky test", cwd: "/Users/e2e/project", projectPath: "/Users/e2e/project", createdAt: oldTime, lastActivityAt: oldTime },
    {
      sessionId: catOne,
      title: "Old refactor",
      cwd: "/Users/e2e/project/crates/core",
      projectPath: "/Users/e2e/project",
      createdAt: oldTime,
      lastActivityAt: oldTime + 1000,
      model: "grok-code",
      preview: "Split the parser into two modules",
    },
    { sessionId: catTwo, title: "Notes", cwd: "/Users/e2e/other", projectPath: "/Users/e2e/other", createdAt: oldTime, lastActivityAt: oldTime },
  ],
});
const finished = await computer.mutation("bridge:finishCatalog", {
  hostId,
  syncId: begun.syncId,
  sessionIds: [sessionId, catOne, catTwo],
});
check(finished.removed === 1, "a closed session missing from the computer's disk is dropped", finished);
check((await computer.mutation("bridge:beginCatalog", { hostId })) === null, "the next listing waits ten minutes");
let groups = await phone.query("sessions:groups", {});
const projectGroup = groups.find((g) => g.path === "/Users/e2e/project");
const otherGroup = groups.find((g) => g.path === "/Users/e2e/other");
check(
  projectGroup?.name === "project" && otherGroup?.name === "other" && groups.indexOf(projectGroup) < groups.indexOf(otherGroup),
  "sessions are grouped by project, the most recently active project first",
  groups.map((g) => [g.name, g.sessions.length]),
);
check(
  projectGroup?.sessions.map((s) => s.sessionId).join() === [sessionId, catOne].join() &&
    !projectGroup.sessions.some((s) => s.sessionId === goneId),
  "a project holds its sessions, newest first",
  projectGroup?.sessions.map((s) => s.title),
);
const catRow = projectGroup?.sessions.find((s) => s.sessionId === catOne);
check(
  catRow && !catRow.online && catRow.historyState === "none" && catRow.preview === "Split the parser into two modules",
  "a session only on disk is listed offline, with its last turn as the preview",
  catRow,
);
check(projectGroup?.sessions[0].online && projectGroup.sessions[0].title === "Fix the flaky test", "the catalog leaves a running session alone");
await phone.mutation("sessions:reorderProjects", { keys: [otherGroup.key, projectGroup.key] });
groups = await phone.query("sessions:groups", {});
check(
  groups.findIndex((g) => g.key === otherGroup.key) < groups.findIndex((g) => g.key === projectGroup.key) &&
    groups.every((g) => g.placed),
  "projects take the order they were put in",
  groups.map((g) => g.name),
);
await phone.mutation("sessions:reorderSessions", { projectKey: projectGroup.key, sessionDocIds: [catRow._id, sessionDocId] });
groups = await phone.query("sessions:groups", {});
check(
  groups.find((g) => g.key === projectGroup.key)?.sessions[0]._id === catRow._id,
  "sessions take the order they were put in",
);
await phone.mutation("sessions:resetOrder", { projectKey: projectGroup.key });
groups = await phone.query("sessions:groups", {});
check(groups.find((g) => g.key === projectGroup.key)?.sessions[0]._id === sessionDocId, "sort by recent activity undoes it");
await phone.mutation("sessions:resetOrder", {});

// Opening a session that only lives on the computer's disk asks the computer for its transcript.
const historyWait = nextValue(computer, "bridge:inbox", { hostId }, (v) => v.commands.some((c) => c.type === "history"));
await phone.mutation("sessions:watch", { sessionDocId: catRow._id });
const historyInbox = await historyWait;
const historyCommand = historyInbox.commands.find((c) => c.type === "history");
check(
  historyCommand?.sessionId === catOne && historyCommand?.cwd === "/Users/e2e/project/crates/core",
  "the computer is asked for the transcript, with the folder it is stored under",
  historyCommand,
);
check((await phone.query("sessions:get", { sessionDocId: catRow._id })).historyState === "requested", "the session shows it is loading");
check(await computer.mutation("bridge:claimCommand", { hostId, commandId: historyCommand._id }), "a crok on that computer claims it");
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId: catRow._id,
  replace: true,
  events: [
    { key: "h-u1", kind: "user", text: "Split the parser", origin: "local", at: oldTime },
    { key: "h-a1", kind: "assistant", text: "Done: two modules.", at: oldTime + 500 },
  ],
  preview: "Done: two modules.",
  previewKind: "assistant",
});
await computer.mutation("bridge:completeCommand", { hostId, commandId: historyCommand._id, status: "done" });
const loaded = await phone.query("sessions:get", { sessionDocId: catRow._id });
const history = await phone.query("sessions:events", { sessionDocId: catRow._id, paginationOpts: { numItems: 20, cursor: null } });
check(
  loaded.historyState === "ready" && history.page.length === 2 && loaded.lastActivityAt === catRow.lastActivityAt,
  "the transcript arrives without making the session look new",
  { state: loaded.historyState, events: history.page.length },
);
await phone.mutation("sessions:watch", { sessionDocId: catRow._id });
const recent = await phone.query("commands:forSession", { sessionDocId: catRow._id });
check(recent.length === 0, "history requests are not shown as prompts", recent);

// A prompt for a session nobody runs goes to a crok on its computer that can open it; claiming it makes that crok the
// session's runner at once.
console.log("Prompts for sessions nobody runs");
let notOpenable;
try {
  await phone.mutation("commands:sendPrompt", { sessionDocId: catRow._id, text: "x", clientId: crypto.randomUUID() });
} catch (error) {
  notOpenable = error.data?.code;
}
check(notOpenable === "OFFLINE", "with no crok there that can open sessions, the prompt is refused", notOpenable);
const { hostId: adoptHost } = await computer.mutation("bridge:connect", {
  instanceId: `e2e-${process.pid}-adopt`,
  app: "tui",
  appVersion: "crok e2e",
  canAdopt: true,
});
const adoptWait = nextValue(computer, "bridge:inbox", { hostId: adoptHost }, (v) => v.commands.some((c) => c.type === "prompt"));
const { commandId: adoptId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId: catRow._id,
  text: "Carry on with the parser",
  clientId: crypto.randomUUID(),
});
const adoptCommand = (await adoptWait).commands.find((c) => c._id === adoptId);
check(
  adoptCommand?.adopt === true && adoptCommand.cwd === "/Users/e2e/project/crates/core",
  "it reaches the crok that can open it, marked to open the session first",
  adoptCommand,
);
const plainInbox = await computer.query("bridge:inbox", { hostId });
check(!plainInbox.commands.some((c) => c._id === adoptId), "a crok that cannot open sessions is not offered it");
check(await computer.mutation("bridge:claimCommand", { hostId: adoptHost, commandId: adoptId }), "the crok claims it");
const adopted = await phone.query("sessions:get", { sessionDocId: catRow._id });
check(adopted.online && adopted.status === "running", "claiming makes the session run there at once", adopted);
check((await computer.query("bridge:inbox", { hostId: adoptHost })).hosted.includes(catOne), "the crok's inbox lists it as its own");

// A permission request in a session: any device may answer it, once.
await computer.mutation("bridge:setPending", {
  hostId: adoptHost,
  sessionId: catOne,
  pending: {
    id: "call_1#1",
    kind: "permission",
    title: "Run cargo test",
    detail: "cargo test",
    toolKind: "execute",
    options: [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "deny", name: "Deny", kind: "reject_once" },
    ],
    at: Date.now(),
  },
});
const withPending = await phone.query("sessions:get", { sessionDocId: catRow._id });
check(withPending.pending?.title === "Run cargo test" && withPending.pending.options.length === 2, "the request shows on the phone", withPending.pending);
let staleAnswer;
try {
  await phone.mutation("commands:answer", { sessionDocId: catRow._id, interactionId: "call_0#9", optionId: "allow" });
} catch (error) {
  staleAnswer = error.data?.code;
}
check(staleAnswer === "EXPIRED", "an answer to an earlier request is refused", staleAnswer);
const answerWait = nextValue(computer, "bridge:inbox", { hostId: adoptHost }, (v) => v.commands.some((c) => c.type === "answer"));
const { commandId: answerId } = await phone.mutation("commands:answer", {
  sessionDocId: catRow._id,
  interactionId: "call_1#1",
  optionId: "allow",
});
const answerCommand = (await answerWait).commands.find((c) => c._id === answerId);
check(answerCommand?.interactionId === "call_1#1" && answerCommand.text === "allow", "the choice reaches the crok running it", answerCommand);
await computer.mutation("bridge:setPending", { hostId: adoptHost, sessionId: catOne });
check((await phone.query("sessions:get", { sessionDocId: catRow._id })).pending === null, "once answered, the request is gone");
await computer.mutation("bridge:completeCommand", { hostId: adoptHost, commandId: adoptId, status: "done" });
await computer.mutation("bridge:closeSession", { hostId: adoptHost, sessionId: catOne });

// Info and Stop for a session nobody runs are settled by the relay.
const { commandId: storedInfoId } = await phone.mutation("commands:requestInfo", { sessionDocId: catRow._id });
const storedInfo = await phone.query("commands:get", { commandId: storedInfoId });
check(
  storedInfo?.status === "done" && storedInfo.result?.stored && storedInfo.result.cwd === "/Users/e2e/project/crates/core",
  "info for a session nobody runs comes at once from what the relay stored",
  storedInfo?.result,
);
const { commandId: waitingId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId: catRow._id,
  text: "later",
  clientId: crypto.randomUUID(),
});
await phone.mutation("commands:stop", { sessionDocId: catRow._id });
check((await phone.query("commands:get", { commandId: waitingId }))?.status === "failed", "Stop drops a prompt no crok picked up yet");
await computer.mutation("bridge:disconnect", { hostId: adoptHost });

// A host that drops off and comes back brings back what it had open, not what it only listed or had closed.
const { hostId: otherHost } = await computer.mutation("bridge:connect", {
  instanceId: `e2e-${process.pid}-b`,
  app: "desktop",
  appVersion: "crok e2e",
});
await computer.mutation("bridge:disconnect", { hostId });
await computer.mutation("bridge:heartbeat", { hostId });
const revived = await phone.query("sessions:groups", {});
const revivedProject = revived.find((g) => g.key === projectGroup.key);
check(
  revivedProject?.sessions.find((s) => s._id === sessionDocId)?.online === true &&
    revivedProject?.sessions.find((s) => s._id === catRow._id)?.online === false,
  "a returning host revives its open session only",
  revivedProject?.sessions.map((s) => [s.title, s.online]),
);
await computer.mutation("bridge:disconnect", { hostId: otherHost });
await phone.mutation("sessions:remove", { sessionDocId: catRow._id });
const otherRow = revived.find((g) => g.key === otherGroup.key)?.sessions[0];
if (otherRow) await phone.mutation("sessions:remove", { sessionDocId: otherRow._id });
void goneDoc;

console.log("Offline and sign-out");
await computer.mutation("bridge:disconnect", { hostId });
const afterDisconnect = await phone.query("sessions:get", { sessionDocId });
check(afterDisconnect.online === false, "a disconnected host's session goes offline");
let offlineError;
try {
  await phone.mutation("commands:sendPrompt", { sessionDocId, text: "hello?", clientId: crypto.randomUUID() });
} catch (error) {
  offlineError = error.data?.code;
}
check(offlineError === "OFFLINE", "prompting an offline session fails with OFFLINE", offlineError);
const devices = await phone.query("devices:list", {});
check(devices[0]?.isCurrent && devices.length === 2, "the phone lists both devices, itself first", devices.map((d) => d.name));
await phone.mutation("devices:revoke", { deviceId: meComputer.device.deviceId });
let revoked;
try {
  await http.mutation("deviceAuth:refresh", { refreshToken: computerTokens.refreshToken });
} catch (error) {
  revoked = error.data?.code;
}
check(revoked === "REVOKED", "a signed-out computer cannot refresh", revoked);
let revokedQuery;
try {
  await computer.query("users:me", {});
} catch (error) {
  revokedQuery = error.data?.code;
}
check(revokedQuery === "REVOKED", "its current JWT stops working at once", revokedQuery);

// Leave nothing behind but the test person: drop the session's copy and unlink the phone.
await phone.mutation("sessions:remove", { sessionDocId });
await http.mutation("deviceAuth:logout", { refreshToken: phoneTokens.refreshToken });

await computer.close();
await phone.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
