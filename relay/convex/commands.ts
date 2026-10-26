import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import type { Viewer } from "./lib/auth";
import { fail, ownCommand, requireSession, requireViewer, viewerLabel } from "./lib/auth";
import { isStarting, modelsFor, opensWithSetup, supports } from "./lib/starting";
import { configId } from "./schema";

/**
 * What a phone or the web asks a computer to do. The computer's bridge sees new commands at once (its `inbox`
 * subscription), claims them, and completes them; the sender watches the command row for the outcome.
 *
 * Ids are plain strings here (from URLs and phones); a malformed one is `NOT_FOUND`.
 */

const MAX_PROMPT = 32_000;

/**
 * Whether a command for the session has somewhere to go: the crok process running it, or, for a session nobody runs,
 * any crok on its computer that can open it (the first to claim the command opens the session there).
 */
export async function reachable(
  ctx: QueryCtx,
  session: Doc<"sessions">,
  type: Doc<"commands">["type"] = "prompt",
  setup: { model?: string; effort?: string } = {},
): Promise<boolean> {
  if (session.online && type !== "git") return true;
  const hosts = await ctx.db
    .query("hosts")
    .withIndex("by_device_online", (q) => q.eq("deviceId", session.deviceId).eq("online", true))
    .take(50);
  // A git read runs in the session's folder: any crok on that computer that knows how can serve it, whether or not
  // it opens sessions or runs the session.
  if (type === "git") return hosts.some((host) => supports(host, "git"));
  // A `create` that carries a model or thinking level needs a crok that applies it.
  return hosts.some(
    (host) => host.canAdopt === true && supports(host, type) && (type !== "create" || opensWithSetup(host, setup)),
  );
}

async function requireReachable(
  ctx: MutationCtx,
  session: Doc<"sessions">,
  type: Doc<"commands">["type"] = "prompt",
  setup: { model?: string; effort?: string } = {},
) {
  // A git read may be served by any of the computer's processes, so only its own reachability decides.
  if (type !== "git" && session.online && !supports((await ctx.db.get(session.hostId)) ?? {}, type)) {
    fail("INVALID", "Update crok on that computer to do this from another device.");
  }
  if (await reachable(ctx, session, type, setup)) return;
  const device = await ctx.db.get(session.deviceId);
  const name = device?.name ?? "that computer";
  if (type === "create" && (await reachable(ctx, session, type))) {
    fail("OFFLINE", `Update crok on ${name} to start a session there with a chosen model or thinking level.`);
  }
  const anyCrok = await reachable(ctx, session);
  fail(
    "OFFLINE",
    anyCrok
      ? `Update crok on ${name} to do this from another device.`
      : `${device?.name ?? "Its computer"} is offline: start crok or Crok Desktop there.`,
  );
}

async function insertCommand(
  ctx: MutationCtx,
  viewer: Viewer,
  session: Doc<"sessions">,
  type: Doc<"commands">["type"],
  extra: {
    text?: string;
    clientId?: string;
    interactionId?: string;
    configId?: Doc<"commands">["configId"];
    model?: string;
    effort?: string;
  },
): Promise<Id<"commands">> {
  await requireReachable(ctx, session, type, extra);
  const now = Date.now();
  return await ctx.db.insert("commands", {
    userId: viewer.user._id,
    deviceId: session.deviceId,
    sessionDocId: session._id,
    type,
    text: extra.text,
    clientId: extra.clientId,
    interactionId: extra.interactionId,
    configId: extra.configId,
    model: extra.model,
    effort: extra.effort,
    status: "pending",
    fromDeviceId: viewer.device?._id,
    fromLabel: viewerLabel(viewer),
    createdAt: now,
    updatedAt: now,
  });
}

/** A command the relay settles itself, for a session no crok runs (there is nothing to stop, its info is stored). */
async function insertSettled(
  ctx: MutationCtx,
  viewer: Viewer,
  session: Doc<"sessions">,
  type: Doc<"commands">["type"],
  result?: unknown,
): Promise<Id<"commands">> {
  const now = Date.now();
  return await ctx.db.insert("commands", {
    userId: viewer.user._id,
    deviceId: session.deviceId,
    sessionDocId: session._id,
    type,
    status: "done",
    result,
    fromDeviceId: viewer.device?._id,
    fromLabel: viewerLabel(viewer),
    createdAt: now,
    updatedAt: now,
  });
}

/** What the info sheet shows for a session no crok runs: what its computer last said about it. */
function storedInfo(session: Doc<"sessions">) {
  return {
    sessionId: session.sessionId,
    title: session.title,
    model: session.model,
    modelId: session.model,
    effort: session.effort,
    cwd: session.cwd,
    gitBranch: session.gitBranch,
    createdAt: session.createdAt,
    usage: {
      inputTokens: session.usage?.inputTokens,
      outputTokens: session.usage?.outputTokens,
      cachedTokens: session.usage?.cachedTokens,
      reasoningTokens: session.usage?.reasoningTokens,
      costUsd: session.usage?.costUsd,
    },
    context: { used: session.usage?.contextTokens, window: session.usage?.contextWindow },
    stored: true,
  };
}

/**
 * Sends a prompt into a session, as if typed on its computer. A session nobody runs is opened by a crok on that
 * computer first. `clientId` (a UUID the sender makes) makes a resend after a dropped connection a no-op and lets the
 * sender match its optimistic bubble.
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
    // A new session whose computer never opened it (it failed, or nobody claimed it): this prompt opens it, with the
    // model and thinking level chosen for it when it was created.
    const type = isStarting(session) && !session.online ? "create" : "prompt";
    const commandId = await insertCommand(ctx, viewer, session, type, {
      text: trimmed,
      clientId,
      model: type === "create" ? session.model : undefined,
      effort: type === "create" ? session.effort : undefined,
    });
    return { commandId };
  },
});

/**
 * Stops the running turn, like Esc in the terminal or Stop in Crok Desktop. For a session nobody runs yet, prompts no
 * computer has picked up are dropped instead.
 */
export const stop = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    if (!session.online) {
      const waiting = await ctx.db
        .query("commands")
        .withIndex("by_session", (q) => q.eq("sessionDocId", session._id))
        .order("desc")
        .take(50);
      const now = Date.now();
      for (const command of waiting) {
        if ((command.type === "prompt" || command.type === "create") && command.status === "pending") {
          await ctx.db.patch(command._id, { status: "failed", error: "Stopped before it ran.", updatedAt: now });
        }
      }
      return { commandId: await insertSettled(ctx, viewer, session, "cancel") };
    }
    const commandId = await insertCommand(ctx, viewer, session, "cancel", {});
    return { commandId };
  },
});

/**
 * Asks the computer for fresh session info (model, tokens, cost, context); the answer lands in the command's `result`.
 * A session nobody runs gets what its computer last reported, at once (`result.stored` is true).
 */
export const requestInfo = mutation({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    if (!session.online) return { commandId: await insertSettled(ctx, viewer, session, "info", storedInfo(session)) };
    const commandId = await insertCommand(ctx, viewer, session, "info", {});
    return { commandId };
  },
});

/**
 * Reads the session's git repository (history, branches, a commit's files or diff), or switches and creates a
 * branch. `request` is JSON: `{op, …}`. Any crok of the session's computer that knows `git` runs it in the
 * session's folder; the answer is in the command's `result`.
 */
export const git = mutation({
  args: { sessionDocId: v.string(), request: v.string() },
  handler: async (ctx, { sessionDocId, request }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const commandId = await insertCommand(ctx, viewer, session, "git", { text: request });
    return { commandId };
  },
});

/**
 * Sets the session's model or thinking level, as if picked on its computer. A session nobody runs is opened there
 * first. The command's `result` is `{model, effort}` once applied.
 */
export const setConfig = mutation({
  args: { sessionDocId: v.string(), configId, value: v.string() },
  handler: async (ctx, { sessionDocId, configId, value }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const wanted = value.trim();
    if (!wanted) fail("INVALID", "Choose a value.");
    if (isStarting(session) && !session.online) fail("INVALID", "This session has not started on its computer yet.");
    const models = await modelsFor(ctx, await ctx.db.get(session.deviceId));
    if (models && models.length > 0) {
      if (configId === "model" && !models.some((m) => m.id === wanted)) {
        fail("INVALID", "That model is not available on this computer.");
      }
      const current = models.find((m) => m.id === session.model);
      if (configId === "reasoning_effort" && current && !current.efforts.some((e) => e.id === wanted || e.value === wanted)) {
        fail("INVALID", "That thinking level is not available for this model.");
      }
    }
    const commandId = await insertCommand(ctx, viewer, session, "config", { text: wanted, configId });
    return { commandId };
  },
});

/**
 * Answers the session's pending permission request with one of its options, as if clicked on the computer. The first
 * answer from any device wins; one for a request that is no longer pending is `EXPIRED`.
 */
export const answer = mutation({
  args: { sessionDocId: v.string(), interactionId: v.string(), optionId: v.string() },
  handler: async (ctx, { sessionDocId, interactionId, optionId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const pending = session.pending;
    if (!session.online || !pending || pending.id !== interactionId) {
      fail("EXPIRED", "That request was already answered.");
    }
    if (!pending.options.some((option) => option.optionId === optionId)) fail("INVALID", "No such choice.");
    const commandId = await insertCommand(ctx, viewer, session, "answer", { text: optionId, interactionId });
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
      .filter((c) => c.type === "prompt" || (c.type === "create" && c.text))
      .map((c) => ({
        _id: c._id,
        type: c.type,
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
    // A prompt for a new session that never opened opens it; a `create` for one that opened since is a plain prompt.
    const starting = isStarting(session) && !session.online;
    const type =
      command.type === "prompt" && starting ? "create" : command.type === "create" && !starting ? "prompt" : command.type;
    // A `create` keeps its own choice; a prompt that now opens the session takes the one chosen for it.
    const setup =
      type !== "create"
        ? {}
        : command.type === "create"
          ? { model: command.model, effort: command.effort }
          : { model: session.model, effort: session.effort };
    await requireReachable(ctx, session, type, setup);
    await ctx.db.patch(command._id, {
      type,
      status: "pending",
      error: undefined,
      updatedAt: Date.now(),
      // A prompt that now opens the session carries the model and thinking level chosen for it.
      ...(type === "create" && command.type !== "create"
        ? { model: session.model, effort: session.effort }
        : {}),
    });
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
