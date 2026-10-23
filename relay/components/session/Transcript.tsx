"use client";

import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { daysApart, formatClock, formatDayHeader } from "@/lib/format";
import type { MessageKey } from "@/lib/i18n";
import { renderMarkdown } from "@/lib/markdown";
import type { PendingPrompt, PromptCommand, TranscriptEvent } from "@/lib/types";
import { useI18n } from "../I18nProvider";
import type { BotCard } from "./BotCommands";
import {
  AlertIcon,
  ArrowDownIcon,
  BulbIcon,
  CheckIcon,
  ChevronRightIcon,
  ClockIcon,
  ComputerIcon,
  DoubleCheckIcon,
  SpinnerIcon,
  ToolKindIcon,
  XIcon,
} from "../icons";
// KaTeX's fonts and layout for the math in replies (lib/markdown.tsx), loaded with the transcript only.
import "katex/dist/katex.min.css";

/** Items of one author within this window merge into one group (Telegram's merge rule). */
const GROUP_WINDOW_MS = 10 * 60 * 1000;
/** Start loading the previous page when the top is this close. */
const LOAD_MORE_PX = 600;
/** Runs of tool calls longer than this collapse to a summary plus the latest call. */
const TOOL_RUN_COLLAPSE = 3;

/** `bot`: this browser's own command answers (`/model`, `/think`), never stored on the relay. */
type Side = "user" | "agent" | "system" | "bot";
type Item =
  | { type: "event"; event: TranscriptEvent }
  | { type: "pending"; prompt: PendingPrompt }
  | { type: "card"; card: BotCard };

function itemTime(item: Item): number {
  if (item.type === "event") return item.event.at;
  return item.type === "pending" ? item.prompt.createdAt : item.card.createdAt;
}

function itemKey(item: Item): string {
  if (item.type === "event") return item.event._id;
  return item.type === "pending" ? item.prompt.key : item.card.id;
}

function itemSide(item: Item): Side {
  if (item.type === "pending") return "user";
  if (item.type === "card") return "bot";
  switch (item.event.kind) {
    case "user":
      return "user";
    case "assistant":
    case "thought":
    case "tool":
      return "agent";
    default:
      return "system";
  }
}

type Group = { side: Side; items: Item[] };
type Day = { key: string; at: number; groups: Group[] };

function buildDays(items: Item[]): Day[] {
  const days: Day[] = [];
  for (const item of items) {
    const at = itemTime(item);
    let day = days[days.length - 1];
    if (!day || daysApart(day.at, at) !== 0) {
      day = { key: `d${at}`, at, groups: [] };
      days.push(day);
    }
    const side = itemSide(item);
    const group = day.groups[day.groups.length - 1];
    const last = group?.items[group.items.length - 1];
    if (group && group.side === side && side !== "system" && last && at - itemTime(last) < GROUP_WINDOW_MS) {
      group.items.push(item);
    } else {
      day.groups.push({ side, items: [item] });
    }
  }
  return days;
}

export type TranscriptProps = {
  /** Newest first, as `sessions:events` pages them. */
  events: TranscriptEvent[];
  pending: PendingPrompt[];
  commands: PromptCommand[] | undefined;
  canLoadMore: boolean;
  loadingMore: boolean;
  isDone: boolean;
  firstLoad: boolean;
  loadMore: () => void;
  onRetry: (prompt: PendingPrompt) => void;
  onDiscard: (prompt: PendingPrompt) => void;
  now: number;
  /**
   * Set while the transcript is still only on the computer (a session listed from its disk, `historyState` none or
   * requested): with no events yet, the transcript says it is loading from there, or that the computer is offline.
   */
  history?: { computer: string; online: boolean } | null;
  /** Bot cards (`/model`, `/think`), placed by time among the rest, and how to draw one. */
  cards?: BotCard[];
  renderCard?: (card: BotCard) => ReactNode;
  /** Shown in the middle while there is nothing at all (the new-session screen's "Starts in …"). */
  emptyNotice?: ReactNode;
};

/** In place of an empty transcript whose history the relay doesn't have yet. */
function HistoryNotice({ computer, online }: { computer: string; online: boolean }) {
  const { t } = useI18n();
  if (online) {
    return (
      <div
        role="status"
        className="flex items-center gap-2 rounded-full bg-surface px-4 py-2 text-[13.5px] text-muted shadow-sm"
      >
        <SpinnerIcon size={15} className="text-accent-text" />
        <span>{t("history_loading", { computer })}</span>
      </div>
    );
  }
  return (
    <div role="status" className="flex max-w-sm flex-col items-center gap-3 rounded-2xl bg-surface px-6 py-5 text-center shadow-sm">
      <span className="flex h-12 w-12 items-center justify-center rounded-full bg-surface-2 text-faint">
        <ComputerIcon size={22} />
      </span>
      <p className="text-[13.5px] leading-relaxed text-muted">{t("history_offline", { computer })}</p>
    </div>
  );
}

/**
 * Bottom-anchored transcript. The scroller is `flex-col-reverse`, so it opens at the newest message and older pages
 * prepended above don't move what you are reading; new messages arriving while you are scrolled up are compensated
 * below, and a "jump to latest" button counts them.
 */
export function Transcript(props: TranscriptProps) {
  const { events, pending, commands, canLoadMore, loadingMore, isDone, firstLoad, loadMore, now, history } = props;
  const cards = props.cards;
  const awaitingHistory = history && events.length === 0 && !firstLoad ? history : null;
  const { t, lang } = useI18n();
  const scrollerRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const [atBottom, setAtBottom] = useState(true);
  const atBottomRef = useRef(true);
  const seenSeqRef = useRef<number>(events[0]?.seq ?? 0);

  const items = useMemo<Item[]>(() => {
    const chrono: Item[] = [];
    for (let i = events.length - 1; i >= 0; i--) chrono.push({ type: "event", event: events[i] });
    for (const prompt of pending) chrono.push({ type: "pending", prompt });
    // Each card goes after everything that is not newer, without reordering the transcript itself.
    for (const card of cards ?? []) {
      let at = chrono.length;
      while (at > 0 && itemTime(chrono[at - 1]) > card.createdAt) at--;
      chrono.splice(at, 0, { type: "card", card });
    }
    return chrono;
  }, [events, pending, cards]);
  const days = useMemo(() => buildDays(items), [items]);
  const commandsById = useMemo(() => new Map((commands ?? []).map((c) => [c._id as string, c])), [commands]);

  const maybeLoadMore = useCallback(() => {
    const el = scrollerRef.current;
    if (!el || !canLoadMore || loadingMore) return;
    const fromTop = el.scrollHeight - el.clientHeight + el.scrollTop;
    if (fromTop < LOAD_MORE_PX) loadMore();
  }, [canLoadMore, loadingMore, loadMore]);

  // Fill the screen: keep loading while the top is in view (the scroll event alone would never fire).
  useEffect(() => {
    maybeLoadMore();
  }, [maybeLoadMore, events.length]);

  const onScroll = () => {
    const el = scrollerRef.current;
    if (!el) return;
    const bottom = -el.scrollTop < 80;
    if (bottom !== atBottomRef.current) {
      atBottomRef.current = bottom;
      setAtBottom(bottom);
      if (!bottom) seenSeqRef.current = events[0]?.seq ?? 0;
    }
    maybeLoadMore();
  };

  // While scrolled up, keep the reader's place when the newest item grows or a new one arrives at the bottom.
  const cardsKey = (cards ?? []).map((c) => c.state).join(",");
  const bottomKey = `${events[0]?._id ?? ""}:${events[0]?.text.length ?? 0}:${events[0]?.status ?? ""}:${pending.length}:${cardsKey}`;
  const lastHeight = useRef(0);
  const lastBottomKey = useRef(bottomKey);
  useLayoutEffect(() => {
    const el = scrollerRef.current;
    const content = contentRef.current;
    if (!el || !content) return;
    const height = content.offsetHeight;
    const delta = height - lastHeight.current;
    if (lastBottomKey.current !== bottomKey && delta !== 0 && !atBottomRef.current && lastHeight.current > 0) {
      el.scrollTop -= delta;
    }
    lastHeight.current = height;
    lastBottomKey.current = bottomKey;
  });

  // A command's answer is for the person who just typed it: bring it into view.
  const cardCount = cards?.length ?? 0;
  const lastCardCount = useRef(cardCount);
  useEffect(() => {
    if (cardCount > lastCardCount.current) scrollerRef.current?.scrollTo({ top: 0, behavior: "smooth" });
    lastCardCount.current = cardCount;
  }, [cardCount]);

  const newCount = atBottom
    ? 0
    : events.filter((e) => e.seq > seenSeqRef.current && (e.kind === "assistant" || e.kind === "user")).length;

  const jumpToLatest = () => {
    scrollerRef.current?.scrollTo({ top: 0, behavior: "smooth" });
  };

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div
        ref={scrollerRef}
        onScroll={onScroll}
        className="scroll-quiet flex min-h-0 flex-1 flex-col-reverse overflow-y-auto overscroll-contain"
        role="log"
        aria-live="polite"
        aria-relevant="additions"
      >
        <div ref={contentRef} className="mx-auto w-full max-w-3xl px-3 pb-4 pt-3 sm:px-6">
          {loadingMore || (firstLoad && events.length === 0) ? (
            <div className="flex justify-center py-4">
              <span className="svc flex items-center gap-2 rounded-full px-3 py-1 text-xs">
                <SpinnerIcon size={14} />
                {firstLoad ? t("loading") : t("loading_older")}
              </span>
            </div>
          ) : null}
          {isDone && !firstLoad && !awaitingHistory ? (
            <div className="flex justify-center py-4">
              <span className="svc rounded-full px-3 py-1 text-xs">
                {items.length ? t("transcript_start") : t("transcript_empty")}
              </span>
            </div>
          ) : null}
          {days.map((day) => (
            <section key={day.key} className="relative">
              <div className="sticky top-2 z-10 my-3 flex justify-center">
                <span className="svc rounded-full px-3 py-1 text-xs font-medium shadow-sm backdrop-blur">
                  {formatDayHeader(day.at, lang, now, { today: t("today"), yesterday: t("yesterday") })}
                </span>
              </div>
              <div className="flex flex-col gap-3">
                {day.groups.map((group) => (
                  <GroupView
                    key={itemKey(group.items[0])}
                    group={group}
                    commandsById={commandsById}
                    onRetry={props.onRetry}
                    onDiscard={props.onDiscard}
                    renderCard={props.renderCard}
                  />
                ))}
              </div>
            </section>
          ))}
        </div>
      </div>
      {props.emptyNotice && items.length === 0 ? (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-4">{props.emptyNotice}</div>
      ) : null}
      {awaitingHistory ? (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-4">
          <HistoryNotice computer={awaitingHistory.computer} online={awaitingHistory.online} />
        </div>
      ) : null}
      {!atBottom ? (
        <button
          type="button"
          onClick={jumpToLatest}
          aria-label={t("jump_latest")}
          title={t("jump_latest")}
          className="absolute bottom-4 right-4 flex h-11 w-11 items-center justify-center rounded-full border border-line bg-surface text-muted shadow-card hover:text-fg"
        >
          <ArrowDownIcon size={20} />
          {newCount > 0 ? (
            <span className="absolute -top-1.5 left-1/2 flex h-5 min-w-5 -translate-x-1/2 items-center justify-center rounded-full bg-accent px-1.5 text-[11px] font-semibold text-accent-fg">
              {newCount}
            </span>
          ) : null}
        </button>
      ) : null}
    </div>
  );
}

function GroupView({
  group,
  commandsById,
  onRetry,
  onDiscard,
  renderCard,
}: {
  group: Group;
  commandsById: Map<string, PromptCommand>;
  onRetry: (p: PendingPrompt) => void;
  onDiscard: (p: PendingPrompt) => void;
  renderCard?: (card: BotCard) => ReactNode;
}) {
  if (group.side === "bot") {
    return (
      <div className="flex flex-col items-start gap-3">
        {group.items.map((item) =>
          item.type === "card" ? (
            <div key={item.card.id} className="flex w-full flex-col items-start">
              {renderCard?.(item.card)}
            </div>
          ) : null,
        )}
        <TimeStamp at={itemTime(group.items[group.items.length - 1])} />
      </div>
    );
  }
  if (group.side === "system") {
    return (
      <div className="flex flex-col items-center gap-1.5">
        {group.items.map((item) =>
          item.type === "event" ? <SystemLine key={item.event._id} event={item.event} /> : null,
        )}
      </div>
    );
  }
  if (group.side === "user") {
    return (
      <div className="flex flex-col items-end gap-1">
        {group.items.map((item) =>
          item.type === "event" ? (
            <UserBubble key={item.event._id} event={item.event} command={commandsById.get(item.event.commandId ?? "")} />
          ) : item.type === "pending" ? (
            <PendingBubble key={item.prompt.key} prompt={item.prompt} onRetry={onRetry} onDiscard={onDiscard} />
          ) : null,
        )}
      </div>
    );
  }
  // Agent side: replies, thoughts and tool calls; long runs of tool calls collapse.
  const blocks: ReactNode[] = [];
  let run: TranscriptEvent[] = [];
  const flushRun = () => {
    if (!run.length) return;
    if (run.length > TOOL_RUN_COLLAPSE) blocks.push(<ToolRun key={`run-${run[0]._id}`} tools={run} />);
    else for (const tool of run) blocks.push(<ToolCard key={tool._id} event={tool} />);
    run = [];
  };
  for (const item of group.items) {
    if (item.type !== "event") continue;
    const event = item.event;
    if (event.kind === "tool") {
      run.push(event);
      continue;
    }
    flushRun();
    if (event.kind === "assistant") blocks.push(<AssistantBubble key={event._id} event={event} />);
    else if (event.kind === "thought") blocks.push(<ThoughtBlock key={event._id} event={event} />);
  }
  flushRun();
  const last = group.items[group.items.length - 1];
  return (
    <div className="flex flex-col items-start gap-1.5">
      {blocks}
      <TimeStamp at={itemTime(last)} />
    </div>
  );
}

function TimeStamp({ at }: { at: number }) {
  const { lang } = useI18n();
  return <span className="loose px-1 text-[11px] text-faint tabular-nums">{formatClock(at, lang)}</span>;
}

const AssistantBubble = memo(function AssistantBubble({ event }: { event: TranscriptEvent }) {
  const body = useMemo(() => renderMarkdown(event.text), [event.text]);
  return (
    <div className="md min-w-0 max-w-full rounded-2xl rounded-tl-md border border-line bg-surface px-4 py-3 text-[15px] text-fg sm:max-w-[92%]">
      {body}
    </div>
  );
});

function ThoughtBlock({ event }: { event: TranscriptEvent }) {
  const { t } = useI18n();
  const text = event.text.trim();
  if (!text) return null;
  return (
    <details className="thought group max-w-full rounded-xl px-1 text-sm text-muted sm:max-w-[92%]">
      <summary className="flex cursor-pointer list-none items-center gap-1.5 py-1 text-[13px] hover:text-fg [&::-webkit-details-marker]:hidden">
        <BulbIcon size={14} />
        <span>{event.title || t("thought")}</span>
        <ChevronRightIcon size={14} className="transition-transform group-open:rotate-90" />
      </summary>
      <div className="mt-1 whitespace-pre-wrap border-l-2 border-line pl-3 text-[13.5px] leading-relaxed">{text}</div>
    </details>
  );
}

function toolStatusKey(status?: string): MessageKey | null {
  switch (status) {
    case "pending":
      return "tool_pending";
    case "in_progress":
      return "tool_in_progress";
    case "completed":
      return "tool_completed";
    case "failed":
      return "tool_failed";
    default:
      return null;
  }
}

function ToolStatusIcon({ status }: { status?: string }) {
  if (status === "in_progress") return <SpinnerIcon size={14} className="text-accent-text" />;
  if (status === "completed") return <CheckIcon size={14} className="text-accent-text" />;
  if (status === "failed") return <XIcon size={14} className="text-danger" />;
  return <ClockIcon size={14} className="text-faint" />;
}

function ToolCard({ event }: { event: TranscriptEvent }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const detail = event.text.trim();
  const statusKey = toolStatusKey(event.status);
  const long = detail.split("\n").length > 6 || detail.length > 420;
  return (
    <div
      className={`w-full max-w-full rounded-xl border bg-surface/80 sm:max-w-[92%] ${
        event.status === "failed" ? "border-danger/40" : "border-line"
      }`}
    >
      <div className="flex items-center gap-2.5 px-3 py-2">
        <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-surface-2 text-muted">
          <ToolKindIcon kind={event.toolKind} size={15} />
        </span>
        <span className="min-w-0 flex-1 truncate text-[13.5px] font-medium text-fg" title={event.title}>
          {event.title || event.toolKind || "Tool"}
        </span>
        <span className="flex shrink-0 items-center gap-1 text-xs text-muted" title={statusKey ? t(statusKey) : undefined}>
          <ToolStatusIcon status={event.status} />
          <span className="sr-only">{statusKey ? t(statusKey) : event.status}</span>
        </span>
      </div>
      {detail ? (
        <div className="border-t border-line px-3 py-2">
          <pre
            className={`whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed text-muted ${
              long && !open ? "max-h-[7.5rem] overflow-hidden [mask-image:linear-gradient(to_bottom,black_70%,transparent)]" : ""
            }`}
          >
            {detail}
          </pre>
          {long ? (
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              className="mt-1 text-xs font-medium text-accent-text hover:underline"
            >
              {open ? t("show_less") : t("show_more")}
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function ToolRun({ tools }: { tools: TranscriptEvent[] }) {
  const { tn } = useI18n();
  const [open, setOpen] = useState(false);
  const failed = tools.filter((tool) => tool.status === "failed").length;
  const running = tools.some((tool) => tool.status === "in_progress" || tool.status === "pending");
  const shown = open ? tools : tools.slice(-1);
  return (
    <div className="flex w-full flex-col items-start gap-1.5">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="loose flex items-center gap-1.5 rounded-full px-2 py-1 text-[13px] text-muted hover:bg-hover hover:text-fg"
      >
        <ChevronRightIcon size={14} className={`transition-transform ${open ? "rotate-90" : ""}`} />
        {tn("tool_calls", tools.length)}
        {running ? <SpinnerIcon size={13} className="text-accent-text" /> : null}
        {failed ? (
          <span className="ml-1 flex items-center gap-0.5 text-danger">
            <XIcon size={12} />
            {failed}
          </span>
        ) : null}
      </button>
      {shown.map((tool) => (
        <ToolCard key={tool._id} event={tool} />
      ))}
    </div>
  );
}

function stopReasonKey(status?: string): MessageKey | null {
  switch (status) {
    case "cancelled":
      return "stop_cancelled";
    case "max_tokens":
      return "stop_max_tokens";
    case "refusal":
      return "stop_refusal";
    case "max_turn_requests":
      return "stop_max_turn_requests";
    default:
      return null;
  }
}

function SystemLine({ event }: { event: TranscriptEvent }) {
  const { t } = useI18n();
  if (event.kind === "error") {
    return (
      <div className="flex max-w-full items-start gap-2 rounded-xl bg-danger-soft px-3 py-2 text-[13px] text-danger sm:max-w-[92%]">
        <AlertIcon size={15} className="mt-px shrink-0" />
        <span className="whitespace-pre-wrap break-words">{event.text || event.title}</span>
      </div>
    );
  }
  const reason = stopReasonKey(event.status);
  const text = reason ? t(reason) : event.text.trim() || event.title || "";
  // A plain end of turn is implied by the reply itself.
  if (!text || (event.status === "end_turn" && !event.text.trim())) return null;
  return (
    <span className="svc max-w-[92%] rounded-full px-3 py-1 text-center text-xs">{text}</span>
  );
}

function Ticks({ tick }: { tick: PendingPrompt["tick"] | "done" }) {
  const { t } = useI18n();
  switch (tick) {
    case "sending":
    case "pending":
      return (
        <span title={t(tick === "sending" ? "tick_sending" : "tick_pending")}>
          <ClockIcon size={13} />
        </span>
      );
    case "delivered":
      return (
        <span title={t("tick_delivered")}>
          <CheckIcon size={14} />
        </span>
      );
    case "done":
      return (
        <span title={t("tick_done")}>
          <DoubleCheckIcon size={15} />
        </span>
      );
    case "failed":
      return (
        <span title={t("tick_failed")} className="text-danger">
          <AlertIcon size={15} />
        </span>
      );
  }
}

function UserBubble({ event, command }: { event: TranscriptEvent; command?: PromptCommand }) {
  const { t, lang } = useI18n();
  const remote = event.origin === "remote";
  const label = event.fromLabel ?? command?.fromLabel;
  const tick: "delivered" | "done" | null = remote ? (command?.status === "delivered" ? "delivered" : "done") : null;
  return (
    <div className="flex max-w-[88%] flex-col items-end sm:max-w-[78%]">
      {remote && label && label !== "Web" ? (
        <span className="loose mb-0.5 px-2 text-[11px] text-faint">{t("from_label", { label })}</span>
      ) : null}
      <div className="rounded-2xl rounded-tr-md bg-bubble-user px-3.5 py-2 text-[15px] leading-relaxed text-bubble-user-fg">
        <span className="whitespace-pre-wrap break-words">{event.text}</span>
        <span className="float-right ml-3 mt-1.5 flex translate-y-0.5 items-center gap-1 text-[11px] text-bubble-user-meta tabular-nums">
          {formatClock(event.at, lang)}
          {tick ? <Ticks tick={tick} /> : null}
        </span>
      </div>
    </div>
  );
}

function PendingBubble({
  prompt,
  onRetry,
  onDiscard,
}: {
  prompt: PendingPrompt;
  onRetry: (p: PendingPrompt) => void;
  onDiscard: (p: PendingPrompt) => void;
}) {
  const { t, lang } = useI18n();
  const failed = prompt.tick === "failed";
  return (
    <div className="flex max-w-[88%] flex-col items-end sm:max-w-[78%]">
      <div className="flex items-center gap-2">
        {failed ? <AlertIcon size={20} className="shrink-0 text-danger" aria-label={t("tick_failed")} /> : null}
        <div
          className={`rounded-2xl rounded-tr-md bg-bubble-user px-3.5 py-2 text-[15px] leading-relaxed text-bubble-user-fg ${
            failed ? "opacity-80" : ""
          }`}
        >
          <span className="whitespace-pre-wrap break-words">{prompt.text}</span>
          <span className="float-right ml-3 mt-1.5 flex translate-y-0.5 items-center gap-1 text-[11px] text-bubble-user-meta tabular-nums">
            {formatClock(prompt.createdAt, lang)}
            <Ticks tick={prompt.tick} />
          </span>
        </div>
      </div>
      {failed ? (
        <div className="loose mt-1 flex flex-wrap items-center justify-end gap-x-3 gap-y-1 px-1 text-xs">
          {prompt.error ? <span className="text-right text-danger">{prompt.error}</span> : null}
          <span className="flex shrink-0 gap-3">
            <button type="button" onClick={() => onRetry(prompt)} className="font-medium text-accent-text hover:underline">
              {t("retry")}
            </button>
            <button type="button" onClick={() => onDiscard(prompt)} className="font-medium text-muted hover:text-danger">
              {t("delete")}
            </button>
          </span>
        </div>
      ) : null}
    </div>
  );
}
