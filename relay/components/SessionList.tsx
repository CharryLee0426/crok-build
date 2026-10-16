"use client";

import { useMutation, useQuery } from "convex/react";
import type { OptimisticLocalStore } from "convex/browser";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { readStorage, writeStorage } from "@/lib/browser";
import { relayError } from "@/lib/errors";
import { folderName, formatListTime, tildePath } from "@/lib/format";
import {
  addSession,
  applyProjectOrder,
  applyResetOrder,
  applySessionOrder,
  moveItem,
  patchSession,
  removeSession,
  reorderWithin,
} from "@/lib/order";
import type { DeviceRow, ProjectGroup, SessionId, SessionRow } from "@/lib/types";
import { LanguageSelect } from "./chrome";
import { useI18n } from "./I18nProvider";
import {
  ArchiveIcon,
  ArrowDownIcon,
  ArrowUpIcon,
  ChatsIcon,
  ChevronDownIcon,
  FolderIcon,
  GripIcon,
  PinIcon,
  RecentIcon,
  SearchIcon,
  StopIcon,
  UnarchiveIcon,
  WrenchIcon,
  XIcon,
} from "./icons";
import { useToast } from "./Toast";
import { ActionMenu, Code, ProjectAvatar, useNow } from "./ui";
import type { MenuItem } from "./ui";
import { useDragReorder } from "./useDragReorder";
import type { DragScope } from "./useDragReorder";

export type SessionActions = {
  setPinned: (id: SessionId, pinned: boolean) => void;
  setArchived: (id: SessionId, archived: boolean) => void;
  stop: (id: SessionId) => void;
};

/** The hand-placed order (DESIGN.md §2): every client shares it through the relay. */
export type OrderActions = {
  /** Some project keys (those the current tab shows) in their new order. */
  reorderProjects: (keys: string[]) => void;
  /** Some of one project's sessions in their new order. */
  reorderSessions: (projectKey: string, ids: string[]) => void;
  /** With a key: that project's sessions back to newest first; without: the projects. */
  resetOrder: (projectKey?: string) => void;
};

export type Tab = "all" | "archived" | { deviceId: string };

/** A section shows this many sessions, then "Show N more". */
const SECTION_ROWS = 5;
/** localStorage: the project keys folded on this device. */
const COLLAPSED_KEY = "crok-collapsed-projects";

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

export function SessionPreview({
  row,
}: {
  row: Pick<SessionRow, "status" | "preview" | "previewKind" | "online" | "model">;
}) {
  const { t } = useI18n();
  if (row.status === "running" && row.online) {
    return (
      <span className="text-accent-text">
        {t("working")}
        <WorkingDots />
      </span>
    );
  }
  const text = (row.preview ?? "").replace(/\s+/g, " ").trim();
  // A new session has no preview until the computer sends one: show its model rather than an empty line.
  if (!text) return <span className="text-faint">{row.model ?? " "}</span>;
  switch (row.previewKind) {
    case "user":
      return (
        <span>
          <span className="text-fg/80">{t("you_prefix")} </span>
          {text}
        </span>
      );
    case "tool":
      return (
        <span className="inline-flex min-w-0 items-center gap-1">
          <WrenchIcon size={13} className="shrink-0" />
          <span className="truncate">{text}</span>
        </span>
      );
    case "thought":
      return <span className="italic">{text}</span>;
    case "error":
      return <span className="text-danger">{text}</span>;
    case "system":
      return <span className="italic text-faint">{text}</span>;
    default:
      return <span>{text}</span>;
  }
}

/**
 * One chat-list row: avatar, title and time, where it runs, preview or "working…", badges. In a project section
 * (`grouped`) the second line names the session's own folder only when it isn't the project's (the header names
 * project and computer); in a flat list (Archived, the landing page) it reads "computer · folder".
 */
export function SessionRowView({
  row,
  now,
  active,
  actions,
  timeText,
  grouped = false,
  extraMenu,
  onDragPointerDown,
  dragging = false,
}: {
  row: SessionRow;
  now: number;
  active?: boolean;
  actions?: SessionActions;
  timeText?: string;
  grouped?: boolean;
  /** More menu entries (Move up / Move down). */
  extraMenu?: MenuItem[];
  /** Set when the row can be dragged: the row's pointerdown starts the gesture. */
  onDragPointerDown?: (e: ReactPointerEvent<HTMLElement>) => void;
  dragging?: boolean;
}) {
  const { t, tn, lang } = useI18n();
  // Dimmed only when its computer is offline: a session nobody runs opens there when you send it a prompt.
  const offline = !row.deviceOnline;
  const time = timeText ?? formatListTime(row.lastActivityAt, lang, now);
  const folder = folderName(row.cwd);
  const place = grouped ? (folder !== row.projectName ? folder : null) : `${row.deviceName} · ${folder}`;
  const menu: MenuItem[] = actions
    ? [
        row.pinned
          ? { label: t("action_unpin"), icon: <PinIcon size={16} />, onSelect: () => actions.setPinned(row._id, false) }
          : { label: t("action_pin"), icon: <PinIcon size={16} />, onSelect: () => actions.setPinned(row._id, true) },
        row.archived
          ? {
              label: t("action_unarchive"),
              icon: <UnarchiveIcon size={16} />,
              onSelect: () => actions.setArchived(row._id, false),
            }
          : {
              label: t("action_archive"),
              icon: <ArchiveIcon size={16} />,
              onSelect: () => actions.setArchived(row._id, true),
            },
        ...(extraMenu ?? []),
        ...(row.status === "running" && row.online
          ? [{ label: t("action_stop"), icon: <StopIcon size={16} />, tone: "danger" as const, onSelect: () => actions.stop(row._id) }]
          : []),
      ]
    : [];
  const draggable = Boolean(onDragPointerDown);

  return (
    <li
      data-session-id={row._id}
      className={`group relative ${dragging ? "z-20 rounded-xl bg-surface shadow-card" : ""}`}
    >
      <Link
        href={`/sessions/${row._id}`}
        aria-current={active ? "page" : undefined}
        draggable={draggable ? false : undefined}
        onPointerDown={onDragPointerDown}
        onDragStart={draggable ? (e) => e.preventDefault() : undefined}
        className={`flex gap-3 rounded-xl px-3 py-2.5 transition-colors ${actions ? "[@media(hover:none)]:pr-11" : ""} ${
          draggable ? "select-none [-webkit-touch-callout:none] [-webkit-user-drag:none]" : ""
        } ${active || dragging ? "bg-accent-soft" : "hover:bg-hover"}`}
      >
        <ProjectAvatar cwd={row.cwd} title={row.title} online={row.online} dim={offline} size={50} />
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-2">
            <span className={`min-w-0 flex-1 truncate text-[15px] font-semibold ${offline ? "text-muted" : "text-fg"}`}>
              {row.title || folder}
            </span>
            <span
              className={`shrink-0 text-xs tabular-nums ${row.unread > 0 ? "text-accent-text" : "text-faint"} transition-opacity ${
                actions
                  ? "group-hover:[@media(hover:hover)]:opacity-0 group-has-[[aria-expanded=true]]:opacity-0 [@media(hover:hover)]:group-has-[button:focus-visible]:opacity-0"
                  : ""
              }`}
            >
              {time}
            </span>
          </div>
          {place ? (
            <div className="truncate text-[13px] text-muted" title={row.cwd}>
              {place}
            </div>
          ) : null}
          <div className="mt-0.5 flex items-center gap-2">
            {row.status === "waiting" && row.online ? (
              <span className="shrink-0 rounded-full bg-warning-soft px-2 py-px text-[11px] font-medium text-warning">
                {t("needs_approval")}
              </span>
            ) : null}
            <span className={`min-w-0 flex-1 truncate text-[13.5px] ${offline ? "text-faint" : "text-muted"}`}>
              <SessionPreview row={row} />
            </span>
            {row.unread > 0 ? (
              <span
                className="flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full bg-accent px-1.5 text-[11px] font-semibold text-accent-fg tabular-nums"
                aria-label={tn("unread", row.unread)}
              >
                {row.unread > 99 ? "99+" : row.unread}
              </span>
            ) : row.pinned ? (
              <PinIcon size={14} className="shrink-0 text-faint" aria-label={t("pinned")} />
            ) : null}
          </div>
        </div>
      </Link>
      {menu.length && !dragging ? (
        <ActionMenu
          label={t("more_actions")}
          items={menu}
          className="absolute right-2.5 top-2 transition-opacity [@media(hover:hover)]:opacity-0 [@media(hover:hover)]:group-hover:opacity-100 [@media(hover:hover)]:focus-within:opacity-100"
        />
      ) : null}
    </li>
  );
}

function sameTab(a: Tab, b: Tab): boolean {
  if (typeof a === "string" || typeof b === "string") return a === b;
  return a.deviceId === b.deviceId;
}

function matches(row: SessionRow, needle: string): boolean {
  return [row.title, row.cwd, row.deviceName, row.projectName, row.preview ?? "", row.model ?? ""].some((field) =>
    field.toLowerCase().includes(needle),
  );
}

/** The project keys folded on this device, remembered across visits. */
function useCollapsedProjects() {
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  useEffect(() => {
    try {
      const saved: unknown = JSON.parse(readStorage(COLLAPSED_KEY) ?? "[]");
      if (Array.isArray(saved)) setCollapsed(new Set(saved.filter((key): key is string => typeof key === "string")));
    } catch {
      // Unreadable: start with every project open.
    }
  }, []);
  const toggle = useCallback(
    (key: string) => {
      const next = new Set(collapsed);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      setCollapsed(next);
      writeStorage(COLLAPSED_KEY, next.size ? JSON.stringify([...next]) : null);
    },
    [collapsed],
  );
  return [collapsed, toggle] as const;
}

/** One project: a header (drag handle, folder, name, computer, count, fold chevron, menu) and its sessions. */
function ProjectSection({
  group,
  first,
  showComputer,
  collapsed,
  onToggleCollapsed,
  expanded,
  onToggleExpanded,
  searching,
  folded,
  dragging,
  draggingSessionId,
  menu,
  onHandlePointerDown,
  onHandleKeyDown,
  rowProps,
}: {
  group: ProjectGroup;
  first: boolean;
  showComputer: boolean;
  collapsed: boolean;
  onToggleCollapsed: () => void;
  expanded: boolean;
  onToggleExpanded: () => void;
  searching: boolean;
  /** Every section shows only its header while a project is dragged. */
  folded: boolean;
  dragging: boolean;
  draggingSessionId: string | null;
  menu: MenuItem[];
  onHandlePointerDown?: (e: ReactPointerEvent<HTMLElement>) => void;
  onHandleKeyDown?: (e: ReactKeyboardEvent<HTMLElement>) => void;
  rowProps: (row: SessionRow, shown: SessionRow[]) => Omit<Parameters<typeof SessionRowView>[0], "row">;
}) {
  const { t, tn } = useI18n();
  const count = group.sessions.length;
  // While searching, sections show every match, folded or not.
  const open = searching || !collapsed;
  const limit = searching || expanded ? count : SECTION_ROWS;
  const shown = group.sessions.slice(0, limit);
  const hidden = count - shown.length;
  const canShowLess = !searching && expanded && count > SECTION_ROWS;

  return (
    <section
      data-project-key={group.key}
      className={`relative ${first ? "" : "mt-1.5"} ${dragging ? "z-20 rounded-xl bg-surface shadow-card" : ""}`}
    >
      <div className="group/header flex items-center gap-0.5 pr-1">
        {onHandlePointerDown ? (
          <button
            type="button"
            data-project-handle={group.key}
            aria-label={t("reorder_project_label", { name: group.name })}
            title={t("drag_to_reorder")}
            onPointerDown={onHandlePointerDown}
            onKeyDown={onHandleKeyDown}
            className={`flex h-8 w-5 shrink-0 cursor-grab touch-none items-center justify-center rounded-md text-faint transition-opacity hover:text-fg ${
              dragging ? "" : "[@media(hover:hover)]:opacity-0 [@media(hover:hover)]:group-hover/header:opacity-100 focus-visible:opacity-100"
            }`}
          >
            <GripIcon size={14} />
          </button>
        ) : (
          <span className="w-5 shrink-0" aria-hidden="true" />
        )}
        <button
          type="button"
          onClick={onToggleCollapsed}
          aria-expanded={open}
          disabled={searching}
          className="flex h-9 min-w-0 flex-1 items-center gap-2 rounded-lg px-1.5 text-left transition-colors hover:bg-hover disabled:hover:bg-transparent"
        >
          <FolderIcon size={16} className="shrink-0 text-muted" />
          <span className="min-w-0 truncate text-[13.5px] font-semibold text-fg" title={tildePath(group.path)}>
            {group.name}
          </span>
          {showComputer ? (
            <span className="flex min-w-0 shrink-[3] items-center gap-1.5 text-[12.5px] text-faint">
              <span
                className={`h-1.5 w-1.5 shrink-0 rounded-full ${group.deviceOnline ? "bg-accent" : "bg-line-strong"}`}
                aria-hidden="true"
              />
              <span className="truncate">{group.deviceName}</span>
              <span className="sr-only">({group.deviceOnline ? t("online") : t("offline")})</span>
            </span>
          ) : null}
          <span className="ml-auto shrink-0 pl-1 text-xs tabular-nums text-faint" aria-hidden="true">
            {count}
          </span>
          <span className="sr-only">{tn("session_count", count)}</span>
          {searching ? null : (
            <ChevronDownIcon
              size={16}
              className={`shrink-0 text-faint transition-transform ${open ? "" : "-rotate-90"}`}
            />
          )}
        </button>
        {menu.length && !dragging ? (
          <ActionMenu
            label={t("project_options")}
            items={menu}
            className="relative transition-opacity [@media(hover:hover)]:opacity-0 [@media(hover:hover)]:group-hover/header:opacity-100 [@media(hover:hover)]:focus-within:opacity-100"
          />
        ) : null}
      </div>
      {open && !folded ? (
        <>
          <ul>
            {shown.map((row) => (
              <SessionRowView key={row._id} row={row} grouped dragging={row._id === draggingSessionId} {...rowProps(row, shown)} />
            ))}
          </ul>
          {hidden > 0 || canShowLess ? (
            <button
              type="button"
              onClick={onToggleExpanded}
              aria-expanded={!hidden}
              className="mb-1 ml-[70px] rounded-md px-1 py-1 text-[13px] font-medium text-accent-text hover:underline"
            >
              {hidden > 0 ? t("show_n_more", { count: hidden }) : t("show_less")}
            </button>
          ) : null}
        </>
      ) : null}
    </section>
  );
}

/**
 * Search, computer tabs (All / each computer / Archived) and the list itself: on All and computer tabs, one section
 * per project in the relay's order (drag a header's handle or a row to reorder, or use the menus); Archived stays a
 * flat list. Pure: data comes in as props.
 */
export function SessionsPaneView({
  groups,
  archived,
  computers,
  tab,
  onTab,
  query,
  onQuery,
  activeId,
  now,
  actions,
  order,
  footer,
}: {
  /** The main list (`sessions:groups`); undefined while loading. */
  groups: ProjectGroup[] | undefined;
  /** The Archived tab (`sessions:list({archived: true})`); undefined while loading. */
  archived: SessionRow[] | undefined;
  computers: Pick<DeviceRow, "_id" | "name" | "online">[];
  tab: Tab;
  onTab: (tab: Tab) => void;
  query: string;
  onQuery: (q: string) => void;
  activeId?: string;
  now: number;
  actions?: SessionActions;
  order?: OrderActions;
  footer?: ReactNode;
}) {
  const { t, tx } = useI18n();
  const needle = query.trim().toLowerCase();
  const searching = needle.length > 0;
  const onArchived = tab === "archived";

  const sections = useMemo(() => {
    if (!groups) return undefined;
    let list = groups;
    if (typeof tab === "object") list = list.filter((g) => g.deviceId === tab.deviceId);
    if (needle) {
      list = list
        .map((g) => ({ ...g, sessions: g.sessions.filter((s) => matches(s, needle)) }))
        .filter((g) => g.sessions.length > 0);
    }
    return list;
  }, [groups, tab, needle]);
  const archivedRows = useMemo(
    () => (archived && needle ? archived.filter((s) => matches(s, needle)) : archived),
    [archived, needle],
  );

  const [collapsed, toggleCollapsed] = useCollapsedProjects();
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const toggleExpanded = (key: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  // Opening a session further down than a section shows (a link, the phone): unfold the rest of that section, once
  // per opened session (a later "Show less" sticks).
  const unfoldedFor = useRef<string | null>(null);
  useEffect(() => {
    if (!activeId || !groups || unfoldedFor.current === activeId) return;
    unfoldedFor.current = activeId;
    const group = groups.find((g) => g.sessions.findIndex((s) => s._id === activeId) >= SECTION_ROWS);
    if (group) setExpanded((prev) => (prev.has(group.key) ? prev : new Set(prev).add(group.key)));
  }, [activeId, groups]);

  const canReorder = Boolean(order) && !searching && !onArchived;
  const keys = useMemo(() => (sections ?? []).map((g) => g.key), [sections]);

  const scrollerRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const indicatorRef = useRef<HTMLDivElement>(null);

  const moveProject = (key: string, delta: number) => {
    const from = keys.indexOf(key);
    const to = from + delta;
    if (!order || from < 0 || to < 0 || to >= keys.length) return;
    order.reorderProjects(moveItem(keys, from, to));
  };
  /** A move within the session's own block (pinned or not) of its project; the relay gets the project's full order. */
  const placeSessions = (group: ProjectGroup, block: string[]) => {
    order?.reorderSessions(
      group.key,
      reorderWithin(
        group.sessions.map((s) => s._id as string),
        block,
      ),
    );
  };
  const moveSession = (group: ProjectGroup, row: SessionRow, delta: number) => {
    const block = group.sessions.filter((s) => s.pinned === row.pinned).map((s) => s._id as string);
    const from = block.indexOf(row._id);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= block.length) return;
    placeSessions(group, moveItem(block, from, to));
  };

  const drag = useDragReorder({
    scrollerRef,
    contentRef,
    indicatorRef,
    onDrop: (scope: DragScope, ids: string[]) => {
      if (!order) return;
      if (scope.level === "project") {
        order.reorderProjects(ids);
        return;
      }
      const group = sections?.find((g) => g.key === scope.projectKey);
      if (group) placeSessions(group, ids);
    },
  });
  const draggingProject = drag.active?.scope.level === "project" ? drag.active.id : null;
  const draggingSession = drag.active?.scope.level === "session" ? drag.active.id : null;

  // Arrow keys on a handle move the project; keep the focus on that handle once the list has moved.
  const refocusRef = useRef<string | null>(null);
  useEffect(() => {
    const key = refocusRef.current;
    if (!key) return;
    refocusRef.current = null;
    const handle = contentRef.current?.querySelector<HTMLElement>(`[data-project-handle="${CSS.escape(key)}"]`);
    if (handle && document.activeElement !== handle) handle.focus();
  });

  const findIn = (selector: string) => contentRef.current?.querySelector<HTMLElement>(selector) ?? null;
  const projectElement = (key: string) => findIn(`[data-project-key="${CSS.escape(key)}"]`);
  const sessionElement = (id: string) => findIn(`[data-session-id="${CSS.escape(id)}"]`);

  const tabs: { tab: Tab; label: string; online?: boolean }[] = [
    { tab: "all", label: t("tab_all") },
    ...computers.map((c) => ({ tab: { deviceId: c._id } as Tab, label: c.name, online: c.online })),
    { tab: "archived", label: t("tab_archived") },
  ];

  const loaded = onArchived ? archivedRows : sections;
  let empty: ReactNode = null;
  if (loaded && loaded.length === 0) {
    if (needle) empty = <p>{t("search_empty")}</p>;
    else if (onArchived) empty = <p>{t("archived_empty")}</p>;
    else if (typeof tab === "object") empty = <p>{t("computer_empty")}</p>;
    else
      empty = (
        <>
          <ChatsIcon size={30} className="mx-auto mb-3 text-faint" />
          <p className="font-medium text-fg">{t("sessions_empty_title")}</p>
          <p className="mt-1">{tx("sessions_empty", { cmd: <Code>crok remote login</Code> })}</p>
        </>
      );
  }

  const listMenu: MenuItem[] =
    order && !onArchived
      ? [
          {
            label: t("sort_projects_by_activity"),
            icon: <RecentIcon size={16} />,
            disabled: searching,
            onSelect: () => order.resetOrder(),
          },
        ]
      : [];

  let body: ReactNode;
  if (loaded === undefined) body = <SkeletonRows />;
  else if (empty) body = <div className="px-6 py-14 text-center text-sm leading-relaxed text-muted">{empty}</div>;
  else if (onArchived)
    body = (
      <ul>
        {(archivedRows ?? []).map((row) => (
          <SessionRowView key={row._id} row={row} now={now} active={row._id === activeId} actions={actions} />
        ))}
      </ul>
    );
  else
    body = (
      <div ref={contentRef} className="relative">
        {(sections ?? []).map((group, index) => {
          const projectMenu: MenuItem[] = canReorder
            ? [
                ...(index > 0
                  ? [{ label: t("move_up"), icon: <ArrowUpIcon size={16} />, onSelect: () => moveProject(group.key, -1) }]
                  : []),
                ...(index < keys.length - 1
                  ? [{ label: t("move_down"), icon: <ArrowDownIcon size={16} />, onSelect: () => moveProject(group.key, 1) }]
                  : []),
                {
                  label: t("sort_by_activity"),
                  icon: <RecentIcon size={16} />,
                  onSelect: () => order?.resetOrder(group.key),
                },
              ]
            : [];
          return (
            <ProjectSection
              key={group.key}
              group={group}
              first={index === 0}
              showComputer={tab === "all"}
              collapsed={collapsed.has(group.key)}
              onToggleCollapsed={() => toggleCollapsed(group.key)}
              expanded={expanded.has(group.key)}
              onToggleExpanded={() => toggleExpanded(group.key)}
              searching={searching}
              folded={draggingProject !== null}
              dragging={draggingProject === group.key}
              draggingSessionId={draggingSession}
              menu={projectMenu}
              onHandlePointerDown={
                canReorder && keys.length > 1
                  ? (e) =>
                      drag.begin(e, {
                        scope: { level: "project" },
                        id: group.key,
                        ids: keys,
                        element: projectElement,
                        handle: true,
                      })
                  : undefined
              }
              onHandleKeyDown={(e) => {
                if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
                e.preventDefault();
                refocusRef.current = group.key;
                moveProject(group.key, e.key === "ArrowUp" ? -1 : 1);
              }}
              rowProps={(row, shown) => {
                const block = group.sessions.filter((s) => s.pinned === row.pinned);
                const at = block.findIndex((s) => s._id === row._id);
                const visibleBlock = shown.filter((s) => s.pinned === row.pinned).map((s) => s._id as string);
                const moves: MenuItem[] = canReorder
                  ? [
                      ...(at > 0
                        ? [{ label: t("move_up"), icon: <ArrowUpIcon size={16} />, onSelect: () => moveSession(group, row, -1) }]
                        : []),
                      ...(at >= 0 && at < block.length - 1
                        ? [{ label: t("move_down"), icon: <ArrowDownIcon size={16} />, onSelect: () => moveSession(group, row, 1) }]
                        : []),
                    ]
                  : [];
                return {
                  now,
                  active: row._id === activeId,
                  actions,
                  extraMenu: moves,
                  onDragPointerDown:
                    canReorder && visibleBlock.length > 1
                      ? (e: ReactPointerEvent<HTMLElement>) =>
                          drag.begin(e, {
                            scope: { level: "session", projectKey: group.key },
                            id: row._id,
                            ids: visibleBlock,
                            element: sessionElement,
                            handle: false,
                          })
                      : undefined,
                };
              }}
            />
          );
        })}
        <div
          ref={indicatorRef}
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-2 top-0 z-10 hidden h-[3px] rounded-full bg-accent"
        >
          <span className="absolute -left-1 -top-[3px] h-[9px] w-[9px] rounded-full border-2 border-accent bg-surface" />
        </div>
      </div>
    );

  return (
    <div className="flex h-full min-h-0 flex-col bg-surface">
      <div className="flex shrink-0 items-center gap-1 px-3 pt-3">
        <label className="flex h-10 min-w-0 flex-1 items-center gap-2 rounded-full bg-surface-2 px-3.5 text-muted focus-within:ring-2 focus-within:ring-accent/40">
          <SearchIcon size={17} />
          <input
            type="search"
            value={query}
            onChange={(e) => onQuery(e.target.value)}
            placeholder={t("search_placeholder")}
            aria-label={t("search_placeholder")}
            className="min-w-0 flex-1 bg-transparent text-[15px] text-fg placeholder:text-faint focus:outline-none [&::-webkit-search-cancel-button]:hidden"
          />
          {query ? (
            <button type="button" onClick={() => onQuery("")} aria-label={t("clear_search")} className="text-faint hover:text-fg">
              <XIcon size={16} />
            </button>
          ) : null}
        </label>
        {listMenu.length ? <ActionMenu label={t("list_options")} items={listMenu} /> : null}
      </div>
      <div className="scroll-quiet mt-2 flex shrink-0 gap-1 overflow-x-auto border-b border-line px-3" role="tablist">
        {tabs.map((entry) => {
          const selected = sameTab(entry.tab, tab);
          return (
            <button
              key={typeof entry.tab === "string" ? entry.tab : entry.tab.deviceId}
              type="button"
              role="tab"
              aria-selected={selected}
              onClick={() => onTab(entry.tab)}
              className={`relative flex shrink-0 items-center gap-1.5 whitespace-nowrap px-2.5 pb-2.5 pt-1.5 text-sm transition-colors ${
                selected ? "font-semibold text-accent-text" : "text-muted hover:text-fg"
              }`}
            >
              {entry.online !== undefined ? (
                <span className={`h-1.5 w-1.5 rounded-full ${entry.online ? "bg-accent" : "bg-line-strong"}`} aria-hidden="true" />
              ) : null}
              {entry.label}
              {selected ? <span className="absolute inset-x-1.5 bottom-0 h-[3px] rounded-t-full bg-accent" /> : null}
            </button>
          );
        })}
      </div>
      <div ref={scrollerRef} className="scroll-quiet min-h-0 flex-1 overflow-y-auto px-1.5 py-1.5">
        {body}
      </div>
      {footer ? <div className="shrink-0 border-t border-line px-4 py-2">{footer}</div> : null}
    </div>
  );
}

function SkeletonRows() {
  return (
    <ul aria-hidden="true">
      {Array.from({ length: 6 }, (_, i) => (
        <li key={i} className="flex gap-3 px-3 py-2.5">
          <span className="h-[50px] w-[50px] shrink-0 animate-pulse rounded-full bg-surface-2" />
          <span className="flex flex-1 flex-col gap-2 pt-1.5">
            <span className="h-3.5 w-2/3 animate-pulse rounded bg-surface-2" />
            <span className="h-3 w-1/2 animate-pulse rounded bg-surface-2" />
            <span className="h-3 w-5/6 animate-pulse rounded bg-surface-2" />
          </span>
        </li>
      ))}
    </ul>
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

function updateDetail(store: OptimisticLocalStore, id: string, patch: { pinned?: boolean; archived?: boolean }) {
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

/** The pin / archive / stop mutations, with optimistic list updates so the row moves at once. */
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
  const stop = useMutation(api.commands.stop);
  return useMemo(
    () => ({
      setPinned: (id, pinned) => void setPinned({ sessionDocId: id, pinned }).catch((e) => toast.show(errorText(e), "error")),
      setArchived: (id, archived) =>
        void setArchived({ sessionDocId: id, archived }).catch((e) => toast.show(errorText(e), "error")),
      stop: (id) => void stop({ sessionDocId: id }).catch((e) => toast.show(errorText(e), "error")),
    }),
    // errorText and toast are stable enough; the mutations are memoized by Convex.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [setPinned, setArchived, stop],
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

/** The live list for the signed-in person (sessions:groups, sessions:list for Archived, devices:list for the tabs). */
export function SessionsPane({ activeId }: { activeId?: string }) {
  const [tab, setTab] = useState<Tab>("all");
  const [query, setQuery] = useState("");
  const now = useNow(30_000);
  const groups = useQuery(api.sessions.groups, {});
  const archived = useQuery(api.sessions.list, tab === "archived" ? { archived: true } : "skip");
  const devices = useQuery(api.devices.list);
  const actions = useSessionActions();
  const order = useOrderActions();
  const computers = useMemo(() => (devices ?? []).filter((d) => d.kind === "computer"), [devices]);
  // A computer tab whose device was signed out falls back to All.
  const effectiveTab = typeof tab === "object" && devices && !computers.some((c) => c._id === tab.deviceId) ? "all" : tab;
  return (
    <SessionsPaneView
      groups={groups}
      archived={archived}
      computers={computers}
      tab={effectiveTab}
      onTab={setTab}
      query={query}
      onQuery={setQuery}
      activeId={activeId}
      now={now}
      actions={actions}
      order={order}
      footer={<LanguageSelect />}
    />
  );
}
