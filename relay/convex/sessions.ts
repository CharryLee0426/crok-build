import { paginationOptsValidator } from "convex/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { mutation, query } from "./_generated/server";
import { fail, requireSession, requireViewer } from "./lib/auth";

/** How long a viewer counts as "watching" after its last `watch` call; clients call it every 60 s. */
const VIEW_TTL_MS = 2 * 60 * 1000;

function planProgress(plan: Doc<"sessions">["plan"]) {
  if (!plan || plan.length === 0) return null;
  return { done: plan.filter((p) => p.status === "completed").length, total: plan.length };
}

/**
 * The chat list: every mirrored session, pinned first, then by last activity. Archived ones only when asked for.
 * Each row carries its computer's name and state so the list needs no second query.
 */
export const list = query({
  args: { archived: v.optional(v.boolean()) },
  handler: async (ctx, { archived }) => {
    const viewer = await requireViewer(ctx);
    const sessions = await ctx.db
      .query("sessions")
      .withIndex("by_user_activity", (q) => q.eq("userId", viewer.user._id))
      .order("desc")
      .take(300);
    const devices = new Map<Id<"devices">, Doc<"devices"> | null>();
    const rows = [];
    for (const session of sessions) {
      if (Boolean(session.archived) !== Boolean(archived)) continue;
      if (!devices.has(session.deviceId)) devices.set(session.deviceId, await ctx.db.get(session.deviceId));
      const device = devices.get(session.deviceId);
      if (!device || device.revokedAt !== undefined) continue;
      rows.push({
        _id: session._id,
        sessionId: session.sessionId,
        title: session.title,
        cwd: session.cwd,
        model: session.model ?? null,
        status: session.status,
        online: session.online,
        app: session.app,
        deviceId: session.deviceId,
        deviceName: device.name,
        deviceOnline: device.online,
        preview: session.preview ?? null,
        previewKind: session.previewKind ?? null,
        lastActivityAt: session.lastActivityAt,
        pinned: Boolean(session.pinned),
        archived: Boolean(session.archived),
        unread: Math.max(0, session.assistantCount - session.readAssistantCount),
        plan: planProgress(session.plan),
      });
    }
    rows.sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
      return b.lastActivityAt - a.lastActivityAt;
    });
    return rows;
  },
});

/** One session with everything the header and the info sheet show. */
export const get = query({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const device = await ctx.db.get(session.deviceId);
    return {
      _id: session._id,
      sessionId: session.sessionId,
      title: session.title,
      cwd: session.cwd,
      model: session.model ?? null,
      effort: session.effort ?? null,
      gitBranch: session.gitBranch ?? null,
      status: session.status,
      online: session.online,
      app: session.app,
      deviceId: session.deviceId,
      deviceName: device?.name ?? "",
      devicePlatform: device?.platform ?? "",
      deviceOnline: device?.online ?? false,
      createdAt: session.createdAt,
      lastActivityAt: session.lastActivityAt,
      plan: session.plan ?? [],
      usage: session.usage ?? null,
      pinned: Boolean(session.pinned),
      archived: Boolean(session.archived),
      unread: Math.max(0, session.assistantCount - session.readAssistantCount),
      eventSeq: session.eventSeq,
    };
  },
});

/** The transcript, newest first, in pages (the client shows it bottom-anchored and loads older pages on scroll). */
export const events = query({
  args: { sessionDocId: v.string(), paginationOpts: paginationOptsValidator },
  handler: async (ctx, { sessionDocId, paginationOpts }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    return await ctx.db
      .query("events")
      .withIndex("by_session_seq", (q) => q.eq("sessionDocId", session._id))
      .order("desc")
      .paginate(paginationOpts);
  },
});

export const markRead = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    if (session.readAssistantCount !== session.assistantCount) {
      await ctx.db.patch(session._id, { readAssistantCount: session.assistantCount });
    }
    return null;
  },
});

/**
 * "I have this session open": the computer streams its reply at a fine grain while someone watches, and only at
 * message boundaries otherwise. Call on open and every 60 s while open.
 */
export const watch = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const viewerKey = viewer.device ? `device:${viewer.device._id}` : `web:${viewer.user._id}`;
    const until = Date.now() + VIEW_TTL_MS;
    const existing = await ctx.db
      .query("sessionViews")
      .withIndex("by_session_viewer", (q) => q.eq("sessionDocId", session._id).eq("viewer", viewerKey))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { until, deviceId: session.deviceId });
    } else {
      await ctx.db.insert("sessionViews", {
        sessionDocId: session._id,
        deviceId: session.deviceId,
        viewer: viewerKey,
        until,
      });
    }
    return null;
  },
});

export const setPinned = mutation({
  args: { sessionDocId: v.string(), pinned: v.boolean() },
  handler: async (ctx, { sessionDocId, pinned }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    await ctx.db.patch(session._id, { pinned });
    return null;
  },
});

export const setArchived = mutation({
  args: { sessionDocId: v.string(), archived: v.boolean() },
  handler: async (ctx, { sessionDocId, archived }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    await ctx.db.patch(session._id, { archived, ...(archived ? { pinned: false } : {}) });
    return null;
  },
});

/** Deletes the relay's copy of a session that is no longer running. The session itself stays on the computer. */
export const remove = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    if (session.online) fail("INVALID", "Close the session on the computer first, or archive it.");
    await ctx.db.delete(session._id);
    await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, {
      sessionDocId: session._id,
      throughSeq: Number.MAX_SAFE_INTEGER,
    });
    return null;
  },
});
