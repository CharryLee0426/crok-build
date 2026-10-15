import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { fail, requireHost, requireViewer } from "./lib/auth";
import { eventKind, hostApp, planEntry, sessionStatus, sessionUsage } from "./schema";

/**
 * The computer side. Every running crok process that is signed in (a TUI, or one Crok Desktop task) is a "host": it
 * `connect`s, heartbeats, mirrors the sessions it runs (`upsertSession`, `pushEvents`), and watches `inbox` for
 * commands from phones and the web, which it `claimCommand`s and `completeCommand`s.
 */

const MAX_EVENT_TEXT = 32_000;
const MAX_EVENTS_PER_CALL = 100;
const DEVICE_SEEN_GRANULARITY_MS = 5 * 60 * 1000;
const INLINE_DELETE_LIMIT = 2_000;

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

/** Registers this process. `instanceId` is random per process, so a restart is a new host. */
export const connect = mutation({
  args: {
    instanceId: v.string(),
    app: hostApp,
    appVersion: v.string(),
    pid: v.optional(v.number()),
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
      await ctx.db.patch(hostId, { lastSeenAt: now, online: true, appVersion: args.appVersion, pid: args.pid });
      await setHostSessionsOnline(ctx, hostId, true);
    } else {
      hostId = await ctx.db.insert("hosts", {
        userId: viewer.user._id,
        deviceId: device._id,
        instanceId: args.instanceId,
        app: args.app,
        appVersion: args.appVersion.slice(0, 80),
        pid: args.pid,
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
    if (online && session.online) continue;
    if (!online && !session.online) continue;
    // A session another host took over stays with that host.
    if (session.hostId !== hostId) continue;
    await ctx.db.patch(session._id, online ? { online: true } : { online: false, status: "idle" });
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
      const sessionDocId = await ctx.db.insert("sessions", {
        userId: viewer.user._id,
        deviceId: viewer.device._id,
        hostId,
        sessionId,
        app: host.app,
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
    if (!existing.online) patch.online = true;
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
    if (session && session.hostId === hostId && session.online) {
      await ctx.db.patch(session._id, { online: false, status: "idle" });
    }
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
 * Writes transcript items. An item with a `key` already present is updated in place (streamed text, a tool call's
 * status); a new one gets the next `seq`. `replace` first drops the session's old items (a resync after the session
 * ran while this computer was not mirroring it).
 */
export const pushEvents = mutation({
  args: {
    hostId: v.id("hosts"),
    sessionDocId: v.id("sessions"),
    replace: v.optional(v.boolean()),
    events: v.array(eventInput),
  },
  handler: async (ctx, { hostId, sessionDocId, replace, events }) => {
    await requireHost(ctx, hostId);
    if (events.length > MAX_EVENTS_PER_CALL) fail("INVALID", `At most ${MAX_EVENTS_PER_CALL} events per call.`);
    const session = await ctx.db.get(sessionDocId);
    if (!session || session.hostId !== hostId) fail("NOT_FOUND", "This host does not run that session.");
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
    if (
      seq !== session.eventSeq ||
      assistantCount !== session.assistantCount ||
      readAssistantCount !== session.readAssistantCount
    ) {
      await ctx.db.patch(sessionDocId, {
        eventSeq: seq,
        assistantCount,
        readAssistantCount,
        ...(inserted > 0 ? { lastActivityAt: Date.now() } : {}),
      });
    }
    return { eventSeq: seq };
  },
});

/**
 * What this host has to act on: commands for the sessions it runs, and which of them someone is looking at right now
 * (`until` is in server time; `serverTime` lets the host correct for its own clock).
 */
export const inbox = query({
  args: { hostId: v.id("hosts") },
  handler: async (ctx, { hostId }) => {
    const { viewer } = await requireHost(ctx, hostId);
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
      if (!session || session.hostId !== hostId) continue;
      const sender = command.fromDeviceId ? await ctx.db.get(command.fromDeviceId) : null;
      commands.push({
        _id: command._id,
        sessionDocId: command.sessionDocId,
        sessionId: session.sessionId,
        type: command.type,
        text: command.text ?? null,
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
    return { commands, views, serverTime: now };
  },
});

/** Takes a pending command for one of this host's sessions. False if another host or a retry got it first. */
export const claimCommand = mutation({
  args: { hostId: v.id("hosts"), commandId: v.id("commands") },
  handler: async (ctx, { hostId, commandId }) => {
    const { viewer } = await requireHost(ctx, hostId);
    const command = await ctx.db.get(commandId);
    if (!command || command.deviceId !== viewer.device._id || command.status !== "pending") return false;
    const session = await ctx.db.get(command.sessionDocId);
    if (!session || session.hostId !== hostId) return false;
    await ctx.db.patch(commandId, { status: "delivered", updatedAt: Date.now() });
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
    return null;
  },
});
