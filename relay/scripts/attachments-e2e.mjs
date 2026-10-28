#!/usr/bin/env node
// End-to-end check of photos and files in prompts (relay/DESIGN.md §2, "Photos and files") against a running
// deployment (by default the local one in .env.local). Like scripts/e2e.mjs, `npx convex run --identity` stands in for
// the Clerk users who approve the sign-ins.
//
//   npx convex dev            # in another terminal
//   node scripts/attachments-e2e.mjs

import { createHash } from "node:crypto";
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
const stamp = Date.now();
const person = (who) => JSON.stringify({ subject: `att-e2e-${who}-${stamp}`, issuer, name: `E2E ${who}`, email: `${who}@example.com` });

let failures = 0;
function check(condition, label, detail) {
  if (condition) {
    console.log(`  ok  ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail === undefined ? "" : `: ${JSON.stringify(detail)}`}`);
  }
}

function runAs(who, fn, args) {
  const out = execFileSync("npx", ["convex", "run", fn, JSON.stringify(args), "--identity", person(who)], {
    encoding: "utf8",
  });
  return out.trim() ? JSON.parse(out) : null;
}

const http = new ConvexHttpClient(url);

async function link(who, kind, name) {
  const started = await http.mutation("deviceAuth:start", { kind, name, platform: "e2e", client: "e2e 0.0" });
  runAs(who, "deviceAuth:approve", { userCode: started.userCode });
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

async function errorOf(promise) {
  try {
    await promise;
    return "ok";
  } catch (error) {
    return `${error?.data?.code}: ${error?.data?.message}`;
  }
}

/** Uploads bytes the way every client does: an upload URL, then a POST with the type. */
async function upload(client, bytes, type) {
  const { url: target } = await client.mutation("files:uploadUrl", {});
  const response = await fetch(target, { method: "POST", headers: { "Content-Type": type }, body: bytes });
  if (!response.ok) throw new Error(`upload: ${response.status}`);
  return (await response.json()).storageId;
}

async function download(target) {
  const response = await fetch(target);
  return response.ok ? Buffer.from(await response.arrayBuffer()) : null;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A 1×1 PNG and a tiny JPEG-typed thumbnail (the relay trusts the stored type, not the bytes).
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);
const thumb = Buffer.concat([png, Buffer.from("thumb")]);
const photo = Buffer.concat([png, Buffer.from("photo")]);
const pdf = Buffer.from("%PDF-1.4\n% crok attachments e2e\n%%EOF\n");

console.log(`Attachments e2e against ${url}`);
const computer = authedClient(await link("ada", "computer", "E2E Mac"));
const phone = authedClient(await link("ada", "phone", "E2E iPhone"));
const stranger = authedClient(await link("eve", "phone", "E2E Other Phone"));
const project = "/Users/e2e/attachments";

const { hostId, deviceId } = await computer.mutation("bridge:connect", {
  instanceId: `att-e2e-${process.pid}`,
  app: "desktop",
  appVersion: "crok e2e",
  canAdopt: true,
  features: ["create", "config", "git", "setup", "catalog", "attachments"],
});
const sessionId = `0199a77a-${stamp.toString(16)}`;
const { sessionDocId } = await computer.mutation("bridge:upsertSession", {
  hostId,
  sessionId,
  fields: { title: "Photos", cwd: project, status: "idle" },
});

console.log("Upload and send");
const imageId = await upload(phone, photo, "image/png");
const thumbId = await upload(phone, thumb, "image/jpeg");
const pdfId = await upload(phone, pdf, "application/pdf");
check(typeof imageId === "string" && typeof pdfId === "string", "uploads answer storage ids");
const clientId = crypto.randomUUID();
const { commandId } = await phone.mutation("commands:sendPrompt", {
  sessionDocId,
  text: "  What is in these?  ",
  clientId,
  attachments: [
    { storageId: imageId, thumbId, name: "../../photo-20261027-120000.png", width: 1, height: 1 },
    { storageId: pdfId, name: "report.pdf" },
  ],
});
const again = await phone.mutation("commands:sendPrompt", {
  sessionDocId,
  text: "What is in these?",
  clientId,
  attachments: [{ storageId: imageId, name: "x.png" }],
});
check(again.commandId === commandId, "a resend with the same clientId is the same command");

const inbox = await computer.query("bridge:inbox", { hostId });
const command = inbox.commands.find((c) => c._id === commandId);
check(command?.attachments?.length === 2, "the inbox carries both attachments", command?.attachments);
const [image, file] = command?.attachments ?? [];
check(
  image?.kind === "image" && image.mimeType === "image/png" && image.size === photo.length && image.width === 1,
  "the photo is an image with the stored type and size",
  image,
);
check(image?.name === "photo-20261027-120000.png", "folders are stripped from names", image?.name);
check(Boolean(image?.thumbId) && typeof image?.thumbUrl === "string", "the thumbnail goes with it", image);
check(file?.kind === "file" && file.mimeType === "application/pdf" && file.width === undefined, "the PDF is a file", file);
const fetched = image?.url ? await download(image.url) : null;
check(fetched !== null && fetched.equals(photo), "the computer downloads the photo's bytes from its url");
check(command?.text === "What is in these?", "the text is trimmed", command?.text);

check(await computer.mutation("bridge:claimCommand", { hostId, commandId }), "the computer claims the prompt");
const stored = command.attachments.map(({ url: _u, thumbUrl: _t, ...rest }) => rest);
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    {
      key: `t:c${commandId}`,
      kind: "user",
      text: "What is in these?",
      origin: "remote",
      commandId,
      fromLabel: "E2E iPhone",
      attachments: stored,
      at: Date.now(),
    },
  ],
});
const transcript = await phone.query("sessions:transcript", { sessionDocId });
const item = transcript.events.find((e) => e.kind === "user");
check(item?.attachments?.length === 2 && typeof item.attachments[0].url === "string", "the transcript item has them with urls", item);
check(item?.attachments?.[0]?.thumbUrl === image?.thumbUrl, "with the same thumbnail url");
const page = await phone.query("sessions:events", { sessionDocId, paginationOpts: { numItems: 10, cursor: null } });
check(typeof page.page.find((e) => e.kind === "user")?.attachments?.[1]?.url === "string", "sessions:events has urls too");
const prompts = await phone.query("commands:forSession", { sessionDocId });
check(prompts.find((p) => p._id === commandId)?.attachments?.length === 2, "commands:forSession lists them");
check(prompts.find((p) => p._id !== commandId)?.attachments?.length !== 2, "other prompts have none");

console.log("A prompt typed on the computer");
const localImage = await upload(computer, png, "image/png");
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    {
      key: "t:p1",
      kind: "user",
      text: "",
      origin: "local",
      attachments: [
        { name: "Screenshot.png", mimeType: "image/png", size: 0, kind: "image" },
        { name: "notes.md", mimeType: "text/markdown", size: 12, kind: "file" },
      ],
      at: Date.now(),
    },
  ],
});
let local = (await phone.query("sessions:transcript", { sessionDocId })).events.find((e) => e.key === "t:p1");
check(local?.attachments?.[0]?.url === null && local.attachments[0].storageId === undefined, "an image not uploaded yet has no url", local);
await computer.mutation("bridge:pushEvents", {
  hostId,
  sessionDocId,
  events: [
    {
      key: "t:p1",
      kind: "user",
      text: "",
      origin: "local",
      attachments: [
        { storageId: localImage, name: "Screenshot.png", mimeType: "image/png", size: 0, kind: "image", width: 1, height: 1 },
        { name: "notes.md", mimeType: "text/markdown", size: 12, kind: "file" },
      ],
      at: Date.now(),
    },
  ],
});
local = (await phone.query("sessions:transcript", { sessionDocId })).events.find((e) => e.key === "t:p1");
check(
  typeof local?.attachments?.[0]?.url === "string" && local.attachments[0].size === png.length,
  "once uploaded the same item gets its url and the stored size",
  local?.attachments?.[0],
);
check(local?.attachments?.[1]?.url === null && local.attachments[1].name === "notes.md", "a file only on the computer stays by name");
const hash = createHash("sha256").update(png).digest("base64");
const known = await computer.query("files:known", { sessionId, sha256: [hash, "nope"] });
check(Boolean(known[hash]?.storageId) && known.nope === undefined, "files:known finds the session's image by SHA-256", known);
const imageHash = createHash("sha256").update(photo).digest("base64");
const knownPhoto = await computer.query("files:known", { sessionId, sha256: [imageHash] });
check(knownPhoto[imageHash]?.thumbId === thumbId, "with its thumbnail when it had one", knownPhoto);
check(
  Object.keys(await phone.query("files:known", { sessionId, sha256: [hash] }).catch(() => ({ x: 1 }))).length === 1,
  "a phone cannot ask",
);

console.log("Refusals");
check(
  (await errorOf(phone.mutation("commands:sendPrompt", { sessionDocId, text: " ", clientId: crypto.randomUUID() }))).startsWith("INVALID"),
  "an empty prompt without attachments is INVALID",
);
const onlyPhoto = await errorOf(
  phone.mutation("commands:sendPrompt", {
    sessionDocId,
    text: "",
    clientId: crypto.randomUUID(),
    attachments: [{ storageId: await upload(phone, png, "image/png"), name: "a.png" }],
  }),
);
check(onlyPhoto === "ok", "a photo alone is a prompt", onlyPhoto);
const theirs = await upload(stranger, png, "image/png");
check(
  (await errorOf(
    phone.mutation("commands:sendPrompt", { sessionDocId, text: "x", clientId: crypto.randomUUID(), attachments: [{ storageId: imageId, name: "a" }] }),
  )) === "ok",
  "the same person may send an upload again",
);
const strangerSession = await errorOf(
  stranger.mutation("commands:sendPrompt", { sessionDocId, text: "x", clientId: crypto.randomUUID() }),
);
check(strangerSession.startsWith("NOT_FOUND"), "someone else's session is NOT_FOUND", strangerSession);
// Eve's upload, claimed by Eve first (in a session of her own), can't be sent by Ada.
const eveComputer = authedClient(await link("eve", "computer", "Eve Mac"));
const eveHost = await eveComputer.mutation("bridge:connect", {
  instanceId: `att-e2e-eve-${process.pid}`,
  app: "tui",
  appVersion: "crok e2e",
  canAdopt: true,
  features: ["attachments"],
});
const eveSession = await eveComputer.mutation("bridge:upsertSession", {
  hostId: eveHost.hostId,
  sessionId: `0199eeee-${stamp.toString(16)}`,
  fields: { title: "Eve", cwd: "/Users/eve", status: "idle" },
});
await stranger.mutation("commands:sendPrompt", {
  sessionDocId: eveSession.sessionDocId,
  text: "",
  clientId: crypto.randomUUID(),
  attachments: [{ storageId: theirs, name: "eve.png" }],
});
const stolen = await errorOf(
  phone.mutation("commands:sendPrompt", { sessionDocId, text: "x", clientId: crypto.randomUUID(), attachments: [{ storageId: theirs, name: "a" }] }),
);
check(stolen.startsWith("FORBIDDEN"), "someone else's upload is FORBIDDEN", stolen);
const gone = await errorOf(
  phone.mutation("commands:sendPrompt", { sessionDocId, text: "x", clientId: crypto.randomUUID(), attachments: [{ storageId: "kg2bogus", name: "a" }] }),
);
check(gone.startsWith("INVALID"), "a bogus upload id is INVALID", gone);
const many = Array.from({ length: 11 }, (_, i) => ({ storageId: imageId, name: `${i}.png` }));
const tooMany = await errorOf(phone.mutation("commands:sendPrompt", { sessionDocId, text: "x", clientId: crypto.randomUUID(), attachments: many }));
check(tooMany.startsWith("INVALID"), "11 attachments are INVALID", tooMany);

console.log("An older crok");
const oldComputer = authedClient(await link("ada", "computer", "E2E Old Mac"));
const old = await oldComputer.mutation("bridge:connect", {
  instanceId: `att-e2e-old-${process.pid}`,
  app: "tui",
  appVersion: "crok 2.0.3",
  canAdopt: true,
  features: ["create", "config", "git", "setup", "catalog"],
});
const oldSession = await oldComputer.mutation("bridge:upsertSession", {
  hostId: old.hostId,
  sessionId: `0199o1d0-${stamp.toString(16)}`,
  fields: { title: "Old", cwd: "/Users/e2e/old", status: "idle" },
});
const refused = await errorOf(
  phone.mutation("commands:sendPrompt", {
    sessionDocId: oldSession.sessionDocId,
    text: "look",
    clientId: crypto.randomUUID(),
    attachments: [{ storageId: await upload(phone, png, "image/png"), name: "a.png" }],
  }),
);
check(refused.startsWith("INVALID") && refused.includes("photos and files"), "a crok without `attachments` refuses them", refused);
check(
  (await errorOf(phone.mutation("commands:sendPrompt", { sessionDocId: oldSession.sessionDocId, text: "plain", clientId: crypto.randomUUID() }))) === "ok",
  "text-only prompts still go to it",
);
const oldMe = await oldComputer.query("users:me", {});
const oldCreate = await errorOf(
  phone.mutation("sessions:create", {
    deviceId: oldMe.device.deviceId,
    path: "/Users/e2e/old",
    clientId: crypto.randomUUID(),
    attachments: [{ storageId: await upload(phone, png, "image/png"), name: "a.png" }],
  }),
);
check(oldCreate.startsWith("OFFLINE") && oldCreate.includes("photos and files"), "nor does it start a session with them", oldCreate);

console.log("New sessions");
const created = await phone.mutation("sessions:create", {
  deviceId,
  path: `${project}/new`,
  clientId: crypto.randomUUID(),
  attachments: [{ storageId: await upload(phone, pdf, "application/pdf"), name: "spec.pdf" }],
});
const createInbox = await computer.query("bridge:inbox", { hostId });
const createCommand = createInbox.commands.find((c) => c._id === created.commandId);
check(
  createCommand?.type === "create" && createCommand.text === "" && createCommand.attachments?.[0]?.name === "spec.pdf",
  "a new session's first prompt can be a file alone",
  createCommand,
);
const createdRow = await phone.query("sessions:get", { sessionDocId: created.sessionDocId });
check(createdRow.status === "running", "that session starts running", createdRow.status);
const createdPrompts = await phone.query("commands:forSession", { sessionDocId: created.sessionDocId });
check(createdPrompts[0]?.attachments?.[0]?.kind === "file", "and its prompt is listed with the file");

console.log("Removing a session removes its files");
await computer.mutation("bridge:closeSession", { hostId, sessionId });
await phone.mutation("sessions:remove", { sessionDocId });
let removed = false;
for (let i = 0; i < 20 && !removed; i++) {
  await sleep(250);
  removed = (await download(image.url)) === null;
}
check(removed, "the photo's url stops working");

await computer.mutation("bridge:disconnect", { hostId });
await oldComputer.mutation("bridge:disconnect", { hostId: old.hostId });
await eveComputer.mutation("bridge:disconnect", { hostId: eveHost.hostId });
for (const client of [computer, phone, stranger, oldComputer, eveComputer]) await client.close();
console.log(failures === 0 ? "All attachment checks passed." : `${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
