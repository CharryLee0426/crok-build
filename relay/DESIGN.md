# Crok remote control — design

Status: first implementation, 2026-10-15 (branch `worktree-remote-relay`); new sessions from any device, slash commands
in every composer, and the model and thinking level from anywhere, 2026-10-16 (branch `worktree-relay-commands`).

Crok runs on your computers (the `crok` TUI and Crok Desktop). Remote control lets you follow and steer those sessions
from a phone, a browser or another of your computers: see every session on every computer, read the transcript as it
streams, send a prompt to any of them (open or not, as long as its computer runs crok), stop the running turn, answer
its permission requests, and look at the session's info (model, tokens, cost, context, plan). Every device is a peer:
a computer lists the other computers' sessions next to its own and works in them like in its own.

```
 computers                                   relay (Convex)                        viewers
┌──────────────────────────┐                ┌─────────────────────────┐          ┌──────────────────────┐
│ crok TUI  ─┐             │  device JWT    │ users  devices  hosts   │  Clerk   │ web app (Next.js,    │
│            ├─ bridge ────┼── WebSocket ──▶│ sessions  events        │◀─ JWT ───│   Vercel)            │
│ Crok Desktop task ─┐     │                │ commands  sessionViews  │          ├──────────────────────┤
│  (crok agent stdio)├ bridge               │ deviceLogins            │◀─ device ─│ iOS app  Android app │
└──────────────────────────┘                └─────────────────────────┘    JWT   └──────────────────────┘
```

- **Relay**: a Convex deployment (`relay/convex`). Realtime queries are the push channel in both directions: viewers
  subscribe to sessions and transcripts, computers subscribe to their command inbox.
- **Web app**: Next.js on Vercel (`relay/app`), sign-in with Clerk (GitHub or Google). It is also where devices are
  approved.
- **Bridge**: a task inside every signed-in crok process, next to the agent (`crates/codegen/crok-remote`,
  `xai-grok-shell/src/remote_control`). It mirrors that process's sessions and executes commands.
- **Phone apps**: `mobile/iOS` (SwiftUI) and `mobile/Android` (Kotlin, Jetpack Compose). Sign-in is required.

Remote sign-in is separate from LLM provider sign-in (`crok login <provider>`): it links a device to a person's relay
account and has nothing to do with model keys. It is optional on computers and required on phones (a phone app has
nothing to show without it).

## 1. Identity and sign-in

### People

People sign in only on the web app, through Clerk, with GitHub or Google. Convex validates Clerk's session JWT (the
Clerk "Convex integration", `aud: "convex"`) via `auth.config.ts`. `users.ensure` stores the person on first sign-in,
keyed by the identity's `tokenIdentifier`.

### Devices

A computer or a phone is a **device**, linked to a person through a device-code flow (RFC 8628 style), the same flow on
every platform:

1. The device calls `deviceAuth:start({ kind, name, platform, client })` and gets a secret `deviceCode`, a short
   `userCode` (`BCDF-GHJK`: 8 consonants, ten minutes) and `verificationUrlComplete` (`<web>/link?code=BCDF-GHJK`).
2. It shows the code and opens the link in a browser: the computer's own browser for crok (plus a QR code in the
   terminal), a system browser sheet for the phone apps (`ASWebAuthenticationSession`, Android Auth Tab / Custom Tab).
3. The person signs in on the web (Clerk) and sees *which* device is asking (name, platform, app, time), then approves
   (`deviceAuth:approve`). A signed-in phone can approve too, by scanning the computer's QR code — Telegram's QR login.
4. The device polls `deviceAuth:poll({ deviceCode })` every 2 s. Once approved it receives, exactly once, a
   **refresh token** (`crr_…`, 256 bits) and a first **access JWT**.
5. The device keeps the refresh token (computer: `~/.crok/remote/credentials.json`, mode 0600, like
   `provider-auth/*.json`; iOS: Keychain; Android: Keystore-encrypted). Only its SHA-256 is stored on the relay.
6. `deviceAuth:refresh({ refreshToken })` returns a new one-hour access JWT. Clients call it before expiry and on every
   reconnect (the Convex clients' auth callbacks do this).
7. `deviceAuth:logout({ refreshToken })` unlinks the device; `devices:revoke` signs out any device from another one.

No token ever travels in a URL. The browser only sees the user code; a phone's browser sheet ends on `crok://signed-in`
just to close itself, and the app then polls.

The access JWT is RS256, signed by the deployment itself inside the `refresh`/`poll` mutations (Web Crypto
RSASSA-PKCS1-v1_5; no randomness needed, so it is allowed in a mutation). `auth.config.ts` declares it as a custom JWT
provider: issuer = the deployment's site URL, audience `crok-device`, keys from `DEVICE_JWKS_DATA_URI`. Its subject is
the device id. Every function resolves the caller through `lib/auth.ts:getViewer`, which loads the device and refuses a
revoked one — so revocation takes effect on the next call, not when the JWT expires.

Why not Clerk on the devices? Clerk session tokens live 60 s and are refreshed only by Clerk's own SDKs; a Rust CLI and
two native apps would each need a Clerk integration. The device flow keeps Clerk on the web, gives every native client
the same tiny auth surface, and lets the person see and revoke every linked device.

### Threats considered

- **Stolen refresh token**: revoke the device from any other device (Devices screen, `devices:revoke`).
- **Device-code phishing** (an attacker gets someone to approve the attacker's code): the approval page names the
  device and when it asked, and says to approve only a sign-in you just started. Codes live ten minutes.
- **Brute-forcing user codes**: 20⁸ codes, ten-minute lifetime, approval requires a signed-in account; a guess links
  the attacker's account to someone else's device at worst, not the reverse.
- **Remote execution**: a prompt from another device runs on the computer with the session's own permission mode,
  also in a session nobody has open there (crok opens it). Permission requests are offered on the relay to every device
  of the person and, for a session the computer shows, on the computer too; the first answer counts. A computer can
  turn control off (`[remote] enabled = false`) or sign out.
- **Data at rest on the relay**: transcripts are stored in the person's own Convex deployment. End-to-end encryption is
  listed under future work.

## 2. Data model (`relay/convex/schema.ts`)

| table | one row is | written by | notes |
|---|---|---|---|
| `users` | a person | `users.ensure` | `tokenIdentifier` from Clerk |
| `devices` | a linked computer or phone | `deviceAuth`, `devices`, `bridge` | `refreshTokenHash`, coarse `lastSeenAt`, `online`, `revokedAt` |
| `deviceLogins` | a sign-in in progress | `deviceAuth` | `deviceCodeHash`, `userCode`, `status` pending → approved → consumed |
| `hosts` | one running crok process | `bridge.connect/heartbeat` | heartbeat every 30 s touches only this row; `canAdopt`: it opens sessions nobody runs |
| `modelLists` | the models a computer's crok can run, with their thinking levels | `bridge.setModels` | one per computer, the latest from any of its processes (§2, "Model and thinking level") |
| `sessions` | a crok session on a computer: mirrored live, or listed from disk | `bridge.upsertSession`, `bridge.catalogBatch`, `bridge.setPending` | title, cwd, `projectPath`, model, status, `online`, preview, plan, usage, unread counters, `position`, `historyState`, `pending` (a permission request) |
| `projects` | a folder sessions are grouped under, per computer | `bridge`, `sessions.reorderProjects` | `path`, `position` (hand-placed order) |
| `catalogSyncs` | the last "list every session on disk" per computer | `bridge.beginCatalog/finishCatalog` | one crok process per computer does it, at most every 10 min |
| `events` | one transcript item | `bridge.pushEvents` | `seq` order, `key` for in-place updates (streaming text, tool status) |
| `commands` | a prompt / stop / info / answer / history / create / config request | viewers; `bridge.claim/complete` | `pending → delivered → done/failed`, `clientId` for idempotency; `interactionId` for an answer; `configId` for a config change |
| `commandLists` | the slash commands a session (or, as a fallback, its computer) offers | `bridge.setCommands` | kept out of `sessions` so the list query does not re-send them |
| `sessionViews` | "someone has this session open" | `sessions.watch` | the bridge streams finely only while one is live |

Write-amplification rules (Convex re-runs a subscription whenever a document it read changes):

- Heartbeats touch `hosts`, which no viewer query reads. `devices.lastSeenAt` moves at most every 5 minutes.
  `online` flags flip only on change.
- Streaming text patches one `events` row; the `sessions` row changes only when an event is inserted (activity time,
  unread count) or a field actually changes (`upsertSession` diffs).
- The bridge flushes streamed text every ~0.75 s while someone watches the session and only at message boundaries
  otherwise.

A cron (`crons.ts`, every minute) marks hosts offline after 90 s without a heartbeat (their sessions go offline, the
device too if no other host is up), fails commands nobody picked up within 5 minutes, and drops expired sign-ins and
views. Daily, it drops the transcripts of sessions idle for 30 days (the sessions stay listed, and on the computer;
opening one reads the transcript again).

### Projects and order

Every session belongs to a **project** on its computer: a crok worktree's source workspace, else the git root, else
the cwd (`projectPath`; the computer decides, the relay guesses the deepest known project holding the cwd until it
does). A project is named by its **key** `<deviceId>:<path>` and shown by its last path component.

Order, for projects in the list and for sessions in a project: items never placed by hand come first, most recently
active first; hand-placed ones follow by `position`. Pinned sessions lead their project. Reordering writes positions
for every item of that level (so later newcomers appear on top), and a subset reorder (one computer's projects) keeps
the others in place. "Sort by recent activity" clears the positions. The order lives on the relay, so the web and every
phone share it; Crok Desktop's own sidebar order is separate.

### Every session, not only running ones

A running crok (one per computer at a time, at most every 10 minutes) lists every session on disk — not hidden ones
(subagents), headless runs, unused husks, or sessions under the system's temp folder — and uploads that **catalog**:
title, cwd, project, times, model, last-turn summary. New ones arrive offline with `historyState: "none"`; sessions
deleted on the computer are dropped. When a viewer opens one (`sessions:watch`) while the computer is online, the
relay queues a `history` command; any crok there claims it, reads the transcript from disk (`x.ai/session/updates`,
last 20 turns) and pushes it (`historyState` → `requested` → `ready`).

### Prompts for sessions nobody runs

A session no crok process runs still takes prompts while its computer is online. `commands:sendPrompt` refuses only
when no crok on that computer can open sessions (`OFFLINE`: no online host with `canAdopt`). The inbox offers such a
prompt (`adopt: true`) to every crok of the computer; the first `claimCommand` makes that crok the session's runner at
once (`hostId`, `online`, `status: running`), so the next commands for the session (Stop, more prompts, answers) go to
it while it opens the session (§4, "Adopted sessions"). Stop for a session nobody runs fails the prompts no crok
picked up yet and is done at once; info is answered at once from the stored row (`result.stored: true`).

### Permission requests from any device

While a session waits on a permission request (run this command, edit that file), its runner publishes it as
`sessions.pending` (`{id, kind: "permission", title, detail?, toolKind?, options: [{optionId, name, kind}], at}`,
`bridge:setPending`) and sets the status to `waiting`. Any device answers with `commands:answer({sessionDocId,
interactionId, optionId})`; the first answer counts (an answer for a request that is no longer pending is `EXPIRED`).
For a session the computer shows, the computer asks too, and whichever answer comes first goes to the agent; the other
side drops its prompt (`x.ai/remote/permission_resolved {sessionId, toolCallId}` tells the TUI and Crok Desktop).

### New sessions from any device

Any device starts a session in any project of any computer that runs crok: `sessions:create({deviceId, path,
text?, clientId})`. The relay adds the session at once — `sessionId: "pending:<clientId>"`, `starting: true` in rows
and in `sessions:get`, `cwd` = `projectPath` = `path`, title from the prompt's first line (else "New session"), status
`running` with a prompt and `idle` without — and a `create` command carrying the prompt. The caller opens the session
right away (its own prompt shows optimistically, ticks from `commands:forSession`, which lists `create` commands with
text like prompts).

The inbox offers a `create` command to every crok of that computer with `canAdopt` (like a prompt for a session nobody
runs). The first to claim it becomes the session's runner, opens a new crok session in `path` (`session/new`), hidden
from its front end like an adopted session, and swaps the placeholder id for the real one (`bridge:bindSession`); from
then on it is an ordinary adopted session: the prompt runs as `remote-<commandId>` and the command is `done` when the
turn ends (at once, with `result.sessionId`, without a prompt). If the computer cannot open it, the command fails, the
session gets status `error` and an error item, and a later prompt to it tries again (a prompt to an offline `pending:`
session becomes a `create`). Catalog uploads never drop `pending:` sessions.

`OFFLINE` when no crok there can open sessions; `INVALID` for a relative path.

Older crok processes (before 2026-10-16) cannot parse the new command types: a host lists what it handles in
`bridge:connect`'s `features` (`["create", "config"]`), and `create` / `config` commands go only to hosts that list
them. With only older crok running on a computer, `sessions:create` and `commands:setConfig` fail with a message
asking to update crok there, and `sessions:get`'s `models` stays null (older crok does not publish them). Any folder of that computer works, not
only listed projects (the clients offer the projects; the TUI and Crok Desktop also the folder of an open session).

### Model and thinking level

Each crok process publishes what it can run (`bridge:setModels`, on sign-in and when its catalog changes) into its
computer's `modelLists` row: `[{id, name, description?, efforts: [{id, name, value?, description?}], defaultEffort?}]`, the
computer's own choices (its providers, its sign-ins). `sessions:get` returns them as `models` while the computer is
online, else null (nothing to choose from while it is offline), next to the session's current `model` and `effort`. A
model with an empty `efforts` has no thinking level. An effort's `id` is what `commands:setConfig` takes; its `value` is
the level it stands for (`low`, `high`, …), which is what the session's `effort` holds: the current choice is the one
whose `value ?? id` equals `effort`. `defaultEffort` is an `id`.

`commands:setConfig({sessionDocId, configId: "model" | "reasoning_effort", value})` changes it, as if picked on the
computer (`session/set_config_option`). For a session nobody runs, the first crok there to claim it opens it hidden
(as for a prompt) and applies it. The command's `result` is `{model, effort}` after the change; the session row follows
through the usual upsert. Values are checked against `models` when the relay has them (`INVALID`).

### Slash commands

A session's slash commands — crok's own (`compact`, `context`, `memory`, …), skills and workflows, as the agent
advertises them (ACP `available_commands_update`) — are published per session (`bridge:setCommands`, only when they
change) into `commandLists`, with a copy per computer as the fallback for sessions no crok runs. `sessions:commands`
returns `{commands: [{name, description, hint?}], source: "session" | "computer" | "none"}`. Such a command is sent as an
ordinary prompt (`/compact`, `/review-pr 42`); crok resolves it on the computer.

Clients add their own commands in front of them, handled on the device: `/new [prompt]` (a session in the same
project), `/model [name]`, `/think [level]`, `/stop`, `/info` (§5, "Commands in the composer").

## 3. API (the contract every client codes against)

All errors are `ConvexError<{ code, message }>` with `code` one of `UNAUTHENTICATED`, `REVOKED` (sign the device out
locally), `FORBIDDEN`, `NOT_FOUND`, `OFFLINE`, `INVALID`, `EXPIRED`, `NOT_CONFIGURED`. Numbers are JSON numbers
(`v.number()`, float64): native clients must send `Double`, not `Int`. Viewer functions take `sessionDocId` and
`commandId` as plain strings: a malformed or foreign id is `NOT_FOUND`.

### Sign-in (no auth needed for `start`, `poll`, `refresh`, `logout`)

| function | args | returns |
|---|---|---|
| `deviceAuth:start` (mutation) | `kind: "computer"\|"phone", name, platform, client` | `deviceCode, userCode, verificationUrl\|null, verificationUrlComplete\|null, expiresAt, interval` |
| `deviceAuth:poll` (mutation) | `deviceCode` | `{status:"pending"\|"denied"\|"expired"}` or `{status:"approved", deviceId, refreshToken, accessToken, accessTokenExpiresAt, user:{name,email,imageUrl}}` |
| `deviceAuth:refresh` (mutation) | `refreshToken` | `deviceId, accessToken, accessTokenExpiresAt` — throws `REVOKED` |
| `deviceAuth:logout` (mutation) | `refreshToken` | `null` |
| `deviceAuth:pendingLogin` (query, signed in) | `userCode` (any case/spacing) | `null` or `{userCode, kind, name, platform, client, createdAt, expiresAt, status: pending\|approved\|denied\|consumed\|expired}` |
| `deviceAuth:approve` / `deny` (mutation, signed in) | `userCode` | `{deviceId, kind, name}` / `null` |

Native clients may call these over Convex's HTTP API (`POST <deployment>/api/mutation` with
`{"path":"deviceAuth:refresh","args":{…},"format":"json"}` → `{"status":"success","value":…}` or
`{"status":"error","errorMessage","errorData"}`), which avoids re-entering the WebSocket client from its own auth
callback.

### Account and devices (signed in: web user or device)

| function | args | returns |
|---|---|---|
| `users:ensure` (mutation, web) | — | `{userId, name, email, imageUrl}` |
| `users:me` (query) | — | `null` or `{userId, name, email, imageUrl, device: null\|{deviceId, kind, name, platform, client}}` |
| `devices:list` (query) | — | `[{_id, kind, name, platform, client, createdAt, lastSeenAt, online, isCurrent, liveSessionCount}]` current first |
| `devices:rename` (mutation) | `deviceId, name` | `null` |
| `devices:revoke` (mutation) | `deviceId` | `null` |
| `devices:revokeOthers` (mutation) | — | `{count}` |

### Sessions and transcript (viewers)

| function | args | returns |
|---|---|---|
| `sessions:groups` (query) | — | `[{key, deviceId, deviceName, deviceOnline, path, name, placed, lastActivityAt, sessions: [row]}]` — the main list: non-archived sessions grouped by project, both levels in list order (above) |
| `sessions:list` (query) | `archived?: boolean` | `[row]` flat, pinned first, then newest (the Archived tab) |
| `sessions:get` (query) | `sessionDocId` | `{…row fields, effort, gitBranch, devicePlatform, createdAt, plan:[{content,status}], usage: null\|{inputTokens, outputTokens, cachedTokens, reasoningTokens, costUsd, contextTokens, contextWindow}, eventSeq, pending: null\|{id, kind, title, detail?, toolKind?, options:[{optionId, name, kind}], at}, models: null\|[{id, name, description?, efforts:[{id, name, value?, description?}], defaultEffort?}]}` |
| `sessions:create` (mutation) | `deviceId, path, text?, clientId` (UUID) | `{sessionDocId, commandId}` — a new session in `path` on that computer (§2, "New sessions from any device"); same `clientId` → same session; `OFFLINE`, `INVALID`, `NOT_FOUND` (not one of your computers), `FORBIDDEN` (a phone) |
| `sessions:commands` (query) | `sessionDocId` | `{commands:[{name, description, hint?}], source: "session"\|"computer"\|"none"}` — the agent's slash commands, without the leading `/` |
| `sessions:reorderProjects` (mutation) | `keys: string[]` | `null` — some project keys in their new order (all, or one computer's) |
| `sessions:reorderSessions` (mutation) | `projectKey, sessionDocIds: string[]` | `null` — some of the project's sessions in their new order |
| `sessions:resetOrder` (mutation) | `projectKey?` | `null` — with a key: that project's sessions back to newest first; without: the projects |

A **row** is `{_id, sessionId, title, cwd, model, status, online, app, deviceId, deviceName, deviceOnline, preview,
previewKind, lastActivityAt, pinned, archived, unread, plan: null|{done,total}, projectKey, projectPath, projectName,
historyState: null|"none"|"requested"|"ready", starting}`; `starting` = made by `sessions:create` and not open on its
computer yet. `historyState` `none`/`requested` with no events: the transcript is
still only on the computer — show "Loading from <computer>…" while `deviceOnline`, else "<computer> is offline; this
session's history shows once crok runs there".
| `sessions:events` (paginated query) | `sessionDocId, paginationOpts:{numItems, cursor}` | `{page:[event], isDone, continueCursor}` newest first |
| `sessions:markRead` / `watch` (mutation) | `sessionDocId` | `null` — call `watch` on open and every 60 s (it also fetches a listed session's transcript) |
| `sessions:setPinned` / `setArchived` (mutation) | `sessionDocId, pinned\|archived` | `null` |
| `sessions:remove` (mutation) | `sessionDocId` | `null` (offline sessions only) |

An **event** is `{_id, seq, key, kind, text, title?, toolKind?, status?, origin?, commandId?, fromLabel?, at}`:

- `kind: "user"` — a prompt; `origin: "remote"`, `commandId` and `fromLabel` (the sender: a device name or "Web")
  when it came from a phone or the web.
- `kind: "assistant"` — Markdown reply text (may still be streaming: same `key`, growing `text`).
- `kind: "thought"` — reasoning summary; show collapsed.
- `kind: "tool"` — `title` (e.g. `Run cargo test`), `toolKind` (`read`, `edit`, `delete`, `move`, `search`,
  `execute`, `think`, `fetch`, `other`), `status` (`pending`, `in_progress`, `completed`, `failed`), `text` = short
  detail (command, path, output tail).
- `kind: "system"` — a turn marker or notice (`status` carries the stop reason: `end_turn`, `cancelled`, `max_tokens`,
  `refusal`, …); `kind: "error"` — a failure line.

Session `status`: `idle`, `running` (a turn is in progress: show Stop), `waiting` (the agent asked a question or a
permission; `pending` holds a permission request any device can answer), `error`. `online: false` = no crok process
runs it now; it still takes prompts while `deviceOnline` (its computer opens it). Clients gate the composer on
`deviceOnline`.

### Commands (viewers)

| function | args | returns |
|---|---|---|
| `commands:sendPrompt` (mutation) | `sessionDocId, text, clientId` (UUID) | `{commandId}`; same `clientId` → same command; throws `OFFLINE` only when no crok on its computer can take it |
| `commands:stop` (mutation) | `sessionDocId` | `{commandId}` (done at once for a session nobody runs) |
| `commands:requestInfo` (mutation) | `sessionDocId` | `{commandId}`; the answer arrives in `commands:get(...).result` (at once, `stored: true`, for a session nobody runs) |
| `commands:answer` (mutation) | `sessionDocId, interactionId, optionId` | `{commandId}`; throws `EXPIRED` when that request is no longer pending |
| `commands:setConfig` (mutation) | `sessionDocId, configId: "model"\|"reasoning_effort", value` | `{commandId}`; `result` = `{model, effort}` once done; `INVALID` for a value not in `models`; `OFFLINE` |
| `commands:get` (query) | `commandId` | the command row or `null` |
| `commands:forSession` (query) | `sessionDocId` | recent prompts `[{_id, type, clientId, text, status, error, fromLabel, fromDeviceId, mine, createdAt, updatedAt}]` (`type` `prompt`, or `create` for the first prompt of a new session); `mine` = sent by this caller |
| `commands:retry` / `discard` (mutation) | `commandId` | `null` |

An info `result` is `{ model, effort, cwd, gitBranch, title, createdAt, usage: {inputTokens, outputTokens,
cachedTokens, reasoningTokens, costUsd}, context: {used, window}, messages, sessionId }` (fields may be missing).

Prompt status ticks (Telegram's clock → ✓ → ✓✓ → red "!"): `pending` = not yet picked up; `delivered` = the
computer accepted it (it is in the transcript or queued behind the running turn); `done` = its turn finished;
`failed` = `error` says why (offline, busy, rejected). A viewer shows its own prompt optimistically from the moment
of sending (keyed by `clientId`) until the transcript holds the user event whose `commandId` matches.

### Bridge (linked computers only)

| function | args | returns |
|---|---|---|
| `bridge:connect` | `instanceId, app: tui\|desktop\|cli, appVersion, pid?, canAdopt?, features?` | `{hostId, deviceId, serverTime}` — `features`: command types beyond the first relay's it handles (`create`, `config`) |
| `bridge:heartbeat` | `hostId` | `{serverTime}` (every 30 s) |
| `bridge:disconnect` | `hostId` | `null` |
| `bridge:upsertSession` | `hostId, sessionId, fields:{title?, cwd?, model?, effort?, gitBranch?, status?, preview?, previewKind?, plan?, usage?, createdAt?, lastActivityAt?, projectPath?}` | `{sessionDocId, eventSeq, created}` |
| `bridge:closeSession` | `hostId, sessionId` | `null` |
| `bridge:pushEvents` | `hostId, sessionDocId, replace?, events:[{key, kind, text, title?, toolKind?, status?, origin?, commandId?, at}]` (≤100), `preview?, previewKind?` | `{eventSeq}` — also for an offline session of this computer (history) |
| `bridge:inbox` (query) | `hostId` | `{commands:[{_id, sessionDocId, sessionId, cwd, type, text, interactionId, configId, adopt, fromLabel, fromKind, createdAt}], views:[{sessionDocId, sessionId, until}], hosted:[sessionId], serverTime}` — `type: "history"` for offline sessions goes to every host of the computer; a prompt or config change for one (`adopt: true`) and every `create` (`cwd` = the folder, `text` the prompt or null) to every host with `canAdopt`; `hosted` = the sessions the relay has this host running |
| `bridge:setPending` | `hostId, sessionId, pending?` | `null` — the session's permission request, or none (absent) once answered or gone |
| `bridge:beginCatalog` | `hostId` | `{syncId}` or `null` (another host did it lately, or is doing it) |
| `bridge:catalogBatch` | `hostId, syncId, sessions:[{sessionId, title, cwd, projectPath, createdAt, lastActivityAt, model?, effort?, gitBranch?, preview?}]` (≤100) | `{added}` |
| `bridge:finishCatalog` | `hostId, syncId, sessionIds: string[]` (all listed) | `{removed}` — offline sessions of this computer not listed are dropped |
| `bridge:claimCommand` | `hostId, commandId` | `boolean` — claiming a prompt, config change or create for a session nobody runs makes this host its runner |
| `bridge:bindSession` | `hostId, sessionDocId, sessionId` | `{sessionDocId, eventSeq}` — the crok session this host opened for a claimed `create` replaces the `pending:` id |
| `bridge:setModels` | `hostId, models:[{id, name, description?, efforts:[{id, name, value?, description?}], defaultEffort?}]` (≤200) | `null` — written only when it changed |
| `bridge:setCommands` | `hostId, sessionId, commands:[{name, description, hint?}]` (≤500) | `null` — the session's slash commands (and this computer's fallback copy) |
| `bridge:completeCommand` | `hostId, commandId, status: done\|failed, result?, error?` | `null` |

## 4. The bridge (computer side)

Both front ends host the same ACP agent, `MvpAgent` (`xai-grok-shell/src/agent/mvp_agent`):

- the TUI runs it in-process on its `acp-agent-worker` thread (`xai-grok-pager/src/acp/spawn.rs`);
- Crok Desktop runs one `crok agent stdio` process per open task (`xai-grok-shell/src/agent/app.rs`,
  `spawn_agent_local`).

The bridge is started right there, on the agent's `LocalSet`, holding an `Rc<MvpAgent>`. It needs no transport of its
own into the agent:

- **Outgoing** (agent → front end): the agent's gateway channel is wrapped by a tee that forwards every message
  unchanged and hands the bridge a copy of session notifications (`session/update`: message / thought chunks, tool
  calls and updates, plan; `_x.ai/session_notification`: turn completed, pending interaction, title generated, model
  changed, usage).
- **Incoming** (front end → agent): the agent handed to the connection is wrapped (like `RequestLog`) so the bridge sees
  `session/new`, `session/load`, `session/prompt` and `session/cancel` — the user's own prompts, which Crok Desktop does
  not ask the agent to echo.
- **Commands**: a phone's prompt becomes `MvpAgent::prompt` with prompt id `remote-<commandId>` (an ordinary user
  origin, so the TUI adopts the turn and shows it like a typed one); stop becomes `MvpAgent::cancel`; info calls the
  `x.ai/session/info` and `x.ai/session/usage` extension methods. Before running a remote prompt the bridge sends the
  front end `_x.ai/remote/prompt { sessionId, promptId, text, from }` so Crok Desktop can show the prompt and its
  running state; the TUI already gets the prompt through its user-message echo.
- A prompt that arrives during a running turn waits in the bridge and runs when the turn ends (status `delivered`).

Network I/O runs on its own thread with its own Tokio runtime (`crok-remote`: the Convex Rust client over WebSocket
for subscriptions and mutations, reqwest for the token endpoints). The agent side and the network side talk over
channels, so a slow network never stalls the agent.

Mirrored live: sessions that have a prompt or were loaded with history, not subagent children, hidden sessions or Crok
Desktop's helper processes (`CROK_REMOTE_BRIDGE=0`). Listed: every session on disk (the catalog, §2), uploaded by one
bridge per computer on sign-in and every 10 minutes after (`persistence::list_summaries`, cached by file time, so a
re-list reads only changed summaries); history requests for listed sessions are answered by whichever bridge claims
them. One-shot agents (`crok models`, `crok worktree`, headless `-p`)
never start a bridge. On first sight of a session whose relay copy is empty, the bridge backfills the tail of its
transcript from `updates.jsonl` (`x.ai/session/updates`).

Turn state survives sign-in at any time: the tee always passes on the once-per-turn `x.ai/session/prompt_complete`,
and on sign-in the bridge reads each session's running prompt from the agent instead of trusting what it saw before.

### Created sessions, config changes and slash commands

- `create` (§2, "New sessions from any device"): `session/new` in the folder, hidden from the front end, then
  `bridge:bindSession`, then the usual mirror and the prompt. The front end may still see the new session's first
  notifications (the id is known only once `session/new` returns); front ends ignore updates for sessions they did not
  open.
- `config`: `session/set_config_option` on the agent (after opening the session hidden, for a session nobody ran).
- Models: on sign-in, and after a config change or a roster change, the bridge lists `model_state` with each model's
  thinking levels (`acp_config_options` for that model) and sends `bridge:setModels` when it differs from the last.
- Slash commands: the tee copies `available_commands_update`; the bridge keeps each mirrored session's list (name,
  description, input hint) and sends `bridge:setCommands` when it changed.

### Adopted sessions

A prompt for a session nobody runs (`adopt: true`, §2) is claimed by whichever crok of the computer gets there first.
That bridge loads the session into its own agent (`load_session` with `_meta.noReplay`) and keeps it from its front
end: the tee drops the session's notifications, refuses its questions and plan approvals, and hands its permission
requests to the bridge, which offers them on the relay only. Once loaded, the mirror registers (with the usual
backfill, which leaves out the prompt that is starting) and the prompt runs. The bridge closes an adopted session after
ten minutes without a turn or a viewer, at once while signed out, and when another crok of the computer took the
session over (it is gone from the inbox's `hosted`), so two processes do not write one session. If the person opens
it in that same process (`/resume`, Crok Desktop), it is theirs from then on.

Crok Desktop keeps one harness of its own running while the Mac is signed in and sharing (the "remote host"), so a Mac
with no task open still takes prompts and lists the other computers' sessions.

### Sessions on other computers

A computer is a viewer too. `ObservedAgent` serves every session id `relay:<sessionDocId>` from the relay instead of
the agent (`remote_control/viewer.rs`), so the TUI and Crok Desktop open another computer's session like one of their
own:

- `session/load` reads the session (`sessions:get`) and the last 200 transcript items (`sessions:events`) and replays
  them as `session/update`s marked `isReplay`; then it watches the session, its newest 40 items and its prompts.
- New and growing items become `user_message_chunk` / `agent_message_chunk` / `agent_thought_chunk` deltas and
  `tool_call` / `tool_call_update`s. A transcript the computer re-sent under new keys (it read it from disk again) is
  matched by content and not shown twice. Turns started elsewhere come with `x.ai/remote/prompt` and end with
  `x.ai/session/prompt_complete`, as a phone's prompt does in a local session.
- `session/prompt` is `commands:sendPrompt`; it returns when the command is done and the session is idle (after a
  short settle, so the last transcript update lands first). `session/cancel` is `commands:stop`.
- The session's `pending` request becomes an ordinary `session/request_permission` to the front end; its choice goes
  back as `commands:answer`.
- `x.ai/remote/sessions` (`{watch: true}` keeps `x.ai/remote/sessions_changed` coming for ten minutes) lists the other
  computers' sessions (`sessions:groups` without this computer); `x.ai/session/list` adds them as rows with
  `source: relay` when asked (`otherComputers: true`, or any search).
- The load response carries `models` and `configOptions` (`model`, `reasoning_effort`) built from `sessions:get`'s
  `models`, `model` and `effort`, so the front end's model and thinking pickers list that computer's choices.
  `session/set_model` and `session/set_config_option` become `commands:setConfig` and return once the computer applied
  it (with the new `configOptions`); a change made elsewhere arrives as `x.ai/session_notification` `model_changed` and
  a `config_option_update`.
- `x.ai/remote/new_session {deviceId, path, text?}` starts a session there (`sessions:create`) and returns
  `{sessionId: "relay:<id>"}` for the front end to open.
- Setting a mode and forking are refused for such a session; they belong to its computer.

Not covered yet: the leader (`[cli] use_leader = true`, where the TUI talks to a shared `crok agent leader`), `crok agent
serve` and headless `crok -p` runs host no bridge, so their sessions are not mirrored.

Configuration (`~/.crok/config.toml`):

```toml
[remote]
enabled = true        # mirror and accept commands while signed in (default true)
# url = "https://<deployment>.convex.cloud"   # only for a relay of one's own (or CROK_REMOTE_URL)
```

Nobody types the relay's address: crok has it built in (`crok_remote::settings::BUILT_IN_URL`, overridable at build
time with `CROK_REMOTE_DEFAULT_URL`), and so do the phone apps (`CROK_RELAY_URL` in the iOS xcconfigs, `RELAY_URL` in
the Android build) and the web app (`NEXT_PUBLIC_CONVEX_URL`). `--server` (hidden), `[remote] url` and
`CROK_REMOTE_URL` remain for development against a local relay.

## 5. Clients

### crok (CLI and TUI)

- `crok remote login [--name NAME] [--json]` — device flow against the built-in relay; prints the code, the link and a QR code,
  opens the browser, waits. `--json` prints one JSON object per line for Crok Desktop
  (`{"event":"code",…}`, `{"event":"signed_in",…}`, `{"event":"error",…}`).
- `crok remote logout`, `crok remote status [--json]`.
- TUI: `/remote` shows status and signs in or out in place (`/remote login`, `/remote logout`); the footer shows a
  phone glyph while the bridge is connected; Settings has a "Remote control" row (`[remote] enabled`).
- TUI: `/resume` lists the other computers' sessions too ("Title · Computer", badge "other computer"); picking one opens
  it (§4, "Sessions on other computers"). A permission request answered on another device leaves the prompt queue with
  "Answered on another device".
- TUI: `/remote new` picks a project on another computer (computer · project, online ones) and opens a new session
  there; `/model` and the thinking level work in another computer's session with that computer's choices.

### Crok Desktop

- Settings › Remote control: signed-out shows "Sign in…" (runs `crok remote login --json`, shows the code and opens
  the browser); signed-in shows the account, this computer's name, a "Let phones control this Mac" toggle and
  "Sign out".
- A remote prompt (`_x.ai/remote/prompt`) appears in the transcript with a small "from <phone>" label and the task
  shows as running, the same as a typed prompt.
- The sidebar has an "Other computers" section (from the remote host): each computer with its sessions; clicking one
  opens it as a task (`relay:` session id, kept under a hidden project whose folder is the app's own) that the other
  computer runs. An approval answered on another device leaves the task.
- Each project of another computer has **New task** (a "+" on hover, and in its context menu): a new task whose first
  prompt starts the session on that computer in that folder (`x.ai/remote/new_session` through the remote host), then
  it is an ordinary remote task.
- The composer's model and thinking-level pickers work in a remote task, listing that computer's choices.

### The session list (web, iOS, Android alike)

- Tabs as before: **All**, one per computer, **Archived**. All and computer tabs show `sessions:groups` (a computer tab
  keeps only its projects); Archived stays a flat `sessions:list({archived: true})`.
- One section per project, in the relay's order. Header: folder icon, project name, on the All tab the computer's name
  (muted, with its online dot), the session count, and a chevron that collapses it (remembered on the device per
  project key). A section shows its first 5 sessions, then "Show N more" / "Show less".
- Rows as before (avatar, title, time, preview or "working…", badges), but the second line shows the session's own
  folder only when it differs from the project's name (the header names project and computer).
- Sessions only on the computer's disk (`online: false`) look like any other row while their computer is online, and
  dimmed when it is not; opening one shows "Loading from <computer>…" until its history arrives, or "<computer> is
  offline…" (see `historyState` above). The composer works whenever the computer is online (a prompt opens the session
  there) and is blocked only while it is offline.
- A pending permission request shows as a card above the composer: "Crok on <computer> asks:", the request, its
  detail, and a button per choice (allow ones prominent); a tap answers it (`commands:answer`).
- **Reorder projects**: drag a section header (web: pointer drag with a handle; iOS: Edit mode's move handles; Android:
  drag handle in Reorder mode), or a header menu's **Move up** / **Move down**, then `sessions:reorderProjects` with
  the keys visible in the current tab in their new order. **Reorder sessions** the same way within a section
  (`sessions:reorderSessions`); a session cannot leave its project. Both are optimistic.
- Menus: a section's menu has **Move up**, **Move down**, **Sort by recent activity** (`resetOrder({projectKey})`);
  the list's menu has **Sort projects by recent activity** (`resetOrder({})`).
- While searching, sections hold only matching rows (empty ones hide) and reordering is off.

### New sessions (web, iOS, Android alike)

- Each project section offers **New session** (a "+" in the header, and in the section menu); the list's toolbar has a
  compose button that first asks for the project (projects of online computers, grouped by computer, recent first).
- Both open a **new-session screen** shaped like a session (Telegram's new chat): header "New session" with the
  project and computer underneath, an empty transcript saying where it will run ("Starts in <path> on <computer>"),
  and the composer. Sending calls `sessions:create` and turns the screen into that session (same navigation entry),
  with the prompt shown optimistically. `/new [prompt]` inside a session does the same for its project (with a prompt:
  at once).
- Rows with `starting` show "Starting…" as their preview.

### Commands in the composer (web, iOS, Android alike; Telegram's bot UI)

Built from Telegram's bot keyboard: the **Menu button** and the **command list** (iOS `ChatTextInputMenuButton`,
`CommandMenuChatInputContextPanelNode`; And `BotCommandsMenuView`, `MentionsAdapter` with `/` hints) and **inline
keyboards** under a bot message (iOS `ChatMessageInlineKeyboard…`; And `BotButtons`).

- A Menu button (a blue pill: ☰ icon, "Menu" while the field is empty, collapsing to the icon when typing) sits at the
  start of the composer. It opens the command list above the composer; so does typing `/` as the first character, then
  filtering by prefix as the person types (`/mo` → `/model`).
- The list: the device's own commands first, then the session's (`sessions:commands`), each row `/name` in bold and the
  description, the input hint greyed after the name. Tap: a command that takes arguments (a hint, or `/new` `/model`
  `/think`, which also work without) fills the field with `/name ` for the rest; others are sent at once.
- The device's own commands (localized descriptions):
  - `/new [prompt]` — Start a new session in this project
  - `/model [name]` — Change the model (on this session's computer)
  - `/think [level]` — Change the thinking level (hidden when the current model has none)
  - `/stop` — Stop the running turn (only while running)
  - `/info` — Session info
- `/model` and `/think` without an argument answer with a local **bot card** in the transcript (not stored on the
  relay): "Model for this session" and an inline keyboard, one button per choice (models one per row with the
  description under the name; thinking levels two per row), the current one marked ✓. A tap calls
  `commands:setConfig`; the button spins until the command is done, then the card says "Model: Grok 4 ✓" and its
  keyboard folds away; a failure shows in the card with the error. With an argument they match by id or name (case
  insensitive, unique prefix) and apply directly, answering with the same card in its done state. Without `models`
  (computer offline) the card says the computer is offline.
- Any other `/text` goes to the computer as a prompt: the session's commands (`/compact`) and unknown ones alike
  (crok answers "unknown command" there).

### Look

- Accent: Telegram blue — light `#3390EC`, dark `#3E88F7` (links, buttons, switches, selection, unread badges, the Menu
  pill, ticks); the person's own prompt bubbles: light `#E1EFFD` with ordinary text, dark `#2B5278` with white text.
  Online dots stay green.
- iOS: on iOS 26 the system bars are Liquid Glass; the composer bar, the scroll-to-bottom button and floating buttons
  use `glassEffect` (on iOS 17–25, `.regularMaterial`).
- Android: the same Liquid Glass look — top bar, tab strip, composer and floating buttons are glass over the content
  scrolling beneath (backdrop blur, refraction at the edge, a light rim and highlight), rounded like iOS; on Android
  12 and older, where there is no backdrop shader, a translucent frosted surface.

### Staying connected (iOS, Android)

A phone's socket dies when the app is suspended or the network changes. The app does not wait for the person to kill
it: on returning to the foreground, on the network coming back, and whenever the connection has not synced for 20 s
while the network is up, it refreshes the access token and, if the socket still does not sync within 10 s, replaces
the Convex client (subscriptions start again on the new one; what is on screen stays meanwhile). `UNAUTHENTICATED`
from a query also triggers a token refresh and a new client. The title shows "Connecting…"/"Updating…" meanwhile.

### Web app (`relay/app`, Vercel)

- `/` — signed out: what remote control is and "Sign in with GitHub or Google"; signed in: the session list (filter by
  computer), like the phone apps.
- `/link` and `/link?code=…` — approve a device (shows name, platform, app, time; Approve / Deny). With `&app=1` (phone
  sign-in) the page ends on `crok://signed-in`.
- `/sessions/[id]` — transcript, composer with Send / Stop, info panel.
- `/devices` — linked devices, sign out one or all others.

### Phone apps (iOS and Android)

Built from Telegram's patterns (structure and UX only; Telegram's code is GPL and none is copied). References are to
`TelegramMessenger/Telegram-iOS` (iOS) and `DrKLO/Telegram` (And, `TMessagesProj/src/main/java/org/telegram/`).

| pattern | crok | Telegram reference |
|---|---|---|
| Per-account context + engine facade, torn down on sign-out | `CrokEngine` owns the Convex client; screens use `engine.sessions`, `engine.commands`, `engine.devices` | iOS `AccountContext.swift`, `TelegramEngine.swift`; And `AccountInstance.java`, `NotificationCenter.appDidLogout` |
| Sign-in as a persisted state machine | welcome → waiting for approval (code shown, browser sheet) → signed in; resumes polling after the app is killed | iOS `AuthorizationSequenceController.updateState`; And `LoginActivity.setPage` + `logininfo2` |
| Connection state in the title, 0.3 s delayed | "Waiting for network" / "Connecting…" / "Updating…" replaces "Sessions"; same in the session header | iOS `ChatListController.swift` (~6876, 7215); And `LaunchActivity.updateCurrentConnectionState` |
| Chat-list row anatomy | avatar (project initials, online dot), title, time, computer · folder, preview or animated "working…", unread badge, pin, needs-approval badge | iOS `ChatListItem.swift`, `ChatListTypingNode.swift`, `ChatListBadgeNode.swift`; And `Cells/DialogCell.java` |
| Folders as tabs | "All" + one tab per computer + "Archived" | iOS `ChatListFilterTabContainerNode`; And `Components/FilterTabsView.java` |
| Swipe actions as data, semantic colours, list frozen during a swipe | Pin (constructive), Stop (destructive, while running), Archive (inactive) | iOS `ChatListItem.revealOptions`, `ItemListRevealOptionsNode.swift`; And `DialogsActivity.SwipeController`, `DialogsAdapter.setDialogsListFrozen` |
| Bottom-anchored windowed history | 50 events per page, load older on scroll | iOS `ChatHistoryListNode.swift` (`historyMessageCount = 44`); And `ChatActivity` reversed layout |
| Grouping + day headers | merge consecutive items of one author within 10 min; sticky day headers | iOS `ChatMessageMergeFingerprint.swift`, `ChatMessageDateHeader.swift`; And `pinnedTop/pinnedBottom` |
| Optimistic send with a client id and status ticks | clock → ✓ → ✓✓, red "!" with Retry / Delete | iOS `EnqueueMessage.swift`, `ChatMessageDateAndStatusNode.swift`, `ChatMessageDeliveryFailedNode`; And `SendMessagesHelper`, `ChatMessageCell.createStatusDrawableParams` |
| Send / Stop / Blocked button | Stop while `status == running`, blocked while offline | iOS `ChatTextInputPanelNode` `displayStop`, `TypingDraftStop.swift`; And `BotForumHelper.SteamingSendButtonState`, `ChatActivityEnterView.setBlockedByStreaming` |
| Smoothed streaming text | reveal speed from the observed chunk rate, finish within 0.3 s at turn end | iOS `StreamingTextReveal/Sources/TextRevealController.swift` |
| Pinned bar | the session's plan ("3/7 · Write tests"), tap to expand | Telegram's pinned-message bar |
| Scroll-to-bottom button with a counter | counts new items only while scrolled up | iOS `ChatHistoryNavigationButtonNode.swift`; And `ChatActivityBlurredRoundPageDownButton.java` |
| Per-session composer draft | survives app kill | iOS `ChatInterfaceState.swift`; And `ChatActivity.saveDraft` |
| QR login | Settings › Link a computer: scan the QR `crok remote login` prints, confirm | iOS `AuthTransfer.swift`, `QrCodeScanScreen.swift`; And `SessionsActivity.ScanQRCodeView` |
| Active sessions | Settings › Devices: this device, computers, phones; online / last seen; sign out one; "Sign out all other devices" | iOS `RecentSessionsController.swift`, `RecentSessionScreen.swift`; And `SessionsActivity.java`, `SessionCell.java` |
| Semantic theme tokens, live theme and language switch | Crok palette (Telegram blue accent `#3390EC` / `#3E88F7`, Crok Night `#141414`, Crok Day `#EEEEEE`), six languages | iOS `PresentationTheme.swift`, `PresentationData.swift`; And `Theme.java`, `LocaleController.java` |

Screens: Sign-in → Sessions (tabs All / per computer / Archived, search) → Session (header, plan bar, transcript,
composer) → Session info sheet; Settings (account, Devices, Link a computer, appearance, language, about, sign out).

Platform choices: iOS 17+, SwiftUI, Observation, `ConvexMobile` 0.8.1 (`ConvexClientWithAuth` with a device
`AuthProvider`), Keychain, XcodeGen project. Android minSdk 26, Kotlin + Compose + Material 3,
`dev.convex:android-convexmobile` 0.8.0 (with JNA 5.19.1 for 16 KB pages), Keystore-encrypted credentials, Auth Tab /
Custom Tabs, Google code scanner for QR.

## 6. Languages

Every surface ships English, 简体中文, 日本語, Español, Français and Deutsch, like the TUI and Crok Desktop: new TUI
strings through `tl`/`tlf` and the catalog, desktop strings through `L10n.t` and a `L10nRemoteTables.swift`, iOS
through a String Catalog, Android through `values-*/strings.xml`, the web app through a small dictionary module.

## 7. Limits and cost

Convex free tier: 1 GB/month database bandwidth, 0.5 GB storage. Events are capped at 32 000 characters (the computer
keeps the full text), 100 per call; sessions keep their relay copy 30 days after their last activity. A busy streaming
session watched from a phone costs about one small mutation per 0.75 s; unwatched, one per message.

## 8. Deployment

See `relay/README.md`: create the Convex project, `npm run keys -- --apply --prod`, set `CLERK_JWT_ISSUER_DOMAIN` and
`CROK_WEB_URL`, connect Clerk (GitHub and Google connections, Convex integration), import `relay/` to Vercel with build
command `npx convex deploy --cmd 'npm run build'`, then point crok and the apps at the deployment URL.

## 9. Future work

- Answer questions and plan approvals from other devices (permission requests already can be; an adopted session
  refuses questions for now).
- Push notifications for "turn finished" and "needs approval" (APNs / FCM via a Convex action; per-session threads and
  Approve / Deny actions, as Telegram's notification service does).
- End-to-end encryption of transcripts with a key shared between the user's devices.
- Attachments (images) in remote prompts.
