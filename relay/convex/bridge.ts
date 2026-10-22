import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { fail, requireHost, requireViewer } from "./lib/auth";
import { ensureProject, inferProjectPath } from "./lib/projects";
import { appendNotice, isStarting, supports } from "./lib/starting";
import {
  eventKind,
  hostApp,
  modelOption,
  pendingInteraction,
  planEntry,
  sessionStatus,
  sessionUsage,
  slashCommand,
} from "./schema";

/**
 * The computer side. Every running crok process that is signed in (a TUI, or one Crok Desktop task) is a "host": it
 * `connect`s, heartbeats, mirrors the sessions it runs (`upsertSession`, `pushEvents`), and watches `inbox` for
 * commands from phones and the web, which it `claimCommand`s and `completeCommand`s.
 */

const MAX_EVENT_TEXT = 32_000;
const MAX_EVENTS_PER_CALL = 100;
const DEVICE_SEEN_GRANULARITY_MS = 5 * 60 * 1000;
const INLINE_DELETE_LIMIT = 2_000;
/** A computer lists its sessions at most this often, whichever of its crok processes does it. */
const CATALOG_INTERVAL_MS = 10 * 60 * 1000;
/** A catalog upload that has not finished in this long is abandoned; another process may start one. */
const CATALOG_STALE_MS = 2 * 60 * 1000;
const MAX_CATALOG_PER_CALL = 100;
const MAX_MODELS = 200;
const MAX_COMMANDS = 500;

function capText(text: string): string {
  if (text.length <= MAX_EVENT_TEXT) return text;
  return `${text.slice(0, MAX_EVENT_TEXT - 40)}\n\n… [${text.length - MAX_EVENT_TEXT + 40} more characters on the computer]`;
}

async function markDeviceOnline(ctx: MutationCtx, device: Doc<"devices">, now: number) {
  const patch: Partial<Doc<"devices">> = {};
  if (!device.online) patch.online = true;
  if (now - device.lastSeenAt > DEVICE_SEEN_GRANULARITY_MS) patch.lastSeenAt = now;
  if (Object.keys(patch).length > 0) await ctx.db.patch(device._id, patch);
}

/**
 * Registers this process. `instanceId` is random per process, so a restart is a new host. `canAdopt`: it can open a
 * session nobody runs when a prompt arrives for it.
 */
export const connect = mutation({
  args: {
    instanceId: v.string(),
    app: hostApp,
    appVersion: v.string(),
    pid: v.optional(v.number()),
    canAdopt: v.optional(v.boolean()),
    features: v.optional(v.array(v.string())),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const viewer = await requireViewer(ctx);
    const device = viewer.device;
    if (!device || device.kind !== "computer") fail("FORBIDDEN", "Only a linked computer can host sessions.");
    const existing = await ctx.db
      .query("hosts")
      .withIndex("by_instance", (q) => q.eq("deviceId", device._id).eq("instanceId", args.instanceId))
      .unique();
    let hostId: Id<"hosts">;
    if (existing) {
      hostId = existing._id;
      await ctx.db.patch(hostId, {
        lastSeenAt: now,
        online: true,
        appVersion: args.appVersion,
        pid: args.pid,
        canAdopt: args.canAdopt,
        features: args.features,
      });
      await setHostSessionsOnline(ctx, hostId, true);
    } else {
      hostId = await ctx.db.insert("hosts", {
        userId: viewer.user._id,
        deviceId: device._id,
        instanceId: args.instanceId,
        app: args.app,
        appVersion: args.appVersion.slice(0, 80),
        pid: args.pid,
        canAdopt: args.canAdopt,
        features: args.features,
        startedAt: now,
        lastSeenAt: now,
        online: true,
      });
    }
    await markDeviceOnline(ctx, device, now);
    return { hostId, deviceId: device._id, serverTime: now };
  },
});

async function setHostSessionsOnline(ctx: MutationCtx, hostId: Id<"hosts">, online: boolean) {
  const sessions = await ctx.db
    .query("sessions")
    .withIndex("by_host", (q) => q.eq("hostId", hostId))
    .collect();
  for (const session of sessions) {
    // A session another host took over stays with that host.
    if (session.hostId !== hostId) continue;
    if (online) {
      // Only what went offline with the host: not sessions closed since, nor ones only listed from disk.
      if (session.suspended) await ctx.db.patch(session._id, { online: true, suspended: undefined });
    } else if (session.online) {
      await ctx.db.patch(session._id, { online: false, status: "idle", suspended: true, pending: undefined });
    }
  }
}

/** Every 30 s. Touches only the host row (no viewer reads it) unless the host had been marked offline. */
export const heartbeat = mutation({
  args: { hostId: v.id("hosts") },
  handler: async (ctx, { hostId }) => {
    const now = Date.now();
    const { viewer, host } = await requireHost(ctx, hostId);
    await ctx.db.patch(hostId, { lastSeenAt: now, ...(host.online ? {} : { online: true }) });
    if (!host.online) await setHostSessionsOnline(ctx, hostId, true);
    await markDeviceOnline(ctx, viewer.device, now);
    return { serverTime: now };
  },
});

/** On a clean exit or sign-out. The cron does the same for a host that just stops heartbeating. */
export const disconnect = mutation({
  args: { hostId: v.id("hosts") },
  handler: async (ctx, { hostId }) => {
    const { host } = await requireHost(ctx, hostId);
    await markHostOffline(ctx, host);
    return null;
  },
});

export async function markHostOffline(ctx: MutationCtx, host: Doc<"hosts">) {
  if (host.online) await ctx.db.patch(host._id, { online: false });
  await setHostSessionsOnline(ctx, host._id, false);
  const others = await ctx.db
    .query("hosts")
    .withIndex("by_device", (q) => q.eq("deviceId", host.deviceId))
    .collect();
  const anyOnline = others.some((h) => h._id !== host._id && h.online);
  const device = await ctx.db.get(host.deviceId);
  if (device && device.online !== anyOnline) await ctx.db.patch(device._id, { online: anyOnline });
}

const sessionFields = {
  title: v.optional(v.string()),
  cwd: v.optional(v.string()),
  model: v.optional(v.string()),
  effort: v.optional(v.string()),
  gitBranch: v.optional(v.string()),
  status: v.optional(sessionStatus),
  preview: v.optional(v.string()),
  previewKind: v.optional(eventKind),
  plan: v.optional(v.array(planEntry)),
  usage: v.optional(sessionUsage),
  createdAt: v.optional(v.number()),
  lastActivityAt: v.optional(v.number()),
  projectPath: v.optional(v.string()),
};

/**
 * Creates or updates the mirror of one session this host runs, writing only the fields that changed (each write
 * re-runs the viewers' session lists). Taking over a session another host ran moves it here.
 */
export const upsertSession = mutation({
  args: { hostId: v.id("hosts"), sessionId: v.string(), fields: v.object(sessionFields) },
  handler: async (ctx, { hostId, sessionId, fields }) => {
    const now = Date.now();
    const { viewer, host } = await requireHost(ctx, hostId);
    const clipped = {
      ...fields,
      title: fields.title?.slice(0, 200),
      preview: fields.preview?.slice(0, 280),
      plan: fields.plan?.slice(0, 100),
    };
    const defined = Object.fromEntries(Object.entries(clipped).filter(([, value]) => value !== undefined));
    const existing = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    if (!existing) {
      const projectPath = clipped.projectPath || (await inferProjectPath(ctx, viewer.device._id, clipped.cwd ?? ""));
      await ensureProject(ctx, viewer.user._id, viewer.device._id, projectPath);
      const sessionDocId = await ctx.db.insert("sessions", {
        userId: viewer.user._id,
        deviceId: viewer.device._id,
        hostId,
        sessionId,
        app: host.app,
        projectPath,
        title: clipped.title || "New session",
        cwd: clipped.cwd ?? "",
        model: clipped.model,
        effort: clipped.effort,
        gitBranch: clipped.gitBranch,
        status: clipped.status ?? "idle",
        online: true,
        preview: clipped.preview,
        previewKind: clipped.previewKind,
        plan: clipped.plan,
        usage: clipped.usage,
        createdAt: clipped.createdAt ?? now,
        lastActivityAt: clipped.lastActivityAt ?? now,
        eventSeq: 0,
        assistantCount: 0,
        readAssistantCount: 0,
      });
      return { sessionDocId, eventSeq: 0, created: true };
    }
    const patch: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(defined)) {
      const current = (existing as Record<string, unknown>)[key];
      if (JSON.stringify(current) !== JSON.stringify(value)) patch[key] = value;
    }
    if (existing.hostId !== hostId) {
      patch.hostId = hostId;
      patch.deviceId = viewer.device._id;
      patch.app = host.app;
    }
    if (patch.projectPath === undefined && !existing.projectPath) {
      patch.projectPath = await inferProjectPath(ctx, viewer.device._id, clipped.cwd ?? existing.cwd);
    }
    if (typeof patch.projectPath === "string") {
      await ensureProject(ctx, viewer.user._id, viewer.device._id, patch.projectPath);
    }
    if (!existing.online) patch.online = true;
    if (existing.suspended) patch.suspended = undefined;
    // A session only listed from disk is running now: its own mirror owns the transcript from here.
    if (existing.historyState !== undefined) patch.historyState = undefined;
    if (existing.archived && fields.status === "running") patch.archived = false;
    if (Object.keys(patch).length > 0) await ctx.db.patch(existing._id, patch);
    return { sessionDocId: existing._id, eventSeq: existing.eventSeq, created: false };
  },
});

/** The session was closed in this process (the task or tab closed). Its transcript stays readable. */
export const closeSession = mutation({
  args: { hostId: v.id("hosts"), sessionId: v.string() },
  handler: async (ctx, { hostId, sessionId }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    if (session && session.hostId === hostId && (session.online || session.suspended)) {
      await ctx.db.patch(session._id, { online: false, status: "idle", suspended: undefined, pending: undefined });
    }
    return null;
  },
});

/**
 * The session's permission request waiting for an answer, or none (`pending` absent) once it was answered anywhere or
 * the turn ended. Viewers show it with its choices; `commands:answer` brings the choice back.
 */
export const setPending = mutation({
  args: { hostId: v.id("hosts"), sessionId: v.string(), pending: v.optional(pendingInteraction) },
  handler: async (ctx, { hostId, sessionId, pending }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    if (!session || session.hostId !== hostId) return null;
    const next = pending
      ? {
          ...pending,
          title: pending.title.slice(0, 500),
          detail: pending.detail?.slice(0, 4_000),
          options: pending.options.slice(0, 8),
        }
      : undefined;
    if (JSON.stringify(session.pending) !== JSON.stringify(next)) await ctx.db.patch(session._id, { pending: next });
    return null;
  },
});

const eventInput = v.object({
  key: v.string(),
  kind: eventKind,
  text: v.string(),
  title: v.optional(v.string()),
  toolKind: v.optional(v.string()),
  status: v.optional(v.string()),
  origin: v.optional(v.union(v.literal("local"), v.literal("remote"))),
  commandId: v.optional(v.id("commands")),
  fromLabel: v.optional(v.string()),
  at: v.number(),
});

/**
 * Whether this host may write the session's transcript: it runs the session, or nobody does and it is on the same
 * computer (a transcript read from disk for a viewer).
 */
function writable(session: Doc<"sessions"> | null, host: Doc<"hosts">): session is Doc<"sessions"> {
  if (!session) return false;
  return session.hostId === host._id || (session.deviceId === host.deviceId && !session.online);
}

/**
 * Writes transcript items. An item with a `key` already present is updated in place (streamed text, a tool call's
 * status); a new one gets the next `seq`. `replace` first drops the session's old items (a resync after the session
 * ran while this computer was not mirroring it, or a transcript read from disk). `preview` updates the list's
 * preview line along with it.
 */
export const pushEvents = mutation({
  args: {
    hostId: v.id("hosts"),
    sessionDocId: v.id("sessions"),
    replace: v.optional(v.boolean()),
    events: v.array(eventInput),
    preview: v.optional(v.string()),
    previewKind: v.optional(eventKind),
  },
  handler: async (ctx, { hostId, sessionDocId, replace, events, preview, previewKind }) => {
    const { host } = await requireHost(ctx, hostId);
    if (events.length > MAX_EVENTS_PER_CALL) fail("INVALID", `At most ${MAX_EVENTS_PER_CALL} events per call.`);
    const session = await ctx.db.get(sessionDocId);
    if (!writable(session, host)) fail("NOT_FOUND", "This host does not run that session.");
    let seq = session.eventSeq;
    let assistantCount = session.assistantCount;
    let readAssistantCount = session.readAssistantCount;
    if (replace) {
      const old = await ctx.db
        .query("events")
        .withIndex("by_session_seq", (q) => q.eq("sessionDocId", sessionDocId).lte("seq", seq))
        .take(INLINE_DELETE_LIMIT + 1);
      for (const event of old.slice(0, INLINE_DELETE_LIMIT)) await ctx.db.delete(event._id);
      if (old.length > INLINE_DELETE_LIMIT) {
        await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, {
          sessionDocId,
          throughSeq: seq,
        });
      }
      assistantCount = 0;
      readAssistantCount = 0;
    }
    let inserted = 0;
    for (const event of events) {
      const fields = {
        kind: event.kind,
        text: capText(event.text),
        title: event.title?.slice(0, 500),
        toolKind: event.toolKind,
        status: event.status,
        origin: event.origin,
        commandId: event.commandId,
        fromLabel: event.fromLabel?.slice(0, 80),
      };
      const existing = replace
        ? null
        : await ctx.db
            .query("events")
            .withIndex("by_session_key", (q) => q.eq("sessionDocId", sessionDocId).eq("key", event.key))
            .unique();
      if (existing) {
        const patch: Record<string, unknown> = {};
        for (const [key, value] of Object.entries(fields)) {
          if (value !== undefined && (existing as Record<string, unknown>)[key] !== value) patch[key] = value;
        }
        if (Object.keys(patch).length > 0) await ctx.db.patch(existing._id, patch);
      } else {
        seq += 1;
        inserted += 1;
        if (event.kind === "assistant") assistantCount += 1;
        await ctx.db.insert("events", { sessionDocId, seq, key: event.key, at: event.at, ...fields });
      }
    }
    if (replace) readAssistantCount = assistantCount;
    const patch: Partial<Doc<"sessions">> = {};
    if (
      seq !== session.eventSeq ||
      assistantCount !== session.assistantCount ||
      readAssistantCount !== session.readAssistantCount
    ) {
      patch.eventSeq = seq;
      patch.assistantCount = assistantCount;
      patch.readAssistantCount = readAssistantCount;
      // History replayed from disk is not new activity: the session keeps its place in the list.
      if (inserted > 0 && !replace) patch.lastActivityAt = Date.now();
    }
    if (replace && session.historyState !== undefined && session.historyState !== "ready") patch.historyState = "ready";
    if (preview !== undefined && preview.slice(0, 280) !== session.preview) patch.preview = preview.slice(0, 280);
    if (previewKind !== undefined && previewKind !== session.previewKind) patch.previewKind = previewKind;
    if (Object.keys(patch).length > 0) await ctx.db.patch(sessionDocId, patch);
    return { eventSeq: seq };
  },
});

/**
 * Whether this host should act on the command: one for a session it runs; for a session of this computer nobody runs,
 * a `history` request (any of its crok processes can read the transcript from disk) or a prompt (any that can open the
 * session: the first to claim it runs the session from then on).
 */
function forHost(command: Doc<"commands">, session: Doc<"sessions"> | null, host: Doc<"hosts">): boolean {
  if (!session) return false;
  if (!supports(host, command.type)) return false;
  if (command.type === "history") return session.deviceId === host.deviceId && !session.online;
  if (session.online) return session.hostId === host._id;
  return opensSession(command) && session.deviceId === host.deviceId && host.canAdopt === true;
}

/** Commands that, for a session nobody runs, make whichever crok of the computer claims them open it. */
function opensSession(command: Doc<"commands">): boolean {
  return command.type === "prompt" || command.type === "config" || command.type === "create";
}

/**
 * What this host has to act on: commands for the sessions it runs (and transcripts to read for sessions nobody runs),
 * and which sessions someone is looking at right now (`until` is in server time; `serverTime` lets the host correct
 * for its own clock).
 */
export const inbox = query({
  args: { hostId: v.id("hosts") },
  handler: async (ctx, { hostId }) => {
    const { viewer, host } = await requireHost(ctx, hostId);
    const now = Date.now();
    const pending = await ctx.db
      .query("commands")
      .withIndex("by_device_status", (q) => q.eq("deviceId", viewer.device._id).eq("status", "pending"))
      .take(200);
    const sessions = new Map<string, Doc<"sessions"> | null>();
    const sessionOf = async (id: Id<"sessions">) => {
      if (!sessions.has(id)) sessions.set(id, await ctx.db.get(id));
      return sessions.get(id) ?? null;
    };
    const commands = [];
    for (const command of pending) {
      const session = await sessionOf(command.sessionDocId);
      if (!session || !forHost(command, session, host)) continue;
      const sender = command.fromDeviceId ? await ctx.db.get(command.fromDeviceId) : null;
      commands.push({
        _id: command._id,
        sessionDocId: command.sessionDocId,
        sessionId: session.sessionId,
        cwd: session.cwd,
        type: command.type,
        text: command.text ?? null,
        /** For `answer`: the pending request it answers. */
        interactionId: command.interactionId ?? null,
        /** For `config`: the setting it changes (`text` holds the value). */
        configId: command.configId ?? null,
        /** For `create`: the model and thinking level to apply before its first prompt. */
        model: command.model ?? null,
        effort: command.effort ?? null,
        /** A prompt or config change for a session nobody runs: the host that claims it opens the session first. */
        adopt: (command.type === "prompt" || command.type === "config") && !session.online,
        fromLabel: command.fromLabel,
        /** `web` for a browser, else the sending device's kind (`phone`, or `computer`). */
        fromKind: command.fromDeviceId ? (sender?.kind ?? "phone") : "web",
        createdAt: command.createdAt,
      });
    }
    commands.sort((a, b) => a.createdAt - b.createdAt);
    const viewRows = await ctx.db
      .query("sessionViews")
      .withIndex("by_device", (q) => q.eq("deviceId", viewer.device._id))
      .collect();
    const views = [];
    for (const view of viewRows) {
      if (view.until <= now) continue;
      const session = await sessionOf(view.sessionDocId);
      if (!session || session.hostId !== hostId) continue;
      views.push({ sessionDocId: view.sessionDocId, sessionId: session.sessionId, until: view.until });
    }
    // The sessions this host runs as far as the relay knows: one another crok here took over is gone from it.
    const hosted = (
      await ctx.db
        .query("sessions")
        .withIndex("by_host", (q) => q.eq("hostId", hostId))
        .take(500)
    )
      .filter((s) => s.online)
      .map((s) => s.sessionId);
    return { commands, views, hosted, serverTime: now };
  },
});

/**
 * Takes a pending command for one of this host's sessions. False if another host or a retry got it first. Claiming a
 * prompt for a session nobody runs makes this host its runner at once, so the next commands for it come here while
 * the session opens.
 */
export const claimCommand = mutation({
  args: { hostId: v.id("hosts"), commandId: v.id("commands") },
  handler: async (ctx, { hostId, commandId }) => {
    const { viewer, host } = await requireHost(ctx, hostId);
    const command = await ctx.db.get(commandId);
    if (!command || command.deviceId !== viewer.device._id || command.status !== "pending") return false;
    const session = await ctx.db.get(command.sessionDocId);
    if (!session || !forHost(command, session, host)) return false;
    const now = Date.now();
    await ctx.db.patch(commandId, { status: "delivered", updatedAt: now });
    if (opensSession(command) && !session.online) {
      const runs = command.type === "prompt" || (command.type === "create" && command.text !== undefined);
      await ctx.db.patch(session._id, {
        hostId,
        app: host.app,
        online: true,
        suspended: undefined,
        ...(runs ? { status: "running" as const } : {}),
        ...(session.archived ? { archived: false } : {}),
      });
    }
    return true;
  },
});

export const completeCommand = mutation({
  args: {
    hostId: v.id("hosts"),
    commandId: v.id("commands"),
    status: v.union(v.literal("done"), v.literal("failed")),
    result: v.optional(v.any()),
    error: v.optional(v.string()),
  },
  handler: async (ctx, { hostId, commandId, status, result, error }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const command = await ctx.db.get(commandId);
    if (!command || command.deviceId !== viewer.device._id) return null;
    if (command.status === "done" || command.status === "failed") return null;
    await ctx.db.patch(commandId, {
      status,
      result,
      error: error?.slice(0, 2000),
      updatedAt: Date.now(),
    });
    if (command.type === "history") await settleHistory(ctx, command.sessionDocId, status === "done");
    if (command.type === "create" && status === "failed") await failCreate(ctx, command.sessionDocId, error);
    return null;
  },
});

/**
 * A new session's computer could not open it (or never picked it up): it stays listed with the reason, offline, and
 * the next prompt to it tries again.
 */
export async function failCreate(ctx: MutationCtx, sessionDocId: Id<"sessions">, error: string | undefined) {
  const session = await ctx.db.get(sessionDocId);
  if (!session || !isStarting(session)) return;
  await ctx.db.patch(sessionDocId, { online: false, status: "error", suspended: undefined, pending: undefined });
  await appendNotice(ctx, sessionDocId, "error", error?.slice(0, 2000) || "The computer could not start this session.");
}

/**
 * The crok session this host opened for a claimed `create` takes the place of the relay's `pending:` id; from then on
 * the session is mirrored like any other (`upsertSession` finds it by its new id).
 */
export const bindSession = mutation({
  args: { hostId: v.id("hosts"), sessionDocId: v.id("sessions"), sessionId: v.string() },
  handler: async (ctx, { hostId, sessionDocId, sessionId }) => {
    const { viewer, host } = await requireHost(ctx, hostId);
    const session = await ctx.db.get(sessionDocId);
    if (!session || session.deviceId !== viewer.device._id) fail("NOT_FOUND", "No such session.");
    if (!isStarting(session)) {
      if (session.sessionId === sessionId) return { sessionDocId, eventSeq: session.eventSeq };
      fail("INVALID", "This session is already open on its computer.");
    }
    if (session.hostId !== hostId || !session.online) fail("EXPIRED", "Another crok took this session over.");
    const taken = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    if (taken) fail("INVALID", "That session id is in use.");
    await ctx.db.patch(sessionDocId, { sessionId, app: host.app });
    return { sessionDocId, eventSeq: session.eventSeq };
  },
});

/** The models this computer's crok can run, with their thinking levels; written only when the list changed. */
export const setModels = mutation({
  args: { hostId: v.id("hosts"), models: v.array(modelOption) },
  handler: async (ctx, { hostId, models }) => {
    const { viewer } = await requireHost(ctx, hostId);
    if (models.length > MAX_MODELS) fail("INVALID", `At most ${MAX_MODELS} models.`);
    const clipped = models.map((m) => ({
      ...m,
      name: m.name.slice(0, 120),
      description: m.description?.slice(0, 300),
      efforts: m.efforts.slice(0, 20).map((e) => ({ ...e, name: e.name.slice(0, 60), description: e.description?.slice(0, 200) })),
    }));
    const row = await ctx.db
      .query("modelLists")
      .withIndex("by_device", (q) => q.eq("deviceId", viewer.device._id))
      .first();
    if (!row) {
      await ctx.db.insert("modelLists", {
        userId: viewer.user._id,
        deviceId: viewer.device._id,
        models: clipped,
        updatedAt: Date.now(),
      });
    } else if (JSON.stringify(row.models) !== JSON.stringify(clipped)) {
      await ctx.db.patch(row._id, { models: clipped, updatedAt: Date.now() });
    }
    return null;
  },
});

/**
 * The slash commands a session this host runs offers (and, as the fallback for sessions no crok runs, this computer's
 * latest list); written only when they changed.
 */
export const setCommands = mutation({
  args: { hostId: v.id("hosts"), sessionId: v.string(), commands: v.array(slashCommand) },
  handler: async (ctx, { hostId, sessionId, commands }) => {
    const { viewer } = await requireHost(ctx, hostId);
    if (commands.length > MAX_COMMANDS) fail("INVALID", `At most ${MAX_COMMANDS} commands.`);
    const clipped = commands.map((c) => ({
      name: c.name.replace(/^\/+/, "").slice(0, 100),
      description: c.description.slice(0, 300),
      ...(c.hint ? { hint: c.hint.slice(0, 200) } : {}),
    }));
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    const now = Date.now();
    const write = async (sessionDocId: Id<"sessions"> | undefined) => {
      const row = sessionDocId
        ? await ctx.db
            .query("commandLists")
            .withIndex("by_session", (q) => q.eq("sessionDocId", sessionDocId))
            .first()
        : await ctx.db
            .query("commandLists")
            .withIndex("by_device_session", (q) => q.eq("deviceId", viewer.device._id).eq("sessionDocId", undefined))
            .first();
      if (!row) {
        await ctx.db.insert("commandLists", {
          userId: viewer.user._id,
          deviceId: viewer.device._id,
          sessionDocId,
          commands: clipped,
          updatedAt: now,
        });
      } else if (JSON.stringify(row.commands) !== JSON.stringify(clipped)) {
        await ctx.db.patch(row._id, { commands: clipped, updatedAt: now });
      }
    };
    if (session && session.hostId === hostId) await write(session._id);
    await write(undefined);
    return null;
  },
});

/**
 * A history request ended. Done without any write (an empty transcript on disk) still counts as here; a failure lets
 * the next open ask again.
 */
export async function settleHistory(ctx: MutationCtx, sessionDocId: Id<"sessions">, done: boolean) {
  const session = await ctx.db.get(sessionDocId);
  if (!session || session.historyState !== "requested") return;
  await ctx.db.patch(sessionDocId, { historyState: done ? "ready" : "none" });
}

// MARK: Catalog: every session on the computer's disk, not only the running ones.

/**
 * Starts listing this computer's sessions, unless another of its crok processes did within the last few minutes or
 * is doing it now. Returns the upload's id, or null when there is nothing to do.
 */
export const beginCatalog = mutation({
  args: { hostId: v.id("hosts") },
  handler: async (ctx, { hostId }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const now = Date.now();
    const last = await ctx.db
      .query("catalogSyncs")
      .withIndex("by_device", (q) => q.eq("deviceId", viewer.device._id))
      .unique();
    if (last) {
      if (last.finishedAt !== undefined && now - last.finishedAt < CATALOG_INTERVAL_MS) return null;
      if (last.finishedAt === undefined && now - last.startedAt < CATALOG_STALE_MS) return null;
    }
    const syncId = `${hostId}-${now}`;
    if (last) {
      await ctx.db.patch(last._id, { hostId, syncId, startedAt: now, finishedAt: undefined });
    } else {
      await ctx.db.insert("catalogSyncs", { deviceId: viewer.device._id, hostId, syncId, startedAt: now });
    }
    return { syncId };
  },
});

const catalogEntry = v.object({
  sessionId: v.string(),
  title: v.string(),
  cwd: v.string(),
  projectPath: v.string(),
  createdAt: v.number(),
  lastActivityAt: v.number(),
  model: v.optional(v.string()),
  effort: v.optional(v.string()),
  gitBranch: v.optional(v.string()),
  /** What the last turn did, for the list's preview line until the transcript is here. */
  preview: v.optional(v.string()),
});

async function requireCatalog(ctx: MutationCtx, deviceId: Id<"devices">, hostId: Id<"hosts">, syncId: string) {
  const sync = await ctx.db
    .query("catalogSyncs")
    .withIndex("by_device", (q) => q.eq("deviceId", deviceId))
    .unique();
  if (!sync || sync.syncId !== syncId || sync.hostId !== hostId || sync.finishedAt !== undefined) {
    fail("EXPIRED", "This catalog upload was replaced by another.");
  }
  return sync;
}

/**
 * Up to 100 sessions from the computer's disk. New ones are added (offline, transcript not here yet); known ones are
 * updated only where something changed, and not at all while a running crok mirrors them (it knows better).
 */
export const catalogBatch = mutation({
  args: { hostId: v.id("hosts"), syncId: v.string(), sessions: v.array(catalogEntry) },
  handler: async (ctx, { hostId, syncId, sessions }) => {
    const { viewer, host } = await requireHost(ctx, hostId);
    if (sessions.length > MAX_CATALOG_PER_CALL) fail("INVALID", `At most ${MAX_CATALOG_PER_CALL} sessions per call.`);
    await requireCatalog(ctx, viewer.device._id, hostId, syncId);
    const projects = new Set<string>();
    let added = 0;
    for (const entry of sessions) {
      const title = entry.title.trim().slice(0, 200);
      const preview = entry.preview?.replace(/\s+/g, " ").trim().slice(0, 280) || undefined;
      if (!projects.has(entry.projectPath)) {
        await ensureProject(ctx, viewer.user._id, viewer.device._id, entry.projectPath);
        projects.add(entry.projectPath);
      }
      const existing = await ctx.db
        .query("sessions")
        .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", entry.sessionId))
        .unique();
      if (!existing) {
        await ctx.db.insert("sessions", {
          userId: viewer.user._id,
          deviceId: viewer.device._id,
          hostId,
          sessionId: entry.sessionId,
          app: host.app,
          projectPath: entry.projectPath,
          title: title || "New session",
          cwd: entry.cwd,
          model: entry.model,
          effort: entry.effort,
          gitBranch: entry.gitBranch,
          status: "idle",
          online: false,
          preview,
          previewKind: preview ? "assistant" : undefined,
          createdAt: entry.createdAt,
          lastActivityAt: entry.lastActivityAt,
          eventSeq: 0,
          assistantCount: 0,
          readAssistantCount: 0,
          historyState: "none",
        });
        added += 1;
        continue;
      }
      if (existing.deviceId !== viewer.device._id) continue;
      const patch: Partial<Doc<"sessions">> = {};
      if (existing.projectPath !== entry.projectPath) patch.projectPath = entry.projectPath;
      if (!existing.online) {
        if (title && title !== existing.title) patch.title = title;
        if (entry.cwd && entry.cwd !== existing.cwd) patch.cwd = entry.cwd;
        if (entry.model && entry.model !== existing.model) patch.model = entry.model;
        if (entry.gitBranch && entry.gitBranch !== existing.gitBranch) patch.gitBranch = entry.gitBranch;
        // A minute of slack: the computer's clock and the relay's differ, and summaries are written after the last event.
        if (entry.lastActivityAt > existing.lastActivityAt + 60_000) patch.lastActivityAt = entry.lastActivityAt;
        // The transcript's own preview wins once it is here.
        if (preview && existing.eventSeq === 0 && preview !== existing.preview) {
          patch.preview = preview;
          patch.previewKind = "assistant";
        }
        // It ran somewhere the relay did not see since: read it again when opened.
        if (patch.lastActivityAt !== undefined && existing.historyState === "ready") patch.historyState = "none";
        if (patch.lastActivityAt !== undefined && existing.historyState === undefined && existing.eventSeq > 0) {
          patch.historyState = "none";
        }
      }
      if (Object.keys(patch).length > 0) await ctx.db.patch(existing._id, patch);
    }
    return { added };
  },
});

/**
 * Ends a catalog upload. `sessionIds` is every session the computer listed: offline copies of this computer's sessions
 * missing from it were deleted there, so the relay drops them too, with projects left empty.
 */
export const finishCatalog = mutation({
  args: { hostId: v.id("hosts"), syncId: v.string(), sessionIds: v.array(v.string()) },
  handler: async (ctx, { hostId, syncId, sessionIds }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const sync = await requireCatalog(ctx, viewer.device._id, hostId, syncId);
    const listed = new Set(sessionIds);
    const sessions = await ctx.db
      .query("sessions")
      .withIndex("by_device", (q) => q.eq("deviceId", viewer.device._id))
      .collect();
    const used = new Set<string>();
    let removed = 0;
    for (const session of sessions) {
      // A new session made from another device is not on this computer's disk until it opens.
      if (session.online || listed.has(session.sessionId) || isStarting(session)) {
        used.add(session.projectPath || session.cwd);
        continue;
      }
      await ctx.db.delete(session._id);
      await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, {
        sessionDocId: session._id,
        throughSeq: Number.MAX_SAFE_INTEGER,
      });
      removed += 1;
    }
    const projects = await ctx.db
      .query("projects")
      .withIndex("by_device_path", (q) => q.eq("deviceId", viewer.device._id))
      .collect();
    for (const project of projects) {
      if (!used.has(project.path)) await ctx.db.delete(project._id);
    }
    await ctx.db.patch(sync._id, { finishedAt: Date.now() });
    return { removed };
  },
});
