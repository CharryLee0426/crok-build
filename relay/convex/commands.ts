import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import type { Viewer } from "./lib/auth";
import { fail, ownCommand, requireSession, requireViewer, viewerLabel } from "./lib/auth";

/**
 * What a phone or the web asks a computer to do. The computer's bridge sees new commands at once (its `inbox`
 * subscription), claims them, and completes them; the sender watches the command row for the outcome.
 *
 * Ids are plain strings here (from URLs and phones); a malformed one is `NOT_FOUND`.
 */

const MAX_PROMPT = 32_000;

async function insertCommand(
  ctx: MutationCtx,
  viewer: Viewer,
  session: Doc<"sessions">,
  type: Doc<"commands">["type"],
  extra: { text?: string; clientId?: string },
): Promise<Id<"commands">> {
  if (!session.online) fail("OFFLINE", "This session is not running on its computer right now.");
  const now = Date.now();
  return await ctx.db.insert("commands", {
    userId: viewer.user._id,
    deviceId: session.deviceId,
    sessionDocId: session._id,
    type,
    text: extra.text,
    clientId: extra.clientId,
    status: "pending",
    fromDeviceId: viewer.device?._id,
    fromLabel: viewerLabel(viewer),
    createdAt: now,
    updatedAt: now,
  });
}

/**
 * Sends a prompt into a running session, as if typed on the computer. `clientId` (a UUID the sender makes) makes a
 * resend after a dropped connection a no-op and lets the sender match its optimistic bubble.
 */
export const sendPrompt = mutation({
  args: { sessionDocId: v.string(), text: v.string(), clientId: v.string() },
  handler: async (ctx, { sessionDocId, text, clientId }) => {
    const viewer = await requireViewer(ctx);
    const duplicate = await ctx.db
      .query("commands")
      .withIndex("by_client_id", (q) => q.eq("userId", viewer.user._id).eq("clientId", clientId))
      .unique();
    if (duplicate) return { commandId: duplicate._id };
    const session = await requireSession(ctx, viewer, sessionDocId);
    const trimmed = text.trim();
    if (!trimmed) fail("INVALID", "The prompt is empty.");
    if (trimmed.length > MAX_PROMPT) fail("INVALID", `Prompts are limited to ${MAX_PROMPT} characters.`);
    const commandId = await insertCommand(ctx, viewer, session, "prompt", { text: trimmed, clientId });
    return { commandId };
  },
});

/** Stops the running turn, like Esc in the terminal or Stop in Crok Desktop. */
export const stop = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const commandId = await insertCommand(ctx, viewer, session, "cancel", {});
    return { commandId };
  },
});

/** Asks the computer for fresh session info (model, tokens, cost, context); the answer lands in the command's `result`. */
export const requestInfo = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const commandId = await insertCommand(ctx, viewer, session, "info", {});
    return { commandId };
  },
});

export const get = query({
  args: { commandId: v.string() },
  handler: async (ctx, { commandId }) => {
    const viewer = await requireViewer(ctx);
    return await ownCommand(ctx, viewer, commandId);
  },
});

/**
 * Recent prompts sent to this session from phones and the web, for the sender's status ticks. `mine` is true for the
 * ones this caller sent (this device, or the web for a web caller).
 */
export const forSession = query({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const commands = await ctx.db
      .query("commands")
      .withIndex("by_session", (q) => q.eq("sessionDocId", session._id))
      .order("desc")
      .take(50);
    return commands
      .filter((c) => c.type === "prompt")
      .map((c) => ({
        _id: c._id,
        clientId: c.clientId ?? null,
        text: c.text ?? "",
        status: c.status,
        error: c.error ?? null,
        fromLabel: c.fromLabel,
        fromDeviceId: c.fromDeviceId ?? null,
        mine: c.fromDeviceId === viewer.device?._id,
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
      }));
  },
});

/** Sends a failed prompt again (Telegram's "Resend"). */
export const retry = mutation({
  args: { commandId: v.string() },
  handler: async (ctx, { commandId }) => {
    const viewer = await requireViewer(ctx);
    const command = await ownCommand(ctx, viewer, commandId);
    if (!command) fail("NOT_FOUND", "No such prompt.");
    if (command.status !== "failed") return null;
    const session = await requireSession(ctx, viewer, command.sessionDocId);
    if (!session.online) fail("OFFLINE", "This session is not running on its computer right now.");
    await ctx.db.patch(command._id, { status: "pending", error: undefined, updatedAt: Date.now() });
    return null;
  },
});

/** Deletes a failed prompt from the sender's view. */
export const discard = mutation({
  args: { commandId: v.string() },
  handler: async (ctx, { commandId }) => {
    const viewer = await requireViewer(ctx);
    const command = await ownCommand(ctx, viewer, commandId);
    if (command?.status === "failed") await ctx.db.delete(command._id);
    return null;
  },
});
