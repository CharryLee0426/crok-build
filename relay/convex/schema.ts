import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

/** Who a linked device is: a computer runs crok (TUI or Crok Desktop) and hosts sessions; a phone views and controls them. */
export const deviceKind = v.union(v.literal("computer"), v.literal("phone"));

/** Which crok front end hosts a session. */
export const hostApp = v.union(v.literal("tui"), v.literal("desktop"), v.literal("cli"));

/** Where a session made by `sessions:create` was started: the device's kind (`web` for the web app) and name, and when. */
export const startedFrom = v.object({
  kind: v.union(v.literal("phone"), v.literal("web"), v.literal("computer")),
  name: v.string(),
  at: v.number(),
});

/** Where a session's turn is: `waiting` means the agent asked a question or a permission on the computer. */
export const sessionStatus = v.union(
  v.literal("idle"),
  v.literal("running"),
  v.literal("waiting"),
  v.literal("error"),
);

export const eventKind = v.union(
  v.literal("user"),
  v.literal("assistant"),
  v.literal("thought"),
  v.literal("tool"),
  v.literal("system"),
  v.literal("error"),
);

/**
 * `history`: the relay asks any running crok on the computer to read a session's transcript from disk. `answer`: a
 * choice for the session's pending permission request. `create`: open a new crok session for a `pending:` row (and run
 * its first prompt, `text`). `config`: set the session's model or thinking level (`configId`, value in `text`).
 */
export const commandType = v.union(
  v.literal("prompt"),
  v.literal("cancel"),
  v.literal("info"),
  v.literal("history"),
  v.literal("answer"),
  v.literal("create"),
  v.literal("config"),
  v.literal("git"),
);

/** The settings `commands:setConfig` changes, named as crok's `session/set_config_option` names them. */
export const configId = v.union(v.literal("model"), v.literal("reasoning_effort"));

/**
 * One thinking level a model offers (crok's `reasoning_effort` choices): `id` is what `commands:setConfig` takes,
 * `value` the level it stands for (`low`, `high`, …), which is what a session's `effort` says.
 */
export const effortOption = v.object({
  id: v.string(),
  name: v.string(),
  value: v.optional(v.string()),
  description: v.optional(v.string()),
});

/** A model a crok process can run, with its thinking levels (none: the model has no thinking level to choose). */
export const modelOption = v.object({
  id: v.string(),
  name: v.string(),
  description: v.optional(v.string()),
  efforts: v.array(effortOption),
  defaultEffort: v.optional(v.string()),
});

/** One slash command a session offers, without the leading `/`. */
export const slashCommand = v.object({
  name: v.string(),
  description: v.string(),
  hint: v.optional(v.string()),
});

/**
 * For a session listed from the computer's disk while no crok runs it: `none` = no transcript on the relay yet,
 * `requested` = a computer was asked for it, `ready` = it is here. Unset for sessions a running crok mirrors.
 */
export const historyState = v.union(v.literal("none"), v.literal("requested"), v.literal("ready"));

/**
 * `pending` → the computer has not picked it up (clock); `delivered` → the computer accepted it (one check);
 * `done` → finished, for a prompt the turn ended (two checks); `failed` → `error` says why (red "!").
 */
export const commandStatus = v.union(
  v.literal("pending"),
  v.literal("delivered"),
  v.literal("done"),
  v.literal("failed"),
);

export const planEntry = v.object({
  content: v.string(),
  status: v.string(),
});

/** One choice of a pending request: `kind` is ACP's `allow_once`, `allow_always`, `reject_once` or `reject_always`. */
export const pendingOption = v.object({
  optionId: v.string(),
  name: v.string(),
  kind: v.string(),
});

/**
 * What the session waits for: a permission request (run this command, edit that file) any of the person's devices may
 * answer. `id` names this request; an answer for another id is ignored.
 */
export const pendingInteraction = v.object({
  id: v.string(),
  kind: v.literal("permission"),
  title: v.string(),
  detail: v.optional(v.string()),
  toolKind: v.optional(v.string()),
  options: v.array(pendingOption),
  at: v.number(),
});

export const sessionUsage = v.object({
  inputTokens: v.optional(v.number()),
  outputTokens: v.optional(v.number()),
  cachedTokens: v.optional(v.number()),
  reasoningTokens: v.optional(v.number()),
  costUsd: v.optional(v.number()),
  contextTokens: v.optional(v.number()),
  contextWindow: v.optional(v.number()),
  /** Output tokens per second, the session average as its computer measured it. */
  outputTokensPerSecond: v.optional(v.number()),
});

export default defineSchema({
  /** A person, created the first time they sign in on the web (Clerk, GitHub or Google). */
  users: defineTable({
    tokenIdentifier: v.string(),
    name: v.optional(v.string()),
    email: v.optional(v.string()),
    imageUrl: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_token", ["tokenIdentifier"]),

  /**
   * A computer or phone linked to a user through the device sign-in. It holds a long-lived refresh token (only its
   * SHA-256 is stored here) and trades it for one-hour device JWTs. `revokedAt` signs it out everywhere at once.
   */
  devices: defineTable({
    userId: v.id("users"),
    kind: deviceKind,
    name: v.string(),
    platform: v.string(),
    client: v.string(),
    refreshTokenHash: v.string(),
    createdAt: v.number(),
    /** Coarse (at most every few minutes) so viewers' device lists are not re-run by every heartbeat. */
    lastSeenAt: v.number(),
    /** A computer is online while any of its hosts is; flipped only on change. */
    online: v.boolean(),
    revokedAt: v.optional(v.number()),
  })
    .index("by_user", ["userId"])
    .index("by_refresh", ["refreshTokenHash"]),

  /** A sign-in in progress (RFC 8628 style): the device shows `userCode`, a signed-in user approves it on the web. */
  deviceLogins: defineTable({
    deviceCodeHash: v.string(),
    userCode: v.string(),
    kind: deviceKind,
    name: v.string(),
    platform: v.string(),
    client: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("approved"),
      v.literal("denied"),
      v.literal("consumed"),
    ),
    userId: v.optional(v.id("users")),
    deviceId: v.optional(v.id("devices")),
    createdAt: v.number(),
    expiresAt: v.number(),
  })
    .index("by_user_code", ["userCode"])
    .index("by_device_code", ["deviceCodeHash"])
    .index("by_expires", ["expiresAt"]),

  /**
   * One running crok process on a computer (a TUI, or one Crok Desktop task). Its heartbeat touches only this row,
   * which no viewer query reads; a cron flips `online` when the heartbeat stops.
   */
  hosts: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    instanceId: v.string(),
    app: hostApp,
    appVersion: v.string(),
    pid: v.optional(v.number()),
    /** It can open a session nobody runs, to take a prompt for it. */
    canAdopt: v.optional(v.boolean()),
    /**
     * Command types beyond the first relay's that this crok handles (`create`, `config`, `git`); older crok processes
     * get none of those (their inbox would not parse them). `setup`: it applies a `create` command's model and thinking
     * level. `catalog`: while it holds its computer's catalog it sends what changed on disk (`bridge:catalogUpdate`).
     */
    features: v.optional(v.array(v.string())),
    startedAt: v.number(),
    lastSeenAt: v.number(),
    online: v.boolean(),
  })
    .index("by_instance", ["deviceId", "instanceId"])
    .index("by_device", ["deviceId"])
    .index("by_device_online", ["deviceId", "online"])
    .index("by_online_seen", ["online", "lastSeenAt"]),

  /**
   * A crok session on a computer: mirrored live while a crok process runs it, or listed from the computer's disk (the
   * catalog) otherwise. `sessionId` is crok's own id (UUIDv7).
   */
  sessions: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    hostId: v.id("hosts"),
    sessionId: v.string(),
    app: hostApp,
    title: v.string(),
    cwd: v.string(),
    model: v.optional(v.string()),
    effort: v.optional(v.string()),
    gitBranch: v.optional(v.string()),
    status: sessionStatus,
    online: v.boolean(),
    preview: v.optional(v.string()),
    previewKind: v.optional(eventKind),
    plan: v.optional(v.array(planEntry)),
    usage: v.optional(sessionUsage),
    createdAt: v.number(),
    lastActivityAt: v.number(),
    /** Highest event `seq` written; the bridge continues from it. */
    eventSeq: v.number(),
    /** Assistant messages so far and how many the user has seen: the unread badge is the difference. */
    assistantCount: v.number(),
    readAssistantCount: v.number(),
    pinned: v.optional(v.boolean()),
    archived: v.optional(v.boolean()),
    /**
     * The project the session is grouped under on its computer: a crok worktree's source workspace, else the git
     * root, else the cwd. Unset on rows from before projects (they group by `cwd`).
     */
    projectPath: v.optional(v.string()),
    /** Its place in the project, set by reordering (lower first). Unplaced sessions come first, newest first. */
    position: v.optional(v.number()),
    historyState: v.optional(historyState),
    /** Offline only because its host stopped heartbeating: it comes back with the host (a closed one does not). */
    suspended: v.optional(v.boolean()),
    /** A permission request waiting for an answer, from the computer or from any other device. */
    pending: v.optional(pendingInteraction),
    /**
     * The device that started it (`sessions:create`: a phone, the web, another computer), so the computer's own TUI
     * and Crok Desktop show it as one of theirs. Unset for sessions started on the computer itself.
     */
    startedFrom: v.optional(startedFrom),
  })
    .index("by_user_activity", ["userId", "lastActivityAt"])
    .index("by_user_session", ["userId", "sessionId"])
    .index("by_host", ["hostId"])
    .index("by_device", ["deviceId"]),

  /**
   * A project (folder) on a computer, for its place in the list. Sessions point at it by `(deviceId, projectPath)`;
   * a row exists once a session names the folder or the person reorders.
   */
  projects: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    path: v.string(),
    /** Set by reordering (lower first). Unplaced projects come first, most recently active first. */
    position: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_device_path", ["deviceId", "path"]),

  /**
   * The last catalog upload per computer: one running crok at a time lists every session on disk, at most every few
   * minutes, however many crok processes run there. That process (`hostId`) holds the catalog: a current crok keeps
   * it current between uploads with what changed on disk (`bridge:catalogUpdate`), and another process takes it over
   * once it is gone.
   */
  catalogSyncs: defineTable({
    deviceId: v.id("devices"),
    hostId: v.id("hosts"),
    syncId: v.string(),
    startedAt: v.number(),
    finishedAt: v.optional(v.number()),
    /** The holder is gone (it quit or lost its connection): the computer's other crok processes list them now. */
    released: v.optional(v.boolean()),
  }).index("by_device", ["deviceId"]),

  /** One transcript item. Streaming text updates the same row (same `key`). */
  events: defineTable({
    sessionDocId: v.id("sessions"),
    /**
     * The session's owner, so `sessions:transcript` can check access without reading the session (whose every change
     * would re-run each loaded part of a long transcript). Unset on items from before it.
     */
    userId: v.optional(v.id("users")),
    seq: v.number(),
    key: v.string(),
    kind: eventKind,
    text: v.string(),
    title: v.optional(v.string()),
    toolKind: v.optional(v.string()),
    status: v.optional(v.string()),
    /** For a user prompt: `remote` when it came from a phone or the web, with the command that carried it. */
    origin: v.optional(v.union(v.literal("local"), v.literal("remote"))),
    commandId: v.optional(v.id("commands")),
    /** Who sent a remote prompt ("Ada's iPhone", "Web"). */
    fromLabel: v.optional(v.string()),
    at: v.number(),
  })
    .index("by_session_seq", ["sessionDocId", "seq"])
    .index("by_session_key", ["sessionDocId", "key"]),

  /** Something a viewer asked a computer to do; the bridge claims and completes it. */
  commands: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    sessionDocId: v.id("sessions"),
    type: commandType,
    text: v.optional(v.string()),
    /** For `answer`: the pending request it answers (`text` holds the chosen option). */
    interactionId: v.optional(v.string()),
    /** For `config`: the setting it changes (`text` holds the value). */
    configId: v.optional(configId),
    /**
     * For `create`: the model and thinking level chosen for the new session (`effort` is what `commands:setConfig`
     * takes), applied by its computer before the first prompt.
     */
    model: v.optional(v.string()),
    effort: v.optional(v.string()),
    /** Client-made id: makes a resend idempotent and lets the sender match its optimistic bubble. */
    clientId: v.optional(v.string()),
    status: commandStatus,
    result: v.optional(v.any()),
    error: v.optional(v.string()),
    fromDeviceId: v.optional(v.id("devices")),
    fromLabel: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_device_status", ["deviceId", "status"])
    .index("by_session", ["sessionDocId", "createdAt"])
    .index("by_client_id", ["userId", "clientId"])
    .index("by_status_created", ["status", "createdAt"]),

  /**
   * The slash commands a session offers (`bridge:setCommands`); the row without `sessionDocId` is its computer's latest
   * list, for sessions no crok runs. Apart from `sessions` so the list query does not re-send them.
   */
  commandLists: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    sessionDocId: v.optional(v.id("sessions")),
    commands: v.array(slashCommand),
    updatedAt: v.number(),
  })
    .index("by_session", ["sessionDocId"])
    .index("by_device_session", ["deviceId", "sessionDocId"]),

  /**
   * The models a computer's crok can run, with their thinking levels (`bridge:setModels`, the latest from any of its
   * processes). One row per computer, apart from `hosts` (heartbeats would re-send it to every open session).
   */
  modelLists: defineTable({
    userId: v.id("users"),
    deviceId: v.id("devices"),
    models: v.array(modelOption),
    updatedAt: v.number(),
  }).index("by_device", ["deviceId"]),

  /**
   * The phones' o11y pages as last built from the owner's Grafana stack (relay/DESIGN.md §3 "o11y"), one row per
   * `page|range|lang`. `refreshingSince` is set while `o11y:refresh` builds it; `error` is the last build's failure
   * (the older page stays).
   */
  o11yPages: defineTable({
    key: v.string(),
    page: v.optional(v.any()),
    builtAt: v.optional(v.number()),
    refreshingSince: v.optional(v.number()),
    error: v.optional(v.string()),
    updatedAt: v.number(),
  }).index("by_key", ["key"]),

  /** A viewer has this session open; while `until` is ahead the bridge streams text at a fine grain. */
  sessionViews: defineTable({
    sessionDocId: v.id("sessions"),
    deviceId: v.id("devices"),
    viewer: v.string(),
    until: v.number(),
  })
    .index("by_session_viewer", ["sessionDocId", "viewer"])
    .index("by_device", ["deviceId"])
    .index("by_until", ["until"]),
});
