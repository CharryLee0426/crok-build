"use client";

/**
 * The left column's rows (mobile/DESIGN.md "Sessions tab", "Project screen", "Archived screen"): a project as a group
 * with topics (Telegram's forum row), a session as a topic, and the Archived Sessions row. The phones' swipe actions
 * are hover buttons here, and their long press is a ⋯ button or a right click.
 */
import Link from "next/link";
import { useRef } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { forumSummary } from "@/lib/computers";
import { folderName, formatListTime, tildePath } from "@/lib/format";
import type { ProjectGroup, SessionRow } from "@/lib/types";
import { ArchiveAvatar, ForumAvatar, TopicIcon } from "../avatars";
import { useI18n } from "../I18nProvider";
import { GripIcon, MoreIcon, PinIcon, WarningIcon, WrenchIcon } from "../icons";
import { MenuPopover, useMenu } from "../menu";
import type { MenuItem } from "../menu";
import { WorkingDots } from "../SessionList";

/**
 * A row's ⋯ and quick buttons show on hover (and while focused) where there is a pointer that hovers; touch screens
 * open the same menu with a long press instead. The time under them steps aside meanwhile.
 */
const SHOW_ON_HOVER =
  "row-actions transition-opacity [@media(hover:none)]:hidden [@media(hover:hover)]:opacity-0 [@media(hover:hover)]:group-hover:opacity-100 [@media(hover:hover)]:focus-within:opacity-100";
const HIDE_ON_HOVER =
  "[@media(hover:hover)]:group-hover:opacity-0 [@media(hover:hover)]:group-has-[.row-actions:focus-within]:opacity-0";

/** Telegram's unread badge: accent, grey while the computer is offline, white on a selected row. */
export function UnreadBadge({ count, muted = false, inverted = false }: { count: number; muted?: boolean; inverted?: boolean }) {
  const { tn } = useI18n();
  return (
    <span
      className={`flex h-[22px] min-w-[22px] shrink-0 items-center justify-center rounded-full px-1.5 text-[12px] font-semibold tabular-nums ${
        inverted ? "bg-white text-accent" : muted ? "bg-faint text-white" : "bg-accent text-accent-fg"
      }`}
      aria-label={tn("unread", count)}
    >
      {count > 999 ? "999+" : count}
    </span>
  );
}

function NeedsApproval({ inverted }: { inverted?: boolean }) {
  const { t } = useI18n();
  return (
    <span
      className={`inline-flex max-w-full items-center gap-1 rounded-full px-2 py-px text-[12px] font-medium ${
        inverted ? "bg-white/20 text-white" : "bg-warning-soft text-warning"
      }`}
    >
      <WarningIcon size={12} className="shrink-0" />
      <span className="truncate">{t("needs_approval")}</span>
    </span>
  );
}

function Working() {
  const { t } = useI18n();
  return (
    <span>
      {t("working")}
      <WorkingDots />
    </span>
  );
}

/** A session's last message as a list shows it: "You: " before a prompt, a glyph before a tool call or an error. */
export function PreviewText({ row }: { row: Pick<SessionRow, "preview" | "previewKind"> }) {
  const { t } = useI18n();
  const text = (row.preview ?? "").replace(/\s+/g, " ").trim();
  switch (row.previewKind) {
    case "user":
      return (
        <>
          <span className="text-fg/80 [.row-selected_&]:text-white">{t("you_prefix")} </span>
          {text}
        </>
      );
    case "tool":
      return (
        <>
          <WrenchIcon size={13} className="mr-1 inline-block align-[-2px]" />
          {text}
        </>
      );
    case "error":
      return (
        <>
          <WarningIcon size={13} className="mr-1 inline-block align-[-2px]" />
          {text}
        </>
      );
    case "thought":
    case "system":
      return <span className="italic">{text}</span>;
    default:
      return <>{text}</>;
  }
}

/** The ⋯ button a row shows on hover (always on touch screens), and the same menu on a right click. */
function RowMenuButton({ menu, label }: { menu: ReturnType<typeof useMenu>; label: string }) {
  const ref = useRef<HTMLButtonElement>(null);
  return (
    <button
      ref={ref}
      type="button"
      aria-label={label}
      title={label}
      aria-haspopup="menu"
      aria-expanded={menu.open}
      onClick={(e) => {
        e.preventDefault();
        e.stopPropagation();
        if (menu.open) menu.close();
        else menu.fromElement(e.currentTarget);
      }}
      className="flex h-7 w-7 items-center justify-center rounded-full bg-surface text-muted shadow-sm ring-1 ring-line hover:text-fg"
    >
      <MoreIcon size={17} />
    </button>
  );
}

/** A drag handle (Edit and Reorder modes); arrow keys move the row too. */
function Handle({
  label,
  onPointerDown,
  onKeyDown,
  dataKey,
}: {
  label: string;
  onPointerDown?: (e: ReactPointerEvent<HTMLElement>) => void;
  onKeyDown?: (e: ReactKeyboardEvent<HTMLElement>) => void;
  dataKey: string;
}) {
  const { t } = useI18n();
  return (
    <button
      type="button"
      data-handle={dataKey}
      aria-label={label}
      title={t("drag_to_reorder")}
      onPointerDown={onPointerDown}
      onKeyDown={onKeyDown}
      className="flex h-10 w-8 shrink-0 cursor-grab touch-none items-center justify-center rounded-lg text-faint hover:text-fg"
    >
      <GripIcon size={18} />
    </button>
  );
}

export type ReorderProps = {
  onPointerDown?: (e: ReactPointerEvent<HTMLElement>) => void;
  onKeyDown?: (e: ReactKeyboardEvent<HTMLElement>) => void;
  dragging: boolean;
};

/**
 * A project (Telegram's row for a group with topics): the rounded-square avatar, name and time, its newest topics,
 * then what is going on in it and its unread total.
 */
export function ForumRow({
  group,
  now,
  timeText,
  onOpen,
  menu: items,
  reorder,
}: {
  group: ProjectGroup;
  now: number;
  /** A fixed time instead of the last activity's (the landing page's picture). */
  timeText?: string;
  onOpen: () => void;
  menu: MenuItem[];
  /** Edit mode: a handle instead of the menu, and the row doesn't open. */
  reorder?: ReorderProps;
}) {
  const { t, lang } = useI18n();
  const menu = useMenu();
  const summary = forumSummary(group);
  const offline = !group.deviceOnline;
  const latest = summary.latest;
  let activity: ReactNode;
  if (summary.activity === "running") activity = <span className="text-accent-text"><Working /></span>;
  else if (summary.activity === "waiting") activity = <NeedsApproval />;
  else if (latest?.starting && latest.status !== "error" && !offline) activity = <span className="text-accent-text">{t("starting")}</span>;
  else if (latest?.preview) activity = <PreviewText row={latest} />;
  else activity = <span className="text-faint">{t("no_messages_yet")}</span>;

  const body = (
    <>
      <ForumAvatar path={group.path} name={group.name} dimmed={offline} />
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          <span className={`min-w-0 flex-1 truncate text-[15.5px] font-semibold ${offline ? "text-muted" : "text-fg"}`} title={tildePath(group.path)}>
            {group.name}
          </span>
          <span
            className={`shrink-0 text-[12.5px] tabular-nums ${summary.unread > 0 && !offline ? "text-accent-text" : "text-faint"} ${
              items.length && !reorder ? HIDE_ON_HOVER : ""
            }`}
          >
            {timeText ?? formatListTime(group.lastActivityAt, lang, now)}
          </span>
        </span>
        {/* One line that truncates at its end, like the phones' topics strip. */}
        <span className="mt-0.5 block truncate text-[13.5px]">
          {summary.topics.map((topic, index) => (
            <span key={topic._id} className={index === 0 && !offline ? "font-medium text-fg" : "text-muted"}>
              {index > 0 ? "  " : null}
              <TopicIcon id={topic._id} title={topic.title} size={14} dimmed={offline} className="mr-1 inline-block align-[-2px]" />
              {topic.title || folderName(topic.cwd)}
            </span>
          ))}
        </span>
        <span className="mt-0.5 flex min-h-[22px] items-center gap-2">
          <span className={`min-w-0 flex-1 truncate text-[13.5px] ${offline ? "text-faint" : "text-muted"}`}>{activity}</span>
          {summary.unread > 0 ? <UnreadBadge count={summary.unread} muted={offline} /> : null}
        </span>
      </span>
    </>
  );

  return (
    <li
      data-project-key={group.key}
      onContextMenu={reorder || !items.length ? undefined : menu.atPointer}
      {...(reorder || !items.length ? {} : menu.longPress)}
      className={`group relative ${reorder?.dragging ? "z-20 rounded-xl bg-surface shadow-card" : ""}`}
    >
      {reorder ? (
        <div className="flex items-center gap-3 rounded-xl py-2 pl-2.5 pr-1">
          {body}
          <Handle
            dataKey={group.key}
            label={t("reorder_project_label", { name: group.name })}
            onPointerDown={reorder.onPointerDown}
            onKeyDown={reorder.onKeyDown}
          />
        </div>
      ) : (
        <button
          type="button"
          onClick={onOpen}
          className="flex w-full select-none items-start gap-3 rounded-xl px-2.5 py-2 text-left transition-colors [-webkit-touch-callout:none] hover:bg-hover focus-visible:bg-hover"
        >
          {body}
        </button>
      )}
      {!reorder && items.length ? (
        <div
          className={`absolute right-3 top-2 ${SHOW_ON_HOVER}`}
          style={menu.open ? { opacity: 1 } : undefined}
        >
          <RowMenuButton menu={menu} label={t("more_actions")} />
        </div>
      ) : null}
      <MenuPopover menu={menu} items={items} label={group.name} />
    </li>
  );
}

/** Telegram's Archived Chats: a grey circle with an archive box, the archived titles joined by ", ". */
export function ArchivedRow({ rows, onOpen }: { rows: SessionRow[]; onOpen: () => void }) {
  const { t } = useI18n();
  const unread = rows.reduce((sum, row) => sum + Math.max(0, row.unread), 0);
  return (
    <li>
      <button
        type="button"
        onClick={onOpen}
        className="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-hover focus-visible:bg-hover"
      >
        <ArchiveAvatar />
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-2">
            <span className="min-w-0 flex-1 truncate text-[15.5px] font-semibold text-fg">{t("archived_sessions")}</span>
            {unread > 0 ? <UnreadBadge count={unread} muted /> : null}
          </span>
          <span className="mt-0.5 block truncate text-[13.5px] text-muted">{rows.map((r) => r.title || folderName(r.cwd)).join(", ")}</span>
        </span>
      </button>
    </li>
  );
}

export type QuickAction = { label: string; icon: ReactNode; tone?: "danger"; onSelect: () => void };

/**
 * A session (Telegram's topic row): the topic icon, title and time, where it runs when that adds something, then the
 * preview in up to two lines, an animated "working…", or "Needs approval"; unread badge or pin. The open session's row
 * is selected (accent background, white text, as Telegram Web).
 */
export function TopicRow({
  row,
  now,
  active = false,
  showsProject = false,
  quick = [],
  menu: items,
  reorder,
}: {
  row: SessionRow;
  now: number;
  active?: boolean;
  /** A flat list (search, Archived): the second line names the project. */
  showsProject?: boolean;
  /** Hover buttons on the row's right (the phones' swipe actions). */
  quick?: QuickAction[];
  menu: MenuItem[];
  reorder?: ReorderProps;
}) {
  const { t, lang } = useI18n();
  const menu = useMenu();
  const offline = !row.deviceOnline;
  const folder = folderName(row.cwd);
  const place = [
    ...(showsProject ? [row.projectName] : []),
    ...(folder !== row.projectName ? [folder] : []),
    ...(offline ? [t("offline")] : []),
  ].filter(Boolean);

  let preview: ReactNode;
  if (row.starting && row.status !== "error" && !offline) {
    preview = <span className={active ? "" : "text-accent-text"}>{t("starting")}</span>;
  } else if (row.online && row.status === "running") {
    preview = (
      <span className={active ? "" : "text-accent-text"}>
        <Working />
      </span>
    );
  } else if (row.online && row.status === "waiting") {
    preview = <NeedsApproval inverted={active} />;
  } else if (row.preview?.trim()) {
    preview = <PreviewText row={row} />;
  } else if (row.historyState === "none" || row.historyState === "requested") {
    preview = <span className={active ? "" : "text-faint"}>{t("history_on", { computer: row.deviceName })}</span>;
  } else {
    preview = <span className={active ? "" : "text-faint"}>{t("no_messages_yet")}</span>;
  }

  const trailing =
    row.unread > 0 ? (
      <UnreadBadge count={row.unread} muted={offline} inverted={active} />
    ) : row.pinned ? (
      <PinIcon size={15} className={`mt-0.5 shrink-0 rotate-45 ${active ? "text-white/80" : "text-faint"}`} aria-label={t("pinned")} />
    ) : null;

  const content = (
    <>
      <TopicIcon id={row._id} title={row.title} size={40} dimmed={offline} className="mt-0.5" />
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          <span className={`min-w-0 flex-1 truncate text-[15px] font-semibold ${active ? "text-white" : offline ? "text-muted" : "text-fg"}`}>
            {row.title || folder}
          </span>
          <span
            className={`shrink-0 text-[12.5px] tabular-nums ${
              active ? "text-white/80" : row.unread > 0 && !offline ? "text-accent-text" : "text-faint"
            } ${(quick.length || items.length) && !reorder ? HIDE_ON_HOVER : ""}`}
          >
            {formatListTime(row.lastActivityAt, lang, now)}
          </span>
        </span>
        {place.length ? (
          <span className={`block truncate text-[13px] ${active ? "text-white/80" : "text-muted"}`} title={row.cwd}>
            {place.join(" · ")}
          </span>
        ) : null}
        <span className="mt-0.5 flex items-start gap-2">
          <span
            className={`line-clamp-2 min-w-0 flex-1 break-words text-[13.5px] leading-[1.35] ${
              active ? "text-white/85" : offline ? "text-faint" : "text-muted"
            }`}
          >
            {preview}
          </span>
          {trailing}
        </span>
      </span>
    </>
  );

  return (
    <li
      data-session-id={row._id}
      onContextMenu={reorder || !items.length ? undefined : menu.atPointer}
      {...(reorder || !items.length ? {} : menu.longPress)}
      className={`group relative ${reorder?.dragging ? "z-20 rounded-xl bg-surface shadow-card" : ""}`}
    >
      {reorder ? (
        <div className="flex items-start gap-3 rounded-xl py-2 pl-2.5 pr-1">
          {content}
          <Handle dataKey={row._id} label={t("drag_to_reorder")} onPointerDown={reorder.onPointerDown} onKeyDown={reorder.onKeyDown} />
        </div>
      ) : (
        <Link
          href={`/sessions/${row._id}`}
          aria-current={active ? "page" : undefined}
          draggable={false}
          className={`flex select-none items-start gap-3 rounded-xl px-2.5 py-2 transition-colors [-webkit-touch-callout:none] ${
            active ? "row-selected bg-accent text-white" : "hover:bg-hover focus-visible:bg-hover"
          }`}
        >
          {content}
        </Link>
      )}
      {!reorder && (quick.length || items.length) ? (
        <div
          className={`absolute right-3 top-1.5 flex items-center gap-1 ${SHOW_ON_HOVER}`}
          style={menu.open ? { opacity: 1 } : undefined}
        >
          {quick.map((action) => (
            <button
              key={action.label}
              type="button"
              aria-label={action.label}
              title={action.label}
              onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                action.onSelect();
              }}
              className={`hidden h-7 w-7 items-center justify-center rounded-full bg-surface shadow-sm ring-1 ring-line [@media(hover:hover)]:flex ${
                action.tone === "danger" ? "text-danger" : "text-muted hover:text-fg"
              }`}
            >
              {action.icon}
            </button>
          ))}
          {items.length ? <RowMenuButton menu={menu} label={t("more_actions")} /> : null}
        </div>
      ) : null}
      <MenuPopover menu={menu} items={items} label={row.title} />
    </li>
  );
}

/** Rows while the list loads. */
export function SkeletonRows({ count = 6, square = true }: { count?: number; square?: boolean }) {
  return (
    <ul aria-hidden="true" className="px-1.5">
      {Array.from({ length: count }, (_, i) => (
        <li key={i} className="flex gap-3 px-2.5 py-2.5">
          <span className={`h-[54px] w-[54px] shrink-0 animate-pulse bg-surface-2 ${square ? "rounded-[16px]" : "rounded-full"}`} />
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
