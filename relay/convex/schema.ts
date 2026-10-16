import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

/** Who a linked device is: a computer runs crok (TUI or Crok Desktop) and hosts sessions; a phone views and controls them. */
export const deviceKind = v.union(v.literal("computer"), v.literal("phone"));

/** Which crok front end hosts a session. */
export const hostApp = v.union(v.literal("tui"), v.literal("desktop"), v.literal("cli"));

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

/** `history`: the relay asks any running crok on the computer to read a session's transcript from disk. */
export const commandType = v.union(v.literal("prompt"), v.literal("cancel"), v.literal("info"), v.literal("history"));

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

export const sessionUsage = v.object({
  inputTokens: v.optional(v.number()),
  outputTokens: v.optional(v.number()),
  cachedTokens: v.optional(v.number()),
  reasoningTokens: v.optional(v.number()),
  costUsd: v.optional(v.number()),
  contextTokens: v.optional(v.number()),
  contextWindow: v.optional(v.number()),
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
    startedAt: v.number(),
    lastSeenAt: v.number(),
    online: v.boolean(),
  })
    .index("by_instance", ["deviceId", "instanceId"])
    .index("by_device", ["deviceId"])
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
   * minutes, however many crok processes run there.
   */
  catalogSyncs: defineTable({
    deviceId: v.id("devices"),
    hostId: v.id("hosts"),
    syncId: v.string(),
    startedAt: v.number(),
    finishedAt: v.optional(v.number()),
  }).index("by_device", ["deviceId"]),

  /** One transcript item. Streaming text updates the same row (same `key`). */
  events: defineTable({
    sessionDocId: v.id("sessions"),
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
