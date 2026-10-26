"use client";

/**
 * The left column's session pages (mobile/DESIGN.md "Web"): the selected computer's projects as groups with topics
 * (the root, with the computer switcher), one project's topics, and the computer's archived sessions.
 */
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, ReactNode, RefObject } from "react";
import type { Computer } from "@/lib/computers";
import { groupUnread, sessionMatches, unreadIds } from "@/lib/computers";
import { formatRelative } from "@/lib/format";
import { moveItem, reorderWithin } from "@/lib/order";
import type { ProjectGroup, SessionId, SessionRow } from "@/lib/types";
import { AccountAvatar, ComputerAvatar, ForumAvatar } from "../avatars";
import { useI18n } from "../I18nProvider";
import {
  ArchiveIcon,
  ArrowDownIcon,
  ArrowUpIcon,
  ChatsIcon,
  ChevronDownIcon,
  ComposeIcon,
  ComputerIcon,
  MoreIcon,
  PinIcon,
  PlusIcon,
  ReadIcon,
  RecentIcon,
  ReorderIcon,
  StopIcon,
  UnarchiveIcon,
} from "../icons";
import { MenuList, MenuPopover, Popover, useMenu } from "../menu";
import type { MenuItem } from "../menu";
import { Button, Code, IconButton } from "../ui";
import { useDragReorder } from "../useDragReorder";
import type { DragScope } from "../useDragReorder";
import { EmptyState, HeaderTextButton, PageHeader, ProjectPicker, SearchField } from "./chrome";
import type { PickerProject } from "./chrome";
import { ArchivedRow, ForumRow, SkeletonRows, TopicRow, UnreadBadge } from "./rows";
import type { QuickAction } from "./rows";
import type { Connection, LeftActions, LeftData } from "./types";

/** "Online" (accent), "last seen …", or the connection state while the relay is not live. */
export function ComputerStatus({
  computer,
  connection,
  now,
}: {
  computer: Pick<Computer, "online" | "lastSeenAt">;
  connection?: Connection;
  now: number;
}) {
  const { t, lang } = useI18n();
  if (connection && connection !== "live") {
    const key = connection === "offline" ? "conn_offline" : connection === "updating" ? "conn_updating" : "conn_connecting";
    return <span className="text-muted">{t(key)}</span>;
  }
  if (computer.online) return <span className="text-accent-text">{t("device_online")}</span>;
  if (computer.lastSeenAt) {
    return <span className="text-muted">{t("last_seen_short", { time: formatRelative(computer.lastSeenAt, lang, now) })}</span>;
  }
  return <span className="text-muted">{t("offline")}</span>;
}

/** The switcher's rows: every computer ("N unread" or its status), then Link a computer. */
export function computerItems(
  t: ReturnType<typeof useI18n>["t"],
  computers: Computer[],
  selectedId: string | null,
  onSelect: (id: string) => void,
  onLink: () => void,
  statusText: (computer: Computer) => string,
): MenuItem[] {
  return [
    ...computers.map<MenuItem>((computer) => ({
      label: computer.name,
      leading: <ComputerAvatar id={computer.id} name={computer.name} online={computer.online} size={32} />,
      detail: computer.unread > 0 ? t("unread_short", { count: computer.unread }) : statusText(computer),
      checked: computer.id === selectedId,
      onSelect: () => onSelect(computer.id),
    })),
    {
      label: t("link_computer"),
      leading: (
        <span className="flex h-8 w-8 items-center justify-center text-accent-text">
          <PlusIcon size={20} strokeWidth={2.2} />
        </span>
      ),
      tone: "accent",
      separated: computers.length > 0,
      onSelect: onLink,
    },
  ];
}

function useStatusText(now: number) {
  const { t, lang } = useI18n();
  return (computer: Computer) =>
    computer.online
      ? t("device_online")
      : computer.lastSeenAt
        ? t("last_seen_short", { time: formatRelative(computer.lastSeenAt, lang, now) })
        : t("offline");
}

/** Arrow keys on a drag handle move the item; the focus follows it once the list has moved. */
function useRefocus(container: RefObject<HTMLElement | null>) {
  const pending = useRef<string | null>(null);
  useEffect(() => {
    const key = pending.current;
    if (!key) return;
    pending.current = null;
    const handle = container.current?.querySelector<HTMLElement>(`[data-handle="${CSS.escape(key)}"]`);
    if (handle && document.activeElement !== handle) handle.focus();
  });
  return (key: string) => {
    pending.current = key;
  };
}

function DragIndicator({ indicatorRef }: { indicatorRef: RefObject<HTMLDivElement | null> }) {
  return (
    <div
      ref={indicatorRef}
      aria-hidden="true"
      className="pointer-events-none absolute inset-x-3 top-0 z-10 hidden h-[3px] rounded-full bg-accent"
    >
      <span className="absolute -left-1 -top-[3px] h-[9px] w-[9px] rounded-full border-2 border-accent bg-surface" />
    </div>
  );
}

/** Pin / Stop / Mark as Read / Archive (and Move Up / Move Down in a project) for a topic row; its hover buttons. */
function topicActions(
  t: ReturnType<typeof useI18n>["t"],
  row: SessionRow,
  actions: LeftActions,
  moves?: { up?: () => void; down?: () => void },
): { quick: QuickAction[]; menu: MenuItem[] } {
  const s = actions.sessions;
  const id = row._id as SessionId;
  const running = row.status === "running" && row.online;
  const pin: QuickAction = row.pinned
    ? { label: t("action_unpin"), icon: <PinIcon size={15} />, onSelect: () => s.setPinned(id, false) }
    : { label: t("action_pin"), icon: <PinIcon size={15} />, onSelect: () => s.setPinned(id, true) };
  const archive: QuickAction = row.archived
    ? { label: t("action_unarchive"), icon: <UnarchiveIcon size={15} />, onSelect: () => s.setArchived(id, false) }
    : { label: t("action_archive"), icon: <ArchiveIcon size={15} />, onSelect: () => s.setArchived(id, true) };
  const stop: QuickAction = { label: t("action_stop"), icon: <StopIcon size={15} />, tone: "danger", onSelect: () => s.stop(id) };
  const quick = row.archived ? [archive] : [pin, archive, ...(running ? [stop] : [])];
  const menu: MenuItem[] = row.archived
    ? [{ ...archive, icon: <UnarchiveIcon size={17} /> }]
    : [
        { ...pin, icon: <PinIcon size={17} /> },
        ...(running ? [{ ...stop, icon: <StopIcon size={17} /> }] : []),
        {
          label: t("mark_read"),
          icon: <ReadIcon size={17} />,
          disabled: row.unread === 0,
          onSelect: () => s.markRead([id]),
        },
        { ...archive, icon: <ArchiveIcon size={17} /> },
        ...(moves
          ? [
              {
                label: t("move_up"),
                icon: <ArrowUpIcon size={17} />,
                disabled: !moves.up,
                separated: true,
                onSelect: () => moves.up?.(),
              },
              { label: t("move_down"), icon: <ArrowDownIcon size={17} />, disabled: !moves.down, onSelect: () => moves.down?.() },
            ]
          : []),
      ];
  return { quick, menu };
}

/* ------------------------------------------------------------------------------------------------------------------ */

/**
 * The root: the selected computer's Sessions. The header holds the computer switcher, Edit, compose and the Profile
 * button; then the search field, the Archived Sessions row and one forum row per project. Edit mode drags projects
 * and offers Read All / Sort by Recent Activity at the bottom.
 */
export function SessionsRootPage({
  data,
  actions,
  computers,
  selected,
  onSelectComputer,
  groups,
  archivedRows,
  query,
  onQuery,
  editing,
  onEditing,
  activeId,
  onOpenProject,
  onOpenArchived,
  onOpenProfile,
  otherUnread,
  initialSwitcherOpen = false,
  initialPickerOpen = false,
}: {
  data: LeftData;
  actions: LeftActions;
  computers: Computer[];
  selected: Computer | null;
  onSelectComputer: (id: string) => void;
  /** This computer's projects; undefined while loading. */
  groups: ProjectGroup[] | undefined;
  archivedRows: SessionRow[];
  query: string;
  onQuery: (query: string) => void;
  editing: boolean;
  onEditing: (editing: boolean) => void;
  activeId?: string;
  onOpenProject: (key: string) => void;
  onOpenArchived: () => void;
  onOpenProfile: () => void;
  /** Unread on the other computers: the Profile button's badge. */
  otherUnread: number;
  initialSwitcherOpen?: boolean;
  initialPickerOpen?: boolean;
}) {
  const { t, tx } = useI18n();
  const router = useRouter();
  const statusText = useStatusText(data.now);
  const switcher = useMenu();
  const switcherRef = useRef<HTMLButtonElement>(null);
  const [pickerOpen, setPickerOpen] = useState(initialPickerOpen);
  const needle = query.trim().toLowerCase();
  const searching = needle.length > 0;

  useEffect(() => {
    if (initialSwitcherOpen && switcherRef.current) switcher.fromElement(switcherRef.current);
    // Once, for the dev preview.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Search turns Edit off.
  useEffect(() => {
    if (searching && editing) onEditing(false);
  }, [searching, editing, onEditing]);

  const keys = useMemo(() => (groups ?? []).map((g) => g.key), [groups]);
  const results = useMemo(
    () => (searching ? (groups ?? []).flatMap((g) => g.sessions).filter((row) => sessionMatches(row, needle)) : []),
    [groups, needle, searching],
  );
  const unread = useMemo(() => unreadIds(groups ?? []), [groups]);

  const scrollerRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLUListElement>(null);
  const indicatorRef = useRef<HTMLDivElement>(null);
  const refocus = useRefocus(contentRef);
  const drag = useDragReorder({
    scrollerRef,
    contentRef,
    indicatorRef,
    onDrop: (scope: DragScope, ids: string[]) => {
      if (scope.level === "project") actions.order.reorderProjects(ids);
    },
  });
  const moveProject = (key: string, delta: number) => {
    const from = keys.indexOf(key);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= keys.length) return;
    actions.order.reorderProjects(moveItem(keys, from, to));
  };

  const projects: PickerProject[] = useMemo(() => {
    const byKey = new Map<string, PickerProject>();
    for (const g of groups ?? []) {
      byKey.set(g.key, { key: g.key, deviceId: g.deviceId, path: g.path, name: g.name, lastActivityAt: g.lastActivityAt });
    }
    // A computer whose sessions are all archived still offers their projects.
    for (const row of archivedRows) {
      if (!byKey.has(row.projectKey)) {
        byKey.set(row.projectKey, {
          key: row.projectKey,
          deviceId: row.deviceId,
          path: row.projectPath,
          name: row.projectName,
          lastActivityAt: row.lastActivityAt,
        });
      }
    }
    return [...byKey.values()];
  }, [groups, archivedRows]);

  const canCompose = Boolean(selected?.online);
  const loaded = groups !== undefined && data.devices !== undefined;

  const switcherButton = selected ? (
    <button
      ref={switcherRef}
      type="button"
      onClick={(e) => (switcher.open ? switcher.close() : switcher.fromElement(e.currentTarget))}
      aria-haspopup="menu"
      aria-expanded={switcher.open}
      aria-label={`${selected.name}, ${t("switch_computer")}`}
      className="flex min-w-0 flex-1 items-center gap-2.5 rounded-xl px-1.5 py-1 text-left transition-colors hover:bg-hover"
    >
      <ComputerAvatar id={selected.id} name={selected.name} online={selected.online} size={36} />
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-1">
          <span className="truncate text-[15.5px] font-semibold leading-tight">{selected.name}</span>
          <ChevronDownIcon size={15} className={`shrink-0 text-muted transition-transform ${switcher.open ? "rotate-180" : ""}`} />
        </span>
        <span className="block truncate text-[13px] leading-tight">
          <ComputerStatus computer={selected} connection={data.connection} now={data.now} />
        </span>
      </span>
    </button>
  ) : (
    <div className="min-w-0 flex-1 pl-2">
      <h2 className="truncate text-[16.5px] font-semibold leading-tight">{t("nav_sessions")}</h2>
      {data.connection !== "live" ? (
        <p className="truncate text-[13px] leading-tight">
          <ComputerStatus computer={{ online: false, lastSeenAt: null }} connection={data.connection} now={data.now} />
        </p>
      ) : null}
    </div>
  );

  const profileButton = (
    <button
      type="button"
      onClick={onOpenProfile}
      aria-label={t("profile")}
      title={t("profile")}
      className="relative ml-0.5 flex h-10 w-10 items-center justify-center rounded-full hover:bg-hover"
    >
      <AccountAvatar name={data.account?.name ?? data.account?.email ?? "?"} imageUrl={data.account?.imageUrl} size={32} />
      {otherUnread > 0 ? (
        <span className="absolute -right-0.5 -top-0.5 scale-[0.85]">
          <UnreadBadge count={otherUnread} />
        </span>
      ) : null}
    </button>
  );

  let body: ReactNode;
  if (!loaded) body = <SkeletonRows />;
  else if (!computers.length) {
    body = (
      <EmptyState
        icon={<ComputerIcon size={34} />}
        title={t("no_computers_title")}
        action={
          <Button tone="primary" onClick={() => router.push("/link")}>
            <PlusIcon size={17} />
            {t("link_computer")}
          </Button>
        }
      >
        {tx("no_computers", { cmd: <Code>crok remote login</Code> })}
      </EmptyState>
    );
  } else if (searching) {
    body = results.length ? (
      <ul className="px-1.5">
        {results.map((row) => {
          const { quick, menu } = topicActions(t, row, actions);
          return <TopicRow key={row._id} row={row} now={data.now} active={row._id === activeId} showsProject quick={quick} menu={menu} />;
        })}
      </ul>
    ) : (
      <EmptyState title={t("no_results")} />
    );
  } else if (!groups?.length && !archivedRows.length) {
    body = (
      <EmptyState
        icon={<ChatsIcon size={34} />}
        title={t("no_sessions_on", { computer: selected?.name ?? "" })}
        action={
          canCompose ? (
            <Button tone="primary" onClick={() => setPickerOpen(true)}>
              <ComposeIcon size={17} />
              {t("menu_new_session")}
            </Button>
          ) : null
        }
      />
    );
  } else {
    body = (
      <ul ref={contentRef} className="relative px-1.5">
        {archivedRows.length && !editing ? <ArchivedRow rows={archivedRows} onOpen={onOpenArchived} /> : null}
        {(groups ?? []).map((group, index) => {
          const menu: MenuItem[] = [
            {
              label: t("menu_new_session"),
              icon: <ComposeIcon size={17} />,
              disabled: !group.deviceOnline,
              onSelect: () => actions.newSession({ deviceId: group.deviceId, path: group.path }),
            },
            {
              label: t("mark_read"),
              icon: <ReadIcon size={17} />,
              disabled: groupUnread(group) === 0,
              onSelect: () => actions.sessions.markRead(unreadIds([group])),
            },
            {
              label: t("move_up"),
              icon: <ArrowUpIcon size={17} />,
              disabled: index === 0,
              separated: true,
              onSelect: () => moveProject(group.key, -1),
            },
            {
              label: t("move_down"),
              icon: <ArrowDownIcon size={17} />,
              disabled: index === keys.length - 1,
              onSelect: () => moveProject(group.key, 1),
            },
            {
              label: t("sort_by_activity"),
              icon: <RecentIcon size={17} />,
              onSelect: () => actions.order.resetOrder(group.key),
            },
          ];
          return (
            <ForumRow
              key={group.key}
              group={group}
              now={data.now}
              onOpen={() => onOpenProject(group.key)}
              menu={menu}
              reorder={
                editing
                  ? {
                      dragging: drag.active?.id === group.key,
                      onPointerDown:
                        keys.length > 1
                          ? (e) =>
                              drag.begin(e, {
                                scope: { level: "project" },
                                id: group.key,
                                ids: keys,
                                element: (key) =>
                                  contentRef.current?.querySelector<HTMLElement>(`[data-project-key="${CSS.escape(key)}"]`) ?? null,
                                handle: true,
                              })
                          : undefined,
                      onKeyDown: (e: ReactKeyboardEvent<HTMLElement>) => {
                        if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
                        e.preventDefault();
                        refocus(group.key);
                        moveProject(group.key, e.key === "ArrowUp" ? -1 : 1);
                      },
                    }
                  : undefined
              }
            />
          );
        })}
        <DragIndicator indicatorRef={indicatorRef} />
      </ul>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        leading={switcherButton}
        trailing={
          <>
            {computers.length ? (
              editing ? (
                <HeaderTextButton strong onClick={() => onEditing(false)}>
                  {t("done")}
                </HeaderTextButton>
              ) : (
                <HeaderTextButton onClick={() => onEditing(true)} disabled={searching || !groups?.length}>
                  {t("edit")}
                </HeaderTextButton>
              )
            ) : null}
            {!editing && selected ? (
              <IconButton
                label={t("menu_new_session")}
                onClick={() => setPickerOpen(true)}
                disabled={!canCompose}
                title={canCompose ? t("menu_new_session") : t("new_session_offline", { computer: selected.name })}
                className="h-10 w-10"
              >
                <ComposeIcon size={20} />
              </IconButton>
            ) : null}
            {profileButton}
          </>
        }
      />
      {switcher.anchor ? (
        <Popover
          anchor={switcher.anchor}
          onClose={switcher.close}
          placement="bottom-start"
          ignore={switcherRef}
          label={t("switch_computer")}
          className="w-72 max-w-[calc(100vw-16px)]"
        >
          <MenuList
            items={computerItems(
              t,
              computers,
              selected?.id ?? null,
              onSelectComputer,
              () => router.push("/link"),
              statusText,
            )}
            onDone={switcher.close}
          />
        </Popover>
      ) : null}
      <SearchField value={query} onChange={onQuery} placeholder={t("search_sessions")} />
      <div ref={scrollerRef} className="scroll-quiet min-h-0 flex-1 overflow-y-auto pb-2">
        {body}
      </div>
      {editing ? (
        <div className="flex shrink-0 items-center justify-between border-t border-line px-2 py-1.5">
          <HeaderTextButton onClick={() => actions.sessions.markRead(unread)} disabled={!unread.length}>
            {t("read_all")}
          </HeaderTextButton>
          <HeaderTextButton onClick={() => actions.order.resetOrder()} disabled={keys.length < 2}>
            {t("sort_by_activity")}
          </HeaderTextButton>
        </div>
      ) : null}
      <ProjectPicker
        open={pickerOpen}
        projects={projects}
        onClose={() => setPickerOpen(false)}
        onPick={(project) => {
          setPickerOpen(false);
          actions.newSession({ deviceId: project.deviceId, path: project.path });
        }}
      />
    </div>
  );
}

/* ------------------------------------------------------------------------------------------------------------------ */

/**
 * A project (the group's topics): back, the project avatar, "N sessions · computer"; compose and a ⋯ menu (Mark All
 * as Read, Reorder, Sort by Recent Activity). Reorder drags sessions within their block (pinned ones lead).
 */
export function ProjectPage({
  group,
  data,
  actions,
  activeId,
  onBack,
  query,
  onQuery,
  initialReorder = false,
}: {
  group: ProjectGroup | undefined;
  data: LeftData;
  actions: LeftActions;
  activeId?: string;
  onBack: () => void;
  query: string;
  onQuery: (query: string) => void;
  initialReorder?: boolean;
}) {
  const { t, tn } = useI18n();
  const menu = useMenu();
  const menuRef = useRef<HTMLButtonElement>(null);
  const [reordering, setReordering] = useState(initialReorder);
  const needle = query.trim().toLowerCase();
  const searching = needle.length > 0;
  const rows = useMemo(
    () => (group?.sessions ?? []).filter((row) => sessionMatches(row, needle)),
    [group, needle],
  );

  useEffect(() => {
    if (searching && reordering) setReordering(false);
  }, [searching, reordering]);

  const scrollerRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLUListElement>(null);
  const indicatorRef = useRef<HTMLDivElement>(null);
  const refocus = useRefocus(contentRef);
  /** A move within the session's own block (pinned or not); the relay gets the project's full order. */
  const place = (block: string[]) => {
    if (!group) return;
    actions.order.reorderSessions(
      group.key,
      reorderWithin(
        group.sessions.map((s) => s._id as string),
        block,
      ),
    );
  };
  const blockOf = (row: SessionRow) => (group?.sessions ?? []).filter((s) => s.pinned === row.pinned).map((s) => s._id as string);
  const move = (row: SessionRow, delta: number) => {
    const block = blockOf(row);
    const from = block.indexOf(row._id);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= block.length) return;
    place(moveItem(block, from, to));
  };
  const drag = useDragReorder({
    scrollerRef,
    contentRef,
    indicatorRef,
    onDrop: (scope: DragScope, ids: string[]) => {
      if (scope.level === "session") place(ids);
    },
  });

  if (!group) {
    return (
      <div className="flex h-full min-h-0 flex-col">
        <PageHeader onBack={onBack} title="" />
        <EmptyState title={t("err_not_found")} />
      </div>
    );
  }

  const unread = unreadIds([group]);
  const projectMenu: MenuItem[] = [
    {
      label: t("mark_all_read"),
      icon: <ReadIcon size={17} />,
      disabled: unread.length === 0,
      onSelect: () => actions.sessions.markRead(unread),
    },
    {
      label: t("reorder"),
      icon: <ReorderIcon size={17} />,
      disabled: searching || group.sessions.length < 2,
      onSelect: () => setReordering(true),
    },
    { label: t("sort_by_activity"), icon: <RecentIcon size={17} />, onSelect: () => actions.order.resetOrder(group.key) },
  ];

  const subtitle =
    data.connection !== "live" ? (
      <ComputerStatus computer={{ online: false, lastSeenAt: null }} connection={data.connection} now={data.now} />
    ) : (
      tn("project_subtitle", group.sessions.length, { computer: group.deviceName })
    );

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        onBack={onBack}
        leading={
          <div className="flex min-w-0 flex-1 items-center gap-2.5 pl-0.5">
            <ForumAvatar path={group.path} name={group.name} size={40} dimmed={!group.deviceOnline} />
            <div className="min-w-0 flex-1">
              <h2 className="truncate text-[16px] font-semibold leading-tight">{group.name}</h2>
              <p className="truncate text-[13px] leading-tight text-muted">{subtitle}</p>
            </div>
          </div>
        }
        trailing={
          reordering ? (
            <HeaderTextButton strong onClick={() => setReordering(false)}>
              {t("done")}
            </HeaderTextButton>
          ) : (
            <>
              <IconButton
                label={t("menu_new_session")}
                title={group.deviceOnline ? t("menu_new_session") : t("new_session_offline", { computer: group.deviceName })}
                disabled={!group.deviceOnline}
                onClick={() => actions.newSession({ deviceId: group.deviceId, path: group.path })}
                className="h-10 w-10"
              >
                <ComposeIcon size={20} />
              </IconButton>
              <IconButton
                ref={menuRef}
                label={t("project_options")}
                aria-haspopup="menu"
                aria-expanded={menu.open}
                onClick={(e) => (menu.open ? menu.close() : menu.fromElement(e.currentTarget))}
                className="h-10 w-10"
              >
                <MoreIcon size={20} />
              </IconButton>
            </>
          )
        }
      />
      <MenuPopover menu={menu} items={projectMenu} label={group.name} ignore={menuRef} />
      <SearchField value={query} onChange={onQuery} placeholder={t("search_sessions")} />
      <div ref={scrollerRef} className="scroll-quiet min-h-0 flex-1 overflow-y-auto pb-2">
        {rows.length === 0 ? (
          <EmptyState title={searching ? t("no_results") : t("no_messages_yet")} />
        ) : (
          <ul ref={contentRef} className="relative px-1.5">
            {rows.map((row) => {
              const block = blockOf(row);
              const at = block.indexOf(row._id);
              const { quick, menu: rowMenu } = topicActions(t, row, actions, {
                up: at > 0 ? () => move(row, -1) : undefined,
                down: at >= 0 && at < block.length - 1 ? () => move(row, 1) : undefined,
              });
              return (
                <TopicRow
                  key={row._id}
                  row={row}
                  now={data.now}
                  active={row._id === activeId}
                  quick={quick}
                  menu={rowMenu}
                  reorder={
                    reordering
                      ? {
                          dragging: drag.active?.id === row._id,
                          onPointerDown:
                            block.length > 1
                              ? (e) =>
                                  drag.begin(e, {
                                    scope: { level: "session", projectKey: group.key },
                                    id: row._id,
                                    ids: block,
                                    element: (id) =>
                                      contentRef.current?.querySelector<HTMLElement>(`[data-session-id="${CSS.escape(id)}"]`) ?? null,
                                    handle: true,
                                  })
                              : undefined,
                          onKeyDown: (e: ReactKeyboardEvent<HTMLElement>) => {
                            if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
                            e.preventDefault();
                            refocus(row._id);
                            move(row, e.key === "ArrowUp" ? -1 : 1);
                          },
                        }
                      : undefined
                  }
                />
              );
            })}
            <DragIndicator indicatorRef={indicatorRef} />
          </ul>
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------------------------------------------------------ */

/** The computer's archived sessions (Telegram's Archived Chats): Unarchive on hover and in the menu. */
export function ArchivedPage({
  rows,
  computerName,
  data,
  actions,
  activeId,
  onBack,
  query,
  onQuery,
}: {
  rows: SessionRow[] | undefined;
  computerName: string;
  data: LeftData;
  actions: LeftActions;
  activeId?: string;
  onBack: () => void;
  query: string;
  onQuery: (query: string) => void;
}) {
  const { t } = useI18n();
  const needle = query.trim().toLowerCase();
  const shown = (rows ?? []).filter((row) => sessionMatches(row, needle));
  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader onBack={onBack} title={t("archived_sessions")} subtitle={computerName} />
      <SearchField value={query} onChange={onQuery} placeholder={t("search_sessions")} />
      <div className="scroll-quiet min-h-0 flex-1 overflow-y-auto pb-2">
        {rows === undefined ? (
          <SkeletonRows square={false} />
        ) : shown.length === 0 ? (
          needle ? (
            <EmptyState title={t("no_results")} />
          ) : (
            <EmptyState icon={<ArchiveIcon size={34} />} title={t("no_archived_title")}>
              {t("archived_empty")}
            </EmptyState>
          )
        ) : (
          <ul className="px-1.5">
            {shown.map((row) => {
              const { quick, menu } = topicActions(t, row, actions);
              return (
                <TopicRow key={row._id} row={row} now={data.now} active={row._id === activeId} showsProject quick={quick} menu={menu} />
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );
}
