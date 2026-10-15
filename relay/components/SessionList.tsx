"use client";

import { useMutation, useQuery } from "convex/react";
import Link from "next/link";
import { useMemo, useState } from "react";
import type { ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { relayError } from "@/lib/errors";
import { folderName, formatListTime } from "@/lib/format";
import type { DeviceRow, SessionId, SessionRow } from "@/lib/types";
import { LanguageSelect } from "./chrome";
import { useI18n } from "./I18nProvider";
import {
  ArchiveIcon,
  ChatsIcon,
  PinIcon,
  SearchIcon,
  StopIcon,
  UnarchiveIcon,
  WrenchIcon,
  XIcon,
} from "./icons";
import { useToast } from "./Toast";
import { ActionMenu, Code, ProjectAvatar, useNow } from "./ui";
import type { MenuItem } from "./ui";

export type SessionActions = {
  setPinned: (id: SessionId, pinned: boolean) => void;
  setArchived: (id: SessionId, archived: boolean) => void;
  stop: (id: SessionId) => void;
};

export type Tab = "all" | "archived" | { deviceId: string };

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
  if (!text) return <span className="text-faint">{row.model ?? " "}</span>;
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

/** One chat-list row: avatar, title and time, "computer · folder", preview or "working…", badges. */
export function SessionRowView({
  row,
  now,
  active,
  actions,
  timeText,
}: {
  row: SessionRow;
  now: number;
  active?: boolean;
  actions?: SessionActions;
  timeText?: string;
}) {
  const { t, tn, lang } = useI18n();
  const offline = !row.online;
  const time = timeText ?? formatListTime(row.lastActivityAt, lang, now);
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
        ...(row.status === "running" && row.online
          ? [{ label: t("action_stop"), icon: <StopIcon size={16} />, tone: "danger" as const, onSelect: () => actions.stop(row._id) }]
          : []),
      ]
    : [];

  return (
    <li className="group relative">
      <Link
        href={`/sessions/${row._id}`}
        aria-current={active ? "page" : undefined}
        className={`flex gap-3 rounded-xl px-3 py-2.5 transition-colors ${actions ? "[@media(hover:none)]:pr-11" : ""} ${
          active ? "bg-accent-soft" : "hover:bg-hover"
        }`}
      >
        <ProjectAvatar cwd={row.cwd} title={row.title} online={row.online} dim={offline} size={50} />
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-2">
            <span className={`min-w-0 flex-1 truncate text-[15px] font-semibold ${offline ? "text-muted" : "text-fg"}`}>
              {row.title || folderName(row.cwd)}
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
          <div className="truncate text-[13px] text-muted" title={row.cwd}>
            {row.deviceName} · {folderName(row.cwd)}
          </div>
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
      {menu.length ? (
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

/** Search, computer tabs (All / each computer / Archived) and the list itself. Pure: data comes in as props. */
export function SessionsPaneView({
  sessions,
  computers,
  tab,
  onTab,
  query,
  onQuery,
  activeId,
  now,
  actions,
  footer,
}: {
  sessions: SessionRow[] | undefined;
  computers: Pick<DeviceRow, "_id" | "name" | "online">[];
  tab: Tab;
  onTab: (tab: Tab) => void;
  query: string;
  onQuery: (q: string) => void;
  activeId?: string;
  now: number;
  actions?: SessionActions;
  footer?: ReactNode;
}) {
  const { t, tx } = useI18n();
  const needle = query.trim().toLowerCase();
  const rows = useMemo(() => {
    if (!sessions) return undefined;
    let list = sessions;
    if (typeof tab === "object") list = list.filter((s) => s.deviceId === tab.deviceId);
    if (needle) {
      list = list.filter((s) =>
        [s.title, s.cwd, s.deviceName, s.preview ?? "", s.model ?? ""].some((field) => field.toLowerCase().includes(needle)),
      );
    }
    return list;
  }, [sessions, tab, needle]);

  const tabs: { tab: Tab; label: string; online?: boolean }[] = [
    { tab: "all", label: t("tab_all") },
    ...computers.map((c) => ({ tab: { deviceId: c._id } as Tab, label: c.name, online: c.online })),
    { tab: "archived", label: t("tab_archived") },
  ];

  let empty: ReactNode = null;
  if (rows && rows.length === 0) {
    if (needle) empty = <p>{t("search_empty")}</p>;
    else if (tab === "archived") empty = <p>{t("archived_empty")}</p>;
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

  return (
    <div className="flex h-full min-h-0 flex-col bg-surface">
      <div className="shrink-0 px-3 pt-3">
        <label className="flex h-10 items-center gap-2 rounded-full bg-surface-2 px-3.5 text-muted focus-within:ring-2 focus-within:ring-accent/40">
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
      <div className="scroll-quiet min-h-0 flex-1 overflow-y-auto px-1.5 py-1.5">
        {rows === undefined ? (
          <SkeletonRows />
        ) : empty ? (
          <div className="px-6 py-14 text-center text-sm leading-relaxed text-muted">{empty}</div>
        ) : (
          <ul>
            {rows.map((row) => (
              <SessionRowView key={row._id} row={row} now={now} active={row._id === activeId} actions={actions} />
            ))}
          </ul>
        )}
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

function sortRows(rows: SessionRow[]): SessionRow[] {
  return [...rows].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    return b.lastActivityAt - a.lastActivityAt;
  });
}

/** The pin / archive / stop mutations, with optimistic list updates so the row moves at once. */
export function useSessionActions(): SessionActions {
  const toast = useToast();
  const errorText = useErrorText();
  const setPinned = useMutation(api.sessions.setPinned).withOptimisticUpdate((store, { sessionDocId, pinned }) => {
    for (const { args, value } of store.getAllQueries(api.sessions.list)) {
      if (!value) continue;
      store.setQuery(
        api.sessions.list,
        args,
        sortRows(value.map((row) => (row._id === sessionDocId ? { ...row, pinned } : row))),
      );
    }
  });
  const setArchived = useMutation(api.sessions.setArchived).withOptimisticUpdate((store, { sessionDocId, archived }) => {
    for (const { args, value } of store.getAllQueries(api.sessions.list)) {
      if (!value) continue;
      if (Boolean(args.archived) === archived) continue;
      store.setQuery(
        api.sessions.list,
        args,
        value.filter((row) => row._id !== sessionDocId),
      );
    }
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

/** The live list for the signed-in person (sessions:list + devices:list for the computer tabs). */
export function SessionsPane({ activeId }: { activeId?: string }) {
  const [tab, setTab] = useState<Tab>("all");
  const [query, setQuery] = useState("");
  const now = useNow(30_000);
  const sessions = useQuery(api.sessions.list, tab === "archived" ? { archived: true } : {});
  const devices = useQuery(api.devices.list);
  const actions = useSessionActions();
  const computers = useMemo(() => (devices ?? []).filter((d) => d.kind === "computer"), [devices]);
  // A computer tab whose device was signed out falls back to All.
  const effectiveTab = typeof tab === "object" && devices && !computers.some((c) => c._id === tab.deviceId) ? "all" : tab;
  return (
    <SessionsPaneView
      sessions={sessions}
      computers={computers}
      tab={effectiveTab}
      onTab={setTab}
      query={query}
      onQuery={setQuery}
      activeId={activeId}
      now={now}
      actions={actions}
      footer={<LanguageSelect />}
    />
  );
}
