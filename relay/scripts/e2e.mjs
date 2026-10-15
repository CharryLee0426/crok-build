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
