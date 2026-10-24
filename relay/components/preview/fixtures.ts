/**
 * Fake relay data for the dev-only /preview gallery (never part of a production build: see next.config.ts).
 * Shapes are the real API types, so the preview breaks at compile time when the contract changes.
 */
import type { BotCard } from "@/components/session/BotCommands";
import type {
  CommandId,
  DeviceRow,
  ModelChoice,
  PendingLogin,
  PendingPrompt,
  ProjectGroup,
  PromptCommand,
  SessionDetail,
  SessionId,
  SessionRow,
  SlashCommand,
  TranscriptEvent,
} from "@/lib/types";

const MIN = 60_000;
const HOUR = 60 * MIN;

type DeviceId = SessionRow["deviceId"];
const mac = "dev_mac" as DeviceId;
const studio = "dev_studio" as DeviceId;
const box = "dev_box" as DeviceId;
const DAY = 24 * HOUR;

const COMPUTERS: Record<string, { name: string; online: boolean }> = {
  [mac]: { name: "MacBook Pro", online: true },
  [box]: { name: "dev-box", online: false },
};

type RowInput = Partial<SessionRow> & Pick<SessionRow, "_id" | "title" | "cwd"> & { project: string };

/** A list row as the relay sends it; `project` is the project's path (its key and name follow from it). */
function fakeRow(now: number, { project, ...r }: RowInput): SessionRow {
  const deviceId = r.deviceId ?? mac;
  const computer = COMPUTERS[deviceId];
  return {
    sessionId: `0199e3b2-${r._id}`,
    model: "grok-code-fast-1",
    gitBranch: null,
    usage: null,
    status: "idle",
    online: computer.online,
    app: "tui",
    deviceId,
    deviceName: computer.name,
    deviceOnline: computer.online,
    preview: null,
    previewKind: null,
    lastActivityAt: now - 5 * MIN,
    pinned: false,
    archived: false,
    unread: 0,
    plan: null,
    projectKey: `${deviceId}:${project}`,
    projectPath: project,
    projectName: project.split("/").pop() || project,
    historyState: null,
    starting: false,
    ...r,
  };
}

/** OpenRouter's share of a long list (a computer signed in there lists about 500), for the dialog's search. */
const OPENROUTER: [string, string][] = [
  ["anthropic/claude-opus-4.1", "Claude Opus 4.1"],
  ["anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5"],
  ["anthropic/claude-haiku-4.5", "Claude Haiku 4.5"],
  ["google/gemini-2.5-pro", "Gemini 2.5 Pro"],
  ["google/gemini-2.5-flash", "Gemini 2.5 Flash"],
  ["meta-llama/llama-4-maverick", "Llama 4 Maverick"],
  ["meta-llama/llama-4-scout", "Llama 4 Scout"],
  ["mistralai/devstral-medium", "Devstral Medium"],
  ["mistralai/mistral-large-2411", "Mistral Large 2411"],
  ["moonshotai/kimi-k2-0905", "Kimi K2 0905"],
  ["qwen/qwen3-coder", "Qwen3 Coder 480B A35B"],
  ["qwen/qwen3-235b-a22b-thinking-2507", "Qwen3 235B A22B Thinking 2507"],
  ["x-ai/grok-4-fast", "Grok 4 Fast"],
  ["z-ai/glm-4.6", "GLM 4.6"],
  ["deepseek/deepseek-v3.2-exp", "DeepSeek V3.2 Exp"],
  ["openai/gpt-oss-120b", "gpt-oss-120b"],
];

/**
 * What MacBook Pro's crok can run (`devices:models`), in picker order: the computer's default and its own providers,
 * then OpenRouter's. Models with and without thinking levels; Claude's levels have ids of their own and the canonical
 * level as `value`.
 */
export const FAKE_MODELS: ModelChoice[] = [
  {
    id: "grok-code-fast-1",
    name: "Grok Code Fast 1",
    description: "Quick and inexpensive, for everyday coding",
    efforts: [
      { id: "low", name: "Low" },
      { id: "medium", name: "Medium" },
      { id: "high", name: "High" },
    ],
    defaultEffort: "medium",
  },
  {
    id: "grok-4",
    name: "Grok 4",
    description: "The most capable Grok model",
    efforts: [
      { id: "low", name: "Low" },
      { id: "medium", name: "Medium" },
      { id: "high", name: "High" },
      { id: "xhigh", name: "Extra high" },
    ],
    defaultEffort: "high",
  },
  {
    id: "anthropic/claude-sonnet-4-5",
    name: "Claude Sonnet 4.5",
    description: "Anthropic, with your API key",
    efforts: [
      { id: "budget-4k", name: "Low", value: "low", description: "4k thinking tokens" },
      { id: "budget-16k", name: "Medium", value: "medium", description: "16k thinking tokens" },
      { id: "budget-32k", name: "High", value: "high", description: "32k thinking tokens" },
    ],
    defaultEffort: "budget-16k",
  },
  { id: "deepseek/deepseek-chat", name: "DeepSeek V3.2", description: "No thinking levels", efforts: [] },
  ...OPENROUTER.map(([id, name]) => ({
    id: `openrouter/${id}`,
    name,
    description: `${name} through OpenRouter. Billed to your OpenRouter account at its own prices.`,
    efforts: id.includes("thinking") || id.startsWith("anthropic/") ? [{ id: "high", name: "High" }, { id: "low", name: "Low" }] : [],
  })),
];

/** `sessions:commands` for the web-app session: crok's own, a skill with an argument, a workflow. */
export const FAKE_SLASH_COMMANDS: SlashCommand[] = [
  { name: "compact", description: "Summarize the conversation to free up context" },
  { name: "context", description: "Show what fills the context window" },
  { name: "memory", description: "Edit crok's memory files" },
  { name: "review-pr", description: "Review a pull request and leave comments", hint: "<number>" },
  { name: "release-notes", description: "Draft release notes in six languages" },
  { name: "model", description: "Shadowed by the device's own /model" },
];

/** Sessions only on the computer's disk (the catalog): offline until opened, transcript not fetched yet. */
const CATALOG = { online: false, historyState: "none" as const, previewKind: "assistant" as const };

/**
 * `sessions:groups`: five projects on two computers, in the relay's order. crok-build has more than a section shows,
 * sessions in folders of their own (a worktree, a subfolder), and sessions listed from disk; dev-box is offline.
 */
export function fakeGroups(now: number): ProjectGroup[] {
  const crok = "/Users/me/code/crok-build";
  const rows: SessionRow[] = [
    fakeRow(now, {
      _id: "s_web" as SessionId,
      project: "/Users/me/code/web-app",
      title: "Fix the flaky login test",
      cwd: "/Users/me/code/web-app",
      status: "running",
      pinned: true,
      preview: "Running the auth suite again with the cache fix",
      previewKind: "tool",
      lastActivityAt: now - 1 * MIN,
      plan: { done: 3, total: 5 },
    }),
    fakeRow(now, {
      _id: "s_new_health" as SessionId,
      project: "/Users/me/code/web-app",
      sessionId: "pending:5f0c9a7e-1d2b-4c3a-9e8f-7a6b5c4d3e2f",
      title: "Add a /health endpoint with a DB check",
      cwd: "/Users/me/code/web-app",
      status: "running",
      online: false,
      starting: true,
      lastActivityAt: now - 0.2 * MIN,
    }),
    fakeRow(now, {
      _id: "s_web_react" as SessionId,
      project: "/Users/me/code/web-app",
      title: "Upgrade to React 19.3",
      cwd: "/Users/me/code/web-app",
      ...CATALOG,
      preview: "Bumped react and react-dom; two type errors are left in the editor.",
      lastActivityAt: now - 6 * DAY,
    }),
    fakeRow(now, {
      _id: "s_relay" as SessionId,
      project: crok,
      title: "Group the remote list by project",
      cwd: `${crok}/.claude/worktrees/remote-relay`,
      preview: "Also let people reorder the sessions",
      previewKind: "user",
      lastActivityAt: now - 8 * MIN,
    }),
    fakeRow(now, {
      _id: "s_docs" as SessionId,
      project: crok,
      title: "Write the release notes for 1.5",
      cwd: crok,
      preview: "Translate them into the five other languages too",
      previewKind: "user",
      lastActivityAt: now - 3 * HOUR,
      unread: 1,
    }),
    fakeRow(now, {
      _id: "s_perf" as SessionId,
      project: crok,
      title: "Profile the slow transcript scroll",
      cwd: `${crok}/desktop`,
      app: "desktop",
      status: "error",
      preview: "Model request failed: 529 overloaded",
      previewKind: "error",
      lastActivityAt: now - 4 * DAY,
    }),
    fakeRow(now, {
      _id: "s_cat_tui" as SessionId,
      project: crok,
      title: "Translate the TUI settings",
      cwd: crok,
      ...CATALOG,
      preview: "All 2,630 strings are in the catalog now.",
      lastActivityAt: now - 5 * DAY,
    }),
    fakeRow(now, {
      _id: "s_cat_rust" as SessionId,
      project: crok,
      title: "Bump the Rust toolchain to 1.94",
      cwd: crok,
      ...CATALOG,
      preview: "Clippy is clean; two new lints are allowed for now.",
      lastActivityAt: now - 9 * DAY,
    }),
    fakeRow(now, {
      _id: "s_cat_pty" as SessionId,
      project: crok,
      title: "Fix the flaky PTY test",
      cwd: `${crok}/crates`,
      ...CATALOG,
      preview: "The pty is drained before waitpid now.",
      lastActivityAt: now - 12 * DAY,
    }),
    fakeRow(now, {
      _id: "s_cat_icons" as SessionId,
      project: crok,
      title: "Clean up the app icons",
      cwd: crok,
      online: false,
      historyState: "ready",
      preview: "Removed the unused 16 px variants.",
      previewKind: "assistant",
      lastActivityAt: now - 20 * DAY,
    }),
    fakeRow(now, {
      _id: "s_settings" as SessionId,
      project: "/Users/me/code/settings-ui",
      title: "Add dark mode to Settings",
      cwd: "/Users/me/code/settings-ui",
      status: "waiting",
      app: "desktop",
      preview: "Should the theme follow the system by default?",
      previewKind: "assistant",
      lastActivityAt: now - 14 * MIN,
      unread: 2,
    }),
    fakeRow(now, {
      _id: "s_billing" as SessionId,
      project: "/home/me/billing-service",
      title: "Migrate the billing API to v2",
      cwd: "/home/me/billing-service",
      deviceId: box,
      preview: "Updated 12 call sites and the webhook handler. Tests pass.",
      previewKind: "assistant",
      lastActivityAt: now - 26 * HOUR,
    }),
    fakeRow(now, {
      _id: "s_infra" as SessionId,
      project: "/home/me/infra",
      title: "Rotate the staging certificates",
      cwd: "/home/me/infra",
      deviceId: box,
      ...CATALOG,
      preview: "Done. Certificates renew on the 1st of each month now.",
      lastActivityAt: now - 40 * DAY,
    }),
  ];
  const groups: ProjectGroup[] = [];
  for (const row of rows) {
    let group = groups.find((g) => g.key === row.projectKey);
    if (!group) {
      group = {
        key: row.projectKey,
        deviceId: row.deviceId,
        deviceName: row.deviceName,
        deviceOnline: row.deviceOnline,
        deviceLastSeenAt: row.deviceOnline ? null : row.lastActivityAt,
        path: row.projectPath,
        name: row.projectName,
        placed: true,
        lastActivityAt: row.lastActivityAt,
        sessions: [],
      };
      groups.push(group);
    }
    group.lastActivityAt = Math.max(group.lastActivityAt, row.lastActivityAt);
    group.sessions.push(row);
  }
  return groups;
}

/** `sessions:list({archived: true})`. */
export function fakeArchived(now: number): SessionRow[] {
  return [
    fakeRow(now, {
      _id: "s_arch_tok" as SessionId,
      project: "/Users/me/code/crok-build",
      title: "Try the new tokenizer",
      cwd: "/Users/me/code/crok-build",
      online: false,
      archived: true,
      preview: "It saves 4% on English and 11% on Chinese prompts.",
      previewKind: "assistant",
      lastActivityAt: now - 15 * DAY,
    }),
    fakeRow(now, {
      _id: "s_arch_deploy" as SessionId,
      project: "/home/me/infra",
      title: "Retire the old deploy script",
      cwd: "/home/me/infra/scripts",
      deviceId: box,
      archived: true,
      preview: "Removed deploy.sh; the pipeline uses the new action.",
      previewKind: "assistant",
      lastActivityAt: now - 52 * DAY,
    }),
  ];
}

export function fakeComputers(): Pick<DeviceRow, "_id" | "name" | "online">[] {
  return Object.entries(COMPUTERS).map(([id, c]) => ({ _id: id as DeviceRow["_id"], name: c.name, online: c.online }));
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
    projectKey: `${mac}:/Users/me/code/web-app`,
    projectPath: "/Users/me/code/web-app",
    projectName: "web-app",
    historyState: null,
    starting: false,
    pending: null,
    models: FAKE_MODELS,
    ...overrides,
  };
}

/**
 * A session only listed from the computer's disk, just opened: no transcript yet. On an online computer the relay has
 * asked for it ("Loading from MacBook Pro…"); on an offline one it waits for crok to run there.
 */
export function fakeCatalogSession(now: number, computerOnline: boolean): SessionDetail {
  const crok = "/Users/me/code/crok-build";
  return fakeSession(now, {
    _id: (computerOnline ? "s_cat_tui" : "s_infra") as SessionId,
    title: computerOnline ? "Translate the TUI settings" : "Rotate the staging certificates",
    cwd: computerOnline ? crok : "/home/me/infra",
    effort: null,
    gitBranch: computerOnline ? "main" : null,
    status: "idle",
    online: false,
    app: "tui",
    deviceId: computerOnline ? mac : box,
    deviceName: computerOnline ? "MacBook Pro" : "dev-box",
    devicePlatform: computerOnline ? "macOS 26.1 (arm64)" : "Linux 6.8 (x86_64)",
    deviceOnline: computerOnline,
    createdAt: now - (computerOnline ? 6 : 41) * DAY,
    lastActivityAt: now - (computerOnline ? 5 : 40) * DAY,
    plan: [],
    usage: null,
    pinned: false,
    eventSeq: 0,
    projectKey: computerOnline ? `${mac}:${crok}` : `${box}:/home/me/infra`,
    projectPath: computerOnline ? crok : "/home/me/infra",
    projectName: computerOnline ? "crok-build" : "infra",
    historyState: computerOnline ? "requested" : "none",
  });
}

/** A session just started from the web (`sessions:create`): listed at once, not open on MacBook Pro yet. */
export function fakeStartingSession(now: number): SessionDetail {
  return fakeSession(now, {
    _id: "s_new_health" as SessionId,
    sessionId: "pending:5f0c9a7e-1d2b-4c3a-9e8f-7a6b5c4d3e2f",
    title: "Add a /health endpoint with a DB check",
    effort: null,
    gitBranch: null,
    status: "running",
    online: false,
    starting: true,
    createdAt: now - 0.2 * MIN,
    lastActivityAt: now - 0.2 * MIN,
    plan: [],
    usage: null,
    pinned: false,
    eventSeq: 0,
  });
}

/** Its `create` command, as `commands:forSession` lists it (taken by the computer, the session opening). */
export function fakeStartingCommands(now: number): PromptCommand[] {
  return [
    {
      _id: "cmd_create" as CommandId,
      type: "create",
      clientId: "c_create",
      text: "Add a /health endpoint that also checks the database connection, with a test.",
      status: "delivered",
      error: null,
      fromLabel: "Web",
      fromDeviceId: null,
      mine: true,
      createdAt: now - 0.2 * MIN,
      updatedAt: now - 0.1 * MIN,
    },
  ];
}

/** `/model` and `/think` answers in every state: picking, applying, done, refused, and an argument that matched nothing. */
export function fakeCards(now: number): BotCard[] {
  return [
    { id: "card-1", kind: "model", createdAt: now - 7 * MIN, state: "done", value: "grok-4" },
    { id: "card-2", kind: "model", createdAt: now - 6 * MIN, state: "choosing", miss: { arg: "gpt", reason: "none" } },
    {
      id: "card-3",
      kind: "model",
      createdAt: now - 5 * MIN,
      state: "failed",
      value: "anthropic/claude-sonnet-4-5",
      error: "That model is not available on this computer.",
    },
    { id: "card-4", kind: "reasoning_effort", createdAt: now - 4 * MIN, state: "applying", value: "xhigh" },
    { id: "card-5", kind: "model", createdAt: now - 3 * MIN, state: "choosing" },
  ];
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

/**
 * The Markdown showcase (relay/scripts/markdown-showcase.md, read by the preview page) as a finished reply, or, with
 * `streaming`, two replies caught mid-stream: one inside an unclosed `$$` and `**`, the last inside an unclosed fence.
 */
export function markdownEvents(now: number, showcase: string, streaming = false): TranscriptEvent[] {
  const ask = ev(1, now - 4 * MIN, { kind: "user", text: "Show me everything a reply can render." });
  if (!streaming) {
    return [ask, ev(2, now - 3 * MIN, { kind: "assistant", text: showcase })].reverse();
  }
  const fence = showcase.indexOf("for f in *.log");
  return [
    ask,
    ev(2, now - 3 * MIN, {
      kind: "assistant",
      text: "Half-way through a formula, **and a bold\n\n$$\n\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt",
    }),
    ev(3, now - 2.5 * MIN, { kind: "tool", title: "Read src/main.rs", toolKind: "read", status: "completed", text: "" }),
    ev(4, now - 2 * MIN, { kind: "assistant", text: showcase.slice(0, fence + "for f in *.log; do".length) }),
  ].reverse();
}

export function fakeCommands(now: number): PromptCommand[] {
  return [
    {
      _id: "cmd_3" as CommandId,
      type: "prompt",
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
      type: "prompt",
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
      type: "prompt",
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

/** `users:me` for the Profile page (a made-up person; no picture, so the initials show). */
export function fakeAccount() {
  return { name: "Alex Rivera", email: "alex@example.com", imageUrl: null };
}

/** A small photo drawn on a canvas, for the Photo theme in the preview (no file to pick there). */
export function fakePhotoUrl(): string {
  const canvas = document.createElement("canvas");
  canvas.width = 640;
  canvas.height = 480;
  const ctx = canvas.getContext("2d");
  if (!ctx) return "";
  const sky = ctx.createLinearGradient(0, 0, 0, 480);
  sky.addColorStop(0, "#f6b26b");
  sky.addColorStop(0.55, "#e06666");
  sky.addColorStop(1, "#3d2b56");
  ctx.fillStyle = sky;
  ctx.fillRect(0, 0, 640, 480);
  ctx.fillStyle = "#ffd966";
  ctx.beginPath();
  ctx.arc(420, 260, 60, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#20124d";
  ctx.beginPath();
  ctx.moveTo(0, 480);
  ctx.lineTo(0, 330);
  ctx.lineTo(160, 250);
  ctx.lineTo(300, 340);
  ctx.lineTo(470, 230);
  ctx.lineTo(640, 320);
  ctx.lineTo(640, 480);
  ctx.fill();
  return canvas.toDataURL("image/jpeg", 0.85);
}
