"use client";

/**
 * The session list's actions on the relay, with optimistic updates so a row moves at once (pin, archive, stop, read,
 * reorder), and small pieces the rows and the session screen share. The list itself is the left column
 * (components/left/).
 */
import { useMutation } from "convex/react";
import type { OptimisticLocalStore } from "convex/browser";
import { useMemo } from "react";
import { api } from "@/convex/_generated/api";
import { relayError } from "@/lib/errors";
import { addSession, applyProjectOrder, applyResetOrder, applySessionOrder, patchSession, removeSession } from "@/lib/order";
import type { ProjectGroup, SessionId, SessionRow } from "@/lib/types";
import { useI18n } from "./I18nProvider";
import { useToast } from "./Toast";

export type SessionActions = {
  setPinned: (id: SessionId, pinned: boolean) => void;
  setArchived: (id: SessionId, archived: boolean) => void;
  stop: (id: SessionId) => void;
  /** `sessions:markRead` for each, shown read at once. */
  markRead: (ids: string[]) => void;
};

/** The hand-placed order (DESIGN.md §2): every client shares it through the relay. */
export type OrderActions = {
  /** Some project keys (one computer's) in their new order. */
  reorderProjects: (keys: string[]) => void;
  /** Some of one project's sessions in their new order. */
  reorderSessions: (projectKey: string, ids: string[]) => void;
  /** With a key: that project's sessions back to newest first; without: the projects. */
  resetOrder: (projectKey?: string) => void;
};

/** Where a new session starts: a folder of a computer (a project's path). */
export type NewSessionTarget = { deviceId: string; path: string };

/** The relay's error, in the reader's language when it is one we know. */
export function useErrorText() {
  const { t } = useI18n();
  return (error: unknown) => {
    const { code } = relayError(error);
    if (code === "OFFLINE") return t("err_offline");
    if (code === "NOT_FOUND") return t("err_not_found");
    if (code === null) return t("err_network");
    return t("error_generic");
  };
}

export function WorkingDots() {
  return (
    <span className="typing-dots" aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
  );
}

/** The flat list's order (`sessions:list`): pinned first, then newest. */
function sortRows(rows: SessionRow[]): SessionRow[] {
  return [...rows].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    return b.lastActivityAt - a.lastActivityAt;
  });
}

/* Optimistic updates: every loaded copy of the list (grouped and flat) and of the open session changes at once. */

function updateGroups(store: OptimisticLocalStore, update: (groups: ProjectGroup[]) => ProjectGroup[]) {
  for (const { args, value } of store.getAllQueries(api.sessions.groups)) {
    if (value) store.setQuery(api.sessions.groups, args, update(value));
  }
}

function updateLists(store: OptimisticLocalStore, update: (rows: SessionRow[], archivedList: boolean) => SessionRow[]) {
  for (const { args, value } of store.getAllQueries(api.sessions.list)) {
    if (value) store.setQuery(api.sessions.list, args, update(value, Boolean(args.archived)));
  }
}

function updateDetail(store: OptimisticLocalStore, id: string, patch: { pinned?: boolean; archived?: boolean; unread?: number }) {
  for (const { args, value } of store.getAllQueries(api.sessions.get)) {
    if (value && args.sessionDocId === id) store.setQuery(api.sessions.get, args, { ...value, ...patch });
  }
}

function findRow(store: OptimisticLocalStore, id: string): SessionRow | undefined {
  for (const { value } of store.getAllQueries(api.sessions.list)) {
    const row = value?.find((r) => r._id === id);
    if (row) return row;
  }
  for (const { value } of store.getAllQueries(api.sessions.groups)) {
    for (const group of value ?? []) {
      const row = group.sessions.find((r) => r._id === id);
      if (row) return row;
    }
  }
  return undefined;
}

/** The pin / archive / stop / read mutations, with optimistic list updates so the row changes at once. */
export function useSessionActions(): SessionActions {
  const toast = useToast();
  const errorText = useErrorText();
  const setPinned = useMutation(api.sessions.setPinned).withOptimisticUpdate((store, { sessionDocId, pinned }) => {
    updateLists(store, (rows) => sortRows(rows.map((row) => (row._id === sessionDocId ? { ...row, pinned } : row))));
    updateGroups(store, (groups) => patchSession(groups, sessionDocId, { pinned }));
    updateDetail(store, sessionDocId, { pinned });
  });
  const setArchived = useMutation(api.sessions.setArchived).withOptimisticUpdate((store, { sessionDocId, archived }) => {
    const found = findRow(store, sessionDocId);
    // Archiving also unpins (the relay does the same).
    const row = found ? { ...found, archived, pinned: archived ? false : found.pinned } : undefined;
    updateLists(store, (rows, archivedList) => {
      const rest = rows.filter((r) => r._id !== sessionDocId);
      return archivedList === archived && row ? sortRows([...rest, row]) : rest;
    });
    updateGroups(store, (groups) => (archived ? removeSession(groups, sessionDocId) : row ? addSession(groups, row) : groups));
    updateDetail(store, sessionDocId, archived ? { archived, pinned: false } : { archived });
  });
  const markRead = useMutation(api.sessions.markRead).withOptimisticUpdate((store, { sessionDocId }) => {
    updateLists(store, (rows) => rows.map((row) => (row._id === sessionDocId ? { ...row, unread: 0 } : row)));
    updateGroups(store, (groups) => patchSession(groups, sessionDocId, { unread: 0 }));
    updateDetail(store, sessionDocId, { unread: 0 });
  });
  const stop = useMutation(api.commands.stop);
  return useMemo(
    () => ({
      setPinned: (id, pinned) => void setPinned({ sessionDocId: id, pinned }).catch((e) => toast.show(errorText(e), "error")),
      setArchived: (id, archived) =>
        void setArchived({ sessionDocId: id, archived }).catch((e) => toast.show(errorText(e), "error")),
      stop: (id) => void stop({ sessionDocId: id }).catch((e) => toast.show(errorText(e), "error")),
      markRead: (ids) => {
        for (const id of ids) void markRead({ sessionDocId: id }).catch(() => {});
      },
    }),
    // errorText and toast are stable enough; the mutations are memoized by Convex.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [setPinned, setArchived, markRead, stop],
  );
}

/** Reordering projects and sessions, optimistic like the relay's own rule (lib/order.ts). */
export function useOrderActions(): OrderActions {
  const toast = useToast();
  const errorText = useErrorText();
  const reorderProjects = useMutation(api.sessions.reorderProjects).withOptimisticUpdate((store, { keys }) =>
    updateGroups(store, (groups) => applyProjectOrder(groups, keys)),
  );
  const reorderSessions = useMutation(api.sessions.reorderSessions).withOptimisticUpdate(
    (store, { projectKey, sessionDocIds }) => updateGroups(store, (groups) => applySessionOrder(groups, projectKey, sessionDocIds)),
  );
  const resetOrder = useMutation(api.sessions.resetOrder).withOptimisticUpdate((store, { projectKey }) =>
    updateGroups(store, (groups) => applyResetOrder(groups, projectKey)),
  );
  return useMemo(
    () => ({
      reorderProjects: (keys) => void reorderProjects({ keys }).catch((e) => toast.show(errorText(e), "error")),
      reorderSessions: (projectKey, ids) =>
        void reorderSessions({ projectKey, sessionDocIds: ids }).catch((e) => toast.show(errorText(e), "error")),
      resetOrder: (projectKey) =>
        void resetOrder(projectKey === undefined ? {} : { projectKey }).catch((e) => toast.show(errorText(e), "error")),
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [reorderProjects, reorderSessions, resetOrder],
  );
}
