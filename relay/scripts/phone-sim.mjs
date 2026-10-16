#!/usr/bin/env node
// A pretend phone for trying the relay from a terminal, without the apps.
//
//   node scripts/phone-sim.mjs link [name]          sign in as a phone (prints the code; approve it on the web)
//   node scripts/phone-sim.mjs list                 sessions, newest first
//   node scripts/phone-sim.mjs events <session>     the transcript (session = relay id or crok session id)
//   node scripts/phone-sim.mjs send <session> <text...>   send a prompt and wait for it to finish
//   node scripts/phone-sim.mjs stop <session>       stop the running turn
//   node scripts/phone-sim.mjs info <session>       fresh session info from the computer
//   node scripts/phone-sim.mjs devices              linked devices
//   node scripts/phone-sim.mjs logout               unlink this pretend phone
//
// The phone's refresh token is kept in .phone-sim.json (git-ignored, 0600; `logout` deletes it).
// PHONE_SIM_APPROVE_AS='{"subject":…,"issuer":…}' approves its own code with `npx convex run --identity` (local tests).

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { ConvexClient, ConvexHttpClient } from "convex/browser";

const STATE = process.env.PHONE_SIM_STATE ?? ".phone-sim.json";

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
const url = envLocal("CONVEX_URL") ?? envLocal("NEXT_PUBLIC_CONVEX_URL");
if (!url) throw new Error("set CONVEX_URL (the relay's deployment URL)");
const http = new ConvexHttpClient(url);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function link(name) {
  const start = await http.mutation("deviceAuth:start", {
    kind: "phone",
    name,
    platform: "Terminal",
    client: "phone-sim",
  });
  console.error(`Code ${start.userCode}${start.verificationUrlComplete ? `  ${start.verificationUrlComplete}` : ""}`);
  if (process.env.PHONE_SIM_APPROVE_AS) {
    execFileSync(
      "npx",
      ["convex", "run", "deviceAuth:approve", JSON.stringify({ userCode: start.userCode }), "--identity", process.env.PHONE_SIM_APPROVE_AS],
      { encoding: "utf8" },
    );
  }
  for (;;) {
    await sleep(start.interval * 1000);
    const poll = await http.mutation("deviceAuth:poll", { deviceCode: start.deviceCode });
    if (poll.status === "approved") {
      writeFileSync(STATE, JSON.stringify({ url, refreshToken: poll.refreshToken }), { mode: 0o600 });
      console.log(JSON.stringify({ linked: true, user: poll.user }));
      return;
    }
    if (poll.status !== "pending") throw new Error(`sign-in ${poll.status}`);
  }
}

function client() {
  if (!existsSync(STATE)) throw new Error("not linked: run `link` first");
  const { refreshToken } = JSON.parse(readFileSync(STATE, "utf8"));
  const convex = new ConvexClient(url);
  convex.setAuth(async () => (await http.mutation("deviceAuth:refresh", { refreshToken })).accessToken);
  return convex;
}

async function findSession(convex, ref) {
  const sessions = await convex.query("sessions:list", {});
  const match = sessions.find((s) => s._id === ref || s.sessionId === ref || s.sessionId.startsWith(ref));
  if (!match) throw new Error(`no session ${ref}`);
  return match;
}

async function waitCommand(convex, commandId, timeoutMs = 120_000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const command = await convex.query("commands:get", { commandId });
    if (command && (command.status === "done" || command.status === "failed")) return command;
    await sleep(400);
  }
  throw new Error("timed out waiting for the computer");
}

const [command, ...rest] = process.argv.slice(2);
if (command === "link") {
  await link(rest.join(" ") || "Phone (terminal)");
  process.exit(0);
}
if (command === "logout") {
  if (existsSync(STATE)) {
    const { refreshToken } = JSON.parse(readFileSync(STATE, "utf8"));
    await http.mutation("deviceAuth:logout", { refreshToken });
    unlinkSync(STATE);
  }
  console.log(JSON.stringify({ linked: false }));
  process.exit(0);
}
const convex = client();
try {
  if (command === "list") {
    console.log(JSON.stringify(await convex.query("sessions:list", {}), null, 2));
  } else if (command === "devices") {
    console.log(JSON.stringify(await convex.query("devices:list", {}), null, 2));
  } else if (command === "events") {
    const session = await findSession(convex, rest[0]);
    const page = await convex.query("sessions:events", {
      sessionDocId: session._id,
      paginationOpts: { numItems: 200, cursor: null },
    });
    console.log(JSON.stringify(page.page.reverse(), null, 2));
  } else if (command === "send") {
    const session = await findSession(convex, rest[0]);
    await convex.mutation("sessions:watch", { sessionDocId: session._id });
    const { commandId } = await convex.mutation("commands:sendPrompt", {
      sessionDocId: session._id,
      text: rest.slice(1).join(" "),
      clientId: crypto.randomUUID(),
    });
    console.log(JSON.stringify(await waitCommand(convex, commandId)));
  } else if (command === "stop") {
    const session = await findSession(convex, rest[0]);
    const { commandId } = await convex.mutation("commands:stop", { sessionDocId: session._id });
    console.log(JSON.stringify(await waitCommand(convex, commandId)));
  } else if (command === "info") {
    const session = await findSession(convex, rest[0]);
    const { commandId } = await convex.mutation("commands:requestInfo", { sessionDocId: session._id });
    console.log(JSON.stringify((await waitCommand(convex, commandId)).result, null, 2));
  } else {
    console.error("commands: link [name] | list | events <s> | send <s> <text> | stop <s> | info <s> | devices | logout");
    process.exitCode = 2;
  }
} finally {
  await convex.close();
}
process.exit(process.exitCode ?? 0);
