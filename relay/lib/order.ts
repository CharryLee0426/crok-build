/**
 * The main list's order rules, as pure functions over `sessions:groups` values (DESIGN.md §2 "Projects and order").
 * The optimistic updates and the dev preview use them, so a move shows at once and matches what the relay will send.
 */
import type { ProjectGroup, SessionRow } from "./types";

/**
 * Puts `wanted` (some of `current`, in their new order) into the places those items hold in `current`, so moving one
 * computer's projects leaves the others where they are. The relay's own rule (convex/lib/projects.ts).
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

/** `list` with the item at `from` moved to index `to` (an index into the list without it). */
export function moveItem<T>(list: T[], from: number, to: number): T[] {
  if (from < 0 || from >= list.length) return list;
  const rest = list.filter((_, i) => i !== from);
  const at = Math.max(0, Math.min(rest.length, to));
  rest.splice(at, 0, list[from]);
  return rest;
}

/** Pinned sessions lead their project; the rest keep their order (a stable sort). */
export function pinnedFirst<T extends Pick<SessionRow, "pinned">>(rows: T[]): T[] {
  return [...rows.filter((r) => r.pinned), ...rows.filter((r) => !r.pinned)];
}

/** Newest first, pinned first: a project's order before anyone placed its sessions. */
export function byActivity<T extends Pick<SessionRow, "pinned" | "lastActivityAt">>(rows: T[]): T[] {
  return [...rows].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    return b.lastActivityAt - a.lastActivityAt;
  });
}

/** `sessions:reorderProjects({keys})`: the projects take their new places, and every project counts as placed. */
export function applyProjectOrder(groups: ProjectGroup[], keys: string[]): ProjectGroup[] {
  const byKey = new Map(groups.map((g) => [g.key, g]));
  const order = reorderWithin(
    groups.map((g) => g.key),
    keys,
  );
  return order.map((key) => ({ ...byKey.get(key)!, placed: true }));
}

/** `sessions:reorderSessions({projectKey, sessionDocIds})`; pinned sessions still lead. */
export function applySessionOrder(groups: ProjectGroup[], projectKey: string, ids: string[]): ProjectGroup[] {
  return groups.map((group) => {
    if (group.key !== projectKey) return group;
    const byId = new Map(group.sessions.map((s) => [s._id as string, s]));
    const order = reorderWithin(
      group.sessions.map((s) => s._id as string),
      ids,
    );
    return { ...group, sessions: pinnedFirst(order.map((id) => byId.get(id)!)) };
  });
}

/** `sessions:resetOrder({projectKey})` with a key (that project's sessions), or without (the projects). */
export function applyResetOrder(groups: ProjectGroup[], projectKey?: string): ProjectGroup[] {
  if (projectKey !== undefined) {
    return groups.map((group) => (group.key === projectKey ? { ...group, sessions: byActivity(group.sessions) } : group));
  }
  return [...groups].sort((a, b) => b.lastActivityAt - a.lastActivityAt).map((g) => ({ ...g, placed: false }));
}

/** One session changed (pin, …): its project re-sorts so pinned sessions lead. */
export function patchSession(
  groups: ProjectGroup[],
  id: string,
  patch: Partial<Pick<SessionRow, "pinned" | "archived">>,
): ProjectGroup[] {
  return groups.map((group) => {
    if (!group.sessions.some((s) => s._id === id)) return group;
    const sessions = group.sessions.map((s) => (s._id === id ? { ...s, ...patch } : s));
    return { ...group, sessions: patch.pinned !== undefined ? pinnedFirst(sessions) : sessions };
  });
}

/** Archived (or removed): the session leaves the list, and its project too when it was the last one. */
export function removeSession(groups: ProjectGroup[], id: string): ProjectGroup[] {
  if (!groups.some((g) => g.sessions.some((s) => s._id === id))) return groups;
  return groups
    .map((group) => ({ ...group, sessions: group.sessions.filter((s) => s._id !== id) }))
    .filter((group) => group.sessions.length > 0);
}

/**
 * Unarchived: the session joins its project at the top of its unpinned sessions (the relay places it for real a moment
 * later); a project the list doesn't show yet appears first, as new projects do.
 */
export function addSession(groups: ProjectGroup[], row: SessionRow): ProjectGroup[] {
  if (groups.some((g) => g.sessions.some((s) => s._id === row._id))) return groups;
  const session = { ...row, archived: false };
  const existing = groups.find((g) => g.key === row.projectKey);
  if (!existing) {
    const group: ProjectGroup = {
      key: row.projectKey,
      deviceId: row.deviceId,
      deviceName: row.deviceName,
      deviceOnline: row.deviceOnline,
      path: row.projectPath,
      name: row.projectName,
      placed: false,
      lastActivityAt: row.lastActivityAt,
      sessions: [session],
    };
    return [group, ...groups];
  }
  return groups.map((group) =>
    group.key === row.projectKey
      ? {
          ...group,
          lastActivityAt: Math.max(group.lastActivityAt, row.lastActivityAt),
          sessions: pinnedFirst([session, ...group.sessions]),
        }
      : group,
  );
}
