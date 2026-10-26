import { paginationOptsValidator } from "convex/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import type { Viewer } from "./lib/auth";
import { fail, requireSession, requireViewer, viewerLabel } from "./lib/auth";
import {
  MAX_LIST,
  buildGroups,
  ensureProject,
  parseProjectKey,
  projectKey,
  projectName,
  reorderWithin,
  sessionProjectPath,
} from "./lib/projects";
import {
  STARTING_PREFIX,
  embeddedModels,
  isAbsolutePath,
  isStarting,
  modelsFor,
  opensWithSetup,
  sessionSetup,
  supports,
  titleFromPrompt,
} from "./lib/starting";

/** How long a viewer counts as "watching" after its last `watch` call; clients call it every 60 s. */
const VIEW_TTL_MS = 2 * 60 * 1000;
/** Placing items by hand takes at most this many in one call. */
const MAX_REORDER = 500;
const MAX_PROMPT = 32_000;

function planProgress(plan: Doc<"sessions">["plan"]) {
  if (!plan || plan.length === 0) return null;
  return { done: plan.filter((p) => p.status === "completed").length, total: plan.length };
}

/** One list row: the session with its computer's name and state, so the list needs no second query. */
function sessionRow(session: Doc<"sessions">, device: Doc<"devices">) {
  const projectPath = sessionProjectPath(session);
  return {
    _id: session._id,
    sessionId: session.sessionId,
    title: session.title,
    cwd: session.cwd,
    model: session.model ?? null,
    gitBranch: session.gitBranch ?? null,
    usage: session.usage ?? null,
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
    projectKey: projectKey(session.deviceId, projectPath),
    projectPath,
    projectName: projectName(projectPath),
    /** `none` / `requested`: the transcript is still on the computer only; `ready` or null: it is here. */
    historyState: session.historyState ?? null,
    /** Made by `sessions:create` and not open on its computer yet. */
    starting: isStarting(session),
  };
}

/**
 * A flat list: every session, pinned first, then by last activity. The app shows archived sessions this way; the main
 * list is `groups`.
 */
export const list = query({
  args: { archived: v.optional(v.boolean()) },
  handler: async (ctx, { archived }) => {
    const viewer = await requireViewer(ctx);
    const sessions = await ctx.db
      .query("sessions")
      .withIndex("by_user_activity", (q) => q.eq("userId", viewer.user._id))
      .order("desc")
      .take(MAX_LIST);
    const devices = new Map<Id<"devices">, Doc<"devices"> | null>();
    const rows = [];
    for (const session of sessions) {
      if (Boolean(session.archived) !== Boolean(archived)) continue;
      if (!devices.has(session.deviceId)) devices.set(session.deviceId, await ctx.db.get(session.deviceId));
      const device = devices.get(session.deviceId);
      if (!device || device.revokedAt !== undefined) continue;
      rows.push(sessionRow(session, device));
    }
    rows.sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
      return b.lastActivityAt - a.lastActivityAt;
    });
    return rows;
  },
});

/**
 * The main list: every session on every linked computer (running or only on disk), grouped by project, in the order
 * the person put them in. Within a project, pinned sessions lead; sessions and projects never placed by hand come
 * before placed ones, most recent first. Archived sessions are left out (`list({archived: true})`).
 */
export const groups = query({
  args: {},
  handler: async (ctx) => {
    const viewer = await requireViewer(ctx);
    const groups = await buildGroups(ctx, viewer);
    return groups.map((group) => ({
      key: group.key,
      deviceId: group.deviceId,
      deviceName: group.device.name,
      deviceOnline: group.device.online,
      /** For "last seen …" while it is offline (null while online, so heartbeats do not re-send the list). */
      deviceLastSeenAt: group.device.online ? null : group.device.lastSeenAt,
      path: group.path,
      name: projectName(group.path),
      placed: group.project?.position !== undefined,
      lastActivityAt: group.lastActivityAt,
      sessions: group.sessions.map((session) => sessionRow(session, group.device)),
    }));
  },
});

/** One session with everything the header and the info sheet show. */
export const get = query({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const device = await ctx.db.get(session.deviceId);
    const projectPath = sessionProjectPath(session);
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
      projectKey: projectKey(session.deviceId, projectPath),
      projectPath,
      projectName: projectName(projectPath),
      historyState: session.historyState ?? null,
      starting: isStarting(session),
      /** A permission request waiting for an answer (`commands:answer`), or null. */
      pending: session.pending ?? null,
      /**
       * What its computer can run (`commands:setConfig` picks from these) when the list is short (`embeddedModels`);
       * current clients read `devices:models`. Null while the computer is offline.
       */
      models: embeddedModels(await modelsFor(ctx, device)),
    };
  },
});

/**
 * Starts a session in `path` on one of the person's computers, from any device: the relay lists it at once
 * (`starting`), and the first crok there to claim the `create` command opens it and runs `text` as its first prompt.
 * `model` and `effort` (the thinking level, an option id or its value) choose from that computer's models; its crok
 * applies them before the first prompt, so only a crok that does (`appliesSetup`) is given such a session.
 * `clientId` (a UUID the caller makes) makes a resend a no-op.
 */
export const create = mutation({
  args: {
    deviceId: v.string(),
    path: v.string(),
    text: v.optional(v.string()),
    model: v.optional(v.string()),
    effort: v.optional(v.string()),
    clientId: v.string(),
  },
  handler: async (ctx, { deviceId, path, text, model, effort, clientId }) => {
    const viewer = await requireViewer(ctx);
    const duplicate = await ctx.db
      .query("commands")
      .withIndex("by_client_id", (q) => q.eq("userId", viewer.user._id).eq("clientId", clientId))
      .unique();
    if (duplicate) return { sessionDocId: duplicate.sessionDocId, commandId: duplicate._id };
    const id = ctx.db.normalizeId("devices", deviceId);
    const device = id ? await ctx.db.get(id) : null;
    if (!device || device.userId !== viewer.user._id || device.revokedAt !== undefined) {
      fail("NOT_FOUND", "No such computer.");
    }
    if (device.kind !== "computer") fail("FORBIDDEN", "Sessions run on computers, not phones.");
    const folder = path.trim();
    if (!isAbsolutePath(folder)) fail("INVALID", "Choose a folder on the computer (a full path).");
    const prompt = text?.trim() || undefined;
    if (prompt && prompt.length > MAX_PROMPT) fail("INVALID", `Prompts are limited to ${MAX_PROMPT} characters.`);
    const setup = sessionSetup(await modelsFor(ctx, device), model, effort);
    const hosts = await ctx.db
      .query("hosts")
      .withIndex("by_device_online", (q) => q.eq("deviceId", device._id).eq("online", true))
      .take(50);
    const starters = hosts.filter((h) => h.canAdopt === true && supports(h, "create"));
    // Only a crok that applies the chosen model and thinking level gets the session: an older one would start it on
    // its own default.
    const host = starters.find((h) => opensWithSetup(h, setup));
    if (!host) {
      fail(
        "OFFLINE",
        starters.length > 0
          ? `Update crok on ${device.name} to start a session there with a chosen model or thinking level, or keep Default.`
          : hosts.some((h) => h.canAdopt === true)
            ? `Update crok on ${device.name} to start sessions there from another device.`
            : `${device.name} is offline: start crok or Crok Desktop there.`,
      );
    }
    await ensureProject(ctx, viewer.user._id, device._id, folder);
    const now = Date.now();
    const sessionDocId = await ctx.db.insert("sessions", {
      userId: viewer.user._id,
      deviceId: device._id,
      hostId: host._id,
      sessionId: `${STARTING_PREFIX}${clientId}`,
      app: host.app,
      title: titleFromPrompt(prompt),
      cwd: folder,
      projectPath: folder,
      model: setup.model,
      effort: setup.effortValue,
      status: prompt ? "running" : "idle",
      online: false,
      createdAt: now,
      lastActivityAt: now,
      eventSeq: 0,
      assistantCount: 0,
      readAssistantCount: 0,
    });
    const commandId = await ctx.db.insert("commands", {
      userId: viewer.user._id,
      deviceId: device._id,
      sessionDocId,
      type: "create",
      text: prompt,
      model: setup.model,
      effort: setup.effort,
      clientId,
      status: "pending",
      fromDeviceId: viewer.device?._id,
      fromLabel: viewerLabel(viewer),
      createdAt: now,
      updatedAt: now,
    });
    return { sessionDocId, commandId };
  },
});

/**
 * The session's slash commands as crok advertises them (built-ins, skills, workflows), else its computer's latest
 * list, for the composer's command menu.
 */
export const commands = query({
  args: { sessionDocId: v.string() },
  handler: async (ctx, { sessionDocId }) => {
    const viewer = await requireViewer(ctx);
    const session = await requireSession(ctx, viewer, sessionDocId);
    const own = await ctx.db
      .query("commandLists")
      .withIndex("by_session", (q) => q.eq("sessionDocId", session._id))
      .first();
    if (own) return { commands: own.commands, source: "session" as const };
    const computer = await ctx.db
      .query("commandLists")
      .withIndex("by_device_session", (q) => q.eq("deviceId", session.deviceId).eq("sessionDocId", undefined))
      .first();
    if (computer) return { commands: computer.commands, source: "computer" as const };
    return { commands: [], source: "none" as const };
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

/** `sessions:transcript` answers at most this many items, and at most about this much text in all (characters). */
const TRANSCRIPT_MAX_ITEMS = 200;
const TRANSCRIPT_MAX_TEXT = 400_000;
const TRANSCRIPT_DEFAULT_ITEMS = 40;
/** A tool call without a title is named by the start of its detail, at most this long. */
const TOOL_TITLE_MAX = 200;

/**
 * A transcript item as the phones show it: thoughts and tool calls by their status only (their text, up to 32 000
 * characters each, stays on the relay for clients that read `sessions:events`).
 */
function slimEvent(event: Doc<"events">) {
  const statusOnly = event.kind === "thought" || event.kind === "tool";
  let title = event.title;
  if (event.kind === "tool" && !title) {
    title = event.text.trim().split("\n", 1)[0]?.slice(0, TOOL_TITLE_MAX) || undefined;
  }
  return {
    _id: event._id,
    seq: event.seq,
    key: event.key,
    kind: event.kind,
    text: statusOnly ? "" : event.text,
    title,
    toolKind: event.toolKind,
    status: event.status,
    origin: event.origin,
    commandId: event.commandId,
    fromLabel: event.fromLabel,
    at: event.at,
  };
}

/**
 * A window of the transcript, newest first, for clients that keep a long transcript in parts (relay/DESIGN.md §3,
 * "Loading long transcripts"): items with `afterSeq < seq <= throughSeq` (either bound optional), the newest `limit`
 * of them (default 40, at most 200) and at most about 400 000 characters of text. `more`: the range holds older items
 * than the ones returned. Thoughts and tool calls come without their text.
 *
 * Reading only the items (not the session, whose every change would re-run it) keeps a part that nothing changes
 * from re-running: only the live end of the window does, as items arrive.
 */
export const transcript = query({
  args: {
    sessionDocId: v.string(),
    afterSeq: v.optional(v.number()),
    throughSeq: v.optional(v.number()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { sessionDocId, afterSeq, throughSeq, limit }) => {
    const viewer = await requireViewer(ctx);
    const id = ctx.db.normalizeId("sessions", sessionDocId);
    if (!id) fail("NOT_FOUND", "No such session.");
    const count = Math.max(1, Math.min(TRANSCRIPT_MAX_ITEMS, Math.floor(limit ?? TRANSCRIPT_DEFAULT_ITEMS)));
    const rows = await ctx.db
      .query("events")
      .withIndex("by_session_seq", (q) => {
        const session = q.eq("sessionDocId", id);
        if (afterSeq !== undefined && throughSeq !== undefined) return session.gt("seq", afterSeq).lte("seq", throughSeq);
        if (afterSeq !== undefined) return session.gt("seq", afterSeq);
        if (throughSeq !== undefined) return session.lte("seq", throughSeq);
        return session;
      })
      .order("desc")
      .take(count + 1);
    // Items written before events carried their owner (and an empty answer) are checked on the session itself.
    if (rows.length === 0 || rows.some((row) => row.userId === undefined)) {
      await requireSession(ctx, viewer, sessionDocId);
    } else if (rows.some((row) => row.userId !== viewer.user._id)) {
      fail("NOT_FOUND", "No such session.");
    }
    const events = [];
    let text = 0;
    for (const row of rows.slice(0, count)) {
      const event = slimEvent(row);
      if (events.length > 0 && text + event.text.length > TRANSCRIPT_MAX_TEXT) break;
      text += event.text.length;
      events.push(event);
    }
    return { events, more: rows.length > events.length };
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
 * A session no crok runs, opened without its transcript: ask a crok running on its computer to read it from disk.
 * Nothing happens while the computer is offline; the next `watch` (every 60 s) tries again.
 */
async function requestHistory(ctx: MutationCtx, viewer: Viewer, session: Doc<"sessions">) {
  if (session.online || session.historyState === undefined || session.historyState === "ready") return;
  const device = await ctx.db.get(session.deviceId);
  if (!device || !device.online) return;
  const recent = await ctx.db
    .query("commands")
    .withIndex("by_session", (q) => q.eq("sessionDocId", session._id))
    .order("desc")
    .take(20);
  const asked = recent.some((c) => c.type === "history" && (c.status === "pending" || c.status === "delivered"));
  if (!asked) {
    const now = Date.now();
    await ctx.db.insert("commands", {
      userId: viewer.user._id,
      deviceId: session.deviceId,
      sessionDocId: session._id,
      type: "history",
      status: "pending",
      fromDeviceId: viewer.device?._id,
      fromLabel: viewerLabel(viewer),
      createdAt: now,
      updatedAt: now,
    });
  }
  if (session.historyState !== "requested") await ctx.db.patch(session._id, { historyState: "requested" });
}

/**
 * "I have this session open": the computer streams its reply at a fine grain while someone watches, and only at
 * message boundaries otherwise. For a session only on the computer's disk it also fetches the transcript. Call on open
 * and every 60 s while open.
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
    await requestHistory(ctx, viewer, session);
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

/**
 * Moves projects: `keys` are some of the list's project keys in their new order (all of them, or one computer's).
 * They take the places those projects held, so the other computers' projects stay put. Every project of the person
 * is placed from then on; a new one appears at the top until it is moved.
 */
export const reorderProjects = mutation({
  args: { keys: v.array(v.string()) },
  handler: async (ctx, { keys }) => {
    const viewer = await requireViewer(ctx);
    if (keys.length > MAX_REORDER) fail("INVALID", `At most ${MAX_REORDER} projects at once.`);
    const groups = await buildGroups(ctx, viewer);
    const order = reorderWithin(
      groups.map((g) => g.key),
      keys,
    );
    const byKey = new Map(groups.map((g) => [g.key, g]));
    for (const [index, key] of order.entries()) {
      const group = byKey.get(key)!;
      const project = group.project ?? (await ensureProject(ctx, viewer.user._id, group.deviceId, group.path));
      if (project.position !== index) await ctx.db.patch(project._id, { position: index });
    }
    return null;
  },
});

/**
 * Moves sessions within one project: `sessionDocIds` are some of its sessions in their new order. Pinned sessions
 * still lead the project.
 */
export const reorderSessions = mutation({
  args: { projectKey: v.string(), sessionDocIds: v.array(v.string()) },
  handler: async (ctx, { projectKey: key, sessionDocIds }) => {
    const viewer = await requireViewer(ctx);
    if (sessionDocIds.length > MAX_REORDER) fail("INVALID", `At most ${MAX_REORDER} sessions at once.`);
    if (!parseProjectKey(key)) fail("INVALID", "No such project.");
    const group = (await buildGroups(ctx, viewer)).find((g) => g.key === key);
    if (!group) fail("NOT_FOUND", "No such project.");
    const order = reorderWithin(
      group.sessions.map((s) => s._id as string),
      sessionDocIds,
    );
    const byId = new Map(group.sessions.map((s) => [s._id as string, s]));
    for (const [index, id] of order.entries()) {
      const session = byId.get(id)!;
      if (session.position !== index) await ctx.db.patch(session._id, { position: index });
    }
    return null;
  },
});

/**
 * Back to "most recent first": with `projectKey`, for that project's sessions; without, for the projects themselves.
 */
export const resetOrder = mutation({
  args: { projectKey: v.optional(v.string()) },
  handler: async (ctx, { projectKey: key }) => {
    const viewer = await requireViewer(ctx);
    if (key !== undefined) {
      const group = (await buildGroups(ctx, viewer)).find((g) => g.key === key);
      if (!group) fail("NOT_FOUND", "No such project.");
      for (const session of group.sessions) {
        if (session.position !== undefined) await ctx.db.patch(session._id, { position: undefined });
      }
      return null;
    }
    const projects = await ctx.db
      .query("projects")
      .withIndex("by_user", (q) => q.eq("userId", viewer.user._id))
      .collect();
    for (const project of projects) {
      if (project.position !== undefined) await ctx.db.patch(project._id, { position: undefined });
    }
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
    const lists = await ctx.db
      .query("commandLists")
      .withIndex("by_session", (q) => q.eq("sessionDocId", session._id))
      .collect();
    for (const list of lists) await ctx.db.delete(list._id);
    await ctx.scheduler.runAfter(0, internal.maintenance.deleteSessionEvents, {
      sessionDocId: session._id,
      throughSeq: Number.MAX_SAFE_INTEGER,
    });
    return null;
  },
});
