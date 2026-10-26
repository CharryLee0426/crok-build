/**
 * Computers as accounts, projects as groups with topics (mobile/DESIGN.md): the pure rules the web shares with the
 * phones. Which computers there are and which one is shown, what a project's row says, topic icon colours, search.
 */
import { folderName } from "./format";
import type { DeviceRow, ProjectGroup, SessionRow } from "./types";

/** A linked computer as the switcher and Profile list it. */
export type Computer = {
  id: string;
  name: string;
  online: boolean;
  /** From `devices:list`; null for a computer only the session list knows. */
  lastSeenAt: number | null;
  createdAt: number | null;
  /** Unread replies over its sessions in the main list. */
  unread: number;
  /** Its most recent session activity; 0 without sessions. */
  lastActivityAt: number;
};

/** A project's unread total (the rows' `unread`). */
export function groupUnread(group: Pick<ProjectGroup, "sessions">): number {
  return group.sessions.reduce((sum, row) => sum + Math.max(0, row.unread), 0);
}

/**
 * Every computer in link order (`devices:list` by `createdAt`), then the ones only the session list knows (signed out
 * since, or a device list still on its way), most recently active first.
 */
export function computerList(devices: readonly DeviceRow[] | undefined, groups: readonly ProjectGroup[] | undefined): Computer[] {
  const unread = new Map<string, number>();
  const activity = new Map<string, number>();
  const known = new Map<string, ProjectGroup>();
  for (const group of groups ?? []) {
    unread.set(group.deviceId, (unread.get(group.deviceId) ?? 0) + groupUnread(group));
    activity.set(group.deviceId, Math.max(activity.get(group.deviceId) ?? 0, group.lastActivityAt));
    if (!known.has(group.deviceId)) known.set(group.deviceId, group);
  }
  const linked = (devices ?? [])
    .filter((d) => d.kind === "computer")
    .sort((a, b) => (a.createdAt !== b.createdAt ? a.createdAt - b.createdAt : a._id < b._id ? -1 : 1));
  const seen = new Set<string>();
  const computers: Computer[] = [];
  for (const device of linked) {
    if (seen.has(device._id)) continue;
    seen.add(device._id);
    computers.push({
      id: device._id,
      name: device.name,
      online: device.online,
      lastSeenAt: device.lastSeenAt,
      createdAt: device.createdAt,
      unread: unread.get(device._id) ?? 0,
      lastActivityAt: activity.get(device._id) ?? 0,
    });
  }
  const others = [...known.values()]
    .filter((g) => !seen.has(g.deviceId))
    .sort((a, b) => {
      const x = activity.get(a.deviceId) ?? 0;
      const y = activity.get(b.deviceId) ?? 0;
      return x !== y ? y - x : a.deviceId < b.deviceId ? -1 : 1;
    });
  for (const group of others) {
    computers.push({
      id: group.deviceId,
      name: group.deviceName,
      online: group.deviceOnline,
      lastSeenAt: null,
      createdAt: null,
      unread: unread.get(group.deviceId) ?? 0,
      lastActivityAt: activity.get(group.deviceId) ?? 0,
    });
  }
  return computers;
}

/** The computer to show: the remembered one while it is still there, else the one active last, else the first. */
export function resolveComputer(remembered: string | null, computers: readonly Computer[]): string | null {
  if (remembered && computers.some((c) => c.id === remembered)) return remembered;
  let latest: Computer | null = null;
  for (const computer of computers) {
    if (computer.lastActivityAt > 0 && (!latest || computer.lastActivityAt > latest.lastActivityAt)) latest = computer;
  }
  return latest?.id ?? computers[0]?.id ?? null;
}

/** What a project's row says (Telegram's forum row): its newest topics and what is going on in it. */
export type ForumSummary = {
  /** Up to three sessions, most recently active first. */
  topics: SessionRow[];
  /** The most recently active session, whose preview the row shows. */
  latest: SessionRow | null;
  activity: "running" | "waiting" | "none";
  unread: number;
};

export function forumSummary(group: ProjectGroup): ForumSummary {
  const recent = [...group.sessions].sort((a, b) =>
    a.lastActivityAt !== b.lastActivityAt ? b.lastActivityAt - a.lastActivityAt : a._id < b._id ? -1 : 1,
  );
  const activity = group.sessions.some((s) => s.online && s.status === "running")
    ? "running"
    : group.sessions.some((s) => s.online && s.status === "waiting")
      ? "waiting"
      : "none";
  return { topics: recent.slice(0, 3), latest: recent[0] ?? null, activity, unread: groupUnread(group) };
}

/** FNV-1a over the UTF-8 bytes: the same index on every platform (`ProjectAvatar.colorIndex` on the phones). */
export function fnv1a(key: string): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(key)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/** Telegram's six topic colours: blue, yellow, violet, green, rose, red. */
export const TOPIC_COLORS = ["#6FB9F0", "#FFD67E", "#CB86DB", "#8EEE98", "#FF93B2", "#FB6F5F"] as const;

export function topicColor(sessionDocId: string): string {
  return TOPIC_COLORS[fnv1a(sessionDocId) % TOPIC_COLORS.length];
}

/** The title's first letter or digit, uppercased; `·` when there is none. */
export function topicLetter(title: string): string {
  const match = /[\p{L}\p{N}]/u.exec(title);
  return match ? match[0].toLocaleUpperCase() : "·";
}

/** `#rrggbb` mixed with white by `amount` (0…1). */
export function lighten(hex: string, amount: number): string {
  const n = parseInt(hex.slice(1), 16);
  const mix = (c: number) => Math.round(c + (255 - c) * amount);
  const r = mix((n >> 16) & 255);
  const g = mix((n >> 8) & 255);
  const b = mix(n & 255);
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, "0")}`;
}

/** One or two letters for an avatar: the first letters of the first two words ("crok-build" → "CB", "MacBook Pro" → "MP"). */
export function nameInitials(name: string): string {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (!words.length) return "·";
  const first = Array.from(words[0])[0] ?? "";
  const second = words.length >= 2 ? (Array.from(words[1])[0] ?? "") : "";
  return (first + second).toLocaleUpperCase();
}

/** Search on the Sessions page: title, folder, project, preview or model (case-insensitive). */
export function sessionMatches(row: SessionRow, needle: string): boolean {
  if (!needle) return true;
  return [row.title, folderName(row.cwd), row.cwd, row.projectName, row.preview ?? "", row.model ?? ""].some((field) =>
    field.toLowerCase().includes(needle),
  );
}

/** The unread sessions "Mark All as Read" (or a project's "Mark as Read") clears. */
export function unreadIds(groups: readonly Pick<ProjectGroup, "sessions">[]): string[] {
  return groups.flatMap((group) => group.sessions.filter((row) => row.unread > 0).map((row) => row._id as string));
}
