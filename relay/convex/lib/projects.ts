import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Viewer } from "./auth";

/**
 * Projects: the folders sessions are grouped under, per computer, and the order people put projects and sessions in.
 *
 * A project is named by a key, `<deviceId>:<path>` (device ids never hold a colon), so a list built from sessions
 * alone can be reordered before any project row exists. Ordering rule for both levels: items never placed by hand come
 * first, most recently active first; placed ones follow by `position`. Within a project, pinned sessions lead.
 */

/** Sessions the list reads at most (every session on every computer of one person). */
export const MAX_LIST = 2_000;

export function projectKey(deviceId: Id<"devices"> | string, path: string): string {
  return `${deviceId}:${path}`;
}

export function parseProjectKey(key: string): { deviceId: string; path: string } | null {
  const colon = key.indexOf(":");
  if (colon <= 0 || colon === key.length - 1) return null;
  return { deviceId: key.slice(0, colon), path: key.slice(colon + 1) };
}

/** The folder's name as people know it: its last path component. */
export function projectName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const name = trimmed.split(/[\\/]/).pop();
  return name || path || "/";
}

/** The project a session belongs to: what the computer said, else (rows from before projects) its folder. */
export function sessionProjectPath(session: Pick<Doc<"sessions">, "projectPath" | "cwd">): string {
  return session.projectPath || session.cwd || "/";
}

export async function ensureProject(
  ctx: MutationCtx,
  userId: Id<"users">,
  deviceId: Id<"devices">,
  path: string,
): Promise<Doc<"projects">> {
  const existing = await ctx.db
    .query("projects")
    .withIndex("by_device_path", (q) => q.eq("deviceId", deviceId).eq("path", path))
    .unique();
  if (existing) return existing;
  const id = await ctx.db.insert("projects", { userId, deviceId, path, createdAt: Date.now() });
  return (await ctx.db.get(id))!;
}

function within(path: string, folder: string): boolean {
  if (path === folder) return true;
  const base = folder.endsWith("/") ? folder : `${folder}/`;
  return path.startsWith(base);
}

/**
 * For a new live session the computer did not place: the deepest known project of that computer holding its folder,
 * else the folder itself. The computer's next catalog upload sets the exact project.
 */
export async function inferProjectPath(ctx: QueryCtx, deviceId: Id<"devices">, cwd: string): Promise<string> {
  const projects = await ctx.db
    .query("projects")
    .withIndex("by_device_path", (q) => q.eq("deviceId", deviceId))
    .collect();
  let best: string | null = null;
  for (const project of projects) {
    if (within(cwd, project.path) && (best === null || project.path.length > best.length)) best = project.path;
  }
  return best ?? (cwd || "/");
}

/** Unplaced first (newest first), then placed by position. */
function byPlace<T>(position: (t: T) => number | undefined, activity: (t: T) => number) {
  return (a: T, b: T) => {
    const pa = position(a);
    const pb = position(b);
    if ((pa === undefined) !== (pb === undefined)) return pa === undefined ? -1 : 1;
    if (pa !== undefined && pb !== undefined && pa !== pb) return pa - pb;
    return activity(b) - activity(a);
  };
}

export function sortSessions(sessions: Doc<"sessions">[]): Doc<"sessions">[] {
  const placed = byPlace<Doc<"sessions">>((s) => s.position, (s) => s.lastActivityAt);
  return [...sessions].sort((a, b) => {
    if (Boolean(a.pinned) !== Boolean(b.pinned)) return a.pinned ? -1 : 1;
    return placed(a, b);
  });
}

export type Group = {
  key: string;
  deviceId: Id<"devices">;
  device: Doc<"devices">;
  path: string;
  project: Doc<"projects"> | null;
  lastActivityAt: number;
  sessions: Doc<"sessions">[];
};

/**
 * Every non-archived session of the person on a linked computer, grouped by project, in list order. Projects without
 * sessions are left out.
 */
export async function buildGroups(ctx: QueryCtx, viewer: Viewer): Promise<Group[]> {
  const sessions = await ctx.db
    .query("sessions")
    .withIndex("by_user_activity", (q) => q.eq("userId", viewer.user._id))
    .order("desc")
    .take(MAX_LIST);
  const projects = await ctx.db
    .query("projects")
    .withIndex("by_user", (q) => q.eq("userId", viewer.user._id))
    .collect();
  const projectByKey = new Map(projects.map((p) => [projectKey(p.deviceId, p.path), p]));
  const devices = new Map<Id<"devices">, Doc<"devices"> | null>();
  const groups = new Map<string, Group>();
  for (const session of sessions) {
    if (session.archived) continue;
    if (!devices.has(session.deviceId)) devices.set(session.deviceId, await ctx.db.get(session.deviceId));
    const device = devices.get(session.deviceId);
    if (!device || device.revokedAt !== undefined) continue;
    const path = sessionProjectPath(session);
    const key = projectKey(session.deviceId, path);
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        deviceId: session.deviceId,
        device,
        path,
        project: projectByKey.get(key) ?? null,
        lastActivityAt: session.lastActivityAt,
        sessions: [],
      };
      groups.set(key, group);
    }
    group.lastActivityAt = Math.max(group.lastActivityAt, session.lastActivityAt);
    group.sessions.push(session);
  }
  const ordered = [...groups.values()].sort(byPlace<Group>((g) => g.project?.position, (g) => g.lastActivityAt));
  for (const group of ordered) group.sessions = sortSessions(group.sessions);
  return ordered;
}

/**
 * Puts `wanted` (some of `current`, in their new order) into the places those items hold in `current`, so reordering
 * the projects of one computer leaves the others where they are.
 */
export function reorderWithin<T>(current: T[], wanted: T[]): T[] {
  const wantedSet = new Set(wanted);
  const slots: number[] = [];
  current.forEach((item, index) => {
    if (wantedSet.has(item)) slots.push(index);
  });
  const known = wanted.filter((item) => current.includes(item));
  if (known.length !== slots.length) return current;
  const next = [...current];
  slots.forEach((slot, i) => {
    next[slot] = known[i];
  });
  return next;
}
