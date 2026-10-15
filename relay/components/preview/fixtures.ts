/**
 * Fake relay data for the dev-only /preview gallery (never part of a production build: see next.config.ts).
 * Shapes are the real API types, so the preview breaks at compile time when the contract changes.
 */
import type {
  CommandId,
  DeviceRow,
  PendingLogin,
  PendingPrompt,
  PromptCommand,
  SessionDetail,
  SessionId,
  SessionRow,
  TranscriptEvent,
} from "@/lib/types";

const MIN = 60_000;
const HOUR = 60 * MIN;

type DeviceId = SessionRow["deviceId"];
const mac = "dev_mac" as DeviceId;
const studio = "dev_studio" as DeviceId;
const box = "dev_box" as DeviceId;

export function fakeSessions(now: number): SessionRow[] {
  const row = (r: Partial<SessionRow> & Pick<SessionRow, "_id" | "title" | "cwd">): SessionRow => ({
    sessionId: `0199e3b2-${r._id}`,
    model: "grok-code-fast-1",
    status: "idle",
    online: true,
    app: "tui",
    deviceId: mac,
    deviceName: "MacBook Pro",
    deviceOnline: true,
    preview: null,
    previewKind: null,
    lastActivityAt: now - 5 * MIN,
    pinned: false,
    archived: false,
    unread: 0,
    plan: null,
    ...r,
  });
  return [
    row({
      _id: "s_web" as SessionId,
      title: "Fix the flaky login test",
      cwd: "/Users/me/code/web-app",
      status: "running",
      pinned: true,
      preview: "Running the auth suite again with the cache fix",
      previewKind: "tool",
      lastActivityAt: now - 1 * MIN,
      plan: { done: 3, total: 5 },
    }),
    row({
      _id: "s_settings" as SessionId,
      title: "Add dark mode to Settings",
      cwd: "/Users/me/code/settings-ui",
      status: "waiting",
      deviceId: studio,
      deviceName: "Mac Studio",
      app: "desktop",
      preview: "Should the theme follow the system by default?",
      previewKind: "assistant",
      lastActivityAt: now - 14 * MIN,
      unread: 2,
    }),
    row({
      _id: "s_billing" as SessionId,
      title: "Migrate the billing API to v2",
      cwd: "/home/me/billing-service",
      deviceId: box,
      deviceName: "dev-box",
      online: false,
      deviceOnline: false,
      preview: "Updated 12 call sites and the webhook handler. Tests pass.",
      previewKind: "assistant",
      lastActivityAt: now - 26 * HOUR,
    }),
    row({
      _id: "s_docs" as SessionId,
      title: "Write the release notes for 1.5",
      cwd: "/Users/me/code/crok-build",
      preview: "Translate them into the five other languages too",
      previewKind: "user",
      lastActivityAt: now - 3 * HOUR,
      unread: 1,
    }),
    row({
      _id: "s_perf" as SessionId,
      title: "Profile the slow transcript scroll",
      cwd: "/Users/me/code/crok-build/desktop",
      deviceId: studio,
      deviceName: "Mac Studio",
      app: "desktop",
      status: "error",
      preview: "Model request failed: 529 overloaded",
      previewKind: "error",
      lastActivityAt: now - 4 * 24 * HOUR,
    }),
    row({
      _id: "s_infra" as SessionId,
      title: "Rotate the staging certificates",
      cwd: "/home/me/infra",
      deviceId: box,
      deviceName: "dev-box",
      online: false,
      deviceOnline: false,
      preview: "Done. Certificates renew on the 1st of each month now.",
      previewKind: "assistant",
      lastActivityAt: now - 40 * 24 * HOUR,
    }),
  ];
}

export function fakeComputers(): Pick<DeviceRow, "_id" | "name" | "online">[] {
  return [
    { _id: mac, name: "MacBook Pro", online: true },
    { _id: studio, name: "Mac Studio", online: true },
    { _id: box, name: "dev-box", online: false },
  ];
}

export function fakeSession(now: number, overrides: Partial<SessionDetail> = {}): SessionDetail {
  return {
    _id: "s_web" as SessionId,
    sessionId: "0199e3b2-7c41-7d2e-9f0a-3b6c1d2e4f58",
    title: "Fix the flaky login test",
    cwd: "/Users/me/code/web-app",
    model: "grok-code-fast-1",
    effort: "high",
    gitBranch: "fix/login-race",
    status: "running",
    online: true,
    app: "tui",
    deviceId: mac,
    deviceName: "MacBook Pro",
    devicePlatform: "macOS 26.1 (arm64)",
    deviceOnline: true,
    createdAt: now - 27 * HOUR,
    lastActivityAt: now - 1 * MIN,
    plan: [
      { content: "Reproduce the failure locally", status: "completed" },
      { content: "Find the race in the session cache", status: "completed" },
      { content: "Fix the cache invalidation", status: "completed" },
      { content: "Run the auth suite 20 times", status: "in_progress" },
      { content: "Write a regression test", status: "pending" },
    ],
    usage: {
      inputTokens: 1_284_311,
      outputTokens: 48_902,
      cachedTokens: 1_102_544,
      reasoningTokens: 12_480,
      costUsd: 0.4123,
      contextTokens: 91_200,
      contextWindow: 256_000,
    },
    pinned: true,
    archived: false,
    unread: 0,
    eventSeq: 30,
    ...overrides,
  };
}

const SESSION = "s_web" as SessionId;

function ev(seq: number, at: number, e: Partial<TranscriptEvent> & Pick<TranscriptEvent, "kind" | "text">): TranscriptEvent {
  return {
    _id: `ev_${seq}` as TranscriptEvent["_id"],
    _creationTime: at,
    sessionDocId: SESSION,
    seq,
    key: `k${seq}`,
    at,
    ...e,
  };
}

const REPLY = `I found it. \`SessionCache.get\` reads the entry **before** the refresh promise resolves, so two requests can race:

1. Request A misses and starts a refresh.
2. Request B reads the stale entry and signs in with the old token.

The fix keeps the in-flight promise in the cache:

\`\`\`ts
const pending = this.refreshing.get(key) ?? this.refresh(key);
this.refreshing.set(key, pending);
return await pending;
\`\`\`

| Run | Before | After |
|---|---:|---:|
| 20× auth suite | 3 failures | 0 failures |
| p95 sign-in | 412 ms | 405 ms |

See [the Node docs on promises](https://nodejs.org/api/) for why awaiting the shared promise is safe.`;

export function fakeEvents(now: number): TranscriptEvent[] {
  const y = now - 26 * HOUR; // yesterday
  const list: TranscriptEvent[] = [
    ev(1, y, { kind: "user", text: "The login test fails about one run in ten on CI. Can you find out why and fix it?" }),
    ev(2, y + 0.3 * MIN, { kind: "thought", text: "Flaky one in ten suggests a race. Start with the session cache and the token refresh path." }),
    ev(3, y + 0.5 * MIN, { kind: "tool", title: "Read src/auth/session-cache.ts", toolKind: "read", status: "completed", text: "src/auth/session-cache.ts (184 lines)" }),
    ev(4, y + 0.7 * MIN, { kind: "tool", title: "Search for refreshToken(", toolKind: "search", status: "completed", text: "7 matches in 4 files" }),
    ev(5, y + 1.2 * MIN, {
      kind: "tool",
      title: "Run npm test -- auth --repeat 20",
      toolKind: "execute",
      status: "failed",
      text: "PASS auth/login.test.ts (19)\nFAIL auth/login.test.ts (1)\n  ● signs in after refresh\n    expected 200, received 401\n      at Object.<anonymous> (auth/login.test.ts:88:23)\n      at processTicksAndRejections (node:internal/process/task_queues:95:5)\n\nTests: 1 failed, 19 passed, 20 total\nTime:  41.2 s",
    }),
    ev(6, y + 3 * MIN, { kind: "assistant", text: REPLY }),
    ev(7, y + 3.2 * MIN, { kind: "system", text: "", status: "end_turn" }),
    ev(8, now - 22 * MIN, { kind: "user", text: "Great, apply the fix and run the suite 20 times.", origin: "remote", commandId: "cmd_1" as CommandId }),
    ev(9, now - 21 * MIN, { kind: "tool", title: "Edit src/auth/session-cache.ts", toolKind: "edit", status: "completed", text: "+6 −2" }),
    ev(10, now - 20.5 * MIN, { kind: "tool", title: "Edit src/auth/refresh.ts", toolKind: "edit", status: "completed", text: "+3 −1" }),
    ev(11, now - 20 * MIN, { kind: "tool", title: "Run npm run typecheck", toolKind: "execute", status: "completed", text: "No errors." }),
    ev(12, now - 19 * MIN, { kind: "tool", title: "Fetch https://registry.npmjs.org/jose", toolKind: "fetch", status: "completed", text: "200 OK" }),
    ev(13, now - 18 * MIN, { kind: "tool", title: "Run npm test -- auth --repeat 20", toolKind: "execute", status: "in_progress", text: "PASS auth/login.test.ts (14/20)" }),
    ev(14, now - 12 * MIN, { kind: "system", text: "", status: "cancelled" }),
    ev(15, now - 11 * MIN, { kind: "error", text: "Model request failed: 529 overloaded. Retrying in 10 s." }),
    ev(16, now - 9 * MIN, { kind: "user", text: "Keep going, but skip the slow e2e tests for now." }),
    ev(17, now - 8.5 * MIN, { kind: "assistant", text: "Running the auth suite again with the cache fix — 14 of 20 runs passed so far, **no failures**." }),
  ];
  return list.reverse(); // newest first, like sessions:events
}

export function fakeCommands(now: number): PromptCommand[] {
  return [
    {
      _id: "cmd_3" as CommandId,
      clientId: "c3",
      text: "Then write the regression test and open a PR.",
      status: "failed",
      error: "The computer is busy with another prompt.",
      fromLabel: "Web",
      fromDeviceId: null,
      mine: true,
      createdAt: now - 2 * MIN,
      updatedAt: now - 2 * MIN,
    },
    {
      _id: "cmd_2" as CommandId,
      clientId: "c2",
      text: "Also check the token refresh in the mobile client.",
      status: "delivered",
      error: null,
      fromLabel: "Web",
      fromDeviceId: null,
      mine: true,
      createdAt: now - 1 * MIN,
      updatedAt: now - 1 * MIN,
    },
    {
      _id: "cmd_1" as CommandId,
      clientId: "c1",
      text: "Great, apply the fix and run the suite 20 times.",
      status: "done",
      error: null,
      fromLabel: "iPhone 17",
      fromDeviceId: "dev_iphone" as never,
      mine: false,
      createdAt: now - 22 * MIN,
      updatedAt: now - 10 * MIN,
    },
  ];
}

export function fakePending(now: number): PendingPrompt[] {
  return [
    {
      key: "c3",
      text: "Then write the regression test and open a PR.",
      createdAt: now - 2 * MIN,
      tick: "failed",
      error: "The computer is busy with another prompt.",
      commandId: "cmd_3" as CommandId,
      clientId: "c3",
    },
    {
      key: "c2",
      text: "Also check the token refresh in the mobile client.",
      createdAt: now - 1 * MIN,
      tick: "delivered",
      commandId: "cmd_2" as CommandId,
      clientId: "c2",
    },
    { key: "c4", text: "And update the changelog.", createdAt: now - 0.1 * MIN, tick: "sending", clientId: "c4" },
  ];
}

export function fakeDevices(now: number): DeviceRow[] {
  return [
    {
      _id: mac as DeviceRow["_id"],
      kind: "computer",
      name: "MacBook Pro",
      platform: "macOS 26.1 (arm64)",
      client: "crok 1.0.45",
      createdAt: now - 30 * 24 * HOUR,
      lastSeenAt: now - 2 * MIN,
      online: true,
      isCurrent: false,
      liveSessionCount: 2,
    },
    {
      _id: studio as DeviceRow["_id"],
      kind: "computer",
      name: "Mac Studio",
      platform: "macOS 26.0 (arm64)",
      client: "Crok Desktop 1.5.0",
      createdAt: now - 12 * 24 * HOUR,
      lastSeenAt: now - 4 * MIN,
      online: true,
      isCurrent: false,
      liveSessionCount: 1,
    },
    {
      _id: box as DeviceRow["_id"],
      kind: "computer",
      name: "dev-box",
      platform: "Linux 6.8 (x86_64)",
      client: "crok 1.0.44",
      createdAt: now - 60 * 24 * HOUR,
      lastSeenAt: now - 26 * HOUR,
      online: false,
      isCurrent: false,
      liveSessionCount: 0,
    },
    {
      _id: "dev_iphone" as DeviceRow["_id"],
      kind: "phone",
      name: "iPhone 17",
      platform: "iOS 26.1",
      client: "Crok for iPhone 1.0",
      createdAt: now - 3 * 24 * HOUR,
      lastSeenAt: now - 15 * MIN,
      online: false,
      isCurrent: false,
      liveSessionCount: 0,
    },
    {
      _id: "dev_pixel" as DeviceRow["_id"],
      kind: "phone",
      name: "Pixel 10",
      platform: "Android 16",
      client: "Crok for Android 1.0",
      createdAt: now - 9 * 24 * HOUR,
      lastSeenAt: now - 6 * 24 * HOUR,
      online: false,
      isCurrent: false,
      liveSessionCount: 0,
    },
  ];
}

export function fakeLogin(now: number, overrides: Partial<PendingLogin> = {}): PendingLogin {
  return {
    userCode: "BCDF-GHJK",
    kind: "computer",
    name: "MacBook Pro",
    platform: "macOS 26.1 (arm64)",
    client: "crok 1.0.45",
    createdAt: now - 70_000,
    expiresAt: now + 8 * MIN + 51_000,
    status: "pending",
    ...overrides,
  };
}
