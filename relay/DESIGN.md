# Crok remote control — design

Status: first implementation, 2026-10-15. Branch `worktree-remote-relay`.

Crok runs on your computers (the `crok` TUI and Crok Desktop). Remote control lets you follow and steer those sessions
from a phone or a browser: see every session on every computer, read the transcript as it streams, send a prompt, stop
the running turn, and look at the session's info (model, tokens, cost, context, plan).

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
- **Remote execution**: a prompt from a phone runs on the computer with the session's own permission mode; permission
  prompts still appear on the computer (the phone shows "Waiting for approval on <computer>"). A computer can turn
  control off (`[remote] enabled = false`) or sign out.
- **Data at rest on the relay**: transcripts are stored in the person's own Convex deployment. End-to-end encryption is
  listed under future work.

## 2. Data model (`relay/convex/schema.ts`)

| table | one row is | written by | notes |
|---|---|---|---|
| `users` | a person | `users.ensure` | `tokenIdentifier` from Clerk |
| `devices` | a linked computer or phone | `deviceAuth`, `devices`, `bridge` | `refreshTokenHash`, coarse `lastSeenAt`, `online`, `revokedAt` |
| `deviceLogins` | a sign-in in progress | `deviceAuth` | `deviceCodeHash`, `userCode`, `status` pending → approved → consumed |
| `hosts` | one running crok process | `bridge.connect/heartbeat` | heartbeat every 30 s touches only this row |
| `sessions` | a mirrored crok session | `bridge.upsertSession` | title, cwd, model, status, `online`, preview, plan, usage, unread counters |
| `events` | one transcript item | `bridge.pushEvents` | `seq` order, `key` for in-place updates (streaming text, tool status) |
| `commands` | a prompt / stop / info request | viewers; `bridge.claim/complete` | `pending → delivered → done/failed`, `clientId` for idempotency |
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
views. Daily, it drops relay copies of sessions idle for 30 days (the sessions stay on the computer).

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
| `sessions:list` (query) | `archived?: boolean` | `[{_id, sessionId, title, cwd, model, status, online, app, deviceId, deviceName, deviceOnline, preview, previewKind, lastActivityAt, pinned, archived, unread, plan: null\|{done,total}}]` pinned first, then newest |
| `sessions:get` (query) | `sessionDocId` | `{…list fields, effort, gitBranch, devicePlatform, createdAt, plan:[{content,status}], usage: null\|{inputTokens, outputTokens, cachedTokens, reasoningTokens, costUsd, contextTokens, contextWindow}, eventSeq}` |
| `sessions:events` (paginated query) | `sessionDocId, paginationOpts:{numItems, cursor}` | `{page:[event], isDone, continueCursor}` newest first |
| `sessions:markRead` / `watch` (mutation) | `sessionDocId` | `null` — call `watch` on open and every 60 s |
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
permission on the computer), `error`. `online: false` = no crok process runs it now (read-only).

### Commands (viewers)

| function | args | returns |
|---|---|---|
| `commands:sendPrompt` (mutation) | `sessionDocId, text, clientId` (UUID) | `{commandId}`; same `clientId` → same command; throws `OFFLINE` |
| `commands:stop` (mutation) | `sessionDocId` | `{commandId}` |
| `commands:requestInfo` (mutation) | `sessionDocId` | `{commandId}`; the answer arrives in `commands:get(...).result` |
| `commands:get` (query) | `commandId` | the command row or `null` |
| `commands:forSession` (query) | `sessionDocId` | recent prompts `[{_id, clientId, text, status, error, fromLabel, fromDeviceId, mine, createdAt, updatedAt}]`; `mine` = sent by this caller |
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
| `bridge:connect` | `instanceId, app: tui\|desktop\|cli, appVersion, pid?` | `{hostId, deviceId, serverTime}` |
| `bridge:heartbeat` | `hostId` | `{serverTime}` (every 30 s) |
| `bridge:disconnect` | `hostId` | `null` |
| `bridge:upsertSession` | `hostId, sessionId, fields:{title?, cwd?, model?, effort?, gitBranch?, status?, preview?, previewKind?, plan?, usage?, createdAt?, lastActivityAt?}` | `{sessionDocId, eventSeq, created}` |
| `bridge:closeSession` | `hostId, sessionId` | `null` |
| `bridge:pushEvents` | `hostId, sessionDocId, replace?, events:[{key, kind, text, title?, toolKind?, status?, origin?, commandId?, at}]` (≤100) | `{eventSeq}` |
| `bridge:inbox` (query) | `hostId` | `{commands:[{_id, sessionDocId, sessionId, type, text, fromLabel, createdAt}], views:[{sessionDocId, sessionId, until}], serverTime}` |
| `bridge:claimCommand` | `hostId, commandId` | `boolean` |
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

Mirrored: sessions that have a prompt or were loaded with history, not subagent children, hidden sessions or Crok
Desktop's helper processes (`CROK_REMOTE_BRIDGE=0`). One-shot agents (`crok models`, `crok worktree`, headless `-p`)
never start a bridge. On first sight of a session whose relay copy is empty, the bridge backfills the tail of its
transcript from `updates.jsonl` (`x.ai/session/updates`).

Turn state survives sign-in at any time: the tee always passes on the once-per-turn `x.ai/session/prompt_complete`,
and on sign-in the bridge reads each session's running prompt from the agent instead of trusting what it saw before.

Not covered yet: the leader (`[cli] use_leader = true`, where the TUI talks to a shared `crok agent leader`), `crok agent
serve` and headless `crok -p` runs host no bridge, so their sessions are not mirrored.

Configuration (`~/.crok/config.toml`):

```toml
[remote]
enabled = true        # mirror and accept commands while signed in (default true)
url = "https://<deployment>.convex.cloud"   # or CROK_REMOTE_URL; `crok remote login --server` writes it
```

## 5. Clients

### crok (CLI and TUI)

- `crok remote login [--server URL] [--name NAME] [--json]` — device flow; prints the code, the link and a QR code,
  opens the browser, waits. `--json` prints one JSON object per line for Crok Desktop
  (`{"event":"code",…}`, `{"event":"signed_in",…}`, `{"event":"error",…}`).
- `crok remote logout`, `crok remote status [--json]`.
- TUI: `/remote` shows status and signs in or out in place (`/remote login`, `/remote logout`); the footer shows a
  phone glyph while the bridge is connected; Settings has a "Remote control" row (`[remote] enabled`).

### Crok Desktop

- Settings › Remote control: signed-out shows "Sign in…" (runs `crok remote login --json`, shows the code and opens
  the browser); signed-in shows the account, this computer's name, a "Let phones control this Mac" toggle and
  "Sign out".
- A remote prompt (`_x.ai/remote/prompt`) appears in the transcript with a small "from <phone>" label and the task
  shows as running, the same as a typed prompt.

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
| Semantic theme tokens, live theme and language switch | Crok palette (sage accent `#41634C` / `#A1BFA8`, Crok Night `#141414`, Crok Day `#EEEEEE`), six languages | iOS `PresentationTheme.swift`, `PresentationData.swift`; And `Theme.java`, `LocaleController.java` |

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

- Answer permission prompts and questions from the phone (`PendingInteraction` → actionable banner, like Telegram's
  "Is this you?" review panel).
- Push notifications for "turn finished" and "needs approval" (APNs / FCM via a Convex action; per-session threads and
  Approve / Deny actions, as Telegram's notification service does).
- Start a new session on a chosen computer and folder from the phone.
- End-to-end encryption of transcripts with a key shared between the user's devices.
- Attachments (images) in remote prompts.
