import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalMutation } from "./_generated/server";
import { markHostOffline, settleHistory } from "./bridge";

/** A host that has not heartbeated (every 30 s) for this long is offline: the process quit, crashed or lost network. */
const HOST_STALE_MS = 90 * 1000;
/** A command no computer picked up in this long fails, so the sender is not left with a clock forever. */
const COMMAND_PICKUP_MS = 5 * 60 * 1000;
const LOGIN_KEEP_MS = 60 * 60 * 1000;
/** The relay keeps a session's copy this long after it last changed; the session itself stays on the computer. */
const SESSION_KEEP_MS = 30 * 24 * 60 * 60 * 1000;
const BATCH = 200;

/** Every minute: offline hosts, unanswered commands, old sign-in attempts, finished views. */
export const sweep = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const stale = await ctx.db
      .query("hosts")
      .withIndex("by_online_seen", (q) => q.eq("online", true).lt("lastSeenAt", now - HOST_STALE_MS))
      .take(BATCH);
    for (const host of stale) await markHostOffline(ctx, host);

    const unanswered = await ctx.db
      .query("commands")
      .withIndex("by_status_created", (q) => q.eq("status", "pending").lt("createdAt", now - COMMAND_PICKUP_MS))
      .take(BATCH);
    for (const command of unanswered) {
      await ctx.db.patch(command._id, {
        status: "failed",
        error: "The computer did not pick this up. Is crok still running there?",
        updatedAt: now,
      });
      if (command.type === "history") await settleHistory(ctx, command.sessionDocId, false);
    }

    const logins = await ctx.db
      .query("deviceLogins")
      .withIndex("by_expires", (q) => q.lt("expiresAt", now - LOGIN_KEEP_MS))
      .take(BATCH);
    for (const login of logins) await ctx.db.delete(login._id);

    const views = await ctx.db
      .query("sessionViews")
      .withIndex("by_until", (q) => q.lt("until", now))
      .take(BATCH);
    for (const view of views) await ctx.db.delete(view._id);
    return { offline: stale.length, failed: unanswered.length };
  },
});

/**
 * Daily: drop the transcripts of sessions nobody has touched for 30 days. The sessions stay listed (the computer lists
 * them anyway); opening one reads its transcript from the computer again.
 */
export const pruneOldSessions = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - SESSION_KEEP_MS;
    const users = await ctx.db.query("users").collect();
    for (const user of users) {
      let pruned = 0;
      for await (const session of ctx.db
        .query("sessions")
        .withIndex("by_user_activity", (q) => q.eq("userId", user._id).lt("lastActivityAt", cutoff))) {
        if (pruned >= 50) break;
        if (session.online || session.pinned || session.eventSeq === 0 || session.historyState === "none") continue;
        await ctx.db.patch(session._id, {
          historyState: "none",
          assistantCount: 0,
          readAssistantCount: 0,
        });
        await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, {
          sessionDocId: session._id,
          throughSeq: session.eventSeq,
        });
        pruned += 1;
      }
    }
    return null;
  },
});

/** Deletes a session's events up to `throughSeq`, a batch at a time. */
export const deleteSessionEvents = internalMutation({
  args: { sessionDocId: v.id("sessions"), throughSeq: v.number() },
  handler: async (ctx, { sessionDocId, throughSeq }) => {
    const batch = await ctx.db
      .query("events")
      .withIndex("by_session_seq", (q) => q.eq("sessionDocId", sessionDocId).lte("seq", throughSeq))
      .take(1000);
    for (const event of batch) await ctx.db.delete(event._id);
    if (batch.length === 1000) {
      await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, { sessionDocId, throughSeq });
    } else if (!(await ctx.db.get(sessionDocId))) {
      const commands = await ctx.db
        .query("commands")
        .withIndex("by_session", (q) => q.eq("sessionDocId", sessionDocId))
        .take(1000);
      for (const command of commands) await ctx.db.delete(command._id);
    }
    return null;
  },
});
